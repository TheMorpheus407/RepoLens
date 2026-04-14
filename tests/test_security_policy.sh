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

# Tests for issue #18: Add SECURITY.md (responsible disclosure for RepoLens itself)
#
# These tests define the behavioral contract for the SECURITY.md policy:
# The file must contain a complete responsible disclosure policy with
# 48h acknowledgment, out-of-scope statement for tool-generated findings,
# explicit reporting channels, supported versions, and response timeline.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECURITY="$SCRIPT_DIR/SECURITY.md"
COC="$SCRIPT_DIR/CODE_OF_CONDUCT.md"
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
echo "=== Test Suite: SECURITY.md — Responsible Disclosure Policy (issue #18) ==="
echo ""

# =====================================================================
# 1. File existence and basic properties
# =====================================================================

echo "--- Section 1: File existence and basic properties ---"
echo ""

echo "Test 1: SECURITY.md exists at repo root"
assert_file_exists "SECURITY.md exists" "$SECURITY"

echo ""
echo "Test 2: SECURITY.md is not empty"
assert_file_not_empty "SECURITY.md is not empty" "$SECURITY"

security_content=""
if [[ -f "$SECURITY" ]]; then
  security_content="$(cat "$SECURITY")"
fi

echo ""
echo "Test 3: SECURITY.md is plain text markdown, not HTML or binary"
if [[ -f "$SECURITY" ]]; then
  TOTAL=$((TOTAL + 1))
  if ! grep -qP '\x00' "$SECURITY" 2>/dev/null && ! grep -qi '<html\|<head\|<body' "$SECURITY"; then
    PASS=$((PASS + 1))
    echo "  PASS: SECURITY.md is a text file"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: SECURITY.md appears to be binary or HTML"
  fi
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: file missing"
fi

echo ""
echo "Test 4: File ends with trailing newline"
if [[ -f "$SECURITY" ]]; then
  TOTAL=$((TOTAL + 1))
  last_byte="$(tail -c1 "$SECURITY" | od -An -tx1 | tr -d ' ')"
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
echo "Test 5: No conflicting security policy files"
TOTAL=$((TOTAL + 1))
conflicting=0
for f in "$SCRIPT_DIR/SECURITY.txt" "$SCRIPT_DIR/SECURITY.rst" "$SCRIPT_DIR/security.md"; do
  if [[ -f "$f" ]]; then
    conflicting=$((conflicting + 1))
  fi
done
if [[ "$conflicting" -eq 0 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: no conflicting security policy files"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: found $conflicting conflicting security policy file(s)"
fi

echo ""
echo "Test 6: No TODO/FIXME/placeholder markers in SECURITY.md"
TOTAL=$((TOTAL + 1))
markers_found=0
if [[ -f "$SECURITY" ]]; then
  if grep -qP '(TODO|FIXME|\[INSERT)' "$SECURITY"; then
    markers_found=1
  fi
fi
if [[ "$markers_found" -eq 0 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: no draft markers in SECURITY.md"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: found TODO/FIXME/[INSERT markers in SECURITY.md"
fi

# =====================================================================
# 2. Required sections exist
# =====================================================================

echo ""
echo "--- Section 2: Required sections ---"
echo ""

echo "Test 7: Has Security Policy heading"
assert_matches "Security Policy heading" "(?i)^# Security Policy" "$security_content"

echo ""
echo "Test 8: Has Reporting a Vulnerability section"
assert_matches "Reporting section" "(?i)## .*Reporting" "$security_content"

echo ""
echo "Test 9: Has Response Timeline section"
assert_matches "Response Timeline section" "(?i)(## .*Response|### .*Response|## .*Timeline|### .*Timeline)" "$security_content"

echo ""
echo "Test 10: Has Scope section"
assert_matches "Scope section" "(?i)## .*Scope" "$security_content"

echo ""
echo "Test 11: Has Supported Versions section"
assert_matches "Supported Versions section" "(?i)## .*Supported.*Version" "$security_content"

echo ""
echo "Test 12: Has Disclosure Policy section"
assert_matches "Disclosure Policy section" "(?i)## .*Disclosure" "$security_content"

# =====================================================================
# 3. Supported versions table (v0.1.x)
# =====================================================================

echo ""
echo "--- Section 3: Supported versions ---"
echo ""

echo "Test 13: Supported versions table lists v0.1.x"
assert_contains "v0.1.x in supported versions" "0.1.x" "$security_content"

echo ""
echo "Test 14: Supported versions table shows v0.1.x as supported"
assert_matches "v0.1.x marked as supported" "0\.1\.x.*Yes|0\.1\.x.*✅|0\.1\.x.*supported" "$security_content"

# =====================================================================
# 4. Reporting channel: GitHub Security Advisories + email
# =====================================================================

echo ""
echo "--- Section 4: Reporting channels ---"
echo ""

echo "Test 15: References GitHub Security Advisories as reporting channel"
assert_contains "GitHub Security Advisories mentioned" "Security Advisories" "$security_content"

echo ""
echo "Test 16: Links to GitHub private vulnerability reporting page"
assert_contains "private vulnerability reporting link" "security/advisories" "$security_content"

echo ""
echo "Test 17: Warns against opening public issues for vulnerabilities"
assert_matches "public issue warning" "(?i)(do not|don.t|never).*open.*public.*(issue|bug)" "$security_content"

echo ""
echo "Test 18: Provides explicit email address for reporting"
assert_matches "explicit email address" "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}" "$security_content"

echo ""
echo "Test 19: No vague contact language (regression guard)"
assert_not_contains "no vague GitHub profile contact wording" "through their GitHub profile" "$security_content"

echo ""
echo "Test 20: Email is consistent with CODE_OF_CONDUCT.md contact"
if [[ -f "$COC" ]]; then
  coc_content="$(cat "$COC")"
  TOTAL=$((TOTAL + 1))
  coc_email="$(echo "$coc_content" | grep -oP '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' | head -1)"
  if [[ -n "$coc_email" ]]; then
    if echo "$security_content" | grep -qF "$coc_email"; then
      PASS=$((PASS + 1))
      echo "  PASS: SECURITY.md uses same email ($coc_email) as CODE_OF_CONDUCT.md"
    else
      FAIL=$((FAIL + 1))
      echo "  FAIL: SECURITY.md does not use the same email as CODE_OF_CONDUCT.md ($coc_email)"
    fi
  else
    PASS=$((PASS + 1))
    echo "  PASS: CODE_OF_CONDUCT.md has no email to compare (skip consistency check)"
  fi
else
  TOTAL=$((TOTAL + 1))
  PASS=$((PASS + 1))
  echo "  PASS: CODE_OF_CONDUCT.md not found (skip consistency check)"
fi

# =====================================================================
# 5. Response timeline: 48h acknowledgment, 7d triage
# =====================================================================

echo ""
echo "--- Section 5: Response timeline ---"
echo ""

echo "Test 21: Acknowledgment timeline is 48 hours (not 72)"
assert_matches "48-hour acknowledgment" "(?i)48\s*hours" "$security_content"

echo ""
echo "Test 22: Does NOT promise 72-hour acknowledgment (superseded by 48h)"
assert_not_contains "no 72h acknowledgment" "72 hours" "$security_content"

echo ""
echo "Test 23: Assessment/triage timeline includes 1 week or 7 days"
assert_matches "1-week assessment timeline" "(?i)(1\s*week|7\s*days|one\s*week)" "$security_content"

echo ""
echo "Test 24: Has fix/mitigation timeline statement"
assert_matches "fix/mitigation timeline" "(?i)(fix|mitigation|patch|remedia)" "$security_content"

# =====================================================================
# 6. Scope statement: RepoLens vulns vs. third-party findings
# =====================================================================

echo ""
echo "--- Section 6: Scope — in-scope vs. out-of-scope ---"
echo ""

echo "Test 25: Scope covers the CLI tool (repolens.sh)"
assert_matches "CLI tool in scope" "(?i)(repolens\.sh|CLI tool|cli)" "$security_content"

echo ""
echo "Test 26: Scope covers libraries (lib/)"
assert_matches "libraries in scope" "(?i)(lib/|libraries)" "$security_content"

echo ""
echo "Test 27: Scope covers prompt templates (prompts/)"
assert_matches "prompts in scope" "(?i)(prompts?/|prompt templates)" "$security_content"

echo ""
echo "Test 28: Scope covers configuration (config/)"
assert_matches "config in scope" "(?i)(config/|configuration)" "$security_content"

echo ""
echo "Test 29: Out of Scope has its own subsection heading"
assert_matches "Out of Scope heading" "(?i)###?\s*Out\s*of\s*Scope" "$security_content"

echo ""
echo "Test 30: Explicit out-of-scope statement for tool-generated findings"
TOTAL=$((TOTAL + 1))
if echo "$security_content" | grep -qiP '(out.of.scope|not.*(in\s*scope|covered|qualif)|findings.*(not|are not|do not)|not.*vulnerabilit.*(in|about|of)\s*(analyzed|third|other|target))'; then
  PASS=$((PASS + 1))
  echo "  PASS: has out-of-scope statement"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: missing explicit out-of-scope statement for tool-generated findings"
  echo "    Expected: statement clarifying that findings the tool generates about third-party code are NOT in scope"
fi

echo ""
echo "Test 31: Out-of-scope mentions findings/issues generated about analyzed/third-party code"
assert_matches "third-party findings excluded" "(?i)(finding|issue|report|result).*((generat|produc|creat|identif).*by.*RepoLens|(analyz|third.party|target|other).*(code|repo|project))" "$security_content"

# =====================================================================
# 7. Security considerations (existing valuable content)
# =====================================================================

echo ""
echo "--- Section 7: Security considerations ---"
echo ""

echo "Test 32: Mentions audit mode"
assert_matches "audit mode documented" "(?i)audit\s*mode" "$security_content"

echo ""
echo "Test 33: Mentions deploy mode"
assert_matches "deploy mode documented" "(?i)deploy\s*mode" "$security_content"

echo ""
echo "Test 34: Warns about --dangerously-skip-permissions"
assert_contains "dangerously-skip-permissions warning" "dangerously-skip-permissions" "$security_content"

echo ""
echo "Test 35: Mentions prompt injection risks"
assert_matches "prompt injection risk" "(?i)prompt.*(injection|inject)" "$security_content"

# =====================================================================
# 8. Disclosure policy
# =====================================================================

echo ""
echo "--- Section 8: Disclosure policy ---"
echo ""

echo "Test 36: Has coordinated disclosure statement"
assert_matches "coordinated disclosure" "(?i)coordinated\s*(disclosure|vulnerabilit)" "$security_content"

echo ""
echo "Test 37: Asks reporters to give reasonable time before public disclosure"
assert_matches "reasonable time for fix" "(?i)(reasonable\s*time|before\s*public|responsible)" "$security_content"

# =====================================================================
# 9. What to include in reports
# =====================================================================

echo ""
echo "--- Section 9: Reporter guidance ---"
echo ""

echo "Test 38: Tells reporters what to include"
assert_matches "what to include section" "(?i)(what to include|when reporting|include.*following|your report)" "$security_content"

echo ""
echo "Test 39: Mentions including steps to reproduce"
assert_matches "reproduction steps guidance" "(?i)(steps.*reproduc|reproduc.*steps|how to reproduc)" "$security_content"

echo ""
echo "Test 40: Mentions including impact assessment"
assert_matches "impact guidance" "(?i)(impact|severity|consequence)" "$security_content"

# =====================================================================
# 10. Cross-references from other files
# =====================================================================

echo ""
echo "--- Section 10: Cross-references ---"
echo ""

echo "Test 41: README.md references SECURITY.md"
if [[ -f "$README" ]]; then
  readme_content="$(cat "$README")"
  TOTAL=$((TOTAL + 1))
  if echo "$readme_content" | grep -qiP '(SECURITY\.md|security policy|report.*vulnerabilit)'; then
    PASS=$((PASS + 1))
    echo "  PASS: README references SECURITY.md or security policy"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: README does not reference SECURITY.md"
  fi
else
  TOTAL=$((TOTAL + 1))
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
