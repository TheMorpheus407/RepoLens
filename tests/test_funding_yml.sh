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

# Tests for issue #29: Add .github/FUNDING.yml for GitHub Sponsors button
# Validates that .github/FUNDING.yml exists, is valid YAML, and contains
# the correct sponsorship entries matching config/sponsors.json.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FUNDING_FILE="$SCRIPT_DIR/.github/FUNDING.yml"
SPONSORS_FILE="$SCRIPT_DIR/config/sponsors.json"

PASS=0
FAIL=0
TOTAL=0

# Portable YAML value extractor for simple key: value files (no nested YAML).
# Usage: yaml_get <file> <key>
yaml_get() {
  local file="$1" key="$2"
  grep -E "^${key}:" "$file" 2>/dev/null | sed "s/^${key}:[[:space:]]*//" | sed 's/[[:space:]]*$//'
}

# Count top-level keys in a simple YAML file.
yaml_key_count() {
  local file="$1"
  grep -cE '^[a-zA-Z_][a-zA-Z0-9_-]*:' "$file" 2>/dev/null || echo "0"
}

# List sorted top-level keys, comma-separated.
yaml_keys_sorted() {
  local file="$1"
  grep -oE '^[a-zA-Z_][a-zA-Z0-9_-]*:' "$file" 2>/dev/null | sed 's/:$//' | sort | paste -sd ',' -
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
echo "=== Test Suite: .github/FUNDING.yml (issue #29) ==="
echo ""

# =====================================================================
# SECTION A: File Existence and Location
# =====================================================================

# =====================================================================
# Test 1: .github/FUNDING.yml exists
# =====================================================================
# The file must exist at exactly .github/FUNDING.yml (GitHub's required path).

echo "Test 1: .github/FUNDING.yml exists"
assert_file_exists ".github/FUNDING.yml exists" "$FUNDING_FILE"

# =====================================================================
# Test 2: File is not empty
# =====================================================================

echo ""
echo "Test 2: .github/FUNDING.yml is not empty"
TOTAL=$((TOTAL + 1))
if [[ -s "$FUNDING_FILE" ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: FUNDING.yml is not empty"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: FUNDING.yml is empty or missing"
fi

# =====================================================================
# SECTION B: Valid YAML
# =====================================================================

# =====================================================================
# Test 3: FUNDING.yml is valid YAML
# =====================================================================
# Validate that every non-blank, non-comment line matches "key: value" format.

echo ""
echo "Test 3: FUNDING.yml is valid YAML (simple key: value format)"
TOTAL=$((TOTAL + 1))
if [[ -f "$FUNDING_FILE" ]]; then
  INVALID_LINES="$(grep -cvE '^\s*$|^\s*#|^[a-zA-Z_][a-zA-Z0-9_-]*:\s+\S' "$FUNDING_FILE" 2>/dev/null || true)"
  if [[ "$INVALID_LINES" == "0" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: FUNDING.yml is valid YAML"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: FUNDING.yml has $INVALID_LINES lines that are not valid key: value pairs"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: FUNDING.yml does not exist (cannot validate YAML)"
fi

# =====================================================================
# SECTION C: Required Keys and Values
# =====================================================================

# =====================================================================
# Test 4: FUNDING.yml contains 'github' key
# =====================================================================

echo ""
echo "Test 4: FUNDING.yml contains 'github' key"
TOTAL=$((TOTAL + 1))
if [[ -f "$FUNDING_FILE" ]]; then
  GITHUB_VAL="$(yaml_get "$FUNDING_FILE" "github")"
  if [[ -n "$GITHUB_VAL" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: 'github' key present"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: 'github' key missing or empty"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: FUNDING.yml does not exist"
fi

# =====================================================================
# Test 5: github key value is 'TheMorpheus407'
# =====================================================================

echo ""
echo "Test 5: github key value is 'TheMorpheus407'"
if [[ -f "$FUNDING_FILE" ]]; then
  GITHUB_VAL="$(yaml_get "$FUNDING_FILE" "github")"
  assert_eq "github value is TheMorpheus407" "TheMorpheus407" "$GITHUB_VAL"
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: FUNDING.yml does not exist"
fi

# =====================================================================
# Test 6: FUNDING.yml contains 'patreon' key
# =====================================================================

echo ""
echo "Test 6: FUNDING.yml contains 'patreon' key"
TOTAL=$((TOTAL + 1))
if [[ -f "$FUNDING_FILE" ]]; then
  PATREON_VAL="$(yaml_get "$FUNDING_FILE" "patreon")"
  if [[ -n "$PATREON_VAL" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: 'patreon' key present"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: 'patreon' key missing or empty"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: FUNDING.yml does not exist"
fi

# =====================================================================
# Test 7: patreon key value is 'themorpheus407'
# =====================================================================

echo ""
echo "Test 7: patreon key value is 'themorpheus407'"
if [[ -f "$FUNDING_FILE" ]]; then
  PATREON_VAL="$(yaml_get "$FUNDING_FILE" "patreon")"
  assert_eq "patreon value is themorpheus407" "themorpheus407" "$PATREON_VAL"
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: FUNDING.yml does not exist"
fi

# =====================================================================
# Test 8: FUNDING.yml contains exactly 2 keys
# =====================================================================
# GitHub FUNDING.yml should only have github and patreon — no extra keys.

echo ""
echo "Test 8: FUNDING.yml contains exactly 2 keys"
TOTAL=$((TOTAL + 1))
if [[ -f "$FUNDING_FILE" ]]; then
  KEY_COUNT="$(yaml_key_count "$FUNDING_FILE")"
  if [[ "$KEY_COUNT" == "2" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: FUNDING.yml has exactly 2 keys"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: FUNDING.yml should have exactly 2 keys, found: $KEY_COUNT"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: FUNDING.yml does not exist"
fi

# =====================================================================
# Test 9: FUNDING.yml keys are exactly 'github' and 'patreon'
# =====================================================================

echo ""
echo "Test 9: FUNDING.yml keys are exactly 'github' and 'patreon'"
TOTAL=$((TOTAL + 1))
if [[ -f "$FUNDING_FILE" ]]; then
  KEYS="$(yaml_keys_sorted "$FUNDING_FILE")"
  if [[ "$KEYS" == "github,patreon" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: keys are github and patreon"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: expected keys 'github,patreon', found: $KEYS"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: FUNDING.yml does not exist"
fi

# =====================================================================
# SECTION D: Format and Hygiene
# =====================================================================

# =====================================================================
# Test 10: FUNDING.yml has no trailing whitespace
# =====================================================================

echo ""
echo "Test 10: FUNDING.yml has no trailing whitespace"
TOTAL=$((TOTAL + 1))
if [[ -f "$FUNDING_FILE" ]]; then
  if grep -qP '\s+$' "$FUNDING_FILE"; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: FUNDING.yml has trailing whitespace"
  else
    PASS=$((PASS + 1))
    echo "  PASS: no trailing whitespace"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: FUNDING.yml does not exist"
fi

# =====================================================================
# Test 11: FUNDING.yml ends with a newline
# =====================================================================

echo ""
echo "Test 11: FUNDING.yml ends with a newline"
TOTAL=$((TOTAL + 1))
if [[ -f "$FUNDING_FILE" ]]; then
  if [[ -n "$(tail -c 1 "$FUNDING_FILE")" ]]; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: FUNDING.yml does not end with a newline"
  else
    PASS=$((PASS + 1))
    echo "  PASS: file ends with newline"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: FUNDING.yml does not exist"
fi

# =====================================================================
# Test 12: FUNDING.yml has no comments
# =====================================================================
# A clean FUNDING.yml should have no comment lines — just the two key-value pairs.

echo ""
echo "Test 12: FUNDING.yml has no comment lines"
TOTAL=$((TOTAL + 1))
if [[ -f "$FUNDING_FILE" ]]; then
  if grep -qE '^\s*#' "$FUNDING_FILE"; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: FUNDING.yml contains comment lines"
  else
    PASS=$((PASS + 1))
    echo "  PASS: no comment lines"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: FUNDING.yml does not exist"
fi

# =====================================================================
# Test 13: FUNDING.yml has no blank lines (only 2 content lines)
# =====================================================================

echo ""
echo "Test 13: FUNDING.yml has exactly 2 non-empty lines"
TOTAL=$((TOTAL + 1))
if [[ -f "$FUNDING_FILE" ]]; then
  LINE_COUNT="$(grep -cve '^\s*$' "$FUNDING_FILE")"
  if [[ "$LINE_COUNT" == "2" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: exactly 2 non-empty lines"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: expected 2 non-empty lines, found: $LINE_COUNT"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: FUNDING.yml does not exist"
fi

# =====================================================================
# SECTION E: Consistency with config/sponsors.json
# =====================================================================

# =====================================================================
# Test 14: github username in FUNDING.yml matches sponsors.json
# =====================================================================
# The GitHub Sponsors URL in sponsors.json ends with /TheMorpheus407.
# FUNDING.yml github field should be TheMorpheus407.

echo ""
echo "Test 14: github username matches sponsors.json"
TOTAL=$((TOTAL + 1))
if [[ -f "$FUNDING_FILE" ]] && [[ -f "$SPONSORS_FILE" ]]; then
  FUNDING_GITHUB="$(yaml_get "$FUNDING_FILE" "github")"
  SPONSORS_GITHUB_URL="$(jq -r '.sponsors[] | select(.name == "GitHub Sponsors") | .url' "$SPONSORS_FILE" 2>/dev/null)"
  # Extract username from URL (last path segment)
  SPONSORS_GITHUB_USER="${SPONSORS_GITHUB_URL##*/}"
  if [[ "$FUNDING_GITHUB" == "$SPONSORS_GITHUB_USER" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: github username matches sponsors.json ($FUNDING_GITHUB)"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: github mismatch — FUNDING.yml=$FUNDING_GITHUB, sponsors.json=$SPONSORS_GITHUB_USER"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: one or both files missing"
fi

# =====================================================================
# Test 15: patreon username in FUNDING.yml matches sponsors.json
# =====================================================================

echo ""
echo "Test 15: patreon username matches sponsors.json"
TOTAL=$((TOTAL + 1))
if [[ -f "$FUNDING_FILE" ]] && [[ -f "$SPONSORS_FILE" ]]; then
  FUNDING_PATREON="$(yaml_get "$FUNDING_FILE" "patreon")"
  SPONSORS_PATREON_URL="$(jq -r '.sponsors[] | select(.name == "Patreon") | .url' "$SPONSORS_FILE" 2>/dev/null)"
  # Extract username from URL (last path segment)
  SPONSORS_PATREON_USER="${SPONSORS_PATREON_URL##*/}"
  if [[ "$FUNDING_PATREON" == "$SPONSORS_PATREON_USER" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: patreon username matches sponsors.json ($FUNDING_PATREON)"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: patreon mismatch — FUNDING.yml=$FUNDING_PATREON, sponsors.json=$SPONSORS_PATREON_USER"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: one or both files missing"
fi

# --- Summary ---
echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
