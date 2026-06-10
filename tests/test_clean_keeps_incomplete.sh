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

# Issue #251 — clean must preserve resume candidates by default
# (--keep-incomplete is ON by default). A run is "incomplete" if its
# status.json.state is running/interrupted/failed, OR summary.json.stopped_reason
# is non-null, OR it carries an abort sentinel. Only clean finished runs go.

set -uo pipefail

# shellcheck disable=SC1091
# shellcheck source=tests/clean_test_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/clean_test_lib.sh"
trap clean_cleanup EXIT

echo "=== clean: keeps incomplete / resume-candidate runs (issue #251) ==="

clean_setup_farm

# All runs are old enough to be removed by age alone — only their state /
# stopped_reason / sentinel should save them.
make_run "20260101T000010Z-state001i" "interrupted"   "" 60 >/dev/null
make_run "20260101T000011Z-state002r" "running"       "" 60 >/dev/null
make_run "20260101T000012Z-state003f" "failed"        "" 60 >/dev/null
make_run "20260101T000013Z-stopreasn" "finished" "degenerate-no-findings" 60 >/dev/null

# A finished run carrying a rate-limit abort sentinel is a resume candidate.
sentinel_dir="$(make_run "20260101T000014Z-sentinel0" "finished" "" 60)"
: > "$sentinel_dir/.rate-limit-abort"
no_progress_dir="$(make_run "20260101T000016Z-noprogss0" "finished" "" 60)"
: > "$no_progress_dir/.agent-no-progress-abort"
touch -d "@$(epoch_days_ago 60)" "$no_progress_dir"

# Control: a genuinely complete run with no resume signal -> removable.
make_run "20260101T000015Z-doneclean" "finished" "" 60 >/dev/null

# Default keep-incomplete is ON; do NOT pass the flag — rely on the default.
clean_run --older-than 1d --keep-last 0 --force
rc=$?
assert_eq "incomplete sweep exits 0" "0" "$rc"

assert_dir_present "state=interrupted run kept" "20260101T000010Z-state001i"
assert_dir_present "state=running run kept" "20260101T000011Z-state002r"
assert_dir_present "state=failed run kept" "20260101T000012Z-state003f"
assert_dir_present "stopped_reason!=null run kept" "20260101T000013Z-stopreasn"
assert_dir_present "abort-sentinel run kept" "20260101T000014Z-sentinel0"
assert_dir_present "agent-no-progress abort sentinel run kept" "20260101T000016Z-noprogss0"
assert_dir_absent  "clean finished control run removed" "20260101T000015Z-doneclean"

# ---------------------------------------------------------------------------
# --remove-incomplete is the explicit opt-out: it flips the keep_incomplete
# default OFF, so resume candidates that are otherwise eligible (old enough,
# past --keep-last) ARE removed. This is the inverse of the property above and
# was previously unexercised — without it, a regression flipping the default
# the other way would still pass.
# ---------------------------------------------------------------------------
clean_cleanup
clean_setup_farm

make_run "20260101T000020Z-rmfailed0" "failed"      "" 60 >/dev/null
make_run "20260101T000021Z-rminterr0" "interrupted" "" 60 >/dev/null
make_run "20260101T000022Z-rmstopre0" "finished" "degenerate-no-findings" 60 >/dev/null
rm_sentinel="$(make_run "20260101T000023Z-rmsentin0" "finished" "" 60)"
: > "$rm_sentinel/.systemic-failure-abort"
# Writing the sentinel bumps the dir mtime back to "now"; re-stamp it old so the
# age guard does not protect it (mtime must be set last — see make_run).
touch -d "@$(epoch_days_ago 60)" "$rm_sentinel"

clean_run --older-than 1d --keep-last 0 --remove-incomplete --force
rc=$?
assert_eq "remove-incomplete sweep exits 0" "0" "$rc"
assert_dir_absent "state=failed run removed under --remove-incomplete" "20260101T000020Z-rmfailed0"
assert_dir_absent "state=interrupted run removed under --remove-incomplete" "20260101T000021Z-rminterr0"
assert_dir_absent "stopped_reason run removed under --remove-incomplete" "20260101T000022Z-rmstopre0"
assert_dir_absent "abort-sentinel run removed under --remove-incomplete" "20260101T000023Z-rmsentin0"

# ---------------------------------------------------------------------------
# jq unavailable: keep-incomplete must fail safe. The run state lives in JSON;
# if clean cannot inspect that JSON, it must not accidentally delete a resume
# candidate whose status.json says interrupted.
# ---------------------------------------------------------------------------
clean_cleanup
clean_setup_farm

make_run "20260101T000030Z-nojqintr" "interrupted" "" 60 >/dev/null
make_run "20260101T000031Z-nojqdone" "finished" "" 60 >/dev/null
make_run "20260101T000032Z-nojqstop" "finished" "degenerate-no-findings" 60 >/dev/null
make_run "20260101T000033Z-nojqunkn" "unknown" "" 60 >/dev/null

# shellcheck disable=SC2329 # Invoked indirectly by clean_run through command -v.
command() {
  if [[ "${1:-}" == "-v" && "${2:-}" == "jq" ]]; then
    return 1
  fi
  builtin command "$@"
}
export -f command
clean_run --older-than 1d --keep-last 0 --force
rc=$?
unset -f command

TOTAL=$((TOTAL + 1))
if [[ "$rc" == "0" || "$rc" == "1" ]]; then
  record_pass "missing jq exits without crashing"
else
  record_fail "missing jq exits without crashing" "rc=$rc"
fi
assert_dir_present "missing jq preserves interrupted resume candidate" "20260101T000030Z-nojqintr"
assert_dir_absent "missing jq removes clearly finished run" "20260101T000031Z-nojqdone"
assert_dir_present "missing jq preserves stopped_reason resume candidate" "20260101T000032Z-nojqstop"
assert_dir_present "missing jq preserves unknown state fail-safe" "20260101T000033Z-nojqunkn"

clean_finish
