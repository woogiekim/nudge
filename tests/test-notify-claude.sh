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
START_HOOK="${REPO_ROOT}/notify-claude-turn-start.sh"
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

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  elif command -v python3 >/dev/null 2>&1; then
    printf '%s' "$1" | python3 -c 'import hashlib,sys; sys.stdout.write(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
  else
    printf 'fallback'
  fi
}

stamp_key_for_cwd() {
  sha256_of "$1"
}

write_stamp_for_cwd() {
  local home_dir="$1" cwd="$2" age_seconds="$3"
  local key stamp_dir now ago
  key="$(stamp_key_for_cwd "${cwd}")"
  stamp_dir="${home_dir}/.nudge/turn-stamps"
  mkdir -p "${stamp_dir}"
  now="$(date +%s)"
  ago=$((now - age_seconds))
  printf '%s\n' "${ago}" > "${stamp_dir}/${key}"
  printf '%s' "${stamp_dir}/${key}"
}

# ---------------------------------------------------------------------------
# Scenario 1 — aiTitle AND lastPrompt both present → lastPrompt wins,
# aiTitle is only a fallback. Body uses the 'Q: ' prefix (no 💬).
# Spec: prd.md § Feature 2 + Feature 1, acceptance criterion
#       "Q: Refactor the auth flow to support OAuth", NOT 'Q: OAuth refactor'
#       and NOT '💬 OAuth refactor'.
# ---------------------------------------------------------------------------
scenario_aititle() {
  echo "[claude:1] aiTitle+lastPrompt both present → line3='Q: <lastPrompt>' (aiTitle loses)"
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

  # Inverted priority: lastPrompt wins over aiTitle.
  if [[ "${message}" != *"Refactor the auth flow to support OAuth"* ]]; then
    fail "message missing lastPrompt 'Refactor the auth flow to support OAuth' (priority should prefer lastPrompt over aiTitle): ${message}"
    return
  fi
  pass "message line 3 contains lastPrompt (preferred over aiTitle)"

  # Regression: aiTitle must NOT be the body — it is only a fallback.
  if [[ "${message}" == *"OAuth refactor"* ]]; then
    fail "message unexpectedly contains aiTitle 'OAuth refactor' — aiTitle must be a final fallback, not preferred: ${message}"
    return
  fi
  pass "message does NOT contain aiTitle (aiTitle is fallback-only)"

  # Shared composer must use 'Q: ' prefix, not 💬.
  if [[ "${message}" == *"💬"* ]]; then
    fail "message must not contain the legacy 💬 emoji (composer should emit 'Q: '): ${message}"
    return
  fi
  pass "message does NOT contain the legacy 💬 emoji"

  if [[ "${message}" != *"Q: Refactor the auth flow to support OAuth"* ]]; then
    fail "message missing 'Q: <lastPrompt>' prefix from shared composer: ${message}"
    return
  fi
  pass "message contains 'Q: <lastPrompt>' (shared composer prefix)"
}

# ---------------------------------------------------------------------------
# Scenario 2 — aiTitle absent → lastPrompt is used; body uses 'Q: ' prefix.
# Spec: prd.md § Feature 2 step 2 (lastPrompt fallback) + § Feature 1.
# ---------------------------------------------------------------------------
scenario_prompt_fallback() {
  echo "[claude:2] aiTitle absent → line3='Q: <lastPrompt>'"
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

  # Composer must emit 'Q: ' prefix, not 💬.
  if [[ "${message}" == *"💬"* ]]; then
    fail "message must not contain the legacy 💬 emoji: ${message}"
    return
  fi
  if [[ "${message}" != *"Q: Fix the broken login page"* ]]; then
    fail "message missing 'Q: <lastPrompt>' prefix from shared composer: ${message}"
    return
  fi
  pass "message uses 'Q: ' prefix (no 💬)"
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
# Scenario 7 — LAST type=="user" record with genuine text wins over both
# lastPrompt and aiTitle; a trailing user record whose first content block
# is a tool_result (not text), and a trailing assistant record, must NOT
# capture the body.
# Spec: prd.md § Feature 2 step 1 (LAST type=="user" with genuine human text).
#
# Acceptable behavior (per PRD): if backend opts to degrade to the simpler
# two-tier inversion (lastPrompt → aiTitle → empty) and records that decision
# in tdd-refactor.md, then 'Outdated last prompt entry' (the lastPrompt)
# becomes the expected body instead. This scenario asserts the strengthened
# behavior; the test-coverage matrix documents the acceptable degradation.
# ---------------------------------------------------------------------------
scenario_last_user_wins() {
  echo "[claude:7] LAST type=='user' with genuine text wins over lastPrompt+aiTitle; trailing tool_result/assistant ignored"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local td proj transcript stub_log
  td="$(make_tmp)"
  proj="${td}/projLast"
  mkdir -p "${proj}"
  transcript="${td}/transcript.jsonl"
  cp "${FIXTURES}/transcript-last-user-wins.jsonl" "${transcript}"
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

  # The LAST user record with genuine human text content wins.
  if [[ "${message}" != *"Current turn — please answer this question"* ]]; then
    fail "message missing LAST user-text 'Current turn — please answer this question': ${message}"
    return
  fi
  pass "message contains LAST user-record text"

  # The trailing user record whose first content block is type=='tool_result'
  # must NOT have its embedded shell-output text leak in.
  if [[ "${message}" == *"shell output that must be ignored"* ]]; then
    fail "message unexpectedly contains tool_result content — picker must require genuine human text (content[0].type=='text'): ${message}"
    return
  fi
  pass "message does NOT contain trailing tool_result content"

  # An earlier user record must not win over a later one.
  if [[ "${message}" == *"Earliest human turn"* ]]; then
    fail "message unexpectedly contains earlier user text 'Earliest human turn' — picker should select the LAST qualifying user record: ${message}"
    return
  fi
  pass "message does NOT contain earlier user-record text"

  # aiTitle is the LOWEST-priority fallback; it must lose to a real user turn.
  if [[ "${message}" == *"Frozen session topic"* ]]; then
    fail "message unexpectedly contains aiTitle 'Frozen session topic' — aiTitle must lose to a real user turn: ${message}"
    return
  fi
  pass "message does NOT contain aiTitle"

  # Composer prefix sanity (also locks in the 💬 → Q: change).
  if [[ "${message}" == *"💬"* ]]; then
    fail "message must not contain the legacy 💬 emoji: ${message}"
    return
  fi
  if [[ "${message}" != *"Q: Current turn — please answer this question"* ]]; then
    fail "message missing 'Q: <last-user-text>' prefix from shared composer: ${message}"
    return
  fi
  pass "message uses 'Q: ' prefix with last-user-text"
}

# ---------------------------------------------------------------------------
# Scenario 8 — isMeta:true skill expansion + tool_result user records are
# SKIPPED; the genuine prior human prompt wins.
# Spec: prd.md § Feature 1 (filter isMeta + toolUseResult) and Feature 5
#       (regression fixture transcript-skill-expansion.jsonl).
# ---------------------------------------------------------------------------
scenario_skip_skill_expansion() {
  echo "[claude:8] isMeta + tool_result user records skipped → prior genuine prompt wins"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local td proj transcript stub_log
  td="$(make_tmp)"
  proj="${td}/projSkill"
  mkdir -p "${proj}"
  transcript="${td}/transcript.jsonl"
  cp "${FIXTURES}/transcript-skill-expansion.jsonl" "${transcript}"
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

  # The genuine prior human prompt must be the body.
  if [[ "${message}" != *"Please summarize the order flow"* ]]; then
    fail "message missing genuine human prompt 'Please summarize the order flow': ${message}"
    return
  fi
  pass "message contains genuine human prompt"

  # isMeta:true skill-expansion body MUST NOT leak in.
  if [[ "${message}" == *"# crew:run"* ]]; then
    fail "message unexpectedly contains skill-expansion body '# crew:run' (isMeta:true must be filtered): ${message}"
    return
  fi
  pass "message does NOT contain '# crew:run' skill body"

  # tool_result user record body MUST NOT leak in.
  if [[ "${message}" == *"Launching skill"* ]]; then
    fail "message unexpectedly contains tool_result body 'Launching skill' (toolUseResult must be filtered): ${message}"
    return
  fi
  pass "message does NOT contain 'Launching skill' tool_result body"

  # Composer prefix sanity.
  if [[ "${message}" != *"Q: Please summarize the order flow"* ]]; then
    fail "message missing 'Q: <genuine-prompt>' prefix: ${message}"
    return
  fi
  pass "message uses 'Q: ' prefix with genuine prompt"
}

# ---------------------------------------------------------------------------
# Scenario 9 — string content starting with '<command-message>' is treated as
# an injected sentinel, not a human prompt; prior genuine prompt wins.
# Spec: prd.md § Feature 2 (8-prefix sentinel list, '<command-message>' case).
# ---------------------------------------------------------------------------
scenario_skip_command_message_string() {
  echo "[claude:9] last user record is '<command-message>...' string → prior genuine prompt wins"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local td proj transcript stub_log
  td="$(make_tmp)"
  proj="${td}/projCmdMsg"
  mkdir -p "${proj}"
  transcript="${td}/transcript.jsonl"
  cp "${FIXTURES}/transcript-with-command-message.jsonl" "${transcript}"
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

  if [[ "${message}" != *"Please summarize the order flow"* ]]; then
    fail "message missing genuine prior prompt 'Please summarize the order flow': ${message}"
    return
  fi
  pass "message contains prior genuine human prompt"

  if [[ "${message}" == *"<command-message>"* ]]; then
    fail "message unexpectedly contains '<command-message>' sentinel body (must be filtered): ${message}"
    return
  fi
  pass "message does NOT contain '<command-message>' sentinel body"

  if [[ "${message}" != *"Q: Please summarize the order flow"* ]]; then
    fail "message missing 'Q: <genuine-prompt>' prefix: ${message}"
    return
  fi
  pass "message uses 'Q: ' prefix with prior genuine prompt"
}

# ---------------------------------------------------------------------------
# Scenario 10 — string content starting with '<bash-input>' is treated as an
# injected sentinel, not a human prompt; prior genuine prompt wins.
# Spec: prd.md § Feature 2 (8-prefix sentinel list, '<bash-input>' case).
# ---------------------------------------------------------------------------
scenario_skip_bash_input_string() {
  echo "[claude:10] last user record is '<bash-input>...' string → prior genuine prompt wins"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local td proj transcript stub_log
  td="$(make_tmp)"
  proj="${td}/projBashIn"
  mkdir -p "${proj}"
  transcript="${td}/transcript.jsonl"
  cp "${FIXTURES}/transcript-with-bash-input.jsonl" "${transcript}"
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

  if [[ "${message}" != *"Please summarize the order flow"* ]]; then
    fail "message missing genuine prior prompt 'Please summarize the order flow': ${message}"
    return
  fi
  pass "message contains prior genuine human prompt"

  if [[ "${message}" == *"<bash-input>"* ]]; then
    fail "message unexpectedly contains '<bash-input>' sentinel body (must be filtered): ${message}"
    return
  fi
  pass "message does NOT contain '<bash-input>' sentinel body"

  if [[ "${message}" == *"echo hi"* ]]; then
    fail "message unexpectedly contains bash-input payload 'echo hi' (must be filtered): ${message}"
    return
  fi
  pass "message does NOT contain bash-input payload"

  if [[ "${message}" != *"Q: Please summarize the order flow"* ]]; then
    fail "message missing 'Q: <genuine-prompt>' prefix: ${message}"
    return
  fi
  pass "message uses 'Q: ' prefix with prior genuine prompt"
}

# ===========================================================================
# Q + A parity scenarios (PRD: Claude Stop-hook banner Q + A parity).
#
# These three scenarios pin the new contract added to notify-claude.sh: the
# composed body delivered to notify.sh must surface BOTH the user prompt
# (`Q: ...`) AND the trailing assistant answer (`A: ...`) on separate
# LF-delimited segments — mirroring the Codex path (notify-codex.sh) which
# already assembles a 3-segment body.
#
# Body shape under test (matching notify-codex.sh):
#   <LINE2>\nQ: <Q>\nA: <A>     (3-segment — Q + A both present)
#   <LINE2>\nQ: <Q>             (2-segment — A omitted entirely)
#
# Each scenario builds a small Claude-shaped JSONL on the fly (or via
# tests/_fixtures/), points the wrapper at it, and asserts on the body
# captured by the notify-stub.
#
# A-extraction rule under test (per PRD § Core Features):
#   - Read every record with .type=="assistant".
#   - Within each record, scan .message.content[] for blocks of .type=="text"
#     whose .text is non-empty.
#   - Emit the LAST non-empty .text observed across the whole turn.
#   - If no non-empty text block exists (e.g. the turn ended in tool_use only),
#     emit no A line — the body is the 2-segment Q-only shape.
# ===========================================================================

# Extract the Q segment from a stub-captured body. The stub-captured body uses
# the 2-char escape sequence "\n" in place of real LFs.
# Returns the substring after "Q: " and before the next "\n" (or end-of-body).
extract_q_segment() {
  local body="$1"
  if [[ "${body}" != *'Q: '* ]]; then
    printf ''
    return 0
  fi
  local after_q="${body#*Q: }"
  local q_seg
  if [[ "${after_q}" == *'\n'* ]]; then
    q_seg="${after_q%%\\n*}"
  else
    q_seg="${after_q}"
  fi
  printf '%s' "${q_seg}"
}

# Extract the A segment from a stub-captured body. Returns the substring after
# "A: " and before the next "\n" (or end-of-body). Returns empty string if no
# "A: " marker exists in the body.
extract_a_segment() {
  local body="$1"
  if [[ "${body}" != *'A: '* ]]; then
    printf ''
    return 0
  fi
  local after_a="${body#*A: }"
  local a_seg
  if [[ "${after_a}" == *'\n'* ]]; then
    a_seg="${after_a%%\\n*}"
  else
    a_seg="${after_a}"
  fi
  printf '%s' "${a_seg}"
}

# ---------------------------------------------------------------------------
# Scenario (a) — Turn ends in an assistant text block
# ---------------------------------------------------------------------------
# Spec: prd.md § Scenario A — "Given a Claude transcript JSONL whose last
#       assistant record has a non-empty text block in .message.content[]
#       ... Then the composed body sent to notify.sh contains both a 'Q:' line
#       and an 'A:' line ... And the 'A:' line equals the normalized,
#       truncated text from that text block."
scenario_qa_text_end() {
  echo "[claude:a] turn ends in assistant text block → body has BOTH Q: and A: on separate LF-delimited segments"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local td proj transcript stub_log
  td="$(make_tmp)"
  proj="${td}/projQAtext"
  mkdir -p "${proj}"
  transcript="${td}/transcript.jsonl"
  cp "${FIXTURES}/transcript-claude-qa-text-end.jsonl" "${transcript}"
  stub_log="${td}/stub.log"

  local stdin_json
  stdin_json="$(jq -n --arg cwd "${proj}" --arg t "${transcript}" \
    '{cwd:$cwd, transcript_path:$t, session_id:"qa-a", hook_event_name:"Stop"}')"

  NUDGE_NOTIFY_CMD="${STUB}" \
  NUDGE_NOTIFY_STUB_LOG="${stub_log}" \
    bash "${WRAPPER}" <<<"${stdin_json}" >/dev/null 2>&1 || true

  if [[ ! -f "${stub_log}" ]] || [[ ! -s "${stub_log}" ]]; then
    fail "(a) stub never called"
    return
  fi

  local body
  body="$(read_last_log "${stub_log}" message)"

  # The body must carry an A line at all (this is the headline regression — the
  # current notify-claude.sh emits Q only).
  if [[ "${body}" != *'A: '* ]]; then
    fail "(a) body missing 'A: ' segment — Claude path is still Q-only: '${body}'"
    return
  fi
  pass "(a) body contains 'A: ' segment (Q + A parity)"

  # Q content must still appear.
  if [[ "${body}" != *"Q: What is two plus two?"* ]]; then
    fail "(a) body missing expected Q content 'Q: What is two plus two?': '${body}'"
    return
  fi
  pass "(a) body contains expected Q text"

  # A content must be the assistant's text block content.
  local a_seg
  a_seg="$(extract_a_segment "${body}")"
  if [[ "${a_seg}" != *"Two plus two is four."* ]]; then
    fail "(a) A segment missing expected answer text 'Two plus two is four.'; a_seg='${a_seg}'; body='${body}'"
    return
  fi
  pass "(a) A segment carries the assistant text-block content"

  # Q and A must live on separate LF-delimited segments (no two-space join).
  # The notify-stub renders embedded LFs as the 2-char marker "\n". A 3-segment
  # body (LINE2 + Q + A) therefore contains exactly TWO "\n" markers.
  local lf_count
  lf_count=$(printf '%s' "${body}" | awk 'BEGIN{ FS="\\\\n" } { print NF - 1 }')
  if [[ "${lf_count}" -lt 2 ]]; then
    fail "(a) expected at least 2 LFs (3-segment LINE2/Q/A body); got ${lf_count}; body='${body}'"
    return
  fi
  pass "(a) body has at least 2 LFs (Q and A on their own LF-delimited segments)"
}

# ---------------------------------------------------------------------------
# Scenario (b) — Turn ends in a tool_use block (no trailing assistant prose)
# ---------------------------------------------------------------------------
# Spec: prd.md § Scenario B — "Given a Claude transcript JSONL whose last
#       assistant record contains only tool_use blocks ... Then the composed
#       body sent to notify.sh contains a 'Q:' line And the body contains NO
#       'A:' line (the A segment is omitted entirely)."
#
# Important: the fixture intentionally has an EARLIER assistant text block
# ("Sure, kicking off the build now.") that the picker MUST NOT pick — because
# the LAST assistant record carries no text content. The A-extraction rule is
# "LAST assistant record with a non-empty text block", and the rule must agree
# with the PRD wording that ties the A line to the trailing-assistant turn.
#
# The PRD §Scenario B prose makes the intent explicit ("Turn ends on a tool_use
# block (no trailing prose) → body contains NO 'A:' line"). The fixture builds
# this case by placing the tool_use record AFTER the only text block, so the
# "turn ended in a tool_use" semantics is what the picker must enforce.
scenario_qa_tool_end() {
  echo "[claude:b] turn ends in tool_use block → body has Q: but NO A: line"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local td proj transcript stub_log
  td="$(make_tmp)"
  proj="${td}/projQAtool"
  mkdir -p "${proj}"
  transcript="${td}/transcript.jsonl"
  cp "${FIXTURES}/transcript-claude-qa-tool-end.jsonl" "${transcript}"
  stub_log="${td}/stub.log"

  local stdin_json
  stdin_json="$(jq -n --arg cwd "${proj}" --arg t "${transcript}" \
    '{cwd:$cwd, transcript_path:$t, session_id:"qa-b", hook_event_name:"Stop"}')"

  NUDGE_NOTIFY_CMD="${STUB}" \
  NUDGE_NOTIFY_STUB_LOG="${stub_log}" \
    bash "${WRAPPER}" <<<"${stdin_json}" >/dev/null 2>&1 || true

  if [[ ! -f "${stub_log}" ]] || [[ ! -s "${stub_log}" ]]; then
    fail "(b) stub never called"
    return
  fi

  local body
  body="$(read_last_log "${stub_log}" message)"

  # Q must still be present.
  if [[ "${body}" != *"Q: Run the build please"* ]]; then
    fail "(b) body missing expected Q content 'Q: Run the build please': '${body}'"
    return
  fi
  pass "(b) body contains expected Q text"

  # The A: line MUST be omitted entirely. No bare "A:" segment may appear.
  if [[ "${body}" == *'A: '* ]]; then
    fail "(b) body unexpectedly contains 'A: ' segment when last assistant record is tool_use only: '${body}'"
    return
  fi
  pass "(b) body does NOT contain 'A: ' segment (A omitted for tool-only turn)"

  # And no stray bare "A:" (even with no trailing space) — empty-A omit policy
  # must never emit a degenerate "A:" with nothing after.
  if printf '%s' "${body}" | grep -E '(^|\\n)A:( |$|\\n)' >/dev/null 2>&1; then
    fail "(b) body has a bare 'A:' segment (empty-A omit policy violated): '${body}'"
    return
  fi
  pass "(b) body has no bare 'A:' segment (empty-A omit policy honored)"
}

# ---------------------------------------------------------------------------
# Scenario (c) — Multiple assistant text blocks → A equals the LAST non-empty
# ---------------------------------------------------------------------------
# Spec: prd.md § Scenario C — "Given a Claude transcript JSONL where several
#       assistant records carry non-empty text blocks across the same turn
#       ... Then the 'A:' line equals the LAST non-empty text block in that
#       turn, not an earlier one."
#
# The fixture interleaves three assistant records carrying text (FIRST /
# MIDDLE / FINAL) with tool_use records, so a naive "last assistant record"
# selector would pick the trailing tool_use record (which has no text) and a
# naive "first text" selector would pick the FIRST block. The correct behavior
# is: the LAST non-empty text content across the turn.
scenario_qa_multiple_text() {
  echo "[claude:c] multiple assistant text blocks → A equals the LAST non-empty text block"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local td proj transcript stub_log
  td="$(make_tmp)"
  proj="${td}/projQAmulti"
  mkdir -p "${proj}"
  transcript="${td}/transcript.jsonl"
  cp "${FIXTURES}/transcript-claude-qa-multiple-text.jsonl" "${transcript}"
  stub_log="${td}/stub.log"

  local stdin_json
  stdin_json="$(jq -n --arg cwd "${proj}" --arg t "${transcript}" \
    '{cwd:$cwd, transcript_path:$t, session_id:"qa-c", hook_event_name:"Stop"}')"

  NUDGE_NOTIFY_CMD="${STUB}" \
  NUDGE_NOTIFY_STUB_LOG="${stub_log}" \
    bash "${WRAPPER}" <<<"${stdin_json}" >/dev/null 2>&1 || true

  if [[ ! -f "${stub_log}" ]] || [[ ! -s "${stub_log}" ]]; then
    fail "(c) stub never called"
    return
  fi

  local body
  body="$(read_last_log "${stub_log}" message)"

  # The A line must exist (parity precondition).
  if [[ "${body}" != *'A: '* ]]; then
    fail "(c) body missing 'A: ' segment — Q-only output indicates parity not implemented: '${body}'"
    return
  fi

  local a_seg
  a_seg="$(extract_a_segment "${body}")"

  # MUST contain the FINAL block's text.
  if [[ "${a_seg}" != *"FINAL assistant text block"* ]]; then
    fail "(c) A segment missing the LAST non-empty text block 'FINAL assistant text block'; a_seg='${a_seg}'; body='${body}'"
    return
  fi
  pass "(c) A segment carries the LAST non-empty assistant text block"

  # MUST NOT contain the FIRST block's content (regression: a naive selector
  # that always picks the first text block would surface this).
  if [[ "${a_seg}" == *"FIRST assistant text block"* ]]; then
    fail "(c) A segment unexpectedly contains the FIRST text block — selector is picking earliest instead of latest text: '${a_seg}'"
    return
  fi
  pass "(c) A segment does NOT contain the FIRST text block (latest-text rule honored)"

  # MUST NOT contain the MIDDLE block's content (regression: a "second-to-last
  # record" selector might surface this).
  if [[ "${a_seg}" == *"MIDDLE assistant text block"* ]]; then
    fail "(c) A segment unexpectedly contains the MIDDLE text block — selector is not scanning to the last non-empty text: '${a_seg}'"
    return
  fi
  pass "(c) A segment does NOT contain the MIDDLE text block"
}

# ---------------------------------------------------------------------------
# Scenario 14 — fast-turn stamp (60s ago) -> skip, no banner, stamp consumed
# ---------------------------------------------------------------------------
scenario_fast_turn_stamp_skip() {
  echo "[claude:14] stamp 60s ago + NUDGE_MIN_TURN_SEC=180 -> skip, no banner, stamp consumed"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local td proj transcript stub_log stamp_file
  td="$(make_tmp)"
  proj="${td}/projFast"
  mkdir -p "${proj}"
  transcript="${td}/transcript.jsonl"
  cp "${FIXTURES}/transcript-prompt-only.jsonl" "${transcript}"
  stub_log="${td}/stub.log"
  stamp_file="$(write_stamp_for_cwd "${td}" "${proj}" 60)"

  local stdin_json
  stdin_json="$(jq -n --arg cwd "${proj}" --arg t "${transcript}" \
    '{cwd:$cwd, transcript_path:$t, hook_event_name:"Stop"}')"

  local exit_code
  set +e
  HOME="${td}" \
  NUDGE_NOTIFY_CMD="${STUB}" \
  NUDGE_NOTIFY_STUB_LOG="${stub_log}" \
  NUDGE_MIN_TURN_SEC=180 \
    bash "${WRAPPER}" <<<"${stdin_json}" >/dev/null 2>&1
  exit_code=$?
  set -e

  if [[ "${exit_code}" -ne 0 ]]; then
    fail "expected exit 0 on fast-turn skip, got ${exit_code}"
    return
  fi
  pass "exit 0 on fast-turn skip"

  if [[ -f "${stub_log}" ]] && [[ -s "${stub_log}" ]]; then
    fail "stub was invoked on fast-turn skip; log=$(cat "${stub_log}")"
    return
  fi
  pass "no banner dispatched on fast-turn skip"

  if [[ -f "${stamp_file}" ]]; then
    fail "stamp file should have been consumed on skip path; still present at ${stamp_file}"
    return
  fi
  pass "stamp file consumed on skip path"
}

# ---------------------------------------------------------------------------
# Scenario 15 — slow-turn stamp (200s ago) -> banner sent, stamp consumed
# ---------------------------------------------------------------------------
scenario_slow_turn_stamp_send() {
  echo "[claude:15] stamp 200s ago + NUDGE_MIN_TURN_SEC=180 -> banner sent, stamp consumed"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local td proj transcript stub_log stamp_file
  td="$(make_tmp)"
  proj="${td}/projSlow"
  mkdir -p "${proj}"
  transcript="${td}/transcript.jsonl"
  cp "${FIXTURES}/transcript-prompt-only.jsonl" "${transcript}"
  stub_log="${td}/stub.log"
  stamp_file="$(write_stamp_for_cwd "${td}" "${proj}" 200)"

  local stdin_json
  stdin_json="$(jq -n --arg cwd "${proj}" --arg t "${transcript}" \
    '{cwd:$cwd, transcript_path:$t, hook_event_name:"Stop"}')"

  HOME="${td}" \
  NUDGE_NOTIFY_CMD="${STUB}" \
  NUDGE_NOTIFY_STUB_LOG="${stub_log}" \
  NUDGE_MIN_TURN_SEC=180 \
    bash "${WRAPPER}" <<<"${stdin_json}" >/dev/null 2>&1 || true

  if [[ ! -f "${stub_log}" ]] || [[ ! -s "${stub_log}" ]]; then
    fail "expected banner for slow turn but stub log is empty"
    return
  fi
  pass "banner dispatched for slow turn"

  if [[ -f "${stamp_file}" ]]; then
    fail "stamp file should have been consumed on send path; still present at ${stamp_file}"
    return
  fi
  pass "stamp file consumed on send path"
}

# ---------------------------------------------------------------------------
# Scenario 16 — no stamp -> send as before
# ---------------------------------------------------------------------------
scenario_no_stamp_sends() {
  echo "[claude:16] no stamp -> banner sent (no suppression source)"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local td proj transcript stub_log
  td="$(make_tmp)"
  proj="${td}/projNoStamp"
  mkdir -p "${proj}"
  transcript="${td}/transcript.jsonl"
  cp "${FIXTURES}/transcript-prompt-only.jsonl" "${transcript}"
  stub_log="${td}/stub.log"

  local stdin_json
  stdin_json="$(jq -n --arg cwd "${proj}" --arg t "${transcript}" \
    '{cwd:$cwd, transcript_path:$t, hook_event_name:"Stop"}')"

  HOME="${td}" \
  NUDGE_NOTIFY_CMD="${STUB}" \
  NUDGE_NOTIFY_STUB_LOG="${stub_log}" \
  NUDGE_MIN_TURN_SEC=180 \
    bash "${WRAPPER}" <<<"${stdin_json}" >/dev/null 2>&1 || true

  if [[ ! -f "${stub_log}" ]] || [[ ! -s "${stub_log}" ]]; then
    fail "expected banner when no elapsed source is available"
    return
  fi
  pass "banner dispatched when no stamp exists"
}

# ---------------------------------------------------------------------------
# Scenario 17 — NUDGE_MIN_TURN_SEC=0 disables suppression
# ---------------------------------------------------------------------------
scenario_disabled_gate_sends() {
  echo "[claude:17] NUDGE_MIN_TURN_SEC=0 + 60s stamp -> banner sent"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local td proj transcript stub_log
  td="$(make_tmp)"
  proj="${td}/projDisabled"
  mkdir -p "${proj}"
  transcript="${td}/transcript.jsonl"
  cp "${FIXTURES}/transcript-prompt-only.jsonl" "${transcript}"
  stub_log="${td}/stub.log"
  write_stamp_for_cwd "${td}" "${proj}" 60 >/dev/null

  local stdin_json
  stdin_json="$(jq -n --arg cwd "${proj}" --arg t "${transcript}" \
    '{cwd:$cwd, transcript_path:$t, hook_event_name:"Stop"}')"

  HOME="${td}" \
  NUDGE_NOTIFY_CMD="${STUB}" \
  NUDGE_NOTIFY_STUB_LOG="${stub_log}" \
  NUDGE_MIN_TURN_SEC=0 \
    bash "${WRAPPER}" <<<"${stdin_json}" >/dev/null 2>&1 || true

  if [[ ! -f "${stub_log}" ]] || [[ ! -s "${stub_log}" ]]; then
    fail "expected banner when NUDGE_MIN_TURN_SEC=0 disables suppression"
    return
  fi
  pass "banner dispatched when suppression is disabled"
}

# ---------------------------------------------------------------------------
# Scenario 18 — Notification hook events are not completion-suppressed
# ---------------------------------------------------------------------------
scenario_notification_event_not_suppressed() {
  echo "[claude:18] Notification event + fast stamp -> high-priority banner still sent"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local td proj stub_log
  td="$(make_tmp)"
  proj="${td}/projNotification"
  mkdir -p "${proj}"
  stub_log="${td}/stub.log"
  write_stamp_for_cwd "${td}" "${proj}" 60 >/dev/null

  local stdin_json
  stdin_json="$(jq -n --arg cwd "${proj}" \
    '{cwd:$cwd, hook_event_name:"Notification", message:"Waiting for your input"}')"

  HOME="${td}" \
  NUDGE_NOTIFY_CMD="${STUB}" \
  NUDGE_NOTIFY_STUB_LOG="${stub_log}" \
  NUDGE_MIN_TURN_SEC=180 \
    bash "${WRAPPER}" <<<"${stdin_json}" >/dev/null 2>&1 || true

  if [[ ! -f "${stub_log}" ]] || [[ ! -s "${stub_log}" ]]; then
    fail "expected Notification event to send even with a fast-turn stamp"
    return
  fi
  pass "Notification event dispatched"

  local priority
  priority="$(read_last_log "${stub_log}" priority)"
  if [[ "${priority}" != "high" ]]; then
    fail "expected Notification priority high, got '${priority}'"
    return
  fi
  pass "Notification priority remains high"
}

# ---------------------------------------------------------------------------
# Scenario 19 — Claude UserPromptSubmit hook writes a start stamp
# ---------------------------------------------------------------------------
scenario_turn_start_writes_stamp() {
  echo "[claude:19] UserPromptSubmit hook writes a turn-start stamp"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local td proj key stamp_file before after
  td="$(make_tmp)"
  proj="${td}/projStart"
  mkdir -p "${proj}"
  key="$(stamp_key_for_cwd "${proj}")"
  stamp_file="${td}/.nudge/turn-stamps/${key}"
  before="$(date +%s)"

  local stdin_json
  stdin_json="$(jq -n --arg cwd "${proj}" '{cwd:$cwd, hook_event_name:"UserPromptSubmit"}')"

  HOME="${td}" bash "${START_HOOK}" <<<"${stdin_json}" >/dev/null 2>&1 || true
  after="$(date +%s)"

  if [[ ! -f "${stamp_file}" ]]; then
    fail "expected start stamp at ${stamp_file}"
    return
  fi
  pass "start stamp file created"

  local stamped
  stamped="$(cat "${stamp_file}" 2>/dev/null || true)"
  if ! [[ "${stamped}" =~ ^[0-9]+$ ]]; then
    fail "stamp content is not numeric epoch: '${stamped}'"
    return
  fi
  if [[ "${stamped}" -lt "${before}" || "${stamped}" -gt "${after}" ]]; then
    fail "stamp epoch ${stamped} outside expected range ${before}..${after}"
    return
  fi
  pass "stamp content is current epoch seconds"
}

# ---------------------------------------------------------------------------
# Scenario 20 — start + stop with the same session_id share a stamp key
# ---------------------------------------------------------------------------
scenario_session_scoped_start_then_stop_skip() {
  echo "[claude:20] UserPromptSubmit + Stop with same session_id -> fast turn skipped"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local td proj transcript stub_log
  td="$(make_tmp)"
  proj="${td}/projSession"
  mkdir -p "${proj}"
  transcript="${td}/transcript.jsonl"
  cp "${FIXTURES}/transcript-prompt-only.jsonl" "${transcript}"
  stub_log="${td}/stub.log"

  local start_json stop_json
  start_json="$(jq -n --arg cwd "${proj}" '{cwd:$cwd, session_id:"session-fast", hook_event_name:"UserPromptSubmit"}')"
  stop_json="$(jq -n --arg cwd "${proj}" --arg t "${transcript}" \
    '{cwd:$cwd, transcript_path:$t, session_id:"session-fast", hook_event_name:"Stop"}')"

  HOME="${td}" bash "${START_HOOK}" <<<"${start_json}" >/dev/null 2>&1 || true
  local stamp_file now ago
  stamp_file="$(find "${td}/.nudge/turn-stamps" -type f -print 2>/dev/null | head -n 1 || true)"
  if [[ -z "${stamp_file}" ]]; then
    fail "start hook did not create a session-scoped stamp"
    return
  fi
  now="$(date +%s)"
  ago=$((now - 60))
  printf '%s\n' "${ago}" > "${stamp_file}"

  HOME="${td}" \
  NUDGE_NOTIFY_CMD="${STUB}" \
  NUDGE_NOTIFY_STUB_LOG="${stub_log}" \
  NUDGE_MIN_TURN_SEC=180 \
    bash "${WRAPPER}" <<<"${stop_json}" >/dev/null 2>&1 || true

  if [[ -f "${stub_log}" ]] && [[ -s "${stub_log}" ]]; then
    fail "expected same-session fast turn to skip, but stub was invoked: $(cat "${stub_log}")"
    return
  fi
  pass "same-session fast turn skipped"
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
  scenario_last_user_wins
  scenario_skip_skill_expansion
  scenario_skip_command_message_string
  scenario_skip_bash_input_string

  # Q + A parity (PRD: Claude Stop-hook banner Q + A parity)
  scenario_qa_text_end
  scenario_qa_tool_end
  scenario_qa_multiple_text
  scenario_fast_turn_stamp_skip
  scenario_slow_turn_stamp_send
  scenario_no_stamp_sends
  scenario_disabled_gate_sends
  scenario_notification_event_not_suppressed
  scenario_turn_start_writes_stamp
  scenario_session_scoped_start_then_stop_skip

  echo
  echo "Scenarios run: ${SCENARIOS_RUN}"
  if [[ ${FAILED} -ne 0 ]]; then
    echo "RESULT: one or more scenarios FAILED" >&2
    exit 1
  fi
  echo "ALL TESTS PASSED"
}

main "$@"
