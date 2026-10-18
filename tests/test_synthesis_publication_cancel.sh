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

# Exercise publication and recovery boundaries with returning signal handlers.
# shellcheck disable=SC2034,SC2329 # Production callbacks consume these globals.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO/lib/synthesize.sh"
FIXTURE="$(mktemp -d)"
trap 'command rm -rf -- "$FIXTURE"' EXIT

for scenario in branch-agent branch-agent-success failure-report staged-actions staged-report post-publish-empty post-publish-model cleanup-error; do
  [[ -z "${TEST_CASE:-}" || "$TEST_CASE" == "$scenario" ]] || continue
  for prior in present absent; do
    (
      LOG_BASE="$FIXTURE/$scenario-$prior"
      PROJECT_PATH="$FIXTURE/project" AGENT=mock MODE=bugreport
      BRANCH_SCOPE_FILE="$LOG_BASE/scope.json"
      REPOLENS_FINAL_STATE=finished REPOLENS_INTERRUPT_EXIT_CODE=143
      trap 'REPOLENS_FINAL_STATE=interrupted' TERM
      mkdir -p "$LOG_BASE/final" "$LOG_BASE/rounds/round-1/lens-outputs" "$PROJECT_PATH/src"
      printf 'source\n' > "$PROJECT_PATH/src/probe.sh"
      printf '["src/probe.sh"]\n' > "$BRANCH_SCOPE_FILE"
      if [[ "$prior" == present ]]; then
        printf '[{"cluster_id":"saved"}]\n' > "$LOG_BASE/final/manifest.json"
        printf '[{"body":"saved action"}]\n' > "$LOG_BASE/final/cross-link-actions.preserved.json"
        manifest_hash="$(sha256sum < "$LOG_BASE/final/manifest.json")"
        actions_hash="$(sha256sum < "$LOG_BASE/final/cross-link-actions.preserved.json")"
      fi
      if [[ "$scenario" != post-publish-empty && "$scenario" != cleanup-error ]]; then
        printf 'src/probe.sh:1\n' > "$LOG_BASE/rounds/round-1/lens-outputs/current.md"
      fi
      if [[ "$scenario" == branch-agent* ]]; then MODE=branch-review; fi
      if [[ "$scenario" == staged-* ]]; then REPOLENS_MIN_SEVERITY=high CROSS_LINK_MODE=comment; fi
      compose_prompt() { printf 'mock prompt\n'; }
      # Cancel inside model work; its nonzero exit must still restore publication.
      run_agent() {
        if [[ "$scenario" == branch-agent ]]; then kill -TERM "$BASHPID"; return 99; fi
        if [[ "$scenario" == branch-agent-success ]]; then kill -TERM "$BASHPID"; fi
        if [[ "$scenario" == failure-report ]]; then return 99; fi
        if [[ "$scenario" == staged-* ]]; then
          printf '%s\n' '[{"cluster_id":"low","severity":"low","source_finding_paths":["current.md"],"cross_link_actions":[{"type":"comment","issue_number":9,"body":"Staged action"}]}]'
          return 0
        fi
        printf '[]\n'
      }
      # Deliver TERM after the generator's first interruption check has passed.
      echo() {
        builtin echo "$@"
        if [[ ( "$scenario" == failure-report || "$scenario" == staged-report ) && "$*" == *'saved results retained under '* ]]; then
          kill -TERM "$BASHPID"
        fi
      }
      # Use the real severity filter to stage an action, then cancel between
      # its promotion and manifest publication, or during failure reporting.
      mv() {
        if [[ "$scenario" == staged-report && "${2:-}" == "$LOG_BASE/final/manifest.json" ]]; then return 42; fi
        command mv "$@" || return $?
        if [[ "$scenario" == staged-* && "${2:-}" == "$LOG_BASE/final/cross-link-actions.preserved.json" ]]; then
          jq -e 'length == 1 and .[0].body == "Staged action"' "$2" > "$LOG_BASE/staged" || return 98
          if [[ "$scenario" == staged-actions ]]; then kill -TERM "$BASHPID"; fi
        fi
      }
      # Inject cancellation after publication but before the generator returns,
      # or fail obsolete backup deletion without changing the current result.
      rm() {
        if [[ "$scenario" == cleanup-error && "$*" == *'/.synthesis-cleanup.'* ]]; then return 42; fi
        command rm "$@" || return $?
        if [[ "$scenario" == post-publish-* && "$*" == *'/manifest.scope-pending.json'* ]]; then
          kill -TERM "$BASHPID"
        fi
      }
      rc=0
      run_synthesizer probe > "$LOG_BASE/phase.log" 2>&1 || rc=$?
      printf '%s/%s: state=%s exit=%s\n' "$scenario" "$prior" "$REPOLENS_FINAL_STATE" "$rc"
      if [[ "$scenario" == cleanup-error ]]; then
        test "$rc" -eq 0
        grep -Fq 'cannot remove recovery directory:' "$LOG_BASE/phase.log"
        test -n "$(find "$LOG_BASE/final" -name '.synthesis-cleanup.*' -print)"
      else
        test "$rc" -eq 143
        test "$REPOLENS_FINAL_STATE" = interrupted
      fi
      if [[ "$scenario" == branch-agent* || "$scenario" == failure-report || "$scenario" == staged-* ]]; then
        if [[ "$prior" == present ]]; then
          test "$(sha256sum < "$LOG_BASE/final/manifest.json")" = "$manifest_hash"
          test "$(sha256sum < "$LOG_BASE/final/cross-link-actions.preserved.json")" = "$actions_hash"
        else
          test ! -e "$LOG_BASE/final/manifest.json"
          test ! -e "$LOG_BASE/final/cross-link-actions.preserved.json"
        fi
      else
        test "$(cat "$LOG_BASE/final/manifest.json")" = '[]'
        test ! -e "$LOG_BASE/final/cross-link-actions.preserved.json"
      fi
      if [[ "$scenario" == staged-* ]]; then
        test -s "$LOG_BASE/staged"
        test -z "$(find "$LOG_BASE/final" -name '.synthesis-cleanup.*' -print)"
        scenario=repaired REPOLENS_FINAL_STATE=finished
        run_synthesizer probe || exit 1
        test "$(cat "$LOG_BASE/final/manifest.json")" = '[]'
        test ! -e "$LOG_BASE/final/cross-link-actions.preserved.json"
        test -z "$(find "$LOG_BASE/final" -name '.synthesis-cleanup.*' -print)"
      fi
    )
  done
done
printf 'PASS: publication and interruption recovery boundaries\n'
