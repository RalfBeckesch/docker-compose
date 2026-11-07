#!/usr/bin/env bash
# =============================================================================
# backup.sh – Forgejo backup
# =============================================================================
# Forgejo keeps database, repositories, LFS objects, attachments and its
# configuration in one place: the /data volume. The vendor's own procedure is
# the `dump` command, which packs all of that into a single archive:
#   app.ini, forgejo-db.sql (the database dump), repos/, data/, custom/, log/
#
# The documentation is explicit about consistency: the instance must be shut
# down while the dump runs. A push or migration in flight can leave the
# repository copy and the database dump disagreeing. So this script
#
#   1. stops the server container (the database keeps running – the dump needs
#      a live connection to produce the SQL),
#   2. runs `forgejo dump` in a one-off container of the same image,
#   3. moves the archive out of the data volume into the backup set,
#   4. starts the server again – also when a step above failed (trap).
#
# What is NOT in the set: the host's OpenSSH authorized_keys (only relevant if
# you use the host's sshd instead of the built-in server) and TLS certificates.
#
# https://forgejo.org/docs/latest/admin/installation-docker/
# https://docs.gitea.com/administration/backup-and-restore/
#
# Usage:   ./scripts/backup.sh [--keep-days N]
# Needs:   docker with the compose plugin (v2), gzip, tar, GNU stat/find
# Writes:  ${BACKUP_DIR}/<timestamp>/{forgejo-dump.tar.gz,env.backup,...}
#
# Exit codes:
#   0  backup complete and verified
#   2  usage error
#   3  prerequisite missing (.env, docker, daemon)
#   5  a backup step failed
#   6  verification of the backup failed
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
APP_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly APP_DIR

readonly ENV_FILE="${APP_DIR}/.env"
readonly COMPOSE_FILE="${APP_DIR}/docker-compose.yaml"
readonly CONTAINER_CONFIG="/data/gitea/conf/app.ini"
readonly DUMP_FILENAME="forgejo-dump.tar.gz"
readonly CONTAINER_DUMP_PATH="/data/${DUMP_FILENAME}"
readonly MINIMUM_DUMP_BYTES=2048

readonly EXIT_USAGE=2
readonly EXIT_PREREQUISITE=3
readonly EXIT_BACKUP_FAILED=5
readonly EXIT_VERIFY_FAILED=6

KEEP_DAYS=""
BACKUP_ROOT=""
BACKUP_DIR=""
SERVER_STOPPED="false"

usage() {
  cat <<'USAGE'
backup.sh – Forgejo backup (dump + data volume)

  ./scripts/backup.sh [--keep-days N]

  --keep-days N   delete backup sets older than N days (default: BACKUP_KEEP_DAYS)

Runs the vendor's `forgejo dump` command, which packs app.ini, a SQL dump of the
database, the repositories, LFS objects, attachments and customisations into one
archive. The server container is stopped for the dump and restarted afterwards –
also when the dump fails. The database container keeps running.

Restore: unpack the archive into the volume as described in the output.
USAGE
}

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() {
  local message="$1" code="${2:-1}"
  printf 'ERROR: %s\n' "${message}" >&2
  exit "${code}"
}

compose() { docker compose -f "${COMPOSE_FILE}" "$@"; }

start_server_again() {
  if [[ "${SERVER_STOPPED}" == "true" ]]; then
    if compose start server >/dev/null 2>&1; then
      SERVER_STOPPED="false"
      log "server container started again"
    else
      warn "could not start the server container – start it manually:"
      warn "  docker compose -f ${COMPOSE_FILE} start server"
    fi
  fi
}

on_error() {
  local exit_code=$?

  printf '\n=== ABORTED (exit %s) ===\n' "${exit_code}" >&2
  start_server_again
  if [[ -n "${BACKUP_DIR}" && -d "${BACKUP_DIR}" ]]; then
    printf 'incomplete backup kept for inspection: %s\n' "${BACKUP_DIR}" >&2
  fi
  exit "${exit_code}"
}

env_value() {
  local file="$1" key="$2" line value

  line="$(grep -E "^[[:space:]]*${key}=" "${file}" 2>/dev/null | tail -1)" || true
  [[ -n "${line}" ]] || return 0
  value="${line#*=}"
  case "${value}" in
    \"*\") value="${value#\"}"; value="${value%\"}" ;;
    \'*\') value="${value#\'}"; value="${value%\'}" ;;
    *)     value="$(printf '%s\n' "${value}" | sed -e 's/[[:space:]]#.*$//' -e 's/[[:space:]]*$//')" ;;
  esac
  printf '%s\n' "${value}"
}

parse_arguments() {
  local argument

  while (( $# > 0 )); do
    argument="$1"
    case "${argument}" in
      -h|--help) usage; exit 0 ;;
      --keep-days)
        [[ -n "${2:-}" ]] || die "--keep-days needs a number" "${EXIT_USAGE}"
        KEEP_DAYS="$2"
        shift
        ;;
      --keep-days=*) KEEP_DAYS="${argument#*=}" ;;
      *) usage; die "unknown option: ${argument}" "${EXIT_USAGE}" ;;
    esac
    shift
  done

  if [[ -n "${KEEP_DAYS}" && ! "${KEEP_DAYS}" =~ ^[0-9]+$ ]]; then
    die "--keep-days expects a whole number" "${EXIT_USAGE}"
  fi
}

check_prerequisites() {
  command -v docker >/dev/null 2>&1 || die "command 'docker' not found" "${EXIT_PREREQUISITE}"
  docker compose version >/dev/null 2>&1 \
    || die "docker compose (plugin v2) is not available" "${EXIT_PREREQUISITE}"
  docker info >/dev/null 2>&1 || die "docker daemon is not reachable" "${EXIT_PREREQUISITE}"
  [[ -f "${ENV_FILE}" ]] || die ".env is missing – copy env-dist and fill it in" "${EXIT_PREREQUISITE}"
}

load_env() {
  FORGEJO_VERSION="$(env_value "${ENV_FILE}" FORGEJO_VERSION)"
  FORGEJO_DATA="$(env_value "${ENV_FILE}" FORGEJO_DATA)"
  FORGEJO_ROOT_URL="$(env_value "${ENV_FILE}" FORGEJO_ROOT_URL)"
  COMPOSE_PROJECT_NAME="$(env_value "${ENV_FILE}" COMPOSE_PROJECT_NAME)"
  BACKUP_ROOT="$(env_value "${ENV_FILE}" BACKUP_DIR)"
  BACKUP_KEEP_DAYS="$(env_value "${ENV_FILE}" BACKUP_KEEP_DAYS)"

  : "${FORGEJO_DATA:=./data/forgejo}"
  : "${COMPOSE_PROJECT_NAME:=forgejo}"
  : "${BACKUP_ROOT:=./backups}"
  : "${BACKUP_KEEP_DAYS:=7}"
  : "${KEEP_DAYS:=${BACKUP_KEEP_DAYS}}"

  [[ -d "${FORGEJO_DATA}" ]] \
    || die "data directory ${FORGEJO_DATA} does not exist – Forgejo keeps app.ini, repositories and LFS there" \
        "${EXIT_PREREQUISITE}"
}

prepare_backup_set() {
  BACKUP_DIR="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "${BACKUP_DIR}"
  log "backup set: ${BACKUP_DIR}"

  compose config 2>/dev/null | grep -E '^[[:space:]]+image:' > "${BACKUP_DIR}/images.txt" || true
  cp "${ENV_FILE}" "${BACKUP_DIR}/env.backup"
  chmod 600 "${BACKUP_DIR}/env.backup"

  cat > "${BACKUP_DIR}/MANIFEST.txt" <<MANIFEST
Forgejo backup
created:            $(date -Is)
version:            ${FORGEJO_VERSION:-unknown}
public URL:         ${FORGEJO_ROOT_URL:-unknown}
procedure:          vendor dump command with the server container stopped
contents:           app.ini, forgejo-db.sql, repos/, data/ (avatars, attachments,
                    LFS, indexer), custom/, log/
not included:       host OpenSSH authorized_keys (only used with the host's sshd)
                    and TLS certificates of a reverse proxy
restore:            see the RESTORE section of scripts/backup.sh output
MANIFEST
}

stop_server() {
  if [[ -n "$(compose ps -q server 2>/dev/null)" ]]; then
    log "stopping the server container for a consistent dump"
    compose stop server >/dev/null
    SERVER_STOPPED="true"
  else
    log "server container is not running – dumping without a stop"
  fi
}

create_dump() {
  local dump_file="${FORGEJO_DATA}/${DUMP_FILENAME}"

  # A leftover from an aborted run would make `dump` fail (it refuses to
  # overwrite) or, worse, end up in the next backup set as a stale file.
  rm -f "${dump_file}"

  log "running forgejo dump (this takes a while on large instances)"
  compose run --rm --no-deps --user git \
      --entrypoint /usr/local/bin/forgejo \
      server dump \
      -c "${CONTAINER_CONFIG}" \
      --type tar.gz \
      --file "${CONTAINER_DUMP_PATH}" \
    || die "forgejo dump failed" "${EXIT_BACKUP_FAILED}"

  [[ -s "${dump_file}" ]] \
    || die "forgejo dump produced no archive at ${dump_file}" "${EXIT_BACKUP_FAILED}"

  mv "${dump_file}" "${BACKUP_DIR}/${DUMP_FILENAME}"
  chmod 600 "${BACKUP_DIR}/${DUMP_FILENAME}" 2>/dev/null || true
  log "dump moved into the backup set"
}

verify_backup() {
  local archive="${BACKUP_DIR}/${DUMP_FILENAME}"
  local entries size missing=0 file

  gzip -t "${archive}" || die "dump archive is corrupted" "${EXIT_VERIFY_FAILED}"

  size="$(stat -c %s "${archive}")"
  (( size >= MINIMUM_DUMP_BYTES )) \
    || die "dump archive is implausibly small (${size} bytes)" "${EXIT_VERIFY_FAILED}"

  entries="$(tar -tzf "${archive}" | wc -l)"
  (( entries > 0 )) || die "dump archive contains no entries" "${EXIT_VERIFY_FAILED}"

  # The vendor archive always carries the configuration and the SQL dump.
  tar -tzf "${archive}" | grep -q 'app\.ini$' \
    || die "dump archive has no app.ini" "${EXIT_VERIFY_FAILED}"
  tar -tzf "${archive}" | grep -qE '\.sql$' \
    || die "dump archive has no database dump" "${EXIT_VERIFY_FAILED}"
  log "dump archive verified (${entries} entries, ${size} bytes)"

  for file in env.backup MANIFEST.txt images.txt; do
    [[ -s "${BACKUP_DIR}/${file}" ]] || { warn "missing or empty: ${file}"; missing=$(( missing + 1 )); }
  done
  (( missing == 0 )) || die "${missing} expected file(s) are missing" "${EXIT_VERIFY_FAILED}"

  log "backup set verified: $(du -sh "${BACKUP_DIR}" | cut -f1) in ${BACKUP_DIR}"
}

prune_old_backups() {
  local removed=0 candidate age_days

  [[ -d "${BACKUP_ROOT}" ]] || return 0
  while IFS= read -r candidate; do
    [[ -n "${candidate}" ]] || continue
    age_days=$(( ( $(date +%s) - $(stat -c %Y "${candidate}") ) / 86400 ))
    if (( age_days > KEEP_DAYS )); then
      rm -rf "${candidate}"
      removed=$(( removed + 1 ))
      log "pruned $(basename "${candidate}") (${age_days} days old)"
    fi
  done < <(find "${BACKUP_ROOT}" -mindepth 1 -maxdepth 1 -type d \
             -name '[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]')

  log "retention: ${KEEP_DAYS} days, ${removed} set(s) pruned"
}

show_restore_instructions() {
  cat <<RESTORE

=== Backup finished ===
set:   ${BACKUP_DIR}
size:  $(du -sh "${BACKUP_DIR}" | cut -f1)

Restore (same Forgejo version, empty volume):
  1) cd ${APP_DIR} && docker compose down
  2) rm -rf ${FORGEJO_DATA}/* ${FORGEJO_DATA}/.[!.]* 2>/dev/null || true
  3) tar -xzf ${BACKUP_DIR}/${DUMP_FILENAME} -C ${FORGEJO_DATA}
  4) chown -R ${FORGEJO_UID:-1000}:${FORGEJO_GID:-1000} ${FORGEJO_DATA}
  5) create an empty database matching .env, then import forgejo-db.sql:
       docker compose up -d db
       docker compose exec -T db psql -U ${POSTGRES_USER:-forgejo} \
         -d ${POSTGRES_DB:-forgejo} < ${FORGEJO_DATA}/forgejo-db.sql
  6) docker compose up -d
  7) docker compose exec -u git server forgejo admin regenerate keys
     docker compose exec -u git server forgejo doctor check --all

The archive has no top-level folder – app.ini and forgejo-db.sql sit at its
root. A backup on the same disk is not a backup: copy ${BACKUP_ROOT} elsewhere.
RESTORE
}

main() {
  parse_arguments "$@"
  trap on_error ERR

  cd "${APP_DIR}"
  check_prerequisites
  load_env
  log "backing up Forgejo ${FORGEJO_VERSION:-}"

  prepare_backup_set
  stop_server
  create_dump
  start_server_again
  verify_backup
  prune_old_backups
  show_restore_instructions
}

main "$@"
