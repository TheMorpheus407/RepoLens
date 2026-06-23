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

# Behavioral coverage for issue #310 — populate `discarded_runs` in
# logs/latest-result.json via the clean.sh classification predicates.
#
# Sibling issue #308 shipped the pointer with `discarded_runs: []` as a
# placeholder. This issue replaces that placeholder: at finalize,
# write_latest_result_pointer must scan the OTHER genuine run dirs under
# <logs_dir> (everything except the current run) and emit a {run_id, reason}
# entry for each, where `reason` is derived from the existing `_clean_*`
# predicates in lib/clean.sh:
#
#   _clean_is_locked       -> skip (a live run is not "discarded")
#   _clean_is_incomplete   -> "aborted-or-incomplete"
#   no final/manifest.json AND .totals.issues_created == 0 -> "empty"
#   otherwise (a prior complete run)                       -> "superseded"
#
# The harness sources clean.sh (so the predicates are defined, matching
# production where repolens.sh sources clean.sh before result_pointer.sh),
# builds a logs tree BY HAND (no real run, NEVER a real model), calls the lib
# function with the documented signature, and asserts on
# logs/latest-result.json .discarded_runs.
#
# Two non-obvious behaviors are pinned deliberately:
#   * The current run (passed as <run_id>) must never appear in its own
#     discarded_runs.
#   * "empty" requires BOTH no manifest AND zero issues; a no-manifest run with
#     issues_created > 0 must be "superseded". The issue count lives at
#     .totals.issues_created (NOT a top-level .issues_created) — reading the
#     wrong path would misclassify every issue-bearing run as "empty", so
#     Scenario 2 guards that path directly.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
TOTAL=0
KEEP_ARTIFACTS=0
TMP_ROOT=""

# shellcheck disable=SC2329  # cleanup is invoked indirectly via 'trap cleanup EXIT' below.
cleanup() {
  if (( KEEP_ARTIFACTS == 0 )); then
    [[ -n "$TMP_ROOT" && -d "$TMP_ROOT" ]] && rm -rf "$TMP_ROOT"
  else
    printf 'Preserved test artifacts: %s\n' "$TMP_ROOT"
  fi
}
trap cleanup EXIT

pass_with() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

fail_with() {
  local desc="$1" detail="${2:-}"
  FAIL=$((FAIL + 1))
  KEEP_ARTIFACTS=1
  echo "  FAIL: $desc"
  [[ -n "$detail" ]] && printf '    %s\n' "$detail"
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected: $expected | Actual: $actual"
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

# assert_jq_true <desc> <file> <filter> — filter must evaluate truthy under jq -e.
assert_jq_true() {
  local desc="$1" file="$2" filter="$3"
  TOTAL=$((TOTAL + 1))
  if jq -e "$filter" "$file" >/dev/null 2>&1; then
    pass_with "$desc"
  else
    fail_with "$desc" "jq filter not truthy: $filter (file: $file)"
  fi
}

# assert_jq_eq <desc> <file> <filter> <expected>
assert_jq_eq() {
  local desc="$1" file="$2" filter="$3" expected="$4" actual
  TOTAL=$((TOTAL + 1))
  actual="$(jq -r "$filter" "$file" 2>/dev/null || printf '__jq_error__')"
  if [[ "$expected" == "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected: $expected | Actual: $actual | Filter: $filter"
  fi
}

finish() {
  echo ""
  echo "Results: $PASS/$TOTAL passed, $FAIL failed"
  [[ "$FAIL" -gt 0 ]] && exit 1
  exit 0
}

RP_LIB="$SCRIPT_DIR/lib/result_pointer.sh"
CORE_LIB="$SCRIPT_DIR/lib/core.sh"
LOG_LIB="$SCRIPT_DIR/lib/logging.sh"
CLEAN_LIB="$SCRIPT_DIR/lib/clean.sh"

TMP_ROOT="$(mktemp -d)"

# run_pointer <logs_dir> <run_id> <summary_file> <status> <final_dir>
# Calls the lib function in an isolated shell with the documented signature,
# sourcing clean.sh so the _clean_* predicates the scan relies on are defined
# (this mirrors production: repolens.sh sources clean.sh before
# result_pointer.sh). stderr is captured to $UNIT_ERR.
UNIT_ERR=""
run_pointer() {
  local logs_dir="$1" run_id="$2" summary_file="$3" status="$4" final_dir="$5"
  UNIT_ERR="$(mktemp "$TMP_ROOT/unit-err.XXXXXX")"
  bash -c '
    set -uo pipefail
    source "$1"   # core.sh           (severity_normalize)
    source "$2"   # logging.sh        (log_warn)
    source "$3"   # clean.sh          (_clean_is_run_dir / _clean_is_incomplete / _clean_is_locked)
    source "$4"   # result_pointer.sh (function under test)
    write_latest_result_pointer "$5" "$6" "audit" "codex" "$7" "$8" "$9"
  ' _ "$CORE_LIB" "$LOG_LIB" "$CLEAN_LIB" "$RP_LIB" \
    "$logs_dir" "$run_id" "$summary_file" "$status" "$final_dir" \
    2>"$UNIT_ERR"
  return $?
}

# seed_run <dir> <state> <stopped_reason_json> <issues_created>
# Builds a genuine run dir the clean selector recognizes: status.json (.state)
# + summary.json (.stopped_reason and .totals.issues_created). stopped_reason
# must be a JSON literal: `null` or `"some-reason"`.
seed_run() {
  local dir="$1" state="$2" stopped="$3" issues="$4" name="${1##*/}"
  mkdir -p "$dir"
  printf '{"run_id":"%s","state":"%s"}\n' "$name" "$state" > "$dir/status.json"
  printf '{"run_id":"%s","stopped_reason":%s,"totals":{"issues_created":%s}}\n' \
    "$name" "$stopped" "$issues" > "$dir/summary.json"
}

if [[ ! -f "$RP_LIB" ]]; then
  fail_with "lib/result_pointer.sh exists" "Missing $RP_LIB"
fi

# ---------------------------------------------------------------------------
# Scenario 1 — acceptance fixture from the issue
#
# current + incomplete(.rate-limit-abort) + empty(no final, 0 issues) +
# prior-complete(final/manifest.json) + two non-run dirs. discarded_runs must
# list EXACTLY the three non-current run dirs, each with the expected reason.
# ---------------------------------------------------------------------------
echo "=== discarded_runs classifies sibling run dirs (issue #310) ==="

LOGS1="$TMP_ROOT/logs1"
mkdir -p "$LOGS1"

CUR="20260601T000000Z-cur00000"     # current run — must be EXCLUDED
ABORT="20260601T010000Z-abort001"   # has .rate-limit-abort -> aborted-or-incomplete
EMPTY="20260601T020000Z-empty002"   # no final/, 0 issues    -> empty
PRIOR="20260601T030000Z-prior003"   # final/manifest.json    -> superseded
BARE="20260601T050000Z-bare005"     # run-id-shaped but NO summary/status -> not a run dir

# Current run: a genuine run dir, finished, that the scan must skip by run_id.
seed_run "$LOGS1/$CUR" "finished" "null" "0"

# Incomplete: state finished but an abort sentinel forces the resume-candidate
# classification (the sentinel is the trigger, isolating that path).
seed_run "$LOGS1/$ABORT" "finished" "null" "0"
touch "$LOGS1/$ABORT/.rate-limit-abort"

# Empty: finished, no final/ dir, zero issues.
seed_run "$LOGS1/$EMPTY" "finished" "null" "0"

# Prior complete: a finalized run with final/manifest.json present (and issues).
seed_run "$LOGS1/$PRIOR" "finished" "null" "2"
mkdir -p "$LOGS1/$PRIOR/final"
printf '[{"severity":"high","title":"prior finding"}]\n' > "$LOGS1/$PRIOR/final/manifest.json"

# Non-run dirs that must never appear:
mkdir -p "$LOGS1/issues"            # AutoDev state dir — name fails run-id regex
printf '{"state":"whatever"}\n' > "$LOGS1/issues/state.json"
mkdir -p "$LOGS1/not-a-run"         # bare, non-run-id name, no summary/status
mkdir -p "$LOGS1/$BARE"             # run-id-shaped but has NO summary.json/status.json

# The current run owns the summary_file passed to the helper (for timestamps).
run_pointer "$LOGS1" "$CUR" "$LOGS1/$CUR/summary.json" "finished" "$LOGS1/$CUR/final"
rc1=$?

POINTER1="$LOGS1/latest-result.json"

assert_eq "scan returns 0 (non-fatal finalize helper)" "0" "$rc1"
assert_file_exists "latest-result.json written" "$POINTER1"
assert_jq_true "latest-result.json is valid JSON" "$POINTER1" '.'
assert_jq_true "discarded_runs is an array" "$POINTER1" '.discarded_runs | type == "array"'

# Exactly the three non-current run dirs, no more, no fewer.
assert_jq_eq "discarded_runs lists exactly 3 runs" "$POINTER1" '.discarded_runs | length' "3"

# Every entry carries both required fields.
assert_jq_true "each discarded entry has run_id and reason" "$POINTER1" \
  'all(.discarded_runs[]; (has("run_id")) and (has("reason")))'

# Each run classified with the expected reason.
assert_jq_eq "incomplete run -> aborted-or-incomplete" "$POINTER1" \
  ".discarded_runs[] | select(.run_id==\"$ABORT\") | .reason" "aborted-or-incomplete"
assert_jq_eq "no-final zero-issue run -> empty" "$POINTER1" \
  ".discarded_runs[] | select(.run_id==\"$EMPTY\") | .reason" "empty"
assert_jq_eq "prior complete run (has manifest) -> superseded" "$POINTER1" \
  ".discarded_runs[] | select(.run_id==\"$PRIOR\") | .reason" "superseded"

# The current run is never listed in its own discarded_runs.
assert_jq_true "current run is NOT in discarded_runs" "$POINTER1" \
  "([.discarded_runs[].run_id] | index(\"$CUR\")) == null"

# Non-run dirs never appear (clean.sh's run-dir filter does this by construction).
assert_jq_true "AutoDev 'issues/' dir is NOT in discarded_runs" "$POINTER1" \
  '([.discarded_runs[].run_id] | index("issues")) == null'
assert_jq_true "bare non-run-id dir is NOT in discarded_runs" "$POINTER1" \
  '([.discarded_runs[].run_id] | index("not-a-run")) == null'
assert_jq_true "run-id-shaped dir with no summary/status is NOT in discarded_runs" "$POINTER1" \
  "([.discarded_runs[].run_id] | index(\"$BARE\")) == null"

# ---------------------------------------------------------------------------
# Scenario 2 — the .totals.issues_created path guard
#
# "empty" requires BOTH no manifest AND zero issues. A no-manifest run with
# issues_created > 0 must be "superseded", not "empty". Reading a top-level
# .issues_created (always null) instead of .totals.issues_created would
# misclassify the issue-bearing run as empty — this scenario catches that.
# ---------------------------------------------------------------------------
echo ""
echo "=== empty vs superseded keys off .totals.issues_created ==="

LOGS2="$TMP_ROOT/logs2"
mkdir -p "$LOGS2"

CUR2="20260601T000000Z-cur20000"
SUPISS="20260601T060000Z-supiss6"   # no manifest, issues>0 -> superseded (NOT empty)
ZERO="20260601T070000Z-zero007"     # no manifest, 0 issues -> empty

seed_run "$LOGS2/$CUR2" "finished" "null" "0"
seed_run "$LOGS2/$SUPISS" "finished" "null" "5"   # issues_created = 5, no final/
seed_run "$LOGS2/$ZERO" "finished" "null" "0"     # issues_created = 0, no final/

run_pointer "$LOGS2" "$CUR2" "$LOGS2/$CUR2/summary.json" "finished" "$LOGS2/$CUR2/final"
rc2=$?

POINTER2="$LOGS2/latest-result.json"

assert_eq "scenario 2 scan returns 0" "0" "$rc2"
assert_jq_eq "scenario 2 lists exactly 2 runs" "$POINTER2" '.discarded_runs | length' "2"
assert_jq_eq "no-manifest run WITH issues -> superseded (not empty)" "$POINTER2" \
  ".discarded_runs[] | select(.run_id==\"$SUPISS\") | .reason" "superseded"
assert_jq_eq "no-manifest run with ZERO issues -> empty" "$POINTER2" \
  ".discarded_runs[] | select(.run_id==\"$ZERO\") | .reason" "empty"

# ---------------------------------------------------------------------------
# Scenario 3 — a live (flock-held) sibling run is SKIPPED, not discarded
#
# The implementation maps _clean_is_locked -> skip (a live run is not
# "discarded"). The acceptance fixtures contain no locked run, so neither
# scenario above exercises that `continue` branch. Here we hold a real flock on
# a sibling run's .repolens.flock — mirroring how acquire_run_lock holds it
# during a live run (and the proven idiom in tests/test_clean_dry_run.sh) — and
# assert the locked run is absent while a non-locked sibling is still listed
# (proving the scan ran and only the live run was skipped). The locked run is
# seeded as a would-be-"superseded" run (manifest + issues), so if the skip
# branch regressed it would appear as a second entry and these asserts fail.
# Guarded by `command -v flock`, matching clean.sh's own flock dependency.
# ---------------------------------------------------------------------------
echo ""
echo "=== a live (flock-held) sibling run is skipped, not discarded ==="

if command -v flock >/dev/null 2>&1; then
  LOGS3="$TMP_ROOT/logs3"
  mkdir -p "$LOGS3"

  CUR3="20260601T000000Z-cur30000"
  LOCKED="20260601T080000Z-locked08"   # flock held -> live -> SKIPPED (absent)
  EMPTY3="20260601T090000Z-empty009"   # no final, 0 issues -> empty (proves scan ran)

  seed_run "$LOGS3/$CUR3" "finished" "null" "0"
  # Would classify as "superseded" if it were not skipped (manifest + issues).
  seed_run "$LOGS3/$LOCKED" "finished" "null" "3"
  mkdir -p "$LOGS3/$LOCKED/final"
  printf '[{"severity":"low","title":"locked finding"}]\n' > "$LOGS3/$LOCKED/final/manifest.json"
  seed_run "$LOGS3/$EMPTY3" "finished" "null" "0"

  lock_file3="$LOGS3/$LOCKED/.repolens.flock"
  # Hold an exclusive, non-blocking flock for the duration of the scan. The fd
  # is close-on-exec (bash {var}> semantics), so the bash -c probe child in
  # run_pointer opens its own fd and contends with this lock -> _clean_is_locked
  # returns 0 (locked).
  exec {hold_fd3}>"$lock_file3"
  flock -n "$hold_fd3"
  (
    exec {bg_fd3}>"$lock_file3"
    flock -n "$bg_fd3" || true   # already held by parent; keep the file busy
    sleep 5
  ) &
  bg_pid3=$!

  run_pointer "$LOGS3" "$CUR3" "$LOGS3/$CUR3/summary.json" "finished" "$LOGS3/$CUR3/final"
  rc3=$?

  exec {hold_fd3}>&-
  kill "$bg_pid3" 2>/dev/null || true
  wait "$bg_pid3" 2>/dev/null || true

  POINTER3="$LOGS3/latest-result.json"

  assert_eq "scenario 3 scan returns 0" "0" "$rc3"
  assert_jq_true "locked (live) run is NOT in discarded_runs" "$POINTER3" \
    "([.discarded_runs[].run_id] | index(\"$LOCKED\")) == null"
  assert_jq_eq "scenario 3 lists exactly 1 run (locked one skipped)" "$POINTER3" \
    '.discarded_runs | length' "1"
  assert_jq_eq "non-locked sibling is still classified (empty)" "$POINTER3" \
    ".discarded_runs[] | select(.run_id==\"$EMPTY3\") | .reason" "empty"
else
  echo "  SKIP: flock not available — locked-run skip branch not exercised"
fi

# ---------------------------------------------------------------------------
# Scenario 4 — "empty requires BOTH" from the manifest side, and the check
# keys on the final/manifest.json FILE (not merely a final/ dir).
#
# Scenario 1's prior-complete run conflated manifest-present WITH issues>0, so
# the manifest half of the "empty requires BOTH no-manifest AND zero-issues"
# rule was never isolated (Scenario 2 isolated only the issues half). Here:
#   * a run with final/manifest.json present but ZERO issues must be
#     "superseded" (manifest presence alone defeats "empty").
#   * a run with a final/ DIR present but NO manifest.json inside and zero
#     issues must be "empty" (the predicate is `-f final/manifest.json`, not
#     `-d final` — a crashed run that made final/ but never wrote the manifest
#     is still empty).
# ---------------------------------------------------------------------------
echo ""
echo "=== empty vs superseded keys off the final/manifest.json file ==="

LOGS4="$TMP_ROOT/logs4"
mkdir -p "$LOGS4"

CUR4="20260601T000000Z-cur40000"
MANIFEST0="20260601T100000Z-manz004"   # manifest present, 0 issues -> superseded
FINALNOMAN="20260601T110000Z-fnm0005"  # final/ dir, no manifest, 0 issues -> empty

seed_run "$LOGS4/$CUR4" "finished" "null" "0"
seed_run "$LOGS4/$MANIFEST0" "finished" "null" "0"
mkdir -p "$LOGS4/$MANIFEST0/final"
printf '[]\n' > "$LOGS4/$MANIFEST0/final/manifest.json"
seed_run "$LOGS4/$FINALNOMAN" "finished" "null" "0"
mkdir -p "$LOGS4/$FINALNOMAN/final"     # final/ dir exists, but NO manifest.json inside

run_pointer "$LOGS4" "$CUR4" "$LOGS4/$CUR4/summary.json" "finished" "$LOGS4/$CUR4/final"
rc4=$?

POINTER4="$LOGS4/latest-result.json"

assert_eq "scenario 4 scan returns 0" "0" "$rc4"
assert_jq_eq "scenario 4 lists exactly 2 runs" "$POINTER4" '.discarded_runs | length' "2"
assert_jq_eq "manifest present WITH zero issues -> superseded (not empty)" "$POINTER4" \
  ".discarded_runs[] | select(.run_id==\"$MANIFEST0\") | .reason" "superseded"
assert_jq_eq "final/ dir but NO manifest.json + zero issues -> empty" "$POINTER4" \
  ".discarded_runs[] | select(.run_id==\"$FINALNOMAN\") | .reason" "empty"

# ---------------------------------------------------------------------------
# Scenario 5 — no sibling runs, predicates sourced -> discarded_runs == []
#
# Both scenarios above always have siblings, so the empty-result path of the
# scan loop (clean.sh predicates ARE defined, but only the current run exists)
# is never reached. That path is distinct from the `declare -F` guard path that
# tests/test_latest_result_pointer.sh covers (where clean.sh is NOT sourced).
# Here clean.sh IS sourced: the loop runs, finds only the current run, skips it
# by run_id, and falls through to the empty `[]` return.
# ---------------------------------------------------------------------------
echo ""
echo "=== only the current run present -> discarded_runs is [] ==="

LOGS5="$TMP_ROOT/logs5"
mkdir -p "$LOGS5"

CUR5="20260601T000000Z-cur50000"
seed_run "$LOGS5/$CUR5" "finished" "null" "0"

run_pointer "$LOGS5" "$CUR5" "$LOGS5/$CUR5/summary.json" "finished" "$LOGS5/$CUR5/final"
rc5=$?

POINTER5="$LOGS5/latest-result.json"

assert_eq "scenario 5 scan returns 0" "0" "$rc5"
assert_jq_true "scenario 5 discarded_runs is an array" "$POINTER5" '.discarded_runs | type == "array"'
assert_jq_eq "no sibling runs -> discarded_runs is empty" "$POINTER5" '.discarded_runs | length' "0"

finish
