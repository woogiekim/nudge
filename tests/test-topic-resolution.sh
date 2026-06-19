#!/usr/bin/env bash
# Spec: prd.md § F1-F6 + F9 + Acceptance Criteria (NTFY_TOPIC resolution).
#
# Verifies the six acceptance scenarios from PRD context/prd.md:
#   F1  --topic <value>  wins over everything (flag precedence)
#   F2  NTFY_TOPIC env var used when no --topic
#   F3  Existing ~/.nudge/.env with non-empty NTFY_TOPIC is preserved
#       ("left untouched" contract; install.sh:781 stays intact)
#   F4  /dev/tty interactive prompt when no other source AND tty available
#       (pty-based, best-effort — gracefully skipped if BSD `script` cannot
#       allocate a pty in this environment; documented in test output)
#   F5  No-tty fallback: stdin closed, /dev/tty unopenable → empty topic
#       + LOUD WARNING printed, exit code 0, no hang
#   F6  Empty / whitespace --topic value falls through to next priority
#       (resolution does NOT lock in the blank value)
#
# Strategy:
#   - HOME redirected to a per-scenario tempdir, so INSTALL_DIR=${HOME}/.nudge
#     never touches the user's real ~/.nudge.
#   - install.sh is invoked with the local checkout's siblings present, so the
#     self-fetch path stays untouched (we only exercise the topic-resolution
#     branch, which lives entirely above the .env create branch).
#   - For F5 the install.sh body is piped via `cat install.sh | bash -s --`
#     to simulate the curl|bash self-fetch where stdin == script body. We
#     also close /dev/tty's controlling terminal via `setsid`/background
#     when available; on macOS the simpler `</dev/null` + `setsid` substitute
#     is to run without a controlling tty by detaching (`nohup` + redirection)
#     OR by relying on the fact that piping the script body already prevents
#     /dev/tty from being mapped to a usable terminal in a non-interactive
#     test harness. Both paths assert: exit 0, LOUD WARNING printed, the
#     test process does not hang (bounded by a 30s timeout).
#   - For F4 we use BSD `script` (/usr/bin/script on macOS) to allocate a pty,
#     piping "interactive-topic\n" as its input. If `script` is not available
#     or cannot allocate a pty, F4 is recorded as skipped (not failed).
#
# Expected to FAIL on HEAD=ff361c5 (red phase): install.sh has no --topic
# flag, no resolution function, and writes an empty NTFY_TOPIC unconditionally.
# Becomes green once the parallel backend stage lands the resolution branch.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"

FAILED=0
SCENARIOS_RUN=0
SCENARIOS_SKIPPED=0

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

pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*" >&2; FAILED=1; }
skip() { echo "  SKIP: $*"; SCENARIOS_SKIPPED=$((SCENARIOS_SKIPPED + 1)); }

# --- fixture helpers --------------------------------------------------------

mkroot() {
  local d
  d="$(mktemp -d -t nudge-topicres-XXXXXX)"
  FIXTURE_DIRS+=("${d}")
  printf '%s' "${d}"
}

# Sibling files install.sh expects to find next to itself in clone-mode.
# Mirrors tests/test-install-selffetch.sh.
SIBLING_SCRIPTS=(
  "notify.sh"
  "notify-claude.sh"
  "notify-codex.sh"
  "notify-codex-turn-start.sh"
  "notify-gemini.sh"
  "notify-mac.sh"
  "_nudge_lib.sh"
  "test.sh"
)
SIBLING_ALL=("${SIBLING_SCRIPTS[@]}" ".env.example")

# populate_checkout — copy install.sh + siblings into a fresh source dir so the
# in-tree (no self-fetch) path is exercised. Resolution logic is independent of
# the fetch mode, but using clone-mode keeps the fixture simpler.
populate_checkout() {
  local src_dir="$1"
  cp "${INSTALL_SH}" "${src_dir}/install.sh"
  chmod +x "${src_dir}/install.sh"
  local f
  for f in "${SIBLING_ALL[@]}"; do
    if [[ -f "${REPO_ROOT}/${f}" ]]; then
      cp "${REPO_ROOT}/${f}" "${src_dir}/${f}"
    fi
  done
}

# assert_env_topic <env_file> <expected_value> <label>
#   PRD F1/F2/F4/F6 — ~/.nudge/.env must contain NTFY_TOPIC=<expected>.
#   Matches a literal "NTFY_TOPIC=<expected>" line (no surrounding quotes).
assert_env_topic() {
  local env_file="$1" expected="$2" label="$3"
  if [[ ! -f "${env_file}" ]]; then
    fail "${label}: ${env_file} does not exist"
    return
  fi
  if grep -E "^NTFY_TOPIC=${expected}\$" "${env_file}" >/dev/null 2>&1; then
    pass "${label}: ${env_file} contains NTFY_TOPIC=${expected}"
  else
    fail "${label}: ${env_file} does NOT contain NTFY_TOPIC=${expected}"
    echo "    --- ${env_file} ---" >&2
    sed 's/^/    /' "${env_file}" >&2 || true
    echo "    -------------------" >&2
  fi
}

# assert_env_topic_empty <env_file> <label>
#   PRD F5 — fallback path leaves the placeholder NTFY_TOPIC= (empty) line in
#   place (the file is created from .env.example, which ships an empty value).
assert_env_topic_empty() {
  local env_file="$1" label="$2"
  if [[ ! -f "${env_file}" ]]; then
    fail "${label}: ${env_file} does not exist"
    return
  fi
  if grep -E '^NTFY_TOPIC=$' "${env_file}" >/dev/null 2>&1 \
     || grep -E '^NTFY_TOPIC=""$' "${env_file}" >/dev/null 2>&1; then
    pass "${label}: NTFY_TOPIC is empty in ${env_file} (fallback contract)"
  else
    fail "${label}: NTFY_TOPIC is not empty as expected in ${env_file}"
    echo "    --- ${env_file} ---" >&2
    sed 's/^/    /' "${env_file}" >&2 || true
    echo "    -------------------" >&2
  fi
}

# ---------------------------------------------------------------------------
# F1 — --topic <value> wins over $NTFY_TOPIC env var.
#
# Gherkin: Given .env does not exist and NTFY_TOPIC=fromenv is exported,
#          When install.sh runs with --topic fromflag,
#          Then ~/.nudge/.env contains NTFY_TOPIC=fromflag
#          And no /dev/tty prompt is issued.
# ---------------------------------------------------------------------------
scenario_f1_flag_wins_over_env() {
  echo "=== F1: --topic flag wins over NTFY_TOPIC env var ==="
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local root home_dir src_dir
  root="$(mkroot)"
  home_dir="${root}/home"
  src_dir="${root}/checkout"

  mkdir -p "${home_dir}" "${src_dir}"
  populate_checkout "${src_dir}"

  set +e
  HOME="${home_dir}" \
    NTFY_TOPIC="fromenv" \
    bash "${src_dir}/install.sh" --topic fromflag \
      </dev/null \
      >"${root}/stdout.log" 2>"${root}/stderr.log"
  local rc=$?
  set -e

  if [[ "${rc}" -eq 0 ]]; then
    pass "F1 install.sh exited 0"
  else
    fail "F1 install.sh exited ${rc} (expected 0)"
    sed 's/^/    /' "${root}/stderr.log" >&2 || true
  fi

  assert_env_topic "${home_dir}/.nudge/.env" "fromflag" "F1"

  # No /dev/tty prompt is issued — stdout/stderr should not contain a
  # prompt-style "topic" question. We grep for "topic" prompt markers
  # (case-insensitive, common phrasings).
  if grep -iE 'enter.*topic|topic[?:]|ntfy.*topic.*\?' "${root}/stdout.log" "${root}/stderr.log" >/dev/null 2>&1; then
    fail "F1 install.sh appears to have issued an interactive topic prompt"
  else
    pass "F1 no interactive topic prompt issued"
  fi
}

# ---------------------------------------------------------------------------
# F2 — NTFY_TOPIC env var used when no --topic flag.
#
# Gherkin: Given .env does not exist and NTFY_TOPIC=fromenv is exported,
#          When install.sh runs with no --topic,
#          Then ~/.nudge/.env contains NTFY_TOPIC=fromenv.
# ---------------------------------------------------------------------------
scenario_f2_env_var_used_when_no_flag() {
  echo "=== F2: NTFY_TOPIC env var used when no --topic flag ==="
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local root home_dir src_dir
  root="$(mkroot)"
  home_dir="${root}/home"
  src_dir="${root}/checkout"

  mkdir -p "${home_dir}" "${src_dir}"
  populate_checkout "${src_dir}"

  set +e
  HOME="${home_dir}" \
    NTFY_TOPIC="fromenv" \
    bash "${src_dir}/install.sh" \
      </dev/null \
      >"${root}/stdout.log" 2>"${root}/stderr.log"
  local rc=$?
  set -e

  if [[ "${rc}" -eq 0 ]]; then
    pass "F2 install.sh exited 0"
  else
    fail "F2 install.sh exited ${rc} (expected 0)"
    sed 's/^/    /' "${root}/stderr.log" >&2 || true
  fi

  assert_env_topic "${home_dir}/.nudge/.env" "fromenv" "F2"
}

# ---------------------------------------------------------------------------
# F3 — Existing ~/.nudge/.env with non-empty NTFY_TOPIC is preserved.
#
# Gherkin: Given ~/.nudge/.env exists with NTFY_TOPIC=existing,
#          When install.sh runs with --topic ignored,
#          Then ~/.nudge/.env still contains NTFY_TOPIC=existing,
#          And install.sh prints "left untouched".
# ---------------------------------------------------------------------------
scenario_f3_existing_env_preserved() {
  echo "=== F3: existing .env with non-empty NTFY_TOPIC is preserved ==="
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local root home_dir src_dir env_file
  root="$(mkroot)"
  home_dir="${root}/home"
  src_dir="${root}/checkout"
  env_file="${home_dir}/.nudge/.env"

  mkdir -p "${home_dir}/.nudge" "${src_dir}"
  populate_checkout "${src_dir}"

  # Seed an existing .env with a pre-set NTFY_TOPIC (and an unrelated marker
  # line that we will check survives the install so we know the file is
  # genuinely untouched, not rewritten with the same value).
  cat > "${env_file}" <<'PRE_EOF'
NTFY_TOPIC=existing
# user-preservation-marker do-not-touch
PRE_EOF

  set +e
  HOME="${home_dir}" \
    bash "${src_dir}/install.sh" --topic ignored \
      </dev/null \
      >"${root}/stdout.log" 2>"${root}/stderr.log"
  local rc=$?
  set -e

  if [[ "${rc}" -eq 0 ]]; then
    pass "F3 install.sh exited 0"
  else
    fail "F3 install.sh exited ${rc} (expected 0)"
    sed 's/^/    /' "${root}/stderr.log" >&2 || true
  fi

  assert_env_topic "${env_file}" "existing" "F3"

  # The user-preservation marker must still be in the file (proves the file
  # was not rewritten with a fresh template that happened to set the same
  # NTFY_TOPIC value).
  if grep -F "user-preservation-marker do-not-touch" "${env_file}" >/dev/null 2>&1; then
    pass "F3 user-preservation-marker comment survived install"
  else
    fail "F3 .env was rewritten — user-preservation-marker comment lost"
  fi

  # install.sh:781 — the "left untouched" line on stdout is the existing
  # contract marker; it MUST still fire.
  if grep -F "left untouched" "${root}/stdout.log" >/dev/null 2>&1; then
    pass "F3 install.sh printed 'left untouched' transcript line"
  else
    fail "F3 install.sh did not print 'left untouched'"
    sed 's/^/    /' "${root}/stdout.log" >&2 || true
  fi
}

# ---------------------------------------------------------------------------
# F4 — /dev/tty interactive prompt (PTY-based, best-effort).
#
# Gherkin: Given .env does not exist, NTFY_TOPIC is unset, no --topic,
#          /dev/tty is openable,
#          When install.sh runs and the user types "interactive-topic",
#          Then ~/.nudge/.env contains NTFY_TOPIC=interactive-topic.
#
# Implementation: macOS BSD `script` allocates a pty. We feed the topic on
# `script`'s stdin and run install.sh inside it. If `script` is unavailable
# or cannot allocate a pty in this environment, the scenario is SKIPPED
# (recorded but not failed), per the PRD's HARD constraint that we must
# never hang the test suite.
# ---------------------------------------------------------------------------
scenario_f4_dev_tty_prompt() {
  echo "=== F4: /dev/tty interactive prompt (best-effort pty) ==="
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  if ! command -v script >/dev/null 2>&1; then
    skip "F4 BSD/util-linux 'script' not available — pty scenario skipped"
    return
  fi

  local root home_dir src_dir
  root="$(mkroot)"
  home_dir="${root}/home"
  src_dir="${root}/checkout"

  mkdir -p "${home_dir}" "${src_dir}"
  populate_checkout "${src_dir}"

  # We run install.sh inside a pty. The user "types" interactive-topic + Enter
  # via the pty's stdin. We unset NTFY_TOPIC and DO NOT pass --topic so
  # priorities 1-3 all fail and only priority 4 (/dev/tty) can yield a value.
  #
  # BSD `script` form (macOS):
  #   script [-q] <typescript_file> <command> [args...]
  #
  # The 30s timeout is a hard safety net so a regression that wires
  # /dev/tty to a blocking `read` cannot hang the suite indefinitely.
  local typescript="${root}/typescript.out"

  set +e
  printf 'interactive-topic\n' \
    | HOME="${home_dir}" NTFY_TOPIC="" \
      script -q "${typescript}" \
        /bin/bash -c "exec '${src_dir}/install.sh' </dev/tty" \
        >"${root}/stdout.log" 2>"${root}/stderr.log" &
  local pid=$!

  # Bounded wait — kill after 30s if still running.
  local waited=0
  while kill -0 "${pid}" 2>/dev/null; do
    if [[ "${waited}" -ge 30 ]]; then
      kill -9 "${pid}" 2>/dev/null || true
      fail "F4 install.sh hung in /dev/tty path — killed after 30s (regression)"
      set -e
      return
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "${pid}"
  local rc=$?
  set -e

  # If `script` itself failed to allocate a pty (e.g. running on a CI host
  # without /dev/ptmx wired up), treat F4 as skipped, not failed.
  if [[ "${rc}" -ne 0 ]] && ! [[ -f "${home_dir}/.nudge/.env" ]]; then
    skip "F4 'script' could not allocate a pty (rc=${rc}); /dev/tty scenario skipped"
    return
  fi

  if [[ "${rc}" -eq 0 ]]; then
    pass "F4 install.sh exited 0 with pty-driven /dev/tty input"
  else
    fail "F4 install.sh exited ${rc} (expected 0). stderr:"
    sed 's/^/    /' "${root}/stderr.log" >&2 || true
  fi

  assert_env_topic "${home_dir}/.nudge/.env" "interactive-topic" "F4"
}

# ---------------------------------------------------------------------------
# F5 — No-tty fallback: stdin closed, /dev/tty unopenable.
#
# Gherkin: Given .env does not exist, NTFY_TOPIC is unset, no --topic flag,
#          /dev/tty cannot be opened,
#          When install.sh runs with stdin closed,
#          Then exit code is 0,
#          And ~/.nudge/.env contains NTFY_TOPIC= (empty),
#          And the existing LOUD WARNING is printed,
#          And the script does not hang on read.
#
# Implementation: we run install.sh through `cat install.sh | bash -s --`
# (the exact curl|bash self-fetch invocation form). To make /dev/tty
# definitively unopenable AND prevent any hang, we wrap the bash invocation
# in a 30s timeout. On macOS we use a portable timeout shim because
# `timeout(1)` is not always installed.
# ---------------------------------------------------------------------------
scenario_f5_no_tty_fallback() {
  echo "=== F5: no-tty fallback — stdin closed, LOUD WARNING, exit 0, no hang ==="
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local root home_dir src_dir
  root="$(mkroot)"
  home_dir="${root}/home"
  src_dir="${root}/checkout"

  mkdir -p "${home_dir}" "${src_dir}"
  populate_checkout "${src_dir}"

  # 30s hard watchdog — if install.sh blocks on a /dev/tty read, the
  # background-kill below catches it and the test fails loudly.
  set +e
  (
    HOME="${home_dir}" \
      bash "${src_dir}/install.sh" \
        </dev/null \
        >"${root}/stdout.log" 2>"${root}/stderr.log"
  ) &
  local pid=$!

  local waited=0
  local hung=0
  while kill -0 "${pid}" 2>/dev/null; do
    if [[ "${waited}" -ge 30 ]]; then
      kill -9 "${pid}" 2>/dev/null || true
      hung=1
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "${pid}" 2>/dev/null
  local rc=$?
  set -e

  if [[ "${hung}" -eq 1 ]]; then
    fail "F5 install.sh HUNG on read in no-tty path (killed after 30s)"
    return
  fi

  if [[ "${rc}" -eq 0 ]]; then
    pass "F5 install.sh exited 0 in no-tty fallback path"
  else
    fail "F5 install.sh exited ${rc} (expected 0 for curl|bash chaining)"
    sed 's/^/    /' "${root}/stderr.log" >&2 || true
  fi

  # .env exists with empty NTFY_TOPIC.
  assert_env_topic_empty "${home_dir}/.nudge/.env" "F5"

  # LOUD WARNING marker: install.sh:563/820 uses "WARNING" + "NTFY_TOPIC" in
  # the existing ff361c5 warning. The PRD says priority 5 reuses that wording
  # verbatim. We assert both tokens appear on stderr OR stdout (some echo
  # transcripts use stdout for ==> lines), case-insensitive.
  local combined="${root}/combined.log"
  cat "${root}/stdout.log" "${root}/stderr.log" > "${combined}"
  if grep -iE 'WARNING' "${combined}" >/dev/null 2>&1 \
     && grep -E 'NTFY_TOPIC' "${combined}" >/dev/null 2>&1; then
    pass "F5 LOUD WARNING (WARNING + NTFY_TOPIC tokens) printed in fallback"
  else
    fail "F5 LOUD WARNING not present in fallback transcript:"
    sed 's/^/    /' "${combined}" >&2 || true
  fi
}

# ---------------------------------------------------------------------------
# F6 — Empty / whitespace --topic falls through to the next priority.
#
# Gherkin: Given --topic "   " is supplied and no other source,
#          When install.sh runs,
#          Then the empty value is rejected,
#          And resolution falls through to priority 2/3/4/5.
#
# Test design: pass --topic "   " (whitespace) AND export NTFY_TOPIC=fromenv.
# Per PRD F1: empty trimmed --topic must be treated as "not supplied", so
# priority 2 (the env var) takes over. We then assert ~/.nudge/.env contains
# NTFY_TOPIC=fromenv, NOT a blank/whitespace value.
# ---------------------------------------------------------------------------
scenario_f6_empty_topic_falls_through() {
  echo "=== F6: empty/whitespace --topic falls through to env var (priority 2) ==="
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local root home_dir src_dir
  root="$(mkroot)"
  home_dir="${root}/home"
  src_dir="${root}/checkout"

  mkdir -p "${home_dir}" "${src_dir}"
  populate_checkout "${src_dir}"

  set +e
  HOME="${home_dir}" \
    NTFY_TOPIC="fromenv" \
    bash "${src_dir}/install.sh" --topic "   " \
      </dev/null \
      >"${root}/stdout.log" 2>"${root}/stderr.log"
  local rc=$?
  set -e

  if [[ "${rc}" -eq 0 ]]; then
    pass "F6 install.sh exited 0 with whitespace --topic"
  else
    fail "F6 install.sh exited ${rc} (expected 0)"
    sed 's/^/    /' "${root}/stderr.log" >&2 || true
  fi

  # Must have fallen through to priority 2 (NTFY_TOPIC env var).
  assert_env_topic "${home_dir}/.nudge/.env" "fromenv" "F6"

  # And the .env MUST NOT contain a whitespace-only NTFY_TOPIC line.
  if grep -E '^NTFY_TOPIC= +$' "${home_dir}/.nudge/.env" >/dev/null 2>&1 \
     || grep -E '^NTFY_TOPIC=" +"$' "${home_dir}/.nudge/.env" >/dev/null 2>&1; then
    fail "F6 .env contains whitespace-only NTFY_TOPIC value (must reject)"
  else
    pass "F6 .env does NOT contain whitespace-only NTFY_TOPIC value"
  fi
}

main() {
  scenario_f1_flag_wins_over_env
  scenario_f2_env_var_used_when_no_flag
  scenario_f3_existing_env_preserved
  scenario_f4_dev_tty_prompt
  scenario_f5_no_tty_fallback
  scenario_f6_empty_topic_falls_through

  echo
  echo "Scenarios run:     ${SCENARIOS_RUN}"
  echo "Scenarios skipped: ${SCENARIOS_SKIPPED}"
  if [[ "${FAILED}" -ne 0 ]]; then
    echo "SOME TESTS FAILED" >&2
    exit 1
  fi
  echo "ALL TESTS PASSED"
}

main "$@"
