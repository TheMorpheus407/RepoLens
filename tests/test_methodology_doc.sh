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

# Tests for issue #12: METHODOLOGY.md v0.1 stub
# Validates that METHODOLOGY.md exists with all required sections, correct labeling,
# citation, and cross-referenced numbers matching the actual codebase.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
METHODOLOGY="$SCRIPT_DIR/METHODOLOGY.md"
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
echo "=== Test Suite: METHODOLOGY.md v0.1 stub (issue #12) ==="
echo ""

# =====================================================================
# 1. File existence and basic properties
# =====================================================================

echo "Test 1: METHODOLOGY.md exists at repo root"
assert_file_exists "METHODOLOGY.md file exists" "$METHODOLOGY"

echo ""
echo "Test 2: METHODOLOGY.md is not empty"
assert_file_not_empty "METHODOLOGY.md is not empty" "$METHODOLOGY"

# Read content (guard against missing file)
methodology_content=""
if [[ -f "$METHODOLOGY" ]]; then
  methodology_content="$(cat "$METHODOLOGY")"
fi

# =====================================================================
# 2. v0.1 labeling — must be explicitly marked as draft/stub
# =====================================================================

echo ""
echo "Test 3: METHODOLOGY.md contains v0.1 version label"
assert_contains "contains 'v0.1'" "v0.1" "$methodology_content"

echo ""
echo "Test 4: METHODOLOGY.md is clearly labeled as draft/stub"
assert_matches "labeled as draft, stub, or work-in-progress" "(?i)(draft|stub|work.in.progress|living document|preliminary)" "$methodology_content"

# =====================================================================
# 3. All 8 required sections present as headings
# =====================================================================

echo ""
echo "Test 5: Section — Abstract"
assert_matches "has Abstract heading" "(?im)^#{1,3}\s+.*abstract" "$methodology_content"

echo ""
echo "Test 6: Section — Core concept (Lensing / LBA)"
assert_matches "has Core Concept heading" "(?im)^#{1,3}\s+.*(core concept|lensing|lens.based)" "$methodology_content"

echo ""
echo "Test 7: Section — Why LBA differs from monolithic review"
assert_matches "has LBA vs monolithic heading" "(?im)^#{1,3}\s+.*(differ|monolithic|vs\.?\s|comparison|versus)" "$methodology_content"

echo ""
echo "Test 8: Section — DONE x3 streak protocol"
assert_matches "has DONE streak heading" "(?im)^#{1,3}\s+.*(done|streak)" "$methodology_content"

echo ""
echo "Test 9: Section — Parallel agent execution"
assert_matches "has Parallel execution heading" "(?im)^#{1,3}\s+.*(parallel|execution|concurrent)" "$methodology_content"

echo ""
echo "Test 10: Section — Mode isolation"
assert_matches "has Mode isolation heading" "(?im)^#{1,3}\s+.*(mode|isolation)" "$methodology_content"

echo ""
echo "Test 11: Section — Future Work"
assert_matches "has Future Work heading" "(?im)^#{1,3}\s+.*future" "$methodology_content"

echo ""
echo "Test 12: Section — Citation"
assert_matches "has Citation heading" "(?im)^#{1,3}\s+.*(citation|credit|attribution)" "$methodology_content"

# =====================================================================
# 4. Citation content — must credit Cedric Moessner and Bootstrap Academy
# =====================================================================

echo ""
echo "Test 13: Citation contains 'Created by Cedric Moessner.'"
assert_contains "contains citation credit line" "Created by Cedric Moessner." "$methodology_content"

echo ""
echo "Test 14: Citation mentions Bootstrap Academy"
assert_contains "mentions Bootstrap Academy" "Bootstrap Academy" "$methodology_content"

# =====================================================================
# 5. Core terminology — key concepts must be mentioned
# =====================================================================

echo ""
echo "Test 15: Mentions 'Lensing' as a concept"
assert_contains "mentions Lensing" "Lensing" "$methodology_content"

echo ""
echo "Test 16: Mentions 'Lens-Based Auditing' or 'LBA'"
assert_matches "mentions LBA" "(Lens-Based Auditing|LBA)" "$methodology_content"

echo ""
echo "Test 17: Mentions 'lens' in the context of the methodology"
assert_matches "mentions lens/lenses" "(?i)\blens(es)?\b" "$methodology_content"

# =====================================================================
# 6. Cross-reference checks — numbers must match codebase
# =====================================================================

echo ""
echo "Test 18: Lens count matches codebase"
actual_lens_count="$(jq '[.domains[].lenses | length] | add' "$DOMAINS_FILE")"
assert_contains "contains actual lens count ($actual_lens_count)" "$actual_lens_count" "$methodology_content"

echo ""
echo "Test 19: Domain count matches codebase"
actual_domain_count="$(jq '.domains | length' "$DOMAINS_FILE")"
assert_contains "contains actual domain count ($actual_domain_count)" "$actual_domain_count" "$methodology_content"

echo ""
echo "Test 20: Mode count — mentions 8 modes"
assert_matches "mentions 8 modes" "8\s+mode" "$methodology_content"

# =====================================================================
# 7. DONE x3 streak content — section must explain the protocol
# =====================================================================

echo ""
echo "Test 21: DONE streak section mentions streak count (3)"
# The streak protocol requires 3 consecutive DONEs in audit/feature/bugfix modes
assert_matches "mentions streak count 3" "(3.*consecutive|three.*consecutive|DONE.*3|streak.*3|3.*streak|x3|×3)" "$methodology_content"

echo ""
echo "Test 22: DONE streak section explains termination"
assert_matches "explains termination" "(?i)(terminat|complet|exit|finish|stop)" "$methodology_content"

# =====================================================================
# 8. Mode isolation content — must reference the 8 modes
# =====================================================================

echo ""
echo "Test 23: Mode isolation references audit mode"
assert_contains "references audit mode" "audit" "$methodology_content"

echo ""
echo "Test 24: Mode isolation references deploy mode"
assert_contains "references deploy mode" "deploy" "$methodology_content"

echo ""
echo "Test 25: Mode isolation references discover mode"
assert_contains "references discover mode" "discover" "$methodology_content"

echo ""
echo "Test 26: Mode isolation references custom mode"
assert_contains "references custom mode" "custom" "$methodology_content"

echo ""
echo "Test 27: Mode isolation references opensource mode"
assert_contains "references opensource mode" "opensource" "$methodology_content"

echo ""
echo "Test 28: Mode isolation references content mode"
assert_contains "references content mode" "content" "$methodology_content"

echo ""
echo "Test 29: Mode isolation references feature mode"
assert_contains "references feature mode" "feature" "$methodology_content"

echo ""
echo "Test 30: Mode isolation references bugfix mode"
assert_contains "references bugfix mode" "bugfix" "$methodology_content"

# =====================================================================
# 9. Parallel execution content — must describe the model
# =====================================================================

echo ""
echo "Test 31: Parallel execution section mentions concurrency or parallelism"
assert_matches "mentions parallel/concurrent execution" "(?i)(parallel|concurrent|simultaneous)" "$methodology_content"

echo ""
echo "Test 32: Parallel execution section mentions semaphore or agent coordination"
assert_matches "mentions semaphore or coordination" "(?i)(semaphore|coordinat|independent|token)" "$methodology_content"

# =====================================================================
# 10. LBA vs monolithic content — must explain the difference
# =====================================================================

echo ""
echo "Test 33: Comparison section explains attention dilution or specialization advantage"
assert_matches "explains specialization advantage" "(?i)(dilut|speciali[sz]|narrow|focus|depth|shallow|breadth)" "$methodology_content"

# =====================================================================
# 11. File format and structure checks
# =====================================================================

echo ""
echo "Test 34: METHODOLOGY.md is plain text, not HTML or binary"
if [[ -f "$METHODOLOGY" ]]; then
  TOTAL=$((TOTAL + 1))
  if ! grep -qP '\x00' "$METHODOLOGY" 2>/dev/null && ! grep -qi '<html\|<head\|<body' "$METHODOLOGY"; then
    PASS=$((PASS + 1))
    echo "  PASS: METHODOLOGY.md is a text file"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: METHODOLOGY.md appears to be binary or HTML"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: METHODOLOGY.md missing"
fi

echo ""
echo "Test 35: METHODOLOGY.md has a top-level heading"
assert_matches "has H1 heading" "(?m)^#\s+" "$methodology_content"

echo ""
echo "Test 36: No conflicting methodology files"
TOTAL=$((TOTAL + 1))
conflicting_count=0
for f in "$SCRIPT_DIR/METHODOLOGY.txt" "$SCRIPT_DIR/methodology.md" "$SCRIPT_DIR/Methodology.md"; do
  if [[ -f "$f" ]] && [[ "$f" != "$METHODOLOGY" ]]; then
    conflicting_count=$((conflicting_count + 1))
  fi
done
if [[ "$conflicting_count" -eq 0 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: no conflicting methodology files"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: found $conflicting_count conflicting methodology file(s)"
fi

# =====================================================================
# 12. Minimum content depth — sections should not be empty stubs
# =====================================================================

echo ""
echo "Test 37: Document has meaningful length (at least 50 lines)"
if [[ -f "$METHODOLOGY" ]]; then
  line_count="$(wc -l < "$METHODOLOGY")"
  TOTAL=$((TOTAL + 1))
  if [[ "$line_count" -ge 50 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: METHODOLOGY.md has $line_count lines (>= 50)"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: METHODOLOGY.md has only $line_count lines (expected >= 50 for a meaningful stub)"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: METHODOLOGY.md missing"
fi

echo ""
echo "Test 38: Document has at least 8 headings (one per required section)"
if [[ -f "$METHODOLOGY" ]]; then
  heading_count="$(grep -cP '^#{1,3}\s+' "$METHODOLOGY")"
  TOTAL=$((TOTAL + 1))
  if [[ "$heading_count" -ge 8 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: METHODOLOGY.md has $heading_count headings (>= 8)"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: METHODOLOGY.md has only $heading_count headings (expected >= 8)"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: METHODOLOGY.md missing"
fi

# =====================================================================
# 13. Acceptance criterion — reader comprehension signals
# =====================================================================

echo ""
echo "Test 39: Explains WHAT lensing is"
assert_matches "explains what lensing is" "(?i)(examin|analyz|inspect|review|audit).*(single|narrow|specific|one|individual)" "$methodology_content"

echo ""
echo "Test 40: Explains WHY lensing works"
assert_matches "explains why lensing works" "(?i)(advantage|benefit|why|better|superior|effective|improve|enables)" "$methodology_content"

# =====================================================================
# 14. Mentions RepoLens by name
# =====================================================================

echo ""
echo "Test 41: Mentions RepoLens"
assert_contains "mentions RepoLens" "RepoLens" "$methodology_content"

# =====================================================================
# 15. Future Work section has content
# =====================================================================

echo ""
echo "Test 42: Future Work section has substantive content"
# Extract the Future Work section (from its heading to the next heading or end of file)
if [[ -f "$METHODOLOGY" ]]; then
  future_section="$(sed -n '/^#.*[Ff]uture/,/^#/p' "$METHODOLOGY" | head -n -1)"
  future_lines="$(echo "$future_section" | grep -c '[^[:space:]]' || true)"
  TOTAL=$((TOTAL + 1))
  if [[ "$future_lines" -ge 3 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: Future Work section has $future_lines non-empty lines (>= 3)"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: Future Work section has only $future_lines non-empty lines (expected >= 3)"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: METHODOLOGY.md missing"
fi

# =====================================================================
# 16. No stale or incorrect claims
# =====================================================================

echo ""
echo "Test 43: Does not claim wrong number of lenses"
actual_lens_count="$(jq '[.domains[].lenses | length] | add' "$DOMAINS_FILE")"
for wrong_count in 109 150 200 250 300; do
  if [[ "$wrong_count" -ne "$actual_lens_count" ]]; then
    assert_not_contains "no stale claim of $wrong_count lenses" "$wrong_count expert" "$methodology_content"
  fi
done

echo ""
echo "Test 44: Does not claim wrong number of modes"
for wrong_modes in "6 mode" "7 mode" "9 mode" "10 mode"; do
  assert_not_contains "no stale claim of $wrong_modes" "$wrong_modes" "$methodology_content"
done

# =====================================================================
# 17. Lens category breakdown — individual numbers must match codebase
# =====================================================================

echo ""
echo "Test 45: Toolgate lens count matches codebase"
toolgate_count="$(jq '[.domains[] | select(.id == "toolgate") | .lenses | length] | add' "$DOMAINS_FILE")"
assert_contains "contains toolgate lens count ($toolgate_count)" "$toolgate_count tool gate" "$methodology_content"

echo ""
echo "Test 46: Code analysis lens count matches codebase"
code_analysis_count="$(jq '[.domains[] | select(.mode == null or (.mode != "discover" and .mode != "deploy" and .mode != "opensource" and .mode != "content")) | select(.id != "toolgate") | .lenses | length] | add' "$DOMAINS_FILE")"
assert_contains "contains code analysis lens count ($code_analysis_count)" "$code_analysis_count code analysis" "$methodology_content"

echo ""
echo "Test 47: Discovery lens count matches codebase"
discover_count="$(jq '[.domains[] | select(.mode == "discover") | .lenses | length] | add' "$DOMAINS_FILE")"
assert_contains "contains discovery lens count ($discover_count)" "$discover_count" "$methodology_content"

echo ""
echo "Test 48: Deployment lens count matches codebase"
deploy_count="$(jq '[.domains[] | select(.mode == "deploy") | .lenses | length] | add' "$DOMAINS_FILE")"
assert_contains "contains deployment lens count ($deploy_count)" "$deploy_count" "$methodology_content"

echo ""
echo "Test 49: Open-source readiness lens count matches codebase"
oss_count="$(jq '[.domains[] | select(.mode == "opensource") | .lenses | length] | add' "$DOMAINS_FILE")"
assert_contains "contains open-source lens count ($oss_count)" "$oss_count" "$methodology_content"

echo ""
echo "Test 50: Content quality lens count matches codebase"
content_count="$(jq '[.domains[] | select(.mode == "content") | .lenses | length] | add' "$DOMAINS_FILE")"
assert_contains "contains content lens count ($content_count)" "$content_count" "$methodology_content"

# =====================================================================
# 18. Cross-referenced constants must match repolens.sh
# =====================================================================

REPOLENS_SH="$SCRIPT_DIR/repolens.sh"

echo ""
echo "Test 51: Safety cap (max iterations) matches source code"
max_iter="$(grep -oP 'MAX_ITERATIONS_PER_LENS=\K[0-9]+' "$REPOLENS_SH")"
assert_contains "contains safety cap value ($max_iter)" "$max_iter iterations" "$methodology_content"

echo ""
echo "Test 52: Default concurrency limit matches source code"
max_par="$(grep -oP '^MAX_PARALLEL=\K[0-9]+' "$REPOLENS_SH")"
assert_contains "contains concurrency default ($max_par)" "$max_par simultaneous" "$methodology_content"

# =====================================================================
# 19. Per-section content depth — critical sections must have substance
# =====================================================================

extract_section() {
  local heading_pattern="$1"
  sed -n "/^#.*${heading_pattern}/I,/^#/p" "$METHODOLOGY" | head -n -1
}

assert_section_depth() {
  local desc="$1" heading_pattern="$2" min_lines="$3"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$METHODOLOGY" ]]; then
    local section
    section="$(extract_section "$heading_pattern")"
    local nonempty
    nonempty="$(echo "$section" | grep -c '[^[:space:]]' || true)"
    if [[ "$nonempty" -ge "$min_lines" ]]; then
      PASS=$((PASS + 1))
      echo "  PASS: $desc ($nonempty lines >= $min_lines)"
    else
      FAIL=$((FAIL + 1))
      echo "  FAIL: $desc ($nonempty lines < $min_lines)"
    fi
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (file missing)"
  fi
}

echo ""
echo "Test 53: Abstract section has substantive content"
assert_section_depth "Abstract has >= 3 non-empty lines" "Abstract" 3

echo ""
echo "Test 54: Core Concept section has substantive content"
assert_section_depth "Core Concept has >= 5 non-empty lines" "Core Concept" 5

echo ""
echo "Test 55: Comparison section has substantive content"
assert_section_depth "LBA vs Monolithic has >= 5 non-empty lines" "Differ\|Monolithic" 5

echo ""
echo "Test 56: DONE streak section has substantive content"
assert_section_depth "DONE streak has >= 5 non-empty lines" "DONE" 5

echo ""
echo "Test 57: Parallel execution section has substantive content"
assert_section_depth "Parallel execution has >= 4 non-empty lines" "Parallel" 4

echo ""
echo "Test 58: Mode Isolation section has substantive content"
assert_section_depth "Mode Isolation has >= 5 non-empty lines" "Mode Isolation" 5

# =====================================================================
# 20. Section ordering — sections appear in the order specified by the issue
# =====================================================================

echo ""
echo "Test 59: Sections appear in the correct order"
TOTAL=$((TOTAL + 1))
if [[ -f "$METHODOLOGY" ]]; then
  abstract_line="$(grep -n -i '^#.*abstract' "$METHODOLOGY" | head -1 | cut -d: -f1)"
  core_line="$(grep -n -i '^#.*core concept' "$METHODOLOGY" | head -1 | cut -d: -f1)"
  compare_line="$(grep -n -i '^#.*differ\|^#.*monolithic' "$METHODOLOGY" | head -1 | cut -d: -f1)"
  streak_line="$(grep -n -i '^#.*done\|^#.*streak' "$METHODOLOGY" | head -1 | cut -d: -f1)"
  parallel_line="$(grep -n -i '^#.*parallel' "$METHODOLOGY" | head -1 | cut -d: -f1)"
  mode_line="$(grep -n -i '^#.*mode isolation' "$METHODOLOGY" | head -1 | cut -d: -f1)"
  future_line="$(grep -n -i '^#.*future' "$METHODOLOGY" | head -1 | cut -d: -f1)"
  citation_line="$(grep -n -i '^#.*citation' "$METHODOLOGY" | head -1 | cut -d: -f1)"

  if [[ "$abstract_line" -lt "$core_line" ]] && \
     [[ "$core_line" -lt "$compare_line" ]] && \
     [[ "$compare_line" -lt "$streak_line" ]] && \
     [[ "$streak_line" -lt "$parallel_line" ]] && \
     [[ "$parallel_line" -lt "$mode_line" ]] && \
     [[ "$mode_line" -lt "$future_line" ]] && \
     [[ "$future_line" -lt "$citation_line" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: sections appear in correct order"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: sections are out of order"
    echo "    Order found: Abstract=$abstract_line Core=$core_line Compare=$compare_line Streak=$streak_line Parallel=$parallel_line Mode=$mode_line Future=$future_line Citation=$citation_line"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: METHODOLOGY.md missing"
fi

# --- Summary ---
echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
