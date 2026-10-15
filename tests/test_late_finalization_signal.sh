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

# repolens-r2-p1-4: a signal during final presentation must reach the exit,
# attempt ledger, result pointer and Cursor completion with one consistent state.
# shellcheck disable=SC2034,SC2329 # Extracted production code consumes globals.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
# shellcheck source=/dev/null
source "$REPO/lib/parallel.sh"
# shellcheck source=/dev/null
source "$REPO/lib/attempts.sh"
# shellcheck source=/dev/null
source "$REPO/lib/summary.sh"
# Exercise the real interruption resolvers and main signal handlers.
eval "$(sed -n '/^rate_limit_sleep_interrupt_marker() {/,/^_handle_hangup() {/p' "$REPO/repolens.sh" | sed '$d')"
eval "$(sed -n '/^_handle_hangup() {/,/^trap _handle_termination TERM/p' "$REPO/repolens.sh")"
# shellcheck source=/dev/null
source "$REPO/lib/clean.sh"
# shellcheck source=/dev/null
source "$REPO/lib/result_pointer.sh"
# shellcheck source=/dev/null
source "$REPO/lib/cursor_ide.sh"
sed -n '/^# Resolve the process exit code/,$p' "$REPO/repolens.sh" > "$FIXTURE/tail.sh"
test -s "$FIXTURE/tail.sh"
parallel_preflight() { _REPOLENS_SCOPE_READY=1; _REPOLENS_SCOPE_FAILED=0; }
log_info() { :; }
log_warn() { :; }
# Send to the parent even from a jq command substitution or pipeline.
interrupt_once() {
  if [[ ! -e "$LOG_BASE/signalled" ]]; then
    : > "$LOG_BASE/signalled"
    kill -s "$SIGNAL" "$SIGNAL_PARENT_PID"
  fi
}
summary_time_breakdown() { if [[ "$hook" == time ]]; then interrupt_once; fi; }
print_resume_hint() { printf 'resume hint\n'; }
# Inject inside the real serializers, after their arguments have been captured.
jq() {
  case "$hook:$*" in
    filtered:*findings_filtered*) interrupt_once ;;
    summary:'. '*) interrupt_once ;;
    signal-cycle:'. '*) interrupt_once ;;
    signal-cycle:*'.started_at //'* )
      if [[ -e "$LOG_BASE/cycle-middle" && ! -e "$LOG_BASE/cycle-end" ]]; then
        : > "$LOG_BASE/cycle-end"
        kill -s "$SIGNAL" "$SIGNAL_PARENT_PID"
      fi
      ;;
    history:*'if type == "array" then length else'*) interrupt_once ;;
    pointer:*'.started_at //'* ) interrupt_once ;;
    cursor:*'--arg kind run_complete'* ) interrupt_once ;;
    attempt:*'--argjson attempt_id'* ) interrupt_once ;;
    reconcile:*'--arg kind run_complete'*)
      if [[ ! -e "$LOG_BASE/signalled" ]]; then
        : > "$LOG_BASE/signalled"
        first_signal=INT
        if [[ "$SIGNAL" == INT ]]; then first_signal=TERM; fi
        kill -s "$first_signal" "$SIGNAL_PARENT_PID"
      fi
      ;;
    reconcile:*'.started_at //'* )
      if [[ -e "$LOG_BASE/signalled" && ! -e "$LOG_BASE/second-signal" ]]; then
        : > "$LOG_BASE/second-signal"
        kill -s "$SIGNAL" "$SIGNAL_PARENT_PID"
      fi
      ;;
    count-failure:'length + 1'*) return 1 ;;
    write-failure:*'--argjson attempt_id'* ) return 1 ;;
  esac
  command jq "$@"
}
# Start interrupted, change the signal after the loop snapshot, then restore it
# during pointer serialization. Equal signal codes must not hide a stale reason.
eval "$(declare -f resolve_run_exit_code | sed '1s/resolve_run_exit_code/original_resolve_run_exit_code/')"
resolve_run_exit_code() {
  if [[ "$hook" == signal-cycle && ! -e "$LOG_BASE/cycle-middle" ]]; then
    : > "$LOG_BASE/cycle-middle"
    middle_signal=TERM
    if [[ "$SIGNAL" == TERM ]]; then middle_signal=INT; fi
    kill -s "$middle_signal" "$SIGNAL_PARENT_PID"
  fi
  original_resolve_run_exit_code
}
# Exercise interruption after an append has reached disk, too.
mv() {
  command mv "$@" || return
  if [[ "$hook" == attempt-move && "${*: -1}" == "$LOG_BASE/attempts.json" ]]; then
    interrupt_once
  fi
}
# Probe the final check-to-freeze race without changing production logic.
trap() {
  if [[ "${hook:-}" == before-freeze && "$*" == ' HUP INT TERM' ]]; then interrupt_once; fi
  # shellcheck disable=SC2064 # Forward the already-quoted trap arguments unchanged.
  builtin trap "$@"
}
eval "$(declare -f cursor_ide_emit | sed '1s/cursor_ide_emit/original_cursor_ide_emit/')"
cursor_ide_emit() {
  if [[ "$hook" == terminal ]]; then interrupt_once; fi
  original_cursor_ide_emit "$@"
}
eval "$(sed -n '/^_cleanup_all() {/,/^trap _cleanup_all EXIT/p' "$REPO/repolens.sh" | sed '$d')"
stop_status_updater() {
  if [[ "$hook" == cleanup ]]; then interrupt_once; fi
  printf '%s|%s\n' "$1" "${RUN_EXIT_CODE:-unresolved}" > "$LOG_BASE/cleanup-state"
}
_cleanup_remote_control_socket() { :; }
_cleanup_spec_resume_snapshot() { :; }
_cleanup_clone() { :; }
failed=0 cases=0
check() {
  if ! "$@" >/dev/null 2>&1; then
    printf 'FAIL %s/%s/%s: %s\n' "$SIGNAL" "$prior" "$hook" "$*" >&2
    failed=$((failed + 1))
  fi
}
for SIGNAL in INT TERM HUP; do
  expected_signal=130
  case "$SIGNAL" in TERM) expected_signal=143 ;; HUP) expected_signal=129 ;; esac
  for prior in 0 1; do
    for hook in filtered time summary history pointer cursor attempt attempt-move before-freeze reconcile signal-cycle terminal cleanup write-failure count-failure corrupt non-array clean; do
      if [[ "$hook" == history && "$prior" == 0 ]]; then continue; fi
      # Optional case selection makes each before/after failure reproducible.
      if [[ -n "${REPOLENS_LATE_TEST_HOOK:-}" && "$hook" != "$REPOLENS_LATE_TEST_HOOK" ]]; then continue; fi
      LOG_BASE="$FIXTURE/$SIGNAL-$prior-$hook/logs/20261015T000000Z-probe"
      SUMMARY_FILE="$LOG_BASE/summary.json"
      mkdir -p "$LOG_BASE"
      printf '{"health":"ok"}\n' > "$SUMMARY_FILE"
      if [[ "$prior" == 1 ]]; then
        printf '[{"attempt_id":1,"status":"finished","exit_code":0}]\n' > "$LOG_BASE/attempts.json"
      fi
      case "$hook" in
        corrupt) printf 'invalid history\n' > "$LOG_BASE/attempts.json" ;;
        non-array) printf '{"prior":"data"}\n' > "$LOG_BASE/attempts.json" ;;
      esac
      if [[ -f "$LOG_BASE/attempts.json" ]]; then cp "$LOG_BASE/attempts.json" "$LOG_BASE/history-before"; fi
      printf 'one\ntwo\n' > "$LOG_BASE/.completed"
      rc=0
      (
        trap _cleanup_all EXIT
        HOSTED=false
        SIGNAL_PARENT_PID="$BASHPID"
        RUN_ID=20261015T000000Z-probe MODE=audit AGENT=mock LOCAL_MODE=false
        SCRIPT_DIR="${LOG_BASE%/logs/*}"
        CURSOR_IDE_ACTIVE=true RUN_ROUNDS_RC=0 RUN_HEALTH=ok
        REPOLENS_CURSOR_IDE_CTL_LOG="$LOG_BASE/control.ndjson"
        REPOLENS_FINAL_STATE=finished REPOLENS_INTERRUPT_EXIT_CODE=130
        trap _handle_hangup HUP
        init_parallel "$LOG_BASE/.semaphore" 1
        attempts_begin "$LOG_BASE"
        cp "$LOG_BASE/.attempt-start" "$LOG_BASE/start-before"
        printf 'three\n' >> "$LOG_BASE/.completed"
        # shellcheck source=/dev/null
        source "$FIXTURE/tail.sh"
      ) > "$LOG_BASE/output" 2>&1 || rc=$?
      cases=$((cases + 1))
      expected_exit="$expected_signal" expected_state=interrupted
      case "$hook" in clean|write-failure|count-failure|corrupt|non-array|terminal|cleanup) expected_exit=0; expected_state=finished ;; esac
      printf '%s/%s/%s: exit=%s expected=%s\n' "$SIGNAL" "$prior" "$hook" "$rc" "$expected_exit"
      check test "$rc" -eq "$expected_exit"
      if [[ "$hook" == corrupt || "$hook" == non-array ]]; then
        check cmp "$LOG_BASE/history-before" "$LOG_BASE/attempts.json"
        check test -e "$LOG_BASE/.attempt-start"
        if grep -q 'This run took' "$LOG_BASE/output"; then check false; fi
      elif [[ "$hook" == write-failure || "$hook" == count-failure ]]; then
        if [[ "$prior" == 1 ]]; then
          check command jq -e 'length == 1' "$LOG_BASE/attempts.json"
        else
          check test ! -e "$LOG_BASE/attempts.json"
        fi
        # The history notice must never invent an unpersisted attempt.
        if grep -q 'This run took 2 attempts' "$LOG_BASE/output"; then
          check false
        fi
      else
        check command jq -e --arg state "$expected_state" --argjson code "$expected_exit" --argjson count "$((prior + 1))" \
          'length == $count and last.status == $state and last.exit_code == $code' "$LOG_BASE/attempts.json" >/dev/null
      fi
      if [[ "$hook" != write-failure && "$hook" != count-failure && "$hook" != corrupt && "$hook" != non-array ]]; then
        check command jq -e 'last.lenses_completed_this_attempt == 1 and last.lenses_completed_total == 3' "$LOG_BASE/attempts.json"
        expected_start="$(sed -n 's/^started_at=//p' "$LOG_BASE/start-before")"
        check command jq -e --arg start "$expected_start" 'last.started_at == $start' "$LOG_BASE/attempts.json"
        check test ! -e "$LOG_BASE/.attempt-start"
        if [[ "$prior" == 1 ]]; then
          check grep -q "This run took 2 attempts (latest: $expected_state)" "$LOG_BASE/output"
        fi
      fi
      check test "$(cat "$LOG_BASE/cleanup-state")" = "$expected_state|$expected_exit"
      if [[ "$prior" == 1 && "$hook" != corrupt && "$hook" != non-array ]]; then
        check command jq -e '.[0] == {attempt_id:1,status:"finished",exit_code:0}' "$LOG_BASE/attempts.json" >/dev/null
      fi
      check command jq -e --arg state "$expected_state" '.status == $state' "${LOG_BASE%/*}/latest-result.json" >/dev/null
      # Exactly one terminal notification; a stale success followed by a correction
      # can already have told Composer to stop, so it is not sufficient.
      check command jq -se --arg state "$expected_state" 'length == 1 and .[0].outcome == $state' "$LOG_BASE/control.ndjson" >/dev/null
      case "$hook" in
        clean|write-failure|count-failure|corrupt|non-array|terminal|cleanup) ;;
        *)
          check grep -q 'resume hint' "$LOG_BASE/output"
          check command jq -e 'last.why_stopped | startswith("interrupted-sig")' "$LOG_BASE/attempts.json" >/dev/null
          expected_reason="interrupted-sig${SIGNAL,,}"
          check command jq -e --arg reason "$expected_reason" 'last.why_stopped == $reason' "$LOG_BASE/attempts.json"
          check command jq -e --arg reason "$expected_reason" '.stopped_reason == $reason' "$SUMMARY_FILE"
          if [[ "$hook" == signal-cycle ]]; then check test -e "$LOG_BASE/cycle-end"; fi
          ;;
      esac
    done
  done
done
printf 'Late finalization: %s cases, %s failures.\n' "$cases" "$failed"
(( failed == 0 ))
