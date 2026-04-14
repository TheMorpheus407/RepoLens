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

# Tests for issue #26: .env.example must be trackable despite .env.* wildcard
#
# The .gitignore blocks all .env.* files via a wildcard, but .env.example is a
# safe template file that documents required environment variables. A negation
# pattern !.env.example must allow it to be tracked, while all other .env.*
# files remain blocked.
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
echo "=== Test Suite: .env.example trackability (issue #26) ==="
echo ""

gitignore_content=""
if [[ -f "$SCRIPT_DIR/.gitignore" ]]; then
  gitignore_content="$(cat "$SCRIPT_DIR/.gitignore")"
fi

# =====================================================================
# 1. Negation pattern presence
# =====================================================================

echo "--- Section 1: !.env.example negation pattern ---"
echo ""

echo "Test 1: .gitignore contains !.env.example negation pattern"
assert_matches "!.env.example pattern present" '^!\.env\.example$' "$gitignore_content"

echo ""
echo "Test 2: !.env.example appears AFTER .env.* wildcard (ordering matters)"
TOTAL=$((TOTAL + 1))
env_wildcard_line=""
negation_line=""
line_num=0
while IFS= read -r line; do
  line_num=$((line_num + 1))
  if [[ "$line" == ".env.*" ]]; then
    env_wildcard_line="$line_num"
  fi
  if [[ "$line" == "!.env.example" ]]; then
    negation_line="$line_num"
  fi
done <<< "$gitignore_content"

if [[ -n "$env_wildcard_line" && -n "$negation_line" && "$negation_line" -gt "$env_wildcard_line" ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: !.env.example (line $negation_line) appears after .env.* (line $env_wildcard_line)"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: !.env.example must appear after .env.* for the negation to take effect"
  echo "    .env.* line: ${env_wildcard_line:-not found}"
  echo "    !.env.example line: ${negation_line:-not found}"
fi

# =====================================================================
# 2. Behavioral: .env.example must NOT be ignored by git
# =====================================================================

echo ""
echo "--- Section 2: Behavioral verification — .env.example is trackable ---"
echo ""

echo "Test 3: git does NOT ignore .env.example (root level)"
TOTAL=$((TOTAL + 1))
if git -C "$SCRIPT_DIR" check-ignore -q ".env.example" 2>/dev/null; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: .env.example is ignored by git — it should be trackable"
  echo "    The !.env.example negation pattern is missing or not working"
else
  PASS=$((PASS + 1))
  echo "  PASS: .env.example is NOT ignored by git (trackable)"
fi

echo ""
echo "Test 4: git does NOT ignore subdir/.env.example (nested path)"
TOTAL=$((TOTAL + 1))
if git -C "$SCRIPT_DIR" check-ignore -q "subdir/.env.example" 2>/dev/null; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: subdir/.env.example is ignored by git — it should be trackable"
else
  PASS=$((PASS + 1))
  echo "  PASS: subdir/.env.example is NOT ignored by git (trackable)"
fi

echo ""
echo "Test 5: git does NOT ignore app/config/.env.example (deeply nested)"
TOTAL=$((TOTAL + 1))
if git -C "$SCRIPT_DIR" check-ignore -q "app/config/.env.example" 2>/dev/null; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: app/config/.env.example is ignored by git — it should be trackable"
else
  PASS=$((PASS + 1))
  echo "  PASS: app/config/.env.example is NOT ignored by git (trackable)"
fi

# =====================================================================
# 3. Regression: other .env.* files must still be ignored
# =====================================================================

echo ""
echo "--- Section 3: Regression — other .env.* files still ignored ---"
echo ""

env_variants=(
  ".env.local"
  ".env.production"
  ".env.development"
  ".env.staging"
  ".env.test"
  ".env.development.local"
)

test_num=6
for envfile in "${env_variants[@]}"; do
  echo "Test $test_num: git still ignores '$envfile'"
  TOTAL=$((TOTAL + 1))
  if git -C "$SCRIPT_DIR" check-ignore -q "$envfile" 2>/dev/null; then
    PASS=$((PASS + 1))
    echo "  PASS: '$envfile' is still ignored"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: '$envfile' is NOT ignored — negation may be too broad"
  fi
  echo ""
  test_num=$((test_num + 1))
done

# =====================================================================
# 4. Integrity: updated negation guard must still catch dangerous patterns
# =====================================================================

echo "--- Section 4: Integrity guard — dangerous negations still blocked ---"
echo ""

echo "Test $test_num: negation guard allows !.env.example but blocks other .env negations"
TOTAL=$((TOTAL + 1))
filtered_content="$(echo "$gitignore_content" | grep -vP '^!\.env\.example$')"
if echo "$filtered_content" | grep -qP '^!\.(env|pem|key|p12|jks|keystore|pfx)|^!.*credentials|^!.*secrets'; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: found dangerous negation pattern (other than !.env.example)"
else
  PASS=$((PASS + 1))
  echo "  PASS: no dangerous negation patterns found (excluding safe !.env.example)"
fi
echo ""
test_num=$((test_num + 1))

echo "Test $test_num: only !.env.example is allowed as a negation — no other .env negations exist"
TOTAL=$((TOTAL + 1))
other_env_negations="$(echo "$gitignore_content" | grep -P '^!\.env\.' | grep -vP '^!\.env\.example$' || true)"
if [[ -z "$other_env_negations" ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: no other .env.* negation patterns found"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: found unexpected .env negation patterns:"
  echo "    $other_env_negations"
fi
echo ""
test_num=$((test_num + 1))

# =====================================================================
# 5. Negation precision — similar names must still be ignored
# =====================================================================

echo "--- Section 5: Negation precision — only exact .env.example is un-ignored ---"
echo ""

similar_names=(
  ".env.example.bak"
  ".env.example.old"
  ".env.examples"
  ".env.example_backup"
  ".env.example.local"
)

for similar in "${similar_names[@]}"; do
  echo "Test $test_num: git still ignores '$similar' (negation is exact-match only)"
  TOTAL=$((TOTAL + 1))
  if git -C "$SCRIPT_DIR" check-ignore -q "$similar" 2>/dev/null; then
    PASS=$((PASS + 1))
    echo "  PASS: '$similar' is still ignored"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: '$similar' is NOT ignored — negation may be too broad"
  fi
  echo ""
  test_num=$((test_num + 1))
done

# =====================================================================
# 6. .env (base) still ignored — not affected by the negation
# =====================================================================

echo "--- Section 6: .env base file still ignored ---"
echo ""

echo "Test $test_num: .env (base, no extension) is still ignored"
TOTAL=$((TOTAL + 1))
if git -C "$SCRIPT_DIR" check-ignore -q ".env" 2>/dev/null; then
  PASS=$((PASS + 1))
  echo "  PASS: .env is still ignored"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: .env is NOT ignored — the negation may have broken base .env exclusion"
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
