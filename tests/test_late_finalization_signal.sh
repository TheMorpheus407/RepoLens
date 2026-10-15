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
eval "$(sed -n '/^resolve_run_exit_code() {/,/^_handle_hangup() {/p' "$REPO/repolens.sh" | sed '$d')"
sed -n '/^# Resolve the process exit code/,$p' "$REPO/repolens.sh" > "$FIXTURE/tail.sh"
test -s "$FIXTURE/tail.sh"
parallel_preflight() { _REPOLENS_SCOPE_READY=1; _REPOLENS_SCOPE_FAILED=0; }
log_info() { :; }
log_warn() { :; }
interrupt_once() {
  if [[ ! -e "$LOG_BASE/signalled" ]]; then
    : > "$LOG_BASE/signalled"
    kill -s "$SIGNAL" "$SIGNAL_PARENT_PID"
  fi
}
summary_time_breakdown() { if [[ "$hook" == time ]]; then interrupt_once; fi; }
print_resume_hint() { printf 'resume hint\n'; }
write_latest_result_pointer() { printf '%s\n' "$6" > "$LOG_BASE/pointer-state"; }
cursor_ide_emit_run_complete() { printf '%s\n' "$2" > "$LOG_BASE/cursor-state"; }
jq() {
  case "$hook:$*" in
    filtered:*findings_filtered*) interrupt_once ;;
    summary:'. '*) interrupt_once ;;
    history:*'if type == "array" then length'*) interrupt_once ;;
  esac
  command jq "$@"
}
for SIGNAL in INT TERM; do
  expected_signal=130
  if [[ "$SIGNAL" == TERM ]]; then expected_signal=143; fi
  for prior in 0 1; do
    for hook in filtered time summary history clean; do
      if [[ "$hook" == history && "$prior" == 0 ]]; then continue; fi
      LOG_BASE="$FIXTURE/$SIGNAL-$prior-$hook"
      SUMMARY_FILE="$LOG_BASE/summary.json"
      mkdir -p "$LOG_BASE"
      printf '{"health":"ok"}\n' > "$SUMMARY_FILE"
      if [[ "$prior" == 1 ]]; then
        printf '[{"attempt_id":1,"status":"finished","exit_code":0}]\n' > "$LOG_BASE/attempts.json"
      fi
      rc=0
      (
        trap - EXIT
        SIGNAL_PARENT_PID="$BASHPID"
        RUN_ID=probe MODE=audit AGENT=mock LOCAL_MODE=false SCRIPT_DIR="$REPO"
        CURSOR_IDE_ACTIVE=true RUN_ROUNDS_RC=0 RUN_HEALTH=ok
        REPOLENS_FINAL_STATE=finished REPOLENS_INTERRUPT_EXIT_CODE=130
        init_parallel "$LOG_BASE/.semaphore" 1
        attempts_begin "$LOG_BASE"
        # shellcheck source=/dev/null
        source "$FIXTURE/tail.sh"
      ) > "$LOG_BASE/output" 2>&1 || rc=$?
      expected_exit="$expected_signal" expected_state=interrupted
      if [[ "$hook" == clean ]]; then expected_exit=0; expected_state=finished; fi
      printf '%s/%s/%s: exit=%s expected=%s\n' "$SIGNAL" "$prior" "$hook" "$rc" "$expected_exit"
      test "$rc" -eq "$expected_exit"
      command jq -e --arg state "$expected_state" --argjson code "$expected_exit" --argjson count "$((prior + 1))" \
        'length == $count and last.status == $state and last.exit_code == $code' "$LOG_BASE/attempts.json" >/dev/null
      if [[ "$prior" == 1 ]]; then
        command jq -e '.[0] == {attempt_id:1,status:"finished",exit_code:0}' "$LOG_BASE/attempts.json" >/dev/null
      fi
      test "$(cat "$LOG_BASE/pointer-state")" = "$expected_state"
      test "$(cat "$LOG_BASE/cursor-state")" = "$expected_state"
      if [[ "$hook" != clean ]]; then
        grep -q 'resume hint' "$LOG_BASE/output"
        command jq -e 'last.why_stopped | startswith("interrupted-sig")' "$LOG_BASE/attempts.json" >/dev/null
      fi
    done
  done
done
printf 'PASS: late INT/TERM finalization matches exit, attempts and projections.\n'
