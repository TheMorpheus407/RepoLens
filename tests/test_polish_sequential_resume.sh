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


# repolens-r8-p2-1 / p2-2: production sequential traps and fresh resume counters.
# shellcheck disable=SC2034,SC2329 # Globals/callbacks consumed by sourced code.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
# shellcheck source=lib/core.sh
source "$REPO/lib/core.sh"
# shellcheck source=lib/summary.sh
source "$REPO/lib/summary.sh"
# shellcheck source=lib/polish.sh
source "$REPO/lib/polish.sh"
eval "$(sed -n '/^_handle_hangup() {/,/^trap _handle_termination TERM/p' "$REPO/repolens.sh")"
trap - HUP INT TERM
print_resume_hint() { :; }
eval "$(declare -f increment_summary_issues_created | sed '1s/increment_summary_issues_created/original_increment_summary_issues_created/')"
PASS=0 FAIL=0
check() {
  if "$@"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$*"; fi
}
forge_issue_create() {
  printf '%s\n' "$2" >> "$LOG_BASE/posts"
  local n
  n="$(wc -l < "$LOG_BASE/posts")"
  printf 'https://github.com/fixture/repo/issues/%s\n' "$n"
  if [[ "$boundary" == post && "$n" -eq 1 ]]; then kill -s "$signal" "$parent_pid"; fi
  return 0
}
for boundary in post summary; do
  for signal in HUP INT TERM; do
    RUN_ID=probe LOG_BASE="$FIXTURE/$boundary-$signal" SUMMARY_FILE="$FIXTURE/$boundary-$signal/summary.json"
    MODE=polish MAX_ISSUES=1 GLOBAL_ISSUES_CREATED=0 LOCAL_MODE=false PARALLEL=false
    FORGE_REPO_SLUG=fixture/repo REPOLENS_FINAL_STATE=finished
    mkdir -p "$LOG_BASE/polish"
    : > "$LOG_BASE/posts"
    init_summary "$SUMMARY_FILE" "$RUN_ID" "$FIXTURE" polish mock '' 1 github ''
    jq -n '["spacing-consistency","typographic-rhythm"] | map({domain:"fluency",lens_id:.,title:("[POLISH] "+.),body:"Concrete suggestion",voice_fit:"strong",polish_rank_x1000:1500})' \
      > "$LOG_BASE/polish/ranked-suggestions.json"
    rc=0
    (
      parent_pid=$BASHPID
      trap '_handle_hangup' HUP
      trap '_handle_interrupt' INT
      trap '_handle_termination' TERM
      increment_summary_issues_created() {
        original_increment_summary_issues_created "$@"
        if [[ "$boundary" == summary ]]; then kill -s "$signal" "$parent_pid"; fi
      }
      run_polish_issue_emission probe 3
    ) || rc=$?
    expected=143
    case "$signal" in HUP) expected=129 ;; INT) expected=130 ;; esac
    check test "$rc" -eq "$expected"
    check test "$(wc -l < "$LOG_BASE/posts")" -eq 1
    check test "$(find "$LOG_BASE/polish/filed" -name '*.url' | wc -l)" -eq 1
    check test "$(jq .totals.issues_created "$SUMMARY_FILE")" -eq 1
    GLOBAL_ISSUES_CREATED=0 REPOLENS_FINAL_STATE=finished
    rc=0
    run_polish_issue_emission probe 3 || rc=$?
    check test "$rc" -eq 0
    check test "$(wc -l < "$LOG_BASE/posts")" -eq 1
    check test "$(find "$LOG_BASE/polish/filed" -name '*.url' | wc -l)" -eq 1
    check test "$(jq .totals.issues_created "$SUMMARY_FILE")" -eq 1
    # An additional resume must keep the same run-wide cap too.
    GLOBAL_ISSUES_CREATED=0
    run_polish_issue_emission probe 3 || rc=$?
    check test "$(wc -l < "$LOG_BASE/posts")" -eq 1
  done
done
printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
