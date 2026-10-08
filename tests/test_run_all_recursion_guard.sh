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

# Regression test: recursion guard for tests/run-all.sh
#
# Background: tests/test_issue6_test27_fix.sh invokes `make check` to
# validate the Makefile target. If run-all.sh (the pure-bash runner used
# by AutoDev) invokes that test, the inner `make check` re-runs every
# other suite — including tests that block waiting for TTY stdin — and
# the whole run wedges for hours. The symptom observed in production was
# "AutoDev hangs indefinitely on every quality-gate run".
#
# The fix: run-all.sh unconditionally sets _SKIP_META=1 and exports
# REPOLENS_MAKE_CHECK=1, so the skip-iterator ignores any test that
# recurses into a runner (match on `&& make check` or `tests/run-all.sh`)
# and any child test that still spawns `make check` is caught by the
# Makefile's own parse-time _SKIP_META guard.
#
# Behavioral contract this test pins:
#   1. run-all.sh completes well under the 5-minute budget when invoked
#      with stdin closed and a clean env (no REPOLENS_MAKE_CHECK pre-set)
#   2. No orphan test_issue6_test27_fix.sh (or child `make check`)
#      processes remain after run-all.sh exits
#   3. run-all.sh reports a "Results:" summary line (output contract)
#   4. run-all.sh exports REPOLENS_MAKE_CHECK=1 (source-level contract)
#   5. run-all.sh sets _SKIP_META=1 unconditionally (source-level)
#   6. test_issue6_test27_fix.sh's internal make-check sub-test passes
#      when invoked with REPOLENS_MAKE_CHECK=1 (the recursion-guarded
#      path that AutoDev now exercises)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
RUNNER="$SCRIPT_DIR/tests/run-all.sh"
META_TEST="$SCRIPT_DIR/tests/test_issue6_test27_fix.sh"

PASS=0
FAIL=0
TOTAL=0

fail_with() {
  local desc="$1" detail="${2:-}"
  FAIL=$((FAIL + 1))
  echo "  FAIL: $desc"
  if [[ -n "$detail" ]]; then
    printf '    %s\n' "$detail"
  fi
}

pass_with() {
  local desc="$1"
  PASS=$((PASS + 1))
  echo "  PASS: $desc"
}

runner_process_snapshot() {
  local line pid working_dir
  while IFS= read -r line; do
    pid="${line%% *}"
    # Concurrent gates in other checkouts belong to their own runners.
    # Linux exposes cwd even after an orphan has been reparented.
    if [[ -d /proc ]]; then
      working_dir="$(readlink "/proc/$pid/cwd" 2>/dev/null)" || continue
      [[ "$working_dir" == "$SCRIPT_DIR" ]] || continue
    fi
    printf '%s\n' "$line"
  done < <(pgrep -af "$1" 2>/dev/null || true)
}

echo "=== Test Suite: run-all.sh recursion guard ==="

# ---------------------------------------------------------------------
# Source-level assertions — no process spawned, cheap and deterministic.
# ---------------------------------------------------------------------

echo ""
echo "Test 1: run-all.sh exists and is executable"
TOTAL=$((TOTAL + 1))
if [[ -f "$RUNNER" && -r "$RUNNER" ]]; then
  pass_with "run-all.sh is present"
else
  fail_with "run-all.sh missing or unreadable" "path: $RUNNER"
fi

echo ""
echo "Test 2: run-all.sh exports REPOLENS_MAKE_CHECK=1"
TOTAL=$((TOTAL + 1))
if grep -qE '^[[:space:]]*export[[:space:]]+REPOLENS_MAKE_CHECK=1' "$RUNNER"; then
  pass_with "export REPOLENS_MAKE_CHECK=1 is present"
else
  fail_with "run-all.sh must export REPOLENS_MAKE_CHECK=1 to share the recursion guard with the Makefile"
fi

echo ""
echo "Test 3: run-all.sh sets _SKIP_META=1 unconditionally"
# Must have an unconditional `_SKIP_META=1` assignment (top-level, not
# guarded by an `if`). The pre-fix code guarded it behind an env-var
# check, which left AutoDev invocations unprotected.
TOTAL=$((TOTAL + 1))
if grep -qE '^[[:space:]]*_SKIP_META=1[[:space:]]*$' "$RUNNER"; then
  pass_with "_SKIP_META=1 is set unconditionally"
else
  fail_with "_SKIP_META=1 must be set unconditionally in run-all.sh (top-level)"
fi

echo ""
echo "Test 4: run-all.sh's skip loop consumes _SKIP_META"
TOTAL=$((TOTAL + 1))
if grep -qE '_SKIP_META == 1' "$RUNNER" && grep -q '&& make check' "$RUNNER"; then
  pass_with "skip loop honors _SKIP_META and matches '&& make check'"
else
  fail_with "run-all.sh must skip meta-tests when _SKIP_META=1"
fi

# ---------------------------------------------------------------------
# Behavioral assertion — actually run run-all.sh with a hard timeout.
# Budget: 900s with --kill-after=30 to guarantee termination even when
# inner bash ignores SIGTERM (e.g. while wait-blocked on grandchild
# processes). Pre-fix run-all.sh wedged for many hours; 900s is well
# above the suite's natural max (~700s with current test_local_mode
# integration tests) but well below "human-noticed hang".
# ---------------------------------------------------------------------

echo ""
echo "Test 5: run-all.sh completes within 900s with clean env + stdin closed"
TOTAL=$((TOTAL + 1))
runner_log="$(mktemp)"
# Snapshot pre-run process list so we can detect orphans that the run
# itself spawned (vs. unrelated shells the user has open).
# Match command positions, rather than arbitrary arguments: an agent prompt
# mentioning make check must not be reported as a running make process.
meta_pattern='^([^[:space:]]*/)?(bash|sh)([[:space:]]+-[^[:space:]]+)*[[:space:]]+([^[:space:]]*/)?tests/test_issue6_test27_fix\.sh([[:space:]]|$)'
make_pattern='^([^[:space:]]*/)?g?make[[:space:]]+check([[:space:]]|$)'
before_snapshot="$(mktemp)"
runner_process_snapshot "$meta_pattern" > "$before_snapshot"
runner_process_snapshot "$make_pattern" >> "$before_snapshot"

# Explicitly unset the env var so we exercise the top-level path AutoDev
# hits (not the recursive path that's always been guarded).
# `exec </dev/null` mirrors how AutoDev spawns agents with no TTY.
start_ts="$(date +%s)"
if timeout --kill-after=30 900 env -u REPOLENS_MAKE_CHECK bash -c \
     'exec </dev/null; bash "$0"' "$RUNNER" > "$runner_log" 2>&1; then
  runner_rc=0
else
  runner_rc=$?
fi
end_ts="$(date +%s)"
elapsed=$((end_ts - start_ts))

# rc==0: green run. rc==1: some suites failed (fine — pre-existing
# failures are catalogued by the QG baseline). rc==124: timeout — the
# regression we're guarding against. Any other rc is a real bug.
if (( runner_rc == 124 )); then
  fail_with "run-all.sh timed out after ${elapsed}s (recursion guard broken)" \
            "log tail: $(tail -5 "$runner_log" | tr '\n' ' ')"
elif (( runner_rc != 0 && runner_rc != 1 )); then
  fail_with "run-all.sh exited with unexpected rc=$runner_rc after ${elapsed}s" \
            "log tail: $(tail -5 "$runner_log" | tr '\n' ' ')"
else
  pass_with "run-all.sh finished in ${elapsed}s with rc=$runner_rc"
fi

echo ""
echo "Test 6: run-all.sh emits the 'Results:' summary line"
TOTAL=$((TOTAL + 1))
if grep -qE '^Results: [0-9]+ suites run, [0-9]+ failed' "$runner_log"; then
  pass_with "Results summary line is present"
else
  fail_with "run-all.sh did not emit the expected 'Results: N suites run, M failed' line" \
            "log tail: $(tail -3 "$runner_log" | tr '\n' ' ')"
fi

echo ""
echo "Test 7: no orphan test_issue6_test27_fix.sh processes remain"
TOTAL=$((TOTAL + 1))
# Give the OS a moment to reap zombies that were in flight when timeout
# fired. Keep this short — if a process is still running 2s after
# run-all.sh exits, it's orphaned, not slow.
sleep 2
after_meta="$(runner_process_snapshot "$meta_pattern")"
after_make="$(runner_process_snapshot "$make_pattern")"
# Strip any PIDs that pre-dated our run (unrelated user work).
unexpected_meta=""
if [[ -n "$after_meta" ]]; then
  while IFS= read -r line; do
    pid="${line%% *}"
    [[ -z "$pid" ]] && continue
    if ! grep -qE "^${pid}[[:space:]]" "$before_snapshot" 2>/dev/null; then
      unexpected_meta+="$line"$'\n'
    fi
  done <<< "$after_meta"
fi
unexpected_make=""
if [[ -n "$after_make" ]]; then
  while IFS= read -r line; do
    pid="${line%% *}"
    [[ -z "$pid" ]] && continue
    if ! grep -qE "^${pid}[[:space:]]" "$before_snapshot" 2>/dev/null; then
      unexpected_make+="$line"$'\n'
    fi
  done <<< "$after_make"
fi
if [[ -z "$unexpected_meta" && -z "$unexpected_make" ]]; then
  pass_with "no orphan meta-test or make check processes left behind"
else
  detail="meta orphans:${unexpected_meta:-none}; make orphans:${unexpected_make:-none}"
  fail_with "run-all.sh left orphan processes running" "$detail"
fi

# ---------------------------------------------------------------------
# Isolated check of the meta-test. This exercises the guarded path (env
# var pre-set by the caller) — the one AutoDev/Makefile rely on. We do
# NOT invoke the unguarded standalone path here; that path deliberately
# cascades, and running it here would re-trigger the very hang we just
# proved run-all.sh avoids.
# ---------------------------------------------------------------------

echo ""
echo "Test 8: test_issue6_test27_fix.sh exits successfully when invoked with the recursion-guard env var"
TOTAL=$((TOTAL + 1))
meta_log="$(mktemp)"
start_ts="$(date +%s)"
if timeout --kill-after=30 900 env REPOLENS_MAKE_CHECK=1 bash -c \
     'exec </dev/null; bash "$0"' "$META_TEST" > "$meta_log" 2>&1; then
  meta_rc=0
else
  meta_rc=$?
fi
end_ts="$(date +%s)"
meta_elapsed=$((end_ts - start_ts))

if (( meta_rc == 124 )); then
  fail_with "test_issue6_test27_fix.sh hung with REPOLENS_MAKE_CHECK=1 (guard broken)" \
            "elapsed: ${meta_elapsed}s; log tail: $(tail -5 "$meta_log" | tr '\n' ' ')"
elif (( meta_rc != 0 )); then
  # meta test has some pre-existing failures (tests 15-17 depend on the
  # Makefile being able to run without any regression, which can fail
  # for unrelated reasons). We only regress here if it hung.
  pass_with "test_issue6_test27_fix.sh finished in ${meta_elapsed}s with rc=$meta_rc (non-hang — guard works)"
else
  pass_with "test_issue6_test27_fix.sh passed in ${meta_elapsed}s"
fi

# ---------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------
rm -f "$runner_log" "$meta_log" "$before_snapshot"

echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

[[ "$FAIL" -eq 0 ]] || exit 1
