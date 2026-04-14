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

# Tests for issue #21: RepoLens repo launch polish
#
# Validates repo-level polish for v0.1.0 public launch:
# 1. Lens request issue template exists with correct structure
# 2. Pull request template exists with DCO and domain ownership checklist
# 3. README has version, stars, and license badges
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
echo "=== Test Suite: Repo Launch Polish (issue #21) ==="
echo ""

# =====================================================================
# 1. Lens Request issue template
# =====================================================================

echo "--- Section 1: Lens Request issue template ---"
echo ""

LENS_TEMPLATE="$SCRIPT_DIR/.github/ISSUE_TEMPLATE/lens_request.md"

echo "Test 1: Lens request template exists"
assert_file_exists "lens_request.md exists at .github/ISSUE_TEMPLATE/" "$LENS_TEMPLATE"

echo ""
echo "Test 2: Lens request template is not empty"
assert_file_not_empty "lens_request.md has content" "$LENS_TEMPLATE"

lens_content=""
if [[ -f "$LENS_TEMPLATE" ]]; then
  lens_content="$(cat "$LENS_TEMPLATE")"
fi

echo ""
echo "Test 3: Lens request template starts with YAML frontmatter"
TOTAL=$((TOTAL + 1))
if [[ -f "$LENS_TEMPLATE" ]] && head -n1 "$LENS_TEMPLATE" | grep -q '^---$'; then
  PASS=$((PASS + 1))
  echo "  PASS: lens request template starts with ---"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: lens request template does not start with YAML frontmatter (---)"
fi

echo ""
echo "Test 4: Lens request template has 'name:' in frontmatter"
assert_matches "frontmatter has name:" "^name:" "$lens_content"

echo ""
echo "Test 5: Lens request template has 'about:' in frontmatter"
assert_matches "frontmatter has about:" "^about:" "$lens_content"

echo ""
echo "Test 6: Lens request template has 'labels:' including lens-request"
assert_matches "frontmatter has labels with lens-request" "^labels:.*lens-request" "$lens_content"

echo ""
echo "Test 7: Lens request template has closing frontmatter delimiter"
TOTAL=$((TOTAL + 1))
if [[ -f "$LENS_TEMPLATE" ]]; then
  # Count '---' lines — must have at least 2 (opening and closing)
  delimiter_count="$(grep -c '^---$' "$LENS_TEMPLATE")"
  if [[ "$delimiter_count" -ge 2 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: lens request template has closing frontmatter delimiter"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: lens request template missing closing frontmatter delimiter"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: lens request template not found"
fi

echo ""
echo "Test 8: Lens request template has section for lens idea/description"
assert_matches "has lens idea section" "(?i)## .*(lens.*idea|lens.*description|what.*lens|what.*detect|what.*analy)" "$lens_content"

echo ""
echo "Test 9: Lens request template has section for domain"
assert_matches "has domain section" "(?i)## .*(domain|categor)" "$lens_content"

echo ""
echo "Test 10: Lens request template has section for expert focus"
assert_matches "has expert focus section" "(?i)## .*(expert.*focus|expertise|focus)" "$lens_content"

echo ""
echo "Test 11: Lens request template has section for example findings"
assert_matches "has example findings section" "(?i)## .*(example.*finding|example.*issue|sample.*finding)" "$lens_content"

echo ""
echo "Test 12: Lens request template references domains.json or domain list"
assert_matches "references domain list" "(?i)(domains\.json|domain)" "$lens_content"

# =====================================================================
# 2. Pull Request template
# =====================================================================

echo ""
echo "--- Section 2: Pull Request template ---"
echo ""

PR_TEMPLATE="$SCRIPT_DIR/.github/PULL_REQUEST_TEMPLATE.md"

echo "Test 13: Pull request template exists"
assert_file_exists "PULL_REQUEST_TEMPLATE.md exists at .github/" "$PR_TEMPLATE"

echo ""
echo "Test 14: Pull request template is not empty"
assert_file_not_empty "PULL_REQUEST_TEMPLATE.md has content" "$PR_TEMPLATE"

pr_content=""
if [[ -f "$PR_TEMPLATE" ]]; then
  pr_content="$(cat "$PR_TEMPLATE")"
fi

echo ""
echo "Test 15: PR template has summary section"
assert_matches "has summary section" "(?i)## .*summar" "$pr_content"

echo ""
echo "Test 16: PR template has type-of-change section"
assert_matches "has type of change section" "(?i)## .*(type.*change|change.*type)" "$pr_content"

echo ""
echo "Test 17: PR template has lens checkbox option"
assert_matches "has lens type option" "(?i)\[[ ]\].*[Ll]ens" "$pr_content"

echo ""
echo "Test 18: PR template has bug fix checkbox option"
assert_matches "has bug fix type option" "(?i)\[[ ]\].*[Bb]ug" "$pr_content"

echo ""
echo "Test 19: PR template has DCO sign-off reminder"
assert_matches "has DCO sign-off" "(?i)(DCO|sign.off|Developer Certificate|git commit -s)" "$pr_content"

echo ""
echo "Test 20: PR template has lens-specific checklist"
assert_matches "has lens checklist" "(?i)(lens.*checklist|adding.*lens|modif.*lens)" "$pr_content"

echo ""
echo "Test 21: PR template mentions frontmatter fields for lens contributions"
assert_matches "mentions lens frontmatter" "(?i)(frontmatter|id.*domain.*name.*role)" "$pr_content"

echo ""
echo "Test 22: PR template mentions domains.json for lens contributions"
assert_contains "mentions domains.json" "domains.json" "$pr_content"

echo ""
echo "Test 23: PR template has testing section"
assert_matches "has testing section" "(?i)## .*(test|verif)" "$pr_content"

echo ""
echo "Test 24: PR template mentions make check"
assert_contains "mentions make check" "make check" "$pr_content"

# =====================================================================
# 3. README badges
# =====================================================================

echo ""
echo "--- Section 3: README badges ---"
echo ""

readme_content=""
if [[ -f "$SCRIPT_DIR/README.md" ]]; then
  readme_content="$(cat "$SCRIPT_DIR/README.md")"
fi

echo "Test 25: License badge still present (no regression)"
assert_matches "license badge present" "\[!\[.*License.*Apache.*2\.0.*\]\(https://img\.shields\.io" "$readme_content"

echo ""
echo "Test 26: Version badge present"
TOTAL=$((TOTAL + 1))
if echo "$readme_content" | grep -qP '\[!\[.*(version|Version|v0\.1\.0|Release|release).*\]\(https://img\.shields\.io'; then
  PASS=$((PASS + 1))
  echo "  PASS: version badge present (shields.io)"
elif echo "$readme_content" | grep -qP '\[!\[.*GitHub Release.*\]\(https://img\.shields\.io/github/v/release'; then
  PASS=$((PASS + 1))
  echo "  PASS: version badge present (GitHub release)"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: version badge not found"
  echo "    Expected shields.io version or release badge"
fi

echo ""
echo "Test 27: Stars badge present"
assert_matches "stars badge present" "\[!\[.*[Ss]tars.*\]\(https://img\.shields\.io/github/stars" "$readme_content"

echo ""
echo "Test 28: Badge block has at least 3 badges (license + version + stars)"
TOTAL=$((TOTAL + 1))
badge_count="$(echo "$readme_content" | grep -cP '\[!\[.*\]\(https://img\.shields\.io')"
if [[ "$badge_count" -ge 3 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: found $badge_count shield badges (>= 3)"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: found only $badge_count shield badge(s), expected at least 3"
fi

echo ""
echo "Test 29: Stars badge links to RepoLens repo"
assert_matches "stars badge links to repo" "stars/TheMorpheus407/RepoLens" "$readme_content"

echo ""
echo "Test 30: Version badge links to CHANGELOG or releases"
TOTAL=$((TOTAL + 1))
# The badge image line ([![...](shields-url)](link-target)) must link to CHANGELOG or releases
if echo "$readme_content" | grep -P 'img\.shields\.io.*version|img\.shields\.io.*release|img\.shields\.io.*v0' | grep -qP '\]\(CHANGELOG\.md\)|\]\(.*releases\)'; then
  PASS=$((PASS + 1))
  echo "  PASS: version badge links to CHANGELOG or releases"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: version badge does not link to CHANGELOG.md or releases page"
fi

# =====================================================================
# 4. All three issue templates work together
# =====================================================================

echo ""
echo "--- Section 4: Issue template consistency ---"
echo ""

echo "Test 31: Bug report template still exists (no regression)"
assert_file_exists "bug_report.md still exists" "$SCRIPT_DIR/.github/ISSUE_TEMPLATE/bug_report.md"

echo ""
echo "Test 32: Feature request template still exists (no regression)"
assert_file_exists "feature_request.md still exists" "$SCRIPT_DIR/.github/ISSUE_TEMPLATE/feature_request.md"

echo ""
echo "Test 33: All three issue templates have distinct names"
TOTAL=$((TOTAL + 1))
if [[ -f "$SCRIPT_DIR/.github/ISSUE_TEMPLATE/bug_report.md" ]] && \
   [[ -f "$SCRIPT_DIR/.github/ISSUE_TEMPLATE/feature_request.md" ]] && \
   [[ -f "$LENS_TEMPLATE" ]]; then
  bug_name="$(grep '^name:' "$SCRIPT_DIR/.github/ISSUE_TEMPLATE/bug_report.md" | head -1)"
  feature_name="$(grep '^name:' "$SCRIPT_DIR/.github/ISSUE_TEMPLATE/feature_request.md" | head -1)"
  lens_name="$(grep '^name:' "$LENS_TEMPLATE" | head -1)"
  if [[ "$bug_name" != "$feature_name" ]] && \
     [[ "$bug_name" != "$lens_name" ]] && \
     [[ "$feature_name" != "$lens_name" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: all three templates have distinct names"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: template names are not all distinct"
    echo "    Bug: $bug_name | Feature: $feature_name | Lens: $lens_name"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: not all three templates exist"
fi

echo ""
echo "Test 34: Lens request template 'about:' mentions lens"
TOTAL=$((TOTAL + 1))
if [[ -f "$LENS_TEMPLATE" ]]; then
  about_line="$(grep '^about:' "$LENS_TEMPLATE" | head -1)"
  if echo "$about_line" | grep -qiP 'lens'; then
    PASS=$((PASS + 1))
    echo "  PASS: lens request about: mentions lens"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: lens request about: does not mention lens"
    echo "    Found: $about_line"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: lens request template not found"
fi

# =====================================================================
# 5. PR template depth — content quality
# =====================================================================

echo ""
echo "--- Section 5: PR template content quality ---"
echo ""

echo "Test 35: PR template has at least 15 lines (substantive, not a stub)"
TOTAL=$((TOTAL + 1))
if [[ -f "$PR_TEMPLATE" ]]; then
  pr_lines="$(wc -l < "$PR_TEMPLATE")"
  if [[ "$pr_lines" -ge 15 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: PR template has $pr_lines lines (>= 15)"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: PR template has only $pr_lines lines (expected >= 15)"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: PR template not found"
fi

echo ""
echo "Test 36: PR template has at least 3 checkbox items"
TOTAL=$((TOTAL + 1))
if [[ -f "$PR_TEMPLATE" ]]; then
  checkbox_count="$(grep -cP '^\s*-\s*\[[ ]\]' "$PR_TEMPLATE")"
  if [[ "$checkbox_count" -ge 3 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: PR template has $checkbox_count checkboxes (>= 3)"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: PR template has only $checkbox_count checkbox(es), expected at least 3"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: PR template not found"
fi

echo ""
echo "Test 37: PR template mentions kebab-case for lens IDs"
assert_matches "mentions kebab-case" "(?i)kebab" "$pr_content"

echo ""
echo "Test 38: PR template has no TODO or placeholder markers"
assert_not_contains "no TODO markers" "TODO" "$pr_content"

echo ""
echo "Test 39: Lens request template has no TODO or placeholder markers"
assert_not_contains "no TODO markers in lens template" "TODO" "$lens_content"

# =====================================================================
# 6. Coverage: additional gap tests
# =====================================================================

echo ""
echo "--- Section 6: Additional coverage tests ---"
echo ""

echo "Test 40: Lens request template has 'title:' in frontmatter with [Lens] prefix"
assert_matches "frontmatter has title with [Lens] prefix" '(?i)^title:.*\[Lens\]' "$lens_content"

echo ""
echo "Test 41: Lens request template has Prior Art section"
assert_matches "has prior art section" "(?i)## .*[Pp]rior [Aa]rt" "$lens_content"

echo ""
echo "Test 42: PR template has feature/enhancement checkbox option"
assert_matches "has feature type option" "(?i)\[[ ]\].*[Ff]eature" "$pr_content"

echo ""
echo "Test 43: PR template has documentation checkbox option"
assert_matches "has documentation type option" "(?i)\[[ ]\].*[Dd]ocumentation" "$pr_content"

echo ""
echo "Test 44: PR template DCO section mentions 'git commit -s' command"
assert_contains "DCO section has git commit -s" "git commit -s" "$pr_content"

echo ""
echo "Test 45: PR template DCO links to Developer Certificate of Origin"
assert_contains "DCO links to developercertificate.org" "developercertificate.org" "$pr_content"

echo ""
echo "Test 46: README badges appear in first 10 lines"
TOTAL=$((TOTAL + 1))
if [[ -f "$SCRIPT_DIR/README.md" ]]; then
  badge_in_header="$(head -10 "$SCRIPT_DIR/README.md" | grep -cP '\[!\[.*\]\(https://img\.shields\.io')"
  if [[ "$badge_in_header" -ge 3 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $badge_in_header badges found in first 10 lines"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: only $badge_in_header badge(s) in first 10 lines, expected at least 3"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: README.md not found"
fi

echo ""
echo "Test 47: Lens request template has at least 5 H2 sections"
TOTAL=$((TOTAL + 1))
if [[ -f "$LENS_TEMPLATE" ]]; then
  h2_count="$(grep -cP '^## ' "$LENS_TEMPLATE")"
  if [[ "$h2_count" -ge 5 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: lens template has $h2_count H2 sections (>= 5)"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: lens template has only $h2_count H2 section(s), expected at least 5"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: lens template not found"
fi

# --- Summary ---
echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
