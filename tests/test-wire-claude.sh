#!/usr/bin/env bash
# Spec: prd.md § "Core Features / Must have" — acceptance criteria for
# install.sh --wire-claude (completion Stop hook + start stamp hook wiring).
#
# Five scenarios, derived from the PRD's Gherkin acceptance block:
#   (a) Merge into absent settings.json → Stop + UserPromptSubmit (NOT Notification)
#   (b) Append preserves a pre-existing non-nudge Stop hook
#   (c) Idempotent re-run (no duplicate, no new backup)
#   (d) jq-absent path prints manual snippet and leaves fixture untouched
#   (e) Pre-existing non-nudge Notification entry is preserved, and the
#       nudge wrapper is NOT added to .hooks.Notification
#
# Test contract:
# - Each scenario uses a `mktemp -d` fixture HOME so the real
#   ${HOME}/.claude/settings.json is NEVER touched.
# - The fixture target file path is passed both via NUDGE_CLAUDE_SETTINGS
#   (env-var override) AND under a temp HOME, so whichever way the
#   implementer wires path resolution, the fixture wins.
# - Scenarios are self-contained and clean up via trap.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"

FAILED=0
SCENARIOS_RUN=0

# Track all fixture dirs for cleanup
FIXTURE_DIRS=()
cleanup() {
  local d
  for d in "${FIXTURE_DIRS[@]:-}"; do
    if [[ -n "${d:-}" && -d "${d}" ]]; then
      rm -rf "${d}"
    fi
  done
  return 0
}
trap cleanup EXIT

make_fixture_home() {
  # Create a temp HOME with a .claude/ subdirectory ready for settings.json.
  local home_dir
  home_dir="$(mktemp -d -t nudge-wire-claude-XXXXXX)"
  FIXTURE_DIRS+=("${home_dir}")
  mkdir -p "${home_dir}/.claude"
  printf '%s' "${home_dir}"
}

run_install_wire() {
  # Run install.sh --wire-claude against a fixture HOME.
  # The fixture path is passed via BOTH HOME override and
  # NUDGE_CLAUDE_SETTINGS env, so the implementer's preferred mechanism
  # is honored either way.
  local home_dir="$1"
  shift || true
  local extra_path="${1:-}"   # optional prefix for PATH

  local fixture_file="${home_dir}/.claude/settings.json"
  local effective_path="${PATH}"
  if [[ -n "${extra_path}" ]]; then
    effective_path="${extra_path}:${PATH}"
  fi

  HOME="${home_dir}" \
  NUDGE_CLAUDE_SETTINGS="${fixture_file}" \
  PATH="${effective_path}" \
    bash "${INSTALL_SH}" --wire-claude
}

pass() {
  echo "  PASS: $*"
}

fail() {
  echo "  FAIL: $*" >&2
  FAILED=1
}

# ---------------------------------------------------------------------------
# Scenario (a) — merge into ABSENT settings.json
# ---------------------------------------------------------------------------
scenario_a_absent_file() {
  echo "[scenario a] merge into absent settings.json"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local home_dir
  home_dir="$(make_fixture_home)"
  local fixture_file="${home_dir}/.claude/settings.json"

  if [[ -e "${fixture_file}" ]]; then
    fail "fixture file already exists before wiring (pre-condition violated)"
    return
  fi

  local out
  set +e
  out="$(run_install_wire "${home_dir}" 2>&1)"
  local exit_code=$?
  set -e
  if [[ ${exit_code} -ne 0 ]]; then
    fail "install.sh --wire-claude exited non-zero (exit=${exit_code})"
    return
  fi

  if [[ ! -f "${fixture_file}" ]]; then
    fail "fixture settings.json was not created"
    return
  fi
  pass "settings.json created at fixture path"

  if command -v jq >/dev/null 2>&1; then
    if ! jq -e . "${fixture_file}" >/dev/null 2>&1; then
      fail "fixture settings.json is not valid JSON"
      return
    fi
  elif command -v python3 >/dev/null 2>&1; then
    if ! python3 -c "import json,sys; json.load(open('${fixture_file}'))" >/dev/null 2>&1; then
      fail "fixture settings.json is not valid JSON (python3 check)"
      return
    fi
  fi
  pass "settings.json parses as valid JSON"

  local expected_prefix="${home_dir}/.nudge/notify"
  if ! grep -F "${expected_prefix}" "${fixture_file}" >/dev/null 2>&1; then
    fail "settings.json missing absolute-form path ${expected_prefix}*.sh"
    return
  fi
  if ! grep -E "/\.nudge/notify(-claude(-turn-start)?)?\.sh" "${fixture_file}" >/dev/null 2>&1; then
    fail "settings.json missing /.nudge/notify*.sh path"
    return
  fi
  pass "settings.json contains absolute-form notify*.sh path"

  if grep -F "~/.nudge/notify.sh" "${fixture_file}" >/dev/null 2>&1; then
    fail "settings.json contains forbidden tilde-form '~/.nudge/notify.sh'"
    return
  fi
  pass "settings.json does not contain '~' shorthand"

  if command -v jq >/dev/null 2>&1; then
    local stop_cmd
    stop_cmd="$(jq -r '.hooks.Stop[0].hooks[0].command // ""' "${fixture_file}")"
    if ! [[ "${stop_cmd}" =~ /\.nudge/notify(-claude)?\.sh ]]; then
      fail ".hooks.Stop[0].hooks[0].command does not reference /.nudge/notify.sh or notify-claude.sh: ${stop_cmd}"
      return
    fi
    pass ".hooks.Stop references notify(-claude).sh"

    local start_nudge_count
    start_nudge_count="$(jq -r '
      [ (.hooks.UserPromptSubmit // [])[]
        | .hooks[]?
        | select(.command | test("/\\.nudge/notify-claude-turn-start\\.sh"))
      ] | length
    ' "${fixture_file}")"
    if [[ "${start_nudge_count}" -ne 1 ]]; then
      fail ".hooks.UserPromptSubmit should contain exactly 1 notify-claude-turn-start.sh entry, found ${start_nudge_count}"
      return
    fi
    pass ".hooks.UserPromptSubmit references notify-claude-turn-start.sh"

    # Completion notifications are Stop-only: .hooks.Notification is either
    # absent OR contains no nudge command. The dual-hook regression would put
    # the nudge wrapper under Notification — fail in that case.
    local notif_nudge_count
    notif_nudge_count="$(jq -r '
      [ (.hooks.Notification // [])[]
        | .hooks[]?
        | select(.command | test("/\\.nudge/notify.*\\.sh"))
      ] | length
    ' "${fixture_file}")"
    if [[ "${notif_nudge_count}" -ne 0 ]]; then
      fail ".hooks.Notification contains ${notif_nudge_count} nudge entry/entries — must be Stop-only"
      return
    fi
    pass ".hooks.Notification does NOT reference the nudge wrapper (Stop-only)"
  fi

  # Echo line must reflect Stop-only contract.
  if ! grep -F "Stop" <<<"${out}" >/dev/null || ! grep -F "UserPromptSubmit" <<<"${out}" >/dev/null; then
    fail "from-scratch success echo does not mention both Stop and UserPromptSubmit"
    echo "---- captured output ----" >&2
    echo "${out}" >&2
    echo "-------------------------" >&2
    return
  fi
  pass "captured stdout mentions Stop and UserPromptSubmit"

  if grep -F "Notification hooks" <<<"${out}" >/dev/null; then
    fail "from-scratch success echo still mentions 'Notification hooks' — must be Stop-only"
    echo "---- captured output ----" >&2
    echo "${out}" >&2
    echo "-------------------------" >&2
    return
  fi
  pass "captured stdout does NOT contain 'Notification hooks'"
}

# ---------------------------------------------------------------------------
# Scenario (b) — append preserves a pre-existing non-nudge Stop hook
# ---------------------------------------------------------------------------
scenario_b_preserves_existing_stop() {
  echo "[scenario b] append preserves a pre-existing non-nudge Stop hook"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local home_dir
  home_dir="$(make_fixture_home)"
  local fixture_file="${home_dir}/.claude/settings.json"

  cat > "${fixture_file}" <<'JSON_EOF'
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "/usr/local/bin/mnemos capture --auto"
          }
        ]
      }
    ]
  }
}
JSON_EOF

  if ! run_install_wire "${home_dir}" >/dev/null 2>&1; then
    fail "install.sh --wire-claude exited non-zero"
    return
  fi

  if ! grep -F "mnemos capture --auto" "${fixture_file}" >/dev/null 2>&1; then
    fail "pre-existing mnemos Stop entry was lost"
    return
  fi
  pass "pre-existing mnemos Stop entry is preserved"

  if ! grep -E "/.nudge/notify(-claude)?.sh" "${fixture_file}" >/dev/null 2>&1; then
    fail "nudge Stop entry was not appended"
    return
  fi
  pass "nudge entry appended alongside mnemos"

  if command -v jq >/dev/null 2>&1; then
    local start_nudge_count
    start_nudge_count="$(jq -r '
      [ (.hooks.UserPromptSubmit // [])[]
        | .hooks[]?
        | select(.command | test("/\\.nudge/notify-claude-turn-start\\.sh"))
      ] | length
    ' "${fixture_file}")"
    if [[ "${start_nudge_count}" -ne 1 ]]; then
      fail "expected 1 UserPromptSubmit start hook, found ${start_nudge_count}"
      return
    fi
    pass "UserPromptSubmit start hook appended"
  fi

  shopt -s nullglob
  local backups=( "${fixture_file}".bak.* )
  shopt -u nullglob
  if [[ ${#backups[@]} -eq 0 ]]; then
    fail "no timestamped backup file written"
    return
  fi
  pass "timestamped backup file written (${#backups[@]} file(s))"

  local backup_path="${backups[0]}"
  if grep -E "/.nudge/notify(-claude)?.sh" "${backup_path}" >/dev/null 2>&1; then
    fail "backup file contains nudge entry — backup taken AFTER edit, not before"
    return
  fi
  if ! grep -F "mnemos capture --auto" "${backup_path}" >/dev/null 2>&1; then
    fail "backup file does not contain the original mnemos entry"
    return
  fi
  pass "backup file captures pre-edit state"

  if command -v jq >/dev/null 2>&1; then
    local stop_count
    stop_count="$(jq -r '[.hooks.Stop[].hooks[].command] | length' "${fixture_file}")"
    if [[ "${stop_count}" -lt 2 ]]; then
      fail "expected >=2 Stop hook commands after wiring, found ${stop_count}"
      return
    fi
    pass ".hooks.Stop contains ${stop_count} hook commands (mnemos + nudge)"
  fi
}

# ---------------------------------------------------------------------------
# Scenario (c) — re-run is idempotent
# ---------------------------------------------------------------------------
scenario_c_idempotent_rerun() {
  echo "[scenario c] re-run is idempotent (no duplicate, no new backup)"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local home_dir
  home_dir="$(make_fixture_home)"
  local fixture_file="${home_dir}/.claude/settings.json"

  if ! run_install_wire "${home_dir}" >/dev/null 2>&1; then
    fail "first install.sh --wire-claude run exited non-zero"
    return
  fi

  if [[ ! -f "${fixture_file}" ]]; then
    fail "fixture file missing after first run"
    return
  fi

  local count_before
  count_before="$(grep -c -E "/.nudge/notify(-claude(-turn-start)?)?.sh" "${fixture_file}" || true)"
  if [[ "${count_before}" -lt 1 ]]; then
    fail "first run did not produce any /.nudge/notify(-claude).sh entry"
    return
  fi
  pass "first run wired ${count_before} nudge command(s)"

  shopt -s nullglob
  local backups_before=( "${fixture_file}".bak.* )
  shopt -u nullglob
  local n_backups_before=${#backups_before[@]}

  sleep 1

  if ! run_install_wire "${home_dir}" >/dev/null 2>&1; then
    fail "second install.sh --wire-claude run exited non-zero"
    return
  fi

  local count_after
  count_after="$(grep -c -E "/.nudge/notify(-claude(-turn-start)?)?.sh" "${fixture_file}" || true)"
  if [[ "${count_after}" -ne "${count_before}" ]]; then
    fail "second run added a duplicate (before=${count_before}, after=${count_after})"
    return
  fi
  pass "no duplicate nudge entry after re-run (count stable at ${count_after})"

  shopt -s nullglob
  local backups_after=( "${fixture_file}".bak.* )
  shopt -u nullglob
  local n_backups_after=${#backups_after[@]}

  if [[ "${n_backups_after}" -ne "${n_backups_before}" ]]; then
    fail "second run created a new backup file (before=${n_backups_before}, after=${n_backups_after})"
    return
  fi
  pass "no new backup file written on idempotent re-run"
}

# ---------------------------------------------------------------------------
# Scenario (d) — jq absent: print manual snippet, leave fixture untouched
# ---------------------------------------------------------------------------
scenario_d_jq_absent() {
  echo "[scenario d] jq absent → print manual snippet, do not touch fixture"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local home_dir
  home_dir="$(make_fixture_home)"
  local fixture_file="${home_dir}/.claude/settings.json"

  cat > "${fixture_file}" <<'JSON_EOF'
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "/usr/local/bin/mnemos capture --auto" }
        ]
      }
    ]
  }
}
JSON_EOF

  local pre_md5
  pre_md5="$(md5 -q "${fixture_file}" 2>/dev/null || md5sum "${fixture_file}" | awk '{print $1}')"
  local pre_mtime
  pre_mtime="$(stat -f %m "${fixture_file}" 2>/dev/null || stat -c %Y "${fixture_file}")"

  # Build a PATH that excludes any directory containing jq, to simulate
  # jq-absent. Include the basic system dirs that DON'T have jq.
  local minimal_path=""
  local d
  for d in /bin /usr/bin /sbin /usr/sbin; do
    if [[ -d "${d}" && ! -x "${d}/jq" ]]; then
      minimal_path="${minimal_path:+${minimal_path}:}${d}"
    fi
  done
  if [[ -z "${minimal_path}" ]]; then
    minimal_path="/bin:/usr/bin"
  fi

  local out
  set +e
  out="$(HOME="${home_dir}" \
        NUDGE_CLAUDE_SETTINGS="${fixture_file}" \
        PATH="${minimal_path}" \
        bash "${INSTALL_SH}" --wire-claude 2>&1)"
  local exit_code=$?
  set -e

  if [[ ${exit_code} -ne 0 ]]; then
    fail "jq-absent run exited non-zero (exit=${exit_code}); expected 0"
    return
  fi
  pass "jq-absent run exited 0"

  if ! grep -E "examples/claude-code\.settings\.json|notify\.sh" <<<"${out}" >/dev/null; then
    fail "jq-absent run did not print the manual merge snippet hint"
    echo "---- captured output ----" >&2
    echo "${out}" >&2
    echo "-------------------------" >&2
    return
  fi
  pass "manual merge snippet hint printed"

  local post_md5
  post_md5="$(md5 -q "${fixture_file}" 2>/dev/null || md5sum "${fixture_file}" | awk '{print $1}')"
  local post_mtime
  post_mtime="$(stat -f %m "${fixture_file}" 2>/dev/null || stat -c %Y "${fixture_file}")"

  if [[ "${pre_md5}" != "${post_md5}" ]]; then
    fail "fixture content changed during jq-absent run (md5 mismatch)"
    return
  fi
  if [[ "${pre_mtime}" != "${post_mtime}" ]]; then
    fail "fixture mtime changed during jq-absent run"
    return
  fi
  pass "fixture file is byte-and-mtime untouched"

  shopt -s nullglob
  local backups=( "${fixture_file}".bak.* )
  shopt -u nullglob
  if [[ ${#backups[@]} -gt 0 ]]; then
    fail "jq-absent run wrote ${#backups[@]} backup file(s) — must write none"
    return
  fi
  pass "no backup file written in jq-absent path"
}

# ---------------------------------------------------------------------------
# Scenario (e) — pre-existing non-nudge Notification entry is preserved AND
# the nudge wrapper is NOT added to .hooks.Notification (Stop-only contract).
# ---------------------------------------------------------------------------
scenario_e_preserves_existing_notification() {
  echo "[scenario e] preserves a pre-existing non-nudge Notification entry"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  if ! command -v jq >/dev/null 2>&1; then
    echo "  SKIP: jq not on PATH (this scenario asserts jq-driven Notification preservation)"
    return
  fi

  local home_dir
  home_dir="$(make_fixture_home)"
  local fixture_file="${home_dir}/.claude/settings.json"

  cat > "${fixture_file}" <<'JSON_EOF'
{
  "hooks": {
    "Notification": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "/usr/local/bin/some-user-tool"
          }
        ]
      }
    ]
  }
}
JSON_EOF

  # Snapshot the pre-existing Notification array byte-for-byte (canonical jq form)
  # so we can verify it survives unchanged.
  local pre_notif_json
  pre_notif_json="$(jq -S '.hooks.Notification' "${fixture_file}")"

  if ! run_install_wire "${home_dir}" >/dev/null 2>&1; then
    fail "install.sh --wire-claude exited non-zero"
    return
  fi

  if [[ ! -f "${fixture_file}" ]]; then
    fail "fixture file missing after wiring"
    return
  fi

  local post_notif_json
  post_notif_json="$(jq -S '.hooks.Notification' "${fixture_file}")"
  if [[ "${pre_notif_json}" != "${post_notif_json}" ]]; then
    fail ".hooks.Notification changed after wiring (Stop-only contract violated)"
    echo "---- pre ----" >&2
    echo "${pre_notif_json}" >&2
    echo "---- post ----" >&2
    echo "${post_notif_json}" >&2
    echo "--------------" >&2
    return
  fi
  pass ".hooks.Notification preserved byte-for-byte (user's some-user-tool entry intact)"

  # The user's command must still be findable.
  if ! grep -F "/usr/local/bin/some-user-tool" "${fixture_file}" >/dev/null 2>&1; then
    fail "pre-existing /usr/local/bin/some-user-tool entry was lost"
    return
  fi
  pass "pre-existing /usr/local/bin/some-user-tool entry survives"

  # No nudge wrapper should appear under Notification.
  local notif_nudge_count
  notif_nudge_count="$(jq -r '
    [ (.hooks.Notification // [])[]
      | .hooks[]?
      | select(.command | test("/\\.nudge/notify.*\\.sh"))
    ] | length
  ' "${fixture_file}")"
  if [[ "${notif_nudge_count}" -ne 0 ]]; then
    fail "nudge wrapper was added to .hooks.Notification (${notif_nudge_count} entry/entries) — must be Stop-only"
    return
  fi
  pass "nudge wrapper NOT added to .hooks.Notification"

  # The Stop hook MUST now carry the nudge wrapper.
  local stop_nudge_count
  stop_nudge_count="$(jq -r '
    [ (.hooks.Stop // [])[]
      | .hooks[]?
      | select(.command | test("/\\.nudge/notify(-claude)?\\.sh"))
    ] | length
  ' "${fixture_file}")"
  if [[ "${stop_nudge_count}" -lt 1 ]]; then
    fail ".hooks.Stop is missing the nudge wrapper after wiring"
    return
  fi
  pass ".hooks.Stop carries the nudge wrapper (${stop_nudge_count} entry/entries)"

  local start_nudge_count
  start_nudge_count="$(jq -r '
    [ (.hooks.UserPromptSubmit // [])[]
      | .hooks[]?
      | select(.command | test("/\\.nudge/notify-claude-turn-start\\.sh"))
    ] | length
  ' "${fixture_file}")"
  if [[ "${start_nudge_count}" -lt 1 ]]; then
    fail ".hooks.UserPromptSubmit is missing the start hook after wiring"
    return
  fi
  pass ".hooks.UserPromptSubmit carries the start hook (${start_nudge_count} entry/entries)"
}

# ---------------------------------------------------------------------------
# Scenario (f) — existing nudge Stop hook but missing UserPromptSubmit start
# hook: installer must add the missing start hook without duplicating Stop.
# ---------------------------------------------------------------------------
scenario_f_adds_missing_start_hook() {
  echo "[scenario f] existing Stop nudge hook -> add missing UserPromptSubmit start hook"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  if ! command -v jq >/dev/null 2>&1; then
    echo "  SKIP: jq not on PATH (this scenario asserts jq-driven hook merge)"
    return
  fi

  local home_dir
  home_dir="$(make_fixture_home)"
  local fixture_file="${home_dir}/.claude/settings.json"

  cat > "${fixture_file}" <<JSON_EOF
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "${home_dir}/.nudge/notify-claude.sh"
          }
        ]
      }
    ]
  }
}
JSON_EOF

  if ! run_install_wire "${home_dir}" >/dev/null 2>&1; then
    fail "install.sh --wire-claude exited non-zero"
    return
  fi

  local stop_nudge_count
  stop_nudge_count="$(jq -r '
    [ (.hooks.Stop // [])[]
      | .hooks[]?
      | select(.command | test("/\\.nudge/notify(-claude)?\\.sh"))
    ] | length
  ' "${fixture_file}")"
  if [[ "${stop_nudge_count}" -ne 1 ]]; then
    fail "existing Stop nudge hook should not be duplicated; found ${stop_nudge_count}"
    return
  fi
  pass "existing Stop nudge hook not duplicated"

  local start_nudge_count
  start_nudge_count="$(jq -r '
    [ (.hooks.UserPromptSubmit // [])[]
      | .hooks[]?
      | select(.command | test("/\\.nudge/notify-claude-turn-start\\.sh"))
    ] | length
  ' "${fixture_file}")"
  if [[ "${start_nudge_count}" -ne 1 ]]; then
    fail "expected missing UserPromptSubmit start hook to be added exactly once; found ${start_nudge_count}"
    return
  fi
  pass "missing UserPromptSubmit start hook added"
}

# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------
main() {
  if [[ ! -f "${INSTALL_SH}" ]]; then
    echo "FATAL: install.sh not found at ${INSTALL_SH}" >&2
    exit 2
  fi

  scenario_a_absent_file
  scenario_b_preserves_existing_stop
  scenario_c_idempotent_rerun
  scenario_d_jq_absent
  scenario_e_preserves_existing_notification
  scenario_f_adds_missing_start_hook

  echo
  echo "Scenarios run: ${SCENARIOS_RUN}"
  if [[ ${FAILED} -ne 0 ]]; then
    echo "RESULT: one or more scenarios FAILED" >&2
    exit 1
  fi
  echo "ALL TESTS PASSED"
}

main "$@"
