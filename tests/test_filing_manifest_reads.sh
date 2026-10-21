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

# Manifest read failures must never become a successful empty filing batch.
# shellcheck disable=SC2030,SC2031,SC2329
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
source "$ROOT/lib/filing.sh"
set -euo pipefail

for fault in none length ids partial_ids completion; do
  (
    export LOG_BASE="$FIXTURE/$fault" RUN_ID=probe MODE=bugreport ROUNDS=2 LOCAL_MODE=false
    PARALLEL=false CROSS_LINK_MODE=off REPOLENS_FINAL_STATE=finished RUN_ROUNDS_RC=0
    MAX_ISSUES='' SUMMARY_FILE="$LOG_BASE/summary.json"
    mkdir -p "$LOG_BASE/final"
    printf '[{"cluster_id":"c1"},{"cluster_id":"c2"}]\n' > "$LOG_BASE/final/manifest.json"
    printf '{"stopped_reason":null}\n' > "$SUMMARY_FILE"
    _FILING_AGENT_CALLBACK=mock_filing
    mock_filing() {
      printf '%s\n' "$2" >> "$LOG_BASE/callbacks"
      printf 'mock-url\n' > "$LOG_BASE/final/filed/$2.url"
    }
    run_synthesizer() { return 0; }
    log_info() { printf 'INFO %s\n' "$*"; }
    log_warn() { printf 'WARN %s\n' "$*"; }
    set_stop_reason() { printf '%s\n' "$2" > "$LOG_BASE/stop-reason"; }
    clear_stop_reason() { :; }
    jq() {
      if [[ "$1" == length && "$fault" == length ]]; then return 74; fi
      if [[ "$*" == '-r .[].cluster_id '* ]]; then
        if [[ "$fault" == ids || "$fault" == partial_ids ||
              ( "$fault" == completion && -f "$LOG_BASE/callbacks" ) ]]; then
          [[ "$fault" != partial_ids ]] || printf 'c1\n'
          return 74
        fi
      fi
      command jq "$@"
    }
    if [[ "$fault" == length || "$fault" == ids || "$fault" == partial_ids ]]; then
      if dispatch_filing_batch "$RUN_ID" > "$LOG_BASE/direct.log" 2>&1; then
        printf 'FAIL: dispatcher accepted %s read failure\n' "$fault"; exit 1
      fi
      [[ ! -e "$LOG_BASE/callbacks" ]]
    fi
    # Exercise the actual caller's completion check as well as the dispatcher.
    # shellcheck disable=SC1090
    source <(sed -n '/^# --- Synthesizer (post-rounds, post-verifier) ---/,/^# --- Finalize ---/p' "$ROOT/repolens.sh" | sed '$d')
    if [[ "$fault" == none ]]; then
      [[ "$RUN_ROUNDS_RC" == 0 && "$REPOLENS_FINAL_STATE" == finished ]]
      [[ "$(wc -l < "$LOG_BASE/callbacks")" == 2 ]]
    else
      [[ "$RUN_ROUNDS_RC" != 0 && "$REPOLENS_FINAL_STATE" == failed ]] || {
        printf 'FAIL: %s read failure was accepted\n' "$fault"; exit 1;
      }
      [[ "$(cat "$LOG_BASE/stop-reason")" == filing-failed ]]
      if [[ "$fault" != completion ]]; then [[ ! -e "$LOG_BASE/callbacks" ]]; fi
    fi
    printf 'PASS: %s\n' "$fault"
  )
done
printf 'Results: manifest read failures remain retryable\n'
