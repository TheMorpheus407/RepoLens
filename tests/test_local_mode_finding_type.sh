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

# Issue #339 — the default-mode LOCAL MODE frontmatter contract must instruct
# lenses to EMIT a `type:` value from the closed six-member taxonomy, mirrored
# in prompts/_base/investigator.md and prompts/_base/bugreport.md, and the
# greenfield (priority) / polish (JSON) local-mode blocks must stay unchanged.
# NEVER invoke a real model — assert only on the composed prompt and static
# prompt files.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/core.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/template.sh"

PASS=0
FAIL=0
TOTAL=0

pass_with() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail_with() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; [[ -n "${2:-}" ]] && printf '    %s\n' "$2"; }

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Missing: $needle"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Unexpected: $needle"
  fi
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  (( FAIL == 0 )) || exit 1
}

# The closed taxonomy — read from config so the test fails loudly if the
# canonical ids ever drift away from what the contract emits.
TAXONOMY_IDS=(security-vulnerability reliability-bug performance-risk maintainability test-gap external-dependency)

lens_file="$SCRIPT_DIR/prompts/lenses/security/auth-session.md"
local_output_dir="$SCRIPT_DIR/logs/test-local-mode-finding-type-out"

base_vars=""
base_vars+="PROJECT_PATH=/tmp/repolens-finding-type-fixture"
base_vars+="|DOMAIN=security"
base_vars+="|DOMAIN_NAME=Security"
base_vars+="|DOMAIN_COLOR=ff0000"
base_vars+="|LENS_ID=auth-session"
base_vars+="|LENS_NAME=Auth & Session"
base_vars+="|LENS_LABEL=security:security/auth-session"
base_vars+="|RUN_ID=test-local-mode-finding-type"
base_vars+="|REPO_NAME=fixture-repo"
base_vars+="|REPO_OWNER=fixture-owner"
base_vars+="|FORGE_REPO_SLUG=fixture-owner/fixture-repo"
base_vars+="|FORGE_ISSUE_CREATE=fake-forge issue create"
base_vars+="|FORGE_LABEL_CREATE=fake-forge label create"
base_vars+="|FORGE_ENHANCEMENT_LABEL_CREATE=fake-forge label create enhancement"
base_vars+="|FORGE_ISSUE_LIST_OPEN=fake-forge issue list --state open"
base_vars+="|FORGE_ISSUE_LIST_CLOSED=fake-forge issue list --state closed"

# compose_prompt positional args:
#   1 base 2 lens 3 vars 4 spec 5 mode 6 max_issues 7 source 8 hosted
#   9 local_mode 10 local_output_dir
# Local mode requires arg 9 == "true" AND a non-empty arg 10.

echo "=== default-mode local frontmatter requires type: ==="

default_rendered="$(compose_prompt \
  "$SCRIPT_DIR/prompts/_base/audit.md" "$lens_file" "$base_vars" \
  "" "audit" "" "" "false" "true" "$local_output_dir")"

assert_contains "default local mode renders the LOCAL MODE OVERRIDE block" \
  "## LOCAL MODE OVERRIDE" "$default_rendered"
assert_not_contains "default local mode leaves no raw placeholder" \
  "{{LOCAL_MODE_SECTION}}" "$default_rendered"
assert_contains "default local frontmatter carries a type: field" \
  "type:" "$default_rendered"
for tid in "${TAXONOMY_IDS[@]}"; do
  assert_contains "default local frontmatter lists taxonomy value '$tid'" \
    "$tid" "$default_rendered"
done
assert_contains "default local frontmatter type: line keeps severity adjacency" \
  "severity: critical|high|medium|low
type: security-vulnerability|reliability-bug|performance-risk|maintainability|test-gap|external-dependency" \
  "$default_rendered"
assert_contains "default guidance states type is orthogonal to severity" \
  "orthogonal to severity" "$default_rendered"
assert_contains "default guidance names external-dependency as the CVE/scanner case" \
  "CVE" "$default_rendered"

echo ""
echo "=== greenfield local mode is unchanged (priority, no type:) ==="

greenfield_rendered="$(compose_prompt \
  "$SCRIPT_DIR/prompts/_base/greenfield.md" "$lens_file" "$base_vars" \
  "" "greenfield" "" "" "false" "true" "$local_output_dir")"

assert_contains "greenfield local mode renders the LOCAL MODE OVERRIDE block" \
  "## LOCAL MODE OVERRIDE" "$greenfield_rendered"
assert_contains "greenfield local frontmatter still carries priority:" \
  "priority: P0|P1|P2|P3" "$greenfield_rendered"
assert_not_contains "greenfield local mode does NOT add the type taxonomy" \
  "security-vulnerability|reliability-bug|performance-risk|maintainability|test-gap|external-dependency" \
  "$greenfield_rendered"

echo ""
echo "=== polish local mode is unchanged (JSON, no type:) ==="

polish_rendered="$(compose_prompt \
  "$SCRIPT_DIR/prompts/_base/polish.md" "$lens_file" "$base_vars" \
  "" "polish" "" "" "false" "true" "$local_output_dir")"

assert_contains "polish local mode renders the LOCAL MODE OVERRIDE block" \
  "## LOCAL MODE OVERRIDE" "$polish_rendered"
assert_contains "polish local mode still emits the JSON polish_family field" \
  "polish_family" "$polish_rendered"
assert_not_contains "polish local mode does NOT add the type taxonomy" \
  "security-vulnerability|reliability-bug|performance-risk|maintainability|test-gap|external-dependency" \
  "$polish_rendered"

echo ""
echo "=== investigator.md frontmatter mirrors the type: contract ==="

investigator_contents="$(cat "$SCRIPT_DIR/prompts/_base/investigator.md")"
assert_contains "investigator frontmatter carries a type: field" \
  "type: security-vulnerability | reliability-bug | performance-risk | maintainability | test-gap | external-dependency" \
  "$investigator_contents"
assert_contains "investigator guidance states type is orthogonal to severity" \
  "orthogonal to severity" "$investigator_contents"
for tid in "${TAXONOMY_IDS[@]}"; do
  assert_contains "investigator frontmatter lists taxonomy value '$tid'" \
    "$tid" "$investigator_contents"
done

echo ""
echo "=== bugreport.md frontmatter mirrors the type: contract ==="

bugreport_contents="$(cat "$SCRIPT_DIR/prompts/_base/bugreport.md")"
assert_contains "bugreport required-keys frontmatter carries a type: field" \
  "type: security-vulnerability | reliability-bug | performance-risk | maintainability | test-gap | external-dependency" \
  "$bugreport_contents"
assert_contains "bugreport guidance states type is orthogonal to severity" \
  "orthogonal to severity" "$bugreport_contents"
assert_contains "bugreport worked-example skeleton carries a type: value" \
  "type: reliability-bug" "$bugreport_contents"
for tid in "${TAXONOMY_IDS[@]}"; do
  assert_contains "bugreport frontmatter lists taxonomy value '$tid'" \
    "$tid" "$bugreport_contents"
done

finish
