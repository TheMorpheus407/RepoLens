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
  LOG_BASE="$FIXTURE/receipt-cancel-$receipt_read_result-$receipt_signal"
  PROJECT_PATH="$LOG_BASE/project"
  RUN_ID=probe MODE=audit PARALLEL=false CROSS_LINK_MODE=off FORGE_REPO=acme/probe
  REPOLENS_FINAL_STATE=finished
  mkdir -p "$LOG_BASE/final/filed" "$PROJECT_PATH/src"
  printf 'approved source\n' > "$PROJECT_PATH/src/probe.sh"
  jq -n '[range(0;3) | {cluster_id:("c"+tostring),title:("Finding "+tostring),body:"src/probe.sh:1",proposed_labels:[],dedup_against_existing:[]}]' \
    > "$LOG_BASE/final/manifest.json"
  for n in 1 2; do
    jq --arg cid "c$n" '.[] | select(.cluster_id == $cid)' "$LOG_BASE/final/manifest.json" > "$LOG_BASE/final/filed/c$n.request.json"
    printf 'https://github.com/acme/probe/issues/%s\n' "$n" > "$LOG_BASE/final/filed/c$n.url"
  done
  parallel_preflight() { _REPOLENS_SCOPE_READY=1; }
  init_parallel "$LOG_BASE/.semaphore" 1
  parent_pid="$BASHPID"
  forge_filing_capable() { return 0; }
  forge_issue_number_from_url() { printf '%s\n' "${2##*/}"; }
  forge_issue_read_json() {
    printf '%s\n' "$2" >> "$LOG_BASE/reads"
    if [[ "$2" == 1 ]]; then
      kill -s "$receipt_signal" "$parent_pid"
      [[ "$receipt_read_result" != failure ]] || return 1
    fi
    jq -cn --argjson n "$2" '{url:("https://github.com/acme/probe/issues/"+($n|tostring)),number:$n,title:("Finding "+($n|tostring)),body:"src/probe.sh:1",labels:[],state:"open"}'
  }
  dispatch_rc=0
  dispatch_filing_batch probe || dispatch_rc=$?
  printf 'RECEIPT_CANCEL first_read=%s rc=%s state=%s remote_reads=%s first_receipt_quarantined=%s\n' \
    "$receipt_read_result" "$dispatch_rc" "$REPOLENS_FINAL_STATE" "$(tr '\n' ',' < "$LOG_BASE/reads")" \
    "$(test -e "$LOG_BASE/final/filed/c1.unverified-url" && echo yes || echo no)"
  test "$REPOLENS_FINAL_STATE" = interrupted
  test "$dispatch_rc" -eq 1
  test "$(wc -l < "$LOG_BASE/reads")" -eq 1
  test -e "$LOG_BASE/final/filed/c1.url"
  test -e "$LOG_BASE/final/filed/c2.url"
  test ! -e "$LOG_BASE/final/filed/c1.failed"
  test ! -e "$LOG_BASE/final/filed/c1.attempted"
  test ! -e "$LOG_BASE/final/filed/c1.unverified-url"
  test ! -e "$LOG_BASE/final/filed/c1.governor"
  test ! -e "$LOG_BASE/final/filed/c2.governor"
  test ! -e "$LOG_BASE/final/filed/c0.lock"

)

for signal in TERM INT; do
  for result in success failure; do
    case_receipt_cancellation "$result" "$signal"
  done
done
printf 'All four receipt cancellation regressions passed.\n'
