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

# Tests for issue #132: logs/retry-loops lens registration and prompt contract.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LENS_FILE="$SCRIPT_DIR/prompts/lenses/logs/retry-loops.md"
DOMAINS_FILE="$SCRIPT_DIR/config/domains.json"

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
    echo "    Expected: $expected"
    echo "    Actual:   $actual"
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
    echo "    Unexpected: $needle"
  fi
}

assert_file_exists() {
  local desc="$1" filepath="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$filepath" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    File not found: $filepath"
  fi
}

mode_lenses() {
  local mode="$1"
  jq -r --arg mode "$mode" \
    '.domains | sort_by(.order)[] |
      (if $mode == "discover" then select(.mode == "discover")
       elif $mode == "deploy" then select(.mode == "deploy")
       elif $mode == "opensource" then select(.mode == "opensource")
       elif $mode == "content" then select(.mode == "content")
       else select(.mode != "discover" and .mode != "deploy" and .mode != "opensource" and .mode != "content") end) |
      .id as $d | .lenses[] | $d + "/" + .' "$DOMAINS_FILE"
}

echo ""
echo "=== Test Suite: logs/retry-loops lens (issue #132) ==="
echo ""

assert_file_exists "retry-loops lens prompt exists" "$LENS_FILE"

lens_content=""
if [[ -f "$LENS_FILE" ]]; then
  lens_content="$(cat "$LENS_FILE")"
fi

echo ""
echo "Test 1: frontmatter is exact"
frontmatter="$(sed -n '1,6p' "$LENS_FILE" 2>/dev/null)"
expected_frontmatter="---
id: retry-loops
domain: logs
name: Retry Loop Detector
role: Retry Behavior Analyst
---"
assert_eq "frontmatter matches issue contract" "$expected_frontmatter" "$frontmatter"

echo ""
echo "Test 2: prompt length is in the requested band"
line_count="$(wc -l < "$LENS_FILE" 2>/dev/null || echo 0)"
if [[ "$line_count" -ge 80 && "$line_count" -le 150 ]]; then
  PASS=$((PASS + 1))
  TOTAL=$((TOTAL + 1))
  echo "  PASS: prompt length is $line_count lines"
else
  FAIL=$((FAIL + 1))
  TOTAL=$((TOTAL + 1))
  echo "  FAIL: prompt length should be 80-150 lines, got $line_count"
fi

echo ""
echo "Test 3: logs domain registration is audit-visible"
logs_lenses="$(jq -r '.domains[] | select(.id == "logs") | .lenses | join(",")' "$DOMAINS_FILE")"
logs_mode="$(jq -r '.domains[] | select(.id == "logs") | .mode // "null"' "$DOMAINS_FILE")"
assert_eq "logs domain registers expected lenses" "error-storms,error-cascades,retry-loops,recursive-growth,resource-leaks,resource-exhaustion,log-gaps,missing-heartbeats,silent-failures,state-machine-violations,state-corruption,race-condition-signals,lifecycle-violations,orphaned-events,process-orphans,latency-degradation,clock-skew,timeout-clusters,deadlock-symptoms,data-loss-signals,transaction-anomalies" "$logs_lenses"
assert_eq "logs domain stays mode-less" "null" "$logs_mode"
audit_lenses="$(mode_lenses audit)"
assert_contains "audit mode includes logs/retry-loops" "logs/retry-loops" "$audit_lenses"

for mode in discover deploy opensource content; do
  lenses="$(mode_lenses "$mode")"
  assert_not_contains "$mode mode excludes logs/retry-loops" "logs/retry-loops" "$lenses"
done

echo ""
echo "Test 4: prompt scope and sections match the issue"
assert_contains "has expert focus section" "## Your Expert Focus" "$lens_content"
assert_contains "has hunt section" "### What You Hunt For" "$lens_content"
assert_contains "has investigation section" "### How You Investigate" "$lens_content"
assert_contains "uses LOGS_PATH variable" '{{LOGS_PATH}}' "$lens_content"
assert_contains "accepts single file" "single file" "$lens_content"
assert_contains "accepts directory" "directory" "$lens_content"
assert_contains "distinguishes error-storms" 'distinct from `error-storms`' "$lens_content"
assert_contains "distinguishes error-cascades" 'distinct from `error-cascades`' "$lens_content"

echo ""
echo "Test 5: prompt covers required retry categories"
for term in \
  "Deterministic Failure Treated As Transient" \
  "No-Backoff Retries (Tight Loops)" \
  "Max-Retry-Cap Reached Repeatedly" \
  "Retry Without Input Change" \
  "Exponential Backoff Configured But Not Honored" \
  "Retry Storms Hitting Rate Limits"; do
  assert_contains "mentions $term" "$term" "$lens_content"
done

echo ""
echo "Test 6: prompt requires attempt and fingerprint investigation"
for term in \
  "track the attempt counter" \
  "Extract the input fingerprint" \
  "Extract the failure fingerprint" \
  "Compare spacing between attempts" \
  "Look for observable state change" \
  "Locate the source emit site" \
  "Reject legitimate retries"; do
  assert_contains "mentions $term" "$term" "$lens_content"
done

echo ""
echo "Test 7: prompt excludes legitimate and sibling cases"
assert_contains "excludes attempt 2 success" "attempt 2" "$lens_content"
assert_contains "says attempt 2 success is not a loop" "not a loop" "$lens_content"
assert_contains "routes volume cases to error-storms" 'route that to `error-storms`' "$lens_content"
assert_contains "routes cascade cases to error-cascades" 'route that to `error-cascades`' "$lens_content"

echo ""
echo "Test 8: prompt requires evidence fields"
for term in \
  "Operation identity" \
  "At least 3 attempts" \
  "Identical sanitized input fingerprint" \
  "Identical sanitized failure fingerprint" \
  "Observed retry spacing" \
  "Source emit site" \
  "Statement of what did not change" \
  "Estimated cost"; do
  assert_contains "requires evidence $term" "$term" "$lens_content"
done

echo ""
echo "Test 9: prompt avoids forbidden tool-specific commands"
for term in "grep" "awk" "jq" "journalctl"; do
  assert_not_contains "does not prescribe $term" "$term" "$lens_content"
done

echo ""
echo "Test 10: prompt includes redaction contract"
for term in \
  "input fingerprints" \
  "failure fingerprints" \
  "<TOKEN>" \
  "<COOKIE>" \
  "<EMAIL>" \
  "<API_KEY>" \
  "<PASSWORD>" \
  "<REQUEST_BODY_REDACTED>" \
  "<PII_REDACTED>"; do
  assert_contains "mentions redaction term $term" "$term" "$lens_content"
done

echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
