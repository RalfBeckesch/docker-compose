#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh – First-time setup of the Vikunja stack (idempotent)
# =============================================================================
# Creates .env from env-dist (generating the secrets), creates the data
# directories, sets the ownership the container needs, fetches the upstream
# changelog of the pinned version, validates the Compose file, starts the stack
# and waits until Vikunja actually answers.
#
# Usage:   ./scripts/bootstrap.sh
# Needs:   docker with the compose plugin (v2), curl, openssl, gzip, tar, chown
# Writes:  .env (mode 600), data/, ref/, backup/
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
readonly REF_DIR="${APP_DIR}/ref"
readonly BACKUP_ROOT="${APP_DIR}/backups"
readonly UPSTREAM_REPO="https://raw.githubusercontent.com/go-vikunja/vikunja"
readonly HEALTH_PATH="/api/v1/info"
readonly HEALTH_TIMEOUT_S="180"

readonly EXIT_USAGE=2
readonly EXIT_PREREQUISITE=3
readonly EXIT_CONFIG_INVALID=4
readonly EXIT_NOT_READY=6

usage() {
  cat <<'USAGE'
bootstrap.sh – set up the Vikunja stack for the first time

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
  local db_password service_secret

  if [[ -f "${ENV_FILE}" ]]; then
    log ".env already exists – leaving it untouched"
    return 0
  fi

  db_password="$(openssl rand -hex 32)"
  service_secret="$(openssl rand -hex 32)"

  sed -e "s/^POSTGRES_PASSWORD=CHANGEME$/POSTGRES_PASSWORD=${db_password}/" \
      -e "s/^VIKUNJA_SERVICE_SECRET=CHANGEME$/VIKUNJA_SERVICE_SECRET=${service_secret}/" \
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

  : "${VIKUNJA_VERSION:?VIKUNJA_VERSION is missing in .env}"
  : "${VIKUNJA_FILES:?VIKUNJA_FILES is missing in .env}"
  : "${POSTGRES_DATA:?POSTGRES_DATA is missing in .env}"
  : "${VIKUNJA_UID:=1000}"
  : "${VIKUNJA_GID:=1000}"
  : "${HTTP_PORT:=3456}"
  : "${COMPOSE_PROJECT_NAME:=vikunja}"
}

prepare_directories() {
  mkdir -p "${VIKUNJA_FILES}" "${POSTGRES_DATA}" "${REF_DIR}" "${BACKUP_ROOT}"

  # Vikunja runs as VIKUNJA_UID inside the container and never takes ownership
  # of this directory itself, so the host owner has to match.
  if chown "${VIKUNJA_UID}:${VIKUNJA_GID}" "${VIKUNJA_FILES}" 2>/dev/null; then
    log "${VIKUNJA_FILES} owned by ${VIKUNJA_UID}:${VIKUNJA_GID}"
  else
    warn "cannot chown ${VIKUNJA_FILES} (missing privileges?)"
    warn "without uid ${VIKUNJA_UID} on that directory, uploads fail with 'permission denied'"
  fi
  # The postgres data directory is deliberately not chowned: the postgres
  # entrypoint starts as root and fixes the PGDATA ownership itself.
}

fetch_upstream_reference() {
  local target="${REF_DIR}/CHANGELOG-${VIKUNJA_VERSION}.md"
  local url="${UPSTREAM_REPO}/v${VIKUNJA_VERSION}/CHANGELOG.md"

  if [[ -f "${target}" ]]; then
    log "upstream reference already present: ${target}"
    return 0
  fi
  if curl -fsS --max-time 30 "${url}" -o "${target}"; then
    log "upstream reference downloaded: ${target}"
  else
    rm -f "${target}" 2>/dev/null || true
    warn "cannot download the upstream changelog – read it manually before the next upgrade"
  fi
}

validate_compose() {
  compose config >/dev/null \
    || die "docker compose config failed (syntax, or a variable missing in .env)" "${EXIT_CONFIG_INVALID}"
  log "compose configuration is valid"
}

start_stack() {
  log "pulling images (vikunja ${VIKUNJA_VERSION}, postgres ${POSTGRES_VERSION})"
  compose pull
  log "starting the stack"
  compose up -d
}

wait_for_service() {
  local url="http://127.0.0.1:${HTTP_PORT}${HEALTH_PATH}"
  local waited=0

  log "waiting for Vikunja at ${url} (max ${HEALTH_TIMEOUT_S}s)"
  while (( waited < HEALTH_TIMEOUT_S )); do
    if curl -fsS -m 5 -o /dev/null "${url}"; then
      log "Vikunja is answering"
      return 0
    fi
    sleep 3
    waited=$(( waited + 3 ))
  done

  compose logs --tail 40 vikunja >&2 || true
  die "Vikunja did not answer within ${HEALTH_TIMEOUT_S}s" "${EXIT_NOT_READY}"
}

show_status() {
  compose ps
  log "running images:"
  docker inspect -f '  {{.Name}} -> {{.Config.Image}}' \
    "${COMPOSE_PROJECT_NAME}" "${COMPOSE_PROJECT_NAME}-db" 2>/dev/null || true

  log "public URL: ${VIKUNJA_PUBLIC_URL}"
  log "local URL:  http://127.0.0.1:${HTTP_PORT}/"
  log "backups:    ${BACKUP_ROOT}"
  log "next step:  register your account, then set VIKUNJA_ENABLE_REGISTRATION=false"
  log "            in .env and run 'docker compose up -d' to apply it"
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
  fetch_upstream_reference
  validate_compose
  start_stack
  wait_for_service
  show_status
}

main "$@"
