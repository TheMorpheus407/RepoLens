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

# Tests for issue #31: Add Apache 2.0 license headers to all shell source files
#
# Behavioral contract:
# 1. Every .sh file (lib, entry point, tests) must contain the Apache 2.0 boilerplate header
# 2. The header must appear after the shebang line, not before it
# 3. Copyright holder must be "Bootstrap Academy" (matching NOTICE file)
# 4. Copyright year must be 2025 (matching NOTICE file)
# 5. Header must be complete (not truncated) — both opening and closing lines present
# 6. Header must appear exactly once per file (no duplicates)
# 7. .md files must NOT receive headers (token cost for LLM prompts)
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

echo ""
echo "=== Test Suite: Apache 2.0 license headers in .sh files (issue #31) ==="
echo ""

# Collect all .sh files that must have headers
sh_files=()
for f in "$SCRIPT_DIR"/repolens.sh "$SCRIPT_DIR"/lib/*.sh "$SCRIPT_DIR"/tests/*.sh; do
  if [[ -f "$f" ]]; then
    sh_files+=("$f")
  fi
done

# =====================================================================
# 1. At least one .sh file exists (sanity check)
# =====================================================================

echo "Test 1: Repository contains .sh files to check"
TOTAL=$((TOTAL + 1))
if [[ "${#sh_files[@]}" -gt 0 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: Found ${#sh_files[@]} .sh files"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: No .sh files found"
fi

# =====================================================================
# 2. Every .sh file contains the Apache 2.0 license header
# =====================================================================

echo ""
echo "Test 2: Every .sh file contains 'Licensed under the Apache License'"
TOTAL=$((TOTAL + 1))
missing_header=()
for f in "${sh_files[@]}"; do
  # Check the first 20 lines for the license header
  if ! head -20 "$f" | grep -q "Licensed under the Apache License"; then
    missing_header+=("$(basename "$f")")
  fi
done
if [[ "${#missing_header[@]}" -eq 0 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: All ${#sh_files[@]} .sh files contain the Apache license header"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: ${#missing_header[@]} file(s) missing the Apache license header:"
  for m in "${missing_header[@]}"; do
    echo "    - $m"
  done
fi

# =====================================================================
# 3. Shebang is always on line 1 (header does not displace it)
# =====================================================================

echo ""
echo "Test 3: Every .sh file has '#!/usr/bin/env bash' on line 1"
TOTAL=$((TOTAL + 1))
bad_shebang=()
for f in "${sh_files[@]}"; do
  first_line="$(head -1 "$f")"
  if [[ "$first_line" != "#!/usr/bin/env bash" ]]; then
    bad_shebang+=("$(basename "$f")")
  fi
done
if [[ "${#bad_shebang[@]}" -eq 0 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: All .sh files have correct shebang on line 1"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: ${#bad_shebang[@]} file(s) have incorrect first line:"
  for m in "${bad_shebang[@]}"; do
    echo "    - $m"
  done
fi

# =====================================================================
# 4. Copyright holder is Bootstrap Academy in every header
# =====================================================================

echo ""
echo "Test 4: Every .sh file header names 'Bootstrap Academy' as copyright holder"
TOTAL=$((TOTAL + 1))
wrong_holder=()
for f in "${sh_files[@]}"; do
  if ! head -20 "$f" | grep -q "Copyright.*Bootstrap Academy"; then
    wrong_holder+=("$(basename "$f")")
  fi
done
if [[ "${#wrong_holder[@]}" -eq 0 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: All headers name Bootstrap Academy as copyright holder"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: ${#wrong_holder[@]} file(s) missing Bootstrap Academy copyright:"
  for m in "${wrong_holder[@]}"; do
    echo "    - $m"
  done
fi

# =====================================================================
# 5. Copyright year is 2025 (matching NOTICE file)
# =====================================================================

echo ""
echo "Test 5: Every .sh file header uses copyright year 2025"
TOTAL=$((TOTAL + 1))
wrong_year=()
for f in "${sh_files[@]}"; do
  if ! head -20 "$f" | grep -q "Copyright 2025"; then
    wrong_year+=("$(basename "$f")")
  fi
done
if [[ "${#wrong_year[@]}" -eq 0 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: All headers use copyright year 2025"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: ${#wrong_year[@]} file(s) missing copyright year 2025:"
  for m in "${wrong_year[@]}"; do
    echo "    - $m"
  done
fi

# =====================================================================
# 6. Header is complete — contains both opening and closing lines
# =====================================================================

echo ""
echo "Test 6: Every .sh file header is complete (has opening AND closing lines)"
TOTAL=$((TOTAL + 1))
incomplete_header=()
for f in "${sh_files[@]}"; do
  header_area="$(head -20 "$f")"
  has_opening=false
  has_closing=false
  if echo "$header_area" | grep -q 'Licensed under the Apache License, Version 2.0'; then
    has_opening=true
  fi
  if echo "$header_area" | grep -q 'limitations under the License'; then
    has_closing=true
  fi
  if [[ "$has_opening" != true || "$has_closing" != true ]]; then
    incomplete_header+=("$(basename "$f")")
  fi
done
if [[ "${#incomplete_header[@]}" -eq 0 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: All headers are complete (opening and closing lines present)"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: ${#incomplete_header[@]} file(s) have incomplete headers:"
  for m in "${incomplete_header[@]}"; do
    echo "    - $m"
  done
fi

# =====================================================================
# 7. Header contains the http://www.apache.org/licenses/LICENSE-2.0 URL
# =====================================================================

echo ""
echo "Test 7: Every .sh file header contains the Apache license URL"
TOTAL=$((TOTAL + 1))
missing_url=()
for f in "${sh_files[@]}"; do
  if ! head -20 "$f" | grep -q "http://www.apache.org/licenses/LICENSE-2.0"; then
    missing_url+=("$(basename "$f")")
  fi
done
if [[ "${#missing_url[@]}" -eq 0 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: All headers contain the Apache license URL"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: ${#missing_url[@]} file(s) missing the Apache license URL:"
  for m in "${missing_url[@]}"; do
    echo "    - $m"
  done
fi

# =====================================================================
# 8. Header contains the AS IS disclaimer
# =====================================================================

echo ""
echo "Test 8: Every .sh file header contains the 'AS IS' disclaimer"
TOTAL=$((TOTAL + 1))
missing_disclaimer=()
for f in "${sh_files[@]}"; do
  if ! head -20 "$f" | grep -q '"AS IS"'; then
    missing_disclaimer+=("$(basename "$f")")
  fi
done
if [[ "${#missing_disclaimer[@]}" -eq 0 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: All headers contain the 'AS IS' disclaimer"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: ${#missing_disclaimer[@]} file(s) missing the 'AS IS' disclaimer:"
  for m in "${missing_disclaimer[@]}"; do
    echo "    - $m"
  done
fi

# =====================================================================
# 9. No duplicate headers — license text appears exactly once per file
# =====================================================================

echo ""
echo "Test 9: License header text appears exactly once per file (no duplicates)"
TOTAL=$((TOTAL + 1))
duplicate_header=()
for f in "${sh_files[@]}"; do
  # Only check the header area (first 30 lines) to avoid false positives from
  # files that reference the header text in their body (test assertions, heredocs)
  comment_count="$(head -30 "$f" | grep -c '^# Licensed under the Apache License' 2>/dev/null || echo 0)"
  if [[ "$comment_count" -gt 1 ]]; then
    duplicate_header+=("$(basename "$f") (found $comment_count comment headers)")
  fi
done
if [[ "${#duplicate_header[@]}" -eq 0 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: No files have duplicate license headers"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: ${#duplicate_header[@]} file(s) have duplicate headers:"
  for m in "${duplicate_header[@]}"; do
    echo "    - $m"
  done
fi

# =====================================================================
# 10. Header does not contain personal name as copyright holder
# =====================================================================

echo ""
echo "Test 10: No .sh file header uses a personal name as copyright holder"
TOTAL=$((TOTAL + 1))
personal_name=()
for f in "${sh_files[@]}"; do
  header_area="$(head -5 "$f")"
  if echo "$header_area" | grep -q "Copyright.*Cedric"; then
    personal_name+=("$(basename "$f")")
  fi
  if echo "$header_area" | grep -q "Copyright.*Moessner"; then
    personal_name+=("$(basename "$f")")
  fi
done
if [[ "${#personal_name[@]}" -eq 0 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: No headers use a personal name as copyright holder"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: ${#personal_name[@]} file(s) use a personal name:"
  for m in "${personal_name[@]}"; do
    echo "    - $m"
  done
fi

# =====================================================================
# 11. Library files retain their descriptive comments after the header
# =====================================================================

echo ""
echo "Test 11: Library files retain their 'RepoLens' descriptive comments"
TOTAL=$((TOTAL + 1))
# Library files that should have "# RepoLens —" descriptive comments
lib_missing_desc=()
for f in "$SCRIPT_DIR"/lib/*.sh; do
  if [[ -f "$f" ]]; then
    if ! grep -q "^# RepoLens" "$f"; then
      lib_missing_desc+=("$(basename "$f")")
    fi
  fi
done
if [[ "${#lib_missing_desc[@]}" -eq 0 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: All library files retain their descriptive comments"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: ${#lib_missing_desc[@]} library file(s) lost their descriptive comments:"
  for m in "${lib_missing_desc[@]}"; do
    echo "    - $m"
  done
fi

# =====================================================================
# 12. Header is positioned after shebang (line 2+ starts with copyright)
# =====================================================================

echo ""
echo "Test 12: Copyright line appears on line 2 of every .sh file"
TOTAL=$((TOTAL + 1))
wrong_position=()
for f in "${sh_files[@]}"; do
  line2="$(sed -n '2p' "$f")"
  if [[ "$line2" != "# Copyright 2025 Bootstrap Academy" ]]; then
    wrong_position+=("$(basename "$f")")
  fi
done
if [[ "${#wrong_position[@]}" -eq 0 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: Copyright line is on line 2 of every .sh file"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: ${#wrong_position[@]} file(s) have the copyright line in wrong position:"
  for m in "${wrong_position[@]}"; do
    echo "    - $m"
  done
fi

# =====================================================================
# 13. The full 13-line header block is present (line count check)
# =====================================================================

echo ""
echo "Test 13: Header block spans 13 lines (standard Apache 2.0 boilerplate)"
TOTAL=$((TOTAL + 1))
wrong_length=()
for f in "${sh_files[@]}"; do
  # Count comment lines from line 2 up to the first blank or non-comment line
  header_lines=0
  line_num=0
  while IFS= read -r line; do
    line_num=$((line_num + 1))
    if [[ "$line_num" -lt 2 ]]; then continue; fi
    if [[ "$line" == "#"* ]]; then
      header_lines=$((header_lines + 1))
    else
      break
    fi
  done < "$f"
  if [[ "$header_lines" -ne 13 ]]; then
    wrong_length+=("$(basename "$f") (found $header_lines header comment lines)")
  fi
done
if [[ "${#wrong_length[@]}" -eq 0 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: All files have exactly 13 header comment lines"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: ${#wrong_length[@]} file(s) have wrong header line count:"
  for m in "${wrong_length[@]}"; do
    echo "    - $m"
  done
fi

# =====================================================================
# 14. Prompt .md files do NOT contain license headers (token cost)
# =====================================================================

echo ""
echo "Test 14: Prompt .md files do not contain Apache license headers"
TOTAL=$((TOTAL + 1))
md_with_header=()
for f in "$SCRIPT_DIR"/prompts/_base/*.md "$SCRIPT_DIR"/prompts/lenses/**/*.md; do
  if [[ -f "$f" ]]; then
    if head -20 "$f" | grep -q "Licensed under the Apache License"; then
      md_with_header+=("$(echo "$f" | sed "s|$SCRIPT_DIR/||")")
    fi
  fi
done
if [[ "${#md_with_header[@]}" -eq 0 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: No prompt .md files contain license headers"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: ${#md_with_header[@]} prompt .md file(s) have license headers (increases token cost):"
  for m in "${md_with_header[@]}"; do
    echo "    - $m"
  done
fi

# =====================================================================
# 15. Copyright line in headers matches NOTICE file
# =====================================================================

echo ""
echo "Test 15: Header copyright line matches NOTICE file content"
TOTAL=$((TOTAL + 1))
notice_copyright=""
if [[ -f "$SCRIPT_DIR/NOTICE" ]]; then
  notice_copyright="$(grep -oP 'Copyright \d+ .+' "$SCRIPT_DIR/NOTICE" | head -1)"
fi
if [[ -z "$notice_copyright" ]]; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: Could not extract copyright line from NOTICE file"
else
  mismatch=()
  for f in "${sh_files[@]}"; do
    header_copyright="$(head -5 "$f" | grep -oP 'Copyright \d+ .+' | head -1)"
    if [[ "$header_copyright" != "$notice_copyright" ]]; then
      mismatch+=("$(basename "$f")")
    fi
  done
  if [[ "${#mismatch[@]}" -eq 0 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: All headers match NOTICE copyright: '$notice_copyright'"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: ${#mismatch[@]} file(s) have copyright mismatch with NOTICE:"
    for m in "${mismatch[@]}"; do
      echo "    - $m"
    done
  fi
fi

# =====================================================================
# 16. repolens.sh entry point has the header
# =====================================================================

echo ""
echo "Test 16: repolens.sh (entry point) has the license header"
TOTAL=$((TOTAL + 1))
if [[ -f "$SCRIPT_DIR/repolens.sh" ]]; then
  if head -20 "$SCRIPT_DIR/repolens.sh" | grep -q "Licensed under the Apache License"; then
    PASS=$((PASS + 1))
    echo "  PASS: repolens.sh has the license header"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: repolens.sh is missing the license header"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: repolens.sh not found"
fi

# =====================================================================
# 17. All lib/*.sh files have the header
# =====================================================================

echo ""
echo "Test 17: All lib/*.sh files have the license header"
TOTAL=$((TOTAL + 1))
lib_missing=()
for f in "$SCRIPT_DIR"/lib/*.sh; do
  if [[ -f "$f" ]]; then
    if ! head -20 "$f" | grep -q "Licensed under the Apache License"; then
      lib_missing+=("$(basename "$f")")
    fi
  fi
done
if [[ "${#lib_missing[@]}" -eq 0 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: All library files have the license header"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: ${#lib_missing[@]} library file(s) missing the header:"
  for m in "${lib_missing[@]}"; do
    echo "    - $m"
  done
fi

# =====================================================================
# 18. All tests/*.sh files have the header
# =====================================================================

echo ""
echo "Test 18: All tests/*.sh files have the license header"
TOTAL=$((TOTAL + 1))
test_missing=()
for f in "$SCRIPT_DIR"/tests/*.sh; do
  if [[ -f "$f" ]]; then
    if ! head -20 "$f" | grep -q "Licensed under the Apache License"; then
      test_missing+=("$(basename "$f")")
    fi
  fi
done
if [[ "${#test_missing[@]}" -eq 0 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: All test files have the license header"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: ${#test_missing[@]} test file(s) missing the header:"
  for m in "${test_missing[@]}"; do
    echo "    - $m"
  done
fi

# =====================================================================
# 19. Header lines are proper bash comments (each starts with #)
# =====================================================================

echo ""
echo "Test 19: All header lines are proper bash comments (start with #)"
TOTAL=$((TOTAL + 1))
bad_comments=()
for f in "${sh_files[@]}"; do
  # Read lines 2 through 14 (the 13-line header block)
  line_num=0
  while IFS= read -r line; do
    line_num=$((line_num + 1))
    if [[ "$line_num" -lt 2 || "$line_num" -gt 14 ]]; then continue; fi
    if [[ "$line" != "#"* ]]; then
      bad_comments+=("$(basename "$f"):$line_num")
      break
    fi
  done < "$f"
done
if [[ "${#bad_comments[@]}" -eq 0 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: All header lines are proper bash comments"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: ${#bad_comments[@]} file(s) have non-comment lines in header area:"
  for m in "${bad_comments[@]}"; do
    echo "    - $m"
  done
fi

# =====================================================================
# 20. Header is followed by a blank line (separator before existing content)
# =====================================================================

echo ""
echo "Test 20: Header block is followed by a blank line separator"
TOTAL=$((TOTAL + 1))
no_separator=()
for f in "${sh_files[@]}"; do
  # Line 15 should be empty (after 1 shebang + 13 header lines)
  line15="$(sed -n '15p' "$f")"
  if [[ -n "$line15" ]]; then
    no_separator+=("$(basename "$f")")
  fi
done
if [[ "${#no_separator[@]}" -eq 0 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: All files have a blank line after the header block"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: ${#no_separator[@]} file(s) missing blank line separator after header:"
  for m in "${no_separator[@]}"; do
    echo "    - $m"
  done
fi

# =====================================================================
# 21. All files have IDENTICAL header blocks (cross-file consistency)
# =====================================================================

echo ""
echo "Test 21: All .sh files have identical header blocks (no per-file deviations)"
TOTAL=$((TOTAL + 1))
# Extract the canonical header from the first file and compare all others
canonical_header=""
deviated=()
for f in "${sh_files[@]}"; do
  # Extract lines 2-14 (the 13-line header block)
  file_header="$(sed -n '2,14p' "$f")"
  if [[ -z "$canonical_header" ]]; then
    canonical_header="$file_header"
  elif [[ "$file_header" != "$canonical_header" ]]; then
    deviated+=("$(basename "$f")")
  fi
done
if [[ "${#deviated[@]}" -eq 0 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: All ${#sh_files[@]} files have identical header blocks"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: ${#deviated[@]} file(s) have a header that differs from the canonical one:"
  for m in "${deviated[@]}"; do
    echo "    - $m"
  done
fi

# =====================================================================
# 22. Header matches the canonical Apache 2.0 boilerplate exactly
# =====================================================================

echo ""
echo "Test 22: Header text matches the canonical Apache 2.0 boilerplate"
TOTAL=$((TOTAL + 1))
# The canonical 13-line Apache 2.0 boilerplate (as a bash comment block)
read -r -d '' EXPECTED_HEADER << 'ENDOFHEADER' || true
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
ENDOFHEADER
canonical_mismatch=()
for f in "${sh_files[@]}"; do
  file_header="$(sed -n '2,14p' "$f")"
  if [[ "$file_header" != "$EXPECTED_HEADER" ]]; then
    canonical_mismatch+=("$(basename "$f")")
  fi
done
if [[ "${#canonical_mismatch[@]}" -eq 0 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: All files match the canonical Apache 2.0 boilerplate exactly"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: ${#canonical_mismatch[@]} file(s) do not match the canonical boilerplate:"
  for m in "${canonical_mismatch[@]}"; do
    echo "    - $m"
  done
fi

# --- Summary ---
echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
