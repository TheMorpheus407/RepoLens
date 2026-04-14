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

# Tests for issue #19: Add CHANGELOG.md with v0.1.0 first entry
#
# Behavioral contract:
# CHANGELOG.md exists in Keep-a-Changelog format with a complete v0.1.0 entry
# documenting all 8 operational modes, key features, and first-release context.
# README.md links to the CHANGELOG.
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

echo ""
echo "=== Test Suite: CHANGELOG.md with v0.1.0 entry (issue #19) ==="
echo ""

changelog="$SCRIPT_DIR/CHANGELOG.md"
readme="$SCRIPT_DIR/README.md"

changelog_content=""
if [[ -f "$changelog" ]]; then
  changelog_content="$(cat "$changelog")"
fi

readme_content=""
if [[ -f "$readme" ]]; then
  readme_content="$(cat "$readme")"
fi

# =====================================================================
# 1. CHANGELOG.md file existence and basic structure
# =====================================================================

echo "--- Section 1: File existence and Keep-a-Changelog format ---"
echo ""

echo "Test 1: CHANGELOG.md exists"
assert_file_exists "CHANGELOG.md exists at repo root" "$changelog"

echo ""
echo "Test 2: CHANGELOG.md is not empty"
TOTAL=$((TOTAL + 1))
if [[ -s "$changelog" ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: CHANGELOG.md is not empty"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: CHANGELOG.md is empty or missing"
fi

echo ""
echo "Test 3: CHANGELOG.md references Keep a Changelog"
assert_contains "references Keep a Changelog" "keepachangelog.com" "$changelog_content"

echo ""
echo "Test 4: CHANGELOG.md references Semantic Versioning"
assert_contains "references Semantic Versioning" "semver.org" "$changelog_content"

# =====================================================================
# 2. v0.1.0 entry structure
# =====================================================================

echo ""
echo "--- Section 2: v0.1.0 entry structure ---"
echo ""

echo "Test 5: CHANGELOG has v0.1.0 version heading"
assert_matches "v0.1.0 version heading exists" '## \[0\.1\.0\]' "$changelog_content"

echo ""
echo "Test 6: v0.1.0 entry has a date"
assert_matches "v0.1.0 entry includes date" '\[0\.1\.0\].*\d{4}-\d{2}-\d{2}' "$changelog_content"

echo ""
echo "Test 7: CHANGELOG has ### Added section"
assert_matches "has Added section" '### Added' "$changelog_content"

echo ""
echo "Test 8: v0.1.0 footer link exists"
assert_matches "footer link for v0.1.0" '\[0\.1\.0\]:.*https://github\.com' "$changelog_content"

# =====================================================================
# 3. Mode documentation — all 8 modes must use correct CLI names
# =====================================================================

echo ""
echo "--- Section 3: Operational mode documentation ---"
echo ""

echo "Test 9: CHANGELOG documents audit mode"
assert_contains "documents audit mode" "audit" "$changelog_content"

echo ""
echo "Test 10: CHANGELOG documents feature mode"
assert_contains "documents feature mode" "feature" "$changelog_content"

echo ""
echo "Test 11: CHANGELOG documents bugfix mode"
assert_contains "documents bugfix mode" "bugfix" "$changelog_content"

echo ""
echo "Test 12: CHANGELOG documents discover mode"
assert_contains "documents discover mode" "discover" "$changelog_content"

echo ""
echo "Test 13: CHANGELOG documents deploy mode"
assert_contains "documents deploy mode" "deploy" "$changelog_content"

echo ""
echo "Test 14: CHANGELOG documents custom mode"
assert_contains "documents custom mode" "custom" "$changelog_content"

echo ""
echo "Test 15: CHANGELOG documents opensource mode"
assert_contains "documents opensource mode" "opensource" "$changelog_content"

echo ""
echo "Test 16: CHANGELOG documents content mode"
TOTAL=$((TOTAL + 1))
if echo "$changelog_content" | grep -qP '\bcontent\b'; then
  PASS=$((PASS + 1))
  echo "  PASS: documents content mode"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: CHANGELOG should document the content mode"
fi

echo ""
echo "Test 17: CHANGELOG does not use incorrect mode name oss-readiness"
assert_not_contains "no incorrect mode name oss-readiness" "oss-readiness" "$changelog_content"

echo ""
echo "Test 18: CHANGELOG does not use incorrect mode name content-quality"
assert_not_contains "no incorrect mode name content-quality" "content-quality" "$changelog_content"

# =====================================================================
# 4. Key features documented
# =====================================================================

echo ""
echo "--- Section 4: Key feature documentation ---"
echo ""

echo "Test 19: CHANGELOG documents lens domain taxonomy"
TOTAL=$((TOTAL + 1))
if echo "$changelog_content" | grep -qP '(192.*code|18.*tool gate|14.*discovery|26.*deploy|13.*open.source|17.*content)'; then
  PASS=$((PASS + 1))
  echo "  PASS: documents lens counts / domain taxonomy"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: CHANGELOG should document lens domain taxonomy with counts"
fi

echo ""
echo "Test 20: CHANGELOG documents DONE×3 streak protocol"
TOTAL=$((TOTAL + 1))
if echo "$changelog_content" | grep -qiP 'DONE.*[x×].*3|DONE.*streak'; then
  PASS=$((PASS + 1))
  echo "  PASS: documents DONE×3 streak protocol"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: CHANGELOG should document DONE×3 streak detection"
fi

echo ""
echo "Test 21: CHANGELOG documents parallel execution"
assert_contains "documents parallel execution" "arallel" "$changelog_content"

echo ""
echo "Test 22: CHANGELOG documents --agent flag"
TOTAL=$((TOTAL + 1))
if echo "$changelog_content" | grep -qiP '(agent.agnostic|--agent|supports.*claude.*codex)'; then
  PASS=$((PASS + 1))
  echo "  PASS: documents --agent flag / agent-agnostic design"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: CHANGELOG should document the --agent flag or agent-agnostic design"
fi

echo ""
echo "Test 23: CHANGELOG documents resume support"
TOTAL=$((TOTAL + 1))
if echo "$changelog_content" | grep -qiP '(resume|--resume)'; then
  PASS=$((PASS + 1))
  echo "  PASS: documents resume support"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: CHANGELOG should document resume support"
fi

echo ""
echo "Test 24: CHANGELOG documents --hosted DAST scanning"
TOTAL=$((TOTAL + 1))
if echo "$changelog_content" | grep -qiP '(--hosted|hosted.*DAST|DAST.*scan|Docker Compose.*scan)'; then
  PASS=$((PASS + 1))
  echo "  PASS: documents --hosted DAST scanning"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: CHANGELOG should document --hosted DAST scanning"
fi

# =====================================================================
# 5. First public release note
# =====================================================================

echo ""
echo "--- Section 5: First public release context ---"
echo ""

echo "Test 25: CHANGELOG notes first public release"
TOTAL=$((TOTAL + 1))
if echo "$changelog_content" | grep -qiP '(first.*public.*release|initial.*public.*release|first.*release|public.*release|previously.*private|private.*development)'; then
  PASS=$((PASS + 1))
  echo "  PASS: notes first public release"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: CHANGELOG should note this is the first public release"
fi

# =====================================================================
# 6. README links to CHANGELOG
# =====================================================================

echo ""
echo "--- Section 6: README links to CHANGELOG ---"
echo ""

echo "Test 26: README contains a link to CHANGELOG.md"
TOTAL=$((TOTAL + 1))
if echo "$readme_content" | grep -qP 'CHANGELOG'; then
  PASS=$((PASS + 1))
  echo "  PASS: README references CHANGELOG"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: README should contain a link or reference to CHANGELOG.md"
fi

echo ""
echo "Test 27: README contains a Markdown link to CHANGELOG.md"
TOTAL=$((TOTAL + 1))
if echo "$readme_content" | grep -qP '\]\(CHANGELOG\.md\)'; then
  PASS=$((PASS + 1))
  echo "  PASS: README has Markdown link to CHANGELOG.md"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: README should have a Markdown link to CHANGELOG.md (e.g. [Changelog](CHANGELOG.md))"
fi

# =====================================================================
# 7. No draft markers or placeholders in CHANGELOG
# =====================================================================

echo ""
echo "--- Section 7: CHANGELOG quality ---"
echo ""

echo "Test 28: CHANGELOG contains no TODO markers"
assert_not_contains "no TODO in CHANGELOG" "TODO" "$changelog_content"

echo ""
echo "Test 29: CHANGELOG contains no FIXME markers"
assert_not_contains "no FIXME in CHANGELOG" "FIXME" "$changelog_content"

echo ""
echo "Test 30: CHANGELOG contains no placeholder text"
assert_not_contains "no [INSERT placeholder in CHANGELOG" "[INSERT" "$changelog_content"

echo ""
echo "Test 31: CHANGELOG contains no YYYY-MM-DD placeholder"
assert_not_contains "no YYYY-MM-DD placeholder" "YYYY-MM-DD" "$changelog_content"

# =====================================================================
# 8. Cross-referencing mode names against the CLI source
# =====================================================================

echo ""
echo "--- Section 8: Mode names match CLI definition ---"
echo ""

echo "Test 32: All 8 CLI modes appear in CHANGELOG mode listing"
TOTAL=$((TOTAL + 1))
cli_modes="audit feature bugfix discover deploy custom opensource content"
missing_modes=""
for mode in $cli_modes; do
  if ! echo "$changelog_content" | grep -qP "\b${mode}\b"; then
    missing_modes="$missing_modes $mode"
  fi
done
if [[ -z "$missing_modes" ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: all 8 CLI modes found in CHANGELOG"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: CHANGELOG missing CLI modes:$missing_modes"
fi

# =====================================================================
# 9. Coverage tests — additional structural checks
# =====================================================================

echo ""
echo "--- Section 9: Additional structural coverage ---"
echo ""

echo "Test 33: CHANGELOG has standard title heading"
assert_matches "CHANGELOG title is '# Changelog'" '^# Changelog' "$changelog_content"

echo ""
echo "Test 34: README has ## Changelog section heading"
assert_matches "README has ## Changelog section heading" '^## Changelog' "$readme_content"

echo ""
echo "Test 35: README Changelog section appears before Contributing"
TOTAL=$((TOTAL + 1))
changelog_pos=$(echo "$readme_content" | grep -n '## Changelog' | head -1 | cut -d: -f1)
contributing_pos=$(echo "$readme_content" | grep -n '## Contributing' | head -1 | cut -d: -f1)
if [[ -n "$changelog_pos" && -n "$contributing_pos" && "$changelog_pos" -lt "$contributing_pos" ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: Changelog section (line $changelog_pos) appears before Contributing (line $contributing_pos)"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: Changelog section should appear before Contributing in README"
fi

echo ""
echo "Test 36: Mode listing count word matches actual mode count"
TOTAL=$((TOTAL + 1))
mode_line=$(echo "$changelog_content" | grep -i 'operational modes')
if echo "$mode_line" | grep -qiP '\beight\b'; then
  mode_count=$(echo "$mode_line" | grep -oP '\b(audit|feature|bugfix|discover|deploy|custom|opensource|content)\b' | wc -l)
  if [[ "$mode_count" -eq 8 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: mode count word 'Eight' matches 8 modes found on the line"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: count word says 'Eight' but found $mode_count modes on the line"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: mode listing line should include count word 'Eight'"
fi

echo ""
echo "Test 37: CHANGELOG v0.1.0 has Infrastructure section"
assert_matches "v0.1.0 has Infrastructure section" '### Infrastructure' "$changelog_content"

# --- Summary ---
echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
