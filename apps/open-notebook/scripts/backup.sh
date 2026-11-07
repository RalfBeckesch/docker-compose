#!/usr/bin/env bash
# =============================================================================
# backup.sh – Open Notebook backup
# =============================================================================
# The project's own documentation names the procedure: stop the services and
# copy both data folders.
#
#   docker compose down
#   tar czf open-notebook-backup.tgz surreal_data notebook_data
#   docker compose up -d
#
# https://github.com/lfnovo/open-notebook/blob/main/docs/1-INSTALLATION/docker-compose.md
#
# Both folders are needed. The database holds sources, notes, embeddings and the
# job queue; the application folder holds uploads and the caches. Copying only
# one leaves an instance that starts but has no documents or no database.
#
# The stack is stopped while the archive is written: RocksDB writes continuously
# and a copy taken from a running database can be torn. Downtime is a few
# seconds – the archive is created right after `stop`, then the stack is started
# again, also when a step fails.
#
# Permissions: when SURREAL_UID/SURREAL_GID are 0:0 the database runs as root and
# leaves root-owned files in SURREAL_DATA. This script reads them as the
# invoking user; if that fails, it names the exact remedy. When started via sudo
# it hands the backup set back to SUDO_USER so the operator can read it later.
#
# Usage:   ./scripts/backup.sh [--keep-days N]
# Needs:   docker with the compose plugin (v2), tar, gzip, GNU stat/find
# Writes:  ${BACKUP_DIR}/<timestamp>/{state.tar.gz,env.backup,...}
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
readonly ARCHIVE_NAME="state.tar.gz"

readonly EXIT_USAGE=2
readonly EXIT_PREREQUISITE=3
readonly EXIT_BACKUP_FAILED=5
readonly EXIT_VERIFY_FAILED=6

KEEP_DAYS=""
BACKUP_ROOT=""
BACKUP_DIR=""
STACK_STOPPED="0"

usage() {
  cat <<'USAGE'
backup.sh – Open Notebook backup (database folder + application folder)

  ./scripts/backup.sh [--keep-days N]

  --keep-days N   delete backup sets older than N days (default: BACKUP_KEEP_DAYS)

Stops the stack, archives both bind mounts into one tarball and starts the stack
again. Captures everything needed to rebuild the instance on a fresh host.
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

  # Restart the stack even when the backup failed – leaving the instance down is
  # worse than an incomplete backup set.
  if [[ "${STACK_STOPPED}" == "1" ]]; then
    printf '\n=== ABORTED (exit %s) – starting the stack again ===\n' "${exit_code}" >&2
    compose up -d >&2 || printf 'WARNING: the stack could not be started again\n' >&2
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
  OPEN_NOTEBOOK_VERSION="$(env_value "${ENV_FILE}" OPEN_NOTEBOOK_VERSION)"
  SURREAL_DATA="$(env_value "${ENV_FILE}" SURREAL_DATA)"
  NOTEBOOK_DATA="$(env_value "${ENV_FILE}" NOTEBOOK_DATA)"
  BACKUP_ROOT="$(env_value "${ENV_FILE}" BACKUP_DIR)"
  BACKUP_KEEP_DAYS="$(env_value "${ENV_FILE}" BACKUP_KEEP_DAYS)"

  : "${SURREAL_DATA:=./data/open-notebook/surreal}"
  : "${NOTEBOOK_DATA:=./data/open-notebook/notebook}"
  : "${BACKUP_ROOT:=./backups}"
  : "${BACKUP_KEEP_DAYS:=7}"
  : "${KEEP_DAYS:=${BACKUP_KEEP_DAYS}}"

  [[ -d "${SURREAL_DATA}" ]] \
    || die "database directory ${SURREAL_DATA} does not exist – nothing to back up" "${EXIT_PREREQUISITE}"
  [[ -d "${NOTEBOOK_DATA}" ]] \
    || die "application directory ${NOTEBOOK_DATA} does not exist – nothing to back up" "${EXIT_PREREQUISITE}"

  # Fail before stopping the stack if the files cannot be read at all. One probe
  # file per directory is enough to know whether sudo is needed.
  local probe unreadable=0
  for probe in "${SURREAL_DATA}" "${NOTEBOOK_DATA}"; do
    if ! find "${probe}" -maxdepth 2 -type f -readable -print -quit 2>/dev/null | grep -q .; then
      unreadable=$(( unreadable + 1 ))
    fi
  done
  if (( unreadable > 0 )); then
    warn "some files in the data directories are not readable as $(id -un)."
    warn "SurrealDB runs as root when SURREAL_UID=0 and leaves root-owned files."
    warn "Remedy: run 'sudo ./scripts/backup.sh' – or set SURREAL_UID/SURREAL_GID"
    warn "to your own uid:gid in .env and chown the data directory once."
  fi
}

prepare_backup_set() {
  BACKUP_DIR="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "${BACKUP_DIR}"
  log "backup set: ${BACKUP_DIR}"

  compose config 2>/dev/null | grep -E '^[[:space:]]+image:' > "${BACKUP_DIR}/images.txt" || true
  cp "${ENV_FILE}" "${BACKUP_DIR}/env.backup"
  chmod 600 "${BACKUP_DIR}/env.backup"

  cat > "${BACKUP_DIR}/MANIFEST.txt" <<MANIFEST
Open Notebook backup
created:            $(date -Is)
version:            ${OPEN_NOTEBOOK_VERSION:-unknown}
database folder:    ${SURREAL_DATA}   (RocksDB: sources, notes, embeddings, job queue)
application folder: ${NOTEBOOK_DATA}  (uploads and caches)
procedure:          vendor procedure – stack stopped, both folders archived, stack started again
restore:            see the RESTORE section printed by scripts/backup.sh
MANIFEST
}

stop_stack() {
  log "stopping the stack"
  STACK_STOPPED="1"
  compose stop || die "stopping the stack failed" "${EXIT_BACKUP_FAILED}"
}

create_archive() {
  local archive="${BACKUP_DIR}/${ARCHIVE_NAME}"

  log "archiving the data directories"
  tar -czf "${archive}" -C "${APP_DIR}" "${SURREAL_DATA}" "${NOTEBOOK_DATA}" \
    || die "archiving failed (permissions? see the WARNING above – try sudo)" "${EXIT_BACKUP_FAILED}"
  gzip -t "${archive}" || die "archive is corrupted" "${EXIT_VERIFY_FAILED}"

  local entries
  entries="$(tar -tzf "${archive}" | wc -l)"
  (( entries > 0 )) || die "archive contains no entries" "${EXIT_VERIFY_FAILED}"
  log "archive verified (${entries} entries, $(stat -c %s "${archive}") bytes)"
}

start_stack_again() {
  log "starting the stack again"
  compose up -d || die "the stack did not start again" "${EXIT_BACKUP_FAILED}"
  STACK_STOPPED="0"
}

hand_over_ownership() {
  # When the script ran via sudo, the backup set belongs to root. Give it to the
  # invoking user so later runs (and the operator) can read and prune it.
  local owner="${SUDO_USER:-}"

  [[ -n "${owner}" ]] || return 0
  if chown -R "${owner}:" "${BACKUP_DIR}" 2>/dev/null; then
    log "backup set handed over to ${owner}"
  else
    warn "could not chown ${BACKUP_DIR} to ${owner}"
  fi
}

verify_backup() {
  local missing=0 file

  for file in "${ARCHIVE_NAME}" env.backup MANIFEST.txt; do
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
      rm -rf "${candidate}" 2>/dev/null || { warn "could not prune ${candidate} (root-owned? use sudo)"; continue; }
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

Restore (on this host or a fresh one):
  1) cd ${APP_DIR}
  2) docker compose down
  3) rm -rf ${SURREAL_DATA} ${NOTEBOOK_DATA}
  4) tar -xzf ${BACKUP_DIR}/${ARCHIVE_NAME} -C ${APP_DIR}
  5) cp ${BACKUP_DIR}/env.backup .env && chmod 600 .env
  6) docker compose up -d

Steps 4 and 5 need the same privileges the backup was taken with. If the set is
root-owned, run them with sudo and chown the restored data directories to
SURREAL_UID/SURREAL_GID afterwards.

The encryption key in .env must stay the same, otherwise provider credentials
stored in the database can no longer be decrypted. Since v1.15.0 the encryption
format changed: rolling back to an older image requires the backup taken before
the update.

A backup on the same disk is not a backup – copy ${BACKUP_ROOT} to other storage.
RESTORE
}

main() {
  parse_arguments "$@"
  trap on_error ERR

  cd "${APP_DIR}"
  check_prerequisites
  load_env
  log "backing up Open Notebook ${OPEN_NOTEBOOK_VERSION:-}"

  prepare_backup_set
  stop_stack
  create_archive
  start_stack_again
  hand_over_ownership
  verify_backup
  prune_old_backups
  show_restore_instructions
}

main "$@"
