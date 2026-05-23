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
# lens id when resolving `LENS: <id>` directives. Two domains using the
# same lens id silently makes the second-by-order lens unreachable in
# round 2+ dispatch. This guard fails when any bare lens id appears more
# than once across domains, so future contributors cannot reintroduce
# the foot-gun silently.

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
echo "Test 2: no bare lens id appears more than once across domains"
# Supports both string-form lens entries and object-form entries
# (issue #230's `skip_modes` shape: `{"id": "<id>", "skip_modes": [...]}`).
duplicates="$(jq -r '
  .domains[].lenses[]
  | if type == "string" then . else .id end
' "$DOMAINS_FILE" | sort | uniq -d)"
assert_empty "no duplicate lens ids" "$duplicates"

echo ""
echo "Test 3: every registered lens id resolves to exactly one (domain, lens) pair"
ambiguous="$(jq -r '
  .domains[] as $d
  | $d.lenses[]
  | if type == "string" then . else .id end
  | . as $id
  | "\($id)\t\($d.id)"
' "$DOMAINS_FILE" \
  | awk -F'\t' '{ count[$1]++; domains[$1] = (domains[$1] ? domains[$1] "," : "") $2 } END { for (id in count) if (count[id] > 1) printf "%s -> %s\n", id, domains[id] }')"
assert_empty "no lens id resolves to more than one domain" "$ambiguous"

echo ""
echo "Test 4: every registered lens id matches a prompt file on disk"
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
echo "Test 5: every prompt file's frontmatter id matches its filename basename"
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
