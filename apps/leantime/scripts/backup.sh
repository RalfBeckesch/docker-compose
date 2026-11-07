#!/usr/bin/env bash
# =============================================================================
# backup.sh – Leantime backup
# =============================================================================
# Leantime keeps its state in two places: the MariaDB database (projects, tasks,
# users, settings) and four writable directories inside the app container
# (uploads, public files, plugins, logs). The vendor documents exactly that
# split, and the dump runs online – `--single-transaction` gives a consistent
# snapshot without stopping the app.
#
#   1. mariadb-dump inside the running db container -> db.sql.gz
#   2. tar of userfiles/, public/userfiles/, app/Plugins/ and storage/logs/
#                                                  -> data.tar.gz
#   3. .env, MANIFEST.txt and the resolved image tags
#
# What is NOT in the set: TLS certificates of a reverse proxy and anything the
# app stores in S3 when LEAN_USE_S3 is enabled.
#
# https://docs.leantime.io/installation/backup-restore
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
readonly DATA_ARCHIVE="data.tar.gz"
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
backup.sh – Leantime backup (database dump + application directories)

  ./scripts/backup.sh [--keep-days N]

  --keep-days N   delete backup sets older than N days (default: BACKUP_KEEP_DAYS)

The stack has to be running: the database is dumped through the running MariaDB
container with --single-transaction, which keeps the dump consistent without
stopping Leantime. The four writable directories are archived from the host
bind mounts.

Restore: unpack the archive into the app directory, import db.sql.gz and run
`php bin/leantime db:migrate` – the exact steps are printed at the end.
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

# Read one value from the env file. Sourcing it would break on names that are
# readonly in bash (UID, BACKUP_DIR as used elsewhere) – so read, never source.
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
  [[ -n "$(compose ps -q db 2>/dev/null)" ]] \
    || die "the db container is not running – start the stack first" "${EXIT_PREREQUISITE}"
  [[ -n "$(compose ps -q leantime 2>/dev/null)" ]] \
    || die "the leantime container is not running – start the stack first" "${EXIT_PREREQUISITE}"
}

load_env() {
  LEANTIME_VERSION="$(env_value "${ENV_FILE}" LEANTIME_VERSION)"
  COMPOSE_PROJECT_NAME="$(env_value "${ENV_FILE}" COMPOSE_PROJECT_NAME)"
  LEAN_APP_URL="$(env_value "${ENV_FILE}" LEAN_APP_URL)"
  LEAN_UID="$(env_value "${ENV_FILE}" LEAN_UID)"
  LEAN_GID="$(env_value "${ENV_FILE}" LEAN_GID)"
  MYSQL_DATABASE="$(env_value "${ENV_FILE}" MYSQL_DATABASE)"
  MYSQL_ROOT_PASSWORD="$(env_value "${ENV_FILE}" MYSQL_ROOT_PASSWORD)"
  LEAN_USERFILES="$(env_value "${ENV_FILE}" LEAN_USERFILES)"
  LEAN_PUBLIC_USERFILES="$(env_value "${ENV_FILE}" LEAN_PUBLIC_USERFILES)"
  LEAN_PLUGINS="$(env_value "${ENV_FILE}" LEAN_PLUGINS)"
  LEAN_LOGS="$(env_value "${ENV_FILE}" LEAN_LOGS)"
  BACKUP_ROOT="$(env_value "${ENV_FILE}" BACKUP_DIR)"
  BACKUP_KEEP_DAYS="$(env_value "${ENV_FILE}" BACKUP_KEEP_DAYS)"

  : "${LEANTIME_VERSION:?LEANTIME_VERSION is missing in .env}"
  : "${MYSQL_DATABASE:=leantime}"
  : "${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD is missing in .env}"
  : "${LEAN_UID:=1000}"
  : "${LEAN_GID:=0}"
  : "${LEAN_USERFILES:?LEAN_USERFILES is missing in .env}"
  : "${LEAN_PUBLIC_USERFILES:?LEAN_PUBLIC_USERFILES is missing in .env}"
  : "${LEAN_PLUGINS:?LEAN_PLUGINS is missing in .env}"
  : "${LEAN_LOGS:?LEAN_LOGS is missing in .env}"
  : "${COMPOSE_PROJECT_NAME:=leantime}"
  : "${BACKUP_ROOT:=./backups}"
  : "${BACKUP_KEEP_DAYS:=7}"
  : "${KEEP_DAYS:=${BACKUP_KEEP_DAYS}}"

  [[ "${MYSQL_ROOT_PASSWORD}" != "CHANGEME" ]] \
    || die "MYSQL_ROOT_PASSWORD is still the placeholder – run ./scripts/bootstrap.sh first" \
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
Leantime backup
created:            $(date -Is)
pinned version:     ${LEANTIME_VERSION}
public URL:         ${LEAN_APP_URL:-unknown}
database:           ${MYSQL_DATABASE} (service db)
data directories:   userfiles, public/userfiles, app/Plugins, storage/logs
procedure:          mariadb-dump --single-transaction + directory archive
not included:       reverse-proxy TLS certificates and S3-stored files
                    (only relevant when LEAN_USE_S3 is enabled)
restore:            see the RESTORE section of scripts/backup.sh output
MANIFEST
}

create_database_dump() {
  local dump_file="${BACKUP_DIR}/db.sql.gz"
  local size marker

  log "dumping the database"
  # The password stays inside the container's environment: it is expanded by
  # the container's shell, never by the host's, so it does not show up in the
  # host's process list.
  # shellcheck disable=SC2016  # the variables must expand in the container's shell
  compose exec -T db sh -c \
    'exec mariadb-dump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --quick --triggers --default-character-set=utf8mb4 "$MYSQL_DATABASE"' \
    | gzip > "${dump_file}" \
    || die "mariadb-dump failed" "${EXIT_BACKUP_FAILED}"

  gzip -t "${dump_file}" || die "database dump is not a valid gzip file" "${EXIT_VERIFY_FAILED}"
  size="$(zcat "${dump_file}" | wc -c)"
  (( size > MINIMUM_DUMP_BYTES )) \
    || die "database dump is implausibly small at ${size} bytes uncompressed" "${EXIT_VERIFY_FAILED}"
  # mariadb-dump writes "MariaDB dump" in newer releases and "MySQL dump" in the
  # classic client – accept either header.
  marker="$(zcat "${dump_file}" | head -20 | grep -cE 'MariaDB dump|MySQL dump' || true)"
  (( marker > 0 )) || die "database dump has no dump header" "${EXIT_VERIFY_FAILED}"
  log "database dump verified (${size} bytes uncompressed)"
}

create_file_archive() {
  local archive="${BACKUP_DIR}/${DATA_ARCHIVE}"
  local -a members=()
  local directory entries

  for directory in "${LEAN_USERFILES}" "${LEAN_PUBLIC_USERFILES}" \
                   "${LEAN_PLUGINS}" "${LEAN_LOGS}"; do
    [[ -d "${directory}" ]] || { warn "directory missing: ${directory}"; continue; }
    members+=("${directory#./}")
  done
  (( ${#members[@]} > 0 )) || die "no application directory to archive" "${EXIT_BACKUP_FAILED}"

  log "archiving ${#members[@]} application directories"
  tar -czf "${archive}" -C "${APP_DIR}" "${members[@]}" \
    || die "archiving the application directories failed" "${EXIT_BACKUP_FAILED}"
  gzip -t "${archive}" || die "data archive is corrupted" "${EXIT_VERIFY_FAILED}"

  entries="$(tar -tzf "${archive}" | wc -l)"
  (( entries > 0 )) || die "data archive contains no entries" "${EXIT_VERIFY_FAILED}"
  log "data archive verified (${entries} entries, $(stat -c %s "${archive}") bytes)"
}

verify_backup() {
  local missing=0 file

  gzip -t "${BACKUP_DIR}/db.sql.gz" || die "database dump is corrupted" "${EXIT_VERIFY_FAILED}"
  tar -tzf "${BACKUP_DIR}/${DATA_ARCHIVE}" | grep -q 'userfiles' \
    || die "data archive has no userfiles" "${EXIT_VERIFY_FAILED}"
  log "userfiles is part of the archive"

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

Restore (same Leantime version):
  1) cd ${APP_DIR} && docker compose down
  2) unpack the application directories into the app directory:
       tar -xzf ${BACKUP_DIR}/${DATA_ARCHIVE} -C ${APP_DIR}
       chown -R ${LEAN_UID}:${LEAN_GID} ${LEAN_USERFILES} ${LEAN_PUBLIC_USERFILES} \\
         ${LEAN_PLUGINS} ${LEAN_LOGS}
  3) start only the database, then import the dump:
       docker compose up -d db
       gunzip -c ${BACKUP_DIR}/db.sql.gz | \\
         docker compose exec -T db mariadb -uroot -p"\$MYSQL_ROOT_PASSWORD" ${MYSQL_DATABASE}
  4) docker compose up -d
  5) run the migrations and clear the cache:
       docker compose exec leantime php bin/leantime db:migrate
       docker compose exec leantime php bin/leantime cache:clear

The dump contains CREATE TABLE statements for the current schema. Restoring it
into a database that already holds data fails on duplicate tables – drop and
recreate ${MYSQL_DATABASE} first, or restore into an empty volume.

A backup on the same disk is not a backup – copy ${BACKUP_ROOT} to other storage.
RESTORE
}

main() {
  parse_arguments "$@"
  trap on_error ERR

  cd "${APP_DIR}"
  check_prerequisites
  load_env
  log "backing up Leantime ${LEANTIME_VERSION}"

  prepare_backup_set
  create_database_dump
  create_file_archive
  verify_backup
  prune_old_backups
  show_restore_instructions
}

main "$@"
