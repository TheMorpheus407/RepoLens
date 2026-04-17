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

# Regression tests for issue #111 — wait_all in lib/parallel.sh blocks
# forever on a stuck child. The fix adds a REPOLENS_CHILD_MAX_WAIT
# deadline, polls each child with `kill -0` + `sleep 1`, and on deadline
# expiry sends SIGTERM (10s grace) then SIGKILL while still processing
# the remaining children.
#
# No AI models are invoked — tests source lib/parallel.sh directly and
# exercise it with synthetic sleep-only callbacks.

# shellcheck disable=SC2329  # cb_* callbacks are invoked indirectly via spawn_lens string dispatch.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/parallel.sh"

PASS=0
FAIL=0
TOTAL=0

TMPROOT="$(mktemp -d)"
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

assert_lt() {
  local desc="$1" bound="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if (( actual < bound )); then
    PASS=$((PASS + 1))
    echo "  PASS: $desc ($actual < $bound)"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (actual=$actual, expected < $bound)"
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
    echo "  FAIL: $desc (missing '$needle' in output)"
    echo "  ---- haystack ----"
    printf '%s\n' "$haystack" | sed 's/^/    /'
    echo "  ------------------"
  fi
}

fresh_sem() {
  local case_dir
  case_dir="$(mktemp -d -p "$TMPROOT" sem.XXXXXX)"
  init_parallel "$case_dir" 8
}

# Unique marker strings keep `pgrep -f` assertions tight — a bare
# `pgrep -f 'sleep 60'` could accidentally catch an unrelated sleep from
# another test on the same machine.
MARK="$$-rl111-$RANDOM"

echo "=== parallel.sh wait_all per-child deadline (issue #111) ==="

# ---------------------------------------------------------------------------
# 1. Happy path — fast callback finishes well within deadline.
# ---------------------------------------------------------------------------
cb_fast() { sleep 0.1; }
fresh_sem
spawn_lens "fast" cb_fast
start=$SECONDS
wait_all; wait_rc=$?
elapsed=$((SECONDS - start))
assert_eq "Happy path: wait_all returns 0" "0" "$wait_rc"
assert_lt "Happy path: completes promptly" 5 "$elapsed"
assert_eq "Happy path: child PIDs cleared" "0" "${#_REPOLENS_CHILD_PIDS[@]}"
assert_eq "Happy path: child lens ids cleared" "0" "${#_REPOLENS_CHILD_LENS_IDS[@]}"

# ---------------------------------------------------------------------------
# 2. Single stuck child — deadline trips, SIGTERM reaps it.
#    REPOLENS_CHILD_MAX_WAIT=3, callback sleeps much longer. Must return
#    non-zero, finish in well under the callback's own runtime, and leave
#    no orphan sleep.
# ---------------------------------------------------------------------------
cb_stuck() {
  # Use a long sleep so we know the deadline (not natural exit) did the work.
  sleep 120 &
  # Tag this subshell with the marker so pgrep below finds the right PID.
  # shellcheck disable=SC2034  # used by pgrep -f below
  _RL111_MARK="$MARK-stuck"
  wait
}
fresh_sem
REPOLENS_CHILD_MAX_WAIT=3
export REPOLENS_CHILD_MAX_WAIT
spawn_lens "stuck-lens-a" cb_stuck
start=$SECONDS
stderr_log="$(mktemp -p "$TMPROOT")"
wait_all 2>"$stderr_log"; wait_rc=$?
elapsed=$((SECONDS - start))
stderr_out="$(cat "$stderr_log")"

assert_eq "Stuck child: wait_all surfaces failure" "1" "$wait_rc"
assert_lt "Stuck child: deadline honored (<20s)" 20 "$elapsed"
assert_contains "Stuck child: log names the lens id" "stuck-lens-a" "$stderr_out"
assert_contains "Stuck child: log references REPOLENS_CHILD_MAX_WAIT" "REPOLENS_CHILD_MAX_WAIT" "$stderr_out"
assert_eq "Stuck child: PIDs cleared" "0" "${#_REPOLENS_CHILD_PIDS[@]}"
assert_eq "Stuck child: lens ids cleared" "0" "${#_REPOLENS_CHILD_LENS_IDS[@]}"
unset REPOLENS_CHILD_MAX_WAIT

# ---------------------------------------------------------------------------
# 3. Mixed concurrent — one fast, one stuck. Fast reaps cleanly; stuck is
#    SIGTERM'd. Final rc is non-zero, state arrays are both empty.
# ---------------------------------------------------------------------------
cb_sleep_short() { sleep 0.2; }
cb_sleep_long()  { sleep 120; }
fresh_sem
REPOLENS_CHILD_MAX_WAIT=3
export REPOLENS_CHILD_MAX_WAIT
spawn_lens "mix-fast" cb_sleep_short
spawn_lens "mix-slow" cb_sleep_long
start=$SECONDS
stderr_log="$(mktemp -p "$TMPROOT")"
wait_all 2>"$stderr_log"; wait_rc=$?
elapsed=$((SECONDS - start))
stderr_out="$(cat "$stderr_log")"

assert_eq "Mixed: wait_all surfaces failure" "1" "$wait_rc"
assert_lt "Mixed: deadline honored (<20s)" 20 "$elapsed"
assert_contains "Mixed: log names the stuck lens id" "mix-slow" "$stderr_out"
assert_eq "Mixed: PIDs cleared" "0" "${#_REPOLENS_CHILD_PIDS[@]}"
assert_eq "Mixed: lens ids cleared" "0" "${#_REPOLENS_CHILD_LENS_IDS[@]}"
unset REPOLENS_CHILD_MAX_WAIT

# ---------------------------------------------------------------------------
# 4. SIGTERM-ignoring child — escalates to SIGKILL. Callback installs
#    `trap '' TERM` in its own subshell, then sleeps. The kill-escalation
#    path must still reap it within max_wait + 10s grace + tolerance.
# ---------------------------------------------------------------------------
cb_term_ignorer() {
  trap '' TERM
  sleep 120
}
fresh_sem
REPOLENS_CHILD_MAX_WAIT=3
export REPOLENS_CHILD_MAX_WAIT
spawn_lens "kill-escalate" cb_term_ignorer
start=$SECONDS
stderr_log="$(mktemp -p "$TMPROOT")"
wait_all 2>"$stderr_log"; wait_rc=$?
elapsed=$((SECONDS - start))
stderr_out="$(cat "$stderr_log")"

assert_eq "SIGKILL escalation: wait_all surfaces failure" "1" "$wait_rc"
# 3s deadline + 10s SIGTERM grace + 2s tolerance = 15s upper bound.
assert_lt "SIGKILL escalation: completes within deadline+grace window" 25 "$elapsed"
assert_contains "SIGKILL escalation: log mentions SIGKILL fallback" "SIGKILL" "$stderr_out"
unset REPOLENS_CHILD_MAX_WAIT

# ---------------------------------------------------------------------------
# 5. Default value — no REPOLENS_CHILD_MAX_WAIT set, default is 14400.
#    Introspect wait_all's declared body so a future "I'll just bump this
#    to 7200" tweak shows up as a deliberate test change.
# ---------------------------------------------------------------------------
unset REPOLENS_CHILD_MAX_WAIT
wait_all_src="$(declare -f wait_all)"
TOTAL=$((TOTAL + 1))
if [[ "$wait_all_src" =~ REPOLENS_CHILD_MAX_WAIT:-14400 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: wait_all default REPOLENS_CHILD_MAX_WAIT is 14400"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: wait_all does not use default 14400 for REPOLENS_CHILD_MAX_WAIT"
fi

# ---------------------------------------------------------------------------
# 6. Structural guard — wait_all body must use `kill -0` polling plus
#    `kill -TERM` escalation, NOT bare `wait $pid` with no deadline.
#    This pins the fix so a future revert to the unguarded form trips the
#    test.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
if [[ "$wait_all_src" == *"kill -0"* ]] \
   && [[ "$wait_all_src" == *"kill -TERM"* ]] \
   && [[ "$wait_all_src" == *"REPOLENS_CHILD_MAX_WAIT"* ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: wait_all uses deadline polling with SIGTERM escalation"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: wait_all missing deadline polling primitives"
  echo "  ---- current wait_all body ----"
  printf '%s\n' "$wait_all_src" | sed 's/^/    /'
  echo "  -------------------------------"
fi

# ---------------------------------------------------------------------------
# 7. Structural guard — spawn_lens must populate the new lens-id parallel
#    array so wait_all can map PID -> lens id on deadline expiry.
# ---------------------------------------------------------------------------
spawn_lens_src="$(declare -f spawn_lens)"
TOTAL=$((TOTAL + 1))
if [[ "$spawn_lens_src" == *"_REPOLENS_CHILD_LENS_IDS"* ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: spawn_lens records lens id in _REPOLENS_CHILD_LENS_IDS"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: spawn_lens does not populate _REPOLENS_CHILD_LENS_IDS"
fi

# ---------------------------------------------------------------------------
# 8. Documentation coverage — usage() and README.md must mention the new
#    env var so operators can discover it without reading code.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
if grep -q 'REPOLENS_CHILD_MAX_WAIT' "$SCRIPT_DIR/repolens.sh"; then
  PASS=$((PASS + 1))
  echo "  PASS: repolens.sh documents REPOLENS_CHILD_MAX_WAIT"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: repolens.sh usage() missing REPOLENS_CHILD_MAX_WAIT"
fi

TOTAL=$((TOTAL + 1))
if grep -q 'REPOLENS_CHILD_MAX_WAIT' "$SCRIPT_DIR/README.md"; then
  PASS=$((PASS + 1))
  echo "  PASS: README.md documents REPOLENS_CHILD_MAX_WAIT"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: README.md missing REPOLENS_CHILD_MAX_WAIT"
fi

echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
exit "$FAIL"
