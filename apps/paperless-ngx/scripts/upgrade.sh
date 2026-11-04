#!/usr/bin/env bash
# =============================================================================
# upgrade.sh – Move the Paperless-ngx stack to another version
# =============================================================================
# NOTE: this stack keeps its configuration in docker-compose.env (not .env),
# which is why every compose call here passes --env-file explicitly.
#
# Order of operations: verify the target tag → classify the jump → dump the
# database → stop → archive the env file and the application directories →
# bump PAPERLESS_VERSION → check the resolved configuration → start → verify →
# print rollback instructions.
#
# Usage:   ./scripts/upgrade.sh <target-version> [--yes]
#            <target-version>  e.g. 2.21 – the value of PAPERLESS_VERSION
#            --yes             skip the confirmation prompt on a minor/major jump
# Needs:   docker with the compose plugin (v2), curl, gzip, tar, GNU sed/stat
# Writes:  backup/<timestamp>/{db.sql.gz,data.tar.gz,env.backup,images*.txt}
#
# Exit codes:
#   0  upgrade done (or aborted by the user without changes)
#   2  usage error
#   3  prerequisite missing (env file, docker, daemon)
#   4  target version rejected (unknown tag, config resolves to something else)
#   5  backup incomplete
#   6  stack did not become ready after the upgrade
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
APP_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly APP_DIR

readonly ENV_FILE="${APP_DIR}/docker-compose.env"
readonly COMPOSE_FILE="${APP_DIR}/docker-compose.yaml"
readonly DOCKERHUB_TAGS_API="https://hub.docker.com/v2/repositories/paperlessngx/paperless-ngx/tags"
readonly HTTP_TIMEOUT_S="300"
readonly MINIMUM_DUMP_BYTES=1024
readonly VERSION_PATTERN='^[0-9]+\.[0-9]+(\.[0-9]+)?$'

readonly EXIT_USAGE=2
readonly EXIT_PREREQUISITE=3
readonly EXIT_TARGET_REJECTED=4
readonly EXIT_BACKUP_FAILED=5
readonly EXIT_NOT_READY=6

TARGET_VERSION=""
PREVIOUS_VERSION=""
ASSUME_YES="false"
BACKUP_DIR=""

usage() {
  cat <<'USAGE'
upgrade.sh – update the Paperless-ngx stack

  ./scripts/upgrade.sh <target-version> [--yes]

  <target-version>  a published tag of the paperless-ngx image, e.g. 2.21
  --yes             skip the confirmation prompt on a minor/major jump

Note: the Redis data directory is deliberately NOT backed up – it only holds the
task queue, which is rebuilt on start. The database is captured with pg_dump.
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
    printf 'backup of this run: %s\n' "${BACKUP_DIR}" >&2
  fi
  printf 'stack state: docker compose --env-file docker-compose.env -f %s ps\n' "${COMPOSE_FILE}" >&2
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
  [[ "${TARGET_VERSION}" =~ ${VERSION_PATTERN} ]] \
    || die "target version '${TARGET_VERSION}' is not of the form X.Y or X.Y.Z" "${EXIT_USAGE}"
}

check_prerequisites() {
  command -v docker >/dev/null 2>&1 || die "command 'docker' not found" "${EXIT_PREREQUISITE}"
  command -v curl   >/dev/null 2>&1 || die "command 'curl' not found" "${EXIT_PREREQUISITE}"
  docker compose version >/dev/null 2>&1 \
    || die "docker compose (plugin v2) is not available" "${EXIT_PREREQUISITE}"
  docker info >/dev/null 2>&1 || die "docker daemon is not reachable" "${EXIT_PREREQUISITE}"
  [[ -f "${ENV_FILE}" ]] \
    || die "docker-compose.env is missing – run ./scripts/bootstrap.sh first" "${EXIT_PREREQUISITE}"
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

load_env() {
  PAPERLESS_VERSION="$(env_value "${ENV_FILE}" PAPERLESS_VERSION)"
  PAPERLESS_DATA_DIR="$(env_value "${ENV_FILE}" PAPERLESS_DATA_DIR)"
  PAPERLESS_MEDIA_DIR="$(env_value "${ENV_FILE}" PAPERLESS_MEDIA_DIR)"
  PAPERLESS_CONSUMPTION_DIR="$(env_value "${ENV_FILE}" PAPERLESS_CONSUMPTION_DIR)"
  PAPERLESS_EXPORT_DIR="$(env_value "${ENV_FILE}" PAPERLESS_EXPORT_DIR)"
  POSTGRES_DATA_DIR="$(env_value "${ENV_FILE}" POSTGRES_DATA_DIR)"
  PAPERLESS_EXPORT_PORT="$(env_value "${ENV_FILE}" PAPERLESS_EXPORT_PORT)"
  POSTGRES_USER="$(env_value "${ENV_FILE}" POSTGRES_USER)"
  POSTGRES_DB="$(env_value "${ENV_FILE}" POSTGRES_DB)"
  BACKUP_ROOT="$(env_value "${ENV_FILE}" BACKUP_DIR)"
  : "${BACKUP_ROOT:=./backups}"

  : "${PAPERLESS_VERSION:?PAPERLESS_VERSION is missing in the env file}"
  : "${PAPERLESS_DATA_DIR:?PAPERLESS_DATA_DIR is missing in the env file}"
  : "${PAPERLESS_MEDIA_DIR:?PAPERLESS_MEDIA_DIR is missing in the env file}"
  : "${PAPERLESS_CONSUMPTION_DIR:?PAPERLESS_CONSUMPTION_DIR is missing in the env file}"
  : "${PAPERLESS_EXPORT_DIR:?PAPERLESS_EXPORT_DIR is missing in the env file}"
  : "${POSTGRES_DATA_DIR:?POSTGRES_DATA_DIR is missing in the env file}"
  : "${PAPERLESS_EXPORT_PORT:=8080}"
}

host_port() {
  printf '%s\n' "${1##*:}"
}

verify_target_version_exists() {
  local status

  status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 \
    "${DOCKERHUB_TAGS_API}/${TARGET_VERSION}")"
  [[ "${status}" == "200" ]] \
    || die "image tag paperless-ngx:${TARGET_VERSION} does not exist (HTTP ${status})" "${EXIT_TARGET_REJECTED}"
  log "target version confirmed in the registry: paperless-ngx:${TARGET_VERSION}"
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
      warn "release notes: https://github.com/paperless-ngx/paperless-ngx/releases"
      return 0
    fi
    log "patch jump ${PREVIOUS_VERSION} -> ${TARGET_VERSION} (low risk)"
    return 0
  fi

  warn "major jump ${PREVIOUS_VERSION} -> ${TARGET_VERSION}"
  warn "check the release notes for migration steps and required intermediate"
  warn "versions: https://docs.paperless-ngx.com/setup/#migrating-to-paperless-ngx"
  warn "the database is migrated on start and cannot be rolled back except from backup"
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
    paperless-webserver paperless-db paperless-broker \
    > "${BACKUP_DIR}/images.txt" 2>/dev/null \
    || docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" ps \
         > "${BACKUP_DIR}/images.txt" 2>/dev/null \
    || warn "could not record the running image tags"
  cp "${ENV_FILE}" "${BACKUP_DIR}/env.backup"
  log "backup directory: ${BACKUP_DIR}"
}

create_database_dump() {
  local dump_file="${BACKUP_DIR}/db.sql.gz"
  local size marker

  log "creating the database dump (the stack is still running)"
  compose exec -T db pg_dump -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" | gzip > "${dump_file}" \
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

  for path in "${ENV_FILE}" "${PAPERLESS_DATA_DIR}" "${PAPERLESS_MEDIA_DIR}" \
              "${PAPERLESS_CONSUMPTION_DIR}" "${PAPERLESS_EXPORT_DIR}"; do
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
      || die "could not set ${key} in the env file" "${EXIT_TARGET_REJECTED}"
  else
    printf '%s=%s\n' "${key}" "${value}" >> "${ENV_FILE}"
  fi
  log "${key}=${value} written to the env file"
}

validate_compose() {
  compose config >/dev/null \
    || die "docker compose config failed after the version bump" "${EXIT_TARGET_REJECTED}"
}

assert_resolved_image() {
  local resolved

  compose config 2>/dev/null | grep -E '^[[:space:]]+image:' > "${BACKUP_DIR}/images-resolved.txt" || true
  resolved="$(grep -oE 'paperless-ngx:[^[:space:]]+' "${BACKUP_DIR}/images-resolved.txt" | head -1)"

  [[ "${resolved}" == "paperless-ngx:${TARGET_VERSION}" ]] \
    || die "the active Compose file would start '${resolved}' instead of 'paperless-ngx:${TARGET_VERSION}'" \
           "${EXIT_TARGET_REJECTED}"
  log "resolved configuration confirmed: ${resolved}"
}

start_stack() {
  log "pulling images"
  compose pull
  log "starting the stack"
  compose up -d
}

wait_for_service() {
  local port url waited=0

  port="$(host_port "${PAPERLESS_EXPORT_PORT}")"
  url="http://127.0.0.1:${port}/"
  log "waiting for Paperless at ${url} (max ${HTTP_TIMEOUT_S}s)"

  while (( waited < HTTP_TIMEOUT_S )); do
    if curl -fsS -m 5 -o /dev/null "${url}"; then
      return 0
    fi
    sleep 5
    waited=$(( waited + 5 ))
  done

  compose logs --tail 60 webserver >&2 || true
  die "Paperless did not answer within ${HTTP_TIMEOUT_S}s – consider the rollback below" "${EXIT_NOT_READY}"
}

verify_upgrade() {
  local resolved

  compose ps
  resolved="$(grep -oE 'paperless-ngx:[^[:space:]]+' "${BACKUP_DIR}/images-resolved.txt" | head -1)"
  log "verified: running image ${resolved}"

  # The webserver reports its own version at this endpoint.
  log "version reported by the API:"
  curl -fsS -m 10 "http://127.0.0.1:$(host_port "${PAPERLESS_EXPORT_PORT}")/api/remote_version" 2>/dev/null || \
    warn "could not read /api/remote_version (may be disabled) – check the web UI"
}

show_rollback_instructions() {
  cat <<ROLLBACK

=== Upgrade to ${TARGET_VERSION} finished ===
backup: ${BACKUP_DIR}

Way back (only if the new version misbehaves):
  1) cd ${APP_DIR} && docker compose --env-file docker-compose.env down
  2) sed -i 's/^PAPERLESS_VERSION=.*/PAPERLESS_VERSION=${PREVIOUS_VERSION}/' docker-compose.env
  3) rm -rf ${POSTGRES_DATA_DIR:?}/*   # discard the migrated schema
  4) docker compose --env-file docker-compose.env up -d db broker
  5) gunzip -c ${BACKUP_DIR}/db.sql.gz | \\
       docker compose --env-file docker-compose.env exec -T db psql -U ${POSTGRES_USER} -d ${POSTGRES_DB}
  6) docker compose --env-file docker-compose.env up -d

Alternative without a database restore: ${BACKUP_DIR}/data.tar.gz holds the env file and the
application directories. The Redis data is not backed up on purpose (task queue only).

Paperless-ngx also has a built-in exporter for a portable snapshot:
  docker compose --env-file docker-compose.env exec webserver document_exporter ../export
which writes into ${PAPERLESS_EXPORT_DIR}.
ROLLBACK
}

main() {
  parse_arguments "$@"
  trap on_error ERR

  cd "${APP_DIR}"
  check_prerequisites
  load_env
  PREVIOUS_VERSION="${PAPERLESS_VERSION}"
  log "pinned version: ${PREVIOUS_VERSION} -> target version: ${TARGET_VERSION}"

  verify_target_version_exists
  check_version_jump
  prepare_backup_directory
  create_database_dump
  stop_stack
  backup_data_directories
  set_env_value "PAPERLESS_VERSION" "${TARGET_VERSION}"
  validate_compose
  assert_resolved_image
  start_stack
  wait_for_service
  verify_upgrade
  show_rollback_instructions
}

main "$@"
