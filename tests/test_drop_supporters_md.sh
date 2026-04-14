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

# Tests for issue #14: Drop SUPPORTERS.md plan; mention Patreon generically
# Validates: no SUPPORTERS.md, generic Patreon acknowledgment in README, no PII.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
README="$SCRIPT_DIR/README.md"

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
  if echo "$haystack" | grep -qP "$pattern"; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    Expected to match pattern: $pattern"
  fi
}

assert_not_matches() {
  local desc="$1" pattern="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if ! echo "$haystack" | grep -qP "$pattern"; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    Expected NOT to match pattern: $pattern"
  fi
}

assert_file_not_exists() {
  local desc="$1" filepath="$2"
  TOTAL=$((TOTAL + 1))
  if [[ ! -f "$filepath" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    File should not exist: $filepath"
  fi
}

echo ""
echo "=== Test Suite: Drop SUPPORTERS.md plan; mention Patreon generically (issue #14) ==="
echo ""

# Read README content (guard against missing file)
readme_content=""
if [[ -f "$README" ]]; then
  readme_content="$(cat "$README")"
fi

# =====================================================================
# SECTION A: SUPPORTERS.md Must Not Exist
# =====================================================================

# =====================================================================
# Test 1: SUPPORTERS.md does not exist at repo root
# =====================================================================

echo "Test 1: SUPPORTERS.md does not exist at repo root"
assert_file_not_exists "no SUPPORTERS.md at root" "$SCRIPT_DIR/SUPPORTERS.md"

# =====================================================================
# Test 2: No SUPPORTERS.md anywhere in the repository
# =====================================================================

echo ""
echo "Test 2: No SUPPORTERS.md anywhere in the repository"
TOTAL=$((TOTAL + 1))
supporters_files="$(find "$SCRIPT_DIR" -name "SUPPORTERS.md" -not -path "*/.git/*" 2>/dev/null)"
if [[ -z "$supporters_files" ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: no SUPPORTERS.md found anywhere"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: SUPPORTERS.md found at: $supporters_files"
fi

# =====================================================================
# Test 3: No SUPPORTERS file with any extension (md, txt, rst)
# =====================================================================

echo ""
echo "Test 3: No SUPPORTERS file with any extension"
TOTAL=$((TOTAL + 1))
supporters_any="$(find "$SCRIPT_DIR" -maxdepth 1 -iname "SUPPORTERS*" -not -path "*/.git/*" 2>/dev/null)"
if [[ -z "$supporters_any" ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: no SUPPORTERS file in any format"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: SUPPORTERS file found: $supporters_any"
fi

# =====================================================================
# SECTION B: README Support Section — Generic Patreon Acknowledgment
# =====================================================================

# =====================================================================
# Test 4: README contains a Support section
# =====================================================================

echo ""
echo "Test 4: README contains a Support section"
assert_matches "has ## Support heading" "^## Support" "$readme_content"

# =====================================================================
# Test 5: README contains Patreon link
# =====================================================================

echo ""
echo "Test 5: README contains Patreon link"
assert_contains "Patreon URL present" "patreon.com/themorpheus407" "$readme_content"

# =====================================================================
# Test 6: README support section contains generic acknowledgment wording
# =====================================================================
# The issue says: "Supported by Patreon patrons — thank you" with link

echo ""
echo "Test 6: README contains generic Patreon acknowledgment"
assert_matches "generic acknowledgment" "(?i)supported by.*patreon.*patrons" "$readme_content"

# =====================================================================
# Test 7: README support section uses a single acknowledgment line, not multi-bullet CTA
# =====================================================================
# The old format had a bullet list. The new format should not have bullets in the support section.

echo ""
echo "Test 7: README support section does not use bullet-list CTA format"
TOTAL=$((TOTAL + 1))
support_section="$(echo "$readme_content" | sed -n '/^## Support$/,/^## /p' | head -n -1)"
if echo "$support_section" | grep -qP '^\s*-\s+'; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: Support section still contains bullet points"
  echo "    Section content: $(echo "$support_section" | head -5)"
else
  PASS=$((PASS + 1))
  echo "  PASS: Support section has no bullet points"
fi

# =====================================================================
# Test 8: README support section does not contain "consider supporting" CTA
# =====================================================================
# Old text: "If you find RepoLens useful, consider supporting its development:"

echo ""
echo "Test 8: README does not have old CTA wording"
assert_not_contains "no old CTA" "consider supporting its development" "$readme_content"

# =====================================================================
# Test 9: README support section does not list "Star this repo"
# =====================================================================

echo ""
echo "Test 9: Support section does not contain 'Star this repo'"
assert_not_contains "no star CTA" "Star this repo" "$readme_content"

# =====================================================================
# Test 10: README support section does not list "Share it with your team"
# =====================================================================

echo ""
echo "Test 10: Support section does not contain 'Share it with your team'"
assert_not_contains "no share CTA" "Share it with your team" "$readme_content"

# =====================================================================
# Test 11: Patreon link is a proper markdown link (clickable)
# =====================================================================

echo ""
echo "Test 11: Patreon link is a proper markdown link"
assert_matches "markdown Patreon link" "\[.*\]\(https?://patreon\.com/themorpheus407\)" "$readme_content"

# =====================================================================
# SECTION C: No Personally-Identifying Supporter Data
# =====================================================================

# =====================================================================
# Test 12: config/sponsors.json contains no individual person names
# =====================================================================
# sponsors.json should only have platform entries, not individual supporters

echo ""
echo "Test 12: config/sponsors.json has no individual sponsor type"
TOTAL=$((TOTAL + 1))
sponsors_json="$SCRIPT_DIR/config/sponsors.json"
if [[ -f "$sponsors_json" ]]; then
  individual_count="$(jq '[.sponsors[] | select(.type == "individual")] | length' "$sponsors_json" 2>/dev/null)"
  if [[ "$individual_count" == "0" ]] || [[ -z "$individual_count" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: no individual sponsor entries in sponsors.json"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: found $individual_count individual sponsor entries in sponsors.json"
  fi
else
  PASS=$((PASS + 1))
  echo "  PASS: sponsors.json does not exist (no PII risk)"
fi

# =====================================================================
# Test 13: No file named PATRONS or BACKERS exists
# =====================================================================

echo ""
echo "Test 13: No PATRONS or BACKERS files exist"
TOTAL=$((TOTAL + 1))
pii_files="$(find "$SCRIPT_DIR" -maxdepth 1 \( -iname "PATRONS*" -o -iname "BACKERS*" \) -not -path "*/.git/*" 2>/dev/null)"
if [[ -z "$pii_files" ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: no PATRONS or BACKERS files"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: found PII-risk files: $pii_files"
fi

# =====================================================================
# Test 14: README does not list individual supporter names
# =====================================================================
# Check that the support section doesn't enumerate specific people

echo ""
echo "Test 14: README support section does not enumerate individual names"
TOTAL=$((TOTAL + 1))
support_section="$(echo "$readme_content" | sed -n '/^## Support$/,/^## /p' | head -n -1)"
support_lines="$(echo "$support_section" | grep -cP '\S' 2>/dev/null || echo 0)"
if [[ "$support_lines" -le 5 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: Support section is concise ($support_lines non-empty lines) — no name list"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: Support section has $support_lines non-empty lines — may contain a name list"
fi

# =====================================================================
# Test 15: README does not contain "thank you <name>" patterns
# =====================================================================

echo ""
echo "Test 15: README does not contain personal thank-you patterns"
assert_not_matches "no personal thanks" "(?i)thanks? (to|you,?) [A-Z][a-z]+ [A-Z][a-z]+" "$readme_content"

# =====================================================================
# SECTION D: Existing Tests Compatibility
# =====================================================================

# =====================================================================
# Test 16: README still matches existing test_readme_rewrite.sh sponsor regex
# =====================================================================
# test_readme_rewrite.sh test 25 checks (?i)(sponsor|support|patreon|fund|donat)
# The new wording must still match at least one of these keywords.

echo ""
echo "Test 16: README still matches existing sponsor/support regex"
assert_matches "matches existing test regex" "(?i)(sponsor|support|patreon|fund|donat)" "$readme_content"

# =====================================================================
# Test 17: config/sponsors.json still has platform entries (not emptied)
# =====================================================================
# Ensure the implementation doesn't accidentally remove sponsors.json content

echo ""
echo "Test 17: config/sponsors.json retains platform entries"
TOTAL=$((TOTAL + 1))
if [[ -f "$sponsors_json" ]]; then
  platform_count="$(jq '[.sponsors[] | select(.type == "platform")] | length' "$sponsors_json" 2>/dev/null)"
  if [[ "$platform_count" -gt 0 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: sponsors.json has $platform_count platform entries"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: sponsors.json has no platform entries (may have been accidentally emptied)"
  fi
else
  TOTAL=$((TOTAL - 1))
  echo "  SKIP: sponsors.json does not exist"
fi

# =====================================================================
# Test 18: Patreon entry still exists in config/sponsors.json
# =====================================================================

echo ""
echo "Test 18: Patreon entry exists in config/sponsors.json"
TOTAL=$((TOTAL + 1))
if [[ -f "$sponsors_json" ]]; then
  has_patreon="$(jq '[.sponsors[] | select(.url | test("patreon"))] | length' "$sponsors_json" 2>/dev/null)"
  if [[ "$has_patreon" -gt 0 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: Patreon entry exists in sponsors.json"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: Patreon entry missing from sponsors.json"
  fi
else
  TOTAL=$((TOTAL - 1))
  echo "  SKIP: sponsors.json does not exist"
fi

# =====================================================================
# Test 19: README contains "thank you" acknowledgment
# =====================================================================
# The issue specifies: "Supported by Patreon patrons — thank you"

echo ""
echo "Test 19: README contains thank-you acknowledgment"
assert_matches "has thank you" "(?i)thank you" "$readme_content"

# =====================================================================
# Test 20: Support section is minimal (heading + 1-2 content lines)
# =====================================================================
# The issue says "single line" — the section should be heading + one line of content

echo ""
echo "Test 20: Support section is minimal (single content line)"
TOTAL=$((TOTAL + 1))
support_section="$(echo "$readme_content" | sed -n '/^## Support$/,/^## /p' | head -n -1)"
content_lines="$(echo "$support_section" | grep -cP '^\S' 2>/dev/null || echo 0)"
# Expect: 1 heading line + 1 content line = 2 lines with non-whitespace starting chars
if [[ "$content_lines" -le 3 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: Support section has $content_lines non-blank lines (minimal)"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: Support section has $content_lines non-blank lines (expected <= 3)"
  echo "    Section: $(echo "$support_section" | head -5)"
fi

# =====================================================================
# Test 21: Support section does not contain "Sponsor on GitHub" CTA
# =====================================================================
# Old text: "- [Sponsor on GitHub](https://github.com/sponsors/TheMorpheus407)"
# All four old bullets should be gone — tests 8-10 cover three, this covers the fourth.

echo ""
echo "Test 21: Support section does not contain 'Sponsor on GitHub'"
assert_not_contains "no GitHub Sponsors CTA" "Sponsor on GitHub" "$readme_content"

# =====================================================================
# Test 22: Support section does not contain github.com/sponsors URL
# =====================================================================
# The GitHub Sponsors link was removed from README (still available in --version/--about).

echo ""
echo "Test 22: Support section does not contain GitHub Sponsors URL"
assert_not_contains "no GitHub Sponsors URL in README" "github.com/sponsors" "$readme_content"

# --- Summary ---
echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
