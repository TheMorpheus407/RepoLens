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

# Tests for issues #299 and #300: polish-mode hedonic domain and lenses.
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

EXPECTED_LENSES="voice-and-microcopy identity-and-ownership stimulation-moments fitting-easter-eggs"

echo ""
echo "=== Test Suite: polish hedonic lenses (issues #299 and #300) ==="
echo ""

echo "Test 1: hedonic domain is registered for polish mode"
mode="$(jq -r '.domains[] | select(.id == "hedonic") | .mode' "$DOMAINS_FILE")"
assert_eq "hedonic mode is polish" "polish" "$mode"
order="$(jq -r '.domains[] | select(.id == "hedonic") | .order' "$DOMAINS_FILE")"
assert_eq "hedonic follows effort-signal" "36" "$order"
description="$(jq -r '.domains[] | select(.id == "hedonic") | .description' "$DOMAINS_FILE")"
assert_contains "hedonic description marks experimental status" "Experimental" "$description"

echo ""
echo "Test 2: hedonic exposes exactly the expected polish lenses"
lenses="$(jq -r '.domains[] | select(.id == "hedonic") | .lenses | join(" ")' "$DOMAINS_FILE")"
assert_eq "hedonic lens list matches issue scope" "$EXPECTED_LENSES" "$lenses"

echo ""
echo "Test 3: hedonic label color is deterministic"
color="$(jq -r '.hedonic' "$COLORS_FILE")"
assert_eq "hedonic label color exists" "a855f7" "$color"

echo ""
echo "Test 4: polish mode resolves hedonic lenses"
polish_lenses="$(jq -r --arg mode "polish" \
  '.domains | sort_by(.order)[] | (if $mode == "polish" then select(.mode == "polish") else select(.mode != "discover" and .mode != "deploy" and .mode != "opensource" and .mode != "content" and .mode != "greenfield" and .mode != "polish") end) | .id as $d | .lenses[] | $d + "/" + .' "$DOMAINS_FILE")"
assert_eq "polish lens count is 16" "16" "$(printf '%s\n' "$polish_lenses" | sed '/^$/d' | wc -l | tr -d ' ')"
for lens in $EXPECTED_LENSES; do
  assert_contains "polish resolves hedonic/$lens" "hedonic/$lens" "$polish_lenses"
done

echo ""
echo "Test 5: default audit selection excludes hedonic"
audit_lenses="$(jq -r --arg mode "audit" \
  '.domains | sort_by(.order)[] | (if $mode == "discover" then select(.mode == "discover") elif $mode == "deploy" then select(.mode == "deploy") elif $mode == "opensource" then select(.mode == "opensource") elif $mode == "content" then select(.mode == "content") elif $mode == "greenfield" then select(.mode == "greenfield") elif $mode == "polish" then select(.mode == "polish") else select(.mode != "discover" and .mode != "deploy" and .mode != "opensource" and .mode != "content" and .mode != "greenfield" and .mode != "polish") end) | .id as $d | .lenses[] | $d + "/" + .' "$DOMAINS_FILE")"
hedonic_audit_lenses="$(printf '%s\n' "$audit_lenses" | grep '^hedonic/' || true)"
assert_eq "no hedonic lenses in default audit mode" "" "$hedonic_audit_lenses"

echo ""
echo "Test 6: all hedonic lens files exist with required frontmatter and focus body"
for lens in $EXPECTED_LENSES; do
  lens_file="$LENSES_DIR/hedonic/$lens.md"
  if [[ ! -f "$lens_file" ]]; then
    TOTAL=$((TOTAL + 1))
    fail_with "$lens file exists" "Missing $lens_file"
    continue
  fi

  lens_content="$(cat "$lens_file")"
  body="$(read_body "$lens_file")"
  assert_eq "$lens id frontmatter" "$lens" "$(read_frontmatter "$lens_file" "id")"
  assert_eq "$lens domain frontmatter" "hedonic" "$(read_frontmatter "$lens_file" "domain")"
  assert_contains "$lens name frontmatter" "name:" "$lens_content"
  assert_contains "$lens role frontmatter" "role:" "$lens_content"
  assert_contains "$lens expert focus" "## Your Expert Focus" "$body"
  assert_contains "$lens uses polish framing" "polish mode" "$body"
  assert_contains "$lens states weak evidence" "weak evidence" "$body"
  assert_contains "$lens references project voice profile" "project voice profile" "$body"
  assert_contains "$lens permits No change needed" "No change needed" "$body"
  assert_not_contains_regex "$lens avoids scoring language" 'scor(e|ing)|grade|rating' "$body"
done

echo ""
echo "Test 7: voice-and-microcopy names required copy surfaces"
voice_content="$(cat "$LENSES_DIR/hedonic/voice-and-microcopy.md")"
assert_contains "voice lens names empty states" "empty states" "$voice_content"
assert_contains "voice lens names errors" "errors" "$voice_content"
assert_contains "voice lens names buttons" "buttons" "$voice_content"
assert_contains "voice lens names confirmations" "confirmations" "$voice_content"
assert_contains "voice lens requires local copy evidence" "local copy evidence" "$voice_content"

echo ""
echo "Test 8: identity-and-ownership names required caveats"
identity_content="$(cat "$LENSES_DIR/hedonic/identity-and-ownership.md")"
assert_contains "identity lens names HQ-I" "HQ-I" "$identity_content"
assert_contains "identity lens names reflective level" "reflective level" "$identity_content"
assert_contains "identity lens names IKEA effect" "IKEA effect" "$identity_content"
assert_contains "identity lens rejects customization ownership claim" "do not add customization to create ownership" "$identity_content"

echo ""
echo "Test 9: stimulation-moments names required caveats"
stimulation_content="$(cat "$LENSES_DIR/hedonic/stimulation-moments.md")"
assert_contains "stimulation lens names HQ-S" "HQ-S" "$stimulation_content"
assert_contains "stimulation lens names stimulation" "stimulation" "$stimulation_content"
assert_contains "stimulation lens names exploration" "exploration" "$stimulation_content"
assert_contains "stimulation lens says exploratory" "exploratory" "$stimulation_content"
assert_contains "stimulation lens rejects generic surprise" "generic surprise" "$stimulation_content"

echo ""
echo "Test 10: fitting-easter-eggs names required restraint"
easter_content="$(cat "$LENSES_DIR/hedonic/fitting-easter-eggs.md")"
assert_contains "easter lens states default answer" "none — it wouldn't fit" "$easter_content"
assert_contains "easter lens says restraint is the feature" "restraint is the feature" "$easter_content"
assert_contains "easter lens requires strong voice fit" "strong voice-profile justification" "$easter_content"
assert_contains "easter lens rejects Konami-code" "Konami-code" "$easter_content"
assert_contains "easter lens rejects confetti" "confetti" "$easter_content"
assert_contains "easter lens rejects special affect claim" "no verified evidence that easter eggs or surprise produce special affect" "$easter_content"

echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

[[ "$FAIL" -eq 0 ]] || exit 1
