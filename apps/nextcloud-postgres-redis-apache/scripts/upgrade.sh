#!/usr/bin/env bash
# =============================================================================
# upgrade.sh – Move the Nextcloud stack to another version
# =============================================================================
# Nextcloud is not a simple "pull and restart" upgrade: the code has to be
# swapped, the maintenance mode enabled, the database migrated with `occ
# upgrade`, and the mode disabled again. This script does that in the right
# order, with a verified backup first.
#
# Order of operations: verify the target tag → classify the jump → dump the
# database → archive .env and the data directories → stop → bump
# NEXTCLOUD_VERSION → check the resolved configuration → start infrastructure
# and app → occ upgrade → verify → print rollback instructions.
#
# Usage:   ./scripts/upgrade.sh <target-version> [--yes]
#            <target-version>  e.g. 32-apache – the value of NEXTCLOUD_VERSION
#            --yes             skip the confirmation prompt on a minor/major jump
# Needs:   docker with the compose plugin (v2), curl, gzip, tar, GNU sed/stat
# Writes:  backup/<timestamp>/{db.sql.gz,data.tar.gz,env.backup,images*.txt}
#
# Exit codes:
#   0  upgrade done (or aborted by the user without changes)
#   2  usage error
#   3  prerequisite missing (.env, docker, daemon)
#   4  target version rejected (unknown tag, config resolves to something else)
#   5  backup incomplete
#   6  stack or `occ upgrade` did not succeed
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
APP_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly APP_DIR

readonly ENV_FILE="${APP_DIR}/.env"
readonly COMPOSE_FILE="${APP_DIR}/docker-compose.yaml"
readonly APP_CONTAINER_SUFFIX="-app"
readonly HTTP_TIMEOUT_S="300"
readonly MINIMUM_DUMP_BYTES=1024

readonly EXIT_USAGE=2
readonly EXIT_PREREQUISITE=3
readonly EXIT_TARGET_REJECTED=4
readonly EXIT_BACKUP_FAILED=5
readonly EXIT_UPGRADE_FAILED=6

TARGET_VERSION=""
PREVIOUS_VERSION=""
ASSUME_YES="false"
INSTANCE=""
BACKUP_DIR=""

usage() {
  cat <<'USAGE'
upgrade.sh – update the Nextcloud stack

  ./scripts/upgrade.sh <target-version> [--yes]

  <target-version>  a published tag of the nextcloud image, e.g. 32-apache
  --yes             skip the confirmation prompt on a minor/major jump

The script runs `occ upgrade` for you – that step is what turns a pulled image
into an actually upgraded instance.
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

# HTTP_PORT may be a bare port ("8080") or a full binding ("127.0.0.1:8080").
host_port() {
  printf '%s\n' "${1##*:}"
}

on_error() {
  local exit_code=$?
  printf '\n=== ABORTED (exit %s) ===\n' "${exit_code}" >&2
  if [[ -n "${BACKUP_DIR}" && -d "${BACKUP_DIR}" ]]; then
    printf 'backup of this run: %s\n' "${BACKUP_DIR}" >&2
  fi
  printf 'stack state: docker compose -f %s ps\n' "${COMPOSE_FILE}" >&2
  printf 'maintenance mode may still be on – disable it with:\n' >&2
  printf '  docker compose -f %s exec -u www-data app php occ maintenance:mode --off\n' "${COMPOSE_FILE}" >&2
  exit "${exit_code}"
}

parse_arguments() {
  local argument

  for argument in "$@"; do
    case "${argument}" in
      -h|--help) usage; exit 0 ;;
      --yes)     ASSUME_YES="true" ;;
      -*)        usage; die "unknown option: ${argument}" "${EXIT_USAGE}" ;;
      *)
        [[ -z "${TARGET_VERSION}" ]] || die "only one target version allowed" "${EXIT_USAGE}"
        TARGET_VERSION="${argument}"
        ;;
    esac
  done

  [[ -n "${TARGET_VERSION}" ]] || { usage; die "target version is missing" "${EXIT_USAGE}"; }
}

check_prerequisites() {
  command -v docker >/dev/null 2>&1 || die "command 'docker' not found" "${EXIT_PREREQUISITE}"
  command -v curl   >/dev/null 2>&1 || die "command 'curl' not found" "${EXIT_PREREQUISITE}"
  docker compose version >/dev/null 2>&1 \
    || die "docker compose (plugin v2) is not available" "${EXIT_PREREQUISITE}"
  docker info >/dev/null 2>&1 || die "docker daemon is not reachable" "${EXIT_PREREQUISITE}"
  [[ -f "${ENV_FILE}" ]] || die ".env is missing – copy env-dist and fill it in" "${EXIT_PREREQUISITE}"
}

# Read one variable from an env file the way Docker Compose does, WITHOUT
# sourcing it: the file is data, not shell code. Sourcing would execute values
# like UID (readonly in bash) or an unquoted "a b" as commands.
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

load_env() {
  NEXTCLOUD_VERSION="$(env_value "${ENV_FILE}" NEXTCLOUD_VERSION)"
  INSTANCE_NAME="$(env_value "${ENV_FILE}" INSTANCE_NAME)"
  HTTP_PORT="$(env_value "${ENV_FILE}" HTTP_PORT)"
  POSTGRES_USER="$(env_value "${ENV_FILE}" POSTGRES_USER)"
  POSTGRES_DB="$(env_value "${ENV_FILE}" POSTGRES_DB)"
  NEXTCLOUD_DATA="$(env_value "${ENV_FILE}" NEXTCLOUD_DATA)"
  NEXTCLOUD_APP_DATA="$(env_value "${ENV_FILE}" NEXTCLOUD_APP_DATA)"
  NEXTCLOUD_CONFIG="$(env_value "${ENV_FILE}" NEXTCLOUD_CONFIG)"
  POSTGRES_DATA="$(env_value "${ENV_FILE}" POSTGRES_DATA)"
  BACKUP_ROOT="$(env_value "${ENV_FILE}" BACKUP_DIR)"
  : "${BACKUP_ROOT:=./backups}"

  : "${NEXTCLOUD_VERSION:?NEXTCLOUD_VERSION is missing in .env}"
  : "${INSTANCE_NAME:?INSTANCE_NAME is missing in .env}"
  : "${POSTGRES_DATA:?POSTGRES_DATA is missing in .env}"
  : "${NEXTCLOUD_DATA:?NEXTCLOUD_DATA is missing in .env}"
  : "${HTTP_PORT:=8080}"
  : "${POSTGRES_USER:=nextcloud}"
  : "${POSTGRES_DB:=nextcloud}"
  INSTANCE="${INSTANCE_NAME}"
}

verify_target_version_exists() {
  local status

  status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 \
    "https://hub.docker.com/v2/repositories/library/nextcloud/tags/${TARGET_VERSION}")"
  [[ "${status}" == "200" ]] \
    || die "image tag nextcloud:${TARGET_VERSION} does not exist (HTTP ${status})" "${EXIT_TARGET_REJECTED}"
  log "target version confirmed in the registry: nextcloud:${TARGET_VERSION}"
}

check_version_jump() {
  local -a previous_parts target_parts
  local previous_major target_major previous_minor target_minor

  if [[ "${TARGET_VERSION}" == "${PREVIOUS_VERSION}" ]]; then
    log "target equals the pinned version – no version change, only config re-apply"
    return 0
  fi

  IFS='.' read -r -a previous_parts <<< "${PREVIOUS_VERSION#v}"
  IFS='.' read -r -a target_parts   <<< "${TARGET_VERSION#v}"
  previous_major="${previous_parts[0]:-}"; target_major="${target_parts[0]:-}"
  previous_minor="${previous_parts[1]:-}"; target_minor="${target_parts[1]:-}"

  if [[ "${previous_major}" == "${target_major}" ]]; then
    if [[ "${previous_minor}" != "${target_minor}" ]]; then
      warn "minor jump ${PREVIOUS_VERSION} -> ${TARGET_VERSION} within the ${previous_major} line"
      warn "read the release notes: https://docs.nextcloud.com/server/latest/admin_manual/release_notes.html"
      return 0
    fi
    log "patch or variant change (${previous_major}) – low risk"
    return 0
  fi

  warn "major jump ${PREVIOUS_VERSION} -> ${TARGET_VERSION}"
  warn "Nextcloud supports only ONE major step at a time, and it must be applied"
  warn "code-first: the containers are swapped, then 'occ upgrade' migrates the database."
  warn "Read https://docs.nextcloud.com/server/latest/admin_manual/maintenance/upgrade.html"
  warn "before confirming. Skipping a major version is not supported."
  if [[ "${ASSUME_YES}" != "true" ]]; then
    answer=""
    read -r -p "continue? [no/yes] " answer || answer=""
    if [[ "${answer}" != "yes" ]]; then
      log "aborted by the user – stack left untouched"
      exit 0
    fi
  fi
}

prepare_backup_directory() {
  BACKUP_DIR="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "${BACKUP_DIR}"

  docker inspect -f '{{.Name}} -> {{.Config.Image}}' \
    "${INSTANCE}${APP_CONTAINER_SUFFIX}" "${INSTANCE}-db" "${INSTANCE}-redis" \
    > "${BACKUP_DIR}/images.txt" 2>/dev/null \
    || warn "could not record every running image tag"
  cp "${ENV_FILE}" "${BACKUP_DIR}/env.backup"
  log "backup directory: ${BACKUP_DIR}"
}

create_database_dump() {
  local dump_file="${BACKUP_DIR}/db.sql.gz"
  local size marker

  log "creating the database dump (the stack is still running)"
  compose exec -T db pg_dump -U "${POSTGRES_USER:-nextcloud}" -d "${POSTGRES_DB:-nextcloud}" \
    | gzip > "${dump_file}" \
    || die "pg_dump failed – nothing was changed" "${EXIT_BACKUP_FAILED}"

  gzip -t "${dump_file}" || die "dump archive is corrupted" "${EXIT_BACKUP_FAILED}"

  # The size is checked on the DECOMPRESSED data: even a real dump of a small
  # database packs into a few hundred bytes, so the packed size proves nothing.
  size="$(zcat "${dump_file}" | wc -c)"
  (( size > MINIMUM_DUMP_BYTES )) \
    || die "dump is implausibly small at ${size} bytes uncompressed" "${EXIT_BACKUP_FAILED}"

  marker="$(zcat "${dump_file}" | head -20 | grep -c 'PostgreSQL database dump' || true)"
  (( marker > 0 )) || die "dump has no PostgreSQL header" "${EXIT_BACKUP_FAILED}"
  log "dump verified: ${dump_file} (${size} bytes uncompressed, $(stat -c %s "${dump_file}") packed)"
}

backup_data_directories() {
  local archive="${BACKUP_DIR}/data.tar.gz"
  local path
  local -a existing=()

  # NEXTCLOUD_DATA can be large; it is included on purpose – user files are the
  # part that cannot be reconstructed from anything else.
  for path in "${ENV_FILE}" "${NEXTCLOUD_DATA}" "${NEXTCLOUD_APP_DATA}" \
              "${NEXTCLOUD_CONFIG}" "${POSTGRES_DATA}"; do
    if [[ -e "${path}" ]]; then
      existing+=("${path}")
    else
      warn "path is missing and will be skipped: ${path}"
    fi
  done

  (( ${#existing[@]} > 0 )) || die "no backup paths exist" "${EXIT_BACKUP_FAILED}"
  tar -czf "${archive}" -C "${APP_DIR}" "${existing[@]}" \
    || die "archiving the data directories failed" "${EXIT_BACKUP_FAILED}"
  gzip -t "${archive}" || die "data archive is corrupted" "${EXIT_BACKUP_FAILED}"
  log "data archived: ${archive} ($(stat -c %s "${archive}") bytes)"
}

stop_stack() {
  log "stopping the stack (plain down – volumes and data stay in place)"
  compose down
}

set_env_value() {
  local key="$1" value="$2"

  if grep -qE "^${key}=" "${ENV_FILE}"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "${ENV_FILE}" \
      || die "could not set ${key} in .env" "${EXIT_UPGRADE_FAILED}"
  else
    printf '%s=%s\n' "${key}" "${value}" >> "${ENV_FILE}"
  fi
  log "${key}=${value} written to .env"
}

bump_version_in_env() {
  set_env_value "NEXTCLOUD_VERSION" "${TARGET_VERSION}"
}

validate_compose() {
  compose config >/dev/null \
    || die "docker compose config failed after the version bump" "${EXIT_TARGET_REJECTED}"
}

assert_resolved_image() {
  local resolved

  compose config 2>/dev/null | grep -E '^[[:space:]]+image:' > "${BACKUP_DIR}/images-resolved.txt" || true
  resolved="$(grep -oE 'nextcloud:[^[:space:]]+' "${BACKUP_DIR}/images-resolved.txt" | head -1)"

  [[ "${resolved}" == "nextcloud:${TARGET_VERSION}" ]] \
    || die "the active Compose file would start '${resolved}' instead of 'nextcloud:${TARGET_VERSION}'" \
           "${EXIT_TARGET_REJECTED}"
  log "resolved configuration confirmed: ${resolved}"
}

start_infrastructure() {
  log "pulling images"
  compose pull
  log "starting database and cache first"
  compose up -d db redis
}

start_application() {
  log "starting the application containers (this triggers the code upgrade)"
  compose up -d app cron imaginary
}

wait_for_http() {
  local url
  local waited=0
  url="http://127.0.0.1:$(host_port "${HTTP_PORT}")/status.php"

  log "waiting for Nextcloud at ${url} (max ${HTTP_TIMEOUT_S}s)"
  while (( waited < HTTP_TIMEOUT_S )); do
    if curl -fsS -m 5 -o /dev/null "${url}"; then
      log "Nextcloud is answering"
      return 0
    fi
    sleep 5
    waited=$(( waited + 5 ))
  done

  compose logs --tail 60 app >&2 || true
  die "Nextcloud did not answer within ${HTTP_TIMEOUT_S}s" "${EXIT_UPGRADE_FAILED}"
}

run_occ_upgrade() {
  log "running 'occ upgrade' – this migrates the database and can take a while"
  occ maintenance:mode --on || true

  if ! occ upgrade; then
    occ maintenance:mode --off || true
    die "'occ upgrade' failed – restore the backup or fix the reported problem, the maintenance mode is off again" \
        "${EXIT_UPGRADE_FAILED}"
  fi
  log "'occ upgrade' finished"
}

disable_maintenance_mode() {
  log "disabling the maintenance mode"
  occ maintenance:mode --off
}

verify_upgrade() {
  local status

  status="$(occ status 2>/dev/null || true)"
  printf '%s\n' "${status}"

  if grep -qE 'installed:[[:space:]]*true' <<< "${status}"; then
    log "'occ status' reports the instance as installed"
  else
    die "'occ status' does not report an installed instance" "${EXIT_UPGRADE_FAILED}"
  fi

  if grep -qiE 'maintenance:[[:space:]]*false' <<< "${status}"; then
    log "maintenance mode is off"
  else
    warn "maintenance mode still reports as on – check 'occ maintenance:mode --off'"
  fi
}

show_rollback_instructions() {
  cat <<ROLLBACK

=== Upgrade to ${TARGET_VERSION} finished ===
backup: ${BACKUP_DIR}

Way back (only if the new version misbehaves):
  1) cd ${APP_DIR} && docker compose down
  2) sed -i 's/^NEXTCLOUD_VERSION=.*/NEXTCLOUD_VERSION=${PREVIOUS_VERSION}/' .env
  3) rm -rf ${POSTGRES_DATA:?}/*      # discard the migrated schema
  4) docker compose up -d db redis
  5) gunzip -c ${BACKUP_DIR}/db.sql.gz | \\
       docker compose exec -T db psql -U ${POSTGRES_USER:-nextcloud} -d ${POSTGRES_DB:-nextcloud}
  6) docker compose up -d
  7) If Nextcloud still reports a pending upgrade, undo it in the database:
       docker compose exec -u www-data app php occ maintenance:repair

Alternative without a database restore: ${BACKUP_DIR}/data.tar.gz holds .env and all
four data directories as they were before the upgrade.

Note: 'occ upgrade' downgrades nothing. A database migrated to the newer version
is unreadable for the older code – step 3 is what makes the older version usable again.
ROLLBACK
}

main() {
  parse_arguments "$@"
  trap on_error ERR

  cd "${APP_DIR}"
  check_prerequisites
  load_env
  PREVIOUS_VERSION="${NEXTCLOUD_VERSION}"
  log "pinned version: ${PREVIOUS_VERSION} -> target version: ${TARGET_VERSION}"

  verify_target_version_exists
  check_version_jump
  prepare_backup_directory
  create_database_dump
  stop_stack
  backup_data_directories
  bump_version_in_env
  validate_compose
  assert_resolved_image
  start_infrastructure
  start_application
  wait_for_http
  run_occ_upgrade
  disable_maintenance_mode
  verify_upgrade
  show_rollback_instructions
}

main "$@"
