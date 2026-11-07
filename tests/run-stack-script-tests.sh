#!/usr/bin/env bash
# =============================================================================
# run-stack-script-tests.sh – exercise the stack scripts against fake binaries
# =============================================================================
# Builds a sandbox copy of each app, puts stub docker/curl/openssl first in
# PATH and then drives the real scripts through their argument handling, their
# prerequisite checks and a complete upgrade run — including an injected abort.
# Nothing here touches a real Docker daemon, and the repository is only read.
#
# Usage: ./tests/run-stack-script-tests.sh
#
# What it verifies per app: --help/exit codes, missing env file, unknown option,
# the full upgrade run (backup files, version pin in the env file, resolved
# image), non-interactive abort without --yes, and bootstrap idempotence.
# =============================================================================
set -uo pipefail

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly TESTS_DIR
REPO_ROOT="$(cd -- "${TESTS_DIR}/.." && pwd)"
readonly REPO_ROOT
readonly REPO_APPS="${REPO_ROOT}/apps"
# The sandbox lives outside the repository so a test run never litters it.
readonly SANDBOX="${TMPDIR:-/tmp}/docker-compose-script-tests"
readonly STUB_BIN="${TESTS_DIR}/stub-bin"
# Optional stubs, only put on PATH by the tests that need them.
readonly OPTIONAL_STUB_BIN="${TESTS_DIR}/stub-bin-optional"

PASS=0
FAIL=0
FAILED_NAMES=()

check() {
  local name="$1" expected="$2" actual="$3"

  if [[ "${expected}" == "${actual}" ]]; then
    PASS=$(( PASS + 1 ))
    printf '  OK    %s\n' "${name}"
  else
    FAIL=$(( FAIL + 1 ))
    FAILED_NAMES+=("${name}")
    printf '  FAIL  %s (expected %s, got %s)\n' "${name}" "${expected}" "${actual}"
  fi
}

check_contains() {
  local name="$1" needle="$2" haystack="$3"

  if grep -qF -- "${needle}" <<< "${haystack}"; then
    PASS=$(( PASS + 1 ))
    printf '  OK    %s\n' "${name}"
  else
    FAIL=$(( FAIL + 1 ))
    FAILED_NAMES+=("${name}")
    printf '  FAIL  %s (missing: %s)\n' "${name}" "${needle}"
  fi
}

env_file_for() {
  case "$1" in
    paperless-ngx) printf 'docker-compose.env' ;;
    *)             printf '.env' ;;
  esac
}

# Build a writable copy of one app with a real env file and real data dirs.
build_sandbox() {
  local app="$1" target="${SANDBOX}/$1" env_name

  rm -rf "${target}"
  mkdir -p "${target}"
  cp -a "${REPO_APPS}/${app}/." "${target}/"
  chmod +x "${target}/scripts/"*.sh

  env_name="$(env_file_for "${app}")"
  cp "${target}/env-dist" "${target}/${env_name}"
  chmod 600 "${target}/${env_name}"

  # Point the host-path variables at the sandbox and plant data to back up.
  local -a host_path_vars
  case "${app}" in
    nextcloud-postgres-redis-apache)
      host_path_vars=(NEXTCLOUD_DATA NEXTCLOUD_APP_DATA NEXTCLOUD_CONFIG POSTGRES_DATA)
      sed -i "s|^NEXTCLOUD_DATA=.*|NEXTCLOUD_DATA=${target}/data/nextcloud-data|" "${target}/${env_name}" ;;
    mealie)
      host_path_vars=(MEALIE_DATA POSTGRES_DATA) ;;
    ntfy)
      host_path_vars=(NTFY_CACHE_DIR NTFY_CONFIG_DIR POSTGRES_DATA_DIR) ;;
    paperless-ngx)
      host_path_vars=(PAPERLESS_DATA_DIR PAPERLESS_MEDIA_DIR PAPERLESS_CONSUMPTION_DIR PAPERLESS_EXPORT_DIR POSTGRES_DATA_DIR REDIS_DATA_DIR) ;;
    vaultwarden)
      host_path_vars=(DATA) ;;
    vikunja)
      host_path_vars=(VIKUNJA_FILES POSTGRES_DATA) ;;
    stirling-pdf)
      host_path_vars=(extraConfigs customFiles pipeline logs tessdata_trainingData) ;;
    searxng)
      host_path_vars=(SEARXNG_CONFIG SEARXNG_DATA VALKEY_DATA) ;;
    forgejo)
      host_path_vars=(FORGEJO_DATA POSTGRES_DATA) ;;
    open-notebook)
      host_path_vars=(SURREAL_DATA NOTEBOOK_DATA) ;;
    leantime)
      host_path_vars=(MARIADB_DATA LEAN_USERFILES LEAN_PUBLIC_USERFILES LEAN_PLUGINS LEAN_LOGS) ;;
    *) host_path_vars=() ;;
  esac

  local variable value
  for variable in "${host_path_vars[@]}"; do
    value="$(grep -E "^${variable}=" "${target}/${env_name}" | head -1 | cut -d= -f2-)"
    value="${value%\"}"; value="${value#\"}"
    [[ -n "${value}" ]] || continue
    local resolved="${target}/${value#./}"
    mkdir -p "${resolved}"
    printf 'payload for %s\n' "${variable}" > "${resolved}/${variable}.marker"
    sed -i "s|^${variable}=.*|${variable}=${resolved}|" "${target}/${env_name}"
  done

  # Seeds that a realistic backup needs: a SQLite database with its magic bytes
  # and an attachments directory for vaultwarden, a settings file for
  # Stirling-PDF, and a file for the vikunja dump target.
  case "${app}" in
    vaultwarden)
      printf 'SQLite format 3\0fake-database-payload' > "${target}/data/vaultwarden/db.sqlite3"
      mkdir -p "${target}/data/vaultwarden/attachments"
      printf 'attachment payload\n' > "${target}/data/vaultwarden/attachments/file.txt"
      ;;
    stirling-pdf)
      printf 'security:\n  enableLogin: false\n' > "${target}/data/configs/settings.yml"
      ;;
    searxng)
      printf 'use_default_settings: true\nserver:\n  secret_key: "test-only"\n' \
        > "${target}/data/searxng/config/settings.yml"
      ;;
    vikunja)
      printf 'uploaded file payload\n' > "${target}/data/vikunja-files/attachment.bin"
      ;;
  esac

  # The scripts insist on a non-placeholder database password.
  sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=test-only-password|" "${target}/${env_name}"
  sed -i "s|^PAPERLESS_SECRET_KEY=.*|PAPERLESS_SECRET_KEY=test-only-secret|" "${target}/${env_name}" 2>/dev/null
  sed -i "s|^ADMIN_TOKEN=.*|ADMIN_TOKEN='\$argon2id\$test'|" "${target}/${env_name}" 2>/dev/null
  sed -i "s|^COLLABORA_ADMIN_PASSWORD=.*|COLLABORA_ADMIN_PASSWORD=test-only|" "${target}/${env_name}" 2>/dev/null
  sed -i "s|^REDIS_PASSWORD=.*|REDIS_PASSWORD=test-only|" "${target}/${env_name}" 2>/dev/null
  sed -i "s|^SEARXNG_SECRET=.*|SEARXNG_SECRET=test-only-secret|" "${target}/${env_name}" 2>/dev/null
  # Leantime uses MariaDB credential names and its own session key.
  sed -i "s|^MYSQL_ROOT_PASSWORD=.*|MYSQL_ROOT_PASSWORD=test-only-root-password|" "${target}/${env_name}" 2>/dev/null
  sed -i "s|^MYSQL_PASSWORD=.*|MYSQL_PASSWORD=test-only-password|" "${target}/${env_name}" 2>/dev/null
  sed -i "s|^LEAN_SESSION_PASSWORD=.*|LEAN_SESSION_PASSWORD=test-only-session|" "${target}/${env_name}" 2>/dev/null

  printf '%s\n' "${target}"
}

read_env_value() {
  local file="$1" key="$2"
  grep -E "^${key}=" "${file}" | head -1 | cut -d= -f2-
}

# Run a script with the stubs in front of PATH.
run_script() {
  local script="$1"
  shift
  PATH="${STUB_BIN}:${PATH}" "${script}" "$@"
}

test_upgrade_script() {
  local app="$1" script="$2" target_version="$3" env_name="$4"
  local target env_file output code

  echo "--- ${app}/scripts/upgrade.sh"
  target="$(build_sandbox "${app}")"
  env_file="${target}/${env_name}"

  output="$(run_script "${target}/scripts/upgrade.sh" --help 2>&1)"; code=$?
  check "${app}: --help exits 0" "0" "${code}"
  check_contains "${app}: --help prints usage" "target-version" "${output}"

  output="$(run_script "${target}/scripts/upgrade.sh" 2>&1)"; code=$?
  check "${app}: no argument exits 2" "2" "${code}"

  output="$(run_script "${target}/scripts/upgrade.sh" --nope 2>&1)"; code=$?
  check "${app}: unknown option exits 2" "2" "${code}"

  output="$(run_script "${target}/scripts/upgrade.sh" "${target_version}" --yes 2>&1)"; code=$?
  check "${app}: upgrade run exits 0" "0" "${code}"

  check "${app}: target version written to ${env_name}" "${target_version}" \
        "$(read_env_value "${env_file}" "$(version_key "${app}")")"

  local backup_dir
  backup_dir="$(find "${target}/backups" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)"
  if [[ -n "${backup_dir}" ]]; then
    check "${app}: backup directory created" "0" "$( [[ -d "${backup_dir}" ]] && echo 0 || echo 1 )"
    check "${app}: env file backed up" "0" "$( [[ -f "${backup_dir}/env.backup" ]] && echo 0 || echo 1 )"
    # The archive name differs per app (data.tar.gz, state.tar.gz, dump archive…).
    check "${app}: backup archive created" "0" \
          "$( [[ -s "${backup_dir}/$(backup_archive_for "${app}")" ]] && echo 0 || echo 1 )"
    check "${app}: resolved image recorded" "0" "$( [[ -f "${backup_dir}/images-resolved.txt" ]] && echo 0 || echo 1 )"
    check_contains "${app}: resolved image matches the target" "${target_version}" \
          "$(cat "${backup_dir}/images-resolved.txt" 2>/dev/null)"
  else
    check "${app}: backup directory created" "0" "1"
  fi

  case "${app}" in
    nextcloud-postgres-redis-apache)
      check_contains "${app}: occ upgrade was run" "'occ upgrade' finished" "${output}"
      check_contains "${app}: occ status verified" "reports the instance as installed" "${output}"
      ;;
    vaultwarden)
      check_contains "${app}: stop before copying" "stopping the stack" "${output}"
      ;;
    forgejo)
      # The upgrade runs backup.sh and captures its output; on success only the
      # summary line reaches stdout. The dump-specific text stays inside the
      # backup run (covered by test_backup_script).
      check_contains "${app}: backup completed" "backup complete" "${output}"
      check_contains "${app}: resolved configuration confirmed" "resolved configuration confirmed" "${output}"
      check_contains "${app}: health check passed" "Forgejo is answering" "${output}"
      ;;
    open-notebook)
      check_contains "${app}: backup completed" "backup complete" "${output}"
      check_contains "${app}: resolved configuration confirmed" "resolved configuration confirmed" "${output}"
      check_contains "${app}: health check passed" "the API answers on /health" "${output}"
      ;;
    leantime)
      # The upgrade runs backup.sh and captures its output; on success only the
      # summary line reaches stdout. The dump-specific text stays inside the
      # backup run (covered by test_backup_script).
      check_contains "${app}: backup completed" "backup complete" "${output}"
      check_contains "${app}: resolved configuration confirmed" "resolved configuration confirmed" "${output}"
      check_contains "${app}: health check passed" "Leantime is answering" "${output}"
      check_contains "${app}: migrations were run" "running the database migrations" "${output}"
      ;;
    *)
      check_contains "${app}: database dump verified" "dump verified" "${output}"
      ;;
  esac

  # Missing env file must be a prerequisite error, not a partial run.
  rm -f "${env_file}"
  output="$(run_script "${target}/scripts/upgrade.sh" "${target_version}" 2>&1)"; code=$?
  check "${app}: missing env file exits 3" "3" "${code}"

  # Without --yes and without a terminal, a risky jump must abort cleanly and
  # leave the pinned version alone. Vaultwarden always asks, the rest only on a
  # major jump.
  if [[ "${app}" == "nextcloud-postgres-redis-apache" || "${app}" == "vaultwarden" ]]; then
    local abort_target abort_env before_version
    abort_target="$(build_sandbox "${app}")"
    abort_env="${abort_target}/${env_name}"
    before_version="$(read_env_value "${abort_env}" "$(version_key "${app}")")"

    output="$(run_script "${abort_target}/scripts/upgrade.sh" "${target_version}" </dev/null 2>&1)"; code=$?
    check "${app}: non-interactive abort exits 0" "0" "${code}"
    check_contains "${app}: abort is reported" "aborted by the user" "${output}"
    check "${app}: abort leaves the version untouched" "${before_version}" \
          "$(read_env_value "${abort_env}" "$(version_key "${app}")")"
    check "${app}: abort creates no backup" "1" \
          "$( [[ -d "${abort_target}/backups" ]] && echo 0 || echo 1 )"
  fi
}

version_key() {
  case "$1" in
    nextcloud-postgres-redis-apache) printf 'NEXTCLOUD_VERSION' ;;
    paperless-ngx)                   printf 'PAPERLESS_VERSION' ;;
    mealie)                          printf 'MEALIE_VERSION' ;;
    ntfy)                            printf 'NTFY_VERSION' ;;
    vaultwarden)                     printf 'VERSION' ;;
    forgejo)                         printf 'FORGEJO_VERSION' ;;
    open-notebook)                   printf 'OPEN_NOTEBOOK_VERSION' ;;
    leantime)                        printf 'LEANTIME_VERSION' ;;
  esac
}

test_bootstrap_script() {
  local app="$1" env_name="$2"
  local target env_file output code before after

  echo "--- ${app}/scripts/bootstrap.sh"
  target="$(build_sandbox "${app}")"
  env_file="${target}/${env_name}"
  rm -f "${env_file}"          # bootstrap must create it

  output="$(run_script "${target}/scripts/bootstrap.sh" --help 2>&1)"; code=$?
  check "${app}: bootstrap --help exits 0" "0" "${code}"

  output="$(run_script "${target}/scripts/bootstrap.sh" --nope 2>&1)"; code=$?
  check "${app}: bootstrap unknown option exits 2" "2" "${code}"

  output="$(run_script "${target}/scripts/bootstrap.sh" 2>&1)"; code=$?
  check "${app}: bootstrap run exits 0" "0" "${code}"
  check "${app}: bootstrap created the env file" "0" "$( [[ -f "${env_file}" ]] && echo 0 || echo 1 )"
  check "${app}: env file is mode 600" "600" "$(stat -c %a "${env_file}" 2>/dev/null)"
  check "${app}: placeholder password replaced" "0" \
        "$( grep -qE '^POSTGRES_PASSWORD=(CHANGEME|your-postgres-password-here)$' "${env_file}" && echo 1 || echo 0 )"

  before="$(md5sum "${env_file}" | cut -d' ' -f1)"
  output="$(run_script "${target}/scripts/bootstrap.sh" 2>&1)"; code=$?
  after="$(md5sum "${env_file}" | cut -d' ' -f1)"
  check "${app}: bootstrap is idempotent" "0" "${code}"
  check "${app}: second run leaves the env file alone" "${before}" "${after}"
}

# The single archive file a backup set is built around, per app. Used by the
# upgrade test, which checks that the backup really produced its main artifact.
backup_archive_for() {
  case "$1" in
    stirling-pdf)   printf 'state.tar.gz' ;;
    searxng)        printf 'config.tar.gz' ;;
    forgejo)        printf 'forgejo-dump.tar.gz' ;;
    open-notebook)  printf 'state.tar.gz' ;;
    *)              printf 'data.tar.gz' ;;
  esac
}

# Files a complete backup set must contain, per app.
expected_backup_files() {
  case "$1" in
    nextcloud-postgres-redis-apache) printf 'db.sql.gz data.tar.gz env.backup MANIFEST.txt images.txt' ;;
    paperless-ngx)                   printf 'db.sql.gz data.tar.gz env.backup MANIFEST.txt images.txt' ;;
    mealie)                          printf 'db.sql.gz data.tar.gz env.backup MANIFEST.txt images.txt' ;;
    ntfy)                            printf 'db.sql.gz env.backup MANIFEST.txt images.txt' ;;
    vaultwarden)                     printf 'db.sqlite3 data.tar.gz env.backup MANIFEST.txt images.txt' ;;
    vikunja)                         printf 'vikunja-dump.zip db.sql.gz env.backup MANIFEST.txt images.txt' ;;
    stirling-pdf)                    printf 'state.tar.gz env.backup MANIFEST.txt images.txt' ;;
    searxng)                         printf 'config.tar.gz env.backup MANIFEST.txt images.txt' ;;
    forgejo)                         printf 'forgejo-dump.tar.gz env.backup MANIFEST.txt images.txt' ;;
    open-notebook)                   printf 'state.tar.gz env.backup MANIFEST.txt images.txt' ;;
    leantime)                        printf 'db.sql.gz data.tar.gz env.backup MANIFEST.txt images.txt' ;;
  esac
}

test_backup_script() {
  local app="$1" env_name="$2"
  local target env_file backup_root backup_set output code file missing

  echo "--- ${app}/scripts/backup.sh"
  target="$(build_sandbox "${app}")"
  env_file="${target}/${env_name}"
  backup_root="${target}/backups"

  output="$(run_script "${target}/scripts/backup.sh" --help 2>&1)"; code=$?
  check "${app}: backup --help exits 0" "0" "${code}"
  check_contains "${app}: backup help documents --keep-days" "--keep-days" "${output}"

  output="$(run_script "${target}/scripts/backup.sh" --nope 2>&1)"; code=$?
  check "${app}: backup unknown option exits 2" "2" "${code}"

  output="$(run_script "${target}/scripts/backup.sh" --keep-days abc 2>&1)"; code=$?
  check "${app}: backup rejects a non-numeric keep-days" "2" "${code}"

  # The real run.
  output="$(run_script "${target}/scripts/backup.sh" 2>&1)"; code=$?
  check "${app}: backup run exits 0" "0" "${code}"

  backup_set="$(find "${backup_root}" -mindepth 1 -maxdepth 1 -type d ! -name '2020*' 2>/dev/null | head -1)"
  if [[ -n "${backup_set}" ]]; then
    check "${app}: backup set directory created" "0" "0"
  else
    check "${app}: backup set directory created" "0" "1"
    return 0
  fi

  missing=0
  for file in $(expected_backup_files "${app}"); do
    [[ -s "${backup_set}/${file}" ]] || missing=$(( missing + 1 ))
  done
  check "${app}: all expected files present" "0" "${missing}"

  # Secrets must not be world-readable.
  check "${app}: env.backup is mode 600" "600" "$(stat -c %a "${backup_set}/env.backup" 2>/dev/null)"

  # The images snapshot must carry the pinned tag, not an empty placeholder.
  check "${app}: images.txt is not empty" "0" \
        "$( [[ -s "${backup_set}/images.txt" ]] && echo 0 || echo 1 )"

  case "${app}" in
    nextcloud-postgres-redis-apache)
      check_contains "${app}: maintenance mode was used" "maintenance mode" "${output}"
      check_contains "${app}: maintenance mode is off afterwards" "maintenance mode is off again" "${output}"
      check_contains "${app}: database dump verified" "database dump verified" "${output}"
      ;;
    paperless-ngx)
      check_contains "${app}: document_exporter was run" "document_exporter" "${output}"
      check_contains "${app}: export verified" "export verified" "${output}"
      check_contains "${app}: consume directory checked" "consume directory" "${output}"
      ;;
    vaultwarden)
      check_contains "${app}: sqlite fallback reported" "falling back to a short stop" "${output}"
      check_contains "${app}: attachments confirmed" "attachments/ is part of the archive" "${output}"
      check_contains "${app}: sqlite header verified" "SQLite header ok" "${output}"
      # The stopped service must be running again.
      check "${app}: service restarted after the copy" "0" \
            "$( grep -q 'service started again' <<< "${output}" && echo 0 || echo 1 )"
      ;;
    vikunja)
      check_contains "${app}: vikunja dump was run" "official dump" "${output}"
      check_contains "${app}: dump signature verified" "ZIP signature ok" "${output}"
      check "${app}: dump is gone from the files directory" "1" \
            "$( [[ -e "${target}/data/vikunja-files/vikunja-dump.zip" ]] && echo 0 || echo 1 )"
      ;;
    stirling-pdf)
      check_contains "${app}: config directory archived" "settings.yml is part of the archive" "${output}"
      check_contains "${app}: container stopped for the copy" "consistent copy" "${output}"
      ;;
    searxng)
      check_contains "${app}: config directory archived" "settings.yml is part of the archive" "${output}"
      check_contains "${app}: archive verified" "configuration archive verified" "${output}"
      # SearXNG has no database – a dump would be a bug in the script.
      check "searxng: no database dump attempted" "1" \
            "$( grep -q 'database dump verified' <<< "${output}" && echo 0 || echo 1 )"
      ;;
    forgejo)
      # The vendor dump packs app.ini and the SQL dump; the script verifies both.
      # Only the server container stops, the database keeps running – so the
      # restart is a `compose start server`, not a full `up -d`.
      check_contains "${app}: dump archive verified" "dump archive verified" "${output}"
      check_contains "${app}: server restarted" "server container started again" "${output}"
      ;;
    open-notebook)
      check_contains "${app}: archive verified" "archive verified" "${output}"
      check_contains "${app}: stack stopped for the copy" "stopping the stack" "${output}"
      check_contains "${app}: stack restarted" "starting the stack again" "${output}"
      ;;
    leantime)
      # Online dump (no stop) plus an archive of the four writable directories.
      check_contains "${app}: database dump verified" "database dump verified" "${output}"
      check_contains "${app}: data archive verified" "data archive verified" "${output}"
      check_contains "${app}: userfiles archived" "userfiles is part of the archive" "${output}"
      ;;
    *)
      check_contains "${app}: database dump verified" "database dump verified" "${output}"
      ;;
  esac

  # Retention: a year-old set must be removed, a fresh one must survive.
  mkdir -p "${backup_root}/20200101-000000"
  printf 'old\n' > "${backup_root}/20200101-000000/old.txt"
  # Backdate the directory itself – the retention check looks at its mtime.
  touch -d '2020-01-01 00:00:00' "${backup_root}/20200101-000000"
  output="$(run_script "${target}/scripts/backup.sh" --keep-days 7 2>&1)"; code=$?
  check "${app}: second run exits 0" "0" "${code}"
  check "${app}: old backup set pruned" "1" \
        "$( [[ -d "${backup_root}/20200101-000000" ]] && echo 0 || echo 1 )"
  check "${app}: fresh backup set kept" "0" \
        "$( [[ -n "$(find "${backup_root}" -mindepth 1 -maxdepth 1 -type d ! -name '2020*' | head -1)" ]] && echo 0 || echo 1 )"

  # A missing env file must stop before anything is touched. This runs last
  # because build_sandbox() rebuilds the same directory, so it would wipe the
  # env file the checks above need.
  local probe_target probe_env
  probe_target="$(build_sandbox "${app}")"
  probe_env="${probe_target}/${env_name}"
  rm -f "${probe_env}"
  output="$(run_script "${probe_target}/scripts/backup.sh" 2>&1)"; code=$?
  check "${app}: backup without env file exits 3" "3" "${code}"
  check "${app}: backup without env file writes nothing" "1" \
        "$( [[ -d "${probe_target}/backups" ]] && echo 0 || echo 1 )"
}

# The default vaultwarden run has no sqlite3, so it exercises the fallback.
# This one puts a sqlite3 stand-in first on PATH and must take the online path.
test_vaultwarden_sqlite_path() {
  local target output code

  echo "--- vaultwarden/scripts/backup.sh (sqlite3 available)"
  target="$(build_sandbox "vaultwarden")"

  output="$(PATH="${OPTIONAL_STUB_BIN}:${STUB_BIN}:${PATH}" "${target}/scripts/backup.sh" 2>&1)"; code=$?
  check "vaultwarden: online backup run exits 0" "0" "${code}"
  check_contains "vaultwarden: sqlite3 route used" "using the online backup API" "${output}"
  check_contains "vaultwarden: integrity_check reported" "integrity_check: ok" "${output}"
  check "vaultwarden: no stop needed with sqlite3" "1" \
        "$( grep -q 'falling back to a short stop' <<< "${output}" && echo 0 || echo 1 )"

  local backup_set
  backup_set="$(find "${target}/backups" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)"
  check "vaultwarden: database copy written" "0" \
        "$( [[ -s "${backup_set}/db.sqlite3" ]] && echo 0 || echo 1 )"
}

main() {
  echo "=== stack script tests ==="
  echo "sandbox: ${SANDBOX}"
  echo

  test_upgrade_script "nextcloud-postgres-redis-apache" "upgrade.sh" "32-apache" ".env"
  test_backup_script "nextcloud-postgres-redis-apache" ".env"
  test_upgrade_script "paperless-ngx" "upgrade.sh" "2.21" "docker-compose.env"
  test_bootstrap_script "paperless-ngx" "docker-compose.env"
  test_backup_script "paperless-ngx" "docker-compose.env"
  test_upgrade_script "mealie" "upgrade.sh" "v3.14.0" ".env"
  test_bootstrap_script "mealie" ".env"
  test_backup_script "mealie" ".env"
  test_upgrade_script "ntfy" "upgrade.sh" "v2.20" ".env"
  test_bootstrap_script "ntfy" ".env"
  test_backup_script "ntfy" ".env"
  test_upgrade_script "vaultwarden" "upgrade.sh" "1.35.0" ".env"
  test_backup_script "vaultwarden" ".env"
  test_vaultwarden_sqlite_path
  test_backup_script "vikunja" ".env"
  test_backup_script "stirling-pdf" ".env"
  test_bootstrap_script "searxng" ".env"
  test_backup_script "searxng" ".env"
  test_upgrade_script "forgejo" "upgrade.sh" "17.0.2" ".env"
  test_bootstrap_script "forgejo" ".env"
  test_backup_script "forgejo" ".env"
  test_upgrade_script "open-notebook" "upgrade.sh" "1.15.2" ".env"
  test_bootstrap_script "open-notebook" ".env"
  test_backup_script "open-notebook" ".env"
  test_upgrade_script "leantime" "upgrade.sh" "3.13.3" ".env"
  test_bootstrap_script "leantime" ".env"
  test_backup_script "leantime" ".env"

  echo
  echo "=== ${PASS} OK, ${FAIL} FAIL ==="
  if (( FAIL > 0 )); then
    printf 'failed: %s\n' "${FAILED_NAMES[*]}"
    exit 1
  fi
}

main "$@"
