#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh – First-time setup of the Open Notebook stack (idempotent)
# =============================================================================
# Creates .env from env-dist (generating the encryption key, the UI password and
# the database password), creates the data directories, validates the Compose
# file, starts the stack and waits until /health answers on the API port.
#
# Usage:   ./scripts/bootstrap.sh
# Needs:   docker with the compose plugin (v2), curl, openssl
# Writes:  .env (mode 600), the directories under ./data/open-notebook/
#
# Exit codes:
#   0  stack is up and healthy
#   2  usage error
#   3  prerequisite missing (.env source, docker, daemon)
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
readonly HTTP_TIMEOUT_S="300"
readonly SECRET_HEX_BYTES="32"
readonly PASSWORD_HEX_BYTES="16"

readonly EXIT_USAGE=2
readonly EXIT_PREREQUISITE=3
readonly EXIT_CONFIG_INVALID=4
readonly EXIT_NOT_READY=6

usage() {
  cat <<'USAGE'
bootstrap.sh – set up the Open Notebook stack for the first time

  ./scripts/bootstrap.sh

Re-running is safe: an existing .env and existing data are never overwritten.
The generated secrets land in .env only (mode 600) and are never printed.
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
  local encryption_key password db_password

  if [[ -f "${ENV_FILE}" ]]; then
    log ".env already exists – leaving it untouched"
    return 0
  fi

  encryption_key="$(openssl rand -hex "${SECRET_HEX_BYTES}")"
  password="$(openssl rand -hex "${PASSWORD_HEX_BYTES}")"
  db_password="$(openssl rand -hex "${SECRET_HEX_BYTES}")"

  sed -e "s|^OPEN_NOTEBOOK_ENCRYPTION_KEY=.*|OPEN_NOTEBOOK_ENCRYPTION_KEY=${encryption_key}|" \
      -e "s|^OPEN_NOTEBOOK_PASSWORD=.*|OPEN_NOTEBOOK_PASSWORD=${password}|" \
      -e "s|^SURREAL_PASSWORD=.*|SURREAL_PASSWORD=${db_password}|" \
      "${ENV_EXAMPLE}" > "${ENV_FILE}"
  chmod 600 "${ENV_FILE}"
  log ".env created from env-dist (mode 600)"
  log "generated: encryption key, UI password and database password – all in .env"
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
  OPEN_NOTEBOOK_UI_PORT="$(env_value "${ENV_FILE}" OPEN_NOTEBOOK_UI_PORT)"
  OPEN_NOTEBOOK_ENCRYPTION_KEY="$(env_value "${ENV_FILE}" OPEN_NOTEBOOK_ENCRYPTION_KEY)"
  OPEN_NOTEBOOK_PASSWORD="$(env_value "${ENV_FILE}" OPEN_NOTEBOOK_PASSWORD)"
  SURREAL_PASSWORD="$(env_value "${ENV_FILE}" SURREAL_PASSWORD)"
  SURREAL_DATA="$(env_value "${ENV_FILE}" SURREAL_DATA)"
  NOTEBOOK_DATA="$(env_value "${ENV_FILE}" NOTEBOOK_DATA)"

  : "${OPEN_NOTEBOOK_UI_PORT:=8502}"
  : "${SURREAL_DATA:=./data/open-notebook/surreal}"
  : "${NOTEBOOK_DATA:=./data/open-notebook/notebook}"

  if [[ "${OPEN_NOTEBOOK_ENCRYPTION_KEY}" == "CHANGEME" || -z "${OPEN_NOTEBOOK_ENCRYPTION_KEY}" ]]; then
    die "OPEN_NOTEBOOK_ENCRYPTION_KEY is still the placeholder from env-dist" "${EXIT_CONFIG_INVALID}"
  fi
  if [[ "${OPEN_NOTEBOOK_PASSWORD}" == "CHANGEME" ]]; then
    die "OPEN_NOTEBOOK_PASSWORD is still the placeholder from env-dist" "${EXIT_CONFIG_INVALID}"
  fi
  if [[ "${SURREAL_PASSWORD}" == "CHANGEME" || -z "${SURREAL_PASSWORD}" ]]; then
    die "SURREAL_PASSWORD is still the placeholder from env-dist" "${EXIT_CONFIG_INVALID}"
  fi
}

prepare_directories() {
  mkdir -p "${SURREAL_DATA}" "${NOTEBOOK_DATA}"
  log "data directories created: ${SURREAL_DATA}, ${NOTEBOOK_DATA}"

  # SurrealDB writes its RocksDB files as SURREAL_UID/SURREAL_GID. When those
  # are 0:0 the container runs as root and the host operator may not be able to
  # read the files – scripts/backup.sh then needs sudo. Warn early.
  local uid_value gid_value
  uid_value="$(env_value "${ENV_FILE}" SURREAL_UID)"
  gid_value="$(env_value "${ENV_FILE}" SURREAL_GID)"
  : "${uid_value:=0}"
  : "${gid_value:=0}"

  if [[ "${uid_value}" == "0" ]]; then
    warn "SURREAL_UID=0 – the database runs as root and its files in ${SURREAL_DATA}"
    warn "will be root-owned. Backups then need sudo. Set SURREAL_UID/SURREAL_GID"
    warn "to your own uid:gid and re-run to keep the data operator-owned."
  elif chown -R "${uid_value}:${gid_value}" "${SURREAL_DATA}" 2>/dev/null; then
    log "${SURREAL_DATA} owned by ${uid_value}:${gid_value}"
  else
    warn "cannot chown ${SURREAL_DATA} (missing privileges?)"
  fi
}

validate_compose() {
  compose config >/dev/null \
    || die "docker compose config failed (syntax, or a variable missing in .env)" "${EXIT_CONFIG_INVALID}"
  log "compose configuration is valid"
}

start_stack() {
  log "pulling images (Open Notebook ${OPEN_NOTEBOOK_VERSION:-unknown})"
  compose pull
  log "starting the stack"
  compose up -d
}

wait_for_health() {
  local url code waited=0 api_port

  # The API listens on its own port; probe it there.
  api_port="$(env_value "${ENV_FILE}" OPEN_NOTEBOOK_API_PORT)"
  : "${api_port:=5055}"
  url="http://127.0.0.1:${api_port}/health"
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

  compose logs --tail 40 open_notebook >&2 || true
  die "Open Notebook did not answer within ${HTTP_TIMEOUT_S}s" "${EXIT_NOT_READY}"
}

show_status() {
  local ui_port api_port
  ui_port="$(env_value "${ENV_FILE}" OPEN_NOTEBOOK_UI_PORT)"
  api_port="$(env_value "${ENV_FILE}" OPEN_NOTEBOOK_API_PORT)"
  : "${ui_port:=8502}"
  : "${api_port:=5055}"

  compose ps
  log "web UI:  http://127.0.0.1:$(host_port "${ui_port}")/"
  log "REST API: http://127.0.0.1:$(host_port "${api_port}")/docs"
  log "sign in with OPEN_NOTEBOOK_PASSWORD from .env"
  log "provider credentials are configured in the UI (Manage → Models), not in .env"
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
