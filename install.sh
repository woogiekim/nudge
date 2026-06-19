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

# Raw base URL for self-fetch (no-clone curl|bash install). Override to point
# at a fork/branch: NUDGE_RAW_BASE_URL=https://raw.githubusercontent.com/<fork>/nudge/<ref>
NUDGE_RAW_BASE_URL="${NUDGE_RAW_BASE_URL:-https://raw.githubusercontent.com/woogiekim/nudge/main}"

# Receiver-skip signal flag. setup_receiver_macos() flips this to 1 when the
# macOS receiver provisioning is short-circuited because NTFY_TOPIC is empty,
# so the Next-steps block at the tail of install.sh can render an extra
# WARNING. Declared up-front (default 0) so the tail reference stays safe
# under `set -u`.
NUDGE_RECEIVER_SKIPPED=0

# Fetch helper: downloads one URL to one destination using (in order):
#   1. NUDGE_FETCH_CMD (alias NUDGE_CURL_CMD) — test/override hook.
#      Contract: invoked as `"${cmd}" <url> <dest>`; writes non-empty content
#      to <dest> and exits 0 on success; exits non-zero on failure.
#   2. curl -fsSL "${url}" -o "${dest}" — default when curl is on PATH.
#   3. wget -q -O "${dest}" "${url}"   — fallback when curl is absent.
# After the fetcher returns, verifies the destination exists and is non-empty.
# Any failure aborts the install with a clear stderr message.
nudge_fetch_one() {
  local url="$1"
  local dest="$2"
  local fetch_cmd="${NUDGE_FETCH_CMD:-${NUDGE_CURL_CMD:-}}"
  local rc=0

  if [[ -n "${fetch_cmd}" ]]; then
    "${fetch_cmd}" "${url}" "${dest}" || rc=$?
  elif command -v curl >/dev/null 2>&1; then
    curl -fsSL "${url}" -o "${dest}" || rc=$?
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "${dest}" "${url}" || rc=$?
  else
    echo "error: neither curl nor wget available" >&2
    echo "       install one of them and re-run, or set NUDGE_FETCH_CMD to a custom fetcher" >&2
    exit 1
  fi

  if [[ "${rc}" -ne 0 ]] || [[ ! -s "${dest}" ]]; then
    echo "error: failed to fetch ${url} -> ${dest}" >&2
    exit 1
  fi
}

# --- CLI flag parsing -------------------------------------------------------
WIRE_CLAUDE=0
WIRE_CODEX=0
WIRE_GEMINI=0
SETUP_RECEIVER_MACOS=0
OPT_TOPIC=""
while [[ $# -gt 0 ]]; do
  case "${1}" in
    --wire-claude) WIRE_CLAUDE=1 ;;
    --wire-codex)  WIRE_CODEX=1 ;;
    --wire-gemini) WIRE_GEMINI=1 ;;
    --wire-all)
      WIRE_CLAUDE=1
      WIRE_CODEX=1
      WIRE_GEMINI=1
      ;;
    --setup-receiver-macos) SETUP_RECEIVER_MACOS=1 ;;
    --topic)
      # --topic <value>: consume the next argv as the topic. Missing value
      # (end of argv, or next token starts with --) leaves OPT_TOPIC empty
      # and the resolver falls through to the next priority.
      if [[ $# -ge 2 && "${2}" != --* ]]; then
        OPT_TOPIC="${2}"
        shift
      else
        OPT_TOPIC=""
      fi
      ;;
    --topic=*)
      # --topic=<value>: split on the first '='. An empty value falls through.
      OPT_TOPIC="${1#--topic=}"
      ;;
    -h|--help)
      cat <<USAGE
Usage: install.sh [--wire-claude] [--wire-codex] [--wire-gemini] [--wire-all]
                  [--setup-receiver-macos] [--topic <value>]

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
  --topic <value>            Set NTFY_TOPIC during install (highest priority).
                             Without it, the script falls back to: NTFY_TOPIC env
                             var, existing ~/.nudge/.env, /dev/tty prompt (when
                             interactive), and finally a loud warning.

Default invocation only copies the nudge files; AI tool configs are left
untouched.
USAGE
      exit 0
      ;;
    *)
      echo "install.sh: unknown flag: ${1}" >&2
      echo "Usage: install.sh [--wire-claude] [--wire-codex] [--wire-gemini] [--wire-all] [--setup-receiver-macos] [--topic <value>]" >&2
      exit 2
      ;;
  esac
  shift
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
    else
      echo "    (example snippet not available in self-fetch mode — see ${NUDGE_RAW_BASE_URL}/examples/claude-code.settings.json)"
    fi
    echo "    --- end snippet ---"
  }

  # Graceful degradation: jq missing -> print snippet, exit 0, do not edit.
  if ! command -v jq >/dev/null 2>&1; then
    _print_manual_snippet "jq not found on PATH — skipping auto-wiring"
    return 0
  fi

  # Missing file: create a minimal valid settings.json with the Stop hook only.
  # Stop-only contract: a Claude turn fires Stop once and (separately) Notification;
  # wiring the nudge wrapper into both produces a duplicate banner per turn.
  if [[ ! -f "${settings_file}" ]]; then
    mkdir -p "$(dirname "${settings_file}")"
    local tmp_create
    tmp_create="$(mktemp "${settings_file}.tmp.XXXXXX")"
    trap 'rm -f "${tmp_create}"' RETURN
    jq -n \
      --arg stop "${stop_cmd}" \
      '{
        hooks: {
          Stop: [
            { matcher: "", hooks: [ { type: "command", command: $stop } ] }
          ]
        }
      }' > "${tmp_create}"
    mv "${tmp_create}" "${settings_file}"
    trap - RETURN
    echo "==> Created ${settings_file} with nudge Stop hook"
    echo "${restart_notice}"
    return 0
  fi

  # Existing file: validate JSON. Invalid -> manual snippet path (no edit).
  if ! jq -e . "${settings_file}" >/dev/null 2>&1; then
    _print_manual_snippet "${settings_file} is not valid JSON — skipping auto-wiring"
    return 0
  fi

  # Idempotency probe: does .hooks.Stop already contain a notify-claude.sh or
  # legacy /.nudge/notify.sh command? Either form counts as "already wired".
  # Stop-only contract: the probe ignores .hooks.Notification — pre-existing
  # non-nudge Notification entries are preserved verbatim by the merge below.
  local has_stop
  has_stop="$(jq '[.hooks.Stop[]?.hooks[]?.command // empty] | map(select(test("/\\.nudge/notify(-claude)?\\.sh"))) | length > 0' "${settings_file}")"

  if [[ "${has_stop}" == "true" ]]; then
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
    '
    .hooks = ((.hooks // {}) | (
      .Stop = ((.Stop // []) + [ { matcher: "", hooks: [ { type: "command", command: $stop } ] } ])
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
    else
      echo "    (example snippet not available in self-fetch mode — see ${NUDGE_RAW_BASE_URL}/examples/gemini.settings.json)"
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
    # LOUD stderr WARNING — the operator grep marker for this skip path.
    # Keep the original stdout informational echoes too (they help users
    # who eyeball install output), but the authoritative signal lives on
    # stderr alongside other install-time warnings.
    echo "==> setup-receiver-macos: NTFY_TOPIC is not set."
    echo "    Edit ${env_file} and set NTFY_TOPIC to a unique value first,"
    echo "    then re-run: bash install.sh --setup-receiver-macos"
    echo "WARNING: setup-receiver-macos skipped — NTFY_TOPIC is empty in ${env_file}. Edit ${env_file}, set NTFY_TOPIC, then re-run: bash install.sh --setup-receiver-macos" >&2

    NUDGE_RECEIVER_SKIPPED=1
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

  # 6. Load via launchctl: bootout, settle-wait, then bounded bootstrap retry.
  #    Async-teardown race: launchctl bootout returns before the service is
  #    fully unloaded, so a follow-up bootstrap can race and fail with
  #    "Bootstrap failed: 5: Input/output error" or "service already
  #    bootstrapped". Poll print(1) until the service is gone (bounded),
  #    then retry bootstrap (bounded), then emit a non-fatal WARN if the
  #    final state is still not-loaded. RunAtLoad=true on a fresh bootstrap
  #    runs the service, so the old `kickstart -k` is intentionally dropped.
  local launchctl_cmd="${NUDGE_LAUNCHCTL_CMD:-launchctl}"
  local uid
  uid="$(id -u)"
  local gui_target="gui/${uid}"
  local svc="${gui_target}/sh.ntfy.subscribe"

  # F1. bootout + bounded settle-wait. Capture rc explicitly under
  #     set -euo pipefail by using the if/else form. rc=3 (No such
  #     process — nothing was loaded) is treated as already-settled.
  local bootout_rc
  if "${launchctl_cmd}" bootout "${svc}"; then
    bootout_rc=0
  else
    bootout_rc=$?
  fi

  if [[ "${bootout_rc}" -ne 3 ]]; then
    local settle_i=0
    while [[ "${settle_i}" -lt 10 ]]; do
      if ! "${launchctl_cmd}" print "${svc}" >/dev/null 2>&1; then
        break
      fi
      sleep 0.5
      settle_i=$((settle_i + 1))
    done
  fi

  # F2. Bounded bootstrap retry (up to 5 attempts).
  local bootstrap_attempt=0
  local bootstrap_ok=0
  while [[ "${bootstrap_attempt}" -lt 5 ]]; do
    bootstrap_attempt=$((bootstrap_attempt + 1))
    if "${launchctl_cmd}" bootstrap "${gui_target}" "${plist}"; then
      bootstrap_ok=1
      break
    fi
    sleep 0.5
  done

  # Final is-loaded probe — authoritative final state.
  local final_loaded=0
  if "${launchctl_cmd}" print "${svc}" >/dev/null 2>&1; then
    final_loaded=1
  fi

  # F3. Non-fatal WARN when bootstrap never succeeded AND service is not
  #     loaded. The script continues to self-test publish / permission
  #     guidance / duplicate-GUI advisory and exits 0.
  if [[ "${bootstrap_ok}" -eq 0 && "${final_loaded}" -eq 0 ]]; then
    >&2 echo "==> WARN: launchd bootstrap of sh.ntfy.subscribe failed after ${bootstrap_attempt} attempts; run 'launchctl bootstrap gui/${uid} ${plist}' manually"
  fi

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

# Canonical files installed by the core copy loop.
NUDGE_CORE_SCRIPTS=(notify.sh notify-claude.sh notify-codex.sh notify-codex-turn-start.sh notify-gemini.sh notify-mac.sh _nudge_lib.sh test.sh)

# Sibling-presence detection: when running from a local checkout, the canonical
# sibling files sit next to install.sh. Under `curl ... | bash`, BASH_SOURCE[0]
# resolves to the pipe (e.g. /dev/fd/N) so ${SRC_DIR} points somewhere that
# does not contain notify.sh / _nudge_lib.sh — trigger self-fetch instead.
if [[ -f "${SRC_DIR}/notify.sh" && -f "${SRC_DIR}/_nudge_lib.sh" ]]; then
  # Local-checkout path — preserved byte-for-byte (zero behavior change).
  STAGE_DIR="${SRC_DIR}"
else
  # Self-fetch path — download each canonical file into a staging dir, then
  # let the existing for-loop and .env guard read from STAGE_DIR.
  STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nudge-selffetch.XXXXXX")"
  trap 'rm -rf "${STAGE_DIR}"' EXIT
  echo "==> Self-fetch mode: siblings not found next to install.sh — fetching from ${NUDGE_RAW_BASE_URL}"
  for src in "${NUDGE_CORE_SCRIPTS[@]}" .env.example; do
    echo "==> Fetching ${src} from ${NUDGE_RAW_BASE_URL}"
    nudge_fetch_one "${NUDGE_RAW_BASE_URL}/${src}" "${STAGE_DIR}/${src}"
  done
  # chmod +x each fetched script (matches the local-copy +x at install time).
  for src in "${NUDGE_CORE_SCRIPTS[@]}"; do
    chmod +x "${STAGE_DIR}/${src}"
  done
fi

# Copy core + all per-tool wrappers + shared lib + macOS notifier + Codex
# UserPromptSubmit hook.
for src in "${NUDGE_CORE_SCRIPTS[@]}"; do
  if [[ -f "${STAGE_DIR}/${src}" ]]; then
    cp "${STAGE_DIR}/${src}" "${INSTALL_DIR}/${src}"
    chmod +x "${INSTALL_DIR}/${src}"
  fi
done

# --- NTFY_TOPIC resolution (5-tier, first match wins) ----------------------
# Resolves the topic value to write into a freshly created ~/.nudge/.env, in
# priority order:
#   1. --topic <value>            (OPT_TOPIC, trimmed; empty falls through)
#   2. NTFY_TOPIC env var         (trimmed; empty falls through)
#   3. existing ~/.nudge/.env with a non-empty NTFY_TOPIC=...  → SHORT-CIRCUIT
#      (never overwrite a user-edited .env; preserves the "left untouched"
#       contract below)
#   4. /dev/tty interactive prompt, guarded by `exec 3</dev/tty 2>/dev/null`.
#      MUST NOT read from stdin — the curl|bash self-fetch path delivers the
#      script body on stdin and a plain `read` would consume EOF.
#   5. fallback: leave .env's NTFY_TOPIC empty; the existing ff361c5 LOUD
#      WARNING (in setup_receiver_macos + Next-steps tail) fires later if the
#      user also passed --setup-receiver-macos.
#
# Sets two script-scope variables:
#   RESOLVED_TOPIC — trimmed topic string (empty in fallback/existing-env paths)
#   TOPIC_SOURCE   — one of: flag | env | existing-env | tty | fallback
RESOLVED_TOPIC=""
TOPIC_SOURCE=""

nudge_trim() {
  # Strips leading/trailing whitespace AND control characters from $1; echoes
  # the result. Pure-bash implementation so a stripped install-time PATH
  # (e.g. /bin:/sbin:/usr/sbin during test fixtures that exclude /usr/bin
  # to hide jq) cannot break the resolver. Control-char stripping protects
  # the /dev/tty path against BSD `script(1)` pseudoterminals that may
  # prepend an EOT (0x04) byte to the buffered input when their source pipe
  # closes (see notes in `nudge_resolve_topic`).
  local s="${1:-}"
  local out="" c
  local i=0
  while [[ ${i} -lt ${#s} ]]; do
    c="${s:${i}:1}"
    case "${c}" in
      [[:cntrl:]]) : ;;
      *) out="${out}${c}" ;;
    esac
    i=$((i + 1))
  done
  # Trim leading/trailing whitespace using pure parameter expansion.
  out="${out#"${out%%[![:space:]]*}"}"
  out="${out%"${out##*[![:space:]]}"}"
  printf '%s' "${out}"
}

nudge_env_topic_value() {
  # Echoes the current NTFY_TOPIC value stored in $1 (an env file path),
  # stripping wrapping single/double quotes. Empty echo when absent/empty.
  local env_file="$1"
  [[ -f "${env_file}" ]] || return 0
  grep -E '^[[:space:]]*NTFY_TOPIC[[:space:]]*=' "${env_file}" \
    | tail -n 1 \
    | sed -E 's/^[[:space:]]*NTFY_TOPIC[[:space:]]*=[[:space:]]*//' \
    | sed -E 's/^"(.*)"$/\1/' \
    | sed -E "s/^'(.*)'\$/\\1/" \
    || true
}

nudge_resolve_topic() {
  local env_file="${INSTALL_DIR}/.env"
  local val

  # 1. --topic flag.
  val="$(nudge_trim "${OPT_TOPIC:-}")"
  if [[ -n "${val}" ]]; then
    RESOLVED_TOPIC="${val}"
    TOPIC_SOURCE="flag"
    return 0
  fi

  # 2. NTFY_TOPIC env var.
  val="$(nudge_trim "${NTFY_TOPIC:-}")"
  if [[ -n "${val}" ]]; then
    RESOLVED_TOPIC="${val}"
    TOPIC_SOURCE="env"
    return 0
  fi

  # 3. Existing ~/.nudge/.env with a non-empty NTFY_TOPIC=... → short-circuit.
  if [[ -f "${env_file}" ]]; then
    val="$(nudge_env_topic_value "${env_file}")"
    if [[ -n "${val}" ]]; then
      RESOLVED_TOPIC=""
      TOPIC_SOURCE="existing-env"
      return 0
    fi
  fi

  # 4. Guarded /dev/tty prompt. Open ONLY a separate fd 3 — never stdin.
  #    Self-fetch curl|bash puts the script body on stdin, so a plain `read`
  #    would consume EOF and the script would silently fall through here.
  #
  #    Important: write the human-facing prompt to stderr (which IS the
  #    controlling tty when interactive), NOT to fd 3. Some pty layers (BSD
  #    `script` on macOS, certain CI tty multiplexers) loop slave writes back
  #    into the slave read buffer, which would otherwise let `read -r <&3`
  #    consume the prompt text itself as the topic. Reading fd 3 only keeps
  #    the input channel free of our own output.
  #
  #    `stty eof undef <&3`: when install.sh is driven through a fresh BSD
  #    `script(1)` pty whose stdin source (e.g. a printf pipe in the test
  #    harness) closes before the read happens, the pty injects an EOF char
  #    that races ahead of the buffered topic line and makes `read` return
  #    immediately empty. Undefining the EOF char keeps the line-discipline
  #    cooked-mode editing (backspace, Ctrl-W) intact for real users while
  #    letting `read` see the buffered topic line in the pty-race case.
  #    Errors are swallowed because stty is best-effort across BSD/GNU.
  if exec 3</dev/tty 2>/dev/null; then
    local typed=""
    stty eof undef <&3 2>/dev/null || true
    printf '%s' '>>> Enter NTFY_TOPIC (leave blank to skip): ' >&2 || true
    read -r typed <&3 || typed=''
    stty eof '^D' <&3 2>/dev/null || true
    exec 3<&-
    typed="$(nudge_trim "${typed}")"
    if [[ -n "${typed}" ]]; then
      RESOLVED_TOPIC="${typed}"
      TOPIC_SOURCE="tty"
      return 0
    fi
  fi

  # 5. Fallback — empty topic; the LOUD WARNING from ff361c5 (in
  # setup_receiver_macos + Next-steps tail) is unchanged and fires later.
  RESOLVED_TOPIC=""
  TOPIC_SOURCE="fallback"
}

nudge_write_topic_to_env() {
  # Replaces the first NTFY_TOPIC= line in $1 with NTFY_TOPIC=$2 (unquoted).
  # Unquoted form matches the canonical shape consumed by both the
  # `setup_receiver_macos` topic extractor and downstream `grep -E
  # '^NTFY_TOPIC=value$'` assertions; topics in nudge's threat model are long
  # random alphanumeric/dash strings, so quoting is not load-bearing.
  # Preserves file mode (mktemp creates 600 by default, which would otherwise
  # tighten .env's mode below .env.example's).
  local env_file="$1"
  local topic="$2"
  local mode tmp

  mode="$(stat -f '%Lp' "${env_file}" 2>/dev/null || stat -c '%a' "${env_file}" 2>/dev/null || echo '')"
  tmp="$(mktemp "${env_file}.tmp.XXXXXX")"

  awk -v topic="${topic}" '
    BEGIN { done = 0 }
    /^[[:space:]]*NTFY_TOPIC[[:space:]]*=/ {
      if (!done) {
        print "NTFY_TOPIC=" topic
        done = 1
        next
      }
    }
    { print }
  ' "${env_file}" > "${tmp}"

  mv "${tmp}" "${env_file}"
  if [[ -n "${mode}" ]]; then
    chmod "${mode}" "${env_file}" 2>/dev/null || true
  fi
}

nudge_resolve_topic

# Create .env only if it does not already exist (never overwrite your config).
# When the resolver yielded a topic from --topic / env / tty AND .env did not
# previously exist, persist it into the new file. The existing-env path is
# handled by the `else` branch below (file untouched, contract preserved).
if [[ ! -f "${INSTALL_DIR}/.env" ]]; then
  cp "${STAGE_DIR}/.env.example" "${INSTALL_DIR}/.env"
  if [[ -n "${RESOLVED_TOPIC}" ]]; then
    nudge_write_topic_to_env "${INSTALL_DIR}/.env" "${RESOLVED_TOPIC}"
    echo "==> Created ${INSTALL_DIR}/.env  (NTFY_TOPIC set from ${TOPIC_SOURCE})"
  else
    echo "==> Created ${INSTALL_DIR}/.env  (edit it and set NTFY_TOPIC)"
    # Install-time LOUD WARNING when fallback was the only available source.
    # Mirrors the ff361c5 receiver-skipped warning style: a single stderr
    # WARNING line that names the file and the next manual step. The
    # receiver-skipped warning in setup_receiver_macos() (install.sh ~line
    # 555) stays unmodified — this is a separate, install-time signal that
    # fires regardless of --setup-receiver-macos.
    if [[ "${TOPIC_SOURCE}" == "fallback" ]]; then
      echo "WARNING: NTFY_TOPIC is empty in ${INSTALL_DIR}/.env. Edit ${INSTALL_DIR}/.env and set NTFY_TOPIC, or re-run install.sh with --topic <value>." >&2
    fi
  fi
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

# Next-steps step 1 wording adapts to the resolver outcome. When the install
# wrote a topic during this run (flag | env | tty) OR found an existing topic
# (existing-env), step 1 becomes a "✓" acknowledgement; otherwise it keeps
# the original "Edit ... and set NTFY_TOPIC" instruction so the loud-warning
# + fallback paths still nudge the user toward editing .env by hand.
case "${TOPIC_SOURCE}" in
  flag|env|tty)
    NUDGE_NEXT_STEP_1="✓ NTFY_TOPIC already set in ${INSTALL_DIR}/.env (from ${TOPIC_SOURCE})"
    ;;
  existing-env)
    NUDGE_NEXT_STEP_1="✓ NTFY_TOPIC already set in ${INSTALL_DIR}/.env (existing config)"
    ;;
  *)
    NUDGE_NEXT_STEP_1="Edit ${INSTALL_DIR}/.env and set a unique NTFY_TOPIC"
    ;;
esac

cat <<EOF

Next steps:
  1. ${NUDGE_NEXT_STEP_1}
  2. Subscribe to that same topic in the ntfy app (iOS / Android / desktop / web)
  3. Test it:
       ${INSTALL_DIR}/notify.sh 'Test' 'It works' high
  4. Wire up each AI tool — either rerun with --wire-claude / --wire-codex /
     --wire-gemini / --wire-all, or merge the matching file in examples/
     into the tool's config manually.
  5. macOS users: rerun with --setup-receiver-macos to receive notifications
     natively in Notification Center without the ntfy GUI app.
EOF

# Receiver-skipped advisory: when --setup-receiver-macos was requested but
# short-circuited because NTFY_TOPIC was empty, repeat the warning at the
# tail of the install transcript so it is impossible to miss between the
# happy-path Next-steps block and the shell prompt.
if [[ "${NUDGE_RECEIVER_SKIPPED}" -eq 1 ]]; then
  cat <<WARN_EOF

WARNING: macOS receiver was NOT provisioned because NTFY_TOPIC is empty.
  Edit ${INSTALL_DIR}/.env, set NTFY_TOPIC to a unique value, and re-run:
      bash install.sh --setup-receiver-macos
WARN_EOF
fi
