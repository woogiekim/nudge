#!/usr/bin/env bash
# TDD tests for install.sh --wire-gemini.

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
  d="$(mktemp -d -t nudge-wire-gemini-XXXXXX)"
  TMP_DIRS+=("${d}")
  printf '%s' "${d}"
}

md5_of() {
  if md5 -q "$1" >/dev/null 2>&1; then md5 -q "$1"
  else md5sum "$1" | awk '{print $1}'
  fi
}

run_install_with_gemini() {
  # Gemini dir present; settings.json may or may not exist.
  local home="$1"
  local settings_file="${home}/.gemini/settings.json"
  mkdir -p "${home}/.gemini"
  HOME="${home}" \
  NUDGE_GEMINI_SETTINGS="${settings_file}" \
  NUDGE_GEMINI_DIR="${home}/.gemini" \
    bash "${INSTALL_SH}" --wire-gemini "${@:2}"
}

run_install_no_gemini_dir() {
  # Gemini absent: NUDGE_GEMINI_DIR points to a non-existent dir.
  local home="$1"
  HOME="${home}" \
  NUDGE_GEMINI_DIR="${home}/.gemini" \
  NUDGE_GEMINI_SETTINGS="${home}/.gemini/settings.json" \
    bash "${INSTALL_SH}" --wire-gemini "${@:2}"
}

# ---------------------------------------------------------------------------
# Scenario A — ~/.gemini absent → skip with notice, exit 0
# ---------------------------------------------------------------------------
scenario_skip_when_absent() {
  echo "[gemini-wire:A] ~/.gemini absent → skip + notice, exit 0"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local home
  home="$(make_fixture_home)"
  # No .gemini dir created.

  local exit_code out
  set +e
  out="$(run_install_no_gemini_dir "${home}" 2>&1)"
  exit_code=$?
  set -e

  if [[ "${exit_code}" -ne 0 ]]; then
    fail "expected exit 0 when gemini dir absent, got ${exit_code}"
    echo "${out}" >&2
    return
  fi
  pass "exit 0 when ~/.gemini absent"

  if ! grep -E "(gemini|skip|not found|absent)" -i <<<"${out}" >/dev/null; then
    fail "no skip notice for absent gemini dir"
    return
  fi
  pass "skip notice printed"

  if [[ -d "${home}/.gemini" ]]; then
    fail "installer wrongly created ~/.gemini"
    return
  fi
  pass "no ~/.gemini created"
}

# ---------------------------------------------------------------------------
# Scenario B — settings.json absent (but .gemini exists) → create
# ---------------------------------------------------------------------------
scenario_create_when_settings_missing() {
  echo "[gemini-wire:B] settings.json missing → create"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local home settings_file
  home="$(make_fixture_home)"
  settings_file="${home}/.gemini/settings.json"

  run_install_with_gemini "${home}" >/dev/null 2>&1 || { fail "install failed"; return; }

  if [[ ! -f "${settings_file}" ]]; then
    fail "settings.json was not created"
    return
  fi

  if ! grep -F "notify-gemini.sh" "${settings_file}" >/dev/null 2>&1; then
    fail "settings.json missing notify-gemini.sh"
    return
  fi
  pass "settings.json created with notify-gemini.sh"

  if grep -F "~/.nudge" "${settings_file}" >/dev/null 2>&1; then
    fail "tilde form '~/.nudge' present (forbidden)"
    return
  fi
  pass "absolute path used"

  if command -v jq >/dev/null 2>&1; then
    local n_after_agent n_notif
    n_after_agent="$(jq -r '[.hooks.AfterAgent[]?.hooks[]?.command] | length' "${settings_file}")"
    n_notif="$(jq -r '[.hooks.Notification[]?.hooks[]?.command] | length' "${settings_file}")"
    if [[ "${n_after_agent}" -lt 1 ]] || [[ "${n_notif}" -lt 1 ]]; then
      fail "expected AfterAgent + Notification hooks (got after=${n_after_agent}, notif=${n_notif})"
      return
    fi
    pass "AfterAgent + Notification hooks both wired"
  fi
}

# ---------------------------------------------------------------------------
# Scenario C — merge preserves existing non-nudge hook + backup
# ---------------------------------------------------------------------------
scenario_preserves_existing() {
  echo "[gemini-wire:C] pre-existing non-nudge hook preserved + backup"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local home settings_file
  home="$(make_fixture_home)"
  settings_file="${home}/.gemini/settings.json"
  mkdir -p "${home}/.gemini"
  cp "${FIXTURES}/gemini-settings-existing.json" "${settings_file}"

  run_install_with_gemini "${home}" >/dev/null 2>&1 || { fail "install failed"; return; }

  if ! grep -F "some-existing-tool" "${settings_file}" >/dev/null 2>&1; then
    fail "pre-existing hook was lost"
    return
  fi
  pass "pre-existing hook preserved"

  if ! grep -F "notify-gemini.sh" "${settings_file}" >/dev/null 2>&1; then
    fail "nudge hook not added"
    return
  fi
  pass "nudge hook added alongside existing"

  shopt -s nullglob
  local backups=( "${settings_file}".bak.* )
  shopt -u nullglob
  if [[ ${#backups[@]} -eq 0 ]]; then
    fail "no timestamped backup written"
    return
  fi
  pass "timestamped backup written"

  local backup_path="${backups[0]}"
  if grep -F "notify-gemini.sh" "${backup_path}" >/dev/null 2>&1; then
    fail "backup taken AFTER edit"
    return
  fi
  pass "backup is pre-edit"
}

# ---------------------------------------------------------------------------
# Scenario D — idempotent re-run
# ---------------------------------------------------------------------------
scenario_idempotent_rerun() {
  echo "[gemini-wire:D] idempotent re-run"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local home settings_file
  home="$(make_fixture_home)"
  settings_file="${home}/.gemini/settings.json"
  mkdir -p "${home}/.gemini"

  run_install_with_gemini "${home}" >/dev/null 2>&1 || { fail "first run failed"; return; }

  local md5_before
  md5_before="$(md5_of "${settings_file}")"
  shopt -s nullglob
  local n_before=$(ls "${settings_file}".bak.* 2>/dev/null | wc -l | tr -d ' ')
  shopt -u nullglob

  sleep 1
  run_install_with_gemini "${home}" >/dev/null 2>&1 || { fail "second run failed"; return; }

  local md5_after
  md5_after="$(md5_of "${settings_file}")"
  shopt -s nullglob
  local n_after=$(ls "${settings_file}".bak.* 2>/dev/null | wc -l | tr -d ' ')
  shopt -u nullglob

  if [[ "${md5_before}" != "${md5_after}" ]]; then
    fail "settings.json changed on re-run (md5 ${md5_before} -> ${md5_after})"
    return
  fi
  pass "no content change on re-run"

  if [[ "${n_after}" != "${n_before}" ]]; then
    fail "new backup on re-run (count ${n_before} -> ${n_after})"
    return
  fi
  pass "no new backup on re-run"
}

main() {
  if [[ ! -f "${INSTALL_SH}" ]]; then
    echo "FATAL: install.sh not found"; exit 2
  fi
  scenario_skip_when_absent
  scenario_create_when_settings_missing
  scenario_preserves_existing
  scenario_idempotent_rerun

  echo
  echo "Scenarios run: ${SCENARIOS_RUN}"
  if [[ ${FAILED} -ne 0 ]]; then
    echo "RESULT: one or more scenarios FAILED" >&2
    exit 1
  fi
  echo "ALL TESTS PASSED"
}

main "$@"
