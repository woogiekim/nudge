#!/usr/bin/env bash
# TDD tests for install.sh --wire-codex.
#
# Critical invariant under test: Codex `notify` in config.toml is a single
# value (not array-mergeable). If a non-nudge `notify` already exists, the
# installer MUST NOT overwrite it. Instead it prints clobber guidance and
# exits 0, leaving the file byte-identical.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
FIXTURES="${REPO_ROOT}/tests/_fixtures"

FAILED=0
SCENARIOS_RUN=0
TMP_DIRS=()

cleanup() {
  local d
  for d in "${TMP_DIRS[@]:-}"; do
    [[ -n "${d:-}" && -d "${d}" ]] && rm -rf "${d}"
  done
  return 0
}
trap cleanup EXIT

pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*" >&2; FAILED=1; }

make_fixture_home() {
  local d
  d="$(mktemp -d -t nudge-wire-codex-XXXXXX)"
  TMP_DIRS+=("${d}")
  mkdir -p "${d}/.codex"
  printf '%s' "${d}"
}

# Stable hash helper (md5 on mac, md5sum on linux).
md5_of() {
  if md5 -q "$1" >/dev/null 2>&1; then md5 -q "$1"
  else md5sum "$1" | awk '{print $1}'
  fi
}

run_install() {
  local home_dir="$1"
  shift || true
  local fixture_file="${home_dir}/.codex/config.toml"
  HOME="${home_dir}" \
  NUDGE_CODEX_CONFIG="${fixture_file}" \
    bash "${INSTALL_SH}" --wire-codex "$@"
}

# ---------------------------------------------------------------------------
# Scenario A — pre-existing non-nudge notify → REFUSE to overwrite + guidance
# ---------------------------------------------------------------------------
scenario_clobber_refusal() {
  echo "[codex:A] pre-existing non-nudge notify → refuse + guidance + exit 0"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local home fixture_file pre_md5 pre_mtime
  home="$(make_fixture_home)"
  fixture_file="${home}/.codex/config.toml"
  cp "${FIXTURES}/codex-config-existing-notify.toml" "${fixture_file}"
  pre_md5="$(md5_of "${fixture_file}")"
  pre_mtime="$(stat -f %m "${fixture_file}" 2>/dev/null || stat -c %Y "${fixture_file}")"

  local out exit_code
  set +e
  out="$(run_install "${home}" 2>&1)"
  exit_code=$?
  set -e

  if [[ "${exit_code}" -ne 0 ]]; then
    fail "expected exit 0 on clobber refusal, got ${exit_code}"
    return
  fi
  pass "exit 0 on clobber refusal"

  local post_md5 post_mtime
  post_md5="$(md5_of "${fixture_file}")"
  post_mtime="$(stat -f %m "${fixture_file}" 2>/dev/null || stat -c %Y "${fixture_file}")"

  if [[ "${pre_md5}" != "${post_md5}" ]] || [[ "${pre_mtime}" != "${post_mtime}" ]]; then
    fail "fixture changed during refusal (md5 ${pre_md5}->${post_md5}; mtime ${pre_mtime}->${post_mtime})"
    return
  fi
  pass "fixture is byte-and-mtime untouched"

  if ! grep -E "(notify|already|existing|manual)" <<<"${out}" >/dev/null; then
    fail "guidance text missing in stdout"
    echo "----- output -----" >&2; echo "${out}" >&2; echo "------------------" >&2
    return
  fi
  if ! grep -F "notify-codex.sh" <<<"${out}" >/dev/null; then
    fail "guidance did not show the manual notify-codex.sh line"
    return
  fi
  pass "clobber guidance printed"
}

# ---------------------------------------------------------------------------
# Scenario B — no notify key → write it
# ---------------------------------------------------------------------------
scenario_set_when_absent() {
  echo "[codex:B] no notify present → set it (with backup)"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local home fixture_file
  home="$(make_fixture_home)"
  fixture_file="${home}/.codex/config.toml"
  cp "${FIXTURES}/codex-config-no-notify.toml" "${fixture_file}"

  local exit_code
  set +e
  run_install "${home}" >/dev/null 2>&1
  exit_code=$?
  set -e

  if [[ "${exit_code}" -ne 0 ]]; then
    fail "exit non-zero (${exit_code}) when setting notify"
    return
  fi

  if ! grep -F "notify-codex.sh" "${fixture_file}" >/dev/null 2>&1; then
    fail "notify-codex.sh not added to config.toml"
    return
  fi
  pass "notify-codex.sh wired"

  if ! grep -E '^notify\s*=' "${fixture_file}" >/dev/null 2>&1; then
    fail "no top-level 'notify =' line"
    return
  fi
  pass "top-level 'notify =' line present"

  if grep -F '~/.nudge' "${fixture_file}" >/dev/null 2>&1; then
    fail "config contains forbidden '~/.nudge' tilde-form"
    return
  fi
  if ! grep -F '/.nudge/notify-codex.sh' "${fixture_file}" >/dev/null 2>&1; then
    fail "config.toml missing absolute /.nudge/notify-codex.sh path"
    return
  fi
  pass "absolute /.nudge/notify-codex.sh path used"

  shopt -s nullglob
  local backups=( "${fixture_file}".bak.* )
  shopt -u nullglob
  if [[ ${#backups[@]} -eq 0 ]]; then
    fail "no timestamped backup file written"
    return
  fi
  pass "timestamped backup written (${#backups[@]} file(s))"

  # Existing [model] section must survive.
  if ! grep -E '^\[model\]' "${fixture_file}" >/dev/null 2>&1; then
    fail "pre-existing [model] section was lost"
    return
  fi
  pass "pre-existing [model] section preserved"
}

# ---------------------------------------------------------------------------
# Scenario C — idempotent re-run (nudge notify already present)
# ---------------------------------------------------------------------------
scenario_idempotent_rerun() {
  echo "[codex:C] re-run with nudge notify present → no-op"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local home fixture_file
  home="$(make_fixture_home)"
  fixture_file="${home}/.codex/config.toml"
  cp "${FIXTURES}/codex-config-no-notify.toml" "${fixture_file}"

  run_install "${home}" >/dev/null 2>&1 || { fail "first run failed"; return; }

  shopt -s nullglob
  local backups_before=( "${fixture_file}".bak.* )
  shopt -u nullglob
  local n_before=${#backups_before[@]}
  local md5_before
  md5_before="$(md5_of "${fixture_file}")"

  sleep 1
  run_install "${home}" >/dev/null 2>&1 || { fail "second run failed"; return; }

  shopt -s nullglob
  local backups_after=( "${fixture_file}".bak.* )
  shopt -u nullglob
  local n_after=${#backups_after[@]}
  local md5_after
  md5_after="$(md5_of "${fixture_file}")"

  if [[ "${md5_before}" != "${md5_after}" ]]; then
    fail "second run changed config.toml (md5 ${md5_before} -> ${md5_after})"
    return
  fi
  pass "config.toml unchanged on re-run"

  if [[ "${n_after}" -ne "${n_before}" ]]; then
    fail "second run wrote a new backup (count ${n_before} -> ${n_after})"
    return
  fi
  pass "no new backup file on re-run"
}

# ---------------------------------------------------------------------------
# Scenario D — config.toml absent → create minimal one with nudge notify
# ---------------------------------------------------------------------------
scenario_create_when_missing() {
  echo "[codex:D] config.toml missing → create with nudge notify"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local home fixture_file
  home="$(make_fixture_home)"
  fixture_file="${home}/.codex/config.toml"
  # do NOT pre-create
  if [[ -e "${fixture_file}" ]]; then
    fail "precondition: fixture should not exist"
    return
  fi

  local exit_code
  set +e
  run_install "${home}" >/dev/null 2>&1
  exit_code=$?
  set -e

  if [[ "${exit_code}" -ne 0 ]]; then
    fail "exit non-zero when config missing (${exit_code})"
    return
  fi

  if [[ ! -f "${fixture_file}" ]]; then
    fail "config.toml was not created"
    return
  fi
  if ! grep -F "notify-codex.sh" "${fixture_file}" >/dev/null 2>&1; then
    fail "created config.toml missing notify-codex.sh"
    return
  fi
  pass "config.toml created with nudge notify"
}

# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------
main() {
  if [[ ! -f "${INSTALL_SH}" ]]; then
    echo "FATAL: install.sh not found"
    exit 2
  fi

  scenario_clobber_refusal
  scenario_set_when_absent
  scenario_idempotent_rerun
  scenario_create_when_missing

  echo
  echo "Scenarios run: ${SCENARIOS_RUN}"
  if [[ ${FAILED} -ne 0 ]]; then
    echo "RESULT: one or more scenarios FAILED" >&2
    exit 1
  fi
  echo "ALL TESTS PASSED"
}

main "$@"
