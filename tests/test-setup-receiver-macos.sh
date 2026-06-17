#!/usr/bin/env bash
# Spec: prd.md § F3 + F4 — install.sh --setup-receiver-macos contract.
#
# Five scenarios derived from the PRD's Gherkin acceptance criteria + handoff
# test contract:
#   (a) Non-Darwin guard → zero side effects, no plist
#   (b) Missing NTFY_TOPIC → exit 0, no plist, guidance mentions NTFY_TOPIC + .env
#   (c) Happy-path plist generation with correct topic + ntfy path + notifier path
#   (d) Idempotent re-run + timestamped backup of existing plist
#   (e) (covered by tests/test-notify-mac.sh — separate file)
#
# Stub strategy:
#   - PATH-prepended stub binaries (uname, brew, ntfy, launchctl, open,
#     terminal-notifier).
#   - Each stub records its argv to ${shim_dir}/<cmd>.calls so each scenario
#     can grep invocation history.
#   - Override env vars (NUDGE_BREW_CMD, NUDGE_LAUNCHCTL_CMD, NUDGE_OPEN_CMD,
#     NUDGE_TN_CMD, NUDGE_NTFY_CMD, NUDGE_PUBLISH_CMD, NUDGE_LAUNCHAGENTS_DIR)
#     point at the stubs so the production-default branches still resolve
#     correctly even when PATH is bypassed.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"

FAILED=0
SCENARIOS_RUN=0

FIXTURE_DIRS=()
cleanup() {
  local d
  for d in "${FIXTURE_DIRS[@]:-}"; do
    if [[ -n "${d:-}" && -d "${d}" ]]; then
      rm -rf "${d}"
    fi
  done
  return 0
}
trap cleanup EXIT

make_fixture_home() {
  local home_dir
  home_dir="$(mktemp -d -t nudge-setup-receiver-XXXXXX)"
  FIXTURE_DIRS+=("${home_dir}")
  mkdir -p "${home_dir}/.nudge" \
           "${home_dir}/Library/LaunchAgents" \
           "${home_dir}/Library/Logs"
  printf '%s' "${home_dir}"
}

# make_stub_bin <home_dir> <uname-emits>
#   Creates a stub bin dir with recording shims for every side-effect cmd.
#   `uname -s` returns <uname-emits>.
#   Other commands (brew, ntfy, launchctl, open, terminal-notifier) exit 0
#   and record argv to <home>/_shims/<name>.calls.
make_stub_bin() {
  local home_dir="$1"
  local uname_emits="$2"

  local stub_dir="${home_dir}/_stubbin"
  mkdir -p "${stub_dir}"
  local shim_log="${home_dir}/_shims"
  mkdir -p "${shim_log}"

  # uname stub — only `-s` matters.
  cat > "${stub_dir}/uname" <<UNAME_EOF
#!/usr/bin/env bash
printf '%s\n' "$@" > "${shim_log}/uname.calls"
echo "${uname_emits}"
exit 0
UNAME_EOF

  # generic recorder factory
  for cmd in brew ntfy launchctl open terminal-notifier; do
    cat > "${stub_dir}/${cmd}" <<RECORDER_EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "${shim_log}/${cmd}.calls"
exit 0
RECORDER_EOF
  done

  chmod +x "${stub_dir}/"*
  printf '%s' "${stub_dir}"
}

pass() {
  echo "  PASS: $*"
}

fail() {
  echo "  FAIL: $*" >&2
  FAILED=1
}

assert_file_missing() {
  local f="$1" msg="$2"
  if [[ -e "${f}" ]]; then
    fail "${msg} — file present: ${f}"
  else
    pass "${msg}"
  fi
}

assert_file_exists() {
  local f="$1" msg="$2"
  if [[ -e "${f}" ]]; then
    pass "${msg}"
  else
    fail "${msg} — file missing: ${f}"
  fi
}

assert_file_contains() {
  local f="$1" needle="$2" msg="$3"
  if [[ -f "${f}" ]] && grep -F -- "${needle}" "${f}" >/dev/null 2>&1; then
    pass "${msg}"
  else
    fail "${msg} — needle '${needle}' not found in ${f}"
  fi
}

assert_file_lacks() {
  local f="$1" needle="$2" msg="$3"
  if [[ -f "${f}" ]] && grep -F -- "${needle}" "${f}" >/dev/null 2>&1; then
    fail "${msg} — needle '${needle}' unexpectedly present in ${f}"
  else
    pass "${msg}"
  fi
}

# ---------------------------------------------------------------------------
# Scenario (a) — Non-Darwin guard is a clean no-op
# ---------------------------------------------------------------------------
scenario_a_non_darwin_guard() {
  echo "=== Scenario (a): non-Darwin guard ==="
  SCENARIOS_RUN=$((SCENARIOS_RUN+1))

  local home_dir
  home_dir="$(make_fixture_home)"
  local stub_dir
  stub_dir="$(make_stub_bin "${home_dir}" "Linux")"

  # NTFY_TOPIC set just to prove the guard short-circuits before topic logic.
  printf 'NTFY_TOPIC="should-never-be-read"\n' > "${home_dir}/.nudge/.env"

  local output
  set +e
  output="$(HOME="${home_dir}" \
    PATH="${stub_dir}:${PATH}" \
    NUDGE_LAUNCHAGENTS_DIR="${home_dir}/Library/LaunchAgents" \
    NUDGE_BREW_CMD="${stub_dir}/brew" \
    NUDGE_NTFY_CMD="${stub_dir}/ntfy" \
    NUDGE_LAUNCHCTL_CMD="${stub_dir}/launchctl" \
    NUDGE_OPEN_CMD="${stub_dir}/open" \
    NUDGE_TN_CMD="${stub_dir}/terminal-notifier" \
    NUDGE_PUBLISH_CMD="${stub_dir}/ntfy publish" \
    bash "${INSTALL_SH}" --setup-receiver-macos 2>&1)"
  local rc=$?
  set -e

  if [[ "${rc}" -ne 0 ]]; then
    fail "(a) install.sh exited ${rc}, expected 0"
  else
    pass "(a) install.sh exited 0"
  fi

  if echo "${output}" | grep -F "macOS only" >/dev/null 2>&1; then
    pass "(a) output mentions 'macOS only'"
  else
    fail "(a) output missing 'macOS only' guard message"
  fi

  assert_file_missing "${home_dir}/Library/LaunchAgents/sh.ntfy.subscribe.plist" \
    "(a) no plist written"

  # Side-effect counters must all be 0 (uname is allowed to be called).
  for cmd in brew launchctl open terminal-notifier; do
    local calls_file="${home_dir}/_shims/${cmd}.calls"
    if [[ -f "${calls_file}" ]] && [[ -s "${calls_file}" ]]; then
      fail "(a) ${cmd} stub was invoked unexpectedly:"
      cat "${calls_file}" >&2
    else
      pass "(a) ${cmd} stub was not invoked"
    fi
  done
}

# ---------------------------------------------------------------------------
# Scenario (b) — Missing NTFY_TOPIC blocks gracefully
# ---------------------------------------------------------------------------
scenario_b_missing_topic() {
  echo "=== Scenario (b): missing NTFY_TOPIC ==="
  SCENARIOS_RUN=$((SCENARIOS_RUN+1))

  local home_dir
  home_dir="$(make_fixture_home)"
  local stub_dir
  stub_dir="$(make_stub_bin "${home_dir}" "Darwin")"

  printf 'NTFY_TOPIC=""\n' > "${home_dir}/.nudge/.env"

  local output
  set +e
  output="$(HOME="${home_dir}" \
    PATH="${stub_dir}:${PATH}" \
    NUDGE_LAUNCHAGENTS_DIR="${home_dir}/Library/LaunchAgents" \
    NUDGE_BREW_CMD="${stub_dir}/brew" \
    NUDGE_NTFY_CMD="${stub_dir}/ntfy" \
    NUDGE_LAUNCHCTL_CMD="${stub_dir}/launchctl" \
    NUDGE_OPEN_CMD="${stub_dir}/open" \
    NUDGE_TN_CMD="${stub_dir}/terminal-notifier" \
    bash "${INSTALL_SH}" --setup-receiver-macos 2>&1)"
  local rc=$?
  set -e

  if [[ "${rc}" -ne 0 ]]; then
    fail "(b) install.sh exited ${rc}, expected 0"
  else
    pass "(b) install.sh exited 0"
  fi

  assert_file_missing "${home_dir}/Library/LaunchAgents/sh.ntfy.subscribe.plist" \
    "(b) no plist written"

  if echo "${output}" | grep -E 'NTFY_TOPIC' >/dev/null 2>&1; then
    pass "(b) output mentions NTFY_TOPIC"
  else
    fail "(b) output missing NTFY_TOPIC reference"
  fi

  if echo "${output}" | grep -E '\.env' >/dev/null 2>&1; then
    pass "(b) output mentions .env"
  else
    fail "(b) output missing .env reference"
  fi
}

# ---------------------------------------------------------------------------
# Scenario (c) — Happy-path plist generation
# ---------------------------------------------------------------------------
scenario_c_happy_path() {
  echo "=== Scenario (c): happy-path plist generation ==="
  SCENARIOS_RUN=$((SCENARIOS_RUN+1))

  local home_dir
  home_dir="$(make_fixture_home)"
  local stub_dir
  stub_dir="$(make_stub_bin "${home_dir}" "Darwin")"

  printf 'NTFY_TOPIC="fixture-topic-abc"\n' > "${home_dir}/.nudge/.env"

  local lad="${home_dir}/Library/LaunchAgents"

  local output
  set +e
  output="$(HOME="${home_dir}" \
    PATH="${stub_dir}:${PATH}" \
    NUDGE_LAUNCHAGENTS_DIR="${lad}" \
    NUDGE_BREW_CMD="${stub_dir}/brew" \
    NUDGE_NTFY_CMD="${stub_dir}/ntfy" \
    NUDGE_LAUNCHCTL_CMD="${stub_dir}/launchctl" \
    NUDGE_OPEN_CMD="${stub_dir}/open" \
    NUDGE_TN_CMD="${stub_dir}/terminal-notifier" \
    bash "${INSTALL_SH}" --setup-receiver-macos 2>&1)"
  local rc=$?
  set -e

  if [[ "${rc}" -ne 0 ]]; then
    fail "(c) install.sh exited ${rc}, expected 0 — output: ${output}"
    return
  fi
  pass "(c) install.sh exited 0"

  local plist="${lad}/sh.ntfy.subscribe.plist"
  assert_file_exists "${plist}" "(c) plist created at ${plist}"

  assert_file_contains "${plist}" "<string>fixture-topic-abc</string>" \
    "(c) plist contains the topic"

  assert_file_contains "${plist}" "${stub_dir}/ntfy" \
    "(c) plist references the resolved ntfy abs path"

  assert_file_contains "${plist}" "${home_dir}/.nudge/notify-mac.sh" \
    "(c) plist references the notify-mac.sh path"

  assert_file_contains "${plist}" "<string>sh.ntfy.subscribe</string>" \
    "(c) plist Label is sh.ntfy.subscribe"

  assert_file_contains "${plist}" "<key>RunAtLoad</key>" \
    "(c) plist contains RunAtLoad key"

  assert_file_contains "${plist}" "<key>KeepAlive</key>" \
    "(c) plist contains KeepAlive key"

  assert_file_contains "${plist}" "<key>EnvironmentVariables</key>" \
    "(c) plist contains EnvironmentVariables key"

  assert_file_contains "${plist}" "/opt/homebrew/bin" \
    "(c) plist PATH includes /opt/homebrew/bin"

  if [[ -s "${home_dir}/_shims/launchctl.calls" ]]; then
    pass "(c) launchctl stub was invoked"
  else
    fail "(c) launchctl stub was NOT invoked"
  fi

  if grep -F "bootstrap" "${home_dir}/_shims/launchctl.calls" >/dev/null 2>&1; then
    pass "(c) launchctl received bootstrap subcommand"
  else
    fail "(c) launchctl bootstrap subcommand not captured"
  fi
}

# ---------------------------------------------------------------------------
# Scenario (d) — Idempotent re-run + timestamped backup
# ---------------------------------------------------------------------------
scenario_d_idempotent_rerun() {
  echo "=== Scenario (d): idempotent re-run + timestamped backup ==="
  SCENARIOS_RUN=$((SCENARIOS_RUN+1))

  local home_dir
  home_dir="$(make_fixture_home)"
  local stub_dir
  stub_dir="$(make_stub_bin "${home_dir}" "Darwin")"

  printf 'NTFY_TOPIC="fixture-topic-abc"\n' > "${home_dir}/.nudge/.env"

  local lad="${home_dir}/Library/LaunchAgents"
  local plist="${lad}/sh.ntfy.subscribe.plist"

  # Pre-write a stale plist with OLD-TOPIC-XYZ as the marker.
  cat > "${plist}" <<STALE_EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>Label</key><string>sh.ntfy.subscribe</string>
  <key>ProgramArguments</key>
  <array>
    <string>/opt/homebrew/bin/ntfy</string>
    <string>subscribe</string>
    <string>OLD-TOPIC-XYZ</string>
    <string>/tmp/old-notify.sh</string>
  </array>
</dict>
</plist>
STALE_EOF

  # First run
  set +e
  HOME="${home_dir}" \
    PATH="${stub_dir}:${PATH}" \
    NUDGE_LAUNCHAGENTS_DIR="${lad}" \
    NUDGE_BREW_CMD="${stub_dir}/brew" \
    NUDGE_NTFY_CMD="${stub_dir}/ntfy" \
    NUDGE_LAUNCHCTL_CMD="${stub_dir}/launchctl" \
    NUDGE_OPEN_CMD="${stub_dir}/open" \
    NUDGE_TN_CMD="${stub_dir}/terminal-notifier" \
    bash "${INSTALL_SH}" --setup-receiver-macos >/dev/null 2>&1
  local rc=$?
  set -e
  if [[ "${rc}" -ne 0 ]]; then
    fail "(d) first run exited ${rc}, expected 0"
    return
  fi

  # Backups present?
  local first_backup_count
  first_backup_count="$(ls "${lad}"/sh.ntfy.subscribe.plist.bak.* 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${first_backup_count}" -ge 1 ]]; then
    pass "(d) first run produced ${first_backup_count} timestamped backup"
  else
    fail "(d) first run did NOT produce a timestamped backup"
  fi

  # Backup must contain the OLD-TOPIC-XYZ.
  local backup_file
  backup_file="$(ls "${lad}"/sh.ntfy.subscribe.plist.bak.* 2>/dev/null | head -n 1)"
  if [[ -n "${backup_file}" ]] && grep -F "OLD-TOPIC-XYZ" "${backup_file}" >/dev/null 2>&1; then
    pass "(d) backup file preserves OLD-TOPIC-XYZ"
  else
    fail "(d) backup file missing OLD-TOPIC-XYZ"
  fi

  # Live plist no longer contains OLD-TOPIC-XYZ and contains the new topic.
  assert_file_lacks "${plist}" "OLD-TOPIC-XYZ" "(d) live plist clears OLD-TOPIC-XYZ"
  assert_file_contains "${plist}" "fixture-topic-abc" "(d) live plist contains new topic"

  # Sleep 1s and re-run → SECOND backup expected (timestamped at the second
  # boundary). Live plist must remain canonical (no duplicated XML blocks).
  sleep 1
  set +e
  HOME="${home_dir}" \
    PATH="${stub_dir}:${PATH}" \
    NUDGE_LAUNCHAGENTS_DIR="${lad}" \
    NUDGE_BREW_CMD="${stub_dir}/brew" \
    NUDGE_NTFY_CMD="${stub_dir}/ntfy" \
    NUDGE_LAUNCHCTL_CMD="${stub_dir}/launchctl" \
    NUDGE_OPEN_CMD="${stub_dir}/open" \
    NUDGE_TN_CMD="${stub_dir}/terminal-notifier" \
    bash "${INSTALL_SH}" --setup-receiver-macos >/dev/null 2>&1
  rc=$?
  set -e
  if [[ "${rc}" -ne 0 ]]; then
    fail "(d) second run exited ${rc}, expected 0"
    return
  fi

  local total_backup_count
  total_backup_count="$(ls "${lad}"/sh.ntfy.subscribe.plist.bak.* 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${total_backup_count}" -ge 2 ]]; then
    pass "(d) re-run added a second backup (count: ${total_backup_count})"
  else
    fail "(d) re-run did NOT produce a second backup (count: ${total_backup_count})"
  fi

  # Canonical content check: exactly one <?xml ... ?> declaration in live plist.
  local xml_decls
  xml_decls="$(grep -c '<?xml' "${plist}" || true)"
  if [[ "${xml_decls}" -eq 1 ]]; then
    pass "(d) live plist has exactly one <?xml?> declaration (no duplicated block)"
  else
    fail "(d) live plist has ${xml_decls} <?xml?> declarations (expected 1)"
  fi
}

# ---------------------------------------------------------------------------
# Scenario (f) — install.sh --setup-receiver-macos publishes self-test with
#                --no-cache flag to the ntfy CLI.
#
# Spec: prd.md § F2 + Test contract T1 + T3
# (Disable ntfy server-side cache for nudge publishes)
#
# Derived purely from PRD:
#   Given the existing stub harness (PATH-prepended ntfy recorder),
#   When install.sh --setup-receiver-macos runs to completion (rc == 0),
#   Then ${home}/_shims/ntfy.calls contains a line whose argv includes the
#        literal token `--no-cache`, the topic, and the self-test message
#        `nudge receiver installed`.
#   T3 negative: `--no-cache` appears exactly once, and no other unrecognized
#                ntfy publish CLI flags appear beyond topic + message.
#
# Expected to FAIL on the unmodified install.sh (red phase).
# ---------------------------------------------------------------------------
scenario_f_self_test_no_cache_flag() {
  echo "=== Scenario (f): self-test publish uses --no-cache ==="
  SCENARIOS_RUN=$((SCENARIOS_RUN+1))

  local home_dir
  home_dir="$(make_fixture_home)"
  local stub_dir
  stub_dir="$(make_stub_bin "${home_dir}" "Darwin")"

  printf 'NTFY_TOPIC="fixture-topic-abc"\n' > "${home_dir}/.nudge/.env"

  local lad="${home_dir}/Library/LaunchAgents"
  local ntfy_calls="${home_dir}/_shims/ntfy.calls"

  set +e
  HOME="${home_dir}" \
    PATH="${stub_dir}:${PATH}" \
    NUDGE_LAUNCHAGENTS_DIR="${lad}" \
    NUDGE_BREW_CMD="${stub_dir}/brew" \
    NUDGE_NTFY_CMD="${stub_dir}/ntfy" \
    NUDGE_LAUNCHCTL_CMD="${stub_dir}/launchctl" \
    NUDGE_OPEN_CMD="${stub_dir}/open" \
    NUDGE_TN_CMD="${stub_dir}/terminal-notifier" \
    NUDGE_PUBLISH_CMD="${stub_dir}/ntfy publish" \
    bash "${INSTALL_SH}" --setup-receiver-macos >/dev/null 2>&1
  local rc=$?
  set -e

  if [[ "${rc}" -ne 0 ]]; then
    fail "(f) install.sh exited ${rc}, expected 0"
    return
  fi
  pass "(f) install.sh exited 0"

  if [[ ! -f "${ntfy_calls}" ]]; then
    fail "(f) ntfy.calls file missing — publish stub was not invoked"
    return
  fi

  # The publish call records each argv token on its own line. The expected
  # tokens for the cache-aware publish are:
  #   publish
  #   --no-cache
  #   fixture-topic-abc
  #   nudge receiver installed
  if grep -F -x -- "--no-cache" "${ntfy_calls}" >/dev/null 2>&1; then
    pass "(f) ntfy.calls contains --no-cache"
  else
    fail "(f) ntfy.calls does NOT contain --no-cache"
    echo "    --- ntfy.calls ---" >&2
    cat "${ntfy_calls}" >&2
    echo "    ------------------" >&2
  fi

  if grep -F -x -- "fixture-topic-abc" "${ntfy_calls}" >/dev/null 2>&1; then
    pass "(f) ntfy.calls still contains the topic 'fixture-topic-abc'"
  else
    fail "(f) ntfy.calls missing topic 'fixture-topic-abc' (positional preserved?)"
  fi

  if grep -F -x -- "nudge receiver installed" "${ntfy_calls}" >/dev/null 2>&1; then
    pass "(f) ntfy.calls still contains the self-test message"
  else
    fail "(f) ntfy.calls missing self-test message 'nudge receiver installed'"
  fi

  # T3 negative bound: `--no-cache` occurs exactly once.
  local nc_count
  nc_count="$(grep -c -F -x -- "--no-cache" "${ntfy_calls}" || true)"
  if [[ "${nc_count}" -eq 1 ]]; then
    pass "(f/T3) --no-cache token appears exactly once (count=${nc_count})"
  else
    fail "(f/T3) --no-cache token appears ${nc_count} times, expected exactly 1"
  fi

  # T3 negative bound: no other unrecognized ntfy publish flags. The only
  # `--`-prefixed token that may appear is `--no-cache`. Any other long flag
  # smuggled in by the implementer (e.g. `--quiet`, `--priority`, `--tag`)
  # would violate "additive cache-disable only".
  local other_flags
  other_flags="$(awk '/^--/ && $0 != "--no-cache" { print }' "${ntfy_calls}" || true)"
  if [[ -z "${other_flags}" ]]; then
    pass "(f/T3) no unrecognized '--*' flags beyond --no-cache"
  else
    fail "(f/T3) unexpected extra '--*' flags present:"
    echo "${other_flags}" >&2
  fi
}

main() {
  scenario_a_non_darwin_guard
  scenario_b_missing_topic
  scenario_c_happy_path
  scenario_d_idempotent_rerun
  scenario_f_self_test_no_cache_flag

  echo
  echo "Scenarios run: ${SCENARIOS_RUN}"
  if [[ "${FAILED}" -ne 0 ]]; then
    echo "SOME TESTS FAILED" >&2
    exit 1
  fi
  echo "ALL TESTS PASSED"
}

main "$@"
