#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh – First-time setup of the Forgejo stack (idempotent)
# =============================================================================
# Creates .env from env-dist (generating the three secrets), creates the data
# directories, applies the ownership the container requires, validates the
# Compose file, starts the stack and waits until /api/healthz answers.
#
# Usage:   ./scripts/bootstrap.sh
# Needs:   docker with the compose plugin (v2), curl, openssl, chown
# Writes:  .env (mode 600) and the directories under ./data/forgejo/
#
# Exit codes:
#   0  stack is up and answering
#   2  usage error
#   3  prerequisite missing (.env/env-dist/compose file, docker, daemon)
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
readonly HEALTH_PATH="/api/healthz"
readonly HEALTH_TIMEOUT_S="180"

readonly EXIT_USAGE=2
readonly EXIT_PREREQUISITE=3
readonly EXIT_CONFIG_INVALID=4
readonly EXIT_NOT_READY=6

usage() {
  cat <<'USAGE'
bootstrap.sh – set up the Forgejo stack for the first time

  ./scripts/bootstrap.sh

The stack configuration lives in ../.env afterwards (mode 600).
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

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "command '$1' not found" "${EXIT_PREREQUISITE}"
}

check_prerequisites() {
  require_command docker
  require_command curl
  require_command openssl
  docker compose version >/dev/null 2>&1 \
    || die "docker compose (plugin v2) is not available" "${EXIT_PREREQUISITE}"
  docker info >/dev/null 2>&1 \
    || die "docker daemon is not reachable" "${EXIT_PREREQUISITE}"
  [[ -f "${COMPOSE_FILE}" ]] \
    || die "docker-compose.yaml not found in ${APP_DIR}" "${EXIT_PREREQUISITE}"
  [[ -f "${ENV_EXAMPLE}" ]] \
    || die "env-dist not found in ${APP_DIR}" "${EXIT_PREREQUISITE}"
}

create_env_file() {
  local db_password secret_key internal_token jwt_secret

  if [[ -f "${ENV_FILE}" ]]; then
    log ".env already exists – leaving it untouched"
    return 0
  fi

  db_password="$(openssl rand -hex 32)"
  secret_key="$(openssl rand -hex 32)"
  internal_token="$(openssl rand -hex 40)"
  jwt_secret="$(openssl rand -hex 32)"

  sed -e "s/^POSTGRES_PASSWORD=CHANGEME$/POSTGRES_PASSWORD=${db_password}/" \
      -e "s/^FORGEJO_SECRET_KEY=CHANGEME$/FORGEJO_SECRET_KEY=${secret_key}/" \
      -e "s/^FORGEJO_INTERNAL_TOKEN=CHANGEME$/FORGEJO_INTERNAL_TOKEN=${internal_token}/" \
      -e "s/^FORGEJO_JWT_SECRET=CHANGEME$/FORGEJO_JWT_SECRET=${jwt_secret}/" \
      "${ENV_EXAMPLE}" > "${ENV_FILE}"
  chmod 600 "${ENV_FILE}"
  log ".env created from env-dist (mode 600, secrets generated)"
}

load_env() {
  # Values come from the user-maintained .env; keep it shell-compatible
  # (no spaces, no unescaped $) or this sourcing step breaks.
  set -a
  # shellcheck source=/dev/null
  . "${ENV_FILE}"
  set +a

  : "${FORGEJO_VERSION:?FORGEJO_VERSION is missing in .env}"
  : "${FORGEJO_DATA:?FORGEJO_DATA is missing in .env}"
  : "${POSTGRES_DATA:?POSTGRES_DATA is missing in .env}"
  : "${POSTGRES_VERSION:?POSTGRES_VERSION is missing in .env}"
  : "${FORGEJO_ROOT_URL:?FORGEJO_ROOT_URL is missing in .env}"
  : "${FORGEJO_UID:=1000}"
  : "${FORGEJO_GID:=1000}"
  : "${FORGEJO_HTTP_PORT:=3000}"
  : "${FORGEJO_SSH_PORT:=2222}"
  : "${COMPOSE_PROJECT_NAME:=forgejo}"
}

prepare_directories() {
  mkdir -p "${FORGEJO_DATA}" "${POSTGRES_DATA}"

  # Forgejo runs as FORGEJO_UID inside the container and never takes ownership
  # of /data itself, so the host owner has to match. Without this the container
  # cannot create app.ini and exits.
  if chown "${FORGEJO_UID}:${FORGEJO_GID}" "${FORGEJO_DATA}" 2>/dev/null; then
    log "${FORGEJO_DATA} owned by ${FORGEJO_UID}:${FORGEJO_GID}"
  else
    warn "cannot chown ${FORGEJO_DATA} (missing privileges?)"
    warn "without uid ${FORGEJO_UID} on that directory, Forgejo fails to start"
  fi
  # The postgres data directory is deliberately not chowned: the postgres
  # entrypoint starts as root and fixes the PGDATA ownership itself.
}

validate_compose() {
  compose config >/dev/null \
    || die "docker compose config failed (syntax, or a variable missing in .env)" "${EXIT_CONFIG_INVALID}"
  log "compose configuration is valid"
}

start_stack() {
  log "pulling images (forgejo ${FORGEJO_VERSION}, postgres ${POSTGRES_VERSION})"
  compose pull
  log "starting the stack"
  compose up -d
}

wait_for_service() {
  local url="http://127.0.0.1:${FORGEJO_HTTP_PORT}${HEALTH_PATH}"
  local waited=0

  log "waiting for Forgejo at ${url} (max ${HEALTH_TIMEOUT_S}s)"
  while (( waited < HEALTH_TIMEOUT_S )); do
    if curl -fsS -m 5 -o /dev/null "${url}"; then
      log "Forgejo is answering"
      return 0
    fi
    sleep 3
    waited=$(( waited + 3 ))
  done

  compose logs --tail 40 server >&2 || true
  die "Forgejo did not answer within ${HEALTH_TIMEOUT_S}s" "${EXIT_NOT_READY}"
}

show_status() {
  compose ps
  log "running images:"
  docker inspect -f '  {{.Name}} -> {{.Config.Image}}' \
    "${COMPOSE_PROJECT_NAME}" "${COMPOSE_PROJECT_NAME}-db" 2>/dev/null || true

  log "public URL: ${FORGEJO_ROOT_URL}"
  log "local URL:  http://127.0.0.1:${FORGEJO_HTTP_PORT}/"
  log "git over SSH: ssh://git@${FORGEJO_SSH_DOMAIN}:${FORGEJO_SSH_PORT}/<owner>/<repo>.git"
  log "backups:    ${BACKUP_DIR:-./backups}"
  log "next step:  open the UI and create the first account (it becomes admin),"
  log "            then set FORGEJO_DISABLE_REGISTRATION=true in .env and run"
  log "            'docker compose up -d' to apply it"
}

main() {
  case "${1:-}" in
    -h|--help) usage; return 0 ;;
    "")        ;;
    *)         usage; die "unknown option: $1" "${EXIT_USAGE}" ;;
  esac

  # Relative data paths in .env are resolved against the app directory, so the
  # script is callable from anywhere.
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
