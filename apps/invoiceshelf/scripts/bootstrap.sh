#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh – First-time setup of the InvoiceShelf stack (idempotent)
# =============================================================================
# Creates .env from env-dist (generating the secrets), creates the data
# directories with the ownership the container needs, validates the Compose
# file, starts the stack and waits until InvoiceShelf actually answers.
#
# Usage:   ./scripts/bootstrap.sh
# Needs:   docker with the compose plugin (v2), curl, openssl, chown
# Writes:  .env (mode 600), data/, backups/
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
readonly BACKUP_ROOT="${APP_DIR}/backups"
readonly HEALTH_PATH="/healthcheck"
readonly HEALTH_TIMEOUT_S="300"

readonly EXIT_USAGE=2
readonly EXIT_PREREQUISITE=3
readonly EXIT_CONFIG_INVALID=4
readonly EXIT_NOT_READY=6

usage() {
  cat <<'USAGE'
bootstrap.sh – set up the InvoiceShelf stack for the first time

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
  local db_password app_key

  if [[ -f "${ENV_FILE}" ]]; then
    log ".env already exists – leaving it untouched"
    return 0
  fi

  db_password="$(openssl rand -hex 32)"
  # Laravel keys are "base64:" followed by 32 random bytes in base64. The "|"
  # delimiter keeps the "/" and "+" of a base64 string from breaking sed.
  app_key="$(openssl rand -base64 32)"

  sed -e "s|^POSTGRES_PASSWORD=CHANGEME$|POSTGRES_PASSWORD=${db_password}|" \
      -e "s|^APP_KEY=CHANGEME$|APP_KEY=base64:${app_key}|" \
      "${ENV_EXAMPLE}" > "${ENV_FILE}"
  chmod 600 "${ENV_FILE}"
  log ".env created from env-dist (mode 600, database password and APP_KEY generated)"
}

load_env() {
  # Values come from the user-maintained .env; keep it shell-compatible
  # (no spaces, no unescaped $) or this sourcing step breaks.
  set -a
  # shellcheck source=/dev/null
  . "${ENV_FILE}"
  set +a

  : "${INVOICESHELF_VERSION:?INVOICESHELF_VERSION is missing in .env}"
  : "${POSTGRES_VERSION:?POSTGRES_VERSION is missing in .env}"
  : "${INVOICESHELF_STORAGE:?INVOICESHELF_STORAGE is missing in .env}"
  : "${INVOICESHELF_MODULES:?INVOICESHELF_MODULES is missing in .env}"
  : "${POSTGRES_DATA:?POSTGRES_DATA is missing in .env}"
  : "${INVOICESHELF_UID:=82}"
  : "${INVOICESHELF_GID:=82}"
  : "${INVOICESHELF_HOST_PORT:=8090}"
  : "${COMPOSE_PROJECT_NAME:=invoiceshelf}"
}

prepare_directories() {
  mkdir -p "${INVOICESHELF_STORAGE}" "${INVOICESHELF_MODULES}" \
           "${POSTGRES_DATA}" "${BACKUP_ROOT}"

  # The image runs as uid 82 (www-data) and never takes ownership of the
  # mounted directories itself. Without matching ownership the container stops
  # at boot with "Cannot write to /var/www/html/storage".
  local directory
  for directory in "${INVOICESHELF_STORAGE}" "${INVOICESHELF_MODULES}"; do
    if chown "${INVOICESHELF_UID}:${INVOICESHELF_GID}" "${directory}" 2>/dev/null; then
      log "${directory} owned by ${INVOICESHELF_UID}:${INVOICESHELF_GID}"
    else
      warn "cannot chown ${directory} (missing privileges?)"
      warn "without uid ${INVOICESHELF_UID} on that directory the container refuses to start"
      warn "run as root: chown -R ${INVOICESHELF_UID}:${INVOICESHELF_GID} ${directory}"
    fi
  done
  # The postgres data directory is deliberately not chowned: the postgres
  # entrypoint starts as root and fixes the PGDATA ownership itself.
}

validate_compose() {
  compose config >/dev/null \
    || die "docker compose config failed (syntax, or a variable missing in .env)" "${EXIT_CONFIG_INVALID}"
  log "compose configuration is valid"
}

start_stack() {
  log "pulling images (invoiceshelf ${INVOICESHELF_VERSION}, postgres ${POSTGRES_VERSION})"
  compose pull
  log "starting the stack"
  compose up -d
}

wait_for_service() {
  local url="http://127.0.0.1:${INVOICESHELF_HOST_PORT}${HEALTH_PATH}"
  local waited=0

  log "waiting for InvoiceShelf at ${url} (max ${HEALTH_TIMEOUT_S}s)"
  while (( waited < HEALTH_TIMEOUT_S )); do
    if curl -fsS -m 5 -o /dev/null "${url}"; then
      log "InvoiceShelf is answering"
      return 0
    fi
    sleep 3
    waited=$(( waited + 3 ))
  done

  compose logs --tail 40 invoiceshelf >&2 || true
  die "InvoiceShelf did not answer within ${HEALTH_TIMEOUT_S}s" "${EXIT_NOT_READY}"
}

show_status() {
  compose ps
  log "running images:"
  docker inspect -f '  {{.Name}} -> {{.Config.Image}}' \
    "${COMPOSE_PROJECT_NAME}" "${COMPOSE_PROJECT_NAME}-db" 2>/dev/null || true

  log "local URL:  http://127.0.0.1:${INVOICESHELF_HOST_PORT}/"
  log "public URL: ${APP_URL:-unset}"
  log "backups:    ${BACKUP_ROOT}"
  log "next step:  open the UI and complete the setup wizard"
  log "            (the first account becomes the super admin)"
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
