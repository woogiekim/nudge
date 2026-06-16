#!/usr/bin/env bash
# nudge — shared helpers for the per-tool context wrappers.
#
# This file is SOURCED by notify-claude.sh, notify-codex.sh, notify-gemini.sh.
# It does not run as a standalone command.
#
# Responsibilities:
#   - normalize_question:   collapse newlines/tabs/control chars to spaces, trim,
#                           and truncate to NUDGE_MAX_Q chars (default 70).
#   - format_and_send:      compose the 3-line message and dispatch to notify.sh
#                           (or whatever path NUDGE_NOTIFY_CMD points at).
#
# Fail-soft contract: even if notify.sh itself errors, return 0. Wrappers
# must never break the calling AI tool.

NUDGE_MAX_Q="${NUDGE_MAX_Q:-70}"

# Default notify command path. Tests override via NUDGE_NOTIFY_CMD pointing
# at tests/_fixtures/notify-stub.sh.
_nudge_notify_path() {
  local cmd="${NUDGE_NOTIFY_CMD:-${HOME}/.nudge/notify.sh}"
  printf '%s' "${cmd}"
}

# Strip control chars (incl. \n,\t,\r), collapse whitespace runs, trim,
# truncate to NUDGE_MAX_Q. Argument is the raw question/title string.
normalize_question() {
  local raw="${1:-}"
  if [[ -z "${raw}" ]]; then printf ''; return 0; fi

  # Replace control chars (\x00-\x1f and \x7f) with a single space using tr.
  # Then squeeze runs of whitespace and trim leading/trailing.
  local cleaned
  cleaned="$(printf '%s' "${raw}" | tr '\000-\037\177' ' ' | tr -s ' ')"
  # Trim leading/trailing whitespace
  cleaned="${cleaned#"${cleaned%%[![:space:]]*}"}"
  cleaned="${cleaned%"${cleaned##*[![:space:]]}"}"

  local max="${NUDGE_MAX_Q}"
  if (( ${#cleaned} > max )); then
    cleaned="${cleaned:0:max}…"
  fi
  printf '%s' "${cleaned}"
}

# Best-effort `git rev-parse --abbrev-ref HEAD` in a given dir.
# Prints the branch name or empty (never errors out).
git_branch_for() {
  local dir="${1:-}"
  if [[ -z "${dir}" ]] || [[ ! -d "${dir}" ]]; then printf ''; return 0; fi
  git -C "${dir}" rev-parse --abbrev-ref HEAD 2>/dev/null || true
}

# Format + send. Arguments:
#   $1 tool_label    e.g. "Claude Code"
#   $2 project_basename
#   $3 event_text    e.g. "Response complete" / "Waiting for input"
#   $4 git_branch    may be empty
#   $5 question      may be empty
#   $6 priority      default|high|urgent
#
# Builds:
#   TITLE = "{tool} · {project}"  (ntfy's `Tags: robot` adds the 🤖 icon)
#   MESSAGE line2 = "{event}" or "{event} · {branch}"
#   MESSAGE line3 = "💬 {question}"   (omitted if question empty)
# Then calls notify.sh "{TITLE}" "{MESSAGE}" "{priority}".
#
# Always returns 0 (fail-soft).
format_and_send() {
  local tool="${1:-AI}"
  local project="${2:-?}"
  local event="${3:-}"
  local branch="${4:-}"
  local question_raw="${5:-}"
  local priority="${6:-default}"

  # NOTE: do NOT prefix an emoji here. notify.sh sends `Tags: robot`, which
  # ntfy already renders as a 🤖 in front of the title. Adding a literal emoji
  # too produced a doubled "🤖🤖" in the notification.
  local title="${tool} · ${project}"

  local line2="${event}"
  if [[ -n "${branch}" ]]; then
    line2="${event} · ${branch}"
  fi

  local message="${line2}"
  if [[ -n "${question_raw}" ]]; then
    local q
    q="$(normalize_question "${question_raw}")"
    if [[ -n "${q}" ]]; then
      message="${line2}"$'\n'"💬 ${q}"
    fi
  fi

  local cmd
  cmd="$(_nudge_notify_path)"
  if [[ -x "${cmd}" ]] || [[ -f "${cmd}" ]]; then
    bash "${cmd}" "${title}" "${message}" "${priority}" 2>/dev/null || true
  fi
  return 0
}
