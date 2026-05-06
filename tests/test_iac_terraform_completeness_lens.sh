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

# Tests for issue #78: iac/terraform-completeness lens integration.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LENS_FILE="$SCRIPT_DIR/prompts/lenses/iac/terraform-completeness.md"
DOMAINS_FILE="$SCRIPT_DIR/config/domains.json"
COLORS_FILE="$SCRIPT_DIR/config/label-colors.json"

PASS=0
FAIL=0
TOTAL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    Expected: $expected"
    echo "    Actual:   $actual"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    Missing: $needle"
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

echo ""
echo "=== Test Suite: iac/terraform-completeness lens (issue #78) ==="
echo ""

assert_file_exists "terraform-completeness lens prompt exists" "$LENS_FILE"

lens_content=""
if [[ -f "$LENS_FILE" ]]; then
  lens_content="$(cat "$LENS_FILE")"
fi

echo ""
echo "Test 1: frontmatter is complete"
assert_contains "id frontmatter" "id: terraform-completeness" "$lens_content"
assert_contains "domain frontmatter" "domain: iac" "$lens_content"
assert_contains "name frontmatter" "name: Terraform Completeness Audit" "$lens_content"
assert_contains "role frontmatter" "role: Terraform Completeness Analyst" "$lens_content"

echo ""
echo "Test 2: body has required sections"
assert_contains "expert focus section" "## Your Expert Focus" "$lens_content"
assert_contains "hunt section" "### What You Hunt For" "$lens_content"
assert_contains "investigate section" "### How You Investigate" "$lens_content"

echo ""
echo "Test 3: prompt covers Terraform completeness risks"
for term in \
  "TODO" \
  "resource" \
  "module" \
  "count = 0" \
  "for_each = {}" \
  "variables.tf" \
  "outputs.tf" \
  "required_providers" \
  "backend" \
  "terraform.lock.hcl" \
  "terraform plan"; do
  assert_contains "prompt mentions $term" "$term" "$lens_content"
done

echo ""
echo "Test 4: prompt guards against unsafe Terraform execution"
for term in \
  "Reason statically by default" \
  'do not run `terraform init`' \
  'do not run `terraform plan`' \
  "provider downloads" \
  "module downloads" \
  "credentialed Terraform commands" \
  "no secrets" \
  "no network access"; do
  assert_contains "prompt safety guard mentions $term" "$term" "$lens_content"
done

echo ""
echo "Test 5: iac domain is registered once"
iac_domain_count="$(jq '[.domains[] | select(.id == "iac")] | length' "$DOMAINS_FILE")"
assert_eq "one iac domain" "1" "$iac_domain_count"

echo ""
echo "Test 6: iac domain is mode-less default audit coverage"
iac_mode="$(jq -r '.domains[] | select(.id == "iac") | .mode // "null"' "$DOMAINS_FILE")"
assert_eq "no mode field" "null" "$iac_mode"

echo ""
echo "Test 7: iac domain contains terraform-completeness"
iac_lenses="$(jq -r '.domains[] | select(.id == "iac") | .lenses | join(",")' "$DOMAINS_FILE")"
assert_eq "registered lens list" "terraform-completeness,terraform-security,iac-secrets,iac-networking" "$iac_lenses"

echo ""
echo "Test 8: iac label color is configured"
iac_color="$(jq -r '.iac // empty' "$COLORS_FILE")"
assert_eq "iac label color" "844fba" "$iac_color"

echo ""
echo "Test 9: Audit-like mode resolution includes the iac lens"
audit_lenses="$(jq -r --arg mode "audit" \
  '.domains | sort_by(.order)[] | (if $mode == "discover" then select(.mode == "discover") elif $mode == "deploy" then select(.mode == "deploy") elif $mode == "opensource" then select(.mode == "opensource") elif $mode == "content" then select(.mode == "content") else select(.mode != "discover" and .mode != "deploy" and .mode != "opensource" and .mode != "content") end) | .id as $d | .lenses[] | $d + "/" + .' "$DOMAINS_FILE")"
if grep -qxF "iac/terraform-completeness" <<< "$audit_lenses"; then
  PASS=$((PASS + 1))
  TOTAL=$((TOTAL + 1))
  echo "  PASS: audit mode includes iac/terraform-completeness"
else
  FAIL=$((FAIL + 1))
  TOTAL=$((TOTAL + 1))
  echo "  FAIL: audit mode should include iac/terraform-completeness"
fi

echo ""
echo "Test 10: Exclusive modes do not include the iac lens"
for mode in discover deploy opensource content; do
  mode_lenses="$(jq -r --arg mode "$mode" \
    '.domains | sort_by(.order)[] | (if $mode == "discover" then select(.mode == "discover") elif $mode == "deploy" then select(.mode == "deploy") elif $mode == "opensource" then select(.mode == "opensource") elif $mode == "content" then select(.mode == "content") else select(.mode != "discover" and .mode != "deploy" and .mode != "opensource" and .mode != "content") end) | .id as $d | .lenses[] | $d + "/" + .' "$DOMAINS_FILE")"
  if grep -qxF "iac/terraform-completeness" <<< "$mode_lenses"; then
    FAIL=$((FAIL + 1))
    TOTAL=$((TOTAL + 1))
    echo "  FAIL: $mode mode should not include iac/terraform-completeness"
  else
    PASS=$((PASS + 1))
    TOTAL=$((TOTAL + 1))
    echo "  PASS: $mode mode excludes iac/terraform-completeness"
  fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi

exit 0
