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

# Tests for issue #27: Add community section to README linking to contribution resources
#
# Behavioral contract:
# 1. README.md must have a ## Contributing section with links to CONTRIBUTING.md and CODE_OF_CONDUCT.md
# 2. README.md must have a ## Security section linking to SECURITY.md
# 3. README.md must have a ## Authors section linking to AUTHORS.md
# 4. All linked community files must exist and be non-empty
# 5. Community sections must appear before ## Legal in correct order
# 6. All community links use proper markdown link syntax [text](file.md)
# 7. No duplicate community section headings
# 8. The ## Adding a Lens section should cross-reference CONTRIBUTING.md
# 9. ## Support and ## Contributing are distinct sections
# 10. Community sections have non-empty content bodies
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
README="$SCRIPT_DIR/README.md"
CONTRIBUTING="$SCRIPT_DIR/CONTRIBUTING.md"
COC="$SCRIPT_DIR/CODE_OF_CONDUCT.md"
SECURITY="$SCRIPT_DIR/SECURITY.md"
AUTHORS="$SCRIPT_DIR/AUTHORS.md"

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
echo "=== Test Suite: Community Section in README (issue #27) ==="
echo ""

readme_content=""
if [[ -f "$README" ]]; then
  readme_content="$(cat "$README")"
fi

# =====================================================================
# 1. README must exist
# =====================================================================

echo "--- Section 1: README existence ---"
echo ""

echo "Test 1: README.md exists at repo root"
assert_file_exists "README.md exists" "$README"

echo ""
echo "Test 2: README.md is not empty"
assert_file_not_empty "README.md is not empty" "$README"

# =====================================================================
# 2. ## Contributing section exists with correct links
# =====================================================================

echo ""
echo "--- Section 2: Contributing section ---"
echo ""

echo "Test 3: README has ## Contributing heading"
assert_matches "## Contributing heading exists" '^## Contributing' "$readme_content"

echo ""
echo "Test 4: Contributing section links to CONTRIBUTING.md"
assert_matches "link to CONTRIBUTING.md" '\]\(CONTRIBUTING\.md\)' "$readme_content"

echo ""
echo "Test 5: Contributing section links to CODE_OF_CONDUCT.md"
assert_matches "link to CODE_OF_CONDUCT.md" '\]\(CODE_OF_CONDUCT\.md\)' "$readme_content"

echo ""
echo "Test 6: Contributing section mentions how to contribute"
assert_matches "contributing guidance text" '(?i)(report bugs|suggest features|submit code|contribute|contribution)' "$readme_content"

echo ""
echo "Test 7: Contributing section mentions Code of Conduct by name"
assert_matches "Code of Conduct reference" '(?i)Code of Conduct' "$readme_content"

# =====================================================================
# 3. ## Security section exists with correct link
# =====================================================================

echo ""
echo "--- Section 3: Security section ---"
echo ""

echo "Test 8: README has ## Security heading"
assert_contains "## Security heading exists" "## Security" "$readme_content"

echo ""
echo "Test 9: Security section links to SECURITY.md"
assert_matches "link to SECURITY.md" '\]\(SECURITY\.md\)' "$readme_content"

echo ""
echo "Test 10: Security section mentions vulnerability reporting"
assert_matches "vulnerability reporting guidance" '(?i)(report.*vulnerabilit|vulnerabilit.*report)' "$readme_content"

echo ""
echo "Test 11: Security section warns against public issues"
assert_matches "public issue warning" '(?i)(do not|don.t|never).*open.*public.*issue' "$readme_content"

# =====================================================================
# 4. ## Authors section exists (bonus — exceeds original request)
# =====================================================================

echo ""
echo "--- Section 4: Authors section ---"
echo ""

echo "Test 12: README has ## Authors heading"
assert_contains "## Authors heading exists" "## Authors" "$readme_content"

echo ""
echo "Test 13: Authors section links to AUTHORS.md"
assert_matches "link to AUTHORS.md" '\]\(AUTHORS\.md\)' "$readme_content"

# =====================================================================
# 5. Linked community files exist and are non-empty
# =====================================================================

echo ""
echo "--- Section 5: Community files exist ---"
echo ""

echo "Test 14: CONTRIBUTING.md exists"
assert_file_exists "CONTRIBUTING.md exists" "$CONTRIBUTING"

echo ""
echo "Test 15: CONTRIBUTING.md is not empty"
assert_file_not_empty "CONTRIBUTING.md is not empty" "$CONTRIBUTING"

echo ""
echo "Test 16: CODE_OF_CONDUCT.md exists"
assert_file_exists "CODE_OF_CONDUCT.md exists" "$COC"

echo ""
echo "Test 17: CODE_OF_CONDUCT.md is not empty"
assert_file_not_empty "CODE_OF_CONDUCT.md is not empty" "$COC"

echo ""
echo "Test 18: SECURITY.md exists"
assert_file_exists "SECURITY.md exists" "$SECURITY"

echo ""
echo "Test 19: SECURITY.md is not empty"
assert_file_not_empty "SECURITY.md is not empty" "$SECURITY"

echo ""
echo "Test 20: AUTHORS.md exists"
assert_file_exists "AUTHORS.md exists" "$AUTHORS"

echo ""
echo "Test 21: AUTHORS.md is not empty"
assert_file_not_empty "AUTHORS.md is not empty" "$AUTHORS"

# =====================================================================
# 6. Section ordering — community sections before ## Legal
# =====================================================================

echo ""
echo "--- Section 6: Section ordering ---"
echo ""

echo "Test 22: ## Contributing appears before ## Legal"
TOTAL=$((TOTAL + 1))
if [[ -f "$README" ]]; then
  contributing_line="$(grep -n '## Contributing' "$README" | head -1 | cut -d: -f1)"
  legal_line="$(grep -n '## Legal' "$README" | head -1 | cut -d: -f1)"
  if [[ -n "$contributing_line" && -n "$legal_line" && "$contributing_line" -lt "$legal_line" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: ## Contributing (line $contributing_line) before ## Legal (line $legal_line)"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: ## Contributing must appear before ## Legal"
    echo "    Contributing: line ${contributing_line:-missing}, Legal: line ${legal_line:-missing}"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: README.md not found"
fi

echo ""
echo "Test 23: ## Security appears before ## Legal"
TOTAL=$((TOTAL + 1))
if [[ -f "$README" ]]; then
  security_line="$(grep -n '## Security' "$README" | head -1 | cut -d: -f1)"
  legal_line="$(grep -n '## Legal' "$README" | head -1 | cut -d: -f1)"
  if [[ -n "$security_line" && -n "$legal_line" && "$security_line" -lt "$legal_line" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: ## Security (line $security_line) before ## Legal (line $legal_line)"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: ## Security must appear before ## Legal"
    echo "    Security: line ${security_line:-missing}, Legal: line ${legal_line:-missing}"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: README.md not found"
fi

echo ""
echo "Test 24: ## Authors appears before ## Legal"
TOTAL=$((TOTAL + 1))
if [[ -f "$README" ]]; then
  authors_line="$(grep -n '## Authors' "$README" | head -1 | cut -d: -f1)"
  legal_line="$(grep -n '## Legal' "$README" | head -1 | cut -d: -f1)"
  if [[ -n "$authors_line" && -n "$legal_line" && "$authors_line" -lt "$legal_line" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: ## Authors (line $authors_line) before ## Legal (line $legal_line)"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: ## Authors must appear before ## Legal"
    echo "    Authors: line ${authors_line:-missing}, Legal: line ${legal_line:-missing}"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: README.md not found"
fi

echo ""
echo "Test 25: Community sections appear in correct order (Contributing → Authors → Security)"
TOTAL=$((TOTAL + 1))
if [[ -f "$README" ]]; then
  contributing_line="$(grep -n '## Contributing' "$README" | head -1 | cut -d: -f1)"
  authors_line="$(grep -n '## Authors' "$README" | head -1 | cut -d: -f1)"
  security_line="$(grep -n '## Security' "$README" | head -1 | cut -d: -f1)"
  if [[ -n "$contributing_line" && -n "$authors_line" && -n "$security_line" && \
        "$contributing_line" -lt "$authors_line" && "$authors_line" -lt "$security_line" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: sections in correct order (Contributing=$contributing_line, Authors=$authors_line, Security=$security_line)"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: expected order Contributing → Authors → Security"
    echo "    Contributing: ${contributing_line:-missing}, Authors: ${authors_line:-missing}, Security: ${security_line:-missing}"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: README.md not found"
fi

# =====================================================================
# 7. Links use correct markdown syntax (not bare URLs)
# =====================================================================

echo ""
echo "--- Section 7: Link format ---"
echo ""

echo "Test 26: CONTRIBUTING.md link uses proper markdown link syntax"
assert_matches "CONTRIBUTING.md proper markdown link" '\[.*\]\(CONTRIBUTING\.md\)' "$readme_content"

echo ""
echo "Test 27: CODE_OF_CONDUCT.md link uses proper markdown link syntax"
assert_matches "CODE_OF_CONDUCT.md proper markdown link" '\[.*\]\(CODE_OF_CONDUCT\.md\)' "$readme_content"

echo ""
echo "Test 28: SECURITY.md link uses proper markdown link syntax"
assert_matches "SECURITY.md proper markdown link" '\[.*\]\(SECURITY\.md\)' "$readme_content"

echo ""
echo "Test 29: AUTHORS.md link uses proper markdown link syntax"
assert_matches "AUTHORS.md proper markdown link" '\[.*\]\(AUTHORS\.md\)' "$readme_content"

# =====================================================================
# 8. No duplicate community sections
# =====================================================================

echo ""
echo "--- Section 8: No duplicate sections ---"
echo ""

echo "Test 30: Only one ## Contributing section"
TOTAL=$((TOTAL + 1))
if [[ -f "$README" ]]; then
  count="$(grep -c '^## Contributing' "$README" || true)"
  if [[ "$count" -eq 1 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: exactly one ## Contributing section"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: expected exactly 1 ## Contributing section, found $count"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: README.md not found"
fi

echo ""
echo "Test 31: Only one ## Security section"
TOTAL=$((TOTAL + 1))
if [[ -f "$README" ]]; then
  count="$(grep -c '^## Security' "$README" || true)"
  if [[ "$count" -eq 1 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: exactly one ## Security section"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: expected exactly 1 ## Security section, found $count"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: README.md not found"
fi

echo ""
echo "Test 32: Only one ## Authors section"
TOTAL=$((TOTAL + 1))
if [[ -f "$README" ]]; then
  count="$(grep -c '^## Authors' "$README" || true)"
  if [[ "$count" -eq 1 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: exactly one ## Authors section"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: expected exactly 1 ## Authors section, found $count"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: README.md not found"
fi

# =====================================================================
# 9. ## Adding a Lens cross-references CONTRIBUTING.md (minor gap)
# =====================================================================

echo ""
echo "--- Section 9: Adding a Lens cross-reference ---"
echo ""

echo "Test 33: ## Adding a Lens section exists"
assert_contains "## Adding a Lens heading exists" "## Adding a Lens" "$readme_content"

echo ""
echo "Test 34: Adding a Lens section cross-references CONTRIBUTING.md"
TOTAL=$((TOTAL + 1))
adding_section_content=""
if [[ -f "$README" ]]; then
  adding_start="$(grep -n '## Adding a Lens' "$README" | head -1 | cut -d: -f1)"
  next_section="$(awk -v start="$adding_start" 'NR > start && /^## / { print NR; exit }' "$README")"
  if [[ -n "$adding_start" && -n "$next_section" ]]; then
    adding_section_content="$(sed -n "${adding_start},${next_section}p" "$README")"
    if echo "$adding_section_content" | grep -qP 'CONTRIBUTING\.md'; then
      PASS=$((PASS + 1))
      echo "  PASS: Adding a Lens section references CONTRIBUTING.md"
    else
      FAIL=$((FAIL + 1))
      echo "  FAIL: Adding a Lens section should cross-reference CONTRIBUTING.md for full contribution workflow"
    fi
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: could not parse Adding a Lens section boundaries"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: README.md not found"
fi

echo ""
echo "Test 35: Adding a Lens cross-reference is a proper markdown link (not bare text)"
TOTAL=$((TOTAL + 1))
if [[ -n "$adding_section_content" ]]; then
  if echo "$adding_section_content" | grep -qP '\[.*\]\(CONTRIBUTING\.md\)'; then
    PASS=$((PASS + 1))
    echo "  PASS: cross-reference uses proper markdown link syntax"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: CONTRIBUTING.md reference in Adding a Lens must be a markdown link [text](CONTRIBUTING.md)"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: could not extract Adding a Lens section content"
fi

# =====================================================================
# 10. ## Support section is distinct from ## Contributing
# =====================================================================

echo ""
echo "--- Section 10: Support vs Contributing distinction ---"
echo ""

echo "Test 36: ## Support section still exists (financial sponsorship)"
assert_contains "## Support heading exists" "## Support" "$readme_content"

echo ""
echo "Test 37: ## Support is separate from ## Contributing (different line numbers)"
TOTAL=$((TOTAL + 1))
if [[ -f "$README" ]]; then
  support_line="$(grep -n '## Support' "$README" | head -1 | cut -d: -f1)"
  contributing_line="$(grep -n '## Contributing' "$README" | head -1 | cut -d: -f1)"
  if [[ -n "$support_line" && -n "$contributing_line" && "$support_line" -ne "$contributing_line" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: ## Support (line $support_line) and ## Contributing (line $contributing_line) are distinct sections"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: ## Support and ## Contributing must be separate sections"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: README.md not found"
fi

# =====================================================================
# 11. Community sections have non-empty content bodies
# =====================================================================

echo ""
echo "--- Section 11: Non-empty section bodies ---"
echo ""

echo "Test 38: Contributing, Authors, and Security sections each have content between heading and next heading"
TOTAL=$((TOTAL + 1))
empty_sections=()
if [[ -f "$README" ]]; then
  for section_name in "Contributing" "Authors" "Security"; do
    section_start="$(grep -n "^## ${section_name}" "$README" | head -1 | cut -d: -f1)"
    if [[ -z "$section_start" ]]; then
      empty_sections+=("$section_name (heading missing)")
      continue
    fi
    next_heading="$(awk -v start="$section_start" 'NR > start && /^## / { print NR; exit }' "$README")"
    if [[ -z "$next_heading" ]]; then
      next_heading="$(wc -l < "$README")"
    fi
    body_start=$((section_start + 1))
    body_end=$((next_heading - 1))
    if [[ "$body_start" -le "$body_end" ]]; then
      non_empty_lines="$(sed -n "${body_start},${body_end}p" "$README" | grep -c '[^ ]' || true)"
      if [[ "$non_empty_lines" -eq 0 ]]; then
        empty_sections+=("$section_name")
      fi
    else
      empty_sections+=("$section_name")
    fi
  done
  if [[ ${#empty_sections[@]} -eq 0 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: all community sections have non-empty content"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: the following sections have no content: ${empty_sections[*]}"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: README.md not found"
fi

# --- Summary ---
echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
