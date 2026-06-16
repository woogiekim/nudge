#!/usr/bin/env bash
# nudge — Claude Code context wrapper.
#
# Wired into ~/.claude/settings.json hooks (Stop, Notification). Claude Code
# pipes a JSON object to STDIN with fields cwd, transcript_path, session_id,
# hook_event_name (Notification also adds message + notification_type).
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
    local title="🤖 ${1:-Claude Code} · ${2:-?}"
    local notify="${NUDGE_NOTIFY_CMD:-${HOME}/.nudge/notify.sh}"
    [[ -f "${notify}" ]] && bash "${notify}" "${title}" "${3:-Done}" "${6:-default}" 2>/dev/null || true
  }
  normalize_question() { printf '%s' "${1:-}"; }
  git_branch_for() { printf ''; }
fi

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

PROJECT="$(basename "${CWD}" 2>/dev/null || echo '?')"
BRANCH="$(git_branch_for "${CWD}")"

# Pull question: aiTitle (latest) preferred, else lastPrompt (latest).
# Use jq -rs (slurp) so multi-line field values are NOT chopped by tail.
QUESTION=""
if [[ "${_JQ_OK}" -eq 1 ]] && [[ -n "${TRANSCRIPT_PATH}" ]] && [[ -f "${TRANSCRIPT_PATH}" ]]; then
  AITITLE="$(jq -rs '[.[] | select(.type=="ai-title")] | last | .aiTitle // empty' "${TRANSCRIPT_PATH}" 2>/dev/null || true)"
  # Strip a single trailing newline that jq tacks on; do not collapse internal newlines here.
  AITITLE="${AITITLE%$'\n'}"
  if [[ -n "${AITITLE}" ]]; then
    QUESTION="${AITITLE}"
  else
    LASTP="$(jq -rs '[.[] | select(.type=="last-prompt")] | last | .lastPrompt // empty' "${TRANSCRIPT_PATH}" 2>/dev/null || true)"
    LASTP="${LASTP%$'\n'}"
    [[ -n "${LASTP}" ]] && QUESTION="${LASTP}"
  fi
fi

format_and_send "${TOOL_LABEL}" "${PROJECT}" "${EVENT_TEXT}" "${BRANCH}" "${QUESTION}" "${PRIORITY}"
exit 0
