#!/usr/bin/env bash
# Spec: prd.md § F1 + Test contract T2 + T3
# (Disable ntfy server-side cache for nudge publishes)
#
# Verifies that notify.sh passes `-H "Cache: no"` to curl, alongside the
# pre-existing Title / Priority / Tags headers, the message body, and the
# target URL — and that no extra headers were introduced.
#
# Strategy:
#   - PATH-prepend a `curl` recorder stub that writes one argv token per line
#     to ${home}/_shims/curl.calls and exits 0.
#   - Inject NTFY_TOPIC / NTFY_SERVER via the environment (notify.sh loads
#     .env beside itself; real env vars override).
#   - Invoke notify.sh "Title-X" "Body-Y" and assert recorded argv shape.
#
# Expected to FAIL on the unmodified notify.sh (red phase) — the `Cache: no`
# header and the `-H` count assertion (4) only become satisfiable once the
# implementer lands the cache-disable header.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NOTIFY_SH="${REPO_ROOT}/notify.sh"

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
  home_dir="$(mktemp -d -t nudge-notify-XXXXXX)"
  FIXTURE_DIRS+=("${home_dir}")
  mkdir -p "${home_dir}/.nudge"
  printf '%s' "${home_dir}"
}

# make_curl_stub <home_dir>
#   Creates ${home_dir}/_stubbin/curl that records each argv token on its
#   own line to ${home_dir}/_shims/curl.calls, then exits 0.
make_curl_stub() {
  local home_dir="$1"
  local stub_dir="${home_dir}/_stubbin"
  local shim_log="${home_dir}/_shims"
  mkdir -p "${stub_dir}" "${shim_log}"

  cat > "${stub_dir}/curl" <<STUB_EOF
#!/usr/bin/env bash
{
  printf '%s\n' "INVOCATION"
  for a in "\$@"; do
    printf '%s\n' "ARG=\${a}"
  done
} >> "${shim_log}/curl.calls"
exit 0
STUB_EOF
  chmod +x "${stub_dir}/curl"
  printf '%s' "${stub_dir}"
}

pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*" >&2; FAILED=1; }

# assert_calls_contains_arg <calls_file> <expected_arg> <msg>
#   Passes if a line `ARG=<expected_arg>` exists in the calls file.
assert_calls_contains_arg() {
  local calls_file="$1" expected="$2" msg="$3"
  if [[ -f "${calls_file}" ]] && grep -F -x -- "ARG=${expected}" "${calls_file}" >/dev/null 2>&1; then
    pass "${msg}"
  else
    fail "${msg} — token '${expected}' not present in ${calls_file}"
    if [[ -f "${calls_file}" ]]; then
      echo "    --- recorded argv ---" >&2
      cat "${calls_file}" >&2
      echo "    ---------------------" >&2
    fi
  fi
}

# assert_consecutive_dash_h <calls_file> <expected_value> <msg>
#   Passes if a line `ARG=-H` is immediately followed by `ARG=<expected_value>`.
assert_consecutive_dash_h() {
  local calls_file="$1" expected_value="$2" msg="$3"
  if [[ ! -f "${calls_file}" ]]; then
    fail "${msg} — calls file missing: ${calls_file}"
    return
  fi
  # Walk the file looking for the pair.
  local prev=""
  local found=0
  while IFS= read -r line; do
    if [[ "${prev}" == "ARG=-H" && "${line}" == "ARG=${expected_value}" ]]; then
      found=1
      break
    fi
    prev="${line}"
  done < "${calls_file}"
  if [[ "${found}" -eq 1 ]]; then
    pass "${msg}"
  else
    fail "${msg} — consecutive '-H' '${expected_value}' not found in ${calls_file}"
    echo "    --- recorded argv ---" >&2
    cat "${calls_file}" >&2
    echo "    ---------------------" >&2
  fi
}

# assert_dash_h_count <calls_file> <expected_count> <msg>
#   Counts `ARG=-H` lines and asserts it equals expected_count.
assert_dash_h_count() {
  local calls_file="$1" expected_count="$2" msg="$3"
  if [[ ! -f "${calls_file}" ]]; then
    fail "${msg} — calls file missing: ${calls_file}"
    return
  fi
  local count
  count="$(grep -c -F -x 'ARG=-H' "${calls_file}" || true)"
  if [[ "${count}" -eq "${expected_count}" ]]; then
    pass "${msg} (count=${count})"
  else
    fail "${msg} — expected ${expected_count} '-H' flags, observed ${count}"
    echo "    --- recorded argv ---" >&2
    cat "${calls_file}" >&2
    echo "    ---------------------" >&2
  fi
}

# ---------------------------------------------------------------------------
# Scenario T2 — notify.sh passes `-H "Cache: no"` to curl alongside the
# pre-existing headers, body, and URL; total `-H` count is exactly 4.
# ---------------------------------------------------------------------------
scenario_t2_cache_no_header() {
  echo "=== Scenario T2: notify.sh emits -H 'Cache: no' to curl ==="
  SCENARIOS_RUN=$((SCENARIOS_RUN+1))

  local home_dir
  home_dir="$(make_fixture_home)"
  local stub_dir
  stub_dir="$(make_curl_stub "${home_dir}")"

  local calls_file="${home_dir}/_shims/curl.calls"

  set +e
  HOME="${home_dir}" \
    PATH="${stub_dir}:${PATH}" \
    NTFY_TOPIC="testtopic" \
    NTFY_SERVER="https://ntfy.sh" \
    bash "${NOTIFY_SH}" "Title-X" "Body-Y" >/dev/null 2>&1
  local rc=$?
  set -e

  if [[ "${rc}" -ne 0 ]]; then
    fail "T2 notify.sh exited ${rc}, expected 0"
  else
    pass "T2 notify.sh exited 0"
  fi

  # Existing headers must still be present (proves additive change only).
  assert_consecutive_dash_h "${calls_file}" "Title: Title-X" \
    "T2 curl argv contains -H 'Title: Title-X'"
  assert_consecutive_dash_h "${calls_file}" "Priority: default" \
    "T2 curl argv contains -H 'Priority: default'"
  assert_consecutive_dash_h "${calls_file}" "Tags: robot" \
    "T2 curl argv contains -H 'Tags: robot'"

  # The new cache-disable header — the actual point of this test.
  assert_consecutive_dash_h "${calls_file}" "Cache: no" \
    "T2 curl argv contains -H 'Cache: no' (exact case + single space)"

  # Body and URL still intact.
  assert_calls_contains_arg "${calls_file}" "Body-Y" \
    "T2 curl argv contains the message body 'Body-Y'"
  assert_calls_contains_arg "${calls_file}" "https://ntfy.sh/testtopic" \
    "T2 curl argv contains the target URL"

  # T3 negative bound: exactly 4 `-H` flags (Title, Priority, Tags, Cache).
  # If implementer adds extra headers beyond the cache directive, this fails.
  assert_dash_h_count "${calls_file}" 4 \
    "T2/T3 curl argv has exactly 4 '-H' flags"
}

# ---------------------------------------------------------------------------
# Scenario F3 — empty NTFY_TOPIC writes a trace line to ~/.nudge/notify.log
#
# Spec: prd.md § F3 — notify.sh trace-log on skip
#   Given NTFY_TOPIC is unset in env and absent from .env
#   When notify.sh "TestTitle" "TestMsg" runs (HOME redirected to a fixture)
#   Then the script exits 0
#   And ${HOME}/.nudge/notify.log exists and contains a line with a
#       timestamp-looking token AND the literal "NTFY_TOPIC" AND the title.
#   And the existing stderr message "not set ... Skipping" is still emitted.
#
# Expected to FAIL on the unmodified notify.sh (red phase) — the script
# currently writes only to stderr and exits 0 without touching notify.log.
# ---------------------------------------------------------------------------
scenario_f3_empty_topic_writes_trace_log() {
  echo "=== Scenario F3: empty NTFY_TOPIC writes trace line to ~/.nudge/notify.log ==="
  SCENARIOS_RUN=$((SCENARIOS_RUN+1))

  local home_dir
  home_dir="$(make_fixture_home)"
  # No .env file beside the script's SCRIPT_DIR is created in the fixture
  # HOME, and we explicitly unset NTFY_TOPIC in the env. notify.sh resolves
  # SCRIPT_DIR to the real repo dir (the notify.sh path), so if a stale .env
  # exists beside the repo's notify.sh it could leak through. Defensive:
  # explicitly empty NTFY_TOPIC and NTFY_SERVER on the command line so the
  # in-script env-takes-precedence logic forces topic=empty.

  local stderr_file="${home_dir}/stderr.txt"

  set +e
  HOME="${home_dir}" \
    NTFY_TOPIC="" \
    NTFY_SERVER="" \
    bash "${NOTIFY_SH}" "TestTitle" "TestMsg" >/dev/null 2>"${stderr_file}"
  local rc=$?
  set -e

  if [[ "${rc}" -ne 0 ]]; then
    fail "F3 notify.sh exited ${rc}, expected 0 (must remain hook-safe)"
  else
    pass "F3 notify.sh exited 0"
  fi

  # The existing stderr behaviour must NOT regress — the "not set ... Skipping"
  # message is the long-standing operator signal and must still be there.
  if grep -F -- "not set" "${stderr_file}" >/dev/null 2>&1 \
      && grep -F -- "Skipping" "${stderr_file}" >/dev/null 2>&1; then
    pass "F3 stderr still contains the legacy 'not set' + 'Skipping' message"
  else
    fail "F3 stderr regressed — missing 'not set' or 'Skipping'"
    echo "    --- stderr ---" >&2
    cat "${stderr_file}" >&2
    echo "    --------------" >&2
  fi

  local log_file="${home_dir}/.nudge/notify.log"
  if [[ -f "${log_file}" ]]; then
    pass "F3 ${HOME}/.nudge/notify.log exists after skip"
  else
    fail "F3 ${log_file} does NOT exist — trace log was not written"
    return
  fi

  # The trace line must include: a timestamp-looking token (4-digit year
  # followed by '-'), the literal token 'NTFY_TOPIC', and the title.
  # All three on the same line — that's the operator grep contract.
  if grep -E '20[0-9]{2}-' "${log_file}" \
      | grep -F 'NTFY_TOPIC' \
      | grep -F 'TestTitle' >/dev/null 2>&1; then
    pass "F3 notify.log line contains timestamp + NTFY_TOPIC + 'TestTitle'"
  else
    fail "F3 notify.log line missing one of: timestamp, NTFY_TOPIC, 'TestTitle'"
    echo "    --- notify.log ---" >&2
    cat "${log_file}" >&2
    echo "    ------------------" >&2
  fi
}

main() {
  scenario_t2_cache_no_header
  scenario_f3_empty_topic_writes_trace_log

  echo
  echo "Scenarios run: ${SCENARIOS_RUN}"
  if [[ "${FAILED}" -ne 0 ]]; then
    echo "SOME TESTS FAILED" >&2
    exit 1
  fi
  echo "ALL TESTS PASSED"
}

main "$@"
