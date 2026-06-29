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

# Issue #376 — clean must recognize attempts.json as a resume-candidate signal.
#
# A run whose status.json/summary.json look CLEAN (state=finished,
# stopped_reason=null, no abort sentinel) can still be a live continuation
# candidate: its most recent invocation hit a rate limit, was interrupted, or
# failed. attempts.json is the authoritative per-invocation ledger, so clean
# must KEEP a run when the LAST attempt's status is anything other than
# finished/finished-empty. The discriminator is the LAST array element (the most
# recent attempt) — NOT the first — which is the one non-obvious hazard here.
#
# These are behavioral tests: they fabricate run dirs + attempts.json, run the
# real `repolens.sh clean`, and assert which dirs survive. They never invoke an
# agent. Tests are intentionally written BEFORE the implementation exists, so
# the "keep because of attempts.json" cases are expected to FAIL until
# _clean_is_incomplete learns the new signal (TDD red phase).

set -uo pipefail

# shellcheck disable=SC1091
# shellcheck source=tests/clean_test_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/clean_test_lib.sh"
trap clean_cleanup EXIT

echo "=== clean: recognizes attempts.json continuation signal (issue #376) ==="

# write_attempts <dir> <status1> [status2 ...] — fabricate an attempts.json
# matching the JSON-ARRAY shape lib/attempts.sh:attempts_finalize writes: one
# pretty-printed entry per status, in order, the LAST being the most-recent
# attempt. Each entry carries a free-text why_stopped (which never contains the
# literal "status": token) so the no-jq grep path is exercised against realistic
# adjacent fields. With zero statuses, writes an empty array []. The dir mtime is
# bumped to "now" by this write — callers must re-stamp it old afterward.
write_attempts() {
  local dir="$1"; shift
  local file="$dir/attempts.json"
  if (( $# == 0 )); then
    printf '[]\n' > "$file"
    return 0
  fi
  local i=0 status entries=""
  for status in "$@"; do
    i=$((i + 1))
    [[ -n "$entries" ]] && entries+=$',\n'
    entries+="$(printf '  {\n    "attempt_id": %d,\n    "started_at": "2026-06-23T06:00:00Z",\n    "finished_at": "2026-06-23T07:00:00Z",\n    "status": "%s",\n    "why_stopped": "free text for attempt %d",\n    "lenses_completed_this_attempt": 1,\n    "lenses_completed_total": %d,\n    "exit_code": 0\n  }' "$i" "$status" "$i" "$i")"
  done
  printf '[\n%s\n]\n' "$entries" > "$file"
}

# make_attempts_run <name> <status1> [status2 ...] — build a CLEAN finished run
# (state=finished, stopped_reason=null, no abort sentinel — so attempts.json is
# the ONLY possible keep-signal), attach attempts.json with the given per-attempt
# statuses, then re-stamp the dir mtime 60 days old. The re-stamp is mandatory:
# writing attempts.json bumps the dir mtime to "now", which would otherwise let
# the age guard protect the dir for the wrong reason (a false green).
make_attempts_run() {
  local name="$1"; shift
  local dir
  dir="$(make_run "$name" "finished" "" 60)"
  write_attempts "$dir" "$@"
  touch -d "@$(epoch_days_ago 60)" "$dir"
}

# ---------------------------------------------------------------------------
# jq available (default). Every run below is CLEAN (finished, null
# stopped_reason, no sentinel), so the ONLY thing that can save it from
# age-based pruning is the new attempts.json signal.
# ---------------------------------------------------------------------------
clean_setup_farm

# Last attempt abnormal -> KEPT (the three abnormal enum values).
make_attempts_run "20260101T000100Z-attrlp00" "rate-limit-pending"
make_attempts_run "20260101T000101Z-attintr0" "interrupted"
make_attempts_run "20260101T000102Z-attfail0" "failed"

# Last attempt finished -> PRUNED (finished is clean; back-compat with age prune).
make_attempts_run "20260101T000103Z-attfin00" "finished"

# Last attempt finished-empty -> PRUNED. finished-empty is the OTHER clean
# terminal status (a successful run that produced no findings). The predicate
# lists it explicitly alongside finished; dropping it from the case would wrongly
# KEEP such a run, so this pins the second clean-status arm.
make_attempts_run "20260101T000109Z-attfemp0" "finished-empty"

# Multi-entry ordering: the LAST entry decides, not the first. This is the
# regression guard against reusing the first-match no-jq helper.
#   [interrupted, finished]          -> last is clean        -> PRUNED
#   [finished, rate-limit-pending]   -> last is abnormal     -> KEPT
make_attempts_run "20260101T000104Z-attordr1" "interrupted" "finished"
make_attempts_run "20260101T000105Z-attordr2" "finished" "rate-limit-pending"

# Empty array -> no last attempt -> no signal -> PRUNED (fail-safe boundary).
make_attempts_run "20260101T000106Z-attempty"

# No attempts.json at all -> unchanged behavior -> PRUNED (back-compat control).
make_run "20260101T000107Z-attnone0" "finished" "" 60 >/dev/null

# Corrupt / non-JSON attempts.json -> no extractable status -> no signal ->
# PRUNED, and clean must not crash on it.
corrupt_dir="$(make_run "20260101T000108Z-attcorpt" "finished" "" 60)"
printf 'this is not valid json {{{[[[\n' > "$corrupt_dir/attempts.json"
touch -d "@$(epoch_days_ago 60)" "$corrupt_dir"

# Default keep-incomplete is ON; rely on the default (do not pass the flag).
clean_run --older-than 1d --keep-last 0 --force
rc=$?
assert_eq "attempts-signal sweep exits 0" "0" "$rc"

assert_dir_present "last=rate-limit-pending kept"        "20260101T000100Z-attrlp00"
assert_dir_present "last=interrupted kept"               "20260101T000101Z-attintr0"
assert_dir_present "last=failed kept"                    "20260101T000102Z-attfail0"
assert_dir_absent  "last=finished pruned"               "20260101T000103Z-attfin00"
assert_dir_absent  "last=finished-empty pruned"         "20260101T000109Z-attfemp0"
assert_dir_absent  "[interrupted,finished] pruned (last wins)" "20260101T000104Z-attordr1"
assert_dir_present "[finished,rate-limit-pending] kept (last wins)" "20260101T000105Z-attordr2"
assert_dir_absent  "empty attempts array pruned"        "20260101T000106Z-attempty"
assert_dir_absent  "no attempts.json pruned (back-compat)" "20260101T000107Z-attnone0"
assert_dir_absent  "corrupt attempts.json pruned (no signal, no crash)" "20260101T000108Z-attcorpt"

# ---------------------------------------------------------------------------
# jq unavailable: the attempts.json signal must still work via the no-jq
# fallback, and crucially must read the LAST attempt (not the first). This
# exercises the dedicated last-status extractor end-to-end.
# ---------------------------------------------------------------------------
clean_cleanup
clean_setup_farm

make_attempts_run "20260101T000200Z-njqrlp00" "rate-limit-pending"
make_attempts_run "20260101T000201Z-njqordr0" "interrupted" "finished"
make_attempts_run "20260101T000202Z-njqfin00" "finished"
# finished-empty must also be prunable through the no-jq extractor (symmetry with
# the jq branch's second clean-status arm).
make_attempts_run "20260101T000203Z-njqfemp0" "finished-empty"
# Empty array []: the grep extractor finds no "status" -> empty -> no signal ->
# PRUNED. Exercises the grep-matches-nothing path end-to-end (grep exits 1 inside
# the pipefail pipeline) which the three status-bearing fixtures above never hit.
make_attempts_run "20260101T000204Z-njqempt0"
# Keep-direction ordering through the no-jq tail -n1 extractor: the LAST entry
# (rate-limit-pending) must win over an earlier finished -> KEPT. The sibling
# prune-direction case ([interrupted,finished]) only proves tail picks the last
# CLEAN status; this proves it picks the last ABNORMAL status too.
make_attempts_run "20260101T000205Z-njqkord0" "finished" "rate-limit-pending"

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
  record_pass "no-jq attempts sweep exits without crashing"
else
  record_fail "no-jq attempts sweep exits without crashing" "rc=$rc"
fi
assert_dir_present "no-jq last=rate-limit-pending kept" "20260101T000200Z-njqrlp00"
assert_dir_absent  "no-jq [interrupted,finished] pruned (last wins)" "20260101T000201Z-njqordr0"
assert_dir_absent  "no-jq last=finished pruned" "20260101T000202Z-njqfin00"
assert_dir_absent  "no-jq last=finished-empty pruned" "20260101T000203Z-njqfemp0"
assert_dir_absent  "no-jq empty attempts array pruned (no crash)" "20260101T000204Z-njqempt0"
assert_dir_present "no-jq [finished,rate-limit-pending] kept (last wins)" "20260101T000205Z-njqkord0"

clean_finish
