#!/usr/bin/env bash
# =============================================================================
# backup.sh – SearXNG backup
# =============================================================================
# SearXNG has no database. Its state is the configuration directory mounted at
# /etc/searxng:
#   * settings.yml  – engines, UI, server settings, secret_key if set there
#   * limiter.toml  – bot protection rules
#   * favicons.toml – favicon resolver configuration
# The project documentation names exactly these two mounts as the ones to keep:
# /etc/searxng (configuration) and /var/cache/searxng (persistent data).
#
# What is deliberately NOT in the set:
#   * /var/cache/searxng – faviconcache.db and similar caches. Rebuilt on the
#     next request; not worth restoring.
#   * Valkey – rate-limit counters and cache. Losing it costs a few seconds of
#     limiter state, nothing more.
# The container does not need to be stopped: SearXNG only writes settings.yml
# when an administrator changes something, not continuously.
#
# https://docs.searxng.org/admin/installation-docker.html#volumes
#
# Usage:   ./scripts/backup.sh [--keep-days N]
# Needs:   docker with the compose plugin (v2), tar, gzip, GNU stat/find
# Writes:  ${BACKUP_DIR}/<timestamp>/{config.tar.gz,env.backup,...}
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

usage() {
  cat <<'USAGE'
backup.sh – SearXNG backup (configuration directory)

  ./scripts/backup.sh [--keep-days N]

  --keep-days N   delete backup sets older than N days (default: BACKUP_KEEP_DAYS)

Captures the configuration mount (/etc/searxng): settings.yml, limiter.toml and
favicons.toml. The cache mount and the Valkey instance are not state worth
restoring and are left out. The container keeps running – no downtime.
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
  SEARXNG_VERSION="$(env_value "${ENV_FILE}" SEARXNG_VERSION)"
  SEARXNG_CONFIG="$(env_value "${ENV_FILE}" SEARXNG_CONFIG)"
  SEARXNG_BASE_URL="$(env_value "${ENV_FILE}" SEARXNG_BASE_URL)"
  BACKUP_ROOT="$(env_value "${ENV_FILE}" BACKUP_DIR)"
  BACKUP_KEEP_DAYS="$(env_value "${ENV_FILE}" BACKUP_KEEP_DAYS)"

  : "${SEARXNG_CONFIG:=./data/searxng/config}"
  : "${BACKUP_ROOT:=./backups}"
  : "${BACKUP_KEEP_DAYS:=7}"
  : "${KEEP_DAYS:=${BACKUP_KEEP_DAYS}}"

  [[ -d "${SEARXNG_CONFIG}" ]] \
    || die "config directory ${SEARXNG_CONFIG} does not exist – SearXNG keeps settings.yml, limiter.toml and favicons.toml there" \
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
SearXNG backup
created:            $(date -Is)
version:            ${SEARXNG_VERSION:-unknown}
base URL:           ${SEARXNG_BASE_URL:-unknown}
config directory:   ${SEARXNG_CONFIG}  (settings.yml, limiter.toml, favicons.toml)
not included:       the cache mount (faviconcache.db – rebuilt on demand) and the
                    Valkey data (rate-limit counters and cache – not state)
procedure:          copy the configuration directory, container keeps running
restore:            see the RESTORE section of scripts/backup.sh output
MANIFEST
}

create_config_archive() {
  local archive="${BACKUP_DIR}/config.tar.gz"
  local entries

  log "archiving ${SEARXNG_CONFIG}"
  tar -czf "${archive}" -C "${APP_DIR}" "${SEARXNG_CONFIG}" \
    || die "archiving the configuration failed" "${EXIT_BACKUP_FAILED}"
  gzip -t "${archive}" || die "configuration archive is corrupted" "${EXIT_VERIFY_FAILED}"

  entries="$(tar -tzf "${archive}" | wc -l)"
  (( entries > 0 )) || die "configuration archive contains no entries" "${EXIT_VERIFY_FAILED}"

  # A missing settings.yml is not an error: the instance can run purely on the
  # SEARXNG_* environment variables. But then engine and UI customisations are
  # not in this set either, and the operator should know that.
  if tar -tzf "${archive}" | grep -q 'settings\.yml$'; then
    log "settings.yml is part of the archive"
  else
    warn "no settings.yml in the archive – the instance is configured by environment variables only;"
    warn "engine/UI customisations would be lost, the secret and base URL come from .env"
  fi
  log "configuration archive verified (${entries} entries, $(stat -c %s "${archive}") bytes)"
}

verify_backup() {
  local missing=0 file

  for file in config.tar.gz env.backup MANIFEST.txt; do
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
  2) tar -xzf ${BACKUP_DIR}/config.tar.gz -C ${APP_DIR}
  3) docker compose up -d

The archive restores the whole configuration directory. The cache and the
Valkey data rebuild themselves; nothing else is needed. If the set contains no
settings.yml, the instance was configured purely through .env – restoring that
file plus a fresh start reproduces it.

A backup on the same disk is not a backup – copy ${BACKUP_ROOT} to other storage.
RESTORE
}

main() {
  parse_arguments "$@"
  trap on_error ERR

  cd "${APP_DIR}"
  check_prerequisites
  load_env
  log "backing up SearXNG configuration"

  prepare_backup_set
  create_config_archive
  verify_backup
  prune_old_backups
  show_restore_instructions
}

main "$@"
