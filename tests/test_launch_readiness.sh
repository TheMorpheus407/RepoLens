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

# Tests for issue #15: Launch day — flip RepoLens repo from private to public
#
# These tests define the behavioral contract for launch readiness:
# A cold user clicking the video description link reaches a fully rendered
# public RepoLens repo with README, LICENSE, and issue tracker visible.
#
# Checklist items tested:
# 1. Pre-launch files present (LICENSE, README, .gitignore, NOTICE)
# 2. README quality for public audience (substantive, quickstart, legal section)
# 3. No secrets in tracked files
# 4. v0.1.0 tag exists
# 5. Community health files present (CONTRIBUTING, CODE_OF_CONDUCT, SECURITY, CHANGELOG)
# 6. .github directory with social preview / community files
# 7. Repo metadata (description, homepage) — via gh CLI if available
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

assert_dir_exists() {
  local desc="$1" dirpath="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -d "$dirpath" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    Directory not found: $dirpath"
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
echo "=== Test Suite: Launch Readiness (issue #15) ==="
echo ""

# =====================================================================
# 1. Core files must exist for public launch
# =====================================================================

echo "--- Section 1: Core file presence ---"
echo ""

echo "Test 1: LICENSE file exists"
assert_file_exists "LICENSE file exists at repo root" "$SCRIPT_DIR/LICENSE"

echo ""
echo "Test 2: README.md exists"
assert_file_exists "README.md exists at repo root" "$SCRIPT_DIR/README.md"

echo ""
echo "Test 3: .gitignore exists"
assert_file_exists ".gitignore exists at repo root" "$SCRIPT_DIR/.gitignore"

echo ""
echo "Test 4: NOTICE file exists"
assert_file_exists "NOTICE file exists at repo root" "$SCRIPT_DIR/NOTICE"

# =====================================================================
# 2. README quality — must be substantive for a public audience
# =====================================================================

echo ""
echo "--- Section 2: README quality for public audience ---"
echo ""

readme_content=""
if [[ -f "$SCRIPT_DIR/README.md" ]]; then
  readme_content="$(cat "$SCRIPT_DIR/README.md")"
fi

echo "Test 5: README is substantive (at least 100 lines)"
if [[ -f "$SCRIPT_DIR/README.md" ]]; then
  readme_lines="$(wc -l < "$SCRIPT_DIR/README.md")"
  TOTAL=$((TOTAL + 1))
  if [[ "$readme_lines" -ge 100 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: README has $readme_lines lines (>= 100)"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: README has only $readme_lines lines (expected >= 100)"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: README.md not found"
fi

echo ""
echo "Test 6: README contains project name 'RepoLens'"
assert_contains "README contains project name" "RepoLens" "$readme_content"

echo ""
echo "Test 7: README contains quickstart or getting started section"
TOTAL=$((TOTAL + 1))
if echo "$readme_content" | grep -qiP '(quick\s*start|getting\s*started)'; then
  PASS=$((PASS + 1))
  echo "  PASS: README has quickstart/getting-started section"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: README missing quickstart or getting-started section"
fi

echo ""
echo "Test 8: README contains prerequisites section"
TOTAL=$((TOTAL + 1))
if echo "$readme_content" | grep -qiP 'prerequisites'; then
  PASS=$((PASS + 1))
  echo "  PASS: README has prerequisites section"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: README missing prerequisites section"
fi

echo ""
echo "Test 9: README contains legal or license section"
TOTAL=$((TOTAL + 1))
if echo "$readme_content" | grep -qiP '(## .*legal|## .*license|## .*licensing)'; then
  PASS=$((PASS + 1))
  echo "  PASS: README has legal/license section"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: README missing legal/license section heading"
fi

echo ""
echo "Test 10: README contains correct clone URL for public access"
assert_contains "README has correct clone URL" "TheMorpheus407/RepoLens" "$readme_content"

echo ""
echo "Test 11: README contains usage examples or CLI reference"
TOTAL=$((TOTAL + 1))
if echo "$readme_content" | grep -qiP '(usage|cli.*reference|command.*reference)'; then
  PASS=$((PASS + 1))
  echo "  PASS: README has usage/CLI reference section"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: README missing usage or CLI reference section"
fi

# =====================================================================
# 3. No secrets in tracked files
# =====================================================================

echo ""
echo "--- Section 3: No secrets in tracked files ---"
echo ""

echo "Test 12: No AWS access keys in tracked files"
TOTAL=$((TOTAL + 1))
secret_hits="$(git -C "$SCRIPT_DIR" grep -l 'AKIA[0-9A-Z]\{16\}' -- ':!prompts/' ':!tests/' ':!logs/' 2>/dev/null | wc -l)"
if [[ "$secret_hits" -eq 0 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: no AWS access keys found in tracked files"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: found potential AWS access keys in $secret_hits file(s)"
fi

echo ""
echo "Test 13: No private keys in tracked files"
TOTAL=$((TOTAL + 1))
pk_hits="$(git -C "$SCRIPT_DIR" grep -l '-----BEGIN.*PRIVATE KEY-----' -- ':!prompts/' ':!tests/' ':!logs/' 2>/dev/null | wc -l)"
if [[ "$pk_hits" -eq 0 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: no private keys found in tracked files"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: found potential private keys in $pk_hits file(s)"
fi

echo ""
echo "Test 14: No .env files are tracked"
TOTAL=$((TOTAL + 1))
env_tracked="$(git -C "$SCRIPT_DIR" ls-files '*.env' '.env*' 2>/dev/null | wc -l)"
if [[ "$env_tracked" -eq 0 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: no .env files are tracked"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: found $env_tracked .env file(s) tracked in git"
fi

echo ""
echo "Test 15: No hardcoded password assignments in source files"
TOTAL=$((TOTAL + 1))
pwd_hits="$(git -C "$SCRIPT_DIR" grep -l 'password\s*=\s*["\x27][^"\x27]\+["\x27]' -- '*.sh' '*.json' ':!prompts/' ':!tests/' ':!logs/' 2>/dev/null | wc -l)"
if [[ "$pwd_hits" -eq 0 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: no hardcoded password assignments found"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: found potential hardcoded passwords in $pwd_hits file(s)"
fi

# =====================================================================
# 4. .gitignore covers sensitive patterns
# =====================================================================

echo ""
echo "--- Section 4: .gitignore coverage ---"
echo ""

gitignore_content=""
if [[ -f "$SCRIPT_DIR/.gitignore" ]]; then
  gitignore_content="$(cat "$SCRIPT_DIR/.gitignore")"
fi

echo "Test 16: .gitignore is not empty"
assert_file_not_empty ".gitignore is not empty" "$SCRIPT_DIR/.gitignore"

echo ""
echo "Test 17: .gitignore covers log files"
TOTAL=$((TOTAL + 1))
if echo "$gitignore_content" | grep -qP '(logs/|\*\.log)'; then
  PASS=$((PASS + 1))
  echo "  PASS: .gitignore covers log files"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: .gitignore does not cover log files (logs/ or *.log)"
fi

# =====================================================================
# 5. v0.1.0 release tag must exist
# =====================================================================

echo ""
echo "--- Section 5: Release tag ---"
echo ""

echo "Test 18: v0.1.0 tag exists"
TOTAL=$((TOTAL + 1))
if git -C "$SCRIPT_DIR" tag -l 'v0.1.0' | grep -q 'v0.1.0'; then
  PASS=$((PASS + 1))
  echo "  PASS: v0.1.0 tag exists"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: v0.1.0 tag does not exist"
fi

echo ""
echo "Test 19: At least one git tag exists"
TOTAL=$((TOTAL + 1))
tag_count="$(git -C "$SCRIPT_DIR" tag -l | wc -l)"
if [[ "$tag_count" -ge 1 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: $tag_count git tag(s) exist"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: no git tags exist (expected at least v0.1.0)"
fi

# =====================================================================
# 6. Community health files must exist for public repo
# =====================================================================

echo ""
echo "--- Section 6: Community health files ---"
echo ""

echo "Test 20: CONTRIBUTING.md exists"
assert_file_exists "CONTRIBUTING.md exists" "$SCRIPT_DIR/CONTRIBUTING.md"

echo ""
echo "Test 21: CODE_OF_CONDUCT.md exists"
assert_file_exists "CODE_OF_CONDUCT.md exists" "$SCRIPT_DIR/CODE_OF_CONDUCT.md"

echo ""
echo "Test 22: SECURITY.md exists"
assert_file_exists "SECURITY.md exists" "$SCRIPT_DIR/SECURITY.md"

echo ""
echo "Test 23: CHANGELOG.md exists"
assert_file_exists "CHANGELOG.md exists" "$SCRIPT_DIR/CHANGELOG.md"

echo ""
echo "Test 24: CONTRIBUTING.md is not empty (if it exists)"
if [[ -f "$SCRIPT_DIR/CONTRIBUTING.md" ]]; then
  assert_file_not_empty "CONTRIBUTING.md has content" "$SCRIPT_DIR/CONTRIBUTING.md"
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: CONTRIBUTING.md does not exist"
fi

echo ""
echo "Test 25: CODE_OF_CONDUCT.md is not empty (if it exists)"
if [[ -f "$SCRIPT_DIR/CODE_OF_CONDUCT.md" ]]; then
  assert_file_not_empty "CODE_OF_CONDUCT.md has content" "$SCRIPT_DIR/CODE_OF_CONDUCT.md"
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: CODE_OF_CONDUCT.md does not exist"
fi

echo ""
echo "Test 26: SECURITY.md is not empty (if it exists)"
if [[ -f "$SCRIPT_DIR/SECURITY.md" ]]; then
  assert_file_not_empty "SECURITY.md has content" "$SCRIPT_DIR/SECURITY.md"
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: SECURITY.md does not exist"
fi

echo ""
echo "Test 27: CHANGELOG.md is not empty (if it exists)"
if [[ -f "$SCRIPT_DIR/CHANGELOG.md" ]]; then
  assert_file_not_empty "CHANGELOG.md has content" "$SCRIPT_DIR/CHANGELOG.md"
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: CHANGELOG.md does not exist"
fi

echo ""
echo "Test 28: CHANGELOG.md references v0.1.0 (if it exists)"
if [[ -f "$SCRIPT_DIR/CHANGELOG.md" ]]; then
  changelog_content="$(cat "$SCRIPT_DIR/CHANGELOG.md")"
  assert_contains "CHANGELOG references v0.1.0" "0.1.0" "$changelog_content"
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: CHANGELOG.md does not exist"
fi

# =====================================================================
# 7. .github directory and social presence
# =====================================================================

echo ""
echo "--- Section 7: GitHub community integration ---"
echo ""

echo "Test 29: .github directory exists"
assert_dir_exists ".github directory exists" "$SCRIPT_DIR/.github"

echo ""
echo "Test 30: Social preview image or issue templates present in .github"
TOTAL=$((TOTAL + 1))
if [[ -d "$SCRIPT_DIR/.github" ]]; then
  github_file_count="$(find "$SCRIPT_DIR/.github" -type f 2>/dev/null | wc -l)"
  if [[ "$github_file_count" -ge 1 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: .github directory has $github_file_count file(s)"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: .github directory exists but is empty"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: .github directory does not exist"
fi

# =====================================================================
# 8. Repo metadata via gh CLI (graceful skip if gh unavailable)
# =====================================================================

echo ""
echo "--- Section 8: Repository metadata (via gh CLI) ---"
echo ""

if command -v gh &>/dev/null; then
  repo_json="$(gh repo view --json description,homepageUrl 2>/dev/null || echo '{}')"

  echo "Test 31: Repo description is non-empty"
  TOTAL=$((TOTAL + 1))
  repo_desc="$(echo "$repo_json" | jq -r '.description // ""' 2>/dev/null)"
  if [[ -n "$repo_desc" && "$repo_desc" != "null" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: repo description is set: $repo_desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: repo description is empty"
  fi

  echo ""
  echo "Test 32: Repo homepage URL is set"
  TOTAL=$((TOTAL + 1))
  repo_homepage="$(echo "$repo_json" | jq -r '.homepageUrl // ""' 2>/dev/null)"
  if [[ -n "$repo_homepage" && "$repo_homepage" != "null" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: repo homepage URL is set: $repo_homepage"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: repo homepage URL is empty"
  fi
else
  echo "Test 31: SKIP — gh CLI not available, cannot check repo description"
  echo "Test 32: SKIP — gh CLI not available, cannot check repo homepage URL"
fi

# =====================================================================
# 9. README must not contain placeholder or draft markers
# =====================================================================

echo ""
echo "--- Section 9: README does not contain draft markers ---"
echo ""

echo "Test 33: README does not contain TODO markers"
assert_not_contains "no TODO markers in README" "TODO" "$readme_content"

echo ""
echo "Test 34: README does not contain FIXME markers"
assert_not_contains "no FIXME markers in README" "FIXME" "$readme_content"

echo ""
echo "Test 35: README does not contain placeholder text '[INSERT'..."
assert_not_contains "no [INSERT placeholder text" "[INSERT" "$readme_content"

echo ""
echo "Test 36: README does not contain 'coming soon' placeholder"
TOTAL=$((TOTAL + 1))
if echo "$readme_content" | grep -qiP 'coming soon'; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: README contains 'coming soon' placeholder text"
else
  PASS=$((PASS + 1))
  echo "  PASS: no 'coming soon' placeholder in README"
fi

# =====================================================================
# 10. Entry point is executable and has shebang
# =====================================================================

echo ""
echo "--- Section 10: Entry point readiness ---"
echo ""

echo "Test 37: repolens.sh exists"
assert_file_exists "repolens.sh exists" "$SCRIPT_DIR/repolens.sh"

echo ""
echo "Test 38: repolens.sh is executable"
TOTAL=$((TOTAL + 1))
if [[ -x "$SCRIPT_DIR/repolens.sh" ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: repolens.sh is executable"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: repolens.sh is not executable"
fi

echo ""
echo "Test 39: repolens.sh has a bash shebang"
TOTAL=$((TOTAL + 1))
if [[ -f "$SCRIPT_DIR/repolens.sh" ]]; then
  first_line="$(head -n1 "$SCRIPT_DIR/repolens.sh")"
  if [[ "$first_line" == "#!/"*"bash"* ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: repolens.sh has bash shebang"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: repolens.sh first line is '$first_line', expected bash shebang"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: repolens.sh not found"
fi

# =====================================================================
# 11. SECURITY.md content quality (if it exists)
# =====================================================================

echo ""
echo "--- Section 11: SECURITY.md content ---"
echo ""

echo "Test 40: SECURITY.md contains vulnerability reporting instructions"
if [[ -f "$SCRIPT_DIR/SECURITY.md" ]]; then
  security_content="$(cat "$SCRIPT_DIR/SECURITY.md")"
  TOTAL=$((TOTAL + 1))
  if echo "$security_content" | grep -qiP '(report|disclos|vulnerabilit)'; then
    PASS=$((PASS + 1))
    echo "  PASS: SECURITY.md contains vulnerability reporting guidance"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: SECURITY.md lacks vulnerability reporting instructions"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: SECURITY.md does not exist"
fi

# =====================================================================
# 12. CONTRIBUTING.md content quality (if it exists)
# =====================================================================

echo ""
echo "--- Section 12: CONTRIBUTING.md content ---"
echo ""

echo "Test 41: CONTRIBUTING.md explains how to contribute"
if [[ -f "$SCRIPT_DIR/CONTRIBUTING.md" ]]; then
  contributing_content="$(cat "$SCRIPT_DIR/CONTRIBUTING.md")"
  TOTAL=$((TOTAL + 1))
  if echo "$contributing_content" | grep -qiP '(pull request|issue|contribut|fork)'; then
    PASS=$((PASS + 1))
    echo "  PASS: CONTRIBUTING.md contains contribution guidance"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: CONTRIBUTING.md lacks contribution instructions"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: CONTRIBUTING.md does not exist"
fi

# =====================================================================
# 13. README references license correctly
# =====================================================================

echo ""
echo "--- Section 13: README license references ---"
echo ""

echo "Test 42: README mentions Apache-2.0 license"
assert_contains "README references Apache-2.0" "Apache-2.0" "$readme_content"

echo ""
echo "Test 43: README links to LICENSE file"
TOTAL=$((TOTAL + 1))
if echo "$readme_content" | grep -qP '\]\(LICENSE\)'; then
  PASS=$((PASS + 1))
  echo "  PASS: README contains link to LICENSE"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: README does not link to LICENSE file"
fi

# =====================================================================
# 14. CODE_OF_CONDUCT.md content quality (if it exists)
# =====================================================================

echo ""
echo "--- Section 14: CODE_OF_CONDUCT.md content ---"
echo ""

echo "Test 44: CODE_OF_CONDUCT.md describes standards of conduct"
if [[ -f "$SCRIPT_DIR/CODE_OF_CONDUCT.md" ]]; then
  coc_content="$(cat "$SCRIPT_DIR/CODE_OF_CONDUCT.md")"
  TOTAL=$((TOTAL + 1))
  if echo "$coc_content" | grep -qiP '(harassment|respectful|unacceptable|enforcement)'; then
    PASS=$((PASS + 1))
    echo "  PASS: CODE_OF_CONDUCT.md contains conduct standards"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: CODE_OF_CONDUCT.md lacks meaningful conduct standards"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: CODE_OF_CONDUCT.md does not exist"
fi

echo ""
echo "Test 45: CODE_OF_CONDUCT.md has enforcement section"
if [[ -f "$SCRIPT_DIR/CODE_OF_CONDUCT.md" ]]; then
  TOTAL=$((TOTAL + 1))
  if echo "$coc_content" | grep -qiP '## .*enforcement'; then
    PASS=$((PASS + 1))
    echo "  PASS: CODE_OF_CONDUCT.md has enforcement section"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: CODE_OF_CONDUCT.md missing enforcement section"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: CODE_OF_CONDUCT.md does not exist"
fi

# =====================================================================
# 15. Issue template validity
# =====================================================================

echo ""
echo "--- Section 15: Issue template validity ---"
echo ""

echo "Test 46: Bug report template has valid YAML frontmatter"
TOTAL=$((TOTAL + 1))
bug_template="$SCRIPT_DIR/.github/ISSUE_TEMPLATE/bug_report.md"
if [[ -f "$bug_template" ]]; then
  if head -n1 "$bug_template" | grep -q '^---$'; then
    if grep -q 'name:' "$bug_template" && grep -q 'about:' "$bug_template"; then
      PASS=$((PASS + 1))
      echo "  PASS: bug report template has valid YAML frontmatter"
    else
      FAIL=$((FAIL + 1))
      echo "  FAIL: bug report template missing name: or about: in frontmatter"
    fi
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: bug report template does not start with YAML frontmatter (---)"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: bug report template not found at .github/ISSUE_TEMPLATE/bug_report.md"
fi

echo ""
echo "Test 47: Feature request template has valid YAML frontmatter"
TOTAL=$((TOTAL + 1))
feature_template="$SCRIPT_DIR/.github/ISSUE_TEMPLATE/feature_request.md"
if [[ -f "$feature_template" ]]; then
  if head -n1 "$feature_template" | grep -q '^---$'; then
    if grep -q 'name:' "$feature_template" && grep -q 'about:' "$feature_template"; then
      PASS=$((PASS + 1))
      echo "  PASS: feature request template has valid YAML frontmatter"
    else
      FAIL=$((FAIL + 1))
      echo "  FAIL: feature request template missing name: or about: in frontmatter"
    fi
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: feature request template does not start with YAML frontmatter (---)"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: feature request template not found at .github/ISSUE_TEMPLATE/feature_request.md"
fi

# =====================================================================
# 16. SECURITY.md depth — responsible disclosure and scope
# =====================================================================

echo ""
echo "--- Section 16: SECURITY.md depth ---"
echo ""

echo "Test 48: SECURITY.md has responsible disclosure policy"
if [[ -f "$SCRIPT_DIR/SECURITY.md" ]]; then
  security_content="${security_content:-$(cat "$SCRIPT_DIR/SECURITY.md")}"
  TOTAL=$((TOTAL + 1))
  if echo "$security_content" | grep -qiP '(disclosure|coordinated)'; then
    PASS=$((PASS + 1))
    echo "  PASS: SECURITY.md has disclosure policy"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: SECURITY.md missing disclosure policy"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: SECURITY.md does not exist"
fi

echo ""
echo "Test 49: SECURITY.md defines scope"
if [[ -f "$SCRIPT_DIR/SECURITY.md" ]]; then
  TOTAL=$((TOTAL + 1))
  if echo "$security_content" | grep -qiP '## .*scope'; then
    PASS=$((PASS + 1))
    echo "  PASS: SECURITY.md defines scope"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: SECURITY.md missing scope section"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: SECURITY.md does not exist"
fi

echo ""
echo "Test 50: SECURITY.md has response timeline"
if [[ -f "$SCRIPT_DIR/SECURITY.md" ]]; then
  TOTAL=$((TOTAL + 1))
  if echo "$security_content" | grep -qiP '(timeline|response time|within.*hours|within.*week)'; then
    PASS=$((PASS + 1))
    echo "  PASS: SECURITY.md includes response timeline"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: SECURITY.md missing response timeline"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: SECURITY.md does not exist"
fi

# =====================================================================
# 17. CONTRIBUTING.md depth — dev setup and testing
# =====================================================================

echo ""
echo "--- Section 17: CONTRIBUTING.md depth ---"
echo ""

echo "Test 51: CONTRIBUTING.md includes development setup"
if [[ -f "$SCRIPT_DIR/CONTRIBUTING.md" ]]; then
  contributing_content="${contributing_content:-$(cat "$SCRIPT_DIR/CONTRIBUTING.md")}"
  TOTAL=$((TOTAL + 1))
  if echo "$contributing_content" | grep -qiP '(development setup|prerequisites|getting started|dev setup)'; then
    PASS=$((PASS + 1))
    echo "  PASS: CONTRIBUTING.md includes development setup"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: CONTRIBUTING.md missing development setup instructions"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: CONTRIBUTING.md does not exist"
fi

echo ""
echo "Test 52: CONTRIBUTING.md explains how to run tests"
if [[ -f "$SCRIPT_DIR/CONTRIBUTING.md" ]]; then
  TOTAL=$((TOTAL + 1))
  if echo "$contributing_content" | grep -qiP '(run.*test|test.*suite|make check)'; then
    PASS=$((PASS + 1))
    echo "  PASS: CONTRIBUTING.md explains how to run tests"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: CONTRIBUTING.md missing test instructions"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: CONTRIBUTING.md does not exist"
fi

echo ""
echo "Test 53: CONTRIBUTING.md describes code style conventions"
if [[ -f "$SCRIPT_DIR/CONTRIBUTING.md" ]]; then
  TOTAL=$((TOTAL + 1))
  if echo "$contributing_content" | grep -qiP '(code style|coding style|style guide|set -uo pipefail)'; then
    PASS=$((PASS + 1))
    echo "  PASS: CONTRIBUTING.md describes code style"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: CONTRIBUTING.md missing code style conventions"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: CONTRIBUTING.md does not exist"
fi

# =====================================================================
# 18. CHANGELOG format quality
# =====================================================================

echo ""
echo "--- Section 18: CHANGELOG format quality ---"
echo ""

echo "Test 54: CHANGELOG has structured section headers"
if [[ -f "$SCRIPT_DIR/CHANGELOG.md" ]]; then
  changelog_content="${changelog_content:-$(cat "$SCRIPT_DIR/CHANGELOG.md")}"
  TOTAL=$((TOTAL + 1))
  if echo "$changelog_content" | grep -qiP '### (Added|Changed|Fixed|Removed|Deprecated|Security)'; then
    PASS=$((PASS + 1))
    echo "  PASS: CHANGELOG has structured section headers"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: CHANGELOG missing structured section headers (Added/Changed/Fixed/etc.)"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: CHANGELOG.md does not exist"
fi

echo ""
echo "Test 55: CHANGELOG v0.1.0 entry has a date"
if [[ -f "$SCRIPT_DIR/CHANGELOG.md" ]]; then
  TOTAL=$((TOTAL + 1))
  if echo "$changelog_content" | grep -qP '\[0\.1\.0\].*\d{4}-\d{2}-\d{2}'; then
    PASS=$((PASS + 1))
    echo "  PASS: CHANGELOG v0.1.0 entry has a date"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: CHANGELOG v0.1.0 entry missing date"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: CHANGELOG.md does not exist"
fi

# =====================================================================
# 19. Community files have no draft markers
# =====================================================================

echo ""
echo "--- Section 19: Community files have no draft markers ---"
echo ""

echo "Test 56: Community files contain no TODO markers"
TOTAL=$((TOTAL + 1))
community_todo=0
for cf in CONTRIBUTING.md CODE_OF_CONDUCT.md SECURITY.md CHANGELOG.md; do
  if [[ -f "$SCRIPT_DIR/$cf" ]] && grep -q 'TODO' "$SCRIPT_DIR/$cf"; then
    community_todo=$((community_todo + 1))
  fi
done
if [[ "$community_todo" -eq 0 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: no TODO markers in community files"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: found TODO markers in $community_todo community file(s)"
fi

echo ""
echo "Test 57: Community files contain no FIXME markers"
TOTAL=$((TOTAL + 1))
community_fixme=0
for cf in CONTRIBUTING.md CODE_OF_CONDUCT.md SECURITY.md CHANGELOG.md; do
  if [[ -f "$SCRIPT_DIR/$cf" ]] && grep -q 'FIXME' "$SCRIPT_DIR/$cf"; then
    community_fixme=$((community_fixme + 1))
  fi
done
if [[ "$community_fixme" -eq 0 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: no FIXME markers in community files"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: found FIXME markers in $community_fixme community file(s)"
fi

echo ""
echo "Test 58: Community files contain no placeholder text"
TOTAL=$((TOTAL + 1))
community_placeholder=0
for cf in CONTRIBUTING.md CODE_OF_CONDUCT.md SECURITY.md CHANGELOG.md; do
  if [[ -f "$SCRIPT_DIR/$cf" ]] && grep -q '\[INSERT' "$SCRIPT_DIR/$cf"; then
    community_placeholder=$((community_placeholder + 1))
  fi
done
if [[ "$community_placeholder" -eq 0 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: no [INSERT placeholder text in community files"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: found [INSERT placeholders in $community_placeholder community file(s)"
fi

# --- Summary ---
echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
