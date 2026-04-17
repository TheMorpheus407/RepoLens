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

# Tests for issue #6: Fix test_discover_mode.sh test 27
#
# Behavioral contract:
# 1. Test 27 in test_discover_mode.sh must use a mode-count-agnostic grep pattern
# 2. Test 27 must PASS when run
# 3. The grep pattern must be robust against future mode additions
# 4. A Makefile with a 'check' target must exist to run all test suites
# 5. 'make check' must discover and run all test suites successfully
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

echo "=== Test Suite: issue #6 — test 27 fix & make check ==="

TEST_FILE="$SCRIPT_DIR/tests/test_discover_mode.sh"
REPOLENS_SH="$SCRIPT_DIR/repolens.sh"

# =====================================================================
# Contract 1: Test 27 grep pattern is mode-count-agnostic
# =====================================================================

echo ""
echo "Test 1: test 27 must NOT use the stale hardcoded mode list"
test27_area="$(sed -n '/Test 27:/,/Test 28:/p' "$TEST_FILE")"
# The broken pattern was: "audit|feature|bugfix|discover)"
assert_not_contains "no stale hardcoded mode list" 'audit|feature|bugfix|discover)' "$test27_area"

echo ""
echo "Test 2: test 27 must use the agnostic character-class pattern"
# The fix uses [|)] to match discover followed by either | or )
assert_contains "uses agnostic [|)] pattern" '[|)]' "$test27_area"

echo ""
echo "Test 3: test 27 must grep for discover specifically"
assert_contains "greps for discover" 'discover' "$test27_area"

echo ""
echo "Test 4: test 27 must not match the entire mode case string"
# Must not contain a full enumeration of all modes before discover
assert_not_contains "no full mode enumeration" 'audit|feature|bugfix|discover|deploy' "$test27_area"

# =====================================================================
# Contract 2: The grep pattern is robust against mode-list changes
# =====================================================================
# Test the actual pattern '|discover[|)]' against synthetic case lines
# to verify it handles future additions correctly

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo ""
echo "Test 5: pattern matches discover as last mode in case"
echo '  audit|feature|bugfix|discover) ;;' > "$TMPDIR/last.txt"
TOTAL=$((TOTAL + 1))
if grep -q '|discover[|)]' "$TMPDIR/last.txt"; then
  PASS=$((PASS + 1))
  echo "  PASS: matches discover as last mode"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: should match discover as last mode"
fi

echo ""
echo "Test 6: pattern matches discover with modes after it"
echo '  audit|feature|bugfix|discover|deploy|custom) ;;' > "$TMPDIR/middle.txt"
TOTAL=$((TOTAL + 1))
if grep -q '|discover[|)]' "$TMPDIR/middle.txt"; then
  PASS=$((PASS + 1))
  echo "  PASS: matches discover with trailing modes"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: should match discover with trailing modes"
fi

echo ""
echo "Test 7: pattern matches discover with many modes after it"
echo '  audit|feature|bugfix|discover|deploy|custom|opensource|content) ;;' > "$TMPDIR/many.txt"
TOTAL=$((TOTAL + 1))
if grep -q '|discover[|)]' "$TMPDIR/many.txt"; then
  PASS=$((PASS + 1))
  echo "  PASS: matches discover with many trailing modes"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: should match discover with many trailing modes"
fi

echo ""
echo "Test 8: pattern does NOT match 'discovers' (no false positives)"
echo '  discovers|something) ;;' > "$TMPDIR/false.txt"
TOTAL=$((TOTAL + 1))
# '|discover[|)]' requires | before discover and [|)] after — 'discovers' has 's' after
if grep -q '|discover[|)]' "$TMPDIR/false.txt"; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: should not match 'discovers'"
else
  PASS=$((PASS + 1))
  echo "  PASS: does not match 'discovers'"
fi

echo ""
echo "Test 9: pattern does NOT match 'undiscover'"
echo '  undiscover|other) ;;' > "$TMPDIR/prefix.txt"
TOTAL=$((TOTAL + 1))
# '|discover[|)]' with the pipe before 'discover' would NOT match 'undiscover|'
# since the grep looks for '|discover[|)]' which would match '|discover|' in 'undiscover|other'
# Wait — actually 'undiscover|other' contains '|discover' only if we look at 'cover|'. Let me trace:
# The string is: '  undiscover|other) ;;'
# Does '|discover[|)]' appear? Looking for literal |discover followed by | or )
# In 'undiscover|other', the substring 'r|o' exists, not '|discover'
# So the pattern won't match — correct behavior
if grep -q '|discover[|)]' "$TMPDIR/prefix.txt"; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: should not match 'undiscover'"
else
  PASS=$((PASS + 1))
  echo "  PASS: does not match 'undiscover'"
fi

echo ""
echo "Test 10: pattern matches the actual current repolens.sh mode line"
TOTAL=$((TOTAL + 1))
if grep -q '|discover[|)]' "$REPOLENS_SH"; then
  PASS=$((PASS + 1))
  echo "  PASS: pattern matches current repolens.sh"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: pattern does not match current repolens.sh"
fi

# =====================================================================
# Contract 3: Test 27 passes when run in full suite
# =====================================================================

echo ""
echo "Test 11: test_discover_mode.sh test 27 passes"
test_output="$(bash "$TEST_FILE" 2>&1 || true)"
test27_result="$(echo "$test_output" | grep -A2 'Test 27:' | head -3)"
TOTAL=$((TOTAL + 1))
if grep -q 'PASS' <<< "$test27_result"; then
  PASS=$((PASS + 1))
  echo "  PASS: test 27 passes in test_discover_mode.sh"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: test 27 must pass in test_discover_mode.sh"
  echo "    Output: $test27_result"
fi

echo ""
echo "Test 12: test_discover_mode.sh suite passes entirely (0 failures)"
suite_result="$(echo "$test_output" | grep 'Results:' | tail -1)"
TOTAL=$((TOTAL + 1))
if grep -q '0 failed' <<< "$suite_result"; then
  PASS=$((PASS + 1))
  echo "  PASS: full test_discover_mode.sh suite passes"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: test_discover_mode.sh suite must pass with 0 failures"
  echo "    Result: $suite_result"
fi

# =====================================================================
# Contract 4: Makefile with 'check' target exists
# =====================================================================

echo ""
echo "Test 13: Makefile exists in project root"
TOTAL=$((TOTAL + 1))
if [[ -f "$SCRIPT_DIR/Makefile" ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: Makefile exists"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: Makefile missing in project root"
fi

echo ""
echo "Test 14: Makefile has a 'check' target"
TOTAL=$((TOTAL + 1))
if [[ -f "$SCRIPT_DIR/Makefile" ]] && grep -qE '^check:' "$SCRIPT_DIR/Makefile"; then
  PASS=$((PASS + 1))
  echo "  PASS: Makefile has 'check' target"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: Makefile must have a 'check' target"
fi

# Cache `make check` output/rc ONCE. The Makefile recursion guard keys off
# REPOLENS_MAKE_CHECK, so setting it here is required when this file is
# itself invoked by a make check parent (otherwise we recurse forever and
# blow every outer budget). We always set it — the guard is the thing
# under test in contracts 5-7, and tests 15-17 only read output shape.
_MAKE_OK_OUT=""
_MAKE_OK_RC=0
if [[ -f "$SCRIPT_DIR/Makefile" ]] && command -v make >/dev/null 2>&1; then
  # set -e is not active (script uses set -uo pipefail), so a non-zero
  # exit from the command substitution won't abort — $? correctly
  # captures make's rc.
  _MAKE_OK_OUT="$(cd "$SCRIPT_DIR" && REPOLENS_MAKE_CHECK=1 make check 2>&1)"
  _MAKE_OK_RC=$?
fi

echo ""
echo "Test 15: 'make check' discovers all test suites"
test_script_count="$(find "$SCRIPT_DIR/tests" -maxdepth 1 -name 'test_*.sh' -type f | wc -l)"
TOTAL=$((TOTAL + 1))
if [[ -n "$_MAKE_OK_OUT" ]]; then
  results_count="$(echo "$_MAKE_OK_OUT" | grep -c 'Results:' || true)"
  if [[ "$results_count" -ge "$((test_script_count - 1))" ]] && [[ "$results_count" -gt 0 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: make check discovers $results_count test suites (of $test_script_count scripts)"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: make check must discover all test suites"
    echo "    Found $results_count Results lines for $test_script_count test scripts"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: cannot test — Makefile missing"
fi

echo ""
echo "Test 16: 'make check' exits successfully"
TOTAL=$((TOTAL + 1))
if [[ -f "$SCRIPT_DIR/Makefile" ]]; then
  if [[ "$_MAKE_OK_RC" -eq 0 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: make check exits 0"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: make check must exit 0 when all tests pass (got rc=$_MAKE_OK_RC)"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: cannot test — Makefile missing"
fi

echo ""
echo "Test 17: 'make check' reports aggregate pass/fail counts"
TOTAL=$((TOTAL + 1))
if [[ -n "$_MAKE_OK_OUT" ]]; then
  if grep -qiE '(passed|failed|total|suites|results)' <<< "$_MAKE_OK_OUT"; then
    PASS=$((PASS + 1))
    echo "  PASS: make check reports aggregate results"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: make check must report aggregate results"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: cannot test — Makefile missing"
fi

# =====================================================================
# Contract 5: Makefile failure handling
# =====================================================================
# Run make check ONCE with a planted failing suite, then assert shape.
# All invocations set REPOLENS_MAKE_CHECK=1 to activate the recursion
# guard, preventing this file from being re-executed and avoiding
# infinite recursion.

_FAIL_MAKE_OUT=""
_FAIL_MAKE_RC=0
if [[ -f "$SCRIPT_DIR/Makefile" ]] && command -v make >/dev/null 2>&1; then
  _fail_script="$SCRIPT_DIR/tests/test_zzz_tempfail.sh"
  cat > "$_fail_script" <<'FAILEOF'
#!/usr/bin/env bash
echo "  FAIL: intentional failure"
echo "Results: 0/1 passed, 1 failed"
exit 1
FAILEOF
  chmod +x "$_fail_script"
  _FAIL_MAKE_OUT="$(cd "$SCRIPT_DIR" && REPOLENS_MAKE_CHECK=1 make check 2>&1)"
  _FAIL_MAKE_RC=$?
  rm -f "$_fail_script"
fi

echo ""
echo "Test 18: 'make check' exits non-zero when a suite fails"
TOTAL=$((TOTAL + 1))
if [[ -n "$_FAIL_MAKE_OUT" ]]; then
  if [[ "$_FAIL_MAKE_RC" -ne 0 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: make check exits non-zero on suite failure"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: make check must exit non-zero when a suite fails (got rc=$_FAIL_MAKE_RC)"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: cannot test — Makefile or make command missing"
fi

echo ""
echo "Test 19: 'make check' output shows FAILED for failing suites"
TOTAL=$((TOTAL + 1))
if [[ -n "$_FAIL_MAKE_OUT" ]]; then
  if grep -q 'FAILED: tests/test_zzz_tempfail.sh' <<< "$_FAIL_MAKE_OUT"; then
    PASS=$((PASS + 1))
    echo "  PASS: make check output shows FAILED for failing suite"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: make check must show FAILED for failing suites"
    echo "    Output: $(echo "$_FAIL_MAKE_OUT" | grep -iE '(FAIL|test_zzz)' | head -3)"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: cannot test — Makefile or make command missing"
fi

echo ""
echo "Test 20: 'make check' reports failed count > 0 for failing suites"
TOTAL=$((TOTAL + 1))
if [[ -n "$_FAIL_MAKE_OUT" ]]; then
  _agg_line="$(echo "$_FAIL_MAKE_OUT" | grep -E '^Results:.*suites' | tail -1)"
  if grep -qE 'Results: [0-9]+ suites run, [1-9]' <<< "$_agg_line"; then
    PASS=$((PASS + 1))
    echo "  PASS: aggregate reports non-zero failed count"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: aggregate must report non-zero failed count"
    echo "    Aggregate: $_agg_line"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: cannot test — Makefile or make command missing"
fi

# =====================================================================
# Contract 6: Recursion guard
# =====================================================================
# These tests set REPOLENS_MAKE_CHECK=1 to simulate the recursive
# invocation that occurs when make check calls a test that calls
# make check again. The guard should skip files containing '&& make check'.

echo ""
echo "Test 21: recursion guard skips meta-test files when REPOLENS_MAKE_CHECK=1"
TOTAL=$((TOTAL + 1))
if [[ -n "$_MAKE_OK_OUT" ]]; then
  # This test file (test_issue6_test27_fix.sh) contains '&& make check',
  # so the recursion guard should skip it when REPOLENS_MAKE_CHECK=1 is set.
  if grep -qE '(PASSED|FAILED): tests/test_issue6_test27_fix.sh' <<< "$_MAKE_OK_OUT"; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: recursion guard should skip this meta-test when REPOLENS_MAKE_CHECK=1"
  else
    PASS=$((PASS + 1))
    echo "  PASS: recursion guard correctly skips this test file"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: cannot test — Makefile or make command missing"
fi

echo ""
echo "Test 22: recursion guard runs all non-meta test suites"
TOTAL=$((TOTAL + 1))
if [[ -n "$_MAKE_OK_OUT" ]]; then
  _non_meta=0
  for _f in "$SCRIPT_DIR"/tests/test_*.sh; do
    if ! grep -q '&& make check' "$_f" 2>/dev/null; then
      _non_meta=$((_non_meta + 1))
    fi
  done
  _run_count="$(echo "$_MAKE_OK_OUT" | grep -cE '^(PASSED|FAILED):' || true)"
  if [[ "$_run_count" -eq "$_non_meta" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: make check runs all $_non_meta non-meta suites"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: expected $_non_meta suites run, got $_run_count"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: cannot test — Makefile or make command missing"
fi

# =====================================================================
# Contract 7: Aggregate results format accuracy
# =====================================================================

echo ""
echo "Test 23: aggregate results line follows 'Results: N suites run, M failed' format"
TOTAL=$((TOTAL + 1))
if [[ -n "$_MAKE_OK_OUT" ]]; then
  _agg_line="$(echo "$_MAKE_OK_OUT" | grep -E '^Results:.*suites' | tail -1)"
  if grep -qE '^Results: [0-9]+ suites run, [0-9]+ failed$' <<< "$_agg_line"; then
    PASS=$((PASS + 1))
    echo "  PASS: aggregate line matches expected format"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: aggregate format mismatch"
    echo "    Got: $_agg_line"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: cannot test — Makefile or make command missing"
fi

echo ""
echo "Test 24: aggregate suite count matches actual suites run"
TOTAL=$((TOTAL + 1))
if [[ -n "$_MAKE_OK_OUT" ]]; then
  _run_count="$(echo "$_MAKE_OK_OUT" | grep -cE '^(PASSED|FAILED):' || true)"
  _agg_line="$(echo "$_MAKE_OK_OUT" | grep -E '^Results:.*suites' | tail -1)"
  _reported="$(echo "$_agg_line" | grep -oE '[0-9]+ suites' | grep -oE '[0-9]+')"
  if [[ -n "$_reported" ]] && [[ "$_run_count" -eq "$_reported" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: reported suite count ($_reported) matches actual ($_run_count)"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: reported $_reported suites but ran $_run_count"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: cannot test — Makefile or make command missing"
fi

# =====================================================================
# Summary
# =====================================================================

echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

[[ "$FAIL" -eq 0 ]] || exit 1
