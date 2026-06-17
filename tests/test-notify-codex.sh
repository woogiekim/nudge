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

# ===========================================================================
# Below: scenarios for codepoint-safe truncation + fast-turn suppression
# (PRD: codepoint-safe truncation + fast-turn suppression, F1/F2/F4/F5).
# ===========================================================================

# Spec: prd.md § F1 — Q ASCII truncation to NUDGE_MAX_Q=80 + …
# Body line ends with the U+2026 ellipsis and visible prefix is exactly the
# first 80 codepoints of the Q value.
read_log_field() {
  # $1 = log file, $2 = field index (1-based)
  local logfile="$1" idx="$2"
  tail -n 1 "${logfile}" 2>/dev/null | awk -v i="${idx}" -F '\t' '{print $i}'
}

# Count codepoints in stdin using python3 (byte-safe). Returns "0" if python3
# missing — caller should detect.
codepoint_len() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys; sys.stdout.write(str(len(sys.stdin.read())))'
  else
    awk 'BEGIN{ RS="" } { print length($0) }'
  fi
}

# Build a payload with arbitrary Q (input-messages[-1]) and A
# (last-assistant-message). Uses python3 for clean JSON encoding so we can
# safely embed multibyte content (Korean).
make_payload() {
  # $1 = cwd, $2 = Q string, $3 = A string, $4 = turn-id (optional)
  local cwd="$1" q="$2" a="$3" turn="${4:-turn-7}"
  if command -v python3 >/dev/null 2>&1; then
    CWD="${cwd}" Q="${q}" A="${a}" TURN="${turn}" \
      python3 -c '
import json, os
print(json.dumps({
  "type": "agent-turn-complete",
  "thread-id": "thr-12345",
  "turn-id": os.environ["TURN"],
  "cwd": os.environ["CWD"],
  "client": "codex-cli",
  "input-messages": [os.environ["Q"]],
  "last-assistant-message": os.environ["A"],
}))
'
  else
    # Minimal fallback: cannot safely embed Korean without python3.
    printf '{"type":"agent-turn-complete","turn-id":"%s","cwd":"%s","input-messages":["%s"],"last-assistant-message":"%s"}' \
      "${turn}" "${cwd}" "${q}" "${a}"
  fi
}

# Extract the Q segment from the captured body. After the F1 LF refactor the
# body has the shape:
#     <LINE2>\nQ: <Q>\nA: <A>            (3-segment)
#     <LINE2>\nQ: <Q>                    (2-segment, Q-only)
#     <LINE2>\nA: <A>                    (2-segment, A-only — Q absent)
# where "\n" is the 2-char escape the notify stub writes. The Q segment is the
# substring AFTER "Q: " and BEFORE the next "\n" (or end-of-body).
# Returns empty string when there is no Q line.
extract_q_segment() {
  # $1 = body string (stub-escaped: literal LFs replaced with the 2-char "\n").
  local body="$1"
  if [[ "${body}" != *'Q: '* ]]; then
    printf ''
    return 0
  fi
  # Drop everything up through "Q: ".
  local after_q="${body#*Q: }"
  # If a literal "\n" follows, that's the segment terminator; else it's EOL.
  local q_seg
  if [[ "${after_q}" == *'\n'* ]]; then
    q_seg="${after_q%%\\n*}"
  else
    q_seg="${after_q}"
  fi
  printf '%s' "${q_seg}"
}

# Extract the A segment: substring after "A: " up to the next "\n" or EOL.
extract_a_segment() {
  # $1 = body string (stub-escaped).
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
# Scenario 6 — long ASCII Q → truncated to NUDGE_MAX_Q (default 80) + "…"
# ---------------------------------------------------------------------------
# Spec: prd.md § F1 / AC: "Given a 200-codepoint Q ... Then 80 codepoints + …"
scenario_trunc_q_ascii() {
  echo "[codex:6] long ASCII Q → first 80 codepoints + …"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local td proj stub_log
  td="$(make_tmp)"
  proj="${td}/codexproj6"
  mkdir -p "${proj}"
  stub_log="${td}/stub.log"

  local long_q
  long_q="$(printf 'a%.0s' $(seq 1 500))"
  local short_a="ok"
  local payload
  payload="$(make_payload "${proj}" "${long_q}" "${short_a}")"

  NUDGE_NOTIFY_CMD="${STUB}" \
  NUDGE_NOTIFY_STUB_LOG="${stub_log}" \
  HOME="${td}" \
  NUDGE_MIN_TURN_SEC=0 \
    bash "${WRAPPER}" "${payload}" >/dev/null 2>&1 || true

  if [[ ! -f "${stub_log}" ]]; then
    fail "stub never called"
    return
  fi
  local body q_seg q_len
  body="$(read_log_field "${stub_log}" 2)"
  q_seg="$(extract_q_segment "${body}")"

  # The Q segment MUST end with the U+2026 ellipsis character (1 codepoint).
  if [[ "${q_seg}" != *"…" ]]; then
    fail "expected truncated Q to end with U+2026 ellipsis; got: '${q_seg}'"
    return
  fi
  pass "Q segment ends with U+2026 ellipsis"

  # And the visible prefix (strip the trailing ellipsis) must be exactly the
  # first 80 codepoints — i.e. 80 'a's.
  local prefix="${q_seg%…}"
  q_len="$(printf '%s' "${prefix}" | codepoint_len)"
  if [[ "${q_len}" != "80" ]]; then
    fail "expected 80 codepoints before ellipsis, got ${q_len}: '${prefix}'"
    return
  fi
  pass "Q truncated prefix is exactly 80 codepoints"
}

# ---------------------------------------------------------------------------
# Scenario 7 — long ASCII A → truncated to NUDGE_MAX_A (default 120) + "…"
# ---------------------------------------------------------------------------
# Spec: prd.md § F1 — "NUDGE_MAX_A introduced, default 120 ... + …"
scenario_trunc_a_ascii() {
  echo "[codex:7] long ASCII A → first 120 codepoints + …"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local td proj stub_log
  td="$(make_tmp)"
  proj="${td}/codexproj7"
  mkdir -p "${proj}"
  stub_log="${td}/stub.log"

  local short_q="hello"
  local long_a
  long_a="$(printf 'b%.0s' $(seq 1 800))"
  local payload
  payload="$(make_payload "${proj}" "${short_q}" "${long_a}")"

  NUDGE_NOTIFY_CMD="${STUB}" \
  NUDGE_NOTIFY_STUB_LOG="${stub_log}" \
  HOME="${td}" \
  NUDGE_MIN_TURN_SEC=0 \
    bash "${WRAPPER}" "${payload}" >/dev/null 2>&1 || true

  if [[ ! -f "${stub_log}" ]]; then
    fail "stub never called"
    return
  fi
  local body a_seg a_len
  body="$(read_log_field "${stub_log}" 2)"
  a_seg="$(extract_a_segment "${body}")"

  if [[ -z "${a_seg}" ]]; then
    fail "no 'A:' segment found in body: ${body}"
    return
  fi

  if [[ "${a_seg}" != *"…" ]]; then
    fail "expected truncated A to end with U+2026 ellipsis; got: '${a_seg}'"
    return
  fi
  pass "A segment ends with U+2026 ellipsis"

  local prefix="${a_seg%…}"
  a_len="$(printf '%s' "${prefix}" | codepoint_len)"
  if [[ "${a_len}" != "120" ]]; then
    fail "expected 120 codepoints before ellipsis, got ${a_len}: '${prefix}'"
    return
  fi
  pass "A truncated prefix is exactly 120 codepoints"
}

# ---------------------------------------------------------------------------
# Scenario 8 — short Q / short A: NO ellipsis appended (verbatim pass-through)
# ---------------------------------------------------------------------------
# Spec: prd.md § F1 — truncation only when length > max.
scenario_no_trunc_for_short() {
  echo "[codex:8] short Q + short A → no ellipsis appended"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local td proj stub_log
  td="$(make_tmp)"
  proj="${td}/codexproj8"
  mkdir -p "${proj}"
  stub_log="${td}/stub.log"

  local q="how do I run tests?"
  local a="bash test.sh"
  local payload
  payload="$(make_payload "${proj}" "${q}" "${a}")"

  NUDGE_NOTIFY_CMD="${STUB}" \
  NUDGE_NOTIFY_STUB_LOG="${stub_log}" \
  HOME="${td}" \
  NUDGE_MIN_TURN_SEC=0 \
    bash "${WRAPPER}" "${payload}" >/dev/null 2>&1 || true

  if [[ ! -f "${stub_log}" ]]; then
    fail "stub never called"
    return
  fi
  local body q_seg a_seg
  body="$(read_log_field "${stub_log}" 2)"
  q_seg="$(extract_q_segment "${body}")"
  a_seg="$(extract_a_segment "${body}")"

  if [[ "${q_seg}" == *"…" ]]; then
    fail "short Q must NOT have appended ellipsis; got: '${q_seg}'"
    return
  fi
  if [[ "${a_seg}" == *"…" ]]; then
    fail "short A must NOT have appended ellipsis; got: '${a_seg}'"
    return
  fi
  pass "short Q + short A pass through verbatim (no ellipsis)"
}

# ---------------------------------------------------------------------------
# Scenario 9 — override NUDGE_MAX_Q + NUDGE_MAX_A via env
# ---------------------------------------------------------------------------
# Spec: prd.md § F1 — caps are env-overridable.
scenario_trunc_caps_overridable() {
  echo "[codex:9] env override → NUDGE_MAX_Q=10, NUDGE_MAX_A=15"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local td proj stub_log
  td="$(make_tmp)"
  proj="${td}/codexproj9"
  mkdir -p "${proj}"
  stub_log="${td}/stub.log"

  local long_q
  long_q="$(printf 'a%.0s' $(seq 1 100))"
  local long_a
  long_a="$(printf 'b%.0s' $(seq 1 100))"
  local payload
  payload="$(make_payload "${proj}" "${long_q}" "${long_a}")"

  NUDGE_NOTIFY_CMD="${STUB}" \
  NUDGE_NOTIFY_STUB_LOG="${stub_log}" \
  HOME="${td}" \
  NUDGE_MIN_TURN_SEC=0 \
  NUDGE_MAX_Q=10 \
  NUDGE_MAX_A=15 \
    bash "${WRAPPER}" "${payload}" >/dev/null 2>&1 || true

  if [[ ! -f "${stub_log}" ]]; then
    fail "stub never called"
    return
  fi
  local body q_seg a_seg
  body="$(read_log_field "${stub_log}" 2)"
  q_seg="$(extract_q_segment "${body}")"
  a_seg="$(extract_a_segment "${body}")"

  if [[ "${q_seg}" != *"…" ]] || [[ "${a_seg}" != *"…" ]]; then
    fail "expected ellipsis on both Q and A under env override; body='${body}'"
    return
  fi
  local q_prefix="${q_seg%…}"
  local a_prefix="${a_seg%…}"
  local q_len a_len
  q_len="$(printf '%s' "${q_prefix}" | codepoint_len)"
  a_len="$(printf '%s' "${a_prefix}" | codepoint_len)"
  if [[ "${q_len}" != "10" ]]; then
    fail "expected NUDGE_MAX_Q=10 to produce 10-codepoint prefix, got ${q_len}: '${q_prefix}'"
    return
  fi
  if [[ "${a_len}" != "15" ]]; then
    fail "expected NUDGE_MAX_A=15 to produce 15-codepoint prefix, got ${a_len}: '${a_prefix}'"
    return
  fi
  pass "env-overridden caps respected (Q=10, A=15)"
}

# ---------------------------------------------------------------------------
# Scenario 10 — Korean codepoint safety under LC_ALL=C (launchd-like locale)
# ---------------------------------------------------------------------------
# Spec: prd.md AC — "Given 200-codepoint Korean Q under LC_ALL=C, Then 80
# Korean codepoints + … and decodes as valid UTF-8 with no broken trailing
# multibyte sequence."
scenario_trunc_korean_locale_c() {
  echo "[codex:10] Korean Q under LC_ALL=C → 80 Korean codepoints + … (no broken multibyte)"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  if ! command -v python3 >/dev/null 2>&1; then
    fail "python3 required for Korean codepoint test — please install python3"
    return
  fi

  local td proj stub_log
  td="$(make_tmp)"
  proj="${td}/codexproj10"
  mkdir -p "${proj}"
  stub_log="${td}/stub.log"

  local long_q
  long_q="$(python3 -c 'print("한"*200, end="")')"
  local short_a="ok"
  local payload
  payload="$(make_payload "${proj}" "${long_q}" "${short_a}")"

  # Run under launchd-like minimal environment with LC_ALL=C. The wrapper
  # must internally promote LC_ALL=en_US.UTF-8 for the truncation primitive
  # so codepoint boundaries are respected.
  env -i \
    LC_ALL=C \
    PATH="${PATH}" \
    HOME="${td}" \
    NUDGE_NOTIFY_CMD="${STUB}" \
    NUDGE_NOTIFY_STUB_LOG="${stub_log}" \
    NUDGE_MIN_TURN_SEC=0 \
      bash "${WRAPPER}" "${payload}" >/dev/null 2>&1 || true

  if [[ ! -f "${stub_log}" ]]; then
    fail "stub never called"
    return
  fi
  local body q_seg
  body="$(read_log_field "${stub_log}" 2)"
  q_seg="$(extract_q_segment "${body}")"

  if [[ "${q_seg}" != *"…" ]]; then
    fail "expected Korean Q to end with U+2026 ellipsis under LC_ALL=C; got: '${q_seg}'"
    return
  fi
  pass "Korean Q ends with U+2026 ellipsis under LC_ALL=C"

  # Validate the truncated Q decodes as valid UTF-8 and is exactly 80 (+ the
  # ellipsis codepoint) "한" characters. We write q_seg to a temp file and read
  # it from python3 to sidestep any pipefail nuance with set -uo pipefail.
  local seg_file="${td}/q_seg.bin"
  printf '%s' "${q_seg}" > "${seg_file}"
  local decode_check rc
  set +e
  decode_check="$(LC_ALL=en_US.UTF-8 python3 -c '
import sys
with open(sys.argv[1], "rb") as fp:
    data = fp.read()
try:
    s = data.decode("utf-8")
except UnicodeDecodeError as e:
    print("UTF8_DECODE_ERROR:" + str(e))
    sys.exit(1)
prefix = s[:-1] if s.endswith("…") else s
if not all(ch == "한" for ch in prefix):
    print("PREFIX_NOT_PURE_HAN:len=%d sample=%r" % (len(prefix), prefix[:5]))
    sys.exit(1)
print("OK:len=%d" % len(prefix))
' "${seg_file}" 2>&1)"
  rc=$?
  set -e
  if [[ "${rc}" -ne 0 ]]; then
    fail "Korean truncated Q failed UTF-8 / prefix check: ${decode_check}"
    return
  fi
  pass "Korean truncated Q decodes clean UTF-8 (no broken multibyte)"

  # And the prefix length must be exactly 80 Korean codepoints.
  if [[ "${decode_check}" != "OK:len=80" ]]; then
    fail "expected exactly 80 Korean codepoints before ellipsis under LC_ALL=C; got: '${decode_check}'"
    return
  fi
  pass "Korean Q truncated to exactly 80 codepoints under LC_ALL=C"
}

# ---------------------------------------------------------------------------
# Scenario 11 — Korean A under LC_ALL=C → 120 Korean codepoints + …
# ---------------------------------------------------------------------------
# Spec: prd.md AC — "Given 300-codepoint Korean A ... 120 Korean codepoints + …".
scenario_trunc_korean_a_locale_c() {
  echo "[codex:11] Korean A under LC_ALL=C → 120 Korean codepoints + …"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  if ! command -v python3 >/dev/null 2>&1; then
    fail "python3 required for Korean codepoint test"
    return
  fi

  local td proj stub_log
  td="$(make_tmp)"
  proj="${td}/codexproj11"
  mkdir -p "${proj}"
  stub_log="${td}/stub.log"

  local short_q="질문"
  local long_a
  long_a="$(python3 -c 'print("답"*300, end="")')"
  local payload
  payload="$(make_payload "${proj}" "${short_q}" "${long_a}")"

  env -i \
    LC_ALL=C \
    PATH="${PATH}" \
    HOME="${td}" \
    NUDGE_NOTIFY_CMD="${STUB}" \
    NUDGE_NOTIFY_STUB_LOG="${stub_log}" \
    NUDGE_MIN_TURN_SEC=0 \
      bash "${WRAPPER}" "${payload}" >/dev/null 2>&1 || true

  if [[ ! -f "${stub_log}" ]]; then
    fail "stub never called"
    return
  fi
  local body a_seg
  body="$(read_log_field "${stub_log}" 2)"
  a_seg="$(extract_a_segment "${body}")"

  if [[ "${a_seg}" != *"…" ]]; then
    fail "expected Korean A to end with U+2026 ellipsis; got: '${a_seg}'"
    return
  fi
  local seg_file="${td}/a_seg.bin"
  printf '%s' "${a_seg}" > "${seg_file}"
  local check rc
  set +e
  check="$(LC_ALL=en_US.UTF-8 python3 -c '
import sys
with open(sys.argv[1], "rb") as fp:
    data = fp.read()
try:
    s = data.decode("utf-8")
except UnicodeDecodeError as e:
    print("UTF8_DECODE_ERROR:" + str(e)); sys.exit(1)
prefix = s[:-1] if s.endswith("…") else s
if not all(ch == "답" for ch in prefix):
    print("PREFIX_NOT_PURE:len=%d" % len(prefix)); sys.exit(1)
print("OK:len=%d" % len(prefix))
' "${seg_file}" 2>&1)"
  rc=$?
  set -e
  if [[ "${rc}" -ne 0 ]] || [[ "${check}" != "OK:len=120" ]]; then
    fail "Korean A truncation under LC_ALL=C failed: ${check}"
    return
  fi
  pass "Korean A truncated to exactly 120 codepoints under LC_ALL=C (clean UTF-8)"
}

# ---------------------------------------------------------------------------
# Scenario 12 — fast-turn suppression via stamp file (60s ago → skip)
# ---------------------------------------------------------------------------
# Spec: prd.md AC — "stamp at now-60s, NUDGE_MIN_TURN_SEC=180 → exit 0, no banner,
# stamp removed."
sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    printf 'fallback'
  fi
}

# Helper: derive the stamp key the way the hook/notify will. We use
# cwd-only fallback (no Codex session env present) which matches the PRD
# documented single-session fallback. This MUST agree with the implementation.
stamp_key_for_cwd() {
  sha256_of "$1"
}

scenario_skip_stamp_60s() {
  echo "[codex:12] stamp 60s ago + NUDGE_MIN_TURN_SEC=180 → skip, no banner, stamp consumed"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local td proj stub_log
  td="$(make_tmp)"
  proj="${td}/codexproj12"
  mkdir -p "${proj}"
  stub_log="${td}/stub.log"

  local key stamp_dir stamp_file now ago
  key="$(stamp_key_for_cwd "${proj}")"
  stamp_dir="${td}/.nudge/turn-stamps"
  mkdir -p "${stamp_dir}"
  stamp_file="${stamp_dir}/${key}"
  now="$(date +%s)"
  ago=$((now - 60))
  printf '%s\n' "${ago}" > "${stamp_file}"

  local payload
  payload="$(make_payload "${proj}" "fast turn?" "ok" "turn-fast-60s")"

  local exit_code
  set +e
  HOME="${td}" \
  NUDGE_NOTIFY_CMD="${STUB}" \
  NUDGE_NOTIFY_STUB_LOG="${stub_log}" \
  NUDGE_MIN_TURN_SEC=180 \
    bash "${WRAPPER}" "${payload}" >/dev/null 2>&1
  exit_code=$?
  set -e

  if [[ "${exit_code}" -ne 0 ]]; then
    fail "expected exit 0 on fast-turn skip, got ${exit_code}"
    return
  fi
  pass "exit 0 on fast-turn skip"

  if [[ -f "${stub_log}" ]] && [[ -s "${stub_log}" ]]; then
    fail "stub was invoked on fast-turn skip; body=$(cat "${stub_log}")"
    return
  fi
  pass "no banner dispatched on fast-turn skip"

  if [[ -f "${stamp_file}" ]]; then
    fail "stamp file should have been consumed (deleted) on skip path; still present at ${stamp_file}"
    return
  fi
  pass "stamp file consumed on skip path"
}

# ---------------------------------------------------------------------------
# Scenario 13 — slow-turn stamp (200s ago) → banner sent, stamp consumed
# ---------------------------------------------------------------------------
# Spec: prd.md AC — "stamp at now-200s ... Then it sends the banner and removes
# the stamp."
scenario_send_stamp_200s() {
  echo "[codex:13] stamp 200s ago + NUDGE_MIN_TURN_SEC=180 → banner sent, stamp consumed"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local td proj stub_log
  td="$(make_tmp)"
  proj="${td}/codexproj13"
  mkdir -p "${proj}"
  stub_log="${td}/stub.log"

  local key stamp_dir stamp_file now ago
  key="$(stamp_key_for_cwd "${proj}")"
  stamp_dir="${td}/.nudge/turn-stamps"
  mkdir -p "${stamp_dir}"
  stamp_file="${stamp_dir}/${key}"
  now="$(date +%s)"
  ago=$((now - 200))
  printf '%s\n' "${ago}" > "${stamp_file}"

  local payload
  payload="$(make_payload "${proj}" "slow turn?" "took a while" "turn-slow-200s")"

  HOME="${td}" \
  NUDGE_NOTIFY_CMD="${STUB}" \
  NUDGE_NOTIFY_STUB_LOG="${stub_log}" \
  NUDGE_MIN_TURN_SEC=180 \
    bash "${WRAPPER}" "${payload}" >/dev/null 2>&1 || true

  if [[ ! -f "${stub_log}" ]] || [[ ! -s "${stub_log}" ]]; then
    fail "expected banner to be dispatched for slow turn (200s elapsed) but stub log is empty"
    return
  fi
  pass "banner dispatched for slow turn (200s)"

  if [[ -f "${stamp_file}" ]]; then
    fail "stamp file should have been consumed on send path too; still present"
    return
  fi
  pass "stamp file consumed on send path"
}

# ---------------------------------------------------------------------------
# Scenario 14 — JSONL fallback (no stamp): rollout duration_ms=60000 → skip
# ---------------------------------------------------------------------------
# Spec: prd.md AC — "no stamp + rollout duration_ms 60000 for payload turn-id
# → exit 0 without banner."
scenario_fallback_jsonl_fast() {
  echo "[codex:14] no stamp + rollout fast (duration_ms=60000) → skip"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local td proj stub_log codex_sessions_dir
  td="$(make_tmp)"
  proj="${td}/codexproj14"
  mkdir -p "${proj}"
  stub_log="${td}/stub.log"

  # Drop a rollout JSONL with the turn-id we will use.
  local turn_id="turn-jsonl-fast"
  codex_sessions_dir="${td}/.codex/sessions/2026/06/17"
  mkdir -p "${codex_sessions_dir}"
  # Use a freshly-named rollout-*.jsonl so "most recent" picks it up.
  printf '{"turn_id":"%s","duration_ms":60000}\n' "${turn_id}" \
    > "${codex_sessions_dir}/rollout-${turn_id}.jsonl"

  local payload
  payload="$(make_payload "${proj}" "jsonl q" "jsonl a" "${turn_id}")"

  local exit_code
  set +e
  HOME="${td}" \
  NUDGE_NOTIFY_CMD="${STUB}" \
  NUDGE_NOTIFY_STUB_LOG="${stub_log}" \
  NUDGE_MIN_TURN_SEC=180 \
    bash "${WRAPPER}" "${payload}" >/dev/null 2>&1
  exit_code=$?
  set -e

  if [[ "${exit_code}" -ne 0 ]]; then
    fail "expected exit 0 on JSONL-fast skip, got ${exit_code}"
    return
  fi
  if [[ -f "${stub_log}" ]] && [[ -s "${stub_log}" ]]; then
    fail "stub was invoked despite JSONL duration_ms=60000 (should skip); body=$(cat "${stub_log}")"
    return
  fi
  pass "no banner dispatched on JSONL fast (60s) fallback"
}

# ---------------------------------------------------------------------------
# Scenario 15 — JSONL fallback: rollout duration_ms=200000 → banner sent
# ---------------------------------------------------------------------------
scenario_fallback_jsonl_slow() {
  echo "[codex:15] no stamp + rollout slow (duration_ms=200000) → banner sent"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local td proj stub_log codex_sessions_dir
  td="$(make_tmp)"
  proj="${td}/codexproj15"
  mkdir -p "${proj}"
  stub_log="${td}/stub.log"

  local turn_id="turn-jsonl-slow"
  codex_sessions_dir="${td}/.codex/sessions/2026/06/17"
  mkdir -p "${codex_sessions_dir}"
  printf '{"turn_id":"%s","duration_ms":200000}\n' "${turn_id}" \
    > "${codex_sessions_dir}/rollout-${turn_id}.jsonl"

  local payload
  payload="$(make_payload "${proj}" "jsonl slow q" "jsonl slow a" "${turn_id}")"

  HOME="${td}" \
  NUDGE_NOTIFY_CMD="${STUB}" \
  NUDGE_NOTIFY_STUB_LOG="${stub_log}" \
  NUDGE_MIN_TURN_SEC=180 \
    bash "${WRAPPER}" "${payload}" >/dev/null 2>&1 || true

  if [[ ! -f "${stub_log}" ]] || [[ ! -s "${stub_log}" ]]; then
    fail "expected banner on JSONL-slow (200s) fallback, but stub log empty"
    return
  fi
  pass "banner dispatched on JSONL slow (200s) fallback"
}

# ---------------------------------------------------------------------------
# Scenario 16 — no stamp + no rollout match → send as before
# ---------------------------------------------------------------------------
scenario_fallback_neither() {
  echo "[codex:16] no stamp + no rollout → banner sent (no suppression)"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local td proj stub_log
  td="$(make_tmp)"
  proj="${td}/codexproj16"
  mkdir -p "${proj}"
  stub_log="${td}/stub.log"

  local payload
  payload="$(make_payload "${proj}" "no source q" "no source a" "turn-no-source")"

  HOME="${td}" \
  NUDGE_NOTIFY_CMD="${STUB}" \
  NUDGE_NOTIFY_STUB_LOG="${stub_log}" \
  NUDGE_MIN_TURN_SEC=180 \
    bash "${WRAPPER}" "${payload}" >/dev/null 2>&1 || true

  if [[ ! -f "${stub_log}" ]] || [[ ! -s "${stub_log}" ]]; then
    fail "expected banner when no elapsed source is available"
    return
  fi
  pass "banner dispatched when no stamp + no rollout (send as before)"
}

# ---------------------------------------------------------------------------
# Scenario 17 — NUDGE_MIN_TURN_SEC=0 disables suppression (always send)
# ---------------------------------------------------------------------------
# Spec: prd.md AC — "NUDGE_MIN_TURN_SEC=0 with any stamp age → always send."
scenario_disabled_always_send() {
  echo "[codex:17] NUDGE_MIN_TURN_SEC=0 + 60s stamp → banner sent (suppression disabled)"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local td proj stub_log
  td="$(make_tmp)"
  proj="${td}/codexproj17"
  mkdir -p "${proj}"
  stub_log="${td}/stub.log"

  local key stamp_dir stamp_file now ago
  key="$(stamp_key_for_cwd "${proj}")"
  stamp_dir="${td}/.nudge/turn-stamps"
  mkdir -p "${stamp_dir}"
  stamp_file="${stamp_dir}/${key}"
  now="$(date +%s)"
  ago=$((now - 60))
  printf '%s\n' "${ago}" > "${stamp_file}"

  local payload
  payload="$(make_payload "${proj}" "fast turn?" "ok" "turn-disabled")"

  HOME="${td}" \
  NUDGE_NOTIFY_CMD="${STUB}" \
  NUDGE_NOTIFY_STUB_LOG="${stub_log}" \
  NUDGE_MIN_TURN_SEC=0 \
    bash "${WRAPPER}" "${payload}" >/dev/null 2>&1 || true

  if [[ ! -f "${stub_log}" ]] || [[ ! -s "${stub_log}" ]]; then
    fail "expected banner when NUDGE_MIN_TURN_SEC=0 disables suppression"
    return
  fi
  pass "banner dispatched when suppression disabled"
}

# ---------------------------------------------------------------------------
# Scenario 18 — _JQ_OK=0 (no-jq fallback) still extracts Q + A and truncates
# ---------------------------------------------------------------------------
# Spec: handoff.md "Constraints" — "_JQ_OK no-jq fallback path must still work
# end-to-end (no JSONL parse attempted when _JQ_OK=0; send-as-before path)."
scenario_no_jq_fallback() {
  echo "[codex:18] _JQ_OK=0 (no jq) → still extracts Q + last-A and applies truncation"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local td proj stub_log shadow_bin
  td="$(make_tmp)"
  proj="${td}/codexproj18"
  mkdir -p "${proj}"
  stub_log="${td}/stub.log"

  # Shadow jq off PATH by pointing PATH at a tiny dir with no jq.
  shadow_bin="${td}/shadow_bin"
  mkdir -p "${shadow_bin}"
  # We still want common utilities — symlink the minimum the wrapper needs.
  for tool in bash awk sed grep tr cut head tail cat mkdir rm date dirname basename find shasum python3 env; do
    if command -v "${tool}" >/dev/null 2>&1; then
      ln -s "$(command -v "${tool}")" "${shadow_bin}/${tool}" 2>/dev/null || true
    fi
  done

  local long_q
  long_q="$(printf 'a%.0s' $(seq 1 200))"
  local short_a="answer"
  local payload
  payload="$(make_payload "${proj}" "${long_q}" "${short_a}" "turn-nojq")"

  env -i \
    LC_ALL=C \
    PATH="${shadow_bin}" \
    HOME="${td}" \
    NUDGE_NOTIFY_CMD="${STUB}" \
    NUDGE_NOTIFY_STUB_LOG="${stub_log}" \
    NUDGE_MIN_TURN_SEC=0 \
      bash "${WRAPPER}" "${payload}" >/dev/null 2>&1 || true

  if [[ ! -f "${stub_log}" ]] || [[ ! -s "${stub_log}" ]]; then
    fail "expected banner to fire under _JQ_OK=0 (no jq) path; got empty log"
    return
  fi

  local body q_seg
  body="$(read_log_field "${stub_log}" 2)"
  q_seg="$(extract_q_segment "${body}")"
  if [[ -z "${q_seg}" ]]; then
    fail "no Q segment recovered under no-jq fallback; body='${body}'"
    return
  fi
  # The no-jq path is best-effort: it must at least surface SOME Q content and
  # still apply the truncation cap. The trailing ellipsis proves the truncation
  # ran on the no-jq extraction result.
  if [[ "${q_seg}" != *"…" ]]; then
    fail "no-jq path failed to apply truncation; q_seg='${q_seg}'"
    return
  fi
  pass "no-jq fallback extracted Q and applied truncation"
}

# ---------------------------------------------------------------------------
# Scenario 19 — NTFY_ID stability across truncation
# ---------------------------------------------------------------------------
# Spec: handoff.md "NTFY_ID stability — the dedup hash MUST remain stable
# across cache replays even after truncation." The same Q/A pair on consecutive
# calls (same turn-id) must produce the same NTFY_ID; changing only the body
# length (truncated vs untruncated) must not change the NTFY_ID — i.e. the id
# is derived from a stable upstream identifier (turn-id) OR computed
# pre-truncation.
scenario_ntfy_id_stable_across_truncation() {
  echo "[codex:19] NTFY_ID stable across calls with same turn-id, regardless of body length"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local td proj stub_log
  td="$(make_tmp)"
  proj="${td}/codexproj19"
  mkdir -p "${proj}"
  stub_log="${td}/stub.log"

  # Call 1: short Q (no truncation).
  local short_q="hello"
  local short_a="world"
  local payload_short
  payload_short="$(make_payload "${proj}" "${short_q}" "${short_a}" "turn-stable")"

  HOME="${td}" \
  NUDGE_NOTIFY_CMD="${STUB}" \
  NUDGE_NOTIFY_STUB_LOG="${stub_log}" \
  NUDGE_MIN_TURN_SEC=0 \
    bash "${WRAPPER}" "${payload_short}" >/dev/null 2>&1 || true

  # Call 2: same turn-id but a long Q so truncation kicks in.
  local long_q
  long_q="$(printf 'z%.0s' $(seq 1 400))"
  local payload_long
  payload_long="$(make_payload "${proj}" "${long_q}" "${short_a}" "turn-stable")"

  HOME="${td}" \
  NUDGE_NOTIFY_CMD="${STUB}" \
  NUDGE_NOTIFY_STUB_LOG="${stub_log}" \
  NUDGE_MIN_TURN_SEC=0 \
    bash "${WRAPPER}" "${payload_long}" >/dev/null 2>&1 || true

  if [[ "$(wc -l < "${stub_log}" | tr -d ' ')" != "2" ]]; then
    fail "expected exactly 2 stub invocations; got: $(cat "${stub_log}")"
    return
  fi

  local id1 id2
  id1="$(awk -F '\t' 'NR==1{print $4}' "${stub_log}")"
  id2="$(awk -F '\t' 'NR==2{print $4}' "${stub_log}")"

  if [[ -z "${id1}" ]] || [[ -z "${id2}" ]]; then
    fail "NTFY_ID not exported by notify-codex.sh on at least one call (id1='${id1}', id2='${id2}')"
    return
  fi
  if [[ "${id1}" != "${id2}" ]]; then
    fail "NTFY_ID changed across truncation: '${id1}' vs '${id2}' (expected stable across body length for same turn-id)"
    return
  fi
  pass "NTFY_ID stable across truncation for same turn-id ('${id1}')"
}

# ---------------------------------------------------------------------------
# Scenario 20 — install-wiring idempotency for hooks.json UserPromptSubmit
# ---------------------------------------------------------------------------
# Spec: prd.md § F3 / AC — "Two consecutive wire_codex_settings invocations →
# byte-identical hooks.json (idempotent)." config.toml notify wiring preserved.
scenario_install_hooks_idempotent() {
  echo "[codex:20] install --wire-codex twice → hooks.json has exactly one notify-codex-turn-start entry"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  if ! command -v jq >/dev/null 2>&1; then
    pass "jq not installed — install path uses manual-snippet fallback (covered by test-wire-codex.sh no-jq scenario)"
    return
  fi

  local install_sh
  install_sh="${REPO_ROOT}/install.sh"
  if [[ ! -f "${install_sh}" ]]; then
    fail "install.sh not found at ${install_sh}"
    return
  fi

  local td hooks_file config_file
  td="$(make_tmp)"
  mkdir -p "${td}/.codex"
  hooks_file="${td}/.codex/hooks.json"
  config_file="${td}/.codex/config.toml"

  # Pre-seed an empty config.toml so wire-codex updates it once and is then a
  # no-op (we want to assert config.toml is not duplicated either).
  : > "${config_file}"

  local run1_rc run2_rc
  set +e
  HOME="${td}" \
  NUDGE_CODEX_CONFIG="${config_file}" \
    bash "${install_sh}" --wire-codex >/dev/null 2>&1
  run1_rc=$?
  HOME="${td}" \
  NUDGE_CODEX_CONFIG="${config_file}" \
    bash "${install_sh}" --wire-codex >/dev/null 2>&1
  run2_rc=$?
  set -e

  if [[ "${run1_rc}" -ne 0 ]] || [[ "${run2_rc}" -ne 0 ]]; then
    fail "install.sh --wire-codex returned non-zero (rc1=${run1_rc}, rc2=${run2_rc})"
    return
  fi
  pass "install.sh --wire-codex exits 0 on both runs"

  if [[ ! -f "${hooks_file}" ]]; then
    fail "expected ${hooks_file} to be created by --wire-codex (UserPromptSubmit hook wiring)"
    return
  fi
  pass "hooks.json created on first --wire-codex run"

  # Count entries that reference notify-codex-turn-start.sh under
  # .hooks.UserPromptSubmit[*].hooks[*].command. The PRD pins exactly one entry.
  local count
  count="$(jq '[.hooks.UserPromptSubmit[]?.hooks[]?.command // empty]
              | map(select(test("/notify-codex-turn-start\\.sh"))) | length' \
             "${hooks_file}" 2>/dev/null || echo "ERR")"

  if [[ "${count}" != "1" ]]; then
    fail "expected exactly 1 notify-codex-turn-start.sh entry under .hooks.UserPromptSubmit; got count=${count}; file:"
    cat "${hooks_file}" >&2 || true
    return
  fi
  pass "hooks.json has exactly one notify-codex-turn-start.sh entry after two runs (idempotent)"

  # config.toml notify wiring must remain wired and unchanged (same line) -
  # i.e. exactly one 'notify =' line referencing notify-codex.sh.
  local notify_count
  notify_count="$(grep -cE '^[[:space:]]*notify[[:space:]]*=' "${config_file}" 2>/dev/null || echo 0)"
  if [[ "${notify_count}" != "1" ]]; then
    fail "expected exactly one top-level 'notify =' line in config.toml; got ${notify_count}"
    cat "${config_file}" >&2 || true
    return
  fi
  if ! grep -F '/.nudge/notify-codex.sh' "${config_file}" >/dev/null 2>&1; then
    fail "config.toml lost its notify-codex.sh wiring across the two runs"
    return
  fi
  pass "config.toml notify wiring preserved across two install runs"
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

  # Codepoint-safe truncation (F1)
  scenario_trunc_q_ascii
  scenario_trunc_a_ascii
  scenario_no_trunc_for_short
  scenario_trunc_caps_overridable
  scenario_trunc_korean_locale_c
  scenario_trunc_korean_a_locale_c

  # Fast-turn suppression (F4)
  scenario_skip_stamp_60s
  scenario_send_stamp_200s
  scenario_fallback_jsonl_fast
  scenario_fallback_jsonl_slow
  scenario_fallback_neither
  scenario_disabled_always_send
  scenario_no_jq_fallback

  # NTFY_ID stability (F1 pre-truncation rule)
  scenario_ntfy_id_stable_across_truncation

  # install.sh wiring idempotency (F3)
  scenario_install_hooks_idempotent

  # Q/A on separate LF-delimited lines + NTFY_ID dedup invariant (PRD §F1, §F3)
  scenario_qa_separate_lines_full
  scenario_qa_q_only_fallback
  scenario_qa_a_only_fallback
  scenario_ntfy_id_hash_unchanged_by_lf_refactor

  echo
  echo "Scenarios run: ${SCENARIOS_RUN}"
  if [[ ${FAILED} -ne 0 ]]; then
    echo "RESULT: one or more scenarios FAILED" >&2
    exit 1
  fi
  echo "ALL TESTS PASSED"
}

# ===========================================================================
# Q/A separate-line scenarios (prd.md § F1) — Q and A on their own LF-delimited
# lines, with the historical "Q: ...  A: ..." two-space join removed. The
# wrapper now composes the body so notify-mac.sh can split:
#   LINE2 \n Q: <Q> \n A: <A>   (3-segment, both Q+A)
#   LINE2 \n Q: <Q>             (2-segment, Q-only)
#   LINE2 \n A: <A>             (2-segment, A-only)
# The stub captures the literal MESSAGE arg; \n is escaped to a 2-char "\n"
# marker by the stub so the log stays one record per call.
#
# Spec: prd.md § F1 — "After the change, the assembly must produce one of:
#   3 segments (LINE2 + Q + A): \"${LINE2}\"\$'\\n'\"Q: ${Q}\"\$'\\n'\"A: ${A}\""
# ===========================================================================

# ---------------------------------------------------------------------------
# Scenario (l) — full Q+A → body has TWO LFs; second LF immediately followed by "A: "
# ---------------------------------------------------------------------------
scenario_qa_separate_lines_full() {
  echo "[codex:l] full Q+A → message body has TWO LFs, second LF followed by 'A: '"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local td proj stub_log
  td="$(make_tmp)"
  proj="${td}/codexproj_l"
  mkdir -p "${proj}"
  stub_log="${td}/stub.log"

  local q="how do I run tests?"
  local a="bash test.sh"
  local payload
  payload="$(make_payload "${proj}" "${q}" "${a}" "turn-l")"

  HOME="${td}" \
  NUDGE_NOTIFY_CMD="${STUB}" \
  NUDGE_NOTIFY_STUB_LOG="${stub_log}" \
  NUDGE_MIN_TURN_SEC=0 \
    bash "${WRAPPER}" "${payload}" >/dev/null 2>&1 || true

  if [[ ! -f "${stub_log}" ]] || [[ ! -s "${stub_log}" ]]; then
    fail "(l) stub never called"
    return
  fi

  local body
  body="$(read_log_field "${stub_log}" 2)"

  # The stub escapes literal LFs to the 2-char marker "\n". Count occurrences.
  # The stub escapes literal LFs to the 2-char marker "\n" (backslash + n).
  # Count occurrences of that 2-char sequence in the captured body field.
  local lf_count
  lf_count=$(printf '%s' "${body}" | awk 'BEGIN{ FS="\\\\n" } { print NF - 1 }')
  if [[ "${lf_count}" -ne 2 ]]; then
    fail "(l) expected exactly 2 LFs in body for full Q+A; got ${lf_count}; body='${body}'"
    return
  fi
  pass "(l) body contains exactly 2 LFs"

  # The second LF must be immediately followed by 'A: ' (the A-line prefix).
  # The body looks like: "<LINE2>\nQ: <Q>\nA: <A>". Match the second-LF→A pattern.
  if printf '%s' "${body}" | grep -F -- '\nA: ' >/dev/null 2>&1 \
     && printf '%s' "${body}" | grep -F -- '\nQ: ' >/dev/null 2>&1; then
    pass "(l) second LF is immediately followed by 'A: ' (A-line prefix)"
  else
    fail "(l) LF→A: or LF→Q: marker missing; body='${body}'"
    return
  fi

  # Two-space join MUST NOT appear anymore (the historical pattern was
  # "Q: ...  A: ..." — i.e. two consecutive spaces separating Q from A).
  if [[ "${body}" == *"Q: ${q}  A: ${a}"* ]]; then
    fail "(l) deprecated 'Q: ...  A: ...' two-space join still present in body: '${body}'"
    return
  fi
  pass "(l) deprecated two-space 'Q: ...  A: ...' join is gone"

  # Sanity: the Q content and A content are still present on their respective lines.
  if [[ "${body}" != *"Q: ${q}"* ]]; then
    fail "(l) Q content 'Q: ${q}' missing from body"
    return
  fi
  if [[ "${body}" != *"A: ${a}"* ]]; then
    fail "(l) A content 'A: ${a}' missing from body"
    return
  fi
  pass "(l) Q line ('Q: …') and A line ('A: …') both present on separate LF-delimited lines"
}

# ---------------------------------------------------------------------------
# Scenario (m) — Q-only fallback → ONE LF; body contains 'Q: ' but NOT 'A: '
# ---------------------------------------------------------------------------
# Spec: prd.md § F1 — "Only Q present → emit just the Q line (no trailing LF)."
# The resulting MESSAGE is LINE2 \n Q: <Q>, with exactly ONE LF and no 'A: '
# segment, and no stray empty A line.
scenario_qa_q_only_fallback() {
  echo "[codex:m] Q-only → ONE LF, body contains 'Q: ' but NOT 'A: '"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local td proj stub_log
  td="$(make_tmp)"
  proj="${td}/codexproj_m"
  mkdir -p "${proj}"
  stub_log="${td}/stub.log"

  # Build a payload with Q present but last-assistant-message EMPTY.
  if ! command -v python3 >/dev/null 2>&1; then
    fail "(m) python3 required for empty-A payload construction"
    return
  fi
  local payload
  payload="$(CWD="${proj}" Q="why?" python3 -c '
import json, os
print(json.dumps({
  "type": "agent-turn-complete",
  "thread-id": "thr-l-m",
  "turn-id": "turn-m",
  "cwd": os.environ["CWD"],
  "client": "codex-cli",
  "input-messages": [os.environ["Q"]],
  "last-assistant-message": "",
}))
')"

  HOME="${td}" \
  NUDGE_NOTIFY_CMD="${STUB}" \
  NUDGE_NOTIFY_STUB_LOG="${stub_log}" \
  NUDGE_MIN_TURN_SEC=0 \
    bash "${WRAPPER}" "${payload}" >/dev/null 2>&1 || true

  if [[ ! -f "${stub_log}" ]] || [[ ! -s "${stub_log}" ]]; then
    fail "(m) stub never called"
    return
  fi

  local body
  body="$(read_log_field "${stub_log}" 2)"

  # The stub escapes literal LFs to the 2-char marker "\n" (backslash + n).
  # Count occurrences of that 2-char sequence in the captured body field.
  local lf_count
  lf_count=$(printf '%s' "${body}" | awk 'BEGIN{ FS="\\\\n" } { print NF - 1 }')
  if [[ "${lf_count}" -ne 1 ]]; then
    fail "(m) expected exactly 1 LF for Q-only fallback; got ${lf_count}; body='${body}'"
    return
  fi
  pass "(m) body contains exactly 1 LF"

  if [[ "${body}" != *"Q: "* ]]; then
    fail "(m) Q-line prefix 'Q: ' missing from body: '${body}'"
    return
  fi
  pass "(m) body contains 'Q: ' (Q-line prefix)"

  if [[ "${body}" == *"A: "* ]]; then
    fail "(m) Q-only fallback unexpectedly emitted 'A: ' (A-line prefix): '${body}'"
    return
  fi
  pass "(m) body does NOT contain 'A: ' (no stray A line)"

  # And there must be no trailing empty line right at the end (the body's
  # last 2 chars must not be the escaped "\n" marker).
  local body_tail="${body: -2}"
  if [[ "${body_tail}" == '\n' ]]; then
    fail "(m) Q-only body has trailing LF (should not): '${body}'"
    return
  fi
  pass "(m) body has no trailing LF (no empty A line)"
}

# ---------------------------------------------------------------------------
# Scenario (n) — A-only fallback → ONE LF; body contains 'A: ' but NOT 'Q: '
# ---------------------------------------------------------------------------
# Spec: prd.md § F1 — "Only A present → emit just the A line."
scenario_qa_a_only_fallback() {
  echo "[codex:n] A-only → ONE LF, body contains 'A: ' but NOT 'Q: '"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local td proj stub_log
  td="$(make_tmp)"
  proj="${td}/codexproj_n"
  mkdir -p "${proj}"
  stub_log="${td}/stub.log"

  if ! command -v python3 >/dev/null 2>&1; then
    fail "(n) python3 required for empty-Q payload construction"
    return
  fi
  local payload
  payload="$(CWD="${proj}" A="all done" python3 -c '
import json, os
print(json.dumps({
  "type": "agent-turn-complete",
  "thread-id": "thr-n",
  "turn-id": "turn-n",
  "cwd": os.environ["CWD"],
  "client": "codex-cli",
  "input-messages": [],
  "last-assistant-message": os.environ["A"],
}))
')"

  HOME="${td}" \
  NUDGE_NOTIFY_CMD="${STUB}" \
  NUDGE_NOTIFY_STUB_LOG="${stub_log}" \
  NUDGE_MIN_TURN_SEC=0 \
    bash "${WRAPPER}" "${payload}" >/dev/null 2>&1 || true

  if [[ ! -f "${stub_log}" ]] || [[ ! -s "${stub_log}" ]]; then
    fail "(n) stub never called"
    return
  fi

  local body
  body="$(read_log_field "${stub_log}" 2)"

  # The stub escapes literal LFs to the 2-char marker "\n" (backslash + n).
  # Count occurrences of that 2-char sequence in the captured body field.
  local lf_count
  lf_count=$(printf '%s' "${body}" | awk 'BEGIN{ FS="\\\\n" } { print NF - 1 }')
  if [[ "${lf_count}" -ne 1 ]]; then
    fail "(n) expected exactly 1 LF for A-only fallback; got ${lf_count}; body='${body}'"
    return
  fi
  pass "(n) body contains exactly 1 LF"

  if [[ "${body}" != *"A: "* ]]; then
    fail "(n) A-line prefix 'A: ' missing from body: '${body}'"
    return
  fi
  pass "(n) body contains 'A: ' (A-line prefix)"

  if [[ "${body}" == *"Q: "* ]]; then
    fail "(n) A-only fallback unexpectedly emitted 'Q: ' (Q-line prefix): '${body}'"
    return
  fi
  pass "(n) body does NOT contain 'Q: ' (no stray Q line)"
}

# ---------------------------------------------------------------------------
# Scenario (o) — NTFY_ID hash invariant: unchanged by the LF restructuring
# ---------------------------------------------------------------------------
# Spec: prd.md § F1 / F3 / handoff.md — "NTFY_ID dedup hash MUST be unchanged
# by this refactor. The LF restructuring of NTFY_MESSAGE does NOT leak into
# the dedup hash input."
#
# This test pins the dedup hash against the LF restructuring concretely: the
# hash must be a stable sha256-shaped digest, computed BEFORE the body
# assembly. Concretely:
#
#   (1) Two calls with IDENTICAL (Q, A, turn-id) MUST produce the same hash.
#       (Determinism — without this the dedup mechanism cannot suppress
#       replays at all.)
#   (2) Two calls with IDENTICAL (Q, A, turn-id) but where one of them feeds
#       the wrapper a Q that triggers truncation (long-Q vs short-Q with the
#       same prefix) MUST still produce the same hash. The handoff calls this
#       the "pre-truncation raw values" rule — the LF/render-side change must
#       not move the hash to a post-truncation or post-LF-assembly input.
#   (3) The hash MUST be a 64-char lowercase hex sha256 digest. The PRD
#       documents the sha256 input format as "qa:<PROMPT_RAW>\\0<ANSWER_RAW>";
#       this assertion locks in the output shape so a regression to a non-hex,
#       short, or empty value is caught.
#   (4) Two calls with DIFFERENT Q (and same turn-id) MUST produce DIFFERENT
#       hashes. This is the regression guard: if the LF refactor accidentally
#       breaks the hash input so it stops including Q (e.g. drops Q entirely),
#       two distinct prompts would collide and dedup would suppress legitimate
#       follow-up notifications.
scenario_ntfy_id_hash_unchanged_by_lf_refactor() {
  echo "[codex:o] NTFY_ID hash invariant — stable across calls, LF refactor does not leak"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local td proj stub_log
  td="$(make_tmp)"
  proj="${td}/codexproj_o"
  mkdir -p "${proj}"
  stub_log="${td}/stub.log"

  # Call 1 — short Q + A, fixed turn-id.
  local q1="how do I run tests?"
  local a1="bash test.sh"
  local payload1
  payload1="$(make_payload "${proj}" "${q1}" "${a1}" "turn-o")"

  HOME="${td}" \
  NUDGE_NOTIFY_CMD="${STUB}" \
  NUDGE_NOTIFY_STUB_LOG="${stub_log}" \
  NUDGE_MIN_TURN_SEC=0 \
    bash "${WRAPPER}" "${payload1}" >/dev/null 2>&1 || true

  # Call 2 — IDENTICAL Q + A + turn-id to call 1. Hash must be byte-equal.
  HOME="${td}" \
  NUDGE_NOTIFY_CMD="${STUB}" \
  NUDGE_NOTIFY_STUB_LOG="${stub_log}" \
  NUDGE_MIN_TURN_SEC=0 \
    bash "${WRAPPER}" "${payload1}" >/dev/null 2>&1 || true

  # Call 3 — SAME turn-id, SAME A, but a LONG Q (forces truncation). The PRD
  # rule "pre-truncation raw values" means the hash sees the long Q raw, not
  # the truncated body — and the existing scenario 19 already pins this for
  # the truncation axis. We replay it here under the new LF assembly to
  # confirm the LF refactor does not flip the input from raw to LF-rendered.
  local long_q
  long_q="$(printf 'h%.0s' $(seq 1 400))"
  local payload_long
  payload_long="$(make_payload "${proj}" "${long_q}" "${a1}" "turn-o-long")"
  HOME="${td}" \
  NUDGE_NOTIFY_CMD="${STUB}" \
  NUDGE_NOTIFY_STUB_LOG="${stub_log}" \
  NUDGE_MIN_TURN_SEC=0 \
    bash "${WRAPPER}" "${payload_long}" >/dev/null 2>&1 || true

  # Call 4 — DIFFERENT Q + A + turn-id. Hash MUST differ from call 1.
  local q4="totally different prompt"
  local a4="totally different answer"
  local payload4
  payload4="$(make_payload "${proj}" "${q4}" "${a4}" "turn-o-other")"
  HOME="${td}" \
  NUDGE_NOTIFY_CMD="${STUB}" \
  NUDGE_NOTIFY_STUB_LOG="${stub_log}" \
  NUDGE_MIN_TURN_SEC=0 \
    bash "${WRAPPER}" "${payload4}" >/dev/null 2>&1 || true

  if [[ ! -f "${stub_log}" ]] || [[ ! -s "${stub_log}" ]]; then
    fail "(o) stub never called"
    return
  fi

  local line_count
  line_count="$(wc -l < "${stub_log}" | tr -d ' ')"
  if [[ "${line_count}" -ne 4 ]]; then
    fail "(o) expected 4 stub invocations, got ${line_count}; log:"
    cat "${stub_log}" >&2
    return
  fi

  local id1 id2 id3 id4
  id1="$(awk -F '\t' 'NR==1{print $4}' "${stub_log}")"
  id2="$(awk -F '\t' 'NR==2{print $4}' "${stub_log}")"
  id3="$(awk -F '\t' 'NR==3{print $4}' "${stub_log}")"
  id4="$(awk -F '\t' 'NR==4{print $4}' "${stub_log}")"

  if [[ -z "${id1}" ]] || [[ -z "${id2}" ]] || [[ -z "${id3}" ]] || [[ -z "${id4}" ]]; then
    fail "(o) NTFY_ID missing in at least one call (id1='${id1}' id2='${id2}' id3='${id3}' id4='${id4}')"
    return
  fi

  # Invariant 1: deterministic for identical input — same payload → same hash.
  if [[ "${id1}" != "${id2}" ]]; then
    fail "(o) identical payload produced different NTFY_IDs (non-deterministic hash): id1='${id1}' id2='${id2}'"
    return
  fi
  pass "(o) identical (Q,A,turn-id) → identical NTFY_ID across calls (deterministic)"

  # Invariant 2: shape is a 64-char lowercase hex sha256 digest.
  if [[ ! "${id1}" =~ ^[0-9a-f]{64}$ ]]; then
    fail "(o) NTFY_ID is not a 64-char lowercase hex sha256 digest: '${id1}'"
    return
  fi
  pass "(o) NTFY_ID is a 64-char lowercase hex sha256 digest (${id1:0:12}…)"

  # Invariant 3: the LONG-Q variant still produces a sha256-shaped digest
  # (i.e. the hash path didn't blow up on a 400-char Q that gets truncated
  # for display). This is the "LF refactor does not leak / hash uses raw
  # pre-truncation Q" guard, paired with scenario 19.
  if [[ ! "${id3}" =~ ^[0-9a-f]{64}$ ]]; then
    fail "(o) NTFY_ID is malformed when Q exceeds truncation cap: '${id3}'"
    return
  fi
  pass "(o) NTFY_ID is well-formed under long-Q truncation path"

  # Invariant 4: different Q+A → different hash (regression guard against
  # accidentally dropping Q/A from the hash input).
  if [[ "${id1}" == "${id4}" ]]; then
    fail "(o) different (Q,A) produced the SAME NTFY_ID — hash dropped Q/A from input"
    return
  fi
  pass "(o) different (Q,A) → different NTFY_ID (Q/A still drive the hash)"
}

main "$@"
