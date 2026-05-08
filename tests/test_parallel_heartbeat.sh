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

# Regression tests for issue #118: wait_all emits a periodic heartbeat
# naming currently running parallel children and their elapsed runtime.
#
# No AI models are invoked. Tests source lib/parallel.sh directly and use
# synthetic sleep-only callbacks.

# shellcheck disable=SC2329  # cb_* callbacks are invoked indirectly via spawn_lens string dispatch.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/parallel.sh"

PASS=0
FAIL=0
TOTAL=0

TMPROOT="$SCRIPT_DIR/logs/test_parallel_heartbeat.$$.$RANDOM"
mkdir -p "$TMPROOT"
trap 'rm -rf "$TMPROOT"' EXIT

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (expected='$expected' actual='$actual')"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (missing '$needle')"
    printf '%s\n' "$haystack" | sed 's/^/    /'
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (unexpected '$needle')"
    printf '%s\n' "$haystack" | sed 's/^/    /'
  fi
}

assert_matches() {
  local desc="$1" regex="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" =~ $regex ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (missing pattern '$regex')"
    printf '%s\n' "$haystack" | sed 's/^/    /'
  fi
}

fresh_sem() {
  local case_dir max_parallel="${1:-8}"
  case_dir="$TMPROOT/sem.$RANDOM.$RANDOM"
  mkdir -p "$case_dir"
  init_parallel "$case_dir" "$max_parallel"
}

run_wait_all_capture() {
  local output_file="$1"
  wait_all >"$output_file" 2>&1
}

cb_sleep() {
  sleep "$1"
}

echo "=== parallel.sh heartbeat status (issue #118) ==="

# ---------------------------------------------------------------------------
# 1. Two long-running children: wait_all emits a heartbeat with both full
#    lens ids and elapsed seconds.
# ---------------------------------------------------------------------------
fresh_sem
REPOLENS_HEARTBEAT_INTERVAL=1
export REPOLENS_HEARTBEAT_INTERVAL
spawn_lens "slow/a" cb_sleep 3
spawn_lens "slow/b" cb_sleep 3
output_file="$TMPROOT/two-child.out"
run_wait_all_capture "$output_file"
wait_rc=$?
output="$(cat "$output_file")"

assert_eq "Two-child heartbeat: wait_all succeeds" "0" "$wait_rc"
assert_contains "Two-child heartbeat: heartbeat label emitted" "[heartbeat]" "$output"
assert_contains "Two-child heartbeat: first lens id listed" "slow/a" "$output"
assert_contains "Two-child heartbeat: second lens id listed" "slow/b" "$output"
assert_matches "Two-child heartbeat: elapsed seconds shown" "slow/a \\([0-9]+s\\)" "$output"
assert_eq "Two-child heartbeat: child PIDs cleared" "0" "${#_REPOLENS_CHILD_PIDS[@]}"
assert_eq "Two-child heartbeat: child lens ids cleared" "0" "${#_REPOLENS_CHILD_LENS_IDS[@]}"
assert_eq "Two-child heartbeat: child start times cleared" "0" "${#_REPOLENS_CHILD_STARTED_AT[@]}"
unset REPOLENS_HEARTBEAT_INTERVAL

# ---------------------------------------------------------------------------
# 2. Full semaphore: a blocked third spawn_lens emits heartbeat output before
#    control can reach wait_all.
# ---------------------------------------------------------------------------
fresh_sem 2
REPOLENS_HEARTBEAT_INTERVAL=1
export REPOLENS_HEARTBEAT_INTERVAL
spawn_lens "blocked/a" cb_sleep 5
spawn_lens "blocked/b" cb_sleep 5
output_file="$TMPROOT/blocked-spawn.out"
spawn_lens "blocked/c" cb_sleep 1 >"$output_file" 2>&1
spawn_rc=$?
output="$(cat "$output_file")"

assert_eq "Blocked spawn path: third spawn_lens eventually succeeds" "0" "$spawn_rc"
assert_contains "Blocked spawn path: heartbeat emitted before wait_all" "[heartbeat]" "$output"
assert_contains "Blocked spawn path: first held slot listed" "blocked/a" "$output"
assert_contains "Blocked spawn path: second held slot listed" "blocked/b" "$output"
assert_not_contains "Blocked spawn path: blocked child is not listed before spawn" "blocked/c" "$output"

output_file="$TMPROOT/blocked-spawn-wait-all.out"
run_wait_all_capture "$output_file"
wait_rc=$?
assert_eq "Blocked spawn path: wait_all succeeds after blocked spawn" "0" "$wait_rc"
unset REPOLENS_HEARTBEAT_INTERVAL

# ---------------------------------------------------------------------------
# 3. Single running child: heartbeat output is suppressed as noise.
# ---------------------------------------------------------------------------
fresh_sem
REPOLENS_HEARTBEAT_INTERVAL=1
export REPOLENS_HEARTBEAT_INTERVAL
spawn_lens "single/a" cb_sleep 2
output_file="$TMPROOT/single-child.out"
run_wait_all_capture "$output_file"
wait_rc=$?
output="$(cat "$output_file")"

assert_eq "Single-child path: wait_all succeeds" "0" "$wait_rc"
assert_not_contains "Single-child path: no heartbeat emitted" "[heartbeat]" "$output"
unset REPOLENS_HEARTBEAT_INTERVAL

# ---------------------------------------------------------------------------
# 4. Disable knob: interval 0 turns heartbeat output off even with multiple
#    running children.
# ---------------------------------------------------------------------------
fresh_sem
REPOLENS_HEARTBEAT_INTERVAL=0
export REPOLENS_HEARTBEAT_INTERVAL
spawn_lens "disabled/a" cb_sleep 2
spawn_lens "disabled/b" cb_sleep 2
output_file="$TMPROOT/disabled.out"
run_wait_all_capture "$output_file"
wait_rc=$?
output="$(cat "$output_file")"

assert_eq "Disabled heartbeat path: wait_all succeeds" "0" "$wait_rc"
assert_not_contains "Disabled heartbeat path: no heartbeat emitted" "[heartbeat]" "$output"
unset REPOLENS_HEARTBEAT_INTERVAL

# ---------------------------------------------------------------------------
# 5. Elapsed formatter keeps the public heartbeat shape stable.
# ---------------------------------------------------------------------------
assert_eq "Elapsed formatter: seconds" "5s" "$(_format_elapsed 5)"
assert_eq "Elapsed formatter: minutes" "1m05s" "$(_format_elapsed 65)"
assert_eq "Elapsed formatter: hours" "1h01m01s" "$(_format_elapsed 3661)"

# ---------------------------------------------------------------------------
# 6. Structural guards and documentation coverage.
# ---------------------------------------------------------------------------
spawn_lens_src="$(declare -f spawn_lens)"
wait_all_src="$(declare -f wait_all)"
sem_acquire_src="$(declare -f sem_acquire)"

assert_contains "spawn_lens records child start times" "_REPOLENS_CHILD_STARTED_AT" "$spawn_lens_src"
assert_contains "wait_all reads heartbeat interval env var" "REPOLENS_HEARTBEAT_INTERVAL" "$wait_all_src"
assert_contains "wait_all emits heartbeat label through helper" "[heartbeat]" "$wait_all_src"
assert_contains "sem_acquire reads heartbeat interval env var" "REPOLENS_HEARTBEAT_INTERVAL" "$sem_acquire_src"
assert_contains "sem_acquire emits heartbeat while blocked" "_repolens_emit_heartbeat" "$sem_acquire_src"
assert_contains "repolens.sh documents REPOLENS_HEARTBEAT_INTERVAL" \
                "REPOLENS_HEARTBEAT_INTERVAL" "$(grep 'REPOLENS_HEARTBEAT_INTERVAL' "$SCRIPT_DIR/repolens.sh" || true)"
assert_contains "README.md documents REPOLENS_HEARTBEAT_INTERVAL" \
                "REPOLENS_HEARTBEAT_INTERVAL" "$(grep 'REPOLENS_HEARTBEAT_INTERVAL' "$SCRIPT_DIR/README.md" || true)"

echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
exit "$FAIL"
