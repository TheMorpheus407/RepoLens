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

# Tests for issue #252: PR CI must require CHANGELOG.md changes unless the PR
# body explicitly includes [skip changelog].
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE_SCRIPT="$SCRIPT_DIR/ci/check-changelog-touched.sh"
CI_WORKFLOW="$SCRIPT_DIR/.github/workflows/ci.yml"

PASS=0
FAIL=0
TOTAL=0

pass_with() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

fail_with() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
  [[ -n "${2:-}" ]] && printf '    %s\n' "$2"
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected: $expected; actual: $actual"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected to contain: $needle"
  fi
}

assert_matches() {
  local desc="$1" pattern="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if grep -qE -- "$pattern" <<< "$haystack"; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected to match: $pattern"
  fi
}

run_gate() {
  local changed_files="$1" pr_body="$2"
  local out err
  out="$(mktemp)"
  err="$(mktemp)"
  PR_BODY="$pr_body" bash "$GATE_SCRIPT" <<< "$changed_files" >"$out" 2>"$err"
  LAST_RC=$?
  LAST_OUT="$(cat "$out")"
  LAST_ERR="$(cat "$err")"
  rm -f "$out" "$err"
}

echo ""
echo "=== Test Suite: CHANGELOG PR gate (issue #252) ==="
echo ""

echo "Test 1: changelog gate helper exists"
TOTAL=$((TOTAL + 1))
if [[ -f "$GATE_SCRIPT" ]]; then
  pass_with "ci/check-changelog-touched.sh exists"
else
  fail_with "ci/check-changelog-touched.sh exists"
fi

echo ""
echo "Test 2: PR touching CHANGELOG.md passes"
run_gate $'README.md\nCHANGELOG.md\ntests/test_example.sh' ""
assert_eq "CHANGELOG touch exits 0" "0" "$LAST_RC"
assert_contains "success output names CHANGELOG.md" "CHANGELOG.md was touched." "$LAST_OUT"

echo ""
echo "Test 3: PR without CHANGELOG.md fails"
run_gate $'README.md\ntests/test_example.sh' ""
assert_eq "missing CHANGELOG exits 1" "1" "$LAST_RC"
assert_contains "failure tells contributor how to fix" "Add an [Unreleased] entry or include [skip changelog]" "$LAST_ERR"

echo ""
echo "Test 4: [skip changelog] marker passes without CHANGELOG.md"
run_gate $'README.md\ntests/test_example.sh' "tiny maintenance change [skip changelog]"
assert_eq "skip marker exits 0" "0" "$LAST_RC"
assert_contains "skip output names marker" "[skip changelog]" "$LAST_OUT"

ci_content=""
if [[ -f "$CI_WORKFLOW" ]]; then
  ci_content="$(cat "$CI_WORKFLOW")"
fi

echo ""
echo "Test 5: CI workflow has a pull-request changelog job"
assert_matches "changelog job defined" "^[[:space:]]{2}changelog:" "$ci_content"
assert_contains "job is limited to pull_request events" "github.event_name == 'pull_request'" "$ci_content"

echo ""
echo "Test 6: CI workflow diffs the PR base and head SHAs"
assert_contains "workflow uses pull request base SHA" "github.event.pull_request.base.sha" "$ci_content"
assert_contains "workflow uses pull request head SHA" "github.event.pull_request.head.sha" "$ci_content"
assert_contains "workflow uses git diff --name-only" "git diff --name-only" "$ci_content"

echo ""
echo "Test 7: CI workflow delegates to the tested gate helper"
assert_contains "workflow calls changelog gate helper" "bash ./ci/check-changelog-touched.sh" "$ci_content"
assert_contains "workflow passes PR body to helper" "PR_BODY:" "$ci_content"

echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
