#!/usr/bin/env bash
# TDD tests for notify-gemini.sh — Gemini CLI hooks stream JSON on STDIN.
# AfterAgent has .prompt + .prompt_response. Notification has .message.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER="${REPO_ROOT}/notify-gemini.sh"
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
  d="$(mktemp -d -t nudge-notify-gemini-XXXXXX)"
  TMP_DIRS+=("${d}")
  printf '%s' "${d}"
}

read_last_log() {
  local logfile="$1" field="$2"
  local idx
  case "${field}" in title) idx=1;; message) idx=2;; priority) idx=3;; esac
  tail -n 1 "${logfile}" 2>/dev/null | awk -v i="${idx}" -F '\t' '{print $i}'
}

# ---------------------------------------------------------------------------
# Scenario 1 — AfterAgent event with .prompt → title+message present
# ---------------------------------------------------------------------------
scenario_afteragent() {
  echo "[gemini:1] AfterAgent → title with project, message with .prompt"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local td proj stub_log
  td="$(make_tmp)"
  proj="${td}/gemproj"
  mkdir -p "${proj}"
  stub_log="${td}/stub.log"

  local payload
  payload="$(sed "s|__CWD_PLACEHOLDER__|${proj}|" "${FIXTURES}/gemini-afteragent.json")"

  NUDGE_NOTIFY_CMD="${STUB}" \
  NUDGE_NOTIFY_STUB_LOG="${stub_log}" \
    bash "${WRAPPER}" <<<"${payload}" >/dev/null 2>&1 || true

  if [[ ! -f "${stub_log}" ]]; then
    fail "stub never called"
    return
  fi
  local title message
  title="$(read_last_log "${stub_log}" title)"
  message="$(read_last_log "${stub_log}" message)"

  if [[ "${title}" != *"Gemini CLI"* ]] || [[ "${title}" != *"gemproj"* ]]; then
    fail "title missing 'Gemini CLI · gemproj': ${title}"
    return
  fi
  pass "title contains 'Gemini CLI' and project basename"

  if [[ "${message}" != *"Write a unit test"* ]]; then
    fail "message missing .prompt content: ${message}"
    return
  fi
  pass "message line 3 contains .prompt"
}

# ---------------------------------------------------------------------------
# Scenario 2 — Notification event (no .prompt) → message reflects 'Waiting'
# ---------------------------------------------------------------------------
scenario_notification() {
  echo "[gemini:2] Notification event → 'Waiting' reflected, high priority"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local td proj stub_log
  td="$(make_tmp)"
  proj="${td}/gemproj2"
  mkdir -p "${proj}"
  stub_log="${td}/stub.log"

  local payload
  payload="$(sed "s|__CWD_PLACEHOLDER__|${proj}|" "${FIXTURES}/gemini-notification.json")"

  NUDGE_NOTIFY_CMD="${STUB}" \
  NUDGE_NOTIFY_STUB_LOG="${stub_log}" \
    bash "${WRAPPER}" <<<"${payload}" >/dev/null 2>&1 || true

  local message priority
  message="$(read_last_log "${stub_log}" message)"
  priority="$(read_last_log "${stub_log}" priority)"

  if [[ "${message}" != *"Waiting"* ]] && [[ "${message}" != *"approval"* ]]; then
    fail "Notification message must reflect waiting/approval; got: ${message}"
    return
  fi
  pass "Notification message reflects waiting"

  if [[ "${priority}" != "high" ]] && [[ "${priority}" != "urgent" ]]; then
    fail "Notification priority should be high/urgent, got: ${priority}"
    return
  fi
  pass "Notification priority is high/urgent"
}

# ---------------------------------------------------------------------------
# Scenario 3 — malformed JSON stdin → fail-soft basic notification
# ---------------------------------------------------------------------------
scenario_bad_json() {
  echo "[gemini:3] malformed JSON → fail-soft, basic notification"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local td proj stub_log
  td="$(make_tmp)"
  proj="${td}/projG"
  mkdir -p "${proj}"
  stub_log="${td}/stub.log"

  local exit_code
  set +e
  ( cd "${proj}" && \
    NUDGE_NOTIFY_CMD="${STUB}" \
    NUDGE_NOTIFY_STUB_LOG="${stub_log}" \
      bash "${WRAPPER}" <<<'not json {{' >/dev/null 2>&1 )
  exit_code=$?
  set -e

  if [[ "${exit_code}" -ne 0 ]]; then
    fail "wrapper exit non-zero on malformed JSON (got ${exit_code})"
    return
  fi
  pass "exit 0 (fail-soft) on bad JSON"

  if [[ ! -f "${stub_log}" ]]; then
    fail "no basic notification sent on bad JSON"
    return
  fi
  local title
  title="$(read_last_log "${stub_log}" title)"
  if [[ "${title}" != *"Gemini CLI"* ]]; then
    fail "basic notification missing 'Gemini CLI': ${title}"
    return
  fi
  pass "basic notification sent on bad JSON"
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

  scenario_afteragent
  scenario_notification
  scenario_bad_json

  echo
  echo "Scenarios run: ${SCENARIOS_RUN}"
  if [[ ${FAILED} -ne 0 ]]; then
    echo "RESULT: one or more scenarios FAILED" >&2
    exit 1
  fi
  echo "ALL TESTS PASSED"
}

main "$@"
