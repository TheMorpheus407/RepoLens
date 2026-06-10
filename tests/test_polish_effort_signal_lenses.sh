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

# Tests for issues #297 and #298: polish-mode effort-signal domain and lenses.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/template.sh
source "$SCRIPT_DIR/lib/template.sh"

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

assert_not_contains_regex() {
  local desc="$1" pattern="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if ! grep -qiE -- "$pattern" <<< "$haystack"; then
    pass_with "$desc"
  else
    fail_with "$desc" "Did not expect regex: $pattern"
  fi
}

DOMAINS_FILE="$SCRIPT_DIR/config/domains.json"
COLORS_FILE="$SCRIPT_DIR/config/label-colors.json"
LENSES_DIR="$SCRIPT_DIR/prompts/lenses"

EXPECTED_LENSES="empty-states error-and-404-grace edge-case-thoughtfulness loading-transparency forgotten-corners offline-and-failure-grace"

echo ""
echo "=== Test Suite: polish effort-signal lenses (issue #297) ==="
echo ""

echo "Test 1: effort-signal domain is registered for polish mode"
mode="$(jq -r '.domains[] | select(.id == "effort-signal") | .mode' "$DOMAINS_FILE")"
assert_eq "effort-signal mode is polish" "polish" "$mode"
order="$(jq -r '.domains[] | select(.id == "effort-signal") | .order' "$DOMAINS_FILE")"
assert_eq "effort-signal follows fluency" "35" "$order"

echo ""
echo "Test 2: effort-signal exposes exactly the expected polish lenses"
lenses="$(jq -r '.domains[] | select(.id == "effort-signal") | .lenses | join(" ")' "$DOMAINS_FILE")"
assert_eq "effort-signal lens list matches issue scope" "$EXPECTED_LENSES" "$lenses"

echo ""
echo "Test 3: effort-signal label color is deterministic"
color="$(jq -r '."effort-signal"' "$COLORS_FILE")"
assert_eq "effort-signal label color exists" "f59e0b" "$color"

echo ""
echo "Test 4: polish mode resolves effort-signal lenses"
polish_lenses="$(jq -r --arg mode "polish" \
  '.domains | sort_by(.order)[] | (if $mode == "polish" then select(.mode == "polish") else select(.mode != "discover" and .mode != "deploy" and .mode != "opensource" and .mode != "content" and .mode != "greenfield" and .mode != "polish") end) | .id as $d | .lenses[] | $d + "/" + .' "$DOMAINS_FILE")"
for lens in $EXPECTED_LENSES; do
  assert_contains "polish resolves effort-signal/$lens" "effort-signal/$lens" "$polish_lenses"
done

echo ""
echo "Test 5: default audit selection excludes effort-signal"
audit_lenses="$(jq -r --arg mode "audit" \
  '.domains | sort_by(.order)[] | (if $mode == "discover" then select(.mode == "discover") elif $mode == "deploy" then select(.mode == "deploy") elif $mode == "opensource" then select(.mode == "opensource") elif $mode == "content" then select(.mode == "content") elif $mode == "greenfield" then select(.mode == "greenfield") elif $mode == "polish" then select(.mode == "polish") else select(.mode != "discover" and .mode != "deploy" and .mode != "opensource" and .mode != "content" and .mode != "greenfield" and .mode != "polish") end) | .id as $d | .lenses[] | $d + "/" + .' "$DOMAINS_FILE")"
effort_signal_audit_lenses="$(printf '%s\n' "$audit_lenses" | grep '^effort-signal/' || true)"
assert_eq "no effort-signal lenses in default audit mode" "" "$effort_signal_audit_lenses"

echo ""
echo "Test 6: all effort-signal lens files exist with required frontmatter and focus body"
for lens in $EXPECTED_LENSES; do
  lens_file="$LENSES_DIR/effort-signal/$lens.md"
  if [[ ! -f "$lens_file" ]]; then
    TOTAL=$((TOTAL + 1))
    fail_with "$lens file exists" "Missing $lens_file"
    continue
  fi

  lens_content="$(cat "$lens_file")"
  body="$(read_body "$lens_file")"
  assert_eq "$lens id frontmatter" "$lens" "$(read_frontmatter "$lens_file" "id")"
  assert_eq "$lens domain frontmatter" "effort-signal" "$(read_frontmatter "$lens_file" "domain")"
  assert_contains "$lens name frontmatter" "name:" "$lens_content"
  assert_contains "$lens role frontmatter" "role:" "$lens_content"
  assert_contains "$lens expert focus" "## Your Expert Focus" "$body"
  assert_contains "$lens uses polish framing" "polish mode" "$body"
  assert_contains "$lens cites effort-gap rationale" "effort-gap rationale" "$body"
  assert_contains "$lens references project voice profile" "project voice profile" "$body"
  assert_contains "$lens permits No change needed" "No change needed" "$body"
  assert_not_contains_regex "$lens avoids scoring language" 'scor(e|ing)|grade|rating' "$body"
done

echo ""
echo "Test 7: each effort-signal lens names its issue-specific surface"
assert_contains "empty-states names zero-data states" \
  "Zero-data" "$(cat "$LENSES_DIR/effort-signal/empty-states.md")"
assert_contains "empty-states names no-results states" \
  "no-results" "$(cat "$LENSES_DIR/effort-signal/empty-states.md")"
assert_contains "error-and-404-grace names 404 pages" \
  "404 pages" "$(cat "$LENSES_DIR/effort-signal/error-and-404-grace.md")"
assert_contains "error-and-404-grace names recovery" \
  "recovery" "$(cat "$LENSES_DIR/effort-signal/error-and-404-grace.md")"
assert_contains "edge-case-thoughtfulness names singular/plural" \
  "Singular/plural" "$(cat "$LENSES_DIR/effort-signal/edge-case-thoughtfulness.md")"
assert_contains "edge-case-thoughtfulness names zero/one/many" \
  "zero/one/many" "$(cat "$LENSES_DIR/effort-signal/edge-case-thoughtfulness.md")"
assert_contains "edge-case-thoughtfulness names unsaved changes" \
  "Unsaved changes" "$(cat "$LENSES_DIR/effort-signal/edge-case-thoughtfulness.md")"
assert_contains "loading-transparency names labor illusion" \
  "labor illusion" "$(cat "$LENSES_DIR/effort-signal/loading-transparency.md")"
assert_contains "loading-transparency names perceived value" \
  "perceived value" "$(cat "$LENSES_DIR/effort-signal/loading-transparency.md")"
assert_contains "loading-transparency includes honesty caveat" \
  "do not claim downstream satisfaction or repurchase effects" "$(cat "$LENSES_DIR/effort-signal/loading-transparency.md")"
assert_contains "forgotten-corners names help output" \
  "--help" "$(cat "$LENSES_DIR/effort-signal/forgotten-corners.md")"
assert_contains "forgotten-corners names deep settings" \
  "Deep settings" "$(cat "$LENSES_DIR/effort-signal/forgotten-corners.md")"
assert_contains "forgotten-corners names effort-gap multiplier" \
  "effort-gap multiplier" "$(cat "$LENSES_DIR/effort-signal/forgotten-corners.md")"
assert_contains "offline-and-failure-grace names connectivity" \
  "connectivity drops" "$(cat "$LENSES_DIR/effort-signal/offline-and-failure-grace.md")"
assert_contains "offline-and-failure-grace names stale-but-usable content" \
  "stale-but-usable" "$(cat "$LENSES_DIR/effort-signal/offline-and-failure-grace.md")"
assert_contains "offline-and-failure-grace separates from reliability work" \
  "missing offline mode" "$(cat "$LENSES_DIR/effort-signal/offline-and-failure-grace.md")"

echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

[[ "$FAIL" -eq 0 ]] || exit 1
