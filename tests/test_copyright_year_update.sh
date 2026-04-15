#!/usr/bin/env bash
# Copyright 2025-2026 Bootstrap Academy
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

# Tests for issue #33: Verify and correct copyright year in NOTICE file
#
# Behavioral contract:
# 1. NOTICE file must contain "Copyright 2025-2026 Bootstrap Academy"
# 2. All .sh file headers (line 2) must contain "Copyright 2025-2026 Bootstrap Academy"
# 3. No stale "Copyright 2025 Bootstrap Academy" (without -2026) may remain
# 4. Existing test assertions in test_license_files.sh and test_license_headers.sh
#    must be updated to match the new year format
# 5. All copyright lines across the project must be consistent
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
echo "=== Test Suite: Copyright year update 2025 -> 2025-2026 (issue #33) ==="
echo ""

# Collect all .sh files
sh_files=()
for f in "$SCRIPT_DIR"/repolens.sh "$SCRIPT_DIR"/lib/*.sh "$SCRIPT_DIR"/tests/*.sh; do
  if [[ -f "$f" ]]; then
    sh_files+=("$f")
  fi
done

# =====================================================================
# 1. NOTICE file contains the updated copyright year range
# =====================================================================

notice_content=""
if [[ -f "$SCRIPT_DIR/NOTICE" ]]; then
  notice_content="$(cat "$SCRIPT_DIR/NOTICE")"
fi

echo "Test 1: NOTICE contains 'Copyright 2025-2026 Bootstrap Academy'"
assert_contains "NOTICE has updated copyright year range" \
  "Copyright 2025-2026 Bootstrap Academy" "$notice_content"

# =====================================================================
# 2. NOTICE does NOT contain stale single-year copyright
# =====================================================================

echo ""
echo "Test 2: NOTICE does not contain stale 'Copyright 2025 Bootstrap Academy'"
TOTAL=$((TOTAL + 1))
if [[ -f "$SCRIPT_DIR/NOTICE" ]]; then
  # Match "Copyright 2025 " (with trailing space) to avoid matching "Copyright 2025-2026"
  if grep -q "Copyright 2025 " "$SCRIPT_DIR/NOTICE"; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: NOTICE still contains stale 'Copyright 2025 ' (without -2026)"
  else
    PASS=$((PASS + 1))
    echo "  PASS: NOTICE has no stale single-year copyright"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: NOTICE file not found"
fi

# =====================================================================
# 3. Every .sh file header (line 2) has the updated copyright year
# =====================================================================

echo ""
echo "Test 3: Every .sh file has 'Copyright 2025-2026 Bootstrap Academy' on line 2"
TOTAL=$((TOTAL + 1))
wrong_year=()
for f in "${sh_files[@]}"; do
  line2="$(sed -n '2p' "$f")"
  if [[ "$line2" != "# Copyright 2025-2026 Bootstrap Academy" ]]; then
    wrong_year+=("$(basename "$f")")
  fi
done
if [[ "${#wrong_year[@]}" -eq 0 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: All ${#sh_files[@]} .sh files have the updated copyright year on line 2"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: ${#wrong_year[@]} file(s) do not have 'Copyright 2025-2026 Bootstrap Academy' on line 2:"
  for m in "${wrong_year[@]}"; do
    echo "    - $m"
  done
fi

# =====================================================================
# 4. No stale single-year copyright in any .sh file header
# =====================================================================

echo ""
echo "Test 4: No .sh file header contains stale 'Copyright 2025 ' (single year)"
TOTAL=$((TOTAL + 1))
stale_year=()
for f in "${sh_files[@]}"; do
  # Check first 5 lines for "Copyright 2025 " (trailing space = not followed by dash)
  if head -5 "$f" | grep -q "Copyright 2025 "; then
    stale_year+=("$(basename "$f")")
  fi
done
if [[ "${#stale_year[@]}" -eq 0 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: No .sh files have stale single-year copyright in headers"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: ${#stale_year[@]} file(s) still have stale 'Copyright 2025 ' in header:"
  for m in "${stale_year[@]}"; do
    echo "    - $m"
  done
fi

# =====================================================================
# 5. Zero stale "Copyright 2025 Bootstrap Academy" anywhere in codebase
# =====================================================================

echo ""
echo "Test 5: No stale 'Copyright 2025 Bootstrap Academy' in any .sh file or NOTICE"
TOTAL=$((TOTAL + 1))
stale_count=0
# Check NOTICE
if [[ -f "$SCRIPT_DIR/NOTICE" ]]; then
  count=$(grep -c "Copyright 2025 Bootstrap Academy" "$SCRIPT_DIR/NOTICE" 2>/dev/null) || count=0
  stale_count=$((stale_count + count))
fi
# Check all .sh files (skip this test file — it contains the stale pattern in assertions)
for f in "${sh_files[@]}"; do
  [[ "$f" == "${BASH_SOURCE[0]}" || "$(basename "$f")" == "test_copyright_year_update.sh" ]] && continue
  count=$(grep -c "Copyright 2025 Bootstrap Academy" "$f" 2>/dev/null) || count=0
  stale_count=$((stale_count + count))
done
if [[ "$stale_count" -eq 0 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: Zero stale 'Copyright 2025 Bootstrap Academy' found"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: Found $stale_count occurrence(s) of stale 'Copyright 2025 Bootstrap Academy'"
fi

# =====================================================================
# 6. All .sh file copyright lines are consistent with NOTICE
# =====================================================================

echo ""
echo "Test 6: All .sh file copyright lines match NOTICE copyright line"
TOTAL=$((TOTAL + 1))
notice_copyright=""
if [[ -f "$SCRIPT_DIR/NOTICE" ]]; then
  notice_copyright="$(grep -oP 'Copyright \S+ .+' "$SCRIPT_DIR/NOTICE" | head -1)"
fi
if [[ -z "$notice_copyright" ]]; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: Could not extract copyright line from NOTICE"
else
  mismatch=()
  for f in "${sh_files[@]}"; do
    header_copyright="$(head -5 "$f" | grep -oP 'Copyright \S+ .+' | head -1)"
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
# 7. test_license_files.sh assertion is updated
# =====================================================================

echo ""
echo "Test 7: test_license_files.sh asserts 'Copyright 2025-2026 Bootstrap Academy'"
TOTAL=$((TOTAL + 1))
tlf="$SCRIPT_DIR/tests/test_license_files.sh"
if [[ -f "$tlf" ]]; then
  if grep -q 'Copyright 2025-2026 Bootstrap Academy' "$tlf"; then
    PASS=$((PASS + 1))
    echo "  PASS: test_license_files.sh has updated copyright assertion"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: test_license_files.sh still asserts old copyright year"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: test_license_files.sh not found"
fi

# =====================================================================
# 8. test_license_headers.sh assertions are updated
# =====================================================================

echo ""
echo "Test 8: test_license_headers.sh asserts 'Copyright 2025-2026' (not just 2025)"
TOTAL=$((TOTAL + 1))
tlh="$SCRIPT_DIR/tests/test_license_headers.sh"
if [[ -f "$tlh" ]]; then
  # The file should contain 2025-2026 in its assertions and canonical header
  if grep -q 'Copyright 2025-2026' "$tlh"; then
    PASS=$((PASS + 1))
    echo "  PASS: test_license_headers.sh has updated copyright assertions"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: test_license_headers.sh does not contain 'Copyright 2025-2026'"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: test_license_headers.sh not found"
fi

# =====================================================================
# 9. test_license_headers.sh has no stale single-year assertions
# =====================================================================

echo ""
echo "Test 9: test_license_headers.sh has no stale 'Copyright 2025 ' in assertions"
TOTAL=$((TOTAL + 1))
if [[ -f "$tlh" ]]; then
  # Count lines with "Copyright 2025 " (trailing space, i.e. not followed by dash)
  # Exclude the script's own header (lines 1-14) to check only assertion content
  stale_assert_count=$(tail -n +15 "$tlh" | grep -c "Copyright 2025 " 2>/dev/null) || stale_assert_count=0
  if [[ "$stale_assert_count" -eq 0 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: test_license_headers.sh has no stale single-year assertions"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: test_license_headers.sh has $stale_assert_count stale 'Copyright 2025 ' assertion(s)"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: test_license_headers.sh not found"
fi

# =====================================================================
# 10. test_license_files.sh has no stale single-year assertion
# =====================================================================

echo ""
echo "Test 10: test_license_files.sh has no stale 'Copyright 2025 ' in assertions"
TOTAL=$((TOTAL + 1))
if [[ -f "$tlf" ]]; then
  stale_tlf_count=$(tail -n +15 "$tlf" | grep -c "Copyright 2025 " 2>/dev/null) || stale_tlf_count=0
  if [[ "$stale_tlf_count" -eq 0 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: test_license_files.sh has no stale single-year assertions"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: test_license_files.sh has $stale_tlf_count stale 'Copyright 2025 ' assertion(s)"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: test_license_files.sh not found"
fi

# =====================================================================
# 11. NOTICE structure preserved (first line is project name)
# =====================================================================

echo ""
echo "Test 11: NOTICE structure is preserved (first line is 'RepoLens')"
if [[ -f "$SCRIPT_DIR/NOTICE" ]]; then
  first_line="$(head -n1 "$SCRIPT_DIR/NOTICE")"
  TOTAL=$((TOTAL + 1))
  if [[ "$first_line" == "RepoLens" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: NOTICE first line is still 'RepoLens'"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: NOTICE first line is '$first_line', expected 'RepoLens'"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: NOTICE file not found"
fi

# =====================================================================
# 12. NOTICE copyright is on line 2 (structure preserved)
# =====================================================================

echo ""
echo "Test 12: NOTICE copyright line is on line 2"
TOTAL=$((TOTAL + 1))
if [[ -f "$SCRIPT_DIR/NOTICE" ]]; then
  line2="$(sed -n '2p' "$SCRIPT_DIR/NOTICE")"
  if [[ "$line2" == "Copyright 2025-2026 Bootstrap Academy" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: NOTICE line 2 is 'Copyright 2025-2026 Bootstrap Academy'"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: NOTICE line 2 is '$line2', expected 'Copyright 2025-2026 Bootstrap Academy'"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: NOTICE file not found"
fi

# =====================================================================
# 13. NOTICE still contains the license reference line (no accidental deletion)
# =====================================================================

echo ""
echo "Test 13: NOTICE still contains the Apache license reference line"
assert_contains "NOTICE has license reference" \
  "This product is licensed under the Apache License, Version 2.0." "$notice_content"

# =====================================================================
# 14. Copyright year format uses dash (2025-2026), not other separators
# =====================================================================

echo ""
echo "Test 14: NOTICE uses dash separator in year range (not comma, slash, etc.)"
TOTAL=$((TOTAL + 1))
if [[ -f "$SCRIPT_DIR/NOTICE" ]]; then
  if grep -qP "Copyright 2025-2026" "$SCRIPT_DIR/NOTICE"; then
    PASS=$((PASS + 1))
    echo "  PASS: NOTICE uses dash-separated year range"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: NOTICE does not use dash-separated year range '2025-2026'"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: NOTICE file not found"
fi

# =====================================================================
# 15. Existing test suites pass after the update (meta-test)
# =====================================================================

echo ""
echo "Test 15: test_license_files.sh passes (all its own assertions hold)"
TOTAL=$((TOTAL + 1))
if [[ -f "$tlf" ]]; then
  tlf_output=$(bash "$tlf" 2>&1)
  tlf_rc=$?
  if [[ "$tlf_rc" -eq 0 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: test_license_files.sh passes"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: test_license_files.sh fails (exit code $tlf_rc)"
    echo "$tlf_output" | grep -E '^\s*FAIL:' | head -5 | sed 's/^/    /'
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: test_license_files.sh not found"
fi

echo ""
echo "Test 16: test_license_headers.sh passes (all its own assertions hold)"
TOTAL=$((TOTAL + 1))
if [[ -f "$tlh" ]]; then
  tlh_output=$(bash "$tlh" 2>&1)
  tlh_rc=$?
  if [[ "$tlh_rc" -eq 0 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: test_license_headers.sh passes"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: test_license_headers.sh fails (exit code $tlh_rc)"
    echo "$tlh_output" | grep -E '^\s*FAIL:' | head -5 | sed 's/^/    /'
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: test_license_headers.sh not found"
fi

# --- Summary ---
echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
