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

# Tests for issue #385 — the FORGE half of task-complexity routing: the
# `ensure_labels` (repolens.sh) pre-creation gate for the
# `repolens/complexity/<n>` labels. The registry half (parse/store/project/
# validate) is covered by test_ledger_complexity.sh; this file covers the label
# bootstrap, which lives inside repolens.sh and had a real, previously-DENIED
# defect: the gate must pre-create the five complexity labels ONLY for audit,
# bugreport, and branch-review, whose prompts actually instruct an agent to
# APPLY a `repolens/complexity/<n>` label. Every other mode
# references complexity zero times, so creating the labels there would litter the
# target repo with five unused labels per run.
#
# repolens.sh runs `main` at top level (no source guard), so it cannot be sourced
# to reach ensure_labels. Instead we EXTRACT the real function verbatim (the
# established repo alternative is a static grep, but that cannot verify the GATE —
# which modes get the labels — which is the exact axis that regressed). We source
# the extracted bytes and drive them with stubbed externals (log_info/die/
# forge_label_bootstrap) plus the globals ensure_labels reads. The stub captures
# the newline-delimited `label=color` bootstrap file BEFORE ensure_labels removes
# it, so we can assert exactly which labels the run would create. NO AI models are
# invoked — pure bash/jq, per CLAUDE.md.
# shellcheck disable=SC2329

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOLENS_SH="$SCRIPT_DIR/repolens.sh"

PASS=0
FAIL=0
TOTAL=0

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

pass_with() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail_with() {
  local desc="$1" detail="${2:-}"
  FAIL=$((FAIL + 1))
  echo "  FAIL: $desc"
  [[ -n "$detail" ]] && printf '    %s\n' "$detail"
  return 0
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" == "$expected" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "expected [$expected], got [$actual]"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "did not find '$needle' in: $haystack"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "unexpectedly found '$needle' in: $haystack"
  fi
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  [[ "$FAIL" -gt 0 ]] && exit 1
  exit 0
}

# --- Extract the real ensure_labels function verbatim from repolens.sh --------
# awk boundary: a top-level `ensure_labels() {` opener through the first column-0
# `}`. This is the whole-repo bash style (functions open/close at column 0), so
# the extraction stays valid as the body evolves — it always drives the CURRENT
# production bytes, never a reimplementation.
TOTAL=$((TOTAL + 1))
if [[ -f "$REPOLENS_SH" ]]; then
  pass_with "repolens.sh exists"
else
  fail_with "repolens.sh exists" "missing: $REPOLENS_SH"
  finish
fi

FN_FILE="$TMPDIR/ensure_labels.fn"
awk '/^ensure_labels\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$REPOLENS_SH" > "$FN_FILE"

TOTAL=$((TOTAL + 1))
if [[ -s "$FN_FILE" ]] \
   && head -1 "$FN_FILE" | grep -q '^ensure_labels() {' \
   && tail -1 "$FN_FILE" | grep -q '^}'; then
  pass_with "ensure_labels extracted as a complete function block"
else
  fail_with "ensure_labels extracted as a complete function block" \
    "extraction produced no clean opener/closer — repolens.sh style may have changed"
  finish
fi

# A colors fixture for the domain-label loop's `jq -r '.[$d] // "ededed"'`.
COLORS_JSON="$TMPDIR/colors.json"
printf '%s\n' '{"code":"aa11bb"}' > "$COLORS_JSON"

# drive_mode <mode>
#   Runs the real extracted ensure_labels in an isolated subshell for the given
#   MODE and prints the label=color bootstrap file the run would send to the
#   forge (captured by the forge_label_bootstrap stub before ensure_labels
#   deletes it). Empty output means the run created zero labels.
drive_mode() {
  local mode="$1"
  local cap="$TMPDIR/labels-$mode.txt"
  : > "$cap"
  # shellcheck disable=SC2034  # MODE/LENS_LIST/COLORS_FILE/SPEC_FILE/FORGE_REPO_SLUG are read by the sourced ensure_labels.
  (
    set -uo pipefail
    MODE="$mode"
    LENS_LIST=("code/example")
    COLORS_FILE="$COLORS_JSON"
    SPEC_FILE=""
    FORGE_REPO_SLUG="owner/repo"
    log_info() { :; }
    die() { echo "die: $*" >&2; exit 1; }
    # Capture the assembled label set BEFORE ensure_labels rm's it.
    forge_label_bootstrap() { cp "$2" "$cap"; }
    # shellcheck disable=SC1090
    source "$FN_FILE"
    ensure_labels
  ) >/dev/null 2>&1
  cat "$cap"
}

# ===========================================================================
echo "=== audit / bugreport / branch-review: the five complexity labels ARE pre-created ==="
# ===========================================================================
# These are the three modes whose prompts apply a repolens/complexity/<n> label,
# so the bootstrap must create all five up front (agents only apply, never
# create). The gradient is fixed green->red: 1=trivial ... 5=complex.
for mode in audit bugreport branch-review; do
  out="$(drive_mode "$mode")"
  assert_contains "$mode: complexity/1 label present"  "repolens/complexity/1=" "$out"
  assert_contains "$mode: complexity/5 label present"  "repolens/complexity/5=" "$out"

  # Exactly five complexity labels — no more, no fewer.
  cx_count="$(grep -c '^repolens/complexity/' <<<"$out" || true)"
  assert_eq "$mode: exactly 5 repolens/complexity labels" "5" "$cx_count"

  # The exact green->red gradient, index-mapped to the 1..5 tier. This pins the
  # color table (complexity_colors[cx-1]) so an off-by-one or a swapped color
  # regresses loudly.
  assert_contains "$mode: tier 1 -> trivial green c2e0c6" "repolens/complexity/1=c2e0c6" "$out"
  assert_contains "$mode: tier 2 -> bfd4f2"               "repolens/complexity/2=bfd4f2" "$out"
  assert_contains "$mode: tier 3 -> fbca04"               "repolens/complexity/3=fbca04" "$out"
  assert_contains "$mode: tier 4 -> ff9800"               "repolens/complexity/4=ff9800" "$out"
  assert_contains "$mode: tier 5 -> complex red d73a4a"   "repolens/complexity/5=d73a4a" "$out"

  # Regression guard: the complexity gate must not disturb the base job — the
  # per-lens domain label is still emitted (label_prefix:domain/lens + color).
  domain_prefix="$mode"
  [[ "$mode" == "branch-review" ]] && domain_prefix="regression"
  assert_contains "$mode: domain lens label still emitted" \
    "$domain_prefix:code/example=aa11bb" "$out"
done

# ===========================================================================
echo "=== every other mode: NO complexity labels are pre-created ==="
# ===========================================================================
# The DENIED defect this guards: the gate previously created the five labels for
# these modes too, none of which ever apply them. Each must emit zero
# repolens/complexity lines. (feature/bugfix/custom/opensource/content/
# spec-change reference complexity nowhere; discover/deploy/greenfield/polish are
# separate issue-emission families that also don't route by complexity.)
for mode in feature bugfix custom opensource content spec-change \
            discover deploy greenfield polish; do
  out="$(drive_mode "$mode")"
  assert_not_contains "$mode: no repolens/complexity label pre-created" \
    "repolens/complexity/" "$out"
done

# A representative non-complexity mode must STILL bootstrap its own domain label —
# proves the empty-complexity result above is the gate working, not ensure_labels
# silently producing nothing.
feature_out="$(drive_mode feature)"
assert_contains "feature: domain lens label still emitted (gate is selective, not a no-op)" \
  "feature:code/example=aa11bb" "$feature_out"

finish
