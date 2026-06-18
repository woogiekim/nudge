#!/usr/bin/env bash
# Spec: prd.md "README docs-audit follow-up — Notification format + Security note"
#   - Acceptance criterion: Notification format fenced block shows
#     Q: {question} and A: {assistant answer} lines, with no 💬 character.
#   - Acceptance criterion: explanatory bullets name NUDGE_MAX_Q and NUDGE_MAX_A
#     as the truncation caps.
#   - Acceptance criterion: Security section warns about both $QUESTION and
#     $ANSWER as the secret-leak surface.
#   - Acceptance criterion: Markdown fences remain balanced (one open, one close)
#     in the Notification format example.
#
# Strategy: pure structural greps against README.md, scoped to the two PRD
# regions (Notification format section, Security section). No process spawned,
# no host services touched, no fixture HOME needed — this is a documentation
# contract test.
#
# Expected to FAIL on the unmodified README.md at HEAD 45fd70f (red phase):
# - the fenced block still contains 💬 and lacks Q:/A: lines;
# - the Security bullet only mentions $QUESTION, not $ANSWER.
# Becomes green once the parallel backend stage lands its README edit.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
README="${REPO_ROOT}/README.md"

FAILED=0
SCENARIOS_RUN=0

pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*" >&2; FAILED=1; }

# --- section extraction helpers -----------------------------------------------
# extract_section <heading_title_regex>
#   Prints lines starting from the first Markdown heading (any "#" depth) whose
#   text matches <heading_title_regex>, up to (but not including) the next
#   heading of equal or shallower depth. The PRD-named sections we care about
#   ("Notification format", "Security") may live at any nesting level; the
#   extractor follows whichever level it finds first.
extract_section() {
  local title_re="$1"
  awk -v re="${title_re}" '
    /^#+[[:space:]]/ {
      # Heading depth = number of leading "#" characters.
      depth = match($0, /[^#]/) - 1
      if (in_section) {
        if (depth > 0 && depth <= start_depth) {
          exit
        }
      } else if ($0 ~ re) {
        in_section = 1
        start_depth = depth
        print
        next
      }
    }
    in_section { print }
  ' "${README}"
}

# count_lines <pattern> <text>
#   Echoes the number of lines in <text> that match <pattern> (fixed-string).
count_lines_fixed() {
  local pat="$1" text="$2"
  printf '%s\n' "${text}" | grep -F -c -- "${pat}" || true
}

# count_lines_regex <ere> <text>
#   Echoes the number of lines in <text> that match the ERE <ere>.
count_lines_regex() {
  local re="$1" text="$2"
  printf '%s\n' "${text}" | grep -E -c -- "${re}" || true
}

# --- scenario 1: README exists and is non-empty -------------------------------
scenario_readme_present() {
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))
  echo "T1: README.md is present and non-empty"

  if [[ -f "${README}" && -s "${README}" ]]; then
    pass "T1 README.md exists at ${README}"
  else
    fail "T1 README.md missing or empty at ${README}"
    return
  fi
}

# --- scenario 2: Notification format section banner shape ---------------------
scenario_notification_format_banner() {
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))
  echo "T2: Notification format section shows Q: / A: banner shape (no 💬)"

  local section
  section="$(extract_section '^#+[[:space:]].*[Nn]otification format')"

  if [[ -z "${section}" ]]; then
    fail "T2 'Notification format' section not found in README.md"
    return
  fi

  # The fenced block must contain a `Q: {question}` line.
  local q_count
  q_count="$(count_lines_fixed 'Q: {question}' "${section}")"
  if [[ "${q_count}" -ge 1 ]]; then
    pass "T2 fenced block contains 'Q: {question}' line"
  else
    fail "T2 fenced block missing 'Q: {question}' line (found ${q_count})"
  fi

  # The fenced block must contain an `A: {assistant answer}` line.
  local a_count
  a_count="$(count_lines_fixed 'A: {assistant answer}' "${section}")"
  if [[ "${a_count}" -ge 1 ]]; then
    pass "T2 fenced block contains 'A: {assistant answer}' line"
  else
    fail "T2 fenced block missing 'A: {assistant answer}' line (found ${a_count})"
  fi

  # The 💬 character must NOT appear anywhere in this section.
  local emoji_count
  emoji_count="$(count_lines_fixed '💬' "${section}")"
  if [[ "${emoji_count}" -eq 0 ]]; then
    pass "T2 section contains no 💬 character"
  else
    fail "T2 section still contains 💬 character on ${emoji_count} line(s)"
  fi

  # The explanatory bullets must name the truncation caps.
  local has_max_q has_max_a
  has_max_q="$(count_lines_fixed 'NUDGE_MAX_Q' "${section}")"
  has_max_a="$(count_lines_fixed 'NUDGE_MAX_A' "${section}")"
  if [[ "${has_max_q}" -ge 1 ]]; then
    pass "T2 section names NUDGE_MAX_Q truncation cap"
  else
    fail "T2 section does not name NUDGE_MAX_Q truncation cap"
  fi
  if [[ "${has_max_a}" -ge 1 ]]; then
    pass "T2 section names NUDGE_MAX_A truncation cap"
  else
    fail "T2 section does not name NUDGE_MAX_A truncation cap"
  fi

  # Fences must be balanced inside the section: even number of ``` lines,
  # and at least one pair (one open, one close).
  local fence_count
  fence_count="$(count_lines_regex '^```' "${section}")"
  if [[ "${fence_count}" -ge 2 && $((fence_count % 2)) -eq 0 ]]; then
    pass "T2 fenced code block is balanced (${fence_count} fence lines)"
  else
    fail "T2 fenced code block is unbalanced (${fence_count} fence lines)"
  fi
}

# --- scenario 3: Security section secret-leak warning -------------------------
scenario_security_warning() {
  SCENARIOS_RUN=$((SCENARIOS_RUN + 1))
  echo "T3: Security section warns about \$QUESTION AND \$ANSWER"

  local section
  section="$(extract_section '^#+[[:space:]].*[Ss]ecurity')"

  if [[ -z "${section}" ]]; then
    fail "T3 'Security' section not found in README.md"
    return
  fi

  local q_var a_var
  q_var="$(count_lines_fixed '$QUESTION' "${section}")"
  a_var="$(count_lines_fixed '$ANSWER' "${section}")"

  if [[ "${q_var}" -ge 1 ]]; then
    pass "T3 Security section mentions \$QUESTION"
  else
    fail "T3 Security section does not mention \$QUESTION"
  fi
  if [[ "${a_var}" -ge 1 ]]; then
    pass "T3 Security section mentions \$ANSWER"
  else
    fail "T3 Security section does not mention \$ANSWER (still single-variable warning)"
  fi
}

main() {
  scenario_readme_present
  scenario_notification_format_banner
  scenario_security_warning

  echo
  echo "Scenarios run: ${SCENARIOS_RUN}"
  if [[ "${FAILED}" -ne 0 ]]; then
    echo "SOME TESTS FAILED" >&2
    exit 1
  fi
  echo "ALL TESTS PASSED"
}

main "$@"
