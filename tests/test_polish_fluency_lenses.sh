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

# Tests for issues #295 and #296: polish-mode fluency domain and lenses.
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

EXPECTED_LENSES="contrast-figure-ground alignment-symmetry spacing-consistency motion-consistency convention-match typographic-rhythm"

echo ""
echo "=== Test Suite: polish fluency lenses (issues #295 and #296) ==="
echo ""

echo "Test 1: fluency domain is registered for polish mode"
fluency_mode="$(jq -r '.domains[] | select(.id == "fluency") | .mode' "$DOMAINS_FILE")"
assert_eq "fluency mode is polish" "polish" "$fluency_mode"

echo ""
echo "Test 2: fluency domain exposes exactly the expected polish lenses"
fluency_lenses="$(jq -r '.domains[] | select(.id == "fluency") | .lenses | join(" ")' "$DOMAINS_FILE")"
assert_eq "fluency lens list matches issue scope" "$EXPECTED_LENSES" "$fluency_lenses"

echo ""
echo "Test 3: fluency label color is deterministic"
color="$(jq -r '.fluency' "$COLORS_FILE")"
assert_eq "fluency label color exists" "14b8a6" "$color"

echo ""
echo "Test 4: polish mode resolves fluency lenses"
polish_lenses="$(jq -r --arg mode "polish" \
  '.domains | sort_by(.order)[] | (if $mode == "polish" then select(.mode == "polish") else select(.mode != "discover" and .mode != "deploy" and .mode != "opensource" and .mode != "content" and .mode != "greenfield" and .mode != "polish") end) | .id as $d | .lenses[] | $d + "/" + .' "$DOMAINS_FILE")"
assert_eq "polish lens count is 16" "16" "$(printf '%s\n' "$polish_lenses" | sed '/^$/d' | wc -l | tr -d ' ')"
for lens in $EXPECTED_LENSES; do
  assert_contains "polish resolves fluency/$lens" "fluency/$lens" "$polish_lenses"
done

echo ""
echo "Test 5: default audit selection excludes fluency"
audit_lenses="$(jq -r --arg mode "audit" \
  '.domains | sort_by(.order)[] | (if $mode == "discover" then select(.mode == "discover") elif $mode == "deploy" then select(.mode == "deploy") elif $mode == "opensource" then select(.mode == "opensource") elif $mode == "content" then select(.mode == "content") elif $mode == "greenfield" then select(.mode == "greenfield") elif $mode == "polish" then select(.mode == "polish") else select(.mode != "discover" and .mode != "deploy" and .mode != "opensource" and .mode != "content" and .mode != "greenfield" and .mode != "polish") end) | .id as $d | .lenses[] | $d + "/" + .' "$DOMAINS_FILE")"
fluency_audit_lenses="$(printf '%s\n' "$audit_lenses" | grep '^fluency/' || true)"
assert_eq "no fluency lenses in default audit mode" "" "$fluency_audit_lenses"

echo ""
echo "Test 6: all fluency lens files exist with required frontmatter and focus body"
for lens in $EXPECTED_LENSES; do
  lens_file="$LENSES_DIR/fluency/$lens.md"
  if [[ ! -f "$lens_file" ]]; then
    TOTAL=$((TOTAL + 1))
    fail_with "$lens file exists" "Missing $lens_file"
    continue
  fi

  lens_content="$(cat "$lens_file")"
  body="$(read_body "$lens_file")"
  assert_eq "$lens id frontmatter" "$lens" "$(read_frontmatter "$lens_file" "id")"
  assert_eq "$lens domain frontmatter" "fluency" "$(read_frontmatter "$lens_file" "domain")"
  assert_contains "$lens name frontmatter" "name:" "$lens_content"
  assert_contains "$lens role frontmatter" "role:" "$lens_content"
  assert_contains "$lens expert focus" "## Your Expert Focus" "$body"
  assert_contains "$lens cites processing fluency" "processing fluency" "$body"
  assert_contains "$lens references project voice profile" "project voice profile" "$body"
  assert_contains "$lens permits No change needed" "No change needed" "$body"
  assert_contains "$lens ties fluency to usability" "usable" "$body"
  assert_contains "$lens ties fluency to beauty" "beautiful" "$body"
  assert_contains "$lens ties fluency to trust" "trustworthy" "$body"
  assert_not_contains_regex "$lens avoids scoring language" 'scor(e|ing)|grade|rating' "$body"
done

echo ""
echo "Test 7: each fluency lens names its evidence-backed lever"
assert_contains "contrast lens names figure-ground contrast" \
  "figure-ground contrast" "$(cat "$LENSES_DIR/fluency/contrast-figure-ground.md")"
assert_contains "alignment lens names symmetry" \
  "symmetry" "$(cat "$LENSES_DIR/fluency/alignment-symmetry.md")"
assert_contains "alignment lens names figural goodness" \
  "figural goodness" "$(cat "$LENSES_DIR/fluency/alignment-symmetry.md")"
assert_contains "spacing lens names repetition" \
  "repetition" "$(cat "$LENSES_DIR/fluency/spacing-consistency.md")"
assert_contains "spacing lens names consistency" \
  "consistency" "$(cat "$LENSES_DIR/fluency/spacing-consistency.md")"
assert_contains "motion lens names shared easing" \
  "shared easing" "$(cat "$LENSES_DIR/fluency/motion-consistency.md")"
assert_contains "motion lens names duration tokens" \
  "duration tokens" "$(cat "$LENSES_DIR/fluency/motion-consistency.md")"
assert_contains "convention lens names prototypicality" \
  "prototypicality" "$(cat "$LENSES_DIR/fluency/convention-match.md")"
assert_contains "convention lens flags unintentional deviation" \
  "Unintentional deviation" "$(cat "$LENSES_DIR/fluency/convention-match.md")"
assert_contains "convention lens permits intentional voice-fit deviation" \
  "intentional, voice-fit deviation" "$(cat "$LENSES_DIR/fluency/convention-match.md")"
assert_contains "typographic lens names type scale" \
  "type scale" "$(cat "$LENSES_DIR/fluency/typographic-rhythm.md")"
assert_contains "typographic lens names line-height" \
  "line-height" "$(cat "$LENSES_DIR/fluency/typographic-rhythm.md")"
assert_contains "typographic lens names measure" \
  "measure" "$(cat "$LENSES_DIR/fluency/typographic-rhythm.md")"
assert_contains "typographic lens names vertical rhythm" \
  "vertical rhythm" "$(cat "$LENSES_DIR/fluency/typographic-rhythm.md")"

echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

[[ "$FAIL" -eq 0 ]] || exit 1
