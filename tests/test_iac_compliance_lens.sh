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

# Tests for issue #82: iac/iac-compliance lens integration.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LENS_FILE="$SCRIPT_DIR/prompts/lenses/iac/iac-compliance.md"
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
echo "=== Test Suite: iac/iac-compliance lens (issue #82) ==="
echo ""

assert_file_exists "iac-compliance lens prompt exists" "$LENS_FILE"

lens_content=""
if [[ -f "$LENS_FILE" ]]; then
  lens_content="$(cat "$LENS_FILE")"
fi

echo ""
echo "Test 1: frontmatter is complete"
assert_contains "id frontmatter" "id: iac-compliance" "$lens_content"
assert_contains "domain frontmatter" "domain: iac" "$lens_content"
assert_contains "name frontmatter" "name: Infrastructure Compliance" "$lens_content"
assert_contains "role frontmatter" "role: Infrastructure Compliance Analyst" "$lens_content"

echo ""
echo "Test 2: body has required sections"
assert_contains "expert focus section" "## Your Expert Focus" "$lens_content"
assert_contains "hunt section" "### What You Hunt For" "$lens_content"
assert_contains "investigate section" "### How You Investigate" "$lens_content"

echo ""
echo "Test 3: prompt covers IaC compliance risks"
for term in \
  "backup_retention_period" \
  "point-in-time recovery" \
  "CloudWatch" \
  "alarm actions" \
  "Environment" \
  "Team" \
  "Service" \
  "ManagedBy" \
  "default_tags" \
  "auto_minor_version_upgrade" \
  "preferred_maintenance_window" \
  "CloudTrail" \
  "aws_s3_bucket_versioning" \
  "aws_s3_bucket_server_side_encryption_configuration" \
  "aws_s3_bucket_lifecycle_configuration" \
  "WAF" \
  "aws_budgets_budget" \
  "SNS" \
  "access logging" \
  "Container Insights" \
  "Performance Insights" \
  "disaster recovery" \
  "CloudFormation" \
  "Pulumi" \
  "CDK"; do
  assert_contains "prompt mentions $term" "$term" "$lens_content"
done

echo ""
echo "Test 4: prompt guards against unsafe IaC execution"
for term in \
  "Reason statically by default" \
  'do not run `terraform init`' \
  'do not run `terraform plan`' \
  "provider downloads" \
  "module downloads" \
  "credentialed Terraform commands" \
  "credentialed cloud CLI commands" \
  "no secrets" \
  "no network access" \
  'do not run `pulumi preview`' \
  'do not run `pulumi up`' \
  'do not run `cdk synth`' \
  'do not run `cdk deploy`'; do
  assert_contains "prompt safety guard mentions $term" "$term" "$lens_content"
done

echo ""
echo "Test 5: prompt redacts compliance-sensitive evidence"
for term in \
  "Compliance evidence guard" \
  "account IDs" \
  "subscriber emails" \
  "SNS endpoints" \
  "runbook paths" \
  "Redact secret-bearing values" \
  "avoid exposing subscriber details" \
  "short fingerprint"; do
  assert_contains "prompt evidence guard mentions $term" "$term" "$lens_content"
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
echo "Test 9: Audit-like mode resolution includes iac-compliance"
audit_lenses="$(jq -r --arg mode "audit" \
  '.domains | sort_by(.order)[] | (if $mode == "discover" then select(.mode == "discover") elif $mode == "deploy" then select(.mode == "deploy") elif $mode == "opensource" then select(.mode == "opensource") elif $mode == "content" then select(.mode == "content") else select(.mode != "discover" and .mode != "deploy" and .mode != "opensource" and .mode != "content") end) | .id as $d | .lenses[] | $d + "/" + .' "$DOMAINS_FILE")"
if grep -qxF "iac/iac-compliance" <<< "$audit_lenses"; then
  PASS=$((PASS + 1))
  TOTAL=$((TOTAL + 1))
  echo "  PASS: audit mode includes iac/iac-compliance"
else
  FAIL=$((FAIL + 1))
  TOTAL=$((TOTAL + 1))
  echo "  FAIL: audit mode should include iac/iac-compliance"
fi

echo ""
echo "Test 10: Exclusive modes do not include iac-compliance"
for mode in discover deploy opensource content; do
  mode_lenses="$(jq -r --arg mode "$mode" \
    '.domains | sort_by(.order)[] | (if $mode == "discover" then select(.mode == "discover") elif $mode == "deploy" then select(.mode == "deploy") elif $mode == "opensource" then select(.mode == "opensource") elif $mode == "content" then select(.mode == "content") else select(.mode != "discover" and .mode != "deploy" and .mode != "opensource" and .mode != "content") end) | .id as $d | .lenses[] | $d + "/" + .' "$DOMAINS_FILE")"
  if grep -qxF "iac/iac-compliance" <<< "$mode_lenses"; then
    FAIL=$((FAIL + 1))
    TOTAL=$((TOTAL + 1))
    echo "  FAIL: $mode mode should not include iac/iac-compliance"
  else
    PASS=$((PASS + 1))
    TOTAL=$((TOTAL + 1))
    echo "  PASS: $mode mode excludes iac/iac-compliance"
  fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi

exit 0
