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

# Signal the real enactor at serialization/POST boundaries; never contact a forge.
# shellcheck disable=SC2034,SC2329
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
source "$REPO/lib/filing.sh" || exit 1
FIXTURE="$(mktemp -d)" || exit 1
trap 'rm -rf -- "$FIXTURE"' EXIT
PASS=0 FAIL=0
for scenario in comment-body reopen-body comment-body-fail reopen-body-fail reconciled-comment-body-fail reconciled-reopen-body-fail reopen-banner comment-post reopen-post dispatch-full dispatch-empty ordinary-full ordinary-empty; do
  if (
    LOG_BASE="$FIXTURE/$scenario"
    cross_dir="$LOG_BASE/final/filed/cross-link"
    mkdir -p "$cross_dir" || exit 1
    FORGE_REPO=acme/repo PARALLEL=false CROSS_LINK_MODE=suggest-reopen MAX_ISSUES=1
    REPOLENS_FINAL_STATE=finished
    cancel_enabled=1
    parent_pid="$BASHPID"
    trap 'REPOLENS_FINAL_STATE=interrupted' TERM
    action=comment
    [[ "$scenario" != *reopen-* ]] || action=reopen-suggestion
    key="$action-9"
    if [[ "$scenario" == reconciled-* ]]; then
      : > "$cross_dir/$key.done" || exit 1
      printf 'https://example.invalid/saved-response\n' > "$cross_dir/$key.created-response" || exit 1
    fi
    command jq -n --arg type "$action" '[{cluster_id:"c1",body:"evidence",cross_link_actions:[
      {type:$type,issue_number:9,body:"action body"}]}]' > "$LOG_BASE/final/manifest.json" || exit 1

    # Keep validation deterministic; only the local reservation/dispatch is real.
    filing_verify_cluster_citations() { return 0; }
    branch_scope_verify_body() { return 0; }
    repolens_extract_citations() { return 0; }
    _filing_action_reference_candidates() { return 0; }
    forge_filing_capable() { return 0; }
    forge_issue_list_json() { printf '[]\n'; }
    forge_issue_read_json() {
      if [[ "$action" == comment ]]; then printf '{"state":"open"}\n';
      else printf '{"state":"closed"}\n'; fi
    }
    # A lost POST response must retain its attempt marker even on cancellation.
    forge_issue_comment_once() {
      printf 'POST\n' >> "$LOG_BASE/writes"
      [[ "$scenario" != *-post ]] || kill -TERM "$parent_pid"
      return 1
    }
    forge_issue_create_once() { forge_issue_comment_once "$@"; }
    # Deliver TERM after a reservation exists but before any POST can begin.
    jq() {
      if [[ "$cancel_enabled" == 1 && "$1" == -jr && "$scenario" == *-body-fail ]]; then
        printf 'partial body'
        kill -TERM "$parent_pid"
        return 1
      fi
      command jq "$@" || return 1
      if [[ "$cancel_enabled" == 1 && "$1" == -jr && "$scenario" == *-body ]]; then kill -TERM "$parent_pid"; fi
    }
    cat() {
      command cat "$@" || return 1
      if [[ "$cancel_enabled" == 1 && "$scenario" == reopen-banner && "$1" == "$cross_dir/$key.body.md" ]]; then
        kill -TERM "$parent_pid"
      fi
    }
    case "$scenario" in
      dispatch-*|ordinary-*)
        # Exercise both dispatcher exits; a preserved action survives an empty manifest.
        if [[ "$scenario" == *-empty ]]; then
          command jq '[.[0].cross_link_actions[] + {cluster_id:"c1",evidence_body:"evidence"}]' \
            "$LOG_BASE/final/manifest.json" > "$LOG_BASE/final/cross-link-actions.preserved.json" || exit 1
          printf '[]\n' > "$LOG_BASE/final/manifest.json" || exit 1
        fi
        callback() { printf 'mock-success\n' > "$LOG_BASE/final/filed/$2.url"; }
        _FILING_AGENT_CALLBACK=callback
        forge_issue_comment_once() {
          printf 'POST\n' >> "$LOG_BASE/writes"
          if [[ "$scenario" == dispatch-* ]]; then kill -TERM "$parent_pid"; fi
          return 1
        }
        rc=0
        dispatch_filing_batch probe || rc=$?
        [[ "$(command cat "$LOG_BASE/writes")" == POST ]] || exit 1
        if [[ "$scenario" == dispatch-* ]]; then
          [[ "$rc" != 0 && "$REPOLENS_FINAL_STATE" == interrupted ]] || exit 1
        else
          [[ "$rc" == 0 && "$REPOLENS_FINAL_STATE" == finished ]] || exit 1
        fi
        ;;
      *)
        rc=0
        _filing_cross_link_enact probe || rc=$?
        [[ "$REPOLENS_FINAL_STATE" == interrupted ]] || exit 1
        if [[ "$scenario" == *-body-fail ]]; then
          [[ "$rc" != 0 ]] || exit 1
        fi
        if [[ "$scenario" == reconciled-* ]]; then
          # A saved successful POST still needs reconciliation, even if its body write fails.
          [[ ! -e "$LOG_BASE/writes" && -e "$cross_dir/$key.attempted" ]] || exit 1
          [[ -e "$cross_dir/$key.unverified-done" && -s "$cross_dir/$key.created-response" ]] || exit 1
          REPOLENS_FINAL_STATE=finished
          cancel_enabled=0
          _filing_cross_link_enact probe || true
          [[ ! -e "$LOG_BASE/writes" && -e "$cross_dir/$key.attempted" ]] || exit 1
          exit 0
        elif [[ "$scenario" == *-post ]]; then
          [[ -e "$cross_dir/$key.attempted" ]] || exit 1
          [[ "$(command cat "$LOG_BASE/writes")" == POST ]] || exit 1
        else
          [[ ! -e "$LOG_BASE/writes" && ! -e "$cross_dir/$key.attempted" ]] || exit 1
          [[ ! -e "$cross_dir/$key.body.md" && ! -e "$cross_dir/$key.body.banner.md" ]] || exit 1
          # An unsent reopen action must release the sole issue-budget slot.
          if [[ "$action" == reopen-suggestion ]]; then
            _filing_reserve_issue_attempt "$LOG_BASE/final/filed" "$cross_dir/reopen-suggestion-10.attempted" || exit 1
            rm "$cross_dir/reopen-suggestion-10.attempted"
          fi
        fi
        # Resume: unsent work is eligible; ambiguous POSTs are never retried.
        REPOLENS_FINAL_STATE=finished
        cancel_enabled=0
        _filing_cross_link_enact probe || true
        [[ "$(command cat "$LOG_BASE/writes")" == POST ]] || exit 1
        ;;
    esac
  ); then
    printf 'PASS: %s cross-link cancellation contract\n' "$scenario"
    PASS=$((PASS + 1))
  else
    printf 'FAIL: %s cross-link cancellation contract\n' "$scenario"
    FAIL=$((FAIL + 1))
  fi
done
printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
