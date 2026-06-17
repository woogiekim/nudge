#!/usr/bin/env bash
# Test stub for notify.sh — captures the args the wrapper invoked us with
# instead of actually sending a push. Wrappers honor NUDGE_NOTIFY_CMD so a
# test can point it at this stub.
#
# Captures each call as a fresh log line:
#   <title>\t<message>\t<priority>\t<ntfy_id>
# into the file at $NUDGE_NOTIFY_STUB_LOG (required).
#
# The 4th column (<ntfy_id>) carries the value of the NTFY_ID env var as the
# stub saw it at invocation time, or empty when unset. This lets tests assert
# that notify-codex.sh's NTFY_ID is stable across truncation. Older callers
# that only inspect columns 1..3 are unaffected.
#
# Multi-line MESSAGE lines are joined with a literal "\n" (two chars) so a
# single log line stays one record. Tests un-escape if they need to assert
# line-by-line.

set -u

if [[ -z "${NUDGE_NOTIFY_STUB_LOG:-}" ]]; then
  echo "notify-stub: NUDGE_NOTIFY_STUB_LOG not set" >&2
  exit 2
fi

TITLE="${1:-}"
MESSAGE="${2:-}"
PRIORITY="${3:-default}"

# Escape embedded newlines/tabs so the record stays on one line.
escaped_message="${MESSAGE//$'\t'/\\t}"
escaped_message="${escaped_message//$'\n'/\\n}"
escaped_title="${TITLE//$'\t'/\\t}"
escaped_title="${escaped_title//$'\n'/\\n}"

NTFY_ID_CAPTURED="${NTFY_ID:-}"
escaped_ntfy_id="${NTFY_ID_CAPTURED//$'\t'/\\t}"
escaped_ntfy_id="${escaped_ntfy_id//$'\n'/\\n}"

printf '%s\t%s\t%s\t%s\n' "${escaped_title}" "${escaped_message}" "${PRIORITY}" "${escaped_ntfy_id}" \
  >> "${NUDGE_NOTIFY_STUB_LOG}"
