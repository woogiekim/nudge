#!/usr/bin/env bash
# Spec: prd.md § F2 — notify-mac.sh behavioral contract.
#
# Scenarios:
#   (a) terminal-notifier path: NTFY_TITLE/NTFY_MESSAGE/NTFY_PRIORITY env →
#       shim invoked with exactly `-title <T> -message <M> -sound default`,
#       log file gains a line containing `prio=<P> | <T> | <M>`,
#       exit code 0.
#   (b) osascript fallback path: when terminal-notifier shim exits NON-ZERO,
#       the osascript shim is invoked (with the title+msg embedded).
#   (c) missing-binary fallback: when NUDGE_TN_CMD points at a missing path,
#       the osascript shim is invoked directly without trying terminal-notifier.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NOTIFY_MAC="${REPO_ROOT}/notify-mac.sh"

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
  home_dir="$(mktemp -d -t nudge-notify-mac-XXXXXX)"
  FIXTURE_DIRS+=("${home_dir}")
  mkdir -p "${home_dir}/.nudge"
  printf '%s' "${home_dir}"
}

# make_shim <home_dir> <name> <exit-code>
#   Creates an executable shim at <home_dir>/_stubbin/<name> that:
#   - appends one line per arg to <home_dir>/_shims/<name>.calls
#   - prints a blank line separator after each invocation
#   - exits with <exit-code>
make_shim() {
  local home_dir="$1"
  local name="$2"
  local exit_code="$3"

  local stub_dir="${home_dir}/_stubbin"
  local shim_log="${home_dir}/_shims"
  mkdir -p "${stub_dir}" "${shim_log}"

  cat > "${stub_dir}/${name}" <<SHIM_EOF
#!/usr/bin/env bash
{
  printf '%s\n' "INVOCATION"
  for a in "\$@"; do
    printf '%s\n' "ARG=\${a}"
  done
} >> "${shim_log}/${name}.calls"
exit ${exit_code}
SHIM_EOF
  chmod +x "${stub_dir}/${name}"
  printf '%s' "${stub_dir}/${name}"
}

pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*" >&2; FAILED=1; }

# ---------------------------------------------------------------------------
# Scenario (a) — terminal-notifier success path
# ---------------------------------------------------------------------------
scenario_a_tn_happy_path() {
  echo "=== Scenario (a): terminal-notifier happy path ==="
  SCENARIOS_RUN=$((SCENARIOS_RUN+1))

  local home_dir
  home_dir="$(make_fixture_home)"
  local tn_shim
  tn_shim="$(make_shim "${home_dir}" "tn" 0)"
  local osa_shim
  osa_shim="$(make_shim "${home_dir}" "osa" 0)"

  set +e
  HOME="${home_dir}" \
    NTFY_TITLE="Test T" \
    NTFY_MESSAGE="Test M" \
    NTFY_PRIORITY="5" \
    NUDGE_TN_CMD="${tn_shim}" \
    NUDGE_OSA_CMD="${osa_shim}" \
    bash "${NOTIFY_MAC}"
  local rc=$?
  set -e

  if [[ "${rc}" -ne 0 ]]; then
    fail "(a) notify-mac.sh exited ${rc}, expected 0"
  else
    pass "(a) notify-mac.sh exited 0"
  fi

  local tn_calls="${home_dir}/_shims/tn.calls"
  if [[ ! -s "${tn_calls}" ]]; then
    fail "(a) terminal-notifier shim was NOT invoked"
    return
  fi

  for needle in '-title' 'ARG=Test T' '-message' 'ARG=Test M' '-sound' 'ARG=default'; do
    if grep -F -- "${needle}" "${tn_calls}" >/dev/null 2>&1; then
      pass "(a) terminal-notifier received '${needle}'"
    else
      fail "(a) terminal-notifier missing '${needle}'"
    fi
  done

  local log="${home_dir}/.nudge/ntfy-mac-notify.log"
  if [[ ! -f "${log}" ]]; then
    fail "(a) log file ${log} not created"
    return
  fi
  if grep -F 'prio=5 | Test T | Test M' "${log}" >/dev/null 2>&1; then
    pass "(a) log contains 'prio=5 | Test T | Test M' line"
  else
    fail "(a) log missing canonical 'prio=5 | Test T | Test M' line"
    echo "    log content:" >&2
    cat "${log}" >&2
  fi

  # osascript MUST NOT be called when terminal-notifier succeeded.
  if [[ -s "${home_dir}/_shims/osa.calls" ]]; then
    fail "(a) osascript shim was unexpectedly invoked"
  else
    pass "(a) osascript shim was NOT invoked (terminal-notifier won)"
  fi
}

# ---------------------------------------------------------------------------
# Scenario (b) — terminal-notifier exits non-zero → osascript fallback
# ---------------------------------------------------------------------------
scenario_b_tn_fail_osascript_fallback() {
  echo "=== Scenario (b): terminal-notifier fails → osascript fallback ==="
  SCENARIOS_RUN=$((SCENARIOS_RUN+1))

  local home_dir
  home_dir="$(make_fixture_home)"
  local tn_shim
  tn_shim="$(make_shim "${home_dir}" "tn" 1)"     # nonzero
  local osa_shim
  osa_shim="$(make_shim "${home_dir}" "osa" 0)"

  set +e
  HOME="${home_dir}" \
    NTFY_TITLE="FailoverT" \
    NTFY_MESSAGE="FailoverM" \
    NTFY_PRIORITY="3" \
    NUDGE_TN_CMD="${tn_shim}" \
    NUDGE_OSA_CMD="${osa_shim}" \
    bash "${NOTIFY_MAC}"
  local rc=$?
  set -e

  if [[ "${rc}" -ne 0 ]]; then
    fail "(b) notify-mac.sh exited ${rc}, expected 0"
  else
    pass "(b) notify-mac.sh exited 0 despite tn failure"
  fi

  if [[ -s "${home_dir}/_shims/osa.calls" ]]; then
    pass "(b) osascript fallback was invoked"
  else
    fail "(b) osascript fallback was NOT invoked despite tn nonzero"
  fi
}

# ---------------------------------------------------------------------------
# Scenario (c) — terminal-notifier binary missing → osascript path
# ---------------------------------------------------------------------------
scenario_c_tn_missing_osascript() {
  echo "=== Scenario (c): NUDGE_TN_CMD missing → osascript path ==="
  SCENARIOS_RUN=$((SCENARIOS_RUN+1))

  local home_dir
  home_dir="$(make_fixture_home)"
  local osa_shim
  osa_shim="$(make_shim "${home_dir}" "osa" 0)"
  local missing_tn="${home_dir}/_stubbin/does-not-exist-terminal-notifier"

  set +e
  HOME="${home_dir}" \
    NTFY_TITLE="NoTn" \
    NTFY_MESSAGE="NoTnMsg" \
    NUDGE_TN_CMD="${missing_tn}" \
    NUDGE_OSA_CMD="${osa_shim}" \
    bash "${NOTIFY_MAC}"
  local rc=$?
  set -e

  if [[ "${rc}" -ne 0 ]]; then
    fail "(c) notify-mac.sh exited ${rc}, expected 0"
  else
    pass "(c) notify-mac.sh exited 0"
  fi

  if [[ -s "${home_dir}/_shims/osa.calls" ]]; then
    pass "(c) osascript was invoked when terminal-notifier is missing"
  else
    fail "(c) osascript NOT invoked when terminal-notifier is missing"
  fi
}

main() {
  scenario_a_tn_happy_path
  scenario_b_tn_fail_osascript_fallback
  scenario_c_tn_missing_osascript

  echo
  echo "Scenarios run: ${SCENARIOS_RUN}"
  if [[ "${FAILED}" -ne 0 ]]; then
    echo "SOME TESTS FAILED" >&2
    exit 1
  fi
  echo "ALL TESTS PASSED"
}

main "$@"
