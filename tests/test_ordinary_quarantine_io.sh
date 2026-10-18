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

# Exercise resume after failed quarantine/rollback with real dispatch, no forge IO.
# shellcheck disable=SC1091,SC2034,SC2329 # sourced APIs consume fixture globals
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO/lib/filing.sh"
eval "$(declare -f _branch_scope_replace_file | sed '1s/_branch_scope_replace_file/real_replace/')"
eval "$(sed -n '/^_install_finalization_signal_handlers() {/,/^}/p' "$REPO/repolens.sh")"
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT

case_io() (
  mode="$1" signal="${2:-TERM}"
  LOG_BASE="$FIXTURE/$mode-$signal"
  filed_dir="$LOG_BASE/final/filed" prefix="$LOG_BASE/final/filed/c1"
  FORGE_REPO=acme/probe PARALLEL=false CROSS_LINK_MODE=off
  REPOLENS_FINAL_STATE=finished _final_interrupt_exit_code='' _final_signal_generation=0
  _install_finalization_signal_handlers
  mkdir -p "$filed_dir"
  printf 'https://github.com/acme/probe/issues/17\n' > "$prefix.url"
  entry='{"cluster_id":"c1","title":"Finding","body":"Evidence","proposed_labels":[],"dedup_against_existing":[]}'
  printf '%s\n' "$entry" > "$prefix.request.json"
  printf '[%s]\n' "$entry" > "$LOG_BASE/final/manifest.json"
  # Isolate receipt lifecycle; payload validators have their own governance suites.
  filing_verify_cluster_citations() { return 0; }
  branch_scope_verify_body() { return 0; }
  forge_filing_capable() { return 0; }
  forge_issue_number_from_url() { printf '17\n'; }
  read_ok=false
  forge_issue_read_json() {
    printf 'read\n' >> "$LOG_BASE/reads"
    $read_ok || return 1
    printf '{"url":"https://github.com/acme/probe/issues/17","number":17,"title":"Finding","body":"Evidence","state":"open","labels":[]}\n'
  }
  forge_issue_list_json() { printf '[]\n'; }
  forge_issue_create_once() {
    printf 'POST\n' >> "$LOG_BASE/posts"
    printf 'https://github.com/acme/probe/issues/17\n'
  }
  _branch_scope_replace_file() {
    if [[ "$mode" == move && "${1:-}" == "$prefix.url" ]]; then return 1; fi
    if [[ "$mode" == rollback && "${1:-}" == "$prefix.unverified-url" ]]; then return 1; fi
    real_replace "$@" || return 1
    if [[ "$mode" == rollback && "${1:-}" == "$prefix.url" ]]; then
      kill -s "$signal" "$BASHPID"
    fi
  }

  if [[ "$mode" == move ]]; then
    # Both the governor's quarantine and the dispatcher's fallback move fail.
    dispatch_rc=0
    dispatch_filing_batch probe > "$LOG_BASE/first-dispatch" || dispatch_rc=$?
    [[ "$dispatch_rc" == 1 ]]
  elif [[ "$mode" == rollback ]]; then
    # Recount has no governor and this historical success has no attempt marker.
    rc=0
    filing_verified_issue_count probe > "$LOG_BASE/count" || rc=$?
    [[ "$rc" == "$REPOLENS_INTERRUPT_EXIT_CODE" && ! -s "$LOG_BASE/count" ]]
    [[ -e "$prefix.unverified-url" && ! -e "$prefix.url" && ! -e "$prefix.failed" ]]
  else
    # Failure to persist the guard must leave the original receipt resumable.
    mkdir "$prefix.attempted"
    dispatch_rc=0
    dispatch_filing_batch probe > "$LOG_BASE/first-dispatch" 2> "$LOG_BASE/errors" || dispatch_rc=$?
    printf 'guard failure: receipt=%s quarantined=%s governor=%s\n' \
      "$(test -f "$prefix.url" && echo yes || echo no)" \
      "$(test -e "$prefix.unverified-url" && echo yes || echo no)" \
      "$(test -e "$prefix.governor" && echo yes || echo no)"
    [[ "$dispatch_rc" == 1 && -f "$prefix.url" && ! -e "$prefix.unverified-url" && ! -e "$prefix.governor" ]]
    rmdir "$prefix.attempted"
  fi

  # Heal storage/readback and deliberately miss remote deduplication. A saved
  # receipt must be reattested; an unrestored receipt must never repeat its POST.
  mode=healed read_ok=true REPOLENS_FINAL_STATE=finished
  : > "$LOG_BASE/reads"
  dispatch_rc=0
  dispatch_filing_batch probe > "$LOG_BASE/resumed-dispatch" || dispatch_rc=$?
  reads="$(wc -l < "$LOG_BASE/reads")"
  posts=0
  [[ ! -e "$LOG_BASE/posts" ]] || posts="$(wc -l < "$LOG_BASE/posts")"
  printf '%s/%s: resumed reads=%s posts=%s, %s\n' "$1" "$signal" "$reads" "$posts" "$(cat "$LOG_BASE/resumed-dispatch")"
  [[ "$dispatch_rc" == 0 && "$posts" == 0 && ! -e "$prefix.governor" ]]
  if [[ "$1" == rollback ]]; then
    [[ "$reads" == 0 && -f "$prefix.attempted" && -f "$prefix.unverified-url" ]]
  else
    [[ "$reads" == 1 && -f "$prefix.url" && ! -e "$prefix.failed" && ! -e "$prefix.unverified-url" ]]
  fi
)

case "${1:-all}" in
  all)
    case_io move
    case_io guard
    for signal in HUP INT TERM; do case_io rollback "$signal"; done
    ;;
  move|guard) case_io "$1" ;;
  rollback) for signal in HUP INT TERM; do case_io rollback "$signal"; done ;;
  *) exit 2 ;;
esac
