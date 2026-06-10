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

# Tests for CLAUDE.md project instructions inventory counts.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLAUDE_FILE="$SCRIPT_DIR/CLAUDE.md"
DOMAINS_FILE="$SCRIPT_DIR/config/domains.json"

PASS=0
FAIL=0
TOTAL=0

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    Expected to contain: $needle"
  fi
}

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

echo ""
echo "=== Test Suite: CLAUDE.md project instructions ==="
echo ""

assert_file_exists "CLAUDE.md exists" "$CLAUDE_FILE"
assert_file_exists "domains.json exists" "$DOMAINS_FILE"

claude_content=""
if [[ -f "$CLAUDE_FILE" ]]; then
  claude_content="$(cat "$CLAUDE_FILE")"
fi

total_lenses="$(jq '[.domains[].lenses | length] | add' "$DOMAINS_FILE")"
code_analysis_count="$(jq '[.domains[] | select((.mode // "default") == "default") | select(.id != "toolgate" and .id != "logs") | .lenses | length] | add' "$DOMAINS_FILE")"
toolgate_count="$(jq '[.domains[] | select(.id == "toolgate") | .lenses | length] | add' "$DOMAINS_FILE")"
logs_count="$(jq '[.domains[] | select(.id == "logs") | .lenses | length] | add' "$DOMAINS_FILE")"
discovery_count="$(jq '[.domains[] | select(.mode == "discover") | .lenses | length] | add' "$DOMAINS_FILE")"
deployment_count="$(jq '[.domains[] | select(.mode == "deploy") | .lenses | length] | add' "$DOMAINS_FILE")"
opensource_count="$(jq '[.domains[] | select(.mode == "opensource") | .lenses | length] | add' "$DOMAINS_FILE")"
content_count="$(jq '[.domains[] | select(.mode == "content") | .lenses | length] | add' "$DOMAINS_FILE")"
greenfield_count="$(jq '[.domains[] | select(.mode == "greenfield") | .lenses | length] | add' "$DOMAINS_FILE")"
polish_count="$(jq '[.domains[] | select(.mode == "polish") | .lenses | length] | add' "$DOMAINS_FILE")"
breakdown_total="$((code_analysis_count + toolgate_count + logs_count + discovery_count + deployment_count + opensource_count + content_count))"
documented_total="$((total_lenses - greenfield_count - polish_count))"

echo ""
echo "Test 1: CLAUDE.md headline count matches domains.json"
assert_contains "headline has documented analysis lens count" "runs $documented_total expert analysis agents" "$claude_content"

echo ""
echo "Test 2: CLAUDE.md prompt inventory count matches domains.json"
assert_contains "prompt inventory has documented analysis lens count" "($documented_total expert prompts)" "$claude_content"

echo ""
echo "Test 3: CLAUDE.md category breakdown matches domains.json"
assert_eq "category breakdown sums to documented total" "$documented_total" "$breakdown_total"
assert_contains "code analysis count matches" "$code_analysis_count code analysis" "$claude_content"
assert_contains "tool gate count matches" "$toolgate_count tool gate" "$claude_content"
assert_contains "runtime log count matches" "$logs_count runtime log" "$claude_content"
assert_contains "product discovery count matches" "$discovery_count product discovery" "$claude_content"
assert_contains "deployment/android count matches" "$deployment_count deployment and Android audit" "$claude_content"
assert_contains "open-source readiness count matches" "$opensource_count open-source readiness" "$claude_content"
assert_contains "content quality count matches" "$content_count content quality" "$claude_content"

echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
