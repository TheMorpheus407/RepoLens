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

# A failed cancellation rollback must release its read-only governor for repair.
# shellcheck disable=SC1091,SC2034,SC2329
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
source "$REPO/lib/filing.sh" || exit 1
replace_function="$(declare -f _branch_scope_replace_file)" || exit 1
eval "${replace_function/_branch_scope_replace_file/real_replace}" || exit 1
signal_handlers="$(sed -n '/^_install_finalization_signal_handlers() {/,/^}/p' "$REPO/repolens.sh")" || exit 1
[[ -n "$signal_handlers" ]] || exit 1
eval "$signal_handlers" || exit 1
FIXTURE="$(mktemp -d)" || exit 1
trap 'rm -rf -- "$FIXTURE"' EXIT
case_rollback() (
  signal="$1" move_status="$2"
  LOG_BASE="$FIXTURE/$signal-$move_status"
  prefix="$LOG_BASE/final/filed/c1"
  FORGE_REPO=acme/probe PARALLEL=false CROSS_LINK_MODE=off
  REPOLENS_FINAL_STATE=finished _final_interrupt_exit_code='' _final_signal_generation=0
  _install_finalization_signal_handlers || return 1
  mkdir -p "${prefix%/*}" || return 1
  printf 'https://github.com/acme/probe/issues/17\n' > "$prefix.url" || return 1
  entry='{"cluster_id":"c1","title":"Finding","body":"Evidence","proposed_labels":[],"dedup_against_existing":[]}'
  printf '%s\n' "$entry" > "$prefix.request.json" || return 1
  printf '[%s]\n' "$entry" > "$LOG_BASE/final/manifest.json" || return 1
  filing_verify_cluster_citations() { return 0; }
  branch_scope_verify_body() { return 0; }
  forge_filing_capable() { return 0; }
  forge_issue_number_from_url() { printf '17\n'; }
  read_ok=false
  forge_issue_read_json() {
    printf 'read\n' >> "$LOG_BASE/reads" || return 1
    $read_ok || return 1
    printf '{"url":"https://github.com/acme/probe/issues/17","number":17,"title":"Finding","body":"Evidence","state":"open","labels":[]}\n'
  }
  forge_issue_list_json() { printf '[]\n'; }
  forge_issue_create_once() { printf 'POST\n' >> "$LOG_BASE/posts"; return 1; }
  _branch_scope_replace_file() {
    [[ "$1" != "$prefix.unverified-url" ]] || return 1
    real_replace "$@" || return 1
    if [[ "$1" == "$prefix.url" ]]; then
      kill -s "$signal" "$BASHPID" || return 1
      return "$move_status"
    fi
  }
  rc=0
  dispatch_filing_batch probe > "$LOG_BASE/interrupted-dispatch" || rc=$?
  [[ "$rc" == 1 && "$REPOLENS_FINAL_STATE" == interrupted ]] || return 1
  [[ -f "$prefix.unverified-url" && -f "$prefix.attempted" && ! -e "$prefix.url" && ! -e "$prefix.failed" ]] || return 1
  [[ ! -e "$prefix.governor" ]] || { printf 'FAIL: %s/%s leaked governor\n' "$signal" "$move_status"; exit 1; }
  cmp -s <(printf 'https://github.com/acme/probe/issues/17\n') "$prefix.unverified-url" || return 1
  # Model explicit operator reconciliation, then resume through the real governor.
  real_replace "$prefix.unverified-url" "$prefix.url" || return 1
  REPOLENS_FINAL_STATE=finished read_ok=true
  : > "$LOG_BASE/reads" || return 1
  dispatch_filing_batch probe > "$LOG_BASE/resumed-dispatch" || return 1
  read_count="$(wc -l < "$LOG_BASE/reads")" || return 1
  [[ "$read_count" == 1 && ! -e "$LOG_BASE/posts" && ! -e "$prefix.governor" ]] || return 1
  [[ -f "$prefix.url" && -f "$prefix.attempted" && ! -e "$prefix.failed" ]] || return 1
  printf 'PASS: %s/move-status-%s releases governor; repaired resume reattests without POST\n' "$signal" "$move_status"
)
for signal in HUP INT TERM; do
  for move_status in 0 1; do
    case_rollback "$signal" "$move_status" || { printf 'FAIL: %s/move-status-%s\n' "$signal" "$move_status"; exit 1; }
  done
done
