#!/usr/bin/env bash
# Installs the nudge core (notify.sh) plus three per-tool context wrappers
# (notify-claude.sh, notify-codex.sh, notify-gemini.sh) and an internal shared
# helper (_nudge_lib.sh) into ~/.nudge/.
#
# By default, install.sh leaves AI tool config files untouched.
#
# Opt-in wiring flags:
#   --wire-claude  : jq-merge nudge hooks into ~/.claude/settings.json
#   --wire-codex   : set ~/.codex/config.toml `notify` (REFUSES to clobber)
#   --wire-gemini  : jq-merge nudge hooks into ~/.gemini/settings.json
#   --wire-all     : run every available wiring
#
# All wirings are idempotent, take timestamped backups before writing,
# and degrade gracefully (manual snippet) if jq is unavailable.

set -euo pipefail

INSTALL_DIR="${HOME}/.nudge"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- CLI flag parsing -------------------------------------------------------
WIRE_CLAUDE=0
WIRE_CODEX=0
WIRE_GEMINI=0
for arg in "$@"; do
  case "${arg}" in
    --wire-claude) WIRE_CLAUDE=1 ;;
    --wire-codex)  WIRE_CODEX=1 ;;
    --wire-gemini) WIRE_GEMINI=1 ;;
    --wire-all)
      WIRE_CLAUDE=1
      WIRE_CODEX=1
      WIRE_GEMINI=1
      ;;
    -h|--help)
      cat <<USAGE
Usage: install.sh [--wire-claude] [--wire-codex] [--wire-gemini] [--wire-all]

  --wire-claude    Merge nudge hooks into \${HOME}/.claude/settings.json (requires jq).
  --wire-codex     Set 'notify' in \${HOME}/.codex/config.toml (refuses to overwrite
                   a pre-existing non-nudge notify).
  --wire-gemini    Merge nudge hooks into \${HOME}/.gemini/settings.json (requires jq).
                   Skipped if ~/.gemini does not exist.
  --wire-all       Run every available wiring above.

Default invocation only copies the nudge files; AI tool configs are left
untouched.
USAGE
      exit 0
      ;;
    *)
      echo "install.sh: unknown flag: ${arg}" >&2
      echo "Usage: install.sh [--wire-claude] [--wire-codex] [--wire-gemini] [--wire-all]" >&2
      exit 2
      ;;
  esac
done

# --- Claude Code hook wiring (P1 + P2 wrapper rename) -----------------------
# Calls notify-claude.sh (the P2 context wrapper) instead of notify.sh directly.
# All other invariants are unchanged from P1: jq-merge, idempotent, timestamped
# backup, preserve existing hooks (mnemos/agent-crew live alongside nudge), and
# graceful degradation when jq is missing or the file is invalid JSON.
wire_claude_settings() {
  local settings_file="${NUDGE_CLAUDE_SETTINGS:-${HOME}/.claude/settings.json}"
  local wrapper_path="${HOME}/.nudge/notify-claude.sh"
  local stop_cmd="${wrapper_path}"
  local notif_cmd="${wrapper_path}"

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

  # Idempotency probe: does either category already contain a notify-claude.sh
  # or legacy /.nudge/notify.sh command? Either form counts as "already wired".
  local has_stop has_notif
  has_stop="$(jq '[.hooks.Stop[]?.hooks[]?.command // empty] | map(select(test("/\\.nudge/notify(-claude)?\\.sh"))) | length > 0' "${settings_file}")"
  has_notif="$(jq '[.hooks.Notification[]?.hooks[]?.command // empty] | map(select(test("/\\.nudge/notify(-claude)?\\.sh"))) | length > 0' "${settings_file}")"

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

# --- Codex CLI notify wiring (P2) ------------------------------------------
# config.toml `notify` is a SINGLE value (not array-mergeable). If a non-nudge
# `notify` already exists, REFUSE to overwrite — print clobber guidance and
# exit 0. Only set `notify` when absent or already nudge's.
wire_codex_settings() {
  local config_file="${NUDGE_CODEX_CONFIG:-${HOME}/.codex/config.toml}"
  local wrapper_path="${HOME}/.nudge/notify-codex.sh"
  # Codex appends its JSON payload to the command, so a bash -c wrapper that
  # forwards $1 (the payload) gives us a single ARGV[1] in notify-codex.sh.
  local notify_line='notify = ["bash", "-c", "'"${wrapper_path}"' \"$1\"", "--"]'

  # Always print a portable manual command line that the user can paste.
  local manual_snippet="${notify_line}"

  # config.toml absent → create a minimal one with nudge notify.
  if [[ ! -f "${config_file}" ]]; then
    mkdir -p "$(dirname "${config_file}")"
    {
      echo "# Created by nudge install.sh --wire-codex"
      echo "${notify_line}"
    } > "${config_file}"
    echo "==> Created ${config_file} with nudge notify"
    return 0
  fi

  # Detect existing `notify =` (at line start; ignore comments).
  local existing_notify_lines
  existing_notify_lines="$(grep -nE '^[[:space:]]*notify[[:space:]]*=' "${config_file}" 2>/dev/null || true)"

  if [[ -z "${existing_notify_lines}" ]]; then
    # No `notify` key — backup then append.
    local backup_path
    backup_path="${config_file}.bak.$(date +%Y%m%d%H%M%S)"
    cp "${config_file}" "${backup_path}"
    echo "==> Backup written: ${backup_path}"

    # Append at the TOP-level (before any [section] header).
    # Strategy: drop the new line at the end of the file with a leading newline.
    # TOML semantics tolerate trailing top-level keys after sections only if
    # they belong to the last section. Safer: prepend after any leading comment
    # block. We choose: insert just BEFORE the first '[section]' line if any,
    # otherwise append to EOF.
    local tmp_merge
    tmp_merge="$(mktemp "${config_file}.tmp.XXXXXX")"
    if grep -qE '^[[:space:]]*\[' "${config_file}"; then
      awk -v notify="${notify_line}" '
        BEGIN { inserted = 0 }
        {
          if (!inserted && $0 ~ /^[[:space:]]*\[/) {
            print notify
            print ""
            inserted = 1
          }
          print
        }
        END {
          if (!inserted) print notify
        }
      ' "${config_file}" > "${tmp_merge}"
    else
      cp "${config_file}" "${tmp_merge}"
      printf '\n%s\n' "${notify_line}" >> "${tmp_merge}"
    fi
    mv "${tmp_merge}" "${config_file}"
    echo "==> Added nudge 'notify' line to ${config_file}"
    return 0
  fi

  # `notify` exists. Is it already pointing at notify-codex.sh? Then idempotent
  # no-op (do not write, do not back up).
  if echo "${existing_notify_lines}" | grep -F "/.nudge/notify-codex.sh" >/dev/null 2>&1; then
    echo "==> ${config_file} already wired for nudge — no changes made"
    return 0
  fi

  # Existing non-nudge notify → REFUSE to overwrite. Print guidance + exit 0.
  echo "==> ${config_file} already has a non-nudge 'notify' value:"
  echo "    ${existing_notify_lines}"
  echo "    nudge install.sh REFUSES to overwrite a single-value 'notify' key."
  echo "    To wire nudge manually, replace the existing 'notify' line with:"
  echo
  echo "    ${manual_snippet}"
  echo
  echo "    Then keep your existing [tui].notifications entries (no change needed)."
  return 0
}

# --- Gemini CLI hook wiring (P2) -------------------------------------------
# Same pattern as wire_claude_settings (jq-merge, idempotent, timestamped
# backup, preserve existing hooks). If ~/.gemini does not exist, skip with
# a notice — do NOT presumptuously create it.
wire_gemini_settings() {
  local gemini_dir="${NUDGE_GEMINI_DIR:-${HOME}/.gemini}"
  local settings_file="${NUDGE_GEMINI_SETTINGS:-${gemini_dir}/settings.json}"
  local wrapper_path="${HOME}/.nudge/notify-gemini.sh"
  local after_cmd="${wrapper_path}"
  local notif_cmd="${wrapper_path}"

  local manual_snippet_path="${SRC_DIR}/examples/gemini.settings.json"
  local restart_notice="==> Gemini CLI reads settings.json at session start — restart your Gemini session to load the new hooks."

  # Hard skip if Gemini is not installed (dir absent).
  if [[ ! -d "${gemini_dir}" ]]; then
    echo "==> ${gemini_dir} not found — Gemini CLI doesn't appear to be installed, skipping."
    return 0
  fi

  _print_gemini_manual_snippet() {
    local reason="$1"
    echo "==> ${reason}"
    echo "    Manual merge required for: ${settings_file}"
    echo "    --- begin snippet ---"
    if [[ -f "${manual_snippet_path}" ]]; then
      cat "${manual_snippet_path}"
    fi
    echo "    --- end snippet ---"
  }

  # Graceful degradation: jq missing → manual snippet.
  if ! command -v jq >/dev/null 2>&1; then
    _print_gemini_manual_snippet "jq not found on PATH — skipping auto-wiring"
    return 0
  fi

  # Missing settings file: create minimal valid one with both hook entries.
  if [[ ! -f "${settings_file}" ]]; then
    mkdir -p "$(dirname "${settings_file}")"
    local tmp_create
    tmp_create="$(mktemp "${settings_file}.tmp.XXXXXX")"
    trap 'rm -f "${tmp_create}"' RETURN
    jq -n \
      --arg after "${after_cmd}" \
      --arg notif "${notif_cmd}" \
      '{
        hooks: {
          AfterAgent: [
            { matcher: "", hooks: [ { type: "command", command: $after } ] }
          ],
          Notification: [
            { matcher: "", hooks: [ { type: "command", command: $notif } ] }
          ]
        }
      }' > "${tmp_create}"
    mv "${tmp_create}" "${settings_file}"
    trap - RETURN
    echo "==> Created ${settings_file} with nudge AfterAgent + Notification hooks"
    echo "${restart_notice}"
    return 0
  fi

  # Existing file: validate JSON.
  if ! jq -e . "${settings_file}" >/dev/null 2>&1; then
    _print_gemini_manual_snippet "${settings_file} is not valid JSON — skipping auto-wiring"
    return 0
  fi

  # Idempotency probe.
  local has_after has_notif
  has_after="$(jq '[.hooks.AfterAgent[]?.hooks[]?.command // empty] | map(select(test("/\\.nudge/notify-gemini\\.sh"))) | length > 0' "${settings_file}")"
  has_notif="$(jq '[.hooks.Notification[]?.hooks[]?.command // empty] | map(select(test("/\\.nudge/notify-gemini\\.sh"))) | length > 0' "${settings_file}")"

  if [[ "${has_after}" == "true" && "${has_notif}" == "true" ]]; then
    echo "==> ${settings_file} already wired for nudge — no changes made"
    return 0
  fi

  # Backup first, then merge.
  local backup_path
  backup_path="${settings_file}.bak.$(date +%Y%m%d%H%M%S)"
  cp "${settings_file}" "${backup_path}"
  echo "==> Backup written: ${backup_path}"

  local tmp_merge
  tmp_merge="$(mktemp "${settings_file}.tmp.XXXXXX")"
  trap 'rm -f "${tmp_merge}"' RETURN

  jq \
    --arg after "${after_cmd}" \
    --arg notif "${notif_cmd}" \
    --argjson has_after "${has_after}" \
    --argjson has_notif "${has_notif}" \
    '
    .hooks = ((.hooks // {}) | (
      (if $has_after then . else
        .AfterAgent = ((.AfterAgent // []) + [ { matcher: "", hooks: [ { type: "command", command: $after } ] } ])
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

# Copy core + all per-tool wrappers + shared lib.
for src in notify.sh notify-claude.sh notify-codex.sh notify-gemini.sh _nudge_lib.sh; do
  if [[ -f "${SRC_DIR}/${src}" ]]; then
    cp "${SRC_DIR}/${src}" "${INSTALL_DIR}/${src}"
    chmod +x "${INSTALL_DIR}/${src}"
  fi
done

# Create .env only if it does not already exist (never overwrite your config)
if [[ ! -f "${INSTALL_DIR}/.env" ]]; then
  cp "${SRC_DIR}/.env.example" "${INSTALL_DIR}/.env"
  echo "==> Created ${INSTALL_DIR}/.env  (edit it and set NTFY_TOPIC)"
else
  echo "==> ${INSTALL_DIR}/.env already exists — left untouched"
fi

# Opt-in tool wirings.
if [[ "${WIRE_CLAUDE}" -eq 1 ]]; then
  wire_claude_settings
fi
if [[ "${WIRE_CODEX}" -eq 1 ]]; then
  wire_codex_settings
fi
if [[ "${WIRE_GEMINI}" -eq 1 ]]; then
  wire_gemini_settings
fi

cat <<EOF

Next steps:
  1. Edit ${INSTALL_DIR}/.env and set a unique NTFY_TOPIC
  2. Subscribe to that same topic in the ntfy app (iOS / Android / desktop / web)
  3. Test it:
       ${INSTALL_DIR}/notify.sh 'Test' 'It works' high
  4. Wire up each AI tool — either rerun with --wire-claude / --wire-codex /
     --wire-gemini / --wire-all, or merge the matching file in examples/
     into the tool's config manually.
EOF
