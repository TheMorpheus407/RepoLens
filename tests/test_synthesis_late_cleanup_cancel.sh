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

# repolens-r13-p5-1: keep rollback data until a replacement is published.
# shellcheck disable=SC2034,SC2329 # Sourced phase consumes globals/callbacks.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO/lib/synthesize.sh"
FIXTURE="$(mktemp -d)"
trap 'command rm -rf -- "$FIXTURE"' EXIT
for phase in cleanup after-retire; do
  for inventory in empty nonempty; do
    (
      LOG_BASE="$FIXTURE/$phase-$inventory/run"
      AGENT=mock MODE=bugreport PROJECT_PATH="$FIXTURE/project"
      mkdir -p "$PROJECT_PATH" "$LOG_BASE/rounds/round-1/lens-outputs" "$LOG_BASE/final"
      printf '[{"cluster_id":"saved","title":"Saved result"}]\n' > "$LOG_BASE/final/manifest.json"
      printf '[{"type":"comment","body":"Saved action"}]\n' > "$LOG_BASE/final/cross-link-actions.preserved.json"
      manifest_hash="$(sha256sum < "$LOG_BASE/final/manifest.json")"
      actions_hash="$(sha256sum < "$LOG_BASE/final/cross-link-actions.preserved.json")"
      if [[ "$inventory" == nonempty ]]; then printf 'Current evidence\n' > "$LOG_BASE/rounds/round-1/lens-outputs/current.md"; fi
      REPOLENS_FINAL_STATE=finished REPOLENS_INTERRUPT_EXIT_CODE=143
      trap 'REPOLENS_FINAL_STATE=interrupted; REPOLENS_INTERRUPT_EXIT_CODE=143' TERM
      compose_prompt() { printf 'mock prompt\n'; }
      run_agent() {
        printf '%s\n' "$REPOLENS_FINAL_STATE" >> "$LOG_BASE/admitted"
        [[ "$REPOLENS_FINAL_STATE" != interrupted ]] || return 99
        # Original output remains recoverable throughout model work.
        test -n "$(find "$LOG_BASE/final" -path '*/.synthesis-cleanup.*/manifest.json' -print)" || return 98
        printf '[]\n'
      }
      rm() {
        command rm "$@" || return $?
        if [[ "$phase" == cleanup && "${1:-}" == -rf && "${2:-}" == -- && "${3:-}" == "$LOG_BASE/final/.synthesis-cleanup."* ]]; then
          kill -TERM "$BASHPID"
        fi
      }
      if [[ "$phase" == after-retire ]]; then
        original_retire="$(declare -f _synthesize_retire_saved_results)"
        eval "${original_retire/_synthesize_retire_saved_results/_original_retire_saved_results}"
        _synthesize_retire_saved_results() {
          _original_retire_saved_results "$@" || return $?
          kill -TERM "$BASHPID"
          return 0
        }
      fi
      rc=0
      run_synthesizer late-cleanup > "$LOG_BASE/phase.log" 2>&1 || rc=$?
      printf '%s/%s: state=%s exit=%s (expected 143)\n' "$phase" "$inventory" "$REPOLENS_FINAL_STATE" "$rc"
      test "$rc" -eq 143
      test "$REPOLENS_FINAL_STATE" = interrupted
      if [[ "$phase" == after-retire ]]; then
        test "$(sha256sum < "$LOG_BASE/final/manifest.json")" = "$manifest_hash"
        test "$(sha256sum < "$LOG_BASE/final/cross-link-actions.preserved.json")" = "$actions_hash"
        test ! -e "$LOG_BASE/admitted"
      else
        # Cleanup is now after a validated replacement, which remains usable.
        test "$(cat "$LOG_BASE/final/manifest.json")" = '[]'
        test ! -e "$LOG_BASE/final/cross-link-actions.preserved.json"
        if [[ "$inventory" == empty ]]; then test ! -e "$LOG_BASE/admitted"
        else test "$(cat "$LOG_BASE/admitted")" = finished; fi
      fi
      test -z "$(find "$LOG_BASE/final" -name '.synthesis-cleanup.*' -print)"
    )
  done
done
(
  LOG_BASE="$FIXTURE/failed-retry/run" AGENT=mock MODE=bugreport PROJECT_PATH="$FIXTURE/project"
  REPOLENS_FINAL_STATE=finished
  mkdir -p "$LOG_BASE/rounds/round-1/lens-outputs" "$LOG_BASE/final"
  printf 'Current evidence\n' > "$LOG_BASE/rounds/round-1/lens-outputs/current.md"
  printf '[{"cluster_id":"saved"}]\n' > "$LOG_BASE/final/manifest.json"
  printf '[{"type":"comment","body":"saved"}]\n' > "$LOG_BASE/final/cross-link-actions.preserved.json"
  manifest_hash="$(sha256sum < "$LOG_BASE/final/manifest.json")"
  actions_hash="$(sha256sum < "$LOG_BASE/final/cross-link-actions.preserved.json")"
  compose_prompt() { printf 'mock prompt\n'; }
  run_agent() { return 99; }
  rc=0
  run_synthesizer failed-retry > "$LOG_BASE/failed.log" 2>&1 || rc=$?
  test "$rc" -ne 0
  recovery="$(find "$LOG_BASE/final" -name '.synthesis-cleanup.*' -type d -print)"
  test -n "$recovery"
  test "$(sha256sum < "$recovery/manifest.json")" = "$manifest_hash"
  test "$(sha256sum < "$recovery/cross-link-actions.preserved.json")" = "$actions_hash"
  grep -Fq "saved results retained under $recovery" "$LOG_BASE/failed.log"
  run_agent() { printf '[]\n'; }
  run_synthesizer failed-retry || exit 1
  test "$(cat "$LOG_BASE/final/manifest.json")" = '[]'
  test -z "$(find "$LOG_BASE/final" -name '.synthesis-cleanup.*' -print)"
)
printf 'PASS: late cancellation never admits work after interruption or destroys the last recoverable result.\n'
