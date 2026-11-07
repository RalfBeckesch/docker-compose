#!/usr/bin/env bash
# =============================================================================
# upgrade.sh – Move the Open Notebook stack to another version
# =============================================================================
# Order of operations: verify the target tag → verified backup → bump
# OPEN_NOTEBOOK_VERSION → check the resolved configuration → pull → start →
# verify → print rollback steps.
#
# The vendor procedure is "back up first, then pull and up -d". The backup is
# not optional here: since v1.15.0 the stored API keys use a new encryption
# format that older images cannot read, so a rollback without a matching backup
# loses every provider credential.
#
# Usage:   ./scripts/upgrade.sh <target-version>
#            <target-version>  e.g. 1.15.1 – the value of OPEN_NOTEBOOK_VERSION
# Needs:   docker with the compose plugin (v2), curl, python3 or jq for the JSON
#          check (python3 is used when present), gzip, tar, GNU sed/stat
# Writes:  backups/<timestamp>/… (via scripts/backup.sh)
#
# Exit codes:
#   0  upgrade done
#   2  usage error
#   3  prerequisite missing (.env, docker, daemon)
#   4  target version rejected (unknown tag, configuration resolves elsewhere)
#   5  backup incomplete
#   6  stack did not become ready after the upgrade
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
APP_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly APP_DIR

readonly ENV_FILE="${APP_DIR}/.env"
readonly COMPOSE_FILE="${APP_DIR}/docker-compose.yaml"
readonly DOCKERHUB_TAGS_API="https://hub.docker.com/v2/repositories/lfnovo/open_notebook/tags"
readonly RELEASE_NOTES="https://github.com/lfnovo/open-notebook/releases"
readonly HEALTH_PATH="/health"
readonly HTTP_TIMEOUT_S="300"
readonly VERSION_PATTERN='^[0-9]+\.[0-9]+\.[0-9]+$'

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
upgrade.sh – update the Open Notebook stack

  ./scripts/upgrade.sh <target-version> [--yes]

  <target-version>  a published tag of the open_notebook image, e.g. 1.15.1
  --yes             skip the confirmation prompt on a major jump

Always takes a verified backup first. Rolling back to an older image requires
that backup: since v1.15.0 stored API keys use an encryption format older
versions cannot read.
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

host_port() { printf '%s\n' "${1##*:}"; }

on_error() {
  local exit_code=$?
  printf '\n=== ABORTED (exit %s) ===\n' "${exit_code}" >&2
  if [[ -n "${BACKUP_DIR}" && -d "${BACKUP_DIR}" ]]; then
    printf 'backup of this run: %s\n' "${BACKUP_DIR}" >&2
  fi
  printf 'stack state: docker compose -f %s ps\n' "${COMPOSE_FILE}" >&2
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
    || die "target version '${TARGET_VERSION}' does not look like a release tag (X.Y.Z)" \
           "${EXIT_USAGE}"
}

check_prerequisites() {
  command -v docker >/dev/null 2>&1 || die "command 'docker' not found" "${EXIT_PREREQUISITE}"
  command -v curl   >/dev/null 2>&1 || die "command 'curl' not found" "${EXIT_PREREQUISITE}"
  docker compose version >/dev/null 2>&1 \
    || die "docker compose (plugin v2) is not available" "${EXIT_PREREQUISITE}"
  docker info >/dev/null 2>&1 || die "docker daemon is not reachable" "${EXIT_PREREQUISITE}"
  [[ -f "${ENV_FILE}" ]] || die ".env is missing – run ./scripts/bootstrap.sh first" "${EXIT_PREREQUISITE}"
  [[ -x "${SCRIPT_DIR}/backup.sh" ]] || die "scripts/backup.sh is missing or not executable" "${EXIT_PREREQUISITE}"
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
  OPEN_NOTEBOOK_VERSION="$(env_value "${ENV_FILE}" OPEN_NOTEBOOK_VERSION)"
  OPEN_NOTEBOOK_API_PORT="$(env_value "${ENV_FILE}" OPEN_NOTEBOOK_API_PORT)"
  BACKUP_ROOT="$(env_value "${ENV_FILE}" BACKUP_DIR)"

  : "${OPEN_NOTEBOOK_VERSION:?OPEN_NOTEBOOK_VERSION is missing in .env}"
  : "${OPEN_NOTEBOOK_API_PORT:=5055}"
  : "${BACKUP_ROOT:=./backups}"
}

verify_target_version_exists() {
  local status

  # The tag endpoint answers 200 for an existing tag and 404 for a missing one.
  status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 \
    "${DOCKERHUB_TAGS_API}/${TARGET_VERSION}")"
  [[ "${status}" == "200" ]] \
    || die "image tag open_notebook:${TARGET_VERSION} does not exist (HTTP ${status})" "${EXIT_TARGET_REJECTED}"
  log "target version confirmed in the registry: open_notebook:${TARGET_VERSION}"
}

check_version_jump() {
  local previous_major target_major

  if [[ "${TARGET_VERSION}" == "${PREVIOUS_VERSION}" ]]; then
    log "target equals the pinned version – no version change, only config re-apply"
    return 0
  fi

  previous_major="${PREVIOUS_VERSION%%.*}"
  target_major="${TARGET_VERSION%%.*}"

  if [[ "${previous_major}" != "${target_major}" ]]; then
    warn "major jump ${PREVIOUS_VERSION} -> ${TARGET_VERSION}"
    warn "check the release notes for breaking changes: ${RELEASE_NOTES}"
    warn "the backup taken next is the only way back"
    if [[ "${ASSUME_YES}" != "true" ]]; then
      local answer=""
      read -r -p "continue? [no/yes] " answer || answer=""
      if [[ "${answer}" != "yes" ]]; then
        log "aborted by the user – stack left untouched"
        exit 0
      fi
    fi
  else
    log "version change within the ${previous_major} line: ${PREVIOUS_VERSION} -> ${TARGET_VERSION}"
  fi
}

run_backup() {
  local output

  log "creating a verified backup before the upgrade"
  output="$("${SCRIPT_DIR}/backup.sh" 2>&1)" \
    || { printf '%s\n' "${output}" >&2; die "backup failed – nothing was changed" "${EXIT_BACKUP_FAILED}"; }
  BACKUP_DIR="$(sed -n 's/^set:[[:space:]]*//p' <<< "${output}" | tail -1)"
  [[ -n "${BACKUP_DIR}" && -d "${BACKUP_DIR}" ]] \
    || die "backup reported success but its directory is unknown" "${EXIT_BACKUP_FAILED}"
  log "backup complete: ${BACKUP_DIR}"
}

set_env_value() {
  local key="$1" value="$2"

  if grep -qE "^${key}=" "${ENV_FILE}"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "${ENV_FILE}" \
      || die "could not set ${key} in .env" "${EXIT_TARGET_REJECTED}"
  else
    printf '%s=%s\n' "${key}" "${value}" >> "${ENV_FILE}"
  fi
  log "${key}=${value} written to .env"
}

validate_compose() {
  compose config >/dev/null \
    || die "docker compose config failed after the version bump" "${EXIT_TARGET_REJECTED}"
}

assert_resolved_image() {
  local resolved

  compose config 2>/dev/null | grep -E '^[[:space:]]+image:' > "${BACKUP_DIR}/images-resolved.txt" || true
  resolved="$(grep -oE 'lfnovo/open_notebook:[^[:space:]]+' "${BACKUP_DIR}/images-resolved.txt" | head -1)"

  [[ "${resolved}" == "lfnovo/open_notebook:${TARGET_VERSION}" ]] \
    || die "the active Compose file would start '${resolved}' instead of 'lfnovo/open_notebook:${TARGET_VERSION}'" \
           "${EXIT_TARGET_REJECTED}"
  log "resolved configuration confirmed: ${resolved}"
}

start_stack() {
  log "stopping the stack"
  compose down
  log "pulling images"
  compose pull
  log "starting the stack"
  compose up -d
}

wait_for_health() {
  local url code waited=0

  url="http://127.0.0.1:$(host_port "${OPEN_NOTEBOOK_API_PORT}")${HEALTH_PATH}"
  log "waiting for the API at ${url} (max ${HTTP_TIMEOUT_S}s)"

  while (( waited < HTTP_TIMEOUT_S )); do
    code="$(curl -s -o /dev/null -w '%{http_code}' -m 5 "${url}" 2>/dev/null || true)"
    if [[ "${code}" == "200" ]]; then
      log "the API answers on /health"
      return 0
    fi
    sleep 5
    waited=$(( waited + 5 ))
  done

  compose logs --tail 60 open_notebook >&2 || true
  die "Open Notebook did not answer within ${HTTP_TIMEOUT_S}s – consider the rollback below" \
      "${EXIT_NOT_READY}"
}

verify_upgrade() {
  compose ps
  log "running images:"
  docker inspect -f '  {{.Name}} -> {{.Config.Image}}' \
    "${COMPOSE_PROJECT_NAME:-open-notebook}-app" 2>/dev/null || true
}

show_rollback_instructions() {
  cat <<ROLLBACK

=== Upgrade to ${TARGET_VERSION} finished ===
backup: ${BACKUP_DIR}

Way back (only if the new version misbehaves):
  1) cd ${APP_DIR} && docker compose down
  2) sed -i 's/^OPEN_NOTEBOOK_VERSION=.*/OPEN_NOTEBOOK_VERSION=${PREVIOUS_VERSION}/' .env
  3) restore the backup set:
       rm -rf ${SURREAL_DATA:-./data/open-notebook/surreal} ${NOTEBOOK_DATA:-./data/open-notebook/notebook}
       tar -xzf ${BACKUP_DIR}/state.tar.gz -C ${APP_DIR}
       cp ${BACKUP_DIR}/env.backup .env && chmod 600 .env
  4) docker compose pull && docker compose up -d

Step 3 needs the privileges the backup was taken with. The database keeps its
RocksDB layout between v2 releases, so a rollback within the v2 line works
without a schema import. Since v1.15.0 the encryption format changed – rolling
back across that boundary without this backup loses the stored provider keys.
ROLLBACK
}

main() {
  parse_arguments "$@"
  trap on_error ERR

  cd "${APP_DIR}"
  check_prerequisites
  load_env
  PREVIOUS_VERSION="${OPEN_NOTEBOOK_VERSION}"
  log "pinned version: ${PREVIOUS_VERSION} -> target version: ${TARGET_VERSION}"

  verify_target_version_exists
  check_version_jump
  run_backup
  set_env_value "OPEN_NOTEBOOK_VERSION" "${TARGET_VERSION}"
  validate_compose
  assert_resolved_image
  start_stack
  wait_for_health
  verify_upgrade
  show_rollback_instructions
}

main "$@"
