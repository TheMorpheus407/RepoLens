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

# Deterministic receipt replacements at grouping and in-flight publication.
# All forge calls are stubs; no timing assumptions or real models are used.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/polish.sh
source "$REPO/lib/polish.sh"
# shellcheck source=lib/summary.sh
source "$REPO/lib/summary.sh"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
failures=0
checks=0
# Accumulate failures so every boundary is exercised in one run.
check() {
  checks=$((checks + 1))
  if ! "$@"; then
    printf 'FAIL (%s/%s): %s\n' "$boundary" "$kind" "$*" >&2
    failures=$((failures + 1))
  fi
}
# Replace the selected receipt without touching the saved draft or reservation.
create_invalid_receipt() {
  case "$kind" in
    directory) mkdir "$marker"; printf 'retained bytes\n' > "$marker/keep" ;;
    symlink) printf 'retained bytes\n' > "$LOG_BASE/outside"; ln -s "$LOG_BASE/outside" "$marker" ;;
    directory-symlink) mkdir "$LOG_BASE/outside"; printf 'retained bytes\n' > "$LOG_BASE/outside/keep"; ln -s "$LOG_BASE/outside" "$marker" ;;
    dangling) ln -s "$LOG_BASE/absent" "$marker" ;;
    fifo) mkfifo "$marker" ;;
  esac
}
# Verify both object identity/type and any unrelated bytes after rejection.
check_invalid_receipt() {
  case "$kind" in
    directory) check test -d "$marker"; check test "$(cat "$marker/keep")" = 'retained bytes'; check test "$(find "$marker" -type f | wc -l)" -eq 1 ;;
    symlink) check test -L "$marker"; check test "$(cat "$LOG_BASE/outside")" = 'retained bytes' ;;
    directory-symlink) check test -L "$marker"; check test "$(cat "$LOG_BASE/outside/keep")" = 'retained bytes'; check test "$(find "$LOG_BASE/outside" -type f | wc -l)" -eq 1 ;;
    dangling) check test -L "$marker"; check test ! -e "$LOG_BASE/absent" ;;
    fifo) check test -p "$marker" ;;
  esac
}
# Introduce the invalid path after inventory, before selected-path admission.
eval "$(declare -f _polish_build_issue_groups | sed '1s/_polish_build_issue_groups/original_build_issue_groups/')"
_polish_build_issue_groups() {
  original_build_issue_groups "$@" || return $?
  if [[ "$boundary" == grouping ]]; then create_invalid_receipt; fi
}
# Introduce the invalid path during a successful in-flight remote create.
forge_issue_create() {
  printf 'post\n' >> "$LOG_BASE/posts"
  create_invalid_receipt || return $?
  printf 'https://github.com/fixture/repo/issues/1\n'
}
# Local emission reaches the same receipt publisher after rendering its draft.
eval "$(declare -f _polish_render_issue_body | sed '1s/_polish_render_issue_body/original_render_issue_body/')"
_polish_render_issue_body() {
  original_render_issue_body "$@" || return $?
  if [[ "$boundary" == local ]]; then create_invalid_receipt; fi
}
for boundary in grouping post local; do
  for kind in directory symlink directory-symlink dangling fifo; do
    RUN_ID=probe LOG_BASE="$fixture/$boundary-$kind"
    SUMMARY_FILE="$LOG_BASE/summary.json"
    GLOBAL_ISSUES_CREATED=0 MAX_ISSUES=1 LOCAL_MODE=false
    [[ "$boundary" != local ]] || LOCAL_MODE=true
    FORGE_REPO_SLUG=fixture/repo REPOLENS_FINAL_STATE=finished
    mkdir -p "$LOG_BASE/polish/filed"
    : > "$LOG_BASE/posts"
    init_summary "$SUMMARY_FILE" probe "$fixture" polish mock '' 1 github ''
    printf '[{"domain":"fluency","lens_id":"spacing-consistency","title":"Spacing","body":"Concrete suggestion","voice_fit":"strong","polish_rank_x1000":1500}]\n' > "$LOG_BASE/polish/ranked-suggestions.json"
    marker="$LOG_BASE/polish/filed/fluency-spacing-consistency.url"
    draft="${marker%.url}.md"
    reservation="${marker%.url}.attempted"
    printf 'previous draft\n' > "$draft"
    rc=0
    run_polish_issue_emission probe 3 > "$LOG_BASE/emission.log" 2>&1 || rc=$?
    check test "$rc" -ne 0
    check test "$GLOBAL_ISSUES_CREATED" -eq 0
    check jq -e '.totals.issues_created == 0' "$SUMMARY_FILE"
    check_invalid_receipt
    check test "$(find "$LOG_BASE/polish/filed" -name '*.tmp.*' | wc -l)" -eq 0
    if [[ "$boundary" == grouping ]]; then
      check test "$(cat "$draft")" = 'previous draft'
      check test ! -e "$reservation"
      check test ! -s "$LOG_BASE/posts"
    else
      check test -s "$draft"
      expected_posts=0
      if [[ "$boundary" == post ]]; then
        expected_posts=1
        check test -f "$reservation"
      else
        check test ! -e "$reservation"
      fi
      check test "$(wc -l < "$LOG_BASE/posts")" -eq "$expected_posts"
      # An unresolved late receipt must also block the next call before a POST.
      rc=0
      run_polish_issue_emission probe 3 > "$LOG_BASE/retry.log" 2>&1 || rc=$?
      check test "$rc" -ne 0
      check test "$(wc -l < "$LOG_BASE/posts")" -eq "$expected_posts"
      check test "$GLOBAL_ISSUES_CREATED" -eq 0
      # Independent reconciliation repairs the receipt without another create.
      if [[ "$kind" == directory ]]; then rm -rf -- "$marker"; else rm -f -- "$marker"; fi
      printf 'https://github.com/fixture/repo/issues/1\n' > "$marker"
      rc=0
      run_polish_issue_emission probe 3 > "$LOG_BASE/repaired.log" 2>&1 || rc=$?
      check test "$rc" -eq 0
      check test "$GLOBAL_ISSUES_CREATED" -eq 1
      check jq -e '.totals.issues_created == 1' "$SUMMARY_FILE"
      check test "$(wc -l < "$LOG_BASE/posts")" -eq "$expected_posts"
    fi
  done
done
printf 'Polish receipt races: %s checks, %s failures\n' "$checks" "$failures"
(( failures == 0 ))
