#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh – First-time setup of the SearXNG stack (idempotent)
# =============================================================================
# Creates .env from env-dist (generating SEARXNG_SECRET), creates the data
# directories, validates the Compose file, starts the stack and waits until
# /healthz answers.
#
# Usage:   ./scripts/bootstrap.sh
# Needs:   docker with the compose plugin (v2), curl, openssl
# Writes:  .env (mode 600) and the directories under ./data/searxng/
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
readonly SECRET_HEX_BYTES="32"

readonly EXIT_USAGE=2
readonly EXIT_PREREQUISITE=3
readonly EXIT_CONFIG_INVALID=4
readonly EXIT_NOT_READY=6

usage() {
  cat <<'USAGE'
bootstrap.sh – set up the SearXNG stack for the first time

  ./scripts/bootstrap.sh

Re-running is safe: an existing .env and existing data are never overwritten.
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
  local secret

  if [[ -f "${ENV_FILE}" ]]; then
    log ".env already exists – leaving it untouched"
    return 0
  fi

  secret="$(openssl rand -hex "${SECRET_HEX_BYTES}")"
  sed -e "s|^SEARXNG_SECRET=.*|SEARXNG_SECRET=${secret}|" "${ENV_EXAMPLE}" > "${ENV_FILE}"
  chmod 600 "${ENV_FILE}"
  log ".env created from env-dist (mode 600, SEARXNG_SECRET generated)"
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
  SEARXNG_VERSION="$(env_value "${ENV_FILE}" SEARXNG_VERSION)"
  SEARXNG_PORT="$(env_value "${ENV_FILE}" SEARXNG_PORT)"
  SEARXNG_SECRET="$(env_value "${ENV_FILE}" SEARXNG_SECRET)"
  SEARXNG_CONFIG="$(env_value "${ENV_FILE}" SEARXNG_CONFIG)"
  SEARXNG_DATA="$(env_value "${ENV_FILE}" SEARXNG_DATA)"
  VALKEY_DATA="$(env_value "${ENV_FILE}" VALKEY_DATA)"

  : "${SEARXNG_PORT:=42180}"
  : "${SEARXNG_CONFIG:=./data/searxng/config}"
  : "${SEARXNG_DATA:=./data/searxng/cache}"
  : "${VALKEY_DATA:=./data/searxng/valkey}"

  if [[ "${SEARXNG_SECRET}" == "CHANGEME" || -z "${SEARXNG_SECRET}" ]]; then
    die "SEARXNG_SECRET is still the placeholder from env-dist" "${EXIT_CONFIG_INVALID}"
  fi
}

prepare_directories() {
  mkdir -p "${SEARXNG_CONFIG}" "${SEARXNG_DATA}" "${VALKEY_DATA}"
  log "data directories created: ${SEARXNG_CONFIG}, ${SEARXNG_DATA}, ${VALKEY_DATA}"

  if [[ -s "${SEARXNG_CONFIG}/settings.yml" ]]; then
    log "settings.yml found – the instance uses its own configuration"
  else
    warn "no settings.yml in ${SEARXNG_CONFIG} – SearXNG starts with built-in defaults"
    warn "engine and UI customisations need that file; the secret and base URL come from .env"
  fi
}

validate_compose() {
  compose config >/dev/null \
    || die "docker compose config failed (syntax, or a variable missing in .env)" "${EXIT_CONFIG_INVALID}"
  log "compose configuration is valid"
}

start_stack() {
  log "pulling images (SearXNG ${SEARXNG_VERSION:-unknown})"
  compose pull
  log "starting the stack"
  compose up -d
}

wait_for_health() {
  local url code waited=0

  url="http://127.0.0.1:$(host_port "${SEARXNG_PORT}")/healthz"
  log "waiting for SearXNG at ${url} (max ${HTTP_TIMEOUT_S}s)"

  while (( waited < HTTP_TIMEOUT_S )); do
    code="$(curl -s -o /dev/null -w '%{http_code}' -m 5 "${url}" 2>/dev/null || true)"
    if [[ "${code}" == "200" ]]; then
      log "SearXNG answers on /healthz"
      return 0
    fi
    sleep 5
    waited=$(( waited + 5 ))
  done

  compose logs --tail 40 searxng >&2 || true
  die "SearXNG did not answer within ${HTTP_TIMEOUT_S}s" "${EXIT_NOT_READY}"
}

show_status() {
  compose ps
  log "web UI: http://127.0.0.1:$(host_port "${SEARXNG_PORT}")/"
  log "the limiter is active against Valkey – no extra setup needed"
  log "put a reverse proxy in front and set SEARXNG_BASE_URL to the public URL"
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
