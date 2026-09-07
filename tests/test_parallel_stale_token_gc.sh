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

# Regression tests for issue #117 — stale semaphore tokens from dead
# worker PIDs must not block --resume. No AI models are invoked; tests
# source lib/parallel.sh directly and exercise synthetic callbacks only.

# shellcheck disable=SC2329  # cb_* callbacks are invoked indirectly via spawn_lens string dispatch.

# shellcheck disable=SC2218 # Pre-definition calls intentionally use sourced implementations.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/logging.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/parallel.sh"
source "$SCRIPT_DIR/tests/process_scope_test_support.sh"
require_process_scopes

PASS=0
FAIL=0
TOTAL=0

TMPROOT="$SCRIPT_DIR/logs/test_parallel_stale_token_gc.$$.$RANDOM"
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

assert_file_exists() {
  local desc="$1" marker="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$marker" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
  fi
}

assert_file_missing() {
  local desc="$1" marker="$2"
  TOTAL=$((TOTAL + 1))
  if [[ ! -f "$marker" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
  fi
}

fresh_dir() {
  local case_dir
  case_dir="$TMPROOT/sem.$RANDOM.$RANDOM"
  mkdir -p "$case_dir"
  printf '%s\n' "$case_dir"
}

token_count_in() {
  local sem_dir="$1"
  find "$sem_dir" -maxdepth 1 -name '*.token' 2>/dev/null | wc -l | tr -d ' '
}

token_snapshot() {
  local token="$1"
  if [[ -f "$token" ]]; then
    tr '\n' '|' < "$token"
  else
    printf '<missing>'
  fi
}

token_contains_pid() {
  local token="$1" pid="$2"
  [[ -f "$token" ]] && grep -Eq "(^|[^0-9])${pid}([^0-9]|$)" "$token"
}

wait_for_file() {
  local file="$1" attempts="$2" waited=0
  while (( waited < attempts )); do
    [[ -f "$file" ]] && return 0
    sleep 0.2
    waited=$((waited + 1))
  done
  return 1
}

cb_record_holder_metadata() {
  local marker="$1"
  local token="$_REPOLENS_SEM_DIR/holder.token"

  if [[ -s "$token" ]] && token_contains_pid "$token" "$BASHPID"; then
    printf 'ok\n' > "$marker"
  else
    printf 'bad:%s\n' "$(token_snapshot "$token")" > "$marker"
  fi
}

cb_kill_self() {
  kill -9 "$BASHPID"
  sleep 2
}

echo "=== parallel.sh stale semaphore token GC (issue #117) ==="

# ---------------------------------------------------------------------------
# 1. Startup GC removes legacy PID-only tokens whose holder is gone.
#    This is the resume-crash shape from pre-upgrade token files.
# ---------------------------------------------------------------------------
case_dir="$(fresh_dir)"
printf '99999999\n' > "$case_dir/dead.token"
init_parallel "$case_dir" 2
assert_eq "Startup GC removes a token containing a dead PID" \
          "0" "$(token_count_in "$case_dir")"

# ---------------------------------------------------------------------------
# 2. Startup GC removes empty pre-upgrade tokens. Empty files have no
#    recoverable liveness signal, so keeping them can wedge --resume.
# ---------------------------------------------------------------------------
case_dir="$(fresh_dir)"
: > "$case_dir/empty.token"
init_parallel "$case_dir" 2
assert_eq "Startup GC removes an empty legacy token" \
          "0" "$(token_count_in "$case_dir")"

# ---------------------------------------------------------------------------
# 3. Startup GC preserves legacy PID-only tokens while the recorded
#    holder is still alive. This pins the backward-compatible parser's
#    live-PID path, not just the dead-PID cleanup path above.
# ---------------------------------------------------------------------------
case_dir="$(fresh_dir)"
printf '%s\n' "$BASHPID" > "$case_dir/live-legacy.token"
init_parallel "$case_dir" 2
assert_eq "Startup GC keeps a live legacy PID-only token" \
          "1" "$(token_count_in "$case_dir")"
rm -f "$case_dir/live-legacy.token"

# ---------------------------------------------------------------------------
# 4. Startup GC removes malformed metadata tokens. Keeping unreadable
#    metadata would preserve the same wedged count as an empty token.
# ---------------------------------------------------------------------------
case_dir="$(fresh_dir)"
{
  printf 'owner=%s\n' "$_REPOLENS_SEM_OWNER"
  printf 'pid=not-a-pid\n'
} > "$case_dir/malformed.token"
init_parallel "$case_dir" 2
assert_eq "Startup GC removes malformed token metadata" \
          "0" "$(token_count_in "$case_dir")"

# ---------------------------------------------------------------------------
# 5. PID-reuse guard: a token from another live shell is stale for this
#    run. Otherwise an unrelated process that reused a PID can pin a slot.
# ---------------------------------------------------------------------------
case_dir="$(fresh_dir)"
foreign_ready="$case_dir/foreign.ready"
bash -c '
  set -uo pipefail
  script_dir="$1"
  sem_dir="$2"
  ready="$3"
  # shellcheck source=/dev/null
  source "$script_dir/lib/logging.sh"
  # shellcheck source=/dev/null
  source "$script_dir/lib/parallel.sh"
  init_parallel "$sem_dir" 2
  sem_token_create "foreign"
  printf "ready\n" > "$ready"
  sleep 30
' bash "$SCRIPT_DIR" "$case_dir" "$foreign_ready" >/dev/null 2>&1 &
foreign_holder_pid=$!
wait_for_file "$foreign_ready" 25 || true
assert_file_exists "Foreign holder creates the token before GC runs" "$foreign_ready"
init_parallel "$case_dir" 2
assert_eq "Startup GC removes a foreign-run token even when its PID is live" \
          "0" "$(token_count_in "$case_dir")"
kill -KILL "$foreign_holder_pid" 2>/dev/null || true
wait "$foreign_holder_pid" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 6. Token creation records the actual spawned worker's PID before the
#    callback runs, so a SIGKILLed worker can be reconciled later.
# ---------------------------------------------------------------------------
case_dir="$(fresh_dir)"
holder_marker="$case_dir/holder.marker"
init_parallel "$case_dir" 2
spawn_lens "holder" cb_record_holder_metadata "$holder_marker"
wait_all >/dev/null 2>&1
holder_result="<missing>"
if [[ -f "$holder_marker" ]]; then
  holder_result="$(tr -d '\n' < "$holder_marker")"
fi
assert_eq "spawn_lens token metadata contains the worker BASHPID" \
          "ok" "$holder_result"

# ---------------------------------------------------------------------------
# 7. GC must not delete a token produced by the current run while its
#    recorded holder is still alive.
# ---------------------------------------------------------------------------
case_dir="$(fresh_dir)"
init_parallel "$case_dir" 2
sem_token_create "live"
init_parallel "$case_dir" 2
assert_eq "Startup GC keeps a current live token" \
          "1" "$(token_count_in "$case_dir")"
sem_token_remove "live"

# ---------------------------------------------------------------------------
# 8. A SIGKILLed worker still leaks before reconciliation, but a later
#    startup sweep must remove the orphaned token.
# ---------------------------------------------------------------------------
case_dir="$(fresh_dir)"
init_parallel "$case_dir" 2
spawn_lens "kill9" cb_kill_self
wait_all >/dev/null 2>&1
wait_rc=$?
assert_eq "SIGKILLed worker surfaces a wait_all failure" "1" "$wait_rc"
assert_eq "SIGKILLed worker scope is collected without an orphan token" \
          "0" "$(token_count_in "$case_dir")"
init_parallel "$case_dir" 2
assert_eq "Startup GC removes the SIGKILL orphan" \
          "0" "$(token_count_in "$case_dir")"

# ---------------------------------------------------------------------------
# 9. Resume-capacity behavior: if every slot is occupied by stale tokens,
#    init_parallel must clear enough capacity that sem_acquire returns
#    instead of blocking forever.
# ---------------------------------------------------------------------------
case_dir="$(fresh_dir)"
printf '99999999\n' > "$case_dir/stale-a.token"
printf '99999999\n' > "$case_dir/stale-b.token"
init_parallel "$case_dir" 2
acquired_marker="$case_dir/acquired.marker"
(
  sem_acquire
  printf 'done\n' > "$acquired_marker"
) >/dev/null 2>&1 &
acquire_pid=$!

if wait_for_file "$acquired_marker" 15; then
  wait "$acquire_pid" 2>/dev/null || true
else
  kill -KILL "$acquire_pid" 2>/dev/null || true
  wait "$acquire_pid" 2>/dev/null || true
fi
assert_file_exists "A full stale semaphore does not block sem_acquire after init_parallel" \
                   "$acquired_marker"

# ---------------------------------------------------------------------------
# 10. Mid-run self-heal behavior: sem_acquire runs GC when it would
#    otherwise block on a full semaphore, not only during init_parallel.
# ---------------------------------------------------------------------------
case_dir="$(fresh_dir)"
init_parallel "$case_dir" 1
{
  printf 'owner=%s\n' "$_REPOLENS_SEM_OWNER"
  printf 'pid=99999999\n'
} > "$case_dir/midrun-stale.token"
midrun_marker="$case_dir/midrun-acquired.marker"
(
  sem_acquire
  printf 'done\n' > "$midrun_marker"
) >/dev/null 2>&1 &
midrun_acquire_pid=$!

if wait_for_file "$midrun_marker" 15; then
  wait "$midrun_acquire_pid" 2>/dev/null || true
else
  kill -KILL "$midrun_acquire_pid" 2>/dev/null || true
  wait "$midrun_acquire_pid" 2>/dev/null || true
fi
assert_file_exists "sem_acquire self-heals stale capacity introduced after init_parallel" \
                   "$midrun_marker"
assert_eq "sem_acquire self-heal removes the stale token it unblocked on" \
          "0" "$(token_count_in "$case_dir")"

# ---------------------------------------------------------------------------
# 11. Token replacement must be atomic. sem_acquire may run GC while
#     spawn_lens rewrites a parent reservation from inside the child; the
#     live token must remain visible until the replacement is complete.
# ---------------------------------------------------------------------------
case_dir="$(fresh_dir)"
init_parallel "$case_dir" 1
sem_token_create "race"
race_marker="$case_dir/race-admitted.marker"
race_pause_marker="$case_dir/race-paused.marker"
(
  sem_acquire
  printf 'admitted\n' > "$race_marker"
) >/dev/null 2>&1 &
race_acquire_pid=$!
sleep 0.3

printf() {
  if [[ "${REPOLENS_TEST_DELAY_TOKEN_WRITE:-0}" == "1" && "${1-}" == 'owner=%s\n' ]]; then
    REPOLENS_TEST_DELAY_TOKEN_WRITE=0
    builtin printf 'paused\n' > "$REPOLENS_TEST_TOKEN_WRITE_PAUSE_MARKER"
    sleep 3
  fi
  # shellcheck disable=SC2059  # This wrapper intentionally preserves printf's format argument.
  builtin printf "$@"
}

REPOLENS_TEST_DELAY_TOKEN_WRITE=1
REPOLENS_TEST_TOKEN_WRITE_PAUSE_MARKER="$race_pause_marker"
sem_token_create "race"
unset -f printf
unset REPOLENS_TEST_DELAY_TOKEN_WRITE REPOLENS_TEST_TOKEN_WRITE_PAUSE_MARKER
sleep 0.3

assert_file_exists "Race test delayed token replacement while sem_acquire was polling" \
                   "$race_pause_marker"
assert_eq "Atomic token replacement keeps the live token counted during GC" \
          "1" "$(token_count_in "$case_dir")"
assert_file_missing "sem_acquire does not enter while a live token is being replaced" \
                    "$race_marker"
sem_token_remove "race"
if wait_for_file "$race_marker" 15; then
  wait "$race_acquire_pid" 2>/dev/null || true
else
  kill -KILL "$race_acquire_pid" 2>/dev/null || true
  wait "$race_acquire_pid" 2>/dev/null || true
fi
assert_file_exists "sem_acquire proceeds after the live token is released" \
                   "$race_marker"

echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
exit "$FAIL"
