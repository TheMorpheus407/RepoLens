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

# shellcheck disable=SC2016  # dollar signs in regex patterns are intentional literals
# Tests for issue #16: Add CONTRIBUTING.md
# Validates that CONTRIBUTING.md covers all required sections for a clean v0.1.0 OSS launch.
# Acceptance: a motivated contributor can open a meaningful lens PR in under 30 minutes
# using only CONTRIBUTING.md as their guide.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTRIBUTING="$SCRIPT_DIR/CONTRIBUTING.md"
DOMAINS_FILE="$SCRIPT_DIR/config/domains.json"

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
echo "=== Test Suite: CONTRIBUTING.md (issue #16) ==="
echo ""

# =====================================================================
# 1. File existence and basic properties
# =====================================================================

echo "Test 1: CONTRIBUTING.md exists at repo root"
assert_file_exists "CONTRIBUTING.md file exists" "$CONTRIBUTING"

echo ""
echo "Test 2: CONTRIBUTING.md is not empty"
assert_file_not_empty "CONTRIBUTING.md is not empty" "$CONTRIBUTING"

# Read content (guard against missing file)
contributing_content=""
if [[ -f "$CONTRIBUTING" ]]; then
  contributing_content="$(cat "$CONTRIBUTING")"
fi

# =====================================================================
# 2. Welcome paragraph — mission-aligned one-liner
# =====================================================================

echo ""
echo "Test 3: Welcome paragraph mentions RepoLens"
assert_contains "mentions RepoLens in opening" "RepoLens" "$contributing_content"

echo ""
echo "Test 4: Welcome paragraph has mission alignment (audit/analysis/lens concept)"
assert_matches "mission-aligned opening" "(?i)(audit|analysis|analyz|lens|code review|code quality)" "$contributing_content"

# =====================================================================
# 3. Lens YAML frontmatter structure — annotated example
# =====================================================================

echo ""
echo "Test 5: Documents lens frontmatter 'id' field"
assert_matches "frontmatter 'id' field documented" "(?m)^.*id:.*" "$contributing_content"

echo ""
echo "Test 6: Documents lens frontmatter 'domain' field"
assert_matches "frontmatter 'domain' field documented" "(?m)^.*domain:.*" "$contributing_content"

echo ""
echo "Test 7: Documents lens frontmatter 'name' field"
assert_matches "frontmatter 'name' field documented" "(?m)^.*name:.*" "$contributing_content"

echo ""
echo "Test 8: Documents lens frontmatter 'role' field"
assert_matches "frontmatter 'role' field documented" "(?m)^.*role:.*" "$contributing_content"

echo ""
echo "Test 9: Shows YAML frontmatter delimiters (---)"
# The frontmatter must be shown in a code block with --- delimiters
assert_matches "shows YAML --- delimiters" "(?m)^---$" "$contributing_content"

echo ""
echo "Test 10: Contains a concrete lens example (not just field names)"
# A good example will have a concrete value for the id field (kebab-case)
assert_matches "concrete lens example with kebab-case id" "id:\s*[a-z]+-[a-z]" "$contributing_content"

# =====================================================================
# 4. Prompt body conventions — What You Hunt For, How You Investigate
# =====================================================================

echo ""
echo "Test 11: Documents '## Your Expert Focus' heading convention"
assert_contains "documents Expert Focus heading" "Your Expert Focus" "$contributing_content"

echo ""
echo "Test 12: Documents 'What You Hunt For' section convention"
assert_contains "documents What You Hunt For" "What You Hunt For" "$contributing_content"

echo ""
echo "Test 13: Documents 'How You Investigate' section convention"
assert_contains "documents How You Investigate" "How You Investigate" "$contributing_content"

# =====================================================================
# 5. config/domains.json registration — JSON snippet
# =====================================================================

echo ""
echo "Test 14: Mentions config/domains.json"
assert_contains "references domains.json" "domains.json" "$contributing_content"

echo ""
echo "Test 15: Shows JSON snippet for domain registration"
# Must contain a JSON-like structure showing the lenses array
assert_matches "shows JSON lenses array" '(?i)"lenses"' "$contributing_content"

echo ""
echo "Test 16: Explains where to add the lens ID in domains.json"
assert_matches "explains adding lens to domain" '(?i)(add|append|insert|include).*lens.*(domain|array|list|lenses)|(domain|array|list|lenses).*(add|append|insert|include).*lens' "$contributing_content"

# =====================================================================
# 6. Lens domain taxonomy reference
# =====================================================================

echo ""
echo "Test 17: Contains a domain taxonomy section"
assert_matches "has domain taxonomy section" "(?im)^#{1,3}\s+.*(domain|taxonomy)" "$contributing_content"

echo ""
echo "Test 18: References actual domain count from domains.json"
actual_domains="$(jq '.domains | length' "$DOMAINS_FILE")"
assert_contains "contains actual domain count ($actual_domains)" "$actual_domains" "$contributing_content"

echo ""
echo "Test 19: Lists security domain"
assert_matches "lists security domain" "(?i)\bsecurity\b" "$contributing_content"

echo ""
echo "Test 20: Lists architecture domain"
assert_matches "lists architecture domain" "(?i)\barchitecture\b" "$contributing_content"

echo ""
echo "Test 21: Lists performance domain"
assert_matches "lists performance domain" "(?i)\bperformance\b" "$contributing_content"

echo ""
echo "Test 22: Lists mode-specific domains"
for domain_id in "discovery" "deployment" "open-source-readiness" "content-quality"; do
  assert_matches "lists $domain_id domain" "(?i)$domain_id" "$contributing_content"
done

echo ""
echo "Test 23: References domains.json as source of truth for taxonomy"
# Should point contributors to the config file rather than hardcoding everything
assert_matches "domains.json as source of truth" "(?i)(source of truth|authoritative|definitive|canonical|refer to|see|check).*domains\.json|domains\.json.*(source of truth|authoritative|definitive|canonical|refer to|see|check|complete|full list)" "$contributing_content"

# =====================================================================
# 7. PR workflow — fork → branch → PR → review → merge
# =====================================================================

echo ""
echo "Test 24: PR workflow section exists"
assert_matches "has PR workflow section" "(?im)^#{1,3}\s+.*(pull request|PR|workflow|contribut)" "$contributing_content"

echo ""
echo "Test 25: PR workflow mentions fork"
assert_matches "workflow mentions fork" "(?i)\bfork\b" "$contributing_content"

echo ""
echo "Test 26: PR workflow mentions branch"
assert_matches "workflow mentions branch" "(?i)\bbranch\b" "$contributing_content"

echo ""
echo "Test 27: PR workflow mentions pull request"
assert_matches "workflow mentions pull request" "(?i)pull request|PR" "$contributing_content"

echo ""
echo "Test 28: PR workflow mentions review"
assert_matches "workflow mentions review" "(?i)\breview\b" "$contributing_content"

echo ""
echo "Test 29: PR workflow mentions merge"
assert_matches "workflow mentions merge" "(?i)\bmerge\b" "$contributing_content"

echo ""
echo "Test 30: PR workflow mentions master branch"
assert_matches "workflow references master" "(?i)\bmaster\b" "$contributing_content"

# =====================================================================
# 8. Commit message convention — Conventional Commits
# =====================================================================

echo ""
echo "Test 31: Commit convention section exists or is documented"
assert_matches "documents commit convention" "(?i)(commit|conventional)" "$contributing_content"

echo ""
echo "Test 32: Mentions 'feat:' prefix"
assert_contains "documents feat: prefix" "feat:" "$contributing_content"

echo ""
echo "Test 33: Mentions 'fix:' prefix"
assert_contains "documents fix: prefix" "fix:" "$contributing_content"

echo ""
echo "Test 34: Mentions Conventional Commits by name or describes the pattern"
assert_matches "names Conventional Commits" "(?i)(conventional commits|conventional commit|type:.*description|<type>)" "$contributing_content"

# =====================================================================
# 9. Code style — set -uo pipefail, no set -e, pure functions
# =====================================================================

echo ""
echo "Test 35: Code style documents 'set -uo pipefail'"
assert_contains "documents set -uo pipefail" "set -uo pipefail" "$contributing_content"

echo ""
echo "Test 36: Code style warns against 'set -e'"
assert_matches "warns against set -e" "(?i)(no|not|avoid|don.t|never).*set -e|set -e.*(no|not|avoid|don.t|never)" "$contributing_content"

echo ""
echo "Test 37: Code style mentions pure functions"
assert_matches "mentions pure functions" "(?i)pure.*function|function.*pure" "$contributing_content"

echo ""
echo "Test 38: Code style mentions side effects documentation"
assert_matches "mentions side effects" "(?i)side.effect" "$contributing_content"

echo ""
echo "Test 39: Code style mentions jq for JSON processing"
assert_contains "mentions jq" "jq" "$contributing_content"

echo ""
echo "Test 40: Code style mentions structured logging"
assert_matches "mentions logging format" '(?i)\[LEVEL\].*\[timestamp\]|structured.*log|log.*format' "$contributing_content"

# =====================================================================
# 10. How to run tests locally — make check
# =====================================================================

echo ""
echo "Test 41: Documents 'make check' command"
assert_contains "documents make check" "make check" "$contributing_content"

echo ""
echo "Test 42: Mentions test file naming pattern"
# Tests follow the pattern tests/test_*.sh
assert_matches "mentions test file pattern" "(?i)test_\*\.sh|test_.*\.sh|tests/" "$contributing_content"

# =====================================================================
# 11. DCO sign-off requirement — git commit -s
# =====================================================================

echo ""
echo "Test 43: DCO sign-off section exists"
assert_matches "documents DCO" "(?i)(DCO|Developer Certificate|sign.off|sign off)" "$contributing_content"

echo ""
echo "Test 44: Documents 'git commit -s' command"
assert_contains "shows git commit -s" "git commit -s" "$contributing_content"

echo ""
echo "Test 45: Explains Signed-off-by line"
assert_contains "explains Signed-off-by" "Signed-off-by" "$contributing_content"

# =====================================================================
# 12. Code of conduct reference
# =====================================================================

echo ""
echo "Test 46: References Code of Conduct"
assert_matches "references code of conduct" "(?i)code of conduct" "$contributing_content"

echo ""
echo "Test 47: Links to CODE_OF_CONDUCT.md"
assert_contains "links to CODE_OF_CONDUCT.md" "CODE_OF_CONDUCT.md" "$contributing_content"

# =====================================================================
# 13. Internal link validation — referenced files must exist
# =====================================================================

echo ""
echo "Test 48: Referenced CODE_OF_CONDUCT.md exists"
assert_file_exists "CODE_OF_CONDUCT.md exists" "$SCRIPT_DIR/CODE_OF_CONDUCT.md"

echo ""
echo "Test 49: Referenced LICENSE file exists"
assert_file_exists "LICENSE exists" "$SCRIPT_DIR/LICENSE"

echo ""
echo "Test 50: Referenced config/domains.json exists"
assert_file_exists "config/domains.json exists" "$DOMAINS_FILE"

echo ""
echo "Test 51: Lens prompt directory exists"
TOTAL=$((TOTAL + 1))
if [[ -d "$SCRIPT_DIR/prompts/lenses" ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: prompts/lenses/ directory exists"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: prompts/lenses/ directory not found"
fi

# =====================================================================
# 14. License reference
# =====================================================================

echo ""
echo "Test 52: Mentions Apache License 2.0"
assert_matches "mentions Apache 2.0" "(?i)apache.*2\.0|apache license" "$contributing_content"

# =====================================================================
# 15. File format and structure checks
# =====================================================================

echo ""
echo "Test 53: CONTRIBUTING.md is plain text, not HTML or binary"
if [[ -f "$CONTRIBUTING" ]]; then
  TOTAL=$((TOTAL + 1))
  if ! grep -qP '\x00' "$CONTRIBUTING" 2>/dev/null && ! grep -qi '<html\|<head\|<body' "$CONTRIBUTING"; then
    PASS=$((PASS + 1))
    echo "  PASS: CONTRIBUTING.md is a text file"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: CONTRIBUTING.md appears to be binary or HTML"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: CONTRIBUTING.md missing"
fi

echo ""
echo "Test 54: CONTRIBUTING.md has a top-level heading"
assert_matches "has H1 heading" "(?m)^#\s+" "$contributing_content"

echo ""
echo "Test 55: No conflicting contributing files"
TOTAL=$((TOTAL + 1))
conflicting_count=0
for f in "$SCRIPT_DIR/CONTRIBUTING.txt" "$SCRIPT_DIR/contributing.md" "$SCRIPT_DIR/Contributing.md"; do
  if [[ -f "$f" ]] && [[ "$f" != "$CONTRIBUTING" ]]; then
    conflicting_count=$((conflicting_count + 1))
  fi
done
if [[ "$conflicting_count" -eq 0 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: no conflicting contributing files"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: found $conflicting_count conflicting contributing file(s)"
fi

# =====================================================================
# 16. Minimum content depth — expanded file should be significantly longer
# =====================================================================

echo ""
echo "Test 56: CONTRIBUTING.md has meaningful length (at least 100 lines)"
if [[ -f "$CONTRIBUTING" ]]; then
  line_count="$(wc -l < "$CONTRIBUTING")"
  TOTAL=$((TOTAL + 1))
  if [[ "$line_count" -ge 100 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: CONTRIBUTING.md has $line_count lines (>= 100)"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: CONTRIBUTING.md has only $line_count lines (expected >= 100 for comprehensive guide)"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: CONTRIBUTING.md missing"
fi

echo ""
echo "Test 57: CONTRIBUTING.md has at least 8 headings"
if [[ -f "$CONTRIBUTING" ]]; then
  heading_count="$(grep -cP '^#{1,3}\s+' "$CONTRIBUTING")"
  TOTAL=$((TOTAL + 1))
  if [[ "$heading_count" -ge 8 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: CONTRIBUTING.md has $heading_count headings (>= 8)"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: CONTRIBUTING.md has only $heading_count headings (expected >= 8)"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: CONTRIBUTING.md missing"
fi

# =====================================================================
# 17. Lens file path convention documented
# =====================================================================

echo ""
echo "Test 58: Documents lens file path convention"
assert_contains "documents lens file path" "prompts/lenses/" "$contributing_content"

echo ""
echo "Test 59: Documents kebab-case naming for lens IDs"
assert_matches "documents kebab-case" "(?i)kebab.case" "$contributing_content"

# =====================================================================
# 18. All 4 required frontmatter fields explicitly listed as required
# =====================================================================

echo ""
echo "Test 60: States all 4 frontmatter fields are required"
assert_matches "states fields are required" "(?i)(required|must|mandatory|necessar).*(id|domain|name|role)|(id|domain|name|role).*(required|must|mandatory|necessar)|all (4|four).*field" "$contributing_content"

# =====================================================================
# 19. Lens contribution golden path — can a contributor follow the steps?
# =====================================================================

echo ""
echo "Test 61: Documents step-by-step lens creation process"
# Must have numbered steps or a clear sequence for adding a lens
assert_matches "has numbered steps for lens creation" "(?m)^[0-9]+\.\s+" "$contributing_content"

echo ""
echo "Test 62: Mentions running make check before submitting"
# The workflow should tell contributors to run make check
assert_matches "workflow includes make check step" "(?i)(run|execute).*make check|make check.*(before|run|first)" "$contributing_content"

# =====================================================================
# 20. Lens domain mode field documentation
# =====================================================================

echo ""
echo "Test 63: Documents mode-specific domains"
assert_matches "documents mode field" '(?i)"mode"|mode field|mode.*domain|domain.*mode' "$contributing_content"

# =====================================================================
# 21. Bug reporting and feature suggestion sections
# =====================================================================

echo ""
echo "Test 64: Has bug reporting section"
assert_matches "has bug reporting" "(?i)(report|bug|issue)" "$contributing_content"

echo ""
echo "Test 65: Has feature suggestion section"
assert_matches "has feature suggestion" "(?i)(feature|suggest|enhance|request)" "$contributing_content"

# =====================================================================
# 22. No stale content from old skeleton
# =====================================================================

echo ""
echo "Test 66: Frontmatter example goes beyond just naming the 4 fields"
# The old version just said "id, domain, name, role" in passing — the new one needs an annotated example
# Check that there's a code block containing frontmatter (both ``` and --- and id: must appear)
TOTAL=$((TOTAL + 1))
if echo "$contributing_content" | grep -qP '```' && echo "$contributing_content" | grep -qP '^id:\s+\S' && echo "$contributing_content" | grep -qP '^---$'; then
  PASS=$((PASS + 1))
  echo "  PASS: has code block with frontmatter example"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: has code block with frontmatter example"
  echo "    Expected code block (\`\`\`) containing YAML frontmatter (--- and id: field)"
fi

# =====================================================================
# 23. Prerequisites section
# =====================================================================

echo ""
echo "Test 67: Documents Bash 4.0+ requirement"
assert_matches "documents Bash requirement" "(?i)bash.*4|bash 4" "$contributing_content"

echo ""
echo "Test 68: Documents jq prerequisite"
assert_matches "documents jq prerequisite" "(?i)\bjq\b" "$contributing_content"

echo ""
echo "Test 69: Documents git prerequisite"
assert_matches "documents git prerequisite" "(?i)\bgit\b" "$contributing_content"

echo ""
echo "Test 70: Documents agent CLI prerequisite"
assert_matches "documents agent CLI" "(?i)(claude|codex|opencode|sparc|agent)" "$contributing_content"

# =====================================================================
# 24. Additional commit types documented
# =====================================================================

echo ""
echo "Test 71: Documents 'docs:' commit type"
assert_contains "documents docs: prefix" "docs:" "$contributing_content"

echo ""
echo "Test 72: Documents 'test:' commit type"
assert_contains "documents test: prefix" "test:" "$contributing_content"

echo ""
echo "Test 73: Documents 'chore:' commit type"
assert_contains "documents chore: prefix" "chore:" "$contributing_content"

# =====================================================================
# 25. Table of Contents presence and coverage
# =====================================================================

echo ""
echo "Test 74: Has a Table of Contents section"
assert_matches "has table of contents" "(?im)^#{1,3}\s+table of contents" "$contributing_content"

echo ""
echo "Test 75: Table of Contents links to key sections"
for section in "Quick Start" "PR Workflow" "Commit Messages" "DCO Sign-Off" "Code Style" "Domain Taxonomy"; do
  assert_matches "ToC links to $section" "(?i)\[.*${section}.*\]\(#" "$contributing_content"
done

# =====================================================================
# 26. Code style: additional conventions documented
# =====================================================================

echo ""
echo "Test 76: Code style documents variable quoting"
assert_matches "documents variable quoting" '(?i)quote.*variable|\$var|"\$' "$contributing_content"

echo ""
echo "Test 77: Code style documents 'local' for function variables"
assert_matches "documents local keyword" "(?i)\blocal\b.*variable|variable.*\blocal\b|\blocal\b.*function" "$contributing_content"

# =====================================================================
# 27. Domain taxonomy cross-validation against domains.json
# =====================================================================

echo ""
echo "Test 78: All default-mode domain IDs in CONTRIBUTING.md exist in domains.json"
if [[ -f "$DOMAINS_FILE" ]]; then
  default_domains_in_json="$(jq -r '.domains[] | select(.mode == null or .mode == "") | .id' "$DOMAINS_FILE" | sort)"
  all_pass=true
  while IFS= read -r domain_id; do
    if ! echo "$contributing_content" | grep -qP "(?m)^\|?\s*${domain_id}\s*\|"; then
      echo "  MISSING in CONTRIBUTING.md: $domain_id"
      all_pass=false
    fi
  done <<< "$default_domains_in_json"
  TOTAL=$((TOTAL + 1))
  if $all_pass; then
    PASS=$((PASS + 1))
    echo "  PASS: all default domains from domains.json are listed in CONTRIBUTING.md"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: some default domains missing from CONTRIBUTING.md"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: domains.json not found"
fi

echo ""
echo "Test 79: Lens counts in CONTRIBUTING.md match domains.json"
if [[ -f "$DOMAINS_FILE" ]]; then
  mismatch_count=0
  while IFS=: read -r domain_id expected_count _mode; do
    if echo "$contributing_content" | grep -qP "(?m)^\|?\s*${domain_id}\s*\|"; then
      doc_count="$(echo "$contributing_content" | grep -P "^\|?\s*${domain_id}\s*\|" | grep -oP '\|\s*(\d+)\s*\|?\s*$' | grep -oP '\d+')"
      if [[ -n "$doc_count" && "$doc_count" != "$expected_count" ]]; then
        echo "  MISMATCH: $domain_id — doc says $doc_count, domains.json has $expected_count"
        mismatch_count=$((mismatch_count + 1))
      fi
    fi
  done < <(jq -r '.domains[] | "\(.id):\(.lenses | length):\(.mode // "default")"' "$DOMAINS_FILE")
  TOTAL=$((TOTAL + 1))
  if [[ "$mismatch_count" -eq 0 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: all documented lens counts match domains.json"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $mismatch_count domain(s) have mismatched lens counts"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: domains.json not found"
fi

# =====================================================================
# 28. Mode-specific domain mode values cross-validation
# =====================================================================

echo ""
echo "Test 80: Mode-specific domains list correct mode values"
if [[ -f "$DOMAINS_FILE" ]]; then
  mode_ok=true
  while IFS=: read -r domain_id _count mode; do
    if [[ "$mode" != "default" ]]; then
      if ! echo "$contributing_content" | grep -qP "(?m)^\|?\s*${domain_id}\s*\|.*\`${mode}\`"; then
        echo "  MISSING mode value: $domain_id should show mode=$mode"
        mode_ok=false
      fi
    fi
  done < <(jq -r '.domains[] | "\(.id):\(.lenses | length):\(.mode // "default")"' "$DOMAINS_FILE")
  TOTAL=$((TOTAL + 1))
  if $mode_ok; then
    PASS=$((PASS + 1))
    echo "  PASS: all mode-specific domains show correct mode values"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: some mode-specific domains have incorrect mode values"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: domains.json not found"
fi

# =====================================================================
# 29. Domain table placement cross-validation
# =====================================================================

echo ""
echo "Test 81: Default-mode domains appear in Default-Mode section, not Mode-Specific section"
if [[ -f "$DOMAINS_FILE" ]]; then
  default_section="$(echo "$contributing_content" | sed -n '/### Default-Mode Domains/,/### Mode-Specific Domains/p')"
  mode_specific_section="$(echo "$contributing_content" | sed -n '/### Mode-Specific Domains/,/^## /p')"
  placement_ok=true
  while IFS= read -r domain_id; do
    if echo "$mode_specific_section" | grep -qP "^\|?\s*${domain_id}\s*\|"; then
      echo "  WRONG TABLE: $domain_id has no mode field but appears in Mode-Specific section"
      placement_ok=false
    fi
    if ! echo "$default_section" | grep -qP "^\|?\s*${domain_id}\s*\|"; then
      echo "  MISSING: $domain_id has no mode field but is missing from Default-Mode section"
      placement_ok=false
    fi
  done < <(jq -r '.domains[] | select(.mode == null or .mode == "") | .id' "$DOMAINS_FILE")
  while IFS= read -r domain_id; do
    if echo "$default_section" | grep -qP "^\|?\s*${domain_id}\s*\|"; then
      echo "  WRONG TABLE: $domain_id has mode field but appears in Default-Mode section"
      placement_ok=false
    fi
    if ! echo "$mode_specific_section" | grep -qP "^\|?\s*${domain_id}\s*\|"; then
      echo "  MISSING: $domain_id has mode field but is missing from Mode-Specific section"
      placement_ok=false
    fi
  done < <(jq -r '.domains[] | select(.mode != null and .mode != "") | .id' "$DOMAINS_FILE")
  TOTAL=$((TOTAL + 1))
  if $placement_ok; then
    PASS=$((PASS + 1))
    echo "  PASS: all domains appear in the correct taxonomy table"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: some domains appear in the wrong taxonomy table"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: domains.json not found"
fi

echo ""
echo "Test 82: Section heading counts match actual domain counts from domains.json"
if [[ -f "$DOMAINS_FILE" ]]; then
  actual_default="$(jq '[.domains[] | select(.mode == null or .mode == "")] | length' "$DOMAINS_FILE")"
  actual_mode="$(jq '[.domains[] | select(.mode != null and .mode != "")] | length' "$DOMAINS_FILE")"
  heading_count_ok=true
  if ! echo "$contributing_content" | grep -qP "### Default-Mode Domains \(${actual_default}\)"; then
    echo "  MISMATCH: Default-Mode heading count should be $actual_default"
    heading_count_ok=false
  fi
  if ! echo "$contributing_content" | grep -qP "### Mode-Specific Domains \(${actual_mode}\)"; then
    echo "  MISMATCH: Mode-Specific heading count should be $actual_mode"
    heading_count_ok=false
  fi
  TOTAL=$((TOTAL + 1))
  if $heading_count_ok; then
    PASS=$((PASS + 1))
    echo "  PASS: section heading counts match domains.json"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: section heading counts do not match domains.json"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: domains.json not found"
fi

# =====================================================================
# 30. Frontmatter example references a real lens file
# =====================================================================

echo ""
echo "Test 83: Frontmatter example lens ID matches an actual lens file"
example_id="$(echo "$contributing_content" | grep -P '^id:\s+' | head -1 | sed 's/^id:\s*//')"
example_domain="$(echo "$contributing_content" | grep -P '^domain:\s+' | head -1 | sed 's/^domain:\s*//')"
TOTAL=$((TOTAL + 1))
if [[ -n "$example_id" && -n "$example_domain" ]]; then
  expected_file="$SCRIPT_DIR/prompts/lenses/$example_domain/$example_id.md"
  if [[ -f "$expected_file" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: example lens $example_domain/$example_id.md exists"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: example lens file not found: $expected_file"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: could not extract id/domain from frontmatter example"
fi

# =====================================================================
# 30b. Frontmatter example name/role match actual lens file
# =====================================================================

echo ""
echo "Test 83b: Frontmatter example name and role match actual lens file"
TOTAL=$((TOTAL + 1))
if [[ -n "$example_id" && -n "$example_domain" ]]; then
  expected_file="$SCRIPT_DIR/prompts/lenses/$example_domain/$example_id.md"
  if [[ -f "$expected_file" ]]; then
    example_name="$(echo "$contributing_content" | grep -P '^name:\s+' | head -1 | sed 's/^name:\s*//')"
    example_role="$(echo "$contributing_content" | grep -P '^role:\s+' | head -1 | sed 's/^role:\s*//')"
    actual_name="$(grep -P '^name:\s+' "$expected_file" | head -1 | sed 's/^name:\s*//')"
    actual_role="$(grep -P '^role:\s+' "$expected_file" | head -1 | sed 's/^role:\s*//')"
    if [[ "$example_name" == "$actual_name" && "$example_role" == "$actual_role" ]]; then
      PASS=$((PASS + 1))
      echo "  PASS: name='$example_name' and role='$example_role' match actual lens file"
    else
      FAIL=$((FAIL + 1))
      if [[ "$example_name" != "$actual_name" ]]; then
        echo "  FAIL: name mismatch: CONTRIBUTING.md='$example_name' vs actual='$actual_name'"
      fi
      if [[ "$example_role" != "$actual_role" ]]; then
        echo "  FAIL: role mismatch: CONTRIBUTING.md='$example_role' vs actual='$actual_role'"
      fi
    fi
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: cannot cross-validate — lens file not found: $expected_file"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: could not extract id/domain from frontmatter example"
fi

# =====================================================================
# 31. JSON registration snippet uses real lens IDs from domains.json
# =====================================================================

echo ""
echo "Test 84: JSON snippet lens IDs exist in domains.json"
if [[ -f "$DOMAINS_FILE" ]]; then
  json_block="$(echo "$contributing_content" | sed -n '/```json/,/```/p')"
  all_lenses_in_json="$(jq -r '.domains[].lenses[]' "$DOMAINS_FILE")"
  snippet_ok=true
  while IFS= read -r lens_id; do
    if [[ "$lens_id" == "your-new-lens-id" ]]; then
      continue
    fi
    if ! echo "$all_lenses_in_json" | grep -qxF "$lens_id"; then
      echo "  INVALID: JSON snippet lens '$lens_id' not found in domains.json"
      snippet_ok=false
    fi
  done < <(echo "$json_block" | grep -oP '"([a-z]+-[a-z-]+)"' | tr -d '"')
  TOTAL=$((TOTAL + 1))
  if $snippet_ok; then
    PASS=$((PASS + 1))
    echo "  PASS: all JSON snippet lens IDs are real"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: JSON snippet contains non-existent lens IDs"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: domains.json not found"
fi

# =====================================================================
# 32. Structure Breakdown table exists
# =====================================================================

echo ""
echo "Test 85: Has Structure Breakdown table for lens sections"
assert_matches "has Structure Breakdown section" "(?im)^#{1,4}\s+Structure Breakdown" "$contributing_content"

# =====================================================================
# 33. Table of Contents covers all major sections
# =====================================================================

echo ""
echo "Test 86: Table of Contents links to remaining sections"
for section in "Running Tests" "Reporting Bugs" "Suggesting Features" "Prerequisites" "Code of Conduct" "License" "Lens Prompt Conventions" "Registering in domains"; do
  assert_matches "ToC links to $section" "(?i)\[.*${section}.*\]\(#" "$contributing_content"
done

# =====================================================================
# 34. Commit message convention details
# =====================================================================

echo ""
echo "Test 87: Documents no-scope-parentheses convention"
assert_matches "documents no scope parentheses" "(?i)no.*scope.*parenthes|scope.*parenthes.*not" "$contributing_content"

echo ""
echo "Test 88: Documents lowercase commit description convention"
assert_matches "documents lowercase convention" "(?i)(lowercase|lower.case).*descri|descri.*(lowercase|lower.case)" "$contributing_content"

# =====================================================================
# 35. DCO section references external standard
# =====================================================================

echo ""
echo "Test 89: DCO section links to developercertificate.org"
assert_contains "links to DCO website" "developercertificate.org" "$contributing_content"

# =====================================================================
# 36. Template engine reference for lens parsing
# =====================================================================

echo ""
echo "Test 90: References template engine for frontmatter parsing"
assert_matches "references template engine" "(?i)template|read_frontmatter|lib/template" "$contributing_content"

# =====================================================================
# 37. Structure Breakdown table completeness
# =====================================================================

echo ""
echo "Test 91: Structure Breakdown table lists all 7 documented sections"
structure_section="$(echo "$contributing_content" | sed -n '/### Structure Breakdown/,/^## /p')"
structure_ok=true
for row_key in '`id`' '`domain`' '`name`' '`role`' 'Your Expert Focus' 'What You Hunt For' 'How You Investigate'; do
  if [[ "$structure_section" != *"$row_key"* ]]; then
    echo "  MISSING row: $row_key"
    structure_ok=false
  fi
done
TOTAL=$((TOTAL + 1))
if $structure_ok; then
  PASS=$((PASS + 1))
  echo "  PASS: all 7 Structure Breakdown rows present"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: Structure Breakdown table is missing rows"
fi

# =====================================================================
# 38. JSON snippet domain metadata cross-validation
# =====================================================================

echo ""
echo "Test 92: JSON snippet domain id/name match domains.json"
if [[ -f "$DOMAINS_FILE" ]]; then
  snippet_domain_id="$(echo "$contributing_content" | sed -n '/```json/,/```/p' | grep -oP '"id":\s*"\K[^"]+')"
  if [[ -n "$snippet_domain_id" ]]; then
    actual_name="$(jq -r --arg id "$snippet_domain_id" '.domains[] | select(.id == $id) | .name' "$DOMAINS_FILE")"
    snippet_name="$(echo "$contributing_content" | sed -n '/```json/,/```/p' | grep -oP '"name":\s*"\K[^"]+')"
    TOTAL=$((TOTAL + 1))
    if [[ -n "$actual_name" && "$snippet_name" == "$actual_name" ]]; then
      PASS=$((PASS + 1))
      echo "  PASS: JSON snippet domain '$snippet_domain_id' name matches domains.json ('$actual_name')"
    else
      FAIL=$((FAIL + 1))
      echo "  FAIL: JSON snippet domain name mismatch: snippet='$snippet_name' vs domains.json='$actual_name'"
    fi
  else
    TOTAL=$((TOTAL + 1))
    FAIL=$((FAIL + 1))
    echo "  FAIL: could not extract domain id from JSON snippet"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: domains.json not found"
fi

echo ""
echo "Test 93: JSON snippet domain order matches domains.json"
if [[ -f "$DOMAINS_FILE" && -n "${snippet_domain_id:-}" ]]; then
  snippet_order="$(echo "$contributing_content" | sed -n '/```json/,/```/p' | grep -oP '"order":\s*\K[0-9]+')"
  actual_order="$(jq -r --arg id "$snippet_domain_id" '.domains[] | select(.id == $id) | .order' "$DOMAINS_FILE")"
  TOTAL=$((TOTAL + 1))
  if [[ -n "$snippet_order" && "$snippet_order" == "$actual_order" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: JSON snippet order ($snippet_order) matches domains.json"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: JSON snippet order mismatch: snippet='$snippet_order' vs domains.json='$actual_order'"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: could not validate order (missing domains.json or domain id)"
fi

# =====================================================================
# 39. Quick Start section completeness
# =====================================================================

echo ""
echo "Test 94: Quick Start covers all 6 essential steps"
quickstart_section="$(echo "$contributing_content" | sed -n '/## Quick Start/,/^## /p')"
qs_ok=true
for step_keyword in "domain" "prompts/lenses/" "frontmatter" "domains.json" "make check" "pull request"; do
  if ! echo "$quickstart_section" | grep -qi "$step_keyword"; then
    echo "  MISSING step keyword: $step_keyword"
    qs_ok=false
  fi
done
TOTAL=$((TOTAL + 1))
if $qs_ok; then
  PASS=$((PASS + 1))
  echo "  PASS: Quick Start covers all 6 essential steps"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: Quick Start is missing essential steps"
fi

echo ""
echo "Test 95: Quick Start states no code changes needed"
assert_matches "no code changes needed statement" "(?i)no code changes.*(needed|required|necessary)" "$contributing_content"

# =====================================================================
# 40. Table of Contents anchor integrity
# =====================================================================

echo ""
echo "Test 96: All Table of Contents anchors resolve to actual headings"
heading_anchors="$(echo "$contributing_content" | grep -P '^#{1,4}\s+' | sed 's/^#\+ //' | \
  tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9 -]//g' | sed 's/  */ /g' | sed 's/ /-/g')"
anchors_ok=true
while IFS= read -r anchor; do
  if ! echo "$heading_anchors" | grep -qxF "$anchor"; then
    echo "  BROKEN ANCHOR: #$anchor does not resolve to a heading"
    anchors_ok=false
  fi
done < <(echo "$contributing_content" | sed -n '/## Table of Contents/,/^## [^T]/p' | grep -oP '\]\(#\K[^)]+')
TOTAL=$((TOTAL + 1))
if $anchors_ok; then
  PASS=$((PASS + 1))
  echo "  PASS: all ToC anchors resolve to actual headings"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: some ToC anchors do not resolve to headings"
fi

# =====================================================================
# 41. Conventional Commits external link
# =====================================================================

echo ""
echo "Test 97: Links to Conventional Commits website"
assert_contains "links to conventionalcommits.org" "conventionalcommits.org" "$contributing_content"

# =====================================================================
# 42. JSON snippet lenses array matches actual domain lenses
# =====================================================================

echo ""
echo "Test 98: JSON snippet lenses array matches actual domain lenses from domains.json"
if [[ -f "$DOMAINS_FILE" && -n "${snippet_domain_id:-}" ]]; then
  actual_lenses="$(jq -r --arg id "$snippet_domain_id" '.domains[] | select(.id == $id) | .lenses[]' "$DOMAINS_FILE")"
  snippet_lenses="$(echo "$contributing_content" | sed -n '/```json/,/```/p' | grep -oP '"([a-z]+-[a-z-]+)"' | tr -d '"' | grep -v 'your-new-lens-id')"
  all_present=true
  while IFS= read -r lens; do
    if ! echo "$actual_lenses" | grep -qxF "$lens"; then
      echo "  NOT IN DOMAIN: $lens is in snippet but not in $snippet_domain_id lenses"
      all_present=false
    fi
  done <<< "$snippet_lenses"
  while IFS= read -r lens; do
    if ! echo "$snippet_lenses" | grep -qxF "$lens"; then
      echo "  MISSING FROM SNIPPET: $lens is in $snippet_domain_id but not in JSON snippet"
      all_present=false
    fi
  done <<< "$actual_lenses"
  TOTAL=$((TOTAL + 1))
  if $all_present; then
    PASS=$((PASS + 1))
    echo "  PASS: JSON snippet lenses match $snippet_domain_id domain completely"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: JSON snippet lenses do not match $snippet_domain_id domain in domains.json"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: could not validate lenses (missing domains.json or domain id)"
fi

# --- Summary ---
echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
