#!/usr/bin/env bash
# nudge — Codex CLI context wrapper.
#
# Wired via ~/.codex/config.toml's `notify` key. Codex passes the JSON
# payload as ARGV[1] (NOT stdin; stdin is null). Gate on
# type=="agent-turn-complete" — other event types are silent.
#
# Fields: type, thread-id, turn-id, cwd (may be absent on older Codex
# builds — fall back to $PWD), client, input-messages (FULL session
# user-prompt history; the current-turn prompt is the LAST element),
# last-assistant-message (the just-produced assistant answer for this turn).
#
# Fast-turn suppression (NUDGE_MIN_TURN_SEC, default 180):
#   Elapsed source priority — stamp file → rollout JSONL duration_ms → none.
#   When 0 < elapsed < NUDGE_MIN_TURN_SEC the banner is skipped (exit 0).
#   Set NUDGE_MIN_TURN_SEC=0 to disable the gate entirely.
#
# Long-content handling: Q and A are codepoint-truncated (see _nudge_lib.sh
# normalize_question / normalize_answer) so launchd's C locale cannot cut a
# Korean codepoint mid-byte. NUDGE_MAX_Q=80, NUDGE_MAX_A=120 by default.
#
# NTFY_ID dedup: derived from the payload turn-id when present, else from a
# stable sha256 over the pre-truncation Q+A. Stable across truncation length
# so receivers (notify-mac.sh) suppress cache replays consistently.
#
# FAIL SOFT — every new I/O is wrapped in `|| true` to preserve the launchd
# exit 0 invariant. Any extraction error still exits 0.

set -uo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LIB="${_SCRIPT_DIR}/_nudge_lib.sh"
if [[ ! -f "${_LIB}" ]] && [[ -f "${HOME}/.nudge/_nudge_lib.sh" ]]; then
  _LIB="${HOME}/.nudge/_nudge_lib.sh"
fi
# shellcheck disable=SC1090
[[ -f "${_LIB}" ]] && source "${_LIB}"

if ! declare -f format_and_send >/dev/null 2>&1; then
  format_and_send() {
    local title="${1:-Codex CLI} · ${2:-?}"
    local notify="${NUDGE_NOTIFY_CMD:-${HOME}/.nudge/notify.sh}"
    [[ -f "${notify}" ]] && bash "${notify}" "${title}" "${3:-Done}" "${6:-default}" 2>/dev/null || true
  }
  normalize_question() { printf '%s' "${1:-}"; }
  normalize_answer()   { printf '%s' "${1:-}"; }
  git_branch_for()     { printf ''; }
  nudge_truncate()     { cat; }
fi

TOOL_LABEL="Codex CLI"
PAYLOAD="${1:-}"

# Missing argv[1] → exit 0 (fail-soft, never error).
if [[ -z "${PAYLOAD}" ]]; then
  exit 0
fi

_JQ_OK=0
if command -v jq >/dev/null 2>&1; then _JQ_OK=1; fi
# NUDGE_FORCE_NO_JQ=1 lets tests simulate the no-jq fallback path even when
# jq is installed on the host.
if [[ "${NUDGE_FORCE_NO_JQ:-0}" -eq 1 ]]; then _JQ_OK=0; fi

# Try to read type — if jq missing or JSON invalid, treat as unknown event.
EVENT_TYPE=""
if [[ "${_JQ_OK}" -eq 1 ]]; then
  EVENT_TYPE="$(jq -r '.type // empty' <<<"${PAYLOAD}" 2>/dev/null || true)"
else
  # No-jq fallback: extract "type":"<value>" via awk so the agent-turn-complete
  # gate still works when jq is absent.
  EVENT_TYPE="$(printf '%s' "${PAYLOAD}" \
    | awk 'BEGIN{RS=","} /"type"[[:space:]]*:/ { sub(/.*"type"[[:space:]]*:[[:space:]]*"/, ""); sub(/".*/, ""); print; exit }' 2>/dev/null || true)"
fi

# Gate: only emit on agent-turn-complete (the only Codex event type today).
if [[ "${EVENT_TYPE}" != "agent-turn-complete" ]]; then
  exit 0
fi

CWD=""
TURN_ID=""
PROMPT=""
ANSWER=""
if [[ "${_JQ_OK}" -eq 1 ]]; then
  CWD="$(jq -r '.cwd // empty' <<<"${PAYLOAD}" 2>/dev/null || true)"
  TURN_ID="$(jq -r '."turn-id" // empty' <<<"${PAYLOAD}" 2>/dev/null || true)"
  # input-messages[-1] — the current-turn user prompt (input-messages is the
  # FULL session user-prompt history; the just-sent prompt is the LAST one).
  PROMPT="$(jq -r '."input-messages" | if length>0 then .[-1] else empty end' <<<"${PAYLOAD}" 2>/dev/null || true)"
  # last-assistant-message — the just-produced assistant answer for this turn.
  ANSWER="$(jq -r '."last-assistant-message" // empty' <<<"${PAYLOAD}" 2>/dev/null || true)"
else
  # No-jq fallback: do a coarse grep-based extraction so the wrapper still
  # produces a banner. We rely on the well-known field positions in Codex's
  # JSON payload (no embedded raw quotes are expected from the producer side).
  # Best-effort only — fail-soft to empty strings if the regex misses.
  CWD="$(printf '%s' "${PAYLOAD}" \
    | awk 'BEGIN{RS=","} /"cwd"[[:space:]]*:/ { sub(/.*"cwd"[[:space:]]*:[[:space:]]*"/, ""); sub(/".*/, ""); print; exit }' 2>/dev/null || true)"
  TURN_ID="$(printf '%s' "${PAYLOAD}" \
    | awk 'BEGIN{RS=","} /"turn-id"[[:space:]]*:/ { sub(/.*"turn-id"[[:space:]]*:[[:space:]]*"/, ""); sub(/".*/, ""); print; exit }' 2>/dev/null || true)"
  # input-messages last element via awk: find the last "..."
  # inside the input-messages array. This is a coarse but conservative grep.
  PROMPT="$(printf '%s' "${PAYLOAD}" \
    | awk '
      {
        s = $0
        i = index(s, "\"input-messages\"")
        if (i == 0) exit
        s = substr(s, i)
        b = index(s, "[")
        if (b == 0) exit
        e = index(s, "]")
        if (e == 0) exit
        arr = substr(s, b + 1, e - b - 1)
        last = ""
        # Greedy: pull the rightmost "..." token.
        while (match(arr, /"[^"]*"/)) {
          last = substr(arr, RSTART, RLENGTH)
          arr = substr(arr, RSTART + RLENGTH)
        }
        gsub(/^"|"$/, "", last)
        print last
      }' 2>/dev/null || true)"
  ANSWER="$(printf '%s' "${PAYLOAD}" \
    | awk 'BEGIN{RS=","} /"last-assistant-message"[[:space:]]*:/ { sub(/.*"last-assistant-message"[[:space:]]*:[[:space:]]*"/, ""); sub(/".*/, ""); print; exit }' 2>/dev/null || true)"
fi

# Codex schema may omit .cwd on older builds → defensive fallback.
[[ -z "${CWD}" ]] && CWD="${PWD}"

PROJECT="$(basename "${CWD}" 2>/dev/null || echo '?')"
BRANCH="$(git_branch_for "${CWD}")"

# Preserve pre-truncation Q and A so NTFY_ID can be derived from a stable
# source even after the body is shortened.
PROMPT_RAW="${PROMPT}"
ANSWER_RAW="${ANSWER}"

# Trim the assistant answer to its first line BEFORE codepoint truncation
# (multi-line answers must not survive into the banner).
if [[ -n "${ANSWER}" ]]; then
  ANSWER="${ANSWER%%$'\n'*}"
fi

# Apply codepoint-safe truncation. normalize_question and normalize_answer
# both run LC_ALL=en_US.UTF-8 awk internally so launchd's C locale cannot
# cut a Korean codepoint mid-byte.
PROMPT_TRUNC=""
ANSWER_TRUNC=""
if [[ -n "${PROMPT}" ]]; then
  PROMPT_TRUNC="$(normalize_question "${PROMPT}")"
fi
if [[ -n "${ANSWER}" ]]; then
  ANSWER_TRUNC="$(normalize_answer "${ANSWER}")"
fi

# Compose ONE combined string "Q: <prompt>  A: <answer>" (two-space inline
# separator — preserved through to the banner body so receivers can split the
# two halves reliably). Fallbacks: only prompt → "Q: <prompt>"; only answer →
# "A: <answer>"; both empty → "" (the 💬 line is omitted).
QUESTION=""
if [[ -n "${PROMPT_TRUNC}" ]] && [[ -n "${ANSWER_TRUNC}" ]]; then
  QUESTION="Q: ${PROMPT_TRUNC}  A: ${ANSWER_TRUNC}"
elif [[ -n "${PROMPT_TRUNC}" ]]; then
  QUESTION="Q: ${PROMPT_TRUNC}"
elif [[ -n "${ANSWER_TRUNC}" ]]; then
  QUESTION="A: ${ANSWER_TRUNC}"
fi

# ---------------------------------------------------------------------------
# NTFY_ID dedup hash — stable across truncation.
# ---------------------------------------------------------------------------
# Priority:
#   1) sha256("turn:<turn-id>") when payload turn-id is non-empty.
#   2) sha256("qa:<PROMPT_RAW>\0<ANSWER_RAW>") (pre-truncation hash).
#   3) Empty (no dedup possible).
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

NTFY_ID=""
if [[ -n "${TURN_ID}" ]]; then
  NTFY_ID="$(_sha256_helper "turn:${TURN_ID}" || true)"
elif [[ -n "${PROMPT_RAW}" || -n "${ANSWER_RAW}" ]]; then
  NTFY_ID="$(_sha256_helper "qa:${PROMPT_RAW}"$'\0'"${ANSWER_RAW}" || true)"
fi
export NTFY_ID

# ---------------------------------------------------------------------------
# Fast-turn suppression gate (NUDGE_MIN_TURN_SEC).
# ---------------------------------------------------------------------------
NUDGE_MIN_TURN_SEC="${NUDGE_MIN_TURN_SEC:-180}"

# Compute the same stamp key the hook used:
#   sha256(cwd + "\0" + ${CODEX_SESSION_ID:-${CODEX_SESSION:-}})  when a
# session env var is present, else sha256(cwd).
_stamp_key() {
  local key_input
  local sess="${CODEX_SESSION_ID:-${CODEX_SESSION:-}}"
  if [[ -n "${sess}" ]]; then
    key_input="${CWD}"$'\0'"${sess}"
  else
    # Single-session collision limitation: when no session env var is
    # present, two interleaved Codex sessions in the same cwd will share
    # a stamp file. Documented in PRD §F2.
    key_input="${CWD}"
  fi
  _sha256_helper "${key_input}"
}

STAMP_DIR="${HOME}/.nudge/turn-stamps"
STAMP_KEY="$(_stamp_key || true)"
STAMP_FILE=""
[[ -n "${STAMP_KEY}" ]] && STAMP_FILE="${STAMP_DIR}/${STAMP_KEY}"

# Best-effort stale-stamp sweep (idempotent; survives missing dir).
find "${STAMP_DIR}" -type f -mmin +120 -delete 2>/dev/null || true

NOW="$(date +%s 2>/dev/null || printf '0')"
ELAPSED=""
ELAPSED_SOURCE="none"

# 1) Stamp file
if [[ -n "${STAMP_FILE}" && -f "${STAMP_FILE}" ]]; then
  STAMP_EPOCH="$(cat "${STAMP_FILE}" 2>/dev/null || true)"
  rm -f "${STAMP_FILE}" 2>/dev/null || true
  if [[ -n "${STAMP_EPOCH}" ]] && [[ "${STAMP_EPOCH}" =~ ^[0-9]+$ ]]; then
    ELAPSED=$(( NOW - STAMP_EPOCH ))
    ELAPSED_SOURCE="stamp"
  fi
fi

# 2) Rollout JSONL fallback (only when no stamp AND jq available).
if [[ -z "${ELAPSED}" && "${_JQ_OK}" -eq 1 && -n "${TURN_ID}" ]]; then
  ROLLOUT_DIR="${NUDGE_CODEX_SESSIONS_DIR:-${HOME}/.codex/sessions}"
  # Locate most recent rollout-*.jsonl by mtime. ls -t is portable on macOS
  # bash 3.2 and Linux. find -printf is gawk-only — avoid.
  ROLLOUT_FILE=""
  if [[ -d "${ROLLOUT_DIR}" ]]; then
    # shellcheck disable=SC2012
    ROLLOUT_FILE="$(find "${ROLLOUT_DIR}" -type f -name 'rollout-*.jsonl' -print0 2>/dev/null \
      | xargs -0 ls -t 2>/dev/null \
      | head -n 1 || true)"
  fi
  if [[ -n "${ROLLOUT_FILE}" && -f "${ROLLOUT_FILE}" ]]; then
    # Search every line for a record matching the payload turn-id; read its
    # duration in ms, tolerating field-name variants.
    DUR_MS="$(jq -r --arg tid "${TURN_ID}" '
      select((."turn-id" // .turn_id // .turnId // "") == $tid)
      | (.duration_ms // .durationMs // .duration // empty)
    ' "${ROLLOUT_FILE}" 2>/dev/null | head -n 1 || true)"
    if [[ -n "${DUR_MS}" ]] && [[ "${DUR_MS}" =~ ^[0-9]+$ ]]; then
      ELAPSED=$(( DUR_MS / 1000 ))
      ELAPSED_SOURCE="jsonl"
    fi
  fi
fi

# Debug logging (only when NUDGE_DEBUG=1).
if [[ "${NUDGE_DEBUG:-0}" -eq 1 ]]; then
  echo "nudge[codex] elapsed=${ELAPSED:-} source=${ELAPSED_SOURCE} min=${NUDGE_MIN_TURN_SEC} turn=${TURN_ID:-}" >&2
fi

# Suppression rule: gate enabled, elapsed available, within the window.
if [[ "${NUDGE_MIN_TURN_SEC}" -gt 0 ]] && [[ -n "${ELAPSED}" ]] && \
   [[ "${ELAPSED}" -gt 0 ]] && [[ "${ELAPSED}" -lt "${NUDGE_MIN_TURN_SEC}" ]]; then
  if [[ "${NUDGE_DEBUG:-0}" -eq 1 ]]; then
    echo "nudge[codex] decision=skip (elapsed=${ELAPSED}s < ${NUDGE_MIN_TURN_SEC}s)" >&2
  fi
  exit 0
fi

if [[ "${NUDGE_DEBUG:-0}" -eq 1 ]]; then
  echo "nudge[codex] decision=send" >&2
fi

# Build the banner directly (bypassing format_and_send's normalize_question
# step). The Q/A is already codepoint-truncated upstream; calling
# normalize_question here would collapse the two-space "Q: x  A: y" delimiter
# and re-apply NUDGE_MAX_Q to the combined string. We replicate the title /
# branch line / 💬 question construction inline.
TITLE="${TOOL_LABEL} · ${PROJECT}"
LINE2="Response complete"
if [[ -n "${BRANCH}" ]]; then
  LINE2="${LINE2} · ${BRANCH}"
fi
MESSAGE="${LINE2}"
if [[ -n "${QUESTION}" ]]; then
  MESSAGE="${LINE2}"$'\n'"💬 ${QUESTION}"
fi

NOTIFY_CMD="${NUDGE_NOTIFY_CMD:-${HOME}/.nudge/notify.sh}"
if [[ -x "${NOTIFY_CMD}" ]] || [[ -f "${NOTIFY_CMD}" ]]; then
  bash "${NOTIFY_CMD}" "${TITLE}" "${MESSAGE}" "default" 2>/dev/null || true
fi

exit 0
