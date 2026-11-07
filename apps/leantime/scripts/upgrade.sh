#!/usr/bin/env bash
# =============================================================================
# upgrade.sh – Move the Leantime stack to another version
# =============================================================================
# Order of operations: verify the target tag → classify the jump → verified
# backup (database dump + directories) → bump LEANTIME_VERSION → check the
# resolved configuration → pull → start → wait for /health → run the migrations
# → print rollback steps.
#
# A major jump (3.x → 4.x) is refused: the upstream guide requires disabling
# every plugin first and verifying the result by hand. So are 3.6.0 and 3.6.1 –
# both shipped redirect loops and missing JS assets (fixed in 3.6.2).
#
# Usage:   ./scripts/upgrade.sh <target-version> [--yes]
#            <target-version>  e.g. 3.13.3 – the value of LEANTIME_VERSION
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
readonly REGISTRY_TAG_API="https://hub.docker.com/v2/repositories/leantime/leantime/tags"
readonly UPGRADE_GUIDE="https://docs.leantime.io/installation/upgrade-guide"
readonly RELEASE_NOTES="https://github.com/Leantime/leantime/releases"
readonly HEALTH_PATH="/health"
readonly HTTP_TIMEOUT_S="240"
readonly VERSION_PATTERN='^[0-9]+\.[0-9]+\.[0-9]+$'

readonly EXIT_USAGE=2
readonly EXIT_PREREQUISITE=3
readonly EXIT_TARGET_REJECTED=4
readonly EXIT_BACKUP_FAILED=5
readonly EXIT_NOT_READY=6

TARGET_VERSION=""
PREVIOUS_VERSION=""
BACKUP_DIR=""
ASSUME_YES="false"

usage() {
  cat <<'USAGE'
upgrade.sh – update the Leantime stack

  ./scripts/upgrade.sh <target-version> [--yes]

  <target-version>  a published tag of the Leantime image, e.g. 3.13.3
  --yes             skip the confirmation prompt for a minor jump

Patch jumps run unattended. A minor jump asks once (unless --yes is given).
A major jump is refused on purpose: the upstream guide requires disabling all
plugins first and verifying the result by hand.
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

# Read one value from the env file. Sourcing it would break on names that are
# readonly in bash – so read, never source.
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
  LEANTIME_VERSION="$(env_value "${ENV_FILE}" LEANTIME_VERSION)"
  LEAN_HOST_PORT="$(env_value "${ENV_FILE}" LEAN_HOST_PORT)"
  LEAN_BIND_ADDR="$(env_value "${ENV_FILE}" LEAN_BIND_ADDR)"
  COMPOSE_PROJECT_NAME="$(env_value "${ENV_FILE}" COMPOSE_PROJECT_NAME)"
  BACKUP_ROOT="$(env_value "${ENV_FILE}" BACKUP_DIR)"

  : "${LEANTIME_VERSION:?LEANTIME_VERSION is missing in .env}"
  : "${LEAN_HOST_PORT:=8080}"
  : "${LEAN_BIND_ADDR:=127.0.0.1}"
  : "${COMPOSE_PROJECT_NAME:=leantime}"
  : "${BACKUP_ROOT:=./backups}"
}

verify_target_version_exists() {
  local status

  # Docker Hub answers 200 for an existing tag and 404 for a missing one.
  status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 \
    "${REGISTRY_TAG_API}/${TARGET_VERSION}")"
  [[ "${status}" == "200" ]] \
    || die "image tag leantime/leantime:${TARGET_VERSION} does not exist (HTTP ${status})" \
           "${EXIT_TARGET_REJECTED}"
  log "target version confirmed in the registry: leantime/leantime:${TARGET_VERSION}"
}

confirm_or_abort() {
  local prompt="$1" answer

  [[ "${ASSUME_YES}" == "true" ]] && return 0
  # No terminal (cron, CI) → do not guess: abort cleanly.
  [[ -t 0 ]] || return 1
  read -r -p "${prompt} [y/N] " answer || return 1
  [[ "${answer}" =~ ^[Yy]$ ]]
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

  if [[ "${previous_major}" != "${target_major}" ]]; then
    # The upstream guide is explicit: crossing a major line needs every plugin
    # deactivated first and human verification. A script that guesses those
    # steps is worse than one that stops here.
    printf 'ERROR: major jump %s -> %s is not automated.\n' "${PREVIOUS_VERSION}" "${TARGET_VERSION}" >&2
    printf 'Read the upgrade guide first: %s\n' "${UPGRADE_GUIDE}" >&2
    printf 'Typical manual steps for a major jump:\n' >&2
    printf '  1) deactivate every plugin in Settings → Plugins\n' >&2
    printf '  2) back up (scripts/backup.sh)\n' >&2
    printf '  3) stop the stack (docker compose down)\n' >&2
    printf '  4) set LEANTIME_VERSION in .env\n' >&2
    printf '  5) docker compose pull && docker compose up -d\n' >&2
    printf '  6) open the UI, run the update and check the plugins\n' >&2
    exit "${EXIT_TARGET_REJECTED}"
  fi

  # 3.6.0 and 3.6.1 are broken releases (redirect loops, missing JS assets).
  if [[ "${TARGET_VERSION}" == "3.6.0" || "${TARGET_VERSION}" == "3.6.1" ]]; then
    printf 'ERROR: %s is a broken release (redirect loops, missing JS assets).\n' "${TARGET_VERSION}" >&2
    printf 'Use 3.6.2 or newer: %s\n' "${RELEASE_NOTES}" >&2
    exit "${EXIT_TARGET_REJECTED}"
  fi

  if [[ "${previous_minor}" != "${target_minor}" ]]; then
    warn "minor jump ${PREVIOUS_VERSION} -> ${TARGET_VERSION} within the ${previous_major} line"
    warn "release notes: ${RELEASE_NOTES}"
    if ! confirm_or_abort "Upgrade from ${PREVIOUS_VERSION} to ${TARGET_VERSION}?"; then
      printf 'aborted by the user – nothing was changed\n' >&2
      exit 0
    fi
    return 0
  fi

  log "patch jump ${PREVIOUS_VERSION} -> ${TARGET_VERSION} (low risk)"
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
  resolved="$(grep -oE 'leantime/leantime:[^[:space:]]+' "${BACKUP_DIR}/images-resolved.txt" | head -1)"

  [[ "${resolved}" == "leantime/leantime:${TARGET_VERSION}" ]] \
    || die "the active Compose file would start '${resolved}' instead of 'leantime/leantime:${TARGET_VERSION}'" \
           "${EXIT_TARGET_REJECTED}"
  log "resolved configuration confirmed: ${resolved}"
}

start_stack() {
  log "pulling images"
  compose pull
  log "starting the stack"
  compose up -d
}

wait_for_health() {
  local url response waited=0
  url="http://127.0.0.1:$(host_port "${LEAN_HOST_PORT}")${HEALTH_PATH}"

  log "waiting for Leantime at ${url} (max ${HTTP_TIMEOUT_S}s)"
  while (( waited < HTTP_TIMEOUT_S )); do
    response="$(curl -fsS -m 5 -o /dev/null -w '%{http_code}' "${url}" 2>/dev/null || true)"
    if [[ "${response}" == "200" ]]; then
      log "Leantime is answering"
      return 0
    fi
    sleep 5
    waited=$(( waited + 5 ))
  done

  compose logs --tail 60 leantime >&2 || true
  die "Leantime did not answer within ${HTTP_TIMEOUT_S}s – consider the rollback below" \
      "${EXIT_NOT_READY}"
}

run_migrations() {
  log "running the database migrations"
  compose exec -T leantime php bin/leantime db:migrate \
    || warn "the CLI migration failed – the first browser request redirects to /update instead"
}

verify_upgrade() {
  compose ps
  log "running images:"
  docker inspect -f '  {{.Name}} -> {{.Config.Image}}' \
    "${COMPOSE_PROJECT_NAME:-leantime}" 2>/dev/null || true
}

show_rollback_instructions() {
  cat <<ROLLBACK

=== Upgrade to ${TARGET_VERSION} finished ===
backup: ${BACKUP_DIR}

Way back (only if the new version misbehaves):
  1) cd ${APP_DIR} && docker compose down
  2) sed -i 's/^LEANTIME_VERSION=.*/LEANTIME_VERSION=${PREVIOUS_VERSION}/' .env
  3) unpack the application directories and restore the database:
       tar -xzf ${BACKUP_DIR}/data.tar.gz -C ${APP_DIR}
       chown -R \${LEAN_UID:-1000}:\${LEAN_GID:-0} \${LEAN_USERFILES} \\
         \${LEAN_PUBLIC_USERFILES} \${LEAN_PLUGINS} \${LEAN_LOGS}
       docker compose up -d db
       docker compose exec -T db mariadb -uroot -p"\$MYSQL_ROOT_PASSWORD" \\
         -e 'DROP DATABASE IF EXISTS \${MYSQL_DATABASE}; CREATE DATABASE \${MYSQL_DATABASE};'
       gunzip -c ${BACKUP_DIR}/db.sql.gz | \\
         docker compose exec -T db mariadb -uroot -p"\$MYSQL_ROOT_PASSWORD" \${MYSQL_DATABASE}
  4) docker compose up -d
  5) open the UI and confirm the instance starts without a redirect to /update

The new version migrated the schema. Switching the image tag back alone is not
enough – the old image cannot read the migrated tables, so the database dump
has to be restored as well.
ROLLBACK
}

main() {
  parse_arguments "$@"
  trap on_error ERR

  cd "${APP_DIR}"
  check_prerequisites
  load_env
  PREVIOUS_VERSION="${LEANTIME_VERSION}"
  log "pinned version: ${PREVIOUS_VERSION} -> target version: ${TARGET_VERSION}"

  verify_target_version_exists
  check_version_jump
  run_backup
  set_env_value "LEANTIME_VERSION" "${TARGET_VERSION}"
  validate_compose
  assert_resolved_image
  start_stack
  wait_for_health
  run_migrations
  verify_upgrade
  show_rollback_instructions
}

main "$@"
