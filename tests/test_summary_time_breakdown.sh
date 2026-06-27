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

# Tests for issue #340: emit a final time-breakdown report.
#
# A new helper `summary_time_breakdown <summary_file> [top_n]` in lib/summary.sh
# rolls up the per-lens `duration_seconds` recorded in #337 and prints a
# human-readable breakdown to stdout:
#   - total wall time and total lens-seconds,
#   - the top-N slowest individual lens-runs (default 10, descending),
#   - per-domain summed duration_seconds (descending).
#
# Acceptance criteria exercised here:
#   AC1: end-of-run output includes a "Time breakdown" section with the slowest
#        lenses and per-domain totals.
#   AC2: no error when duration_seconds is missing/null (prints nothing or a
#        one-line "no timing data"), exit 0.
#   AC3: durations are human-formatted (e.g. "2h 13m"), not raw seconds.
#
# These are BEHAVIORAL tests against the public helper. They are format-tolerant
# where the issue leaves latitude (lens key separator, exact section wording) and
# strict where the issue pins a contract (descending order, top-N cap, the
# status_format_duration output, graceful degradation). No real models.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Source both libs so the real status_format_duration is exercised by the helper.
# shellcheck disable=SC1091
# shellcheck source=../lib/status.sh
source "$SCRIPT_DIR/lib/status.sh"
# shellcheck disable=SC1091
# shellcheck source=../lib/summary.sh
source "$SCRIPT_DIR/lib/summary.sh"

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
    echo "    Expected: $(printf '%s' "$expected" | head -3)"
    echo "    Actual:   $(printf '%s' "$actual" | head -3)"
  fi
}

# yes/no: does $1 (needle) appear as a literal substring of $2 (haystack)?
contains() {
  case "$2" in
    *"$1"*) echo "yes" ;;
    *)      echo "no" ;;
  esac
}

# assert_before: assert that literal $3 appears on an earlier line than $4 in $2.
assert_before() {
  local desc="$1" hay="$2" a="$3" b="$4" la lb result="no"
  la="$(grep -nF -- "$a" <<<"$hay" | head -1 | cut -d: -f1)"
  lb="$(grep -nF -- "$b" <<<"$hay" | head -1 | cut -d: -f1)"
  if [[ -n "$la" && -n "$lb" ]] && (( la < lb )); then
    result="yes"
  fi
  assert_eq "$desc" "yes" "$result"
}

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "=== summary_time_breakdown (issue #340) ==="

# =====================================================================
# Test 1: AC1 — "Time breakdown" section + slowest lenses in descending order.
#   Durations: quality/gamma=600 > perf/alpha=300 > security/beta=120.
#   Lens names are distinct from every domain name so grep ordering on the
#   lens name is unambiguous and separator-agnostic.
# =====================================================================
echo ""
echo "Test 1: slowest lenses listed in descending duration order"
F1="$TMPDIR/order.json"
init_summary "$F1" "test-run" "/tmp/project" "audit" "claude" "" ""
record_lens "$F1" "quality"  "gamma" 1 "completed" 0 0 "" "" 600
record_lens "$F1" "perf"     "alpha" 1 "completed" 0 0 "" "" 300
record_lens "$F1" "security" "beta"  1 "completed" 0 0 "" "" 120
out1="$(summary_time_breakdown "$F1" 10 2>/dev/null)"
assert_eq "output includes a 'Time breakdown' section header" "yes" "$(contains "Time breakdown" "$out1")"
assert_eq "slowest lens (gamma) is present" "yes" "$(contains "gamma" "$out1")"
assert_eq "all three lens names present" "yesyesyes" \
  "$(contains gamma "$out1")$(contains alpha "$out1")$(contains beta "$out1")"
assert_before "gamma (600s) listed before alpha (300s)" "$out1" "gamma" "alpha"
assert_before "alpha (300s) listed before beta (120s)" "$out1" "alpha" "beta"

# =====================================================================
# Test 2: top-N cap — with top_n=2, only the two slowest appear; the third
#   (beta, the smallest) must be excluded entirely. Lens names never appear in
#   the per-domain section (which uses domain names), so absence is decisive.
# =====================================================================
echo ""
echo "Test 2: top_n caps the slowest list"
out2="$(summary_time_breakdown "$F1" 2 2>/dev/null)"
assert_eq "top-2 keeps slowest (gamma)"           "yes" "$(contains "gamma" "$out2")"
assert_eq "top-2 keeps second slowest (alpha)"    "yes" "$(contains "alpha" "$out2")"
assert_eq "top-2 excludes third slowest (beta)"   "no"  "$(contains "beta" "$out2")"

# =====================================================================
# Test 3: per-domain totals are summed and ordered descending.
#   security: beta=120 + delta=200 = 320s -> "5m 20s"
#   perf:     alpha=250 + epsilon=60 = 310s -> "5m 10s"
#   No individual lens duration equals 320 or 310, so each formatted total
#   appears exactly once and uniquely identifies the per-domain total line.
#   security (320) > perf (310) -> security total must come first.
# =====================================================================
echo ""
echo "Test 3: per-domain totals summed and ordered descending"
F3="$TMPDIR/domains.json"
init_summary "$F3" "test-run" "/tmp/project" "audit" "claude" "" ""
record_lens "$F3" "security" "beta"    1 "completed" 0 0 "" "" 120
record_lens "$F3" "security" "delta"   1 "completed" 0 0 "" "" 200
record_lens "$F3" "perf"     "alpha"   1 "completed" 0 0 "" "" 250
record_lens "$F3" "perf"     "epsilon" 1 "completed" 0 0 "" "" 60
out3="$(summary_time_breakdown "$F3" 10 2>/dev/null)"
assert_eq "security domain total summed to 5m 20s (320s)" "yes" "$(contains "5m 20s" "$out3")"
assert_eq "perf domain total summed to 5m 10s (310s)"     "yes" "$(contains "5m 10s" "$out3")"
assert_before "security total (320s) ordered before perf total (310s)" "$out3" "5m 20s" "5m 10s"

# =====================================================================
# Test 4: AC3 — durations are human-formatted, not raw seconds.
#   7980s -> "2h 13m". The raw integer "7980" must NOT appear in the output.
# =====================================================================
echo ""
echo "Test 4: durations are human-formatted, not raw seconds"
F4="$TMPDIR/human.json"
init_summary "$F4" "test-run" "/tmp/project" "audit" "claude" "" ""
record_lens "$F4" "deep" "scan" 1 "completed" 0 0 "" "" 7980
out4="$(summary_time_breakdown "$F4" 10 2>/dev/null)"
assert_eq "7980s rendered as '2h 13m'"          "yes" "$(contains "2h 13m" "$out4")"
assert_eq "raw seconds '7980' are not printed"  "no"  "$(contains "7980" "$out4")"

# =====================================================================
# Test 5: total wall time is reported, human-formatted.
#   started_at..completed_at span exactly 1h -> "1h 00m". A positive-duration
#   lens is present so the breakdown is rendered (not the no-timing path).
# =====================================================================
echo ""
echo "Test 5: total wall time reported and human-formatted"
F5="$TMPDIR/wall.json"
init_summary "$F5" "test-run" "/tmp/project" "audit" "claude" "" ""
record_lens "$F5" "perf" "alpha" 1 "completed" 0 0 "" "" 300
# Pin the top-level wall-clock anchors 1 hour apart.
jq '.started_at = "2026-06-27T10:00:00Z" | .completed_at = "2026-06-27T11:00:00Z"' \
  "$F5" > "$F5.tmp" && mv "$F5.tmp" "$F5"
out5="$(summary_time_breakdown "$F5" 10 2>/dev/null)"
assert_eq "wall time of 3600s rendered as '1h 00m'" "yes" "$(contains "1h 00m" "$out5")"

# =====================================================================
# Test 6: AC2 — graceful degradation when duration data is missing/null.
#   An older-shape summary whose lens objects either omit duration_seconds or
#   set it to null must NOT error: it prints nothing or a one-line
#   "no timing data", and exits 0. (Forces the no-data fallback branch.)
# =====================================================================
echo ""
echo "Test 6: missing/null duration_seconds degrades gracefully (no error)"
F6="$TMPDIR/legacy.json"
cat > "$F6" <<'JSON'
{
  "started_at": "2026-06-27T10:00:00Z",
  "completed_at": "2026-06-27T10:30:00Z",
  "lenses": [
    {"domain": "security", "lens": "legacy-a", "status": "completed"},
    {"domain": "perf",     "lens": "legacy-b", "status": "completed", "duration_seconds": null}
  ]
}
JSON
out6="$(summary_time_breakdown "$F6" 10 2>/dev/null)"
rc6=$?
assert_eq "exits 0 on legacy summary without timing" "0" "$rc6"
no_timing_ok="no"
if [[ -z "$out6" || "$out6" == *"no timing data"* ]]; then
  no_timing_ok="yes"
fi
assert_eq "prints nothing or a one-line 'no timing data'" "yes" "$no_timing_ok"
assert_eq "does not fabricate a slowest-lens row from legacy data" "no" \
  "$(contains "legacy-a" "$out6")"

# =====================================================================
# Test 7: nonexistent summary file is handled gracefully (no crash).
#   Returns 0 with no output rather than erroring.
# =====================================================================
echo ""
echo "Test 7: nonexistent summary file returns 0 with no output"
out7="$(summary_time_breakdown "$TMPDIR/does-not-exist.json" 10 2>/dev/null)"
rc7=$?
assert_eq "exits 0 for a missing file" "0" "$rc7"
assert_eq "prints no breakdown for a missing file" "" "$out7"

# =====================================================================
# Test 8: zero-duration (skipped) lenses are filtered out of BOTH the slowest
#   list and the per-domain totals; a domain whose only lens has duration 0 is
#   dropped entirely. Positive lenses survive and their domain totals are not
#   inflated by the zero siblings.
#     alpha/active   = 300  (positive)
#     alpha/zerolens =   0  (excluded from slowest; must not inflate alpha total)
#     zerodom/lonely =   0  (its domain has ONLY zero -> dropped from per-domain)
#     beta/active2   = 120  (positive)
# =====================================================================
echo ""
echo "Test 8: zero-duration lenses excluded from slowest list and per-domain totals"
F8="$TMPDIR/zero.json"
init_summary "$F8" "test-run" "/tmp/project" "audit" "claude" "" ""
record_lens "$F8" "alpha"   "active"   1 "completed" 0 0 "" "" 300
record_lens "$F8" "alpha"   "zerolens" 1 "skipped"   0 0 "" "" 0
record_lens "$F8" "zerodom" "lonely"   1 "skipped"   0 0 "" "" 0
record_lens "$F8" "beta"    "active2"  1 "completed" 0 0 "" "" 120
out8="$(summary_time_breakdown "$F8" 10 2>/dev/null)"
assert_eq "zero-duration lens (zerolens) excluded from slowest list" "no"  "$(contains "zerolens" "$out8")"
assert_eq "zero-only domain's lens (lonely) excluded everywhere"     "no"  "$(contains "lonely" "$out8")"
assert_eq "zero-only domain (zerodom) excluded from per-domain totals" "no" "$(contains "zerodom" "$out8")"
assert_eq "positive lens (active) still present"                     "yes" "$(contains "active" "$out8")"
assert_eq "alpha domain total not inflated by zero sibling (5m 00s)" "yes" "$(contains "5m 00s" "$out8")"

# =====================================================================
# Test 9: top_n is coerced back to the default (10) for non-numeric / zero /
#   negative values, rather than being applied literally. With the F1 fixture
#   (gamma=600, alpha=300, beta=120), a literal top_n of 0 would slice to an
#   empty slowest list, so beta's PRESENCE proves coercion happened. Lens names
#   appear only in the slowest section, so their presence is decisive.
# =====================================================================
echo ""
echo "Test 9: non-numeric / zero / negative top_n coerces to default 10"
out9_nonnum="$(summary_time_breakdown "$F1" "abc" 2>/dev/null)"
out9_zero="$(summary_time_breakdown "$F1" "0" 2>/dev/null)"
out9_neg="$(summary_time_breakdown "$F1" "-3" 2>/dev/null)"
assert_eq "non-numeric top_n='abc' keeps all three lenses (incl. beta)" "yes" "$(contains "beta" "$out9_nonnum")"
assert_eq "zero top_n='0' keeps all three lenses (incl. beta)"          "yes" "$(contains "beta" "$out9_zero")"
assert_eq "negative top_n='-3' keeps all three lenses (incl. beta)"     "yes" "$(contains "beta" "$out9_neg")"

# =====================================================================
# Test 10: when lib/status.sh is NOT loaded (status_format_duration absent),
#   the helper degrades to raw "<n>s" durations rather than erroring — the
#   declare -F fallback in _summary_fmt_duration. Driven through the PUBLIC
#   helper in a subshell that unsets the formatter, so the whole output path is
#   exercised in degraded mode (the existing tests always source status.sh and
#   so can never reach this branch).
# =====================================================================
echo ""
echo "Test 10: raw-seconds fallback when status_format_duration is not loaded"
out10="$( unset -f status_format_duration; summary_time_breakdown "$F1" 10 2>/dev/null )"
rc10=$?
assert_eq "degraded mode exits 0"                          "0"   "$rc10"
assert_eq "gamma (600s) rendered as raw seconds '600s'"    "yes" "$(contains "600s" "$out10")"
assert_eq "human-formatted '10m 00s' absent in degraded mode" "no" "$(contains "10m 00s" "$out10")"

# =====================================================================
# Test 11: the 'lens-seconds' line reports the SUM of all durations, distinct
#   from any single lens and from any per-domain total. Two lenses in different
#   domains (300 + 250 = 550 -> "9m 10s"); per-domain totals are 300 and 250, so
#   "9m 10s" can only be the lens-seconds line. (Test 4's single-lens value
#   coincided with the slowest lens, so the sum was never isolated.)
# =====================================================================
echo ""
echo "Test 11: lens-seconds reports the summed total across lenses"
F11="$TMPDIR/lensseconds.json"
init_summary "$F11" "test-run" "/tmp/project" "audit" "claude" "" ""
record_lens "$F11" "metrics" "lensP" 1 "completed" 0 0 "" "" 300
record_lens "$F11" "review"  "lensQ" 1 "completed" 0 0 "" "" 250
out11="$(summary_time_breakdown "$F11" 10 2>/dev/null)"
assert_eq "lens-seconds label is present"                        "yes" "$(contains "lens-seconds" "$out11")"
assert_eq "lens-seconds sums 300+250 to 9m 10s (550s)"           "yes" "$(contains "9m 10s" "$out11")"

# =====================================================================
# Test 12: the wall-time line is OMITTED when completed_at is null (e.g. an
#   interrupted run that still reaches the print path), while the rest of the
#   breakdown — lens-seconds, slowest, per-domain — still renders. init_summary
#   leaves completed_at:null, so no pinning is needed.
# =====================================================================
echo ""
echo "Test 12: wall-time line omitted when completed_at is null; breakdown still renders"
F12="$TMPDIR/nowall.json"
init_summary "$F12" "test-run" "/tmp/project" "audit" "claude" "" ""
record_lens "$F12" "perf" "alpha" 1 "completed" 0 0 "" "" 300
out12="$(summary_time_breakdown "$F12" 10 2>/dev/null)"
rc12=$?
assert_eq "exits 0 with null completed_at"                "0"   "$rc12"
assert_eq "wall-time line omitted when completed_at null" "no"  "$(contains "wall time" "$out12")"
assert_eq "lens-seconds still printed without wall time"  "yes" "$(contains "lens-seconds" "$out12")"

# =====================================================================
# Test 13: AC2 robustness — when jq is unavailable the helper degrades to a
#   silent no-op (return 0, no output), NOT the "no timing data" line and NOT an
#   error. Drives the `command -v jq || return 0` guard by running the public
#   helper in a subshell whose PATH cannot resolve jq. F1 has positive timing, so
#   the only thing suppressing output here is the missing-jq guard itself (this
#   is distinct from Test 6's no-timing path and Test 7's missing-file path).
# =====================================================================
echo ""
echo "Test 13: missing jq degrades to a silent no-op (return 0, no output)"
# shellcheck disable=SC2123  # intentional: clobber PATH so jq is unfindable, exercising the missing-jq guard.
out13="$( PATH=/nonexistent-repolens-pathdir; summary_time_breakdown "$F1" 10 2>/dev/null )"
rc13=$?
assert_eq "exits 0 when jq is not on PATH"            "0" "$rc13"
assert_eq "prints no breakdown when jq is missing"    ""  "$out13"

# =====================================================================
# Test 14: the documented default of top_n=10 is applied when the second
#   argument is OMITTED entirely (the `${2:-10}` default), capping the slowest
#   list to ten. Test 9 only proves bad values coerce to 10, and every other
#   fixture has <=4 lenses — so neither can tell "10" from "all". Here 11 lenses
#   share one domain (so lens names appear ONLY in the slowest section); calling
#   the helper with NO top_n must keep the 10 slowest and drop the 11th.
#     topmost            = 660 (rank 1, kept)
#     f02..f10           = 600..120 (ranks 2-10, kept)
#     excluded_eleventh  =  60 (rank 11, dropped by the default cap of 10)
# =====================================================================
echo ""
echo "Test 14: omitted top_n applies the documented default cap of 10"
F14="$TMPDIR/default_topn.json"
init_summary "$F14" "test-run" "/tmp/project" "audit" "claude" "" ""
record_lens "$F14" "perfd" "topmost"           1 "completed" 0 0 "" "" 660
record_lens "$F14" "perfd" "f02"               1 "completed" 0 0 "" "" 600
record_lens "$F14" "perfd" "f03"               1 "completed" 0 0 "" "" 540
record_lens "$F14" "perfd" "f04"               1 "completed" 0 0 "" "" 480
record_lens "$F14" "perfd" "f05"               1 "completed" 0 0 "" "" 420
record_lens "$F14" "perfd" "f06"               1 "completed" 0 0 "" "" 360
record_lens "$F14" "perfd" "f07"               1 "completed" 0 0 "" "" 300
record_lens "$F14" "perfd" "f08"               1 "completed" 0 0 "" "" 240
record_lens "$F14" "perfd" "f09"               1 "completed" 0 0 "" "" 180
record_lens "$F14" "perfd" "f10"               1 "completed" 0 0 "" "" 120
record_lens "$F14" "perfd" "excluded_eleventh" 1 "completed" 0 0 "" "" 60
# NOTE: called with ONE argument — exercises the ${2:-10} default, not a literal 10.
out14="$(summary_time_breakdown "$F14" 2>/dev/null)"
assert_eq "default cap keeps the slowest lens (topmost)"          "yes" "$(contains "topmost" "$out14")"
assert_eq "default cap keeps the 10th slowest lens (f10)"         "yes" "$(contains "f10" "$out14")"
assert_eq "default cap drops the 11th slowest lens (eleventh)"    "no"  "$(contains "excluded_eleventh" "$out14")"

# =====================================================================
# Test 15: wall time is clamped at 0 when completed_at precedes started_at
#   (clock skew / a resumed run stamping an earlier completion). The negative
#   span must render as "0s", never a negative or huge unsigned value. A
#   positive-duration lens is present so the breakdown renders; the wall-time
#   line is isolated by label so the assertion can't be fooled by "00s" inside
#   other durations (e.g. the "5m 00s" lens total).
# =====================================================================
echo ""
echo "Test 15: negative wall span (completed_at < started_at) clamps to 0s"
F15="$TMPDIR/skew.json"
init_summary "$F15" "test-run" "/tmp/project" "audit" "claude" "" ""
record_lens "$F15" "perf" "alpha" 1 "completed" 0 0 "" "" 300
# completed_at one hour BEFORE started_at -> raw span -3600s, must clamp to 0.
jq '.started_at = "2026-06-27T11:00:00Z" | .completed_at = "2026-06-27T10:00:00Z"' \
  "$F15" > "$F15.tmp" && mv "$F15.tmp" "$F15"
out15="$(summary_time_breakdown "$F15" 10 2>/dev/null)"
rc15=$?
wall_line15="$(grep -F "wall time" <<<"$out15" | head -1)"
wall_compact15="${wall_line15// /}"   # strip spaces -> "walltime:0s"
assert_eq "exits 0 on negative wall span"                 "0"   "$rc15"
assert_eq "wall-time line is present for the skewed run"  "yes" "$(contains "wall time" "$out15")"
assert_eq "negative wall span clamped to 0s"              "yes" "$(contains ":0s" "$wall_compact15")"

# --- Summary ---
echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
