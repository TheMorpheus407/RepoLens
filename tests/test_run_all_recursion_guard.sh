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
#   1. run-all.sh completes within seconds against isolated fixture suites
#      with stdin closed and a clean env (no REPOLENS_MAKE_CHECK pre-set)
#   2. Meta-tests cannot run, and child suites inherit the recursion guard
#   3. run-all.sh reports exact suite/failure counts and propagates failures
#      without leaving fixture-owned meta-test or make-check processes
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

GUARD_FIXTURE="$(mktemp -d)" || exit 1
trap 'rm -rf "$GUARD_FIXTURE"' EXIT

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
# Exercise the real runner against an isolated corpus, as the Makefile meta-test
# does. The outer gate already runs every real suite; recursively running them
# here tests their combined runtime rather than the runner's recursion guard.
# Use several ordinary suites and both recursion markers. Marked fixtures
# fail if executed, so a broken skip loop cannot silently pass.
# ---------------------------------------------------------------------

mkdir -p "$GUARD_FIXTURE/tests"
cp "$RUNNER" "$GUARD_FIXTURE/tests/run-all.sh"
expected_suites=3
for fixture_name in a_stdin b_success c_success; do
  cat > "$GUARD_FIXTURE/tests/test_$fixture_name.sh" <<'SUITE'
#!/usr/bin/env bash
set -uo pipefail
if [[ "${REPOLENS_MAKE_CHECK:-}" != 1 ]] || read -r -t 1; then
  echo "  FAIL: child recursion guard or closed stdin missing"
  exit 1
fi
echo "Results: 1/1 passed, 0 failed"
SUITE
done

# Both recursive marker forms must be skipped before their tripwires run.
cat > "$GUARD_FIXTURE/tests/test_make_meta.sh" <<'MAKE_META'
#!/usr/bin/env bash
set -uo pipefail
touch make-meta-ran
echo '  FAIL: recursive make meta-test executed'
exit 1
true && make check
MAKE_META
cat > "$GUARD_FIXTURE/tests/test_runner_meta.sh" <<'RUNNER_META'
#!/usr/bin/env bash
set -uo pipefail
touch runner-meta-ran
echo '  FAIL: recursive runner meta-test executed'
exit 1
bash tests/run-all.sh
RUNNER_META

echo ""
echo "Test 5: run-all.sh completes within 10s with clean env + stdin closed"
TOTAL=$((TOTAL + 1))
runner_log="$GUARD_FIXTURE/runner.log"
# Snapshot existing processes; only fixture-owned descendants count as orphans.
before_snapshot="$GUARD_FIXTURE/before.snapshot"
pgrep -af 'tests/test_issue6_test27_fix\.sh' > "$before_snapshot" 2>/dev/null || true
pgrep -af 'make[[:space:]]+check' >> "$before_snapshot" 2>/dev/null || true
start_ts="$(date +%s)"
if timeout --kill-after=2 10 env -u REPOLENS_MAKE_CHECK bash -c \
     'exec </dev/null; bash "$0"' "$GUARD_FIXTURE/tests/run-all.sh" > "$runner_log" 2>&1; then
  runner_rc=0
else
  runner_rc=$?
fi
end_ts="$(date +%s)"
elapsed=$((end_ts - start_ts))
if (( runner_rc == 0 )); then
  pass_with "run-all.sh finished in ${elapsed}s and skipped all recursive fixtures"
else
  fail_with "run-all.sh exited with rc=$runner_rc after ${elapsed}s" \
            "log tail: $(tail -5 "$runner_log" | tr '\n' ' ')"
fi

echo ""
echo "Test 6: run-all.sh emits the 'Results:' summary line"
TOTAL=$((TOTAL + 1))
if grep -qx "Results: $expected_suites suites run, 0 failed" "$runner_log"; then
  pass_with "Results summary line is present"
else
  fail_with "run-all.sh did not emit the expected 'Results: N suites run, M failed' line" \
            "log tail: $(tail -3 "$runner_log" | tr '\n' ' ')"
fi

echo ""
echo "Test 7: runner discovers every non-recursive suite and no meta-tests"
TOTAL=$((TOTAL + 1))
if [[ "$(grep -c '^PASSED:' "$runner_log")" == "$expected_suites" ]] \
   && ! grep -q '^FAILED:' "$runner_log"; then
  pass_with "all $expected_suites runnable fixtures inherited the guard and closed stdin"
else
  fail_with "runner did not execute exactly the non-recursive corpus"
fi

TOTAL=$((TOTAL + 1))
if [[ ! -e "$GUARD_FIXTURE/make-meta-ran" && ! -e "$GUARD_FIXTURE/runner-meta-ran" ]] \
  && ! grep -qE '^(PASSED|FAILED): tests/test_(make|runner)_meta.sh' "$runner_log"; then
  pass_with "both recursive meta-test forms were skipped before execution"
else
  fail_with "runner executed a recursive meta-test" "$(cat "$runner_log")"
fi

# A deliberately failing fixture verifies exit propagation and diagnostics;
# fixing this meta-test must retain the runner's all-zero success requirement.
cat > "$GUARD_FIXTURE/tests/test_zzz_failure.sh" <<'FAILURE'
#!/usr/bin/env bash
set -uo pipefail
echo "  FAIL: intentional runner fixture failure"
echo "Results: 0/1 passed, 1 failed"
exit 1
FAILURE
failure_log="$GUARD_FIXTURE/failure.log"
if timeout --kill-after=2 10 env -u REPOLENS_MAKE_CHECK bash \
     "$GUARD_FIXTURE/tests/run-all.sh" </dev/null > "$failure_log" 2>&1; then
  failure_rc=0
else
  failure_rc=$?
fi
TOTAL=$((TOTAL + 1))
if [[ "$failure_rc" == 1 ]]; then
  pass_with "runner propagates a failing suite as exit 1"
else
  fail_with "runner must return exit 1 for a failing suite" "got $failure_rc"
fi
TOTAL=$((TOTAL + 1))
if grep -qx "Results: $((expected_suites + 1)) suites run, 1 failed" "$failure_log" \
   && grep -q '^FAILED: tests/test_zzz_failure.sh' "$failure_log" \
   && grep -q '^  FAIL: intentional runner fixture failure' "$failure_log"; then
  pass_with "runner preserves failure counts and assertion diagnostics"
else
  fail_with "runner lost the failing suite's summary or diagnostics"
fi

# This orphan check requires Linux /proc with readable /proc/<pid>/cwd links.
# Missing or unreadable links skip candidates, so the assertion can pass without
# checking them. Ownership follows cwd; descendants that leave GUARD_FIXTURE
# are also outside this check. The current recursive fixtures keep that cwd.
TOTAL=$((TOTAL + 1))
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
# Retain the existing meta-test watchdog; machine load must not introduce a
# tighter deadline than this check had before fixture isolation.
if timeout --kill-after=30 900 env REPOLENS_MAKE_CHECK=1 bash -c \
     'exec </dev/null; bash "$0"' "$META_TEST" > "$meta_log" 2>&1; then
  meta_rc=0
else
  meta_rc=$?
fi
end_ts="$(date +%s)"
meta_elapsed=$((end_ts - start_ts))

if (( meta_rc == 0 )); then
  pass_with "test_issue6_test27_fix.sh passed in ${meta_elapsed}s"
else
  fail_with "test_issue6_test27_fix.sh failed with REPOLENS_MAKE_CHECK=1" \
            "rc=$meta_rc; log tail: $(tail -5 "$meta_log" | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------
rm -rf "$GUARD_FIXTURE"

echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

[[ "$FAIL" -eq 0 ]] || exit 1
