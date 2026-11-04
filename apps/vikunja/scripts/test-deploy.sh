#!/usr/bin/env bash
# =============================================================================
# test-deploy.sh – Test matrix for the Vikunja stack (no running Docker daemon)
# =============================================================================
# Covers everything that is provable without Docker: syntax, ShellCheck, the
# Compose structure and its variables, argument handling, the registry check and
# the Docker-free bootstrap functions. The first real start is done by
# scripts/bootstrap.sh on the target host – this script does not replace it.
#
# Usage:  ./scripts/test-deploy.sh [path-to-shellcheck]
# Needs:  bash, python3 with PyYAML, optionally shellcheck, network for block 5
# Writes: a working copy in $TMPDIR, removed afterwards
#
# Exit codes:
#   0  every check passed
#   1  at least one check failed
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
APP_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly APP_DIR

WORK_DIR="$(mktemp -d)"
readonly WORK_DIR
readonly SHELLCHECK_PATH="${1:-$(command -v shellcheck || true)}"
readonly PYTHON_PATH="${PYTHON:-/opt/data/.venv/bin/python}"
readonly COMPOSE_FILE="docker-compose.yaml"
readonly ENV_TEMPLATE="env-dist"

PASSED=0
FAILED=0
SKIPPED=0

pass()    { PASSED=$(( PASSED + 1 )); printf '  OK      %s\n' "$*"; }
skip()    { SKIPPED=$(( SKIPPED + 1 )); printf '  SKIP    %s\n' "$*"; }
failing() { FAILED=$(( FAILED + 1 )); printf '  FAIL    %s\n' "$*"; }

cleanup() { rm -rf "${WORK_DIR}"; }
trap cleanup EXIT

section() { printf '\n== %s\n' "$*"; }

expect_status() {
  local expected="$1" actual="$2" label="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass "${label} (exit ${actual})"
  else
    failing "${label} (expected ${expected}, got ${actual})"
  fi
}

expect_contains() {
  local needle="$1" haystack="$2" label="$3"
  if grep -qF -- "${needle}" <<< "${haystack}"; then
    pass "${label}"
  else
    failing "${label} – '${needle}' is missing"
  fi
}

# ------------------------------------------------------------------ 1. Syntax
test_syntax() {
  local script status

  section "1. Syntax (bash -n)"
  for script in bootstrap.sh upgrade.sh test-deploy.sh; do
    set +e
    bash -n "${SCRIPT_DIR}/${script}"
    status=$?
    set -e
    expect_status 0 "${status}" "bash -n ${script}"
  done
}

# -------------------------------------------------------------- 2. ShellCheck
test_shellcheck() {
  local status

  section "2. ShellCheck (-S style)"
  if [[ -z "${SHELLCHECK_PATH}" || ! -x "${SHELLCHECK_PATH}" ]]; then
    skip "shellcheck not found (pass its path as the first argument)"
    return 0
  fi
  set +e
  "${SHELLCHECK_PATH}" -S style \
    "${SCRIPT_DIR}/bootstrap.sh" "${SCRIPT_DIR}/upgrade.sh" "${SCRIPT_DIR}/test-deploy.sh"
  status=$?
  set -e
  expect_status 0 "${status}" "shellcheck without findings"
}

# ---------------------------------------------------- 3. Compose and variables
test_compose() {
  local status

  section "3. Compose file and variable wiring"
  set +e
  "${PYTHON_PATH}" - "${APP_DIR}" "${COMPOSE_FILE}" "${ENV_TEMPLATE}" <<'PY'
import re, sys, os, yaml

app_dir, compose_name, env_name = sys.argv[1:4]
raw = open(f"{app_dir}/{compose_name}").read()
compose = yaml.safe_load(raw)

problems = []
db = compose["services"]["db"]
vikunja = compose["services"]["vikunja"]

if "PGDATA" in db.get("environment", {}):
    problems.append("PGDATA is overridden – the version-specific image default must stay")
if not any(str(mount).endswith(":/var/lib/postgresql") for mount in db["volumes"]):
    problems.append("Postgres mount does not target /var/lib/postgresql (postgres:18 PGDATA)")
if "healthcheck" in vikunja:
    problems.append("an active healthcheck on vikunja can block the start via depends_on")

for pin in re.findall(r"^\s*image:\s*(\S+)", raw, re.M):
    if "latest" in pin or "unstable" in pin:
        problems.append(f"unpinned image tag: {pin}")
    if "${" not in pin:
        problems.append(f"image tag not driven by a .env variable: {pin}")

used = set(re.findall(r"\$\{([A-Z_][A-Z0-9_]*)", raw))
env_keys = set()
for line in open(f"{app_dir}/{env_name}"):
    line = line.strip()
    if line and not line.startswith("#") and "=" in line:
        env_keys.add(line.split("=", 1)[0])

for name in sorted(used):
    has_default = re.search(r"\$\{%s:-" % name, raw)
    is_required = re.search(r"\$\{%s:\?" % name, raw)
    if name not in env_keys and not has_default and not is_required:
        problems.append(f"{name} is used in the Compose file but defined nowhere")

# Variables that only the scripts read – Compose never sees them. They are still
# checked the other way round: a value here that no script reads is dead weight.
script_only = {"BACKUP_DIR", "BACKUP_KEEP_DAYS"}
script_text = ""
for entry in sorted(os.listdir(f"{app_dir}/scripts")):
    with open(f"{app_dir}/scripts/{entry}") as handle:
        script_text += handle.read()

for name in sorted(env_keys - used):
    if name in script_only:
        if name not in script_text:
            problems.append(f"{name} is defined in {env_name} but no script reads it")
        continue
    problems.append(f"{name} is defined in {env_name} but unused in the Compose file")

print("services:", list(compose["services"]))
print("image lines:", re.findall(r"image: (\S+)", raw))
print("data mounts:", vikunja["volumes"] + db["volumes"])
for problem in problems:
    print("PROBLEM:", problem)
sys.exit(1 if problems else 0)
PY
  status=$?
  set -e
  expect_status 0 "${status}" "Compose structure, pinning and variable wiring"
}

# -------------------------------------------------------- 4. Argument handling
test_arguments() {
  local output status

  section "4. Argument handling"
  set +e
  output="$(bash "${SCRIPT_DIR}/bootstrap.sh" --help 2>&1)"; status=$?
  set -e
  expect_status 0 "${status}" "bootstrap.sh --help"
  expect_contains "set up the Vikunja stack" "${output}" "help text of bootstrap.sh"

  set +e
  output="$(bash "${SCRIPT_DIR}/bootstrap.sh" --bogus 2>&1)"; status=$?
  set -e
  expect_status 2 "${status}" "bootstrap.sh rejects an unknown option"

  set +e
  output="$(bash "${SCRIPT_DIR}/upgrade.sh" 2>&1)"; status=$?
  set -e
  expect_status 2 "${status}" "upgrade.sh without a target version exits 2"

  set +e
  output="$(bash "${SCRIPT_DIR}/upgrade.sh" 2.7 2>&1)"; status=$?
  set -e
  expect_status 2 "${status}" "upgrade.sh rejects an incomplete version"
  expect_contains "X.Y.Z" "${output}" "error names the expected format"

  set +e
  output="$(bash "${SCRIPT_DIR}/upgrade.sh" latest 2>&1)"; status=$?
  set -e
  expect_status 2 "${status}" "upgrade.sh rejects 'latest'"

  set +e
  output="$(bash "${SCRIPT_DIR}/upgrade.sh" "2.7.1-rc1" 2>&1)"; status=$?
  set -e
  expect_status 2 "${status}" "upgrade.sh rejects an RC tag"

  set +e
  output="$(bash "${SCRIPT_DIR}/upgrade.sh" --bogus 2>&1)"; status=$?
  set -e
  expect_status 2 "${status}" "upgrade.sh rejects an unknown option"
}

# ---------------------------------------------------------- 5. Registry check
test_registry_check() {
  local status

  section "5. Target version in the registry (needs network)"
  set +e
  status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
    https://hub.docker.com/v2/repositories/vikunja/vikunja/tags/2.7.1)"
  set -e
  if [[ "${status}" == "000" ]]; then
    skip "no network access to the registry"
    return 0
  fi
  expect_status 200 "${status}" "tag 2.7.1 exists"

  set +e
  status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
    https://hub.docker.com/v2/repositories/vikunja/vikunja/tags/9.9.9)"
  set -e
  expect_status 404 "${status}" "tag 9.9.9 is reported as missing"
}

# ------------------------------------------------ 6. Bootstrap without Docker
test_bootstrap_functions() {
  local output status first_hash second_hash mode

  section "6. bootstrap.sh – Docker-free functions"
  cp -a "${APP_DIR}/." "${WORK_DIR}/"
  rm -f "${WORK_DIR}/.env"

  # --help makes the sourced script return early; the functions stay available
  # in that shell and are then exercised one by one.
  set +e
  output="$(cd "${WORK_DIR}" && bash -c '
    source ./scripts/bootstrap.sh --help >/dev/null
    create_env_file
    load_env
    prepare_directories
    fetch_upstream_reference
    printf "VERSION=%s\n" "${VIKUNJA_VERSION}"
    printf "SECRET_LEN=%s\n" "${#VIKUNJA_SERVICE_SECRET}"
    printf "PLACEHOLDER=%s\n" "$(grep -cE "^[A-Z_]+=CHANGEME" .env || true)"
    stat -c "MODE=%a" .env
    printf "FILES_DIR=%s\n" "$([[ -d "${VIKUNJA_FILES}" ]] && echo present || echo missing)"
    printf "POSTGRES_DIR=%s\n" "$([[ -d "${POSTGRES_DATA}" ]] && echo present || echo missing)"
    ls ref/
  ' 2>&1)"; status=$?
  set -e
  expect_status 0 "${status}" "bootstrap functions complete"
  expect_contains "VERSION=2.7.1" "${output}" ".env carries the pinned version"
  expect_contains "SECRET_LEN=64" "${output}" "token secret is 32 bytes of hex"
  expect_contains "PLACEHOLDER=0" "${output}" "no active CHANGEME assignment left in .env"
  expect_contains "MODE=600" "${output}" ".env has mode 600"
  expect_contains "FILES_DIR=present" "${output}" "VIKUNJA_FILES directory created"
  expect_contains "POSTGRES_DIR=present" "${output}" "POSTGRES_DATA directory created"
  expect_contains "CHANGELOG-2.7.1.md" "${output}" "upstream changelog fetched into ref/"

  mode="$(stat -c %a "${WORK_DIR}/.env")"
  if [[ "${mode}" == "600" ]]; then
    pass ".env mode confirmed independently (600)"
  else
    failing ".env mode is ${mode}, expected 600"
  fi

  first_hash="$(sha256sum "${WORK_DIR}/.env" | cut -d' ' -f1)"
  (cd "${WORK_DIR}" && bash -c 'source ./scripts/bootstrap.sh --help >/dev/null; create_env_file' >/dev/null 2>&1)
  second_hash="$(sha256sum "${WORK_DIR}/.env" | cut -d' ' -f1)"
  if [[ "${first_hash}" == "${second_hash}" ]]; then
    pass "idempotent: a second run does not rewrite .env"
  else
    failing "a second run modified .env"
  fi
}

# ----------------------------------------------------------------- 7. Fail-fast
test_fail_fast() {
  local output status

  section "7. Fail-fast without a Docker daemon"
  cp -a "${APP_DIR}/." "${WORK_DIR}/bootstrap-fail/"
  set +e
  output="$(cd "${WORK_DIR}/bootstrap-fail" && bash ./scripts/bootstrap.sh 2>&1)"; status=$?
  set -e
  if (( status != 0 )); then
    pass "bootstrap.sh aborts without a daemon (exit ${status})"
  else
    failing "bootstrap.sh reported success without a Docker daemon"
  fi
  expect_contains "ERROR" "${output}" "the abort is reported as an error"
}

main() {
  printf 'Test matrix – Vikunja stack\nsource: %s\nwork copy: %s\n' "${APP_DIR}" "${WORK_DIR}"
  test_syntax
  test_shellcheck
  test_compose
  test_arguments
  test_registry_check
  test_bootstrap_functions
  test_fail_fast
  printf '\n== result: %s OK, %s FAIL, %s SKIP\n' "${PASSED}" "${FAILED}" "${SKIPPED}"
  (( FAILED == 0 ))
}

main "$@"
