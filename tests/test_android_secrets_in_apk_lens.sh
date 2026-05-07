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

# Tests for issue #91 — Android APK secrets lens.
#
# Behavioural contract:
#   - android/secrets-in-apk exists and is registered in config/domains.json.
#   - Shell examples use the exported runtime APK path variable, not direct
#     template interpolation of the APK path inside commands.
#   - Decode output goes under a private per-run scratch tree and is cleaned up,
#     never fixed shared paths for secret-bearing APK contents.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LENS_FILE="$SCRIPT_DIR/prompts/lenses/android/secrets-in-apk.md"
DOMAINS_FILE="$SCRIPT_DIR/config/domains.json"

PASS=0
FAIL=0
TOTAL=0

record_pass() {
  TOTAL=$((TOTAL + 1))
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

record_fail() {
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (missing '$needle')"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (should not contain '$needle')"
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (expected='$expected' actual='$actual')"
  fi
}

echo ""
echo "=== Test Suite: Android APK secrets lens (issue #91) ==="
echo ""

echo "Test 1: lens file exists"
if [[ -f "$LENS_FILE" ]]; then
  record_pass "secrets-in-apk lens file exists"
else
  record_fail "secrets-in-apk lens file exists"
fi

lens_content=""
if [[ -f "$LENS_FILE" ]]; then
  lens_content="$(cat "$LENS_FILE")"
fi

echo ""
echo "Test 2: frontmatter is complete"
assert_contains "id frontmatter" "id: secrets-in-apk" "$lens_content"
assert_contains "domain frontmatter" "domain: android" "$lens_content"
assert_contains "name frontmatter" "name: APK Secrets Hunter" "$lens_content"
assert_contains "role frontmatter" "role: Android Secrets & Credentials Analyst" "$lens_content"

echo ""
echo "Test 3: lens is registered under android deploy domain"
android_lenses="$(jq -r '.domains[] | select(.id == "android") | .lenses | join(",")' "$DOMAINS_FILE")"
assert_eq "registered android lens list" "apk-overview,secrets-in-apk" "$android_lenses"

echo ""
echo "Test 4: investigation commands use shell-safe runtime APK variable"
assert_contains "assigns runtime APK path to local variable" 'apk_path=${ANDROID_APK_PATH:?ANDROID_APK_PATH is required}' "$lens_content"
assert_contains "uses quoted APK variable for unzip inventory" 'unzip -l "$apk_path"' "$lens_content"
assert_contains "uses quoted APK variable for aapt" 'aapt dump badging "$apk_path"' "$lens_content"
assert_contains "uses quoted APK variable for aapt2" 'aapt2 dump badging "$apk_path"' "$lens_content"
assert_contains "uses quoted APK variable for DEX streaming" 'unzip -p "$apk_path" classes.dex | strings' "$lens_content"
assert_contains "uses quoted APK variable for apktool" 'apktool d -f "$apk_path" -o "$apktool_out"' "$lens_content"
assert_contains "uses quoted APK variable for jadx" 'jadx --deobf -d "$jadx_out" "$apk_path"' "$lens_content"
assert_not_contains "does not quote template APK path in commands" '"{{ANDROID_APK_PATH}}"' "$lens_content"

echo ""
echo "Test 5: decoded output uses private per-run scratch directory"
assert_contains "sets restrictive umask for scratch tree" 'umask 077' "$lens_content"
assert_contains "creates unique scratch directory" 'scratch_dir="$(mktemp -d)"' "$lens_content"
assert_contains "places apktool output under scratch tree" 'apktool_out="$scratch_dir/apktool"' "$lens_content"
assert_contains "places jadx output under scratch tree" 'jadx_out="$scratch_dir/jadx"' "$lens_content"
assert_contains "cleans decoded scratch output" 'rm -rf -- "$scratch_dir"' "$lens_content"
assert_not_contains "does not use fixed apktool shared path" "/tmp/apk-secrets" "$lens_content"
assert_not_contains "does not use fixed jadx shared path" "/tmp/apk-jadx" "$lens_content"
assert_not_contains "does not use any hard-coded tmp directory" "/tmp/" "$lens_content"

echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"

if [[ $FAIL -ne 0 ]]; then
  exit 1
fi
exit 0
