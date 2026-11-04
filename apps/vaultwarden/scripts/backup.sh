#!/usr/bin/env bash
# =============================================================================
# backup.sh – Vaultwarden backup following the official wiki procedure
# =============================================================================
# Follows https://github.com/dani-garcia/vaultwarden/wiki/Backing-up-your-vault
#
# The wiki recommends Sqlite's Online Backup API (.backup) because it copies a
# running database without locking it – no downtime. Two things the wiki is
# explicit about:
#
#   * attachments/ MUST be backed up (it is not inside the database)
#   * the official Docker image ships neither sqlite3 nor cron, so the backup
#     has to run on the host
#
# Therefore: if sqlite3 is available, the online backup is used. If it is not,
# the script falls back to stopping the service for a moment and copying the
# database files (including -wal and -shm), which the wiki allows as long as the
# database is not in use at that time.
#
# Usage:   ./scripts/backup.sh [--keep-days N]
# Needs:   docker with the compose plugin (v2), tar, gzip, GNU stat/find,
#          sqlite3 on the host for the online backup (optional)
# Writes:  ${BACKUP_DIR}/<timestamp>/{db.sqlite3,data.tar.gz,env.backup,...}
#
# Exit codes:
#   0  backup complete and verified
#   2  usage error
#   3  prerequisite missing (.env, docker, daemon, data directory)
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
readonly SERVICE_NAME="bitwarden"
readonly SQLITE_MAGIC="SQLite format 3"

readonly EXIT_USAGE=2
readonly EXIT_PREREQUISITE=3
readonly EXIT_BACKUP_FAILED=5
readonly EXIT_VERIFY_FAILED=6

KEEP_DAYS=""
BACKUP_ROOT=""
BACKUP_DIR=""
DATA=""
STACK_STOPPED="false"

usage() {
  cat <<'USAGE'
backup.sh – Vaultwarden backup (consistent SQLite copy + data directory)

  ./scripts/backup.sh [--keep-days N]

  --keep-days N   delete backup sets older than N days (default: BACKUP_KEEP_DAYS)

Uses sqlite3's online backup when sqlite3 is installed on the host, so the
service keeps running. Without sqlite3 the service is stopped briefly while the
database files are copied – the wiki allows that as long as nothing uses the
database at that moment.
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

on_error() {
  local exit_code=$?

  printf '\n=== ABORTED (exit %s) ===\n' "${exit_code}" >&2
  if [[ "${STACK_STOPPED}" == "true" ]]; then
    warn "backup failed while the service was stopped – starting it again"
    compose up -d || warn "could not start the service – run: docker compose up -d"
  fi
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
  VERSION="$(env_value "${ENV_FILE}" VERSION)"
  DATA="$(env_value "${ENV_FILE}" DATA)"
  BACKUP_ROOT="$(env_value "${ENV_FILE}" BACKUP_DIR)"
  BACKUP_KEEP_DAYS="$(env_value "${ENV_FILE}" BACKUP_KEEP_DAYS)"

  : "${VERSION:=latest}"
  : "${DATA:=./data/vaultwarden}"
  : "${BACKUP_ROOT:=./backups}"
  : "${BACKUP_KEEP_DAYS:=7}"
  : "${KEEP_DAYS:=${BACKUP_KEEP_DAYS}}"

  [[ -d "${DATA}" ]] || die "data directory ${DATA} does not exist" "${EXIT_PREREQUISITE}"
  [[ -f "${DATA}/db.sqlite3" ]] \
    || die "no db.sqlite3 in ${DATA} – is this instance initialised?" "${EXIT_PREREQUISITE}"
}

prepare_backup_set() {
  BACKUP_DIR="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "${BACKUP_DIR}"
  log "backup set: ${BACKUP_DIR}"

  compose config 2>/dev/null | grep -E '^[[:space:]]+image:' > "${BACKUP_DIR}/images.txt" || true
  cp "${ENV_FILE}" "${BACKUP_DIR}/env.backup"
  chmod 600 "${BACKUP_DIR}/env.backup"

  cat > "${BACKUP_DIR}/MANIFEST.txt" <<MANIFEST
Vaultwarden backup
created:            $(date -Is)
pinned version:     ${VERSION}
data directory:     ${DATA}
procedure:          SQLite online backup (or copy while stopped) + data directory
included:           db.sqlite3, attachments/, config.json, rsa keys, etc.
not included:       icon_cache/ is part of the archive but can be dropped – it is
                    rebuilt on demand from the websites' favicons
restore:            see the RESTORE section of scripts/backup.sh output
MANIFEST
}

create_database_copy() {
  local target="${BACKUP_DIR}/db.sqlite3"

  if command -v sqlite3 >/dev/null 2>&1; then
    log "sqlite3 found – using the online backup API (no downtime)"
    sqlite3 "${DATA}/db.sqlite3" ".backup '${target}'" \
      || die "sqlite3 .backup failed" "${EXIT_BACKUP_FAILED}"

    local integrity
    integrity="$(sqlite3 "${target}" 'PRAGMA integrity_check;' 2>/dev/null || true)"
    if [[ "${integrity}" == "ok" ]]; then
      log "integrity_check: ok"
    else
      die "integrity_check reported: ${integrity:-<no answer>}" "${EXIT_VERIFY_FAILED}"
    fi
    return 0
  fi

  warn "sqlite3 is not installed on this host"
  warn "falling back to a short stop: the official image has no sqlite3 of its own,"
  warn "so this is the documented alternative for a database that is not in use."
  compose stop "${SERVICE_NAME}" || die "could not stop the service" "${EXIT_BACKUP_FAILED}"
  STACK_STOPPED="true"

  # Copy WAL and SHM as well: without them a just-written transaction would be lost.
  local file
  for file in db.sqlite3 db.sqlite3-wal db.sqlite3-shm; do
    [[ -f "${DATA}/${file}" ]] && cp -p "${DATA}/${file}" "${BACKUP_DIR}/${file}" || true
  done

  compose up -d || die "could not start the service again" "${EXIT_BACKUP_FAILED}"
  STACK_STOPPED="false"
  log "service started again – db.sqlite3 (plus -wal/-shm) copied while stopped"
}

create_file_archive() {
  local archive="${BACKUP_DIR}/data.tar.gz"
  local entries

  log "archiving ${DATA} without the database files (those are copied separately)"
  tar -czf "${archive}" -C "${APP_DIR}" \
      --exclude="db.sqlite3" --exclude="db.sqlite3-wal" --exclude="db.sqlite3-shm" \
      "${DATA}" \
    || die "archiving the data directory failed" "${EXIT_BACKUP_FAILED}"
  gzip -t "${archive}" || die "data archive is corrupted" "${EXIT_VERIFY_FAILED}"

  entries="$(tar -tzf "${archive}" | wc -l)"
  (( entries > 0 )) || die "data archive contains no entries" "${EXIT_VERIFY_FAILED}"

  if tar -tzf "${archive}" | grep -q '/attachments/'; then
    log "attachments/ is part of the archive – the wiki calls them mandatory"
  else
    warn "no attachments/ in the archive – fine for an instance without file uploads,"
    warn "but check this if you use attachments"
  fi
  log "data archive verified (${entries} entries, $(stat -c %s "${archive}") bytes)"
}

verify_backup() {
  local missing=0 file
  local header

  [[ -s "${BACKUP_DIR}/db.sqlite3" ]] \
    || die "db.sqlite3 is missing or empty in the backup set" "${EXIT_VERIFY_FAILED}"

  # Reading the magic bytes works without sqlite3.
  header="$(head -c 16 "${BACKUP_DIR}/db.sqlite3" | tr -d '\0')"
  [[ "${header}" == "${SQLITE_MAGIC}" ]] \
    || die "db.sqlite3 does not start with '${SQLITE_MAGIC}' (found: ${header})" "${EXIT_VERIFY_FAILED}"
  log "db.sqlite3 verified ($(stat -c %s "${BACKUP_DIR}/db.sqlite3") bytes, SQLite header ok)"

  for file in data.tar.gz env.backup MANIFEST.txt; do
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

Restore:
  1) cd ${APP_DIR} && docker compose down
  2) cp -a ${DATA} ${DATA}.broken            # keep the current state as a fallback
  3) remove the database files AND the leftovers from the running instance:
       rm -f ${DATA}/db.sqlite3 ${DATA}/db.sqlite3-wal ${DATA}/db.sqlite3-shm
     The wiki is explicit about that: a stale -wal file makes Vaultwarden ignore
     the restored database.
  4) cp ${BACKUP_DIR}/db.sqlite3 ${DATA}/db.sqlite3
  5) tar -xzf ${BACKUP_DIR}/data.tar.gz -C ${APP_DIR}
  6) docker compose up -d

A copy of db.sqlite3 is not a vault export: if you only need a disaster copy,
the same data lives in the web vault under Tools → Export vault (JSON). Store
that file somewhere else – it contains all secrets in clear text.

A backup on the same disk is not a backup – copy ${BACKUP_ROOT} to other storage.
RESTORE
}

main() {
  parse_arguments "$@"
  trap on_error ERR

  cd "${APP_DIR}"
  check_prerequisites
  load_env
  log "Vaultwarden image tag ${VERSION}"

  prepare_backup_set
  create_database_copy
  create_file_archive
  verify_backup
  prune_old_backups
  show_restore_instructions
}

main "$@"
