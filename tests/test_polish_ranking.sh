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

# Tests for issue #301: deterministic polish ranking.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/template.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/polish.sh"

PASS=0
FAIL=0
TOTAL=0

TMP_PARENT="$SCRIPT_DIR/logs/test-polish-ranking"
mkdir -p "$TMP_PARENT"
TMPDIR="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"
unset LOG_BASE RUN_ID OUTPUT_DIR CURRENT_ROUND_OUTPUT_DIR

cleanup() {
  rm -rf "$TMPDIR"
  rmdir "$TMP_PARENT" 2>/dev/null || true
}
trap cleanup EXIT

pass_with() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

fail_with() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
  if [[ -n "${2:-}" ]]; then
    printf '    %s\n' "$2"
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected: $expected | Actual: ${actual:-<empty>}"
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

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Did not expect to contain: $needle"
  fi
}

assert_matches() {
  local desc="$1" pattern="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if grep -qE -- "$pattern" <<< "$haystack"; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected to match regex: $pattern"
  fi
}

assert_file_exists() {
  local desc="$1" file="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$file" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected file at $file"
  fi
}

assert_jq() {
  local desc="$1" file="$2" filter="$3"
  TOTAL=$((TOTAL + 1))
  if jq -e "$filter" "$file" >/dev/null 2>&1; then
    pass_with "$desc"
  else
    fail_with "$desc" "jq filter failed: $filter"
  fi
}

assert_function_exists() {
  local desc="$1" name="$2"
  TOTAL=$((TOTAL + 1))
  if declare -F "$name" >/dev/null 2>&1; then
    pass_with "$desc"
    return 0
  fi
  fail_with "$desc" "Missing shell function: $name"
  return 1
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

write_rank_fixture() {
  local file="$1"
  mkdir -p "$(dirname "$file")"
  cat > "$file" <<'JSON'
[
  {
    "title": "Medium no-benchmark",
    "domain": "effort-signal",
    "lens_id": "loading-transparency",
    "source_path": "src/loading.ts",
    "polish_family": "effort-signal",
    "voice_fit": "medium",
    "location_expectedness": "no-benchmark",
    "body": "Loading state polish with explicit voice fit."
  },
  {
    "title": "Off-brand corner",
    "domain": "hedonic",
    "lens_id": "fitting-easter-eggs",
    "source_path": "src/easter.ts",
    "polish_family": "hedonic",
    "voice_fit": "off-brand",
    "location_expectedness": "forgotten-corner",
    "body": "Hidden moment that does not fit this repository."
  },
  {
    "title": "Expected strong fit",
    "domain": "fluency",
    "lens_id": "spacing-consistency",
    "source_path": "app/ui.css",
    "polish_family": "fluency",
    "voice_fit": "strong",
    "location_expectedness": "expected",
    "body": "Expected surface with strong project voice fit."
  },
  {
    "title": "Weak low-expectation",
    "domain": "hedonic",
    "lens_id": "voice-and-microcopy",
    "source_path": "README.md",
    "polish_family": "hedonic",
    "voice_fit": "weak",
    "location_expectedness": "low-expectation",
    "body": "Weak voice fit stays low even in a lower-expectation surface."
  },
  {
    "title": "Forgotten corner with strong fit",
    "domain": "effort-signal",
    "lens_id": "forgotten-corners",
    "source_path": "scripts/rare.sh",
    "polish_family": "effort-signal",
    "voice_fit": "strong",
    "location_expectedness": "forgotten-corner",
    "body": "Unexpected corner with strong project voice fit."
  }
]
JSON
}

echo ""
echo "=== Test Suite: polish ranking (issue #301) ==="
echo ""

echo "Test 1: polish prompt asks for structured tags, not rank output"
cat > "$TMPDIR/lens.md" <<'EOF'
---
id: ranking-test
domain: fluency
name: Ranking Test
role: tester
---
## Your Expert Focus
Check polish suggestions.
EOF

base_vars="LENS_NAME=Ranking Test|DOMAIN_NAME=Fluency|REPO_OWNER=owner|REPO_NAME=repo|PROJECT_PATH=/tmp/project|LENS_LABEL=polish:fluency/ranking-test|DOMAIN_COLOR=14b8a6|DOMAIN=fluency|LENS_ID=ranking-test|MODE=polish|RUN_ID=test-run|VOICE_PROFILE=Mock polish voice profile."
rendered_prompt="$(compose_prompt "$SCRIPT_DIR/prompts/_base/polish.md" "$TMPDIR/lens.md" "$base_vars" "" "polish" "" "" "false" "true" "$TMPDIR/local-output")"
remote_rendered_prompt="$(compose_prompt "$SCRIPT_DIR/prompts/_base/polish.md" "$TMPDIR/lens.md" "$base_vars" "" "polish" "" "" "false" "false" "")"

assert_contains "polish prompt requires voice_fit tag" "voice_fit:" "$rendered_prompt"
assert_contains "polish prompt requires location_expectedness tag" "location_expectedness:" "$rendered_prompt"
assert_contains "polish prompt requires polish_family tag" "polish_family:" "$rendered_prompt"
assert_contains "polish prompt substitutes the default suggestion file path" "logs/test-run/polish/suggestions/fluency--ranking-test.json" "$remote_rendered_prompt"
assert_not_contains "polish prompt has no unresolved suggestion file placeholder" "{{POLISH_SUGGESTIONS_FILE}}" "$remote_rendered_prompt"
assert_contains "polish local mode points at the requested JSON output directory" "$TMPDIR/local-output" "$rendered_prompt"
assert_not_contains "polish prompt does not ask lenses to emit computed rank" "polish_rank_x1000:" "$rendered_prompt"
assert_not_contains "polish local mode does not require severity frontmatter" "severity: critical|high|medium|low" "$rendered_prompt"
assert_not_contains "polish local mode does not use severity title template" "[SEVERITY] Finding title" "$rendered_prompt"
assert_matches "repolens invokes polish ranking after lens execution" \
  'run_polish_ranking[[:space:]]+"\$\{?RUN_ID\}?"' \
  "$(cat "$SCRIPT_DIR/repolens.sh")"
assert_matches "repolens pre-creates the polish suggestions fragment directory" \
  'mkdir[[:space:]]+-p[[:space:]]+"\$LOG_BASE/polish/suggestions"' \
  "$(cat "$SCRIPT_DIR/repolens.sh")"

echo ""
echo "Test 2: run_polish_ranking produces a sorted ranked artifact"
if ! assert_function_exists "run_polish_ranking is available" "run_polish_ranking"; then
  finish
fi

RUN_ID="ranking-run"
LOG_BASE="$TMPDIR/logs/$RUN_ID"
suggestions_file="$LOG_BASE/polish/suggestions.json"
ranked_file="$LOG_BASE/polish/ranked-suggestions.json"
write_rank_fixture "$suggestions_file"

run_polish_ranking "$RUN_ID"
rank_rc=$?
assert_eq "ranking helper exits successfully" "0" "$rank_rc"
assert_file_exists "ranked polish artifact exists" "$ranked_file"
assert_jq "ranked polish artifact is a JSON array" "$ranked_file" 'type == "array" and length == 5'
assert_jq "each suggestion carries computed polish factors" "$ranked_file" \
  'all(.[]; (.polish_rank_x1000 | type == "number") and (.fluency_baseline == 1) and (.soul_fit | type == "number") and (.effort_gap_multiplier | type == "number"))'
assert_jq "ranked suggestions do not inherit audit severity metadata" "$ranked_file" \
  'all(.[]; has("severity") | not)'
assert_eq "ranked suggestions are sorted by computed polish rank" \
  "Forgotten corner with strong fit|Expected strong fit|Medium no-benchmark|Weak low-expectation|Off-brand corner" \
  "$(jq -r 'map(.title) | join("|")' "$ranked_file")"
assert_eq "strong forgotten-corner rank is fixed-point 1500" \
  "1500" \
  "$(jq -r '.[] | select(.title == "Forgotten corner with strong fit") | .polish_rank_x1000' "$ranked_file")"
assert_eq "strong expected rank is fixed-point 1000" \
  "1000" \
  "$(jq -r '.[] | select(.title == "Expected strong fit") | .polish_rank_x1000' "$ranked_file")"
assert_eq "off-brand rank is fixed-point zero" \
  "0" \
  "$(jq -r '.[] | select(.title == "Off-brand corner") | .polish_rank_x1000' "$ranked_file")"

echo ""
echo "Test 3: malformed tags use deterministic conservative defaults"
RUN_ID="defaults-run"
LOG_BASE="$TMPDIR/logs/$RUN_ID"
mkdir -p "$LOG_BASE/polish"
cat > "$LOG_BASE/polish/suggestions.json" <<'JSON'
[
  {
    "title": "Unknown tags",
    "domain": "fluency",
    "lens_id": "spacing-consistency",
    "source_path": "a.css",
    "polish_family": "fluency",
    "voice_fit": "mystery",
    "location_expectedness": "surprising",
    "body": "Malformed tags must not rank high."
  },
  {
    "title": "Known strong",
    "domain": "fluency",
    "lens_id": "alignment-symmetry",
    "source_path": "b.css",
    "polish_family": "fluency",
    "voice_fit": "strong",
    "location_expectedness": "expected",
    "body": "Known tags establish the ordering baseline."
  }
]
JSON
ranked_file="$LOG_BASE/polish/ranked-suggestions.json"
run_polish_ranking "$RUN_ID"
rank_rc=$?
assert_eq "defaulting run exits successfully" "0" "$rank_rc"
assert_eq "known tags outrank malformed tags" \
  "Known strong|Unknown tags" \
  "$(jq -r 'map(.title) | join("|")' "$ranked_file")"
assert_jq "malformed voice fit defaults to zero soul fit" "$ranked_file" \
  '.[] | select(.title == "Unknown tags") | .soul_fit == 0 and .effort_gap_multiplier == 1 and .polish_rank_x1000 == 0'

echo ""
echo "Test 4: equal ranks use deterministic tie-breakers"
RUN_ID="tie-run"
LOG_BASE="$TMPDIR/logs/$RUN_ID"
mkdir -p "$LOG_BASE/polish"
cat > "$LOG_BASE/polish/suggestions.json" <<'JSON'
[
  {
    "title": "Zulu",
    "domain": "hedonic",
    "lens_id": "voice-and-microcopy",
    "source_path": "z.md",
    "polish_family": "hedonic",
    "voice_fit": "strong",
    "location_expectedness": "expected",
    "body": "Same rank, later tie-breaker."
  },
  {
    "title": "Alpha",
    "domain": "fluency",
    "lens_id": "spacing-consistency",
    "source_path": "b.css",
    "polish_family": "fluency",
    "voice_fit": "strong",
    "location_expectedness": "expected",
    "body": "Same rank, sorted after alignment lens."
  },
  {
    "title": "Beta",
    "domain": "effort-signal",
    "lens_id": "empty-states",
    "source_path": "empty.md",
    "polish_family": "effort-signal",
    "voice_fit": "strong",
    "location_expectedness": "expected",
    "body": "Same rank, first by domain."
  },
  {
    "title": "Alpha",
    "domain": "fluency",
    "lens_id": "alignment-symmetry",
    "source_path": "a.css",
    "polish_family": "fluency",
    "voice_fit": "strong",
    "location_expectedness": "expected",
    "body": "Same rank, earlier fluency lens."
  }
]
JSON
ranked_file="$LOG_BASE/polish/ranked-suggestions.json"
run_polish_ranking "$RUN_ID"
rank_rc=$?
assert_eq "tie-breaker run exits successfully" "0" "$rank_rc"
assert_eq "equal ranks sort by domain, lens, title, and source path" \
  "effort-signal/empty-states/Beta/empty.md|fluency/alignment-symmetry/Alpha/a.css|fluency/spacing-consistency/Alpha/b.css|hedonic/voice-and-microcopy/Zulu/z.md" \
  "$(jq -r 'map([.domain, .lens_id, .title, .source_path] | join("/")) | join("|")' "$ranked_file")"

echo ""
echo "Test 5: zero polish suggestions produce an empty ranked artifact"
RUN_ID="empty-run"
LOG_BASE="$TMPDIR/logs/$RUN_ID"
mkdir -p "$LOG_BASE/polish"
printf '[]\n' > "$LOG_BASE/polish/suggestions.json"
ranked_file="$LOG_BASE/polish/ranked-suggestions.json"
run_polish_ranking "$RUN_ID"
rank_rc=$?
assert_eq "empty run exits successfully" "0" "$rank_rc"
assert_file_exists "empty ranked artifact exists" "$ranked_file"
assert_eq "empty ranked artifact is canonical JSON array" "[]" "$(jq -c '.' "$ranked_file")"

RUN_ID="missing-run"
LOG_BASE="$TMPDIR/logs/$RUN_ID"
mkdir -p "$LOG_BASE/polish"
ranked_file="$LOG_BASE/polish/ranked-suggestions.json"
run_polish_ranking "$RUN_ID"
rank_rc=$?
assert_eq "missing suggestions input exits successfully" "0" "$rank_rc"
assert_file_exists "missing-input ranked artifact exists" "$ranked_file"
assert_eq "missing-input ranked artifact is canonical JSON array" "[]" "$(jq -c '.' "$ranked_file")"

echo ""
echo "Test 6: canonical and per-lens fragments are collected and normalized"
RUN_ID="fragments-run"
LOG_BASE="$TMPDIR/logs/$RUN_ID"
mkdir -p "$LOG_BASE/polish/suggestions"
cat > "$LOG_BASE/polish/suggestions.json" <<'JSON'
{
  "title": "Canonical object with plural expectedness",
  "domain": "effort-signal",
  "lens_id": "forgotten-corners",
  "source_path": "scripts/rare.sh",
  "polish_family": "effort-signal",
  "voice_fit": "STRONG",
  "location_expectedness": "forgotten_corners",
  "body": "Canonical object input is accepted as one suggestion."
}
JSON
cat > "$LOG_BASE/polish/suggestions/010-offbrand-object.json" <<'JSON'
{
  "title": "Offbrand spelling variant",
  "domain": "hedonic",
  "lens_id": "fitting-easter-eggs",
  "source_path": "src/easter.ts",
  "polish_family": "hedonic",
  "voice_fit": "offbrand",
  "location_expectedness": "forgotten-corner",
  "body": "Offbrand spelling without a hyphen still gates the rank to zero."
}
JSON
cat > "$LOG_BASE/polish/suggestions/020-medium-array.json" <<'JSON'
[
  {
    "title": "Medium spaced no benchmark",
    "domain": "effort-signal",
    "lens_id": "loading-transparency",
    "source_path": "src/loading.ts",
    "polish_family": "effort-signal",
    "voice_fit": "medium",
    "location_expectedness": "no benchmark",
    "body": "Space-separated expectedness is normalized before ranking."
  },
  {
    "title": "Weak uppercase low expectation",
    "domain": "hedonic",
    "lens_id": "voice-and-microcopy",
    "source_path": "README.md",
    "polish_family": "hedonic",
    "voice_fit": "weak",
    "location_expectedness": "LOW_EXPECTATION",
    "body": "Uppercase underscore expectedness is normalized before ranking."
  }
]
JSON
ranked_file="$LOG_BASE/polish/ranked-suggestions.json"
run_polish_ranking "$RUN_ID"
rank_rc=$?
assert_eq "fragment collection run exits successfully" "0" "$rank_rc"
assert_jq "canonical object plus fragment array/object are all ranked" "$ranked_file" \
  'type == "array" and length == 4'
assert_eq "mixed inputs sort by normalized computed rank" \
  "Canonical object with plural expectedness|Medium spaced no benchmark|Weak uppercase low expectation|Offbrand spelling variant" \
  "$(jq -r 'map(.title) | join("|")' "$ranked_file")"
assert_eq "plural underscore forgotten-corners maps to fixed-point 1500" \
  "1500" \
  "$(jq -r '.[] | select(.title == "Canonical object with plural expectedness") | .polish_rank_x1000' "$ranked_file")"
assert_eq "spaced no-benchmark maps to floored fixed-point 877" \
  "877" \
  "$(jq -r '.[] | select(.title == "Medium spaced no benchmark") | .polish_rank_x1000' "$ranked_file")"
assert_eq "uppercase underscore low-expectation maps to fixed-point 180" \
  "180" \
  "$(jq -r '.[] | select(.title == "Weak uppercase low expectation") | .polish_rank_x1000' "$ranked_file")"
assert_jq "offbrand spelling variant gates rank to zero" "$ranked_file" \
  '.[] | select(.title == "Offbrand spelling variant") | .soul_fit == 0 and .polish_rank_x1000 == 0'

echo ""
echo "Test 7: local polish JSON outputs are collected and ranked"
RUN_ID="local-output-run"
LOG_BASE="$TMPDIR/logs/$RUN_ID"
local_output_dir="$LOG_BASE/rounds/round-1/lens-outputs"
ranked_file="$LOG_BASE/polish/ranked-suggestions.json"

mkdir -p "$local_output_dir/fluency/local-copy" "$local_output_dir/effort/local-corner"
cat > "$local_output_dir/fluency/local-copy/001-local-expected.json" <<'JSON'
{
  "title": "Local expected polish",
  "domain": "fluency",
  "lens_id": "local-copy",
  "source_path": "README.md",
  "polish_family": "fluency",
  "voice_fit": "strong",
  "location_expectedness": "expected",
  "body": "A local-mode polish suggestion."
}
JSON
cat > "$local_output_dir/effort/local-corner/001-forgotten-corner.json" <<'JSON'
{
  "title": "Local forgotten corner",
  "domain": "effort",
  "lens_id": "local-corner",
  "source_path": "scripts/rare.sh",
  "polish_family": "effort-signal",
  "voice_fit": "strong",
  "location_expectedness": "forgotten-corner",
  "body": "A local-mode corner suggestion."
}
JSON

run_polish_ranking "$RUN_ID"
rank_rc=$?
assert_eq "local-output collection run exits successfully" "0" "$rank_rc"
assert_jq "local-output JSON suggestions are ranked" "$ranked_file" \
  'type == "array" and length == 2 and all(.[]; has("polish_rank_x1000"))'
assert_eq "local-output suggestions sort by computed rank" \
  '["Local forgotten corner","Local expected polish"]' \
  "$(jq -c '[.[].title]' "$ranked_file")"
assert_eq "local-output forgotten corner rank is fixed-point 1500" \
  "1500" \
  "$(jq -r '.[] | select(.title == "Local forgotten corner") | .polish_rank_x1000' "$ranked_file")"

echo ""
echo "Test 8: explicit local output roots are collected and ranked"
RUN_ID="explicit-local-roots-run"
LOG_BASE="$TMPDIR/logs/$RUN_ID"
OUTPUT_DIR="$TMPDIR/custom-output"
CURRENT_ROUND_OUTPUT_DIR="$TMPDIR/current-round-output"
ranked_file="$LOG_BASE/polish/ranked-suggestions.json"

mkdir -p "$OUTPUT_DIR/fluency/output-root" "$CURRENT_ROUND_OUTPUT_DIR/hedonic/current-root"
cat > "$OUTPUT_DIR/fluency/output-root/001-output-root.json" <<'JSON'
{
  "title": "Explicit output root",
  "domain": "fluency",
  "lens_id": "output-root",
  "source_path": "app/ui.css",
  "polish_family": "fluency",
  "voice_fit": "strong",
  "location_expectedness": "expected",
  "body": "A suggestion written to a custom --output directory."
}
JSON
cat > "$CURRENT_ROUND_OUTPUT_DIR/hedonic/current-root/001-current-root.json" <<'JSON'
{
  "title": "Explicit current round root",
  "domain": "hedonic",
  "lens_id": "current-root",
  "source_path": "README.md",
  "polish_family": "hedonic",
  "voice_fit": "strong",
  "location_expectedness": "forgotten-corner",
  "body": "A suggestion written to CURRENT_ROUND_OUTPUT_DIR."
}
JSON

run_polish_ranking "$RUN_ID"
rank_rc=$?
assert_eq "explicit local roots run exits successfully" "0" "$rank_rc"
assert_jq "explicit OUTPUT_DIR and CURRENT_ROUND_OUTPUT_DIR suggestions are ranked" "$ranked_file" \
  'type == "array" and length == 2 and all(.[]; has("polish_rank_x1000"))'
assert_eq "explicit local roots sort by computed rank" \
  '["Explicit current round root","Explicit output root"]' \
  "$(jq -c '[.[].title]' "$ranked_file")"
assert_eq "explicit current round root rank is fixed-point 1500" \
  "1500" \
  "$(jq -r '.[] | select(.title == "Explicit current round root") | .polish_rank_x1000' "$ranked_file")"
unset OUTPUT_DIR CURRENT_ROUND_OUTPUT_DIR

echo ""
echo "Test 9: RUN_ID environment fallback is honored"
RUN_ID="env-fallback-run"
LOG_BASE="$TMPDIR/logs/$RUN_ID"
suggestions_file="$LOG_BASE/polish/suggestions.json"
ranked_file="$LOG_BASE/polish/ranked-suggestions.json"
mkdir -p "$LOG_BASE/polish"
cat > "$suggestions_file" <<'JSON'
[
  {
    "title": "Environment RUN_ID fallback",
    "domain": "fluency",
    "lens_id": "alignment-symmetry",
    "source_path": "app/ui.css",
    "polish_family": "fluency",
    "voice_fit": "strong",
    "location_expectedness": "expected",
    "body": "Calling without an explicit run id should use RUN_ID."
  }
]
JSON
run_polish_ranking
rank_rc=$?
assert_eq "no-argument ranking uses RUN_ID successfully" "0" "$rank_rc"
assert_file_exists "RUN_ID fallback ranked artifact exists" "$ranked_file"
assert_eq "RUN_ID fallback suggestion is ranked" \
  "Environment RUN_ID fallback:1000" \
  "$(jq -r '.[] | "\(.title):\(.polish_rank_x1000)"' "$ranked_file")"

echo ""
echo "Test 10: missing run identity and malformed JSON fail explicitly"
unset RUN_ID
rank_rc=0
run_polish_ranking >/dev/null 2>&1 || rank_rc=$?
assert_eq "ranking without RUN_ID fails" "1" "$rank_rc"

RUN_ID="malformed-run"
LOG_BASE="$TMPDIR/logs/$RUN_ID"
mkdir -p "$LOG_BASE/polish"
ranked_file="$LOG_BASE/polish/ranked-suggestions.json"
printf '{"title": "Broken JSON"\n' > "$LOG_BASE/polish/suggestions.json"
rank_rc=0
run_polish_ranking "$RUN_ID" >/dev/null 2>&1 || rank_rc=$?
assert_eq "malformed suggestion JSON fails the ranking stage" "1" "$rank_rc"
assert_eq "malformed JSON does not promote a ranked artifact" "missing" "$([[ -f "$ranked_file" ]] && printf 'exists' || printf 'missing')"

finish
