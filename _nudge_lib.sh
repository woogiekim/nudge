#!/usr/bin/env bash
# nudge — shared helpers for the per-tool context wrappers.
#
# This file is SOURCED by notify-claude.sh, notify-codex.sh, notify-gemini.sh.
# It does not run as a standalone command.
#
# Responsibilities:
#   - nudge_truncate:       codepoint-safe truncation primitive reading stdin
#                           and writing stdout. Forces LC_ALL=en_US.UTF-8
#                           internally so launchd's C locale doesn't cut a
#                           multibyte sequence mid-codepoint.
#   - normalize_question:   collapse newlines/tabs/control chars to spaces, trim,
#                           and truncate to NUDGE_MAX_Q codepoints (default 80).
#   - normalize_answer:     trim the assistant answer to its first line and
#                           codepoint-truncate to NUDGE_MAX_A (default 120).
#   - format_and_send:      compose the 3-line message and dispatch to notify.sh
#                           (or whatever path NUDGE_NOTIFY_CMD points at).
#
# Fail-soft contract: even if notify.sh itself errors, return 0. Wrappers
# must never break the calling AI tool.

NUDGE_MAX_Q="${NUDGE_MAX_Q:-80}"
NUDGE_MAX_A="${NUDGE_MAX_A:-120}"

# Default notify command path. Tests override via NUDGE_NOTIFY_CMD pointing
# at tests/_fixtures/notify-stub.sh.
_nudge_notify_path() {
  local cmd="${NUDGE_NOTIFY_CMD:-${HOME}/.nudge/notify.sh}"
  printf '%s' "${cmd}"
}

# Codepoint-safe truncation. Reads stdin, writes stdout.
#
# Usage:
#   printf '%s' "$text" | nudge_truncate 80
#
# Behavior:
#   - If max is 0 (or empty), pass through unchanged (bypass).
#   - If the input's codepoint length is <= max, pass through unchanged.
#   - Otherwise, emit substr(input, 1, max) followed by U+2026 ELLIPSIS
#     (UTF-8 bytes E2 80 A6).
#
# Why not ${var:0:N}: macOS bash 3.2's parameter expansion slices BYTES,
# not codepoints, even under LC_ALL=en_US.UTF-8 — a Korean codepoint can
# be cut mid-byte, producing mojibake.
#
# Why not awk: macOS BSD awk's length() and substr() are byte-based
# regardless of LC_ALL. gawk works but is not installed by default.
# To stay portable and codepoint-safe, we prefer python3 (almost always
# present on modern macOS / Linux), fall back to perl with -CSDA (also
# common), and only as a last resort fall back to byte-based awk
# (acceptable for ASCII-only environments).
nudge_truncate() {
  local max="${1:-0}"
  if [[ -z "${max}" ]] || ! [[ "${max}" =~ ^[0-9]+$ ]] || [[ "${max}" -eq 0 ]]; then
    cat
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    LC_ALL=en_US.UTF-8 python3 -c '
import sys
max_n = int(sys.argv[1])
data = sys.stdin.buffer.read()
try:
    s = data.decode("utf-8")
except UnicodeDecodeError:
    # Fall back to latin1 so we never crash the pipeline; produces best-effort
    # output for non-UTF-8 input.
    s = data.decode("latin-1")
# Strip trailing newline so the truncation decision is on the visible content.
trailing_nl = s.endswith("\n")
if trailing_nl:
    s = s[:-1]
if len(s) > max_n:
    out = s[:max_n] + "…"
else:
    out = s
sys.stdout.write(out)
if trailing_nl:
    sys.stdout.write("\n")
' "${max}"
    return 0
  fi

  if command -v perl >/dev/null 2>&1; then
    LC_ALL=en_US.UTF-8 perl -CSDA -e '
my $max = $ARGV[0];
local $/;
my $s = <STDIN>;
my $trailing_nl = ($s =~ s/\n\z//);
if (length($s) > $max) {
    print substr($s, 0, $max), "\x{2026}";
} else {
    print $s;
}
print "\n" if $trailing_nl;
' -- "${max}"
    return 0
  fi

  # Final fallback: byte-based awk. Acceptable for ASCII-only environments;
  # NOT codepoint-safe for multibyte input. Documented degraded path.
  LC_ALL=en_US.UTF-8 awk -v n="${max}" '
    {
      if (length($0) > n) {
        printf("%s\xE2\x80\xA6\n", substr($0, 1, n))
      } else {
        print $0
      }
    }
  '
}

# Strip control chars (incl. \n,\t,\r), collapse whitespace runs, trim,
# codepoint-truncate to NUDGE_MAX_Q. Argument is the raw question/title string.
normalize_question() {
  local raw="${1:-}"
  if [[ -z "${raw}" ]]; then printf ''; return 0; fi

  # Replace control chars (\x00-\x1f and \x7f) with a single space using tr.
  # Then squeeze runs of whitespace and trim leading/trailing.
  local cleaned
  cleaned="$(printf '%s' "${raw}" | tr '\000-\037\177' ' ' | tr -s ' ')"
  # Trim leading/trailing whitespace.
  cleaned="${cleaned#"${cleaned%%[![:space:]]*}"}"
  cleaned="${cleaned%"${cleaned##*[![:space:]]}"}"

  printf '%s' "${cleaned}" | nudge_truncate "${NUDGE_MAX_Q:-80}"
}

# Codepoint-truncate the assistant answer to NUDGE_MAX_A. Caller has already
# clipped to a single line (see notify-codex.sh).
normalize_answer() {
  local raw="${1:-}"
  if [[ -z "${raw}" ]]; then printf ''; return 0; fi

  # Apply the same control-char strip as normalize_question so embedded
  # newlines/tabs in the assistant answer don't break the one-line banner.
  local cleaned
  cleaned="$(printf '%s' "${raw}" | tr '\000-\037\177' ' ' | tr -s ' ')"
  cleaned="${cleaned#"${cleaned%%[![:space:]]*}"}"
  cleaned="${cleaned%"${cleaned##*[![:space:]]}"}"

  printf '%s' "${cleaned}" | nudge_truncate "${NUDGE_MAX_A:-120}"
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
#   MESSAGE line3 = "Q: {question}"   (omitted if question empty)
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
      message="${line2}"$'\n'"Q: ${q}"
    fi
  fi

  local cmd
  cmd="$(_nudge_notify_path)"
  if [[ -x "${cmd}" ]] || [[ -f "${cmd}" ]]; then
    bash "${cmd}" "${title}" "${message}" "${priority}" 2>/dev/null || true
  fi
  return 0
}
