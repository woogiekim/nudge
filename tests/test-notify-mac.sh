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

# ---------------------------------------------------------------------------
# Scenario (g) — 2-LF body → -title / -subtitle / -message (3-segment route)
# ---------------------------------------------------------------------------
# Spec: prd.md § F2 — "If MSG contains TWO OR MORE LFs: split on the FIRST LF
# into HEAD and REST, then split REST on its FIRST LF into MID and TAIL. Map
# -subtitle = MID, -message = TAIL. HEAD is DROPPED from the visual banner."
# The terminal-notifier shim must see args in order: -title <T> -subtitle <MID>
# -message <TAIL>, with NTFY_TITLE preserved as the title and HEAD nowhere in
# the arg list.
scenario_g_two_lf_subtitle_route() {
  echo "=== Scenario (g): 2-LF body → -title/-subtitle/-message (HEAD dropped) ==="
  SCENARIOS_RUN=$((SCENARIOS_RUN+1))

  local home_dir
  home_dir="$(make_fixture_home)"
  local tn_shim
  tn_shim="$(make_shim "${home_dir}" "tn" 0)"
  local osa_shim
  osa_shim="$(make_shim "${home_dir}" "osa" 0)"

  # 3-segment body: HEAD="Response complete · main", MID="💬 Q?", TAIL="💡 A!"
  local body
  body=$'Response complete · main\n💬 Q?\n💡 A!'

  set +e
  HOME="${home_dir}" \
    NTFY_TITLE="Codex CLI · workspace" \
    NTFY_MESSAGE="${body}" \
    NTFY_PRIORITY="3" \
    NUDGE_TN_CMD="${tn_shim}" \
    NUDGE_OSA_CMD="${osa_shim}" \
    bash "${NOTIFY_MAC}"
  local rc=$?
  set -e

  if [[ "${rc}" -ne 0 ]]; then
    fail "(g) notify-mac.sh exited ${rc}, expected 0"
  else
    pass "(g) notify-mac.sh exited 0"
  fi

  local tn_calls="${home_dir}/_shims/tn.calls"
  if [[ ! -s "${tn_calls}" ]]; then
    fail "(g) terminal-notifier shim was NOT invoked"
    return
  fi

  # -title arg must carry NTFY_TITLE verbatim.
  if grep -F -- 'ARG=Codex CLI · workspace' "${tn_calls}" >/dev/null 2>&1; then
    pass "(g) -title carries 'Codex CLI · workspace'"
  else
    fail "(g) -title missing 'Codex CLI · workspace'"
  fi

  # -subtitle MUST be present and carry MID line (the Q line).
  if grep -F -- '-subtitle' "${tn_calls}" >/dev/null 2>&1; then
    pass "(g) -subtitle flag present"
  else
    fail "(g) -subtitle flag missing for 3-segment body"
  fi
  if grep -F -- 'ARG=💬 Q?' "${tn_calls}" >/dev/null 2>&1; then
    pass "(g) -subtitle value is the MID/Q line '💬 Q?'"
  else
    fail "(g) -subtitle value not the MID/Q line"
  fi

  # -message MUST carry TAIL (the A line).
  if grep -F -- 'ARG=💡 A!' "${tn_calls}" >/dev/null 2>&1; then
    pass "(g) -message value is the TAIL/A line '💡 A!'"
  else
    fail "(g) -message value not the TAIL/A line"
  fi

  # HEAD ("Response complete · main") MUST NOT appear in any tn arg — it is
  # explicitly dropped from the macOS banner per the PRD trade-off.
  if grep -F -- 'ARG=Response complete · main' "${tn_calls}" >/dev/null 2>&1; then
    fail "(g) HEAD 'Response complete · main' leaked into tn args (must be dropped)"
  else
    pass "(g) HEAD dropped from tn args (Q+A legibility wins over branch info)"
  fi

  # Order check: -title, -subtitle, -message must appear in that order.
  local order
  order="$(grep -nE '^ARG=(-title|-subtitle|-message)$' "${tn_calls}" | awk -F: '{print $2}' | tr '\n' ',' | sed 's/,$//')"
  if [[ "${order}" == "ARG=-title,ARG=-subtitle,ARG=-message" ]]; then
    pass "(g) flag order is -title, -subtitle, -message"
  else
    fail "(g) flag order incorrect (got: ${order})"
  fi
}

# ---------------------------------------------------------------------------
# Scenario (h) — 1-LF body → -title / -subtitle / -message (HEAD→subtitle)
# ---------------------------------------------------------------------------
# Spec: prd.md § F2 — "If MSG contains exactly ONE LF: split into HEAD (before
# LF) and TAIL (after LF). Map HEAD → -subtitle, TAIL → -message."
scenario_h_one_lf_subtitle_route() {
  echo "=== Scenario (h): 1-LF body → -title/-subtitle/-message (HEAD→subtitle) ==="
  SCENARIOS_RUN=$((SCENARIOS_RUN+1))

  local home_dir
  home_dir="$(make_fixture_home)"
  local tn_shim
  tn_shim="$(make_shim "${home_dir}" "tn" 0)"
  local osa_shim
  osa_shim="$(make_shim "${home_dir}" "osa" 0)"

  # 2-segment body: HEAD="Response complete · main", TAIL="💡 A!" (A-only fallback shape).
  local body
  body=$'Response complete · main\n💡 A!'

  set +e
  HOME="${home_dir}" \
    NTFY_TITLE="Codex CLI · workspace" \
    NTFY_MESSAGE="${body}" \
    NTFY_PRIORITY="3" \
    NUDGE_TN_CMD="${tn_shim}" \
    NUDGE_OSA_CMD="${osa_shim}" \
    bash "${NOTIFY_MAC}"
  local rc=$?
  set -e

  if [[ "${rc}" -ne 0 ]]; then
    fail "(h) notify-mac.sh exited ${rc}, expected 0"
  else
    pass "(h) notify-mac.sh exited 0"
  fi

  local tn_calls="${home_dir}/_shims/tn.calls"
  if [[ ! -s "${tn_calls}" ]]; then
    fail "(h) terminal-notifier shim was NOT invoked"
    return
  fi

  if grep -F -- '-subtitle' "${tn_calls}" >/dev/null 2>&1; then
    pass "(h) -subtitle flag present for 1-LF body"
  else
    fail "(h) -subtitle flag missing for 1-LF body"
  fi

  if grep -F -- 'ARG=Response complete · main' "${tn_calls}" >/dev/null 2>&1; then
    pass "(h) HEAD routed to -subtitle"
  else
    fail "(h) HEAD not present as -subtitle arg"
  fi

  if grep -F -- 'ARG=💡 A!' "${tn_calls}" >/dev/null 2>&1; then
    pass "(h) TAIL routed to -message"
  else
    fail "(h) TAIL not present as -message arg"
  fi

  # And the LF split must actually have run — that is, the -message arg must
  # be exactly the TAIL ("💡 A!"), NOT the entire 2-segment body. The shim
  # writes each arg as its own "ARG=<value>" line, so an arg that itself
  # contained a literal LF would create a "stray" line in the log that does
  # NOT start with "ARG=" or "INVOCATION". The presence of such a stray line
  # is the red signal that the split did not happen.
  local stray
  stray=$(grep -cvE '^(ARG=|INVOCATION$)' "${tn_calls}" 2>/dev/null | head -n 1 | tr -d '\n ')
  stray="${stray:-0}"
  if [[ "${stray}" -ne 0 ]]; then
    fail "(h) ${stray} non-ARG line(s) in tn.calls — implies an arg contained a raw LF (split did not run cleanly)"
    echo "    tn.calls content:" >&2
    cat "${tn_calls}" >&2
  else
    pass "(h) every line in tn.calls is INVOCATION or ARG= (no arg carries a raw LF)"
  fi
}

# ---------------------------------------------------------------------------
# Scenario (i) — 0-LF body → -title / -message only (NO -subtitle)
# ---------------------------------------------------------------------------
# Spec: prd.md § F2 — "If MSG contains NO LF: behave exactly as today (single
# -message, single osascript message). DO NOT add a -subtitle flag." This is
# the bytewise backward-compat guarantee.
scenario_i_zero_lf_no_subtitle() {
  echo "=== Scenario (i): 0-LF body → -title/-message only (no -subtitle) ==="
  SCENARIOS_RUN=$((SCENARIOS_RUN+1))

  local home_dir
  home_dir="$(make_fixture_home)"
  local tn_shim
  tn_shim="$(make_shim "${home_dir}" "tn" 0)"
  local osa_shim
  osa_shim="$(make_shim "${home_dir}" "osa" 0)"

  set +e
  HOME="${home_dir}" \
    NTFY_TITLE="Plain Title" \
    NTFY_MESSAGE="single line text" \
    NTFY_PRIORITY="3" \
    NUDGE_TN_CMD="${tn_shim}" \
    NUDGE_OSA_CMD="${osa_shim}" \
    bash "${NOTIFY_MAC}"
  local rc=$?
  set -e

  if [[ "${rc}" -ne 0 ]]; then
    fail "(i) notify-mac.sh exited ${rc}, expected 0"
  else
    pass "(i) notify-mac.sh exited 0"
  fi

  local tn_calls="${home_dir}/_shims/tn.calls"
  if [[ ! -s "${tn_calls}" ]]; then
    fail "(i) terminal-notifier shim was NOT invoked"
    return
  fi

  # -subtitle MUST NOT be present for a 0-LF body (bytewise backward compat).
  if grep -F -- '-subtitle' "${tn_calls}" >/dev/null 2>&1; then
    fail "(i) -subtitle flag UNEXPECTEDLY present for 0-LF body (breaks backward compat)"
  else
    pass "(i) -subtitle flag absent for 0-LF body (backward compat preserved)"
  fi

  # -title and -message MUST be present with the original values.
  if grep -F -- 'ARG=Plain Title' "${tn_calls}" >/dev/null 2>&1; then
    pass "(i) -title carries 'Plain Title'"
  else
    fail "(i) -title missing 'Plain Title'"
  fi
  if grep -F -- 'ARG=single line text' "${tn_calls}" >/dev/null 2>&1; then
    pass "(i) -message carries 'single line text' verbatim"
  else
    fail "(i) -message does not carry 'single line text' verbatim"
  fi
}

# ---------------------------------------------------------------------------
# Scenario (j) — subtitle containing double-quote → stripped (no AppleScript break)
# ---------------------------------------------------------------------------
# Spec: prd.md § F2 — "NEW: SUBTITLE_SAFE=\"${SUBTITLE//\\\"/}\" — identical
# strip before embedding in the osascript subtitle \"...\" clause and the
# terminal-notifier -subtitle arg." Force osascript path by making tn fail.
scenario_j_subtitle_quote_strip() {
  echo "=== Scenario (j): subtitle with double-quote → stripped (osascript stays valid) ==="
  SCENARIOS_RUN=$((SCENARIOS_RUN+1))

  local home_dir
  home_dir="$(make_fixture_home)"
  local tn_shim
  tn_shim="$(make_shim "${home_dir}" "tn" 1)"     # nonzero → osascript fallback
  local osa_shim
  osa_shim="$(make_shim "${home_dir}" "osa" 0)"

  # 1-LF body where HEAD contains a literal double-quote.
  local body
  body=$'Q has "quotes"\n💡 A!'

  set +e
  HOME="${home_dir}" \
    NTFY_TITLE="Codex CLI · workspace" \
    NTFY_MESSAGE="${body}" \
    NTFY_PRIORITY="3" \
    NUDGE_TN_CMD="${tn_shim}" \
    NUDGE_OSA_CMD="${osa_shim}" \
    bash "${NOTIFY_MAC}"
  local rc=$?
  set -e

  if [[ "${rc}" -ne 0 ]]; then
    fail "(j) notify-mac.sh exited ${rc}, expected 0"
  else
    pass "(j) notify-mac.sh exited 0"
  fi

  local tn_calls="${home_dir}/_shims/tn.calls"
  local osa_calls="${home_dir}/_shims/osa.calls"

  # On the tn path the -subtitle arg the shim sees must have the `"` stripped.
  if grep -F -- 'ARG=Q has quotes' "${tn_calls}" >/dev/null 2>&1; then
    pass "(j) terminal-notifier -subtitle arg has '\"' stripped"
  else
    fail "(j) terminal-notifier -subtitle arg did NOT strip '\"' (saw: $(grep -F -- 'Q has' "${tn_calls}" || printf 'none'))"
  fi

  # The osascript fallback path was forced (tn exit 1). The osascript -e arg
  # (single combined script string) MUST contain `subtitle "Q has quotes"` —
  # i.e. with the `"` characters stripped from the subtitle segment.
  if [[ ! -s "${osa_calls}" ]]; then
    fail "(j) osascript shim was NOT invoked (tn fail did not trigger fallback)"
    return
  fi
  if grep -F -- 'subtitle "Q has quotes"' "${osa_calls}" >/dev/null 2>&1; then
    pass "(j) osascript -e command contains: subtitle \"Q has quotes\" (quotes stripped)"
  else
    fail "(j) osascript -e command missing the stripped-quote subtitle clause"
    echo "    osa.calls content:" >&2
    cat "${osa_calls}" >&2
  fi
}

# ---------------------------------------------------------------------------
# Scenario (k) — osascript fallback path with 2-LF body → subtitle clause emitted
# ---------------------------------------------------------------------------
# Spec: prd.md § F2 — "1-LF or 2-LF case: display notification \"<MSG_SAFE>\"
# with title \"<TITLE_SAFE>\" subtitle \"<SUBTITLE_SAFE>\"." When the 3-segment
# body is presented via osascript, the -e arg must contain a `subtitle "..."`
# clause referencing MID (the Q line), and the message argument of the
# display-notification call must be TAIL (the A line), NOT the whole body.
scenario_k_osascript_two_lf_subtitle_clause() {
  echo "=== Scenario (k): osascript fallback with 2-LF body emits subtitle clause ==="
  SCENARIOS_RUN=$((SCENARIOS_RUN+1))

  local home_dir
  home_dir="$(make_fixture_home)"
  local tn_shim
  tn_shim="$(make_shim "${home_dir}" "tn" 1)"     # nonzero → fallback
  local osa_shim
  osa_shim="$(make_shim "${home_dir}" "osa" 0)"

  local body
  body=$'Response complete · main\n💬 Q?\n💡 A!'

  set +e
  HOME="${home_dir}" \
    NTFY_TITLE="Codex CLI · workspace" \
    NTFY_MESSAGE="${body}" \
    NTFY_PRIORITY="3" \
    NUDGE_TN_CMD="${tn_shim}" \
    NUDGE_OSA_CMD="${osa_shim}" \
    bash "${NOTIFY_MAC}"
  local rc=$?
  set -e

  if [[ "${rc}" -ne 0 ]]; then
    fail "(k) notify-mac.sh exited ${rc}, expected 0"
  else
    pass "(k) notify-mac.sh exited 0"
  fi

  local osa_calls="${home_dir}/_shims/osa.calls"
  if [[ ! -s "${osa_calls}" ]]; then
    fail "(k) osascript shim was NOT invoked despite tn failure"
    return
  fi

  # The -e arg of osascript carries the whole `display notification ...` cmd.
  # It MUST include `subtitle "💬 Q?"` (the MID line).
  if grep -F -- 'subtitle "💬 Q?"' "${osa_calls}" >/dev/null 2>&1; then
    pass "(k) osascript -e includes 'subtitle \"💬 Q?\"' clause"
  else
    fail "(k) osascript -e missing 'subtitle \"💬 Q?\"' clause"
    echo "    osa.calls content:" >&2
    cat "${osa_calls}" >&2
  fi

  # The display-notification message argument (the first string in the AppleScript)
  # must be TAIL (the A line "💡 A!"), NOT the whole body. Match the canonical
  # AppleScript prefix:  display notification "💡 A!" with title ...
  if grep -F -- 'display notification "💡 A!" with title' "${osa_calls}" >/dev/null 2>&1; then
    pass "(k) osascript display-notification message is TAIL (A line)"
  else
    fail "(k) osascript message field is not the TAIL/A line"
  fi

  # HEAD must NOT appear inside the AppleScript command string (it is dropped).
  if grep -F -- 'Response complete · main' "${osa_calls}" >/dev/null 2>&1; then
    fail "(k) HEAD 'Response complete · main' leaked into osascript -e arg"
  else
    pass "(k) HEAD dropped from osascript -e arg"
  fi
}

main() {
  scenario_a_tn_happy_path
  scenario_b_tn_fail_osascript_fallback
  scenario_c_tn_missing_osascript
  scenario_d_ntfy_id_dedup
  scenario_e_empty_id_passthrough
  scenario_f_rotation_cap
  scenario_g_two_lf_subtitle_route
  scenario_h_one_lf_subtitle_route
  scenario_i_zero_lf_no_subtitle
  scenario_j_subtitle_quote_strip
  scenario_k_osascript_two_lf_subtitle_clause

  echo
  echo "Scenarios run: ${SCENARIOS_RUN}"
  if [[ "${FAILED}" -ne 0 ]]; then
    echo "SOME TESTS FAILED" >&2
    exit 1
  fi
  echo "ALL TESTS PASSED"
}

main "$@"
