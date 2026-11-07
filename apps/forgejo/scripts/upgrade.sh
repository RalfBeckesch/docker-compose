#!/usr/bin/env bash
# =============================================================================
# upgrade.sh – Move the Forgejo stack to another version
# =============================================================================
# Order of operations: verify the target tag → classify the jump → verified
# backup (dump with the server stopped) → stop → bump FORGEJO_VERSION → check
# the resolved configuration → pull → start → verify → print rollback steps.
#
# A major jump (16 → 17) is refused: the upstream upgrade guide requires manual
# operations and human verification for those. Run the steps from the guide by
# hand instead of letting a script guess.
#
# Usage:   ./scripts/upgrade.sh <target-version>
#            <target-version>  e.g. 17.0.1 – the value of FORGEJO_VERSION
# Needs:   docker with the compose plugin (v2), curl, gzip, tar, GNU sed/stat
# Writes:  backups/<timestamp>/… (via scripts/backup.sh)
#
# Exit codes:
#   0  upgrade done
#   2  usage error
#   3  prerequisite missing (.env, docker, daemon)
#   4  target version rejected (unknown tag, major jump, config resolves elsewhere)
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
readonly REGISTRY_MANIFEST_API="https://data.forgejo.org/v2/forgejo/forgejo/manifests"
readonly UPGRADE_GUIDE="https://forgejo.org/docs/latest/admin/upgrade/"
readonly RELEASE_NOTES="https://codeberg.org/forgejo/forgejo/releases"
readonly HEALTH_PATH="/api/healthz"
readonly HTTP_TIMEOUT_S="180"
readonly VERSION_PATTERN='^[0-9]+\.[0-9]+\.[0-9]+$'

readonly EXIT_USAGE=2
readonly EXIT_PREREQUISITE=3
readonly EXIT_TARGET_REJECTED=4
readonly EXIT_BACKUP_FAILED=5
readonly EXIT_NOT_READY=6

TARGET_VERSION=""
PREVIOUS_VERSION=""
BACKUP_DIR=""

usage() {
  cat <<'USAGE'
upgrade.sh – update the Forgejo stack

  ./scripts/upgrade.sh <target-version> [--yes]

  <target-version>  a published tag of the Forgejo image, e.g. 17.0.1
  --yes             accepted for consistency with the other stacks; a major
                    jump is refused regardless, so there is no prompt to skip

Patch and minor jumps run unattended. A major jump is refused on purpose: the
upstream upgrade guide requires manual operations for those.
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
      # Accepted for consistency with the other stacks. A major jump is refused
      # regardless, so there is no prompt this flag could skip.
      --yes)     ;;
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
  FORGEJO_VERSION="$(env_value "${ENV_FILE}" FORGEJO_VERSION)"
  FORGEJO_HTTP_PORT="$(env_value "${ENV_FILE}" FORGEJO_HTTP_PORT)"
  BACKUP_ROOT="$(env_value "${ENV_FILE}" BACKUP_DIR)"

  : "${FORGEJO_VERSION:?FORGEJO_VERSION is missing in .env}"
  : "${FORGEJO_HTTP_PORT:=3000}"
  : "${BACKUP_ROOT:=./backups}"
}

verify_target_version_exists() {
  local status

  # The manifest endpoint answers 200 for an existing tag and 404 for a missing
  # one – no authentication needed on the data.forgejo.org mirror. The Accept
  # header asks for the OCI index the registry publishes.
  status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 \
    -H 'Accept: application/vnd.oci.image.index.v1+json' \
    "${REGISTRY_MANIFEST_API}/${TARGET_VERSION}")"
  [[ "${status}" == "200" ]] \
    || die "image tag forgejo:${TARGET_VERSION} does not exist (HTTP ${status})" "${EXIT_TARGET_REJECTED}"
  log "target version confirmed in the registry: forgejo:${TARGET_VERSION}"
}

check_version_jump() {
  local previous_major target_major previous_minor target_minor

  if [[ "${TARGET_VERSION}" == "${PREVIOUS_VERSION}" ]]; then
    log "target equals the pinned version – no version change, only config re-apply"
    return 0
  fi

  previous_major="${PREVIOUS_VERSION%%.*}"
  target_major="${TARGET_VERSION%%.*}"
  previous_minor="${PREVIOUS_VERSION#*.}"; previous_minor="${previous_minor%%.*}"
  target_minor="${TARGET_VERSION#*.}";     target_minor="${target_minor%%.*}"

  if [[ "${previous_major}" == "${target_major}" ]]; then
    if [[ "${previous_minor}" != "${target_minor}" ]]; then
      warn "minor jump ${PREVIOUS_VERSION} -> ${TARGET_VERSION} within the ${previous_major} line"
      warn "release notes: ${RELEASE_NOTES}"
      return 0
    fi
    log "patch jump ${PREVIOUS_VERSION} -> ${TARGET_VERSION} (low risk)"
    return 0
  fi

  # The upstream guide is explicit: crossing a major line needs manual
  # operations and human verification. A script that guesses those steps is
  # worse than one that stops here.
  printf 'ERROR: major jump %s -> %s is not automated.\n' "${PREVIOUS_VERSION}" "${TARGET_VERSION}" >&2
  printf 'Read the upgrade guide first: %s\n' "${UPGRADE_GUIDE}" >&2
  printf 'Typical manual steps for a major jump:\n' >&2
  printf '  1) back up (scripts/backup.sh)\n' >&2
  printf '  2) stop the stack (docker compose down)\n' >&2
  printf '  3) set FORGEJO_VERSION in .env\n' >&2
  printf '  4) docker compose pull && docker compose up -d\n' >&2
  printf '  5) run the post-upgrade checks named in the guide\n' >&2
  exit "${EXIT_TARGET_REJECTED}"
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
  resolved="$(grep -oE 'forgejo/forgejo:[^[:space:]]+' "${BACKUP_DIR}/images-resolved.txt" | head -1)"

  [[ "${resolved}" == "forgejo/forgejo:${TARGET_VERSION}" ]] \
    || die "the active Compose file would start '${resolved}' instead of 'forgejo/forgejo:${TARGET_VERSION}'" \
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
  local url response waited=0
  url="http://127.0.0.1:$(host_port "${FORGEJO_HTTP_PORT}")${HEALTH_PATH}"

  log "waiting for Forgejo at ${url} (max ${HTTP_TIMEOUT_S}s)"
  while (( waited < HTTP_TIMEOUT_S )); do
    response="$(curl -fsS -m 5 -o /dev/null -w '%{http_code}' "${url}" 2>/dev/null || true)"
    if [[ "${response}" == "200" ]]; then
      log "Forgejo is answering"
      return 0
    fi
    sleep 5
    waited=$(( waited + 5 ))
  done

  compose logs --tail 60 server >&2 || true
  die "Forgejo did not answer within ${HTTP_TIMEOUT_S}s – consider the rollback below" \
      "${EXIT_NOT_READY}"
}

verify_upgrade() {
  compose ps
  log "running images:"
  docker inspect -f '  {{.Name}} -> {{.Config.Image}}' \
    "${COMPOSE_PROJECT_NAME:-forgejo}" 2>/dev/null || true
}

show_rollback_instructions() {
  cat <<ROLLBACK

=== Upgrade to ${TARGET_VERSION} finished ===
backup: ${BACKUP_DIR}

Way back (only if the new version misbehaves):
  1) cd ${APP_DIR} && docker compose down
  2) sed -i 's/^FORGEJO_VERSION=.*/FORGEJO_VERSION=${PREVIOUS_VERSION}/' .env
  3) restore the data volume from the dump:
       rm -rf ${FORGEJO_DATA:-./data/forgejo}/* ${FORGEJO_DATA:-./data/forgejo}/.[!.]* 2>/dev/null || true
       tar -xzf ${BACKUP_DIR}/forgejo-dump.tar.gz -C ${FORGEJO_DATA:-./data/forgejo}
       chown -R ${FORGEJO_UID:-1000}:${FORGEJO_GID:-1000} ${FORGEJO_DATA:-./data/forgejo}
  4) drop and recreate the database, then import forgejo-db.sql:
       docker compose up -d db
       docker compose exec -T db psql -U ${POSTGRES_USER:-forgejo} -d ${POSTGRES_DB:-forgejo} \\
         -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;'
       docker compose exec -T db psql -U ${POSTGRES_USER:-forgejo} -d ${POSTGRES_DB:-forgejo} \\
         < ${FORGEJO_DATA:-./data/forgejo}/forgejo-db.sql
  5) docker compose up -d

The old image can only read the old database schema. That is why the rollback
recreates the database instead of just switching the tag back.
ROLLBACK
}

main() {
  parse_arguments "$@"
  trap on_error ERR

  cd "${APP_DIR}"
  check_prerequisites
  load_env
  PREVIOUS_VERSION="${FORGEJO_VERSION}"
  log "pinned version: ${PREVIOUS_VERSION} -> target version: ${TARGET_VERSION}"

  verify_target_version_exists
  check_version_jump
  run_backup
  set_env_value "FORGEJO_VERSION" "${TARGET_VERSION}"
  validate_compose
  assert_resolved_image
  start_stack
  wait_for_health
  verify_upgrade
  show_rollback_instructions
}

main "$@"
