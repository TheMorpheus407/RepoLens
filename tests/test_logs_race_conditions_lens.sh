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

# Tests for issue #157: logs/race-conditions lens registration and prompt contract.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LENS_FILE="$SCRIPT_DIR/prompts/lenses/logs/race-conditions.md"
DOMAINS_FILE="$SCRIPT_DIR/config/domains.json"
EXPECTED_LOGS_LENSES="error-storms,error-cascades,retry-loops,recursive-growth,resource-leaks,resource-exhaustion,log-gaps,missing-heartbeats,silent-failures,state-machine-violations,state-corruption,race-conditions,lifecycle-violations,orphaned-events,process-orphans,latency-degradation,clock-skew,timeout-clusters,deadlock-symptoms,data-loss-signals"

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
echo "=== Test Suite: logs/race-conditions lens (issue #157) ==="
echo ""

assert_file_exists "race-conditions lens prompt exists" "$LENS_FILE"

lens_content=""
if [[ -f "$LENS_FILE" ]]; then
  lens_content="$(cat "$LENS_FILE")"
fi

echo ""
echo "Test 1: frontmatter is exact"
frontmatter="$(sed -n '1,6p' "$LENS_FILE" 2>/dev/null)"
expected_frontmatter="---
id: race-conditions
domain: logs
name: Race Condition Symptom Detector
role: Concurrency Anomaly Analyst
---"
assert_eq "frontmatter matches issue contract" "$expected_frontmatter" "$frontmatter"

echo ""
echo "Test 2: prompt length and template variables match the issue"
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
assert_contains "audit mode includes logs/race-conditions" "logs/race-conditions" "$audit_lenses"

for mode in discover deploy opensource content; do
  lenses="$(mode_lenses "$mode")"
  assert_not_contains "$mode mode excludes logs/race-conditions" "logs/race-conditions" "$lenses"
done

echo ""
echo "Test 4: required sections appear in order"
focus_line="$(line_no_fixed "## Your Expert Focus")"
hunt_line="$(line_no_fixed "### What You Hunt For")"
investigate_line="$(line_no_fixed "### How You Investigate")"
evidence_line="$(line_no_fixed "### Evidence Requirements")"
does_not_file_line="$(line_no_fixed "### What This Lens Does NOT File")"
assert_before "focus before hunt" "$focus_line" "$hunt_line"
assert_before "hunt before investigation" "$hunt_line" "$investigate_line"
assert_before "investigation before evidence" "$investigate_line" "$evidence_line"
assert_before "evidence before exclusions" "$evidence_line" "$does_not_file_line"

echo ""
echo "Test 5: prompt covers required race-symptom buckets"
for term in \
  "Optimistic-lock / version-conflict logs" \
  "Double-processing of the same identity" \
  "Interleaved partial event sequences from concurrent operations" \
  "Leader-flapping / split-brain warnings" \
  "Write-after-read inconsistency surfaced via stale-cache / stale-read warnings"; do
  assert_contains "mentions $term" "$term" "$lens_content"
done

echo ""
echo "Test 6: prompt requires concurrency-first investigation"
for term in \
  "Bucket events by entity identity first" \
  "Within each bucket, prove concurrent handlers" \
  "Confirm the symptom matches a race bucket" \
  "Measure recurrence and diversity" \
  "Rule out designed retry-on-conflict" \
  "Locate the emit-site or detection gap"; do
  assert_contains "mentions investigation step $term" "$term" "$lens_content"
done

echo ""
echo "Test 7: prompt states thresholds and sibling boundaries"
assert_contains "requires at least three occurrences" "at least 3 times" "$lens_content"
assert_contains "requires distinct operations or entities" "distinct operations or entities are affected" "$lens_content"
assert_contains "requires at least two entity identities when scoped" "at least 2 distinct entity identities" "$lens_content"
assert_contains "distinguishes designed CAS retries" "designed CAS retry loops" "$lens_content"
assert_contains "excludes successful CAS retries" "single optimistic-lock retry that succeeds" "$lens_content"
assert_contains "files exhausted retries" "File when retries exhaust" "$lens_content"
assert_contains "distinguishes deadlock-symptoms" "deadlock-symptoms" "$lens_content"
assert_contains "distinguishes state-machine-violations" "state-machine-violations" "$lens_content"

echo ""
echo "Test 8: prompt requires evidence fields and redaction contract"
for term in \
  "Race symptom name" \
  "Raw log lines proving concurrency" \
  "Recurrence rate" \
  "Distinct-entity or distinct-operation proof" \
  "CAS retry classification" \
  "Emit-site" \
  "Sibling distinction" \
  "Recommended fix scoped to about 1 hour" \
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
echo "Test 10: domain-qualified focus resolves the duplicate lens ID"
TMP_ROOT="$SCRIPT_DIR/logs/test-logs-race-conditions.$$"
RUN_ID="test-logs-race-conditions-$$"
FAKE_BIN="$TMP_ROOT/bin"
PROJECT_DIR="$TMP_ROOT/project"
LOG_DIR="$TMP_ROOT/runtime-logs"
trap 'rm -rf "$TMP_ROOT" "$SCRIPT_DIR/logs/${RUN_ID}"*' EXIT
mkdir -p "$FAKE_BIN" "$PROJECT_DIR" "$LOG_DIR"
printf '#!/usr/bin/env bash\nprintf "DONE\\n"\n' > "$FAKE_BIN/claude"
chmod +x "$FAKE_BIN/claude"
git init -q "$PROJECT_DIR"
printf '2026-04-25T14:32:01Z worker=a job=42 claim start\n' > "$LOG_DIR/app.log"

focus_output="$(PATH="$FAKE_BIN:$PATH" bash "$SCRIPT_DIR/repolens.sh" \
  --project "$PROJECT_DIR" \
  --agent claude \
  --local \
  --yes \
  --resume "$RUN_ID" \
  --logs "$LOG_DIR" \
  --domain logs \
  --focus race-conditions \
  --dry-run 2>&1)"
focus_rc=$?
assert_eq "domain-qualified focus dry-run exits zero" "0" "$focus_rc"
assert_contains "domain-qualified focus lists logs/race-conditions" "logs/race-conditions" "$focus_output"
assert_not_contains "domain-qualified focus excludes concurrency/race-conditions" "concurrency/race-conditions" "$focus_output"
assert_contains "domain-qualified focus logs absolute logs path" "Logs: $LOG_DIR" "$focus_output"
assert_contains "domain-qualified focus completes dry run" "Dry run complete" "$focus_output"

echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
