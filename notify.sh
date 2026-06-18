#!/usr/bin/env bash
# nudge — provider-agnostic notification sender
#
# Every AI tool (Claude Code, Codex CLI, Gemini CLI, ...) calls THIS script
# from its own hook/notify mechanism. The notification logic lives in one
# place, so adding a new tool only means pointing its hook at this file.
#
# Usage:
#   notify.sh "<title>" "<message>" [priority]
#   priority is an ntfy priority: min | low | default | high | urgent
#
# Examples:
#   notify.sh "Claude Code" "Response complete"
#   notify.sh "Codex CLI"   "Waiting for input" high

set -euo pipefail

# Resolve the directory this script lives in, so we can find an adjacent .env
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Capture any values already provided via the environment (these win over .env)
_ENV_TOPIC="${NTFY_TOPIC:-}"
_ENV_SERVER="${NTFY_SERVER:-}"

# Load topic/server from .env if present
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/.env"
fi

# Environment variables take precedence over .env file values
NTFY_TOPIC="${_ENV_TOPIC:-${NTFY_TOPIC:-}}"
NTFY_SERVER="${_ENV_SERVER:-${NTFY_SERVER:-https://ntfy.sh}}"

# Argument defaults. Lifted above the skip branch so the trace-log line
# emitted on empty NTFY_TOPIC can reference TITLE/MESSAGE without depending
# on whether the script reached the curl call.
TITLE="${1:-AI Agent}"      # arg 1: notification title
MESSAGE="${2:-Done}"        # arg 2: notification body
PRIORITY="${3:-default}"    # arg 3: ntfy priority (optional)

# Fail soft: if not configured, warn to stderr but do NOT block the agent.
if [[ -z "${NTFY_TOPIC}" ]]; then
  echo "nudge: NTFY_TOPIC is not set (edit .env or export NTFY_TOPIC). Skipping." >&2

  # Best-effort trace log: record that a notification was dropped so an
  # operator can grep ~/.nudge/notify.log after the fact. Wrapped in
  # `|| true` so a read-only $HOME, a full disk, or any other filesystem
  # error cannot break the calling AI tool's hook contract.
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "${HOME}/.nudge" 2>/dev/null || true
  printf "%s | NTFY_TOPIC empty — notification skipped (TITLE='%s' MSG='%s')\n" \
    "${ts}" "${TITLE}" "${MESSAGE}" >> "${HOME}/.nudge/notify.log" 2>/dev/null || true

  exit 0
fi

# Send the push to ntfy. Never let a network error break the calling tool.
curl -s \
  -H "Title: ${TITLE}" \
  -H "Priority: ${PRIORITY}" \
  -H "Tags: robot" \
  -H "Cache: no" \
  -d "${MESSAGE}" \
  "${NTFY_SERVER}/${NTFY_TOPIC}" > /dev/null 2>&1 || true
