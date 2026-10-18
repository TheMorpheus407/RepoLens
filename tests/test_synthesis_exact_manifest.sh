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

# Verify both publication paths reject a directory appearing after retirement.
# shellcheck disable=SC2034,SC2329 # Production callbacks consume these globals.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO/lib/synthesize.sh"
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
# Keep the real snapshot/retirement implementation; inject only its race window.
eval "$(declare -f _synthesize_retire_saved_results | sed '1s/_synthesize_retire_saved_results/_real_retire_saved_results/')"
for inventory in model empty; do
  for obstruction in directory symlink; do
    (
      LOG_BASE="$FIXTURE/$inventory-$obstruction/run"
      PROJECT_PATH="$FIXTURE/project" AGENT=mock MODE=bugreport
      REPOLENS_FINAL_STATE=finished fault=true
      mkdir -p "$LOG_BASE/final" "$LOG_BASE/rounds/round-1/lens-outputs" "$PROJECT_PATH" "$LOG_BASE/foreign"
      printf '[{"cluster_id":"saved","title":"Previous publication"}]\n' > "$LOG_BASE/final/manifest.json"
      saved_hash="$(sha256sum < "$LOG_BASE/final/manifest.json")"
      if [[ "$inventory" == model ]]; then
        printf 'Current evidence\n' > "$LOG_BASE/rounds/round-1/lens-outputs/current.md"
      fi
      # Deterministic filesystem obstruction after the old path is retired.
      obstruct() {
        [[ "$fault" == true ]] || return 0
        test ! -e "$LOG_BASE/final/manifest.json"
        if [[ "$obstruction" == directory ]]; then
          mkdir "$LOG_BASE/final/manifest.json"
        else
          ln -s "$LOG_BASE/foreign" "$LOG_BASE/final/manifest.json"
        fi
        touch "$LOG_BASE/reached"
      }
      _synthesize_retire_saved_results() {
        _real_retire_saved_results "$@" || return $?
        if [[ "$inventory" == empty ]]; then obstruct; fi
      }
      compose_prompt() { printf 'Mock synthesis prompt\n'; }
      # Valid empty response exercises actual validation and normal publication.
      run_agent() { obstruct || return $?; printf '[]\n'; }
      rc=0
      run_synthesizer probe > "$LOG_BASE/attempt.log" 2>&1 || rc=$?
      test -f "$LOG_BASE/reached"
      printf '%s/%s: synthesis exit=%s\n' "$inventory" "$obstruction" "$rc"
      test "$rc" -ne 0
      test -d "$LOG_BASE/final/manifest.json"
      test -z "$(find -H "$LOG_BASE/final/manifest.json" -type f -print)"
      test -z "$(find "$LOG_BASE/foreign" -type f -print)"
      recovered=false
      for backup in "$LOG_BASE/final"/.synthesis-cleanup.*/manifest.json; do
        [[ -f "$backup" ]] || continue
        test "$(sha256sum < "$backup")" = "$saved_hash"
        recovered=true
      done
      test "$recovered" = true
      # Repair the obstruction and retry: only a real publication retires backups.
      if [[ "$obstruction" == directory ]]; then
        rmdir "$LOG_BASE/final/manifest.json"
      else
        rm "$LOG_BASE/final/manifest.json"
      fi
      fault=false
      run_synthesizer probe
      test -f "$LOG_BASE/final/manifest.json"
      test ! -L "$LOG_BASE/final/manifest.json"
      test "$(cat "$LOG_BASE/final/manifest.json")" = '[]'
      test -z "$(find "$LOG_BASE/final" -name '.synthesis-cleanup.*' -print)"
    )
  done
done
printf 'PASS: exact manifest publication and recovery on both paths\n'
