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

# Tests for issue #97 - Android APK dependency CVE lens.
#
# Behavioural contract:
#   - android/apk-dependencies exists and is registered in config/domains.json.
#   - The prompt covers bundled APK third-party dependency inventory and known
#     CVE analysis across Java/Kotlin, native, SDK, and cross-platform runtimes.
#   - Shell examples use the exported runtime APK path variable through a
#     local shell variable, not fixed shared decode paths.
#   - Examples remain read-only and avoid active device/app mutation commands.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LENS_FILE="$SCRIPT_DIR/prompts/lenses/android/apk-dependencies.md"
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

echo ""
echo "=== Test Suite: Android APK dependency CVE lens (issue #97) ==="
echo ""

echo "Test 1: lens file exists"
if [[ -f "$LENS_FILE" ]]; then
  record_pass "apk-dependencies lens file exists"
else
  record_fail "apk-dependencies lens file exists"
fi

lens_content=""
if [[ -f "$LENS_FILE" ]]; then
  lens_content="$(cat "$LENS_FILE")"
fi

echo ""
echo "Test 2: frontmatter is complete"
assert_contains "id frontmatter" "id: apk-dependencies" "$lens_content"
assert_contains "domain frontmatter" "domain: android" "$lens_content"
assert_contains "name frontmatter" "name: APK Dependency CVE Analyst" "$lens_content"
assert_contains "role frontmatter" "role: APK Bundled Library Vulnerability Specialist" "$lens_content"

echo ""
echo "Test 3: lens is registered under android deploy domain"
android_lenses="$(jq -r '.domains[] | select(.id == "android") | .lenses[]' "$DOMAINS_FILE")"
assert_contains "registered android lens list includes apk-dependencies" "apk-dependencies" "$android_lenses"

echo ""
echo "Test 4: requested dependency families and CVE workflow are covered"
for term in \
  "AndroidX" \
  "Jetpack" \
  "OkHttp" \
  "Retrofit" \
  "Gson" \
  "Firebase" \
  "Play Services" \
  "ProviderInstaller" \
  "Glide" \
  "Picasso" \
  "Coil" \
  "Apache HTTP" \
  "commons-io" \
  "Realm" \
  "SQLCipher" \
  "Kotlin stdlib" \
  "protobuf" \
  "gRPC" \
  "native" \
  ".so" \
  "React Native" \
  "Flutter" \
  "Cordova" \
  "OSV" \
  "CVE" \
  "Maven"; do
  assert_contains "covers $term" "$term" "$lens_content"
done

echo ""
echo "Test 5: investigation commands use shell-safe runtime APK variable"
assert_contains "assigns runtime APK path to local variable" 'apk_path=${ANDROID_APK_PATH:?ANDROID_APK_PATH is required}' "$lens_content"
assert_contains "checks quoted APK path exists" '[ -f "$apk_path" ]' "$lens_content"
assert_contains "uses quoted APK variable for file" 'file "$apk_path"' "$lens_content"
assert_contains "uses quoted APK variable for unzip inventory" 'unzip -l "$apk_path"' "$lens_content"
assert_contains "uses quoted APK variable for aapt badging" 'aapt dump badging "$apk_path"' "$lens_content"
assert_contains "uses quoted APK variable for aapt2 badging" 'aapt2 dump badging "$apk_path"' "$lens_content"
assert_contains "uses quoted APK variable for DEX streaming" 'unzip -p "$apk_path" classes.dex | strings' "$lens_content"
assert_contains "uses quoted APK variable for apktool" 'apktool d -f "$apk_path" -o "$apktool_out"' "$lens_content"
assert_contains "uses quoted APK variable for jadx" 'jadx --deobf -d "$jadx_out" "$apk_path"' "$lens_content"
assert_contains "includes native strings workflow" 'strings "$apktool_out/lib/arm64-v8a/libcrypto.so"' "$lens_content"
assert_contains "includes OSV Maven query example" "https://api.osv.dev/v1/query" "$lens_content"
assert_not_contains "does not quote template APK path in commands" '"{{ANDROID_APK_PATH}}"' "$lens_content"

echo ""
echo "Test 6: decoded output uses private per-run scratch directory"
assert_contains "sets restrictive umask for scratch tree" 'umask 077' "$lens_content"
assert_contains "creates unique scratch directory" 'scratch_dir="$(mktemp -d)"' "$lens_content"
assert_contains "places apktool output under scratch tree" 'apktool_out="$scratch_dir/apktool"' "$lens_content"
assert_contains "places jadx output under scratch tree" 'jadx_out="$scratch_dir/jadx"' "$lens_content"
assert_contains "cleans decoded scratch output" 'rm -rf -- "$scratch_dir"' "$lens_content"
assert_not_contains "does not use fixed dependency shared path" "/tmp/apk-deps" "$lens_content"
assert_not_contains "does not use fixed jadx shared path" "/tmp/apk-jadx" "$lens_content"
assert_not_contains "does not use any hard-coded tmp directory" "/tmp/" "$lens_content"

echo ""
echo "Test 7: examples avoid active device and app mutation commands"
for forbidden in \
  "adb install" \
  "pm clear" \
  "am force-stop" \
  "settings put" \
  "adb push" \
  "input tap" \
  "adb shell am start" \
  "adb shell am broadcast"; do
  assert_not_contains "does not mention $forbidden" "$forbidden" "$lens_content"
done

echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"

if [[ $FAIL -ne 0 ]]; then
  exit 1
fi
exit 0
