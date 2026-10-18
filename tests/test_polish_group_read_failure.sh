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

# Group inventory open/EOF failures must fail, retaining completed receipts for
# an idempotent retry. All forge calls are local fixture writes.
# shellcheck disable=SC2034,SC2329
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/polish.sh
source "$REPO/lib/polish.sh"
# shellcheck source=lib/summary.sh
source "$REPO/lib/summary.sh"
eval "$(declare -f _polish_build_issue_groups | sed '1s/_polish_build_issue_groups/real_build_groups/')"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
failures=0
check() {
  if ! "$@" >/dev/null; then
    printf 'FAIL: %s\n' "$*" >&2
    failures=$((failures + 1))
  fi
}
reset_run() {
  RUN_ID=probe LOG_BASE="$fixture/$1" SUMMARY_FILE="$fixture/$1/summary.json"
  MODE=polish LOCAL_MODE=false GLOBAL_ISSUES_CREATED=0 MAX_ISSUES=''
  FORGE_REPO_SLUG=fixture/repo REPOLENS_FINAL_STATE=finished
  REPOLENS_INTERRUPT_EXIT_CODE=143 consumed_fault=0 fault="$1"
  mkdir -p "$LOG_BASE/polish"
  : > "$LOG_BASE/posts"
  init_summary "$SUMMARY_FILE" probe "$fixture" polish mock '' '' github ''
  jq -n '["spacing-consistency","typographic-rhythm"] | map({domain:"fluency",lens_id:.,title:.,body:"Concrete suggestion",voice_fit:"strong",polish_rank_x1000:1500})' > "$LOG_BASE/polish/ranked-suggestions.json"
}
_polish_build_issue_groups() {
  real_build_groups "$@" || return $?
  if [[ "$fault" == missing ]]; then command rm -- "$groups_file"; fi
}
read() {
  if [[ "${!#}" == group_json && "$consumed_fault" == 0 ]]; then
    if [[ "$fault" == empty-read ]]; then
      : > "$groups_file"
      consumed_fault=1
    elif [[ "$fault" == interrupt ]]; then
      REPOLENS_FINAL_STATE=interrupted
      consumed_fault=1
      printf -v "${!#}" '%s' ''
      return 1
    fi
  fi
  builtin read -r "$@"
}
forge_issue_create() {
  printf 'POST\n' >> "$LOG_BASE/posts"
  # A genuine early EOF on the already-open inventory, after the first complete
  # POST. The caller must save that receipt but report the incomplete batch.
  if [[ "$fault" == partial ]]; then : > "$groups_file"; fi
  printf 'https://github.com/fixture/repo/issues/%s\n' "$(wc -l < "$LOG_BASE/posts")"
}
for mode in missing empty-read partial; do
  reset_run "$mode"
  rc=0
  run_polish_issue_emission probe 3 > "$LOG_BASE/first.log" 2>&1 || rc=$?
  check test "$rc" -ne 0
  expected_posts=0
  if [[ "$mode" == partial ]]; then expected_posts=1; fi
  check test "$(wc -l < "$LOG_BASE/posts")" -eq "$expected_posts"
  check test "$GLOBAL_ISSUES_CREATED" -eq "$expected_posts"
  check jq -e --argjson n "$expected_posts" '.totals.issues_created == $n' "$SUMMARY_FILE"
  check test "$(find "$LOG_BASE/polish/filed" -name '*.url' -type f | wc -l)" -eq "$expected_posts"
  check test -z "$(find "$LOG_BASE/polish" -name 'issue-groups.jsonl.tmp.*' -print)"
  fault=none GLOBAL_ISSUES_CREATED=0
  rc=0
  run_polish_issue_emission probe 3 > "$LOG_BASE/retry.log" 2>&1 || rc=$?
  check test "$rc" -eq 0
  check test "$(wc -l < "$LOG_BASE/posts")" -eq 2
  check test "$GLOBAL_ISSUES_CREATED" -eq 2
  check jq -e '.totals.issues_created == 2' "$SUMMARY_FILE"
  check test "$(find "$LOG_BASE/polish/filed" -name '*.url' -type f | wc -l)" -eq 2
  rc=0
  run_polish_issue_emission probe 3 > "$LOG_BASE/repeat.log" 2>&1 || rc=$?
  check test "$rc" -eq 0
  check test "$(wc -l < "$LOG_BASE/posts")" -eq 2
done
reset_run budget
MAX_ISSUES=1
rc=0
run_polish_issue_emission probe 3 > "$LOG_BASE/budget.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test "$(wc -l < "$LOG_BASE/posts")" -eq 1
check test "$GLOBAL_ISSUES_CREATED" -eq 1
reset_run empty
printf '[]\n' > "$LOG_BASE/polish/ranked-suggestions.json"
rc=0
run_polish_issue_emission probe 3 > "$LOG_BASE/empty.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test ! -s "$LOG_BASE/posts"
reset_run interrupt
rc=0
run_polish_issue_emission probe 3 > "$LOG_BASE/interrupted.log" 2>&1 || rc=$?
check test "$rc" -eq 143
check test ! -s "$LOG_BASE/posts"
printf 'Polish group inventory: %s failures\n' "$failures"
(( failures == 0 ))
