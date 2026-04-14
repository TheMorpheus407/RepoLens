#!/usr/bin/env bash
# Copyright 2025 Bootstrap Academy
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

# Tests for issue #25: .gitignore missing common sensitive file patterns
#
# These tests define the behavioral contract for sensitive-file gitignore coverage:
# The .gitignore must contain patterns that prevent accidental commits of
# .env files, private keys, keystores, and credential files. Tests verify
# both pattern presence (text) and actual git behavior (git check-ignore).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

assert_matches() {
  local desc="$1" pattern="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if echo "$haystack" | grep -qP "$pattern"; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    Expected to match pattern: $pattern"
  fi
}

echo ""
echo "=== Test Suite: .gitignore Sensitive File Patterns (issue #25) ==="
echo ""

gitignore_content=""
if [[ -f "$SCRIPT_DIR/.gitignore" ]]; then
  gitignore_content="$(cat "$SCRIPT_DIR/.gitignore")"
fi

# =====================================================================
# 1. Sensitive files section exists and is labeled
# =====================================================================

echo "--- Section 1: Sensitive files section presence ---"
echo ""

echo "Test 1: .gitignore has a labeled section for sensitive files"
TOTAL=$((TOTAL + 1))
if echo "$gitignore_content" | grep -qiP '^#.*sensitive|^#.*secret'; then
  PASS=$((PASS + 1))
  echo "  PASS: .gitignore has a labeled sensitive files section"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: .gitignore missing a labeled comment for sensitive files section"
  echo "    Expected: a comment line containing 'sensitive' or 'secret'"
fi

# =====================================================================
# 2. Required patterns present in .gitignore text
# =====================================================================

echo ""
echo "--- Section 2: Required sensitive file patterns in .gitignore ---"
echo ""

echo "Test 2: .gitignore contains .env pattern"
assert_matches ".env pattern present" '^\.env$' "$gitignore_content"

echo ""
echo "Test 3: .gitignore contains .env.* wildcard pattern"
assert_matches ".env.* pattern present" '^\.env\.\*$' "$gitignore_content"

echo ""
echo "Test 4: .gitignore contains *.pem pattern"
assert_matches "*.pem pattern present" '^\*\.pem$' "$gitignore_content"

echo ""
echo "Test 5: .gitignore contains *.key pattern"
assert_matches "*.key pattern present" '^\*\.key$' "$gitignore_content"

echo ""
echo "Test 6: .gitignore contains *.p12 pattern"
assert_matches "*.p12 pattern present" '^\*\.p12$' "$gitignore_content"

echo ""
echo "Test 7: .gitignore contains *.jks pattern"
assert_matches "*.jks pattern present" '^\*\.jks$' "$gitignore_content"

echo ""
echo "Test 8: .gitignore contains *.keystore pattern"
assert_matches "*.keystore pattern present" '^\*\.keystore$' "$gitignore_content"

echo ""
echo "Test 9: .gitignore contains *.pfx pattern"
assert_matches "*.pfx pattern present" '^\*\.pfx$' "$gitignore_content"

echo ""
echo "Test 10: .gitignore contains key.properties pattern"
assert_matches "key.properties pattern present" '^key\.properties$' "$gitignore_content"

echo ""
echo "Test 11: .gitignore contains google-services.json pattern"
assert_matches "google-services.json pattern present" '^google-services\.json$' "$gitignore_content"

echo ""
echo "Test 12: .gitignore contains GoogleService-Info.plist pattern"
assert_matches "GoogleService-Info.plist pattern present" '^GoogleService-Info\.plist$' "$gitignore_content"

echo ""
echo "Test 13: .gitignore contains credentials.json pattern"
assert_matches "credentials.json pattern present" '^credentials\.json$' "$gitignore_content"

echo ""
echo "Test 14: .gitignore contains secrets.yaml pattern"
assert_matches "secrets.yaml pattern present" '^secrets\.yaml$' "$gitignore_content"

echo ""
echo "Test 15: .gitignore contains secrets.yml pattern"
assert_matches "secrets.yml pattern present" '^secrets\.yml$' "$gitignore_content"

# =====================================================================
# 3. Behavioral: git check-ignore verifies patterns actually work
# =====================================================================

echo ""
echo "--- Section 3: Behavioral verification via git check-ignore ---"
echo ""

sensitive_files=(
  ".env"
  ".env.local"
  ".env.production"
  "server.pem"
  "private.key"
  "cert.p12"
  "release.jks"
  "debug.keystore"
  "cert.pfx"
  "key.properties"
  "google-services.json"
  "GoogleService-Info.plist"
  "credentials.json"
  "secrets.yaml"
  "secrets.yml"
)

test_num=16
for sfile in "${sensitive_files[@]}"; do
  echo "Test $test_num: git ignores '$sfile'"
  TOTAL=$((TOTAL + 1))
  if git -C "$SCRIPT_DIR" check-ignore -q "$sfile" 2>/dev/null; then
    PASS=$((PASS + 1))
    echo "  PASS: '$sfile' is ignored by git"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: '$sfile' is NOT ignored by git"
    echo "    Expected: git check-ignore to confirm this file is ignored"
  fi
  echo ""
  test_num=$((test_num + 1))
done

# =====================================================================
# 4. No false positives on legitimate RepoLens files
# =====================================================================

echo "--- Section 4: No false positives on legitimate project files ---"
echo ""

legitimate_files=(
  "repolens.sh"
  "config/domains.json"
  "config/label-colors.json"
  "lib/core.sh"
  "lib/logging.sh"
  "README.md"
  "CLAUDE.md"
  "LICENSE"
)

for lfile in "${legitimate_files[@]}"; do
  echo "Test $test_num: git does NOT ignore legitimate file '$lfile'"
  TOTAL=$((TOTAL + 1))
  if git -C "$SCRIPT_DIR" check-ignore -q "$lfile" 2>/dev/null; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: '$lfile' is incorrectly ignored by git"
    echo "    This is a false positive — legitimate project files must not be ignored"
  else
    PASS=$((PASS + 1))
    echo "  PASS: '$lfile' is correctly NOT ignored"
  fi
  echo ""
  test_num=$((test_num + 1))
done

# =====================================================================
# 5. Existing gitignore entries still work (no regression)
# =====================================================================

echo "--- Section 5: Existing .gitignore entries preserved (regression check) ---"
echo ""

echo "Test $test_num: .gitignore still covers logs/ directory"
assert_matches "logs/ pattern still present" '(^|\n)logs/' "$gitignore_content"
test_num=$((test_num + 1))

echo ""
echo "Test $test_num: .gitignore still covers .semaphore/ directory"
assert_matches ".semaphore/ pattern still present" '(^|\n)\.semaphore/' "$gitignore_content"
test_num=$((test_num + 1))

echo ""
echo "Test $test_num: .gitignore still covers *.tmp files"
assert_matches "*.tmp pattern still present" '(^|\n)\*\.tmp' "$gitignore_content"
test_num=$((test_num + 1))

echo ""
echo "Test $test_num: .gitignore still covers *.swp files"
assert_matches "*.swp pattern still present" '(^|\n)\*\.swp' "$gitignore_content"
test_num=$((test_num + 1))

echo ""
echo "Test $test_num: .gitignore still covers .DS_Store"
assert_matches ".DS_Store pattern still present" '(^|\n)\.DS_Store' "$gitignore_content"
test_num=$((test_num + 1))

echo ""
echo "Test $test_num: .gitignore still covers *.swo files"
assert_matches "*.swo pattern still present" '(^|\n)\*\.swo' "$gitignore_content"
test_num=$((test_num + 1))

echo ""
echo "Test $test_num: .gitignore still covers *~ files"
assert_matches "*~ pattern still present" '(^|\n)\*~' "$gitignore_content"
test_num=$((test_num + 1))

# =====================================================================
# 6. Subdirectory and edge-case matching
# =====================================================================

echo "--- Section 6: Subdirectory and edge-case matching ---"
echo ""

subdir_files=(
  "subdir/.env"
  "app/config/.env.local"
  "android/key.properties"
  "ssl/certs/server.pem"
  "deploy/credentials.json"
  "config/secrets.yaml"
  ".env.development.local"
)

for sfile in "${subdir_files[@]}"; do
  echo "Test $test_num: git ignores '$sfile' (nested/edge-case path)"
  TOTAL=$((TOTAL + 1))
  if git -C "$SCRIPT_DIR" check-ignore -q "$sfile" 2>/dev/null; then
    PASS=$((PASS + 1))
    echo "  PASS: '$sfile' is ignored by git"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: '$sfile' is NOT ignored by git"
    echo "    Expected: git check-ignore to confirm this file is ignored in subdirectory"
  fi
  echo ""
  test_num=$((test_num + 1))
done

# =====================================================================
# 7. Integrity guards
# =====================================================================

echo "--- Section 7: Integrity guards ---"
echo ""

echo "Test $test_num: no negation patterns override sensitive file exclusions"
TOTAL=$((TOTAL + 1))
if echo "$gitignore_content" | grep -vP '^!\.env\.example$' | grep -qP '^!\.(env|pem|key|p12|jks|keystore|pfx)|^!.*credentials|^!.*secrets'; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: found negation pattern that could re-include sensitive files"
else
  PASS=$((PASS + 1))
  echo "  PASS: no negation patterns override sensitive file exclusions"
fi
echo ""
test_num=$((test_num + 1))

echo "Test $test_num: at least 14 sensitive file patterns present"
TOTAL=$((TOTAL + 1))
sensitive_count=0
for pat in '.env' '.env.*' '*.pem' '*.key' '*.p12' '*.jks' '*.keystore' '*.pfx' \
           'key.properties' 'google-services.json' 'GoogleService-Info.plist' \
           'credentials.json' 'secrets.yaml' 'secrets.yml'; do
  if echo "$gitignore_content" | grep -qF "$pat"; then
    sensitive_count=$((sensitive_count + 1))
  fi
done
if [[ "$sensitive_count" -ge 14 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: $sensitive_count/14 sensitive patterns found"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: only $sensitive_count/14 sensitive patterns found"
fi
echo ""
test_num=$((test_num + 1))

# --- Summary ---
echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
