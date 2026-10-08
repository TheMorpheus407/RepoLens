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
#   1. The real run-all.sh completes on isolated fixture suites with stdin
#      closed and a clean env (no REPOLENS_MAKE_CHECK pre-set)
#   2. No orphan test_issue6_test27_fix.sh (or child `make check`)
#      processes remain after run-all.sh exits
#   3. run-all.sh reports exact suite/failure counts and a nonzero failure exit
#   4. run-all.sh exports REPOLENS_MAKE_CHECK=1 (source-level contract)
#   5. run-all.sh sets _SKIP_META=1 unconditionally (source-level)
#   6. test_issue6_test27_fix.sh's internal make-check sub-test passes
#      when invoked with REPOLENS_MAKE_CHECK=1 (the recursion-guarded
#      path that AutoDev now exercises)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$SCRIPT_DIR/tests/run-all.sh"
META_TEST="$SCRIPT_DIR/tests/test_issue6_test27_fix.sh"

PASS=0
FAIL=0
TOTAL=0

GUARD_FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$GUARD_FIXTURE"' EXIT

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
# Behavioral assertion — execute the actual runner on isolated suites.
# Re-running the product suite here duplicated the outer gate and timed out
# after 900s, conflating suite duration with recursion. Tripwire meta-tests
# exercise both skip patterns directly; ordinary suites pin guard export,
# discovery, failure propagation and exact aggregate reporting.
# ---------------------------------------------------------------------

echo ""
mkdir -p "$GUARD_FIXTURE/tests"
cp "$RUNNER" "$GUARD_FIXTURE/tests/run-all.sh"
cat > "$GUARD_FIXTURE/tests/test_plain.sh" <<'PLAIN'
#!/usr/bin/env bash
set -euo pipefail
[[ "${REPOLENS_MAKE_CHECK:-}" == 1 ]]
echo 'Results: 1/1 passed, 0 failed'
PLAIN
cat > "$GUARD_FIXTURE/tests/test_failure.sh" <<'FAILURE'
#!/usr/bin/env bash
echo '  FAIL: intentional fixture failure'
echo 'Results: 0/1 passed, 1 failed'
exit 1
FAILURE
cat > "$GUARD_FIXTURE/tests/test_make_meta.sh" <<'MAKE_META'
#!/usr/bin/env bash
touch make-meta-ran
echo '  FAIL: recursive make meta-test executed'
exit 1
true && make check
MAKE_META
cat > "$GUARD_FIXTURE/tests/test_runner_meta.sh" <<'RUNNER_META'
#!/usr/bin/env bash
touch runner-meta-ran
echo '  FAIL: recursive runner meta-test executed'
exit 1
bash tests/run-all.sh
RUNNER_META

echo "Test 5: run-all.sh completes within 5s with clean env + stdin closed"
TOTAL=$((TOTAL + 1))
runner_log="$GUARD_FIXTURE/runner.log"
# Snapshot pre-run process list so we can detect orphans that the run
# itself spawned (vs. unrelated shells the user has open).
before_snapshot="$GUARD_FIXTURE/before.snapshot"
pgrep -af 'tests/test_issue6_test27_fix\.sh' > "$before_snapshot" 2>/dev/null || true
pgrep -af 'make[[:space:]]+check' >> "$before_snapshot" 2>/dev/null || true

# Explicitly unset the env var so we exercise the top-level path AutoDev
# hits (not the recursive path that's always been guarded).
# `exec </dev/null` mirrors how AutoDev spawns agents with no TTY.
start_ts="$(date +%s)"
if timeout --kill-after=1 5 env -u REPOLENS_MAKE_CHECK bash -c \
     'exec </dev/null; bash "$0"' "$GUARD_FIXTURE/tests/run-all.sh" > "$runner_log" 2>&1; then
  runner_rc=0
else
  runner_rc=$?
fi
end_ts="$(date +%s)"
elapsed=$((end_ts - start_ts))

# One intentionally failing fixture must produce rc=1. A missing guard trips
# meta-test markers; a hang or a swallowed failure is independently rejected.
if (( runner_rc == 124 )); then
  fail_with "run-all.sh timed out after ${elapsed}s (recursion guard broken)" \
            "log tail: $(tail -5 "$runner_log" | tr '\n' ' ')"
elif (( runner_rc != 1 )); then
  fail_with "run-all.sh exited with unexpected rc=$runner_rc after ${elapsed}s" \
            "log tail: $(tail -5 "$runner_log" | tr '\n' ' ')"
else
  pass_with "run-all.sh finished in ${elapsed}s with rc=$runner_rc"
fi

echo ""
echo "Test 6: run-all.sh runs both ordinary suites and reports the exact failure"
TOTAL=$((TOTAL + 1))
if grep -qFx 'Results: 2 suites run, 1 failed' "$runner_log" \
  && grep -q '^PASSED: tests/test_plain.sh ' "$runner_log" \
  && grep -q '^FAILED: tests/test_failure.sh ' "$runner_log" \
  && grep -q 'FAIL: intentional fixture failure' "$runner_log"; then
  pass_with "ordinary suites, failure detail and exact Results summary are present"
else
  fail_with "run-all.sh did not emit the expected 'Results: N suites run, M failed' line" \
            "log tail: $(tail -3 "$runner_log" | tr '\n' ' ')"
fi

TOTAL=$((TOTAL + 1))
if [[ ! -e "$GUARD_FIXTURE/make-meta-ran" && ! -e "$GUARD_FIXTURE/runner-meta-ran" ]] \
  && ! grep -qE '^(PASSED|FAILED): tests/test_(make|runner)_meta.sh' "$runner_log"; then
  pass_with "both recursive meta-test forms were skipped before execution"
else
  fail_with "runner executed a recursive meta-test" "$(cat "$runner_log")"
fi

echo ""
echo "Test 7: no orphan test_issue6_test27_fix.sh processes remain"
TOTAL=$((TOTAL + 1))
# Give the OS a moment to reap zombies that were in flight when timeout
# fired. Keep this short — if a process is still running 2s after
# run-all.sh exits, it's orphaned, not slow.
sleep 2
after_meta="$(pgrep -af 'tests/test_issue6_test27_fix\.sh' 2>/dev/null || true)"
after_make="$(pgrep -af 'make[[:space:]]+check' 2>/dev/null || true)"
# Strip any PIDs that pre-dated our run (unrelated user work).
unexpected_meta=""
if [[ -n "$after_meta" ]]; then
  while IFS= read -r line; do
    pid="${line%% *}"
    [[ -z "$pid" ]] && continue
    # Concurrent controller checks may start after our snapshot. Only the
    # isolated runner's working directory can identify its own descendants.
    candidate_cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null || true)"
    [[ "$candidate_cwd" == "$GUARD_FIXTURE" || "$candidate_cwd" == "$GUARD_FIXTURE/"* ]] || continue
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
    candidate_cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null || true)"
    [[ "$candidate_cwd" == "$GUARD_FIXTURE" || "$candidate_cwd" == "$GUARD_FIXTURE/"* ]] || continue
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
meta_log="$GUARD_FIXTURE/meta.log"
start_ts="$(date +%s)"
if timeout --kill-after=1 30 env REPOLENS_MAKE_CHECK=1 bash -c \
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
  fail_with "test_issue6_test27_fix.sh failed with REPOLENS_MAKE_CHECK=1" \
            "elapsed: ${meta_elapsed}s; log tail: $(tail -5 "$meta_log" | tr '\n' ' ')"
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
