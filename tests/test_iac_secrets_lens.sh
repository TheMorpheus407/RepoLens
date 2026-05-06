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

# Tests for issue #80: iac/iac-secrets lens integration.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LENS_FILE="$SCRIPT_DIR/prompts/lenses/iac/iac-secrets.md"
DOMAINS_FILE="$SCRIPT_DIR/config/domains.json"

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
echo "=== Test Suite: iac/iac-secrets lens (issue #80) ==="
echo ""

assert_file_exists "iac-secrets lens prompt exists" "$LENS_FILE"

lens_content=""
redaction_guard=""
if [[ -f "$LENS_FILE" ]]; then
  lens_content="$(cat "$LENS_FILE")"
  redaction_guard="$(grep -F "Secret reporting guard:" "$LENS_FILE")"
fi

echo ""
echo "Test 1: frontmatter is complete"
assert_contains "id frontmatter" "id: iac-secrets" "$lens_content"
assert_contains "domain frontmatter" "domain: iac" "$lens_content"
assert_contains "name frontmatter" "name: IaC Secrets & Sensitive Data Exposure" "$lens_content"
assert_contains "role frontmatter" "role: Infrastructure-as-Code Secrets Specialist" "$lens_content"

echo ""
echo "Test 2: body has required sections"
assert_contains "expert focus section" "## Your Expert Focus" "$lens_content"
assert_contains "hunt section" "### What You Hunt For" "$lens_content"
assert_contains "investigate section" "### How You Investigate" "$lens_content"

echo ""
echo "Test 3: prompt covers IaC secret exposure risks"
for term in \
  "terraform.tfvars" \
  "*.auto.tfvars" \
  "terraform.tfstate" \
  "terraform.tfstate.backup" \
  "sensitive = true" \
  "backend" \
  "encrypt = true" \
  "-var" \
  "TF_VAR_" \
  "Vault" \
  "AWS Secrets Manager" \
  "GCP Secret Manager" \
  "Azure Key Vault" \
  ".terraformrc" \
  "credentials.json"; do
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
echo "Test 5: prompt redacts secret-bearing evidence"
for term in \
  "Secret reporting guard" \
  "redact every secret-bearing value" \
  "Evidence may include file path, line number, key/variable/output/backend/resource name, secret type, and a short fingerprint" \
  "must never quote full secret values" \
  "Terraform state values" \
  "plaintext CI env values" \
  '<redacted>'; do
  assert_contains "prompt redaction guard mentions $term" "$term" "$redaction_guard"
done

for term in \
  '`terraform.tfvars`' \
  'Terraform state' \
  'backend credentials' \
  'CI `TF_VAR_*` values' \
  'provider credential files' \
  'inline provider credentials'; do
  assert_contains "prompt forbids copying full values from $term" "$term" "$redaction_guard"
done

echo ""
echo "Test 6: iac domain is registered once"
iac_domain_count="$(jq '[.domains[] | select(.id == "iac")] | length' "$DOMAINS_FILE")"
assert_eq "one iac domain" "1" "$iac_domain_count"

echo ""
echo "Test 7: iac domain is mode-less default audit coverage"
iac_mode="$(jq -r '.domains[] | select(.id == "iac") | .mode // "null"' "$DOMAINS_FILE")"
assert_eq "no mode field" "null" "$iac_mode"

echo ""
echo "Test 8: iac domain contains all five IaC lenses"
iac_lenses="$(jq -r '.domains[] | select(.id == "iac") | .lenses | join(",")' "$DOMAINS_FILE")"
assert_eq "registered lens list" "terraform-completeness,terraform-security,iac-secrets,iac-networking,iac-compliance" "$iac_lenses"

echo ""
echo "Test 9: Audit-like mode resolution includes iac-secrets"
audit_lenses="$(jq -r --arg mode "audit" \
  '.domains | sort_by(.order)[] | (if $mode == "discover" then select(.mode == "discover") elif $mode == "deploy" then select(.mode == "deploy") elif $mode == "opensource" then select(.mode == "opensource") elif $mode == "content" then select(.mode == "content") else select(.mode != "discover" and .mode != "deploy" and .mode != "opensource" and .mode != "content") end) | .id as $d | .lenses[] | $d + "/" + .' "$DOMAINS_FILE")"
if grep -qxF "iac/iac-secrets" <<< "$audit_lenses"; then
  PASS=$((PASS + 1))
  TOTAL=$((TOTAL + 1))
  echo "  PASS: audit mode includes iac/iac-secrets"
else
  FAIL=$((FAIL + 1))
  TOTAL=$((TOTAL + 1))
  echo "  FAIL: audit mode should include iac/iac-secrets"
fi

echo ""
echo "Test 10: Exclusive modes do not include iac-secrets"
for mode in discover deploy opensource content; do
  mode_lenses="$(jq -r --arg mode "$mode" \
    '.domains | sort_by(.order)[] | (if $mode == "discover" then select(.mode == "discover") elif $mode == "deploy" then select(.mode == "deploy") elif $mode == "opensource" then select(.mode == "opensource") elif $mode == "content" then select(.mode == "content") else select(.mode != "discover" and .mode != "deploy" and .mode != "opensource" and .mode != "content") end) | .id as $d | .lenses[] | $d + "/" + .' "$DOMAINS_FILE")"
  if grep -qxF "iac/iac-secrets" <<< "$mode_lenses"; then
    FAIL=$((FAIL + 1))
    TOTAL=$((TOTAL + 1))
    echo "  FAIL: $mode mode should not include iac/iac-secrets"
  else
    PASS=$((PASS + 1))
    TOTAL=$((TOTAL + 1))
    echo "  PASS: $mode mode excludes iac/iac-secrets"
  fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi

exit 0
