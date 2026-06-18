#!/usr/bin/env bash
# Spec: prd.md § F1-F5 + F10 + Acceptance Criteria
#   (install.sh self-fetch — no-clone curl|bash install)
#
# Verifies the three contract scenarios from PRD F10:
#   (a) Siblings PRESENT     — local-checkout path is byte-for-byte unchanged.
#                              No fetcher is invoked. Installed files match
#                              the local sources.
#   (b) Siblings ABSENT      — self-fetch mode: NUDGE_FETCH_CMD stub is invoked
#                              exactly 8 times (7 .sh + .env.example); each URL
#                              starts with ${NUDGE_RAW_BASE_URL}/; all 7 scripts
#                              land in INSTALL_DIR and are chmod +x.
#   (c) Failed download      — stub exits non-zero (or writes empty) for one
#                              specific URL; install.sh exits non-zero and
#                              stderr names the failed URL/file.
#
# Strategy:
#   - HOME is redirected to a tempdir, so INSTALL_DIR=${HOME}/.nudge points
#     into the fixture and never touches the user's real ~/.nudge.
#   - The "checkout-like" source dir is a separate tempdir; install.sh is
#     copied into it (with or without siblings depending on scenario), and
#     invoked as `bash <copy>/install.sh` with NO flags so neither
#     --wire-* nor --setup-receiver-macos fires.
#   - The mock fetcher is generated per scenario into a fixtures tempdir.
#     It records (url, dest) tuples to a calls log and increments a counter
#     file, so the assertions can read both invocation count and per-URL
#     prefix shape without any real network.
#
# Expected to FAIL on the unmodified install.sh (red phase): the script has
# no self-fetch branch, no NUDGE_FETCH_CMD hook, and no fail-loudly check
# on empty downloads. Becomes green once the parallel backend stage lands
# the self-fetch implementation.

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

pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*" >&2; FAILED=1; }

# --- fixture helpers --------------------------------------------------------

# mkroot — creates a fresh tempdir, registers it for cleanup, echoes the path.
mkroot() {
  local d
  d="$(mktemp -d -t nudge-selffetch-XXXXXX)"
  FIXTURE_DIRS+=("${d}")
  printf '%s' "${d}"
}

# The 8 sibling .sh files the install loop copies, plus .env.example.
# Spec: prd.md § F4 — test.sh MUST be part of NUDGE_CORE_SCRIPTS so it
# lands at ~/.nudge/test.sh in both clone and self-fetch installs.
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

# populate_checkout <src_dir>
#   Copies the real install.sh + all 7 sibling scripts + .env.example into
#   <src_dir>, simulating a local git checkout.
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

# populate_lonely_install <src_dir>
#   Copies ONLY install.sh into <src_dir>, simulating the curl|bash flow
#   where ${BASH_SOURCE[0]} has no sibling files next to it.
populate_lonely_install() {
  local src_dir="$1"
  cp "${INSTALL_SH}" "${src_dir}/install.sh"
  chmod +x "${src_dir}/install.sh"
}

# make_fetch_stub <stub_path> <calls_log> <counter_file> [<fail_basename>] [<empty_basename>]
#   Writes a fetch stub at <stub_path> that:
#     - logs every (url, dest) tuple it sees, one tuple per line, to <calls_log>
#     - increments <counter_file> (count == lines in the file)
#     - if <fail_basename> is set AND the URL/dest basename matches it, exits 1
#     - if <empty_basename> is set AND the URL/dest basename matches it,
#       writes a zero-byte file to <dest> and exits 0
#     - otherwise writes deterministic non-empty content to <dest> and exits 0
make_fetch_stub() {
  local stub_path="$1"
  local calls_log="$2"
  local counter_file="$3"
  local fail_basename="${4:-}"
  local empty_basename="${5:-}"

  mkdir -p "$(dirname "${stub_path}")"
  : > "${calls_log}"
  : > "${counter_file}"

  cat > "${stub_path}" <<STUB_EOF
#!/usr/bin/env bash
# Mock fetcher stub. Contract: invoked as "\${cmd} <url> <dest>".
url="\${1:-}"
dest="\${2:-}"
printf '%s\t%s\n' "\${url}" "\${dest}" >> "${calls_log}"
printf '.' >> "${counter_file}"

base_url="\$(basename "\${url}")"
base_dest="\$(basename "\${dest}")"

# Failure-injection arm.
if [[ -n "${fail_basename}" ]]; then
  if [[ "\${base_url}" == "${fail_basename}" || "\${base_dest}" == "${fail_basename}" ]]; then
    echo "mock-fetch: forced failure for \${url}" >&2
    exit 1
  fi
fi

# Empty-file-injection arm (writes 0 bytes; non-empty check should fail).
if [[ -n "${empty_basename}" ]]; then
  if [[ "\${base_url}" == "${empty_basename}" || "\${base_dest}" == "${empty_basename}" ]]; then
    mkdir -p "\$(dirname "\${dest}")"
    : > "\${dest}"
    exit 0
  fi
fi

# Success arm — deterministic non-empty content.
mkdir -p "\$(dirname "\${dest}")"
printf '# nudge mock-fetched %s\n' "\${base_dest}" > "\${dest}"
exit 0
STUB_EOF
  chmod +x "${stub_path}"
}

# counter_value <counter_file>
#   Echoes the count of fetch invocations (one '.' per call).
counter_value() {
  local counter_file="$1"
  if [[ -f "${counter_file}" ]]; then
    # Byte length == number of '.' chars == invocation count.
    local bytes
    bytes="$(wc -c <"${counter_file}" | tr -d '[:space:]')"
    printf '%s' "${bytes:-0}"
  else
    printf '0'
  fi
}

# ---------------------------------------------------------------------------
# Scenario A — siblings PRESENT → install copies locally, fetcher untouched.
# ---------------------------------------------------------------------------
scenario_a_siblings_present_no_fetch() {
  echo "=== Scenario A: siblings PRESENT → no fetch invoked, local copy used ==="
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local root home_dir src_dir stub_dir calls_log counter_file
  root="$(mkroot)"
  home_dir="${root}/home"
  src_dir="${root}/checkout"
  stub_dir="${root}/_stubbin"
  calls_log="${root}/fetch.calls"
  counter_file="${root}/fetch.count"

  mkdir -p "${home_dir}" "${src_dir}" "${stub_dir}"
  populate_checkout "${src_dir}"
  make_fetch_stub "${stub_dir}/mock-fetch" "${calls_log}" "${counter_file}"

  set +e
  HOME="${home_dir}" \
    NUDGE_FETCH_CMD="${stub_dir}/mock-fetch" \
    NUDGE_RAW_BASE_URL="https://example.invalid/base" \
    bash "${src_dir}/install.sh" >"${root}/stdout.log" 2>"${root}/stderr.log"
  local rc=$?
  set -e

  if [[ "${rc}" -eq 0 ]]; then
    pass "A install.sh exited 0 from a populated checkout"
  else
    fail "A install.sh exited ${rc} (expected 0). stderr:"
    sed 's/^/    /' "${root}/stderr.log" >&2 || true
  fi

  local invocations
  invocations="$(counter_value "${counter_file}")"
  if [[ "${invocations}" -eq 0 ]]; then
    pass "A fetch stub was NOT invoked (count=0)"
  else
    fail "A fetch stub was invoked ${invocations} time(s); expected 0"
    sed 's/^/    /' "${calls_log}" >&2 || true
  fi

  # Every sibling script must be installed and match the local source.
  local script
  for script in "${SIBLING_SCRIPTS[@]}"; do
    local installed="${home_dir}/.nudge/${script}"
    if [[ ! -f "${installed}" ]]; then
      fail "A ${script} not installed at ${installed}"
      continue
    fi
    if [[ ! -x "${installed}" ]]; then
      fail "A ${script} installed but not executable (+x)"
    fi
    if cmp -s "${src_dir}/${script}" "${installed}"; then
      pass "A ${script} matches local source byte-for-byte"
    else
      fail "A ${script} content differs from local source"
    fi
  done

  # .env must be created from the local .env.example.
  if [[ -f "${home_dir}/.nudge/.env" ]]; then
    pass "A .env was created from local .env.example"
  else
    fail "A .env was NOT created at ${home_dir}/.nudge/.env"
  fi
}

# ---------------------------------------------------------------------------
# Scenario B — siblings ABSENT → self-fetch invoked exactly 9 times with
# URLs prefixed by NUDGE_RAW_BASE_URL/; all 8 scripts installed and +x.
#
# Spec: prd.md § F4 — test.sh is part of NUDGE_CORE_SCRIPTS, so the count
# becomes 9 (8 .sh + .env.example) and one fetched URL ends in "/test.sh".
# ---------------------------------------------------------------------------
scenario_b_siblings_absent_self_fetch() {
  echo "=== Scenario B: siblings ABSENT → 9 fetches (8 scripts + .env.example) ==="
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local root home_dir src_dir stub_dir calls_log counter_file
  root="$(mkroot)"
  home_dir="${root}/home"
  src_dir="${root}/curl_bash_only"
  stub_dir="${root}/_stubbin"
  calls_log="${root}/fetch.calls"
  counter_file="${root}/fetch.count"

  mkdir -p "${home_dir}" "${src_dir}" "${stub_dir}"
  populate_lonely_install "${src_dir}"
  make_fetch_stub "${stub_dir}/mock-fetch" "${calls_log}" "${counter_file}"

  local base_url="https://example.invalid/base"

  set +e
  HOME="${home_dir}" \
    NUDGE_FETCH_CMD="${stub_dir}/mock-fetch" \
    NUDGE_RAW_BASE_URL="${base_url}" \
    bash "${src_dir}/install.sh" >"${root}/stdout.log" 2>"${root}/stderr.log"
  local rc=$?
  set -e

  if [[ "${rc}" -eq 0 ]]; then
    pass "B install.sh exited 0 in self-fetch mode"
  else
    fail "B install.sh exited ${rc} (expected 0). stderr:"
    sed 's/^/    /' "${root}/stderr.log" >&2 || true
    sed 's/^/    /' "${root}/stdout.log" >&2 || true
  fi

  local invocations
  invocations="$(counter_value "${counter_file}")"
  if [[ "${invocations}" -eq 9 ]]; then
    pass "B fetch stub invoked exactly 9 times (8 scripts + .env.example)"
  else
    fail "B fetch stub invoked ${invocations} time(s); expected 9"
    if [[ -f "${calls_log}" ]]; then
      echo "    --- recorded fetch calls ---" >&2
      sed 's/^/    /' "${calls_log}" >&2
      echo "    ----------------------------" >&2
    fi
  fi

  # Every recorded URL must start with the configured base URL + '/'.
  local prefix="${base_url}/"
  local bad_prefix=0
  if [[ -s "${calls_log}" ]]; then
    while IFS=$'\t' read -r url _dest; do
      if [[ "${url}" != "${prefix}"* ]]; then
        bad_prefix=$((bad_prefix + 1))
        echo "    URL not prefixed by ${prefix}: ${url}" >&2
      fi
    done < "${calls_log}"
  fi
  if [[ "${bad_prefix}" -eq 0 ]]; then
    pass "B every fetched URL starts with '${prefix}'"
  else
    fail "B ${bad_prefix} URL(s) did not start with '${prefix}'"
  fi

  # Spec: prd.md § F4 — exactly one of the fetched URLs must end in "/test.sh"
  # so that ${INSTALL_DIR}/test.sh lands in self-fetch (no-clone) installs.
  local test_sh_url_hits
  test_sh_url_hits="$(grep -c -F -- "${prefix}test.sh"$'\t' "${calls_log}" 2>/dev/null || true)"
  if [[ "${test_sh_url_hits}" -eq 1 ]]; then
    pass "B URL ${prefix}test.sh fetched exactly once"
  else
    fail "B URL ${prefix}test.sh fetched ${test_sh_url_hits} time(s); expected 1"
    if [[ -f "${calls_log}" ]]; then
      echo "    --- recorded fetch calls ---" >&2
      sed 's/^/    /' "${calls_log}" >&2
      echo "    ----------------------------" >&2
    fi
  fi

  # Spec: prd.md § F4 — ${INSTALL_DIR}/test.sh must exist, be a regular file,
  # and be executable after the self-fetch install completes.
  local installed_test_sh="${home_dir}/.nudge/test.sh"
  if [[ -f "${installed_test_sh}" ]]; then
    pass "B test.sh installed at ${installed_test_sh}"
    if [[ -x "${installed_test_sh}" ]]; then
      pass "B test.sh installed and executable (+x)"
    else
      fail "B test.sh installed but NOT executable (+x)"
    fi
  else
    fail "B test.sh NOT installed at ${installed_test_sh}"
  fi

  # Each of the 8 sibling .sh files must appear (once) among the URLs.
  local missing_urls=0 script
  for script in "${SIBLING_SCRIPTS[@]}"; do
    local hits
    hits="$(grep -c -F -- "${prefix}${script}"$'\t' "${calls_log}" 2>/dev/null || true)"
    if [[ "${hits}" -ne 1 ]]; then
      fail "B URL ${prefix}${script} appears ${hits} time(s); expected 1"
      missing_urls=$((missing_urls + 1))
    fi
  done
  if [[ "${missing_urls}" -eq 0 ]]; then
    pass "B every sibling script URL was fetched exactly once"
  fi

  # The .env.example URL must also have been fetched (once).
  local env_hits
  env_hits="$(grep -c -F -- "${prefix}.env.example"$'\t' "${calls_log}" 2>/dev/null || true)"
  if [[ "${env_hits}" -eq 1 ]]; then
    pass "B .env.example URL fetched exactly once"
  else
    fail "B .env.example URL fetched ${env_hits} time(s); expected 1"
  fi

  # Every fetched script must land in INSTALL_DIR and be +x.
  for script in "${SIBLING_SCRIPTS[@]}"; do
    local installed="${home_dir}/.nudge/${script}"
    if [[ -f "${installed}" && -x "${installed}" ]]; then
      pass "B ${script} installed and executable"
    elif [[ -f "${installed}" ]]; then
      fail "B ${script} installed but not executable (+x)"
    else
      fail "B ${script} not installed at ${installed}"
    fi
  done

  # .env must exist (created from the fetched .env.example).
  if [[ -f "${home_dir}/.nudge/.env" ]]; then
    pass "B .env was created from fetched .env.example"
  else
    fail "B .env was NOT created at ${home_dir}/.nudge/.env"
  fi
}

# ---------------------------------------------------------------------------
# Scenario C — failed/empty download → non-zero exit + clear stderr message.
# Two arms:
#   C1. stub exits 1 for notify.sh
#   C2. stub writes a zero-byte file for notify.sh (fetcher rc=0 but empty)
# ---------------------------------------------------------------------------
scenario_c_failed_download_aborts() {
  echo "=== Scenario C1: fetch stub exits 1 for one file → install aborts ==="
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local root home_dir src_dir stub_dir calls_log counter_file
  root="$(mkroot)"
  home_dir="${root}/home"
  src_dir="${root}/curl_bash_only"
  stub_dir="${root}/_stubbin"
  calls_log="${root}/fetch.calls"
  counter_file="${root}/fetch.count"

  mkdir -p "${home_dir}" "${src_dir}" "${stub_dir}"
  populate_lonely_install "${src_dir}"
  make_fetch_stub "${stub_dir}/mock-fetch" "${calls_log}" "${counter_file}" "notify.sh"

  local base_url="https://example.invalid/base"

  set +e
  HOME="${home_dir}" \
    NUDGE_FETCH_CMD="${stub_dir}/mock-fetch" \
    NUDGE_RAW_BASE_URL="${base_url}" \
    bash "${src_dir}/install.sh" >"${root}/stdout.log" 2>"${root}/stderr.log"
  local rc=$?
  set -e

  if [[ "${rc}" -ne 0 ]]; then
    pass "C1 install.sh exited non-zero (rc=${rc}) on fetch failure"
  else
    fail "C1 install.sh exited 0 despite fetch failure — should have aborted"
  fi

  # The stderr must name the failed file or URL so the user knows what broke.
  if grep -F -- "notify.sh" "${root}/stderr.log" >/dev/null 2>&1; then
    pass "C1 stderr names the failed file ('notify.sh')"
  else
    fail "C1 stderr does not name the failed file:"
    sed 's/^/    /' "${root}/stderr.log" >&2 || true
  fi

  echo "=== Scenario C2: fetch stub writes 0-byte file → install aborts ==="
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))

  local root2 home_dir2 src_dir2 stub_dir2 calls_log2 counter_file2
  root2="$(mkroot)"
  home_dir2="${root2}/home"
  src_dir2="${root2}/curl_bash_only"
  stub_dir2="${root2}/_stubbin"
  calls_log2="${root2}/fetch.calls"
  counter_file2="${root2}/fetch.count"

  mkdir -p "${home_dir2}" "${src_dir2}" "${stub_dir2}"
  populate_lonely_install "${src_dir2}"
  make_fetch_stub "${stub_dir2}/mock-fetch" "${calls_log2}" "${counter_file2}" "" "notify.sh"

  set +e
  HOME="${home_dir2}" \
    NUDGE_FETCH_CMD="${stub_dir2}/mock-fetch" \
    NUDGE_RAW_BASE_URL="${base_url}" \
    bash "${src_dir2}/install.sh" >"${root2}/stdout.log" 2>"${root2}/stderr.log"
  local rc2=$?
  set -e

  if [[ "${rc2}" -ne 0 ]]; then
    pass "C2 install.sh exited non-zero (rc=${rc2}) on empty download"
  else
    fail "C2 install.sh exited 0 despite empty (0-byte) download — should have aborted"
  fi

  if grep -F -- "notify.sh" "${root2}/stderr.log" >/dev/null 2>&1; then
    pass "C2 stderr names the empty-downloaded file ('notify.sh')"
  else
    fail "C2 stderr does not name the empty-downloaded file:"
    sed 's/^/    /' "${root2}/stderr.log" >&2 || true
  fi
}

main() {
  scenario_a_siblings_present_no_fetch
  scenario_b_siblings_absent_self_fetch
  scenario_c_failed_download_aborts

  echo
  echo "Scenarios run: ${SCENARIOS_RUN}"
  if [[ "${FAILED}" -ne 0 ]]; then
    echo "SOME TESTS FAILED" >&2
    exit 1
  fi
  echo "ALL TESTS PASSED"
}

main "$@"
