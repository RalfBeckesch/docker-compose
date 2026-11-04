#!/usr/bin/env bash
# =============================================================================
# backup.sh – Mealie backup
# =============================================================================
# Mealie's own backup feature (Settings → Admin Settings → Backups) is documented
# as BETA and requires an admin API token, so this script takes the route the
# manual describes for PostgreSQL installations: dump the database and archive
# the data directory, which holds recipes, images and uploads.
#
# https://docs.mealie.io/documentation/admin/backups-and-exports
#
# A restore with PostgreSQL needs a *superuser*: Mealie temporarily switches
# roles during an import. The restore instructions output at the end say so.
#
# Usage:   ./scripts/backup.sh [--keep-days N]
# Needs:   docker with the compose plugin (v2), tar, gzip, GNU stat/find
# Writes:  ${BACKUP_DIR}/<timestamp>/{db.sql.gz,data.tar.gz,env.backup,...}
#
# Exit codes:
#   0  backup complete and verified
#   2  usage error
#   3  prerequisite missing (.env, docker, daemon, running containers)
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
readonly MINIMUM_DUMP_BYTES=1024

readonly EXIT_USAGE=2
readonly EXIT_PREREQUISITE=3
readonly EXIT_BACKUP_FAILED=5
readonly EXIT_VERIFY_FAILED=6

KEEP_DAYS=""
BACKUP_ROOT=""
BACKUP_DIR=""

usage() {
  cat <<'USAGE'
backup.sh – Mealie backup (database dump + data directory)

  ./scripts/backup.sh [--keep-days N]

  --keep-days N   delete backup sets older than N days (default: BACKUP_KEEP_DAYS)

The stack has to be running: the database is dumped through the running postgres
container, which keeps the dump consistent without stopping Mealie.
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
  [[ -f "${ENV_FILE}" ]] || die ".env is missing – run ./scripts/bootstrap.sh first" "${EXIT_PREREQUISITE}"
  [[ -n "$(compose ps -q postgres 2>/dev/null)" ]] \
    || die "the postgres container is not running – start the stack first" "${EXIT_PREREQUISITE}"
}

load_env() {
  MEALIE_VERSION="$(env_value "${ENV_FILE}" MEALIE_VERSION)"
  MEALIE_DATA="$(env_value "${ENV_FILE}" MEALIE_DATA)"
  POSTGRES_USER="$(env_value "${ENV_FILE}" POSTGRES_USER)"
  POSTGRES_DB="$(env_value "${ENV_FILE}" POSTGRES_DB)"
  BACKUP_ROOT="$(env_value "${ENV_FILE}" BACKUP_DIR)"
  BACKUP_KEEP_DAYS="$(env_value "${ENV_FILE}" BACKUP_KEEP_DAYS)"

  : "${MEALIE_VERSION:?MEALIE_VERSION is missing in .env}"
  : "${MEALIE_DATA:?MEALIE_DATA is missing in .env}"
  : "${POSTGRES_USER:=mealie}"
  : "${POSTGRES_DB:=mealie}"
  : "${BACKUP_ROOT:=./backups}"
  : "${BACKUP_KEEP_DAYS:=7}"
  : "${KEEP_DAYS:=${BACKUP_KEEP_DAYS}}"
}

prepare_backup_set() {
  BACKUP_DIR="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "${BACKUP_DIR}"
  log "backup set: ${BACKUP_DIR}"

  compose config 2>/dev/null | grep -E '^[[:space:]]+image:' > "${BACKUP_DIR}/images.txt" || true
  cp "${ENV_FILE}" "${BACKUP_DIR}/env.backup"
  chmod 600 "${BACKUP_DIR}/env.backup"

  cat > "${BACKUP_DIR}/MANIFEST.txt" <<MANIFEST
Mealie backup
created:            $(date -Is)
pinned version:     ${MEALIE_VERSION}
database:           ${POSTGRES_DB} (service postgres)
data directory:     ${MEALIE_DATA}
procedure:          pg_dump + data directory (PostgreSQL route from the manual)
restore:            see the RESTORE section of scripts/backup.sh output

Mealie's built-in backup feature (Admin Settings → Backups) is BETA and needs an
admin API token. This set is the version-independent route.
MANIFEST
}

create_database_dump() {
  local dump_file="${BACKUP_DIR}/db.sql.gz"
  local size marker

  log "creating the database dump"
  compose exec -T postgres pg_dump -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" | gzip > "${dump_file}" \
    || die "pg_dump failed" "${EXIT_BACKUP_FAILED}"

  gzip -t "${dump_file}" || die "dump archive is corrupted" "${EXIT_VERIFY_FAILED}"
  size="$(zcat "${dump_file}" | wc -c)"
  (( size > MINIMUM_DUMP_BYTES )) \
    || die "dump is implausibly small at ${size} bytes uncompressed" "${EXIT_VERIFY_FAILED}"
  marker="$(zcat "${dump_file}" | head -20 | grep -c 'PostgreSQL database dump' || true)"
  (( marker > 0 )) || die "dump has no PostgreSQL header" "${EXIT_VERIFY_FAILED}"
  log "database dump verified (${size} bytes uncompressed)"
}

create_file_archive() {
  local archive="${BACKUP_DIR}/data.tar.gz"
  local entries

  [[ -e "${MEALIE_DATA}" ]] || die "data directory ${MEALIE_DATA} does not exist" "${EXIT_BACKUP_FAILED}"

  log "archiving ${MEALIE_DATA}"
  tar -czf "${archive}" -C "${APP_DIR}" "${MEALIE_DATA}" \
    || die "archiving the data directory failed" "${EXIT_BACKUP_FAILED}"
  gzip -t "${archive}" || die "data archive is corrupted" "${EXIT_VERIFY_FAILED}"

  entries="$(tar -tzf "${archive}" | wc -l)"
  (( entries > 0 )) || die "data archive contains no entries" "${EXIT_VERIFY_FAILED}"
  log "data archive verified (${entries} entries, $(stat -c %s "${archive}") bytes)"
}

verify_backup() {
  local missing=0 file

  for file in db.sql.gz data.tar.gz env.backup MANIFEST.txt; do
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
  2) tar -xzf ${BACKUP_DIR}/data.tar.gz -C ${APP_DIR}
  3) docker compose up -d postgres
  4) gunzip -c ${BACKUP_DIR}/db.sql.gz | \\
       docker compose exec -T postgres psql -U ${POSTGRES_USER} -d ${POSTGRES_DB}
  5) docker compose up -d

Mealie can only import through its own feature with a PostgreSQL *superuser*:
     docker compose exec -T postgres psql -U ${POSTGRES_USER} -d ${POSTGRES_DB} \\
       -c 'ALTER USER ${POSTGRES_USER} WITH SUPERUSER;'
   run the restore in the web UI (Admin Settings → Backups → Upload),
   then revoke it again with NOSUPERUSER.

A backup on the same disk is not a backup – copy ${BACKUP_ROOT} to other storage.
RESTORE
}

main() {
  parse_arguments "$@"
  trap on_error ERR

  cd "${APP_DIR}"
  check_prerequisites
  load_env
  log "pinned Mealie ${MEALIE_VERSION}"

  prepare_backup_set
  create_database_dump
  create_file_archive
  verify_backup
  prune_old_backups
  show_restore_instructions
}

main "$@"
