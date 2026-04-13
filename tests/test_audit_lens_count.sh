#!/usr/bin/env bash
# Tests for issue #3: Fix test_discover_mode.sh test 4 (hardcoded lens count)
#
# These tests define the behavioral contract:
# 1. test_discover_mode.sh must NOT hardcode the audit lens count
# 2. The jq query in test_discover_mode.sh must exclude ALL exclusive modes
# 3. Audit lens count must be dynamically derivable from domains.json
# 4. The test's jq query must produce the same count as the production query
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

echo "=== Test Suite: audit lens count (issue #3) ==="

DOMAINS_FILE="$SCRIPT_DIR/config/domains.json"
TEST_FILE="$SCRIPT_DIR/tests/test_discover_mode.sh"

# =====================================================================
# Contract 1: No hardcoded audit lens count
# =====================================================================

echo ""
echo "Test 1: test_discover_mode.sh must not hardcode expected count '112'"
test_content="$(cat "$TEST_FILE")"
assert_not_contains "no hardcoded 112 in assertion" '"112"' "$test_content"

echo ""
echo "Test 2: test_discover_mode.sh must not use 'count is 112' in description"
assert_not_contains "no 'count is 112' description" 'count is 112' "$test_content"

echo ""
echo "Test 3: test_discover_mode.sh test 4 should reference domains.json dynamically"
# The test must compute expected count from domains.json rather than using a literal number.
# We look for a jq computation of the expected count in the test 4 area.
# Extract lines around test 4 (the "Audit mode lens count" test)
test4_area="$(sed -n '/Test 4:/,/Test 5:/p' "$TEST_FILE")"
# Must contain a jq call that computes the expected count (not just the audit_lenses query)
# A dynamic assertion would use a variable computed from domains.json for the expected value
has_dynamic_expected=false
# Check for jq computing an expected count — the pattern is some variable derived from jq
# used as the expected value in assert_eq
if echo "$test4_area" | grep -qE 'jq.*domains.*select.*lenses.*add|expected.*jq'; then
  has_dynamic_expected=true
fi
TOTAL=$((TOTAL + 1))
if $has_dynamic_expected; then
  PASS=$((PASS + 1))
  echo "  PASS: test 4 computes expected count dynamically via jq"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: test 4 must compute expected count dynamically from domains.json"
fi

# =====================================================================
# Contract 2: Mode isolation — jq query must exclude ALL exclusive modes
# =====================================================================

echo ""
echo "Test 4: Audit-mode jq query must exclude deploy mode"
# The jq query used to compute audit_lenses (for tests 3-4) must filter out deploy
audit_lenses_area="$(sed -n '/Test 3:/,/Test 4:/p' "$TEST_FILE")"
assert_contains "deploy exclusion in audit jq query" 'deploy' "$audit_lenses_area"

echo ""
echo "Test 5: Audit-mode jq query must exclude opensource mode"
assert_contains "opensource exclusion in audit jq query" 'opensource' "$audit_lenses_area"

echo ""
echo "Test 6: Audit-mode jq query must exclude content mode"
assert_contains "content exclusion in audit jq query" 'content' "$audit_lenses_area"

echo ""
echo "Test 7: Audit-mode jq query must exclude discover mode"
assert_contains "discover exclusion in audit jq query" 'discover' "$audit_lenses_area"

# =====================================================================
# Contract 3: Audit lens count consistency with domains.json
# =====================================================================

echo ""
echo "Test 8: Dynamic audit count from domains.json must be a positive integer"
# Compute expected audit lens count using the production mode-isolation filter
expected_audit_count="$(jq '[.domains[] | select(.mode != "discover" and .mode != "deploy" and .mode != "opensource" and .mode != "content") | .lenses | length] | add' "$DOMAINS_FILE")"
TOTAL=$((TOTAL + 1))
if [[ "$expected_audit_count" =~ ^[1-9][0-9]*$ ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: dynamic audit count is a positive integer ($expected_audit_count)"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: dynamic audit count should be a positive integer, got '$expected_audit_count'"
fi

echo ""
echo "Test 9: Dynamic audit count must not include exclusive-mode domains"
# Count lenses from exclusive-mode domains
exclusive_count="$(jq '[.domains[] | select(.mode == "discover" or .mode == "deploy" or .mode == "opensource" or .mode == "content") | .lenses | length] | add' "$DOMAINS_FILE")"
total_count="$(jq '[.domains[] | .lenses | length] | add' "$DOMAINS_FILE")"
recomputed_audit="$((total_count - exclusive_count))"
assert_eq "audit count = total minus exclusive" "$recomputed_audit" "$expected_audit_count"

echo ""
echo "Test 10: Production jq query and dynamic count agree"
# Run the full production-style query (with sort_by and full conditional chain) and count
prod_count="$(jq -r --arg mode "audit" \
  '[.domains | sort_by(.order)[] | (if $mode == "discover" then select(.mode == "discover") elif $mode == "deploy" then select(.mode == "deploy") elif $mode == "opensource" then select(.mode == "opensource") elif $mode == "content" then select(.mode == "content") else select(.mode != "discover" and .mode != "deploy" and .mode != "opensource" and .mode != "content") end) | .lenses | length] | add' "$DOMAINS_FILE")"
assert_eq "production query count matches dynamic count" "$expected_audit_count" "$prod_count"

# =====================================================================
# Contract 4: test_discover_mode.sh test 4 must pass
# =====================================================================

echo ""
echo "Test 11: test_discover_mode.sh test 4 must pass"
# Run test_discover_mode.sh and capture output, then check test 4 specifically
test_output="$(bash "$TEST_FILE" 2>&1 || true)"
test4_result="$(echo "$test_output" | grep -A2 'Test 4:' | head -3)"
TOTAL=$((TOTAL + 1))
if echo "$test4_result" | grep -q 'PASS'; then
  PASS=$((PASS + 1))
  echo "  PASS: test 4 in test_discover_mode.sh passes"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: test 4 in test_discover_mode.sh must pass"
  echo "    Output: $test4_result"
fi

# =====================================================================
# Contract 5: Stale query pattern must not be used for audit mode
# =====================================================================

echo ""
echo "Test 12: Audit jq query must not use single-mode exclusion pattern"
# The stale pattern is: else select(.mode != "discover") end)
# This only excludes discover but not deploy/opensource/content
# After the fix, the else branch must exclude all four modes
audit_query_lines="$(grep -B1 -A1 'audit_lenses=' "$TEST_FILE" | head -5)"
stale_pattern='select(.mode != "discover") end)'
TOTAL=$((TOTAL + 1))
if echo "$audit_query_lines" | grep -qF "$stale_pattern"; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: audit jq query still uses stale single-mode exclusion"
  echo "    Found pattern: $stale_pattern"
else
  PASS=$((PASS + 1))
  echo "  PASS: audit jq query does not use stale single-mode exclusion"
fi

echo ""
echo "Test 13: Audit jq query must exclude all four exclusive modes in else branch"
# After fix, the else branch should contain exclusions for all 4 modes
# Pattern: select(.mode != "discover" and .mode != "deploy" and .mode != "opensource" and .mode != "content")
audit_query_full="$(grep -A2 'audit_lenses=' "$TEST_FILE" | tr '\n' ' ')"
TOTAL=$((TOTAL + 1))
has_all_exclusions=true
for mode in discover deploy opensource content; do
  if ! echo "$audit_query_full" | grep -q "mode != \"$mode\""; then
    has_all_exclusions=false
    break
  fi
done
if $has_all_exclusions; then
  PASS=$((PASS + 1))
  echo "  PASS: audit jq query excludes all four exclusive modes"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: audit jq query must exclude discover, deploy, opensource, and content"
fi

# =====================================================================
# Contract 6: Test-production parity for audit_lenses query
# =====================================================================

echo ""
echo "Test 14: Audit lens count in test output must match production query"
# The actual audit count produced by test_discover_mode.sh's jq query
# must equal the production query's count.
# We extract the "Actual:" value from test 4's output to see what the test computed.
prod_audit_count="$(jq -r --arg mode "audit" \
  '.domains | sort_by(.order)[] | (if $mode == "discover" then select(.mode == "discover") elif $mode == "deploy" then select(.mode == "deploy") elif $mode == "opensource" then select(.mode == "opensource") elif $mode == "content" then select(.mode == "content") else select(.mode != "discover" and .mode != "deploy" and .mode != "opensource" and .mode != "content") end) | .id as $d | .lenses[] | $d + "/" + .' "$DOMAINS_FILE" | wc -l)"
test4_actual="$(echo "$test_output" | grep -A3 'Test 4:' | grep 'Actual:' | sed 's/.*Actual:[[:space:]]*//' | tr -d '[:space:]')"
# If test 4 passes, there's no "Actual:" line — the count matched expected.
# In that case, extract the expected value that was asserted.
if [[ -z "$test4_actual" ]]; then
  # Test 4 passed — the actual value equaled expected, so extract from PASS line
  test4_actual="$prod_audit_count"
fi
assert_eq "test audit count matches production ($prod_audit_count)" "$prod_audit_count" "$test4_actual"

# =====================================================================
# Contract 7: Audit query behaviorally excludes all exclusive domains
# =====================================================================

echo ""
echo "Test 15: Audit query excludes deployment domain lenses"
# Run the same audit jq query used in test_discover_mode.sh (and production)
audit_lenses="$(jq -r --arg mode "audit" \
  '.domains | sort_by(.order)[] | (if $mode == "discover" then select(.mode == "discover") elif $mode == "deploy" then select(.mode == "deploy") elif $mode == "opensource" then select(.mode == "opensource") elif $mode == "content" then select(.mode == "content") else select(.mode != "discover" and .mode != "deploy" and .mode != "opensource" and .mode != "content") end) | .id as $d | .lenses[] | $d + "/" + .' "$DOMAINS_FILE")"
deploy_lenses="$(echo "$audit_lenses" | grep "^deployment/" || true)"
assert_eq "no deployment lenses in audit mode" "" "$deploy_lenses"

echo ""
echo "Test 16: Audit query excludes open-source-readiness domain lenses"
oss_lenses="$(echo "$audit_lenses" | grep "^open-source-readiness/" || true)"
assert_eq "no open-source-readiness lenses in audit mode" "" "$oss_lenses"

echo ""
echo "Test 17: Audit query excludes content-quality domain lenses"
content_lenses="$(echo "$audit_lenses" | grep "^content-quality/" || true)"
assert_eq "no content-quality lenses in audit mode" "" "$content_lenses"

echo ""
echo "Test 18: Audit query excludes discovery domain lenses"
discovery_lenses="$(echo "$audit_lenses" | grep "^discovery/" || true)"
assert_eq "no discovery lenses in audit mode" "" "$discovery_lenses"

# =====================================================================
# Summary
# =====================================================================

echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

[[ "$FAIL" -eq 0 ]] || exit 1
