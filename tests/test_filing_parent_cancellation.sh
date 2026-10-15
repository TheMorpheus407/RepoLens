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

# repolens-r3-p2-1: the production dispatcher must observe parent cancellation.
# shellcheck disable=SC2034,SC2329 # Extracted production code consumes fixtures.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$(mktemp -d /tmp/repolens-r3p2.XXXXXX)"
trap 'rc=$?; rm -rf -- "$FIXTURE"; exit "$rc"' EXIT
export TMPDIR="$FIXTURE"
source "$REPO/lib/parallel.sh"
source "$REPO/tests/process_scope_test_support.sh"
require_process_scopes
source "$REPO/lib/filing.sh"
source "$REPO/lib/summary.sh"
eval "$(sed -n '/^rate_limit_sleep_interrupt_marker() {/,/^_handle_hangup() {/p' "$REPO/repolens.sh" | sed '$d')"
# Suppress routine production diagnostics in this signal fixture.
log_info() { :; }
# Let the worker observe that the returning parent trap completed cleanup.
log_warn() {
  if [[ "$*" == 'Stopped 0 children'* ]]; then
    printf 'parent acknowledged cancellation\n' > "$LOG_BASE/parent-cancelled"
  fi
}
LOG_BASE="$FIXTURE/run"
SUMMARY_FILE="$LOG_BASE/summary.json"
mkdir -p "$LOG_BASE/final/filed"
printf '{"stopped_reason":null}\n' > "$SUMMARY_FILE"
printf '[{"cluster_id":"c1"},{"cluster_id":"c2"}]\n' > "$LOG_BASE/final/manifest.json"
RUN_ID=probe LOCAL_MODE=false MODE=branch-review ROUNDS=1 PARALLEL=true MAX_PARALLEL=1
RUN_HEALTH=ok REPOLENS_FINAL_STATE=finished REPOLENS_INTERRUPT_EXIT_CODE=130 RUN_ROUNDS_RC=0
SIGNAL_PARENT_PID="$BASHPID"
# Reuse the prepared manifest without launching a model.
run_synthesizer() { return 0; }
# The first callback cancels the parent; any later admission leaves evidence.
mock_filing() {
  local cid="$2" i
  if [[ "$cid" == c1 ]]; then
    printf 'c1 started before cancellation\n' >> "$LOG_BASE/calls"
    kill -TERM "$SIGNAL_PARENT_PID"
    for ((i=0; i<500; i++)); do
      [[ ! -e "$LOG_BASE/parent-cancelled" ]] || break
      sleep 0.01
    done
    test -e "$LOG_BASE/parent-cancelled" || return 9
  else
    test -e "$LOG_BASE/parent-cancelled" || return 10
    printf 'c2 started AFTER acknowledged cancellation\n' >> "$LOG_BASE/calls"
  fi
  printf 'mock-success\n' > "$LOG_BASE/final/filed/$cid.url"
  rm -f "$LOG_BASE/final/filed/$cid.lock"
}
_FILING_AGENT_CALLBACK=mock_filing
init_parallel "$LOG_BASE/.semaphore" 1 || exit 1
# Execute the unchanged production synthesis / filing orchestration.
# shellcheck source=/dev/null
source <(sed -n '/^# --- Synthesizer (post-rounds, post-verifier) ---/,/^# --- Finalize ---/p' "$REPO/repolens.sh")
printf 'master=%s\n' "$(git -C "$REPO" rev-parse HEAD)"
printf 'parent state=%s; exit=%s\n' "$REPOLENS_FINAL_STATE" "$(resolve_run_exit_code)"
cat "$LOG_BASE/calls"
[[ "$REPOLENS_FINAL_STATE" == interrupted ]] || exit 1
[[ "$(resolve_run_exit_code)" == 143 ]] || exit 1
if [[ -e "$LOG_BASE/final/filed/c2.url" || -e "$LOG_BASE/final/filed/c2.lock" ]]; then
  printf 'FAIL: second callback admitted or its reservation retained after cancellation.\n'
  exit 1
fi
printf 'PASS: parent cancellation prevents admission of the second filing callback.\n'
