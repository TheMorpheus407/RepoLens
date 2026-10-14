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

# Signal cleanup success must still stop the real round driver and collector.
# shellcheck disable=SC2034,SC2329 # Globals and callbacks consumed by sourced libraries.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)" || exit 1
trap 'rm -rf "$TEST_DIR"' EXIT
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/rounds.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/parallel.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/summary.sh"
passed=0 failed=0
check() {
  if "$@"; then passed=$((passed + 1)); else failed=$((failed + 1)); printf 'FAIL: %s\n' "$*"; fi
}
log_info() { :; }
log_warn() { :; }
record_lens() { :; }
is_lens_completed() { return 1; }
parallel_preflight() { _REPOLENS_SCOPE_READY=1; return 0; }
_scope_terminate_batch() {
  local i
  for i in "${!_REPOLENS_CHILD_PIDS[@]}"; do _REPOLENS_SCOPE_BATCH_RESULTS[i]=0; done
}
_scope_destroy() { return 0; }
sem_token_remove() { :; }
spawn_lens() {
  SPAWNS=$((SPAWNS + 1))
  (exit 42) &
  _REPOLENS_CHILD_PIDS+=("$!")
  _REPOLENS_CHILD_LENS_IDS+=("$1")
  _REPOLENS_CHILD_STARTED_AT+=("$SECONDS")
  if [[ "$MOMENT" == spawn ]]; then interrupt_now; fi
  return 0
}
interrupt_now() {
  if [[ "$SENTINEL" != none ]]; then printf '%s\n' "$SENTINEL" > "$LOG_BASE/.systemic-failure-abort"; fi
  kill -s "$SIGNAL" "$BASHPID"
}
_parallel_poll_once() {
  if [[ "$MOMENT" == collect && "$REPOLENS_FINAL_STATE" != interrupted ]]; then interrupt_now; fi
  _REPOLENS_SCOPE_REMAINING=0
}
build_round_digest() { DIGESTS=$((DIGESTS + 1)); if [[ "$MOMENT" == digest ]]; then interrupt_now; fi; return 0; }
run_meta_orchestrator() { METAS=$((METAS + 1)); if [[ "$MOMENT" == meta ]]; then interrupt_now; fi; return 0; }
mark_round_completed() { BARRIERS=$((BARRIERS + 1)); return 0; }
PARALLEL=true LOCAL_MODE=false RUN_ID=signal-probe RESUME_RUN_ID=signal-probe
LENSES=(security/injection security/xss-csrf)
for SIGNAL in INT TERM; do
  for MOMENT in collect spawn digest meta; do
    for SENTINEL in none prompt-render-failed; do
      for ROUNDS in 1 2; do
        if [[ "$MOMENT" == meta && "$ROUNDS" == 1 ]]; then continue; fi
        LOG_BASE="$TEST_DIR/$SIGNAL-$MOMENT-$SENTINEL-$ROUNDS"
        mkdir -p "$LOG_BASE"
        SUMMARY_FILE="$LOG_BASE/summary.json"
        printf '{"stopped_reason":null}\n' > "$SUMMARY_FILE"
        completed_lenses_file="$LOG_BASE/original.completed"
        REPOLENS_FINAL_STATE=finished
        _REPOLENS_SCOPE_FAILED=0
        SPAWNS=0 DIGESTS=0 METAS=0 BARRIERS=0
        run_rounds "$ROUNDS" LENSES
        rc=$?
        check test "$rc" -ne 0
        check test "$REPOLENS_FINAL_STATE" = interrupted
        expected_digests=0 expected_metas=0
        if [[ "$MOMENT" == digest || "$MOMENT" == meta ]]; then expected_digests=1; fi
        if [[ "$MOMENT" == meta ]]; then expected_metas=1; fi
        check test "$DIGESTS" -eq "$expected_digests"
        check test "$METAS" -eq "$expected_metas"
        check test "$BARRIERS" -eq 0
        expected=interrupted-sigint
        if [[ "$SIGNAL" == TERM ]]; then expected=interrupted-sigterm; fi
        check test "$(jq -r '.stopped_reason' "$SUMMARY_FILE")" = "$expected"
        check test "$completed_lenses_file" = "$LOG_BASE/original.completed"
        check test "${#_REPOLENS_CHILD_PIDS[@]}" -eq 0
        if [[ "$MOMENT" == spawn ]]; then check test "$SPAWNS" -eq 1; fi
        trap - INT TERM
      done
    done
  done
done
# A signal received while waiting for capacity must refuse a new callback too.
LOG_BASE="$TEST_DIR/capacity"
mkdir -p "$LOG_BASE/semaphore"
_REPOLENS_SEM_DIR="$LOG_BASE/semaphore"
_REPOLENS_MAX_PARALLEL=1
_REPOLENS_SCOPE_FAILED=0 _REPOLENS_WAIT_RC=0
REPOLENS_FINAL_STATE=finished
_parallel_poll_once() { REPOLENS_FINAL_STATE=interrupted; return 0; }
sem_acquire
check test "$?" -ne 0
printf 'Results: %s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
