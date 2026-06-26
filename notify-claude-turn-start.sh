#!/usr/bin/env bash
# nudge — Claude Code UserPromptSubmit hook.
#
# Claude runs this hook when the user submits a prompt. Record the turn-start
# epoch into ~/.nudge/turn-stamps/<key> so notify-claude.sh can suppress
# completion banners for fast turns.
#
# Fail-soft contract: every I/O is best-effort and the hook always exits 0.

set -u

_sha256_helper() {
  local input="$1"
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "${input}" | shasum -a 256 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "${input}" | sha256sum 2>/dev/null | awk '{print $1}'
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import hashlib,sys; sys.stdout.write(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())' <<<"${input}" 2>/dev/null
  else
    printf ''
  fi
}

STDIN_JSON=""
if [[ ! -t 0 ]]; then
  STDIN_JSON="$(cat 2>/dev/null || true)"
fi

_JQ_OK=0
if command -v jq >/dev/null 2>&1; then _JQ_OK=1; fi

_jq_field() {
  if [[ "${_JQ_OK}" -ne 1 ]]; then printf ''; return; fi
  local filter="$1" json="${2:-}"
  [[ -z "${json}" ]] && { printf ''; return; }
  jq -r "${filter} // empty" <<<"${json}" 2>/dev/null || true
}

CWD="$(_jq_field '.cwd' "${STDIN_JSON}")"
SESSION_ID="$(_jq_field '.session_id' "${STDIN_JSON}")"

[[ -z "${CWD}" ]] && CWD="${CLAUDE_PROJECT_DIR:-${PWD}}"

key_input="${CWD}"
if [[ -n "${SESSION_ID}" ]]; then
  key_input="${CWD}"$'\0'"${SESSION_ID}"
fi

key="$(_sha256_helper "${key_input}" 2>/dev/null || true)"
if [[ -z "${key}" ]]; then
  exit 0
fi

stamp_dir="${HOME}/.nudge/turn-stamps"
mkdir -p "${stamp_dir}" 2>/dev/null || true
date +%s 2>/dev/null > "${stamp_dir}/${key}" 2>/dev/null || true

exit 0
