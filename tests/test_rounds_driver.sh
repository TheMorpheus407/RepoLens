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

# Tests for issue #143: lib/rounds.sh provides the round-aware outer
# driver. As of issue #169, the driver is wired into repolens.sh; these
# tests exercise the library entry point directly to keep the contract
# under unit-level coverage.
#
# shellcheck disable=SC2034  # Test globals are read by the sourced rounds module.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROUNDS_LIB="$SCRIPT_DIR/lib/rounds.sh"

PASS=0
FAIL=0
TOTAL=0

TMP_PARENT="$SCRIPT_DIR/logs/test-rounds-driver"
mkdir -p "$TMP_PARENT"
TMPDIR="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"

cleanup() {
  rm -rf "$TMPDIR"
  rmdir "$TMP_PARENT" 2>/dev/null || true
}
trap cleanup EXIT

pass_with() {
  local desc="$1"
  PASS=$((PASS + 1))
  echo "  PASS: $desc"
}

fail_with() {
  local desc="$1" detail="${2:-}"
  FAIL=$((FAIL + 1))
  echo "  FAIL: $desc"
  if [[ -n "$detail" ]]; then
    printf '    %s\n' "$detail"
  fi
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

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected to find: $needle"
  fi
}

assert_nonzero() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -ne 0 ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected non-zero exit status"
  fi
}

join_by() {
  local sep="$1"
  shift
  local IFS="$sep"
  printf '%s' "$*"
}

join_file_lines() {
  local file="$1" content

  if [[ ! -f "$file" ]]; then
    printf ''
    return
  fi

  content="$(tr '\n' ' ' < "$file")"
  printf '%s' "${content% }"
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

echo "=== rounds.sh run_rounds driver (issue #143) ==="

TOTAL=$((TOTAL + 1))
if [[ -f "$ROUNDS_LIB" ]]; then
  pass_with "lib/rounds.sh exists"
else
  fail_with "lib/rounds.sh exists" "Expected new module at $ROUNDS_LIB"
  finish
fi

log_info() {
  LOG_LINES+=("INFO:$*")
}

log_warn() {
  LOG_LINES+=("WARN:$*")
}

# shellcheck disable=SC1090,SC1091
source "$SCRIPT_DIR/lib/streak.sh"
# shellcheck disable=SC1090,SC1091
source "$SCRIPT_DIR/lib/template.sh"
# shellcheck disable=SC1090
source "$ROUNDS_LIB"

echo ""
echo "Test 0: default helpers use round markers and run meta handoff"
LOG_LINES=()
LOG_BASE="$TMPDIR/default-helper/logs"
mkdir -p "$LOG_BASE"
RUN_ID="default-helper"
PROJECT_PATH="$SCRIPT_DIR"
REPO_OWNER="local"
REPO_NAME="RepoLens"
MODE="audit"
AGENT="codex"
AGENT_TIMEOUT_SECS=5
AGENT_KILL_GRACE_SECS=1
BASE_PROMPTS_DIR="$SCRIPT_DIR/prompts/_base"
LENSES_DIR="$SCRIPT_DIR/prompts/lenses"
CURRENT_ROUND_TOTAL=8

RUN_AGENT_CALLS=()
run_agent() {
  local agent="$1" prompt="$2" project_path="$3" timeout_secs="$4" kill_grace_secs="$5"
  RUN_AGENT_CALLS+=("$agent:$project_path:$timeout_secs:$kill_grace_secs")
  assert_contains "meta prompt includes prior digest content" "Digest for round 7" "$prompt"
  printf '%s\n' \
    'LENS: injection' \
    'CUSTOM: auth-followup' \
    'HYPOTHESES_TO_VERIFY:' \
    '- Verify the selected follow-up angle.'
}

if is_round_completed 7; then
  completed_before=0
else
  completed_before=$?
fi
assert_nonzero "default is_round_completed is false before marker exists" "$completed_before"

mark_round_completed 7
rc=$?
assert_eq "default mark_round_completed exits successfully" "0" "$rc"

if is_round_completed 7; then
  completed_after=0
else
  completed_after=$?
fi
assert_eq "default is_round_completed is true after marker exists" "0" "$completed_after"
if [[ -f "$LOG_BASE/.rounds/round-7.completed" ]]; then
  marker_state="present"
else
  marker_state="missing"
fi
assert_eq "default marker path lives under LOG_BASE/.rounds" "present" "$marker_state"

mkdir -p "$LOG_BASE/rounds/round-7"
printf '%s\n' 'Digest for round 7' > "$LOG_BASE/rounds/round-7/digest.md"
run_meta_orchestrator 7 8
rc=$?
assert_eq "default run_meta_orchestrator exits successfully" "0" "$rc"
assert_eq "default run_meta_orchestrator invokes run_agent once" "1" "${#RUN_AGENT_CALLS[@]}"
assert_contains "default run_meta_orchestrator logs real handoff" \
                "Running meta-orchestrator for round 8" \
                "$(join_by " " "${LOG_LINES[@]}")"
assert_contains "default dispatch contains validated lens" \
                "LENS: injection" \
                "$(cat "$LOG_BASE/rounds/round-7/dispatch.md")"
assert_contains "default dispatch contains custom category" \
                "CUSTOM: auth-followup" \
                "$(cat "$LOG_BASE/rounds/round-7/dispatch.md")"
assert_contains "default hypotheses file contains extracted block" \
                "Verify the selected follow-up angle." \
                "$(cat "$LOG_BASE/rounds/round-7/hypotheses.md")"

reset_case() {
  local name="$1"
  CASE_DIR="$TMPDIR/$name"
  LOG_BASE="$CASE_DIR/logs"
  SUMMARY_FILE="$CASE_DIR/summary.json"
  mkdir -p "$LOG_BASE"
  printf '{"stopped_reason":null,"lenses":[]}\n' > "$SUMMARY_FILE"

  PARALLEL=false
  MAX_PARALLEL=3
  MAX_ISSUES=""
  TOTAL_LENSES=2
  GLOBAL_ISSUES_CREATED=0
  RUN_ID="test-$name"
  RATE_LIMIT_ON_LENS=""
  RATE_LIMIT_ON_SPAWN=""
  RUN_LENS_RESUME_GUARD=false
  RUN_LENS_MARK_COMPLETED=false
  USE_REAL_LENS_COMPLETION=false
  ROUND_COMPLETED_BEFORE=""
  MARK_ROUND_COMPLETED_RC=0
  META_RC=0
  WAIT_ALL_RC=0
  WAIT_ALL_TOUCH_RATE_LIMIT=false
  REMOTE_TARGET=""
  REMOTE_FAIL_ON_CALL=0
  COMPLETED_LENSES=""
  completed_lenses_file="$LOG_BASE/.completed"
  : > "$completed_lenses_file"

  ACTIONS=()
  LOG_LINES=()
  RUN_LENS_CALLS=()
  RUN_LENS_SKIPS=()
  REMOTE_CHECK_CALLS=()
  META_CALLS=()
  INIT_PARALLEL_CALLS=()
  SPAWN_CALLS=()
  WAIT_ALL_CALLS=()
  MARKED_ROUNDS=()
  STOP_REASONS=()
  RECORDED_LENSES=()
}

run_lens() {
  local lens_entry="$1"

  if $RUN_LENS_RESUME_GUARD && is_lens_completed "$lens_entry"; then
    RUN_LENS_SKIPS+=("$lens_entry")
    return 0
  fi

  ACTIONS+=("run:$lens_entry")
  RUN_LENS_CALLS+=("$lens_entry")
  if [[ "$lens_entry" == "$RATE_LIMIT_ON_LENS" ]]; then
    : > "$LOG_BASE/.rate-limit-abort"
  fi
  if $RUN_LENS_MARK_COMPLETED; then
    mark_lens_completed "$lens_entry"
  fi
}

run_meta_orchestrator() {
  local round="$1" next_round="$2"
  META_CALLS+=("$round->$next_round")
  return "$META_RC"
}

init_parallel() {
  local sem_dir="$1" max_parallel="$2"
  INIT_PARALLEL_CALLS+=("$sem_dir:$max_parallel")
}

spawn_lens() {
  local lens_entry="$1" callback="$2" callback_arg="$3"
  ACTIONS+=("spawn:$lens_entry")
  SPAWN_CALLS+=("$lens_entry:$callback:$callback_arg")
  if [[ "$lens_entry" == "$RATE_LIMIT_ON_SPAWN" ]]; then
    : > "$LOG_BASE/.rate-limit-abort"
  fi
}

wait_all() {
  ACTIONS+=("wait")
  WAIT_ALL_CALLS+=("wait")
  if $WAIT_ALL_TOUCH_RATE_LIMIT; then
    : > "$LOG_BASE/.rate-limit-abort"
  fi
  return "$WAIT_ALL_RC"
}

remote_check_master() {
  local check_number=$(( ${#REMOTE_CHECK_CALLS[@]} + 1 ))
  ACTIONS+=("remote-check:$check_number")
  REMOTE_CHECK_CALLS+=("$check_number")
  if [[ "${REMOTE_FAIL_ON_CALL:-0}" == "$check_number" ]]; then
    return 1
  fi
  return 0
}

is_lens_completed() {
  local lens_entry="$1"

  if $USE_REAL_LENS_COMPLETION; then
    [[ -n "${completed_lenses_file:-}" ]] && grep -qxF "$lens_entry" "$completed_lenses_file" 2>/dev/null
    return
  fi

  [[ " $COMPLETED_LENSES " == *" $lens_entry "* ]]
}

mark_lens_completed() {
  local lens_entry="$1"

  if $USE_REAL_LENS_COMPLETION; then
    echo "$lens_entry" >> "$completed_lenses_file"
    return
  fi

  COMPLETED_LENSES="${COMPLETED_LENSES:+$COMPLETED_LENSES }$lens_entry"
}

is_round_completed() {
  local round="$1"
  [[ " $ROUND_COMPLETED_BEFORE " == *" $round "* ]]
}

mark_round_completed() {
  local round="$1"
  MARKED_ROUNDS+=("$round")
  return "$MARK_ROUND_COMPLETED_RC"
}

record_lens() {
  local _summary_file="$1" domain="$2" lens_id="$3" iterations="$4" status="$5"
  RECORDED_LENSES+=("$domain/$lens_id:$iterations:$status")
}

set_stop_reason() {
  local _summary_file="$1" reason="$2"
  STOP_REASONS+=("$reason")
}

LENSES=("security/injection" "quality/dead-code")

echo ""
echo "Test 1: invalid run_rounds inputs are rejected before dispatch"
reset_case "invalid-rounds-total"
run_rounds 0 LENSES
rc=$?
assert_eq "invalid rounds_total returns usage error" "2" "$rc"
assert_contains "invalid rounds_total logs warning" "Invalid rounds_total: 0" "$(join_by " " "${LOG_LINES[@]}")"
assert_eq "invalid rounds_total does not run lenses" "" "$(join_by " " "${RUN_LENS_CALLS[@]}")"

reset_case "invalid-array-name"
run_rounds 1 'LENSES;touch-eval-ran'
rc=$?
assert_eq "invalid lens array name returns usage error" "2" "$rc"
assert_contains "invalid lens array name logs warning" "Invalid lens list array name" "$(join_by " " "${LOG_LINES[@]}")"
assert_eq "invalid lens array name does not run lenses" "" "$(join_by " " "${RUN_LENS_CALLS[@]}")"

echo ""
echo "Test 2: sequential rounds run every lens once per round and call meta between rounds"
reset_case "sequential-three"
run_rounds 3 LENSES
rc=$?
assert_eq "run_rounds 3 exits successfully" "0" "$rc"
assert_eq "sequential run_lens order covers every round" \
          "security/injection quality/dead-code security/injection quality/dead-code security/injection quality/dead-code" \
          "$(join_by " " "${RUN_LENS_CALLS[@]}")"
assert_eq "meta orchestrator is called after non-final rounds" \
          "1->2 2->3" \
          "$(join_by " " "${META_CALLS[@]}")"
assert_eq "each successful round is marked completed" \
          "1 2 3" \
          "$(join_by " " "${MARKED_ROUNDS[@]}")"

echo ""
echo "Test 2b: round-scoped lens completion files prevent later-round resume skips"
reset_case "round-scoped-completion"
USE_REAL_LENS_COMPLETION=true
RUN_LENS_RESUME_GUARD=true
RUN_LENS_MARK_COMPLETED=true
run_rounds 2 LENSES
rc=$?
assert_eq "resume-guarded run_rounds 2 exits successfully" "0" "$rc"
assert_eq "resume-guarded run_lens executes every lens in both rounds" \
          "security/injection quality/dead-code security/injection quality/dead-code" \
          "$(join_by " " "${RUN_LENS_CALLS[@]}")"
assert_eq "resume-guarded run_lens does not skip second-round lenses" \
          "" \
          "$(join_by " " "${RUN_LENS_SKIPS[@]}")"
assert_eq "round 1 lens completion file records only round 1 completions" \
          "security/injection quality/dead-code" \
          "$(join_file_lines "$LOG_BASE/.rounds/round-1.lenses.completed")"
assert_eq "round 2 lens completion file records only round 2 completions" \
          "security/injection quality/dead-code" \
          "$(join_file_lines "$LOG_BASE/.rounds/round-2.lenses.completed")"
assert_eq "run-level completed_lenses_file is restored after run_rounds" \
          "$LOG_BASE/.completed" \
          "$completed_lenses_file"
if [[ -s "$LOG_BASE/.completed" ]]; then
  original_completion_state="nonempty"
else
  original_completion_state="empty"
fi
assert_eq "run-level lens completion file is not polluted by round completions" \
          "empty" \
          "$original_completion_state"

echo ""
echo "Test 3: one round does not call the meta orchestrator"
reset_case "single-round"
run_rounds 1 LENSES
rc=$?
assert_eq "run_rounds 1 exits successfully" "0" "$rc"
assert_eq "single round runs each lens once" \
          "security/injection quality/dead-code" \
          "$(join_by " " "${RUN_LENS_CALLS[@]}")"
assert_eq "single round has no meta handoff" "" "$(join_by " " "${META_CALLS[@]}")"

echo ""
echo "Test 3b: single-round resume uses the existing run-level completion file"
reset_case "single-round-resume-parity"
USE_REAL_LENS_COMPLETION=true
RUN_LENS_RESUME_GUARD=true
RUN_LENS_MARK_COMPLETED=true
printf '%s\n' "security/injection" > "$LOG_BASE/.completed"
run_rounds 1 LENSES
rc=$?
assert_eq "single-round resume parity exits successfully" "0" "$rc"
assert_eq "single-round resume skips pre-completed lens" \
          "security/injection" \
          "$(join_by " " "${RUN_LENS_SKIPS[@]}")"
assert_eq "single-round resume runs only incomplete lens" \
          "quality/dead-code" \
          "$(join_by " " "${RUN_LENS_CALLS[@]}")"
assert_eq "single-round resume keeps original completed_lenses_file" \
          "$LOG_BASE/.completed" \
          "$completed_lenses_file"
assert_eq "single-round resume records completion in run-level file" \
          "security/injection quality/dead-code" \
          "$(join_file_lines "$LOG_BASE/.completed")"
if [[ -e "$LOG_BASE/.rounds/round-1.lenses.completed" ]]; then
  single_round_completion_state="present"
else
  single_round_completion_state="absent"
fi
assert_eq "single-round resume does not create a round-local lens completion file" \
          "absent" \
          "$single_round_completion_state"

echo ""
echo "Test 3c: sequential remote runs check the ControlMaster before each lens"
reset_case "sequential-remote-checks"
REMOTE_TARGET="deploy@remote.example"
run_rounds 1 LENSES
rc=$?
assert_eq "sequential remote run exits successfully" "0" "$rc"
assert_eq "sequential remote check runs before each lens" \
          "remote-check:1 run:security/injection remote-check:2 run:quality/dead-code" \
          "$(join_by " " "${ACTIONS[@]}")"
assert_eq "sequential remote check is called once per lens" \
          "1 2" \
          "$(join_by " " "${REMOTE_CHECK_CALLS[@]}")"

echo ""
echo "Test 3d: sequential remote check failure skips remaining lenses"
reset_case "sequential-remote-check-failure"
REMOTE_TARGET="deploy@remote.example"
REMOTE_FAIL_ON_CALL=2
run_rounds 1 LENSES
rc=$?
assert_nonzero "sequential remote check failure returns non-zero" "$rc"
assert_eq "sequential remote check failure stops before the second lens" \
          "remote-check:1 run:security/injection remote-check:2" \
          "$(join_by " " "${ACTIONS[@]}")"
assert_eq "sequential remote check failure records remaining lens as skipped" \
          "quality/dead-code:0:skipped" \
          "$(join_by " " "${RECORDED_LENSES[@]}")"
assert_contains "sequential remote check failure records stopped_reason" \
                "remote-controlmaster-lost" \
                "$(join_by " " "${STOP_REASONS[@]}")"
assert_eq "sequential remote check failure does not mark the round complete" \
          "" \
          "$(join_by " " "${MARKED_ROUNDS[@]}")"

echo ""
echo "Test 4: parallel mode reinitializes semaphore state once per round"
reset_case "parallel-two"
PARALLEL=true
run_rounds 2 LENSES
rc=$?
assert_eq "parallel run_rounds exits successfully" "0" "$rc"
assert_eq "init_parallel is called once per round with LOG_BASE semaphore" \
          "$LOG_BASE/.semaphore:3 $LOG_BASE/.semaphore:3" \
          "$(join_by " " "${INIT_PARALLEL_CALLS[@]}")"
assert_eq "spawn_lens receives each lens and run_lens callback per round" \
          "security/injection:run_lens:security/injection quality/dead-code:run_lens:quality/dead-code security/injection:run_lens:security/injection quality/dead-code:run_lens:quality/dead-code" \
          "$(join_by " " "${SPAWN_CALLS[@]}")"
assert_eq "wait_all is called once per round" \
          "wait wait" \
          "$(join_by " " "${WAIT_ALL_CALLS[@]}")"

echo ""
echo "Test 4b: parallel remote runs check the ControlMaster before each spawn"
reset_case "parallel-remote-checks"
PARALLEL=true
REMOTE_TARGET="deploy@remote.example"
run_rounds 1 LENSES
rc=$?
assert_eq "parallel remote run exits successfully" "0" "$rc"
assert_eq "parallel remote check runs before each spawn" \
          "remote-check:1 spawn:security/injection remote-check:2 spawn:quality/dead-code wait" \
          "$(join_by " " "${ACTIONS[@]}")"
assert_eq "parallel remote check is called once per lens" \
          "1 2" \
          "$(join_by " " "${REMOTE_CHECK_CALLS[@]}")"

echo ""
echo "Test 4c: parallel remote check failure waits and skips unspawned lenses"
reset_case "parallel-remote-check-failure"
PARALLEL=true
REMOTE_TARGET="deploy@remote.example"
REMOTE_FAIL_ON_CALL=2
run_rounds 1 LENSES
rc=$?
assert_nonzero "parallel remote check failure returns non-zero" "$rc"
assert_eq "parallel remote check failure stops before the second spawn and waits" \
          "remote-check:1 spawn:security/injection remote-check:2 wait" \
          "$(join_by " " "${ACTIONS[@]}")"
assert_eq "parallel remote check failure records unspawned lens as skipped" \
          "quality/dead-code:0:skipped" \
          "$(join_by " " "${RECORDED_LENSES[@]}")"
assert_contains "parallel remote check failure records stopped_reason" \
                "remote-controlmaster-lost" \
                "$(join_by " " "${STOP_REASONS[@]}")"
assert_eq "parallel remote check failure does not mark the round complete" \
          "" \
          "$(join_by " " "${MARKED_ROUNDS[@]}")"
assert_eq "parallel remote check failure waits for already spawned children" \
          "wait" \
          "$(join_by " " "${WAIT_ALL_CALLS[@]}")"

echo ""
echo "Test 5: rate-limit abort stops before the next round and records stop reason"
reset_case "rate-limit-stop"
RATE_LIMIT_ON_LENS="security/injection"
run_rounds 3 LENSES
rc=$?
assert_nonzero "run_rounds returns non-zero after rate-limit abort" "$rc"
assert_eq "rate-limited run stops before later lenses and rounds" \
          "security/injection" \
          "$(join_by " " "${RUN_LENS_CALLS[@]}")"
assert_eq "rate-limited run records remaining lens as skipped" \
          "quality/dead-code:0:skipped" \
          "$(join_by " " "${RECORDED_LENSES[@]}")"
assert_contains "rate-limited run records stopped_reason" \
                "rate-limited" \
                "$(join_by " " "${STOP_REASONS[@]}")"
assert_eq "rate-limited run does not call meta orchestrator" "" "$(join_by " " "${META_CALLS[@]}")"
assert_eq "rate-limited run restores run-level completed_lenses_file" \
          "$LOG_BASE/.completed" \
          "$completed_lenses_file"

echo ""
echo "Test 6: pre-existing rate-limit abort prevents dispatch"
reset_case "pre-existing-rate-limit"
: > "$LOG_BASE/.rate-limit-abort"
run_rounds 2 LENSES
rc=$?
assert_nonzero "pre-existing rate-limit returns non-zero" "$rc"
assert_eq "pre-existing rate-limit does not run lenses" "" "$(join_by " " "${RUN_LENS_CALLS[@]}")"
assert_eq "pre-existing rate-limit does not spawn lenses" "" "$(join_by " " "${SPAWN_CALLS[@]}")"
assert_contains "pre-existing rate-limit records stopped_reason" \
                "rate-limited" \
                "$(join_by " " "${STOP_REASONS[@]}")"
assert_eq "pre-existing rate-limit does not mark a round" "" "$(join_by " " "${MARKED_ROUNDS[@]}")"

echo ""
echo "Test 7: parallel rate-limit during spawn skips unspawned lenses"
reset_case "parallel-rate-limit-during-spawn"
PARALLEL=true
RATE_LIMIT_ON_SPAWN="security/injection"
run_rounds 2 LENSES
rc=$?
assert_nonzero "parallel spawn-loop rate-limit returns non-zero" "$rc"
assert_eq "parallel spawn-loop rate-limit stops spawning after marker appears" \
          "security/injection:run_lens:security/injection" \
          "$(join_by " " "${SPAWN_CALLS[@]}")"
assert_eq "parallel spawn-loop rate-limit records unspawned remaining lens as skipped" \
          "quality/dead-code:0:skipped" \
          "$(join_by " " "${RECORDED_LENSES[@]}")"
assert_contains "parallel spawn-loop rate-limit records stopped_reason" \
                "rate-limited" \
                "$(join_by " " "${STOP_REASONS[@]}")"
assert_eq "parallel spawn-loop rate-limit still waits for spawned children" "wait" "$(join_by " " "${WAIT_ALL_CALLS[@]}")"
assert_eq "parallel spawn-loop rate-limit does not mark the aborted round" "" "$(join_by " " "${MARKED_ROUNDS[@]}")"

echo ""
echo "Test 8: parallel rate-limit after wait_all prevents marking or advancing rounds"
reset_case "parallel-rate-limit-after-wait"
PARALLEL=true
WAIT_ALL_TOUCH_RATE_LIMIT=true
run_rounds 2 LENSES
rc=$?
assert_nonzero "parallel post-wait rate-limit returns non-zero" "$rc"
assert_eq "parallel post-wait rate-limit only spawns the first round" \
          "security/injection:run_lens:security/injection quality/dead-code:run_lens:quality/dead-code" \
          "$(join_by " " "${SPAWN_CALLS[@]}")"
assert_contains "parallel post-wait rate-limit records stopped_reason" \
                "rate-limited" \
                "$(join_by " " "${STOP_REASONS[@]}")"
assert_eq "parallel post-wait rate-limit does not mark the aborted round" "" "$(join_by " " "${MARKED_ROUNDS[@]}")"
assert_eq "parallel post-wait rate-limit does not call meta orchestrator" "" "$(join_by " " "${META_CALLS[@]}")"

echo ""
echo "Test 9: completed rounds are skipped under resume"
reset_case "resume-skip"
ROUND_COMPLETED_BEFORE="1"
run_rounds 2 LENSES
rc=$?
assert_eq "resume run exits successfully" "0" "$rc"
assert_contains "resume logs skipped completed round" "Skipping" "$(join_by " " "${LOG_LINES[@]}")"
assert_eq "resume skip only runs the uncompleted round's lenses" \
          "security/injection quality/dead-code" \
          "$(join_by " " "${RUN_LENS_CALLS[@]}")"
assert_eq "resume skip marks only the newly completed round" \
          "2" \
          "$(join_by " " "${MARKED_ROUNDS[@]}")"

echo ""
echo "Test 10: wait_all failure warns but does not fail the round without a rate-limit marker"
reset_case "wait-all-warning"
PARALLEL=true
WAIT_ALL_RC=42
run_rounds 1 LENSES
rc=$?
assert_eq "wait_all non-zero preserves current non-fatal behavior" "0" "$rc"
assert_contains "wait_all non-zero logs a warning" "Some lenses exited with errors." "$(join_by " " "${LOG_LINES[@]}")"
assert_eq "wait_all non-zero still marks the round complete" "1" "$(join_by " " "${MARKED_ROUNDS[@]}")"

echo ""
echo "Test 11: meta-orchestrator failure stops later rounds"
reset_case "meta-failure"
META_RC=37
run_rounds 3 LENSES
rc=$?
assert_eq "meta-orchestrator failure status is propagated" "37" "$rc"
assert_eq "meta-orchestrator failure stops before round 2 dispatch" \
          "security/injection quality/dead-code" \
          "$(join_by " " "${RUN_LENS_CALLS[@]}")"
assert_eq "meta-orchestrator is called once before failure" "1->2" "$(join_by " " "${META_CALLS[@]}")"
assert_eq "meta-orchestrator failure still leaves completed round marked" "1" "$(join_by " " "${MARKED_ROUNDS[@]}")"

echo ""
echo "Test 12: sequential max-issues skip records only incomplete remaining lenses"
reset_case "max-issues-skip"
GLOBAL_ISSUES_CREATED=2
MAX_ISSUES=2
COMPLETED_LENSES="security/injection"
run_rounds 1 LENSES
rc=$?
assert_eq "max-issues skip exits successfully" "0" "$rc"
assert_eq "max-issues skip does not start another lens" "" "$(join_by " " "${RUN_LENS_CALLS[@]}")"
assert_eq "max-issues skip records only incomplete remaining lenses" \
          "quality/dead-code:0:skipped" \
          "$(join_by " " "${RECORDED_LENSES[@]}")"
assert_contains "max-issues skip records stopped_reason" \
                "max-issues-reached" \
                "$(join_by " " "${STOP_REASONS[@]}")"
assert_eq "max-issues skip still marks the round complete" "1" "$(join_by " " "${MARKED_ROUNDS[@]}")"

echo ""
echo "Test 13: mark_round_completed failure restores completion state and stops"
reset_case "mark-round-failure"
MARK_ROUND_COMPLETED_RC=41
run_rounds 2 LENSES
rc=$?
assert_eq "mark_round_completed failure status is propagated" "41" "$rc"
assert_eq "mark_round_completed failure runs only the first round" \
          "security/injection quality/dead-code" \
          "$(join_by " " "${RUN_LENS_CALLS[@]}")"
assert_eq "mark_round_completed failure attempts to mark the finished round" \
          "1" \
          "$(join_by " " "${MARKED_ROUNDS[@]}")"
assert_eq "mark_round_completed failure does not call meta orchestrator" \
          "" \
          "$(join_by " " "${META_CALLS[@]}")"
assert_eq "mark_round_completed failure restores run-level completed_lenses_file" \
          "$LOG_BASE/.completed" \
          "$completed_lenses_file"

echo ""
echo "Test 14: completed_lenses_file remains unset when it started unset"
reset_case "unset-completed-file"
unset completed_lenses_file
run_rounds 1 LENSES
rc=$?
assert_eq "unset completed_lenses_file run exits successfully" "0" "$rc"
assert_eq "unset completed_lenses_file run still dispatches lenses" \
          "security/injection quality/dead-code" \
          "$(join_by " " "${RUN_LENS_CALLS[@]}")"
if [[ ${completed_lenses_file+x} == x ]]; then
  completed_lenses_state="set"
else
  completed_lenses_state="unset"
fi
assert_eq "completed_lenses_file is restored to unset state" \
          "unset" \
          "$completed_lenses_state"

echo ""
echo "Test 14b: completed_lenses_file remains unset after multi-round execution"
reset_case "unset-completed-file-multi"
unset completed_lenses_file
run_rounds 2 LENSES
rc=$?
assert_eq "unset multi-round completed_lenses_file run exits successfully" "0" "$rc"
assert_eq "unset multi-round completed_lenses_file run dispatches both rounds" \
          "security/injection quality/dead-code security/injection quality/dead-code" \
          "$(join_by " " "${RUN_LENS_CALLS[@]}")"
if [[ ${completed_lenses_file+x} == x ]]; then
  completed_lenses_state="set"
else
  completed_lenses_state="unset"
fi
assert_eq "multi-round completed_lenses_file is restored to unset state" \
          "unset" \
          "$completed_lenses_state"

finish
