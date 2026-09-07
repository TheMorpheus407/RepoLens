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

# Regression tests for issue #112 — semaphore tokens leak on abnormal
# subshell exit.
#
# The parent collects tokens after the owned scope is empty, including exits
# caused by signals. Workers must not inherit the parent's global EXIT cleanup,
# but callbacks may install their own cleanup handlers.
#
# No AI models are invoked — tests source lib/parallel.sh directly and
# exercise it with synthetic callbacks.

# shellcheck disable=SC2329  # cb_* callbacks are invoked indirectly by spawn_lens via string dispatch.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# logging first — _cleanup_children calls log_warn on signal, and
# sourcing order matters so log_warn is defined when init_parallel
# installs its trap.
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/parallel.sh"
source "$SCRIPT_DIR/tests/process_scope_test_support.sh"
require_process_scopes

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

# Count .token files in the active semaphore directory.
token_count() {
  find "$_REPOLENS_SEM_DIR" -maxdepth 1 -name '*.token' 2>/dev/null | wc -l | tr -d ' '
}

# Fresh semaphore directory per test case so a leak in one case
# (notably the SIGKILL test) does not taint the next.
fresh_sem() {
  local case_dir
  case_dir="$(mktemp -d -p "$TMPROOT" sem.XXXXXX)"
  init_parallel "$case_dir" 8
}

echo "=== parallel.sh semaphore cleanup on abnormal exit (issue #112) ==="

# ---------------------------------------------------------------------------
# 0. Issue #276 abort marker guard — a parent waiting for parallel capacity
#    must treat a child-written rate-limit sleep interrupt marker as an abort
#    signal even if it observes that marker independently.
# ---------------------------------------------------------------------------
LOG_BASE="$TMPROOT/abort-marker"
mkdir -p "$LOG_BASE"
_parallel_agent_abort_pending; abort_rc=$?
assert_eq "No abort marker: parallel abort check is clear" "1" "$abort_rc"
: > "$LOG_BASE/.rate-limit-sleep-interrupt"
_parallel_agent_abort_pending; abort_rc=$?
assert_eq "Rate-limit sleep interrupt marker trips parallel abort check" "0" "$abort_rc"
rm -f "$LOG_BASE/.rate-limit-sleep-interrupt"
unset LOG_BASE

# ---------------------------------------------------------------------------
# 1. Happy path — callback returns 0, token released, wait_all == 0.
# ---------------------------------------------------------------------------
cb_ok() { return 0; }
fresh_sem
spawn_lens "ok" cb_ok
wait_all; wait_rc=$?
assert_eq "Happy path: token removed on clean return" "0" "$(token_count)"
assert_eq "Happy path: wait_all returns 0"            "0" "$wait_rc"

# ---------------------------------------------------------------------------
# 2. Callback calls `exit 1` — subshell aborts before the old explicit
#    sem_token_remove line runs, so without the EXIT trap the token leaks.
#    This is the primary red-phase case that fails before the fix.
# ---------------------------------------------------------------------------
cb_exit_nonzero() { exit 1; }
fresh_sem
spawn_lens "exit1" cb_exit_nonzero
wait_all; wait_rc=$?
assert_eq "exit 1: token removed via empty-scope collection" "0" "$(token_count)"
assert_eq "exit 1: wait_all surfaces failure"   "1" "$wait_rc"

# ---------------------------------------------------------------------------
# 2b. `set -e` trip — callback enables errexit and runs a failing command.
#     The issue's acceptance criteria explicitly names "callback errors
#     with `set -e` semantics" as a required exit path. This is distinct
#     from case 2 (`exit 1`): errexit exits the shell via a different
#     code path, and we want to pin down that the EXIT trap still fires.
# ---------------------------------------------------------------------------
cb_errexit() {
  set -e
  false
  # Unreachable — errexit exits the subshell on `false`. If bash ever
  # changes this, the trailing sleep caps the test run instead of hanging.
  sleep 2
}
fresh_sem
spawn_lens "errexit" cb_errexit
wait_all; wait_rc=$?
assert_eq "errexit: token removed via empty-scope collection" "0" "$(token_count)"
assert_eq "errexit: wait_all surfaces failure"   "1" "$wait_rc"

# ---------------------------------------------------------------------------
# 3. Callback sends SIGTERM to its own subshell — must release the token.
#    $BASHPID addresses the subshell process (not the parent's $$).
#    The trailing `sleep 2` is a guard that should never execute; if the
#    signal were somehow lost it caps the test at a few seconds instead
#    of wedging the run.
# ---------------------------------------------------------------------------
cb_term() {
  kill -TERM "$BASHPID"
  sleep 2
}
fresh_sem
spawn_lens "term" cb_term
wait_all; wait_rc=$?
assert_eq "SIGTERM: token removed via empty-scope collection" "0" "$(token_count)"

# ---------------------------------------------------------------------------
# 4. Callback sends SIGHUP to its own subshell — must also release.
# ---------------------------------------------------------------------------
cb_hup() {
  kill -HUP "$BASHPID"
  sleep 2
}
fresh_sem
spawn_lens "hup" cb_hup
wait_all; wait_rc=$?
assert_eq "SIGHUP: token removed via empty-scope collection" "0" "$(token_count)"

# ---------------------------------------------------------------------------
# 5. SIGKILL limitation — bash cannot trap SIGKILL, so the token IS
#    expected to leak here. This test documents the boundary of the
#    fix; the follow-up issue #117 handles SIGKILL residue via a
#    startup-time GC in init_parallel.
# ---------------------------------------------------------------------------
cb_kill() {
  kill -9 "$BASHPID"
  sleep 2
}
fresh_sem
spawn_lens "kill9" cb_kill
wait_all; wait_rc=$?
assert_eq "SIGKILL: empty-scope collection removes token" \
          "0" "$(token_count)"

# ---------------------------------------------------------------------------
# 6. Parent INT/TERM trap installed by init_parallel must NOT be
#    clobbered by the subshell-local EXIT trap. Confirms the fix's
#    scoping — subshell traps do not bleed into the parent.
# ---------------------------------------------------------------------------
fresh_sem
parent_int_before="$(trap -p INT)"
parent_term_before="$(trap -p TERM)"
spawn_lens "scope" cb_ok
wait_all >/dev/null 2>&1
parent_int_after="$(trap -p INT)"
parent_term_after="$(trap -p TERM)"
assert_eq "Parent INT trap unchanged after spawn_lens" \
          "$parent_int_before" "$parent_int_after"
assert_eq "Parent TERM trap unchanged after spawn_lens" \
          "$parent_term_before" "$parent_term_after"
# Sanity — the parent trap really IS _cleanup_children, so the previous
# two assertions aren't passing on two empty strings.
TOTAL=$((TOTAL + 1))
if [[ "$parent_int_after" == *"_cleanup_children"* ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: Parent INT trap references _cleanup_children (sanity)"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: Parent INT trap missing _cleanup_children: '$parent_int_after'"
fi

# ---------------------------------------------------------------------------
# 7. Mid-run SIGTERM on one of several concurrent subshells — the killed
#    worker's token must be released so the semaphore count returns to
#    zero after wait_all. This is the scenario that wedges --resume in
#    the wild: one child dies, its token sticks, the count is permanently
#    inflated.
# ---------------------------------------------------------------------------
cb_sleep1() { sleep 1; }
fresh_sem
spawn_lens "c1" cb_sleep1
victim_pid="${_REPOLENS_CHILD_PIDS[0]}"
spawn_lens "c2" cb_sleep1
spawn_lens "c3" cb_sleep1
spawn_lens "c4" cb_sleep1
# Brief delay so every subshell has installed its EXIT trap before we
# signal the victim. 100ms is plenty for fork+trap setup.
sleep 0.1
kill -TERM "$victim_pid" 2>/dev/null || true
wait_all >/dev/null 2>&1
assert_eq "Concurrent spawns: SIGTERM'd worker token released" \
          "0" "$(token_count)"

# ---------------------------------------------------------------------------
# 8. Scope ownership releases capacity only after kernel-confirmed emptiness.
# This is exercised above for normal, abnormal, and SIGKILL callback exits.

# 9. Heartbeat-style trap save/restore must not activate parent cleanup in a
# worker. Inspect the first READY write as well: isolation precedes enrollment.
(
  trap 'touch "$TMPROOT/parent-exit-ran"' EXIT
  fresh_sem || exit 1
  parent_exit_before="$(trap -p EXIT)"
  printf() {
    if [[ "${1:-}" == '%s %s\n' ]]; then
      trap -p EXIT > "$TMPROOT/gate-exit-trap"
    fi
    # shellcheck disable=SC2059 # Preserve the wrapped builtin format.
    builtin printf "$@"
  }
  cb_restore_exit() {
    local previous_exit
    previous_exit="$(trap -p EXIT)"
    builtin printf '%s' "$previous_exit" > "$TMPROOT/callback-exit-trap"
    trap ':' EXIT
    if [[ -n "$previous_exit" ]]; then eval "$previous_exit"; else trap - EXIT; fi
  }
  spawn_lens trap-isolation cb_restore_exit || exit 1
  wait_all || exit 1
  [[ "$(trap -p EXIT)" == "$parent_exit_before" ]] || exit 1
  trap - EXIT
); assert_eq "Worker trap isolation preserves the parent's EXIT handler" "0" "$?"
assert_eq "Inherited EXIT is cleared before the READY handshake" "true" \
  "$([[ -f "$TMPROOT/gate-exit-trap" && ! -s "$TMPROOT/gate-exit-trap" ]] && echo true || echo false)"
assert_eq "Callback cannot capture the parent's global EXIT cleanup" "true" \
  "$([[ -f "$TMPROOT/callback-exit-trap" && ! -s "$TMPROOT/callback-exit-trap" ]] && echo true || echo false)"
assert_eq "Callback trap restoration never runs parent cleanup" "false" \
  "$([[ -e "$TMPROOT/parent-exit-ran" ]] && echo true || echo false)"

cb_own_exit() { trap 'touch "$TMPROOT/worker-exit-ran"' EXIT; exit 7; }
fresh_sem
spawn_lens own-exit cb_own_exit
wait_all; wait_rc=$?
assert_eq "Callback-installed EXIT cleanup still runs" "true" \
  "$([[ -f "$TMPROOT/worker-exit-ran" ]] && echo true || echo false)"
assert_eq "Callback EXIT cleanup preserves a failing worker result" "1" "$wait_rc"
assert_eq "Callback EXIT cleanup leaves scope token collection intact" "0" "$(token_count)"

echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
exit "$FAIL"
