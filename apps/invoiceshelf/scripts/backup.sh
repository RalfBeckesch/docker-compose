#!/usr/bin/env bash
# =============================================================================
# backup.sh – InvoiceShelf backup: database dump + storage archive
# =============================================================================
# InvoiceShelf documents its backup in the UI (Settings → Backups, types "full",
# "only db", "only files") and implements it with spatie/laravel-backup. The
# in-app job cannot be triggered from the command line, so this script performs
# the same "full" backup from the host:
#
#   1. pg_dump of the database          -> db.sql.gz
#   2. tar of storage/ and Modules/     -> data.tar.gz
#   3. .env, MANIFEST.txt and the resolved image tags
#
# The stack keeps running: pg_dump takes a consistent snapshot, and storage/ is
# dominated by uploads and generated PDFs. The database dump is the authoritative
# part – files that change during the tar are reported, not fatal.
#
# NOT in the set: TLS certificates of a reverse proxy, and anything stored in S3
# or another remote FileDisk when you configured one in the UI.
#
# https://docs.invoiceshelf.com/guide/backups.html
#
# Usage:   ./scripts/backup.sh [--keep-days N]
# Needs:   docker with the compose plugin (v2), gzip, tar, GNU stat/find
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
readonly SERVICE_NAME="invoiceshelf"
readonly DATA_ARCHIVE="data.tar.gz"
readonly MINIMUM_DUMP_BYTES=1024

readonly EXIT_USAGE=2
readonly EXIT_PREREQUISITE=3
readonly EXIT_BACKUP_FAILED=5
readonly EXIT_VERIFY_FAILED=6

KEEP_DAYS=""
BACKUP_ROOT=""
BACKUP_DIR=""
INVOICESHELF_STORAGE=""
INVOICESHELF_MODULES=""

usage() {
  cat <<'USAGE'
backup.sh – InvoiceShelf backup (PostgreSQL dump + storage archive)

  ./scripts/backup.sh [--keep-days N]

  --keep-days N   delete backup sets older than N days (default: BACKUP_KEEP_DAYS)

The stack keeps running during the backup. The database dump is taken with
pg_dump and verified; storage/ and Modules/ are archived with tar.
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

# Read one value from the env file without sourcing it: the file carries values
# that a shell would misinterpret, and readonly variables would abort the run.
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
      -h|--help)   usage; exit 0 ;;
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
  [[ -n "$(compose ps -q "${SERVICE_NAME}" 2>/dev/null)" ]] \
    || die "the ${SERVICE_NAME} container is not running – start the stack first" "${EXIT_PREREQUISITE}"
}

load_env() {
  INVOICESHELF_VERSION="$(env_value "${ENV_FILE}" INVOICESHELF_VERSION)"
  INVOICESHELF_STORAGE="$(env_value "${ENV_FILE}" INVOICESHELF_STORAGE)"
  INVOICESHELF_MODULES="$(env_value "${ENV_FILE}" INVOICESHELF_MODULES)"
  POSTGRES_USER="$(env_value "${ENV_FILE}" POSTGRES_USER)"
  POSTGRES_DB="$(env_value "${ENV_FILE}" POSTGRES_DB)"
  BACKUP_ROOT="$(env_value "${ENV_FILE}" BACKUP_DIR)"
  BACKUP_KEEP_DAYS="$(env_value "${ENV_FILE}" BACKUP_KEEP_DAYS)"

  : "${INVOICESHELF_VERSION:?INVOICESHELF_VERSION is missing in .env}"
  : "${INVOICESHELF_STORAGE:?INVOICESHELF_STORAGE is missing in .env}"
  : "${INVOICESHELF_MODULES:?INVOICESHELF_MODULES is missing in .env}"
  : "${POSTGRES_USER:=invoiceshelf}"
  : "${POSTGRES_DB:=invoiceshelf}"
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
InvoiceShelf backup
created:            $(date -Is)
pinned version:     ${INVOICESHELF_VERSION}
database:           ${POSTGRES_DB} (service db)
storage directory:  ${INVOICESHELF_STORAGE}
modules directory:  ${INVOICESHELF_MODULES}
procedure:          pg_dump (online) + tar of storage/ and Modules/
restore:            see the RESTORE section printed by scripts/backup.sh

db.sql.gz is the database. data.tar.gz holds storage/ (uploads, generated PDFs,
sessions, logs, storage/app/.app_key) and Modules/. The stack kept running during
the backup, so files that changed while being archived may be from a moment
slightly after the database snapshot.
MANIFEST
}

create_database_dump() {
  local dump_file="${BACKUP_DIR}/db.sql.gz"
  local size marker

  log "creating the database dump (the stack is still running)"
  compose exec -T db pg_dump -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" | gzip > "${dump_file}" \
    || die "pg_dump failed" "${EXIT_BACKUP_FAILED}"

  gzip -t "${dump_file}" || die "dump archive is corrupted" "${EXIT_VERIFY_FAILED}"
  size="$(zcat "${dump_file}" | wc -c)"
  (( size > MINIMUM_DUMP_BYTES )) \
    || die "database dump is implausibly small at ${size} bytes uncompressed" "${EXIT_VERIFY_FAILED}"
  marker="$(zcat "${dump_file}" | head -20 | grep -c 'PostgreSQL database dump' || true)"
  (( marker > 0 )) || die "database dump has no PostgreSQL header" "${EXIT_VERIFY_FAILED}"
  log "database dump verified (${size} bytes uncompressed)"
}

create_file_archive() {
  local archive="${BACKUP_DIR}/${DATA_ARCHIVE}"
  local -a members=()
  local directory entries rc=0

  for directory in "${INVOICESHELF_STORAGE}" "${INVOICESHELF_MODULES}"; do
    [[ -d "${directory}" ]] || { warn "directory missing: ${directory}"; continue; }
    members+=("${directory}")
  done
  (( ${#members[@]} > 0 )) || die "no application directory to archive" "${EXIT_BACKUP_FAILED}"

  log "archiving storage and modules"
  # The stack keeps running, so a log or session file can change while it is
  # being read. tar then reports "file changed as we read it" and exits 1 –
  # that is expected here and not a failure. The database dump is authoritative.
  tar -czf "${archive}" -C "${APP_DIR}" --warning=no-file-changed "${members[@]}" \
    2>/dev/null || rc=$?
  if (( rc != 0 && rc != 1 )); then
    die "archiving the application directories failed (tar exit ${rc})" "${EXIT_BACKUP_FAILED}"
  fi
  (( rc == 1 )) && warn "tar reported files that changed while being read (normal on a running stack)"

  gzip -t "${archive}" || die "data archive is corrupted" "${EXIT_VERIFY_FAILED}"
  entries="$(tar -tzf "${archive}" | wc -l)"
  (( entries > 0 )) || die "data archive contains no entries" "${EXIT_VERIFY_FAILED}"
  log "data archive verified (${entries} entries, $(stat -c %s "${archive}") bytes)"
}

verify_backup() {
  local missing=0 file

  gzip -t "${BACKUP_DIR}/db.sql.gz" || die "database dump is corrupted" "${EXIT_VERIFY_FAILED}"
  tar -tzf "${BACKUP_DIR}/${DATA_ARCHIVE}" | grep -q 'storage' \
    || die "data archive has no storage directory" "${EXIT_VERIFY_FAILED}"
  log "storage is part of the archive"

  for file in db.sql.gz "${DATA_ARCHIVE}" env.backup MANIFEST.txt images.txt; do
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

Restore a complete backup:
  1) cd ${APP_DIR} && docker compose down
  2) docker compose up -d db
  3) gunzip -c ${BACKUP_DIR}/db.sql.gz | \\
       docker compose exec -T db psql -U ${POSTGRES_USER} -d ${POSTGRES_DB}
  4) tar -xzf ${BACKUP_DIR}/${DATA_ARCHIVE} -C ${APP_DIR}
  5) docker compose up -d

Step 3 into a database that already holds data: drop and recreate the schema
first, or the import fails on existing tables. On a fresh installation the
database is empty, so the import just works.

The .env of the backed-up installation is in ${BACKUP_DIR}/env.backup – restore
it over .env if the stack configuration was lost as well. APP_KEY must be the
same as before the restore, or encrypted values (including stored mail and
payment credentials) become unreadable.

The same backup can also be created from the UI: Settings → Backups, type "full".
That is the vendor's own path and writes a ZIP into the storage volume, which is
NOT a copy off the machine either.

A backup on the same disk is not a backup – copy ${BACKUP_ROOT} to other storage.
RESTORE
}

main() {
  parse_arguments "$@"
  trap on_error ERR

  cd "${APP_DIR}"
  check_prerequisites
  load_env
  log "pinned InvoiceShelf ${INVOICESHELF_VERSION}"

  prepare_backup_set
  create_database_dump
  create_file_archive
  verify_backup
  prune_old_backups
  show_restore_instructions
}

main "$@"
