#!/usr/bin/env bash
# Tests for the discover mode implementation
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/template.sh
source "$SCRIPT_DIR/lib/template.sh"

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
    echo "    Expected: $(echo "$expected" | head -3)"
    echo "    Actual:   $(echo "$actual" | head -3)"
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

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    Should not contain: $needle"
  fi
}

echo "=== Test Suite: discover mode ==="

DOMAINS_FILE="$SCRIPT_DIR/config/domains.json"
COLORS_FILE="$SCRIPT_DIR/config/label-colors.json"
LENSES_DIR="$SCRIPT_DIR/prompts/lenses"

# =====================================================================
# Mode isolation — jq filtering
# =====================================================================

echo ""
echo "Test 1: Discover mode resolves only discovery domain"
discover_lenses="$(jq -r --arg mode "discover" \
  '.domains | sort_by(.order)[] | (if $mode == "discover" then select(.mode == "discover") else select(.mode != "discover") end) | .id as $d | .lenses[] | $d + "/" + .' "$DOMAINS_FILE")"
discover_count="$(echo "$discover_lenses" | wc -l)"
assert_eq "discover lens count is 14" "14" "$discover_count"

echo ""
echo "Test 2: All discover lenses are in discovery domain"
non_discovery="$(echo "$discover_lenses" | grep -v "^discovery/" || true)"
assert_eq "no lenses outside discovery domain" "" "$non_discovery"

echo ""
echo "Test 3: Audit mode excludes discovery domain"
audit_lenses="$(jq -r --arg mode "audit" \
  '.domains | sort_by(.order)[] | (if $mode == "discover" then select(.mode == "discover") elif $mode == "deploy" then select(.mode == "deploy") elif $mode == "opensource" then select(.mode == "opensource") elif $mode == "content" then select(.mode == "content") else select(.mode != "discover" and .mode != "deploy" and .mode != "opensource" and .mode != "content") end) | .id as $d | .lenses[] | $d + "/" + .' "$DOMAINS_FILE")"
audit_discovery="$(echo "$audit_lenses" | grep "^discovery/" || true)"
assert_eq "no discovery lenses in audit mode" "" "$audit_discovery"

echo ""
echo "Test 4: Audit mode lens count matches domains.json"
audit_count="$(echo "$audit_lenses" | wc -l)"
expected_audit_count="$(jq '[.domains[] | select(.mode != "discover" and .mode != "deploy" and .mode != "opensource" and .mode != "content") | .lenses | length] | add' "$DOMAINS_FILE")"
assert_eq "audit lens count matches domains.json" "$expected_audit_count" "$audit_count"

echo ""
echo "Test 5: Feature mode excludes discovery domain"
feature_discovery="$(jq -r --arg mode "feature" \
  '.domains | sort_by(.order)[] | (if $mode == "discover" then select(.mode == "discover") else select(.mode != "discover") end) | .id' "$DOMAINS_FILE" | grep "^discovery$" || true)"
assert_eq "no discovery domain in feature mode" "" "$feature_discovery"

echo ""
echo "Test 6: Bugfix mode excludes discovery domain"
bugfix_discovery="$(jq -r --arg mode "bugfix" \
  '.domains | sort_by(.order)[] | (if $mode == "discover" then select(.mode == "discover") else select(.mode != "discover") end) | .id' "$DOMAINS_FILE" | grep "^discovery$" || true)"
assert_eq "no discovery domain in bugfix mode" "" "$bugfix_discovery"

# =====================================================================
# Focus lens isolation
# =====================================================================

echo ""
echo "Test 7: Focus on discover lens — discover mode finds it"
found="$(jq -r --arg lens "monetization" --arg mode "discover" \
  '.domains[] | (if $mode == "discover" then select(.mode == "discover") else select(.mode != "discover") end) | select(.lenses[] == $lens) | .id' "$DOMAINS_FILE" | head -1)"
assert_eq "monetization found in discover mode" "discovery" "$found"

echo ""
echo "Test 8: Focus on discover lens — audit mode rejects it"
found="$(jq -r --arg lens "monetization" --arg mode "audit" \
  '.domains[] | (if $mode == "discover" then select(.mode == "discover") else select(.mode != "discover") end) | select(.lenses[] == $lens) | .id' "$DOMAINS_FILE" | head -1)"
assert_eq "monetization not found in audit mode" "" "$found"

echo ""
echo "Test 9: Focus on audit lens — discover mode rejects it"
found="$(jq -r --arg lens "injection" --arg mode "discover" \
  '.domains[] | (if $mode == "discover" then select(.mode == "discover") else select(.mode != "discover") end) | select(.lenses[] == $lens) | .id' "$DOMAINS_FILE" | head -1)"
assert_eq "injection not found in discover mode" "" "$found"

# =====================================================================
# Domain filter isolation
# =====================================================================

echo ""
echo "Test 10: Domain filter — discover mode sees discovery domain"
found="$(jq -r --arg d "discovery" --arg mode "discover" \
  '.domains[] | (if $mode == "discover" then select(.mode == "discover") else select(.mode != "discover") end) | select(.id == $d) | .id' "$DOMAINS_FILE")"
assert_eq "discovery domain found in discover mode" "discovery" "$found"

echo ""
echo "Test 11: Domain filter — audit mode rejects discovery domain"
found="$(jq -r --arg d "discovery" --arg mode "audit" \
  '.domains[] | (if $mode == "discover" then select(.mode == "discover") else select(.mode != "discover") end) | select(.id == $d) | .id' "$DOMAINS_FILE")"
assert_eq "discovery domain not found in audit mode" "" "$found"

echo ""
echo "Test 12: Domain filter — discover mode rejects security domain"
found="$(jq -r --arg d "security" --arg mode "discover" \
  '.domains[] | (if $mode == "discover" then select(.mode == "discover") else select(.mode != "discover") end) | select(.id == $d) | .id' "$DOMAINS_FILE")"
assert_eq "security domain not found in discover mode" "" "$found"

# =====================================================================
# Config validation
# =====================================================================

echo ""
echo "Test 13: Discovery domain has mode field"
mode_val="$(jq -r '.domains[] | select(.id == "discovery") | .mode' "$DOMAINS_FILE")"
assert_eq "discovery domain mode is 'discover'" "discover" "$mode_val"

echo ""
echo "Test 14: Non-modal domains have no mode field"
mode_domains="$(jq -r '.domains[] | select(.mode != null) | select(.mode != "discover" and .mode != "deploy" and .mode != "opensource" and .mode != "content") | .id' "$DOMAINS_FILE")"
assert_eq "no non-modal domain has mode field" "" "$mode_domains"

echo ""
echo "Test 15: Discovery color exists"
color="$(jq -r '.discovery' "$COLORS_FILE")"
assert_eq "discovery color is 06d6a0" "06d6a0" "$color"

# =====================================================================
# Lens file validation
# =====================================================================

EXPECTED_LENSES="product-gaps integration-opportunities ux-improvements monetization developer-experience automation data-insights scale-readiness community-ecosystem competitive-edge accessibility-inclusion content-education ai-augmentation workflow-orchestration"

echo ""
echo "Test 16: All 14 lens files exist"
all_exist=true
for lens in $EXPECTED_LENSES; do
  if [[ ! -f "$LENSES_DIR/discovery/$lens.md" ]]; then
    all_exist=false
    TOTAL=$((TOTAL + 1))
    FAIL=$((FAIL + 1))
    echo "  FAIL: missing lens file: discovery/$lens.md"
  fi
done
if $all_exist; then
  TOTAL=$((TOTAL + 1))
  PASS=$((PASS + 1))
  echo "  PASS: all 14 lens files exist"
fi

echo ""
echo "Test 17: All lens files have correct frontmatter"
fm_ok=true
for lens in $EXPECTED_LENSES; do
  lens_file="$LENSES_DIR/discovery/$lens.md"
  fm_id="$(read_frontmatter "$lens_file" "id")"
  fm_domain="$(read_frontmatter "$lens_file" "domain")"
  fm_name="$(read_frontmatter "$lens_file" "name")"
  fm_role="$(read_frontmatter "$lens_file" "role")"

  if [[ "$fm_id" != "$lens" ]]; then
    fm_ok=false
    TOTAL=$((TOTAL + 1))
    FAIL=$((FAIL + 1))
    echo "  FAIL: $lens.md id mismatch: expected '$lens', got '$fm_id'"
  fi
  if [[ "$fm_domain" != "discovery" ]]; then
    fm_ok=false
    TOTAL=$((TOTAL + 1))
    FAIL=$((FAIL + 1))
    echo "  FAIL: $lens.md domain mismatch: expected 'discovery', got '$fm_domain'"
  fi
  if [[ -z "$fm_name" ]]; then
    fm_ok=false
    TOTAL=$((TOTAL + 1))
    FAIL=$((FAIL + 1))
    echo "  FAIL: $lens.md has empty name"
  fi
  if [[ -z "$fm_role" ]]; then
    fm_ok=false
    TOTAL=$((TOTAL + 1))
    FAIL=$((FAIL + 1))
    echo "  FAIL: $lens.md has empty role"
  fi
done
if $fm_ok; then
  TOTAL=$((TOTAL + 1))
  PASS=$((PASS + 1))
  echo "  PASS: all 14 lens files have correct frontmatter"
fi

echo ""
echo "Test 18: All lens files have required sections"
sections_ok=true
for lens in $EXPECTED_LENSES; do
  lens_file="$LENSES_DIR/discovery/$lens.md"
  body="$(read_body "$lens_file")"

  if [[ "$body" != *"## Your Expert Focus"* ]]; then
    sections_ok=false
    TOTAL=$((TOTAL + 1))
    FAIL=$((FAIL + 1))
    echo "  FAIL: $lens.md missing '## Your Expert Focus'"
  fi
  if [[ "$body" != *"### What You Explore"* ]]; then
    sections_ok=false
    TOTAL=$((TOTAL + 1))
    FAIL=$((FAIL + 1))
    echo "  FAIL: $lens.md missing '### What You Explore'"
  fi
  if [[ "$body" != *"### How You Investigate"* ]]; then
    sections_ok=false
    TOTAL=$((TOTAL + 1))
    FAIL=$((FAIL + 1))
    echo "  FAIL: $lens.md missing '### How You Investigate'"
  fi
done
if $sections_ok; then
  TOTAL=$((TOTAL + 1))
  PASS=$((PASS + 1))
  echo "  PASS: all 14 lens files have required sections"
fi

# =====================================================================
# Base template validation
# =====================================================================

echo ""
echo "Test 19: discover.md base template exists"
base_file="$SCRIPT_DIR/prompts/_base/discover.md"
if [[ -f "$base_file" ]]; then
  TOTAL=$((TOTAL + 1))
  PASS=$((PASS + 1))
  echo "  PASS: discover.md exists"
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: discover.md missing"
fi

echo ""
echo "Test 20: discover.md has effort-based title prefixes"
base_content="$(cat "$base_file")"
assert_contains "has [SMALL]" "[SMALL]" "$base_content"
assert_contains "has [MEDIUM]" "[MEDIUM]" "$base_content"
assert_contains "has [LARGE]" "[LARGE]" "$base_content"
assert_contains "has [XL]" "[XL]" "$base_content"
assert_not_contains "no [CRITICAL]" "[CRITICAL]" "$base_content"
assert_not_contains "no [HIGH]" "[HIGH]" "$base_content"
assert_not_contains "no [LOW]" "[LOW]" "$base_content"

echo ""
echo "Test 21: discover.md has enhancement label"
assert_contains "enhancement label" "enhancement" "$base_content"

echo ""
echo "Test 22: discover.md has all required body sections"
assert_contains "idea summary" "Idea Summary" "$base_content"
assert_contains "opportunity" "Opportunity" "$base_content"
assert_contains "current state" "Current State" "$base_content"
assert_contains "proposed implementation" "Proposed Implementation" "$base_content"
assert_contains "acceptance criteria" "Acceptance Criteria" "$base_content"
assert_contains "dependencies" "Dependencies" "$base_content"
assert_contains "risks" "Risks & Open Questions" "$base_content"

echo ""
echo "Test 23: discover.md has all required placeholders"
assert_contains "LENS_NAME" "{{LENS_NAME}}" "$base_content"
assert_contains "DOMAIN_NAME" "{{DOMAIN_NAME}}" "$base_content"
assert_contains "REPO_OWNER" "{{REPO_OWNER}}" "$base_content"
assert_contains "REPO_NAME" "{{REPO_NAME}}" "$base_content"
assert_contains "PROJECT_PATH" "{{PROJECT_PATH}}" "$base_content"
assert_contains "LENS_LABEL" "{{LENS_LABEL}}" "$base_content"
assert_contains "DOMAIN_COLOR" "{{DOMAIN_COLOR}}" "$base_content"
assert_contains "SPEC_SECTION" "{{SPEC_SECTION}}" "$base_content"
assert_contains "LENS_BODY" "{{LENS_BODY}}" "$base_content"
assert_contains "MAX_ISSUES_SECTION" "{{MAX_ISSUES_SECTION}}" "$base_content"

echo ""
echo "Test 24: discover.md DONE termination"
assert_contains "DONE termination" "output **DONE** as the very first word" "$base_content"

# =====================================================================
# Prompt composition
# =====================================================================

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# Create a minimal lens for testing
cat > "$TMPDIR/test-lens.md" <<'EOF'
---
id: test-lens
domain: discovery
name: Test Lens
role: Test Role
---

## Your Expert Focus

Test focus content here.
EOF

echo ""
echo "Test 25: compose_prompt with discover template"
result="$(compose_prompt "$base_file" "$TMPDIR/test-lens.md" "LENS_NAME=Test Lens|DOMAIN_NAME=Product Discovery|REPO_OWNER=test|REPO_NAME=test|PROJECT_PATH=/tmp|LENS_LABEL=discover:discovery/test-lens|DOMAIN_COLOR=06d6a0|DOMAIN=discovery|LENS_ID=test-lens|MODE=discover|RUN_ID=test" "" "discover" "")"
assert_contains "lens name substituted" "Test Lens" "$result"
assert_contains "lens body inserted" "Test focus content here" "$result"
assert_not_contains "no raw LENS_BODY placeholder" "{{LENS_BODY}}" "$result"
assert_not_contains "no raw SPEC_SECTION placeholder" "{{SPEC_SECTION}}" "$result"
assert_not_contains "no raw MAX_ISSUES_SECTION placeholder" "{{MAX_ISSUES_SECTION}}" "$result"

echo ""
echo "Test 26: compose_prompt with discover + spec"
cat > "$TMPDIR/test-spec.md" <<'EOF'
RepoLens is a multi-lens code audit tool.
EOF
result="$(compose_prompt "$base_file" "$TMPDIR/test-lens.md" "LENS_NAME=Test Lens|DOMAIN_NAME=Product Discovery|REPO_OWNER=test|REPO_NAME=test|PROJECT_PATH=/tmp|LENS_LABEL=discover:discovery/test-lens|DOMAIN_COLOR=06d6a0|DOMAIN=discovery|LENS_ID=test-lens|MODE=discover|RUN_ID=test" "$TMPDIR/test-spec.md" "discover" "")"
assert_contains "spec section present" "## Specification Reference" "$result"
assert_contains "discover framing" "brainstorming" "$result"
assert_contains "spec content" "multi-lens code audit tool" "$result"

# =====================================================================
# Mode validation in repolens.sh
# =====================================================================

echo ""
echo "Test 27: repolens.sh accepts discover mode"
if grep -q '|discover[|)]' "$SCRIPT_DIR/repolens.sh"; then
  TOTAL=$((TOTAL + 1))
  PASS=$((PASS + 1))
  echo "  PASS: discover in mode validation"
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: discover not in mode validation"
fi

echo ""
echo "Test 28: Usage text lists discover mode"
if grep -qF 'discover' "$SCRIPT_DIR/repolens.sh"; then
  TOTAL=$((TOTAL + 1))
  PASS=$((PASS + 1))
  echo "  PASS: discover in usage text"
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: discover not in usage text"
fi

echo ""
echo "Test 29: DONE streak is 1 for discover mode"
if grep -q 'MODE.*==.*discover.*DONE_STREAK_REQUIRED=1\|DONE_STREAK_REQUIRED=1.*MODE.*==.*discover' "$SCRIPT_DIR/repolens.sh" || \
   grep -A1 'MODE.*==.*discover' "$SCRIPT_DIR/repolens.sh" | grep -q 'DONE_STREAK_REQUIRED=1'; then
  TOTAL=$((TOTAL + 1))
  PASS=$((PASS + 1))
  echo "  PASS: discover mode triggers streak=1"
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: discover mode streak not set to 1"
fi

echo ""
echo "Test 30: Label prefix for discover mode exists"
if grep -q 'discover).*label_prefix="discover"' "$SCRIPT_DIR/repolens.sh" || \
   grep -A1 'discover)' "$SCRIPT_DIR/repolens.sh" | grep -q 'label_prefix="discover"'; then
  TOTAL=$((TOTAL + 1))
  PASS=$((PASS + 1))
  echo "  PASS: discover label prefix exists"
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: discover label prefix missing"
fi

# =====================================================================
# Summary
# =====================================================================

echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

[[ "$FAIL" -eq 0 ]] || exit 1
