#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh – First-time setup of the ntfy stack (idempotent)
# =============================================================================
# Creates .env from env-dist (generating the database password), creates the
# data directories, fixes their ownership to NTFY_UID/NTFY_GID, validates the
# Compose file, starts the stack and waits until /v1/health reports healthy.
#
# Usage:   ./scripts/bootstrap.sh
# Needs:   docker with the compose plugin (v2), curl, openssl
# Writes:  .env (mode 600) and the directories under ./data/
#
# Exit codes:
#   0  stack is up and healthy
#   2  usage error
#   3  prerequisite missing (.env, docker, daemon)
#   4  compose file or resolved configuration invalid
#   6  stack did not become ready
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
APP_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly APP_DIR

readonly ENV_FILE="${APP_DIR}/.env"
readonly ENV_EXAMPLE="${APP_DIR}/env-dist"
readonly COMPOSE_FILE="${APP_DIR}/docker-compose.yaml"
readonly HTTP_TIMEOUT_S="180"
readonly PASSWORD_HEX_BYTES="24"

readonly EXIT_USAGE=2
readonly EXIT_PREREQUISITE=3
readonly EXIT_CONFIG_INVALID=4
readonly EXIT_NOT_READY=6

usage() {
  cat <<'USAGE'
bootstrap.sh – set up the ntfy stack for the first time

  ./scripts/bootstrap.sh

Re-running is safe: existing .env values and existing data are never overwritten.
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

check_prerequisites() {
  command -v docker  >/dev/null 2>&1 || die "command 'docker' not found" "${EXIT_PREREQUISITE}"
  command -v curl    >/dev/null 2>&1 || die "command 'curl' not found" "${EXIT_PREREQUISITE}"
  command -v openssl >/dev/null 2>&1 || die "command 'openssl' not found" "${EXIT_PREREQUISITE}"
  docker compose version >/dev/null 2>&1 \
    || die "docker compose (plugin v2) is not available" "${EXIT_PREREQUISITE}"
  docker info >/dev/null 2>&1 || die "docker daemon is not reachable" "${EXIT_PREREQUISITE}"
  [[ -f "${COMPOSE_FILE}" ]] || die "docker-compose.yaml not found in ${APP_DIR}" "${EXIT_PREREQUISITE}"
  [[ -f "${ENV_EXAMPLE}" ]] || die "env-dist not found in ${APP_DIR}" "${EXIT_PREREQUISITE}"
}

create_env_file() {
  local password

  if [[ -f "${ENV_FILE}" ]]; then
    log ".env already exists – leaving it untouched"
    return 0
  fi

  password="$(openssl rand -hex "${PASSWORD_HEX_BYTES}")"
  sed -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${password}|" "${ENV_EXAMPLE}" > "${ENV_FILE}"
  chmod 600 "${ENV_FILE}"
  log ".env created from env-dist (mode 600, database password generated)"
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
  # The Compose file provides the same fallbacks, so a missing value is not an
  # error here – but the script needs concrete paths to work with.
  NTFY_VERSION="$(env_value "${ENV_FILE}" NTFY_VERSION)"
  NTFY_CACHE_DIR="$(env_value "${ENV_FILE}" NTFY_CACHE_DIR)"
  NTFY_CONFIG_DIR="$(env_value "${ENV_FILE}" NTFY_CONFIG_DIR)"
  POSTGRES_DATA_DIR="$(env_value "${ENV_FILE}" POSTGRES_DATA_DIR)"
  NTFY_UID="$(env_value "${ENV_FILE}" NTFY_UID)"
  NTFY_GID="$(env_value "${ENV_FILE}" NTFY_GID)"
  NTFY_EXPOSE_PORT="$(env_value "${ENV_FILE}" NTFY_EXPOSE_PORT)"
  POSTGRES_PASSWORD="$(env_value "${ENV_FILE}" POSTGRES_PASSWORD)"

  : "${NTFY_VERSION:?NTFY_VERSION is missing in .env}"
  : "${NTFY_CACHE_DIR:=./data/ntfy-cache}"
  : "${NTFY_CONFIG_DIR:=./data/ntfy-config}"
  : "${POSTGRES_DATA_DIR:=./data/postgres}"
  : "${NTFY_UID:=1000}"
  : "${NTFY_GID:=1000}"
  : "${NTFY_EXPOSE_PORT:=8080}"
  : "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is missing in .env}"

  if [[ "${POSTGRES_PASSWORD}" == "CHANGEME" ]]; then
    die "POSTGRES_PASSWORD is still the placeholder from env-dist" "${EXIT_CONFIG_INVALID}"
  fi
}

prepare_directories() {
  mkdir -p "${NTFY_CACHE_DIR}" "${NTFY_CONFIG_DIR}" "${POSTGRES_DATA_DIR}"
  log "data directories created: ${NTFY_CACHE_DIR}, ${NTFY_CONFIG_DIR}, ${POSTGRES_DATA_DIR}"

  # ntfy drops privileges to NTFY_UID/NTFY_GID; the cache directory has to
  # belong to that user or message storage fails at runtime.
  if chown -R "${NTFY_UID}:${NTFY_GID}" "${NTFY_CACHE_DIR}" "${NTFY_CONFIG_DIR}" 2>/dev/null; then
    log "ntfy directories owned by ${NTFY_UID}:${NTFY_GID}"
  else
    warn "cannot chown the ntfy directories (missing privileges?) – check the owner"
  fi
}

validate_compose() {
  compose config >/dev/null \
    || die "docker compose config failed (syntax, or a variable missing in .env)" "${EXIT_CONFIG_INVALID}"
  log "compose configuration is valid"
}

start_stack() {
  log "pulling images (ntfy ${NTFY_VERSION})"
  compose pull
  log "starting the stack"
  compose up -d
}

wait_for_health() {
  local url
  local response waited=0
  url="http://127.0.0.1:$(host_port "${NTFY_EXPOSE_PORT}")/v1/health"

  log "waiting for ntfy at ${url} (max ${HTTP_TIMEOUT_S}s)"
  while (( waited < HTTP_TIMEOUT_S )); do
    response="$(curl -fsS -m 5 "${url}" 2>/dev/null || true)"
    if grep -qE '"healthy"[[:space:]]*:[[:space:]]*true' <<< "${response}"; then
      log "ntfy reports healthy"
      return 0
    fi
    sleep 5
    waited=$(( waited + 5 ))
  done

  compose logs --tail 40 ntfy >&2 || true
  die "ntfy did not report healthy within ${HTTP_TIMEOUT_S}s" "${EXIT_NOT_READY}"
}

show_status() {
  compose ps
  log "web UI: http://127.0.0.1:$(host_port "${NTFY_EXPOSE_PORT}")/"
  log "authentication is off until NTFY_AUTH_USERS/ACCESS/TOKENS are set in .env –"
  log "generate them with the Config Generator: https://docs.ntfy.sh/config/#config-generator"
}

main() {
  case "${1:-}" in
    -h|--help) usage; return 0 ;;
    "")        ;;
    *)         usage; die "unknown option: $1" "${EXIT_USAGE}" ;;
  esac

  cd "${APP_DIR}"
  check_prerequisites
  create_env_file
  load_env
  prepare_directories
  validate_compose
  start_stack
  wait_for_health
  show_status
}

main "$@"
