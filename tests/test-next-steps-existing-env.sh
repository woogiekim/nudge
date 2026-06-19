#!/usr/bin/env bash
# Spec: prd.md § AC1 — Next-steps step 1 wording when TOPIC_SOURCE=existing-env.
#
# When ~/.nudge/.env already exists with a non-empty NTFY_TOPIC, install.sh
# resolves TOPIC_SOURCE="existing-env" (install.sh:881). The current
# Next-steps case block (install.sh:1006-1013) does NOT list existing-env,
# so step 1 falls through to "Edit ${INSTALL_DIR}/.env and set a unique
# NTFY_TOPIC" — that is the bug.
#
# After the backend fix, step 1 must read:
#   ✓ NTFY_TOPIC already set in ${INSTALL_DIR}/.env (existing config)
#
# This test is the RED-phase assertion driving the parallel backend stage.
# It will FAIL on unmodified install.sh and PASS once the new existing-env
# branch lands in the case block.
#
# Strategy mirrors tests/test-topic-resolution.sh:
#   - HOME redirected to a per-scenario tempdir, so INSTALL_DIR=${HOME}/.nudge
#     never touches the user's real ~/.nudge.
#   - install.sh is invoked in clone-mode with the local checkout's siblings
#     present (self-fetch path stays out of scope here — we only care about
#     the Next-steps transcript wording).
#   - Asserts:
#       AC1.1 install.sh exits 0
#       AC1.2 transcript contains "Next steps:"
#       AC1.3 step 1 contains "✓ NTFY_TOPIC already set in" AND
#             "(existing config)"
#       AC1.4 transcript does NOT match "Edit <...>.nudge/.env" wording on
#             the existing-env path
#       AC1.5 transcript does NOT contain "(from existing-env)" — the new
#             branch supplies its own parenthetical
#       AC4   .env file content is byte-identical to the pre-existing fixture
#             (preserves install.sh:983 "left untouched" contract)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"

FAILED=0

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

mkroot() {
  local d
  d="$(mktemp -d -t nudge-nextsteps-XXXXXX)"
  FIXTURE_DIRS+=("${d}")
  printf '%s' "${d}"
}

# Sibling files install.sh expects in clone-mode (mirrors test-topic-resolution.sh).
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

scenario_existing_env_next_steps_wording() {
  echo "=== AC1: Next-steps step 1 says 'already set ... (existing config)' for existing-env ==="

  local root home_dir src_dir env_file
  root="$(mkroot)"
  home_dir="${root}/home"
  src_dir="${root}/checkout"
  env_file="${home_dir}/.nudge/.env"

  mkdir -p "${home_dir}/.nudge" "${src_dir}"
  populate_checkout "${src_dir}"

  # Seed an existing .env with a non-empty NTFY_TOPIC. The resolver at
  # install.sh:877-884 will hit this and set TOPIC_SOURCE=existing-env.
  cat > "${env_file}" <<'PRE_EOF'
NTFY_TOPIC=existing-topic-abc123
# preservation-marker-existing-env-next-steps
PRE_EOF

  # Snapshot the pre-existing file content so we can assert "left untouched"
  # after install.sh runs (AC4).
  local env_pre_snapshot
  env_pre_snapshot="$(cat "${env_file}")"

  set +e
  HOME="${home_dir}" \
    bash "${src_dir}/install.sh" \
      </dev/null \
      >"${root}/stdout.log" 2>"${root}/stderr.log"
  local rc=$?
  set -e

  # AC1.1 — install.sh exits 0.
  if [[ "${rc}" -eq 0 ]]; then
    pass "install.sh exited 0 with pre-existing .env"
  else
    fail "install.sh exited ${rc} (expected 0)"
    echo "    --- stderr ---" >&2
    sed 's/^/    /' "${root}/stderr.log" >&2 || true
    echo "    --------------" >&2
  fi

  # Combine streams — Next steps: block lives on stdout but we want any
  # diagnostic that might also have reached stderr in the assertion window.
  local combined="${root}/combined.log"
  cat "${root}/stdout.log" "${root}/stderr.log" > "${combined}"

  # AC1.2 — "Next steps:" header is present (happy path reached).
  if grep -F "Next steps:" "${combined}" >/dev/null 2>&1; then
    pass "transcript contains 'Next steps:' header"
  else
    fail "transcript missing 'Next steps:' header"
    sed 's/^/    /' "${combined}" >&2 || true
  fi

  # AC1.3 — step 1 wording: BOTH tokens must appear on a single line.
  # The expected line is:
  #   1. ✓ NTFY_TOPIC already set in ${INSTALL_DIR}/.env (existing config)
  if grep -F "✓ NTFY_TOPIC already set in" "${combined}" \
       | grep -F "(existing config)" >/dev/null 2>&1; then
    pass "step 1 contains '✓ NTFY_TOPIC already set in' AND '(existing config)'"
  else
    fail "step 1 does NOT contain the expected 'already set ... (existing config)' wording"
    echo "    --- combined transcript ---" >&2
    sed 's/^/    /' "${combined}" >&2 || true
    echo "    ---------------------------" >&2
  fi

  # AC1.4 — the bug wording ("Edit ${INSTALL_DIR}/.env and set ...") must
  # NOT appear on the existing-env path. We look for the literal "Edit"
  # token followed somewhere on the same line by a path containing
  # ".nudge/.env" — the current fallback wording's signature.
  if grep -E 'Edit[[:space:]].*\.nudge/\.env' "${combined}" >/dev/null 2>&1; then
    fail "transcript still contains 'Edit ...nudge/.env' wording — existing-env hit the fallback branch"
    grep -nE 'Edit[[:space:]].*\.nudge/\.env' "${combined}" | sed 's/^/    /' >&2 || true
  else
    pass "transcript does NOT contain the 'Edit ...nudge/.env' fallback wording"
  fi

  # AC1.5 — the new branch supplies "(existing config)", NOT
  # "(from existing-env)". This guards against a careless implementation
  # that just adds existing-env to the flag|env|tty arm, which would emit
  # "(from existing-env)" via the shared ${TOPIC_SOURCE} interpolation.
  if grep -F "(from existing-env)" "${combined}" >/dev/null 2>&1; then
    fail "transcript contains '(from existing-env)' — wording should be '(existing config)'"
  else
    pass "transcript does NOT contain '(from existing-env)'"
  fi

  # AC4 — .env file content is byte-identical to the pre-existing fixture.
  local env_post_snapshot
  env_post_snapshot="$(cat "${env_file}")"
  if [[ "${env_pre_snapshot}" == "${env_post_snapshot}" ]]; then
    pass ".env file is byte-identical to the pre-existing fixture (left untouched)"
  else
    fail ".env file was modified — 'left untouched' contract broken"
    echo "    --- before ---" >&2
    printf '%s\n' "${env_pre_snapshot}" | sed 's/^/    /' >&2 || true
    echo "    --- after ----" >&2
    printf '%s\n' "${env_post_snapshot}" | sed 's/^/    /' >&2 || true
    echo "    --------------" >&2
  fi

  # Also sanity-check the preservation marker is still in the file. The
  # byte-equality check above already covers this, but keep an explicit
  # assertion so a regression that only mutates the marker line shows up
  # with a focused failure message.
  if grep -F "preservation-marker-existing-env-next-steps" "${env_file}" >/dev/null 2>&1; then
    pass "preservation-marker comment survived install"
  else
    fail ".env preservation-marker lost — file was rewritten"
  fi
}

main() {
  scenario_existing_env_next_steps_wording

  echo
  if [[ "${FAILED}" -ne 0 ]]; then
    echo "SOME TESTS FAILED" >&2
    exit 1
  fi
  echo "ALL TESTS PASSED"
}

main "$@"
