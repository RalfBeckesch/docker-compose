#!/usr/bin/env bash
# =============================================================================
# backup.sh – Vikunja backup using the official dump command
# =============================================================================
# Follows https://vikunja.io/docs/cli/#dump
#
# Vikunja ships a first-class command for exactly this job: `vikunja dump`
# writes a single ZIP containing the configuration, the version, all uploaded
# files and the complete database. That is the primary mechanism here.
#
# The container needs a writable path for the archive, so the dump is written
# into the mounted files directory and moved into the backup set afterwards.
# On top of it a plain pg_dump is taken: small, fast, and independent of the
# Vikunja version, which makes it the better tool for rolling a bad upgrade back.
#
# Usage:   ./scripts/backup.sh [--keep-days N] [--skip-dump]
#            --keep-days N   override BACKUP_KEEP_DAYS from .env
#            --skip-dump     skip `vikunja dump`, archive only database and .env
# Needs:   docker with the compose plugin (v2), tar, gzip, GNU stat/find
# Writes:  ${BACKUP_DIR}/<timestamp>/{vikunja-dump.zip,db.sql.gz,env.backup,...}
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
readonly SERVICE_NAME="vikunja"
readonly DUMP_PATH_IN_CONTAINER="/app/vikunja/files"
readonly DUMP_FILENAME="vikunja-dump.zip"
readonly MINIMUM_DUMP_BYTES=1024

readonly EXIT_USAGE=2
readonly EXIT_PREREQUISITE=3
readonly EXIT_BACKUP_FAILED=5
readonly EXIT_VERIFY_FAILED=6

KEEP_DAYS=""
SKIP_DUMP="false"
BACKUP_ROOT=""
BACKUP_DIR=""
VIKUNJA_FILES=""

usage() {
  cat <<'USAGE'
backup.sh – Vikunja backup (official dump + database dump)

  ./scripts/backup.sh [--keep-days N] [--skip-dump]

  --keep-days N   delete backup sets older than N days (default: BACKUP_KEEP_DAYS)
  --skip-dump     do not run `vikunja dump`; keep only the database dump and .env

`vikunja dump` is written into the mounted files directory and moved into the
backup set afterwards, because that is the only path the container may write to.
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
  # A dump left behind in the files directory would end up in the next backup.
  if [[ -n "${VIKUNJA_FILES}" && -f "${VIKUNJA_FILES}/${DUMP_FILENAME}" ]]; then
    warn "removing the leftover dump from the files directory"
    rm -f "${VIKUNJA_FILES}/${DUMP_FILENAME}" || true
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
      -h|--help)   usage; exit 0 ;;
      --skip-dump) SKIP_DUMP="true" ;;
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
  VIKUNJA_VERSION="$(env_value "${ENV_FILE}" VIKUNJA_VERSION)"
  VIKUNJA_FILES="$(env_value "${ENV_FILE}" VIKUNJA_FILES)"
  POSTGRES_USER="$(env_value "${ENV_FILE}" POSTGRES_USER)"
  POSTGRES_DB="$(env_value "${ENV_FILE}" POSTGRES_DB)"
  BACKUP_ROOT="$(env_value "${ENV_FILE}" BACKUP_DIR)"
  BACKUP_KEEP_DAYS="$(env_value "${ENV_FILE}" BACKUP_KEEP_DAYS)"

  : "${VIKUNJA_VERSION:?VIKUNJA_VERSION is missing in .env}"
  : "${VIKUNJA_FILES:?VIKUNJA_FILES is missing in .env}"
  : "${POSTGRES_USER:=vikunja}"
  : "${POSTGRES_DB:=vikunja}"
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
Vikunja backup
created:            $(date -Is)
pinned version:     ${VIKUNJA_VERSION}
database:           ${POSTGRES_DB} (service db)
files directory:    ${VIKUNJA_FILES}
procedure:          vikunja dump (config, version, files, database) + pg_dump
restore:            see the RESTORE section of scripts/backup.sh output

vikunja-dump.zip is the complete snapshot and is read back by 'vikunja restore'.
db.sql.gz is the version-independent database copy – the faster way back after a
failed upgrade.
MANIFEST
}

create_vikunja_dump() {
  local source="${VIKUNJA_FILES}/${DUMP_FILENAME}"
  local target="${BACKUP_DIR}/${DUMP_FILENAME}"
  local size

  if [[ "${SKIP_DUMP}" == "true" ]]; then
    log "vikunja dump skipped on request (--skip-dump)"
    return 0
  fi

  if [[ -e "${source}" ]]; then
    die "a file named ${DUMP_FILENAME} already exists in ${VIKUNJA_FILES} – remove it and retry" \
        "${EXIT_PREREQUISITE}"
  fi

  # -T keeps the command non-interactive; -p points at the mounted files
  # directory, the only path the container is allowed to write to.
  log "running the official dump inside the container"
  if ! compose exec -T "${SERVICE_NAME}" \
        /app/vikunja/vikunja dump -p "${DUMP_PATH_IN_CONTAINER}" -f "${DUMP_FILENAME}"; then
    die "vikunja dump failed – try 'docker compose exec ${SERVICE_NAME} /app/vikunja/vikunja dump' by hand" \
        "${EXIT_BACKUP_FAILED}"
  fi

  [[ -f "${source}" ]] \
    || die "the dump was reported as successful but ${source} does not exist" "${EXIT_BACKUP_FAILED}"

  mv "${source}" "${target}" || die "could not move the dump into the backup set" "${EXIT_BACKUP_FAILED}"

  size="$(stat -c %s "${target}")"
  (( size > MINIMUM_DUMP_BYTES )) \
    || die "the dump is implausibly small at ${size} bytes" "${EXIT_VERIFY_FAILED}"

  # Check the ZIP magic without unzip being installed.
  if [[ "$(head -c 2 "${target}")" == "PK" ]]; then
    log "dump verified (${size} bytes, ZIP signature ok)"
  else
    die "the dump is not a ZIP archive" "${EXIT_VERIFY_FAILED}"
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

verify_backup() {
  local missing=0 file

  for file in db.sql.gz env.backup MANIFEST.txt; do
    [[ -s "${BACKUP_DIR}/${file}" ]] || { warn "missing or empty: ${file}"; missing=$(( missing + 1 )); }
  done
  if [[ "${SKIP_DUMP}" != "true" ]]; then
    [[ -s "${BACKUP_DIR}/${DUMP_FILENAME}" ]] \
      || { warn "missing or empty: ${DUMP_FILENAME}"; missing=$(( missing + 1 )); }
  fi
  (( missing == 0 )) || die "${missing} expected file(s) are missing" "${EXIT_VERIFY_FAILED}"

  # The dump must not linger in the files directory: it would be archived again
  # by the next run and grow the backup set needlessly.
  if [[ -e "${VIKUNJA_FILES}/${DUMP_FILENAME}" ]]; then
    die "the dump is still present in ${VIKUNJA_FILES}" "${EXIT_VERIFY_FAILED}"
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

Restore from the complete dump (config, files and database in one step):
  1) cd ${APP_DIR} && docker compose down
  2) cp ${BACKUP_DIR}/${DUMP_FILENAME} ${VIKUNJA_FILES}/${DUMP_FILENAME}
  3) docker compose up -d db
  4) docker compose exec ${SERVICE_NAME} /app/vikunja/vikunja restore \\
       ${DUMP_PATH_IN_CONTAINER}/${DUMP_FILENAME}
     add --preserve-config if the current .env/config should win over the dump
  5) rm ${VIKUNJA_FILES}/${DUMP_FILENAME} && docker compose up -d

Restore from the database dump only (faster, version-independent):
  gunzip -c ${BACKUP_DIR}/db.sql.gz | \\
    docker compose exec -T db psql -U ${POSTGRES_USER} -d ${POSTGRES_DB}
  Note: attachments live in ${VIKUNJA_FILES} and are NOT part of this dump.

A backup on the same disk is not a backup – copy ${BACKUP_ROOT} to other storage.
RESTORE
}

main() {
  parse_arguments "$@"
  trap on_error ERR

  cd "${APP_DIR}"
  check_prerequisites
  load_env
  log "pinned Vikunja ${VIKUNJA_VERSION}"

  prepare_backup_set
  create_vikunja_dump
  create_database_dump
  verify_backup
  prune_old_backups
  show_restore_instructions
}

main "$@"
