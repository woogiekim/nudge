#!/usr/bin/env bash
# TDD tests for install.sh wire_codex_settings() TOML validity.
#
# Spec: handoff.md (fix-toml-escaping task)
#   The four emission sites in wire_codex_settings() must each produce output
#   that parses as valid TOML and yields the canonical `notify` array:
#     ["bash", "-c", "( nohup <wrapper_path> \"$1\" >/dev/null 2>&1 & )", "--"]
#
# Sites under test (install.sh:237-323):
#   1. echo path  (line 257) — fresh config (config.toml absent)
#   2. awk path   (lines 283-296) — insert-before-[section]
#   3. printf path (line 299) — append-to-EOF (no [section] header)
#   4. echo manual snippet (line 319) — non-nudge notify already present
#
# Red-state expectation (current main): the awk path corrupts the TOML
# because `awk -v notify="..."` performs C-style escape interpretation on
# the value, turning `\"$1\"` into bare `"$1"` and breaking the string
# literal that wraps the bash -c command. Scenarios 2 (and the manual
# snippet in scenario 4) must FAIL on red; all four must PASS on green.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
FIXTURES="${REPO_ROOT}/tests/_fixtures"

FAILED=0
SCENARIOS_RUN=0
TMP_DIRS=()

cleanup() {
  local d
  for d in "${TMP_DIRS[@]:-}"; do
    [[ -n "${d:-}" && -d "${d}" ]] && rm -rf "${d}"
  done
  return 0
}
trap cleanup EXIT

pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*" >&2; FAILED=1; }

# python3 + tomllib precondition. Python 3.11+ ships tomllib in the stdlib.
require_tomllib() {
  if ! python3 -c "import tomllib" >/dev/null 2>&1; then
    echo "SKIP: python3 with tomllib (3.11+) not available — cannot verify TOML validity"
    exit 0
  fi
}

make_fixture_home() {
  local d
  d="$(mktemp -d -t nudge-toml-valid-XXXXXX)"
  TMP_DIRS+=("${d}")
  mkdir -p "${d}/.codex"
  printf '%s' "${d}"
}

# parse_toml_notify <toml_file> <wrapper_path> <ctx_label>
#
# Parses the TOML file with python3 tomllib and asserts that the resulting
# `notify` array equals the canonical value:
#   ["bash", "-c", "( nohup <wrapper_path> \"$1\" >/dev/null 2>&1 & )", "--"]
#
# The TOML inner string element may be encoded as either a basic string
# (with \" escapes) or a literal string ('...'); both decode to the same
# Python value, so this assertion is encoding-agnostic.
parse_toml_notify() {
  local toml_file="$1"
  local wrapper_path="$2"
  local ctx="$3"
  local rc

  python3 - "${toml_file}" "${wrapper_path}" <<'PY'
import sys, tomllib

toml_path = sys.argv[1]
wrapper_path = sys.argv[2]

with open(toml_path, "rb") as fh:
    try:
        cfg = tomllib.load(fh)
    except tomllib.TOMLDecodeError as exc:
        sys.stderr.write(f"PARSE_ERROR: {exc}\n")
        with open(toml_path, "r") as fh2:
            sys.stderr.write("---- file contents ----\n")
            sys.stderr.write(fh2.read())
            sys.stderr.write("---- end ----\n")
        sys.exit(2)

expected = [
    "bash",
    "-c",
    f'( nohup {wrapper_path} "$1" >/dev/null 2>&1 & )',
    "--",
]
got = cfg.get("notify")
if got != expected:
    sys.stderr.write(f"NOTIFY_MISMATCH:\n  expected: {expected!r}\n  got:      {got!r}\n")
    sys.exit(3)

sys.exit(0)
PY
  rc=$?

  if [[ "${rc}" -eq 0 ]]; then
    pass "${ctx}: TOML parses and notify array matches expected canonical value"
    return 0
  elif [[ "${rc}" -eq 2 ]]; then
    fail "${ctx}: TOML failed to parse"
    return 1
  elif [[ "${rc}" -eq 3 ]]; then
    fail "${ctx}: TOML parsed but notify array != canonical value"
    return 1
  else
    fail "${ctx}: unexpected python3 exit code ${rc}"
    return 1
  fi
}

# parse_toml_string <toml_string> <wrapper_path> <ctx_label>
#
# Same as parse_toml_notify but accepts the TOML content via stdin instead
# of a file path. Used for the manual-snippet scenario where we need to
# parse a single emitted line.
parse_toml_string() {
  local toml_content="$1"
  local wrapper_path="$2"
  local ctx="$3"
  local tmp rc

  tmp="$(mktemp -t nudge-toml-parse-XXXXXX)"
  printf '%s\n' "${toml_content}" > "${tmp}"
  parse_toml_notify "${tmp}" "${wrapper_path}" "${ctx}"
  rc=$?
  rm -f "${tmp}"
  return ${rc}
}

run_install() {
  local home_dir="$1"
  shift || true
  local fixture_file="${home_dir}/.codex/config.toml"
  HOME="${home_dir}" \
  NUDGE_CODEX_CONFIG="${fixture_file}" \
    bash "${INSTALL_SH}" --wire-codex "$@"
}

# Wrapper path that wire_codex_settings will embed. It is derived from HOME,
# so every scenario must compute it from the test's mktemp HOME — never
# from the real user HOME.
wrapper_path_for_home() {
  printf '%s/.nudge/notify-codex.sh' "$1"
}

# ---------------------------------------------------------------------------
# Scenario 1 — fresh-config echo path (install.sh:257)
#   Trigger: config.toml does NOT exist. wire_codex_settings creates one with
#     `echo "# ..."; echo "${notify_line}"` → fresh file.
#   Expectation: file parses, notify array matches canonical value.
# ---------------------------------------------------------------------------
scenario_fresh_echo_path() {
  echo "[toml:1] echo path (fresh config) → produces valid TOML"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local home fixture_file wrapper
  home="$(make_fixture_home)"
  fixture_file="${home}/.codex/config.toml"
  wrapper="$(wrapper_path_for_home "${home}")"

  # Precondition: no fixture file.
  if [[ -e "${fixture_file}" ]]; then
    fail "precondition: ${fixture_file} should not exist"
    return
  fi

  run_install "${home}" >/dev/null 2>&1 || {
    fail "install.sh --wire-codex exited non-zero on fresh-config path"
    return
  }

  if [[ ! -f "${fixture_file}" ]]; then
    fail "fresh-config path did not create ${fixture_file}"
    return
  fi

  parse_toml_notify "${fixture_file}" "${wrapper}" "scenario 1 (echo / fresh)"
}

# ---------------------------------------------------------------------------
# Scenario 2 — insert-before-[section] awk path (install.sh:283-296)
#   Trigger: config.toml exists WITH a [section] header and NO notify key.
#   This is the path that is corrupted on red (awk -v escape interpretation
#   destroys the basic-string quoting around `"$1"`).
# ---------------------------------------------------------------------------
scenario_awk_insert_before_section() {
  echo "[toml:2] awk path (insert-before-[section]) → produces valid TOML"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local home fixture_file wrapper
  home="$(make_fixture_home)"
  fixture_file="${home}/.codex/config.toml"
  wrapper="$(wrapper_path_for_home "${home}")"

  # Fixture has [model] and [tui] sections, no notify key. Triggers awk path.
  cp "${FIXTURES}/codex-config-no-notify.toml" "${fixture_file}"

  run_install "${home}" >/dev/null 2>&1 || {
    fail "install.sh --wire-codex exited non-zero on awk path"
    return
  }

  parse_toml_notify "${fixture_file}" "${wrapper}" "scenario 2 (awk / insert-before-section)"
}

# ---------------------------------------------------------------------------
# Scenario 3 — append-to-EOF printf path (install.sh:299)
#   Trigger: config.toml exists with NO [section] header AND NO notify key.
#   The grep `^[[:space:]]*\[` check fails, so wire_codex falls through to
#   the printf '\n%s\n' append-to-EOF branch.
# ---------------------------------------------------------------------------
scenario_printf_append_eof() {
  echo "[toml:3] printf path (append-to-EOF, no [section]) → produces valid TOML"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local home fixture_file wrapper
  home="$(make_fixture_home)"
  fixture_file="${home}/.codex/config.toml"
  wrapper="$(wrapper_path_for_home "${home}")"

  # Fixture: a comment-only file with no [section] header and no notify key.
  # This forces wire_codex onto the printf '\n%s\n' append branch.
  cat > "${fixture_file}" <<'TOML_EOF'
# Pre-existing user config with no [section] header and no notify key.
# Just a top-level comment so wire_codex_settings takes the printf-append branch.
TOML_EOF

  run_install "${home}" >/dev/null 2>&1 || {
    fail "install.sh --wire-codex exited non-zero on printf path"
    return
  }

  parse_toml_notify "${fixture_file}" "${wrapper}" "scenario 3 (printf / append-EOF)"
}

# ---------------------------------------------------------------------------
# Scenario 4 — manual snippet echo path (install.sh:319)
#   Trigger: config.toml exists with a non-nudge `notify =` value already
#   present. wire_codex REFUSES to overwrite, leaves the file untouched, and
#   echoes the manual snippet to stdout for the user to paste.
#
#   The printed snippet, taken in isolation as a TOML document, must itself
#   parse and yield the canonical notify value.
# ---------------------------------------------------------------------------
scenario_manual_snippet_echo() {
  echo "[toml:4] echo path (manual snippet on clobber refusal) → printed snippet is valid TOML"
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local home fixture_file wrapper out manual_line
  home="$(make_fixture_home)"
  fixture_file="${home}/.codex/config.toml"
  wrapper="$(wrapper_path_for_home "${home}")"

  cp "${FIXTURES}/codex-config-existing-notify.toml" "${fixture_file}"

  set +e
  out="$(run_install "${home}" 2>&1)"
  local exit_code=$?
  set -e

  if [[ "${exit_code}" -ne 0 ]]; then
    fail "install.sh --wire-codex exited non-zero on clobber-refusal path (${exit_code})"
    return
  fi

  # Extract the single printed manual notify line. The guidance format prefixes
  # the snippet with whitespace (see install.sh:319 — `echo "    ${manual_snippet}"`).
  manual_line="$(grep -E '^[[:space:]]*notify[[:space:]]*=' <<<"${out}" | head -n1 | sed -E 's/^[[:space:]]+//')"
  if [[ -z "${manual_line}" ]]; then
    fail "could not extract printed manual notify line from guidance output"
    echo "----- output -----" >&2; echo "${out}" >&2; echo "------------------" >&2
    return
  fi

  parse_toml_string "${manual_line}" "${wrapper}" "scenario 4 (echo / manual snippet)"
}

# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------
main() {
  require_tomllib

  if [[ ! -f "${INSTALL_SH}" ]]; then
    echo "FATAL: install.sh not found at ${INSTALL_SH}" >&2
    exit 2
  fi

  scenario_fresh_echo_path
  scenario_awk_insert_before_section
  scenario_printf_append_eof
  scenario_manual_snippet_echo

  echo
  echo "Scenarios run: ${SCENARIOS_RUN}"
  if [[ ${FAILED} -ne 0 ]]; then
    echo "RESULT: one or more scenarios FAILED" >&2
    exit 1
  fi
  echo "ALL TESTS PASSED"
}

main "$@"
