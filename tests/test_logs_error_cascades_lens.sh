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

# Tests for issue #131: logs/error-cascades lens registration and prompt contract.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LENS_FILE="$SCRIPT_DIR/prompts/lenses/logs/error-cascades.md"
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
echo "=== Test Suite: logs/error-cascades lens (issue #131) ==="
echo ""

assert_file_exists "error-cascades lens prompt exists" "$LENS_FILE"

lens_content=""
if [[ -f "$LENS_FILE" ]]; then
  lens_content="$(cat "$LENS_FILE")"
fi

echo ""
echo "Test 1: frontmatter is exact"
frontmatter="$(sed -n '1,6p' "$LENS_FILE" 2>/dev/null)"
expected_frontmatter="---
id: error-cascades
domain: logs
name: Error Cascade Investigator
role: Cascading Failure Analyst
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
assert_eq "logs domain registers expected lenses" "error-storms,error-cascades,retry-loops,recursive-growth,resource-leaks,resource-exhaustion,log-gaps,missing-heartbeats,silent-failures,state-machine-violations,lifecycle-violations,process-orphans,latency-degradation,clock-skew" "$logs_lenses"
assert_eq "logs domain stays mode-less" "null" "$logs_mode"
audit_lenses="$(mode_lenses audit)"
assert_contains "audit mode includes logs/error-cascades" "logs/error-cascades" "$audit_lenses"

for mode in discover deploy opensource content; do
  lenses="$(mode_lenses "$mode")"
  assert_not_contains "$mode mode excludes logs/error-cascades" "logs/error-cascades" "$lenses"
done

echo ""
echo "Test 4: prompt scope and sections match the issue"
assert_contains "has expert focus section" "## Your Expert Focus" "$lens_content"
assert_contains "has hunt section" "### What You Hunt For" "$lens_content"
assert_contains "has investigation section" "### How You Investigate" "$lens_content"
assert_contains "uses LOGS_PATH variable" '{{LOGS_PATH}}' "$lens_content"
assert_contains "accepts single file" "single file" "$lens_content"
assert_contains "accepts directory" "directory" "$lens_content"
assert_contains "is distinct from error-storms" 'distinct from `error-storms`' "$lens_content"

echo ""
echo "Test 5: prompt covers required cascade categories"
for term in \
  "Causal Chains Across Components" \
  "Fan-Out Failures from a Single Trigger" \
  "Secondary-Error Masking the Primary" \
  "Cleanup-of-Cleanup Loops" \
  "Cross-Process Amplification" \
  "Escalation Chains Hitting Circuit-Breakers / Retry-Caps / Storm-Caps"; do
  assert_contains "mentions $term" "$term" "$lens_content"
done

echo ""
echo "Test 6: prompt requires causality-first investigation"
for term in \
  "Sweep for dense error windows" \
  "Pick the loudest symptom and walk backward in time" \
  "Verify causality, not just correlation" \
  "Trace the propagation path" \
  "Check for reproducibility" \
  "Locate source emit-sites" \
  "Identify the recommended break-point"; do
  assert_contains "mentions $term" "$term" "$lens_content"
done

echo ""
echo "Test 7: prompt requires evidence fields"
for term in \
  "Root failure" \
  "The chain" \
  "Temporal proximity" \
  "End effect" \
  "Source emit-sites" \
  "Repetition evidence" \
  "Recommended break-point"; do
  assert_contains "requires evidence $term" "$term" "$lens_content"
done

echo ""
echo "Test 8: prompt covers filing threshold and splitting rule"
for term in \
  ">=3 distinct components / operations" \
  "within minutes, not hours" \
  ">=2 occurrences" \
  "Each cascade gets **ONE issue**" \
  "Do not file separate issues for each link"; do
  assert_contains "mentions $term" "$term" "$lens_content"
done

echo ""
echo "Test 9: prompt avoids forbidden tool-specific commands"
for term in "grep" "journalctl" "jq"; do
  assert_not_contains "does not prescribe $term" "$term" "$lens_content"
done

echo ""
echo "Test 10: prompt keeps cascades separate from storms"
assert_contains "routes single-component repetition to error-storms" "Single-component repetition" "$lens_content"
assert_contains "three lines from one component are not enough" "Three lines from one component are not enough" "$lens_content"

echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
