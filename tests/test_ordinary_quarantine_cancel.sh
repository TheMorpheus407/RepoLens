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

# Regression: repolens-r6-p3-1. Real returning finalization traps, mocked forge.
# shellcheck disable=SC1091,SC2034,SC2329 # sourced APIs and eval-installed signal handlers
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO/lib/filing.sh"
eval "$(declare -f _branch_scope_replace_file | sed '1s/_branch_scope_replace_file/real_replace/')"
eval "$(sed -n '/^_install_finalization_signal_handlers() {/,/^}/p' "$REPO/repolens.sh")"
FIXTURE="$(mktemp -d )"
trap 'rm -rf -- "$FIXTURE"' EXIT
case_quarantine() (
  signal="$1"
  LOG_BASE="$FIXTURE/$signal"
  filed_dir="$LOG_BASE/final/filed"
  mkdir -p "$filed_dir"
  prefix="$filed_dir/c1"
  printf 'https://github.com/acme/probe/issues/17\n' > "$prefix.url"
  printf '{"title":"Finding","body":"Evidence","proposed_labels":[]}\n' > "$prefix.request.json"
  FORGE_REPO=acme/probe REPOLENS_FINAL_STATE=finished
  _final_interrupt_exit_code='' _final_signal_generation=0
  _install_finalization_signal_handlers
  forge_issue_number_from_url() { printf '17\n'; }
  read_ok=false
  forge_issue_read_json() {
    printf 'read\n' >> "$LOG_BASE/reads"
    $read_ok || return 1
    printf '{"url":"https://github.com/acme/probe/issues/17","number":17,"title":"Finding","body":"Evidence","state":"open","labels":[]}\n'
  }
  _branch_scope_replace_file() {
    real_replace "$@" || return 1
    if [[ "${1:-}" == "$prefix.url" ]]; then kill -s "$signal" "$BASHPID"; fi
  }
  rc=0
  filing_verified_issue_count probe > "$LOG_BASE/count" || rc=$?
  [[ "$rc" == "$REPOLENS_INTERRUPT_EXIT_CODE" && "$REPOLENS_FINAL_STATE" == interrupted ]]
  [[ -e "$prefix.url" && ! -e "$prefix.unverified-url" && ! -e "$prefix.failed" ]]
  [[ ! -s "$LOG_BASE/count" ]]
  REPOLENS_FINAL_STATE=finished
  : > "$LOG_BASE/reads"
  read_ok=true
  resumed_count="$(filing_verified_issue_count probe)"
  [[ "$resumed_count" == 1 && -s "$LOG_BASE/reads" ]]
  printf '%s: interrupted rc=%s; saved .url preserved; resume reattests and counts %s\n' \
    "$signal" "$rc" "$resumed_count"
)
for signal in HUP INT TERM; do case_quarantine "$signal"; done

echo 'Results: cancellation boundaries verified without remote writes'
