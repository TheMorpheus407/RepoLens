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

# Saved meta success and round barriers recover without repeating model work.
# shellcheck disable=SC2034,SC2329 # Globals and callbacks are used by the driver.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)" || exit 1
trap 'rm -rf "$TEST_DIR"' EXIT
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/rounds.sh"
passed=0 failed=0
check() {
  if "$@"; then passed=$((passed + 1)); else failed=$((failed + 1)); printf 'FAIL: %s\n' "$*"; fi
}
log_info() { :; }
log_warn() { :; }
set_stop_reason() { :; }
record_lens() { :; }
compose_prompt() { printf 'meta prompt'; }
run_agent() {
  printf 'meta\n' >> "$LOG_BASE/meta-calls"
  if [[ "${ENVELOPE_KIND:-absent}" == success ]]; then
    printf '{"is_error":false}\n' > "$6"
  elif [[ "${ENVELOPE_KIND:-absent}" == failure ]]; then
    printf '{"is_error":true}\n' > "$6"
  elif [[ "${ENVELOPE_KIND:-absent}" == rate ]]; then
    printf '{"is_error":true,"api_error_status":429}\n' > "$6"
  fi
  if [[ "$META_OUTPUT" == saturated ]]; then printf 'NO_FRESH_ANGLES\n';
  else printf 'LENS: injection role=deep focus="trace pipes | safely"\nHYPOTHESES_TO_VERIFY:\n- Follow up.\n'; fi
  return "${AGENT_RC:-0}"
}
run_lens() {
  local canonical role focus anchor exclude
  _rounds_meta_tuple_parse "$1" canonical role focus anchor exclude
  if ! grep -qxF "$canonical" "$completed_lenses_file" 2>/dev/null; then
    printf '%s\n' "$CURRENT_ROUND_INDEX:$1" >> "$LOG_BASE/lens-calls"
    printf '%s\n' "$canonical" >> "$completed_lenses_file"
  fi
}
build_round_digest() { mkdir -p "$1"; printf 'digest\n' > "$1/digest.md"; }
LOCAL_MODE=false PARALLEL=false
RUN_ID=probe RESUME_RUN_ID=probe MODE=audit AGENT=codex
LENSES_DIR="$SCRIPT_DIR/prompts/lenses"
LENSES=(security/injection)
SUMMARY_FILE="$TEST_DIR/summary.json"

# Use production finalize_round: its primary marker commits before legacy fails.
for META_OUTPUT in normal saturated; do
  for marker in primary legacy both neither; do
    LOG_BASE="$TEST_DIR/$META_OUTPUT-$marker"
    mkdir -p "$LOG_BASE/.rounds/round-1.completed"
    completed_lenses_file="$LOG_BASE/.completed"
    run_rounds 2 LENSES
    check test "$?" -ne 0
    check test -f "$LOG_BASE/rounds/round-1/.completed"
    check test "$(wc -l < "$LOG_BASE/meta-calls")" -eq 1
    check test ! -e "$LOG_BASE/rounds/round-2/digest.md"
    rmdir "$LOG_BASE/.rounds/round-1.completed"
    if [[ "$marker" == legacy || "$marker" == neither ]]; then rm "$LOG_BASE/rounds/round-1/.completed"; fi
    if [[ "$marker" == legacy || "$marker" == both ]]; then touch "$LOG_BASE/.rounds/round-1.completed"; fi
    primary_before=""
    if [[ -f "$LOG_BASE/rounds/round-1/.completed" ]]; then
      primary_before="$(stat -c '%y' "$LOG_BASE/rounds/round-1/.completed")"
    fi
    dispatch_before="$(stat -c '%y' "$LOG_BASE/rounds/round-1/dispatch.md")"
    hypotheses_before="$(stat -c '%y' "$LOG_BASE/rounds/round-1/hypotheses.md")"
    run_rounds 2 LENSES
    check test "$?" -eq 0
    check test "$(wc -l < "$LOG_BASE/meta-calls")" -eq 1
    check test -f "$LOG_BASE/rounds/round-1/.completed"
    check test -f "$LOG_BASE/.rounds/round-1.completed"
    if [[ -n "$primary_before" ]]; then
      check test "$(stat -c '%y' "$LOG_BASE/rounds/round-1/.completed")" = "$primary_before"
    fi
    check test "$(stat -c '%y' "$LOG_BASE/rounds/round-1/dispatch.md")" = "$dispatch_before"
    check test "$(stat -c '%y' "$LOG_BASE/rounds/round-1/hypotheses.md")" = "$hypotheses_before"
    if [[ "$META_OUTPUT" == saturated ]]; then
      check test "$(wc -l < "$LOG_BASE/lens-calls")" -eq 1
      check test ! -e "$LOG_BASE/rounds/round-2/digest.md"
    else
      check test "$(wc -l < "$LOG_BASE/lens-calls")" -eq 2
      check grep -Fq '|deep|' "$LOG_BASE/lens-calls"
      check grep -q 'Follow up' "${HYPOTHESES_TO_VERIFY_FILE:-missing}"
      final_digest_before="$(stat -c '%y' "$LOG_BASE/rounds/round-2/digest.md")"
      # Attributed dispatch completion must compare canonical IDs on another retry.
      run_rounds 2 LENSES
      check test "$?" -eq 0
      check test "$(wc -l < "$LOG_BASE/meta-calls")" -eq 1
      check test "$(wc -l < "$LOG_BASE/lens-calls")" -eq 2
      check test "$(stat -c '%y' "$LOG_BASE/rounds/round-2/digest.md")" = "$final_digest_before"
    fi
    check test "$completed_lenses_file" = "$LOG_BASE/.completed"
  done
done

# Real phase classification rejects nonzero and structured failures, even when
# the raw output looks like a valid handoff. No live model or forge is called.
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/streak.sh"
reset_case() {
  LOG_BASE="$TEST_DIR/$1"
  mkdir -p "$LOG_BASE"
  completed_lenses_file="$LOG_BASE/.completed"
  LENSES=(security/injection)
  META_OUTPUT=saturated
  ENVELOPE_KIND=absent AGENT_RC=0
  REPOLENS_FINAL_STATE=finished
}

for fault in missing-proof altered-proof altered-output added-envelope altered-envelope removed-envelope; do
  reset_case "evidence-$fault"
  if [[ "$fault" == *-envelope && "$fault" != added-envelope ]]; then ENVELOPE_KIND=success; fi
  run_rounds 2 LENSES
  check test "$?" -eq 0
  round_dir_saved="$LOG_BASE/rounds/round-1"
  case "$fault" in
    missing-proof) rm "$round_dir_saved/meta-orchestrator-success.json" ;;
    altered-proof) printf '{}\n' > "$round_dir_saved/meta-orchestrator-success.json" ;;
    altered-output) printf 'changed\n' >> "$round_dir_saved/meta-orchestrator-output.txt" ;;
    added-envelope) printf '{}\n' > "$round_dir_saved/meta-orchestrator-output.txt.envelope.json" ;;
    altered-envelope) printf '{}\n' > "$round_dir_saved/meta-orchestrator-output.txt.envelope.json" ;;
    removed-envelope) rm "$round_dir_saved/meta-orchestrator-output.txt.envelope.json" ;;
  esac
  run_rounds 2 LENSES
  check test "$?" -eq 0
  check test "$(wc -l < "$LOG_BASE/meta-calls")" -eq 2
  check test "$(wc -l < "$LOG_BASE/lens-calls")" -eq 1
done

reset_case repair-artifacts
META_OUTPUT=normal
run_rounds 2 LENSES
check test "$?" -eq 0
saved_dir="$LOG_BASE/rounds/round-1"
hypotheses_before="$(stat -c '%y' "$saved_dir/hypotheses.md")"
printf 'untrusted stale dispatch\n' > "$saved_dir/dispatch.md"
run_rounds 2 LENSES
check test "$?" -eq 0
check test "$(wc -l < "$LOG_BASE/meta-calls")" -eq 1
check test "$(stat -c '%y' "$saved_dir/hypotheses.md")" = "$hypotheses_before"
check grep -q '^LENS: injection' "$saved_dir/dispatch.md"
rm "$saved_dir/hypotheses.md"
mkdir "$saved_dir/hypotheses.md"
run_rounds 2 LENSES
check test "$?" -ne 0
check test "$(wc -l < "$LOG_BASE/meta-calls")" -eq 1
rmdir "$saved_dir/hypotheses.md"
run_rounds 2 LENSES
check test "$?" -eq 0
check grep -q 'Follow up' "$saved_dir/hypotheses.md"
check test "$(wc -l < "$LOG_BASE/meta-calls")" -eq 1

reset_case pending-canonical
run_rounds 2 LENSES
check test "$?" -eq 0
LENSES+=(security/xss-csrf)
run_rounds 2 LENSES
check test "$?" -eq 0
check test "$(wc -l < "$LOG_BASE/meta-calls")" -eq 2
check test "$(wc -l < "$LOG_BASE/lens-calls")" -eq 2

# A newly completed lens followed by interruption must retire an older proof
# before the next resume evaluates completion eligibility.
eval "$(declare -f run_lens | sed '1s/run_lens/original_run_lens/')"
for saved_output in normal saturated; do
  reset_case "pending-interrupted-$saved_output"
  META_OUTPUT="$saved_output"
  run_rounds 2 LENSES
  check test "$?" -eq 0
  LENSES+=(security/xss-csrf)
  run_lens() {
    original_run_lens "$@"
    if [[ "$CURRENT_ROUND_INDEX" == 1 && "$1" == security/xss-csrf ]]; then
      REPOLENS_FINAL_STATE=interrupted
      REPOLENS_INTERRUPT_EXIT_CODE=143
    fi
    return 0
  }
  run_rounds 2 LENSES
  check test "$?" -ne 0
  check test "$REPOLENS_FINAL_STATE" = interrupted
  check test "$(wc -l < "$LOG_BASE/meta-calls")" -eq 1
  check test ! -e "$LOG_BASE/rounds/round-1/meta-orchestrator-success.json"
  run_lens() { original_run_lens "$@"; }
  REPOLENS_FINAL_STATE=finished
  if [[ "$saved_output" == normal ]]; then META_OUTPUT=saturated; else META_OUTPUT=normal; fi
  run_rounds 2 LENSES
  check test "$?" -eq 0
  check test "$(wc -l < "$LOG_BASE/meta-calls")" -eq 2
  check test "$(grep -c '^1:' "$LOG_BASE/lens-calls")" -eq 2
  if [[ "$META_OUTPUT" == saturated ]]; then
    check grep -q NO_FRESH_ANGLES "$LOG_BASE/rounds/round-1/dispatch.md"
  else
    check grep -q '^LENS: injection' "$LOG_BASE/rounds/round-1/dispatch.md"
  fi
done

for fault in nonzero structured rate; do
  reset_case "agent-$fault"
  mkdir -p "$LOG_BASE/rounds/round-1"
  # Valid-looking old artifacts must never substitute for accepted execution.
  printf 'LENS: injection\n' > "$LOG_BASE/rounds/round-1/dispatch.md"
  touch "$LOG_BASE/rounds/round-1/hypotheses.md"
  case "$fault" in
    nonzero) AGENT_RC=42 ;;
    structured) ENVELOPE_KIND=failure ;;
    rate) ENVELOPE_KIND=rate ;;
  esac
  run_rounds 2 LENSES
  rc=$?
  check test "$rc" -ne 0
  if [[ "$fault" == rate ]]; then check test "$rc" -eq 3; fi
  check test ! -e "$LOG_BASE/rounds/round-1/meta-orchestrator-success.json"
  check test ! -e "$LOG_BASE/rounds/round-1/.completed"
  rm -f "$LOG_BASE/.rate-limit-abort"
  AGENT_RC=0 ENVELOPE_KIND=absent
  run_rounds 2 LENSES
  check test "$?" -eq 0
  check test ! -e "$LOG_BASE/rounds/round-1/meta-orchestrator-output.txt.envelope.json"
  check test "$(wc -l < "$LOG_BASE/meta-calls")" -eq 2
done

# Failed proof persistence or derived write must not advance or dispatch again
# while an accepted result remains repairable.
reset_case proof-write-failure
mkdir -p "$LOG_BASE/rounds/round-1/meta-orchestrator-success.json"
run_rounds 2 LENSES
check test "$?" -ne 0
check test ! -e "$LOG_BASE/rounds/round-1/.completed"
check test ! -e "$LOG_BASE/meta-calls"
rmdir "$LOG_BASE/rounds/round-1/meta-orchestrator-success.json"
run_rounds 2 LENSES
check test "$?" -eq 0

reset_case proof-after-call-failure
# Fail the proof writer after successful execution; the next attempt must retry.
eval "$(declare -f _rounds_meta_certify_success | sed '1s/_rounds_meta_certify_success/original_certify/')"
_rounds_meta_certify_success() { return 1; }
run_rounds 2 LENSES
check test "$?" -ne 0
check test ! -e "$LOG_BASE/rounds/round-1/dispatch.md"
check test ! -e "$LOG_BASE/rounds/round-1/.completed"
_rounds_meta_certify_success() { original_certify "$@"; }
run_rounds 2 LENSES
check test "$?" -eq 0
check test "$(wc -l < "$LOG_BASE/meta-calls")" -eq 2

# Single/final rounds need no meta evidence and repair partial barriers.
for marker in primary legacy both neither; do
  reset_case "single-$marker"
  printf 'security/injection\n' > "$completed_lenses_file"
  mkdir -p "$LOG_BASE/rounds/round-1" "$LOG_BASE/.rounds"
  if [[ "$marker" == primary || "$marker" == both ]]; then touch "$LOG_BASE/rounds/round-1/.completed"; fi
  if [[ "$marker" == legacy || "$marker" == both ]]; then touch "$LOG_BASE/.rounds/round-1.completed"; fi
  run_rounds 1 LENSES
  check test "$?" -eq 0
  check test ! -e "$LOG_BASE/meta-calls"
  check test ! -e "$LOG_BASE/lens-calls"
  check test -f "$LOG_BASE/rounds/round-1/.completed"
  check test -f "$LOG_BASE/.rounds/round-1.completed"
done

reset_case primary-marker-write-failure
mkdir -p "$LOG_BASE/rounds/round-1/.completed"
run_rounds 2 LENSES
check test "$?" -ne 0
check test ! -e "$LOG_BASE/.rounds/round-1.completed"
check test ! -e "$LOG_BASE/rounds/round-2/digest.md"
rmdir "$LOG_BASE/rounds/round-1/.completed"
run_rounds 2 LENSES
check test "$?" -eq 0
check test "$(wc -l < "$LOG_BASE/meta-calls")" -eq 1

# Canonical identity checks preserve escaped context on the callback tuple.
completion_probe="$TEST_DIR/canonical-completed"
printf 'security/injection\n' > "$completion_probe"
check _rounds_all_lenses_completed "$completion_probe" 'security/injection|deep|pipes\|context|a|b'

reset_case final-marker-write-failure
META_OUTPUT=normal
mkdir -p "$LOG_BASE/.rounds/round-2.completed"
run_rounds 2 LENSES
check test "$?" -ne 0
check test -f "$LOG_BASE/rounds/round-2/.completed"
final_marker_before="$(stat -c '%y' "$LOG_BASE/rounds/round-2/.completed")"
final_digest_before="$(stat -c '%y' "$LOG_BASE/rounds/round-2/digest.md")"
rmdir "$LOG_BASE/.rounds/round-2.completed"
run_rounds 2 LENSES
check test "$?" -eq 0
check test "$(wc -l < "$LOG_BASE/meta-calls")" -eq 1
check test "$(wc -l < "$LOG_BASE/lens-calls")" -eq 2
check test "$(stat -c '%y' "$LOG_BASE/rounds/round-2/.completed")" = "$final_marker_before"
check test "$(stat -c '%y' "$LOG_BASE/rounds/round-2/digest.md")" = "$final_digest_before"
check test -f "$LOG_BASE/.rounds/round-2.completed"
# The actual parallel TERM/INT traps also apply during saved-result recovery,
# even though no callback is launched on that shortcut.
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/parallel.sh"
parallel_preflight() { _REPOLENS_SCOPE_READY=1; return 0; }
eval "$(declare -f _rounds_meta_restore_success | sed '1s/_rounds_meta_restore_success/saved_restore_success/')"
eval "$(declare -f _rounds_repair_completion | sed '1s/_rounds_repair_completion/saved_repair_completion/')"
eval "$(declare -f run_agent | sed '1s/run_agent/saved_recovery_agent/')"
run_agent() {
  local META_OUTPUT=normal
  if [[ "${CURRENT_ROUND_INDEX:-}" == 2 ]]; then META_OUTPUT="$recovery_output"; fi
  saved_recovery_agent "$@"
}
_rounds_meta_restore_success() {
  local result=0
  saved_restore_success "$@" || result=$?
  if [[ "$recovery_armed" == true && "$recovery_moment" == restore && "$1" == "$recovery_target" && "$result" == 0 ]]; then
    kill -s "$recovery_signal" "$BASHPID"
  fi
  return "$result"
}
_rounds_repair_completion() {
  local result=0
  if [[ "$recovery_armed" == true && "${REPOLENS_FINAL_STATE:-}" == interrupted ]]; then
    repairs_after_signal=$((repairs_after_signal + 1))
  fi
  saved_repair_completion "$@" || result=$?
  if [[ "$recovery_armed" == true && "$recovery_moment" == repair && "$1" == "$recovery_round" && "$result" == 0 ]]; then
    kill -s "$recovery_signal" "$BASHPID"
  fi
  return "$result"
}
for recovery_signal in INT TERM; do
  for recovery_output in normal saturated; do
    for recovery_moment in restore repair; do
      reset_case "recover-$recovery_signal-$recovery_output-$recovery_moment"
      recovery_armed=false
      run_rounds 3 LENSES
      check test "$?" -eq 0
      recovery_round=2
      recovery_target="$LOG_BASE/rounds/round-2"
      calls_before="$(wc -l < "$LOG_BASE/meta-calls")"
      lenses_before="$(wc -l < "$LOG_BASE/lens-calls")"
      init_parallel "$LOG_BASE/.semaphore" 1
      check test "$?" -eq 0
      repairs_after_signal=0 recovery_armed=true
      run_rounds 3 LENSES
      recovery_rc=$?
      check test "$recovery_rc" -ne 0
      check test "$REPOLENS_FINAL_STATE" = interrupted
      if [[ "$recovery_signal" == INT ]]; then recovery_exit=130; else recovery_exit=143; fi
      check test "$REPOLENS_INTERRUPT_EXIT_CODE" -eq "$recovery_exit"
      check test "$repairs_after_signal" -eq 0
      check test "$(wc -l < "$LOG_BASE/meta-calls")" -eq "$calls_before"
      check test "$(wc -l < "$LOG_BASE/lens-calls")" -eq "$lenses_before"
      check test "$completed_lenses_file" = "$LOG_BASE/.completed"
    done
  done
  # Final rounds have no meta proof, but their repaired barrier can be interrupted.
  reset_case "recover-final-$recovery_signal"
  recovery_armed=false recovery_output=normal
  run_rounds 3 LENSES
  check test "$?" -eq 0
  recovery_round=3 recovery_moment=repair repairs_after_signal=0
  init_parallel "$LOG_BASE/.semaphore" 1
  recovery_armed=true
  run_rounds 3 LENSES
  check test "$?" -ne 0
  check test "$REPOLENS_FINAL_STATE" = interrupted
  check test "$repairs_after_signal" -eq 0
done
trap - INT TERM
printf 'Results: %s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
