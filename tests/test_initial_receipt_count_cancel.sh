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


# repolens-r8-p2-4: startup count must observe the signal-receiving parent.
# shellcheck disable=SC2034,SC2329 # Production functions consume fixture globals.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
# shellcheck source=lib/core.sh
source "$REPO/lib/core.sh"
# shellcheck source=lib/summary.sh
source "$REPO/lib/summary.sh"
# shellcheck source=lib/filing.sh
source "$REPO/lib/filing.sh"
eval "$(sed -n '/^_handle_hangup() {/,/^trap _handle_termination TERM/p' "$REPO/repolens.sh")"
trap - HUP INT TERM
# Suppress the CLI resume hint during receipt-read cases; takes no arguments.
print_resume_hint() { :; }
# Execute the production startup counter in this shell using fixture globals.
# Takes no arguments; preserves the counter's status and signal-driven exit.
startup_count() {
  # Run the exact startup block, stopping before the status-updater startup.
  # shellcheck source=/dev/null
  source <(sed -n '/^# --- Global issue counter ---/,/^if \[\[ -n "$RESUME_RUN_ID" \]\]; then/p' "$REPO/repolens.sh" | sed '$d')
}
# Mock URL parsing: ignore the repository argument and print the URL's last part.
forge_issue_number_from_url() { printf '%s\n' "${2##*/}"; }
# Mock a read for repository $1 and issue number $2, logging it under LOG_BASE.
# For issue 1, optionally signal the parent and fail; otherwise print issue JSON.
forge_issue_read_json() {
  printf '%s\n' "$2" >> "$LOG_BASE/reads"
  if [[ "$2" == 1 && "$cancel_read" == true ]]; then
    kill -s "$signal" "$parent_pid"
    [[ "$outcome" != failure ]] || return 1
  fi
  jq -cn --argjson n "$2" '{url:("https://github.com/acme/probe/issues/"+($n|tostring)),number:$n,title:("Finding "+($n|tostring)),body:"src/probe.sh:1",labels:[],state:"open"}'
}
PASS=0 FAIL=0
# Run the supplied assertion command, update PASS/FAIL and print any failure.
# Return success so all assertions run before the suite checks FAIL.
check() {
  if "$@"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$*"; fi
}
for outcome in success failure; do
  for signal in HUP INT TERM; do
    LOG_BASE="$FIXTURE/$outcome-$signal" SUMMARY_FILE="$FIXTURE/$outcome-$signal/summary.json"
    RUN_ID=probe MODE=branch-review LOCAL_MODE=false FORGE_REPO=acme/probe MAX_ISSUES=10
    REPOLENS_FINAL_STATE=finished cancel_read=true
    mkdir -p "$LOG_BASE/final/filed"
    : > "$LOG_BASE/reads"
    init_summary "$SUMMARY_FILE" probe "$FIXTURE" branch-review mock '' 10 github ''
    increment_summary_issues_created "$SUMMARY_FILE" 2
    for n in 1 2; do
      jq -n --argjson n "$n" '{title:("Finding "+($n|tostring)),body:"src/probe.sh:1",proposed_labels:[]}' \
        > "$LOG_BASE/final/filed/c$n.request.json"
      printf 'https://github.com/acme/probe/issues/%s\n' "$n" > "$LOG_BASE/final/filed/c$n.url"
    done
    rc=0
    (
      parent_pid=$BASHPID
      trap '_handle_hangup' HUP
      trap '_handle_interrupt' INT
      trap '_handle_termination' TERM
      startup_count
    ) || rc=$?
    expected=143
    case "$signal" in HUP) expected=129 ;; INT) expected=130 ;; esac
    check test "$rc" -eq "$expected"
    check test "$(wc -l < "$LOG_BASE/reads")" -eq 1
    check test "$(jq .totals.issues_created "$SUMMARY_FILE")" -eq 2
    for n in 1 2; do
      check test -s "$LOG_BASE/final/filed/c$n.url"
      for suffix in unverified-url failed attempted; do
        check test ! -e "$LOG_BASE/final/filed/c$n.$suffix"
      done
    done
    check test "$(find "$LOG_BASE" -name '.initial-filing-count.*' | wc -l)" -eq 0
    cancel_read=false REPOLENS_FINAL_STATE=finished GLOBAL_ISSUES_CREATED=0
    : > "$LOG_BASE/reads"
    rc=0
    startup_count || rc=$?
    check test "$rc" -eq 0
    check test "$(wc -l < "$LOG_BASE/reads")" -eq 2
    check test "$(jq .totals.issues_created "$SUMMARY_FILE")" -eq 2
    check test "${_REPOLENS_FILING_RECONCILING:-0}" -eq 0
  done
done
# A signal after the last state check must still stop startup. DEBUG runs
# immediately before the real helper's final return, making the race repeatable.
for signal in HUP INT TERM; do
  LOG_BASE="$FIXTURE/late-$signal" SUMMARY_FILE="$FIXTURE/late-$signal/summary.json"
  RUN_ID=probe MODE=branch-review LOCAL_MODE=false FORGE_REPO=acme/probe MAX_ISSUES=10
  REPOLENS_FINAL_STATE=finished cancel_read=false
  mkdir -p "$LOG_BASE/final/filed"
  init_summary "$SUMMARY_FILE" probe "$FIXTURE" branch-review mock '' 10 github ''
  rc=0
  (
    parent_pid=$BASHPID
    trap '_handle_hangup' HUP
    trap '_handle_interrupt' INT
    trap '_handle_termination' TERM
    # Record a no-argument resume-hint call for the final-return boundary case.
    print_resume_hint() { : > "$LOG_BASE/resume-hint"; }
    set -T
    # shellcheck disable=SC2154 # Match the sourced helper's command literally.
    trap 'if [[ ${FUNCNAME[0]:-} == _reconcile_initial_filing_counts && $BASH_COMMAND == "return \"\$count_rc\"" ]]; then
      trap - DEBUG
      : > "$LOG_BASE/boundary-hit"
      kill -s "$signal" "$parent_pid"
    fi' DEBUG
    startup_count
    : > "$LOG_BASE/continued"
  ) || rc=$?
  expected=143
  case "$signal" in HUP) expected=129 ;; INT) expected=130 ;; esac
  check test -f "$LOG_BASE/boundary-hit"
  check test "$rc" -eq "$expected"
  check test ! -e "$LOG_BASE/continued"
  check test -f "$LOG_BASE/resume-hint"
  check test "$(jq .totals.issues_created "$SUMMARY_FILE")" -eq 0
  check test "$(find "$LOG_BASE" -name '.initial-filing-count.*' | wc -l)" -eq 0
done
printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
