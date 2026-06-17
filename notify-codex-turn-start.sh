#!/usr/bin/env bash
# nudge — Codex CLI UserPromptSubmit hook.
#
# Wired via ~/.codex/hooks.json into the UserPromptSubmit event. Codex runs
# this hook the moment the user submits a prompt; we record the turn-start
# epoch into ~/.nudge/turn-stamps/<key> so notify-codex.sh (post-turn) can
# compute elapsed seconds and decide whether the turn was "fast enough" to
# suppress the banner (see notify-codex.sh NUDGE_MIN_TURN_SEC gate).
#
# Stamp key derivation MUST match notify-codex.sh exactly:
#   sha256("${cwd}\0${CODEX_SESSION_ID:-${CODEX_SESSION:-}}")  when any
#   Codex session env var is present;
#   else sha256("${cwd}")  (single-session collision risk documented in PRD §F2).
#
# Every I/O is wrapped in `|| true`. The hook ALWAYS exits 0 so launchd /
# Codex never flag it as unhealthy.

# Note: NO `set -e` here. The hook is best-effort; any failure must not
# propagate to Codex's prompt-submission path.
set -u

# Compute sha256 with whatever helper is on PATH; degrade silently otherwise.
# Hash priority MUST match notify-codex.sh exactly (shasum → sha256sum →
# python3) so the stamp key derived here is the same one the consumer
# resolves. md5 etc. are deliberately excluded — a key-format mismatch
# would silently break fast-turn suppression.
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

_cwd="${PWD:-$(pwd 2>/dev/null || true)}"
_sess="${CODEX_SESSION_ID:-${CODEX_SESSION:-}}"
if [[ -n "${_sess}" ]]; then
  _key_input="${_cwd}"$'\0'"${_sess}"
else
  _key_input="${_cwd}"
fi

_key="$(_sha256_helper "${_key_input}" 2>/dev/null || true)"

# When the hash helper returned empty (no shasum/sha256sum/python3), there
# is nothing useful to write — exit 0 silently.
if [[ -z "${_key}" ]]; then
  exit 0
fi

mkdir -p "${HOME}/.nudge/turn-stamps" 2>/dev/null || true
date +%s 2>/dev/null > "${HOME}/.nudge/turn-stamps/${_key}" 2>/dev/null || true

exit 0
