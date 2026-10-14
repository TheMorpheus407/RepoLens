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

# repolens-r1-p1-2: returning parallel traps must stop post-round filing and
# retain signal state when synthesis/filing returns success or failure.
# shellcheck disable=SC2034,SC2329 # Globals/callbacks consumed by extracted code.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)" || exit 1
trap 'rm -rf "$TEST_DIR"' EXIT
sed -n '/^# --- Synthesizer (post-rounds, post-verifier) ---/,/^# --- Finalize ---/p' \
  "$SCRIPT_DIR/repolens.sh" > "$TEST_DIR/post-round.sh"
test -s "$TEST_DIR/post-round.sh" || exit 1
sed -n '/^rate_limit_sleep_interrupt_marker() {/,/^_handle_hangup() {/p' \
  "$SCRIPT_DIR/repolens.sh" | sed '$d' > "$TEST_DIR/finalizers.sh"
# shellcheck source=/dev/null
source "$TEST_DIR/finalizers.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/summary.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/parallel.sh"
# The production trap and cleanup run with no workers. Only kernel admission is
# stubbed; no model, forge, subprocess worker, or real scope is launched.
# Admit an empty parallel fixture without requiring a process-scope backend.
parallel_preflight() { _REPOLENS_SCOPE_READY=1; _REPOLENS_SCOPE_FAILED=0; }
# Suppress informational output from the extracted production block.
log_info() { :; }
# Suppress expected warnings from the injected failure scenarios.
log_warn() { :; }
passed=0 failed=0
# Count an expected/actual equality and print the scenario on mismatch.
check_eq() {
  if [[ "$2" == "$3" ]]; then passed=$((passed + 1));
  else failed=$((failed + 1)); printf 'FAIL: %s expected [%s], got [%s]\n' "$1" "$2" "$3"; fi
}
FINALIZER_PID="$BASHPID"
# Deliver SIGNAL to the parent even when invoked by the filing subshell.
interrupt_parent() { kill -s "$SIGNAL" "$FINALIZER_PID"; }
# Record synthesis admission, then inject the selected signal/return outcome.
run_synthesizer() {
  printf 'called\n' >> "$LOG_BASE/synthesis-calls"
  case "$row" in
    synthesis-ok) interrupt_parent; return 0 ;;
    synthesis-fail) interrupt_parent; return 1 ;;
    synthesis-rate) interrupt_parent; return 3 ;;
    normal-synthesis-fail) return 1 ;;
  esac
  return 0
}
# Record filing admission and simulate its terminal receipt or deferral marker.
dispatch_filing_batch() {
  printf 'called\n' >> "$LOG_BASE/filing-calls"
  case "$row" in
    filing-ok|filing-fail|filing-incomplete|filing-deferred) interrupt_parent ;;
  esac
  case "$row" in
    filing-fail|normal-filing-fail) return 1 ;;
    filing-deferred) : > "$LOG_BASE/final/filed/c1.deferred" ;;
    filing-incomplete) : ;;
    *) : > "$LOG_BASE/final/filed/c1.url" ;;
  esac
  return 0
}
for SIGNAL in INT TERM; do
  signal_exit=130 signal_reason=interrupted-sigint
  if [[ "$SIGNAL" == TERM ]]; then signal_exit=143; signal_reason=interrupted-sigterm; fi
  for row in before-synthesis synthesis-ok synthesis-fail synthesis-rate filing-ok filing-fail filing-incomplete filing-deferred clean normal-synthesis-fail normal-filing-fail; do
    LOG_BASE="$TEST_DIR/$SIGNAL-$row"
    mkdir -p "$LOG_BASE/final/filed"
    SUMMARY_FILE="$LOG_BASE/summary.json"
    printf '{"stopped_reason":null}\n' > "$SUMMARY_FILE"
    printf '[{"cluster_id":"c1"}]\n' > "$LOG_BASE/final/manifest.json"
    RUN_ID=post-round-probe LOCAL_MODE=false MODE=branch-review ROUNDS=1
    RUN_HEALTH=ok REPOLENS_ALLOW_DEGENERATE=false
    REPOLENS_FINAL_STATE=finished REPOLENS_INTERRUPT_EXIT_CODE=130 RUN_ROUNDS_RC=0
    init_parallel "$LOG_BASE/.semaphore" 1 || exit 1
    expected_state=interrupted expected_exit="$signal_exit" expected_reason="$signal_reason"
    expected_synthesis=1 expected_filing=1
    case "$row" in
      before-synthesis) interrupt_parent; expected_synthesis=0; expected_filing=0 ;;
      synthesis-*) expected_filing=0 ;;
      clean) expected_state=finished; expected_exit=0; expected_reason="" ;;
      normal-synthesis-fail) expected_state=failed; expected_exit=1; expected_reason=synthesizer-failed; expected_filing=0 ;;
      normal-filing-fail) expected_state=failed; expected_exit=1; expected_reason=filing-failed ;;
    esac
    # shellcheck source=/dev/null
    source "$TEST_DIR/post-round.sh"
    apply_rate_limit_abort_final_state || true
    synthesis_calls=0 filing_calls=0
    if [[ -f "$LOG_BASE/synthesis-calls" ]]; then synthesis_calls="$(wc -l < "$LOG_BASE/synthesis-calls")"; fi
    if [[ -f "$LOG_BASE/filing-calls" ]]; then filing_calls="$(wc -l < "$LOG_BASE/filing-calls")"; fi
    check_eq "$SIGNAL/$row synthesis calls" "$expected_synthesis" "$synthesis_calls"
    check_eq "$SIGNAL/$row filing calls" "$expected_filing" "$filing_calls"
    check_eq "$SIGNAL/$row state" "$expected_state" "$REPOLENS_FINAL_STATE"
    check_eq "$SIGNAL/$row exit" "$expected_exit" "$(resolve_run_exit_code)"
    check_eq "$SIGNAL/$row reason" "$expected_reason" "$(resolve_why_stopped)"
    check_eq "$SIGNAL/$row summary" "$expected_reason" "$(jq -r '.stopped_reason // empty' "$SUMMARY_FILE")"
  done
done
trap - INT TERM
printf 'Results: %s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
