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

# Tests for issue #237: lens-id collisions in config/domains.json.
#
# The meta-orchestrator dispatch protocol (lib/rounds.sh) keys on the bare
# lens id after the active mode has selected its domain set. Two domains in
# the same effective mode using the same lens id silently make one lens
# unreachable in round 2+ dispatch. Cross-mode reuse is allowed when the
# modes are mutually exclusive, such as audit-visible and polish lenses.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

assert_empty() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -z "$actual" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    Unexpected output:"
    printf '      %s\n' "$actual"
  fi
}

echo ""
echo "=== Test Suite: lens-id collision guard (issue #237) ==="
echo ""

echo "Test 1: domains.json registry exists and is valid JSON"
if [[ ! -f "$DOMAINS_FILE" ]]; then
  echo "  FAIL: $DOMAINS_FILE missing"
  exit 1
fi
TOTAL=$((TOTAL + 1))
if jq empty "$DOMAINS_FILE" >/dev/null 2>&1; then
  PASS=$((PASS + 1))
  echo "  PASS: domains.json parses as JSON"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: domains.json is not valid JSON"
fi

echo ""
echo "Test 2: no bare lens id appears more than once within the same mode"
# Supports both string-form lens entries and object-form entries
# (issue #230's `skip_modes` shape: `{"id": "<id>", "skip_modes": [...]}`).
duplicates="$(jq -r '
  .domains[] as $d
  | (($d.mode // "audit-visible") | if . == "" then "audit-visible" else . end) as $mode
  | $d.lenses[]
  | (if type == "string" then . else .id end) as $id
  | "\($mode)\t\($id)"
' "$DOMAINS_FILE" | sort | uniq -d)"
assert_empty "no duplicate lens ids within a mode" "$duplicates"

echo ""
echo "Test 3: every registered lens id resolves to one domain per mode"
ambiguous="$(jq -r '
  .domains[] as $d
  | (($d.mode // "audit-visible") | if . == "" then "audit-visible" else . end) as $mode
  | $d.lenses[]
  | if type == "string" then . else .id end
  | . as $id
  | "\($mode)\t\($id)\t\($d.id)"
' "$DOMAINS_FILE" \
  | awk -F'\t' '{ key=$1 "\t" $2; count[key]++; domains[key] = (domains[key] ? domains[key] "," : "") $3 } END { for (key in count) if (count[key] > 1) printf "%s -> %s\n", key, domains[key] }')"
assert_empty "no lens id resolves to more than one domain in a mode" "$ambiguous"

echo ""
echo "Test 4: intentional cross-mode empty-states reuse is mode-isolated"
empty_states_modes="$(jq -r '
  .domains[] as $d
  | (($d.mode // "audit-visible") | if . == "" then "audit-visible" else . end) as $mode
  | select([ $d.lenses[] | if type == "string" then . else .id end ] | index("empty-states"))
  | "\($d.id):\($mode)"
' "$DOMAINS_FILE" | sort | paste -sd' ' -)"
assert_eq "empty-states exists only in audit-visible and polish domains" "effort-signal:polish information-architecture:audit-visible" "$empty_states_modes"

echo ""
echo "Test 5: every registered lens id matches a prompt file on disk"
missing_files=""
while IFS=$'\t' read -r domain lens_id; do
  [[ -z "$domain" || -z "$lens_id" ]] && continue
  prompt_file="$SCRIPT_DIR/prompts/lenses/$domain/$lens_id.md"
  if [[ ! -f "$prompt_file" ]]; then
    missing_files+="$domain/$lens_id"$'\n'
  fi
done < <(jq -r '
  .domains[] as $d
  | $d.lenses[]
  | (if type == "string" then . else .id end) as $id
  | "\($d.id)\t\($id)"
' "$DOMAINS_FILE")
missing_files="${missing_files%$'\n'}"
assert_empty "every registered lens has a prompt file" "$missing_files"

echo ""
echo "Test 6: every prompt file's frontmatter id matches its filename basename"
mismatched=""
while IFS= read -r prompt_file; do
  base="${prompt_file##*/}"
  expected_id="${base%.md}"
  frontmatter_id="$(awk '
    /^---$/ { count++; if (count == 2) exit; next }
    count == 1 && /^id:[[:space:]]/ {
      sub(/^id:[[:space:]]*/, "")
      gsub(/[[:space:]]+$/, "")
      print
      exit
    }
  ' "$prompt_file")"
  if [[ "$frontmatter_id" != "$expected_id" ]]; then
    mismatched+="$prompt_file (id=$frontmatter_id, expected=$expected_id)"$'\n'
  fi
done < <(find "$SCRIPT_DIR/prompts/lenses" -type f -name '*.md')
mismatched="${mismatched%$'\n'}"
assert_empty "frontmatter id matches filename for every lens prompt" "$mismatched"

echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
