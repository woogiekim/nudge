#!/usr/bin/env bash
# nudge — Gemini CLI context wrapper.
#
# Wired into ~/.gemini/settings.json hooks (AfterAgent, Notification).
# Gemini CLI pipes JSON on STDIN. Base fields: cwd, transcript_path,
# session_id, hook_event_name. AfterAgent adds .prompt + .prompt_response;
# Notification adds .message + .notification_type.
#
# FAIL SOFT — malformed JSON or missing fields still emits a basic
# "{Tool} · {project}" notification.

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
    local title="🤖 ${1:-Gemini CLI} · ${2:-?}"
    local notify="${NUDGE_NOTIFY_CMD:-${HOME}/.nudge/notify.sh}"
    [[ -f "${notify}" ]] && bash "${notify}" "${title}" "${3:-Done}" "${6:-default}" 2>/dev/null || true
  }
  normalize_question() { printf '%s' "${1:-}"; }
  git_branch_for() { printf ''; }
fi

TOOL_LABEL="Gemini CLI"

STDIN_JSON=""
if [[ ! -t 0 ]]; then
  STDIN_JSON="$(cat 2>/dev/null || true)"
fi

_JQ_OK=0
if command -v jq >/dev/null 2>&1; then _JQ_OK=1; fi

# Parse JSON; tolerate malformed input.
_jq_field() {
  if [[ "${_JQ_OK}" -ne 1 ]]; then printf ''; return; fi
  local filter="$1" json="${2:-}"
  [[ -z "${json}" ]] && { printf ''; return; }
  jq -r "${filter} // empty" <<<"${json}" 2>/dev/null || true
}

CWD="$(_jq_field '.cwd' "${STDIN_JSON}")"
HOOK_EVENT="$(_jq_field '.hook_event_name' "${STDIN_JSON}")"
HOOK_MESSAGE="$(_jq_field '.message' "${STDIN_JSON}")"
PROMPT="$(_jq_field '.prompt' "${STDIN_JSON}")"

# Defensive fallbacks. Gemini env-var alias to CLAUDE_PROJECT_DIR exists,
# but we prefer GEMINI_PROJECT_DIR if set.
[[ -z "${CWD}" ]] && CWD="${GEMINI_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-${PWD}}}"
[[ -z "${HOOK_EVENT}" ]] && HOOK_EVENT="AfterAgent"

# Map hook_event → event text + priority.
case "${HOOK_EVENT}" in
  Notification)
    EVENT_TEXT="${HOOK_MESSAGE:-Waiting for input or approval}"
    PRIORITY="high"
    ;;
  AfterAgent|PostAgent|*)
    EVENT_TEXT="Task complete"
    PRIORITY="default"
    ;;
esac

PROJECT="$(basename "${CWD}" 2>/dev/null || echo '?')"
BRANCH="$(git_branch_for "${CWD}")"

# Question: AfterAgent.prompt wins; else (for Notification) we pass none.
QUESTION="${PROMPT}"

format_and_send "${TOOL_LABEL}" "${PROJECT}" "${EVENT_TEXT}" "${BRANCH}" "${QUESTION}" "${PRIORITY}"
exit 0
