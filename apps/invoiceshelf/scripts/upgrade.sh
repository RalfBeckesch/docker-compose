#!/usr/bin/env bash
# =============================================================================
# upgrade.sh – Move the InvoiceShelf stack to another version
# =============================================================================
# Order of operations: verify the target tag → classify the jump → dump and
# verify the database → archive storage and modules → bump the version → check
# the resolved Compose configuration → start → run the database migrations →
# verify. Rollback instructions are printed at the end.
#
# InvoiceShelf's in-app updater is disabled in containerised installs (the
# vendor documents "docker compose pull && docker compose up -d" instead). The
# image does NOT run migrations on boot by default either – AUTORUN_LARAVEL_
# MIGRATION is false in the vendor's Compose files – so this script runs
# "php artisan migrate --force" explicitly after the new container is up.
#
# Usage:   ./scripts/upgrade.sh <target-version> [--yes]
#            <target-version>  e.g. 2.4.7 – must be a published, stable tag
#            --yes             skip the confirmation prompt on a minor jump
# Needs:   docker with the compose plugin (v2), curl, gzip, tar, GNU sed/stat
# Writes:  backups/<timestamp>/{db.sql.gz,data.tar.gz,env.backup,images*.txt}
#
# Exit codes:
#   0  upgrade done, or aborted by the user without changes
#   2  usage error (missing or malformed target version)
#   3  prerequisite missing (.env, docker, daemon)
#   4  target version rejected (unknown tag, 3.x, wrong major)
#   5  backup incomplete – stack left untouched, or stopped and reported
#   6  stack did not become ready after the upgrade
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
APP_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly APP_DIR

readonly ENV_FILE="${APP_DIR}/.env"
readonly COMPOSE_FILE="${APP_DIR}/docker-compose.yaml"
readonly DOCKERHUB_TAGS_API="https://hub.docker.com/v2/repositories/invoiceshelf/invoiceshelf/tags"
readonly HEALTH_PATH="/healthcheck"
readonly HEALTH_TIMEOUT_S="300"
readonly VERSION_PATTERN='^[0-9]+\.[0-9]+\.[0-9]+$'
readonly SUPPORTED_MAJOR="2"
readonly MINIMUM_DUMP_BYTES=1024

readonly EXIT_USAGE=2
readonly EXIT_PREREQUISITE=3
readonly EXIT_TARGET_REJECTED=4
readonly EXIT_BACKUP_FAILED=5
readonly EXIT_NOT_READY=6

TARGET_VERSION=""
PREVIOUS_VERSION=""
ASSUME_YES="false"
BACKUP_DIR=""
BACKUP_ROOT=""

usage() {
  cat <<'USAGE'
upgrade.sh – update the InvoiceShelf stack

  ./scripts/upgrade.sh <target-version> [--yes]

  <target-version>  e.g. 2.4.7 – must be a published, stable release tag
  --yes             skip the confirmation prompt on a minor jump

Examples:
  ./scripts/upgrade.sh 2.4.7          # patch release
  ./scripts/upgrade.sh 2.5.0          # minor release, asks first

The 3.x line is an alpha preview and is refused: the vendor states it must not
be used with production data.
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

on_error() {
  local exit_code=$?
  printf '\n=== ABORTED (exit %s) ===\n' "${exit_code}" >&2
  if [[ -n "${BACKUP_DIR}" && -d "${BACKUP_DIR}" ]]; then
    printf 'backup of this run: %s\n' "${BACKUP_DIR}" >&2
  fi
  printf 'check the stack state: docker compose -f %s ps\n' "${COMPOSE_FILE}" >&2
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
    || die "target version '${TARGET_VERSION}' is not of the form X.Y.Z (no alpha, beta or RC tags)" "${EXIT_USAGE}"
}

check_prerequisites() {
  command -v docker >/dev/null 2>&1 || die "command 'docker' not found" "${EXIT_PREREQUISITE}"
  command -v curl   >/dev/null 2>&1 || die "command 'curl' not found" "${EXIT_PREREQUISITE}"
  docker compose version >/dev/null 2>&1 \
    || die "docker compose (plugin v2) is not available" "${EXIT_PREREQUISITE}"
  docker info >/dev/null 2>&1 \
    || die "docker daemon is not reachable" "${EXIT_PREREQUISITE}"
  [[ -f "${ENV_FILE}" ]] \
    || die ".env is missing – run ./scripts/bootstrap.sh first" "${EXIT_PREREQUISITE}"
}

load_env() {
  set -a
  # shellcheck source=/dev/null
  . "${ENV_FILE}"
  set +a

  : "${INVOICESHELF_VERSION:?INVOICESHELF_VERSION is missing in .env}"
  : "${INVOICESHELF_STORAGE:?INVOICESHELF_STORAGE is missing in .env}"
  : "${INVOICESHELF_MODULES:?INVOICESHELF_MODULES is missing in .env}"
  : "${POSTGRES_DATA:?POSTGRES_DATA is missing in .env}"
  : "${INVOICESHELF_HOST_PORT:=8090}"
  : "${COMPOSE_PROJECT_NAME:=invoiceshelf}"
  # BACKUP_DIR in .env is the root; BACKUP_ROOT keeps it before BACKUP_DIR below
  # is reused for the concrete set of this run.
  : "${BACKUP_DIR:=./backups}"
  BACKUP_ROOT="${BACKUP_DIR}"
}

verify_target_version_exists() {
  local status

  status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 \
    "${DOCKERHUB_TAGS_API}/${TARGET_VERSION}")"
  [[ "${status}" == "200" ]] \
    || die "image tag invoiceshelf/invoiceshelf:${TARGET_VERSION} does not exist (HTTP ${status})" "${EXIT_TARGET_REJECTED}"
  log "target version confirmed in the registry: invoiceshelf/invoiceshelf:${TARGET_VERSION}"
}

check_version_jump() {
  local current_major target_major current_minor target_minor

  if [[ "${TARGET_VERSION}" == "${PREVIOUS_VERSION}" ]]; then
    log "target equals the pinned version – no version change, only config re-apply"
    return 0
  fi

  current_major="${PREVIOUS_VERSION%%.*}"
  target_major="${TARGET_VERSION%%.*}"
  current_minor="${PREVIOUS_VERSION%.*}"
  target_minor="${TARGET_VERSION%.*}"

  if [[ "${target_major}" != "${SUPPORTED_MAJOR}" ]]; then
    die "target major ${target_major} is not supported by this stack. The 2.x line is the stable one (security patches until 2027-09-01); 3.x is an alpha preview and must not be used with production data" "${EXIT_TARGET_REJECTED}"
  fi

  if [[ "${current_major}" != "${target_major}" ]]; then
    die "jump ${PREVIOUS_VERSION} -> ${TARGET_VERSION} crosses a major version – that is a manual migration, not a tag swap" "${EXIT_TARGET_REJECTED}"
  fi

  if [[ "${current_minor}" == "${target_minor}" ]]; then
    log "patch jump ${PREVIOUS_VERSION} -> ${TARGET_VERSION} (low risk)"
    return 0
  fi

  warn "minor jump ${PREVIOUS_VERSION} -> ${TARGET_VERSION}"
  warn "this is a migration, not a tag swap: read the release notes at"
  warn "https://github.com/InvoiceShelf/InvoiceShelf/releases/tag/${TARGET_VERSION}"
  warn "the only way back is the backup this run is about to create (no DB downgrade)"
  if [[ "${ASSUME_YES}" != "true" ]]; then
    read -r -p "continue? [no/yes] " answer
    if [[ "${answer}" != "yes" ]]; then
      log "aborted by the user – stack left untouched"
      exit 0
    fi
  fi
}

record_current_images() {
  local container

  for container in "${COMPOSE_PROJECT_NAME}" "${COMPOSE_PROJECT_NAME}-db"; do
    docker inspect -f '{{.Name}} -> {{.Config.Image}}' "${container}" 2>/dev/null \
      || warn "container ${container} is not running – its image tag cannot be recorded"
  done
}

create_database_dump() {
  local dump_file="${BACKUP_DIR}/db.sql.gz"
  local size marker

  log "creating the database dump (the stack is still running)"
  compose exec -T db pg_dump -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" | gzip > "${dump_file}" \
    || die "pg_dump failed – nothing was changed" "${EXIT_BACKUP_FAILED}"

  gzip -t "${dump_file}" || die "dump archive is corrupted" "${EXIT_BACKUP_FAILED}"

  # Measure the uncompressed content: a gzip stream of a tiny dump is only a few
  # hundred bytes, so the compressed size says nothing about the dump's content.
  size="$(zcat "${dump_file}" | wc -c)"
  (( size > MINIMUM_DUMP_BYTES )) \
    || die "dump is implausibly small at ${size} bytes uncompressed" "${EXIT_BACKUP_FAILED}"

  marker="$(zcat "${dump_file}" | head -20 | grep -c 'PostgreSQL database dump' || true)"
  (( marker > 0 )) \
    || die "dump has no PostgreSQL header (content marker missing)" "${EXIT_BACKUP_FAILED}"

  log "dump verified: ${dump_file} (${size} bytes)"
}

backup_data_directories() {
  local archive="${BACKUP_DIR}/data.tar.gz"
  local path rc=0
  local -a existing=()

  for path in "${INVOICESHELF_STORAGE}" "${INVOICESHELF_MODULES}"; do
    if [[ -e "${path}" ]]; then
      existing+=("${path}")
    else
      warn "path is missing and will be skipped: ${path}"
    fi
  done

  (( ${#existing[@]} > 0 )) || die "no backup paths exist" "${EXIT_BACKUP_FAILED}"
  # The stack keeps running; "file changed as we read it" (tar exit 1) is
  # expected and not a failure. The database dump is the authoritative part.
  tar -czf "${archive}" -C "${APP_DIR}" --warning=no-file-changed "${existing[@]}" \
    2>/dev/null || rc=$?
  if (( rc != 0 && rc != 1 )); then
    die "data archive failed (tar exit ${rc})" "${EXIT_BACKUP_FAILED}"
  fi
  (( rc == 1 )) && warn "tar reported files that changed while being read (normal on a running stack)"

  gzip -t "${archive}" || die "data archive is corrupted" "${EXIT_BACKUP_FAILED}"
  log "data archived: ${archive} ($(stat -c %s "${archive}") bytes)"
}

prepare_backup_directory() {
  BACKUP_DIR="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "${BACKUP_DIR}"

  record_current_images > "${BACKUP_DIR}/images.txt"
  cp "${ENV_FILE}" "${BACKUP_DIR}/env.backup"
  chmod 600 "${BACKUP_DIR}/env.backup"
  log "backup directory: ${BACKUP_DIR}"
}

bump_version_in_env() {
  sed -i "s|^INVOICESHELF_VERSION=.*|INVOICESHELF_VERSION=${TARGET_VERSION}|" "${ENV_FILE}" \
    || die "could not write INVOICESHELF_VERSION to .env" "${EXIT_TARGET_REJECTED}"
}

validate_compose() {
  compose config >/dev/null \
    || die "docker compose config failed after the version bump (syntax or missing variable)" "${EXIT_TARGET_REJECTED}"
}

assert_resolved_image() {
  local resolved

  compose config 2>/dev/null | grep -E '^[[:space:]]+image:' > "${BACKUP_DIR}/images-resolved.txt" || true
  resolved="$(grep -oE 'invoiceshelf/invoiceshelf:[^[:space:]]+' "${BACKUP_DIR}/images-resolved.txt" | head -1)"

  [[ -n "${resolved}" ]] || die "the resolved Compose file names no InvoiceShelf image" "${EXIT_TARGET_REJECTED}"
  [[ "${resolved}" == "invoiceshelf/invoiceshelf:${TARGET_VERSION}" ]] \
    || die "the active Compose file would start '${resolved}' instead of '${TARGET_VERSION}' – not started" "${EXIT_TARGET_REJECTED}"
  log "resolved configuration confirmed: ${resolved}"
}

start_stack() {
  log "pulling images"
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
    sleep 5
    waited=$(( waited + 5 ))
  done

  compose logs --tail 60 >&2 || true
  die "InvoiceShelf did not answer within ${HEALTH_TIMEOUT_S}s – consider the rollback below" "${EXIT_NOT_READY}"
}

run_migrations() {
  # The image does not migrate on boot (AUTORUN_LARAVEL_MIGRATION=false in the
  # vendor's Compose files), and the in-app updater is disabled in containers.
  # Without this step the new code runs against the old schema.
  log "running the database migrations"
  compose exec -T invoiceshelf php artisan migrate --force \
    || die "the database migrations failed – check 'docker compose logs invoiceshelf'" "${EXIT_NOT_READY}"
  log "migrations finished"
}

verify_upgrade() {
  compose ps
  log "running images:"
  # Which image really starts was already asserted against the resolved Compose
  # file in assert_resolved_image – a fresh inspect here would only repeat it.
  docker inspect -f '  {{.Name}} -> {{.Config.Image}}' \
    "${COMPOSE_PROJECT_NAME:-invoiceshelf}" 2>/dev/null || true
}

show_rollback_instructions() {
  cat <<ROLLBACK

=== Upgrade to ${TARGET_VERSION} finished ===
backup: ${BACKUP_DIR}

Way back (only needed if the new version misbehaves):
resetting INVOICESHELF_VERSION alone is NOT enough – the new version migrated the
database schema, and an older InvoiceShelf cannot read it. Therefore:

  1) cd ${APP_DIR} && docker compose down
  2) sed -i 's/^INVOICESHELF_VERSION=.*/INVOICESHELF_VERSION=${PREVIOUS_VERSION}/' .env
  3) docker compose up -d db
  4) Drop and recreate the database, then import the dump:
       docker compose exec -T db psql -U ${POSTGRES_USER} -d postgres \\
         -c 'DROP DATABASE IF EXISTS "${POSTGRES_DB}";' \\
         -c 'CREATE DATABASE "${POSTGRES_DB}" OWNER "${POSTGRES_USER}";'
       gunzip -c ${BACKUP_DIR}/db.sql.gz | \\
         docker compose exec -T db psql -U ${POSTGRES_USER} -d ${POSTGRES_DB}
  5) tar -xzf ${BACKUP_DIR}/data.tar.gz -C ${APP_DIR}
  6) docker compose up -d

Step 5 restores storage/ and Modules/ as they were before the upgrade. The .env
of that moment is in ${BACKUP_DIR}/env.backup.
ROLLBACK
}

main() {
  parse_arguments "$@"
  trap on_error ERR

  cd "${APP_DIR}"
  check_prerequisites
  load_env
  PREVIOUS_VERSION="${INVOICESHELF_VERSION}"
  log "pinned version: ${PREVIOUS_VERSION} -> target version: ${TARGET_VERSION}"

  verify_target_version_exists
  check_version_jump
  prepare_backup_directory
  create_database_dump
  backup_data_directories
  bump_version_in_env
  validate_compose
  assert_resolved_image
  start_stack
  wait_for_service
  run_migrations
  verify_upgrade
  show_rollback_instructions
}

main "$@"
