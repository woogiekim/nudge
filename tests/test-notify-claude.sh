#!/usr/bin/env bash
# TDD tests for notify-claude.sh (the per-tool wrapper that reads Claude Code's
# Stop / Notification hook JSON on stdin and emits a context-rich 3-line
# notification via notify.sh).
#
# Test contract:
# - Uses ONLY fixtures from tests/_fixtures/; never touches real ~/.claude.
# - Wrapper's call to notify.sh is intercepted by NUDGE_NOTIFY_CMD pointing
#   at tests/_fixtures/notify-stub.sh, which logs args to a temp file.
# - Each scenario asserts on the stub log (title \t message \t priority).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER="${REPO_ROOT}/notify-claude.sh"
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
  d="$(mktemp -d -t nudge-notify-claude-XXXXXX)"
  TMP_DIRS+=("${d}")
  printf '%s' "${d}"
}

# Read the stub log and return the most recent record's TITLE / MESSAGE / PRIORITY.
read_last_log() {
  local logfile="$1" field="$2"
  local line idx
  line="$(tail -n 1 "${logfile}" 2>/dev/null || true)"
  case "${field}" in
    title)    idx=1 ;;
    message)  idx=2 ;;
    priority) idx=3 ;;
    *)        echo "bad field" >&2; return 1 ;;
  esac
  printf '%s' "${line}" | awk -v i="${idx}" -F '\t' '{print $i}'
}

# Count log lines.
count_log() {
  local logfile="$1"
  if [[ ! -f "${logfile}" ]]; then echo 0; return; fi
  wc -l < "${logfile}" | tr -d ' '
}

# ---------------------------------------------------------------------------
# Scenario 1 — aiTitle present in transcript
# ---------------------------------------------------------------------------
scenario_aititle() {
  echo "[claude:1] aiTitle present → title='Claude Code · <project>', line3=💬 <aiTitle>"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local td proj transcript stub_log
  td="$(make_tmp)"
  proj="${td}/myproj"
  mkdir -p "${proj}"
  transcript="${td}/transcript.jsonl"
  cp "${FIXTURES}/transcript-with-aititle.jsonl" "${transcript}"
  stub_log="${td}/stub.log"

  local stdin_json
  stdin_json="$(jq -n --arg cwd "${proj}" --arg t "${transcript}" \
    '{cwd:$cwd, transcript_path:$t, session_id:"s1", hook_event_name:"Stop"}')"

  NUDGE_NOTIFY_CMD="${STUB}" \
  NUDGE_NOTIFY_STUB_LOG="${stub_log}" \
    bash "${WRAPPER}" <<<"${stdin_json}" >/dev/null 2>&1 || true

  if [[ ! -f "${stub_log}" ]]; then
    fail "stub was never invoked (no log)"
    return
  fi

  local title message
  title="$(read_last_log "${stub_log}" title)"
  message="$(read_last_log "${stub_log}" message)"

  if [[ "${title}" != *"Claude Code"* ]]; then
    fail "title missing 'Claude Code': ${title}"
    return
  fi
  if [[ "${title}" != *"myproj"* ]]; then
    fail "title missing project basename 'myproj': ${title}"
    return
  fi
  pass "title contains 'Claude Code' and project basename"

  if [[ "${message}" != *"OAuth refactor"* ]]; then
    fail "message missing aiTitle 'OAuth refactor': ${message}"
    return
  fi
  pass "message line 3 contains aiTitle"
}

# ---------------------------------------------------------------------------
# Scenario 2 — aiTitle absent, fallback to lastPrompt
# ---------------------------------------------------------------------------
scenario_prompt_fallback() {
  echo "[claude:2] aiTitle absent → line3=💬 <lastPrompt>"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local td proj transcript stub_log
  td="$(make_tmp)"
  proj="${td}/projB"
  mkdir -p "${proj}"
  transcript="${td}/transcript.jsonl"
  cp "${FIXTURES}/transcript-prompt-only.jsonl" "${transcript}"
  stub_log="${td}/stub.log"

  local stdin_json
  stdin_json="$(jq -n --arg cwd "${proj}" --arg t "${transcript}" \
    '{cwd:$cwd, transcript_path:$t, session_id:"s1", hook_event_name:"Stop"}')"

  NUDGE_NOTIFY_CMD="${STUB}" \
  NUDGE_NOTIFY_STUB_LOG="${stub_log}" \
    bash "${WRAPPER}" <<<"${stdin_json}" >/dev/null 2>&1 || true

  if [[ ! -f "${stub_log}" ]]; then
    fail "stub was never invoked"
    return
  fi
  local message
  message="$(read_last_log "${stub_log}" message)"
  if [[ "${message}" != *"Fix the broken login page"* ]]; then
    fail "message missing fallback prompt: ${message}"
    return
  fi
  pass "message contains fallback lastPrompt"
}

# ---------------------------------------------------------------------------
# Scenario 3 — transcript missing → fail-soft basic notification
# ---------------------------------------------------------------------------
scenario_transcript_missing() {
  echo "[claude:3] transcript missing → still send basic '{Tool} · {project}'"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local td proj stub_log
  td="$(make_tmp)"
  proj="${td}/projC"
  mkdir -p "${proj}"
  stub_log="${td}/stub.log"

  local stdin_json
  stdin_json="$(jq -n --arg cwd "${proj}" \
    '{cwd:$cwd, transcript_path:"/nonexistent/transcript.jsonl", session_id:"s1", hook_event_name:"Stop"}')"

  local exit_code
  set +e
  NUDGE_NOTIFY_CMD="${STUB}" \
  NUDGE_NOTIFY_STUB_LOG="${stub_log}" \
    bash "${WRAPPER}" <<<"${stdin_json}" >/dev/null 2>&1
  exit_code=$?
  set -e

  if [[ "${exit_code}" -ne 0 ]]; then
    fail "wrapper exited non-zero on missing transcript (got ${exit_code})"
    return
  fi
  pass "wrapper exit 0 (fail-soft)"

  if [[ ! -f "${stub_log}" ]]; then
    fail "stub never called — fail-soft should still notify"
    return
  fi
  local title
  title="$(read_last_log "${stub_log}" title)"
  if [[ "${title}" != *"Claude Code"* ]] || [[ "${title}" != *"projC"* ]]; then
    fail "basic notification missing 'Claude Code · projC': ${title}"
    return
  fi
  pass "basic notification sent even without transcript"
}

# ---------------------------------------------------------------------------
# Scenario 4 — Notification event (line 2 should reflect 'Waiting for input')
# ---------------------------------------------------------------------------
scenario_notification_event() {
  echo "[claude:4] Notification event → line 2 reflects 'Waiting'"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local td proj transcript stub_log
  td="$(make_tmp)"
  proj="${td}/projD"
  mkdir -p "${proj}"
  transcript="${td}/transcript.jsonl"
  cp "${FIXTURES}/transcript-with-aititle.jsonl" "${transcript}"
  stub_log="${td}/stub.log"

  local stdin_json
  stdin_json="$(jq -n --arg cwd "${proj}" --arg t "${transcript}" \
    '{cwd:$cwd, transcript_path:$t, session_id:"s1", hook_event_name:"Notification", message:"need approval", notification_type:"approval"}')"

  NUDGE_NOTIFY_CMD="${STUB}" \
  NUDGE_NOTIFY_STUB_LOG="${stub_log}" \
    bash "${WRAPPER}" <<<"${stdin_json}" >/dev/null 2>&1 || true

  local message priority
  message="$(read_last_log "${stub_log}" message)"
  priority="$(read_last_log "${stub_log}" priority)"

  if [[ "${message}" != *"Waiting"* ]] && [[ "${message}" != *"need approval"* ]]; then
    fail "Notification message must reflect waiting/approval; got: ${message}"
    return
  fi
  pass "Notification event reflected in message"

  if [[ "${priority}" != "high" ]] && [[ "${priority}" != "urgent" ]]; then
    fail "Notification should use high priority, got: ${priority}"
    return
  fi
  pass "Notification priority is high/urgent"
}

# ---------------------------------------------------------------------------
# Scenario 5 — long prompt truncated to ~70 chars
# ---------------------------------------------------------------------------
scenario_truncation() {
  echo "[claude:5] long prompt → truncated"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local td proj transcript stub_log
  td="$(make_tmp)"
  proj="${td}/projE"
  mkdir -p "${proj}"
  transcript="${td}/transcript.jsonl"
  cp "${FIXTURES}/transcript-long-prompt.jsonl" "${transcript}"
  stub_log="${td}/stub.log"

  local stdin_json
  stdin_json="$(jq -n --arg cwd "${proj}" --arg t "${transcript}" \
    '{cwd:$cwd, transcript_path:$t, session_id:"s1", hook_event_name:"Stop"}')"

  NUDGE_NOTIFY_CMD="${STUB}" \
  NUDGE_NOTIFY_STUB_LOG="${stub_log}" \
    bash "${WRAPPER}" <<<"${stdin_json}" >/dev/null 2>&1 || true

  local message
  message="$(read_last_log "${stub_log}" message)"
  # The escaped log uses literal \n; tests look only for prefix of the prompt
  # and the absence of the FULL un-truncated string.
  local full="This is a very long prompt that should absolutely be truncated to about seventy characters and not show the entire body of the question"
  if [[ "${message}" == *"${full}"* ]]; then
    fail "long prompt not truncated"
    return
  fi
  pass "long prompt truncated"
}

# ---------------------------------------------------------------------------
# Scenario 6 — multiline prompt → newlines collapsed to spaces
# ---------------------------------------------------------------------------
scenario_multiline() {
  echo "[claude:6] multiline prompt → newlines collapsed"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local td proj transcript stub_log
  td="$(make_tmp)"
  proj="${td}/projF"
  mkdir -p "${proj}"
  transcript="${td}/transcript.jsonl"
  cp "${FIXTURES}/transcript-multiline-prompt.jsonl" "${transcript}"
  stub_log="${td}/stub.log"

  local stdin_json
  stdin_json="$(jq -n --arg cwd "${proj}" --arg t "${transcript}" \
    '{cwd:$cwd, transcript_path:$t, session_id:"s1", hook_event_name:"Stop"}')"

  NUDGE_NOTIFY_CMD="${STUB}" \
  NUDGE_NOTIFY_STUB_LOG="${stub_log}" \
    bash "${WRAPPER}" <<<"${stdin_json}" >/dev/null 2>&1 || true

  local message
  message="$(read_last_log "${stub_log}" message)"
  # Stub records embedded \n as the two-character escape \n. The wrapper must
  # collapse the prompt's newlines BEFORE handing to notify.sh, so the message
  # line containing 'line one line two line three' or similar appears without
  # an EMBEDDED \n between those words.
  # Look for "line one" followed (within a few chars) by "line two" with NO
  # backslash-n between them.
  if ! echo "${message}" | grep -E "line one[^\\]*line two" >/dev/null; then
    fail "multiline prompt: newlines were not collapsed inside the message body: ${message}"
    return
  fi
  pass "multiline prompt newlines collapsed to spaces"
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
    echo "RESULT: FAILED (TDD red)" >&2
    exit 1
  fi
  chmod +x "${WRAPPER}" 2>/dev/null || true
  chmod +x "${STUB}" 2>/dev/null || true

  scenario_aititle
  scenario_prompt_fallback
  scenario_transcript_missing
  scenario_notification_event
  scenario_truncation
  scenario_multiline

  echo
  echo "Scenarios run: ${SCENARIOS_RUN}"
  if [[ ${FAILED} -ne 0 ]]; then
    echo "RESULT: one or more scenarios FAILED" >&2
    exit 1
  fi
  echo "ALL TESTS PASSED"
}

main "$@"
