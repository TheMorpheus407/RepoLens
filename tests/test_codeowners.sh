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

# Tests for issue #28: Add .github/CODEOWNERS for automatic review routing
#
# Behavioral contract:
# 1. .github/CODEOWNERS must exist and be non-empty
# 2. Every non-comment, non-blank line must have valid CODEOWNERS syntax
# 3. File must define a default owner via wildcard (*) pattern
# 4. Owner must be @TheMorpheus407
# 5. No duplicate patterns
# 6. File must not contain TODO/FIXME placeholders
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

assert_matches() {
  local desc="$1" pattern="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if grep -qP -- "$pattern" <<< "$haystack"; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    Expected to match pattern: $pattern"
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

assert_file_not_empty() {
  local desc="$1" filepath="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -s "$filepath" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    File is empty or missing: $filepath"
  fi
}

echo ""
echo "=== Test Suite: .github/CODEOWNERS — Automatic Review Routing (issue #28) ==="
echo ""

CODEOWNERS="$SCRIPT_DIR/.github/CODEOWNERS"

# =====================================================================
# Section 1: File existence and basic properties
# =====================================================================

echo "--- Section 1: File existence and basic properties ---"
echo ""

echo "Test 1: .github/CODEOWNERS exists"
assert_file_exists "CODEOWNERS exists at .github/" "$CODEOWNERS"

echo ""
echo "Test 2: .github/CODEOWNERS is not empty"
assert_file_not_empty "CODEOWNERS has content" "$CODEOWNERS"

codeowners_content=""
if [[ -f "$CODEOWNERS" ]]; then
  codeowners_content="$(cat "$CODEOWNERS")"
fi

echo ""
echo "Test 3: CODEOWNERS is a plain text file (not binary or HTML)"
TOTAL=$((TOTAL + 1))
if [[ -f "$CODEOWNERS" ]]; then
  if ! grep -qP '\x00' "$CODEOWNERS" 2>/dev/null && ! grep -qi '<html\|<head\|<body' "$CODEOWNERS"; then
    PASS=$((PASS + 1))
    echo "  PASS: CODEOWNERS is a text file"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: CODEOWNERS appears to be binary or HTML"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: CODEOWNERS not found"
fi

echo ""
echo "Test 4: CODEOWNERS ends with a newline (POSIX compliance)"
TOTAL=$((TOTAL + 1))
if [[ -f "$CODEOWNERS" ]]; then
  last_byte="$(tail -c 1 "$CODEOWNERS" | xxd -p)"
  if [[ "$last_byte" == "0a" || -z "$last_byte" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: File ends with newline"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: File does not end with a newline"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: CODEOWNERS not found"
fi

# =====================================================================
# Section 2: CODEOWNERS syntax validation
# =====================================================================

echo ""
echo "--- Section 2: CODEOWNERS syntax validation ---"
echo ""

echo "Test 5: Every non-comment, non-blank line has valid CODEOWNERS syntax"
TOTAL=$((TOTAL + 1))
if [[ -f "$CODEOWNERS" ]]; then
  invalid_lines=0
  line_num=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_num=$((line_num + 1))
    # Skip blank lines and comments
    stripped="${line#"${line%%[![:space:]]*}"}"
    if [[ -z "$stripped" || "$stripped" == \#* ]]; then
      continue
    fi
    # Valid CODEOWNERS line: pattern followed by one or more @owner references
    # Pattern: any non-space sequence, owners: @username or @org/team
    if ! echo "$stripped" | grep -qP '^[^\s]+\s+(@[a-zA-Z0-9\-]+(/[a-zA-Z0-9\-_.]+)?\s*)+$'; then
      invalid_lines=$((invalid_lines + 1))
      echo "    Invalid line $line_num: $line"
    fi
  done < "$CODEOWNERS"
  if [[ "$invalid_lines" -eq 0 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: All content lines have valid CODEOWNERS syntax"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: Found $invalid_lines line(s) with invalid syntax"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: CODEOWNERS not found"
fi

echo ""
echo "Test 6: File has at least one ownership rule (not just comments)"
TOTAL=$((TOTAL + 1))
if [[ -f "$CODEOWNERS" ]]; then
  rule_count="$(grep -cP '^\s*[^#\s]' "$CODEOWNERS" 2>/dev/null || echo 0)"
  if [[ "$rule_count" -ge 1 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: File has $rule_count ownership rule(s)"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: No ownership rules found (only comments/blank lines)"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: CODEOWNERS not found"
fi

# =====================================================================
# Section 3: Default owner (wildcard) rule
# =====================================================================

echo ""
echo "--- Section 3: Default owner (wildcard) rule ---"
echo ""

echo "Test 7: CODEOWNERS has a wildcard (*) default owner rule"
TOTAL=$((TOTAL + 1))
if [[ -f "$CODEOWNERS" ]]; then
  if grep -qP '^\*\s+@' "$CODEOWNERS"; then
    PASS=$((PASS + 1))
    echo "  PASS: Wildcard default owner rule found"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: No wildcard (*) default owner rule found"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: CODEOWNERS not found"
fi

echo ""
echo "Test 8: Default owner is @TheMorpheus407"
TOTAL=$((TOTAL + 1))
if [[ -f "$CODEOWNERS" ]]; then
  if grep -qP '^\*\s+.*@TheMorpheus407' "$CODEOWNERS"; then
    PASS=$((PASS + 1))
    echo "  PASS: @TheMorpheus407 is the default owner"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: @TheMorpheus407 not found as default owner on wildcard rule"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: CODEOWNERS not found"
fi

echo ""
echo "Test 9: @TheMorpheus407 appears in at least one ownership rule"
assert_contains "@TheMorpheus407 is listed as owner" "@TheMorpheus407" "$codeowners_content"

# =====================================================================
# Section 4: No duplicate patterns
# =====================================================================

echo ""
echo "--- Section 4: No duplicate patterns ---"
echo ""

echo "Test 10: No duplicate file patterns in CODEOWNERS"
TOTAL=$((TOTAL + 1))
if [[ -f "$CODEOWNERS" ]]; then
  # Extract patterns (first field of non-comment, non-blank lines)
  patterns="$(grep -P '^\s*[^#\s]' "$CODEOWNERS" | awk '{print $1}' | sort)"
  unique_patterns="$(echo "$patterns" | sort -u)"
  if [[ "$patterns" == "$unique_patterns" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: No duplicate patterns"
  else
    duplicates="$(echo "$patterns" | sort | uniq -d)"
    FAIL=$((FAIL + 1))
    echo "  FAIL: Duplicate patterns found: $duplicates"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: CODEOWNERS not found"
fi

# =====================================================================
# Section 5: Content quality
# =====================================================================

echo ""
echo "--- Section 5: Content quality ---"
echo ""

echo "Test 11: CODEOWNERS does not contain TODO markers"
assert_not_contains "no TODO markers" "TODO" "$codeowners_content"

echo ""
echo "Test 12: CODEOWNERS does not contain FIXME markers"
assert_not_contains "no FIXME markers" "FIXME" "$codeowners_content"

echo ""
echo "Test 13: CODEOWNERS does not contain placeholder or example owners"
assert_not_contains "no @example placeholder" "@example" "$codeowners_content"

echo ""
echo "Test 14: No trailing whitespace on any line"
TOTAL=$((TOTAL + 1))
if [[ -f "$CODEOWNERS" ]]; then
  trailing_ws_count="$(grep -cP '\s+$' "$CODEOWNERS" 2>/dev/null)" || trailing_ws_count=0
  if [[ "$trailing_ws_count" -eq 0 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: No trailing whitespace"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $trailing_ws_count line(s) have trailing whitespace"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: CODEOWNERS not found"
fi

echo ""
echo "Test 15: No Windows-style line endings (CR+LF)"
TOTAL=$((TOTAL + 1))
if [[ -f "$CODEOWNERS" ]]; then
  if grep -qP '\r' "$CODEOWNERS" 2>/dev/null; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: File contains Windows-style (CR+LF) line endings"
  else
    PASS=$((PASS + 1))
    echo "  PASS: No Windows-style line endings"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: CODEOWNERS not found"
fi

# =====================================================================
# Section 6: Owner format validation
# =====================================================================

echo ""
echo "--- Section 6: Owner format validation ---"
echo ""

echo "Test 16: All @-mentions follow valid GitHub username format"
TOTAL=$((TOTAL + 1))
if [[ -f "$CODEOWNERS" ]]; then
  # Extract all @mentions from ownership rules
  mentions="$(grep -oP '@[a-zA-Z0-9\-]+(/[a-zA-Z0-9\-_.]+)?' "$CODEOWNERS" 2>/dev/null || echo "")"
  invalid_mentions=0
  if [[ -n "$mentions" ]]; then
    while IFS= read -r mention; do
      # GitHub usernames: alphanumeric + hyphens, no leading/trailing hyphen, max 39 chars
      # Also allow org/team format: @org/team-name
      if ! echo "$mention" | grep -qP '^@[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?(/[a-zA-Z0-9\-_.]+)?$'; then
        invalid_mentions=$((invalid_mentions + 1))
        echo "    Invalid mention: $mention"
      fi
    done <<< "$mentions"
  fi
  if [[ "$invalid_mentions" -eq 0 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: All @-mentions are valid GitHub username format"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $invalid_mentions invalid @-mention(s) found"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: CODEOWNERS not found"
fi

echo ""
echo "Test 17: No email-based owners (CODEOWNERS should use @username, not email)"
TOTAL=$((TOTAL + 1))
if [[ -f "$CODEOWNERS" ]]; then
  if grep -qP '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' "$CODEOWNERS" 2>/dev/null; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: File contains email addresses — use @username format instead"
  else
    PASS=$((PASS + 1))
    echo "  PASS: No email-based owners"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: CODEOWNERS not found"
fi

# =====================================================================
# Section 7: File location correctness
# =====================================================================

echo ""
echo "--- Section 7: File location correctness ---"
echo ""

echo "Test 18: CODEOWNERS is in .github/ (not repo root or docs/)"
TOTAL=$((TOTAL + 1))
if [[ -f "$SCRIPT_DIR/.github/CODEOWNERS" ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: CODEOWNERS is in .github/ directory"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: CODEOWNERS not found at .github/CODEOWNERS"
fi

echo ""
echo "Test 19: No duplicate CODEOWNERS in repo root"
TOTAL=$((TOTAL + 1))
if [[ -f "$SCRIPT_DIR/CODEOWNERS" ]]; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: Duplicate CODEOWNERS found at repo root — should only exist in .github/"
else
  PASS=$((PASS + 1))
  echo "  PASS: No duplicate CODEOWNERS at repo root"
fi

echo ""
echo "Test 20: No duplicate CODEOWNERS in docs/"
TOTAL=$((TOTAL + 1))
if [[ -f "$SCRIPT_DIR/docs/CODEOWNERS" ]]; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: Duplicate CODEOWNERS found in docs/ — should only exist in .github/"
else
  PASS=$((PASS + 1))
  echo "  PASS: No duplicate CODEOWNERS in docs/"
fi

# =====================================================================
# Summary
# =====================================================================

echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
