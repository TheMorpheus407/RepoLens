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

# repolens-r4-p2-2: cancelled reconciliation retains receipts and stops reads.
# shellcheck disable=SC2034,SC2329 # Production functions consume fixture globals.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
log_info() { :; }
log_warn() { :; }
case_receipt_cancellation() (
  source "$REPO/lib/parallel.sh"
  source "$REPO/lib/filing.sh"
  receipt_read_result="$1"
  receipt_signal="$2"
  receipt_boundary="$3"
  receipt_handlers="$4"
  LOG_BASE="$FIXTURE/receipt-cancel-$receipt_read_result-$receipt_signal-$receipt_boundary-$receipt_handlers"
  PROJECT_PATH="$LOG_BASE/project"
  RUN_ID=probe MODE=branch-review PARALLEL=false CROSS_LINK_MODE=off FORGE_REPO=acme/probe
  REPOLENS_FINAL_STATE=finished
  BRANCH_SCOPE_FILE="$LOG_BASE/branch-scope.json"
  mkdir -p "$LOG_BASE/final/filed" "$PROJECT_PATH/src"
  printf 'approved source\n' > "$PROJECT_PATH/src/probe.sh"
  printf '["src/probe.sh"]\n' > "$BRANCH_SCOPE_FILE"
  jq -n '[range(0;3) | {cluster_id:("c"+tostring),title:("Finding "+tostring),body:"src/probe.sh:1",proposed_labels:[],dedup_against_existing:[]}]' \
    > "$LOG_BASE/final/manifest.json"
  for n in 1 2; do
    jq --arg cid "c$n" '.[] | select(.cluster_id == $cid)' "$LOG_BASE/final/manifest.json" > "$LOG_BASE/final/filed/c$n.request.json"
    printf 'https://github.com/acme/probe/issues/%s\n' "$n" > "$LOG_BASE/final/filed/c$n.url"
  done
  parallel_preflight() { _REPOLENS_SCOPE_READY=1; }
  if [[ "$receipt_handlers" == production ]]; then
    # Use the default sequential CLI handlers; do not initialize parallel mode.
    eval "$(sed -n '/^_handle_hangup() {/,/^trap _handle_termination TERM/p' "$REPO/repolens.sh")"
    print_resume_hint() { :; }
  else
    init_parallel "$LOG_BASE/.semaphore" 1
  fi
  parent_pid="$BASHPID"
  cancel_at_boundary() {
    [[ "$receipt_boundary" == "$1" ]] || return 0
    kill -s "$receipt_signal" "$parent_pid"
    [[ "$receipt_read_result" != failure ]]
  }
  # Keep the real jq/validators except at the precise cancellation boundary.
  jq() {
    if [[ "$*" == *'select(length == 1)'* ]]; then
      cancel_at_boundary manifest || return 1
    fi
    command jq "$@"
  }
  eval "$(declare -f filing_verify_cluster_citations | sed '1s/filing_verify_cluster_citations/original_citations/')"
  filing_verify_cluster_citations() {
    cancel_at_boundary citation || return 1
    original_citations "$@"
  }
  eval "$(declare -f branch_scope_verify_body | sed '1s/branch_scope_verify_body/original_scope/')"
  branch_scope_verify_body() {
    cancel_at_boundary branch || return 1
    original_scope "$@"
  }
  forge_filing_capable() { cancel_at_boundary capability; }
  forge_issue_number_from_url() { printf '%s\n' "${2##*/}"; }
  forge_issue_read_json() {
    printf '%s\n' "$2" >> "$LOG_BASE/reads"
    if [[ "$2" == 1 ]]; then cancel_at_boundary read || return 1; fi
    jq -cn --argjson n "$2" '{url:("https://github.com/acme/probe/issues/"+($n|tostring)),number:$n,title:("Finding "+($n|tostring)),body:"src/probe.sh:1",labels:[],state:"open"}'
  }
  : > "$LOG_BASE/reads"
  dispatch_rc=0
  dispatch_filing_batch probe || dispatch_rc=$?
  printf 'RECEIPT_CANCEL boundary=%s handlers=%s signal=%s result=%s rc=%s state=%s remote_reads=%s first_receipt_quarantined=%s\n' \
    "$receipt_boundary" "$receipt_handlers" "$receipt_signal" "$receipt_read_result" "$dispatch_rc" "$REPOLENS_FINAL_STATE" "$(tr '\n' ',' < "$LOG_BASE/reads")" \
    "$(test -e "$LOG_BASE/final/filed/c1.unverified-url" && echo yes || echo no)"
  test "$REPOLENS_FINAL_STATE" = interrupted
  test "$dispatch_rc" -eq 1
  case "$receipt_signal" in
    HUP) test "$REPOLENS_INTERRUPT_EXIT_CODE" -eq 129 ;;
    INT) test "$REPOLENS_INTERRUPT_EXIT_CODE" -eq 130 ;;
    TERM) test "$REPOLENS_INTERRUPT_EXIT_CODE" -eq 143 ;;
  esac
  test "${_REPOLENS_FILING_RECONCILING:-0}" -eq 0
  expected_reads=0
  [[ "$receipt_boundary" != read ]] || expected_reads=1
  test "$(wc -l < "$LOG_BASE/reads")" -eq "$expected_reads"
  test -e "$LOG_BASE/final/filed/c1.url"
  test -e "$LOG_BASE/final/filed/c2.url"
  test ! -e "$LOG_BASE/final/filed/c1.failed"
  test ! -e "$LOG_BASE/final/filed/c1.attempted"
  test ! -e "$LOG_BASE/final/filed/c1.unverified-url"
  test ! -e "$LOG_BASE/final/filed/c1.governor"
  test ! -e "$LOG_BASE/final/filed/c2.governor"
  test ! -e "$LOG_BASE/final/filed/c0.lock"
  test ! -e "$LOG_BASE/final/filed/c2.failed"
  test ! -e "$LOG_BASE/final/filed/c2.attempted"
  test ! -e "$LOG_BASE/final/filed/c2.unverified-url"
  # A normal resume must reattest both receipts without quarantining either.
  REPOLENS_FINAL_STATE=finished receipt_boundary=none
  _filing_real_agent probe c1
  _filing_real_agent probe c2
  test -e "$LOG_BASE/final/filed/c1.url"
  test -e "$LOG_BASE/final/filed/c2.url"
  test ! -e "$LOG_BASE/final/filed/c1.governor"
  test ! -e "$LOG_BASE/final/filed/c2.governor"

)

for boundary in ${1:-read manifest citation branch capability}; do
  for handlers in parallel production; do
    for signal in TERM INT HUP; do
      # init_parallel owns INT/TERM; HUP uses the default production handler.
      [[ "$handlers" != parallel || "$signal" != HUP ]] || continue
      for result in success failure; do
        case_receipt_cancellation "$result" "$signal" "$boundary" "$handlers"
      done
    done
  done
done
printf 'All receipt cancellation regressions passed (%s).\n' "${1:-all five boundaries}"
