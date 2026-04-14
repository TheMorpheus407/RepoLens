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

# Tests for issue #20: Add AUTHORS.md
#
# Behavioral contract:
# AUTHORS.md exists at repo root with proper credit for Cedric Moessner,
# Bootstrap Academy attribution, GitHub profile link, bootstrap.academy link,
# and a contributors section. README.md links to AUTHORS.md.
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
echo "=== Test Suite: AUTHORS.md — Project Credits (issue #20) ==="
echo ""

AUTHORS="$SCRIPT_DIR/AUTHORS.md"
README="$SCRIPT_DIR/README.md"

authors_content=""
if [[ -f "$AUTHORS" ]]; then
  authors_content="$(cat "$AUTHORS")"
fi

readme_content=""
if [[ -f "$README" ]]; then
  readme_content="$(cat "$README")"
fi

# =====================================================================
# 1. File existence and basic properties
# =====================================================================

echo "--- Section 1: File existence and basic properties ---"
echo ""

echo "Test 1: AUTHORS.md exists at repo root"
assert_file_exists "AUTHORS.md exists" "$AUTHORS"

echo ""
echo "Test 2: AUTHORS.md is not empty"
assert_file_not_empty "AUTHORS.md is not empty" "$AUTHORS"

echo ""
echo "Test 3: AUTHORS.md is plain text markdown, not HTML or binary"
if [[ -f "$AUTHORS" ]]; then
  TOTAL=$((TOTAL + 1))
  if ! grep -qP '\x00' "$AUTHORS" 2>/dev/null && ! grep -qi '<html\|<head\|<body' "$AUTHORS"; then
    PASS=$((PASS + 1))
    echo "  PASS: AUTHORS.md is a text file"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: AUTHORS.md appears to be binary or HTML"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: file missing"
fi

echo ""
echo "Test 4: File ends with trailing newline"
if [[ -f "$AUTHORS" ]]; then
  TOTAL=$((TOTAL + 1))
  last_byte="$(tail -c1 "$AUTHORS" | od -An -tx1 | tr -d ' ')"
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

echo ""
echo "Test 5: No conflicting authors files"
TOTAL=$((TOTAL + 1))
conflicting=0
for f in "$SCRIPT_DIR/AUTHORS.txt" "$SCRIPT_DIR/AUTHORS.rst" "$SCRIPT_DIR/authors.md" "$SCRIPT_DIR/CONTRIBUTORS.md"; do
  if [[ -f "$f" ]]; then
    conflicting=$((conflicting + 1))
  fi
done
if [[ "$conflicting" -eq 0 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: no conflicting authors/contributors files"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: found $conflicting conflicting authors/contributors file(s)"
fi

# =====================================================================
# 2. Required heading: # Authors
# =====================================================================

echo ""
echo "--- Section 2: Title heading ---"
echo ""

echo "Test 6: AUTHORS.md has '# Authors' top-level heading"
assert_matches "has # Authors heading" '^# Authors' "$authors_content"

# =====================================================================
# 3. Credit line: Cedric Moessner (TheMorpheus407)
# =====================================================================

echo ""
echo "--- Section 3: Primary credit line ---"
echo ""

echo "Test 7: AUTHORS.md mentions Cedric Moessner"
assert_contains "mentions Cedric Moessner" "Cedric Moessner" "$authors_content"

echo ""
echo "Test 8: AUTHORS.md mentions TheMorpheus407 handle"
assert_contains "mentions TheMorpheus407" "TheMorpheus407" "$authors_content"

echo ""
echo "Test 9: Credit line includes 'Created and maintained by'"
assert_matches "created and maintained by" "(?i)created\s+and\s+maintained\s+by" "$authors_content"

# =====================================================================
# 4. Bootstrap Academy attribution
# =====================================================================

echo ""
echo "--- Section 4: Bootstrap Academy attribution ---"
echo ""

echo "Test 10: AUTHORS.md mentions Bootstrap Academy"
assert_contains "mentions Bootstrap Academy" "Bootstrap Academy" "$authors_content"

echo ""
echo "Test 11: AUTHORS.md contains Bootstrap Academy project statement"
assert_matches "Bootstrap Academy project statement" "(?i)Bootstrap Academy.*project" "$authors_content"

# =====================================================================
# 5. Required links
# =====================================================================

echo ""
echo "--- Section 5: Required links ---"
echo ""

echo "Test 12: Links to github.com/TheMorpheus407"
assert_contains "GitHub profile link" "github.com/TheMorpheus407" "$authors_content"

echo ""
echo "Test 13: GitHub link is a proper Markdown link"
assert_matches "GitHub link is Markdown formatted" '\[.*\]\(https://github\.com/TheMorpheus407\)' "$authors_content"

echo ""
echo "Test 14: Links to bootstrap.academy"
assert_contains "bootstrap.academy link" "bootstrap.academy" "$authors_content"

echo ""
echo "Test 15: bootstrap.academy link is a proper Markdown link"
assert_matches "bootstrap.academy link is Markdown formatted" '\[.*\]\(https://bootstrap\.academy\)' "$authors_content"

# =====================================================================
# 6. Contributors section
# =====================================================================

echo ""
echo "--- Section 6: Contributors section ---"
echo ""

echo "Test 16: Has ## Contributors section heading"
assert_matches "has ## Contributors heading" '^## Contributors' "$authors_content"

echo ""
echo "Test 17: Contributors section has placeholder text for future contributors"
assert_matches "contributors placeholder text" "(?i)(contributor|pull request|PR)" "$authors_content"

# =====================================================================
# 7. Quality checks
# =====================================================================

echo ""
echo "--- Section 7: Quality checks ---"
echo ""

echo "Test 18: AUTHORS.md contains no TODO markers"
assert_not_contains "no TODO in AUTHORS.md" "TODO" "$authors_content"

echo ""
echo "Test 19: AUTHORS.md contains no FIXME markers"
assert_not_contains "no FIXME in AUTHORS.md" "FIXME" "$authors_content"

echo ""
echo "Test 20: AUTHORS.md contains no placeholder text"
assert_not_contains "no [INSERT placeholder" "[INSERT" "$authors_content"

echo ""
echo "Test 21: AUTHORS.md contains no YYYY-MM-DD placeholder"
assert_not_contains "no YYYY-MM-DD placeholder" "YYYY-MM-DD" "$authors_content"

# =====================================================================
# 8. README links to AUTHORS.md
# =====================================================================

echo ""
echo "--- Section 8: README links to AUTHORS.md ---"
echo ""

echo "Test 22: README contains a reference to AUTHORS.md"
TOTAL=$((TOTAL + 1))
if echo "$readme_content" | grep -qP 'AUTHORS'; then
  PASS=$((PASS + 1))
  echo "  PASS: README references AUTHORS"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: README should contain a reference to AUTHORS.md"
fi

echo ""
echo "Test 23: README contains a Markdown link to AUTHORS.md"
TOTAL=$((TOTAL + 1))
if echo "$readme_content" | grep -qP '\]\(AUTHORS\.md\)'; then
  PASS=$((PASS + 1))
  echo "  PASS: README has Markdown link to AUTHORS.md"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: README should have a Markdown link to AUTHORS.md (e.g. [AUTHORS.md](AUTHORS.md))"
fi

echo ""
echo "Test 24: README has an ## Authors section heading"
assert_matches "README has ## Authors section heading" '^## Authors' "$readme_content"

echo ""
echo "Test 25: README Authors section appears in the documentation footer area"
TOTAL=$((TOTAL + 1))
authors_pos=$(echo "$readme_content" | grep -n '^## Authors' | head -1 | cut -d: -f1)
contributing_pos=$(echo "$readme_content" | grep -n '^## Contributing' | head -1 | cut -d: -f1)
coc_pos=$(echo "$readme_content" | grep -n '^## Code of Conduct' | head -1 | cut -d: -f1 2>/dev/null || echo "")
if [[ -n "$authors_pos" && -n "$contributing_pos" ]]; then
  if [[ "$authors_pos" -gt "$contributing_pos" ]] && { [[ -z "$coc_pos" ]] || [[ "$authors_pos" -lt "$coc_pos" ]]; }; then
    PASS=$((PASS + 1))
    echo "  PASS: Authors section (line $authors_pos) is between Contributing (line $contributing_pos) and Code of Conduct"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: Authors section should appear between Contributing and Code of Conduct in README"
    echo "    Authors: line ${authors_pos:-missing}, Contributing: line ${contributing_pos:-missing}, Code of Conduct: line ${coc_pos:-missing}"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: Could not find Authors and/or Contributing section headings in README"
fi

# =====================================================================
# 9. Consistency with other root files
# =====================================================================

echo ""
echo "--- Section 9: Consistency checks ---"
echo ""

echo "Test 26: AUTHORS.md email (if present) is consistent with CODE_OF_CONDUCT.md"
coc="$SCRIPT_DIR/CODE_OF_CONDUCT.md"
if [[ -f "$coc" && -f "$AUTHORS" ]]; then
  coc_content="$(cat "$coc")"
  coc_email="$(echo "$coc_content" | grep -oP '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' | head -1)"
  authors_email="$(echo "$authors_content" | grep -oP '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' | head -1)"
  TOTAL=$((TOTAL + 1))
  if [[ -z "$authors_email" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: AUTHORS.md has no email (no inconsistency possible)"
  elif [[ "$authors_email" == "$coc_email" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: email in AUTHORS.md matches CODE_OF_CONDUCT.md ($coc_email)"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: email in AUTHORS.md ($authors_email) differs from CODE_OF_CONDUCT.md ($coc_email)"
  fi
else
  TOTAL=$((TOTAL + 1))
  PASS=$((PASS + 1))
  echo "  PASS: one or both files missing (skip consistency check)"
fi

echo ""
echo "Test 27: NOTICE copyright entity is consistent with AUTHORS.md"
notice="$SCRIPT_DIR/NOTICE"
if [[ -f "$notice" && -f "$AUTHORS" ]]; then
  notice_content="$(cat "$notice")"
  TOTAL=$((TOTAL + 1))
  if echo "$notice_content" | grep -qi "Bootstrap Academy" && echo "$authors_content" | grep -qi "Bootstrap Academy"; then
    PASS=$((PASS + 1))
    echo "  PASS: both NOTICE and AUTHORS.md reference Bootstrap Academy"
  elif ! echo "$notice_content" | grep -qi "Bootstrap Academy"; then
    PASS=$((PASS + 1))
    echo "  PASS: NOTICE does not mention Bootstrap Academy (skip check)"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: AUTHORS.md mentions Bootstrap Academy but NOTICE does not (or vice versa)"
  fi
else
  TOTAL=$((TOTAL + 1))
  PASS=$((PASS + 1))
  echo "  PASS: one or both files missing (skip consistency check)"
fi

# =====================================================================
# 10. No scope creep — file should be minimal
# =====================================================================

echo ""
echo "--- Section 10: Scope guard ---"
echo ""

echo "Test 28: AUTHORS.md is concise (under 30 lines)"
if [[ -f "$AUTHORS" ]]; then
  TOTAL=$((TOTAL + 1))
  line_count=$(wc -l < "$AUTHORS")
  if [[ "$line_count" -le 30 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: AUTHORS.md is $line_count lines (concise)"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: AUTHORS.md is $line_count lines (expected ≤30 for a minimal credits file)"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: file missing"
fi

echo ""
echo "Test 29: AUTHORS.md does not duplicate NOTICE copyright boilerplate"
assert_not_contains "no Apache license text in AUTHORS" "Apache License" "$authors_content"

echo ""
echo "Test 30: AUTHORS.md does not duplicate METHODOLOGY.md citation block"
assert_not_contains "no BibTeX citation" "@misc{" "$authors_content"

# --- Summary ---
echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
