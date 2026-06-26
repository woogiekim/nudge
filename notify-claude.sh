#!/usr/bin/env bash
# nudge — Claude Code context wrapper.
#
# Wired into ~/.claude/settings.json hooks:
#   - UserPromptSubmit -> notify-claude-turn-start.sh records start time.
#   - Stop             -> this wrapper sends the completion banner.
# Claude Code pipes a JSON object to STDIN with fields cwd, transcript_path,
# session_id, hook_event_name. When Stop fires, no additional fields. The code
# defensively handles Notification events (which add message +
# notification_type) in case they are wired in the future, but nudge currently
# wires completion notifications through Stop only.
#
# This wrapper extracts project/branch/question and calls the shared notify.sh
# (or whatever path NUDGE_NOTIFY_CMD points at) with an enriched 3-line message.
#
# Hard rule: FAIL SOFT — any extraction error still emits a basic
# "{Tool} · {project}" notification rather than breaking Claude Code.

set -uo pipefail

# Resolve script dir to find the shared lib next to us (or in ~/.nudge/).
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LIB="${_SCRIPT_DIR}/_nudge_lib.sh"
if [[ ! -f "${_LIB}" ]] && [[ -f "${HOME}/.nudge/_nudge_lib.sh" ]]; then
  _LIB="${HOME}/.nudge/_nudge_lib.sh"
fi
# shellcheck disable=SC1090
[[ -f "${_LIB}" ]] && source "${_LIB}"

# Provide minimal fallbacks if lib is missing — we still want fail-soft.
if ! declare -f format_and_send >/dev/null 2>&1; then
  format_and_send() {
    local title="${1:-Claude Code} · ${2:-?}"
    local notify="${NUDGE_NOTIFY_CMD:-${HOME}/.nudge/notify.sh}"
    [[ -f "${notify}" ]] && bash "${notify}" "${title}" "${3:-Done}" "${6:-default}" 2>/dev/null || true
  }
  normalize_question() { printf '%s' "${1:-}"; }
  normalize_answer()   { printf '%s' "${1:-}"; }
  git_branch_for() { printf ''; }
fi

_sha256_helper() {
  local input="$1"
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "${input}" | shasum -a 256 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "${input}" | sha256sum 2>/dev/null | awk '{print $1}'
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import hashlib,sys; sys.stdout.write(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())' <<<"${input}" 2>/dev/null
  else
    printf ''
  fi
}

TOOL_LABEL="Claude Code"

# Read all of stdin into a variable; do not error if stdin is empty.
STDIN_JSON=""
if [[ ! -t 0 ]]; then
  STDIN_JSON="$(cat 2>/dev/null || true)"
fi

# Pull fields with jq; if jq is unavailable, all extractions degrade to empty.
_JQ_OK=0
if command -v jq >/dev/null 2>&1; then _JQ_OK=1; fi

_jq_field() {
  # $1 = jq filter, $2 = JSON blob
  if [[ "${_JQ_OK}" -ne 1 ]]; then printf ''; return; fi
  local filter="$1" json="${2:-}"
  [[ -z "${json}" ]] && { printf ''; return; }
  jq -r "${filter} // empty" <<<"${json}" 2>/dev/null || true
}

CWD="$(_jq_field '.cwd' "${STDIN_JSON}")"
TRANSCRIPT_PATH="$(_jq_field '.transcript_path' "${STDIN_JSON}")"
SESSION_ID="$(_jq_field '.session_id' "${STDIN_JSON}")"
HOOK_EVENT="$(_jq_field '.hook_event_name' "${STDIN_JSON}")"
HOOK_MESSAGE="$(_jq_field '.message' "${STDIN_JSON}")"

# Defensive fallbacks.
[[ -z "${CWD}" ]] && CWD="${CLAUDE_PROJECT_DIR:-${PWD}}"
[[ -z "${HOOK_EVENT}" ]] && HOOK_EVENT="Stop"

# Map hook_event → human event text + priority.
case "${HOOK_EVENT}" in
  Notification)
    EVENT_TEXT="${HOOK_MESSAGE:-Waiting for your input}"
    PRIORITY="high"
    ;;
  Stop|PostStop|*)
    EVENT_TEXT="Response complete"
    PRIORITY="default"
    ;;
esac

# Fast-turn suppression for completion events. Claude has no duration in the
# Stop payload, so the UserPromptSubmit hook writes a best-effort stamp first.
case "${HOOK_EVENT}" in
  Stop|PostStop)
    NUDGE_MIN_TURN_SEC="${NUDGE_MIN_TURN_SEC:-180}"
    if ! [[ "${NUDGE_MIN_TURN_SEC}" =~ ^[0-9]+$ ]]; then
      NUDGE_MIN_TURN_SEC=180
    fi

    key_input="${CWD}"
    if [[ -n "${SESSION_ID}" ]]; then
      key_input="${CWD}"$'\0'"${SESSION_ID}"
    fi

    STAMP_DIR="${HOME}/.nudge/turn-stamps"
    STAMP_KEY="$(_sha256_helper "${key_input}" 2>/dev/null || true)"
    STAMP_FILE=""
    [[ -n "${STAMP_KEY}" ]] && STAMP_FILE="${STAMP_DIR}/${STAMP_KEY}"

    find "${STAMP_DIR}" -type f -mmin +120 -delete 2>/dev/null || true

    NOW="$(date +%s 2>/dev/null || printf '0')"
    ELAPSED=""
    if [[ -n "${STAMP_FILE}" && -f "${STAMP_FILE}" ]]; then
      STAMP_EPOCH="$(cat "${STAMP_FILE}" 2>/dev/null || true)"
      rm -f "${STAMP_FILE}" 2>/dev/null || true
      if [[ -n "${STAMP_EPOCH}" ]] && [[ "${STAMP_EPOCH}" =~ ^[0-9]+$ ]]; then
        ELAPSED=$(( NOW - STAMP_EPOCH ))
      fi
    fi

    if [[ "${NUDGE_DEBUG:-0}" -eq 1 ]]; then
      echo "nudge[claude] elapsed=${ELAPSED:-} min=${NUDGE_MIN_TURN_SEC}" >&2
    fi

    if [[ "${NUDGE_MIN_TURN_SEC}" -gt 0 ]] && [[ -n "${ELAPSED}" ]] && \
       [[ "${ELAPSED}" -gt 0 ]] && [[ "${ELAPSED}" -lt "${NUDGE_MIN_TURN_SEC}" ]]; then
      if [[ "${NUDGE_DEBUG:-0}" -eq 1 ]]; then
        echo "nudge[claude] decision=skip (elapsed=${ELAPSED}s < ${NUDGE_MIN_TURN_SEC}s)" >&2
      fi
      exit 0
    fi
    ;;
esac

PROJECT="$(basename "${CWD}" 2>/dev/null || echo '?')"
BRANCH="$(git_branch_for "${CWD}")"

# Pull question with strongest-first priority:
#   1. LAST transcript record where type=="user" AND content is genuine human
#      text (string .message.content, OR .message.content[0] of type "text"
#      with non-empty .text). This avoids tool_result / tool_use / non-user
#      payloads leaking into the banner body.
#   2. last-prompt (the entry that updates every turn).
#   3. ai-title (session-frozen auto-title) — final fallback.
#   4. empty.
# Use jq -rs (slurp) so multi-line field values are NOT chopped by tail.
QUESTION=""
ANSWER=""
if [[ "${_JQ_OK}" -eq 1 ]] && [[ -n "${TRANSCRIPT_PATH}" ]] && [[ -f "${TRANSCRIPT_PATH}" ]]; then
  USERTXT="$(jq -rs '
    [ .[]
      | select(.type=="user")
      | select((.isMeta // false) != true)
      | select(.toolUseResult == null)
      | (.message.content) as $c
      | if ($c | type) == "string" then
          (if ($c | startswith("<command-message>"))
             or ($c | startswith("<command-name>"))
             or ($c | startswith("<command-args>"))
             or ($c | startswith("<local-command-stdout>"))
             or ($c | startswith("<local-command-caveat>"))
             or ($c | startswith("<bash-input>"))
             or ($c | startswith("<bash-stdout>"))
             or ($c | startswith("<bash-stderr>"))
           then empty else $c end)
        elif ($c | type) == "array"
             and ($c | length) > 0
             and ($c[0].type == "text")
             and (($c[0].text // "") != "")
          then $c[0].text
        else empty end
    ] | last // empty
  ' "${TRANSCRIPT_PATH}" 2>/dev/null || true)"
  # Strip a single trailing newline that jq tacks on; do not collapse internal newlines here.
  USERTXT="${USERTXT%$'\n'}"
  if [[ -n "${USERTXT}" ]]; then
    QUESTION="${USERTXT}"
  else
    LASTP="$(jq -rs '[.[] | select(.type=="last-prompt")] | last | .lastPrompt // empty' "${TRANSCRIPT_PATH}" 2>/dev/null || true)"
    LASTP="${LASTP%$'\n'}"
    if [[ -n "${LASTP}" ]]; then
      QUESTION="${LASTP}"
    else
      AITITLE="$(jq -rs '[.[] | select(.type=="ai-title")] | last | .aiTitle // empty' "${TRANSCRIPT_PATH}" 2>/dev/null || true)"
      AITITLE="${AITITLE%$'\n'}"
      [[ -n "${AITITLE}" ]] && QUESTION="${AITITLE}"
    fi
  fi

  # Extract the assistant answer (A) from the transcript JSONL.
  # Selector: examine the LAST `.type=="assistant"` record (slurped over the
  # whole transcript). Within that record's `.message.content[]` array, emit
  # the LAST non-empty `text` block. If the last assistant record carries no
  # text block (e.g. it is tool_use-only), emit empty — caller omits the A
  # line entirely (mirrors notify-codex.sh's empty-A omit policy).
  #
  # Rationale: a Claude turn often contains multiple assistant records
  # (thinking / tool_use / text). A naive "last assistant record" pick is
  # frequently a tool_use record with no text. The picker must agree with the
  # PRD's "turn ends in tool_use → omit A" semantics, so it inspects the LAST
  # assistant record specifically rather than scanning across the whole turn.
  ANSWER="$(jq -rs '
    [ .[] | select(.type=="assistant") ] | last as $rec
    | if $rec == null then empty
      else
        [ ($rec.message.content // [])[]
          | select(.type=="text")
          | (.text // "")
          | select(. != "")
        ] | last // empty
      end
  ' "${TRANSCRIPT_PATH}" 2>/dev/null || true)"
  # Strip a single trailing newline that jq tacks on.
  ANSWER="${ANSWER%$'\n'}"
fi

# Trim the assistant answer to its first line BEFORE codepoint truncation
# (multi-line answers must not survive into the banner). Mirrors
# notify-codex.sh:142-144.
if [[ -n "${ANSWER}" ]]; then
  ANSWER="${ANSWER%%$'\n'*}"
fi

# Apply codepoint-safe normalization/truncation. normalize_question collapses
# control chars and truncates to NUDGE_MAX_Q; normalize_answer does the same
# for NUDGE_MAX_A. Both bypass launchd's C locale by forcing UTF-8.
QUESTION_TRUNC=""
ANSWER_TRUNC=""
if [[ -n "${QUESTION}" ]]; then
  QUESTION_TRUNC="$(normalize_question "${QUESTION}")"
fi
if [[ -n "${ANSWER}" ]]; then
  ANSWER_TRUNC="$(normalize_answer "${ANSWER}")"
fi

# Build labeled Q and A lines (only when content is present).
QUESTION_LINE=""
ANSWER_LINE=""
if [[ -n "${QUESTION_TRUNC}" ]]; then
  QUESTION_LINE="Q: ${QUESTION_TRUNC}"
fi
if [[ -n "${ANSWER_TRUNC}" ]]; then
  ANSWER_LINE="A: ${ANSWER_TRUNC}"
fi

# Compose the 3-segment LF-delimited body (mirrors notify-codex.sh:307-319).
# Segment layout:
#   - 3 segments (LINE2 + Q + A): "${LINE2}\nQ: ${Q}\nA: ${A}"
#   - 2 segments (LINE2 + Q):     "${LINE2}\nQ: ${Q}"
#   - 2 segments (LINE2 + A):     "${LINE2}\nA: ${A}"  (Q absent)
#   - 1 segment  (LINE2 only):    "${LINE2}"
# Empty-A policy: when ANSWER_LINE is empty, the A segment is omitted entirely
# (no bare "A:" ever appears).
TITLE="${TOOL_LABEL} · ${PROJECT}"
LINE2="${EVENT_TEXT}"
if [[ -n "${BRANCH}" ]]; then
  LINE2="${EVENT_TEXT} · ${BRANCH}"
fi
MESSAGE="${LINE2}"
if [[ -n "${QUESTION_LINE}" ]] && [[ -n "${ANSWER_LINE}" ]]; then
  MESSAGE="${LINE2}"$'\n'"${QUESTION_LINE}"$'\n'"${ANSWER_LINE}"
elif [[ -n "${QUESTION_LINE}" ]]; then
  MESSAGE="${LINE2}"$'\n'"${QUESTION_LINE}"
elif [[ -n "${ANSWER_LINE}" ]]; then
  MESSAGE="${LINE2}"$'\n'"${ANSWER_LINE}"
fi

NOTIFY_CMD="${NUDGE_NOTIFY_CMD:-${HOME}/.nudge/notify.sh}"
if [[ -x "${NOTIFY_CMD}" ]] || [[ -f "${NOTIFY_CMD}" ]]; then
  bash "${NOTIFY_CMD}" "${TITLE}" "${MESSAGE}" "${PRIORITY}" 2>/dev/null || true
fi
exit 0
