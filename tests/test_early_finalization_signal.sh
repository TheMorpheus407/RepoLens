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
# shellcheck source=/dev/null
source "$REPO/lib/forge.sh"
# shellcheck source=/dev/null
source "$REPO/lib/filing.sh"
# shellcheck source=/dev/null
source "$REPO/lib/local-dedupe.sh"
eval "$(sed -n '/^rate_limit_sleep_interrupt_marker() {/,/^_handle_hangup() {/p' "$REPO/repolens.sh" | sed '$d')"
eval "$(sed -n '/^_handle_hangup() {/,/^trap _handle_termination TERM/p' "$REPO/repolens.sh")"
log_info() { :; }
log_warn() { :; }
print_resume_hint() { :; }
interrupt_once() {
  if [[ "$SIGNAL" != NONE && ! -e "$LOG_BASE/signalled" ]]; then
    : > "$LOG_BASE/signalled"
    kill -s "$SIGNAL" "$SIGNAL_PARENT_PID"
  fi
}
# Real receipt traversal/readback validation; only the network is stubbed.
forge_issue_read_json() {
  printf '%s\n' "$2" >> "$LOG_BASE/reads"
  interrupt_once
  [[ "$hook" != *failure ]] || return 1
  local title=saved
  [[ "$hook" != reopen* ]] || title="[reopen-candidate] consider re-opening #$2"
  command jq -cn --argjson n "$2" \
    --arg title "$title" '{number:$n,url:("https://github.com/acme/probe/issues/"+($n|tostring)),title:$title,body:"body",state:"open",labels:[]}'
}
# Keep the grouping deterministic to exercise the real in-place marking loop.
build_findings_jsonl_from_local() {
  command jq -cn --arg dir "$1" 'range(0;3) | {markdown_path:($dir+"/"+(.|tostring)+".md"),lens:"probe",domain:"test"}' > "$2"
}
_synthesize_compute_duplicate_groups() {
  printf '{"canonical_idx":0,"member_indices":[0,1,2]}\n'
}
eval "$(declare -f _local_dedupe_mark_file | sed '1s/_local_dedupe_mark_file/original_mark_file/')"
_local_dedupe_mark_file() {
  printf '%s\n' "$1" >> "$LOG_BASE/marks"
  original_mark_file "$@" || return $?
  interrupt_once
}
# Optional artifacts must stop being admitted once cancellation is observed.
build_finding_registry() { printf 'registry\n' >> "$LOG_BASE/optional"; }
branch_scope_filter_directory() { printf 'scope\n' >> "$LOG_BASE/optional"; }
render_human_review_digest() { printf 'digest\n' >> "$LOG_BASE/optional"; }
human_review_heldback_summary() { printf 'heldback\n' >> "$LOG_BASE/optional"; }
generate_todo_md() { printf 'todo\n' >> "$LOG_BASE/optional"; interrupt_once; }
generate_summary_md() { printf 'summary\n' >> "$LOG_BASE/optional"; }
generate_needs_review_md() { printf 'review\n' >> "$LOG_BASE/optional"; }
generate_duplicates_md() { printf 'duplicates\n' >> "$LOG_BASE/optional"; }
jq() {
  command jq "$@" || return $?
  if [[ "$hook" == health && "$*" == *'.health = $h'* ]]; then interrupt_once; fi
}
failed=0 cases=0
check() {
  if ! "$@" >/dev/null 2>&1; then
    printf 'FAIL: %s/%s/prior-%s: %s\n' "$hook" "$SIGNAL" "$prior" "$*"
    failed=$((failed + 1))
  fi
}
run_finalization() (
  SIGNAL_PARENT_PID="$BASHPID"
  trap _handle_hangup HUP
  trap _handle_interrupt INT
  trap _handle_termination TERM
  REPOLENS_FINAL_STATE=finished REPOLENS_INTERRUPT_EXIT_CODE=130 RUN_ROUNDS_RC=0
  RUN_ID=20261015T000000Z-probe MODE=audit AGENT=mock PARALLEL=false
  SCRIPT_DIR="${LOG_BASE%/logs/*}" LOCAL_MODE=false HUMAN_REVIEW=false
  FORGE_PROVIDER=gh FORGE_HOST=github.com FORGE_REPO=acme/probe
  OUTPUT_DIR="$LOG_BASE/output"
  [[ "$hook" != dedupe ]] || LOCAL_MODE=true
  MAX_ISSUES=1 REPOLENS_DEGENERATE_THRESHOLD=90 CURSOR_IDE_ACTIVE=true
  REPOLENS_CURSOR_IDE_CTL_LOG="$LOG_BASE/control.ndjson"
  # Execute the entire production finalization, including early writers.
  # shellcheck source=/dev/null
  source <(sed -n '/^# --- Finalize ---/,$p' "$REPO/repolens.sh")
)
for hook in health filing filing-failure reopen reopen-failure dedupe triage; do
for prior in 0 1; do
  for SIGNAL in HUP INT TERM NONE; do
    LOG_BASE="$FIXTURE/$hook-$SIGNAL-$prior/logs/20261015T000000Z-probe"
    SUMMARY_FILE="$LOG_BASE/summary.json"
    mkdir -p "$LOG_BASE"
    init_summary "$SUMMARY_FILE" probe "$FIXTURE" audit mock
    : > "$LOG_BASE/reads"
    : > "$LOG_BASE/marks"
    : > "$LOG_BASE/optional"
    case "$hook" in
      filing*)
        mkdir -p "$LOG_BASE/final/filed"
        printf '[]\n' > "$LOG_BASE/final/manifest.json"
        # A completed snapshot must survive cancellation halfway through a recount.
        reconcile_summary_filing "$SUMMARY_FILE" 7 10
        for n in 1 2 3; do
          printf 'https://github.com/acme/probe/issues/%s\n' "$n" > "$LOG_BASE/final/filed/$n.url"
          printf '{"title":"saved","body":"body","proposed_labels":[]}\n' > "$LOG_BASE/final/filed/$n.request.json"
        done ;;
      reopen*)
        mkdir -p "$LOG_BASE/final/filed/cross-link"
        printf '[]\n' > "$LOG_BASE/final/manifest.json"
        reconcile_summary_filing "$SUMMARY_FILE" 7 10
        for n in 1 2 3; do
          prefix="$LOG_BASE/final/filed/cross-link/reopen-suggestion-$n"
          : > "$prefix.done"
          printf 'https://github.com/acme/probe/issues/%s\n' "$n" > "$prefix.created-response"
          printf body > "$prefix.body.banner.md"
        done ;;
      dedupe)
        mkdir -p "$LOG_BASE/output"
        for n in 0 1 2; do printf '%s\n' '---' 'title: saved' '---' 'body' > "$LOG_BASE/output/$n.md"; done ;;
      triage)
        mkdir -p "$LOG_BASE/final"
        printf '{}\n' > "$LOG_BASE/final/findings.jsonl" ;;
    esac
    if [[ "$prior" == 1 ]]; then
      printf '[{"attempt_id":1,"status":"finished","exit_code":0}]\n' > "$LOG_BASE/attempts.json"
      printf '{"status":"stale"}\n' > "${LOG_BASE%/*}/latest-result.json"
    fi
    attempts_begin "$LOG_BASE"
    rc=0
    run_finalization > "$LOG_BASE/output.log" 2>&1 || rc=$?
    cases=$((cases + 1))
    expected_exit=0 expected_state=finished-empty expected_reason=""
    case "$SIGNAL" in
      HUP) expected_exit=129; expected_state=interrupted; expected_reason=interrupted-sighup ;;
      INT) expected_exit=130; expected_state=interrupted; expected_reason=interrupted-sigint ;;
      TERM) expected_exit=143; expected_state=interrupted; expected_reason=interrupted-sigterm ;;
    esac
    if [[ "$hook" == *failure && "$SIGNAL" == NONE ]]; then
      expected_exit=1 expected_state=failed expected_reason=filing-accounting-failed
    elif [[ "$hook" == filing || "$hook" == reopen ]] && [[ "$SIGNAL" == NONE ]]; then
      expected_state=finished
    fi
    check test "$rc" -eq "$expected_exit"
    check command jq -e --argjson count "$((prior + 1))" --arg status "$expected_state" \
      --argjson code "$expected_exit" --arg why "$expected_reason" \
      'length == $count and last.status == $status and last.exit_code == $code and last.why_stopped == $why' "$LOG_BASE/attempts.json"
    check command jq -e --arg status "$expected_state" '.status == $status' "${LOG_BASE%/*}/latest-result.json"
    check command jq -se --arg status "$expected_state" 'length == 1 and .[0].outcome == $status' "$LOG_BASE/control.ndjson"
    check test ! -e "$LOG_BASE/.attempt-start"
    if [[ "$SIGNAL" != NONE ]]; then
      check test -e "$LOG_BASE/signalled"
      case "$hook" in
        filing*)
          check test "$(wc -l < "$LOG_BASE/reads")" -eq 1
          check command jq -e '.totals.governed_issues_created == 7 and .totals.issues_created == 7' "$SUMMARY_FILE"
          check test -f "$LOG_BASE/final/filed/1.url"
          check test ! -e "$LOG_BASE/final/filed/1.failed"
          check test ! -e "$LOG_BASE/final/filed/1.readback.json"
          check test ! -s "$LOG_BASE/optional" ;;
        reopen*)
          check test "$(wc -l < "$LOG_BASE/reads")" -eq 1
          check command jq -e '.totals.governed_issues_created == 7 and .totals.issues_created == 7' "$SUMMARY_FILE"
          check test -f "$LOG_BASE/final/filed/cross-link/reopen-suggestion-1.done"
          check test ! -e "$LOG_BASE/final/filed/cross-link/reopen-suggestion-1.failed"
          check test ! -e "$LOG_BASE/final/filed/cross-link/reopen-suggestion-1.readback.json"
          check test ! -s "$LOG_BASE/optional" ;;
        dedupe)
          check test "$(wc -l < "$LOG_BASE/marks")" -eq 1
          check test ! -s "$LOG_BASE/optional"
          check test ! -e "$LOG_BASE/output/2.md.rldedupe.$$"
          check test "$(cat "$LOG_BASE/output/2.md")" = $'---\ntitle: saved\n---\nbody' ;;
        triage) check test "$(cat "$LOG_BASE/optional")" = todo ;;
      esac
    else
      case "$hook" in
        filing|reopen) check command jq -e '.totals.governed_issues_created == 3' "$SUMMARY_FILE" ;;
        dedupe) check test "$(wc -l < "$LOG_BASE/marks")" -eq 3 ;;
        triage) check test "$(wc -l < "$LOG_BASE/optional")" -eq 4 ;;
      esac
    fi
    if [[ "$prior" == 1 ]]; then
      check command jq -e '.[0] == {attempt_id:1,status:"finished",exit_code:0}' "$LOG_BASE/attempts.json"
    fi
    printf '%s/%s/prior-%s: exit=%s expected=%s\n' "$hook" "$SIGNAL" "$prior" "$rc" "$expected_exit"
    if [[ "$SIGNAL" != NONE && "$hook" != *failure ]]; then
      saved_signal="$SIGNAL"
      SIGNAL=NONE
      attempts_begin "$LOG_BASE"
      resume_rc=0
      run_finalization > "$LOG_BASE/resume.log" 2>&1 || resume_rc=$?
      check test "$resume_rc" -eq 0
      check command jq -e --argjson count "$((prior + 2))" \
        'length == $count and .[-2].status == "interrupted" and (last.status | startswith("finished")) and last.exit_code == 0' "$LOG_BASE/attempts.json"
      check command jq -se 'length == 2 and .[0].outcome == "interrupted" and (.[1].outcome | startswith("finished"))' "$LOG_BASE/control.ndjson"
      case "$hook" in
        filing|reopen) check command jq -e '.totals.governed_issues_created == 3' "$SUMMARY_FILE" ;;
        dedupe) check test "$(wc -l < "$LOG_BASE/marks")" -eq 4 ;;
        triage) check test "$(wc -l < "$LOG_BASE/optional")" -eq 5 ;;
      esac
      SIGNAL="$saved_signal"
    fi
  done
done
done
trap - HUP INT TERM
printf 'Early finalization: %s cases, %s failures.\n' "$cases" "$failed"
(( failed == 0 ))
