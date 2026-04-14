#!/usr/bin/env bash
# Copyright 2025 Bootstrap Academy
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

# Tests for issue #4: Fix test_discover_mode.sh test 14 (stale mode field assertion)
#
# These tests define the behavioral contract:
# 1. test_discover_mode.sh test 14 must NOT assert only discovery has a mode field
# 2. test_discover_mode.sh test 14 must filter by known mode values, not domain IDs
# 3. test_discover_mode.sh test 14 must PASS when run
# 4. All known mode-bearing domains are accounted for in domains.json
# 5. No unexpected domain has a mode field (the invariant test 14 should enforce)
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

echo "=== Test Suite: mode field assertion (issue #4) ==="

DOMAINS_FILE="$SCRIPT_DIR/config/domains.json"
TEST_FILE="$SCRIPT_DIR/tests/test_discover_mode.sh"

# =====================================================================
# Contract 1: Test 14 must not use the stale single-domain exclusion
# =====================================================================

echo ""
echo "Test 1: test 14 must not exclude only discovery by domain ID"
# The stale pattern is: select(.id != "discovery") | select(.mode != null)
# This excludes discovery by ID but catches all other mode-bearing domains as failures
test14_area="$(sed -n '/Test 14:/,/Test 15:/p' "$TEST_FILE")"
stale_pattern='select(.id != "discovery")'
assert_not_contains "no stale single-ID exclusion in test 14" "$stale_pattern" "$test14_area"

echo ""
echo "Test 2: test 14 description must not say 'No other domain has mode field'"
# The stale description implies only discovery should have a mode field
assert_not_contains "no stale description" "No other domain has mode field" "$test14_area"

echo ""
echo "Test 3: test 14 assertion message must not say 'no other domain has mode field'"
assert_not_contains "no stale assertion message" "no other domain has mode field" "$test14_area"

# =====================================================================
# Contract 2: Test 14 must filter by mode values, not domain IDs
# =====================================================================

echo ""
echo "Test 4: test 14 jq query must reference 'discover' mode value"
assert_contains "discover mode referenced in test 14" 'discover' "$test14_area"

echo ""
echo "Test 5: test 14 jq query must reference 'deploy' mode value"
assert_contains "deploy mode referenced in test 14" 'deploy' "$test14_area"

echo ""
echo "Test 6: test 14 jq query must reference 'opensource' mode value"
assert_contains "opensource mode referenced in test 14" 'opensource' "$test14_area"

echo ""
echo "Test 7: test 14 jq query must reference 'content' mode value"
assert_contains "content mode referenced in test 14" 'content' "$test14_area"

echo ""
echo "Test 8: test 14 must use mode-value filtering (select on .mode)"
# The fix should filter by .mode values, using a pattern like:
# select(.mode != "discover" and .mode != "deploy" and ...)
# We check for at least the pattern of filtering on .mode field
TOTAL=$((TOTAL + 1))
if echo "$test14_area" | grep -qE '\.mode\s*!=\s*"discover"' && \
   echo "$test14_area" | grep -qE '\.mode\s*!=\s*"deploy"' && \
   echo "$test14_area" | grep -qE '\.mode\s*!=\s*"opensource"' && \
   echo "$test14_area" | grep -qE '\.mode\s*!=\s*"content"'; then
  PASS=$((PASS + 1))
  echo "  PASS: test 14 filters by all four known mode values"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: test 14 must filter out all four known mode values (.mode != each)"
fi

# =====================================================================
# Contract 3: Test 14 must PASS when run
# =====================================================================

echo ""
echo "Test 9: test 14 must pass in test_discover_mode.sh"
test_output="$(bash "$TEST_FILE" 2>&1 || true)"
test14_result="$(echo "$test_output" | grep -A2 'Test 14:' | head -3)"
TOTAL=$((TOTAL + 1))
if echo "$test14_result" | grep -q 'PASS'; then
  PASS=$((PASS + 1))
  echo "  PASS: test 14 in test_discover_mode.sh passes"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: test 14 in test_discover_mode.sh must pass"
  echo "    Output: $test14_result"
fi

# =====================================================================
# Contract 4: domains.json has exactly 4 mode-bearing domains
# =====================================================================

echo ""
echo "Test 10: domains.json has exactly 4 mode-bearing domains"
mode_count="$(jq '[.domains[] | select(.mode != null)] | length' "$DOMAINS_FILE")"
assert_eq "4 domains have mode fields" "4" "$mode_count"

echo ""
echo "Test 11: discovery domain has mode 'discover'"
mode_val="$(jq -r '.domains[] | select(.id == "discovery") | .mode' "$DOMAINS_FILE")"
assert_eq "discovery mode is discover" "discover" "$mode_val"

echo ""
echo "Test 12: deployment domain has mode 'deploy'"
mode_val="$(jq -r '.domains[] | select(.id == "deployment") | .mode' "$DOMAINS_FILE")"
assert_eq "deployment mode is deploy" "deploy" "$mode_val"

echo ""
echo "Test 13: open-source-readiness domain has mode 'opensource'"
mode_val="$(jq -r '.domains[] | select(.id == "open-source-readiness") | .mode' "$DOMAINS_FILE")"
assert_eq "open-source-readiness mode is opensource" "opensource" "$mode_val"

echo ""
echo "Test 14: content-quality domain has mode 'content'"
mode_val="$(jq -r '.domains[] | select(.id == "content-quality") | .mode' "$DOMAINS_FILE")"
assert_eq "content-quality mode is content" "content" "$mode_val"

# =====================================================================
# Contract 5: No unexpected mode fields on standard domains
# =====================================================================

echo ""
echo "Test 15: No domain has an unexpected mode value"
# The only valid mode values are: discover, deploy, opensource, content
# Any domain with a mode field not in this set is a bug
unexpected_modes="$(jq -r '.domains[] | select(.mode != null) | select(.mode != "discover" and .mode != "deploy" and .mode != "opensource" and .mode != "content") | .id + "=" + .mode' "$DOMAINS_FILE")"
assert_eq "no unexpected mode values" "" "$unexpected_modes"

echo ""
echo "Test 16: Standard audit domains have no mode field"
# Spot-check a few standard domains that should never have a mode field
for domain in security architecture performance testing; do
  mode_val="$(jq -r --arg d "$domain" '.domains[] | select(.id == $d) | .mode // "null"' "$DOMAINS_FILE")"
  assert_eq "$domain domain has no mode" "null" "$mode_val"
done

# =====================================================================
# Contract 6: The fix preserves the original intent of test 14
# =====================================================================

echo ""
echo "Test 17: test 14 asserts empty result for non-modal domains"
# The fix should still assert that the jq result is empty (meaning no unexpected modes)
# This verifies the test's original purpose is preserved: catching accidental mode fields
TOTAL=$((TOTAL + 1))
if echo "$test14_area" | grep -qE 'assert_eq.*""'; then
  PASS=$((PASS + 1))
  echo "  PASS: test 14 asserts empty string (no unexpected modes)"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: test 14 must assert empty result to catch accidental mode fields"
fi

echo ""
echo "Test 18: test 14 uses assert_eq (not a weaker assertion)"
# The original and fix should both use assert_eq for a strict equality check
TOTAL=$((TOTAL + 1))
if echo "$test14_area" | grep -q 'assert_eq'; then
  PASS=$((PASS + 1))
  echo "  PASS: test 14 uses assert_eq"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: test 14 must use assert_eq for strict validation"
fi

# =====================================================================
# Contract 7: jq filter detection capability (synthetic data)
# =====================================================================
# The tests above verify the filter returns empty against real domains.json
# (which has no unexpected modes). These tests verify the filter actually
# CATCHES unexpected modes — exercising the positive detection path.

TMPDIR_SYNTH="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_SYNTH"' EXIT

echo ""
echo "Test 19: jq filter catches unexpected mode in synthetic data"
cat > "$TMPDIR_SYNTH/domains.json" <<'SYNTH'
{
  "domains": [
    { "id": "discovery", "mode": "discover", "lenses": [] },
    { "id": "deployment", "mode": "deploy", "lenses": [] },
    { "id": "open-source-readiness", "mode": "opensource", "lenses": [] },
    { "id": "content-quality", "mode": "content", "lenses": [] },
    { "id": "security", "lenses": [] },
    { "id": "bogus-domain", "mode": "bogus", "lenses": [] }
  ]
}
SYNTH
# Run the exact jq filter from the fixed test 14
caught="$(jq -r '.domains[] | select(.mode != null) | select(.mode != "discover" and .mode != "deploy" and .mode != "opensource" and .mode != "content") | .id' "$TMPDIR_SYNTH/domains.json")"
assert_eq "filter catches bogus mode domain" "bogus-domain" "$caught"

echo ""
echo "Test 20: jq filter returns empty when all modes are expected"
cat > "$TMPDIR_SYNTH/domains_clean.json" <<'SYNTH'
{
  "domains": [
    { "id": "discovery", "mode": "discover", "lenses": [] },
    { "id": "deployment", "mode": "deploy", "lenses": [] },
    { "id": "open-source-readiness", "mode": "opensource", "lenses": [] },
    { "id": "content-quality", "mode": "content", "lenses": [] },
    { "id": "security", "lenses": [] },
    { "id": "architecture", "lenses": [] }
  ]
}
SYNTH
clean="$(jq -r '.domains[] | select(.mode != null) | select(.mode != "discover" and .mode != "deploy" and .mode != "opensource" and .mode != "content") | .id' "$TMPDIR_SYNTH/domains_clean.json")"
assert_eq "filter returns empty for clean config" "" "$clean"

echo ""
echo "Test 21: jq filter catches multiple unexpected modes"
cat > "$TMPDIR_SYNTH/domains_multi.json" <<'SYNTH'
{
  "domains": [
    { "id": "discovery", "mode": "discover", "lenses": [] },
    { "id": "bad-one", "mode": "mystery", "lenses": [] },
    { "id": "bad-two", "mode": "unknown", "lenses": [] },
    { "id": "security", "lenses": [] }
  ]
}
SYNTH
multi="$(jq -r '.domains[] | select(.mode != null) | select(.mode != "discover" and .mode != "deploy" and .mode != "opensource" and .mode != "content") | .id' "$TMPDIR_SYNTH/domains_multi.json")"
expected_multi=$'bad-one\nbad-two'
assert_eq "filter catches multiple unexpected domains" "$expected_multi" "$multi"

echo ""
echo "Test 22: jq filter ignores domains without mode field"
cat > "$TMPDIR_SYNTH/domains_nomode.json" <<'SYNTH'
{
  "domains": [
    { "id": "security", "lenses": [] },
    { "id": "architecture", "lenses": [] },
    { "id": "performance", "lenses": [] }
  ]
}
SYNTH
nomode="$(jq -r '.domains[] | select(.mode != null) | select(.mode != "discover" and .mode != "deploy" and .mode != "opensource" and .mode != "content") | .id' "$TMPDIR_SYNTH/domains_nomode.json")"
assert_eq "filter returns empty when no domain has mode" "" "$nomode"

# =====================================================================
# Summary
# =====================================================================

echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

[[ "$FAIL" -eq 0 ]] || exit 1
