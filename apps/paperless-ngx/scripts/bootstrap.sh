#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh – First-time setup of the Paperless-ngx stack (idempotent)
# =============================================================================
# NOTE: this stack keeps its configuration in docker-compose.env (not .env),
# which is why every compose call here passes --env-file explicitly.
#
# Creates docker-compose.env from env-dist (generating the secret key and the
# database password), creates every data directory, validates the Compose file,
# starts the stack, waits until the web UI answers and reminds about the
# superuser, which cannot be scripted.
#
# Usage:   ./scripts/bootstrap.sh
# Needs:   docker with the compose plugin (v2), curl, openssl, gzip, tar
# Writes:  docker-compose.env (mode 600) and all directories under ./data/
#
# Exit codes:
#   0  stack is up and answering
#   2  usage error
#   3  prerequisite missing (env file, docker, daemon)
#   4  compose file or resolved configuration invalid
#   6  stack did not become ready
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
APP_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly APP_DIR

readonly ENV_FILE="${APP_DIR}/docker-compose.env"
readonly ENV_EXAMPLE="${APP_DIR}/env-dist"
readonly COMPOSE_FILE="${APP_DIR}/docker-compose.yaml"
readonly BACKUP_DIR="${APP_DIR}/backup"
readonly HTTP_TIMEOUT_S="300"
readonly SECRET_KEY_HEX_BYTES="64"
readonly PASSWORD_HEX_BYTES="32"

readonly EXIT_USAGE=2
readonly EXIT_PREREQUISITE=3
readonly EXIT_CONFIG_INVALID=4
readonly EXIT_NOT_READY=6

usage() {
  cat <<'USAGE'
bootstrap.sh – set up the Paperless-ngx stack for the first time

  ./scripts/bootstrap.sh

The configuration lives in ../docker-compose.env afterwards (mode 600).
Re-running is safe: an existing env file and existing data are never overwritten.
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

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "command '$1' not found" "${EXIT_PREREQUISITE}"
}

host_port() {
  printf '%s\n' "${1##*:}"
}

check_prerequisites() {
  require_command docker
  require_command curl
  require_command openssl
  docker compose version >/dev/null 2>&1 \
    || die "docker compose (plugin v2) is not available" "${EXIT_PREREQUISITE}"
  docker info >/dev/null 2>&1 || die "docker daemon is not reachable" "${EXIT_PREREQUISITE}"
  [[ -f "${COMPOSE_FILE}" ]] || die "docker-compose.yaml not found in ${APP_DIR}" "${EXIT_PREREQUISITE}"
  [[ -f "${ENV_EXAMPLE}" ]] || die "env-dist not found in ${APP_DIR}" "${EXIT_PREREQUISITE}"
}

create_env_file() {
  local secret_key db_password

  if [[ -f "${ENV_FILE}" ]]; then
    log "docker-compose.env already exists – leaving it untouched"
    return 0
  fi

  secret_key="$(openssl rand -hex "${SECRET_KEY_HEX_BYTES}")"
  db_password="$(openssl rand -hex "${PASSWORD_HEX_BYTES}")"

  sed -e "s|^PAPERLESS_SECRET_KEY=.*|PAPERLESS_SECRET_KEY=${secret_key}|" \
      -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${db_password}|" \
      "${ENV_EXAMPLE}" > "${ENV_FILE}"
  chmod 600 "${ENV_FILE}"
  log "docker-compose.env created from env-dist (mode 600, secret key and password generated)"
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
  PAPERLESS_BACKUP_DIR="$(env_value "${ENV_FILE}" PAPERLESS_BACKUP_DIR)"
  POSTGRES_DATA_DIR="$(env_value "${ENV_FILE}" POSTGRES_DATA_DIR)"
  REDIS_DATA_DIR="$(env_value "${ENV_FILE}" REDIS_DATA_DIR)"
  PAPERLESS_EXPORT_PORT="$(env_value "${ENV_FILE}" PAPERLESS_EXPORT_PORT)"
  USERMAP_UID="$(env_value "${ENV_FILE}" USERMAP_UID)"
  USERMAP_GID="$(env_value "${ENV_FILE}" USERMAP_GID)"

  : "${PAPERLESS_VERSION:?PAPERLESS_VERSION is missing in the env file}"
  : "${PAPERLESS_DATA_DIR:?PAPERLESS_DATA_DIR is missing in the env file}"
  : "${PAPERLESS_MEDIA_DIR:?PAPERLESS_MEDIA_DIR is missing in the env file}"
  : "${PAPERLESS_CONSUMPTION_DIR:?PAPERLESS_CONSUMPTION_DIR is missing in the env file}"
  : "${PAPERLESS_EXPORT_DIR:?PAPERLESS_EXPORT_DIR is missing in the env file}"
  : "${PAPERLESS_BACKUP_DIR:?PAPERLESS_BACKUP_DIR is missing in the env file}"
  : "${POSTGRES_DATA_DIR:?POSTGRES_DATA_DIR is missing in the env file}"
  : "${REDIS_DATA_DIR:?REDIS_DATA_DIR is missing in the env file}"
  : "${PAPERLESS_EXPORT_PORT:=8080}"
}

prepare_directories() {
  local directory

  for directory in "${PAPERLESS_DATA_DIR}" "${PAPERLESS_MEDIA_DIR}" "${PAPERLESS_CONSUMPTION_DIR}" \
                   "${PAPERLESS_EXPORT_DIR}" "${PAPERLESS_BACKUP_DIR}" "${POSTGRES_DATA_DIR}" \
                   "${REDIS_DATA_DIR}" "${BACKUP_DIR}"; do
    mkdir -p "${directory}"
  done
  log "data directories created under ${APP_DIR}"

  # Paperless writes its files as USERMAP_UID/USERMAP_GID; the postgres and redis
  # entrypoints fix the ownership of their own directories during startup.
  if [[ -n "${USERMAP_UID:-}" ]]; then
    if chown -R "${USERMAP_UID}:${USERMAP_GID:-${USERMAP_UID}}" \
         "${PAPERLESS_DATA_DIR}" "${PAPERLESS_MEDIA_DIR}" "${PAPERLESS_CONSUMPTION_DIR}" \
         "${PAPERLESS_EXPORT_DIR}" "${PAPERLESS_BACKUP_DIR}" 2>/dev/null; then
      log "application directories owned by ${USERMAP_UID}:${USERMAP_GID:-${USERMAP_UID}}"
    else
      warn "cannot chown the application directories (missing privileges?)"
    fi
  fi
}

validate_compose() {
  compose config >/dev/null \
    || die "docker compose config failed (syntax, or a variable missing in docker-compose.env)" "${EXIT_CONFIG_INVALID}"
  log "compose configuration is valid"
}

start_stack() {
  log "pulling images (paperless ${PAPERLESS_VERSION})"
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
      log "Paperless is answering"
      return 0
    fi
    sleep 5
    waited=$(( waited + 5 ))
  done

  compose logs --tail 40 webserver >&2 || true
  die "Paperless did not answer within ${HTTP_TIMEOUT_S}s" "${EXIT_NOT_READY}"
}

show_status() {
  compose ps
  log "web UI:  http://127.0.0.1:$(host_port "${PAPERLESS_EXPORT_PORT}")/"
  log "backups: ${BACKUP_DIR}"
  log "REQUIRED NEXT STEP: create the superuser – it cannot be scripted:"
  log "  docker compose --env-file docker-compose.env run --rm webserver createsuperuser"
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
  wait_for_service
  show_status
}

main "$@"
