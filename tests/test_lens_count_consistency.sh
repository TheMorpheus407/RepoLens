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

# Tests for issue #252: lens-count claims in current docs must match
# config/domains.json and prompts/lenses/*.md.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOMAINS_FILE="$SCRIPT_DIR/config/domains.json"
PROMPTS_DIR="$SCRIPT_DIR/prompts/lenses"
README="$SCRIPT_DIR/README.md"
METHODOLOGY="$SCRIPT_DIR/METHODOLOGY.md"

PASS=0
FAIL=0
TOTAL=0

pass_with() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

fail_with() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
  [[ -n "${2:-}" ]] && printf '    %s\n' "$2"
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected: $expected; actual: ${actual:-<empty>}"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected to contain: $needle"
  fi
}

assert_matches() {
  local desc="$1" pattern="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if grep -qE -- "$pattern" <<< "$haystack"; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected to match: $pattern"
  fi
}

jq_sum_mode() {
  local mode="$1"
  jq -r --arg mode "$mode" '([.domains[] | select(.mode == $mode) | .lenses | length] | add) // 0' "$DOMAINS_FILE"
}

jq_domain_lenses() {
  local domain="$1"
  jq -r --arg domain "$domain" '.domains[] | select(.id == $domain) | .lenses | length' "$DOMAINS_FILE"
}

readme_content="$(cat "$README")"
methodology_content="$(cat "$METHODOLOGY")"

registry_total_lenses="$(jq -r '[.domains[].lenses | length] | add' "$DOMAINS_FILE")"
total_lenses="$(jq -r '[.domains[] | select(.mode != "polish") | .lenses | length] | add' "$DOMAINS_FILE")"
prompt_lenses="$(find "$PROMPTS_DIR" -type f -name '*.md' | wc -l | tr -d '[:space:]')"
domain_count="$(jq -r '[.domains[] | select(.mode != "polish")] | length' "$DOMAINS_FILE")"
default_domain_count="$(jq -r '[.domains[] | select((.mode // "default") as $mode | $mode != "discover" and $mode != "deploy" and $mode != "opensource" and $mode != "content" and $mode != "greenfield" and $mode != "polish")] | length' "$DOMAINS_FILE")"
default_lenses="$(jq -r '[.domains[] | select((.mode // "default") as $mode | $mode != "discover" and $mode != "deploy" and $mode != "opensource" and $mode != "content" and $mode != "greenfield" and $mode != "polish") | .lenses | length] | add' "$DOMAINS_FILE")"
toolgate_lenses="$(jq_domain_lenses "toolgate")"
logs_lenses="$(jq_domain_lenses "logs")"
code_and_logs_lenses="$((default_lenses - toolgate_lenses))"
code_analysis_lenses="$((code_and_logs_lenses - logs_lenses))"
discover_lenses="$(jq_sum_mode "discover")"
deploy_lenses="$(jq_sum_mode "deploy")"
deployment_lenses="$(jq_domain_lenses "deployment")"
android_lenses="$(jq_domain_lenses "android")"
opensource_lenses="$(jq_sum_mode "opensource")"
content_lenses="$(jq_sum_mode "content")"
greenfield_lenses="$(jq_sum_mode "greenfield")"

echo ""
echo "=== Test Suite: lens count consistency (issue #252) ==="
echo ""

echo "Test 1: config registry lens count matches prompt file count"
assert_eq "domains.json total lenses equals prompt files" "$registry_total_lenses" "$prompt_lenses"

echo ""
echo "Test 2: README headline lens/domain counts match registry"
assert_matches "README intro has exact lens/domain count" "^\\*\\*Multi-lens code audit tool\\.\\*\\* Runs ${total_lenses} specialist lenses across ${domain_count} domains" "$readme_content"

echo ""
echo "Test 3: README full-audit warning matches registry aggregates"
assert_contains "README default audit warning has exact visible count" "A default full audit runs **${default_lenses} audit-visible lenses across ${default_domain_count} code/toolgate/logs domains**." "$readme_content"
assert_contains "README total lens sentence has exact total" "RepoLens has ${total_lenses} lenses across ${domain_count} domains in total" "$readme_content"

echo ""
echo "Test 4: README mode table lens counts match registry"
for mode in audit feature bugfix bugreport custom; do
  assert_matches "README $mode row uses $default_lenses visible lenses" "^\\| \`${mode}\`[[:space:]]+\\|[^|]*\\| ${default_domain_count} code/toolgate/logs domains \\(${default_lenses} lenses\\)[[:space:]]*\\|" "$readme_content"
done
assert_matches "README discover row uses $discover_lenses lenses" "^\\| \`discover\`[[:space:]]+\\|[^|]*\\| \`discovery\` domain \\(${discover_lenses} lenses\\)[[:space:]]*\\|" "$readme_content"
assert_matches "README deploy row uses deployment/android counts" "^\\| \`deploy\`[[:space:]]+\\|[^|]*\\| \`deployment\` domain \\(${deployment_lenses} lenses\\) or \`android\` domain \\(${android_lenses} lenses\\)" "$readme_content"
assert_matches "README opensource row uses $opensource_lenses lenses" "^\\| \`opensource\`[[:space:]]+\\|[^|]*\\| \`open-source-readiness\` domain \\(${opensource_lenses} lenses\\)[[:space:]]*\\|" "$readme_content"
assert_matches "README content row uses $content_lenses lenses" "^\\| \`content\`[[:space:]]+\\|[^|]*\\| \`content-quality\` domain \\(${content_lenses} lenses\\)[[:space:]]*\\|" "$readme_content"
assert_matches "README greenfield row uses $greenfield_lenses lenses" "^\\| \`greenfield\`[[:space:]]+\\|[^|]*\\| \`greenfield\` domain \\(${greenfield_lenses} lenses\\)[[:space:]]*\\|" "$readme_content"

echo ""
echo "Test 5: README domain section counts match registry"
assert_contains "README domain section heading has exact totals" "## Domains & Lenses (${total_lenses} total across ${domain_count} domains)" "$readme_content"
assert_matches "README discovery domain row has exact count" "^\\| \\*\\*Product Discovery\\*\\*[[:space:]]+\\| \`discover\`[[:space:]]+\\| ${discover_lenses} lenses \\|" "$readme_content"
assert_matches "README deployment domain row has exact count" "^\\| \\*\\*Deployment\\*\\*[[:space:]]+\\| \`deploy\`[[:space:]]+\\| ${deployment_lenses} lenses \\|" "$readme_content"
assert_matches "README Android domain row has exact count" "^\\| \\*\\*Android\\*\\*[[:space:]]+\\| \`deploy\`[[:space:]]+\\| ${android_lenses} lenses \\|" "$readme_content"
assert_matches "README open-source domain row has exact count" "^\\| \\*\\*Open Source Readiness\\*\\*[[:space:]]+\\| \`opensource\`[[:space:]]+\\| ${opensource_lenses} lenses \\|" "$readme_content"
assert_matches "README content domain row has exact count" "^\\| \\*\\*Content Quality\\*\\*[[:space:]]+\\| \`content\`[[:space:]]+\\| ${content_lenses} lenses \\|" "$readme_content"
assert_matches "README greenfield domain row has exact count" "^\\| \\*\\*Greenfield Planning\\*\\*[[:space:]]+\\| \`greenfield\`[[:space:]]+\\| ${greenfield_lenses} lens \\|" "$readme_content"

echo ""
echo "Test 6: METHODOLOGY inventory counts match registry"
assert_contains "METHODOLOGY intro has exact lens/domain count" "decomposes the audit problem into ${total_lenses} narrow-focus specialist agents (\"lenses\") across ${domain_count} domains" "$methodology_content"
assert_contains "METHODOLOGY inventory has exact breakdown" "The current lens inventory spans ${domain_count} domains with ${total_lenses} total lenses, broken down as: ${code_and_logs_lenses} code analysis/audit-visible lenses (${code_analysis_lenses} code analysis plus ${logs_lenses} runtime log analysis) + ${toolgate_lenses} tool gate + ${discover_lenses} product discovery + ${deploy_lenses} deployment and Android audit + ${opensource_lenses} open-source readiness + ${content_lenses} content quality + ${greenfield_lenses} greenfield planning." "$methodology_content"

echo ""
echo "Test 7: METHODOLOGY mode table visible lens counts match registry"
for mode in audit feature bugfix bugreport custom; do
  mode_line="$(grep -E "^\| \*\*${mode}\*\*" "$METHODOLOGY" || true)"
  assert_contains "METHODOLOGY $mode row uses $default_lenses visible lenses" "| ${default_lenses}" "$mode_line"
done
assert_contains "METHODOLOGY discover row uses $discover_lenses lenses" "14 (discovery domain only)" "$methodology_content"
assert_contains "METHODOLOGY deploy row uses deployment/android counts" "\`deployment\` domain (${deployment_lenses} server lenses) or \`android\` domain (${android_lenses} Android lenses" "$methodology_content"
assert_contains "METHODOLOGY opensource row uses $opensource_lenses lenses" "${opensource_lenses} (open-source readiness only)" "$methodology_content"
assert_contains "METHODOLOGY content row uses $content_lenses lenses" "${content_lenses} (content quality only)" "$methodology_content"
assert_contains "METHODOLOGY greenfield row uses $greenfield_lenses lenses" "${greenfield_lenses} (greenfield planning only)" "$methodology_content"

echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
