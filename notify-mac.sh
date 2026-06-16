#!/usr/bin/env bash
# Invoked by `ntfy subscribe` for each incoming message. ntfy exports the
# message fields as NTFY_* environment variables. This posts a native macOS
# Notification Center alert — NO ntfy GUI app required.
#
# Used by the launchd agent ~/Library/LaunchAgents/sh.ntfy.subscribe.plist
# that install.sh --setup-receiver-macos provisions.
#
# Override env vars (for tests / customization):
#   NUDGE_TN_CMD   default "terminal-notifier"
#   NUDGE_OSA_CMD  default "osascript"
#
# Always exits 0 so launchd does not flag the subscriber unhealthy.

TITLE="${NTFY_TITLE:-ntfy}"
MSG="${NTFY_MESSAGE:-(no message)}"
PRIO="${NTFY_PRIORITY:-3}"

TN_CMD="${NUDGE_TN_CMD:-terminal-notifier}"
OSA_CMD="${NUDGE_OSA_CMD:-osascript}"

# Verification log (lets us confirm the headless pipeline fired even before
# the notification-permission grant is in place).
mkdir -p "${HOME}/.nudge" 2>/dev/null || true
printf '%s | prio=%s | %s | %s\n' "$(date '+%F %T')" "${PRIO}" "${TITLE}" "${MSG}" \
  >> "${HOME}/.nudge/ntfy-mac-notify.log" 2>&1

# Strip double-quotes to keep the strings safe in the osascript fallback.
TITLE_SAFE="${TITLE//\"/}"
MSG_SAFE="${MSG//\"/}"

# Prefer terminal-notifier (own permission entry, richer); fall back to
# built-in osascript when the binary is missing OR exits nonzero.
if command -v "${TN_CMD}" >/dev/null 2>&1; then
  "${TN_CMD}" -title "${TITLE_SAFE}" -message "${MSG_SAFE}" -sound default >/dev/null 2>&1 \
    || "${OSA_CMD}" -e "display notification \"${MSG_SAFE}\" with title \"${TITLE_SAFE}\"" >/dev/null 2>&1 \
    || true
else
  "${OSA_CMD}" -e "display notification \"${MSG_SAFE}\" with title \"${TITLE_SAFE}\"" >/dev/null 2>&1 || true
fi

exit 0
