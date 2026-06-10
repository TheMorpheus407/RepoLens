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

# Issue #251 — `repolens clean` subcommand: dispatch, help, the positive
# run-dir selector (the #1 safety property), age-based removal, and --keep-last.

set -uo pipefail

# shellcheck disable=SC1091
# shellcheck source=tests/clean_test_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/clean_test_lib.sh"
trap clean_cleanup EXIT

echo "=== clean: dispatch, help, selector, age, keep-last (issue #251) ==="

# ---------------------------------------------------------------------------
# Help / dispatch — `clean` must dispatch BEFORE run validation (like status),
# so it works with no --project/--agent, and --help must not delete anything.
# ---------------------------------------------------------------------------
clean_setup_farm

clean_run --help
rc=$?
assert_eq "clean --help exits 0" "0" "$rc"
assert_contains "clean --help prints clean usage" "repolens.sh clean" "$CLEAN_OUT"
assert_contains "clean --help documents --older-than" "--older-than" "$CLEAN_OUT"
assert_contains "clean --help documents --keep-last" "--keep-last" "$CLEAN_OUT"
assert_contains "clean --help documents --dry-run" "--dry-run" "$CLEAN_OUT"

top_help="$(bash "$CLEAN_TEST_FARM/repolens.sh" --help 2>/dev/null)"
assert_contains "top-level help lists clean command" "clean" "$top_help"

# ---------------------------------------------------------------------------
# Selector safety + age. The selector MUST be positive: only direct children
# of logs/ that look like a run id AND carry summary.json/status.json. It must
# never touch AutoDev state (logs/issues/...), foreign dirs, or partial dirs.
# ---------------------------------------------------------------------------
clean_cleanup
clean_setup_farm

# Genuine, old, finished run -> eligible for removal.
make_run "20260101T010101Z-aaaaaaaa" "finished" "" 60 >/dev/null
# Genuine, recent, finished run -> protected by age.
make_run "20260601T010101Z-bbbbbbbb" "finished" "" 1 >/dev/null

# Non-run noise that the selector must NEVER remove:
#  (a) AutoDev per-issue dir (wrong name, no summary/status)
mkdir -p "$CLEAN_TEST_LOGS/issues/251"
echo "research" > "$CLEAN_TEST_LOGS/issues/251/research.md"
touch -d "@$(epoch_days_ago 90)" "$CLEAN_TEST_LOGS/issues"
#  (b) run-id-shaped name but NO summary.json/status.json (partial/foreign)
mkdir -p "$CLEAN_TEST_LOGS/20251212T121212Z-cccccccc"
touch -d "@$(epoch_days_ago 90)" "$CLEAN_TEST_LOGS/20251212T121212Z-cccccccc"
#  (c) has summary.json but a non-run-id name (e.g. auto-develop marker dir)
mkdir -p "$CLEAN_TEST_LOGS/auto-develop"
echo '{"run_id":"x"}' > "$CLEAN_TEST_LOGS/auto-develop/summary.json"
touch -d "@$(epoch_days_ago 90)" "$CLEAN_TEST_LOGS/auto-develop"
#  (d) genuine run dirs may carry only one of status.json / summary.json;
#      the selector intentionally accepts either file so old partial-schema
#      runs can still be pruned.
mkdir -p "$CLEAN_TEST_LOGS/20251111T111111Z-statusonly"
echo '{"run_id":"20251111T111111Z-statusonly","state":"finished"}' > "$CLEAN_TEST_LOGS/20251111T111111Z-statusonly/status.json"
touch -d "@$(epoch_days_ago 90)" "$CLEAN_TEST_LOGS/20251111T111111Z-statusonly"
mkdir -p "$CLEAN_TEST_LOGS/20251111T111112Z-summaryonly"
echo '{"run_id":"20251111T111112Z-summaryonly","stopped_reason":null}' > "$CLEAN_TEST_LOGS/20251111T111112Z-summaryonly/summary.json"
touch -d "@$(epoch_days_ago 90)" "$CLEAN_TEST_LOGS/20251111T111112Z-summaryonly"

clean_run --older-than 30d --keep-last 0 --force
rc=$?
assert_eq "clean exits 0 on a valid sweep" "0" "$rc"
assert_dir_absent "old finished run removed" "20260101T010101Z-aaaaaaaa"
assert_dir_absent "status.json-only run dir removed" "20251111T111111Z-statusonly"
assert_dir_absent "summary.json-only run dir removed" "20251111T111112Z-summaryonly"
assert_dir_present "recent run kept (age guard)" "20260601T010101Z-bbbbbbbb"
assert_dir_present "AutoDev issues/ dir never touched" "issues/251"
assert_dir_present "run-id-named dir without summary/status never touched" "20251212T121212Z-cccccccc"
assert_dir_present "non-run-id-named dir with summary.json never touched" "auto-develop"

# ---------------------------------------------------------------------------
# --keep-last protects the N newest runs even when all are past the age cutoff.
# ---------------------------------------------------------------------------
clean_cleanup
clean_setup_farm

make_run "20260101T000001Z-d0000001" "finished" "" 50 >/dev/null
make_run "20260201T000002Z-d0000002" "finished" "" 40 >/dev/null
make_run "20260301T000003Z-d0000003" "finished" "" 30 >/dev/null

clean_run --older-than 7d --keep-last 2 --force
rc=$?
assert_eq "keep-last sweep exits 0" "0" "$rc"
assert_dir_present "newest run kept by --keep-last 2" "20260301T000003Z-d0000003"
assert_dir_present "second-newest run kept by --keep-last 2" "20260201T000002Z-d0000002"
assert_dir_absent "oldest run removed despite --keep-last 2" "20260101T000001Z-d0000001"

# ---------------------------------------------------------------------------
# Equals-form options (--older-than=…, --keep-last=…) must parse identically to
# the space-separated form. Both branches exist in the arg parser; only the
# space form was exercised above.
# ---------------------------------------------------------------------------
clean_cleanup
clean_setup_farm

make_run "20260101T000101Z-e0000001" "finished" "" 50 >/dev/null
make_run "20260201T000102Z-e0000002" "finished" "" 40 >/dev/null

clean_run --older-than=7d --keep-last=1 --force
rc=$?
assert_eq "equals-form sweep exits 0" "0" "$rc"
assert_dir_present "equals-form --keep-last=1 protects newest" "20260201T000102Z-e0000002"
assert_dir_absent "equals-form --older-than=7d removes old run" "20260101T000101Z-e0000001"

# ---------------------------------------------------------------------------
# Error / usage paths: a malformed value or unknown flag must exit non-zero,
# print a diagnostic to stderr, and delete NOTHING (fail safe, not fail open).
# ---------------------------------------------------------------------------
clean_cleanup
clean_setup_farm
make_run "20260101T000201Z-errguard" "finished" "" 60 >/dev/null

# (a) invalid --older-than value
clean_run --older-than 7weeks --force
rc=$?
assert_eq "invalid --older-than exits 1" "1" "$rc"
assert_contains "invalid --older-than diagnosed on stderr" "invalid --older-than" "$CLEAN_ERR"
assert_dir_present "invalid --older-than deletes nothing" "20260101T000201Z-errguard"

# (b) invalid --keep-last value (non-numeric)
clean_run --keep-last abc --force
rc=$?
assert_eq "invalid --keep-last exits 1" "1" "$rc"
assert_contains "invalid --keep-last diagnosed on stderr" "invalid --keep-last" "$CLEAN_ERR"
assert_dir_present "invalid --keep-last deletes nothing" "20260101T000201Z-errguard"

# (c) unknown option
clean_run --frobnicate
rc=$?
assert_eq "unknown option exits 1" "1" "$rc"
assert_contains "unknown option diagnosed on stderr" "unknown option" "$CLEAN_ERR"
assert_dir_present "unknown option deletes nothing" "20260101T000201Z-errguard"

# (d) -h short form prints usage and exits 0 (parity with --help)
clean_run -h
rc=$?
assert_eq "clean -h exits 0" "0" "$rc"
assert_contains "clean -h prints usage" "repolens.sh clean" "$CLEAN_OUT"

# (e) missing trailing value for an arg-consuming flag must NOT hang.
#     Regression for the DENIED defect: `--older-than` / `--keep-last` supplied
#     as the LAST token with no value used to spin forever (`shift 2 || true`
#     left $# unchanged, so `while [[ $# -gt 0 ]]` never advanced). Each must
#     terminate fast, exit 1 (NOT 124/timeout), diagnose on stderr, delete nothing.
clean_run_timed 5 --older-than
rc=$?
assert_eq "trailing --older-than (no value) exits 1, no hang" "1" "$rc"
assert_contains "trailing --older-than diagnosed on stderr" "invalid --older-than" "$CLEAN_ERR"
assert_dir_present "trailing --older-than deletes nothing" "20260101T000201Z-errguard"

clean_run_timed 5 --keep-last
rc=$?
assert_eq "trailing --keep-last (no value) exits 1, no hang" "1" "$rc"
assert_contains "trailing --keep-last diagnosed on stderr" "invalid --keep-last" "$CLEAN_ERR"
assert_dir_present "trailing --keep-last deletes nothing" "20260101T000201Z-errguard"

# ---------------------------------------------------------------------------
# Sub-day --older-than units: hours (Nh), minutes (Nm), and bare seconds. The
# day branch is covered above, but the h/m/seconds branches of the duration
# parser — and their distinct multipliers (3600 / 60 / 1) — were unexercised.
# A wrong multiplier (e.g. h*60 instead of h*3600) would otherwise ship silently.
# The issue body itself cites `24h` as a usage example.
# ---------------------------------------------------------------------------
# Hours: a 3h-old run is older than `--older-than 1h`; a 30m-old run is not.
clean_cleanup
clean_setup_farm
make_run_aged_seconds "20260101T010001Z-hh3hours" "$(( 3 * 3600 ))" >/dev/null
make_run_aged_seconds "20260101T010002Z-mm30mins" 1800 >/dev/null

clean_run --older-than 1h --keep-last 0 --force
rc=$?
assert_eq "hours-unit sweep exits 0" "0" "$rc"
assert_dir_absent "run 3h old removed by --older-than 1h" "20260101T010001Z-hh3hours"
assert_dir_present "run 30m old kept by --older-than 1h" "20260101T010002Z-mm30mins"

# Minutes: a 15m-old run is older than `--older-than 10m`; a 2m-old run is not.
clean_cleanup
clean_setup_farm
make_run_aged_seconds "20260101T010003Z-mm15min0" "$(( 15 * 60 ))" >/dev/null
make_run_aged_seconds "20260101T010004Z-mm02min0" 120 >/dev/null

clean_run --older-than 10m --keep-last 0 --force
rc=$?
assert_eq "minutes-unit sweep exits 0" "0" "$rc"
assert_dir_absent "run 15m old removed by --older-than 10m" "20260101T010003Z-mm15min0"
assert_dir_present "run 2m old kept by --older-than 10m" "20260101T010004Z-mm02min0"

# Bare seconds (no unit suffix): a 120s-old run is older than `--older-than 60`;
# a 5s-old run is not. Large margins so test-execution latency can't flip them.
clean_cleanup
clean_setup_farm
make_run_aged_seconds "20260101T010005Z-ss120sec" 120 >/dev/null
make_run_aged_seconds "20260101T010006Z-ss005sec" 5 >/dev/null

clean_run --older-than 60 --keep-last 0 --force
rc=$?
assert_eq "bare-seconds-unit sweep exits 0" "0" "$rc"
assert_dir_absent "run 120s old removed by --older-than 60 (bare seconds)" "20260101T010005Z-ss120sec"
assert_dir_present "run 5s old kept by --older-than 60 (bare seconds)" "20260101T010006Z-ss005sec"

# ---------------------------------------------------------------------------
# Partial removal failure: manual clean must return non-zero when an eligible
# run could not be removed, while still removing other eligible runs.
# ---------------------------------------------------------------------------
clean_cleanup
clean_setup_farm
make_run "20260101T010007Z-rmfail00" "finished" "" 60 >/dev/null
make_run "20260101T010008Z-rmok0000" "finished" "" 60 >/dev/null

fake_bin="$CLEAN_TEST_FARM/bin"
mkdir -p "$fake_bin"
real_rm="$(command -v rm)"
cat > "$fake_bin/rm" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    */20260101T010007Z-rmfail00|*/20260101T010007Z-rmfail00/) exit 1 ;;
  esac
done
exec "$real_rm" "\$@"
EOF
chmod +x "$fake_bin/rm"

PATH="$fake_bin:$PATH" clean_run --older-than 30d --keep-last 0 --force
rc=$?
assert_eq "partial rm failure exits 1" "1" "$rc"
assert_contains "partial rm failure diagnosed on stderr" "failed to remove: 20260101T010007Z-rmfail00" "$CLEAN_ERR"
assert_dir_present "failed removal remains" "20260101T010007Z-rmfail00"
assert_dir_absent "other eligible run still removed" "20260101T010008Z-rmok0000"

clean_finish
