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

# Regression: repolens-r6-p3-2. Real returning finalization traps, mocked forge.
# shellcheck disable=SC1091,SC2034,SC2329 # sourced APIs and eval-installed signal handlers
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO/lib/filing.sh"
eval "$(sed -n '/^_install_finalization_signal_handlers() {/,/^}/p' "$REPO/repolens.sh")"
FIXTURE="$(mktemp -d )"
trap 'rm -rf -- "$FIXTURE"' EXIT

case_cancel() (
  action="$1" phase="$2" signal="$3"
  LOG_BASE="$FIXTURE/$action-$phase-$signal"
  cross_dir="$LOG_BASE/final/filed/cross-link"
  key="$action-9"
  mkdir -p "$cross_dir"
  FORGE_REPO=acme/probe CROSS_LINK_MODE=suggest-reopen
  REPOLENS_FINAL_STATE=finished parent_pid="$BASHPID"
  _final_interrupt_exit_code='' _final_signal_generation=0
  _install_finalization_signal_handlers
  : > "$cross_dir/$key.done"
  printf 'https://github.com/acme/probe/issues/17\n' > "$cross_dir/$key.created-response"
  printf 'Evidence\n' > "$cross_dir/$key.body.md"
  printf 'Saved banner\n' > "$cross_dir/$key.body.banner.md"
  command jq -n --arg action "$action" '[{cluster_id:"c1",body:"evidence",cross_link_actions:[{type:$action,issue_number:9,body:"Evidence"}]}]' > "$LOG_BASE/final/manifest.json"
  filing_verify_cluster_citations() { return 0; }
  branch_scope_verify_body() { return 0; }
  repolens_extract_citations() { return 0; }
  _filing_action_reference_candidates() { return 0; }
  forge_filing_capable() { return 0; }
  forge_issue_comment_once() { printf 'UNEXPECTED POST\n' >> "$LOG_BASE/posts"; return 99; }
  forge_issue_create_once() { forge_issue_comment_once "$@"; }
  cat() {
    command cat "$@" || return 1
    if [[ "$phase" == response && "${1:-}" == "$cross_dir/$key.created-response" ]]; then
      kill -s "$signal" "$parent_pid"
    fi
  }
  forge_issue_number_from_url() {
    [[ "$phase" != parse ]] || kill -s "$signal" "$parent_pid"
    printf '17\n'
  }
  forge_issue_read_json() {
    if [[ "$2" == 9 ]]; then
      if [[ "$action" == comment ]]; then printf '{"state":"open"}\n';
      else printf '{"state":"closed"}\n'; fi
    else
      printf '%s\n' "$REPOLENS_FINAL_STATE" >> "$LOG_BASE/late-reads"
      printf '{}\n'
    fi
  }
  forge_issue_comment_read_json() {
    printf '%s\n' "$REPOLENS_FINAL_STATE" >> "$LOG_BASE/late-reads"
    printf '{}\n'
  }
  rc=0
  _filing_cross_link_enact probe || rc=$?
  [[ "$rc" == 1 && "$REPOLENS_FINAL_STATE" == interrupted ]]
  [[ ! -e "$LOG_BASE/posts" && -e "$cross_dir/$key.done" ]]
  [[ ! -e "$LOG_BASE/late-reads" ]]
  [[ "$(command cat "$cross_dir/$key.body.md")" == Evidence ]]
  [[ "$(command cat "$cross_dir/$key.body.banner.md")" == 'Saved banner' ]]
  [[ "$(find "$cross_dir" -name '*.reconcile.*' | wc -l)" -eq 0 ]]
  printf '%s/%s/%s: rc=%s, no new remote read, original receipt retained\n' \
    "$action" "$phase" "$signal" "$rc"
)
for signal in HUP INT TERM; do
  case_cancel comment response "$signal"
  case_cancel reopen-suggestion response "$signal"
  case_cancel reopen-suggestion parse "$signal"
done

echo 'Results: cancellation boundaries verified without remote writes'
