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

# tests/run-all.sh — pure-bash test runner that mirrors `make check`.
#
# Produces output in the SAME format the Makefile does so any existing consumer
# (including AutoDev's extract_failing_tests parser) keeps working without care
# for which runner was used.
#
# Output contract (stable; AutoDev depends on this):
#   PASSED: <path/to/test_foo.sh> — Results: P/T passed, F failed
#   FAILED: <path/to/test_foo.sh> — Results: P/T passed, F failed
#     (indented) FAIL: <description>   -- one per failed assertion in that suite
#   <blank line>
#   Results: N suites run, M failed
#
# Exit code: 0 when all suites pass, 1 when any suite fails.

set -uo pipefail

# Resolve the repo root relative to this script, regardless of cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR" || exit 1

# Recursion guard — parity with the Makefile, plus hardening for AutoDev.
#
# Two shared env-var contracts:
#   1. REPOLENS_MAKE_CHECK is exported so any child test that spawns
#      `make check` is detected by the Makefile's own _SKIP_META guard
#      (Makefile: `_SKIP_META := $(if $(REPOLENS_MAKE_CHECK),1,)`) — the
#      inner make then skips meta tests that would recurse into a runner.
#   2. run-all.sh itself is a test runner, so we unconditionally set
#      _SKIP_META=1 here. The Makefile's top-level invocation keeps
#      _SKIP_META=0 so a human running `make check` still validates the
#      Makefile round-trip via test_issue6_test27_fix.sh. Automated
#      consumers (AutoDev) invoke run-all.sh directly — those runs must
#      never recurse into a second runner, because the inner `make check`
#      re-runs every other suite (including tests that hang waiting for
#      TTY stdin) and causes a multi-hour wedge.
#
# Skip criterion: any test file containing `&& make check` or a reference
# to `tests/run-all.sh` — both are markers of a meta-test that spawns a
# runner and would cascade.
export REPOLENS_MAKE_CHECK=1
_SKIP_META=1

suites_run=0
suites_failed=0

# Iterate tests/test_*.sh in sorted order (stable across runs).
while IFS= read -r -d '' f; do
  if (( _SKIP_META == 1 )) && grep -q '&& make check' "$f" 2>/dev/null; then
    continue
  fi
  if (( _SKIP_META == 1 )) && grep -q 'tests/run-all\.sh' "$f" 2>/dev/null; then
    continue
  fi

  output="$(bash "$f" 2>&1)"; rc=$?

  # The per-suite "Results: P/T passed, F failed" line is printed by the suites
  # themselves. Grab the last one (some suites print multiple).
  result_line="$(printf '%s\n' "$output" | grep 'Results:' | tail -1)"

  if (( rc == 0 )); then
    printf 'PASSED: %s — %s\n' "$f" "$result_line"
  else
    printf 'FAILED: %s — %s\n' "$f" "$result_line"
    # Echo each individual FAIL: line so operators (and the AutoDev parser)
    # can see the sub-failures, not just the suite file.
    printf '%s\n' "$output" | grep -E '^[[:space:]]*FAIL:' || true
    suites_failed=$((suites_failed + 1))
  fi
  suites_run=$((suites_run + 1))
done < <(find tests -maxdepth 1 -name 'test_*.sh' -type f -print0 | sort -z)

echo ""
echo "Results: ${suites_run} suites run, ${suites_failed} failed"

if (( suites_failed > 0 )); then
  exit 1
fi
exit 0
