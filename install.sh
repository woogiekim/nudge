#!/usr/bin/env bash
# Installs the nudge core (notify.sh) plus three per-tool context wrappers
# (notify-claude.sh, notify-codex.sh, notify-gemini.sh) and an internal shared
# helper (_nudge_lib.sh) into ~/.nudge/.
#
# By default, install.sh leaves AI tool config files untouched.
#
# Opt-in wiring flags:
#   --wire-claude            : jq-merge nudge hooks into ~/.claude/settings.json
#   --wire-codex             : set ~/.codex/config.toml `notify` (REFUSES to clobber)
#   --wire-gemini            : jq-merge nudge hooks into ~/.gemini/settings.json
#   --wire-all               : run every available wiring
#   --setup-receiver-macos   : provision the macOS headless ntfy receiver
#                              (launchd subscriber + terminal-notifier)
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
SETUP_RECEIVER_MACOS=0
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
    --setup-receiver-macos) SETUP_RECEIVER_MACOS=1 ;;
    -h|--help)
      cat <<USAGE
Usage: install.sh [--wire-claude] [--wire-codex] [--wire-gemini] [--wire-all]
                  [--setup-receiver-macos]

  --wire-claude              Merge nudge hooks into \${HOME}/.claude/settings.json (requires jq).
  --wire-codex               Set 'notify' in \${HOME}/.codex/config.toml (refuses to overwrite
                             a pre-existing non-nudge notify).
  --wire-gemini              Merge nudge hooks into \${HOME}/.gemini/settings.json (requires jq).
                             Skipped if ~/.gemini does not exist.
  --wire-all                 Run every available wiring above.
  --setup-receiver-macos     macOS only. Provision a headless ntfy receiver
                             (brew installs ntfy + terminal-notifier, writes a
                             launchd subscriber plist, publishes a self-test).
                             Requires NTFY_TOPIC set in ~/.nudge/.env.

Default invocation only copies the nudge files; AI tool configs are left
untouched.
USAGE
      exit 0
      ;;
    *)
      echo "install.sh: unknown flag: ${arg}" >&2
      echo "Usage: install.sh [--wire-claude] [--wire-codex] [--wire-gemini] [--wire-all] [--setup-receiver-macos]" >&2
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
  #
  # Detached wiring: Codex runs `notify` fire-and-forget and tears down the
  # process tree right after the turn (esp. `codex exec`), killing a still-running
  # synchronous curl. We wrap the wrapper in a backgrounded subshell + nohup so
  # the network call survives teardown. No setsid — macOS doesn't ship it.
  local notify_line='notify = ["bash", "-c", "( nohup '"${wrapper_path}"' \"$1\" >/dev/null 2>&1 & )", "--"]'

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

# --- Codex hooks.json UserPromptSubmit wiring (fast-turn suppression) ------
# Mirrors wire_claude_settings: jq-merge, idempotent, timestamped backup,
# graceful jq-absent degradation. Leaves the config.toml `notify` wiring
# above intact.
wire_codex_hooks() {
  local hooks_file="${NUDGE_CODEX_HOOKS:-${HOME}/.codex/hooks.json}"
  local hook_path="${HOME}/.nudge/notify-codex-turn-start.sh"

  # Graceful degradation: jq missing → print snippet, exit 0, do not edit.
  if ! command -v jq >/dev/null 2>&1; then
    echo "==> jq not found on PATH — skipping Codex hooks.json auto-wiring."
    echo "    Manual merge required for: ${hooks_file}"
    echo "    --- begin snippet ---"
    cat <<MANUAL_EOF
{
  "hooks": {
    "UserPromptSubmit": [
      { "matcher": "*", "hooks": [
          { "type": "command", "command": "${hook_path}" }
      ] }
    ]
  }
}
MANUAL_EOF
    echo "    --- end snippet ---"
    return 0
  fi

  # Missing file: create from a minimal jq template.
  if [[ ! -f "${hooks_file}" ]]; then
    mkdir -p "$(dirname "${hooks_file}")"
    local tmp_create
    tmp_create="$(mktemp "${hooks_file}.tmp.XXXXXX")"
    jq -n \
      --arg cmd "${hook_path}" \
      '{
        hooks: {
          UserPromptSubmit: [
            { matcher: "*", hooks: [ { type: "command", command: $cmd } ] }
          ]
        }
      }' > "${tmp_create}"
    mv "${tmp_create}" "${hooks_file}"
    echo "==> Created ${hooks_file} with nudge UserPromptSubmit hook"
    return 0
  fi

  # Existing file: validate JSON. Invalid → back up and recreate.
  if ! jq -e . "${hooks_file}" >/dev/null 2>&1; then
    local backup_path
    backup_path="${hooks_file}.bak.$(date +%Y%m%d%H%M%S)"
    cp "${hooks_file}" "${backup_path}" 2>/dev/null || true
    echo "==> ${hooks_file} is not valid JSON — backed up to ${backup_path} and recreating."
    local tmp_recreate
    tmp_recreate="$(mktemp "${hooks_file}.tmp.XXXXXX")"
    jq -n \
      --arg cmd "${hook_path}" \
      '{
        hooks: {
          UserPromptSubmit: [
            { matcher: "*", hooks: [ { type: "command", command: $cmd } ] }
          ]
        }
      }' > "${tmp_recreate}"
    mv "${tmp_recreate}" "${hooks_file}"
    return 0
  fi

  # Idempotency probe: any UserPromptSubmit hook already targeting
  # notify-codex-turn-start.sh? Then no-op (do not write, do not back up).
  local has_hook
  has_hook="$(jq '[.hooks.UserPromptSubmit[]?.hooks[]?.command // empty] | map(select(test("/notify-codex-turn-start\\.sh"))) | length > 0' "${hooks_file}")"

  if [[ "${has_hook}" == "true" ]]; then
    echo "==> ${hooks_file} already wired for nudge UserPromptSubmit — no changes made"
    return 0
  fi

  # Backup first, then merge.
  local backup_path
  backup_path="${hooks_file}.bak.$(date +%Y%m%d%H%M%S)"
  cp "${hooks_file}" "${backup_path}"
  echo "==> Backup written: ${backup_path}"

  local tmp_merge
  tmp_merge="$(mktemp "${hooks_file}.tmp.XXXXXX")"

  jq \
    --arg cmd "${hook_path}" \
    '.hooks = ((.hooks // {}) | (
        .UserPromptSubmit = ((.UserPromptSubmit // []) + [
          { matcher: "*", hooks: [ { type: "command", command: $cmd } ] }
        ])
      ))
    ' "${hooks_file}" > "${tmp_merge}"

  mv "${tmp_merge}" "${hooks_file}"
  echo "==> Merged nudge UserPromptSubmit hook into ${hooks_file}"
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

# --- macOS headless receiver setup (opt-in) --------------------------------
# Provisions a launchd-managed `ntfy subscribe` worker that hands incoming
# messages to ~/.nudge/notify-mac.sh, which posts to Notification Center via
# terminal-notifier (osascript fallback). NO ntfy GUI app required.
#
# All side-effecting commands resolve through override env vars so the test
# suite can stub every external invocation:
#   NUDGE_BREW_CMD          default "brew"
#   NUDGE_LAUNCHCTL_CMD     default "launchctl"
#   NUDGE_OPEN_CMD          default "open"
#   NUDGE_TN_CMD            default "terminal-notifier"
#   NUDGE_NTFY_CMD          default "ntfy"
#   NUDGE_PUBLISH_CMD       default "${NUDGE_NTFY_CMD} publish"
#   NUDGE_LAUNCHAGENTS_DIR  default "${HOME}/Library/LaunchAgents"
setup_receiver_macos() {
  # 1. Platform guard — first statement, zero side effects on non-Darwin.
  local platform
  platform="$(uname -s 2>/dev/null || echo unknown)"
  if [[ "${platform}" != "Darwin" ]]; then
    echo "==> setup-receiver-macos: macOS only — skipping (current platform: ${platform})"
    return 0
  fi

  # 2. Precondition: NTFY_TOPIC must be set in ~/.nudge/.env (non-empty).
  local env_file="${INSTALL_DIR}/.env"
  local topic=""
  if [[ -f "${env_file}" ]]; then
    # Extract NTFY_TOPIC without sourcing arbitrary code into our shell.
    topic="$(grep -E '^[[:space:]]*NTFY_TOPIC[[:space:]]*=' "${env_file}" \
      | tail -n 1 \
      | sed -E 's/^[[:space:]]*NTFY_TOPIC[[:space:]]*=[[:space:]]*//' \
      | sed -E 's/^"(.*)"$/\1/' \
      | sed -E "s/^'(.*)'\$/\\1/" \
      || true)"
  fi

  if [[ -z "${topic}" ]]; then
    echo "==> setup-receiver-macos: NTFY_TOPIC is not set."
    echo "    Edit ${env_file} and set NTFY_TOPIC to a unique value first,"
    echo "    then re-run: bash install.sh --setup-receiver-macos"
    return 0
  fi

  # 3. Deps: brew install ntfy + terminal-notifier (idempotent). If brew is
  # absent, continue only when ntfy is already on PATH.
  local brew_cmd="${NUDGE_BREW_CMD:-brew}"
  local ntfy_cmd="${NUDGE_NTFY_CMD:-ntfy}"
  if command -v "${brew_cmd}" >/dev/null 2>&1; then
    echo "==> Installing ntfy + terminal-notifier via ${brew_cmd} (idempotent)"
    "${brew_cmd}" install ntfy terminal-notifier || true
  else
    echo "==> ${brew_cmd} not found on PATH."
    if command -v "${ntfy_cmd}" >/dev/null 2>&1; then
      echo "    ntfy is already on PATH — continuing without brew."
    else
      echo "    Install Homebrew (https://brew.sh) and re-run, or install ntfy manually."
      return 0
    fi
  fi

  # 4. Notifier presence check — installed by the core copy loop above.
  local notifier="${INSTALL_DIR}/notify-mac.sh"
  if [[ ! -x "${notifier}" ]]; then
    echo "==> setup-receiver-macos: ${notifier} is missing or not executable."
    echo "    Re-run 'bash install.sh' to refresh ${INSTALL_DIR}, then re-try."
    return 0
  fi

  # 5. LaunchAgent plist generation (timestamped backup + clean overwrite).
  local launchagents_dir="${NUDGE_LAUNCHAGENTS_DIR:-${HOME}/Library/LaunchAgents}"
  mkdir -p "${launchagents_dir}"
  local plist="${launchagents_dir}/sh.ntfy.subscribe.plist"

  local ntfy_bin
  ntfy_bin="$(command -v "${ntfy_cmd}" 2>/dev/null || true)"
  if [[ -z "${ntfy_bin}" ]]; then
    ntfy_bin="/opt/homebrew/bin/ntfy"
  fi

  if [[ -f "${plist}" ]]; then
    local backup_path
    backup_path="${plist}.bak.$(date +%Y%m%d%H%M%S)"
    cp "${plist}" "${backup_path}"
    echo "==> Backup written: ${backup_path}"
  fi

  mkdir -p "${HOME}/Library/Logs"

  cat > "${plist}" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>sh.ntfy.subscribe</string>

    <key>ProgramArguments</key>
    <array>
        <string>${ntfy_bin}</string>
        <string>subscribe</string>
        <string>${topic}</string>
        <string>${notifier}</string>
    </array>

    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>

    <key>StandardOutPath</key>
    <string>${HOME}/Library/Logs/ntfy-subscribe.log</string>
    <key>StandardErrorPath</key>
    <string>${HOME}/Library/Logs/ntfy-subscribe.err</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
</dict>
</plist>
PLIST_EOF
  echo "==> Wrote launchd plist: ${plist}"

  # 6. Load via launchctl (bootout-then-bootstrap pattern; kickstart -k).
  local launchctl_cmd="${NUDGE_LAUNCHCTL_CMD:-launchctl}"
  local uid
  uid="$(id -u)"
  local gui_target="gui/${uid}"
  "${launchctl_cmd}" bootout  "${gui_target}/sh.ntfy.subscribe" 2>/dev/null || true
  "${launchctl_cmd}" bootstrap "${gui_target}" "${plist}"        2>/dev/null || true
  "${launchctl_cmd}" kickstart -k "${gui_target}/sh.ntfy.subscribe" 2>/dev/null || true

  # 7. Permission guidance.
  local tn_cmd="${NUDGE_TN_CMD:-terminal-notifier}"
  local open_cmd="${NUDGE_OPEN_CMD:-open}"
  "${tn_cmd}" -title nudge -message "nudge receiver setup — grant notification permission" >/dev/null 2>&1 || true
  "${open_cmd}" "x-apple.systempreferences:com.apple.Notifications-Settings.extension" >/dev/null 2>&1 || true

  cat <<PERM_EOF
==> One-time permission step (System Settings → Notifications):
    1. Allow 'terminal-notifier' and set its alert style to 'Alerts'.
    2. Disable Focus / Do Not Disturb if you want notifications during quiet hours.
    The Notifications pane was opened for you (best-effort).
PERM_EOF

  # 8. Self-test publish + duplicate-GUI advisory.
  local publish_cmd="${NUDGE_PUBLISH_CMD:-${ntfy_cmd} publish}"
  echo "==> Publishing self-test message to topic '${topic}'"
  # shellcheck disable=SC2086
  ${publish_cmd} --no-cache "${topic}" "nudge receiver installed" >/dev/null 2>&1 || true
  echo "    Check Notification Center for the banner in a few seconds."

  cat <<DUP_EOF
==> Advisory: if the ntfy GUI/desktop app is running, QUIT it to avoid
    duplicate notifications. (nudge does NOT auto-quit it.)
DUP_EOF
}

# --- Core install (default, conservative) ----------------------------------
echo "==> Installing nudge to ${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}"

# Copy core + all per-tool wrappers + shared lib + macOS notifier + Codex
# UserPromptSubmit hook.
for src in notify.sh notify-claude.sh notify-codex.sh notify-codex-turn-start.sh notify-gemini.sh notify-mac.sh _nudge_lib.sh; do
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
  wire_codex_hooks
fi
if [[ "${WIRE_GEMINI}" -eq 1 ]]; then
  wire_gemini_settings
fi
if [[ "${SETUP_RECEIVER_MACOS}" -eq 1 ]]; then
  setup_receiver_macos
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
  5. macOS users: rerun with --setup-receiver-macos to receive notifications
     natively in Notification Center without the ntfy GUI app.
EOF
