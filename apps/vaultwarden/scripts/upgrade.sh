#!/usr/bin/env bash
# =============================================================================
# upgrade.sh – Move the Vaultwarden stack to another version, and pin it
# =============================================================================
# Vaultwarden is stateful and its schema migrations are one-way. There is also
# no database service to dump: everything sits in a single SQLite file plus the
# attachment folders under DATA, so the backup is a stop-copy of that directory
# (a running SQLite file is not guaranteed to be consistent).
#
# This script is also the recommended way out of VERSION=latest: pass a release
# tag and it writes that tag into .env, so the stack is pinned afterwards.
#
# Order of operations: verify the target tag → classify the jump → stop the
# stack → archive .env and DATA → bump VERSION → check the resolved
# configuration → start → verify → print rollback instructions.
#
# Usage:   ./scripts/upgrade.sh <target-version> [--yes]
#            <target-version>  e.g. 1.35.0 – the value of VERSION
#            --yes             skip the confirmation prompt
# Needs:   docker with the compose plugin (v2), curl, gzip, tar, GNU sed/stat
# Writes:  backup/<timestamp>/{data.tar.gz,env.backup,images.txt}
#
# Exit codes:
#   0  upgrade done (or aborted by the user without changes)
#   2  usage error
#   3  prerequisite missing (.env, docker, daemon)
#   4  target version rejected (unknown tag, config resolves to something else)
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
readonly DOCKERHUB_TAGS_API="https://hub.docker.com/v2/repositories/vaultwarden/server/tags"
readonly SERVICE_NAME="bitwarden"
readonly HTTP_TIMEOUT_S="180"
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
upgrade.sh – update the Vaultwarden stack

  ./scripts/upgrade.sh <target-version> [--yes]

  <target-version>  a published tag of the vaultwarden/server image, e.g. 1.35.0
  --yes             skip the confirmation prompt

The script stops the stack before copying DATA, because a running SQLite file
cannot be copied consistently. It also replaces VERSION in .env, which is how
you get off "latest": after the first run the stack is on a fixed release.
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
    printf 'the password database itself: %s\n' "${DATA:-./data/vaultwarden}" >&2
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
    || die "target version '${TARGET_VERSION}' is not of the form X.Y.Z (use a real release tag, not 'latest')" \
           "${EXIT_USAGE}"
}

check_prerequisites() {
  command -v docker >/dev/null 2>&1 || die "command 'docker' not found" "${EXIT_PREREQUISITE}"
  command -v curl   >/dev/null 2>&1 || die "command 'curl' not found" "${EXIT_PREREQUISITE}"
  docker compose version >/dev/null 2>&1 \
    || die "docker compose (plugin v2) is not available" "${EXIT_PREREQUISITE}"
  docker info >/dev/null 2>&1 || die "docker daemon is not reachable" "${EXIT_PREREQUISITE}"
  [[ -f "${ENV_FILE}" ]] || die ".env is missing – copy env-dist and fill it in" "${EXIT_PREREQUISITE}"
  command -v df >/dev/null 2>&1 || warn "'df' is missing – the free-space check is skipped"
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
  VERSION="$(env_value "${ENV_FILE}" VERSION)"
  DATA="$(env_value "${ENV_FILE}" DATA)"
  EXPORT_PORT="$(env_value "${ENV_FILE}" EXPORT_PORT)"
  ADMIN_TOKEN="$(env_value "${ENV_FILE}" ADMIN_TOKEN)"
  BACKUP_ROOT="$(env_value "${ENV_FILE}" BACKUP_DIR)"
  : "${BACKUP_ROOT:=./backups}"

  : "${VERSION:?VERSION is missing in .env}"
  : "${DATA:=./data/vaultwarden}"
  : "${EXPORT_PORT:=8080}"

  if [[ -z "${ADMIN_TOKEN:-}" ]]; then
    warn "ADMIN_TOKEN is empty – the /admin panel stays unreachable"
  fi
}

verify_target_version_exists() {
  local status

  status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 \
    "${DOCKERHUB_TAGS_API}/${TARGET_VERSION}")"
  [[ "${status}" == "200" ]] \
    || die "image tag vaultwarden/server:${TARGET_VERSION} does not exist (HTTP ${status})" \
           "${EXIT_TARGET_REJECTED}"
  log "target version confirmed in the registry: vaultwarden/server:${TARGET_VERSION}"
}

check_version_jump() {
  if [[ "${TARGET_VERSION}" == "${PREVIOUS_VERSION}" ]]; then
    log "target equals the pinned version – no version change, only config re-apply"
    return 0
  fi

  if [[ ! "${PREVIOUS_VERSION}" =~ ${VERSION_PATTERN} ]]; then
    warn "the currently pinned version is '${PREVIOUS_VERSION}', which is not a release tag"
    warn "the version actually running cannot be determined from the image alone –"
    warn "use 'docker inspect bitwarden --format {{.Config.Image}}' and docker image ls"
  fi

  warn "jump ${PREVIOUS_VERSION} -> ${TARGET_VERSION}"
  warn "Vaultwarden migrations are one-way: attachments and the SQLite database of"
  warn "the new version cannot be read by the old binary. Back up DATA before continuing,"
  warn "and check the release notes:"
  warn "  https://github.com/dani-garcia/vaultwarden/releases"
  if [[ "${ASSUME_YES}" != "true" ]]; then
    answer=""
    read -r -p "continue? [no/yes] " answer || answer=""
    if [[ "${answer}" != "yes" ]]; then
      log "aborted by the user – stack left untouched"
      exit 0
    fi
  fi
}

check_free_space() {
  local available_kb

  command -v df >/dev/null 2>&1 || return 0
  available_kb="$(df -Pk "${DATA}" 2>/dev/null | awk 'NR==2 {print $4}')"
  [[ -n "${available_kb}" ]] || return 0

  if (( available_kb < 524288 )); then
    warn "less than 512 MiB free on the filesystem holding ${DATA}"
  else
    log "free space for the backup: $(( available_kb / 1024 )) MiB"
  fi
}

prepare_backup_directory() {
  BACKUP_DIR="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "${BACKUP_DIR}"

  docker inspect -f '{{.Name}} -> {{.Config.Image}}' \
    "$(docker compose -f "${COMPOSE_FILE}" ps -q "${SERVICE_NAME}" 2>/dev/null | head -1)" \
    > "${BACKUP_DIR}/images.txt" 2>/dev/null \
    || warn "could not record the running image tag"
  cp "${ENV_FILE}" "${BACKUP_DIR}/env.backup"
  log "backup directory: ${BACKUP_DIR}"
}

stop_stack() {
  log "stopping the stack – required before copying the SQLite database"
  compose down
}

backup_data_directory() {
  local archive="${BACKUP_DIR}/data.tar.gz"
  local entries

  [[ -d "${DATA}" ]] || die "data directory ${DATA} does not exist" "${EXIT_BACKUP_FAILED}"
  tar -czf "${archive}" -C "${APP_DIR}" "${ENV_FILE}" "${DATA}" \
    || die "archiving ${DATA} failed" "${EXIT_BACKUP_FAILED}"
  gzip -t "${archive}" || die "data archive is corrupted" "${EXIT_BACKUP_FAILED}"

  # Check the CONTENT, not the size: a small data directory packs into less
  # than a kilobyte, so a size threshold would reject valid backups.
  entries="$(tar -tzf "${archive}" | wc -l)"
  (( entries > 0 )) || die "data archive contains no entries" "${EXIT_BACKUP_FAILED}"

  if [[ -f "${DATA}/db.sqlite3" ]]; then
    log "SQLite database found and archived: ${DATA}/db.sqlite3"
  else
    warn "no db.sqlite3 in ${DATA} – is this a fresh instance?"
  fi
  log "data archived: ${archive} (${entries} entries, $(stat -c %s "${archive}") bytes)"
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
  resolved="$(grep -oE 'vaultwarden/server:[^[:space:]]+' "${BACKUP_DIR}/images-resolved.txt" | head -1)"

  [[ "${resolved}" == "vaultwarden/server:${TARGET_VERSION}" ]] \
    || die "the active Compose file would start '${resolved}' instead of 'vaultwarden/server:${TARGET_VERSION}'" \
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
  local url
  local waited=0
  url="http://127.0.0.1:$(host_port "${EXPORT_PORT}")/"

  log "waiting for Vaultwarden at ${url} (max ${HTTP_TIMEOUT_S}s)"
  while (( waited < HTTP_TIMEOUT_S )); do
    if curl -fsS -m 5 -o /dev/null "${url}"; then
      log "Vaultwarden is answering"
      return 0
    fi
    sleep 5
    waited=$(( waited + 5 ))
  done

  compose logs --tail 60 "${SERVICE_NAME}" >&2 || true
  die "Vaultwarden did not answer within ${HTTP_TIMEOUT_S}s – consider the rollback below" \
      "${EXIT_NOT_READY}"
}

verify_upgrade() {
  compose ps
  log "check the log for migration messages, they run once on startup:"
  compose logs --tail 20 "${SERVICE_NAME}" || true
  log "clients reconnect on their own; a version mismatch shows up as a notice in the web vault"
}

show_rollback_instructions() {
  cat <<ROLLBACK

=== Upgrade to ${TARGET_VERSION} finished (VERSION is now pinned in .env) ===
backup: ${BACKUP_DIR}

Way back (only if the new version misbehaves):
  1) cd ${APP_DIR} && docker compose down
  2) sed -i 's/^VERSION=.*/VERSION=${PREVIOUS_VERSION}/' .env
  3) rm -rf ${DATA:?}       # discard the migrated database and attachments
  4) tar -xzf ${BACKUP_DIR}/data.tar.gz -C ${APP_DIR}
  5) docker compose up -d

Step 3 is the part people forget: the old image cannot read a database that a
newer version migrated. Restoring the directory without removing the migrated
files first leaves you with a mix of both.

Also worth keeping, in addition to this archive: a JSON export of the vault from
the web UI (Tools → Export vault). It is the only form that survives a lost
master password.
ROLLBACK
}

main() {
  parse_arguments "$@"
  trap on_error ERR

  cd "${APP_DIR}"
  check_prerequisites
  load_env
  PREVIOUS_VERSION="${VERSION}"
  log "pinned version: ${PREVIOUS_VERSION} -> target version: ${TARGET_VERSION}"

  verify_target_version_exists
  check_version_jump
  check_free_space
  prepare_backup_directory
  stop_stack
  backup_data_directory
  set_env_value "VERSION" "${TARGET_VERSION}"
  validate_compose
  assert_resolved_image
  start_stack
  wait_for_service
  verify_upgrade
  show_rollback_instructions
}

main "$@"
