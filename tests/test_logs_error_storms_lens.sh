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

# Tests for issue #130: logs/error-storms lens registration and prompt contract.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LENS_FILE="$SCRIPT_DIR/prompts/lenses/logs/error-storms.md"
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
echo "=== Test Suite: logs/error-storms lens (issue #130) ==="
echo ""

assert_file_exists "error-storms lens prompt exists" "$LENS_FILE"

lens_content=""
if [[ -f "$LENS_FILE" ]]; then
  lens_content="$(cat "$LENS_FILE")"
fi

echo ""
echo "Test 1: frontmatter is exact"
frontmatter="$(sed -n '1,6p' "$LENS_FILE" 2>/dev/null)"
expected_frontmatter="---
id: error-storms
domain: logs
name: Error Storm Detector
role: Error Pattern Analyst
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
assert_eq "logs domain registers logs lenses" "error-storms,error-cascades,retry-loops,recursive-growth,resource-leaks,resource-exhaustion,log-gaps,missing-heartbeats,silent-failures,state-machine-violations,lifecycle-violations,process-orphans,latency-degradation" "$logs_lenses"
assert_eq "logs domain stays mode-less" "null" "$logs_mode"
audit_lenses="$(mode_lenses audit)"
assert_contains "audit mode includes logs/error-storms" "logs/error-storms" "$audit_lenses"

for mode in discover deploy opensource content; do
  lenses="$(mode_lenses "$mode")"
  assert_not_contains "$mode mode excludes logs/error-storms" "logs/error-storms" "$lenses"
done

echo ""
echo "Test 4: prompt uses generic LOGS_PATH input"
assert_contains "uses LOGS_PATH variable" '{{LOGS_PATH}}' "$lens_content"
assert_not_contains "does not prescribe journalctl" "journalctl" "$lens_content"
assert_not_contains "does not prescribe /var/log" "/var/log" "$lens_content"
assert_contains "accepts single file" "single file" "$lens_content"
assert_contains "accepts directory" "directory" "$lens_content"

echo ""
echo "Test 5: prompt covers required storm categories"
for term in \
  "Identical-Fingerprint Storms" \
  "Near-Duplicate Clusters with Rotating Identifiers" \
  "Time-Window Bursts" \
  "Sustained Low-Rate Noise That Adds Up" \
  "Storm-Then-Silence Patterns"; do
  assert_contains "mentions $term" "$term" "$lens_content"
done

echo ""
echo "Test 6: prompt covers required thresholds"
for term in \
  ">= 10 occurrences in any rolling 24-hour window" \
  ">= 3 distinct sessions / runs / PIDs / hostnames" \
  "sustained > 5/hour for > 2 hours" \
  ">= 50 occurrences in any rolling 5-minute burst"; do
  assert_contains "mentions threshold $term" "$term" "$lens_content"
done

echo ""
echo "Test 7: prompt requires evidence fields"
for term in \
  "sanitized event fingerprint" \
  "2-3 sanitized raw exemplar lines" \
  "count" \
  "First-seen" \
  "last-seen" \
  "ISO-8601" \
  "grep -Rn" \
  "path/to/file.ext:LINE"; do
  assert_contains "requires evidence $term" "$term" "$lens_content"
done

echo ""
echo "Test 8: redaction contract covers every exported artifact"
for term in \
  "event fingerprints" \
  "deduplication search strings" \
  "issue titles" \
  "issue bodies" \
  "source snippets" \
  "log snippets" \
  "Recommended Fix context"; do
  assert_contains "redaction applies to $term" "$term" "$lens_content"
done

for placeholder in \
  "<TOKEN>" \
  "<COOKIE>" \
  "<EMAIL>" \
  "<API_KEY>" \
  "<PASSWORD>" \
  "<REQUEST_BODY_REDACTED>" \
  "<PII_REDACTED>"; do
  assert_contains "defines placeholder $placeholder" "$placeholder" "$lens_content"
done

assert_contains "stable secrets are forbidden in fingerprint" "If a sensitive value is stable across the storm, it is still not allowed in the fingerprint" "$lens_content"
assert_contains "fingerprint replaces sensitive values" "rotating fields and sensitive values replaced by placeholders" "$lens_content"

echo ""
echo "Test 9: dedup search is sanitized before gh issue list"
assert_contains "requires gh issue list dedup" "gh issue list --state open --limit 100 --search" "$lens_content"
assert_contains "uses sanitized non-sensitive search phrase" "Build a sanitized, non-sensitive search phrase" "$lens_content"
assert_contains "search from static text" "static text, an error code, an event name, or a format-string fragment" "$lens_content"
assert_contains "forbids sensitive values in gh search" 'Do not pass credentials, bearer/session tokens, cookies, emails, request bodies, API keys, passwords, or other PII/secrets to `gh issue list --search`' "$lens_content"
assert_not_contains "does not suggest raw fingerprint search" "--search \"<event fingerprint substring>\"" "$lens_content"

echo ""
echo "Test 10: prompt references dedup, severity, and out-of-scope limits"
for term in \
  "File one issue per distinct fingerprint" \
  "[CRITICAL]" \
  "[HIGH]" \
  "[MEDIUM]" \
  "[LOW]" \
  "Single-occurrence errors" \
  "Silent-failure" \
  "Log rotation" \
  "Security log investigations" \
  "Log-injection"; do
  assert_contains "mentions $term" "$term" "$lens_content"
done

echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
