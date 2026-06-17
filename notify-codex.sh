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
# FAIL SOFT — any extraction error still exits 0.

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
  git_branch_for() { printf ''; }
fi

TOOL_LABEL="Codex CLI"
PAYLOAD="${1:-}"

# Missing argv[1] → exit 0 (fail-soft, never error).
if [[ -z "${PAYLOAD}" ]]; then
  exit 0
fi

_JQ_OK=0
if command -v jq >/dev/null 2>&1; then _JQ_OK=1; fi

# Try to read type — if jq missing or JSON invalid, treat as unknown event.
EVENT_TYPE=""
if [[ "${_JQ_OK}" -eq 1 ]]; then
  EVENT_TYPE="$(jq -r '.type // empty' <<<"${PAYLOAD}" 2>/dev/null || true)"
fi

# Gate: only emit on agent-turn-complete (the only Codex event type today).
if [[ "${EVENT_TYPE}" != "agent-turn-complete" ]]; then
  exit 0
fi

CWD=""
PROMPT=""
ANSWER=""
if [[ "${_JQ_OK}" -eq 1 ]]; then
  CWD="$(jq -r '.cwd // empty' <<<"${PAYLOAD}" 2>/dev/null || true)"
  # input-messages[-1] — the current-turn user prompt (input-messages is the
  # FULL session user-prompt history; the just-sent prompt is the LAST one).
  PROMPT="$(jq -r '."input-messages" | if length>0 then .[-1] else empty end' <<<"${PAYLOAD}" 2>/dev/null || true)"
  # last-assistant-message — the just-produced assistant answer for this turn.
  ANSWER="$(jq -r '."last-assistant-message" // empty' <<<"${PAYLOAD}" 2>/dev/null || true)"
fi

# Codex schema may omit .cwd on older builds → defensive fallback.
[[ -z "${CWD}" ]] && CWD="${PWD}"

PROJECT="$(basename "${CWD}" 2>/dev/null || echo '?')"
BRANCH="$(git_branch_for "${CWD}")"

# Cap the assistant answer to keep the combined Q/A string compact. Cut at
# the first newline (one-line), then hard-cap to ~200 chars with an ellipsis.
if [[ -n "${ANSWER}" ]]; then
  ANSWER="${ANSWER%%$'\n'*}"
  if (( ${#ANSWER} > 200 )); then
    ANSWER="${ANSWER:0:200}…"
  fi
fi

# Compose ONE combined string "Q: <prompt>  A: <answer>" (two-space inline
# separator — _nudge_lib.sh collapses newlines, so multi-line will not survive).
# Fallbacks: only prompt → "Q: <prompt>"; only answer → "A: <answer>";
# both empty → "" (format_and_send omits the 💬 line).
QUESTION=""
if [[ -n "${PROMPT}" ]] && [[ -n "${ANSWER}" ]]; then
  QUESTION="Q: ${PROMPT}  A: ${ANSWER}"
elif [[ -n "${PROMPT}" ]]; then
  QUESTION="Q: ${PROMPT}"
elif [[ -n "${ANSWER}" ]]; then
  QUESTION="A: ${ANSWER}"
fi

# Raise the local truncation cap so the combined Q/A is not aggressively cut.
# Scope: this script's subshell only — _nudge_lib.sh remains unmodified.
export NUDGE_MAX_Q=200

format_and_send "${TOOL_LABEL}" "${PROJECT}" "Response complete" "${BRANCH}" "${QUESTION}" "default"
exit 0
