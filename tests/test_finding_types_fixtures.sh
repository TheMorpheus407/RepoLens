#!/usr/bin/env bash
# Copyright 2025-2026 Bootstrap Academy
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Consolidating test for the shared finding-types fixtures (issue #354).
#
# tests/fixtures/finding-types/00{1..6}-*.md are reusable, deterministic LOCAL
# MODE finding files that the finding-types + single-source-severity work asserts
# against. This test:
#
#   1. Proves every fixture is parseable LOCAL MODE frontmatter (AC #2) by reading
#      its title/severity/domain through _streak_frontmatter_value — the same
#      reader count_dry_run_issues uses in production.
#   2. Exercises the severity-mismatch detector and the type resolver against the
#      fixtures, asserting the documented outcome per file.
#
# Assertions on the helpers are guarded with `declare -F ... >/dev/null` so the
# file stays green even if cherry-picked onto a branch predating the helpers
# (issue AC #3). On this branch all six helpers exist, so the guards resolve true
# and the assertions run for real.
#
# Why _streak_frontmatter_value for the title: the detector matches a strict
# `^\[SEVERITY\]` prefix. read_frontmatter RETAINS surrounding quotes, so a
# `"[LOW] ..."` title would start with `"` and silently fail to match — turning
# the 001 mismatch assertion into a false pass. _streak_frontmatter_value
# de-quotes (and is the production call path in lib/streak.sh), so the bracket is
# the first character and the regex matches. NO real model is ever invoked.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_LIB="$SCRIPT_DIR/lib/core.sh"
STREAK_LIB="$SCRIPT_DIR/lib/streak.sh"
FIX_DIR="$SCRIPT_DIR/tests/fixtures/finding-types"

PASS=0
FAIL=0
TOTAL=0

pass_with() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

fail_with() {
  local desc="$1" detail="${2:-}"
  FAIL=$((FAIL + 1))
  echo "  FAIL: $desc"
  [[ -n "$detail" ]] && printf '    %s\n' "$detail"
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected '$expected', got '$actual'"
  fi
}

assert_nonempty() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -n "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected a non-empty value, got empty"
  fi
}

# assert_rc_zero / assert_rc_nonzero — the detector's only mismatch signal is its
# exit code, so assert on the captured `$?` directly.
assert_rc_zero() {
  local desc="$1" rc="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$rc" -eq 0 ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected exit code 0, got $rc"
  fi
}

assert_rc_nonzero() {
  local desc="$1" rc="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$rc" -ne 0 ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected a non-zero exit code, got $rc"
  fi
}

skip_note() {
  echo "  SKIP: $1"
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

if [[ ! -f "$CORE_LIB" ]]; then
  fail_with "lib/core.sh exists" "Missing $CORE_LIB"
  finish
fi
if [[ ! -f "$STREAK_LIB" ]]; then
  fail_with "lib/streak.sh exists" "Missing $STREAK_LIB"
  finish
fi

# shellcheck disable=SC1090
source "$CORE_LIB"
# shellcheck disable=SC1090
source "$STREAK_LIB"

EXPECTED_FIXTURES=(
  "001-severity-mismatch.md"
  "002-severity-agree.md"
  "003-missing-type.md"
  "004-invalid-type.md"
  "005-valid-type.md"
  "006-no-title-severity.md"
)

echo "=== all six fixtures exist ==="
for name in "${EXPECTED_FIXTURES[@]}"; do
  TOTAL=$((TOTAL + 1))
  if [[ -f "$FIX_DIR/$name" ]]; then
    pass_with "fixture present: $name"
  else
    fail_with "fixture present: $name" "Missing $FIX_DIR/$name"
  fi
done

echo "=== AC#2: every fixture is parseable LOCAL MODE frontmatter ==="
# title, severity, and domain must all read back non-empty through the production
# reader. A malformed block (bad labels list, missing closing ---) would surface
# here as an empty read rather than passing by visual inspection.
for name in "${EXPECTED_FIXTURES[@]}"; do
  f="$FIX_DIR/$name"
  [[ -f "$f" ]] || continue
  assert_nonempty "frontmatter title parses ($name)" \
    "$(_streak_frontmatter_value title "$f")"
  assert_nonempty "frontmatter severity parses ($name)" \
    "$(_streak_frontmatter_value severity "$f")"
  assert_nonempty "frontmatter domain parses ($name)" \
    "$(_streak_frontmatter_value domain "$f")"
done

echo "=== severity-mismatch detector (guarded) ==="
if declare -F detect_severity_mismatch >/dev/null 2>&1; then
  # 001: title [LOW] vs frontmatter high -> stdout 'high', exit non-zero (mismatch).
  f="$FIX_DIR/001-severity-mismatch.md"
  t="$(_streak_frontmatter_value title "$f")"
  s="$(_streak_frontmatter_value severity "$f")"
  out="$(detect_severity_mismatch "$s" "$t")"; rc=$?
  assert_eq "001 detector prints the frontmatter severity (high)" "high" "$out"
  assert_rc_nonzero "001 title/frontmatter severity mismatch is signalled" "$rc"

  # 002: title [MEDIUM] agrees with frontmatter medium -> stdout 'medium', exit 0.
  f="$FIX_DIR/002-severity-agree.md"
  t="$(_streak_frontmatter_value title "$f")"
  s="$(_streak_frontmatter_value severity "$f")"
  out="$(detect_severity_mismatch "$s" "$t")"; rc=$?
  assert_eq "002 detector prints the frontmatter severity (medium)" "medium" "$out"
  assert_rc_zero "002 agreeing severities signal no mismatch" "$rc"

  # 006: title has no [SEVERITY] prefix -> stdout 'low', exit 0 (cannot disagree).
  f="$FIX_DIR/006-no-title-severity.md"
  t="$(_streak_frontmatter_value title "$f")"
  s="$(_streak_frontmatter_value severity "$f")"
  out="$(detect_severity_mismatch "$s" "$t")"; rc=$?
  assert_eq "006 detector prints the frontmatter severity (low)" "low" "$out"
  assert_rc_zero "006 a title without a [SEVERITY] prefix signals no mismatch" "$rc"
else
  skip_note "detect_severity_mismatch not defined — skipping severity assertions"
fi

echo "=== type resolver (guarded) ==="
if declare -F finding_resolve_type >/dev/null 2>&1; then
  # 003: no type: -> domain default for testing -> test-gap.
  assert_eq "003 missing type falls back to the testing domain default" \
    "test-gap" "$(finding_resolve_type "$FIX_DIR/003-missing-type.md")"
  # 004: invalid type: normalizes to empty -> domain default for security.
  assert_eq "004 invalid type falls back to the security domain default" \
    "security-vulnerability" "$(finding_resolve_type "$FIX_DIR/004-invalid-type.md")"
  # 005: explicit valid type wins over the code-quality domain default.
  assert_eq "005 explicit valid type wins over the domain default" \
    "performance-risk" "$(finding_resolve_type "$FIX_DIR/005-valid-type.md")"
else
  skip_note "finding_resolve_type not defined — skipping type assertions"
fi

finish
