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
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || fail 'resolve repository'
FIXTURE="$(mktemp -d)" || fail 'create fixture'
trap 'rm -rf -- "$FIXTURE"' EXIT
source "$ROOT/lib/filing.sh" || fail 'load filing helpers'
source "$ROOT/lib/summary.sh" || fail 'load summary helpers'
set -euo pipefail
# Extract the actual caller once; fail if its boundaries disappear.
sed -n '/^# --- Synthesizer (post-rounds, post-verifier) ---/,/^# --- Finalize ---/p' "$ROOT/repolens.sh" \
  | sed '$d' > "$FIXTURE/orchestration.sh" || fail 'extract orchestration'
[[ -s "$FIXTURE/orchestration.sh" ]] || fail 'missing orchestration block'
faults=("$@")
if (( ${#faults[@]} == 0 )); then
  faults=(none empty length partial_length ids partial_ids completion partial_completion)
fi

for fault in "${faults[@]}"; do
  (
    export LOG_BASE="$FIXTURE/$fault" RUN_ID=probe MODE=bugreport ROUNDS=2 LOCAL_MODE=false
    PARALLEL=false CROSS_LINK_MODE=off REPOLENS_FINAL_STATE=finished RUN_ROUNDS_RC=0
    MAX_ISSUES='' SUMMARY_FILE="$LOG_BASE/summary.json"
    mkdir -p "$LOG_BASE/final" || fail 'create run directory'
    printf '[{"cluster_id":"c1"},{"cluster_id":"c2"}]\n' > "$LOG_BASE/final/manifest.json" || fail 'write manifest'
    if [[ "$fault" == empty ]]; then
      printf '[]\n' > "$LOG_BASE/final/manifest.json" || fail 'write empty manifest'
    fi
    printf '{"stopped_reason":null}\n' > "$SUMMARY_FILE" || fail 'write summary'
    _FILING_AGENT_CALLBACK=mock_filing
    mock_filing() {
      printf '%s\n' "$2" >> "$LOG_BASE/callbacks" || fail 'record callback'
      printf 'mock-url\n' > "$LOG_BASE/final/filed/$2.url" || fail 'write success receipt'
    }
    run_synthesizer() { return 0; }
    log_info() { printf 'INFO %s\n' "$*"; }
    log_warn() { printf 'WARN %s\n' "$*"; }
    # Simulate jq failing both before and after it emits plausible output.
    jq() {
      if [[ "$1" == length && ( "$fault" == length || "$fault" == partial_length ) ]]; then
        [[ "$fault" != partial_length ]] || printf '0\n'
        return 74
      fi
      if [[ "$*" == '-r .[].cluster_id '* ]]; then
        if [[ "$fault" == ids || "$fault" == partial_ids ||
              ( ( "$fault" == completion || "$fault" == partial_completion ) && -f "$LOG_BASE/callbacks" ) ]]; then
          [[ "$fault" != partial_ids && "$fault" != partial_completion ]] || printf 'c1\n'
          return 74
        fi
      fi
      command jq "$@"
    }
    if [[ "$fault" == length || "$fault" == partial_length || "$fault" == ids || "$fault" == partial_ids ]]; then
      if dispatch_filing_batch "$RUN_ID" > "$LOG_BASE/direct.log" 2>&1; then
        printf 'FAIL: dispatcher accepted %s read failure\n' "$fault"; exit 1
      fi
      [[ ! -e "$LOG_BASE/callbacks" ]] || fail "$fault dispatched a callback"
    fi
    # Exercise the actual caller's completion check as well as the dispatcher.
    # shellcheck source=/dev/null
    source "$FIXTURE/orchestration.sh"
    if [[ "$fault" == none || "$fault" == empty ]]; then
      [[ "$RUN_ROUNDS_RC" == 0 && "$REPOLENS_FINAL_STATE" == finished ]] || fail "$fault control failed"
      if [[ "$fault" == empty ]]; then
        [[ ! -e "$LOG_BASE/callbacks" ]] || fail 'empty manifest dispatched a callback'
      else
        [[ "$(cat "$LOG_BASE/callbacks")" == $'c1\nc2' ]] || fail 'control did not dispatch both clusters once'
      fi
    else
      [[ "$RUN_ROUNDS_RC" != 0 && "$REPOLENS_FINAL_STATE" == failed ]] || {
        printf 'FAIL: %s read failure was accepted\n' "$fault"; exit 1;
      }
      [[ "$(command jq -r .stopped_reason "$SUMMARY_FILE")" == filing-failed ]] || fail "$fault lost stop reason"
      if [[ "$fault" != completion && "$fault" != partial_completion ]]; then
        [[ ! -e "$LOG_BASE/callbacks" ]] || fail "$fault dispatched a callback"
      fi
      # Repair the read and retry the same saved batch. Completion failures
      # retain both receipts, so recovery must not repeat either callback.
      failed_fault="$fault"
      fault=none RUN_ROUNDS_RC=0 REPOLENS_FINAL_STATE=finished
      # shellcheck source=/dev/null
      source "$FIXTURE/orchestration.sh"
      [[ "$RUN_ROUNDS_RC" == 0 && "$REPOLENS_FINAL_STATE" == finished ]] || fail "$failed_fault retry failed"
      [[ "$(cat "$LOG_BASE/callbacks")" == $'c1\nc2' ]] || fail "$failed_fault retry skipped or repeated callbacks"
      [[ "$(command jq -r .stopped_reason "$SUMMARY_FILE")" == null ]] || fail "$failed_fault retry retained stop reason"
      fault="$failed_fault"
    fi
    printf 'PASS: %s\n' "$fault"
  )
done
printf 'Results: manifest read failures remain retryable\n'
