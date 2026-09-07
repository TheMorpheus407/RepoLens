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

# Tests for issue #358: end-to-end / integration test for Human Mode. Drives the
# REAL pipeline (human_review_bucketize -> render_human_review_digest ->
# human_review_heldback_summary) against ONE representative fixture registry and
# asserts the full noise-budget contract end-to-end, then a CLI --dry-run smoke
# of --human-review. This is the safety net on top of the five per-unit suites
# (flag / bucketing / render / grouping / accounting); its distinctive value is
# CROSS-COMPONENT CONSISTENCY — the rendered "showing M" numbers, the bucketizer
# per-bucket counts, and the held-back summary's surfaced/held_back must all agree
# on the same fixture, and surfaced + held_back == total with no record lost.
#
# Pure-function tests only; NO AI models are invoked — the fixture is a
# handwritten JSON-Lines registry, the renderer/bucketizer/summary are pure
# jq + bash, and the only repolens.sh invocations are --dry-run / --help (both
# exit before any agent call). Hard rule from CLAUDE.md: tests MUST NEVER call
# real models.
#
# Fixture (tests/fixtures/human-review/final/findings.jsonl), 49 records:
#   - bucket 1 top_critical_high:              12 crit/high  -> cap 10, held 2
#   - bucket 2 top_medium_security:            30 medium-sec -> cap 25, held 5
#   - bucket 3 test_quality:                    1 test-gap + 1 maintainability
#   - bucket 4 not_actionable_without_scanner:  1 external-dependency
#                                               + 1 needs-validation + scanner
#   - bucket 5 remainder:                       2 perf + 1 docs (multi-domain)
# Derived (must match the rendered digest AND the summary line):
#   surfaced  = min(12,10) + min(30,25) + 2 + 2 = 39
#   held_back = (12-10) + (30-25) + 3            = 10
#   surfaced + held_back = 49 == total           (no silent truncation)

set -uo pipefail
# shellcheck disable=SC2329  # helper functions are invoked indirectly

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_LIB="$SCRIPT_DIR/lib/core.sh"
RISK_LIB="$SCRIPT_DIR/lib/risk.sh"
HUMAN_REVIEW_LIB="$SCRIPT_DIR/lib/human_review.sh"
REPOLENS_SH="$SCRIPT_DIR/repolens.sh"
FIXTURE="$SCRIPT_DIR/tests/fixtures/human-review/final/findings.jsonl"

PASS=0
FAIL=0
TOTAL=0

TMP_PARENT="$SCRIPT_DIR/logs/test-human-review-e2e"
mkdir -p "$TMP_PARENT"
TMPROOT="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"
CREATED_RUN_IDS=()

FAKE_BIN="$TMPROOT/fake-bin"
mkdir -p "$FAKE_BIN"
for _agent in claude codex opencode agy; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/$_agent"
  chmod +x "$FAKE_BIN/$_agent"
done
export PATH="$FAKE_BIN:$PATH"

cleanup() {
  local run_id
  rm -rf "$TMPROOT"
  for run_id in "${CREATED_RUN_IDS[@]:-}"; do
    [[ -n "$run_id" ]] && rm -rf "$SCRIPT_DIR/logs/$run_id"
  done
  rmdir "$TMP_PARENT" 2>/dev/null || true
}
trap cleanup EXIT

pass_with() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

fail_with() {
  local desc="$1" detail="${2:-}"
  FAIL=$((FAIL + 1))
  echo "  FAIL: $desc"
  if [[ -n "$detail" ]]; then
    printf '    %s\n' "$detail"
  fi
}

assert_rc_zero() {
  local desc="$1" rc="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$rc" -eq 0 ]]; then pass_with "$desc"; else fail_with "$desc" "Expected rc 0, got $rc"; fi
}

assert_file_exists() {
  local desc="$1" f="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$f" ]]; then pass_with "$desc"; else fail_with "$desc" "expected file to exist: $f"; fi
}

# assert_no_crash — stderr shows no bash-level explosion (set -u / syntax /
#   command-not-found). Intentional warnings are fine.
assert_no_crash() {
  local desc="$1" errfile="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$errfile" ]] && grep -qiE 'unbound variable|syntax error|command not found' "$errfile"; then
    fail_with "$desc" "stderr indicates a crash: $(head -1 "$errfile")"
  else
    pass_with "$desc"
  fi
}

# assert_contains <desc> <file> <fixed-string>
assert_contains() {
  local desc="$1" f="$2" needle="$3"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$f" ]] && grep -qF -- "$needle" "$f"; then
    pass_with "$desc"
  else
    fail_with "$desc" "expected to find: $needle"
  fi
}

# assert_not_contains <desc> <file> <fixed-string>
assert_not_contains() {
  local desc="$1" f="$2" needle="$3"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$f" ]] && grep -qF -- "$needle" "$f"; then
    fail_with "$desc" "did not expect to find: $needle"
  else
    pass_with "$desc"
  fi
}

# assert_str_contains <desc> <haystack> <fixed-string>
assert_str_contains() {
  local desc="$1" hay="$2" needle="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$hay" == *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "expected to find: $needle (got: $hay)"
  fi
}

# assert_str_not_contains <desc> <haystack> <fixed-string>
assert_str_not_contains() {
  local desc="$1" hay="$2" needle="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$hay" == *"$needle"* ]]; then
    fail_with "$desc" "did not expect to find: $needle (got: $hay)"
  else
    pass_with "$desc"
  fi
}

# assert_eq <desc> <expected> <actual>
assert_eq() {
  local desc="$1" exp="$2" act="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$exp" == "$act" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "expected '$exp', got '$act'"
  fi
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

# section_slice <file> <"## Header"> — print the lines of one Markdown section:
#   from the line that STARTS WITH the given "## Header" (exclusive) up to (but
#   not including) the next "## " section header. index()==1 is a literal-prefix
#   match, so a header containing "/" (e.g. "## Top Critical / High") needs no
#   escaping. A "### " entry heading never starts with "## " (its third char is
#   "#", not a space), so entries are never mistaken for the next section.
section_slice() {
  awk -v s="$2" 'index($0, s) == 1 { p = 1; next } /^## / { if (p) p = 0 } p' "$1"
}

# CLI-smoke helpers (copied from the --human-review flag suite). A --dry-run
# invocation exits before any agent call; --local + --output bypass the
# forge-detection gate so a freshly-init'd no-origin repo still reaches the
# dry-run banner.
make_project() {
  local project="$1"
  mkdir -p "$project"
  git -C "$project" init -q
  printf '# human-review e2e test\n' > "$project/README.md"
  git -C "$project" -c user.email=t@t -c user.name=t add README.md >/dev/null 2>&1 || true
  git -C "$project" -c user.email=t@t -c user.name=t commit -q -m init >/dev/null 2>&1 || true
}

register_run_id_from() {
  local out_file="$1" run_id
  run_id="$(grep -oE 'RepoLens run [^ ]+ starting' "$out_file" 2>/dev/null | head -1 | awk '{print $3}')"
  if [[ -n "$run_id" ]]; then
    CREATED_RUN_IDS+=("$run_id")
  fi
}

run_dry() {
  local out_file="$1" name="$2"
  shift 2
  local project="$TMPROOT/project-$name"
  make_project "$project"
  bash "$REPOLENS_SH" \
    --project "$project" \
    --agent claude \
    --dry-run \
    --yes \
    --local \
    --output "$TMPROOT/issues-$name" \
    "$@" \
    >"$out_file" 2>&1
  local rc=$?
  register_run_id_from "$out_file"
  return "$rc"
}

# Extract the dry-run banner line reporting the resolved --human-review state.
hr_banner_line() {
  grep -iE '^[[:space:]]*human[ _-]?review' "$1" 2>/dev/null | head -1
}

# --- Source the library (core.sh + risk.sh first; harmless if unused). Assert on
# the FUNCTIONS, not the files. ---------------------------------------------------
# shellcheck source=/dev/null
[[ -f "$CORE_LIB" ]] && source "$CORE_LIB"
# shellcheck source=/dev/null
[[ -f "$RISK_LIB" ]] && source "$RISK_LIB"
if [[ -f "$HUMAN_REVIEW_LIB" ]]; then
  # shellcheck source=/dev/null
  source "$HUMAN_REVIEW_LIB"
fi

TOTAL=$((TOTAL + 1))
if declare -F human_review_bucketize >/dev/null 2>&1 \
   && declare -F render_human_review_digest >/dev/null 2>&1 \
   && declare -F human_review_heldback_summary >/dev/null 2>&1; then
  pass_with "human_review_bucketize + render_human_review_digest + human_review_heldback_summary are defined"
else
  fail_with "Human-mode pipeline functions are defined after sourcing lib/human_review.sh" \
    "a function is missing — cannot run the rest of the suite"
  finish
fi

# The committed fixture must be present and well-formed (the whole suite drives it).
assert_file_exists "fixture registry exists" "$FIXTURE"
TOTAL=$((TOTAL + 1))
if jq -e . "$FIXTURE" >/dev/null 2>&1; then
  pass_with "fixture registry is valid JSON-Lines"
else
  fail_with "fixture registry is valid JSON-Lines" "jq failed to parse $FIXTURE"
fi
FIX_TOTAL="$(grep -c . "$FIXTURE")"
assert_eq "fixture has 49 findings" "49" "$FIX_TOTAL"

# ===========================================================================
# Drive the REAL pipeline ONCE against the fixture: bucketize (for membership),
# render the digest, and capture the held-back summary. All three read the same
# registry under one LOG_BASE.
# ===========================================================================
LB="$TMPROOT/lb"
mkdir -p "$LB/final"
cp "$FIXTURE" "$LB/final/findings.jsonl"
OUT="$LB/final/HUMAN_REVIEW.md"
ERR="$TMPROOT/render-err.txt"

# shellcheck disable=SC2030,SC2031  # LOG_BASE is intentionally subshell-scoped
( export LOG_BASE="$LB"; render_human_review_digest "e2e-run" ) 2>"$ERR"
RENDER_RC=$?

BKT="$(human_review_bucketize "$LB/final/findings.jsonl")"

# shellcheck disable=SC2030,SC2031  # LOG_BASE is intentionally subshell-scoped
SUMMARY="$( export LOG_BASE="$LB"; human_review_heldback_summary "e2e-run" 2>>"$ERR" )"
SUMMARY_RC=$?

# ===========================================================================
# 1. Smoke: the renderer wrote a digest atomically, without crashing.
# ===========================================================================
assert_rc_zero    "render against the fixture -> rc 0" "$RENDER_RC"
assert_rc_zero    "held-back summary -> rc 0" "$SUMMARY_RC"
assert_no_crash   "pipeline does not crash" "$ERR"
assert_file_exists "render writes final/HUMAN_REVIEW.md" "$OUT"
assert_contains   "header carries the run id" "$OUT" "# Human Review — e2e-run"
assert_contains   "header carries the fixture total" "$OUT" "49 finding(s) across 5 buckets"
# Atomic write: no *.tmp.* leftover beside the final file.
TOTAL=$((TOTAL + 1))
if ls "$LB/final/"HUMAN_REVIEW.md.tmp.* >/dev/null 2>&1; then
  fail_with "atomic write leaves no tmp file behind" "found a leftover HUMAN_REVIEW.md.tmp.* file"
else
  pass_with "atomic write leaves no tmp file behind"
fi

# ===========================================================================
# 2. Bucket membership: EVERY finding lands in EXACTLY ONE bucket (the partition
#    is total and disjoint). Asserted from the bucketizer JSON, where ids are
#    unique keys — more robust than grepping the rendered Markdown.
# ===========================================================================
part="$(printf '%s' "$BKT" | jq -r '
  [ (.top_critical_high.items[], .top_medium_security.items[], .test_quality.items[],
     .not_actionable_without_scanner.items[], .remainder.items[]) | .id ]
  | "\(length) \(unique | length)"')"
assert_eq "each finding appears in exactly one bucket (ids flattened == unique == total)" \
  "49 49" "$part"

sum_counts="$(printf '%s' "$BKT" | jq -r '
  [ .top_critical_high.count, .top_medium_security.count, .test_quality.count,
    .not_actionable_without_scanner.count, .remainder.count ] | add')"
assert_eq "sum of the five bucket counts == total (no record lost or double-counted)" \
  "49" "$sum_counts"

# Per-bucket counts (the fixture shape).
assert_eq "bucket 1 (top_critical_high) count == 12"   "12" "$(printf '%s' "$BKT" | jq -r '.top_critical_high.count')"
assert_eq "bucket 2 (top_medium_security) count == 30" "30" "$(printf '%s' "$BKT" | jq -r '.top_medium_security.count')"
assert_eq "bucket 3 (test_quality) count == 2"          "2" "$(printf '%s' "$BKT" | jq -r '.test_quality.count')"
assert_eq "bucket 4 (not_actionable_without_scanner) count == 2" "2" "$(printf '%s' "$BKT" | jq -r '.not_actionable_without_scanner.count')"
assert_eq "bucket 5 (remainder) count == 3"             "3" "$(printf '%s' "$BKT" | jq -r '.remainder.count')"

# Caps live on the buckets; the two own-sections + remainder are uncapped (null).
assert_eq "bucket 1 cap == 10"  "10"   "$(printf '%s' "$BKT" | jq -r '.top_critical_high.cap')"
assert_eq "bucket 2 cap == 25"  "25"   "$(printf '%s' "$BKT" | jq -r '.top_medium_security.cap')"
assert_eq "bucket 3 cap == null (uncapped own section)"  "null" "$(printf '%s' "$BKT" | jq -r '.test_quality.cap')"
assert_eq "bucket 4 cap == null (uncapped own section)"  "null" "$(printf '%s' "$BKT" | jq -r '.not_actionable_without_scanner.cap')"
assert_eq "bucket 5 cap == null (uncapped remainder)"    "null" "$(printf '%s' "$BKT" | jq -r '.remainder.cap')"

# ===========================================================================
# 3. Caps (rendered): the visible slice is capped at 10 / 25 even though the
#    bucket retains all 12 / 30 (no truncation upstream). All five section
#    headers are present in the fixed order.
# ===========================================================================
assert_contains "section: Top Critical / High present" "$OUT" "## Top Critical / High"
assert_contains "section: Top Medium Security present"  "$OUT" "## Top Medium Security"
assert_contains "section: Test & Quality present"       "$OUT" "## Test & Quality"
assert_contains "section: Not Actionable Without a Scanner present" "$OUT" "## Not Actionable Without a Scanner"
assert_contains "section: Remainder present"            "$OUT" "## Remainder"

ch_slice="$(section_slice "$OUT" "## Top Critical / High")"
ms_slice="$(section_slice "$OUT" "## Top Medium Security")"
ch_shown="$(printf '%s\n' "$ch_slice" | grep -c '^### \[')"
ms_shown="$(printf '%s\n' "$ms_slice" | grep -c '^### \[')"
assert_eq "Top Critical / High shows exactly 10 entries (cap 10 bites on 12)" "10" "$ch_shown"
assert_eq "Top Medium Security shows exactly 25 entries (cap 25 bites on 30)" "25" "$ms_shown"

# ===========================================================================
# 4. Accounting arithmetic: each capped/own section emits "N total, showing M,
#    K more" with K == N - M, and the four such lines are the only ones (the
#    remainder uses a themed total line, not this form). No literal "null".
# ===========================================================================
assert_contains "Top Critical / High accounting: 12 total, showing 10, 2 more" \
  "$OUT" "12 total, showing 10, 2 more"
assert_contains "Top Medium Security accounting: 30 total, showing 25, 5 more" \
  "$OUT" "30 total, showing 25, 5 more"
assert_contains "Test & Quality accounting: 2 total, showing 2, 0 more" \
  "$OUT" "2 total, showing 2, 0 more"
assert_contains "Not Actionable accounting: 2 total, showing 2, 0 more" \
  "$OUT" "2 total, showing 2, 0 more"
assert_not_contains "no literal 'null' leaks into the digest" "$OUT" "null"

# Parse every accounting line; assert K == N - M and accumulate surfaced/held.
mapfile -t ACCT_LINES < <(grep -oE '[0-9]+ total, showing [0-9]+, [0-9]+ more' "$OUT")
assert_eq "exactly four 'N total, showing M, K more' accounting lines (the capped/own sections)" \
  "4" "${#ACCT_LINES[@]}"

sum_shown=0
sum_more=0
arith_ok=1
for line in "${ACCT_LINES[@]}"; do
  if [[ "$line" =~ ([0-9]+)\ total,\ showing\ ([0-9]+),\ ([0-9]+)\ more ]]; then
    n="${BASH_REMATCH[1]}"; m="${BASH_REMATCH[2]}"; k="${BASH_REMATCH[3]}"
    if [[ $((n - m)) -ne "$k" ]]; then arith_ok=0; fi
    sum_shown=$((sum_shown + m))
    sum_more=$((sum_more + k))
  else
    arith_ok=0
  fi
done
TOTAL=$((TOTAL + 1))
if [[ "$arith_ok" -eq 1 ]]; then
  pass_with "every accounting line satisfies K == N - M"
else
  fail_with "every accounting line satisfies K == N - M" "lines: ${ACCT_LINES[*]}"
fi

# ===========================================================================
# 5. Themed remainder: every leftover finding grouped by domain into <details>
#    blocks, ordered count desc then name asc, with a section total line.
# ===========================================================================
assert_contains "remainder heading carries the count" "$OUT" "## Remainder (3)"
assert_contains "remainder anchor id present" "$OUT" 'id="remainder"'
assert_contains "remainder section total line" "$OUT" "Other findings: 3 across 2 theme(s)."
assert_contains "remainder group: perf with 2 findings" "$OUT" "<summary>perf — 2 finding(s)</summary>"
assert_contains "remainder group: docs with 1 finding" "$OUT" "<summary>docs — 1 finding(s)</summary>"
# Group order: count desc, then domain name asc -> perf (2) before docs (1).
rem_order="$(grep -F '<summary>' "$OUT" | sed -E 's#^<summary>(.*) — [0-9]+ finding\(s\)</summary>$#\1#')"
assert_eq "remainder groups ordered count desc then name asc" $'perf\ndocs' "$rem_order"
# Escape-safety end-to-end: a hostile remainder title survives verbatim (the
# pipe / backtick / $() are data, never shell-evaluated).
assert_contains "hostile remainder title rendered verbatim" "$OUT" \
  'stale docs | pipe `tick` $(cmd)'

# ===========================================================================
# 6. Test/Quality and scanner sections are SEPARATE: each holds only its own
#    findings; neither leaks into the other.
# ===========================================================================
tq_slice="$(section_slice "$OUT" "## Test & Quality")"
na_slice="$(section_slice "$OUT" "## Not Actionable Without a Scanner")"
assert_str_contains "Test & Quality holds the test-gap finding" "$tq_slice" "missing tests for parser"
assert_str_contains "Test & Quality holds the maintainability finding" "$tq_slice" "god object needs refactor"
assert_str_not_contains "Test & Quality does NOT hold the external-dependency finding" \
  "$tq_slice" "vulnerable transitive dependency"
assert_str_not_contains "Test & Quality does NOT hold the scanner finding" \
  "$tq_slice" "possible secret in config"
assert_str_contains "Not Actionable holds the external-dependency finding" \
  "$na_slice" "vulnerable transitive dependency"
assert_str_contains "Not Actionable holds the needs-validation+scanner finding" \
  "$na_slice" "possible secret in config"
assert_str_not_contains "Not Actionable does NOT hold the test-gap finding" \
  "$na_slice" "missing tests for parser"
assert_str_not_contains "Not Actionable does NOT hold the maintainability finding" \
  "$na_slice" "god object needs refactor"

# ===========================================================================
# 7. No silent truncation — the headline invariant + cross-component consistency.
#    The held-back summary, the bucketizer counts, and the rendered "showing M"
#    numbers must all agree on the same fixture.
# ===========================================================================
assert_str_contains "summary uses the loggable 'Human review:' prefix" "$SUMMARY" "Human review:"
assert_str_contains "summary reports 49 findings"  "$SUMMARY" "49 findings"
assert_str_contains "summary reports 39 surfaced"  "$SUMMARY" "39 surfaced"
assert_str_contains "summary reports 10 held back" "$SUMMARY" "10 held back"
assert_str_contains "summary reports critical/high surplus +2"    "$SUMMARY" "critical/high +2"
assert_str_contains "summary reports medium-security surplus +5"  "$SUMMARY" "medium-security +5"
assert_str_contains "summary reports remainder collapsed across 2 themes" \
  "$SUMMARY" "remainder collapsed across 2 theme(s)"

# Parse the summary numbers; assert the reconciliation identity.
TOTAL=$((TOTAL + 1))
if [[ "$SUMMARY" =~ ([0-9]+)\ findings,\ ([0-9]+)\ surfaced,\ ([0-9]+)\ held\ back ]]; then
  s_total="${BASH_REMATCH[1]}"; s_surf="${BASH_REMATCH[2]}"; s_held="${BASH_REMATCH[3]}"
  if [[ "$s_total" -eq "$FIX_TOTAL" && $((s_surf + s_held)) -eq "$s_total" ]]; then
    pass_with "reconciliation: surfaced + held_back == total == fixture lines"
  else
    fail_with "reconciliation: surfaced + held_back == total == fixture lines" \
      "total=$s_total surfaced=$s_surf held=$s_held fixture=$FIX_TOTAL"
  fi
else
  s_total=""; s_surf=""; s_held=""
  fail_with "reconciliation: surfaced + held_back == total == fixture lines" \
    "could not parse the summary numbers from: $SUMMARY"
fi

# Cross-component: the summary's surfaced count == the SUM of the rendered
# sections' "showing M" numbers (the digest and the summary agree on what is
# surfaced). sum_shown = 10 + 25 + 2 + 2 = 39.
assert_eq "summary surfaced == sum of rendered 'showing M' counts" "$s_surf" "$sum_shown"

# Cross-component: the summary's held_back == the cap surplus (sum of rendered
# 'K more') + the whole collapsed remainder. sum_more = 2 + 5 + 0 + 0 = 7;
# remainder = 3; 7 + 3 = 10.
rem_count="$(printf '%s' "$BKT" | jq -r '.remainder.count')"
assert_eq "summary held_back == sum of rendered 'K more' + remainder count" \
  "$s_held" "$((sum_more + rem_count))"

# Cross-component: the per-bucket surplus reported in the summary equals the
# rendered "K more" for buckets 1 and 2.
ch_acct="$(printf '%s\n' "$ch_slice" | grep -oE '[0-9]+ total, showing [0-9]+, [0-9]+ more' | head -1)"
ms_acct="$(printf '%s\n' "$ms_slice" | grep -oE '[0-9]+ total, showing [0-9]+, [0-9]+ more' | head -1)"
ch_more=""; ms_more=""
[[ "$ch_acct" =~ ([0-9]+)\ more ]] && ch_more="${BASH_REMATCH[1]}"
[[ "$ms_acct" =~ ([0-9]+)\ more ]] && ms_more="${BASH_REMATCH[1]}"
assert_str_contains "summary critical/high surplus == rendered Top Critical/High 'K more'" \
  "$SUMMARY" "critical/high +$ch_more"
assert_str_contains "summary medium-security surplus == rendered Top Medium Security 'K more'" \
  "$SUMMARY" "medium-security +$ms_more"

# ===========================================================================
# 8. Determinism: the same fixture renders byte-identically across runs.
# ===========================================================================
cp "$OUT" "$TMPROOT/first.md"
# shellcheck disable=SC2030,SC2031  # LOG_BASE is intentionally subshell-scoped
( export LOG_BASE="$LB"; render_human_review_digest "e2e-run" ) 2>/dev/null
TOTAL=$((TOTAL + 1))
if cmp -s "$TMPROOT/first.md" "$OUT"; then
  pass_with "render is deterministic (byte-identical across runs)"
else
  fail_with "render is deterministic (byte-identical across runs)" "second render differs"
fi

# ===========================================================================
# 9. CLI smoke (no real agent): --help advertises the flag; --dry-run accepts it
#    and reports the resolved boolean in the banner. --dry-run exits before any
#    agent call, satisfying the "never invoke a real model" rule.
# ===========================================================================
help_out="$(bash "$REPOLENS_SH" --help 2>&1)"
help_rc=$?
assert_rc_zero "repolens.sh --help exits 0" "$help_rc"
assert_str_contains "help advertises --human-review" "$help_out" "--human-review"
assert_str_contains "help documents the REPOLENS_HUMAN_REVIEW env fallback" \
  "$help_out" "REPOLENS_HUMAN_REVIEW"

dry_out="$TMPROOT/dry-human-review.txt"
run_dry "$dry_out" "human-review" --human-review
dry_rc=$?
assert_rc_zero "repolens.sh --dry-run --human-review exits 0" "$dry_rc"
assert_str_not_contains "no Unknown argument error for --human-review" \
  "$(cat "$dry_out")" "Unknown argument"
assert_str_contains "dry-run banner reports a human-review line" \
  "$(hr_banner_line "$dry_out")" "review"
assert_str_contains "dry-run banner resolves --human-review to true" \
  "$(hr_banner_line "$dry_out")" "true"

# ===========================================================================
# 10. Finalize wiring (static): the finalize hook ties the whole pipeline
#     together — gated on HUMAN_REVIEW, calls the renderer AND the held-back
#     summary. Running repolens.sh past the gate would invoke real agents
#     (forbidden), so we assert the wiring statically.
# ===========================================================================
if [[ -f "$REPOLENS_SH" ]]; then
  assert_contains "repolens.sh calls render_human_review_digest" "$REPOLENS_SH" "render_human_review_digest"
  assert_contains "repolens.sh calls human_review_heldback_summary" "$REPOLENS_SH" "human_review_heldback_summary"
  assert_contains "finalize hook is gated on HUMAN_REVIEW" "$REPOLENS_SH" 'HUMAN_REVIEW:-false'
else
  echo "  (skip) repolens.sh not found at $REPOLENS_SH — wiring assertions skipped"
fi

finish
