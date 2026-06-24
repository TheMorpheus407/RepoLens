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

# Tests for issue #317 — the `## Validation` evidence block contract in base
# prompt templates. Verifies that prompts/_base/audit.md and the default-mode
# local export in lib/template.sh both carry the six required snake_case fields,
# and that the greenfield/polish local-mode branches do NOT gain the block.
# Pure string/grep + a no-model compose_prompt render check.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/forge.sh"
source "$SCRIPT_DIR/lib/template.sh"

PASS=0
FAIL=0
TOTAL=0
TMPROOT="$SCRIPT_DIR/tests/.tmp"
mkdir -p "$TMPROOT"
TMPDIR="$(mktemp -d "$TMPROOT/validation-block-contract.XXXXXX")"
trap 'rm -rf "$TMPDIR"; rmdir "$TMPROOT" 2>/dev/null || true' EXIT

# The six required fields, in contract order. Field names are a hard contract —
# the downstream parser keys off them verbatim.
VALIDATION_FIELDS=(
  attacker_source
  missing_guard
  sink_effect
  preconditions
  proof_anchors
  suggested_validation
)

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (expected to contain: '$needle')"
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
    echo "  FAIL: $desc (did not expect: '$needle')"
  fi
}

cat > "$TMPDIR/lens.md" <<'EOF'
---
id: naming
domain: code-quality
name: Naming Lens
role: Test Role
---

## Your Expert Focus

Check naming problems.
EOF

# Render an audit-base prompt for a given mode/local-mode, with all forge
# placeholders resolved (so the only leftover content is real template text).
# No real agent is invoked — this is the --dry-run-equivalent render path.
render_local_prompt() {
  local mode="$1" local_mode="$2"
  local repo_slug="owner/repo"
  local project_path="$TMPDIR/local checkout"
  local label="audit:code-quality/naming"
  local color="ededed"
  local base_file="$SCRIPT_DIR/prompts/_base/audit.md"

  FORGE_PROVIDER="gh"
  FORGE_HOST="github.com"
  FORGE_REMOTE_NAME="origin"
  FORGE_PROJECT_PATH="$project_path"

  local vars=""
  vars="PROJECT_PATH=${project_path}"
  vars+="|DOMAIN=code-quality"
  vars+="|DOMAIN_NAME=Code Quality"
  vars+="|DOMAIN_COLOR=${color}"
  vars+="|LENS_ID=naming"
  vars+="|LENS_NAME=Naming Lens"
  vars+="|LENS_LABEL=${label}"
  vars+="|MODE=${mode}"
  vars+="|RUN_ID=test-run"
  vars+="|REPO_NAME=local checkout"
  vars+="|REPO_OWNER=owner"
  vars+="|FORGE_REPO_SLUG=${repo_slug}"
  vars+="|FORGE_ISSUE_CREATE=$(forge_prompt_issue_create "$label" "$repo_slug" "$project_path")"
  vars+="|FORGE_LABEL_CREATE=$(forge_prompt_label_create "$label" "$color" "$repo_slug" "$project_path")"
  vars+="|FORGE_ENHANCEMENT_LABEL_CREATE=$(forge_prompt_label_create "enhancement" "a2eeef" "$repo_slug" "$project_path")"
  vars+="|FORGE_ISSUE_LIST_OPEN=$(forge_prompt_issue_list "open" "$repo_slug" "$project_path")"
  vars+="|FORGE_ISSUE_LIST_CLOSED=$(forge_prompt_issue_list "closed" "$repo_slug" "$project_path")"

  # compose_prompt <base> <lens> <vars> <spec> <mode> <max_issues> <source> <hosted> <local_mode> <local_output_dir>
  compose_prompt "$base_file" "$TMPDIR/lens.md" "$vars" "" "$mode" "" "" "false" "$local_mode" "$TMPDIR/local-output"
}

# Isolate just the LOCAL MODE OVERRIDE section from a rendered prompt. The audit
# base body also carries the field tokens (the Issue Body Structure block), so
# negative/ordering checks on the local export must look ONLY at this section,
# which is the part driven by lib/template.sh's local_mode_section branch.
extract_local_section() {
  local rendered="$1"
  printf '%s' "## LOCAL MODE OVERRIDE${rendered##*## LOCAL MODE OVERRIDE}"
}

echo ""
echo "=== Test Suite: ## Validation evidence block contract (issue #317) ==="
echo ""

echo "--- Group 1: audit.md Issue Body Structure carries the block ---"
audit_md="$(cat "$SCRIPT_DIR/prompts/_base/audit.md")"
assert_contains "audit.md contains the ## Validation heading token" "## Validation" "$audit_md"
for field in "${VALIDATION_FIELDS[@]}"; do
  assert_contains "audit.md contains field '$field'" "$field" "$audit_md"
done

echo ""
echo "--- Group 2: default-mode local export render carries the block ---"
audit_local_section="$(extract_local_section "$(render_local_prompt "audit" "true")")"
assert_contains "default local section contains ## Validation" "## Validation" "$audit_local_section"
assert_contains "default local section still contains ## References" "## References" "$audit_local_section"
for field in "${VALIDATION_FIELDS[@]}"; do
  assert_contains "default local section contains field '$field'" "$field" "$audit_local_section"
done
# Ordering: in the local export, the Validation block must appear AFTER the
# References section. Check that the text following the last ## References still
# contains ## Validation.
after_refs="${audit_local_section##*## References}"
assert_contains "## Validation appears after ## References in local export" "## Validation" "$after_refs"

echo ""
echo "--- Group 3: non-local audit render (forge path) carries the block ---"
audit_forge="$(render_local_prompt "audit" "false")"
assert_contains "audit forge render contains ## Validation" "## Validation" "$audit_forge"
for field in "${VALIDATION_FIELDS[@]}"; do
  assert_contains "audit forge render contains field '$field'" "$field" "$audit_forge"
done

echo ""
echo "--- Group 4: greenfield/polish local branches did NOT gain the block ---"
# Use a field token unique to this contract (attacker_source) for the negative
# guard — '## Validation' already exists unrelatedly in meta_orchestrator.md.
# Scope to the local-mode section so the audit base body (which legitimately
# carries the fields) does not contaminate the check.
greenfield_section="$(extract_local_section "$(render_local_prompt "greenfield" "true")")"
polish_section="$(extract_local_section "$(render_local_prompt "polish" "true")")"
assert_not_contains "greenfield local branch lacks attacker_source" "attacker_source" "$greenfield_section"
assert_not_contains "greenfield local branch lacks proof_anchors" "proof_anchors" "$greenfield_section"
assert_not_contains "polish local branch lacks attacker_source" "attacker_source" "$polish_section"
assert_not_contains "polish local branch lacks suggested_validation" "suggested_validation" "$polish_section"

echo ""
echo "--- Group 5: per-field authoring guidance (#323) ---"
# audit.md must carry how-to-fill-it-well guidance for the #317 contract, with
# good/bad contrasts and the local-vs-external-scanner distinction the classifier
# keys off. Tokens here MUST match the literal prose in prompts/_base/audit.md.
assert_contains "audit.md has the How to Fill guidance section" "How to Fill the" "$audit_md"
assert_contains "audit.md requires path:line proof anchors" "path:line" "$audit_md"
assert_contains "audit.md has a Good: contrast example" "Good:" "$audit_md"
assert_contains "audit.md has a Bad: contrast example" "Bad:" "$audit_md"
assert_contains "audit.md names the 'locally validatable' state" "locally validatable" "$audit_md"
assert_contains "audit.md names the 'needs external scanner' state" "needs external scanner" "$audit_md"
assert_contains "audit.md states the distinction drives classification" "downstream classification" "$audit_md"
assert_contains "audit.md documents the n/a allowance" "n/a" "$audit_md"
assert_contains "audit.md documents the none allowance" "none" "$audit_md"
# The guidance must also reach agents in the rendered prompt, not just the file.
assert_contains "audit forge render carries path:line guidance" "path:line" "$audit_forge"
assert_contains "audit forge render carries locally validatable phrasing" "locally validatable" "$audit_forge"
assert_contains "audit forge render carries needs external scanner phrasing" "needs external scanner" "$audit_forge"

echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
