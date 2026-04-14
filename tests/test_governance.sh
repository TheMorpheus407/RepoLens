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

# Tests for issue #30: Add GOVERNANCE.md documenting project leadership and decisions
# Validates that GOVERNANCE.md exists with correct content: maintainer identity,
# BDFL decision-making model, cross-references to other community health files,
# and README link for discoverability.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GOVERNANCE="$SCRIPT_DIR/GOVERNANCE.md"
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
echo "=== Test Suite: GOVERNANCE.md (issue #30) ==="
echo ""

# =====================================================================
# 1. GOVERNANCE.md file existence and basic properties
# =====================================================================

echo "Test 1: GOVERNANCE.md exists at repo root"
assert_file_exists "GOVERNANCE.md file exists" "$GOVERNANCE"

echo ""
echo "Test 2: GOVERNANCE.md is not empty"
assert_file_not_empty "GOVERNANCE.md is not empty" "$GOVERNANCE"

# =====================================================================
# 2. GOVERNANCE.md is plain text (not binary, not HTML)
# =====================================================================

echo ""
echo "Test 3: GOVERNANCE.md is plain text"
if [[ -f "$GOVERNANCE" ]]; then
  TOTAL=$((TOTAL + 1))
  if ! grep -qP '\x00' "$GOVERNANCE" 2>/dev/null && ! grep -qi '<html\|<head\|<body' "$GOVERNANCE"; then
    PASS=$((PASS + 1))
    echo "  PASS: GOVERNANCE.md is a text file"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: GOVERNANCE.md appears to be binary or HTML"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: GOVERNANCE.md file missing"
fi

# Read content for subsequent tests (guard against missing file)
governance_content=""
if [[ -f "$GOVERNANCE" ]]; then
  governance_content="$(cat "$GOVERNANCE")"
fi

# =====================================================================
# 3. GOVERNANCE.md title — must have a Governance heading
# =====================================================================

echo ""
echo "Test 4: GOVERNANCE.md has a top-level Governance heading"
assert_matches "has Governance heading" "^#\s+Governance" "$governance_content"

# =====================================================================
# 4. Project leadership — names maintainer and organization
# =====================================================================

echo ""
echo "Test 5: Mentions maintainer @TheMorpheus407"
assert_contains "mentions @TheMorpheus407" "@TheMorpheus407" "$governance_content"

echo ""
echo "Test 6: Mentions maintainer name Cedric Moessner"
assert_matches "mentions Cedric Moessner" "(?i)cedric\s+moessner" "$governance_content"

echo ""
echo "Test 7: Mentions Bootstrap Academy"
assert_contains "mentions Bootstrap Academy" "Bootstrap Academy" "$governance_content"

# =====================================================================
# 5. Decision-making model — must describe BDFL model
# =====================================================================

echo ""
echo "Test 8: Describes BDFL governance model"
assert_contains "mentions BDFL" "BDFL" "$governance_content"

echo ""
echo "Test 9: Expands BDFL acronym"
assert_contains "expands BDFL acronym" "Benevolent Dictator for Life" "$governance_content"

echo ""
echo "Test 10: Mentions decision scope — features"
assert_matches "mentions feature decisions" "(?i)feature" "$governance_content"

echo ""
echo "Test 11: Mentions decision scope — releases"
assert_matches "mentions release decisions" "(?i)release" "$governance_content"

echo ""
echo "Test 12: Mentions decision scope — lens domains"
assert_matches "mentions lens domain decisions" "(?i)lens" "$governance_content"

# =====================================================================
# 6. Required sections — headings or clear content areas
# =====================================================================

echo ""
echo "Test 13: Has a Project Leadership section"
assert_matches "has Project Leadership section" "(?i)##\s+.*(?:project\s+)?leadership" "$governance_content"

echo ""
echo "Test 14: Has a Decision-Making section"
assert_matches "has Decision-Making section" "(?i)##\s+.*decision" "$governance_content"

echo ""
echo "Test 15: Has a Contribution / Contributing section"
assert_matches "has Contributing section" "(?i)##\s+.*contribut" "$governance_content"

echo ""
echo "Test 16: Has a Conflict Resolution or Escalation section"
assert_matches "has Conflict Resolution section" "(?i)##\s+.*(conflict|escalation|dispute|resolution)" "$governance_content"

echo ""
echo "Test 17: Has an Evolution section"
assert_matches "has Evolution section" "(?i)##\s+.*evolution" "$governance_content"

# =====================================================================
# 7. Cross-references to other community health files
# =====================================================================

echo ""
echo "Test 18: Links to CONTRIBUTING.md"
assert_matches "links to CONTRIBUTING.md" "\[.*\]\(CONTRIBUTING\.md\)" "$governance_content"

echo ""
echo "Test 19: Links to CODE_OF_CONDUCT.md"
assert_matches "links to CODE_OF_CONDUCT.md" "\[.*\]\(CODE_OF_CONDUCT\.md\)" "$governance_content"

echo ""
echo "Test 20: Links to SECURITY.md"
assert_matches "links to SECURITY.md" "\[.*\]\(SECURITY\.md\)" "$governance_content"

# =====================================================================
# 8. Apache-2.0 fork right as escape valve
# =====================================================================

echo ""
echo "Test 21: Mentions Apache-2.0 license"
assert_matches "mentions Apache-2.0" "(?i)apache" "$governance_content"

echo ""
echo "Test 22: Mentions forking as an option"
assert_matches "mentions fork right" "(?i)fork" "$governance_content"

# =====================================================================
# 9. Communication channels
# =====================================================================

echo ""
echo "Test 23: Mentions GitHub Issues as communication channel"
assert_matches "mentions GitHub Issues" "(?i)github\s+issues?" "$governance_content"

# =====================================================================
# 10. No conflicting governance files
# =====================================================================

echo ""
echo "Test 24: No conflicting governance files"
TOTAL=$((TOTAL + 1))
conflicting_count=0
for f in "$SCRIPT_DIR/GOVERNANCE.txt" "$SCRIPT_DIR/GOVERNANCE.rst" "$SCRIPT_DIR/governance.md"; do
  if [[ -f "$f" ]]; then
    conflicting_count=$((conflicting_count + 1))
  fi
done
if [[ "$conflicting_count" -eq 0 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: no conflicting governance files"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: found $conflicting_count conflicting governance file(s)"
fi

# =====================================================================
# 11. README.md links to GOVERNANCE.md
# =====================================================================

readme_content=""
if [[ -f "$README" ]]; then
  readme_content="$(cat "$README")"
fi

echo ""
echo "Test 25: README.md contains link to GOVERNANCE.md"
if [[ -f "$README" ]]; then
  TOTAL=$((TOTAL + 1))
  if echo "$readme_content" | grep -qP '\]\(GOVERNANCE\.md\)'; then
    PASS=$((PASS + 1))
    echo "  PASS: README contains link to GOVERNANCE.md"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: README does not contain link to GOVERNANCE.md"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: README.md not found"
fi

echo ""
echo "Test 26: README GOVERNANCE.md link resolves to existing file"
if [[ -f "$README" ]]; then
  TOTAL=$((TOTAL + 1))
  if echo "$readme_content" | grep -qP '\]\(GOVERNANCE\.md\)' && [[ -f "$GOVERNANCE" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: README links to GOVERNANCE.md and file exists"
  elif ! echo "$readme_content" | grep -qP '\]\(GOVERNANCE\.md\)'; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: README does not contain GOVERNANCE.md link"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: README links to GOVERNANCE.md but file does not exist"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: README.md not found"
fi

echo ""
echo "Test 27: README governance link is in the community section"
if [[ -f "$README" ]]; then
  TOTAL=$((TOTAL + 1))
  # The governance link should appear near the Contributing/Authors/Security section
  # (between the Contributing heading and the Legal heading)
  community_section="$(sed -n '/^## Contributing/,/^## Legal/p' "$README")"
  if echo "$community_section" | grep -qP '\]\(GOVERNANCE\.md\)'; then
    PASS=$((PASS + 1))
    echo "  PASS: GOVERNANCE.md link is in the community section of README"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: GOVERNANCE.md link is not in the community section of README"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: README.md not found"
fi

# =====================================================================
# 12. GOVERNANCE.md reasonable size — not too short, not too long
# =====================================================================

echo ""
echo "Test 28: GOVERNANCE.md has reasonable length"
if [[ -f "$GOVERNANCE" ]]; then
  line_count="$(wc -l < "$GOVERNANCE")"
  TOTAL=$((TOTAL + 1))
  if [[ "$line_count" -ge 20 && "$line_count" -le 200 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: GOVERNANCE.md has $line_count lines (expected 20-200)"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: GOVERNANCE.md has $line_count lines (expected 20-200)"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: GOVERNANCE.md file missing"
fi

# =====================================================================
# 13. Content quality — must not be aspirational / over-promising
# =====================================================================

echo ""
echo "Test 29: Does not describe a committee that does not exist"
assert_not_contains "no committee claim" "steering committee" "$governance_content"
assert_not_contains "no TSC claim" "technical steering committee" "$governance_content"

echo ""
echo "Test 30: Does not claim multiple maintainers"
assert_not_contains "no multiple maintainers claim" "maintainer team" "$governance_content"

# =====================================================================
# 14. Acceptance criteria for contributions
# =====================================================================

echo ""
echo "Test 31: Mentions contribution acceptance criteria"
assert_matches "mentions quality criteria" "(?i)quality" "$governance_content"

echo ""
echo "Test 32: Mentions test requirements for contributions"
assert_matches "mentions test requirements" "(?i)test" "$governance_content"

# =====================================================================
# 15. Communication section heading (consistency with other heading checks)
# =====================================================================

echo ""
echo "Test 33: Has a Communication section"
assert_matches "has Communication section" "(?i)##\s+.*communication" "$governance_content"

# =====================================================================
# 16. Decision scope — additional items from implementation
# =====================================================================

echo ""
echo "Test 34: Mentions decision scope — breaking changes"
assert_matches "mentions breaking changes" "(?i)breaking\s+change" "$governance_content"

echo ""
echo "Test 35: Mentions decision scope — architecture"
assert_matches "mentions architecture decisions" "(?i)architecture" "$governance_content"

# =====================================================================
# 17. Acceptance criteria — domain fit (RepoLens-specific)
# =====================================================================

echo ""
echo "Test 36: Mentions domain fit as acceptance criterion"
assert_matches "mentions domain fit" "(?i)domain\s+fit" "$governance_content"

# =====================================================================
# 18. Communication channels — Pull Requests
# =====================================================================

echo ""
echo "Test 37: Mentions Pull Requests as communication channel"
assert_matches "mentions Pull Requests" "(?i)pull\s+request" "$governance_content"

# =====================================================================
# 19. Transparency — decisions happen in public
# =====================================================================

echo ""
echo "Test 38: Mentions public/transparent decision-making"
assert_matches "mentions public decisions" "(?i)(in\s+public|transparen)" "$governance_content"

# =====================================================================
# 20. README — has a Governance heading (not just the link)
# =====================================================================

echo ""
echo "Test 39: README has a Governance heading"
if [[ -f "$README" ]]; then
  TOTAL=$((TOTAL + 1))
  if echo "$readme_content" | grep -qP '^## Governance'; then
    PASS=$((PASS + 1))
    echo "  PASS: README has ## Governance heading"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: README does not have ## Governance heading"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: README.md not found"
fi

# =====================================================================
# 21. Cross-reference — NOTICE file
# =====================================================================

echo ""
echo "Test 40: Links to NOTICE file"
assert_matches "links to NOTICE" "\[.*\]\(NOTICE\)" "$governance_content"

# --- Summary ---
echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
