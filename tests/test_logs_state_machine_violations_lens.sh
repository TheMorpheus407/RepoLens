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

# Tests for issue #139: logs/state-machine-violations lens registration and prompt contract.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LENS_FILE="$SCRIPT_DIR/prompts/lenses/logs/state-machine-violations.md"
DOMAINS_FILE="$SCRIPT_DIR/config/domains.json"
EXPECTED_LOGS_LENSES="error-storms,error-cascades,retry-loops,recursive-growth,resource-leaks,resource-exhaustion,log-gaps,missing-heartbeats,silent-failures,state-machine-violations,lifecycle-violations,process-orphans,latency-degradation,clock-skew,timeout-clusters"

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

assert_matches() {
  local desc="$1" pattern="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" =~ $pattern ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    Pattern not found: $pattern"
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

assert_exit_code() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" -eq "$actual" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    Expected exit code: $expected, got: $actual"
  fi
}

line_no_regex() {
  local pattern="$1"
  grep -nE "$pattern" "$LENS_FILE" 2>/dev/null | head -1 | cut -d: -f1
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
echo "=== Test Suite: logs/state-machine-violations lens (issue #139) ==="
echo ""

assert_file_exists "state-machine-violations lens prompt exists" "$LENS_FILE"

lens_content=""
if [[ -f "$LENS_FILE" ]]; then
  lens_content="$(cat "$LENS_FILE")"
fi

echo ""
echo "Test 1: frontmatter is exact"
frontmatter="$(sed -n '1,6p' "$LENS_FILE" 2>/dev/null)"
expected_frontmatter="---
id: state-machine-violations
domain: logs
name: State Machine Violation Detector
role: State Transition Analyst
---"
assert_eq "frontmatter matches issue contract" "$expected_frontmatter" "$frontmatter"

echo ""
echo "Test 2: prompt length is in the requested band"
if [[ -f "$LENS_FILE" ]]; then
  line_count="$(wc -l < "$LENS_FILE")"
else
  line_count=0
fi
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
assert_eq "logs domain registers all expected lenses" "$EXPECTED_LOGS_LENSES" "$logs_lenses"
assert_eq "logs domain stays mode-less" "null" "$logs_mode"
audit_lenses="$(mode_lenses audit)"
assert_contains "audit mode includes logs/state-machine-violations" "logs/state-machine-violations" "$audit_lenses"

for mode in discover deploy opensource content; do
  lenses="$(mode_lenses "$mode")"
  assert_not_contains "$mode mode excludes logs/state-machine-violations" "logs/state-machine-violations" "$lenses"
done

echo ""
echo "Test 4: sections appear in required order"
focus_line="$(line_no_regex '^## Your Expert Focus$')"
hunt_line="$(line_no_regex '^### What You Hunt For$')"
investigate_line="$(line_no_regex '^### How You Investigate$')"
evidence_line="$(line_no_regex '^### Evidence')"
threshold_line="$(line_no_regex '^### Threshold')"
assert_before "focus before hunt" "$focus_line" "$hunt_line"
assert_before "hunt before investigation" "$hunt_line" "$investigate_line"
assert_before "investigation before evidence" "$investigate_line" "$evidence_line"
assert_before "evidence before threshold" "$evidence_line" "$threshold_line"

echo ""
echo "Test 5: prompt covers the five required violation buckets"
for term in \
  "Illegal direct transitions" \
  "skipping mandatory intermediate states" \
  "Simultaneous incompatible states" \
  "Missing transition events between observed states" \
  "State regression" \
  "Cross-component state inconsistency"; do
  assert_contains "mentions $term" "$term" "$lens_content"
done

echo ""
echo "Test 6: investigation derives the state machine before log checks"
first_step="$(sed -n '/^1\. /p' "$LENS_FILE" 2>/dev/null)"
assert_contains "first step derives state machine first" "Derive the state machine first" "$first_step"
assert_contains "first step says log evidence comes second" "log evidence second" "$first_step"
for term in \
  "CLAUDE.md" \
  "README" \
  "docs/" \
  "enums" \
  "status fields" \
  "state-transition functions" \
  "{{LOGS_PATH}}" \
  "observed sequence" \
  "legal transition graph"; do
  assert_contains "investigation mentions $term" "$term" "$lens_content"
done

echo ""
echo "Test 7: prompt requires enough evidence to file a real finding"
for term in \
  "entity type" \
  "state machine source" \
  "file path and line range" \
  "documented or inferred" \
  "legal transition set" \
  "terminal states" \
  "mutually exclusive states" \
  "required transition-event" \
  "raw" \
  "timestamp" \
  "entity ID" \
  "broken rule" \
  "Emit-site" \
  "both emit-sites" \
  "log gaps" \
  "rotation" \
  "dropped" \
  "namespace collisions"; do
  assert_contains "requires evidence term $term" "$term" "$lens_content"
done

echo ""
echo "Test 8: prompt states documented-vs-inferred thresholds and exclusions"
assert_matches "mentions documented graph threshold" '(Documented state machine|Documented graph)' "$lens_content"
assert_matches "documents N=1 threshold" 'N[[:space:]]*=[[:space:]]*1' "$lens_content"
assert_matches "mentions inferred graph threshold" '(Inferred state machine|Inferred graph)' "$lens_content"
assert_matches "documents N>=2 threshold" 'N[[:space:]]*(>=|≥)[[:space:]]*2' "$lens_content"
for term in \
  "docs allow the transition" \
  "log gap" \
  "entity IDs collide"; do
  assert_contains "threshold excludes $term" "$term" "$lens_content"
done

echo ""
echo "Test 9: prompt stays log-path driven and tool-agnostic"
assert_contains "uses LOGS_PATH variable" "{{LOGS_PATH}}" "$lens_content"
for term in "journalctl" "grep" "awk" "/var/log"; do
  assert_not_contains "does not prescribe $term" "$term" "$lens_content"
done
for term in \
  "redact" \
  "<TOKEN>" \
  "<EMAIL>" \
  "<API_KEY>" \
  "<PASSWORD>" \
  "<PII_REDACTED>"; do
  assert_contains "mentions redaction term $term" "$term" "$lens_content"
done

echo ""
echo "Test 10: --focus loads the new logs lens through the dispatcher"
TMP_ROOT="$SCRIPT_DIR/logs/test-logs-state-machine-violations.$$"
RUN_ID="test-logs-state-machine-violations-$$"
FAKE_BIN="$TMP_ROOT/bin"
PROJECT_DIR="$TMP_ROOT/project"
LOG_DIR="$TMP_ROOT/runtime-logs"
mkdir -p "$FAKE_BIN" "$PROJECT_DIR" "$LOG_DIR"
trap 'rm -rf "$TMP_ROOT" "$SCRIPT_DIR/logs/${RUN_ID}"*' EXIT

cat > "$FAKE_BIN/claude" <<'EOF'
#!/usr/bin/env bash
echo "DONE"
EOF
chmod +x "$FAKE_BIN/claude"
git init -q "$PROJECT_DIR"
printf '2026-01-01T00:00:00Z order_id=42 status=pending\n2026-01-01T00:00:01Z order_id=42 status=completed\n' > "$LOG_DIR/app.log"

focus_output="$(PATH="$FAKE_BIN:$PATH" bash "$SCRIPT_DIR/repolens.sh" \
  --project "$PROJECT_DIR" \
  --agent claude \
  --local \
  --yes \
  --resume "$RUN_ID" \
  --focus state-machine-violations \
  --logs "$LOG_DIR" \
  --dry-run 2>&1)"
focus_rc=$?
assert_exit_code "--focus dry-run exits zero" 0 "$focus_rc"
assert_contains "--focus selects one lens" "Lenses:       1" "$focus_output"
assert_contains "--focus lists state-machine-violations" "logs/state-machine-violations" "$focus_output"
assert_contains "--focus logs absolute logs path" "Logs: $LOG_DIR" "$focus_output"

echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
