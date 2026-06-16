#!/usr/bin/env bash
# nudge — Codex CLI context wrapper.
#
# Wired via ~/.codex/config.toml's `notify` key. Codex passes the JSON
# payload as ARGV[1] (NOT stdin; stdin is null). Gate on
# type=="agent-turn-complete" — other event types are silent.
#
# Fields: type, thread-id, turn-id, cwd (may be absent on older Codex
# builds — fall back to $PWD), client, input-messages (array; user prompts),
# last-assistant-message.
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
    local title="🤖 ${1:-Codex CLI} · ${2:-?}"
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
QUESTION=""
if [[ "${_JQ_OK}" -eq 1 ]]; then
  CWD="$(jq -r '.cwd // empty' <<<"${PAYLOAD}" 2>/dev/null || true)"
  # input-messages[0] — the user's most recent prompt for this turn.
  QUESTION="$(jq -r '."input-messages"[0] // empty' <<<"${PAYLOAD}" 2>/dev/null || true)"
fi

# Codex schema may omit .cwd on older builds → defensive fallback.
[[ -z "${CWD}" ]] && CWD="${PWD}"

PROJECT="$(basename "${CWD}" 2>/dev/null || echo '?')"
BRANCH="$(git_branch_for "${CWD}")"

format_and_send "${TOOL_LABEL}" "${PROJECT}" "Response complete" "${BRANCH}" "${QUESTION}" "default"
exit 0
