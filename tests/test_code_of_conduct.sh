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

# Tests for issue #17: Add CODE_OF_CONDUCT.md (Contributor Covenant 2.1)
# Validates that CODE_OF_CONDUCT.md contains the standard CC 2.1 text
# with the correct contact email and all required sections.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COC="$SCRIPT_DIR/CODE_OF_CONDUCT.md"
README="$SCRIPT_DIR/README.md"
CONTRIBUTING="$SCRIPT_DIR/CONTRIBUTING.md"

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
  if echo "$haystack" | grep -qPz "$pattern"; then
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
echo "=== Test Suite: CODE_OF_CONDUCT.md — Contributor Covenant 2.1 (issue #17) ==="
echo ""

# =====================================================================
# 1. File existence and basic properties
# =====================================================================

echo "Test 1: CODE_OF_CONDUCT.md exists at repo root"
assert_file_exists "CODE_OF_CONDUCT.md exists" "$COC"

echo ""
echo "Test 2: CODE_OF_CONDUCT.md is not empty"
assert_file_not_empty "CODE_OF_CONDUCT.md is not empty" "$COC"

# Read file content (guard against missing file)
coc_content=""
if [[ -f "$COC" ]]; then
  coc_content="$(cat "$COC")"
fi

# =====================================================================
# 2. Title heading — must be the standard CC heading
# =====================================================================

echo ""
echo "Test 3: Title is standard Contributor Covenant heading"
assert_contains "standard title heading" "# Contributor Covenant Code of Conduct" "$coc_content"

# =====================================================================
# 3. Our Pledge section — CC 2.1 specific wording
# =====================================================================

echo ""
echo "Test 4: Our Pledge section exists"
assert_contains "Our Pledge heading" "## Our Pledge" "$coc_content"

echo ""
echo "Test 5: Our Pledge includes full inclusivity list"
assert_contains "pledge inclusivity list" "regardless of age, body size" "$coc_content"

echo ""
echo "Test 7: Our Pledge mentions 'caste' (CC 2.1 addition over 2.0)"
assert_contains "caste in pledge (CC 2.1 marker)" "caste" "$coc_content"

# =====================================================================
# 4. Our Standards section — CC 2.1 specific wording
# =====================================================================

echo ""
echo "Test 8: Our Standards section exists"
assert_contains "Our Standards heading" "## Our Standards" "$coc_content"

echo ""
echo "Test 9: Standards uses CC 2.1 wording — 'Demonstrating empathy and kindness'"
assert_contains "CC 2.1 empathy phrasing" "Demonstrating empathy and kindness" "$coc_content"

echo ""
echo "Test 10: Standards does NOT use old CC 2.0 wording"
assert_not_contains "no old 'Using welcoming and inclusive language'" "Using welcoming and inclusive language" "$coc_content"

echo ""
echo "Test 11: Standards includes 'Being respectful of differing opinions'"
assert_contains "respectful of opinions" "Being respectful of differing opinions" "$coc_content"

echo ""
echo "Test 12: Standards includes 'Giving and gracefully accepting constructive feedback'"
assert_contains "constructive feedback" "Giving and gracefully accepting constructive feedback" "$coc_content"

echo ""
echo "Test 13: Standards includes responsibility/apology language (CC 2.1)"
assert_contains "accepting responsibility" "Accepting responsibility and apologizing" "$coc_content"

echo ""
echo "Test 14: Standards includes community focus language (CC 2.1)"
assert_contains "community focus" "Focusing on what is best not just for us as individuals, but for the overall community" "$coc_content"

echo ""
echo "Test 15: Unacceptable behavior — sexualized language"
assert_contains "sexualized language prohibition" "The use of sexualized language or imagery" "$coc_content"

echo ""
echo "Test 16: Unacceptable behavior — trolling"
assert_contains "trolling prohibition" "Trolling, insulting or derogatory comments" "$coc_content"

echo ""
echo "Test 17: Unacceptable behavior — harassment"
assert_contains "harassment prohibition" "Public or private harassment" "$coc_content"

echo ""
echo "Test 18: Unacceptable behavior — publishing private information"
assert_contains "publishing private info" "Publishing others" "$coc_content"

echo ""
echo "Test 19: Unacceptable behavior — inappropriate conduct"
assert_contains "inappropriate conduct clause" "reasonably be considered inappropriate" "$coc_content"

# =====================================================================
# 5. Enforcement Responsibilities section — CC 2.1 detailed version
# =====================================================================

echo ""
echo "Test 20: Enforcement Responsibilities section exists"
assert_contains "Enforcement Responsibilities heading" "## Enforcement Responsibilities" "$coc_content"

echo ""
echo "Test 21: Enforcement Responsibilities includes detailed rights list"
assert_contains "right and responsibility to remove, edit, or reject" "right and responsibility to remove, edit, or reject" "$coc_content"

echo ""
echo "Test 22: Enforcement Responsibilities mentions comments, commits, code, wiki edits, issues"
assert_contains "mentions code artifacts" "comments, commits, code, wiki edits, issues" "$coc_content"

# =====================================================================
# 6. Scope section — CC 2.1 with examples
# =====================================================================

echo ""
echo "Test 23: Scope section exists"
assert_contains "Scope heading" "## Scope" "$coc_content"

echo ""
echo "Test 24: Scope includes CC 2.1 examples"
assert_contains "official e-mail address example" "official e-mail address" "$coc_content"

echo ""
echo "Test 25: Scope includes social media example"
assert_contains "social media account example" "official social media account" "$coc_content"

echo ""
echo "Test 26: Scope includes appointed representative example"
assert_contains "appointed representative example" "appointed representative" "$coc_content"

# =====================================================================
# 7. Enforcement section — correct contact email
# =====================================================================

echo ""
echo "Test 27: Enforcement section exists"
assert_contains "Enforcement heading" "## Enforcement" "$coc_content"

echo ""
echo "Test 28: Contact email is morpheus@espmedia.de"
assert_contains "correct contact email" "morpheus@espmedia.de" "$coc_content"

echo ""
echo "Test 29: Does NOT link to GitHub issues for reporting"
assert_not_contains "no GitHub issues reporting link" "github.com/TheMorpheus407/RepoLens/issues" "$coc_content"

echo ""
echo "Test 30: Enforcement mentions community leaders will review"
assert_matches "community leaders investigate" "(?i)community leaders[\s\S]*investigate|investigate[\s\S]*complaints" "$coc_content"

# =====================================================================
# 8. Enforcement Guidelines section — CC 2.1 escalation ladder
# =====================================================================

echo ""
echo "Test 31: Enforcement Guidelines section exists"
assert_contains "Enforcement Guidelines heading" "## Enforcement Guidelines" "$coc_content"

echo ""
echo "Test 32: Level 1 — Correction subsection"
assert_contains "Correction subsection" "### 1. Correction" "$coc_content"

echo ""
echo "Test 33: Level 2 — Warning subsection"
assert_contains "Warning subsection" "### 2. Warning" "$coc_content"

echo ""
echo "Test 34: Level 3 — Temporary Ban subsection"
assert_contains "Temporary Ban subsection" "### 3. Temporary Ban" "$coc_content"

echo ""
echo "Test 35: Level 4 — Permanent Ban subsection"
assert_contains "Permanent Ban subsection" "### 4. Permanent Ban" "$coc_content"

echo ""
echo "Test 36: Correction level includes Community Impact"
assert_matches "Correction has Community Impact" "### 1\. Correction[\s\S]*Community Impact" "$coc_content"

echo ""
echo "Test 37: Correction level includes Consequence"
assert_matches "Correction has Consequence" "### 1\. Correction[\s\S]*Consequence" "$coc_content"

echo ""
echo "Test 38: Warning level includes Community Impact"
assert_matches "Warning has Community Impact" "### 2\. Warning[\s\S]*Community Impact" "$coc_content"

echo ""
echo "Test 39: Warning level includes Consequence"
assert_matches "Warning has Consequence" "### 2\. Warning[\s\S]*Consequence" "$coc_content"

echo ""
echo "Test 40: Temporary Ban level includes Community Impact"
assert_matches "Temporary Ban has Community Impact" "### 3\. Temporary Ban[\s\S]*Community Impact" "$coc_content"

echo ""
echo "Test 41: Temporary Ban level includes Consequence"
assert_matches "Temporary Ban has Consequence" "### 3\. Temporary Ban[\s\S]*Consequence" "$coc_content"

echo ""
echo "Test 42: Permanent Ban level includes Community Impact"
assert_matches "Permanent Ban has Community Impact" "### 4\. Permanent Ban[\s\S]*Community Impact" "$coc_content"

echo ""
echo "Test 43: Permanent Ban level includes Consequence"
assert_matches "Permanent Ban has Consequence" "### 4\. Permanent Ban[\s\S]*Consequence" "$coc_content"

# =====================================================================
# 9. Attribution section — links and version
# =====================================================================

echo ""
echo "Test 44: Attribution section exists"
assert_contains "Attribution heading" "## Attribution" "$coc_content"

echo ""
echo "Test 45: Attribution links to Contributor Covenant homepage"
assert_contains "CC homepage link" "https://www.contributor-covenant.org" "$coc_content"

echo ""
echo "Test 46: Attribution specifies version 2.1"
assert_contains "version 2.1 in attribution" "version/2/1" "$coc_content"

echo ""
echo "Test 47: Attribution includes FAQ link"
assert_contains "FAQ link" "FAQ" "$coc_content"

echo ""
echo "Test 48: Attribution includes translations link"
assert_contains "translations link" "translations" "$coc_content"

# =====================================================================
# 10. Section ordering — all 8 sections in the correct order
# =====================================================================

echo ""
echo "Test 49: Sections appear in correct order"
TOTAL=$((TOTAL + 1))
sections_ordered=true
if [[ -f "$COC" ]]; then
  pledge_line="$(grep -n '## Our Pledge' "$COC" | head -1 | cut -d: -f1)"
  standards_line="$(grep -n '## Our Standards' "$COC" | head -1 | cut -d: -f1)"
  responsibilities_line="$(grep -n '## Enforcement Responsibilities' "$COC" | head -1 | cut -d: -f1)"
  scope_line="$(grep -n '## Scope' "$COC" | head -1 | cut -d: -f1)"
  enforcement_line="$(grep -n '## Enforcement$' "$COC" | head -1 | cut -d: -f1)"
  guidelines_line="$(grep -n '## Enforcement Guidelines' "$COC" | head -1 | cut -d: -f1)"
  attribution_line="$(grep -n '## Attribution' "$COC" | head -1 | cut -d: -f1)"

  if [[ -z "$pledge_line" || -z "$standards_line" || -z "$responsibilities_line" || \
        -z "$scope_line" || -z "$enforcement_line" || -z "$guidelines_line" || \
        -z "$attribution_line" ]]; then
    sections_ordered=false
  elif [[ "$pledge_line" -ge "$standards_line" || \
          "$standards_line" -ge "$responsibilities_line" || \
          "$responsibilities_line" -ge "$scope_line" || \
          "$scope_line" -ge "$enforcement_line" || \
          "$enforcement_line" -ge "$guidelines_line" || \
          "$guidelines_line" -ge "$attribution_line" ]]; then
    sections_ordered=false
  fi
else
  sections_ordered=false
fi
if $sections_ordered; then
  PASS=$((PASS + 1))
  echo "  PASS: all 8 sections appear in correct order"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: sections are missing or out of order"
  echo "    Expected order: Pledge → Standards → Enforcement Responsibilities → Scope → Enforcement → Enforcement Guidelines → Attribution"
fi

# =====================================================================
# 11. File size / line count — standard CC 2.1 is ~128 lines
# =====================================================================

echo ""
echo "Test 50: File line count in expected range for standard CC 2.1"
if [[ -f "$COC" ]]; then
  line_count="$(wc -l < "$COC")"
  TOTAL=$((TOTAL + 1))
  if [[ "$line_count" -ge 100 && "$line_count" -le 180 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: line count ($line_count) in expected range (100-180)"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: line count ($line_count) outside expected range (100-180)"
    echo "    Standard CC 2.1 is approximately 128 lines"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: file missing, cannot check line count"
fi

# =====================================================================
# 12. File is plain text markdown (not HTML or binary)
# =====================================================================

echo ""
echo "Test 51: File is plain text markdown, not HTML or binary"
if [[ -f "$COC" ]]; then
  TOTAL=$((TOTAL + 1))
  if ! grep -qP '\x00' "$COC" 2>/dev/null && ! grep -qi '<html\|<head\|<body' "$COC"; then
    PASS=$((PASS + 1))
    echo "  PASS: CODE_OF_CONDUCT.md is a text file"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: CODE_OF_CONDUCT.md appears to be binary or HTML"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: file missing"
fi

# =====================================================================
# 13. File ends with trailing newline
# =====================================================================

echo ""
echo "Test 52: File ends with trailing newline"
if [[ -f "$COC" ]]; then
  TOTAL=$((TOTAL + 1))
  last_byte="$(tail -c1 "$COC" | od -An -tx1 | tr -d ' ')"
  if [[ "$last_byte" == "0a" || -z "$last_byte" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: file ends with trailing newline"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: file does not end with trailing newline"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: file missing"
fi

# =====================================================================
# 14. No conflicting CoC files
# =====================================================================

echo ""
echo "Test 53: No conflicting code of conduct files"
TOTAL=$((TOTAL + 1))
conflicting=0
for f in "$SCRIPT_DIR/CODE_OF_CONDUCT.txt" "$SCRIPT_DIR/CODE_OF_CONDUCT.rst" "$SCRIPT_DIR/code_of_conduct.md"; do
  if [[ -f "$f" ]]; then
    conflicting=$((conflicting + 1))
  fi
done
if [[ "$conflicting" -eq 0 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: no conflicting code of conduct files"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: found $conflicting conflicting code of conduct file(s)"
fi

# =====================================================================
# 15. README links to CODE_OF_CONDUCT.md
# =====================================================================

echo ""
echo "Test 54: README.md links to CODE_OF_CONDUCT.md"
if [[ -f "$README" ]]; then
  readme_content="$(cat "$README")"
  TOTAL=$((TOTAL + 1))
  if echo "$readme_content" | grep -qP '\]\(CODE_OF_CONDUCT\.md\)'; then
    PASS=$((PASS + 1))
    echo "  PASS: README links to CODE_OF_CONDUCT.md"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: README does not link to CODE_OF_CONDUCT.md"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: README.md not found"
fi

# =====================================================================
# 16. CONTRIBUTING.md links to CODE_OF_CONDUCT.md
# =====================================================================

echo ""
echo "Test 55: CONTRIBUTING.md links to CODE_OF_CONDUCT.md"
if [[ -f "$CONTRIBUTING" ]]; then
  contributing_content="$(cat "$CONTRIBUTING")"
  TOTAL=$((TOTAL + 1))
  if echo "$contributing_content" | grep -qP '\]\(CODE_OF_CONDUCT\.md\)'; then
    PASS=$((PASS + 1))
    echo "  PASS: CONTRIBUTING.md links to CODE_OF_CONDUCT.md"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: CONTRIBUTING.md does not link to CODE_OF_CONDUCT.md"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: CONTRIBUTING.md not found"
fi

# =====================================================================
# 17. Coverage tests — additional behavioral verification
# =====================================================================

echo ""
echo "Test 56: Our Pledge includes 'color' (CC 2.1 addition alongside caste)"
assert_contains "color in pledge (CC 2.1 marker)" "color" "$coc_content"

echo ""
echo "Test 57: Enforcement mentions privacy and security of reporter"
assert_contains "reporter privacy clause" "respect the privacy and security" "$coc_content"

echo ""
echo "Test 58: Enforcement says complaints reviewed promptly and fairly"
assert_contains "promptly and fairly (CC 2.1)" "promptly and fairly" "$coc_content"

echo ""
echo "Test 59: Attribution references Mozilla's code of conduct enforcement ladder"
assert_contains "Mozilla CoC reference" "Mozilla" "$coc_content"

echo ""
echo "Test 60: Correction level mentions private written warning"
assert_contains "Correction: private written warning" "private, written warning" "$coc_content"

echo ""
echo "Test 61: Warning level mentions temporary or permanent ban escalation"
assert_contains "Warning: escalation to ban" "temporary or permanent ban" "$coc_content"

echo ""
echo "Test 62: Temporary Ban level mentions permanent ban escalation"
assert_contains "Temporary Ban: escalation to permanent ban" "permanent ban" "$coc_content"

echo ""
echo "Test 63: Permanent Ban level mentions pattern of violation"
assert_contains "Permanent Ban: pattern of violation" "pattern of violation" "$coc_content"

echo ""
echo "Test 64: Enforcement Guidelines intro mentions Community Impact Guidelines"
assert_contains "Community Impact Guidelines intro" "Community Impact Guidelines" "$coc_content"

echo ""
echo "Test 65: Reference link definitions include homepage URL"
assert_contains "homepage reference link" "[homepage]: https://www.contributor-covenant.org" "$coc_content"

echo ""
echo "Test 66: Reference link definitions include FAQ URL"
assert_contains "FAQ reference link" "[FAQ]: https://www.contributor-covenant.org/faq" "$coc_content"

echo ""
echo "Test 67: Reference link definitions include translations URL"
assert_contains "translations reference link" "[translations]: https://www.contributor-covenant.org/translations" "$coc_content"

# =====================================================================
# 18. Coverage gap tests — additional verification for implemented code
# =====================================================================

echo ""
echo "Test 68: CHANGELOG.md mentions Code of Conduct addition"
if [[ -f "$SCRIPT_DIR/CHANGELOG.md" ]]; then
  changelog_content="$(cat "$SCRIPT_DIR/CHANGELOG.md")"
  assert_contains "CHANGELOG entry for CoC" "Code of Conduct" "$changelog_content"
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: CHANGELOG.md not found"
fi

echo ""
echo "Test 69: Our Pledge second paragraph — welcoming, diverse, inclusive, healthy community"
assert_contains "healthy community commitment" "welcoming, diverse, inclusive, and healthy community" "$coc_content"

echo ""
echo "Test 70: Enforcement Responsibilities — communicate moderation decisions"
assert_contains "moderation communication clause" "moderation decisions when appropriate" "$coc_content"

echo ""
echo "Test 71: Enforcement Responsibilities — 'not aligned to this Code of Conduct'"
assert_contains "not aligned clause" "not aligned to this Code of Conduct" "$coc_content"

echo ""
echo "Test 72: Reference link definitions include v2.1 URL"
assert_contains "v2.1 reference link" "[v2.1]: https://www.contributor-covenant.org/version/2/1/code_of_conduct.html" "$coc_content"

# --- Summary ---
echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
