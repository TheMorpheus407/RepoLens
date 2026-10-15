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

# repolens-r3-p2-2: signals in early summary persistence must reach the ledger,
# latest-result pointer and the single Cursor terminal event.
# shellcheck disable=SC2034,SC2329 # Extracted production code consumes fixtures.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$(mktemp -d)" || exit 1
trap 'rm -rf -- "$FIXTURE"' EXIT
# shellcheck source=/dev/null
source "$REPO/lib/summary.sh"
# shellcheck source=/dev/null
source "$REPO/lib/attempts.sh"
# shellcheck source=/dev/null
source "$REPO/lib/result_pointer.sh"
# shellcheck source=/dev/null
source "$REPO/lib/cursor_ide.sh"
eval "$(sed -n '/^rate_limit_sleep_interrupt_marker() {/,/^_handle_hangup() {/p' "$REPO/repolens.sh" | sed '$d')"
eval "$(sed -n '/^_handle_hangup() {/,/^trap _handle_termination TERM/p' "$REPO/repolens.sh")"
log_info() { :; }
log_warn() { :; }
print_resume_hint() { :; }
jq() {
  command jq "$@" || return $?
  if [[ "$SIGNAL" != NONE && "$*" == *'.health = $h'* && ! -e "$LOG_BASE/signalled" ]]; then
    : > "$LOG_BASE/signalled"
    kill -s "$SIGNAL" "$SIGNAL_PARENT_PID"
  fi
}
failed=0 cases=0
check() {
  if ! "$@" >/dev/null 2>&1; then
    printf 'FAIL: %s/prior-%s: %s\n' "$SIGNAL" "$prior" "$*"
    failed=$((failed + 1))
  fi
}
for prior in 0 1; do
  for SIGNAL in HUP INT TERM NONE; do
    LOG_BASE="$FIXTURE/$SIGNAL-$prior/logs/20261015T000000Z-probe"
    SUMMARY_FILE="$LOG_BASE/summary.json"
    mkdir -p "$LOG_BASE"
    init_summary "$SUMMARY_FILE" probe "$FIXTURE" audit mock
    if [[ "$prior" == 1 ]]; then
      printf '[{"attempt_id":1,"status":"finished","exit_code":0}]\n' > "$LOG_BASE/attempts.json"
      printf '{"status":"stale"}\n' > "${LOG_BASE%/*}/latest-result.json"
    fi
    attempts_begin "$LOG_BASE"
    rc=0
    (
      SIGNAL_PARENT_PID="$BASHPID"
      trap _handle_hangup HUP
      trap _handle_interrupt INT
      trap _handle_termination TERM
      REPOLENS_FINAL_STATE=finished REPOLENS_INTERRUPT_EXIT_CODE=130 RUN_ROUNDS_RC=0
      RUN_ID=20261015T000000Z-probe MODE=audit AGENT=mock PARALLEL=false
      SCRIPT_DIR="${LOG_BASE%/logs/*}" LOCAL_MODE=false HUMAN_REVIEW=false
      MAX_ISSUES=1 REPOLENS_DEGENERATE_THRESHOLD=90 CURSOR_IDE_ACTIVE=true
      REPOLENS_CURSOR_IDE_CTL_LOG="$LOG_BASE/control.ndjson"
      # Execute the entire production finalization, including early writers.
      # shellcheck source=/dev/null
      source <(sed -n '/^# --- Finalize ---/,$p' "$REPO/repolens.sh")
    ) > "$LOG_BASE/output" 2>&1 || rc=$?
    cases=$((cases + 1))
    expected_exit=0 expected_state=finished-empty expected_reason=""
    case "$SIGNAL" in
      HUP) expected_exit=129; expected_state=interrupted; expected_reason=interrupted-sighup ;;
      INT) expected_exit=130; expected_state=interrupted; expected_reason=interrupted-sigint ;;
      TERM) expected_exit=143; expected_state=interrupted; expected_reason=interrupted-sigterm ;;
    esac
    check test "$rc" -eq "$expected_exit"
    check command jq -e --argjson count "$((prior + 1))" --arg status "$expected_state" \
      --argjson code "$expected_exit" --arg why "$expected_reason" \
      'length == $count and last.status == $status and last.exit_code == $code and last.why_stopped == $why' "$LOG_BASE/attempts.json"
    check command jq -e --arg status "$expected_state" '.status == $status' "${LOG_BASE%/*}/latest-result.json"
    check command jq -se --arg status "$expected_state" 'length == 1 and .[0].outcome == $status' "$LOG_BASE/control.ndjson"
    check test ! -e "$LOG_BASE/.attempt-start"
    if [[ "$prior" == 1 ]]; then
      check command jq -e '.[0] == {attempt_id:1,status:"finished",exit_code:0}' "$LOG_BASE/attempts.json"
    fi
    printf '%s/prior-%s: exit=%s expected=%s\n' "$SIGNAL" "$prior" "$rc" "$expected_exit"
  done
done
trap - HUP INT TERM
printf 'Early finalization: %s cases, %s failures.\n' "$cases" "$failed"
(( failed == 0 ))
