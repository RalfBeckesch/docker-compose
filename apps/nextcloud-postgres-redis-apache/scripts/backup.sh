#!/usr/bin/env bash
# =============================================================================
# backup.sh – Consistent Nextcloud backup
# =============================================================================
# Follows the official procedure from the Nextcloud administration manual:
# https://docs.nextcloud.com/server/stable/admin_manual/maintenance/backup.html
#
# The manual is explicit that the database and the files describe each other,
# so they must be captured at the same moment: the script enables maintenance
# mode first, dumps the database, archives the directories, and disables
# maintenance mode again. A trap guarantees the mode is switched off even when
# the run fails – otherwise the instance would stay offline.
#
# Order of operations: maintenance mode on → database dump → archive .env and
# the data directories → maintenance mode off → verify → prune old sets →
# print restore instructions.
#
# Usage:   ./scripts/backup.sh [--keep-days N] [--skip-app-data]
#            --keep-days N     override BACKUP_KEEP_DAYS from .env
#            --skip-app-data   leave NEXTCLOUD_APP_DATA out (custom apps only)
# Needs:   docker with the compose plugin (v2), tar, gzip, GNU stat/find
# Writes:  ${BACKUP_DIR}/<timestamp>/{db.sql.gz,data.tar.gz,env.backup,...}
#
# Exit codes:
#   0  backup complete and verified
#   2  usage error
#   3  prerequisite missing (.env, docker, daemon, data path)
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
SKIP_APP_DATA="false"
BACKUP_ROOT=""
BACKUP_DIR=""
INSTANCE=""
MAINTENANCE_MODE_ON="false"

usage() {
  cat <<'USAGE'
backup.sh – consistent Nextcloud backup (database + files together)

  ./scripts/backup.sh [--keep-days N] [--skip-app-data]

The script manages Nextcloud's maintenance mode itself: it switches it on for the
duration of the backup and off again afterwards, including on failure.

  --keep-days N     delete backup sets older than N days (default: BACKUP_KEEP_DAYS)
  --skip-app-data   leave the application directory out of the archive.
                    Only needed if you installed custom apps; otherwise the code
                    comes from the image and the directory is a large duplicate.
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
occ()     { compose exec -T -u www-data app php occ "$@"; }

on_error() {
  local exit_code=$?

  printf '\n=== ABORTED (exit %s) ===\n' "${exit_code}" >&2
  if [[ "${MAINTENANCE_MODE_ON}" == "true" ]]; then
    warn "backup failed – switching the maintenance mode off again"
    occ maintenance:mode --off || \
      warn "could not disable it – run: docker compose exec -u www-data app php occ maintenance:mode --off"
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
      -h|--help)      usage; exit 0 ;;
      --skip-app-data) SKIP_APP_DATA="true" ;;
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

  # The occ-based verification needs a running app container.
  if [[ -z "$(compose ps -q app 2>/dev/null)" ]]; then
    die "the app container is not running – start the stack before backing it up" "${EXIT_PREREQUISITE}"
  fi
}

load_env() {
  NEXTCLOUD_VERSION="$(env_value "${ENV_FILE}" NEXTCLOUD_VERSION)"
  INSTANCE_NAME="$(env_value "${ENV_FILE}" INSTANCE_NAME)"
  POSTGRES_USER="$(env_value "${ENV_FILE}" POSTGRES_USER)"
  POSTGRES_DB="$(env_value "${ENV_FILE}" POSTGRES_DB)"
  NEXTCLOUD_DATA="$(env_value "${ENV_FILE}" NEXTCLOUD_DATA)"
  NEXTCLOUD_APP_DATA="$(env_value "${ENV_FILE}" NEXTCLOUD_APP_DATA)"
  NEXTCLOUD_CONFIG="$(env_value "${ENV_FILE}" NEXTCLOUD_CONFIG)"
  BACKUP_ROOT="$(env_value "${ENV_FILE}" BACKUP_DIR)"
  BACKUP_KEEP_DAYS="$(env_value "${ENV_FILE}" BACKUP_KEEP_DAYS)"

  : "${NEXTCLOUD_VERSION:?NEXTCLOUD_VERSION is missing in .env}"
  : "${INSTANCE_NAME:?INSTANCE_NAME is missing in .env}"
  : "${NEXTCLOUD_DATA:?NEXTCLOUD_DATA is missing in .env}"
  : "${NEXTCLOUD_CONFIG:?NEXTCLOUD_CONFIG is missing in .env}"
  : "${POSTGRES_USER:=nextcloud}"
  : "${POSTGRES_DB:=nextcloud}"
  : "${BACKUP_ROOT:=./backups}"
  : "${BACKUP_KEEP_DAYS:=7}"
  : "${KEEP_DAYS:=${BACKUP_KEEP_DAYS}}"
  INSTANCE="${INSTANCE_NAME}"
}

prepare_backup_set() {
  local app_data_line

  BACKUP_DIR="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "${BACKUP_DIR}"
  log "backup set: ${BACKUP_DIR}"

  if [[ "${SKIP_APP_DATA}" == "true" ]]; then
    app_data_line="excluded on request (--skip-app-data)"
  else
    app_data_line="${NEXTCLOUD_APP_DATA}"
  fi

  compose config 2>/dev/null | grep -E '^[[:space:]]+image:' > "${BACKUP_DIR}/images.txt" || true
  cp "${ENV_FILE}" "${BACKUP_DIR}/env.backup"
  chmod 600 "${BACKUP_DIR}/env.backup"

  cat > "${BACKUP_DIR}/MANIFEST.txt" <<MANIFEST
Nextcloud backup
created:            $(date -Is)
instance:           ${INSTANCE}
pinned version:     ${NEXTCLOUD_VERSION}
database:           ${POSTGRES_DB} (service db)
data directory:     ${NEXTCLOUD_DATA}
config directory:   ${NEXTCLOUD_CONFIG}
app directory:      ${app_data_line}
procedure:          Nextcloud admin manual – maintenance mode + pg_dump + files
restore:            see the RESTORE section of scripts/backup.sh output,
                    or apps/nextcloud-postgres-redis-apache/README.md
MANIFEST
}

enable_maintenance_mode() {
  # Files and database have to describe the same moment; without the
  # maintenance mode a user upload during the dump ends up in neither.
  log "enabling the maintenance mode"
  occ maintenance:mode --on
  MAINTENANCE_MODE_ON="true"
}

create_database_dump() {
  local dump_file="${BACKUP_DIR}/db.sql.gz"
  local size marker

  log "creating the database dump"
  compose exec -T db pg_dump -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" | gzip > "${dump_file}" \
    || die "pg_dump failed" "${EXIT_BACKUP_FAILED}"

  gzip -t "${dump_file}" || die "dump archive is corrupted" "${EXIT_VERIFY_FAILED}"

  # Check the DECOMPRESSED size: a small database packs into a few hundred
  # bytes, so the packed size would reject valid backups.
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

  for path in "${NEXTCLOUD_CONFIG}" "${NEXTCLOUD_DATA}"; do
    if [[ -e "${path}" ]]; then
      existing+=("${path}")
    else
      warn "path is missing, skipped: ${path}"
    fi
  done
  if [[ "${SKIP_APP_DATA}" != "true" ]]; then
    if [[ -e "${NEXTCLOUD_APP_DATA}" ]]; then
      existing+=("${NEXTCLOUD_APP_DATA}")
    else
      warn "path is missing, skipped: ${NEXTCLOUD_APP_DATA}"
    fi
  else
    log "NEXTCLOUD_APP_DATA excluded on request (--skip-app-data)"
  fi

  (( ${#existing[@]} > 0 )) || die "no data paths exist – check the paths in .env" "${EXIT_BACKUP_FAILED}"

  log "archiving ${#existing[@]} path(s) – this can take a while for large data directories"
  tar -czf "${archive}" -C "${APP_DIR}" "${existing[@]}" \
    || die "archiving the data directories failed" "${EXIT_BACKUP_FAILED}"
  gzip -t "${archive}" || die "data archive is corrupted" "${EXIT_VERIFY_FAILED}"

  local entries
  entries="$(tar -tzf "${archive}" | wc -l)"
  (( entries > 0 )) || die "data archive contains no entries" "${EXIT_VERIFY_FAILED}"
  log "data archive verified (${entries} entries, $(stat -c %s "${archive}") bytes)"
}

disable_maintenance_mode() {
  log "disabling the maintenance mode"
  occ maintenance:mode --off
  MAINTENANCE_MODE_ON="false"
}

verify_backup() {
  local status

  log "asking Nextcloud for its state"
  status="$(occ status 2>/dev/null || true)"
  if grep -qE 'installed:[[:space:]]*true' <<< "${status}"; then
    log "'occ status' reports the instance as installed"
  else
    warn "'occ status' does not report an installed instance – check the instance"
  fi

  if grep -qiE 'maintenance:[[:space:]]*false' <<< "${status}"; then
    log "maintenance mode is off again"
  else
    warn "maintenance mode still reports as on"
  fi

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
keep:  ${KEEP_DAYS} days (BACKUP_KEEP_DAYS in .env, override with --keep-days)

Restore into a fresh stack (same or newer NEXTCLOUD_VERSION):
  1) cd ${APP_DIR} && docker compose down
  2) untar the files:  tar -xzf ${BACKUP_DIR}/data.tar.gz -C ${APP_DIR}
     (this restores ${NEXTCLOUD_CONFIG} and ${NEXTCLOUD_DATA})
  3) docker compose up -d db redis
  4) gunzip -c ${BACKUP_DIR}/db.sql.gz | \\
       docker compose exec -T db psql -U ${POSTGRES_USER} -d ${POSTGRES_DB}
  5) docker compose up -d
  6) docker compose exec -u www-data app php occ maintenance:mode --off
  7) docker compose exec -u www-data app php occ files:scan --all

A backup on the same disk is not a backup: copy ${BACKUP_ROOT} to another
machine or storage (rsync, Borg, restic). And test a restore before you need one.
RESTORE
}

main() {
  parse_arguments "$@"
  trap on_error ERR

  cd "${APP_DIR}"
  check_prerequisites
  load_env
  log "instance ${INSTANCE}, pinned Nextcloud ${NEXTCLOUD_VERSION}"

  prepare_backup_set
  enable_maintenance_mode
  create_database_dump
  create_file_archive
  disable_maintenance_mode
  verify_backup
  prune_old_backups
  show_restore_instructions
}

main "$@"
