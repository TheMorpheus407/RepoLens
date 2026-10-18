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

# A URL receipt must be a regular non-symlink file before it can consume budget or
# resolve an uncertain POST. Forge calls are local stubs throughout.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/polish.sh
source "$REPO/lib/polish.sh"
# shellcheck source=lib/summary.sh
source "$REPO/lib/summary.sh"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
failures=0
# Accumulate assertion failures while exercising every object and budget case.
check() {
  if ! "$@"; then
    printf 'FAIL: %s\n' "$*" >&2
    failures=$((failures + 1))
  fi
}
# Record remote-create attempts locally and return a deterministic receipt URL.
forge_issue_create() {
  printf 'post\n' >> "$LOG_BASE/posts"
  printf 'https://github.com/fixture/repo/issues/1\n'
}
for kind in directory symlink dangling fifo; do
  for attempted in yes no; do
    for budget in 1 ''; do
      RUN_ID=probe LOG_BASE="$fixture/$kind-$attempted-${budget:-unlimited}"
      SUMMARY_FILE="$LOG_BASE/summary.json"
      GLOBAL_ISSUES_CREATED=0 MAX_ISSUES="$budget" LOCAL_MODE=false
      FORGE_REPO_SLUG=fixture/repo REPOLENS_FINAL_STATE=finished
      mkdir -p "$LOG_BASE/polish/filed"
      : > "$LOG_BASE/posts"
      init_summary "$SUMMARY_FILE" probe "$fixture" polish mock '' 1 github ''
      printf '[{"domain":"fluency","lens_id":"spacing-consistency","title":"Spacing","body":"Concrete suggestion","voice_fit":"strong","polish_rank_x1000":1500}]\n' > "$LOG_BASE/polish/ranked-suggestions.json"
      marker="$LOG_BASE/polish/filed/fluency-spacing-consistency.url"
      reservation="${marker%.url}.attempted"
      case "$kind" in
        directory) mkdir "$marker"; printf 'private bytes\n' > "$marker/sentinel" ;;
        symlink) printf 'unrelated bytes\n' > "$LOG_BASE/outside"; ln -s "$LOG_BASE/outside" "$marker" ;;
        dangling) ln -s "$LOG_BASE/absent" "$marker" ;;
        fifo) mkfifo "$marker" ;;
      esac
      if [[ "$attempted" == yes ]]; then : > "$reservation"; fi
      rc=0
      run_polish_issue_emission probe 3 > "$LOG_BASE/emission.log" 2>&1 || rc=$?
      check test "$rc" -ne 0
      check test "$GLOBAL_ISSUES_CREATED" -eq 0
      check jq -e '.totals.issues_created == 0' "$SUMMARY_FILE"
      check test ! -s "$LOG_BASE/posts"
      case "$kind" in
        directory) check test -d "$marker"; check test "$(cat "$marker/sentinel")" = 'private bytes' ;;
        symlink) check test -L "$marker"; check test "$(cat "$LOG_BASE/outside")" = 'unrelated bytes' ;;
        dangling) check test -L "$marker"; check test ! -e "$LOG_BASE/absent" ;;
        fifo) check test -p "$marker" ;;
      esac
      if [[ "$attempted" == yes ]]; then check test -f "$reservation"; fi
      # Reconcile the original uncertain POST with a real file. It recovers one
      # success without a new POST, even with a freshly reset CLI counter.
      if [[ "$kind" == directory ]]; then rm -rf -- "$marker"; else rm -f -- "$marker"; fi
      printf 'https://github.com/fixture/repo/issues/1\n' > "$marker"
      rc=0
      run_polish_issue_emission probe 3 > "$LOG_BASE/repaired.log" 2>&1 || rc=$?
      check test "$rc" -eq 0
      check test "$GLOBAL_ISSUES_CREATED" -eq 1
      check jq -e '.totals.issues_created == 1' "$SUMMARY_FILE"
      check test ! -s "$LOG_BASE/posts"
    done
  done
done
printf 'Polish receipt objects: %s failures\n' "$failures"
(( failures == 0 ))
