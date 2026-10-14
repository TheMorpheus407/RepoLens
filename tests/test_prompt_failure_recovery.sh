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

# Keep callback failure and pending meta work authoritative across retries.
# shellcheck disable=SC2034 # Globals configure the sourced driver.
# shellcheck disable=SC2329 # The sourced driver invokes these callback stubs.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)" || exit 1
trap 'rm -rf "$TEST_DIR"' EXIT
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/rounds.sh"
passed=0 failed=0
check() {
  if "$@"; then passed=$((passed + 1)); else failed=$((failed + 1)); printf 'FAIL: %s\n' "$*"; fi
}
log_info() { :; }
log_warn() { :; }
set_stop_reason() { STOP_REASON="$2"; return 1; }
record_lens() { :; }
LENSES=(security/injection security/xss-csrf)
LOCAL_MODE=false
PARALLEL=false
RUN_ID=probe
RESUME_RUN_ID=probe
MODE=audit
AGENT=codex
PROJECT_PATH="$SCRIPT_DIR"
LENSES_DIR="$SCRIPT_DIR/prompts/lenses"
SUMMARY_FILE="$TEST_DIR/summary.json"
LOG_BASE="$TEST_DIR/callback"
mkdir -p "$LOG_BASE/.systemic-failure-abort"
completed_lenses_file="$LOG_BASE/.completed"
RUNS=0
run_lens() { RUNS=$((RUNS + 1)); return 42; }
build_round_digest() { mkdir -p "$1"; : > "$1/digest.md"; }
run_rounds 2 LENSES
check test "$?" -ne 0
check test "$RUNS" -eq 1
check test ! -e "$LOG_BASE/rounds/round-1/digest.md"
check test ! -e "$LOG_BASE/rounds/round-1/.completed"
check test "$completed_lenses_file" = "$LOG_BASE/.completed"
check test "${STOP_REASON:-}" = lens-execution-failed

# Collector errors must survive a successful sibling and require no abort file.
PARALLEL=true
init_parallel() { return 0; }
spawn_lens() { return 0; }
wait_all() { return 42; }
LOG_BASE="$TEST_DIR/collector"
mkdir -p "$LOG_BASE"
completed_lenses_file="$LOG_BASE/.completed"
run_rounds 2 LENSES
check test "$?" -ne 0
check test ! -e "$LOG_BASE/rounds/round-1/digest.md"
check test ! -e "$LOG_BASE/rounds/round-1/.completed"
check test "$completed_lenses_file" = "$LOG_BASE/.completed"

# Use the real handoff and barrier helpers with deterministic prompt/agent stubs.
PARALLEL=false
FAIL_PROMPT=true
compose_prompt() { if $FAIL_PROMPT; then return 1; fi; printf 'meta prompt'; }
run_agent() { printf 'meta\n' >> "$LOG_BASE/meta-calls"; printf 'LENS: injection\nHYPOTHESES_TO_VERIFY:\n- Follow up.\n'; }
run_lens() {
  if ! grep -qxF "$1" "$completed_lenses_file" 2>/dev/null; then
    printf '%s\n' "$CURRENT_ROUND_INDEX:$1" >> "$LOG_BASE/lens-calls"
    printf '%s\n' "$1" >> "$completed_lenses_file"
  fi
  return 0
}
# Repeat with historical premature primary/legacy markers, independently.
for legacy in none primary legacy both; do
  LOG_BASE="$TEST_DIR/meta-$legacy"
  mkdir -p "$LOG_BASE"
  completed_lenses_file="$LOG_BASE/.completed"
  FAIL_PROMPT=true
  run_rounds 2 LENSES
  check test "$?" -ne 0
  check test ! -e "$LOG_BASE/rounds/round-1/.completed"
  check test ! -e "$LOG_BASE/.rounds/round-1.completed"
  check test ! -e "$LOG_BASE/rounds/round-2/digest.md"
  check test ! -e "$LOG_BASE/meta-calls"
  check test "$(wc -l < "$LOG_BASE/lens-calls")" -eq 2
  if [[ "$legacy" == primary || "$legacy" == both ]]; then touch "$LOG_BASE/rounds/round-1/.completed"; fi
  if [[ "$legacy" == legacy || "$legacy" == both ]]; then touch "$LOG_BASE/.rounds/round-1.completed"; fi
  rm -f "$LOG_BASE/.systemic-failure-abort"
  FAIL_PROMPT=false
  run_rounds 2 LENSES
  check test "$?" -eq 0
  check test -s "$LOG_BASE/rounds/round-1/dispatch.md"
  check test -s "$LOG_BASE/rounds/round-1/hypotheses.md"
  check grep -q 'Follow up.' "${HYPOTHESES_TO_VERIFY_FILE:-missing}"
  check test -e "$LOG_BASE/rounds/round-2/.completed"
  check test -f "$LOG_BASE/meta-calls"
  if [[ -f "$LOG_BASE/meta-calls" ]]; then check test "$(wc -l < "$LOG_BASE/meta-calls")" -eq 1; fi
  check test "$(wc -l < "$LOG_BASE/lens-calls")" -eq 3
  check test "$completed_lenses_file" = "$LOG_BASE/.completed"
done
# A sibling reaped during capacity acquisition must stop a lens round before
# another callback is launched. Exercise the driver's policy with real sem_acquire.
(
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/parallel.sh"
  PARALLEL=true
  LOG_BASE="$TEST_DIR/capacity"
  mkdir -p "$LOG_BASE"
  completed_lenses_file="$LOG_BASE/.completed"
  : > "$completed_lenses_file"
  SLOT_LAUNCHES=0
  init_parallel() {
    _REPOLENS_SCOPE_FAILED=0
    _REPOLENS_WAIT_RC=0
    _REPOLENS_SEM_DIR="$1"
    _REPOLENS_MAX_PARALLEL="$2"
    mkdir -p "$_REPOLENS_SEM_DIR"
  }
  _parallel_poll_once() { _REPOLENS_WAIT_RC=42; return 0; }
  spawn_lens() {
    sem_acquire || return 1
    SLOT_LAUNCHES=$((SLOT_LAUNCHES + 1))
  }
  run_rounds 2 LENSES
  check test "$?" -ne 0
  check test "$SLOT_LAUNCHES" -eq 0
  check test ! -e "$LOG_BASE/rounds/round-1/digest.md"
  check test ! -e "$LOG_BASE/rounds/round-1/.completed"
  check test "$completed_lenses_file" = "$LOG_BASE/.completed"
  (( failed == 0 ))
)
check test "$?" -eq 0
printf 'Results: %s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
