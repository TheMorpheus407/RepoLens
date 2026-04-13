#!/usr/bin/env bash
# Tests for the --yes / -y confirmation gate (issue #7)
# Tests are BEHAVIORAL: they execute repolens.sh and assert on exit codes + output,
# never on source code patterns.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOLENS="$SCRIPT_DIR/repolens.sh"

# Timeout for each script invocation — prevents hangs when the gate
# doesn't exist yet (TDD red phase) and the script runs into full execution.
TIMEOUT=15

PASS=0
FAIL=0
TOTAL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    Expected: $(echo "$expected" | head -3)"
    echo "    Actual:   $(echo "$actual" | head -3)"
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
    echo "  FAIL: $desc"
    echo "    Expected to contain: $needle"
    echo "    In output (first 200 chars): ${haystack:0:200}"
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
    echo "  FAIL: $desc"
    echo "    Expected NOT to contain: $needle"
  fi
}

assert_exit_code() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" -eq "$actual" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    Expected exit code: $expected, got: $actual"
  fi
}

# Helper: run repolens.sh with timeout and capture output + exit code.
# Usage: run_repolens [--stdin "input"] [args...]
# Sets: RUN_OUTPUT (combined stdout+stderr), RUN_EXIT (exit code)
run_repolens() {
  local stdin_data=""
  if [[ "${1:-}" == "--stdin" ]]; then
    stdin_data="$2"
    shift 2
  fi
  # Capture output to temp file so we can get real exit code
  local tmp_out="$TMPDIR/.run_output"
  echo "$stdin_data" | timeout "$TIMEOUT" bash "$REPOLENS" "$@" >"$tmp_out" 2>&1
  RUN_EXIT=$?
  RUN_OUTPUT="$(cat "$tmp_out")"
  rm -f "$tmp_out"
}

# Helper: run with script(1) for TTY simulation + timeout
# Usage: run_repolens_tty "stdin_data" [args...]
# Sets: RUN_OUTPUT, RUN_EXIT
# Returns 1 if script(1) is not available.
run_repolens_tty() {
  local stdin_data="$1"
  shift
  if ! command -v script >/dev/null 2>&1; then
    return 1
  fi
  local args_str=""
  for arg in "$@"; do
    args_str+=" '${arg//\'/\'\\\'\'}'"
  done
  local tmp_out="$TMPDIR/.tty_output"
  # Use script -qe: -q = quiet, -e = return child exit status
  echo "$stdin_data" | timeout "$TIMEOUT" script -qec "bash '$REPOLENS' $args_str" /dev/null >"$tmp_out" 2>&1
  RUN_EXIT=$?
  RUN_OUTPUT="$(cat "$tmp_out")"
  rm -f "$tmp_out"
  return 0
}

# --- Setup test fixtures ---
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# Create a minimal git repo fixture for integration tests
setup_test_repo() {
  local repo_dir="$TMPDIR/test-repo"
  mkdir -p "$repo_dir"
  git -C "$repo_dir" init -q
  git -C "$repo_dir" config user.email "test@test.com"
  git -C "$repo_dir" config user.name "Test"
  echo "test" > "$repo_dir/README.md"
  git -C "$repo_dir" add .
  git -C "$repo_dir" commit -q -m "init"
  echo "$repo_dir"
}

TEST_REPO="$(setup_test_repo)"

echo ""
echo "=== Test Suite: --yes / -y confirmation gate (issue #7) ==="
echo ""

# =====================================================================
# Test 1: --yes flag is accepted by argument parser
# =====================================================================
# When --yes is passed, the script should NOT fail with "Unknown argument".

echo "Test 1: --yes flag accepted by argument parser"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --yes
assert_not_contains "--yes not rejected as unknown" "Unknown argument: --yes" "$RUN_OUTPUT"

# =====================================================================
# Test 2: -y short flag is accepted by argument parser
# =====================================================================

echo ""
echo "Test 2: -y short flag accepted by argument parser"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude -y
assert_not_contains "-y not rejected as unknown" "Unknown argument: -y" "$RUN_OUTPUT"

# =====================================================================
# Test 3: --help output includes --yes documentation
# =====================================================================

echo ""
echo "Test 3: --help mentions --yes flag"
help_output="$(timeout "$TIMEOUT" bash "$REPOLENS" --help 2>&1)"
assert_contains "--yes in help text" "--yes" "$help_output"

# =====================================================================
# Test 4: --help output includes -y short form documentation
# =====================================================================

echo ""
echo "Test 4: --help mentions -y short form"
assert_contains "-y in help text" "-y" "$help_output"

# =====================================================================
# Test 5: Non-interactive stdin without --yes produces error mentioning --yes
# =====================================================================
# When stdin is not a terminal (piped) and --yes is not passed,
# the script must die with an error mentioning --yes.

echo ""
echo "Test 5: Non-interactive stdin without --yes mentions --yes in error"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude
assert_contains "error mentions --yes" "--yes" "$RUN_OUTPUT"

# =====================================================================
# Test 6: Non-interactive stdin without --yes exits with code 1
# =====================================================================

echo ""
echo "Test 6: Non-interactive stdin without --yes has exit code 1"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude
assert_eq "exit code is 1" "1" "$RUN_EXIT"

# =====================================================================
# Test 7: Non-interactive error message is descriptive
# =====================================================================

echo ""
echo "Test 7: Non-interactive error message mentions non-interactive"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude
assert_contains "mentions non-interactive" "non-interactive" "$RUN_OUTPUT"

# =====================================================================
# Test 8: Piping "N" via TTY shows "Aborted" message
# =====================================================================
# Uses script(1) to simulate a TTY so the interactive prompt appears.

echo ""
echo "Test 8: Piping 'N' via TTY shows Aborted message"
if run_repolens_tty "N" --project "$TEST_REPO" --agent claude; then
  assert_contains "N produces Aborted" "Aborted" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped (counts as failure for TDD)"
fi

# =====================================================================
# Test 9: Piping "N" exits with code 0 (clean abort, not error)
# =====================================================================

echo ""
echo "Test 9: Piping 'N' via TTY exits with code 0"
if run_repolens_tty "N" --project "$TEST_REPO" --agent claude; then
  assert_exit_code "N abort exit code is 0" 0 "$RUN_EXIT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 10: --yes bypasses confirmation in non-interactive context
# =====================================================================
# With --yes, the script should NOT produce a non-interactive error.
# It must also NOT produce the "Unknown argument" error (test 1 checks this too).
# Additionally, verify the confirmation gate header does NOT appear (it's bypassed).

echo ""
echo "Test 10: --yes bypasses confirmation gate"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --yes
assert_not_contains "no non-interactive error with --yes" "non-interactive" "$RUN_OUTPUT"
assert_not_contains "no --yes suggestion with --yes" "Use --yes" "$RUN_OUTPUT"
assert_not_contains "no confirmation header with --yes" "RepoLens Confirmation" "$RUN_OUTPUT"

# =====================================================================
# Test 11: -y short flag also bypasses confirmation
# =====================================================================

echo ""
echo "Test 11: -y bypasses confirmation gate"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude -y
assert_not_contains "no non-interactive error with -y" "non-interactive" "$RUN_OUTPUT"
assert_not_contains "no confirmation header with -y" "RepoLens Confirmation" "$RUN_OUTPUT"

# =====================================================================
# Test 12: Confirmation prompt shows "RepoLens Confirmation" header
# =====================================================================
# The confirmation gate must display a distinctive header.

echo ""
echo "Test 12: Confirmation prompt shows gate header"
if run_repolens_tty "N" --project "$TEST_REPO" --agent claude; then
  assert_contains "gate header present" "RepoLens Confirmation" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 13: Confirmation prompt shows lens count
# =====================================================================

echo ""
echo "Test 13: Confirmation prompt shows lens count"
if run_repolens_tty "N" --project "$TEST_REPO" --agent claude; then
  assert_contains "prompt shows Lenses:" "Lenses:" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 14: Confirmation prompt shows target repo
# =====================================================================

echo ""
echo "Test 14: Confirmation prompt shows target repo"
if run_repolens_tty "N" --project "$TEST_REPO" --agent claude; then
  assert_contains "prompt shows Target repo:" "Target repo:" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 15: Piping "y" proceeds past gate (shows Proceed? but no Aborted)
# =====================================================================

echo ""
echo "Test 15: Piping 'y' proceeds past confirmation gate"
if run_repolens_tty "y" --project "$TEST_REPO" --agent claude; then
  # Gate must have been shown (Proceed?) but user passed it (no Aborted)
  assert_contains "gate was shown" "Proceed?" "$RUN_OUTPUT"
  assert_not_contains "y does not abort" "Aborted" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 2)); FAIL=$((FAIL + 2))
  echo "  FAIL: script(1) not available — skipped"
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 16: Empty input defaults to N (abort)
# =====================================================================

echo ""
echo "Test 16: Empty TTY input defaults to N (Aborted)"
if run_repolens_tty "" --project "$TEST_REPO" --agent claude; then
  assert_contains "empty input produces Aborted" "Aborted" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 17: Confirmation prompt includes "Proceed? [y/N]"
# =====================================================================

echo ""
echo "Test 17: Prompt shows Proceed? [y/N]"
if run_repolens_tty "N" --project "$TEST_REPO" --agent claude; then
  assert_contains "prompt shows Proceed?" "Proceed?" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 18: Labels are NOT created when user aborts with N
# =====================================================================
# The confirmation gate must fire BEFORE ensure_labels().
# If the user aborts, "Ensuring GitHub labels" should never appear.

echo ""
echo "Test 18: No label creation on abort"
if run_repolens_tty "N" --project "$TEST_REPO" --agent claude; then
  # First verify the gate actually ran (Aborted present), then check labels weren't created
  assert_contains "gate ran (Aborted)" "Aborted" "$RUN_OUTPUT"
  assert_not_contains "no label creation on abort" "Ensuring GitHub labels" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 2)); FAIL=$((FAIL + 2))
  echo "  FAIL: script(1) not available — skipped"
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 19: --yes with discover mode works
# =====================================================================

echo ""
echo "Test 19: --yes works with discover mode"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --mode discover --yes
assert_not_contains "--yes works with discover" "Unknown argument: --yes" "$RUN_OUTPUT"
assert_not_contains "no non-interactive error" "non-interactive" "$RUN_OUTPUT"

# =====================================================================
# Test 20: --yes with --resume works
# =====================================================================

echo ""
echo "Test 20: --yes works with --resume"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --yes --resume fake-run-id
assert_not_contains "--yes works with --resume" "Unknown argument: --yes" "$RUN_OUTPUT"

# =====================================================================
# Test 21: Uppercase "Y" proceeds past gate
# =====================================================================
# The case pattern [yY] should accept uppercase Y.

echo ""
echo "Test 21: Uppercase 'Y' proceeds past confirmation gate"
if run_repolens_tty "Y" --project "$TEST_REPO" --agent claude; then
  assert_contains "gate was shown" "Proceed?" "$RUN_OUTPUT"
  assert_not_contains "Y does not abort" "Aborted" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 2)); FAIL=$((FAIL + 2))
  echo "  FAIL: script(1) not available — skipped"
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 22: Full word "yes" proceeds past gate
# =====================================================================
# The case pattern [yY][eE][sS] should accept "yes".

echo ""
echo "Test 22: Full word 'yes' proceeds past confirmation gate"
if run_repolens_tty "yes" --project "$TEST_REPO" --agent claude; then
  assert_contains "gate was shown" "Proceed?" "$RUN_OUTPUT"
  assert_not_contains "yes does not abort" "Aborted" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 2)); FAIL=$((FAIL + 2))
  echo "  FAIL: script(1) not available — skipped"
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 23: All-caps "YES" proceeds past gate
# =====================================================================
# The case pattern [yY][eE][sS] should accept "YES".

echo ""
echo "Test 23: All-caps 'YES' proceeds past confirmation gate"
if run_repolens_tty "YES" --project "$TEST_REPO" --agent claude; then
  assert_contains "gate was shown" "Proceed?" "$RUN_OUTPUT"
  assert_not_contains "YES does not abort" "Aborted" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 2)); FAIL=$((FAIL + 2))
  echo "  FAIL: script(1) not available — skipped"
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 24: Arbitrary text (not y/n) aborts
# =====================================================================
# The * catch-all should reject anything that doesn't match y/Y/yes/YES.

echo ""
echo "Test 24: Arbitrary text 'hello' aborts"
if run_repolens_tty "hello" --project "$TEST_REPO" --agent claude; then
  assert_contains "random text aborts" "Aborted" "$RUN_OUTPUT"
  assert_exit_code "random text exit code is 0" 0 "$RUN_EXIT"
else
  TOTAL=$((TOTAL + 2)); FAIL=$((FAIL + 2))
  echo "  FAIL: script(1) not available — skipped"
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 25: Max issues count displayed when --max-issues is set
# =====================================================================
# When --max-issues is passed, the banner should show the actual number.

echo ""
echo "Test 25: Max issues count shown in confirmation prompt"
if run_repolens_tty "N" --project "$TEST_REPO" --agent claude --max-issues 5; then
  assert_contains "shows max issues value" "Max issues:" "$RUN_OUTPUT"
  assert_contains "shows actual count" "5" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 2)); FAIL=$((FAIL + 2))
  echo "  FAIL: script(1) not available — skipped"
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 26: "(unlimited)" shown when --max-issues is not set
# =====================================================================
# When --max-issues is not passed, the banner should show "(unlimited)".

echo ""
echo "Test 26: (unlimited) shown when --max-issues not set"
if run_repolens_tty "N" --project "$TEST_REPO" --agent claude; then
  assert_contains "shows unlimited" "(unlimited)" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 27: Confirmation prompt shows mode
# =====================================================================
# The banner must display "Mode:" so the user can verify the run mode.

echo ""
echo "Test 27: Confirmation prompt shows mode"
if run_repolens_tty "N" --project "$TEST_REPO" --agent claude; then
  assert_contains "prompt shows Mode:" "Mode:" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 28: Confirmation prompt shows agent
# =====================================================================
# The banner must display "Agent:" so the user can verify which agent runs.

echo ""
echo "Test 28: Confirmation prompt shows agent"
if run_repolens_tty "N" --project "$TEST_REPO" --agent claude; then
  assert_contains "prompt shows Agent:" "Agent:" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 29: Confirmation prompt shows safety warning about issues
# =====================================================================
# The banner must warn users that agents may create GitHub issues.

echo ""
echo "Test 29: Confirmation prompt shows issue creation warning"
if run_repolens_tty "N" --project "$TEST_REPO" --agent claude; then
  assert_contains "warns about issue creation" "create GitHub issues" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 30: Confirmation prompt shows agent count message
# =====================================================================
# The banner must say "This will run N analysis agent(s)" so users know scope.

echo ""
echo "Test 30: Confirmation prompt shows agent count message"
if run_repolens_tty "N" --project "$TEST_REPO" --agent claude; then
  assert_contains "shows analysis agent count" "analysis agent" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 31: Lowercase "n" aborts cleanly
# =====================================================================
# Most users will type lowercase "n". Verify it aborts via * catch-all.

echo ""
echo "Test 31: Lowercase 'n' aborts cleanly"
if run_repolens_tty "n" --project "$TEST_REPO" --agent claude; then
  assert_contains "lowercase n produces Aborted" "Aborted" "$RUN_OUTPUT"
  assert_exit_code "lowercase n exit code is 0" 0 "$RUN_EXIT"
else
  TOTAL=$((TOTAL + 2)); FAIL=$((FAIL + 2))
  echo "  FAIL: script(1) not available — skipped"
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 32: Discover mode shows correct mode in banner
# =====================================================================
# When running with --mode discover, the banner should show "discover".

echo ""
echo "Test 32: Discover mode shows correct mode in banner"
if run_repolens_tty "N" --project "$TEST_REPO" --agent claude --mode discover; then
  assert_contains "banner shows discover mode" "discover" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# --- Summary ---
echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
