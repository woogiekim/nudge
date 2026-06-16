#!/usr/bin/env bash
# TDD tests for install.sh --wire-codex.
#
# Critical invariant under test: Codex `notify` in config.toml is a single
# value (not array-mergeable). If a non-nudge `notify` already exists, the
# installer MUST NOT overwrite it. Instead it prints clobber guidance and
# exits 0, leaving the file byte-identical.
#
# Additional invariant (teardown-resilience): Codex runs `notify` fire-and-
# forget and tears down the process tree shortly after the turn (especially
# `codex exec`), killing a still-running synchronous curl. The installer
# must therefore emit the `notify` line in a DETACHED form
# (nohup + backgrounded subshell), and the same detached form must appear
# in the printed manual-merge guidance for the clobber-refusal case.

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

# Detach-wrapper assertion. Given a single-line string $1 (the notify line) and
# a context label $2 (for the failure message), verify the line contains every
# substring that proves it is the teardown-resilient detached form:
#   - `nohup`                  → survives parent SIGHUP / teardown
#   - `( ` and ` & )`          → backgrounded subshell wrapper
#   - `>/dev/null 2>&1`        → silences output so curl can detach cleanly
#   - `notify-codex.sh`        → still invokes the nudge wrapper
#   - `"$1"`                   → still forwards Codex's JSON payload arg
#   - `/.nudge/notify-codex.sh` → absolute path under HOME/.nudge
# All checks use literal-string grep (-F) and operate on a single line.
assert_detach_line() {
  local line="$1"
  local ctx="$2"
  local missing=0

  if ! grep -F 'nohup' <<<"${line}" >/dev/null; then
    fail "${ctx}: notify line missing 'nohup' (detach wrapper required)"
    missing=1
  fi
  if ! grep -F '( ' <<<"${line}" >/dev/null; then
    fail "${ctx}: notify line missing '( ' opening subshell"
    missing=1
  fi
  if ! grep -F ' & )' <<<"${line}" >/dev/null; then
    fail "${ctx}: notify line missing ' & )' backgrounded subshell close"
    missing=1
  fi
  if ! grep -F '>/dev/null 2>&1' <<<"${line}" >/dev/null; then
    fail "${ctx}: notify line missing '>/dev/null 2>&1' redirect"
    missing=1
  fi
  if ! grep -F 'notify-codex.sh' <<<"${line}" >/dev/null; then
    fail "${ctx}: notify line missing 'notify-codex.sh' wrapper reference"
    missing=1
  fi
  # Payload arg passing — install.sh wires Codex's JSON payload as $1 into the
  # bash -c command. Depending on the emit path the bytes around $1 are either
  # `\"$1\"` (create-when-missing path + printed manual line — install.sh's
  # shell-literal backslash escapes survive) OR `"$1"` (no-notify-append path,
  # because awk -v assignment strips the backslashes when it interpolates the
  # variable). Both forms are valid — accept either, but require `$1` quoted.
  if ! grep -E '\\?"\$1\\?"' <<<"${line}" >/dev/null; then
    fail "${ctx}: notify line missing quoted \$1 payload placeholder (expected \"\$1\" or \\"\$1\\")"
    missing=1
  fi
  if ! grep -F '/.nudge/notify-codex.sh' <<<"${line}" >/dev/null; then
    fail "${ctx}: notify line missing absolute '/.nudge/notify-codex.sh' path"
    missing=1
  fi

  if [[ "${missing}" -eq 0 ]]; then
    pass "${ctx}: detached notify wrapper present (nohup + ( ... & ) + redirect + payload)"
  fi
}

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

  # NEW: the printed manual-merge snippet must itself be the detached form,
  # so users who paste it get teardown-resilient wiring (not the legacy
  # synchronous form that loses curl mid-flight under codex exec).
  local manual_line
  manual_line="$(grep -F 'notify-codex.sh' <<<"${out}" | grep -F 'notify' | head -n1)"
  if [[ -z "${manual_line}" ]]; then
    fail "could not extract printed manual notify line from guidance output"
    echo "----- output -----" >&2; echo "${out}" >&2; echo "------------------" >&2
    return
  fi
  assert_detach_line "${manual_line}" "scenario A printed guidance"
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

  # NEW: the generated notify line must be the detached form (teardown-
  # resilient under codex exec). Operate on the single notify line, not the
  # whole file, so the assertions are unambiguous.
  local notify_line
  notify_line="$(grep -E '^notify\s*=' "${fixture_file}" | head -n1)"
  if [[ -z "${notify_line}" ]]; then
    fail "could not extract generated notify line from config.toml"
    return
  fi
  assert_detach_line "${notify_line}" "scenario B generated notify line"
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

  # NEW: the created notify line must be the detached form.
  local notify_line
  notify_line="$(grep -E '^notify\s*=' "${fixture_file}" | head -n1)"
  if [[ -z "${notify_line}" ]]; then
    fail "could not extract created notify line from config.toml"
    return
  fi
  assert_detach_line "${notify_line}" "scenario D created notify line"
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
