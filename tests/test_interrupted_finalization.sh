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

# Exercise production finalization before the exit/attempt resolvers (#428).
# Intended ordering table (each row below runs for HUP, INT and TERM):
# row                 events                                state / exit / reason
# clean               no abort                              finished / 0 / empty
# lens-rate           rate only                             rate-limit-pending / 3 / rate-limited
# phase-rate          phase rate only                       failed / 1 / rate-limited-meta
# prompt-rate         prompt failure + rate                 rate-limit-pending / 3 / prompt-render-failed
# sleep               child sleep signal only               interrupted / signal / signal reason
# signal-rate         parent signal -> rate                 interrupted / parent signal / parent reason
# rate-signal         rate -> parent signal                 interrupted / parent signal / parent reason
# during-marker       parent signal during marker read      interrupted / parent signal / parent reason
# during-summary      parent signal during summary read     interrupted / parent signal / parent reason
# during-summary-write parent signal during quota write    interrupted / parent signal / parent reason
# parent-child        earlier child -> parent signal        interrupted / parent signal / parent reason
# child-rate          child signal + rate                   interrupted / child signal / child reason
# repeated            signal -> finalize -> finalize        interrupted / parent signal / parent reason
# filing-signal       signal -> failed accounting           interrupted / parent signal / parent reason
# during-accounting   signal during failed accounting       interrupted / parent signal / parent reason
# filing-failure      accounting failure only               failed / 1 / filing-accounting-failed
# Each row also runs with writable and unavailable summary storage. Actual
# attempt publication is checked after finalization, not against resolvers alone.
# shellcheck disable=SC2034,SC2329 # Globals/callbacks consumed by extracted code.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
sed -n '/^rate_limit_sleep_interrupt_marker() {/,/^_handle_hangup() {/p' \
  "$SCRIPT_DIR/repolens.sh" | sed '$d' > "$TEST_DIR/finalizers.sh"
# shellcheck source=/dev/null
source "$TEST_DIR/finalizers.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/summary.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/attempts.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/status.sh"
eval "$(declare -f set_stop_reason | sed '1s/set_stop_reason/original_set_stop_reason/')"
eval "$(declare -f rate_limit_sleep_interrupt_marker | sed '1s/rate_limit_sleep_interrupt_marker/original_sleep_marker/')"
eval "$(declare -f rate_limit_abort_stopped_reason | sed '1s/rate_limit_abort_stopped_reason/original_abort_reason/')"
# The unconditional filing reconciliation in main runs even after failed rounds.
sed -n '/^if ! \$LOCAL_MODE && { \[\[ "\$MODE" == branch-review/,/^# Emit deduped forge-warning/p' \
  "$SCRIPT_DIR/repolens.sh" | sed '$d' > "$TEST_DIR/accounting.sh"
test -s "$TEST_DIR/accounting.sh"
passed=0 failed=0
check_eq() {
  if [[ "$2" == "$3" ]]; then passed=$((passed + 1));
  else failed=$((failed + 1)); printf 'FAIL %s: expected [%s], got [%s]\n' "$1" "$2" "$3"; fi
}
log_warn() { :; }
interrupt_parent() { kill -s "$SIGNAL" "$FINALIZER_PID"; }
rate_limit_sleep_interrupt_marker() {
  if [[ "$row" == during-marker ]]; then interrupt_parent; fi
  original_sleep_marker
}
rate_limit_abort_stopped_reason() {
  if [[ "$row" == during-summary ]]; then interrupt_parent; fi
  original_abort_reason
}
set_stop_reason() {
  if [[ "$row" == during-summary-write && "$2" == rate-limited ]]; then interrupt_parent; fi
  original_set_stop_reason "$@"
}
filing_verified_issue_count() { printf '0\n'; }
reconcile_summary_filing() {
  if [[ "$row" == during-accounting ]]; then interrupt_parent; fi
  return 1
}
FINALIZER_PID="$BASHPID"
LOCAL_MODE=false MODE=branch-review MAX_ISSUES="" RUN_ID=finalization-probe
for SIGNAL in HUP INT TERM; do
  signal_exit=130 signal_reason=interrupted-sigint
  case "$SIGNAL" in
    HUP) signal_exit=129; signal_reason=interrupted-sighup ;;
    TERM) signal_exit=143; signal_reason=interrupted-sigterm ;;
  esac
  # Model the production parallel trap's returning interruption, including HUP
  # state supplied by the sleep marker. No external process or model is launched.
  trap 'REPOLENS_FINAL_STATE=interrupted; REPOLENS_INTERRUPT_EXIT_CODE="$signal_exit"' HUP INT TERM
  for storage in writable unavailable; do
    for row in clean lens-rate phase-rate prompt-rate sleep signal-rate rate-signal during-marker during-summary during-summary-write parent-child child-rate repeated filing-signal during-accounting filing-failure; do
      label="$row/$SIGNAL/$storage"
      LOG_BASE="$TEST_DIR/$row-$SIGNAL-$storage"
      mkdir -p "$LOG_BASE"
      SUMMARY_FILE="$LOG_BASE/summary.json"
      initial_reason=""
      case "$row" in
        phase-rate) initial_reason=rate-limited-meta ;;
        prompt-rate) initial_reason=prompt-render-failed ;;
      esac
      if [[ "$storage" == writable ]]; then
        printf '{"stopped_reason":"%s"}\n' "$initial_reason" > "$SUMMARY_FILE"
      else
        mkdir "$SUMMARY_FILE"
      fi
      REPOLENS_FINAL_STATE=finished REPOLENS_INTERRUPT_EXIT_CODE=130
      ROUNDS_FAILURE_REASON="" RUN_ROUNDS_RC=0 RUN_HEALTH=ok
      REPOLENS_ALLOW_DEGENERATE=false
      expected_state=interrupted expected_exit="$signal_exit" expected_reason="$signal_reason"
      case "$row" in
        clean) expected_state=finished; expected_exit=0; expected_reason="" ;;
        lens-rate|prompt-rate|phase-rate)
          : > "$LOG_BASE/.rate-limit-abort"
          expected_state=rate-limit-pending expected_exit=3 expected_reason=rate-limited
          if [[ "$storage" == unavailable ]]; then expected_reason=rate-limit; fi
          if [[ "$row" == phase-rate && "$storage" == writable ]]; then
            expected_state=failed expected_exit=1 expected_reason=rate-limited-meta
          elif [[ "$row" == prompt-rate && "$storage" == writable ]]; then
            expected_reason=prompt-render-failed
          fi
          ;;
        sleep|child-rate|parent-child)
          child_exit="$signal_exit" child_reason="$signal_reason"
          if [[ "$row" == parent-child ]]; then
            child_exit=130 child_reason=interrupted-sigint
            if [[ "$SIGNAL" == INT ]]; then child_exit=143; child_reason=interrupted-sigterm; fi
          fi
          printf 'exit_code=%s\nstopped_reason=%s\n' "$child_exit" "$child_reason" > "$LOG_BASE/.rate-limit-sleep-interrupt"
          if [[ "$row" == child-rate ]]; then : > "$LOG_BASE/.rate-limit-abort"; fi
          if [[ "$row" == parent-child ]]; then interrupt_parent; fi
          ;;
        signal-rate)
          interrupt_parent
          : > "$LOG_BASE/.rate-limit-abort"
          ;;
        rate-signal|during-marker|during-summary|during-summary-write)
          : > "$LOG_BASE/.rate-limit-abort"
          if [[ "$row" == rate-signal ]]; then interrupt_parent; fi
          ;;
        repeated|filing-signal) interrupt_parent ;;
        filing-failure)
          expected_state=failed expected_exit=1 expected_reason=filing-accounting-failed
          if [[ "$storage" == unavailable ]]; then expected_reason=run-execution-failed; fi
          ;;
      esac
      if [[ "$row" == filing-* || "$row" == during-accounting ]]; then
        # Production shell handles errors explicitly; sourcing as a condition
        # prevents this test's errexit from changing that execution contract.
        # shellcheck source=/dev/null
        if source "$TEST_DIR/accounting.sh"; then :; fi
        apply_rate_limit_abort_final_state || true
      else
        apply_rate_limit_abort_final_state || true
        if [[ "$row" == repeated ]]; then apply_rate_limit_abort_final_state || true; fi
      fi
      check_eq "$label state" "$expected_state" "$REPOLENS_FINAL_STATE"
      check_eq "$label exit" "$expected_exit" "$(resolve_run_exit_code)"
      check_eq "$label reason" "$expected_reason" "$(resolve_why_stopped)"
      if [[ "$expected_state" == interrupted && "$storage" == writable ]]; then
        check_eq "$label summary reason" "$expected_reason" "$(jq -r .stopped_reason "$SUMMARY_FILE")"
      fi
      if [[ "$row" == parent-child || "$row" == rate-signal || "$row" == filing-signal ]]; then
        attempts_begin "$LOG_BASE"
        attempts_finalize "$LOG_BASE" "$REPOLENS_FINAL_STATE" "$(resolve_why_stopped)" "$(resolve_run_exit_code)"
        check_eq "$label persisted attempt" "interrupted|$signal_exit|$signal_reason" \
          "$(jq -r '.[-1] | [.status, (.exit_code|tostring), .why_stopped] | join("|")' "$LOG_BASE/attempts.json")"
        mkdir -p "$LOG_BASE/heartbeat"
        printf 'security/injection\n' > "$LOG_BASE/lenses.txt"
        write_status_snapshot "$REPOLENS_FINAL_STATE" "$RUN_ID" "$LOG_BASE" "$LOG_BASE/heartbeat" \
          "$LOG_BASE/.completed" "$SUMMARY_FILE" "$SCRIPT_DIR" '' "$MODE" codex false 1 "$LOG_BASE/lenses.txt"
        check_eq "$label terminal snapshot" interrupted "$(jq -r .state "$LOG_BASE/status.json")"
      fi
    done
  done
done
trap - HUP INT TERM
printf 'Results: %s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
