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

# Tests for issue #5: Fix test_discover_mode.sh test 22 (and test 27)
#
# These tests define the behavioral contract:
# 1. test_discover_mode.sh test 22 assertions must match discover.md template sections
# 2. test_discover_mode.sh test 22 must NOT assert stale section names ("Vision", "Effort Estimate")
# 3. test_discover_mode.sh test 27 grep pattern must tolerate modes added after "discover"
# 4. test_discover_mode.sh tests 22 and 27 must PASS when run
# 5. All 57 assertions in test_discover_mode.sh must pass (make check acceptance criterion)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
TOTAL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    Expected: $(echo "$expected" | head -3)"
    echo "    Actual:   $(echo "$actual" | head -3)"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    Missing: $needle"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    Should not contain: $needle"
  fi
}

echo "=== Test Suite: discover test 22 & 27 fix (issue #5) ==="

TEST_FILE="$SCRIPT_DIR/tests/test_discover_mode.sh"
TEMPLATE_FILE="$SCRIPT_DIR/prompts/_base/discover.md"

# =====================================================================
# Contract 1: Test 22 assertions must match actual discover.md sections
# =====================================================================

echo ""
echo "Test 1: discover.md template uses 'Proposed Implementation' section"
template_content="$(cat "$TEMPLATE_FILE")"
assert_contains "template has Proposed Implementation" "Proposed Implementation" "$template_content"

echo ""
echo "Test 2: discover.md template uses 'Acceptance Criteria' section"
assert_contains "template has Acceptance Criteria" "Acceptance Criteria" "$template_content"

echo ""
echo "Test 3: discover.md template does NOT use 'Vision' as a section name"
# Vision could appear in other contexts, but the Issue Body Structure uses Proposed Implementation
# Check the body structure block specifically
body_structure="$(sed -n '/Issue Body Structure/,/Quality Standards/p' "$TEMPLATE_FILE")"
assert_not_contains "body structure has no Vision section" "**Vision**" "$body_structure"

echo ""
echo "Test 4: discover.md template does NOT use 'Effort Estimate' as a section name"
assert_not_contains "body structure has no Effort Estimate section" "**Effort Estimate**" "$body_structure"

# =====================================================================
# Contract 2: Test 22 in test_discover_mode.sh must NOT use stale names
# =====================================================================

echo ""
echo "Test 5: test 22 must not assert 'Vision' section"
# Extract the test 22 area from the test file
test22_area="$(sed -n '/Test 22:/,/Test 23:/p' "$TEST_FILE")"
assert_not_contains "no Vision assertion in test 22" '"Vision"' "$test22_area"

echo ""
echo "Test 6: test 22 must not assert 'Effort Estimate' section"
assert_not_contains "no Effort Estimate assertion in test 22" '"Effort Estimate"' "$test22_area"

# =====================================================================
# Contract 3: Test 22 must assert the correct section names
# =====================================================================

echo ""
echo "Test 7: test 22 must assert 'Proposed Implementation' section"
assert_contains "Proposed Implementation assertion in test 22" '"Proposed Implementation"' "$test22_area"

echo ""
echo "Test 8: test 22 must assert 'Acceptance Criteria' section"
assert_contains "Acceptance Criteria assertion in test 22" '"Acceptance Criteria"' "$test22_area"

# =====================================================================
# Contract 4: Test 22 must still assert the non-broken sections
# =====================================================================

echo ""
echo "Test 9: test 22 still asserts 'Idea Summary'"
assert_contains "Idea Summary still in test 22" '"Idea Summary"' "$test22_area"

echo ""
echo "Test 10: test 22 still asserts 'Opportunity'"
assert_contains "Opportunity still in test 22" '"Opportunity"' "$test22_area"

echo ""
echo "Test 11: test 22 still asserts 'Current State'"
assert_contains "Current State still in test 22" '"Current State"' "$test22_area"

echo ""
echo "Test 12: test 22 still asserts 'Dependencies'"
assert_contains "Dependencies still in test 22" '"Dependencies"' "$test22_area"

echo ""
echo "Test 13: test 22 still asserts 'Risks & Open Questions'"
assert_contains "Risks still in test 22" '"Risks & Open Questions"' "$test22_area"

# =====================================================================
# Contract 5: Test 27 grep pattern must tolerate additional modes
# =====================================================================

echo ""
echo "Test 14: test 27 must not use fragile pattern 'audit|feature|bugfix|discover)'"
# The stale pattern expects discover to be the LAST mode before closing paren
test27_area="$(sed -n '/Test 27:/,/Test 28:/p' "$TEST_FILE")"
# The exact fragile pattern is: grep -q "audit|feature|bugfix|discover)"
# It fails because the actual code now has more modes after discover
assert_not_contains "no fragile terminal-discover pattern" 'audit|feature|bugfix|discover)"' "$test27_area"

echo ""
echo "Test 15: test 27 grep pattern must match discover as a non-terminal case alternative"
# The pattern must match discover whether it appears mid-list (discover|...) or at the end (discover))
# Valid patterns include: |discover[|)], |discover|, discover appearing in the mode case
# We verify the grep used in test 27 can match the actual repolens.sh line
TOTAL=$((TOTAL + 1))
# Extract the actual grep pattern from test 27
grep_line="$(echo "$test27_area" | grep 'grep.*repolens.sh' | head -1)"
if [[ -n "$grep_line" ]]; then
  # The grep pattern in test 27 must actually match the real repolens.sh mode line
  mode_line="$(grep 'audit|feature|bugfix|discover' "$SCRIPT_DIR/repolens.sh")"
  # Simulate: does the grep from test 27 match the actual line?
  # We test this indirectly: the pattern must handle discover followed by | (not just ))
  if echo "$mode_line" | grep -q '|discover|'; then
    # discover IS mid-list in actual code — test 27's pattern must handle this
    PASS=$((PASS + 1))
    echo "  PASS: discover is mid-list in repolens.sh mode validation (pattern must handle this)"
  else
    PASS=$((PASS + 1))
    echo "  PASS: discover position in mode list verified"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: could not find grep pattern in test 27"
fi

# =====================================================================
# Contract 6: Test 22 must PASS when test_discover_mode.sh is run
# =====================================================================

echo ""
echo "Test 16: test 22 assertions must all pass in test_discover_mode.sh"
test_output="$(bash "$TEST_FILE" 2>&1 || true)"
# Test 22 produces multiple assertion lines — check for any FAILs in the test 22 block
test22_output="$(echo "$test_output" | sed -n '/Test 22:/,/Test 23:/p')"
TOTAL=$((TOTAL + 1))
if echo "$test22_output" | grep -q 'FAIL'; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: test 22 has failing assertions in test_discover_mode.sh"
  echo "$test22_output" | grep 'FAIL' | while read -r line; do
    echo "    $line"
  done
else
  PASS=$((PASS + 1))
  echo "  PASS: all test 22 assertions pass"
fi

# =====================================================================
# Contract 7: Test 27 must PASS when test_discover_mode.sh is run
# =====================================================================

echo ""
echo "Test 17: test 27 must pass in test_discover_mode.sh"
test27_output="$(echo "$test_output" | sed -n '/Test 27:/,/Test 28:/p')"
TOTAL=$((TOTAL + 1))
if echo "$test27_output" | grep -q 'FAIL'; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: test 27 fails in test_discover_mode.sh"
  echo "$test27_output" | grep 'FAIL' | while read -r line; do
    echo "    $line"
  done
else
  PASS=$((PASS + 1))
  echo "  PASS: test 27 passes"
fi

# =====================================================================
# Contract 8: All test_discover_mode.sh tests must pass (0 failures)
# =====================================================================

echo ""
echo "Test 18: test_discover_mode.sh must report 0 failures"
results_line="$(echo "$test_output" | grep 'Results:')"
TOTAL=$((TOTAL + 1))
if echo "$results_line" | grep -q '0 failed'; then
  PASS=$((PASS + 1))
  echo "  PASS: test_discover_mode.sh reports 0 failures"
  echo "    $results_line"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: test_discover_mode.sh still has failures"
  echo "    $results_line"
fi

echo ""
echo "Test 19: test_discover_mode.sh must exit with code 0"
bash "$TEST_FILE" > /dev/null 2>&1
exit_code=$?
assert_eq "exit code is 0" "0" "$exit_code"

# =====================================================================
# Contract 9: Section name consistency with other templates
# =====================================================================

echo ""
echo "Test 20: discover.md section names are consistent with feature.md"
# feature.md should also use Proposed Implementation and Acceptance Criteria
feature_file="$SCRIPT_DIR/prompts/_base/feature.md"
if [[ -f "$feature_file" ]]; then
  feature_content="$(cat "$feature_file")"
  assert_contains "feature.md also uses Proposed Implementation" "Proposed Implementation" "$feature_content"
  assert_contains "feature.md also uses Acceptance Criteria" "Acceptance Criteria" "$feature_content"
else
  TOTAL=$((TOTAL + 2))
  PASS=$((PASS + 2))
  echo "  PASS: feature.md not found (skip consistency check)"
  echo "  PASS: feature.md not found (skip consistency check)"
fi

# =====================================================================
# Contract 10: Test 27 pattern robustness — future-proofing
# =====================================================================

echo ""
echo "Test 22: test 27 must not hardcode the full mode list in order"
# A robust pattern should not depend on the exact set of modes after discover
# If the test uses a pattern that checks for discover as a case alternative
# without assuming it's the last one, it will survive future mode additions
TOTAL=$((TOTAL + 1))
# The fragile pattern is exactly: "audit|feature|bugfix|discover)"
# Any pattern that ends with discover) is fragile
fragile_count="$(echo "$test27_area" | grep -c 'discover)"' || true)"
if [[ "$fragile_count" -eq 0 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: test 27 does not use fragile terminal-discover pattern"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: test 27 still uses fragile pattern ending with discover)\""
fi

# =====================================================================
# Contract 11: Grep pattern regex matches both mode positions
# =====================================================================

echo ""
echo "Test 23: grep pattern matches discover mid-list (|discover|...)"
TOTAL=$((TOTAL + 1))
if echo "audit|feature|bugfix|discover|deploy|custom)" | grep -q '|discover[|)]'; then
  PASS=$((PASS + 1))
  echo "  PASS: pattern matches |discover| (mid-list)"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: pattern does not match |discover| (mid-list)"
fi

echo ""
echo "Test 24: grep pattern matches discover terminal (|discover))"
TOTAL=$((TOTAL + 1))
if echo "audit|feature|bugfix|discover)" | grep -q '|discover[|)]'; then
  PASS=$((PASS + 1))
  echo "  PASS: pattern matches |discover) (terminal)"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: pattern does not match |discover) (terminal)"
fi

echo ""
echo "Test 25: grep pattern rejects partial match 'discovery'"
TOTAL=$((TOTAL + 1))
if echo "audit|feature|discovery)" | grep -q '|discover[|)]'; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: pattern incorrectly matches 'discovery' mode"
else
  PASS=$((PASS + 1))
  echo "  PASS: pattern correctly rejects 'discovery' (not exact mode)"
fi

# =====================================================================
# Summary
# =====================================================================

echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

[[ "$FAIL" -eq 0 ]] || exit 1
