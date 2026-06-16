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

# NTFY_ID dedup guard (PRD §F1–F4). The ntfy server holds a 12h message
# cache; every subscriber reconnect replays it, so we suppress duplicate
# banners by id on this Mac. Empty/unset id falls through (F3) so we
# never silently drop an alert. All I/O tolerates failure to preserve
# the launchd `exit 0` invariant (F6).
SEEN="${HOME}/.nudge/seen-ids"
if [[ -n "${NTFY_ID:-}" ]]; then
  if grep -Fxq -- "${NTFY_ID}" "${SEEN}" 2>/dev/null; then
    exit 0
  fi
  printf '%s\n' "${NTFY_ID}" >> "${SEEN}" 2>/dev/null || true
  { tail -n 500 "${SEEN}" > "${SEEN}.tmp" && mv "${SEEN}.tmp" "${SEEN}"; } 2>/dev/null || true
fi

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
