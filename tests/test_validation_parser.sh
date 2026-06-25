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

# Tests for issue #332 — the `## Validation` block parser (lib/validation.sh).
#
# `parse_validation_block` lifts the free-form `## Validation` markdown block a
# finding carries (contract defined by #317) into a structured JSON object with
# exactly six keys, built via jq. These are BEHAVIORAL tests against the public
# contract from the issue's acceptance criteria — they do not assume internal
# helper names. No real AI models are invoked; this is a pure parser.
#
# Contract under test:
#   - lib/validation.sh is sourceable with NO side effects on source.
#   - parse_validation_block reads a finding markdown from a file-path arg OR
#     from stdin (no arg).
#   - It emits ONE JSON object on stdout with keys: attacker_source,
#     missing_guard, sink_effect, preconditions, proof_anchors,
#     suggested_validation.
#   - Five fields are strings ("" when absent); proof_anchors is a JSON array of
#     strings ([] when absent).
#   - It tolerates the template's bulleted em-dash form (`- field — value`) and
#     the audit.md colon form (`field: value` / `- field: value`).
#   - It never crashes on a finding without a `## Validation` block.
#   - Values are emitted via jq so quotes / `$(...)` / backticks cannot break
#     the JSON (no injection).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALIDATION_LIB="$SCRIPT_DIR/lib/validation.sh"
FIXTURES="$SCRIPT_DIR/tests/fixtures"
FULL="$FIXTURES/validation-block-full.md"
MISSING="$FIXTURES/validation-block-missing.md"

PASS=0
FAIL=0
TOTAL=0

pass_with() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

fail_with() {
  local desc="$1" detail="${2:-}"
  FAIL=$((FAIL + 1))
  echo "  FAIL: $desc"
  [[ -n "$detail" ]] && printf '    %s\n' "$detail"
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected '$expected', got '$actual'"
  fi
}

# Assert a jq filter is truthy (exit 0) against the given JSON.
assert_jq_true() {
  local desc="$1" json="$2" filter="$3"
  TOTAL=$((TOTAL + 1))
  if printf '%s' "$json" | jq -e "$filter" >/dev/null 2>&1; then
    pass_with "$desc"
  else
    fail_with "$desc" "jq filter not truthy: $filter"
  fi
}

finish() {
  echo ""
  echo "Results: $PASS/$TOTAL passed, $FAIL failed"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
  exit 0
}

# Convenience: read a string field out of a JSON object via jq -r.
jget() {
  local json="$1" key="$2"
  printf '%s' "$json" | jq -r ".$key"
}

echo ""
echo "=== Test Suite: ## Validation block parser (issue #332) ==="
echo ""

# Red-phase guard: if the module does not exist yet, fail cleanly and stop so
# the runner reports a single discoverable failure rather than a cascade of
# "command not found" noise.
if [[ ! -f "$VALIDATION_LIB" ]]; then
  fail_with "lib/validation.sh exists" "Missing $VALIDATION_LIB (not yet implemented)"
  finish
fi

echo "--- Group 1: sourceable module with no side effects ---"
# Sourcing must define functions only — no output, no work at source time.
# shellcheck disable=SC1090
source_out="$(source "$VALIDATION_LIB" 2>&1)"
assert_eq "sourcing lib/validation.sh emits nothing" "" "$source_out"

# shellcheck disable=SC1090
source "$VALIDATION_LIB"
TOTAL=$((TOTAL + 1))
if declare -F parse_validation_block >/dev/null 2>&1; then
  pass_with "parse_validation_block is defined after sourcing"
else
  fail_with "parse_validation_block is defined after sourcing"
  # Nothing else can be tested without the function — stop here.
  finish
fi

echo ""
echo "--- Group 2: full block (bulleted em-dash form, file-path arg) ---"
full_json="$(parse_validation_block "$FULL")"

assert_jq_true "output is valid JSON" "$full_json" '.'
assert_eq "object has exactly the six contract keys (sorted)" \
  '["attacker_source","missing_guard","preconditions","proof_anchors","sink_effect","suggested_validation"]' \
  "$(printf '%s' "$full_json" | jq -c 'keys')"

assert_eq "attacker_source extracted" \
  'HTTP query parameter `id` on GET /users' \
  "$(jget "$full_json" attacker_source)"
assert_eq "missing_guard extracted" \
  'no parameterization or integer cast before the query is built' \
  "$(jget "$full_json" missing_guard)"
assert_eq "sink_effect extracted" \
  'concatenated into a raw SQL SELECT executed against the primary DB' \
  "$(jget "$full_json" sink_effect)"
assert_eq "preconditions extracted" \
  'endpoint is reachable unauthenticated' \
  "$(jget "$full_json" preconditions)"
assert_eq "suggested_validation extracted" \
  'grep -n "SELECT .* + " app/users.py' \
  "$(jget "$full_json" suggested_validation)"

assert_jq_true "proof_anchors is a JSON array" "$full_json" '.proof_anchors | type == "array"'
assert_eq "proof_anchors normalized to a one-element array" \
  '["app/users.py:42"]' \
  "$(printf '%s' "$full_json" | jq -c '.proof_anchors')"

echo ""
echo "--- Group 3: finding with NO ## Validation block ---"
missing_json="$(parse_validation_block "$MISSING")"; missing_rc=$?
assert_eq "parser exits 0 on a finding without a Validation block" "0" "$missing_rc"
assert_jq_true "missing-block output is still valid JSON" "$missing_json" '.'
assert_jq_true "all five string fields default to empty string" "$missing_json" \
  '[.attacker_source,.missing_guard,.sink_effect,.preconditions,.suggested_validation] | all(. == "")'
assert_eq "proof_anchors defaults to an empty array" \
  '[]' \
  "$(printf '%s' "$missing_json" | jq -c '.proof_anchors')"

echo ""
echo "--- Group 4: stdin input (no path argument) ---"
stdin_json="$(parse_validation_block < "$FULL")"
assert_eq "reading from stdin yields the same attacker_source" \
  'HTTP query parameter `id` on GET /users' \
  "$(jget "$stdin_json" attacker_source)"

echo ""
echo "--- Group 5: colon-separator tolerance (audit.md 'Good' form) ---"
TMPROOT="$SCRIPT_DIR/tests/.tmp"
mkdir -p "$TMPROOT"
TMPDIR_VP="$(mktemp -d "$TMPROOT/validation-parser.XXXXXX")"
trap 'rm -rf "$TMPDIR_VP"; rmdir "$TMPROOT" 2>/dev/null || true' EXIT

# A block that mixes plain `field: value` and bulleted `- field: value` lines —
# the colon-separated shape the authoring guidance shows as the "Good" example.
cat > "$TMPDIR_VP/colon.md" <<'EOF'
# Some finding

## Validation
attacker_source: stdin of the parser
- missing_guard: no escaping
- proof_anchors: lib/template.sh:208
EOF
colon_json="$(parse_validation_block "$TMPDIR_VP/colon.md")"
assert_jq_true "colon-form output is valid JSON" "$colon_json" '.'
assert_eq "plain 'field: value' line is parsed" \
  'stdin of the parser' \
  "$(jget "$colon_json" attacker_source)"
assert_eq "bulleted '- field: value' line is parsed" \
  'no escaping' \
  "$(jget "$colon_json" missing_guard)"
assert_eq "colon-form proof_anchors normalized to an array" \
  '["lib/template.sh:208"]' \
  "$(printf '%s' "$colon_json" | jq -c '.proof_anchors')"

echo ""
echo "--- Group 6: JSON-injection safety (values via jq, never concatenated) ---"
# A value containing a double-quote, backslash, $(...) and backticks must NOT
# break the emitted JSON, and must round-trip verbatim — proving values are
# passed through jq --arg rather than string-concatenated into the object.
cat > "$TMPDIR_VP/hostile.md" <<'EOF'
# Hostile finding

## Validation
- attacker_source — "; DROP TABLE users; -- $(whoami) and `id` \end
EOF
hostile_json="$(parse_validation_block "$TMPDIR_VP/hostile.md")"
assert_jq_true "hostile value still produces valid JSON" "$hostile_json" '.'
assert_eq "hostile attacker_source round-trips verbatim" \
  '"; DROP TABLE users; -- $(whoami) and `id` \end' \
  "$(jget "$hostile_json" attacker_source)"

echo ""
echo "--- Group 7: proof_anchors comma-split into a multi-element array ---"
# The documented choice (lib/validation.sh) is to comma-split proof_anchors and
# drop whitespace-only / empty elements. The fixtures above only ever exercise a
# SINGLE inline anchor, so the multi-element split, the per-element trim, and the
# empty-element dropping all go untested. Lock them down here.
multi_json="$(parse_validation_block <<'EOF'
## Validation
- proof_anchors — app/a.py:42, app/b.py:51 ,  , app/c.py:7,
- sink_effect — reads a, b, and c from the table
EOF
)"
assert_jq_true "multi-anchor output is valid JSON" "$multi_json" '.'
assert_eq "comma-separated proof_anchors split into a trimmed, empty-dropped array" \
  '["app/a.py:42","app/b.py:51","app/c.py:7"]' \
  "$(printf '%s' "$multi_json" | jq -c '.proof_anchors')"
# Comma-splitting is scoped to proof_anchors only — a non-anchor string field
# that legitimately contains commas must survive verbatim, not be mangled.
assert_eq "commas in a non-anchor field are preserved verbatim (not split)" \
  'reads a, b, and c from the table' \
  "$(jget "$multi_json" sink_effect)"

echo ""
echo "--- Group 8: bold field-name forms (**field**: / - **field:**) ---"
# The authoring guidance permits bold-wrapped field names. The implementation
# strips a bold marker before the name, after the name, and after the separator;
# none of that is exercised by the em-dash / colon fixtures above.
bold_json="$(parse_validation_block <<'EOF'
## Validation
- **attacker_source**: bold name form
- **proof_anchors:** lib/x.sh:10
EOF
)"
assert_jq_true "bold-field output is valid JSON" "$bold_json" '.'
assert_eq "bold field name '**attacker_source**: value' is parsed" \
  'bold name form' \
  "$(jget "$bold_json" attacker_source)"
assert_eq "bold field+separator '- **proof_anchors:** ...' is parsed to an array" \
  '["lib/x.sh:10"]' \
  "$(printf '%s' "$bold_json" | jq -c '.proof_anchors')"

echo ""
echo "--- Group 9: section bounding (no cross-section / second-block bleed) ---"
# The full fixture places ## Validation LAST, so the section-end boundary is
# never hit and field-name false positives in OTHER sections are never tested.
# Here a field-shaped line appears in ## Summary (before) and ## Notes (after the
# boundary); only the line genuinely inside ## Validation must be captured.
bounded_json="$(parse_validation_block <<'EOF'
## Summary
attacker_source: this lives in Summary and must be ignored
## Validation
- missing_guard — the only real validation field
## Notes
- attacker_source — after the boundary, must be ignored
EOF
)"
assert_eq "field-shaped line in a sibling section is NOT captured" \
  '' \
  "$(jget "$bounded_json" attacker_source)"
assert_eq "the genuine in-section field IS captured" \
  'the only real validation field' \
  "$(jget "$bounded_json" missing_guard)"
# A malformed finding with two ## Validation blocks: only the first is honored.
first_block_json="$(parse_validation_block <<'EOF'
## Validation
- attacker_source — FIRST block
## Validation
- attacker_source — SECOND block
EOF
)"
assert_eq "with two ## Validation blocks, only the first is honored" \
  'FIRST block' \
  "$(jget "$first_block_json" attacker_source)"

echo ""
echo "--- Group 10: remaining separator branches (en-dash, hyphen) ---"
# Existing groups cover em-dash (U+2014) and colon. The en-dash (U+2013) and the
# plain hyphen separator branches are distinct code paths and were untested.
sep_json="$(parse_validation_block <<'EOF'
## Validation
- attacker_source – en-dash separated value
- sink_effect - hyphen separated value
EOF
)"
assert_eq "en-dash (U+2013) separator is parsed, value not retaining the dash" \
  'en-dash separated value' \
  "$(jget "$sep_json" attacker_source)"
assert_eq "plain hyphen separator is parsed, value not retaining the dash" \
  'hyphen separated value' \
  "$(jget "$sep_json" sink_effect)"

echo ""
echo "--- Group 11: partial block (per-field independence) ---"
# Only two of the six fields are present. The full fixture exercises all-present
# and the missing fixture all-absent; the in-between (some present, rest default)
# proves each field is captured independently.
partial_json="$(parse_validation_block <<'EOF'
## Validation
- attacker_source — only this field is set
- proof_anchors — x.sh:1
EOF
)"
assert_jq_true "partial-block output is valid JSON" "$partial_json" '.'
assert_eq "present string field is captured" \
  'only this field is set' \
  "$(jget "$partial_json" attacker_source)"
assert_eq "present proof_anchors is captured as an array" \
  '["x.sh:1"]' \
  "$(printf '%s' "$partial_json" | jq -c '.proof_anchors')"
assert_jq_true "the four absent fields default to empty (string) / empty array" "$partial_json" \
  '(.missing_guard == "") and (.sink_effect == "") and (.preconditions == "") and (.suggested_validation == "")'

echo ""
echo "--- Group 12: input-source robustness ---"
# A given-but-nonexistent path must yield the all-empty object WITHOUT consuming
# stdin — otherwise the parser would silently parse (or block on) unrelated
# piped data in a pipeline. Feed real validation markdown on stdin and prove it
# does NOT leak into the result for a bad path.
nonexistent_json="$(printf '## Validation\n- attacker_source — LEAKED FROM STDIN\n' \
  | parse_validation_block /no/such/validation/file.md)"
assert_jq_true "nonexistent path still yields valid JSON" "$nonexistent_json" '.'
assert_eq "nonexistent path does NOT read/leak stdin (attacker_source stays empty)" \
  '' \
  "$(jget "$nonexistent_json" attacker_source)"
assert_eq "nonexistent path yields empty proof_anchors array" \
  '[]' \
  "$(printf '%s' "$nonexistent_json" | jq -c '.proof_anchors')"

# Explicit "-" path argument is documented to read stdin (same as no arg).
dash_json="$(printf '## Validation\n- attacker_source: explicit dash arg\n' \
  | parse_validation_block -)"
assert_eq "explicit '-' path argument reads from stdin" \
  'explicit dash arg' \
  "$(jget "$dash_json" attacker_source)"

# CRLF line endings (the heading and field lines carry a trailing \r) must be
# tolerated — the \r is stripped before matching / extracting.
crlf_json="$(printf '## Validation\r\n- attacker_source \xe2\x80\x94 crlf tolerated\r\n' \
  | parse_validation_block)"
assert_jq_true "CRLF input still yields valid JSON" "$crlf_json" '.'
assert_eq "CRLF heading + field line is parsed (carriage return stripped)" \
  'crlf tolerated' \
  "$(jget "$crlf_json" attacker_source)"

echo ""
echo "--- Group 13: heading-level granularity of the section boundary ---"
# The section ends on a level-1 (#) or level-2 (##) heading, but NOT on a
# level-3+ (###) sub-heading — the implementation's `^#{1,2}[[:space:]]` choice.
# Every existing group terminates the section with a level-2 (##) heading, so
# the "### does NOT terminate" branch and the "# DOES terminate" branch are both
# untested. A finding may legitimately carry a ### sub-heading inside its
# Validation block; fields after it must still be captured.
level3_json="$(parse_validation_block <<'EOF'
## Validation
- attacker_source — before the sub-heading
### A level-3 subsection inside the block
- missing_guard — still inside Validation, after the level-3 heading
## Notes
- sink_effect — past the level-2 boundary, must be ignored
EOF
)"
assert_eq "field before a level-3 (###) sub-heading is captured" \
  'before the sub-heading' \
  "$(jget "$level3_json" attacker_source)"
assert_eq "a level-3 (###) sub-heading does NOT end the section" \
  'still inside Validation, after the level-3 heading' \
  "$(jget "$level3_json" missing_guard)"
assert_eq "a level-2 (##) heading still ends the section (later field ignored)" \
  '' \
  "$(jget "$level3_json" sink_effect)"

# A level-1 (#) heading must also terminate the section (the lower bound of the
# `#{1,2}` quantifier). Existing termination tests only ever use a `##` heading.
level1_json="$(parse_validation_block <<'EOF'
## Validation
- attacker_source — inside validation
# Appendix
- missing_guard — past a level-1 heading, must be ignored
EOF
)"
assert_eq "field before the level-1 (#) boundary is still captured" \
  'inside validation' \
  "$(jget "$level1_json" attacker_source)"
assert_eq "a level-1 (#) heading ends the section (later field ignored)" \
  '' \
  "$(jget "$level1_json" missing_guard)"

echo ""
echo "--- Group 14: field-name prefix-collision guard (separator required) ---"
# A line whose token merely STARTS WITH the field name but continues into a
# longer token (`attacker_source_notes`) must NOT be mis-captured for the
# shorter field (`attacker_source`): the parser requires a separator IMMEDIATELY
# after the field name. Existing groups only test cross-SECTION false positives
# (Group 9), never an in-section longer-token decoy. A naive startswith matcher
# would wrongly return the decoy's value here.
collision_json="$(parse_validation_block <<'EOF'
## Validation
- attacker_source_notes — DECOY: longer token, must be skipped
- attacker_source — the genuine value
EOF
)"
assert_eq "a longer-token decoy is skipped and the genuine field is captured" \
  'the genuine value' \
  "$(jget "$collision_json" attacker_source)"

# Decoy alone, with no genuine field line: the field stays empty rather than
# borrowing the longer token's value.
decoy_only_json="$(parse_validation_block <<'EOF'
## Validation
- attacker_source_notes — only a decoy, no real attacker_source line
EOF
)"
assert_eq "a longer-token decoy alone leaves the field empty (not borrowed)" \
  '' \
  "$(jget "$decoy_only_json" attacker_source)"

finish
