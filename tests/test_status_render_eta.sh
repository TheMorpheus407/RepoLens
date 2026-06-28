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

# Behavioral tests for issue #352: the human `status` render surfaces the
# already-computed elapsed / estimated-remaining / ETA fields from status.json.
#
# Contract under test (status_render_human in lib/status.sh):
#   1. When status.json carries elapsed_seconds + eta_seconds_remaining +
#      eta_completion_at (a live "running" run), the human output shows the
#      elapsed duration, the remaining duration, and the formatted ETA
#      completion timestamp — all derived from the on-disk values verbatim
#      (the render does NOT recompute them).
#   2. When the ETA is not computable (terminal state / nothing completed →
#      eta_seconds_remaining is null), the output shows "remaining unknown"
#      instead of a bogus number, while still showing elapsed.
#   3. An older status.json that predates the ETA fields renders without
#      crashing (exit 0, no stderr) and falls back to the "unknown" text,
#      leaving the existing progress line intact.
#   4. `--json` output is unchanged — the ETA fields pass through verbatim and
#      none of the new human-render text leaks into the JSON path.
#
# TDD note: the implementation does not exist yet, so the assertions that pin
# the new behavior (elapsed/remaining durations, the ETA timestamp, the
# "remaining unknown"/"elapsed unknown" fallbacks) MUST fail until the render
# is extended. The exit-0 / no-stderr / progress-line / --json assertions are
# regression guards that pass both before and after the change — they prove the
# new line does not break the existing output or the JSON contract.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
# shellcheck source=tests/status_test_lib.sh
source "$SCRIPT_DIR/tests/status_test_lib.sh"
trap status_cleanup EXIT

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    record_fail "$desc" "unexpected needle='$needle'"
  else
    record_pass "$desc"
  fi
}

echo "=== status render surfaces elapsed + ETA (issue #352) ==="
status_require_jq

FIXTURE="$STATUS_TEST_ROOT/tests/fixtures/status_active.json"
OUT_FILE="$STATUS_TEST_TMPDIR/status.out"
ERR_FILE="$STATUS_TEST_TMPDIR/status.err"

# --- Case 1: live "running" run with computed elapsed + remaining + ETA -------
# elapsed_seconds=4980  -> status_format_duration -> "1h 23m"
# eta_seconds_remaining=15120 -> status_format_duration -> "4h 12m"
# eta_completion_at -> status_format_iso_utc -> "2026-04-17 11:39:00 UTC"
RUN1="status-eta-running-test"
DIR1="$STATUS_TEST_ROOT/logs/$RUN1"
mkdir -p "$DIR1"
status_register_run_id "$RUN1"
jq '.run_id = "status-eta-running-test"
    | .elapsed_seconds = 4980
    | .eta_seconds_remaining = 15120
    | .eta_completion_at = "2026-04-17T11:39:00Z"' \
  "$FIXTURE" > "$DIR1/status.json"

bash "$STATUS_TEST_ROOT/repolens.sh" status "$RUN1" --no-color >"$OUT_FILE" 2>"$ERR_FILE"
rc1=$?
out1="$(cat "$OUT_FILE")"
err1="$(cat "$ERR_FILE")"

assert_eq "Running ETA render exits 0" "0" "$rc1"
assert_eq "Running ETA render writes no stderr" "" "$err1"
assert_contains "Running output labels elapsed time" "elapsed" "$out1"
assert_contains "Running output formats real elapsed duration (4980s)" "1h 23m" "$out1"
assert_contains "Running output labels remaining time" "remaining" "$out1"
assert_contains "Running output formats real remaining duration (15120s)" "4h 12m" "$out1"
assert_contains "Running output shows formatted ETA completion timestamp" "2026-04-17 11:39:00 UTC" "$out1"

# --- Case 2: terminal/finished run -> remaining is null, elapsed still set ----
# eta_seconds_remaining=null  -> "remaining unknown" (no bogus number)
# elapsed_seconds=7200        -> "2h 00m" still shown (elapsed is independent)
RUN2="status-eta-null-test"
DIR2="$STATUS_TEST_ROOT/logs/$RUN2"
mkdir -p "$DIR2"
status_register_run_id "$RUN2"
jq '.run_id = "status-eta-null-test"
    | .state = "finished"
    | .elapsed_seconds = 7200
    | .eta_seconds_remaining = null
    | .eta_completion_at = null
    | .counts.active = 0
    | .counts.queued = 0
    | .counts.completed = 152
    | .completion_percentage = 100
    | .active = []' \
  "$FIXTURE" > "$DIR2/status.json"

bash "$STATUS_TEST_ROOT/repolens.sh" status "$RUN2" --no-color >"$OUT_FILE" 2>"$ERR_FILE"
rc2=$?
out2="$(cat "$OUT_FILE")"
err2="$(cat "$ERR_FILE")"

assert_eq "Null-ETA render exits 0" "0" "$rc2"
assert_eq "Null-ETA render writes no stderr" "" "$err2"
assert_contains "Null-ETA output still labels elapsed time" "elapsed" "$out2"
assert_contains "Null-ETA output formats real elapsed duration (7200s)" "2h 00m" "$out2"
assert_contains "Null-ETA output falls back to 'remaining unknown'" "remaining unknown" "$out2"

# --- Case 3: legacy status.json predating the ETA fields ----------------------
# The fixture has no elapsed_seconds / eta_seconds_remaining / eta_completion_at.
# Must not crash, must keep the existing progress line, must show "unknown".
RUN3="status-eta-legacy-test"
DIR3="$STATUS_TEST_ROOT/logs/$RUN3"
mkdir -p "$DIR3"
status_register_run_id "$RUN3"
jq '.run_id = "status-eta-legacy-test"' "$FIXTURE" > "$DIR3/status.json"

bash "$STATUS_TEST_ROOT/repolens.sh" status "$RUN3" --no-color >"$OUT_FILE" 2>"$ERR_FILE"
rc3=$?
out3="$(cat "$OUT_FILE")"
err3="$(cat "$ERR_FILE")"

assert_eq "Legacy file render exits 0 (no crash on missing ETA fields)" "0" "$rc3"
assert_eq "Legacy file render writes no stderr" "" "$err3"
assert_contains "Legacy render preserves the existing progress line" \
  "progress:  24/152 completed  |  8 active  |  120 queued  |  17 issues created" "$out3"
assert_contains "Legacy file falls back to 'remaining unknown'" "remaining unknown" "$out3"
assert_contains "Legacy file falls back to 'elapsed unknown'" "elapsed unknown" "$out3"

# --- Case 4: --json path is unchanged (acceptance criterion #2) ---------------
# Reuse the computed-ETA fixture from Case 1; --json must emit status.json
# verbatim with the ETA fields intact and none of the human-render text.
bash "$STATUS_TEST_ROOT/repolens.sh" status "$RUN1" --json >"$OUT_FILE" 2>"$ERR_FILE"
json_rc=$?
json_out="$(cat "$OUT_FILE")"
json_err="$(cat "$ERR_FILE")"

assert_eq "JSON mode exits 0" "0" "$json_rc"
assert_eq "JSON mode writes no stderr" "" "$json_err"
assert_jq "JSON mode passes elapsed_seconds through verbatim" "$OUT_FILE" '.elapsed_seconds == 4980'
assert_jq "JSON mode passes eta_seconds_remaining through verbatim" "$OUT_FILE" '.eta_seconds_remaining == 15120'
assert_jq "JSON mode passes eta_completion_at through verbatim" "$OUT_FILE" '.eta_completion_at == "2026-04-17T11:39:00Z"'
assert_not_contains "JSON mode does not emit the human render header" "RepoLens run" "$json_out"
assert_not_contains "JSON mode does not emit the human progress line" "progress:" "$json_out"

# --- Case 5: remaining == 0 (essentially done, still running) -----------------
# The writer (test_status_eta.sh Case E) guarantees eta_seconds_remaining can be
# a numeric 0 — not null — when total == completed while state is still
# "running". A computed 0 is a REAL value, not a null/"bogus number", so the
# render must show "~0s remaining  (ETA ...)" and NOT fall back to
# "remaining unknown". This pins the null-vs-zero boundary of the ^[0-9]+$ gate
# (and the jq `// ""` selector, where 0 is truthy in jq and survives as "0"):
# a `> 0` guard would wrongly route this legitimate 0 to "remaining unknown".
# elapsed_seconds=4980 -> "1h 23m"; eta_completion_at -> "2026-04-17 08:00:00 UTC".
RUN5="status-eta-zero-remaining-test"
DIR5="$STATUS_TEST_ROOT/logs/$RUN5"
mkdir -p "$DIR5"
status_register_run_id "$RUN5"
jq '.run_id = "status-eta-zero-remaining-test"
    | .state = "running"
    | .elapsed_seconds = 4980
    | .eta_seconds_remaining = 0
    | .eta_completion_at = "2026-04-17T08:00:00Z"
    | .counts.active = 0
    | .counts.queued = 0
    | .counts.completed = 152
    | .completion_percentage = 100
    | .active = []' \
  "$FIXTURE" > "$DIR5/status.json"

bash "$STATUS_TEST_ROOT/repolens.sh" status "$RUN5" --no-color >"$OUT_FILE" 2>"$ERR_FILE"
rc5=$?
out5="$(cat "$OUT_FILE")"
err5="$(cat "$ERR_FILE")"

assert_eq "Zero-remaining render exits 0" "0" "$rc5"
assert_eq "Zero-remaining render writes no stderr" "" "$err5"
assert_contains "Zero-remaining shows the real 0s remaining (not 'unknown')" "0s remaining" "$out5"
assert_contains "Zero-remaining still shows the ETA completion timestamp" "2026-04-17 08:00:00 UTC" "$out5"
assert_not_contains "Zero-remaining does NOT fall back to 'remaining unknown'" "remaining unknown" "$out5"
assert_contains "Zero-remaining still shows elapsed alongside it" "1h 23m" "$out5"

# --- Case 6: elapsed == 0 (clock-skew clamp), remaining null ------------------
# The writer clamps elapsed_seconds to >= 0 on clock skew (test_status_eta.sh
# Case D), so a numeric 0 elapsed is a valid on-disk value; per the writer
# contract, elapsed == 0 forces eta_seconds_remaining to null. A computed 0
# elapsed must render as "~0s elapsed" (the numeric branch) — NOT the
# absent/null "elapsed unknown" fallback (which is reserved for legacy files
# with no field at all, Case 3). status_format_duration 0 -> "0s".
RUN6="status-eta-zero-elapsed-test"
DIR6="$STATUS_TEST_ROOT/logs/$RUN6"
mkdir -p "$DIR6"
status_register_run_id "$RUN6"
jq '.run_id = "status-eta-zero-elapsed-test"
    | .state = "running"
    | .elapsed_seconds = 0
    | .eta_seconds_remaining = null
    | .eta_completion_at = null' \
  "$FIXTURE" > "$DIR6/status.json"

bash "$STATUS_TEST_ROOT/repolens.sh" status "$RUN6" --no-color >"$OUT_FILE" 2>"$ERR_FILE"
rc6=$?
out6="$(cat "$OUT_FILE")"
err6="$(cat "$ERR_FILE")"

assert_eq "Zero-elapsed render exits 0" "0" "$rc6"
assert_eq "Zero-elapsed render writes no stderr" "" "$err6"
assert_contains "Zero-elapsed shows the real 0s elapsed (not 'unknown')" "0s elapsed" "$out6"
assert_not_contains "Zero-elapsed does NOT fall back to 'elapsed unknown'" "elapsed unknown" "$out6"
assert_contains "Zero-elapsed (remaining null) still shows 'remaining unknown'" "remaining unknown" "$out6"

# --- Case 7: multi-day run -> "Nd Nh" duration branch -------------------------
# The issue's motivating scenario is "a user watching a multi-day run knows
# roughly when it ends". Day-scale durations take a DISTINCT branch of
# status_format_duration ("Nd Nh", not "Nh Nm") that no other render case
# exercises. A render that called the wrong helper or truncated days would still
# pass every existing case yet mangle the exact long-run output the feature was
# built for. elapsed_seconds=180000 -> "2d 2h"; eta_seconds_remaining=270000 ->
# "3d 3h"; eta_completion_at -> "2026-04-20 11:39:00 UTC".
RUN7="status-eta-multiday-test"
DIR7="$STATUS_TEST_ROOT/logs/$RUN7"
mkdir -p "$DIR7"
status_register_run_id "$RUN7"
jq '.run_id = "status-eta-multiday-test"
    | .state = "running"
    | .elapsed_seconds = 180000
    | .eta_seconds_remaining = 270000
    | .eta_completion_at = "2026-04-20T11:39:00Z"' \
  "$FIXTURE" > "$DIR7/status.json"

bash "$STATUS_TEST_ROOT/repolens.sh" status "$RUN7" --no-color >"$OUT_FILE" 2>"$ERR_FILE"
rc7=$?
out7="$(cat "$OUT_FILE")"
err7="$(cat "$ERR_FILE")"

assert_eq "Multi-day render exits 0" "0" "$rc7"
assert_eq "Multi-day render writes no stderr" "" "$err7"
assert_contains "Multi-day output formats real elapsed in days (180000s)" "2d 2h" "$out7"
assert_contains "Multi-day output formats real remaining in days (270000s)" "3d 3h" "$out7"
assert_contains "Multi-day output shows formatted ETA completion timestamp" "2026-04-20 11:39:00 UTC" "$out7"
assert_not_contains "Multi-day output does not fall back to 'remaining unknown'" "remaining unknown" "$out7"

status_finish
