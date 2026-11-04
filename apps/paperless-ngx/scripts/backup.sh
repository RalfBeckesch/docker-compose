#!/usr/bin/env bash
# =============================================================================
# backup.sh – Paperless-ngx backup following the official recommendation
# =============================================================================
# Follows https://docs.paperless-ngx.com/administration/#making-backups
#
# Paperless ships its own exporter, and that is the primary mechanism used here:
# `document_exporter` writes documents, thumbnails and the database contents
# (manifest.json) into one folder, which can also be updated incrementally. On
# top of that the PostgreSQL database is dumped the classic way, because the
# export is tied to the running version while a dump restores into any instance.
#
# The manual warns that the export is only consistent when nothing is being
# consumed at that moment, so the consume directory is checked first.
#
# Usage:   ./scripts/backup.sh [--keep-days N] [--skip-export]
#            --keep-days N    override BACKUP_KEEP_DAYS from .env
#            --skip-export    skip document_exporter (database dump only)
# Needs:   docker with the compose plugin (v2), tar, gzip, GNU stat/find
# Writes:  ${BACKUP_DIR}/<timestamp>/{db.sql.gz,export.tar.gz,data.tar.gz,...}
#
# Exit codes:
#   0  backup complete and verified
#   2  usage error
#   3  prerequisite missing (.env, docker, daemon, running webserver)
#   5  a backup step failed
#   6  verification of the backup failed
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
APP_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly APP_DIR

readonly ENV_FILE="${APP_DIR}/docker-compose.env"
readonly COMPOSE_FILE="${APP_DIR}/docker-compose.yaml"
readonly EXPORT_PATH_IN_CONTAINER="/usr/src/paperless/export"
readonly MINIMUM_DUMP_BYTES=1024

readonly EXIT_USAGE=2
readonly EXIT_PREREQUISITE=3
readonly EXIT_BACKUP_FAILED=5
readonly EXIT_VERIFY_FAILED=6

KEEP_DAYS=""
SKIP_EXPORT="false"
BACKUP_ROOT=""
BACKUP_DIR=""

usage() {
  cat <<'USAGE'
backup.sh – Paperless-ngx backup (document exporter + database dump)

  ./scripts/backup.sh [--keep-days N] [--skip-export]

  --keep-days N    delete backup sets older than N days (default: BACKUP_KEEP_DAYS)
  --skip-export    do not run document_exporter, only dump the database and
                   archive the data and media directories

The exporter runs inside the running webserver container, so the stack has to be
up. It writes into PAPERLESS_EXPORT_DIR, which is part of the backup set.
USAGE
}

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() {
  local message="$1" code="${2:-1}"
  printf 'ERROR: %s\n' "${message}" >&2
  exit "${code}"
}

compose() { docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" "$@"; }

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
      -h|--help)     usage; exit 0 ;;
      --skip-export) SKIP_EXPORT="true" ;;
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
  [[ -f "${ENV_FILE}" ]] \
    || die "docker-compose.env is missing – run ./scripts/bootstrap.sh first" "${EXIT_PREREQUISITE}"
  if [[ -z "$(compose ps -q webserver 2>/dev/null)" ]]; then
    die "the webserver container is not running – start the stack first" "${EXIT_PREREQUISITE}"
  fi
}

load_env() {
  PAPERLESS_VERSION="$(env_value "${ENV_FILE}" PAPERLESS_VERSION)"
  PAPERLESS_DATA_DIR="$(env_value "${ENV_FILE}" PAPERLESS_DATA_DIR)"
  PAPERLESS_MEDIA_DIR="$(env_value "${ENV_FILE}" PAPERLESS_MEDIA_DIR)"
  PAPERLESS_EXPORT_DIR="$(env_value "${ENV_FILE}" PAPERLESS_EXPORT_DIR)"
  PAPERLESS_CONSUMPTION_DIR="$(env_value "${ENV_FILE}" PAPERLESS_CONSUMPTION_DIR)"
  POSTGRES_USER="$(env_value "${ENV_FILE}" POSTGRES_USER)"
  POSTGRES_DB="$(env_value "${ENV_FILE}" POSTGRES_DB)"
  BACKUP_ROOT="$(env_value "${ENV_FILE}" BACKUP_DIR)"
  BACKUP_KEEP_DAYS="$(env_value "${ENV_FILE}" BACKUP_KEEP_DAYS)"

  : "${PAPERLESS_VERSION:?PAPERLESS_VERSION is missing in the env file}"
  : "${PAPERLESS_DATA_DIR:?PAPERLESS_DATA_DIR is missing in the env file}"
  : "${PAPERLESS_MEDIA_DIR:?PAPERLESS_MEDIA_DIR is missing in the env file}"
  : "${PAPERLESS_EXPORT_DIR:?PAPERLESS_EXPORT_DIR is missing in the env file}"
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
Paperless-ngx backup
created:            $(date -Is)
pinned version:     ${PAPERLESS_VERSION}
database:           ${POSTGRES_DB} (service db)
data directory:     ${PAPERLESS_DATA_DIR}
media directory:    ${PAPERLESS_MEDIA_DIR}
export directory:   ${PAPERLESS_EXPORT_DIR}
procedure:          document_exporter + pg_dump, per official administration docs
restore:            see the RESTORE section of scripts/backup.sh output

The export directory holds the portable snapshot (documents, thumbnails,
manifest.json with all metadata) that document_importer reads back. The database
dump is the version-independent copy.
MANIFEST
}

check_consume_directory() {
  local pending

  [[ -n "${PAPERLESS_CONSUMPTION_DIR}" && -d "${PAPERLESS_CONSUMPTION_DIR}" ]] || return 0
  pending="$(find "${PAPERLESS_CONSUMPTION_DIR}" -type f 2>/dev/null | wc -l)"
  if (( pending > 0 )); then
    warn "${pending} file(s) are waiting in the consume directory (${PAPERLESS_CONSUMPTION_DIR})"
    warn "the administration manual asks for a moment where nothing is being consumed –"
    warn "the exporter may capture a document that is only half imported. Continuing anyway."
  else
    log "consume directory is empty – good moment for a backup"
  fi
}

run_document_exporter() {
  local manifest="${PAPERLESS_EXPORT_DIR}/manifest.json"

  if [[ "${SKIP_EXPORT}" == "true" ]]; then
    log "document_exporter skipped on request (--skip-export)"
    return 0
  fi

  # -T suppresses "the input device is not a TTY", which the official docs
  # recommend precisely for this call in a script or cron job.
  log "running document_exporter (this can take a while for large archives)"
  compose exec -T webserver document_exporter "${EXPORT_PATH_IN_CONTAINER}" \
    || die "document_exporter failed" "${EXIT_BACKUP_FAILED}"

  if [[ -s "${manifest}" ]]; then
    log "export verified: manifest.json present ($(stat -c %s "${manifest}") bytes)"
  else
    die "document_exporter finished but ${manifest} is missing or empty" "${EXIT_VERIFY_FAILED}"
  fi
}

create_database_dump() {
  local dump_file="${BACKUP_DIR}/db.sql.gz"
  local size marker

  log "creating the database dump"
  compose exec -T db pg_dump -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" | gzip > "${dump_file}" \
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
  local path
  local -a existing=()

  for path in "${PAPERLESS_DATA_DIR}" "${PAPERLESS_MEDIA_DIR}" "${PAPERLESS_EXPORT_DIR}"; do
    if [[ -e "${path}" ]]; then
      existing+=("${path}")
    else
      warn "path is missing, skipped: ${path}"
    fi
  done
  (( ${#existing[@]} > 0 )) || die "no data paths exist – check the paths in the env file" \
                                 "${EXIT_BACKUP_FAILED}"

  log "archiving ${#existing[@]} path(s)"
  tar -czf "${archive}" -C "${APP_DIR}" "${existing[@]}" \
    || die "archiving the data directories failed" "${EXIT_BACKUP_FAILED}"
  gzip -t "${archive}" || die "data archive is corrupted" "${EXIT_VERIFY_FAILED}"

  local entries
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

  if [[ "${SKIP_EXPORT}" != "true" && ! -s "${PAPERLESS_EXPORT_DIR}/manifest.json" ]]; then
    die "the export folder has no manifest.json" "${EXIT_VERIFY_FAILED}"
  fi
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

Restore with the DB dump (works across versions):
  1) cd ${APP_DIR} && docker compose --env-file docker-compose.env down
  2) docker compose --env-file docker-compose.env up -d db broker
  3) gunzip -c ${BACKUP_DIR}/db.sql.gz | \\
       docker compose --env-file docker-compose.env exec -T db psql -U ${POSTGRES_USER} -d ${POSTGRES_DB}
  4) tar -xzf ${BACKUP_DIR}/data.tar.gz -C ${APP_DIR}
  5) docker compose --env-file docker-compose.env up -d

Restore with the exporter (portable, same version):
  untar the export directory, then inside the webserver container run
    document_importer /usr/src/paperless/export
  Note: API tokens are not part of the export and have to be recreated.

A backup on the same disk is not a backup – copy ${BACKUP_ROOT} to other storage.
RESTORE
}

main() {
  parse_arguments "$@"
  trap on_error ERR

  cd "${APP_DIR}"
  check_prerequisites
  load_env
  log "pinned Paperless-ngx ${PAPERLESS_VERSION}"

  check_consume_directory
  prepare_backup_set
  run_document_exporter
  create_database_dump
  create_file_archive
  verify_backup
  prune_old_backups
  show_restore_instructions
}

main "$@"
