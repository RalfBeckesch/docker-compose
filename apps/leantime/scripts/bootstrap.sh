#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh – First-time setup of the Leantime stack (idempotent)
# =============================================================================
# Creates .env from env-dist (generating the three secrets), creates the data
# directories, applies the ownership the container needs, fetches the upstream
# changelog of the pinned version, validates the Compose file, starts the stack
# and waits until /health answers.
#
# Usage:   ./scripts/bootstrap.sh
# Needs:   docker with the compose plugin (v2), curl, openssl, chown
# Writes:  .env (mode 600), ./data/leantime/*, ./backups
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
readonly UPSTREAM_REPO="https://raw.githubusercontent.com/Leantime/leantime"
readonly HEALTH_PATH="/health"
readonly HEALTH_TIMEOUT_S="180"

readonly EXIT_USAGE=2
readonly EXIT_PREREQUISITE=3
readonly EXIT_CONFIG_INVALID=4
readonly EXIT_NOT_READY=6

usage() {
  cat <<'USAGE'
bootstrap.sh – set up the Leantime stack for the first time

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

# Read one value from an env file. The file is never sourced: values such as
# BACKUP_DIR or UID collide with readonly shell variables and would abort the
# script mid-run.
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
  local db_root_password db_password session_password

  if [[ -f "${ENV_FILE}" ]]; then
    log ".env already exists – leaving it untouched"
    return 0
  fi

  db_root_password="$(openssl rand -hex 32)"
  db_password="$(openssl rand -hex 32)"
  session_password="$(openssl rand -hex 32)"

  sed -e "s/^MYSQL_ROOT_PASSWORD=CHANGEME$/MYSQL_ROOT_PASSWORD=${db_root_password}/" \
      -e "s/^MYSQL_PASSWORD=CHANGEME$/MYSQL_PASSWORD=${db_password}/" \
      -e "s/^LEAN_SESSION_PASSWORD=CHANGEME$/LEAN_SESSION_PASSWORD=${session_password}/" \
      "${ENV_EXAMPLE}" > "${ENV_FILE}"
  chmod 600 "${ENV_FILE}"
  log ".env created from env-dist (mode 600, secrets generated)"
}

load_env() {
  LEANTIME_VERSION="$(env_value "${ENV_FILE}" LEANTIME_VERSION)"
  MARIADB_VERSION="$(env_value "${ENV_FILE}" MARIADB_VERSION)"
  COMPOSE_PROJECT_NAME="$(env_value "${ENV_FILE}" COMPOSE_PROJECT_NAME)"
  LEAN_HOST_PORT="$(env_value "${ENV_FILE}" LEAN_HOST_PORT)"
  LEAN_APP_URL="$(env_value "${ENV_FILE}" LEAN_APP_URL)"
  LEAN_UID="$(env_value "${ENV_FILE}" LEAN_UID)"
  LEAN_GID="$(env_value "${ENV_FILE}" LEAN_GID)"
  MARIADB_DATA="$(env_value "${ENV_FILE}" MARIADB_DATA)"
  LEAN_USERFILES="$(env_value "${ENV_FILE}" LEAN_USERFILES)"
  LEAN_PUBLIC_USERFILES="$(env_value "${ENV_FILE}" LEAN_PUBLIC_USERFILES)"
  LEAN_PLUGINS="$(env_value "${ENV_FILE}" LEAN_PLUGINS)"
  LEAN_LOGS="$(env_value "${ENV_FILE}" LEAN_LOGS)"
  BACKUP_ROOT="$(env_value "${ENV_FILE}" BACKUP_DIR)"

  : "${LEANTIME_VERSION:?LEANTIME_VERSION is missing in .env}"
  : "${MARIADB_VERSION:?MARIADB_VERSION is missing in .env}"
  : "${COMPOSE_PROJECT_NAME:=leantime}"
  : "${LEAN_HOST_PORT:=8080}"
  : "${LEAN_UID:=1000}"
  : "${LEAN_GID:=0}"
  : "${MARIADB_DATA:?MARIADB_DATA is missing in .env}"
  : "${LEAN_USERFILES:?LEAN_USERFILES is missing in .env}"
  : "${LEAN_PUBLIC_USERFILES:?LEAN_PUBLIC_USERFILES is missing in .env}"
  : "${LEAN_PLUGINS:?LEAN_PLUGINS is missing in .env}"
  : "${LEAN_LOGS:?LEAN_LOGS is missing in .env}"
  : "${BACKUP_ROOT:=./backups}"
  : "${LEAN_APP_URL:=http://localhost:${LEAN_HOST_PORT}/}"
}

prepare_directories() {
  mkdir -p "${MARIADB_DATA}" "${LEAN_USERFILES}" "${LEAN_PUBLIC_USERFILES}" \
           "${LEAN_PLUGINS}" "${LEAN_LOGS}" "${BACKUP_ROOT}" "${REF_DIR}"

  # The app runs as LEAN_UID:LEAN_GID and never takes ownership of these
  # directories itself, so the host owner has to match. Without this, uploads,
  # plugin installs and log writes fail with "permission denied".
  if chown -R "${LEAN_UID}:${LEAN_GID}" "${LEAN_USERFILES}" "${LEAN_PUBLIC_USERFILES}" \
       "${LEAN_PLUGINS}" "${LEAN_LOGS}" 2>/dev/null; then
    log "application directories owned by ${LEAN_UID}:${LEAN_GID}"
  else
    warn "cannot chown the application directories (missing privileges?)"
    warn "without uid ${LEAN_UID} on them, uploads and plugin installs fail"
  fi
  # The MariaDB data directory is deliberately not chowned: the MariaDB
  # entrypoint starts as root and fixes the ownership itself.
}

fetch_upstream_reference() {
  local target="${REF_DIR}/CHANGELOG-${LEANTIME_VERSION}.md"
  local url="${UPSTREAM_REPO}/v${LEANTIME_VERSION}/CHANGELOG.md"

  if [[ -s "${target}" ]]; then
    log "upstream reference already present: ${target}"
    return 0
  fi
  if curl -fsS --max-time 30 "${url}" -o "${target}" 2>/dev/null && [[ -s "${target}" ]]; then
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
  log "pulling images (leantime ${LEANTIME_VERSION}, mariadb ${MARIADB_VERSION})"
  compose pull
  log "starting the stack"
  compose up -d
}

wait_for_service() {
  local url="http://127.0.0.1:${LEAN_HOST_PORT}${HEALTH_PATH}"
  local waited=0

  log "waiting for Leantime at ${url} (max ${HEALTH_TIMEOUT_S}s)"
  while (( waited < HEALTH_TIMEOUT_S )); do
    if curl -fsS -m 5 -o /dev/null "${url}"; then
      log "Leantime is answering"
      return 0
    fi
    sleep 3
    waited=$(( waited + 3 ))
  done

  compose logs --tail 40 leantime >&2 || true
  die "Leantime did not answer within ${HEALTH_TIMEOUT_S}s" "${EXIT_NOT_READY}"
}

show_status() {
  compose ps
  log "running images:"
  docker inspect -f '  {{.Name}} -> {{.Config.Image}}' \
    "${COMPOSE_PROJECT_NAME}" "${COMPOSE_PROJECT_NAME}-db" 2>/dev/null || true

  log "public URL: ${LEAN_APP_URL}"
  log "local URL:  http://127.0.0.1:${LEAN_HOST_PORT}/"
  log "backups:    ${BACKUP_ROOT}"
  log "next step:  open the UI and create the first account – it becomes the admin"
  log "            (LEAN_APP_URL must be reachable from the browser for mails)"
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
