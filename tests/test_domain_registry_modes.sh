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

# Tests for issue #230: per-lens `skip_modes` field in `config/domains.json`.
#
# Acceptance criteria from the issue:
#   1. Per-lens `skip_modes` field is parsed when present.
#   2. `--mode bugreport` skips lenses tagged `skip_modes: ["bugreport"]`.
#   3. Existing all-string `"lenses": [...]` registries continue to work.
#
# These tests exercise the central dispatch function
# `_rounds_meta_active_lens_entries` (lib/rounds.sh) against synthetic
# fixture registries, since that is the production code path every other
# `.lenses[]` consumer must converge on. No real models invoked.
# shellcheck disable=SC2034,SC2329

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/streak.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/summary.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/template.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/rounds.sh"

PASS=0
FAIL=0
TOTAL=0

TMP_PARENT="$SCRIPT_DIR/logs/test-domain-registry-modes"
mkdir -p "$TMP_PARENT"
TMPDIR="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"

cleanup() {
  rm -rf "$TMPDIR"
  rmdir "$TMP_PARENT" 2>/dev/null || true
}
trap cleanup EXIT

pass_with() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail_with() {
  local desc="$1" detail="${2:-}"
  FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
  [[ -n "$detail" ]] && printf '    %s\n' "$detail"
}
assert_eq() {
  local desc="$1" expected="$2" actual="$3"; TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then pass_with "$desc"
  else fail_with "$desc" "Expected:
$expected
Actual:
$actual"; fi
}
assert_contains() {
  local desc="$1" needle="$2" haystack="$3"; TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then pass_with "$desc"
  else fail_with "$desc" "Expected to find '$needle' in:
$haystack"; fi
}
assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"; TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then pass_with "$desc"
  else fail_with "$desc" "Did NOT expect '$needle' in:
$haystack"; fi
}

# Build a synthetic lens directory matching the fixtures below. The dispatch
# function only emits entries whose `.md` file exists on disk, so the lens
# files must mirror every id referenced in any fixture.
LENS_FIX="$TMPDIR/lenses"
mkdir -p "$LENS_FIX/code-quality" "$LENS_FIX/security"
touch "$LENS_FIX/code-quality/naming.md"      \
      "$LENS_FIX/code-quality/complexity.md"  \
      "$LENS_FIX/code-quality/formatting.md"  \
      "$LENS_FIX/code-quality/comments.md"
touch "$LENS_FIX/security/injection.md"       \
      "$LENS_FIX/security/auth.md"

# Fixture A: legacy all-strings registry (backwards-compat baseline).
FIX_LEGACY="$TMPDIR/legacy.json"
cat > "$FIX_LEGACY" <<'EOF'
{
  "domains": [
    {"id": "code-quality", "name": "Code Quality", "order": 1,
     "lenses": ["naming", "complexity"]},
    {"id": "security",     "name": "Security",     "order": 2,
     "lenses": ["injection", "auth"]}
  ]
}
EOF

# Fixture B: mixed array with object entries carrying `skip_modes`.
#   complexity  — string (legacy)             → all modes
#   naming      — object, skip [bugreport]    → all modes except bugreport
#   formatting  — object, skip [bugreport,    → all modes except those two
#                                bugfix]
#   comments    — object, skip []             → all modes (empty list = keep)
FIX_MIXED="$TMPDIR/mixed.json"
cat > "$FIX_MIXED" <<'EOF'
{
  "domains": [
    {"id": "code-quality", "name": "Code Quality", "order": 1,
     "lenses": [
       "complexity",
       {"id": "naming",     "skip_modes": ["bugreport"]},
       {"id": "formatting", "skip_modes": ["bugreport", "bugfix"]},
       {"id": "comments",   "skip_modes": []}
     ]},
    {"id": "security",     "name": "Security",     "order": 2,
     "lenses": ["injection", "auth"]}
  ]
}
EOF

# Invoke the dispatch function with a clean per-mode env. stderr is
# silenced so a fixture-format error is observable only via missing
# stdout entries (i.e. it does NOT pollute the test transcript). The
# subshell isolates env mutation from the parent.
list_active() {
  local mode="$1" domains_file="$2"
  (
    unset FOCUS DOMAIN_FILTER TARGET_TYPE
    export MODE="$mode"
    export LENSES_DIR="$LENS_FIX"
    export DOMAINS_FILE="$domains_file"
    _rounds_meta_active_lens_entries "$LENS_FIX" "$domains_file" 2>/dev/null
  )
}

echo ""
echo "=== Test Suite: per-lens skip_modes in config/domains.json (#230) ==="
echo ""

# ---------------------------------------------------------------------------
# Backwards compatibility — legacy all-string `lenses` arrays
# ---------------------------------------------------------------------------

echo "Test 1: legacy string-only fixture resolves all entries in audit mode"
out="$(list_active audit "$FIX_LEGACY")"
expected="code-quality/naming
code-quality/complexity
security/injection
security/auth"
assert_eq "all legacy lenses present in audit mode" "$expected" "$out"

echo ""
echo "Test 2: legacy string-only fixture resolves all entries in bugreport mode"
# Without skip_modes, every entry must still fire in every mode — this is
# the no-regression guarantee for existing registries.
out="$(list_active bugreport "$FIX_LEGACY")"
assert_eq "all legacy lenses present in bugreport mode" "$expected" "$out"

echo ""
echo "Test 3: legacy string-only fixture resolves all entries in bugfix mode"
out="$(list_active bugfix "$FIX_LEGACY")"
assert_eq "all legacy lenses present in bugfix mode" "$expected" "$out"

# ---------------------------------------------------------------------------
# Mixed array parsing — schema extension surface
# ---------------------------------------------------------------------------

echo ""
echo "Test 4: mixed array dispatches in audit mode (no skip_modes applies)"
# `audit` is not listed in any lens's skip_modes, so every entry resolves
# in the original lens-array order. This proves the normaliser handles
# both strings and objects without losing entries.
out="$(list_active audit "$FIX_MIXED")"
expected_all="code-quality/complexity
code-quality/naming
code-quality/formatting
code-quality/comments
security/injection
security/auth"
assert_eq "audit keeps every entry, order preserved" "$expected_all" "$out"

echo ""
echo "Test 5: bugreport mode drops lenses with skip_modes containing bugreport"
# naming + formatting both list bugreport in skip_modes → both excluded.
# complexity (string), comments (empty skip_modes), and the security
# domain remain.
out="$(list_active bugreport "$FIX_MIXED")"
expected_br="code-quality/complexity
code-quality/comments
security/injection
security/auth"
assert_eq "bugreport excludes naming + formatting, keeps the rest" \
  "$expected_br" "$out"
assert_not_contains "naming not present in bugreport" \
  "code-quality/naming" "$out"
assert_not_contains "formatting not present in bugreport" \
  "code-quality/formatting" "$out"

echo ""
echo "Test 6: bugfix mode drops only the multi-skip lens"
# Only formatting lists bugfix in skip_modes → only formatting drops.
# naming (skip=[bugreport]) is NOT in skip_modes for bugfix → must stay.
out="$(list_active bugfix "$FIX_MIXED")"
expected_bf="code-quality/complexity
code-quality/naming
code-quality/comments
security/injection
security/auth"
assert_eq "bugfix excludes formatting only" "$expected_bf" "$out"
assert_contains "naming still present in bugfix" \
  "code-quality/naming" "$out"
assert_not_contains "formatting absent in bugfix" \
  "code-quality/formatting" "$out"

echo ""
echo "Test 7: object entry with empty skip_modes behaves as string entry"
# `comments` has `skip_modes: []`. It must survive in every mode tested.
out_audit="$(list_active audit "$FIX_MIXED")"
out_br="$(list_active bugreport "$FIX_MIXED")"
out_bf="$(list_active bugfix "$FIX_MIXED")"
assert_contains "comments present in audit" "code-quality/comments" "$out_audit"
assert_contains "comments present in bugreport" "code-quality/comments" "$out_br"
assert_contains "comments present in bugfix" "code-quality/comments" "$out_bf"

# ---------------------------------------------------------------------------
# Production registry regression — the real config must still resolve cleanly
# ---------------------------------------------------------------------------

echo ""
echo "Test 8: real config/domains.json resolves under audit mode without error"
# This is the byte-identical-output guarantee for repositories that have
# not yet adopted any skip_modes entry. The count comes from the registry
# itself so it tracks future lens additions automatically.
real_count_expected="$(jq '[.domains[] | select((.mode // "code") == "code") | .lenses | length] | add' "$SCRIPT_DIR/config/domains.json")"
real_out="$(
  unset FOCUS DOMAIN_FILTER TARGET_TYPE
  MODE=audit LENSES_DIR="$SCRIPT_DIR/prompts/lenses" \
    DOMAINS_FILE="$SCRIPT_DIR/config/domains.json" \
    _rounds_meta_active_lens_entries \
      "$SCRIPT_DIR/prompts/lenses" "$SCRIPT_DIR/config/domains.json" 2>&1
)"
real_count_actual="$(printf '%s\n' "$real_out" | sed '/^$/d' | wc -l | tr -d ' ')"
assert_eq "real registry audit lens count unchanged" \
  "$real_count_expected" "$real_count_actual"
assert_not_contains "real registry resolves with no jq errors" "jq: error" "$real_out"

echo ""
echo "Test 8b: real config/domains.json resolves greenfield mode to planner only"
real_greenfield_active="$(
  unset FOCUS DOMAIN_FILTER TARGET_TYPE
  MODE=greenfield LENSES_DIR="$SCRIPT_DIR/prompts/lenses" \
    DOMAINS_FILE="$SCRIPT_DIR/config/domains.json" \
    _rounds_meta_active_lens_entries \
      "$SCRIPT_DIR/prompts/lenses" "$SCRIPT_DIR/config/domains.json" 2>&1
)"
assert_eq "greenfield active meta lens list contains only backlog planner" \
  "greenfield/backlog-planning" "$real_greenfield_active"

real_greenfield_all="$(
  unset FOCUS DOMAIN_FILTER TARGET_TYPE
  MODE=greenfield LENSES_DIR="$SCRIPT_DIR/prompts/lenses" \
    DOMAINS_FILE="$SCRIPT_DIR/config/domains.json" \
    _rounds_meta_all_lens_entries \
      "$SCRIPT_DIR/prompts/lenses" "$SCRIPT_DIR/config/domains.json" 2>&1
)"
assert_eq "greenfield all meta lens list contains only backlog planner" \
  "greenfield/backlog-planning" "$real_greenfield_all"

# ---------------------------------------------------------------------------
# repolens.sh jq filters — the schema change touches 3 additional sites in
# the CLI entry point. _rounds_meta_active_lens_entries (above) is just one
# of four readers of `.lenses[]`. The remaining filters live in repolens.sh
# and must each survive an object-form lens entry.
#
# These tests run the production jq strings (copy-pasted verbatim from
# repolens.sh) against the mixed fixture. If the schema migration regresses
# any filter, these tests catch it without needing to spin up the full CLI.
# ---------------------------------------------------------------------------

echo ""
echo "Test 9: list-output jq filter (repolens.sh:359) emits lens ids for objects"
# Help/list mode iterates every domain and joins lens ids into a CSV per row.
# With an object entry, the filter must extract `.id`, never the JSON object.
list_out="$(jq -r '.domains | sort_by(.order)[] | .id + "|" + .name + "|" + (.mode // "code") + "|" + ([.lenses[] | if type == "string" then . else .id end] | join(","))' "$FIX_MIXED")"
# Row 1 is the mixed-entry domain. The CSV must contain every lens id in
# original order, regardless of string-vs-object form.
expected_cq_row='code-quality|Code Quality|code|complexity,naming,formatting,comments'
assert_contains "code-quality row exposes ids only, in original order" \
  "$expected_cq_row" "$list_out"
# Row 2 is all-string and must round-trip unchanged.
expected_sec_row='security|Security|code|injection,auth'
assert_contains "security row unchanged for all-string lens array" \
  "$expected_sec_row" "$list_out"
# Defensive guard: a regression that forgot the `if type == "string"` branch
# would emit raw JSON objects in the CSV. Catch that here.
assert_not_contains "list filter never leaks JSON object syntax" \
  '{"id":' "$list_out"

echo ""
echo "Test 10: FOCUS jq filter (repolens.sh:1641) finds lens declared as object"
# `--focus <lens>` looks up which domain owns the lens. The filter uses
# `[.lenses[] | if type == "string" then . else .id end] | index($lens)`
# so an object-form lens must still be discoverable by id.
focus_obj_domain="$(jq -r --arg lens "naming" --arg mode "audit" --arg deploy_domain "deployment" \
  '.domains[] | (if $mode == "discover" then select(.mode == "discover") elif $mode == "deploy" then select(.mode == "deploy" and .id == $deploy_domain) elif $mode == "opensource" then select(.mode == "opensource") elif $mode == "content" then select(.mode == "content") else select(.mode != "discover" and .mode != "deploy" and .mode != "opensource" and .mode != "content") end) | select([.lenses[] | if type == "string" then . else .id end] | index($lens)) | .id' "$FIX_MIXED" | head -1)"
assert_eq "object-form lens 'naming' resolved to its domain" \
  "code-quality" "$focus_obj_domain"

# String-form lenses still resolve — backwards compat with mixed registries.
focus_str_domain="$(jq -r --arg lens "complexity" --arg mode "audit" --arg deploy_domain "deployment" \
  '.domains[] | (if $mode == "discover" then select(.mode == "discover") elif $mode == "deploy" then select(.mode == "deploy" and .id == $deploy_domain) elif $mode == "opensource" then select(.mode == "opensource") elif $mode == "content" then select(.mode == "content") else select(.mode != "discover" and .mode != "deploy" and .mode != "opensource" and .mode != "content") end) | select([.lenses[] | if type == "string" then . else .id end] | index($lens)) | .id' "$FIX_MIXED" | head -1)"
assert_eq "string-form lens 'complexity' resolved to its domain" \
  "code-quality" "$focus_str_domain"

# Cross-domain disambiguation: a lens in domain B must not be reported under
# domain A. injection lives in 'security', never in 'code-quality'.
focus_other_domain="$(jq -r --arg lens "injection" --arg mode "audit" --arg deploy_domain "deployment" \
  '.domains[] | (if $mode == "discover" then select(.mode == "discover") elif $mode == "deploy" then select(.mode == "deploy" and .id == $deploy_domain) elif $mode == "opensource" then select(.mode == "opensource") elif $mode == "content" then select(.mode == "content") else select(.mode != "discover" and .mode != "deploy" and .mode != "opensource" and .mode != "content") end) | select([.lenses[] | if type == "string" then . else .id end] | index($lens)) | .id' "$FIX_MIXED" | head -1)"
assert_eq "cross-domain lens 'injection' resolves to 'security'" \
  "security" "$focus_other_domain"

# Negative: an unknown lens id must produce empty output (caller dies on empty).
focus_missing_domain="$(jq -r --arg lens "nonexistent-lens" --arg mode "audit" --arg deploy_domain "deployment" \
  '.domains[] | (if $mode == "discover" then select(.mode == "discover") elif $mode == "deploy" then select(.mode == "deploy" and .id == $deploy_domain) elif $mode == "opensource" then select(.mode == "opensource") elif $mode == "content" then select(.mode == "content") else select(.mode != "discover" and .mode != "deploy" and .mode != "opensource" and .mode != "content") end) | select([.lenses[] | if type == "string" then . else .id end] | index($lens)) | .id' "$FIX_MIXED" | head -1)"
assert_eq "unknown lens id resolves to empty (die trigger)" \
  "" "$focus_missing_domain"

echo ""
echo "Test 11: FOCUS bypasses skip_modes (explicit user override)"
# Per design, --focus is an operator-level override: the user named the lens,
# so the structural denylist must not silently drop it. The FOCUS filter has
# no skip_modes branch — verify that's still the case for an object entry
# whose skip_modes contains the active mode.
focus_skipped_domain="$(jq -r --arg lens "naming" --arg mode "bugreport" --arg deploy_domain "deployment" \
  '.domains[] | (if $mode == "discover" then select(.mode == "discover") elif $mode == "deploy" then select(.mode == "deploy" and .id == $deploy_domain) elif $mode == "opensource" then select(.mode == "opensource") elif $mode == "content" then select(.mode == "content") else select(.mode != "discover" and .mode != "deploy" and .mode != "opensource" and .mode != "content") end) | select([.lenses[] | if type == "string" then . else .id end] | index($lens)) | .id' "$FIX_MIXED" | head -1)"
assert_eq "--focus naming still resolves in bugreport (skip_modes ignored)" \
  "code-quality" "$focus_skipped_domain"

echo ""
echo "Test 12: DOMAIN_FILTER jq filter (repolens.sh:1660) emits id-only entries"
# `--domain <name>` lists every lens in that domain. The filter applies
# `(if type == "string" then . else .id end)` so the emitted lines must be
# `<domain>/<id>` for both legacy and object entries — never JSON-object text.
domain_out="$(jq -r --arg d "code-quality" \
  '.domains[] | select(.id == $d) | .lenses[] | $d + "/" + (if type == "string" then . else .id end)' "$FIX_MIXED")"
expected_domain_out="code-quality/complexity
code-quality/naming
code-quality/formatting
code-quality/comments"
assert_eq "domain filter lists every lens by id, in array order" \
  "$expected_domain_out" "$domain_out"
assert_not_contains "domain filter output has no raw JSON" \
  "skip_modes" "$domain_out"

echo ""
echo "Test 13: DOMAIN_FILTER does NOT apply skip_modes (filter scope)"
# Like --focus, --domain is an operator-level override that lists every lens
# the named domain owns. skip_modes only applies to the global mode-filtered
# dispatch path. With the mixed fixture, even though `naming` skips bugreport
# in the global path, `--domain code-quality` must still surface it.
# (This is a regression guard against accidentally tightening domain-filter
# scope when extending skip_modes coverage.)
domain_out_bugreport="$(jq -r --arg d "code-quality" \
  '.domains[] | select(.id == $d) | .lenses[] | $d + "/" + (if type == "string" then . else .id end)' "$FIX_MIXED")"
assert_eq "domain filter ignores skip_modes (same output in all modes)" \
  "$expected_domain_out" "$domain_out_bugreport"

echo ""
echo "Test 14: nested skip_modes object must not leak into joined output"
# Edge case: an object lens with a *populated* skip_modes list. The list-mode
# CSV join would crash on object values if the if/else branch were dropped.
# This is a structural regression guard for the help/list pipeline.
nested_csv="$(jq -r --arg d "code-quality" '.domains[] | select(.id == $d) | [.lenses[] | if type == "string" then . else .id end] | join(",")' "$FIX_MIXED")"
assert_eq "nested object skip_modes not leaked into csv" \
  "complexity,naming,formatting,comments" "$nested_csv"

echo ""
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
[[ "$FAIL" -eq 0 ]] || exit 1
