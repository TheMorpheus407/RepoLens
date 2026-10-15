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

# Deterministic signal boundaries; external workers/forge writes are stubbed.
# shellcheck disable=SC2034,SC2329
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO/lib/parallel.sh"
source "$REPO/lib/filing.sh"
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
log_info() { :; }
log_warn() { :; }
parallel_preflight() { _REPOLENS_SCOPE_READY=1; }
PASS=0 FAIL=0
for scenario in poll-state poll-destroy final-wait sequential already-interrupted empty-manifest cross-link-read cross-link-next; do
  (
    LOG_BASE="$FIXTURE/$scenario"
    mkdir -p "$LOG_BASE/final/filed"
    printf '[{"cluster_id":"c1"},{"cluster_id":"c2"}]\n' > "$LOG_BASE/final/manifest.json"
    RUN_ID=probe PARALLEL=false CROSS_LINK_MODE=comment
    REPOLENS_FINAL_STATE=finished
    parent_pid="$BASHPID"
    init_parallel "$LOG_BASE/.semaphore" 1 || exit 1
    _scope_terminate_batch() { _REPOLENS_SCOPE_BATCH_RESULTS[0]=0; }
    _scope_destroy() {
      if [[ "$scenario" == poll-destroy ]]; then kill -TERM "$parent_pid"; fi
    }
    _scope_call() {
      if [[ "$scenario" == poll-state ]]; then kill -TERM "$parent_pid"; fi
      printf 'empty\n'
    }
    eval "$(declare -f _filing_cross_link_enact | sed '1s/_filing_cross_link_enact/_real_cross_link_enact/')"
    _filing_cross_link_enact() { touch "$LOG_BASE/forbidden-cross-link"; }
    callback() {
      printf '%s\n' "$2" >> "$LOG_BASE/calls"
      kill -TERM "$parent_pid"
      return 0
    }
    _FILING_AGENT_CALLBACK=callback
    case "$scenario" in
      poll-*)
        _REPOLENS_CHILD_PIDS[0]=99999999
        _REPOLENS_CHILD_LENS_IDS[0]=c1
        _REPOLENS_CHILD_STARTED_AT[0]=0
        _parallel_poll_once
        [[ "$REPOLENS_FINAL_STATE" == interrupted ]] || exit 1
        # Reaching here proves nounset did not abort finalization.
        ;;
      final-wait)
        PARALLEL=true
        printf '[{"cluster_id":"c1"}]\n' > "$LOG_BASE/final/manifest.json"
        spawn_lens() { _REPOLENS_SCOPE_REMAINING=1; }
        _parallel_poll_once() { :; }
        sleep() { kill -TERM "$parent_pid"; _REPOLENS_SCOPE_REMAINING=0; }
        dispatch_filing_batch probe
        ;;
      sequential) dispatch_filing_batch probe ;;
      cross-link-*)
        FORGE_REPO=acme/repo
        jq -n '[{cluster_id:"c1",body:"evidence",cross_link_actions:[
          {type:"comment",issue_number:9,body:"first"},
          {type:"comment",issue_number:10,body:"second"}]}]' > "$LOG_BASE/final/manifest.json"
        filing_verify_cluster_citations() { return 0; }
        branch_scope_verify_body() { return 0; }
        repolens_extract_citations() { return 0; }
        _filing_action_reference_candidates() { return 0; }
        forge_filing_capable() { return 0; }
        forge_issue_read_json() {
          if [[ "$scenario" == cross-link-read ]]; then kill -TERM "$parent_pid"; fi
          printf '{"state":"open"}\n'
        }
        forge_issue_comment_once() {
          printf '%s\n' "$2" >> "$LOG_BASE/writes"
          kill -TERM "$parent_pid"
          printf 'https://example.invalid/comment\n'
        }
        forge_issue_comment_read_json() { return 1; }
        _real_cross_link_enact probe
        if [[ "$scenario" == cross-link-read ]]; then
          [[ ! -e "$LOG_BASE/writes" ]] || exit 1
        else
          [[ "$(cat "$LOG_BASE/writes")" == 9 ]] || exit 1
        fi
        ;;
      already-interrupted|empty-manifest)
        if [[ "$scenario" == empty-manifest ]]; then
          printf '[]\n' > "$LOG_BASE/final/manifest.json"
        fi
        kill -TERM "$parent_pid"
        dispatch_filing_batch probe
        ;;
    esac
    [[ "$REPOLENS_FINAL_STATE" == interrupted ]] || exit 1
    [[ "${REPOLENS_INTERRUPT_EXIT_CODE:-0}" == 143 ]] || exit 1
    [[ ! -e "$LOG_BASE/forbidden-cross-link" ]] || exit 1
    [[ ! -e "$LOG_BASE/final/filed/c2.lock" ]] || exit 1
    if [[ -e "$LOG_BASE/calls" ]]; then
      [[ "$(cat "$LOG_BASE/calls")" == c1 ]] || exit 1
    fi
    if [[ "$scenario" == already-interrupted ]]; then
      [[ ! -e "$LOG_BASE/calls" ]] || exit 1
    fi
    exit 0
  )
  rc=$?
  if (( rc == 0 )); then
    echo "PASS: $scenario cancellation preserves finalization and stops admission"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $scenario cancellation boundary (exit $rc)"
    FAIL=$((FAIL + 1))
  fi
done
printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
