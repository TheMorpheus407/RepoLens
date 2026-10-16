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

# Scope outage recovery through production callers; no real model or forge IO.
# shellcheck disable=SC2034,SC2329 # Production APIs consume fixture globals.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/synthesize.sh"
source "$ROOT/lib/filing.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
# Fail the current case immediately, including inside a checked subshell.
check() { "$@" || { printf 'FAIL: %s\n' "$*" >&2; exit 1; }; }
MODE=branch-review PARALLEL=false CROSS_LINK_MODE=off AGENT=stub
PROJECT_PATH="$TMP/project" FORGE_REPO=acme/probe
mkdir -p "$PROJECT_PATH/src"
printf 'approved source\n' > "$PROJECT_PATH/src/probe.sh"
forge_filing_capable() { return 0; }
forge_issue_list_json() { printf '[]\n'; }
forge_issue_number_from_url() { printf '17\n'; }
forge_issue_read_json() {
  if [[ "$2" == 9 ]]; then
    printf '{"number":9,"state":"open"}\n'
  else
    jq '.[0] | {number:17,title,body,labels:.proposed_labels,state:"open",url:"https://github.com/acme/probe/issues/17"}' "$LOG_BASE/final/manifest.json"
  fi
}
forge_issue_create_once() { printf 'POST\n' >> "$LOG_BASE/posts"; printf 'https://github.com/acme/probe/issues/17\n'; }
forge_issue_comment_once() { printf 'POST\n' >> "$LOG_BASE/posts"; printf 'https://github.com/acme/probe/issues/9#issuecomment-1\n'; }
forge_issue_comment_read_json() { jq -n --rawfile body "$cross_prefix.body.md" '{body:$body,url:"https://github.com/acme/probe/issues/9#issuecomment-1"}'; }
compose_prompt() { printf 'mock prompt\n'; }
run_agent() {
  printf 'MODEL\n' >> "$LOG_BASE/models"
  if [[ "$fault" == late* ]]; then rm "$BRANCH_SCOPE_FILE"; fi
  cat "$LOG_BASE/agent.json"
}
# Create isolated approved findings and scope for each recovery scenario.
fresh() {
  LOG_BASE="$TMP/$1" BRANCH_SCOPE_FILE="$TMP/$1/scope.json"
  mkdir -p "$LOG_BASE/final/filed"
  printf '["src/probe.sh"]\n' > "$BRANCH_SCOPE_FILE"
  jq -n '[{cluster_id:"c1",title:"Finding",severity:"high",domain:"security",lens:"injection",root_cause_category:"validation",source_finding_paths:["finding.md"],dedup_against_existing:[],proposed_labels:[],cross_link_actions:[],granularity:"independent",body:"src/probe.sh:1"}]' > "$LOG_BASE/final/manifest.json"
}
case_directory() (
  fresh directory
  dir="$LOG_BASE/findings"
  mkdir "$dir"
  printf 'src/unchanged.sh:1\n' > "$dir/first.md"
  printf 'src/probe.sh:1\n' > "$dir/second.md"
  # Stable enumeration guarantees rejection precedes the injected outage.
  find() { printf '%s\0' "$dir/first.md" "$dir/second.md"; }
  eval "$(declare -f branch_scope_verify_body | sed '1s/branch_scope_verify_body/original_verify/')"
  branch_scope_verify_body() {
    if [[ "$1" == src/probe.sh:1 ]]; then rm -f "$BRANCH_SCOPE_FILE"; fi
    original_verify "$@"
  }
  rc=0
  branch_scope_filter_directory "$dir" || rc=$?
  check test "$rc" -ne 0
  check test -f "$dir/first.md"
  check test -f "$dir/second.md"
  check test ! -e "$dir/first.md.out-of-scope.reason"
  unset -f branch_scope_verify_body
  eval "$(declare -f original_verify | sed '1s/original_verify/branch_scope_verify_body/')"
  printf '["src/probe.sh"]\n' > "$BRANCH_SCOPE_FILE"
  check branch_scope_filter_directory "$dir"
  check test -f "$dir/first.md.out-of-scope"
  check test -f "$dir/second.md"
  printf 'PASS: directory verifies all findings before quarantining any\n'
)
case_synthesis() (
  fault="$1"
  fresh "synthesis-$fault"
  mkdir -p "$LOG_BASE/rounds/round-1/lens-outputs/security"
  printf 'src/probe.sh:1\n' > "$LOG_BASE/rounds/round-1/lens-outputs/security/finding.md"
  printf '[{"cluster_id":"saved"}]\n' > "$LOG_BASE/final/cross-link-actions.preserved.json"
  cp "$LOG_BASE/final/manifest.json" "$LOG_BASE/agent.json"
  if [[ "$fault" == late-min ]]; then
    REPOLENS_MIN_SEVERITY=high CROSS_LINK_MODE=comment
    jq '. + [.[0] | .cluster_id="low" | .title="Minor concern" | .severity="low" | .cross_link_actions=[{type:"comment",issue_number:9,body:"src/probe.sh:1"}]]' "$LOG_BASE/agent.json" > "$LOG_BASE/low.json"
    mv "$LOG_BASE/low.json" "$LOG_BASE/agent.json"
  fi
  before="$(sha256sum "$LOG_BASE/final/manifest.json" "$LOG_BASE/final/cross-link-actions.preserved.json")"
  case "$fault" in
    missing|missing-empty)
      rm "$BRANCH_SCOPE_FILE"
      [[ "$fault" != missing-empty ]] || rm -rf -- "$LOG_BASE/rounds"
      ;;
    malformed) printf '{broken\n' > "$BRANCH_SCOPE_FILE" ;;
    unreadable)
      chmod 000 "$BRANCH_SCOPE_FILE"
      if [[ -r "$BRANCH_SCOPE_FILE" ]]; then
        jq() {
          local arg
          for arg in "$@"; do [[ "$arg" != "$BRANCH_SCOPE_FILE" ]] || return 2; done
          command jq "$@"
        }
      fi
      ;;
  esac
  rc=0
  run_synthesizer probe || rc=$?
  check test "$rc" -ne 0
  check test "$(sha256sum "$LOG_BASE/final/manifest.json" "$LOG_BASE/final/cross-link-actions.preserved.json")" = "$before"
  if [[ "$fault" == late* ]]; then
    check test -f "$LOG_BASE/final/manifest.scope-pending.json"
    check jq -e 'length == 1 and .[0].body == "src/probe.sh:1"' "$LOG_BASE/final/manifest.scope-pending.json"
    if [[ "$fault" == late-min ]]; then
      check jq -e 'length == 1 and .[0].cluster_id == "low"' "$LOG_BASE/final/cross-link-actions.scope-pending.json"
    fi
  else
    check test ! -e "$LOG_BASE/models"
  fi
  unset -f jq
  [[ ! -f "$BRANCH_SCOPE_FILE" ]] || chmod 600 "$BRANCH_SCOPE_FILE"
  # Regenerate using changed drafts/scope rather than recycling pending evidence.
  mkdir -p "$LOG_BASE/rounds/round-1/lens-outputs/security"
  printf 'new source\n' > "$PROJECT_PATH/src/new.sh"
  printf 'src/new.sh:1\n' > "$LOG_BASE/rounds/round-1/lens-outputs/security/new.md"
  printf '["src/new.sh"]\n' > "$BRANCH_SCOPE_FILE"
  jq '.[0].body="src/new.sh:1" | .[0].title="Refreshed finding"' "$LOG_BASE/agent.json" > "$LOG_BASE/new-agent.json"
  mv "$LOG_BASE/new-agent.json" "$LOG_BASE/agent.json"
  fault=repaired
  check run_synthesizer probe
  [[ "$1" == missing-empty ]] || check test -f "$LOG_BASE/rounds/round-1/lens-outputs/security/finding.md.out-of-scope"
  check jq -e 'length == 1 and .[0].title == "[REGRESSION][HIGH] Refreshed finding" and .[0].body == "src/new.sh:1"' "$LOG_BASE/final/manifest.json"
  check test ! -e "$LOG_BASE/final/manifest.scope-pending.json"
  check test ! -e "$LOG_BASE/final/cross-link-actions.scope-pending.json"
  printf 'PASS: synthesis preserves published outputs on %s scope failure and retries\n' "$1"
)
case_filing() (
  saved="$1"
  fresh "filing-$saved"
  prefix="$LOG_BASE/final/filed/c1"
  if [[ "$saved" == saved ]]; then
    # Admission queues c0 before reattesting c1; an outage must release c0's lock.
    jq '[.[0] | .cluster_id="c0"] + .' "$LOG_BASE/final/manifest.json" > "$LOG_BASE/queued.json"
    mv "$LOG_BASE/queued.json" "$LOG_BASE/final/manifest.json"
    printf 'https://github.com/acme/probe/issues/17\n' > "$prefix.url"
    jq '.[1]' "$LOG_BASE/final/manifest.json" > "$prefix.request.json"
  fi
  rm "$BRANCH_SCOPE_FILE"
  rc=0
  dispatch_filing_batch probe || rc=$?
  check test "$rc" -ne 0
  for suffix in failed attempted unverified-url governor lock; do check test ! -e "$prefix.$suffix"; done
  check test ! -e "$LOG_BASE/posts"
  check test ! -e "$LOG_BASE/final/filed/c0.lock"
  [[ "$saved" != saved ]] || check test -f "$prefix.url"
  printf '["src/probe.sh"]\n' > "$BRANCH_SCOPE_FILE"
  check dispatch_filing_batch probe
  check test -f "$prefix.url"
  check test "$(wc -l < "$LOG_BASE/posts")" -eq 1
  printf 'PASS: %s filing retains retryable state on scope outage\n' "$saved"
)
case_cross_link() (
  saved="$1" boundary="$2"
  fresh "cross-$saved-$boundary"
  CROSS_LINK_MODE=comment
  cross_prefix="$LOG_BASE/final/filed/cross-link/comment-9"
  jq '.[0].cross_link_actions=[{type:"comment",issue_number:9,body:"src/probe.sh:1"}]' "$LOG_BASE/final/manifest.json" > "$LOG_BASE/changed.json"
  mv "$LOG_BASE/changed.json" "$LOG_BASE/final/manifest.json"
  mkdir -p "${cross_prefix%/*}"
  if [[ "$saved" == saved ]]; then
    printf 'done\n' > "$cross_prefix.done"
    printf 'src/probe.sh:1' > "$cross_prefix.body.md"
    printf 'https://github.com/acme/probe/issues/9#issuecomment-1\n' > "$cross_prefix.created-response"
  fi
  # Fail either the parent's scope check or the later action-body check.
  eval "$(declare -f branch_scope_verify_body | sed '1s/branch_scope_verify_body/original_verify/')"
  branch_scope_verify_body() {
    printf 'read\n' >> "$LOG_BASE/scope-reads"
    if [[ "$boundary" == parent || "$(wc -l < "$LOG_BASE/scope-reads")" -eq 2 ]]; then rm -f "$BRANCH_SCOPE_FILE"; fi
    original_verify "$@"
  }
  rc=0
  _filing_cross_link_enact probe || rc=$?
  check test "$rc" -ne 0
  check test ! -e "$cross_prefix.failed"
  check test ! -e "$cross_prefix.unverified-done"
  check test ! -e "$LOG_BASE/posts"
  [[ "$saved" != saved ]] || check test -f "$cross_prefix.done"
  unset -f branch_scope_verify_body
  eval "$(declare -f original_verify | sed '1s/original_verify/branch_scope_verify_body/')"
  printf '["src/probe.sh"]\n' > "$BRANCH_SCOPE_FILE"
  check _filing_cross_link_enact probe
  check test -f "$cross_prefix.done"
  if [[ "$saved" == saved ]]; then check test ! -e "$LOG_BASE/posts";
  else check test "$(wc -l < "$LOG_BASE/posts")" -eq 1; fi
  printf 'PASS: %s cross-link retries %s scope outage without repeated POST\n' "$saved" "$boundary"
)
case "${1:-all}" in
  directory) case_directory ;;
  synthesis) for fault in missing missing-empty malformed unreadable late late-min; do case_synthesis "$fault"; done ;;
  synthesis-*) case_synthesis "${1#synthesis-}" ;;
  filing-*) case_filing "${1#filing-}" ;;
  cross-*) case_cross_link "${1#cross-}" "${2:-action}" ;;
  filing) case_filing new; case_filing saved ;;
  cross) for saved in new saved; do for boundary in parent action; do case_cross_link "$saved" "$boundary"; done; done ;;
  all) case_directory; for fault in missing missing-empty malformed unreadable late late-min; do case_synthesis "$fault"; done; case_filing new; case_filing saved; for saved in new saved; do for boundary in parent action; do case_cross_link "$saved" "$boundary"; done; done ;;
esac
