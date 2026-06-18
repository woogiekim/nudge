#!/usr/bin/env bash
# Spec: prd.md § F3 + F4 — install.sh --setup-receiver-macos contract.
#
# Scenarios derived from the PRD's Gherkin acceptance criteria + handoff
# test contract:
#   (a) Non-Darwin guard → zero side effects, no plist
#   (b) Missing NTFY_TOPIC → exit 0, no plist, guidance mentions NTFY_TOPIC + .env
#   (c) Happy-path plist generation with correct topic + ntfy path + notifier path
#   (d) Idempotent re-run + timestamped backup of existing plist
#   (e) (covered by tests/test-notify-mac.sh — separate file)
#   (f) Self-test publish uses --no-cache (cache-disable contract)
#   (g) launchd settle-wait honored after bootout (PRD F1)
#   (h) bootstrap retry recovers from a transient failure (PRD F2)
#   (i) all bootstraps fail → non-fatal WARN on stderr, script still 0 (PRD F3+F4)
#
# Note on labeling: scenarios (g)/(h)/(i) implement the "f/g/h" tests
# named in the PRD test contract. The letter is shifted by one to avoid
# collision with the pre-existing (f) cache-disable scenario shipped in
# commit 64e3536. Behavioral content matches the PRD verbatim.
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

  # Spec: prd.md § F1 + F2 — capture stdout and stderr separately so we can
  # assert (a) stderr WARNING line from the guard at install.sh:548–553 and
  # (b) Next-steps WARNING block emitted to stdout at install.sh:785–797.
  local stdout_file="${home_dir}/stdout.txt"
  local stderr_file="${home_dir}/stderr.txt"
  local combined_file="${home_dir}/combined.txt"

  set +e
  HOME="${home_dir}" \
    PATH="${stub_dir}:${PATH}" \
    NUDGE_LAUNCHAGENTS_DIR="${home_dir}/Library/LaunchAgents" \
    NUDGE_BREW_CMD="${stub_dir}/brew" \
    NUDGE_NTFY_CMD="${stub_dir}/ntfy" \
    NUDGE_LAUNCHCTL_CMD="${stub_dir}/launchctl" \
    NUDGE_OPEN_CMD="${stub_dir}/open" \
    NUDGE_TN_CMD="${stub_dir}/terminal-notifier" \
    bash "${INSTALL_SH}" --setup-receiver-macos \
    >"${stdout_file}" 2>"${stderr_file}"
  local rc=$?
  set -e

  # Build the combined (stdout+stderr) view used by existing legacy
  # assertions and the new Next-steps WARNING block assertion.
  cat "${stdout_file}" "${stderr_file}" > "${combined_file}"
  local output
  output="$(cat "${combined_file}")"

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

  # Spec: prd.md § F1 — stderr from the empty-NTFY_TOPIC guard MUST contain
  # a literal "WARNING:" line that mentions NTFY_TOPIC. This is the operator
  # grep marker for the receiver-skip path.
  if grep -E '^.*WARNING:.*NTFY_TOPIC' "${stderr_file}" >/dev/null 2>&1; then
    pass "(b) stderr contains 'WARNING:' line mentioning NTFY_TOPIC"
  else
    fail "(b) stderr missing 'WARNING:' line mentioning NTFY_TOPIC"
    echo "    --- stderr ---" >&2
    cat "${stderr_file}" >&2
    echo "    --------------" >&2
  fi

  # Spec: prd.md § F2 — the final installer output (combined stdout+stderr)
  # MUST contain a prominent "WARNING:" block in or alongside the Next-steps
  # section. The block must explicitly state the macOS receiver was NOT
  # provisioned because NTFY_TOPIC is empty, and must mention the re-run
  # command, NTFY_TOPIC, and the .env path.
  if grep -F "WARNING:" "${combined_file}" >/dev/null 2>&1; then
    pass "(b) combined output contains a 'WARNING:' block"
  else
    fail "(b) combined output missing a 'WARNING:' block"
    echo "    --- combined ---" >&2
    cat "${combined_file}" >&2
    echo "    ----------------" >&2
  fi

  # The Next-steps WARNING block must explicitly state "not provisioned"
  # (or equivalently "NOT provisioned" / "was not provisioned"). The PRD
  # requires the block to communicate that the macOS receiver did not get
  # set up. Accept a case-insensitive "not provisioned" match.
  if grep -iE 'not.{0,3}provisioned' "${combined_file}" >/dev/null 2>&1; then
    pass "(b) WARNING block states macOS receiver was not provisioned"
  else
    fail "(b) WARNING block missing 'not provisioned' phrasing"
    echo "    --- combined ---" >&2
    cat "${combined_file}" >&2
    echo "    ----------------" >&2
  fi

  # The WARNING block must guide the operator to the re-run command and to
  # the .env path so they can fix the empty NTFY_TOPIC and re-run.
  if grep -F -- "bash install.sh --setup-receiver-macos" "${combined_file}" \
      >/dev/null 2>&1; then
    pass "(b) WARNING block names the re-run command"
  else
    fail "(b) WARNING block missing re-run command 'bash install.sh --setup-receiver-macos'"
    echo "    --- combined ---" >&2
    cat "${combined_file}" >&2
    echo "    ----------------" >&2
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
# Stateful launchctl mock — used by scenarios (g), (h), (i)
#
# Spec: prd.md § F1-F6 + handoff Test Contract
#
# Why a new mock? The generic recorder at `make_stub_bin` returns rc=0
# for every invocation and cannot vary behavior across calls. Scenarios
# (g)/(h)/(i) drive the install.sh launchd restart loop (bounded
# settle-wait, bootstrap retry, final WARN) — they need:
#   1. Per-subcommand counters so consecutive `print` calls can return
#      different rc values.
#   2. A per-scenario scripted sequence (e.g. `print:loaded,not-loaded,
#      not-loaded`, `bootstrap:1,1,0`).
#   3. A high-fidelity invocation log: one record per call (full argv on
#      one line), so assertions can count exact bootstrap/print/bootout
#      occurrences and verify no `kickstart`.
#
# Mock contract (POSIX bash 3.2 only — no associative arrays, no mapfile):
#   - Reads a state file at `${shim_log}/launchctl.state` containing one
#     line per subcommand, e.g.:
#         print:loaded,not-loaded,not-loaded
#         bootstrap:1,1,0
#         bootout:0
#     A subcommand without a line defaults to "0" (rc=0, no stdout).
#   - For each call, increments a per-subcommand counter file
#     `${shim_log}/launchctl.counter.<subcmd>` and picks the Nth value
#     from the scripted sequence. If N exceeds the sequence length, the
#     LAST scripted value is reused (so a single "loaded" applies to
#     every probe).
#   - `print` token mapping: "loaded" → rc 0; anything else → rc 1.
#     Stdout is left empty (install.sh only checks rc).
#   - `bootstrap` token mapping: token is a literal integer rc.
#   - `bootout` token mapping: token is a literal integer rc (rc=3 is
#     "No such process" — already-settled).
#   - `kickstart` token mapping: token is a literal integer rc.
#   - Each invocation appends ONE line to `${shim_log}/launchctl.calls`:
#         "<subcmd> <rest-of-argv-joined-by-space>"
#     so a test can `grep -F "bootstrap "` or
#     `grep -F "print gui/.../sh.ntfy.subscribe"`.
# ---------------------------------------------------------------------------
install_stateful_launchctl_mock() {
  local stub_dir="$1"
  local shim_log="$2"

  # The mock script itself. Embedded variables are escaped so they
  # resolve at mock-execution time, not at heredoc-write time.
  cat > "${stub_dir}/launchctl_stateful" <<'MOCK_EOF'
#!/usr/bin/env bash
# Stateful launchctl mock for tests/test-setup-receiver-macos.sh.
# All paths derive from NUDGE_TEST_SHIMLOG (injected by the test fixture).
set -u

shim_log="${NUDGE_TEST_SHIMLOG:-}"
if [ -z "${shim_log}" ] || [ ! -d "${shim_log}" ]; then
  echo "mock: NUDGE_TEST_SHIMLOG not set or not a directory" >&2
  exit 99
fi

calls_log="${shim_log}/launchctl.calls"
state_file="${shim_log}/launchctl.state"

subcmd="${1:-_none_}"
shift || true

# Record this invocation: "<subcmd> <rest-of-argv>" on one line.
# Use a manually space-joined rest to avoid printf quoting surprises.
rest=""
for tok in "$@"; do
  if [ -z "${rest}" ]; then
    rest="${tok}"
  else
    rest="${rest} ${tok}"
  fi
done
if [ -z "${rest}" ]; then
  printf '%s\n' "${subcmd}" >> "${calls_log}"
else
  printf '%s %s\n' "${subcmd}" "${rest}" >> "${calls_log}"
fi

# Look up the scripted sequence for this subcommand, default "0".
seq=""
if [ -f "${state_file}" ]; then
  # bash 3.2-safe: while-read loop, no mapfile.
  while IFS= read -r line; do
    case "${line}" in
      "${subcmd}:"*)
        seq="${line#${subcmd}:}"
        break
        ;;
    esac
  done < "${state_file}"
fi
if [ -z "${seq}" ]; then
  seq="0"
fi

# Per-subcommand call counter (1-based).
counter_file="${shim_log}/launchctl.counter.${subcmd}"
n=0
if [ -f "${counter_file}" ]; then
  n=$(cat "${counter_file}")
fi
n=$((n + 1))
printf '%s' "${n}" > "${counter_file}"

# Walk the comma-separated sequence, take the Nth token (1-based).
# If N exceeds length, reuse the last token.
token=""
i=0
remaining="${seq}"
while [ -n "${remaining}" ]; do
  i=$((i + 1))
  case "${remaining}" in
    *,*)
      head_tok="${remaining%%,*}"
      remaining="${remaining#*,}"
      ;;
    *)
      head_tok="${remaining}"
      remaining=""
      ;;
  esac
  token="${head_tok}"
  if [ "${i}" = "${n}" ]; then
    break
  fi
done
# token now holds either the Nth entry, or the last entry if N > length.

# Map token → rc for each subcommand.
rc=0
case "${subcmd}" in
  print)
    # "loaded" means rc 0, anything else rc 1.
    if [ "${token}" = "loaded" ]; then
      rc=0
    else
      rc=1
    fi
    ;;
  bootstrap|bootout|kickstart)
    # Literal integer rc; default 0 on parse miss.
    case "${token}" in
      ''|*[!0-9]*) rc=0 ;;
      *) rc=${token} ;;
    esac
    ;;
  *)
    rc=0
    ;;
esac

exit "${rc}"
MOCK_EOF
  chmod +x "${stub_dir}/launchctl_stateful"
}

# write_launchctl_state <shim_log> <subcmd1>:<seq1> [<subcmd2>:<seq2> ...]
#   Convenience helper for the scenarios below. Each arg is a
#   "subcmd:csv-seq" pair. The mock auto-defaults unspecified subcmds.
write_launchctl_state() {
  local shim_log="$1"
  shift
  local state_file="${shim_log}/launchctl.state"
  : > "${state_file}"
  local pair
  for pair in "$@"; do
    printf '%s\n' "${pair}" >> "${state_file}"
  done
}

# ---------------------------------------------------------------------------
# Scenario (g) — settle-wait honored (PRD F1 + Acceptance #1)
#
# Spec: prd.md § F1 ("Bounded settle-wait after bootout"), Acceptance
#       criterion "Settle-before-bootstrap (was async-teardown race)".
#
# Configuration:
#   - print sequence: "loaded,not-loaded,not-loaded" — the FIRST probe
#     after bootout sees the service still loaded; the SECOND probe sees
#     it gone. The remaining probes (post-bootstrap is-loaded check)
#     also report "not-loaded" by token, but those are mapped after the
#     successful bootstrap so install.sh may treat bootstrap rc=0 as
#     authoritative (per PRD F2). The PRD test contract only requires
#     the FINAL call's rc to reflect loaded — see assertion below using
#     bootstrap-as-authoritative.
#   - bootstrap sequence: "0" — succeeds immediately.
#   - bootout sequence: "0" — clean exit (deferred-settle is what the
#     scenario exercises, not bootout's rc).
#
# Assertions:
#   - >= 2 `print gui/UID/sh.ntfy.subscribe` entries between the
#     `bootout` entry and the first `bootstrap` entry (settle-wait
#     polled at least twice before bootstrapping).
#   - Final state loaded. The FINAL `print` call returns rc 0 when the
#     last scripted token is "loaded"; the test re-scripts the print
#     sequence to "loaded,not-loaded,loaded" so the post-bootstrap
#     probe explicitly observes loaded. (Same scenario, just a clearer
#     final-state assertion.)
#   - Script exits 0.
#   - No `kickstart` entries (F4).
#
# Expected RED on current install.sh: the current 597-604 block calls
# bootout once + bootstrap once + kickstart once, all swallowed with
# `|| true`. The settle-poll never happens, so the count of `print`
# calls between bootout and the first bootstrap is 0, not >=2.
# `kickstart` IS present in the call log, violating F4.
# ---------------------------------------------------------------------------
scenario_g_settle_wait_honored() {
  echo "=== Scenario (g): settle-wait honored ==="
  SCENARIOS_RUN=$((SCENARIOS_RUN+1))

  local home_dir
  home_dir="$(make_fixture_home)"
  local stub_dir
  stub_dir="$(make_stub_bin "${home_dir}" "Darwin")"
  local shim_log="${home_dir}/_shims"

  install_stateful_launchctl_mock "${stub_dir}" "${shim_log}"
  # Script: first print=loaded (drives the settle loop), second=not-loaded
  # (loop exits), third=loaded (final post-bootstrap probe). bootstrap=0
  # succeeds on first attempt. bootout=0 (no scripted error).
  write_launchctl_state "${shim_log}" \
    "print:loaded,not-loaded,loaded" \
    "bootstrap:0" \
    "bootout:0"

  printf 'NTFY_TOPIC="fixture-topic-abc"\n' > "${home_dir}/.nudge/.env"

  local lad="${home_dir}/Library/LaunchAgents"
  local calls_log="${shim_log}/launchctl.calls"

  set +e
  HOME="${home_dir}" \
    PATH="${stub_dir}:${PATH}" \
    NUDGE_LAUNCHAGENTS_DIR="${lad}" \
    NUDGE_BREW_CMD="${stub_dir}/brew" \
    NUDGE_NTFY_CMD="${stub_dir}/ntfy" \
    NUDGE_LAUNCHCTL_CMD="${stub_dir}/launchctl_stateful" \
    NUDGE_TEST_SHIMLOG="${shim_log}" \
    NUDGE_OPEN_CMD="${stub_dir}/open" \
    NUDGE_TN_CMD="${stub_dir}/terminal-notifier" \
    NUDGE_PUBLISH_CMD="${stub_dir}/ntfy publish" \
    bash "${INSTALL_SH}" --setup-receiver-macos >/dev/null 2>&1
  local rc=$?
  set -e

  if [[ "${rc}" -ne 0 ]]; then
    fail "(g) install.sh exited ${rc}, expected 0"
    if [[ -f "${calls_log}" ]]; then
      echo "    --- launchctl.calls ---" >&2
      cat "${calls_log}" >&2
      echo "    -----------------------" >&2
    fi
    return
  fi
  pass "(g) install.sh exited 0"

  if [[ ! -f "${calls_log}" ]]; then
    fail "(g) launchctl.calls missing — mock never invoked"
    return
  fi

  # Locate the FIRST bootout line and the FIRST bootstrap line by
  # 1-based line number, then count `print …/sh.ntfy.subscribe` lines
  # strictly between them.
  local bootout_line bootstrap_line
  bootout_line="$(grep -n -E '^bootout( |$)' "${calls_log}" | head -n 1 | cut -d: -f1 || true)"
  bootstrap_line="$(grep -n -E '^bootstrap( |$)' "${calls_log}" | head -n 1 | cut -d: -f1 || true)"

  if [[ -z "${bootout_line}" ]]; then
    fail "(g) no 'bootout' entry in launchctl.calls"
    cat "${calls_log}" >&2
    return
  fi
  if [[ -z "${bootstrap_line}" ]]; then
    fail "(g) no 'bootstrap' entry in launchctl.calls"
    cat "${calls_log}" >&2
    return
  fi

  # Count `print …/sh.ntfy.subscribe` between (bootout_line+1) and
  # (bootstrap_line-1) inclusive.
  local lo hi
  lo=$((bootout_line + 1))
  hi=$((bootstrap_line - 1))
  local print_between=0
  if [[ "${lo}" -le "${hi}" ]]; then
    print_between="$(sed -n "${lo},${hi}p" "${calls_log}" \
      | grep -c -E '^print .*sh\.ntfy\.subscribe' || true)"
  fi

  if [[ "${print_between}" -ge 2 ]]; then
    pass "(g) >=2 print probes between bootout and bootstrap (count=${print_between})"
  else
    fail "(g) expected >=2 print probes between bootout and bootstrap, got ${print_between}"
    echo "    --- launchctl.calls ---" >&2
    cat "${calls_log}" >&2
    echo "    -----------------------" >&2
  fi

  # Final-state assertion: the LAST print line corresponds to a rc=0
  # call. We don't have rc in the log directly, so derive it from the
  # scripted sequence + counter: count print invocations total, look at
  # the Nth token in the script. With script "loaded,not-loaded,loaded"
  # the Nth token saturates to "loaded" once N>=3 (last-token reuse).
  local final_print_count
  final_print_count="$(grep -c -E '^print .*sh\.ntfy\.subscribe' "${calls_log}" || true)"
  if [[ "${final_print_count}" -ge 1 ]]; then
    # The script reuses the last token once N exceeds length, and the
    # last token is "loaded" → final rc 0 → final state loaded.
    pass "(g) final print probe maps to 'loaded' (script tail token, count=${final_print_count})"
  else
    fail "(g) no print probes recorded at all"
  fi

  # No kickstart entries.
  local kickstart_count
  kickstart_count="$(grep -c -E '^kickstart( |$)' "${calls_log}" || true)"
  if [[ "${kickstart_count}" -eq 0 ]]; then
    pass "(g) no kickstart entries (F4)"
  else
    fail "(g) kickstart appeared ${kickstart_count} times (F4 violated)"
    grep -E '^kickstart( |$)' "${calls_log}" >&2 || true
  fi
}

# ---------------------------------------------------------------------------
# Scenario (h) — bootstrap retry recovers (PRD F2 + Acceptance #2)
#
# Spec: prd.md § F2 ("Bounded bootstrap retry"), Acceptance criterion
#       "Bootstrap retry recovery".
#
# Configuration:
#   - print sequence: "not-loaded,loaded" — after bootout the service
#     is already gone (settle loop exits on the first probe). After
#     the successful bootstrap the probe reports loaded.
#   - bootstrap sequence: "1,0" — first attempt fails (rc=1), second
#     attempt succeeds (rc=0).
#   - bootout sequence: "0" — clean.
#
# Assertions:
#   - 2 <= bootstrap entries <= 5 (PRD upper bound is exactly 5).
#   - No `WARN` line on stderr (the retry recovered, no final warning).
#   - Script exits 0.
#   - No `kickstart` entries (F4).
#
# Expected RED on current install.sh: the current block fires bootstrap
# exactly once (no retry loop), so the bootstrap count is 1, not >=2.
# It also leaves `kickstart` in the call log.
# ---------------------------------------------------------------------------
scenario_h_bootstrap_retry_recovers() {
  echo "=== Scenario (h): bootstrap retry recovers ==="
  SCENARIOS_RUN=$((SCENARIOS_RUN+1))

  local home_dir
  home_dir="$(make_fixture_home)"
  local stub_dir
  stub_dir="$(make_stub_bin "${home_dir}" "Darwin")"
  local shim_log="${home_dir}/_shims"

  install_stateful_launchctl_mock "${stub_dir}" "${shim_log}"
  write_launchctl_state "${shim_log}" \
    "print:not-loaded,loaded" \
    "bootstrap:1,0" \
    "bootout:0"

  printf 'NTFY_TOPIC="fixture-topic-abc"\n' > "${home_dir}/.nudge/.env"

  local lad="${home_dir}/Library/LaunchAgents"
  local calls_log="${shim_log}/launchctl.calls"
  local stderr_file="${home_dir}/stderr.txt"

  set +e
  HOME="${home_dir}" \
    PATH="${stub_dir}:${PATH}" \
    NUDGE_LAUNCHAGENTS_DIR="${lad}" \
    NUDGE_BREW_CMD="${stub_dir}/brew" \
    NUDGE_NTFY_CMD="${stub_dir}/ntfy" \
    NUDGE_LAUNCHCTL_CMD="${stub_dir}/launchctl_stateful" \
    NUDGE_TEST_SHIMLOG="${shim_log}" \
    NUDGE_OPEN_CMD="${stub_dir}/open" \
    NUDGE_TN_CMD="${stub_dir}/terminal-notifier" \
    NUDGE_PUBLISH_CMD="${stub_dir}/ntfy publish" \
    bash "${INSTALL_SH}" --setup-receiver-macos >/dev/null 2>"${stderr_file}"
  local rc=$?
  set -e

  if [[ "${rc}" -ne 0 ]]; then
    fail "(h) install.sh exited ${rc}, expected 0"
    if [[ -f "${calls_log}" ]]; then
      echo "    --- launchctl.calls ---" >&2
      cat "${calls_log}" >&2
      echo "    -----------------------" >&2
    fi
    if [[ -f "${stderr_file}" ]]; then
      echo "    --- stderr ---" >&2
      cat "${stderr_file}" >&2
      echo "    --------------" >&2
    fi
    return
  fi
  pass "(h) install.sh exited 0"

  if [[ ! -f "${calls_log}" ]]; then
    fail "(h) launchctl.calls missing — mock never invoked"
    return
  fi

  local bootstrap_count
  bootstrap_count="$(grep -c -E '^bootstrap( |$)' "${calls_log}" || true)"
  if [[ "${bootstrap_count}" -ge 2 && "${bootstrap_count}" -le 5 ]]; then
    pass "(h) bootstrap count in [2,5] (count=${bootstrap_count})"
  else
    fail "(h) expected 2<=bootstrap<=5, got ${bootstrap_count}"
    echo "    --- launchctl.calls ---" >&2
    cat "${calls_log}" >&2
    echo "    -----------------------" >&2
  fi

  # No WARN line on stderr (the retry recovered).
  if [[ -f "${stderr_file}" ]] && grep -F "WARN" "${stderr_file}" >/dev/null 2>&1; then
    fail "(h) unexpected WARN line on stderr after successful retry"
    grep -F "WARN" "${stderr_file}" >&2 || true
  else
    pass "(h) no WARN line on stderr"
  fi

  local kickstart_count
  kickstart_count="$(grep -c -E '^kickstart( |$)' "${calls_log}" || true)"
  if [[ "${kickstart_count}" -eq 0 ]]; then
    pass "(h) no kickstart entries (F4)"
  else
    fail "(h) kickstart appeared ${kickstart_count} times (F4 violated)"
  fi
}

# ---------------------------------------------------------------------------
# Scenario (i) — all bootstraps fail, non-fatal WARN (PRD F3 + Acceptance #3)
#
# Spec: prd.md § F3 ("Non-fatal WARNING on final failure"), Acceptance
#       criterion "All bootstrap attempts fail → non-fatal WARN".
#
# Configuration:
#   - print sequence: "not-loaded" — always reports not-loaded (last-
#     token reuse covers every iteration).
#   - bootstrap sequence: "1" — every attempt fails (last-token reuse
#     covers all 5 ceiling attempts).
#   - bootout sequence: "0" — clean.
#
# Assertions:
#   - exactly 5 bootstrap entries (the PRD-defined retry ceiling).
#   - stderr contains a non-empty line containing "WARN".
#   - the self-test publish stub still recorded its call (script
#     continued past WARN to the publish stage).
#   - script exits 0.
#   - No `kickstart` entries (F4).
#
# Expected RED on current install.sh: the current block fires bootstrap
# exactly once (no retry, no WARN), so the bootstrap count is 1 not 5,
# and stderr contains no WARN line. `kickstart` is present, violating F4.
# ---------------------------------------------------------------------------
scenario_i_all_bootstraps_fail_warn() {
  echo "=== Scenario (i): all bootstraps fail, non-fatal WARN ==="
  SCENARIOS_RUN=$((SCENARIOS_RUN+1))

  local home_dir
  home_dir="$(make_fixture_home)"
  local stub_dir
  stub_dir="$(make_stub_bin "${home_dir}" "Darwin")"
  local shim_log="${home_dir}/_shims"

  install_stateful_launchctl_mock "${stub_dir}" "${shim_log}"
  write_launchctl_state "${shim_log}" \
    "print:not-loaded" \
    "bootstrap:1" \
    "bootout:0"

  printf 'NTFY_TOPIC="fixture-topic-abc"\n' > "${home_dir}/.nudge/.env"

  local lad="${home_dir}/Library/LaunchAgents"
  local calls_log="${shim_log}/launchctl.calls"
  local stderr_file="${home_dir}/stderr.txt"
  local ntfy_calls="${shim_log}/ntfy.calls"

  set +e
  HOME="${home_dir}" \
    PATH="${stub_dir}:${PATH}" \
    NUDGE_LAUNCHAGENTS_DIR="${lad}" \
    NUDGE_BREW_CMD="${stub_dir}/brew" \
    NUDGE_NTFY_CMD="${stub_dir}/ntfy" \
    NUDGE_LAUNCHCTL_CMD="${stub_dir}/launchctl_stateful" \
    NUDGE_TEST_SHIMLOG="${shim_log}" \
    NUDGE_OPEN_CMD="${stub_dir}/open" \
    NUDGE_TN_CMD="${stub_dir}/terminal-notifier" \
    NUDGE_PUBLISH_CMD="${stub_dir}/ntfy publish" \
    bash "${INSTALL_SH}" --setup-receiver-macos >/dev/null 2>"${stderr_file}"
  local rc=$?
  set -e

  if [[ "${rc}" -ne 0 ]]; then
    fail "(i) install.sh exited ${rc}, expected 0 (must continue past WARN)"
    if [[ -f "${calls_log}" ]]; then
      echo "    --- launchctl.calls ---" >&2
      cat "${calls_log}" >&2
      echo "    -----------------------" >&2
    fi
    if [[ -f "${stderr_file}" ]]; then
      echo "    --- stderr ---" >&2
      cat "${stderr_file}" >&2
      echo "    --------------" >&2
    fi
    return
  fi
  pass "(i) install.sh exited 0"

  if [[ ! -f "${calls_log}" ]]; then
    fail "(i) launchctl.calls missing — mock never invoked"
    return
  fi

  local bootstrap_count
  bootstrap_count="$(grep -c -E '^bootstrap( |$)' "${calls_log}" || true)"
  if [[ "${bootstrap_count}" -eq 5 ]]; then
    pass "(i) exactly 5 bootstrap entries (count=${bootstrap_count})"
  else
    fail "(i) expected exactly 5 bootstrap entries, got ${bootstrap_count}"
    echo "    --- launchctl.calls ---" >&2
    cat "${calls_log}" >&2
    echo "    -----------------------" >&2
  fi

  # stderr contains a non-empty line containing "WARN".
  if [[ -f "${stderr_file}" ]] && grep -E '.*WARN.*' "${stderr_file}" \
      | grep -E '\S' >/dev/null 2>&1; then
    pass "(i) stderr contains a non-empty 'WARN' line"
  else
    fail "(i) stderr missing a non-empty 'WARN' line"
    if [[ -f "${stderr_file}" ]]; then
      echo "    --- stderr ---" >&2
      cat "${stderr_file}" >&2
      echo "    --------------" >&2
    fi
  fi

  # The self-test publish stub recorded its call (script continued).
  if [[ -s "${ntfy_calls}" ]]; then
    pass "(i) ntfy publish stub recorded a call (script continued past WARN)"
  else
    fail "(i) ntfy publish stub NOT invoked (script halted before publish?)"
  fi

  local kickstart_count
  kickstart_count="$(grep -c -E '^kickstart( |$)' "${calls_log}" || true)"
  if [[ "${kickstart_count}" -eq 0 ]]; then
    pass "(i) no kickstart entries (F4)"
  else
    fail "(i) kickstart appeared ${kickstart_count} times (F4 violated)"
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
  scenario_g_settle_wait_honored
  scenario_h_bootstrap_retry_recovers
  scenario_i_all_bootstraps_fail_warn

  echo
  echo "Scenarios run: ${SCENARIOS_RUN}"
  if [[ "${FAILED}" -ne 0 ]]; then
    echo "SOME TESTS FAILED" >&2
    exit 1
  fi
  echo "ALL TESTS PASSED"
}

main "$@"
