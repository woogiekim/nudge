#!/usr/bin/env bash
# TDD tests for notify-codex.sh — Codex CLI's `notify` program receives the
# JSON payload as ARGV[1] (not stdin). Gate on type=="agent-turn-complete";
# extract project from .cwd (fallback $PWD); the per-turn message must surface
# the CURRENT-turn prompt (.input-messages[-1]) AND the assistant answer
# (.last-assistant-message). The FIRST input-messages element is the original
# session-opening prompt and must NOT appear in later-turn notifications.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER="${REPO_ROOT}/notify-codex.sh"
FIXTURES="${REPO_ROOT}/tests/_fixtures"
STUB="${FIXTURES}/notify-stub.sh"

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

make_tmp() {
  local d
  d="$(mktemp -d -t nudge-notify-codex-XXXXXX)"
  TMP_DIRS+=("${d}")
  printf '%s' "${d}"
}

read_last_log() {
  local logfile="$1" field="$2"
  local idx
  case "${field}" in
    title)    idx=1 ;;
    message)  idx=2 ;;
    priority) idx=3 ;;
  esac
  tail -n 1 "${logfile}" 2>/dev/null | awk -v i="${idx}" -F '\t' '{print $i}'
}

# ---------------------------------------------------------------------------
# Scenario 1 — agent-turn-complete with cwd, current-turn prompt, and answer
# ---------------------------------------------------------------------------
# The notification message body must contain:
#   - the LAST input-messages element ("Now add a regression test") — the
#     current-turn prompt
#   - the last-assistant-message text ("Done — pushed a fix.") — the just-
#     produced answer
# It must NOT contain the FIRST input-messages element
# ("Fix the login bug in auth.py") — that is the original session-opening
# prompt, not the current turn.
scenario_agent_turn_complete() {
  echo "[codex:1] agent-turn-complete → title with project, message with current-turn prompt + answer"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local td proj stub_log
  td="$(make_tmp)"
  proj="${td}/codexproj"
  mkdir -p "${proj}"
  stub_log="${td}/stub.log"

  # Build payload with real cwd interpolated.
  local payload
  payload="$(sed "s|__CWD_PLACEHOLDER__|${proj}|" "${FIXTURES}/codex-payload-complete.json")"

  NUDGE_NOTIFY_CMD="${STUB}" \
  NUDGE_NOTIFY_STUB_LOG="${stub_log}" \
    bash "${WRAPPER}" "${payload}" >/dev/null 2>&1 || true

  if [[ ! -f "${stub_log}" ]]; then
    fail "stub never called"
    return
  fi
  local title message
  title="$(read_last_log "${stub_log}" title)"
  message="$(read_last_log "${stub_log}" message)"

  if [[ "${title}" != *"Codex CLI"* ]] || [[ "${title}" != *"codexproj"* ]]; then
    fail "title missing 'Codex CLI · codexproj': ${title}"
    return
  fi
  pass "title contains 'Codex CLI' and project basename"

  if [[ "${message}" != *"Now add a regression test"* ]]; then
    fail "message missing current-turn prompt (input-messages[-1]): ${message}"
    return
  fi
  pass "message contains current-turn prompt (input-messages[-1])"

  if [[ "${message}" != *"Done — pushed a fix"* ]]; then
    fail "message missing assistant answer (last-assistant-message): ${message}"
    return
  fi
  pass "message contains assistant answer (last-assistant-message)"

  if [[ "${message}" == *"Fix the login bug in auth.py"* ]]; then
    fail "message must NOT contain input-messages[0] when later turns exist: ${message}"
    return
  fi
  pass "message does NOT contain input-messages[0]"
}

# ---------------------------------------------------------------------------
# Scenario 2 — non-agent-turn-complete event must be SILENT (no notify)
# ---------------------------------------------------------------------------
scenario_other_event_silent() {
  echo "[codex:2] non-turn-complete event → no notification"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local td proj stub_log
  td="$(make_tmp)"
  proj="${td}/codexproj2"
  mkdir -p "${proj}"
  stub_log="${td}/stub.log"

  local payload
  payload="$(sed "s|__CWD_PLACEHOLDER__|${proj}|" "${FIXTURES}/codex-payload-other.json")"

  local exit_code
  set +e
  NUDGE_NOTIFY_CMD="${STUB}" \
  NUDGE_NOTIFY_STUB_LOG="${stub_log}" \
    bash "${WRAPPER}" "${payload}" >/dev/null 2>&1
  exit_code=$?
  set -e

  if [[ "${exit_code}" -ne 0 ]]; then
    fail "wrapper exit non-zero on filtered event (got ${exit_code})"
    return
  fi
  pass "exit 0 on filtered event"

  if [[ -f "${stub_log}" ]] && [[ -s "${stub_log}" ]]; then
    fail "stub was invoked on filtered event (should be silent)"
    return
  fi
  pass "no notification sent for non-turn-complete event"
}

# ---------------------------------------------------------------------------
# Scenario 3 — .cwd absent → fall back to $PWD
# ---------------------------------------------------------------------------
scenario_cwd_fallback() {
  echo "[codex:3] .cwd absent → use \$PWD basename"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local td proj stub_log
  td="$(make_tmp)"
  proj="${td}/old_codex_dir"
  mkdir -p "${proj}"
  stub_log="${td}/stub.log"

  local payload
  payload="$(cat "${FIXTURES}/codex-payload-no-cwd.json")"

  ( cd "${proj}" && \
    NUDGE_NOTIFY_CMD="${STUB}" \
    NUDGE_NOTIFY_STUB_LOG="${stub_log}" \
      bash "${WRAPPER}" "${payload}" >/dev/null 2>&1 || true )

  if [[ ! -f "${stub_log}" ]]; then
    fail "stub never called"
    return
  fi
  local title
  title="$(read_last_log "${stub_log}" title)"
  if [[ "${title}" != *"old_codex_dir"* ]]; then
    fail "title missing PWD basename 'old_codex_dir': ${title}"
    return
  fi
  pass "PWD fallback used for project basename"
}

# ---------------------------------------------------------------------------
# Scenario 4 — empty/missing argv → fail-soft (exit 0, no crash)
# ---------------------------------------------------------------------------
scenario_no_argv() {
  echo "[codex:4] missing argv[1] → fail-soft exit 0"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local td stub_log
  td="$(make_tmp)"
  stub_log="${td}/stub.log"

  local exit_code
  set +e
  NUDGE_NOTIFY_CMD="${STUB}" \
  NUDGE_NOTIFY_STUB_LOG="${stub_log}" \
    bash "${WRAPPER}" >/dev/null 2>&1
  exit_code=$?
  set -e

  if [[ "${exit_code}" -ne 0 ]]; then
    fail "wrapper exited non-zero on missing argv (got ${exit_code})"
    return
  fi
  pass "exit 0 on missing argv"
}

# ---------------------------------------------------------------------------
# Scenario 5 — regression guard: first input-message must NOT appear when
# later turns exist. This is the [0]-vs-[-1] bug pin: the wrapper used to
# read input-messages[0], which surfaced the session-opening prompt forever.
# Uses the same expanded complete fixture (input-messages has 3 elements,
# last differs from first).
# ---------------------------------------------------------------------------
scenario_first_message_not_shown() {
  echo "[codex:5] later-turn payload → first input-message must NOT appear in body"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local td proj stub_log
  td="$(make_tmp)"
  proj="${td}/codexproj5"
  mkdir -p "${proj}"
  stub_log="${td}/stub.log"

  local payload
  payload="$(sed "s|__CWD_PLACEHOLDER__|${proj}|" "${FIXTURES}/codex-payload-complete.json")"

  NUDGE_NOTIFY_CMD="${STUB}" \
  NUDGE_NOTIFY_STUB_LOG="${stub_log}" \
    bash "${WRAPPER}" "${payload}" >/dev/null 2>&1 || true

  if [[ ! -f "${stub_log}" ]]; then
    fail "stub never called"
    return
  fi
  local message
  message="$(read_last_log "${stub_log}" message)"

  if [[ "${message}" == *"Fix the login bug in auth.py"* ]]; then
    fail "regression: first input-message leaked into body — wrapper still reading [0] not [-1]: ${message}"
    return
  fi
  pass "first input-message ('Fix the login bug in auth.py') is NOT in body"
}

# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------
main() {
  if [[ ! -f "${WRAPPER}" ]]; then
    echo "FATAL: ${WRAPPER} not found — TDD red expected"
    fail "wrapper file does not exist yet"
    echo
    echo "Scenarios run: ${SCENARIOS_RUN}"
    exit 1
  fi
  chmod +x "${WRAPPER}" 2>/dev/null || true
  chmod +x "${STUB}" 2>/dev/null || true

  scenario_agent_turn_complete
  scenario_other_event_silent
  scenario_cwd_fallback
  scenario_no_argv
  scenario_first_message_not_shown

  echo
  echo "Scenarios run: ${SCENARIOS_RUN}"
  if [[ ${FAILED} -ne 0 ]]; then
    echo "RESULT: one or more scenarios FAILED" >&2
    exit 1
  fi
  echo "ALL TESTS PASSED"
}

main "$@"
