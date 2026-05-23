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

# Tests for issue #160: logs/state-corruption lens registration and prompt contract.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LENS_FILE="$SCRIPT_DIR/prompts/lenses/logs/state-corruption.md"
DOMAINS_FILE="$SCRIPT_DIR/config/domains.json"
EXPECTED_LOGS_LENSES="error-storms,error-cascades,retry-loops,recursive-growth,resource-leaks,resource-exhaustion,log-gaps,missing-heartbeats,silent-failures,state-machine-violations,state-corruption,race-condition-signals,lifecycle-violations,orphaned-events,process-orphans,latency-degradation,clock-skew,timeout-clusters,deadlock-symptoms,data-loss-signals,transaction-anomalies"

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

assert_before() {
  local desc="$1" earlier="$2" later="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$earlier" =~ ^[0-9]+$ && "$later" =~ ^[0-9]+$ && "$earlier" -lt "$later" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    Earlier line: $earlier"
    echo "    Later line:   $later"
  fi
}

line_no_fixed() {
  local pattern="$1"
  grep -nF "$pattern" "$LENS_FILE" 2>/dev/null | head -1 | cut -d: -f1
}

count_fixed() {
  local pattern="$1"
  grep -oF "$pattern" "$LENS_FILE" 2>/dev/null | wc -l | tr -d ' '
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
echo "=== Test Suite: logs/state-corruption lens (issue #160) ==="
echo ""

assert_file_exists "state-corruption lens prompt exists" "$LENS_FILE"

lens_content=""
if [[ -f "$LENS_FILE" ]]; then
  lens_content="$(cat "$LENS_FILE")"
fi

echo ""
echo "Test 1: frontmatter is exact"
frontmatter="$(sed -n '1,6p' "$LENS_FILE" 2>/dev/null)"
expected_frontmatter="---
id: state-corruption
domain: logs
name: State Corruption Detector
role: Invariant Violation Analyst
---"
assert_eq "frontmatter matches issue contract" "$expected_frontmatter" "$frontmatter"

echo ""
echo "Test 2: prompt length and template variables"
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
assert_eq "uses LOGS_PATH exactly once" "1" "$(count_fixed '{{LOGS_PATH}}')"
assert_eq "uses no PROJECT_PATH template" "0" "$(count_fixed '{{PROJECT_PATH}}')"

echo ""
echo "Test 3: logs domain registration is audit-visible"
logs_lenses="$(jq -r '.domains[] | select(.id == "logs") | .lenses | join(",")' "$DOMAINS_FILE")"
logs_mode="$(jq -r '.domains[] | select(.id == "logs") | .mode // "null"' "$DOMAINS_FILE")"
assert_eq "logs domain registers expected lenses" "$EXPECTED_LOGS_LENSES" "$logs_lenses"
assert_eq "logs domain stays mode-less" "null" "$logs_mode"
audit_lenses="$(mode_lenses audit)"
assert_contains "audit mode includes logs/state-corruption" "logs/state-corruption" "$audit_lenses"

for mode in discover deploy opensource content; do
  lenses="$(mode_lenses "$mode")"
  assert_not_contains "$mode mode excludes logs/state-corruption" "logs/state-corruption" "$lenses"
done

echo ""
echo "Test 4: required sections appear in order"
focus_line="$(line_no_fixed "## Your Expert Focus")"
hunt_line="$(line_no_fixed "### What You Hunt For")"
investigate_line="$(line_no_fixed "### How You Investigate")"
evidence_line="$(line_no_fixed "### Evidence Required Per Finding")"
threshold_line="$(line_no_fixed "### Threshold")"
not_to_report_line="$(line_no_fixed "### What NOT to Report")"
assert_before "focus before hunt" "$focus_line" "$hunt_line"
assert_before "hunt before investigation" "$hunt_line" "$investigate_line"
assert_before "investigation before evidence" "$investigate_line" "$evidence_line"
assert_before "evidence before threshold" "$evidence_line" "$threshold_line"
assert_before "threshold before exclusions" "$threshold_line" "$not_to_report_line"

echo ""
echo "Test 5: prompt covers required corruption-symptom buckets"
for term in \
  "Assertion failures and \"should never happen\" messages" \
  "Checksum, hash, and integrity-verification failures" \
  "Encoding/decoding/schema mismatches on owned data" \
  "Dangling references (orphan FKs, missing files, broken manifests)" \
  "Panic/abort with state dumps"; do
  assert_contains "mentions hunt bucket: $term" "$term" "$lens_content"
done

echo ""
echo "Test 6: prompt encodes invariant-first investigation flow"
for term in \
  "Read the project's own invariant vocabulary first" \
  "project-specific invariant terms" \
  "search for generic patterns" \
  "system-owned or user-supplied" \
  "Identify the violated invariant by name" \
  "Capture surrounding context" \
  "Decide threshold per bucket" \
  "Distinguish corruption from upstream-data issues"; do
  assert_contains "mentions investigation step: $term" "$term" "$lens_content"
done

echo ""
echo "Test 7: prompt sets threshold rule and sibling boundaries"
assert_contains "files at N=1 for assertion failures" "N=1" "$lens_content"
assert_contains "aggregates soft warnings at >=2" "≥2" "$lens_content"
assert_contains "names should-never-happen override" "should never happen" "$lens_content"
assert_contains "distinguishes system-state from user-input" "system contradicting itself" "$lens_content"
assert_contains "sibling: state-machine-violations" "state-machine-violations" "$lens_content"
assert_contains "sibling: data-loss-signals" "data-loss-signals" "$lens_content"
assert_contains "sibling: error-boundaries" "error-boundaries" "$lens_content"
assert_contains "sibling: error-storms" "error-storms" "$lens_content"

echo ""
echo "Test 8: prompt requires evidence fields and redaction contract"
for term in \
  "Violated invariant" \
  "Raw log line" \
  "Preceding context" \
  "Recurrence" \
  "Emit-site" \
  "Sensitive Data Contract" \
  "<TOKEN>" \
  "<COOKIE>" \
  "<EMAIL>" \
  "<API_KEY>" \
  "<PASSWORD>" \
  "<REQUEST_BODY_REDACTED>" \
  "<PII_REDACTED>"; do
  assert_contains "requires or names $term" "$term" "$lens_content"
done

echo ""
echo "Test 9: prompt avoids forbidden tool-specific commands"
for term in "grep" "awk" "jq" "journalctl"; do
  assert_not_contains "does not prescribe $term" "$term" "$lens_content"
done

echo ""
echo "Test 10: domain-qualified focus resolves the lens via dry-run"
TMP_ROOT="$SCRIPT_DIR/logs/test-logs-state-corruption.$$"
RUN_ID="test-logs-state-corruption-$$"
FAKE_BIN="$TMP_ROOT/bin"
PROJECT_DIR="$TMP_ROOT/project"
LOG_DIR="$TMP_ROOT/runtime-logs"
trap 'rm -rf "$TMP_ROOT" "$SCRIPT_DIR/logs/${RUN_ID}"*' EXIT
mkdir -p "$FAKE_BIN" "$PROJECT_DIR" "$LOG_DIR"
printf '#!/usr/bin/env bash\nprintf "DONE\\n"\n' > "$FAKE_BIN/claude"
chmod +x "$FAKE_BIN/claude"
git init -q "$PROJECT_DIR"
printf '2026-04-25T14:32:01Z assertion failed: refcount > 0 in src/cache.rs:142\n' > "$LOG_DIR/app.log"

focus_output="$(PATH="$FAKE_BIN:$PATH" bash "$SCRIPT_DIR/repolens.sh" \
  --project "$PROJECT_DIR" \
  --agent claude \
  --local \
  --yes \
  --resume "$RUN_ID" \
  --logs "$LOG_DIR" \
  --domain logs \
  --focus state-corruption \
  --dry-run 2>&1)"
focus_rc=$?
assert_eq "domain-qualified focus dry-run exits zero" "0" "$focus_rc"
assert_contains "domain-qualified focus lists logs/state-corruption" "logs/state-corruption" "$focus_output"
assert_contains "domain-qualified focus logs absolute logs path" "Logs: $LOG_DIR" "$focus_output"
assert_contains "domain-qualified focus completes dry run" "Dry run complete" "$focus_output"

echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
