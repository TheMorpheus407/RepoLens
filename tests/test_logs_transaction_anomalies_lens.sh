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

# Tests for issue #170: logs/transaction-anomalies lens registration and prompt contract.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LENS_FILE="$SCRIPT_DIR/prompts/lenses/logs/transaction-anomalies.md"
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
echo "=== Test Suite: logs/transaction-anomalies lens (issue #170) ==="
echo ""

assert_file_exists "transaction-anomalies lens prompt exists" "$LENS_FILE"

lens_content=""
if [[ -f "$LENS_FILE" ]]; then
  lens_content="$(cat "$LENS_FILE")"
fi

echo ""
echo "Test 1: frontmatter is exact"
frontmatter="$(sed -n '1,6p' "$LENS_FILE" 2>/dev/null)"
expected_frontmatter="---
id: transaction-anomalies
domain: logs
name: Transaction Anomaly Detector
role: Atomicity & Consistency Analyst
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
logs_path_count="$(count_fixed '{{LOGS_PATH}}')"
if [[ "$logs_path_count" -ge 1 ]]; then
  PASS=$((PASS + 1))
  TOTAL=$((TOTAL + 1))
  echo "  PASS: uses LOGS_PATH at least once ($logs_path_count occurrences)"
else
  FAIL=$((FAIL + 1))
  TOTAL=$((TOTAL + 1))
  echo "  FAIL: must use LOGS_PATH template variable"
fi
assert_eq "uses no PROJECT_PATH template" "0" "$(count_fixed '{{PROJECT_PATH}}')"

echo ""
echo "Test 3: logs domain registration is audit-visible"
logs_lenses="$(jq -r '.domains[] | select(.id == "logs") | .lenses | join(",")' "$DOMAINS_FILE")"
logs_mode="$(jq -r '.domains[] | select(.id == "logs") | .mode // "null"' "$DOMAINS_FILE")"
assert_eq "logs domain registers expected lenses" "$EXPECTED_LOGS_LENSES" "$logs_lenses"
assert_eq "logs domain stays mode-less" "null" "$logs_mode"
audit_lenses="$(mode_lenses audit)"
assert_contains "audit mode includes logs/transaction-anomalies" "logs/transaction-anomalies" "$audit_lenses"

for mode in discover deploy opensource content; do
  lenses="$(mode_lenses "$mode")"
  assert_not_contains "$mode mode excludes logs/transaction-anomalies" "logs/transaction-anomalies" "$lenses"
done

echo ""
echo "Test 4: required sections appear in order"
focus_line="$(line_no_fixed "## Your Expert Focus")"
hunt_line="$(line_no_fixed "### What You Hunt For")"
investigate_line="$(line_no_fixed "### How You Investigate")"
threshold_line="$(line_no_fixed "### Threshold")"
assert_before "focus before hunt" "$focus_line" "$hunt_line"
assert_before "hunt before investigation" "$hunt_line" "$investigate_line"
assert_before "investigation before threshold" "$investigate_line" "$threshold_line"

echo ""
echo "Test 5: prompt covers required hunt buckets in correct order"
partial_line="$(line_no_fixed "Partial-Commit / Partial-Rollback Messages")"
unresolved_line="$(line_no_fixed "Transactions Started But Not Resolved")"
serialization_line="$(line_no_fixed "Serialization / Isolation Conflicts")"
stalls_line="$(line_no_fixed "Distributed-Transaction Stalls")"
saga_line="$(line_no_fixed "Saga / Compensator Misfires")"
assert_before "partial-commit before unresolved" "$partial_line" "$unresolved_line"
assert_before "unresolved before serialization" "$unresolved_line" "$serialization_line"
assert_before "serialization before stalls" "$serialization_line" "$stalls_line"
assert_before "stalls before saga" "$stalls_line" "$saga_line"

echo ""
echo "Test 6: prompt names protocol-failure vocabulary"
for term in \
  "in-doubt" \
  "heuristic commit" \
  "rollback failed" \
  "partial commit" \
  "transaction log corrupt" \
  "could not serialize access" \
  "Lock wait timeout" \
  "interrupted pack" \
  "PREPARE" \
  "saga"; do
  assert_contains "names protocol-failure term: $term" "$term" "$lens_content"
done

echo ""
echo "Test 7: prompt distinguishes anomalies from designed-failure paths"
assert_contains "names designed-failure exclusion" "designed-failure" "$lens_content"
assert_contains "exempts validation-driven rollback" "validation" "$lens_content"
assert_contains "names CHECK constraint exemption" "CHECK constraint" "$lens_content"

echo ""
echo "Test 8: prompt sets filing thresholds and sibling boundaries"
assert_contains "files at N=1 for explicit protocol failures" "N=1" "$lens_content"
assert_contains "aggregates serialization at N>=3" "N≥3" "$lens_content"
assert_contains "sibling: deadlock-symptoms" "deadlock-symptoms" "$lens_content"
assert_contains "sibling: silent-failures" "silent-failures" "$lens_content"
assert_contains "sibling: state-corruption" "state-corruption" "$lens_content"
assert_contains "sibling: state-machine-violations" "state-machine-violations" "$lens_content"
assert_contains "sibling: data-loss-signals" "data-loss-signals" "$lens_content"
assert_contains "sibling: database/transaction-safety" "database/transaction-safety" "$lens_content"

echo ""
echo "Test 9: prompt requires evidence fields and redaction contract"
for term in \
  "transaction vocabulary" \
  "correlation field" \
  "Recurrence" \
  "paired sample" \
  "Sibling distinction" \
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
echo "Test 10: prompt avoids forbidden tool-specific commands"
forbidden_hits="$(grep -nE '\b(grep|awk|sed|jq|journalctl|dmesg)\b' "$LENS_FILE" 2>/dev/null || true)"
TOTAL=$((TOTAL + 1))
if [[ -z "$forbidden_hits" ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: prompt is tool-agnostic (no whole-word grep/awk/sed/jq/journalctl/dmesg)"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: prompt mentions forbidden tools as whole words:"
  echo "$forbidden_hits"
fi

echo ""
echo "Test 11: domain-qualified focus resolves the lens via dry-run"
TMP_ROOT="$SCRIPT_DIR/logs/test-logs-transaction-anomalies.$$"
RUN_ID="test-logs-transaction-anomalies-$$"
FAKE_BIN="$TMP_ROOT/bin"
PROJECT_DIR="$TMP_ROOT/project"
LOG_DIR="$TMP_ROOT/runtime-logs"
trap 'rm -rf "$TMP_ROOT" "$SCRIPT_DIR/logs/${RUN_ID}"*' EXIT
mkdir -p "$FAKE_BIN" "$PROJECT_DIR" "$LOG_DIR"
printf '#!/usr/bin/env bash\nprintf "DONE\\n"\n' > "$FAKE_BIN/claude"
chmod +x "$FAKE_BIN/claude"
git init -q "$PROJECT_DIR"
printf '2026-04-25T14:32:01Z db: BEGIN tx=42\n' > "$LOG_DIR/app.log"

focus_output="$(PATH="$FAKE_BIN:$PATH" bash "$SCRIPT_DIR/repolens.sh" \
  --project "$PROJECT_DIR" \
  --agent claude \
  --local \
  --yes \
  --resume "$RUN_ID" \
  --logs "$LOG_DIR" \
  --domain logs \
  --focus transaction-anomalies \
  --dry-run 2>&1)"
focus_rc=$?
assert_eq "domain-qualified focus dry-run exits zero" "0" "$focus_rc"
assert_contains "domain-qualified focus lists logs/transaction-anomalies" "logs/transaction-anomalies" "$focus_output"
assert_contains "domain-qualified focus logs absolute logs path" "Logs: $LOG_DIR" "$focus_output"
assert_contains "domain-qualified focus completes dry run" "Dry run complete" "$focus_output"

echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
