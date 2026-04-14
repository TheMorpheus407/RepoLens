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

# Tests for issue #2: Add LICENSE file (Apache-2.0, Bootstrap Academy)
# Validates that LICENSE and NOTICE files exist with correct content.
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
echo "=== Test Suite: LICENSE and NOTICE files (issue #2) ==="
echo ""

# =====================================================================
# 1. LICENSE file existence and basic properties
# =====================================================================

echo "Test 1: LICENSE file exists at repo root"
assert_file_exists "LICENSE file exists" "$SCRIPT_DIR/LICENSE"

echo ""
echo "Test 2: LICENSE file is not empty"
assert_file_not_empty "LICENSE file is not empty" "$SCRIPT_DIR/LICENSE"

# =====================================================================
# 2. LICENSE content — must be Apache License, Version 2.0
# =====================================================================

# Read LICENSE content (guard against missing file)
license_content=""
if [[ -f "$SCRIPT_DIR/LICENSE" ]]; then
  license_content="$(cat "$SCRIPT_DIR/LICENSE")"
fi

echo ""
echo "Test 3: LICENSE contains Apache License header"
assert_contains "contains 'Apache License'" "Apache License" "$license_content"

echo ""
echo "Test 4: LICENSE specifies Version 2.0"
assert_contains "contains 'Version 2.0'" "Version 2.0" "$license_content"

echo ""
echo "Test 5: LICENSE contains January 2004 date"
# The standard Apache-2.0 text includes "January 2004"
assert_contains "contains 'January 2004'" "January 2004" "$license_content"

echo ""
echo "Test 6: LICENSE contains apache.org URL"
assert_contains "contains apache.org URL" "http://www.apache.org/licenses/" "$license_content"

# =====================================================================
# 3. LICENSE content — key legal clauses present (verbatim text check)
# =====================================================================

echo ""
echo "Test 7: LICENSE contains TERMS AND CONDITIONS header"
assert_contains "contains TERMS AND CONDITIONS" "TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION" "$license_content"

echo ""
echo "Test 8: LICENSE contains patent grant clause (Section 3)"
assert_contains "contains patent grant" "Grant of Patent License" "$license_content"

echo ""
echo "Test 9: LICENSE contains redistribution clause (Section 4)"
assert_contains "contains redistribution terms" "Redistribution" "$license_content"

echo ""
echo "Test 10: LICENSE contains limitation of liability"
assert_matches "contains limitation of liability" "(?i)limitation of liability" "$license_content"

echo ""
echo "Test 11: LICENSE contains NO WARRANTY disclaimer"
assert_matches "contains warranty disclaimer" '(?i)(WITHOUT WARRANTIES|NO WARRANTY|"AS IS")' "$license_content"

echo ""
echo "Test 12: LICENSE contains Definitions section"
assert_contains "contains Definitions section" '"License" shall mean' "$license_content"

echo ""
echo "Test 13: LICENSE contains END OF TERMS marker"
assert_contains "contains END OF TERMS" "END OF TERMS AND CONDITIONS" "$license_content"

# =====================================================================
# 4. LICENSE must NOT contain MIT or other license text
# =====================================================================

echo ""
echo "Test 14: LICENSE does not contain MIT license text"
assert_not_contains "no MIT in LICENSE" "MIT License" "$license_content"
assert_not_contains "no MIT permission clause" "Permission is hereby granted, free of charge" "$license_content"

# =====================================================================
# 5. LICENSE is unmodified standard text (line count check)
# =====================================================================

echo ""
echo "Test 15: LICENSE has expected line count for standard Apache-2.0"
# The standard Apache-2.0 text from apache.org is 202 lines (with the appendix)
# or ~176 lines (without appendix). We check it's in a reasonable range.
if [[ -f "$SCRIPT_DIR/LICENSE" ]]; then
  line_count="$(wc -l < "$SCRIPT_DIR/LICENSE")"
  TOTAL=$((TOTAL + 1))
  if [[ "$line_count" -ge 170 && "$line_count" -le 210 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: LICENSE line count ($line_count) is in expected range (170-210)"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: LICENSE line count ($line_count) outside expected range (170-210)"
    echo "    Standard Apache-2.0 is ~176-202 lines"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: LICENSE file missing, cannot check line count"
fi

# =====================================================================
# 6. NOTICE file existence and basic properties
# =====================================================================

echo ""
echo "Test 16: NOTICE file exists at repo root"
assert_file_exists "NOTICE file exists" "$SCRIPT_DIR/NOTICE"

echo ""
echo "Test 17: NOTICE file is not empty"
assert_file_not_empty "NOTICE file is not empty" "$SCRIPT_DIR/NOTICE"

# =====================================================================
# 7. NOTICE content — copyright and project name
# =====================================================================

notice_content=""
if [[ -f "$SCRIPT_DIR/NOTICE" ]]; then
  notice_content="$(cat "$SCRIPT_DIR/NOTICE")"
fi

echo ""
echo "Test 18: NOTICE contains project name 'RepoLens'"
assert_contains "contains 'RepoLens'" "RepoLens" "$notice_content"

echo ""
echo "Test 19: NOTICE contains copyright holder 'Bootstrap Academy'"
assert_contains "contains 'Bootstrap Academy'" "Bootstrap Academy" "$notice_content"

echo ""
echo "Test 20: NOTICE contains copyright year"
# Must contain a year (4-digit number starting with 20)
assert_matches "contains copyright year" "20[0-9]{2}" "$notice_content"

echo ""
echo "Test 21: NOTICE contains the word 'Copyright'"
assert_matches "contains 'Copyright'" "(?i)copyright" "$notice_content"

echo ""
echo "Test 22: NOTICE references Apache License"
assert_matches "references Apache License" "(?i)apache" "$notice_content"

# =====================================================================
# 8. NOTICE must have correct copyright holder (not personal name)
# =====================================================================

echo ""
echo "Test 23: NOTICE copyright is Bootstrap Academy, not personal name"
# The issue explicitly requires "Copyright Bootstrap Academy", not Cedric personally
assert_not_contains "no personal name as copyright holder" "Copyright Cedric" "$notice_content"
assert_not_contains "no personal name as copyright holder (2)" "Copyright Moessner" "$notice_content"

# =====================================================================
# 9. README link integrity — LICENSE link must resolve
# =====================================================================

echo ""
echo "Test 24: README LICENSE badge link resolves to existing file"
if [[ -f "$README" ]]; then
  readme_content="$(cat "$README")"
  # The badge links to LICENSE — verify the file it points to exists
  TOTAL=$((TOTAL + 1))
  if echo "$readme_content" | grep -qP '\]\(LICENSE\)' && [[ -f "$SCRIPT_DIR/LICENSE" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: README links to LICENSE and file exists"
  elif ! echo "$readme_content" | grep -qP '\]\(LICENSE\)'; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: README does not contain link to LICENSE"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: README links to LICENSE but file does not exist"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: README.md not found"
fi

echo ""
echo "Test 25: README license badge still says Apache-2.0"
if [[ -f "$README" ]]; then
  readme_content="$(cat "$README")"
  assert_contains "badge says Apache-2.0" "Apache-2.0" "$readme_content"
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: README.md not found"
fi

# =====================================================================
# 10. LICENSE is plain text (not binary, not HTML)
# =====================================================================

echo ""
echo "Test 26: LICENSE is plain text, not HTML or binary"
if [[ -f "$SCRIPT_DIR/LICENSE" ]]; then
  TOTAL=$((TOTAL + 1))
  # Portable plaintext check: no NUL bytes and no HTML tags
  if ! grep -qP '\x00' "$SCRIPT_DIR/LICENSE" 2>/dev/null && ! grep -qi '<html\|<head\|<body' "$SCRIPT_DIR/LICENSE"; then
    PASS=$((PASS + 1))
    echo "  PASS: LICENSE is a text file"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: LICENSE appears to be binary or HTML"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: LICENSE file missing"
fi

# =====================================================================
# 11. No stale license files (e.g., LICENSE.md, LICENSE.txt alongside LICENSE)
# =====================================================================

echo ""
echo "Test 27: No conflicting license files"
TOTAL=$((TOTAL + 1))
conflicting_count=0
for f in "$SCRIPT_DIR/LICENSE.md" "$SCRIPT_DIR/LICENSE.txt" "$SCRIPT_DIR/LICENCE" "$SCRIPT_DIR/LICENCE.md"; do
  if [[ -f "$f" ]]; then
    conflicting_count=$((conflicting_count + 1))
  fi
done
if [[ "$conflicting_count" -eq 0 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: no conflicting license files (LICENSE.md, LICENSE.txt, LICENCE)"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: found $conflicting_count conflicting license file(s)"
fi

# =====================================================================
# 12. LICENSE completeness — remaining sections not yet covered
# =====================================================================

echo ""
echo "Test 28: LICENSE contains Section 2 (Grant of Copyright License)"
assert_contains "contains copyright license grant" "Grant of Copyright License" "$license_content"

echo ""
echo "Test 29: LICENSE contains Section 5 (Submission of Contributions)"
assert_contains "contains submission of contributions" "Submission of Contributions" "$license_content"

echo ""
echo "Test 30: LICENSE contains Section 6 (Trademarks)"
assert_contains "contains trademarks clause" "Trademarks" "$license_content"

echo ""
echo "Test 31: LICENSE contains Section 9 (Accepting Warranty or Additional Liability)"
assert_contains "contains accepting warranty clause" "Accepting Warranty or Additional Liability" "$license_content"

echo ""
echo "Test 32: LICENSE contains APPENDIX section"
assert_contains "contains APPENDIX" "APPENDIX" "$license_content"

# =====================================================================
# 13. NOTICE — complete copyright line and size constraint
# =====================================================================

echo ""
echo "Test 33: NOTICE contains complete copyright line"
assert_contains "complete copyright line" "Copyright 2025 Bootstrap Academy" "$notice_content"

echo ""
echo "Test 34: NOTICE is concise (under 10 lines per Apache convention)"
if [[ -f "$SCRIPT_DIR/NOTICE" ]]; then
  notice_lines="$(wc -l < "$SCRIPT_DIR/NOTICE")"
  TOTAL=$((TOTAL + 1))
  if [[ "$notice_lines" -le 10 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: NOTICE is concise ($notice_lines lines)"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: NOTICE is too long ($notice_lines lines, expected <= 10)"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: NOTICE file missing"
fi

# =====================================================================
# 14. NOTICE is plain text (parity with LICENSE check)
# =====================================================================

echo ""
echo "Test 35: NOTICE is plain text, not HTML or binary"
if [[ -f "$SCRIPT_DIR/NOTICE" ]]; then
  TOTAL=$((TOTAL + 1))
  if ! grep -qP '\x00' "$SCRIPT_DIR/NOTICE" 2>/dev/null && ! grep -qi '<html\|<head\|<body' "$SCRIPT_DIR/NOTICE"; then
    PASS=$((PASS + 1))
    echo "  PASS: NOTICE is a text file"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: NOTICE appears to be binary or HTML"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: NOTICE file missing"
fi

# =====================================================================
# 15. LICENSE must not contain other common license texts
# =====================================================================

echo ""
echo "Test 36: LICENSE does not contain GPL license text"
assert_not_contains "no GPL in LICENSE" "GNU GENERAL PUBLIC LICENSE" "$license_content"
assert_not_contains "no GPL v3 in LICENSE" "GNU LESSER GENERAL PUBLIC LICENSE" "$license_content"

echo ""
echo "Test 37: LICENSE does not contain BSD license text"
assert_not_contains "no BSD in LICENSE" "Redistribution and use in source and binary forms" "$license_content"

# =====================================================================
# 16. README NOTICE link — implementation added [NOTICE](NOTICE)
# =====================================================================

echo ""
echo "Test 38: README links to NOTICE file"
if [[ -f "$README" ]]; then
  readme_content="$(cat "$README")"
  TOTAL=$((TOTAL + 1))
  if echo "$readme_content" | grep -qP '\]\(NOTICE\)'; then
    PASS=$((PASS + 1))
    echo "  PASS: README contains link to NOTICE"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: README does not contain link to NOTICE"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: README.md not found"
fi

echo ""
echo "Test 39: README NOTICE link resolves to existing file"
if [[ -f "$README" ]]; then
  readme_content="$(cat "$README")"
  TOTAL=$((TOTAL + 1))
  if echo "$readme_content" | grep -qP '\]\(NOTICE\)' && [[ -f "$SCRIPT_DIR/NOTICE" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: README links to NOTICE and file exists"
  elif ! echo "$readme_content" | grep -qP '\]\(NOTICE\)'; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: README does not contain NOTICE link"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: README links to NOTICE but file does not exist"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: README.md not found"
fi

# =====================================================================
# 17. LICENSE APPENDIX boilerplate integrity
# =====================================================================

echo ""
echo "Test 40: LICENSE APPENDIX contains canonical boilerplate notice"
assert_contains "contains boilerplate copyright placeholder" "Copyright [yyyy] [name of copyright owner]" "$license_content"

echo ""
echo "Test 41: LICENSE APPENDIX contains license-under clause"
assert_contains "contains licensed under clause" 'Licensed under the Apache License, Version 2.0 (the "License")' "$license_content"

echo ""
echo "Test 42: LICENSE APPENDIX does not contain non-standard text"
# The fixer agent had to remove a non-standard sentence. Ensure no extra sentences remain.
assert_not_contains "no non-standard text in APPENDIX" "Please also get an information" "$license_content"

# =====================================================================
# 18. NOTICE structure — Apache convention
# =====================================================================

echo ""
echo "Test 43: NOTICE first line is the project name"
if [[ -f "$SCRIPT_DIR/NOTICE" ]]; then
  first_line="$(head -n1 "$SCRIPT_DIR/NOTICE")"
  TOTAL=$((TOTAL + 1))
  if [[ "$first_line" == "RepoLens" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: NOTICE first line is 'RepoLens'"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: NOTICE first line is '$first_line', expected 'RepoLens'"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: NOTICE file missing"
fi

echo ""
echo "Test 44: NOTICE contains exact license reference line"
assert_contains "exact license reference" "This product is licensed under the Apache License, Version 2.0." "$notice_content"

# =====================================================================
# 19. LICENSE canonical header structure
# =====================================================================

echo ""
echo "Test 45: LICENSE first non-empty line is 'Apache License'"
if [[ -f "$SCRIPT_DIR/LICENSE" ]]; then
  first_content_line="$(grep -m1 '[^[:space:]]' "$SCRIPT_DIR/LICENSE" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"
  TOTAL=$((TOTAL + 1))
  if [[ "$first_content_line" == "Apache License" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: LICENSE begins with 'Apache License'"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: LICENSE first content line is '$first_content_line', expected 'Apache License'"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: LICENSE file missing"
fi

# --- Summary ---
echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
