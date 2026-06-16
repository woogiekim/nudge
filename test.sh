#!/usr/bin/env bash
# Sends one test notification to verify the ntfy path works end to end.

set -euo pipefail

NOTIFY="${HOME}/.nudge/notify.sh"

if [[ ! -x "${NOTIFY}" ]]; then
  echo "ERROR: ${NOTIFY} not found or not executable. Run install.sh first." >&2
  exit 1
fi

echo "Sending a test notification via ntfy..."
"${NOTIFY}" "nudge test" "If you see this on your device, the setup works." "high"

echo "Sent. Check your subscribed device or the ntfy web/app."
echo "If nothing arrives, confirm NTFY_TOPIC in ~/.nudge/.env matches"
echo "the topic you subscribed to."
