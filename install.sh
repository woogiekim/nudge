#!/usr/bin/env bash
# Installs the core nudge script. Intentionally conservative:
# it does NOT edit your AI tools' config files (to avoid clobbering existing
# settings). Per-tool wiring is done manually using the snippets in examples/.

set -euo pipefail

INSTALL_DIR="${HOME}/.nudge"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- CLI flag parsing -------------------------------------------------------
WIRE_CLAUDE=0
for arg in "$@"; do
  case "${arg}" in
    --wire-claude)
      WIRE_CLAUDE=1
      ;;
    -h|--help)
      cat <<USAGE
Usage: install.sh [--wire-claude]

  --wire-claude    Opt in to automatic merge of nudge hooks into
                   \${HOME}/.claude/settings.json (requires jq).

Default invocation copies notify.sh + .env only; AI tool configs are
left untouched.
USAGE
      exit 0
      ;;
    *)
      echo "install.sh: unknown flag: ${arg}" >&2
      echo "Usage: install.sh [--wire-claude]" >&2
      exit 2
      ;;
  esac
done

# --- Claude Code hook wiring (P1) ------------------------------------------
# Isolated as its own function so a future P2 per-tool adapter registry can
# dispatch to it without rewriting the call sites.
wire_claude_settings() {
  local settings_file="${NUDGE_CLAUDE_SETTINGS:-${HOME}/.claude/settings.json}"
  local notify_path="${HOME}/.nudge/notify.sh"
  local stop_cmd="${notify_path} 'Claude Code' 'Response complete' default"
  local notif_cmd="${notify_path} 'Claude Code' 'Waiting for your input' high"

  local manual_snippet_path="${SRC_DIR}/examples/claude-code.settings.json"
  local restart_notice="==> Claude Code reads settings.json at session start — restart your Claude Code session to load the new hooks."

  _print_manual_snippet() {
    local reason="$1"
    echo "==> ${reason}"
    echo "    Manual merge required for: ${settings_file}"
    echo "    Install jq to enable auto-wiring (brew install jq / apt-get install jq)."
    echo "    --- begin snippet ---"
    if [[ -f "${manual_snippet_path}" ]]; then
      cat "${manual_snippet_path}"
    fi
    echo "    --- end snippet ---"
  }

  # Graceful degradation: jq missing -> print snippet, exit 0, do not edit.
  if ! command -v jq >/dev/null 2>&1; then
    _print_manual_snippet "jq not found on PATH — skipping auto-wiring"
    return 0
  fi

  # Missing file: create a minimal valid settings.json with both hook entries.
  if [[ ! -f "${settings_file}" ]]; then
    mkdir -p "$(dirname "${settings_file}")"
    local tmp_create
    tmp_create="$(mktemp "${settings_file}.tmp.XXXXXX")"
    trap 'rm -f "${tmp_create}"' RETURN
    jq -n \
      --arg stop "${stop_cmd}" \
      --arg notif "${notif_cmd}" \
      '{
        hooks: {
          Stop: [
            { matcher: "", hooks: [ { type: "command", command: $stop } ] }
          ],
          Notification: [
            { matcher: "", hooks: [ { type: "command", command: $notif } ] }
          ]
        }
      }' > "${tmp_create}"
    mv "${tmp_create}" "${settings_file}"
    trap - RETURN
    echo "==> Created ${settings_file} with nudge Stop + Notification hooks"
    echo "${restart_notice}"
    return 0
  fi

  # Existing file: validate JSON. Invalid -> manual snippet path (no edit).
  if ! jq -e . "${settings_file}" >/dev/null 2>&1; then
    _print_manual_snippet "${settings_file} is not valid JSON — skipping auto-wiring"
    return 0
  fi

  # Idempotency probe: does either category already contain a nudge command?
  local has_stop has_notif
  has_stop="$(jq '[.hooks.Stop[]?.hooks[]?.command // empty] | map(select(test("/\\.nudge/notify\\.sh"))) | length > 0' "${settings_file}")"
  has_notif="$(jq '[.hooks.Notification[]?.hooks[]?.command // empty] | map(select(test("/\\.nudge/notify\\.sh"))) | length > 0' "${settings_file}")"

  if [[ "${has_stop}" == "true" && "${has_notif}" == "true" ]]; then
    echo "==> ${settings_file} already wired for nudge — no changes made"
    return 0
  fi

  # Backup first, then atomic merge.
  local backup_path
  backup_path="${settings_file}.bak.$(date +%Y%m%d%H%M%S)"
  cp "${settings_file}" "${backup_path}"
  echo "==> Backup written: ${backup_path}"

  local tmp_merge
  tmp_merge="$(mktemp "${settings_file}.tmp.XXXXXX")"
  trap 'rm -f "${tmp_merge}"' RETURN

  jq \
    --arg stop "${stop_cmd}" \
    --arg notif "${notif_cmd}" \
    --argjson has_stop "${has_stop}" \
    --argjson has_notif "${has_notif}" \
    '
    .hooks = ((.hooks // {}) | (
      (if $has_stop then . else
        .Stop = ((.Stop // []) + [ { matcher: "", hooks: [ { type: "command", command: $stop } ] } ])
      end)
      |
      (if $has_notif then . else
        .Notification = ((.Notification // []) + [ { matcher: "", hooks: [ { type: "command", command: $notif } ] } ])
      end)
    ))
    ' "${settings_file}" > "${tmp_merge}"

  mv "${tmp_merge}" "${settings_file}"
  trap - RETURN

  echo "==> Merged nudge hooks into ${settings_file}"
  echo "${restart_notice}"
}

# --- Core install (default, conservative) ----------------------------------
echo "==> Installing nudge to ${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}"
cp "${SRC_DIR}/notify.sh" "${INSTALL_DIR}/notify.sh"
chmod +x "${INSTALL_DIR}/notify.sh"

# Create .env only if it does not already exist (never overwrite your config)
if [[ ! -f "${INSTALL_DIR}/.env" ]]; then
  cp "${SRC_DIR}/.env.example" "${INSTALL_DIR}/.env"
  echo "==> Created ${INSTALL_DIR}/.env  (edit it and set NTFY_TOPIC)"
else
  echo "==> ${INSTALL_DIR}/.env already exists — left untouched"
fi

# Opt-in Claude Code hook wiring (runs only with --wire-claude).
if [[ "${WIRE_CLAUDE}" -eq 1 ]]; then
  wire_claude_settings
fi

cat <<EOF

Next steps:
  1. Edit ${INSTALL_DIR}/.env and set a unique NTFY_TOPIC
  2. Subscribe to that same topic in the ntfy app (iOS / Android / desktop / web)
  3. Test it:
       ${INSTALL_DIR}/notify.sh 'Test' 'It works' high
  4. Wire up each AI tool by merging the matching file in examples/
     into that tool's config. These are NOT auto-applied, so your existing
     settings stay intact.
EOF
