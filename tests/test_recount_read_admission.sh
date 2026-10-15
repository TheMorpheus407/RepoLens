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

# repolens-r5-p2-1: do not admit a forge read after local receipt cancellation.
# shellcheck disable=SC2034,SC2329 # Production handlers/callbacks consume globals.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$(mktemp -d)" || exit 1
trap 'rm -rf -- "$FIXTURE"' EXIT
# shellcheck source=/dev/null
source "$REPO/lib/filing.sh"
# shellcheck source=/dev/null
source "$REPO/lib/forge.sh"
eval "$(sed -n '/^_install_finalization_signal_handlers() {/,/^}/p' "$REPO/repolens.sh")"
case_recount_admission() (
  receipt_kind="$1" receipt_signal="$2"
  LOG_BASE="$FIXTURE/$receipt_kind-$receipt_signal"
  FORGE_REPO=acme/probe FORGE_PROVIDER=gh FORGE_HOST=github.com
  mkdir -p "$LOG_BASE/final/filed/cross-link"
  if [[ "$receipt_kind" == issue ]]; then
    prefix="$LOG_BASE/final/filed/c1"
    receipt="$prefix.url" input="$prefix.request.json" number=1
    printf 'https://github.com/acme/probe/issues/1\n' > "$receipt"
    printf '{"title":"Finding","body":"Evidence","proposed_labels":[]}\n' > "$input"
  else
    prefix="$LOG_BASE/final/filed/cross-link/reopen-suggestion-9"
    receipt="$prefix.done" input="$prefix.created-response" number=17
    : > "$receipt"
    printf 'https://github.com/acme/probe/issues/17\n' > "$input"
    printf 'Evidence\n' > "$prefix.body.banner.md"
  fi
  _final_interrupt_exit_code='' _final_signal_generation=0
  REPOLENS_FINAL_STATE=finished parent_pid="$BASHPID" cancel_enabled=true
  : > "$LOG_BASE/reads"
  _install_finalization_signal_handlers
  cat() {
    command cat "$@" || return 1
    if $cancel_enabled && [[ "${1:-}" == "$input" ]]; then kill -s "$receipt_signal" "$parent_pid"; fi
  }
  forge_issue_read_json() {
    printf '%s\n' "$REPOLENS_FINAL_STATE" >> "$LOG_BASE/reads"
    if [[ "$receipt_kind" == issue ]]; then
      printf '{"url":"https://github.com/acme/probe/issues/1","number":1,"title":"Finding","body":"Evidence","state":"open","labels":[]}\n'
    else
      jq -cn --rawfile body "$prefix.body.banner.md" '{number:17,title:"[reopen-candidate] consider re-opening #9",body:$body,url:"https://github.com/acme/probe/issues/17",state:"open"}'
    fi
  }
  passed=0 failed=0
  check() { if "$@"; then passed=$((passed+1)); else failed=$((failed+1)); printf 'FAIL: %s/%s: %s\n' "$receipt_kind" "$receipt_signal" "$*"; fi; }
  count_rc=0
  filing_verified_issue_count probe > "$LOG_BASE/count" || count_rc=$?
  expected_rc=130
  case "$receipt_signal" in HUP) expected_rc=129;; TERM) expected_rc=143;; esac
  check test "$count_rc" -eq "$expected_rc"
  check test "$REPOLENS_FINAL_STATE" = interrupted
  check test ! -s "$LOG_BASE/reads"
  check test ! -s "$LOG_BASE/count"
  check test -f "$receipt"
  check test ! -e "$prefix.unverified-done"
  check test ! -e "$prefix.unverified-url"
  check test ! -e "$prefix.failed"
  REPOLENS_FINAL_STATE=finished cancel_enabled=false
  count="$(filing_verified_issue_count probe)"
  check test "$?" -eq 0
  check test "$count" -eq 1
  check test -s "$LOG_BASE/reads"
  printf '%s/%s: %s passed, %s failed\n' "$receipt_kind" "$receipt_signal" "$passed" "$failed"
  (( failed == 0 ))
)
failed_cases=0
for receipt_kind in issue reopen; do
  for receipt_signal in HUP INT TERM; do
    case_recount_admission "$receipt_kind" "$receipt_signal" || failed_cases=$((failed_cases+1))
  done
done
printf 'Recount admission scenarios: %s failed\n' "$failed_cases"
(( failed_cases == 0 ))
