#!/usr/bin/env bash
# =============================================================================
# backup.sh – Stirling-PDF backup
# =============================================================================
# Stirling-PDF keeps its state in /configs:
#   * settings.yml and custom_settings.yml (the configuration)
#   * the built-in database (users, accounts, saved settings)
#   * the TLS/keystore material
# The project documentation therefore says about the configs mount: "always
# mount this". Custom pipelines and uploaded custom files are separate.
#
# The built-in database is written by the running process, so the container is
# stopped for the copy – the only way to get a consistent snapshot without the
# project offering an export command. Downtime is a few seconds.
#
# https://docs.stirlingpdf.com/Advanced%20Configuration/How%20to%20use%20the%20configs%20directory
#
# Usage:   ./scripts/backup.sh [--keep-days N]
# Needs:   docker with the compose plugin (v2), tar, gzip, GNU stat/find
# Writes:  ${BACKUP_DIR}/<timestamp>/{state.tar.gz,env.backup,...}
#
# Exit codes:
#   0  backup complete and verified
#   2  usage error
#   3  prerequisite missing (.env, docker, daemon)
#   5  a backup step failed
#   6  verification of the backup failed
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
APP_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly APP_DIR

readonly ENV_FILE="${APP_DIR}/.env"
readonly COMPOSE_FILE="${APP_DIR}/docker-compose.yaml"

readonly EXIT_USAGE=2
readonly EXIT_PREREQUISITE=3
readonly EXIT_BACKUP_FAILED=5
readonly EXIT_VERIFY_FAILED=6

KEEP_DAYS=""
BACKUP_ROOT=""
BACKUP_DIR=""
STACK_STOPPED="false"

usage() {
  cat <<'USAGE'
backup.sh – Stirling-PDF backup (configuration, built-in database, custom files)

  ./scripts/backup.sh [--keep-days N]

  --keep-days N   delete backup sets older than N days (default: BACKUP_KEEP_DAYS)

The container is stopped for the copy because the built-in database is written
by the running process. It is started again immediately afterwards – also when
the backup fails.
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
  if [[ "${STACK_STOPPED}" == "true" ]]; then
    warn "backup failed while the service was stopped – starting it again"
    compose up -d || warn "could not start the service – run: docker compose up -d"
  fi
  if [[ -n "${BACKUP_DIR}" && -d "${BACKUP_DIR}" ]]; then
    printf 'incomplete backup kept for inspection: %s\n' "${BACKUP_DIR}" >&2
  fi
  exit "${exit_code}"
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

parse_arguments() {
  local argument

  while (( $# > 0 )); do
    argument="$1"
    case "${argument}" in
      -h|--help) usage; exit 0 ;;
      --keep-days)
        [[ -n "${2:-}" ]] || die "--keep-days needs a number" "${EXIT_USAGE}"
        KEEP_DAYS="$2"
        shift
        ;;
      --keep-days=*) KEEP_DAYS="${argument#*=}" ;;
      *) usage; die "unknown option: ${argument}" "${EXIT_USAGE}" ;;
    esac
    shift
  done

  if [[ -n "${KEEP_DAYS}" && ! "${KEEP_DAYS}" =~ ^[0-9]+$ ]]; then
    die "--keep-days expects a whole number" "${EXIT_USAGE}"
  fi
}

check_prerequisites() {
  command -v docker >/dev/null 2>&1 || die "command 'docker' not found" "${EXIT_PREREQUISITE}"
  docker compose version >/dev/null 2>&1 \
    || die "docker compose (plugin v2) is not available" "${EXIT_PREREQUISITE}"
  docker info >/dev/null 2>&1 || die "docker daemon is not reachable" "${EXIT_PREREQUISITE}"
  [[ -f "${ENV_FILE}" ]] || die ".env is missing – copy env-dist and fill it in" "${EXIT_PREREQUISITE}"
}

load_env() {
  extraConfigs="$(env_value "${ENV_FILE}" extraConfigs)"
  customFiles="$(env_value "${ENV_FILE}" customFiles)"
  pipeline="$(env_value "${ENV_FILE}" pipeline)"
  BACKUP_ROOT="$(env_value "${ENV_FILE}" BACKUP_DIR)"
  BACKUP_KEEP_DAYS="$(env_value "${ENV_FILE}" BACKUP_KEEP_DAYS)"

  : "${extraConfigs:=./data/configs}"
  : "${customFiles:=./data/customFiles}"
  : "${pipeline:=./data/pipeline}"
  : "${BACKUP_ROOT:=./backups}"
  : "${BACKUP_KEEP_DAYS:=7}"
  : "${KEEP_DAYS:=${BACKUP_KEEP_DAYS}}"

  [[ -d "${extraConfigs}" ]] \
    || die "config directory ${extraConfigs} does not exist – Stirling-PDF stores its settings, database and keys there" \
        "${EXIT_PREREQUISITE}"
}

prepare_backup_set() {
  BACKUP_DIR="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "${BACKUP_DIR}"
  log "backup set: ${BACKUP_DIR}"

  compose config 2>/dev/null | grep -E '^[[:space:]]+image:' > "${BACKUP_DIR}/images.txt" || true
  cp "${ENV_FILE}" "${BACKUP_DIR}/env.backup"
  chmod 600 "${BACKUP_DIR}/env.backup"

  cat > "${BACKUP_DIR}/MANIFEST.txt" <<MANIFEST
Stirling-PDF backup
created:            $(date -Is)
config directory:   ${extraConfigs}  (settings.yml, keys, built-in database)
custom files:       ${customFiles}
pipeline directory: ${pipeline}
not included:       logs/ and tessdata/trainingData – logs are disposable and the
                    OCR language data can be fetched again
procedure:          stop the container, archive the directories, start it again
restore:            see the RESTORE section of scripts/backup.sh output
MANIFEST
}

stop_stack() {
  log "stopping the container – the built-in database needs a consistent copy"
  compose stop || die "could not stop the stack" "${EXIT_BACKUP_FAILED}"
  STACK_STOPPED="true"
}

start_stack() {
  log "starting the container again"
  compose up -d || die "could not start the stack again" "${EXIT_BACKUP_FAILED}"
  STACK_STOPPED="false"
}

create_state_archive() {
  local archive="${BACKUP_DIR}/state.tar.gz"
  local path entries
  local -a existing=()

  for path in "${extraConfigs}" "${customFiles}" "${pipeline}"; do
    if [[ -e "${path}" ]]; then
      existing+=("${path}")
    else
      warn "path is missing, skipped: ${path}"
    fi
  done
  (( ${#existing[@]} > 0 )) || die "no state paths exist – check the paths in .env" \
                                 "${EXIT_BACKUP_FAILED}"

  log "archiving ${#existing[@]} path(s)"
  tar -czf "${archive}" -C "${APP_DIR}" "${existing[@]}" \
    || die "archiving the state failed" "${EXIT_BACKUP_FAILED}"
  gzip -t "${archive}" || die "state archive is corrupted" "${EXIT_VERIFY_FAILED}"

  entries="$(tar -tzf "${archive}" | wc -l)"
  (( entries > 0 )) || die "state archive contains no entries" "${EXIT_VERIFY_FAILED}"

  if tar -tzf "${archive}" | grep -q 'settings.yml'; then
    log "settings.yml is part of the archive"
  else
    warn "no settings.yml in the archive – the instance may still be on defaults"
  fi
  log "state archive verified (${entries} entries, $(stat -c %s "${archive}") bytes)"
}

verify_backup() {
  local missing=0 file

  for file in state.tar.gz env.backup MANIFEST.txt; do
    [[ -s "${BACKUP_DIR}/${file}" ]] || { warn "missing or empty: ${file}"; missing=$(( missing + 1 )); }
  done
  (( missing == 0 )) || die "${missing} expected file(s) are missing" "${EXIT_VERIFY_FAILED}"
  log "backup set verified: $(du -sh "${BACKUP_DIR}" | cut -f1) in ${BACKUP_DIR}"
}

prune_old_backups() {
  local removed=0 candidate age_days

  [[ -d "${BACKUP_ROOT}" ]] || return 0
  while IFS= read -r candidate; do
    [[ -n "${candidate}" ]] || continue
    age_days=$(( ( $(date +%s) - $(stat -c %Y "${candidate}") ) / 86400 ))
    if (( age_days > KEEP_DAYS )); then
      rm -rf "${candidate}"
      removed=$(( removed + 1 ))
      log "pruned $(basename "${candidate}") (${age_days} days old)"
    fi
  done < <(find "${BACKUP_ROOT}" -mindepth 1 -maxdepth 1 -type d \
             -name '[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]')

  log "retention: ${KEEP_DAYS} days, ${removed} set(s) pruned"
}

show_restore_instructions() {
  cat <<RESTORE

=== Backup finished ===
set:   ${BACKUP_DIR}
size:  $(du -sh "${BACKUP_DIR}" | cut -f1)

Restore:
  1) cd ${APP_DIR} && docker compose down
  2) tar -xzf ${BACKUP_DIR}/state.tar.gz -C ${APP_DIR}
  3) docker compose up -d
  4) rm -rf ${BACKUP_DIR}   # after a successful start, if you like

The archive replaces the whole ${extraConfigs} directory, so accounts, saved
settings and the keystore come back together. If you only need the settings,
settings.yml inside the archive is enough.

A backup on the same disk is not a backup – copy ${BACKUP_ROOT} to other storage.
RESTORE
}

main() {
  parse_arguments "$@"
  trap on_error ERR

  cd "${APP_DIR}"
  check_prerequisites
  load_env
  log "backing up Stirling-PDF state"

  prepare_backup_set
  stop_stack
  create_state_archive
  start_stack
  verify_backup
  prune_old_backups
  show_restore_instructions
}

main "$@"
