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

# Tests for issue #168: lib/verify.sh — validate_verification_manifest and
# run_verifier. All agent invocations are stubbed via _VERIFIER_AGENT_CALLBACK
# so no real model is ever invoked (per CLAUDE.md::Tests).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY_LIB="$SCRIPT_DIR/lib/verify.sh"
TEMPLATE_LIB="$SCRIPT_DIR/lib/template.sh"
CORE_LIB="$SCRIPT_DIR/lib/core.sh"
LOGGING_LIB="$SCRIPT_DIR/lib/logging.sh"

PASS=0
FAIL=0
TOTAL=0

TMP_PARENT="$SCRIPT_DIR/logs/test-verify"
mkdir -p "$TMP_PARENT"
TMPDIR="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"

cleanup() {
  rm -rf "$TMPDIR"
  rmdir "$TMP_PARENT" 2>/dev/null || true
}
trap cleanup EXIT

pass_with() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

fail_with() {
  local desc="$1" detail="${2:-}"
  FAIL=$((FAIL + 1))
  echo "  FAIL: $desc"
  if [[ -n "$detail" ]]; then
    printf '    %s\n' "$detail"
  fi
}

assert_success() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -eq 0 ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected exit 0, got $actual"
  fi
}

assert_failure() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -ne 0 ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected non-zero exit"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Did not find '$needle' in: $haystack"
  fi
}

assert_file_exists() {
  local desc="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$path" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected file $path"
  fi
}

assert_file_missing() {
  local desc="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [[ ! -e "$path" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Did not expect file $path"
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected '$expected', got '$actual'"
  fi
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

if [[ ! -f "$VERIFY_LIB" ]]; then
  echo "  FAIL: lib/verify.sh missing at $VERIFY_LIB"
  exit 1
fi

# shellcheck disable=SC1090
source "$LOGGING_LIB"
# shellcheck disable=SC1090
source "$TEMPLATE_LIB"
# shellcheck disable=SC1090
source "$CORE_LIB"
# shellcheck disable=SC1090
source "$VERIFY_LIB"

echo "=== validate_verification_manifest ==="

# Case: empty array is valid
empty_path="$TMPDIR/empty.json"
printf '[]\n' > "$empty_path"
validate_verification_manifest "$empty_path" 2>"$TMPDIR/empty.err"
assert_success "empty array validates" "$?"

# Case: well-formed single entry
single_path="$TMPDIR/single.json"
cat > "$single_path" <<'JSON'
[
  {
    "finding_id": "abcdef0123456789",
    "status": "VERIFIED",
    "notes": "Line 42 contains the cited symbol foo()",
    "lens_id": "input-validation",
    "domain": "code",
    "round": 1,
    "source_finding_path": "logs/run-1/rounds/round-1/lens-outputs/code/input-validation.md"
  }
]
JSON
validate_verification_manifest "$single_path" 2>"$TMPDIR/single.err"
assert_success "single VERIFIED entry validates" "$?"

# Case: mixed statuses are all valid
mixed_path="$TMPDIR/mixed.json"
cat > "$mixed_path" <<'JSON'
[
  { "finding_id": "aaa1111111111111", "status": "VERIFIED", "notes": "matched" },
  { "finding_id": "bbb2222222222222", "status": "STALE", "notes": "found 8 lines below" },
  { "finding_id": "ccc3333333333333", "status": "WRONG", "notes": "file not found" }
]
JSON
validate_verification_manifest "$mixed_path" 2>"$TMPDIR/mixed.err"
assert_success "mixed statuses validate" "$?"

# Case: invalid status rejected
bad_status="$TMPDIR/bad-status.json"
cat > "$bad_status" <<'JSON'
[
  { "finding_id": "abc1111111111111", "status": "MAYBE", "notes": "x" }
]
JSON
validate_verification_manifest "$bad_status" 2>"$TMPDIR/bad-status.err"
assert_failure "invalid status rejected" "$?"
assert_contains "bad-status error mentions status" "status" "$(cat "$TMPDIR/bad-status.err")"

# Case: missing finding_id rejected
missing_id="$TMPDIR/missing-id.json"
cat > "$missing_id" <<'JSON'
[
  { "status": "VERIFIED", "notes": "x" }
]
JSON
validate_verification_manifest "$missing_id" 2>"$TMPDIR/missing-id.err"
assert_failure "missing finding_id rejected" "$?"
assert_contains "missing-id error mentions finding_id" "finding_id" "$(cat "$TMPDIR/missing-id.err")"

# Case: empty notes rejected
empty_notes="$TMPDIR/empty-notes.json"
cat > "$empty_notes" <<'JSON'
[
  { "finding_id": "abc1111111111111", "status": "VERIFIED", "notes": "" }
]
JSON
validate_verification_manifest "$empty_notes" 2>"$TMPDIR/empty-notes.err"
assert_failure "empty notes rejected" "$?"
assert_contains "empty-notes error mentions notes" "notes" "$(cat "$TMPDIR/empty-notes.err")"

# Case: not JSON at all
junk_path="$TMPDIR/junk.json"
printf 'not json\n' > "$junk_path"
validate_verification_manifest "$junk_path" 2>"$TMPDIR/junk.err"
assert_failure "non-JSON rejected" "$?"

# Case: top-level object rejected (must be array)
obj_path="$TMPDIR/obj.json"
printf '{}\n' > "$obj_path"
validate_verification_manifest "$obj_path" 2>"$TMPDIR/obj.err"
assert_failure "top-level object rejected" "$?"

# Case: duplicate finding_id rejected
dup_path="$TMPDIR/dup.json"
cat > "$dup_path" <<'JSON'
[
  { "finding_id": "same1111111111aa", "status": "VERIFIED", "notes": "first" },
  { "finding_id": "same1111111111aa", "status": "STALE",    "notes": "second" }
]
JSON
validate_verification_manifest "$dup_path" 2>"$TMPDIR/dup.err"
assert_failure "duplicate finding_id rejected" "$?"
assert_contains "duplicate error mentions duplicate" "duplicate" "$(cat "$TMPDIR/dup.err")"

# Case: missing path
validate_verification_manifest "" 2>"$TMPDIR/missing.err"
assert_failure "missing path rejected" "$?"

echo ""
echo "=== run_verifier dispatcher ==="

# Set up a minimal run layout under TMPDIR
RUN_ID="test-run-168"
LOG_BASE="$TMPDIR/logs/$RUN_ID"
ROUNDS_DIR="$LOG_BASE/rounds/round-1/lens-outputs"
FINAL_DIR="$LOG_BASE/final"
mkdir -p "$ROUNDS_DIR" "$FINAL_DIR"

# A real project path (the verifier insists it exists as a directory)
PROJECT_PATH="$TMPDIR/project"
mkdir -p "$PROJECT_PATH"
printf 'foo function bar\n' > "$PROJECT_PATH/sample.go"

# Required globals for run_verifier
AGENT="claude"
export RUN_ID LOG_BASE PROJECT_PATH AGENT

# Case 1: zero findings → run_verifier writes [] and returns 0 without invoking the agent
_verifier_callback_fail() {
  echo "callback should not have been invoked when there are no findings" >&2
  return 1
}
_VERIFIER_AGENT_CALLBACK=_verifier_callback_fail
run_verifier "$RUN_ID" >"$TMPDIR/zero.out" 2>"$TMPDIR/zero.err"
status=$?
assert_success "zero findings returns 0" "$status"
assert_file_exists "zero findings: verification.json exists" "$FINAL_DIR/verification.json"
assert_eq "zero findings: verification.json is []" "[]" "$(jq -c '.' "$FINAL_DIR/verification.json")"

# Case 2: one finding + happy-path callback → manifest is promoted
cat > "$ROUNDS_DIR/sample-lens.md" <<'MD'
---
lens_id: sample-lens
domain: code
round: 1
severity: high
confidence: medium
root_cause_category: missing-validation
suspect_files:
  - sample.go:1
---
## suspect_files
- sample.go:1 — unguarded handler entry
## hypothesis
Unsanitized input reaches the handler.
## evidence
- sample.go:1 contains `foo function bar`.
## next_steps_for_synthesizer
Add input validation.
MD

_verifier_callback_ok() {
  cat <<'JSON'
[
  {
    "finding_id": "0123456789abcdef",
    "status": "VERIFIED",
    "notes": "sample.go:1 contains 'foo function bar' matching the hypothesis",
    "lens_id": "sample-lens",
    "domain": "code",
    "round": 1,
    "source_finding_path": "logs/test-run-168/rounds/round-1/lens-outputs/sample-lens.md"
  }
]
DONE
JSON
}
_VERIFIER_AGENT_CALLBACK=_verifier_callback_ok
rm -f "$FINAL_DIR/verification.json"
run_verifier "$RUN_ID" >"$TMPDIR/ok.out" 2>"$TMPDIR/ok.err"
status=$?
assert_success "happy-path run_verifier returns 0" "$status"
assert_file_exists "happy-path: verification.json exists" "$FINAL_DIR/verification.json"
assert_eq "happy-path: one entry" "1" "$(jq 'length' "$FINAL_DIR/verification.json")"
assert_eq "happy-path: status is VERIFIED" "VERIFIED" "$(jq -r '.[0].status' "$FINAL_DIR/verification.json")"

# Case 3: callback emits invalid JSON → validation fails, manifest is removed
_verifier_callback_bad_status() {
  cat <<'JSON'
[
  { "finding_id": "deadbeefdeadbeef", "status": "GARBAGE", "notes": "x" }
]
JSON
}
_VERIFIER_AGENT_CALLBACK=_verifier_callback_bad_status
run_verifier "$RUN_ID" >"$TMPDIR/bad.out" 2>"$TMPDIR/bad.err"
status=$?
assert_failure "invalid status returns non-zero" "$status"
assert_file_missing "invalid status: no consumable manifest" "$FINAL_DIR/verification.json"

# Case 4: callback emits no JSON array → returns non-zero
_verifier_callback_no_json() {
  printf 'I have nothing to say\nDONE\n'
}
_VERIFIER_AGENT_CALLBACK=_verifier_callback_no_json
run_verifier "$RUN_ID" >"$TMPDIR/nojson.out" 2>"$TMPDIR/nojson.err"
status=$?
assert_failure "no JSON array returns non-zero" "$status"
assert_file_missing "no JSON: no consumable manifest" "$FINAL_DIR/verification.json"

# Case 5: missing AGENT
unset AGENT
_VERIFIER_AGENT_CALLBACK=_verifier_callback_ok
run_verifier "$RUN_ID" >"$TMPDIR/noagent.out" 2>"$TMPDIR/noagent.err"
status=$?
assert_failure "missing AGENT returns non-zero" "$status"
assert_contains "missing AGENT error message" "AGENT" "$(cat "$TMPDIR/noagent.err")"
AGENT="claude"

# Case 6: missing PROJECT_PATH
saved_path="$PROJECT_PATH"
PROJECT_PATH="$TMPDIR/does-not-exist"
run_verifier "$RUN_ID" >"$TMPDIR/nopath.out" 2>"$TMPDIR/nopath.err"
status=$?
assert_failure "missing PROJECT_PATH returns non-zero" "$status"
PROJECT_PATH="$saved_path"

# Case 7: missing run_id
run_verifier "" >"$TMPDIR/norun.out" 2>"$TMPDIR/norun.err"
status=$?
assert_failure "missing run_id returns non-zero" "$status"

# Case 8: multi-finding file should still drive one verifier invocation (the
# dispatcher batches all findings into one prompt). The callback gets called
# exactly once; we count calls via a counter file.
COUNTER_FILE="$TMPDIR/counter"
echo "0" > "$COUNTER_FILE"
_verifier_callback_count() {
  local n
  n="$(cat "$COUNTER_FILE")"
  printf '%d\n' "$((n + 1))" > "$COUNTER_FILE"
  cat <<'JSON'
[
  { "finding_id": "multi111111111aa", "status": "VERIFIED", "notes": "first finding ok" },
  { "finding_id": "multi222222222bb", "status": "STALE",    "notes": "second finding line moved" }
]
JSON
}

cat > "$ROUNDS_DIR/multi-lens.md" <<'MD'
---
lens_id: multi-lens
domain: code
round: 1
severity: medium
confidence: medium
root_cause_category: race-condition
suspect_files:
  - sample.go:1
---
## suspect_files
- sample.go:1 — first finding
## hypothesis
First race.
## evidence
- sample.go:1
## next_steps_for_synthesizer
Merge.
---
lens_id: multi-lens
domain: code
round: 1
severity: low
confidence: low
root_cause_category: race-condition
suspect_files:
  - sample.go:1
---
## suspect_files
- sample.go:1 — second finding
## hypothesis
Second race.
## evidence
- sample.go:1
## next_steps_for_synthesizer
Merge.
MD

_VERIFIER_AGENT_CALLBACK=_verifier_callback_count
rm -f "$FINAL_DIR/verification.json"
run_verifier "$RUN_ID" >"$TMPDIR/multi.out" 2>"$TMPDIR/multi.err"
status=$?
assert_success "multi-finding returns 0" "$status"
assert_eq "multi-finding: callback called exactly once" "1" "$(cat "$COUNTER_FILE")"
assert_eq "multi-finding: two entries in manifest" "2" "$(jq 'length' "$FINAL_DIR/verification.json")"

echo ""
echo "=== _verify_extract_json_array ==="

# Plain array
plain="$(_verify_extract_json_array '[{"finding_id":"a","status":"VERIFIED","notes":"x"}]')"
assert_eq "extract plain array" '[{"finding_id":"a","status":"VERIFIED","notes":"x"}]' "$plain"

# Array wrapped in markdown fences with prose around it
fenced=$'Here is the result:\n```json\n[{"finding_id":"a","status":"WRONG","notes":"x"}]\n```\nDONE'
extracted="$(_verify_extract_json_array "$fenced")"
assert_eq "extract fenced array" '[{"finding_id":"a","status":"WRONG","notes":"x"}]' "$extracted"

# No JSON array → returns 1
_verify_extract_json_array 'no json at all' >"$TMPDIR/extract-empty.out" 2>"$TMPDIR/extract-empty.err"
status=$?
assert_failure "no JSON array returns non-zero from extractor" "$status"

finish
