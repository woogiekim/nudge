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
#   (d) NTFY_ID dedup: first delivery notifies and appends the id to
#       ~/.nudge/seen-ids; the replay with the same id MUST NOT invoke any
#       shim and MUST still exit 0. (PRD §F1, §F2, acceptance Gherkin
#       "First delivery of a given id notifies" + "Replay of the same id
#       is suppressed".)
#   (e) empty NTFY_ID passthrough: when NTFY_ID is empty/unset, dedup is
#       skipped entirely; two back-to-back invocations both fire the
#       terminal-notifier shim. (PRD §F3, acceptance Gherkin "Empty
#       NTFY_ID always notifies".)
#   (f) rotation cap: pre-seeded ~/.nudge/seen-ids with 510 distinct ids,
#       then notify-mac.sh runs with a new id. After the run, the file must
#       contain at most 500 lines AND the new id must be present.
#       (PRD §F4, acceptance Gherkin "Seen-ids file is capped to ~500
#       entries".)

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

# ---------------------------------------------------------------------------
# Scenario (d) — NTFY_ID dedup: first delivery notifies, replay is suppressed
# ---------------------------------------------------------------------------
# Spec: prd.md § F1 + F2 — acceptance criteria "First delivery of a given id
# notifies" and "Replay of the same id is suppressed".
scenario_d_ntfy_id_dedup() {
  echo "=== Scenario (d): NTFY_ID dedup (first notifies, replay suppressed) ==="
  SCENARIOS_RUN=$((SCENARIOS_RUN+1))

  local home_dir
  home_dir="$(make_fixture_home)"
  local tn_shim
  tn_shim="$(make_shim "${home_dir}" "tn" 0)"
  local osa_shim
  osa_shim="$(make_shim "${home_dir}" "osa" 0)"

  local seen_ids="${home_dir}/.nudge/seen-ids"
  local tn_calls="${home_dir}/_shims/tn.calls"
  local osa_calls="${home_dir}/_shims/osa.calls"

  # First delivery — must notify and append id.
  set +e
  HOME="${home_dir}" \
    NTFY_ID="test-id-1" \
    NTFY_TITLE="Dedup T" \
    NTFY_MESSAGE="Dedup M" \
    NTFY_PRIORITY="3" \
    NUDGE_TN_CMD="${tn_shim}" \
    NUDGE_OSA_CMD="${osa_shim}" \
    bash "${NOTIFY_MAC}"
  local rc1=$?
  set -e

  if [[ "${rc1}" -ne 0 ]]; then
    fail "(d) first run exited ${rc1}, expected 0"
  else
    pass "(d) first run exited 0"
  fi

  if [[ -s "${tn_calls}" ]]; then
    pass "(d) first run: terminal-notifier was invoked"
  else
    fail "(d) first run: terminal-notifier was NOT invoked"
  fi

  if [[ -f "${seen_ids}" ]] && grep -Fxq -- "test-id-1" "${seen_ids}"; then
    pass "(d) first run: seen-ids contains 'test-id-1'"
  else
    fail "(d) first run: seen-ids missing 'test-id-1'"
    if [[ -f "${seen_ids}" ]]; then
      echo "    seen-ids content:" >&2
      cat "${seen_ids}" >&2
    else
      echo "    seen-ids file ${seen_ids} does not exist" >&2
    fi
  fi

  # Truncate shim call logs before replay so we can assert NO invocation.
  : > "${tn_calls}"
  : > "${osa_calls}"

  # Replay with the same id — must NOT notify, must still exit 0.
  set +e
  HOME="${home_dir}" \
    NTFY_ID="test-id-1" \
    NTFY_TITLE="Dedup T" \
    NTFY_MESSAGE="Dedup M" \
    NTFY_PRIORITY="3" \
    NUDGE_TN_CMD="${tn_shim}" \
    NUDGE_OSA_CMD="${osa_shim}" \
    bash "${NOTIFY_MAC}"
  local rc2=$?
  set -e

  if [[ "${rc2}" -ne 0 ]]; then
    fail "(d) replay run exited ${rc2}, expected 0"
  else
    pass "(d) replay run exited 0"
  fi

  if [[ -s "${tn_calls}" ]]; then
    fail "(d) replay: terminal-notifier was UNEXPECTEDLY invoked"
    echo "    tn.calls content:" >&2
    cat "${tn_calls}" >&2
  else
    pass "(d) replay: terminal-notifier was NOT invoked (dedup suppressed)"
  fi

  if [[ -s "${osa_calls}" ]]; then
    fail "(d) replay: osascript was UNEXPECTEDLY invoked"
    echo "    osa.calls content:" >&2
    cat "${osa_calls}" >&2
  else
    pass "(d) replay: osascript was NOT invoked (dedup suppressed)"
  fi
}

# ---------------------------------------------------------------------------
# Scenario (e) — empty NTFY_ID always notifies (no dedup, no silent drop)
# ---------------------------------------------------------------------------
# Spec: prd.md § F3 — acceptance criterion "Empty NTFY_ID always notifies".
scenario_e_empty_id_passthrough() {
  echo "=== Scenario (e): empty NTFY_ID passthrough (notifies every time) ==="
  SCENARIOS_RUN=$((SCENARIOS_RUN+1))

  local home_dir
  home_dir="$(make_fixture_home)"
  local tn_shim
  tn_shim="$(make_shim "${home_dir}" "tn" 0)"
  local osa_shim
  osa_shim="$(make_shim "${home_dir}" "osa" 0)"

  local tn_calls="${home_dir}/_shims/tn.calls"

  # First invocation with empty NTFY_ID.
  set +e
  HOME="${home_dir}" \
    NTFY_ID="" \
    NTFY_TITLE="Empty T" \
    NTFY_MESSAGE="Empty M" \
    NTFY_PRIORITY="3" \
    NUDGE_TN_CMD="${tn_shim}" \
    NUDGE_OSA_CMD="${osa_shim}" \
    bash "${NOTIFY_MAC}"
  local rc1=$?
  set -e

  if [[ "${rc1}" -ne 0 ]]; then
    fail "(e) first empty-id run exited ${rc1}, expected 0"
  fi

  local invocations_after_first
  invocations_after_first=$(grep -c '^INVOCATION$' "${tn_calls}" 2>/dev/null || printf '0')
  if [[ "${invocations_after_first}" -ne 1 ]]; then
    fail "(e) first empty-id run: expected 1 tn invocation, got ${invocations_after_first}"
  else
    pass "(e) first empty-id run: tn invoked once"
  fi

  # Second invocation with empty NTFY_ID — must STILL notify.
  set +e
  HOME="${home_dir}" \
    NTFY_ID="" \
    NTFY_TITLE="Empty T" \
    NTFY_MESSAGE="Empty M" \
    NTFY_PRIORITY="3" \
    NUDGE_TN_CMD="${tn_shim}" \
    NUDGE_OSA_CMD="${osa_shim}" \
    bash "${NOTIFY_MAC}"
  local rc2=$?
  set -e

  if [[ "${rc2}" -ne 0 ]]; then
    fail "(e) second empty-id run exited ${rc2}, expected 0"
  fi

  local invocations_after_second
  invocations_after_second=$(grep -c '^INVOCATION$' "${tn_calls}" 2>/dev/null || printf '0')
  if [[ "${invocations_after_second}" -ne 2 ]]; then
    fail "(e) second empty-id run: expected 2 cumulative tn invocations, got ${invocations_after_second}"
    echo "    tn.calls content:" >&2
    cat "${tn_calls}" >&2
  else
    pass "(e) second empty-id run: tn invoked twice cumulative (no dedup applied)"
  fi
}

# ---------------------------------------------------------------------------
# Scenario (f) — rotation cap: seen-ids kept at ≤ 500 lines after a run
# ---------------------------------------------------------------------------
# Spec: prd.md § F4 — acceptance criterion "Seen-ids file is capped to ~500
# entries". The just-appended id MUST be present after rotation.
scenario_f_rotation_cap() {
  echo "=== Scenario (f): rotation cap (≤500 lines, new id preserved) ==="
  SCENARIOS_RUN=$((SCENARIOS_RUN+1))

  local home_dir
  home_dir="$(make_fixture_home)"
  local tn_shim
  tn_shim="$(make_shim "${home_dir}" "tn" 0)"
  local osa_shim
  osa_shim="$(make_shim "${home_dir}" "osa" 0)"

  local seen_ids="${home_dir}/.nudge/seen-ids"
  local new_id="rotation-new-id"

  # Pre-seed with 510 distinct ids — file is intentionally over the cap.
  local i=0
  : > "${seen_ids}"
  while [[ ${i} -lt 510 ]]; do
    printf 'preseed-id-%04d\n' "${i}" >> "${seen_ids}"
    i=$((i+1))
  done

  local lines_before
  lines_before=$(wc -l < "${seen_ids}" | tr -d ' ')
  if [[ "${lines_before}" -ne 510 ]]; then
    fail "(f) pre-seed failed: expected 510 lines, got ${lines_before}"
    return
  fi

  set +e
  HOME="${home_dir}" \
    NTFY_ID="${new_id}" \
    NTFY_TITLE="Rot T" \
    NTFY_MESSAGE="Rot M" \
    NTFY_PRIORITY="3" \
    NUDGE_TN_CMD="${tn_shim}" \
    NUDGE_OSA_CMD="${osa_shim}" \
    bash "${NOTIFY_MAC}"
  local rc=$?
  set -e

  if [[ "${rc}" -ne 0 ]]; then
    fail "(f) rotation run exited ${rc}, expected 0"
  else
    pass "(f) rotation run exited 0"
  fi

  local lines_after
  lines_after=$(wc -l < "${seen_ids}" | tr -d ' ')
  if [[ "${lines_after}" -le 500 ]]; then
    pass "(f) seen-ids capped at ${lines_after} lines (≤ 500)"
  else
    fail "(f) seen-ids NOT capped: ${lines_after} lines (> 500)"
  fi

  if grep -Fxq -- "${new_id}" "${seen_ids}"; then
    pass "(f) just-appended id '${new_id}' is present after rotation"
  else
    fail "(f) just-appended id '${new_id}' MISSING after rotation"
    echo "    last 10 lines of seen-ids:" >&2
    tail -n 10 "${seen_ids}" >&2
  fi
}

main() {
  scenario_a_tn_happy_path
  scenario_b_tn_fail_osascript_fallback
  scenario_c_tn_missing_osascript
  scenario_d_ntfy_id_dedup
  scenario_e_empty_id_passthrough
  scenario_f_rotation_cap

  echo
  echo "Scenarios run: ${SCENARIOS_RUN}"
  if [[ "${FAILED}" -ne 0 ]]; then
    echo "SOME TESTS FAILED" >&2
    exit 1
  fi
  echo "ALL TESTS PASSED"
}

main "$@"
