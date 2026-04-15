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

# Tests for issue #32: Hardcoded author-specific brand names in trademark-branding lens prompt
#
# Behavioral contract:
# 1. The trademark-branding lens must NOT contain hardcoded author-specific search terms
#    (the-morpheus, morpheus, bootstrapacademy, bootstrap-academy) in grep commands
# 2. The lens must still contain a step 8 that checks for domain references forks would inherit
# 3. The step 8 instruction must be generic/repo-agnostic — usable against ANY repository
# 4. No other lens prompt should contain these author-specific terms in grep commands
# 5. The lens prompt must remain valid YAML frontmatter + markdown structure
# 6. The lens must still be registered in domains.json under open-source-readiness
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
TOTAL=0

LENS_FILE="$SCRIPT_DIR/prompts/lenses/open-source-readiness/trademark-branding.md"
DOMAINS_FILE="$SCRIPT_DIR/config/domains.json"

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    Expected: $(echo "$expected" | head -3)"
    echo "    Actual:   $(echo "$actual" | head -3)"
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
    echo "    Expected to contain: $needle"
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
    echo "    Expected NOT to contain: $needle"
  fi
}

echo ""
echo "=== Test Suite: trademark-branding hardcoded brand names (issue #32) ==="
echo ""

lens_content="$(cat "$LENS_FILE")"

# =====================================================================
# Contract 1: No hardcoded author-specific search terms in grep commands
# =====================================================================

echo "--- Contract 1: No hardcoded author-specific search terms in grep commands ---"
echo ""

# Extract grep command lines from the lens (lines containing backtick-wrapped grep commands)
grep_lines="$(grep -n 'grep.*morpheus\|grep.*bootstrapacademy\|grep.*bootstrap-academy' "$LENS_FILE" 2>/dev/null || true)"

echo "Test 1: No 'the-morpheus' in grep commands"
assert_eq "no 'the-morpheus' in grep commands" "" "$grep_lines"

echo ""
echo "Test 2: No 'morpheus' as a standalone grep search term"
morpheus_grep="$(grep -n "grep.*'.*morpheus" "$LENS_FILE" 2>/dev/null || true)"
assert_eq "no 'morpheus' in grep search patterns" "" "$morpheus_grep"

echo ""
echo "Test 3: No 'bootstrapacademy' in grep commands"
bootstrap_grep="$(grep -n 'grep.*bootstrapacademy' "$LENS_FILE" 2>/dev/null || true)"
assert_eq "no 'bootstrapacademy' in grep commands" "" "$bootstrap_grep"

echo ""
echo "Test 4: No 'bootstrap-academy' in grep commands"
bootstrap_hyphen_grep="$(grep -n 'grep.*bootstrap-academy' "$LENS_FILE" 2>/dev/null || true)"
assert_eq "no 'bootstrap-academy' in grep commands" "" "$bootstrap_hyphen_grep"

echo ""
echo "Test 5: Combined check — no author-specific terms anywhere in grep patterns"
# Broader check: search for any of these terms appearing as grep search arguments
all_author_terms="$(grep -nE "(the-morpheus|bootstrapacademy|bootstrap-academy)" "$LENS_FILE" 2>/dev/null || true)"
assert_eq "no author-specific terms in lens file" "" "$all_author_terms"

# =====================================================================
# Contract 2: Step 8 still exists and checks domain references
# =====================================================================

echo ""
echo "--- Contract 2: Step 8 still exists for domain reference checking ---"
echo ""

echo "Test 6: Lens still contains a step 8"
assert_contains "step 8 exists" "8." "$lens_content"

echo ""
echo "Test 7: Step 8 mentions domain references or forks"
step8_line="$(grep -n '^8\.' "$LENS_FILE" 2>/dev/null || true)"
step8_content="$(echo "$step8_line" | tr '[:upper:]' '[:lower:]')"
TOTAL=$((TOTAL + 1))
if echo "$step8_content" | grep -qiE 'domain|fork|inherit|brand|reference'; then
  PASS=$((PASS + 1))
  echo "  PASS: step 8 addresses domain references or fork-related branding"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: step 8 must address domain references or fork-related branding"
  echo "    Step 8 content: $step8_line"
fi

# =====================================================================
# Contract 3: Step 8 instruction is generic/repo-agnostic
# =====================================================================

echo ""
echo "--- Contract 3: Step 8 instruction is generic/repo-agnostic ---"
echo ""

echo "Test 8: Step 8 uses generic approach (template vars, agent-derived terms, or placeholders)"
step8_full="$(sed -n '/^8\./,/^[0-9]\./p' "$LENS_FILE" | head -5)"
TOTAL=$((TOTAL + 1))
# It should either use template variables like {{REPO_OWNER}}/{{REPO_NAME}},
# or instruct the agent to derive terms dynamically, or use generic placeholders
if echo "$step8_full" | grep -qiE '(REPO_OWNER|REPO_NAME|project.name|org.name|<project|<org|<author|Identify.*project.*name|Identify.*org|derive|determine|discover|README|package.*manifest|git.*remote)'; then
  PASS=$((PASS + 1))
  echo "  PASS: step 8 uses a generic/dynamic approach"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: step 8 must use template variables, placeholders, or agent-derived terms"
  echo "    Step 8: $step8_full"
fi

# =====================================================================
# Contract 4: No other lens has author-specific terms in grep commands
# =====================================================================

echo ""
echo "--- Contract 4: No other lens prompts contain author-specific search terms ---"
echo ""

echo "Test 9: No lens prompt contains 'morpheus' in a grep command pattern"
other_matches="$(grep -rn 'morpheus' "$SCRIPT_DIR/prompts/lenses/" 2>/dev/null || true)"
assert_eq "no 'morpheus' in any lens prompt" "" "$other_matches"

echo ""
echo "Test 10: No lens prompt contains 'bootstrapacademy' in any context"
bootstrap_matches="$(grep -rn 'bootstrapacademy\|bootstrap-academy' "$SCRIPT_DIR/prompts/lenses/" 2>/dev/null || true)"
assert_eq "no 'bootstrapacademy' or 'bootstrap-academy' in any lens prompt" "" "$bootstrap_matches"

# =====================================================================
# Contract 5: Lens prompt retains valid structure
# =====================================================================

echo ""
echo "--- Contract 5: Lens prompt retains valid YAML frontmatter + markdown structure ---"
echo ""

echo "Test 11: Lens starts with YAML frontmatter delimiter"
first_line="$(head -1 "$LENS_FILE")"
assert_eq "starts with ---" "---" "$first_line"

echo ""
echo "Test 12: Lens has closing YAML frontmatter delimiter"
# Count frontmatter delimiters (should be exactly 2: opening and closing)
delimiter_count="$(grep -c '^---$' "$LENS_FILE")"
assert_eq "exactly 2 frontmatter delimiters" "2" "$delimiter_count"

echo ""
echo "Test 13: Lens frontmatter contains required id field"
assert_contains "has id field" "id: trademark-branding" "$lens_content"

echo ""
echo "Test 14: Lens frontmatter contains required domain field"
assert_contains "has domain field" "domain: open-source-readiness" "$lens_content"

echo ""
echo "Test 15: Lens frontmatter contains required name field"
assert_contains "has name field" "name:" "$lens_content"

echo ""
echo "Test 16: Lens frontmatter contains required role field"
assert_contains "has role field" "role:" "$lens_content"

echo ""
echo "Test 17: Lens contains '## Your Expert Focus' section"
assert_contains "has expert focus section" "## Your Expert Focus" "$lens_content"

echo ""
echo "Test 18: Lens contains '## What You Hunt For' section"
assert_contains "has what-you-hunt-for section" "## What You Hunt For" "$lens_content"

echo ""
echo "Test 19: Lens contains '## How You Investigate' section"
assert_contains "has how-you-investigate section" "## How You Investigate" "$lens_content"

# =====================================================================
# Contract 6: Lens is registered in domains.json
# =====================================================================

echo ""
echo "--- Contract 6: Lens is registered in domains.json ---"
echo ""

echo "Test 20: trademark-branding is in open-source-readiness domain lenses"
osr_lenses="$(jq -r '.domains[] | select(.id == "open-source-readiness") | .lenses[]' "$DOMAINS_FILE")"
TOTAL=$((TOTAL + 1))
if echo "$osr_lenses" | grep -q '^trademark-branding$'; then
  PASS=$((PASS + 1))
  echo "  PASS: trademark-branding registered in open-source-readiness"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: trademark-branding must be registered in open-source-readiness domain"
fi

# =====================================================================
# Contract 7: Step 8 still includes grep functionality for searching
# =====================================================================

echo ""
echo "--- Contract 7: Step 8 retains search capability ---"
echo ""

echo "Test 21: Step 8 still references grep or search functionality"
TOTAL=$((TOTAL + 1))
if echo "$step8_full" | grep -qiE '(grep|search|find.*term|look.*for)'; then
  PASS=$((PASS + 1))
  echo "  PASS: step 8 retains search/grep functionality"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: step 8 must retain grep or equivalent search functionality"
  echo "    Step 8: $step8_full"
fi

# =====================================================================
# Contract 8: Other investigation steps are unmodified
# =====================================================================

echo ""
echo "--- Contract 8: Other investigation steps remain intact ---"
echo ""

echo "Test 22: Steps 1-7 still exist in the lens"
for step_num in 1 2 3 4 5 6 7; do
  TOTAL=$((TOTAL + 1))
  if grep -q "^${step_num}\." "$LENS_FILE"; then
    PASS=$((PASS + 1))
    echo "  PASS: step $step_num exists"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: step $step_num is missing"
  fi
done

echo ""
echo "Test 23: Step 1 (brand assets) is unchanged"
step1="$(grep '^1\.' "$LENS_FILE")"
assert_contains "step 1 checks brand assets" "brand" "$step1"

echo ""
echo "Test 24: Step 7 (social links) is unchanged"
step7="$(grep '^7\.' "$LENS_FILE")"
assert_contains "step 7 checks social links" "social" "$step7"

# =====================================================================
# Contract 9: Consistency with other open-source-readiness lenses
# =====================================================================

echo ""
echo "--- Contract 9: Consistency with other open-source-readiness lenses ---"
echo ""

echo "Test 25: All open-source-readiness lenses use repo-agnostic grep patterns"
# Verify no lens in this domain has hardcoded author/org terms
osr_dir="$SCRIPT_DIR/prompts/lenses/open-source-readiness"
author_leaks="$(grep -rl 'morpheus\|bootstrapacademy\|bootstrap-academy' "$osr_dir" 2>/dev/null || true)"
assert_eq "no author-specific terms in any open-source-readiness lens" "" "$author_leaks"

# =====================================================================
# Contract 10: Template variable syntax in step 8 grep command
# =====================================================================

echo ""
echo "--- Contract 10: Template variable syntax in step 8 grep command ---"
echo ""

echo "Test 26: Step 8 grep uses {{REPO_OWNER}} template variable (double braces)"
TOTAL=$((TOTAL + 1))
if echo "$step8_full" | grep -qF '{{REPO_OWNER}}'; then
  PASS=$((PASS + 1))
  echo "  PASS: step 8 grep contains {{REPO_OWNER}} template variable"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: step 8 grep must contain {{REPO_OWNER}} with double-brace syntax for template substitution"
  echo "    Step 8: $step8_full"
fi

echo ""
echo "Test 27: Step 8 grep uses {{REPO_NAME}} template variable (double braces)"
TOTAL=$((TOTAL + 1))
if echo "$step8_full" | grep -qF '{{REPO_NAME}}'; then
  PASS=$((PASS + 1))
  echo "  PASS: step 8 grep contains {{REPO_NAME}} template variable"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: step 8 grep must contain {{REPO_NAME}} with double-brace syntax for template substitution"
  echo "    Step 8: $step8_full"
fi

# =====================================================================
# Contract 11: Hybrid approach — additional brand terms instruction
# =====================================================================

echo ""
echo "--- Contract 11: Hybrid approach — additional brand terms instruction ---"
echo ""

echo "Test 28: Step 8 instructs agent to search for additional brand terms beyond template variables"
TOTAL=$((TOTAL + 1))
if echo "$step8_full" | grep -qiE 'additional.*brand|brand.*term|product.*name|domain.*name|author.*handle'; then
  PASS=$((PASS + 1))
  echo "  PASS: step 8 includes instruction for additional brand term discovery"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: step 8 must instruct agent to search for additional brand terms (hybrid approach)"
  echo "    Step 8: $step8_full"
fi

# =====================================================================
# Contract 12: Step 8 grep retains file extension filter
# =====================================================================

echo ""
echo "--- Contract 12: Step 8 grep retains file extension filter ---"
echo ""

echo "Test 29: Step 8 grep includes --include file filter"
TOTAL=$((TOTAL + 1))
if echo "$step8_full" | grep -qF -- '--include='; then
  PASS=$((PASS + 1))
  echo "  PASS: step 8 grep retains --include file filter"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: step 8 grep must retain --include file extension filter to scope search"
  echo "    Step 8: $step8_full"
fi

# =====================================================================
# Summary
# =====================================================================

echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

[[ "$FAIL" -eq 0 ]] || exit 1
