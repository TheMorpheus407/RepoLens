#!/usr/bin/env bash
# Copyright 2025 Bootstrap Academy
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

# Tests for deploy mode authorization prompt, --dry-run flag, and README legal section (issue #9)
# Tests are BEHAVIORAL: they execute repolens.sh and assert on exit codes + output,
# never on source code patterns.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOLENS="$SCRIPT_DIR/repolens.sh"

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
    echo "    In output (first 300 chars): ${haystack:0:300}"
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
  printf '%s\n' "$stdin_data" | timeout "$TIMEOUT" script -qec "bash '$REPOLENS' $args_str" /dev/null >"$tmp_out" 2>&1
  RUN_EXIT=$?
  RUN_OUTPUT="$(cat "$tmp_out")"
  rm -f "$tmp_out"
  return 0
}

# Helper: run with TTY and multiple lines of stdin input (for two-prompt scenarios)
# Usage: run_repolens_tty_multi "line1\nline2" [args...]
run_repolens_tty_multi() {
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
  printf '%b\n' "$stdin_data" | timeout "$TIMEOUT" script -qec "bash '$REPOLENS' $args_str" /dev/null >"$tmp_out" 2>&1
  RUN_EXIT=$?
  RUN_OUTPUT="$(cat "$tmp_out")"
  rm -f "$tmp_out"
  return 0
}

# --- Setup test fixtures ---
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

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
echo "=== Test Suite: Deploy authorization prompt, --dry-run, and README legal (issue #9) ==="
echo ""

# =====================================================================
# SECTION A: Deploy Authorization Prompt Tests
# =====================================================================

# =====================================================================
# Test 1: Deploy mode shows "Authorization Required" header
# =====================================================================
# When running with --mode deploy via TTY, an "Authorization Required"
# banner must appear BEFORE the cost confirmation gate.

echo "Test 1: Deploy mode shows Authorization Required header"
if run_repolens_tty "N" --project "$TEST_REPO" --agent claude --mode deploy; then
  assert_contains "deploy shows Authorization Required" "Authorization Required" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped (counts as failure for TDD)"
fi

# =====================================================================
# Test 2: Deploy mode shows §202a StGB warning text
# =====================================================================
# The authorization prompt must reference §202a StGB to inform users
# of the legal risk.

echo ""
echo "Test 2: Deploy mode shows §202a StGB warning text"
if run_repolens_tty "N" --project "$TEST_REPO" --agent claude --mode deploy; then
  assert_contains "deploy shows 202a" "202a" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 3: Deploy mode answer N aborts with deploy-specific message
# =====================================================================
# When the user answers N to the authorization prompt, the abort message
# must mention "deploy mode" or "authorization", not just generic "Aborted."

echo ""
echo "Test 3: Deploy mode answer N aborts with deploy-specific message"
if run_repolens_tty "N" --project "$TEST_REPO" --agent claude --mode deploy; then
  assert_contains "abort message mentions authorization" "authorization" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 4: Deploy mode answer N exits with code 0
# =====================================================================
# User-initiated abort is a clean exit, not an error.

echo ""
echo "Test 4: Deploy mode answer N exits with code 0"
if run_repolens_tty "N" --project "$TEST_REPO" --agent claude --mode deploy; then
  assert_exit_code "N abort exit code is 0" 0 "$RUN_EXIT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 5: Deploy mode answer y proceeds past authorization gate
# =====================================================================
# When the user answers y to the authorization gate, the script must
# continue to the cost confirmation gate (showing "Proceed?").
# Send "y" for auth, "N" for cost confirmation.

echo ""
echo "Test 5: Deploy mode answer y proceeds past authorization gate"
if run_repolens_tty_multi "y\nN" --project "$TEST_REPO" --agent claude --mode deploy; then
  assert_contains "reaches cost confirmation" "Proceed?" "$RUN_OUTPUT"
  assert_not_contains "no deploy authorization abort" "deploy mode requires explicit authorization" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 2)); FAIL=$((FAIL + 2))
  echo "  FAIL: script(1) not available — skipped"
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 6: Deploy mode answer Y (uppercase) proceeds past authorization
# =====================================================================
# The case pattern should accept uppercase Y.

echo ""
echo "Test 6: Deploy mode answer Y (uppercase) proceeds past authorization"
if run_repolens_tty_multi "Y\nN" --project "$TEST_REPO" --agent claude --mode deploy; then
  assert_contains "Y reaches cost confirmation" "Proceed?" "$RUN_OUTPUT"
  assert_not_contains "Y no deploy abort" "deploy mode requires explicit authorization" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 2)); FAIL=$((FAIL + 2))
  echo "  FAIL: script(1) not available — skipped"
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 7: Non-deploy modes do NOT show authorization prompt
# =====================================================================
# Audit mode (default) should go straight to cost confirmation without
# showing "Authorization Required".

echo ""
echo "Test 7: Audit mode does NOT show authorization prompt"
if run_repolens_tty "N" --project "$TEST_REPO" --agent claude; then
  assert_not_contains "no Authorization Required in audit mode" "Authorization Required" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 8: --yes bypasses deploy authorization prompt
# =====================================================================
# With --yes, the deploy authorization gate must be silently bypassed.
# The script should NOT produce any "Authorization Required" output.

echo ""
echo "Test 8: --yes bypasses deploy authorization prompt"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --mode deploy --yes
assert_not_contains "--yes skips authorization prompt" "Authorization Required" "$RUN_OUTPUT"
assert_not_contains "--yes no deploy authorization error" "authorization confirmation" "$RUN_OUTPUT"

# =====================================================================
# Test 9: -y also bypasses deploy authorization prompt
# =====================================================================

echo ""
echo "Test 9: -y bypasses deploy authorization prompt"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --mode deploy -y
assert_not_contains "-y skips authorization prompt" "Authorization Required" "$RUN_OUTPUT"
assert_not_contains "-y no deploy authorization error" "authorization confirmation" "$RUN_OUTPUT"

# =====================================================================
# Test 10: Non-interactive stdin + deploy mode produces deploy-specific error
# =====================================================================
# When stdin is not a terminal and --yes is not passed, deploy mode must
# die with an error mentioning deploy authorization, not just the generic
# non-interactive error.

echo ""
echo "Test 10: Non-interactive stdin + deploy mode produces deploy-specific error"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --mode deploy
assert_contains "deploy error mentions authorization" "authorization" "$RUN_OUTPUT"

# =====================================================================
# Test 11: Deploy mode shows cost confirmation AFTER authorization gate
# =====================================================================
# When the user passes the authorization gate (y), the regular cost
# confirmation gate must still appear with "Proceed? [y/N]".

echo ""
echo "Test 11: Deploy mode shows cost confirmation after authorization gate"
if run_repolens_tty_multi "y\nN" --project "$TEST_REPO" --agent claude --mode deploy; then
  assert_contains "auth gate appeared" "Authorization Required" "$RUN_OUTPUT"
  assert_contains "cost gate appeared after auth" "Proceed?" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 2)); FAIL=$((FAIL + 2))
  echo "  FAIL: script(1) not available — skipped"
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 12: Empty input to deploy authorization defaults to N (abort)
# =====================================================================
# The default is N — empty input should abort with the deploy-specific
# authorization abort message.

echo ""
echo "Test 12: Empty input to deploy authorization defaults to N"
if run_repolens_tty "" --project "$TEST_REPO" --agent claude --mode deploy; then
  assert_contains "empty input aborts with authorization message" "authorization" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# SECTION B: --dry-run Tests
# =====================================================================

# =====================================================================
# Test 13: --dry-run flag is accepted by argument parser
# =====================================================================
# When --dry-run is passed, the script should NOT fail with "Unknown argument".

echo ""
echo "Test 13: --dry-run flag accepted by argument parser"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --dry-run
assert_not_contains "--dry-run not rejected as unknown" "Unknown argument: --dry-run" "$RUN_OUTPUT"

# =====================================================================
# Test 14: --help output includes --dry-run documentation
# =====================================================================

echo ""
echo "Test 14: --help mentions --dry-run flag"
help_output="$(timeout "$TIMEOUT" bash "$REPOLENS" --help 2>&1)"
assert_contains "--dry-run in help text" "--dry-run" "$help_output"

# =====================================================================
# Test 15: --dry-run with deploy mode exits cleanly
# =====================================================================
# --dry-run should validate config and exit with code 0, running no agents.

echo ""
echo "Test 15: --dry-run with deploy mode exits with code 0"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --mode deploy --dry-run
assert_exit_code "--dry-run deploy exit code is 0" 0 "$RUN_EXIT"

# =====================================================================
# Test 16: --dry-run output shows "Dry Run" or "Dry run" header
# =====================================================================
# The dry-run output must indicate it's a dry run.

echo ""
echo "Test 16: --dry-run output shows Dry Run header"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --mode deploy --dry-run
assert_contains "output shows Dry Run" "Dry Run" "$RUN_OUTPUT"

# =====================================================================
# Test 17: --dry-run output shows mode, agent, and project path
# =====================================================================

echo ""
echo "Test 17: --dry-run output shows mode, agent, and project path"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --mode deploy --dry-run
assert_contains "dry-run shows Mode" "Mode:" "$RUN_OUTPUT"
assert_contains "dry-run shows Agent" "Agent:" "$RUN_OUTPUT"
assert_contains "dry-run shows Project" "Project:" "$RUN_OUTPUT"

# =====================================================================
# Test 18: --dry-run does NOT show authorization prompt
# =====================================================================
# Since no commands are executed, the authorization gate is unnecessary.

echo ""
echo "Test 18: --dry-run does NOT show authorization prompt"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --mode deploy --dry-run
assert_not_contains "--dry-run skips authorization prompt" "Authorization Required" "$RUN_OUTPUT"
assert_not_contains "--dry-run skips authorization read" "I confirm I am authorized" "$RUN_OUTPUT"

# =====================================================================
# Test 19: --dry-run does NOT show cost confirmation prompt
# =====================================================================
# Dry run should not ask the user to proceed.

echo ""
echo "Test 19: --dry-run does NOT show Proceed? prompt"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --mode deploy --dry-run
assert_not_contains "--dry-run skips Proceed?" "Proceed?" "$RUN_OUTPUT"

# =====================================================================
# Test 20: --dry-run with audit mode also works
# =====================================================================
# --dry-run is a global flag, not deploy-specific.

echo ""
echo "Test 20: --dry-run with audit mode works"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --dry-run
assert_not_contains "audit --dry-run not rejected" "Unknown argument: --dry-run" "$RUN_OUTPUT"
assert_exit_code "audit --dry-run exit code is 0" 0 "$RUN_EXIT"

# =====================================================================
# Test 21: --dry-run with discover mode also works
# =====================================================================

echo ""
echo "Test 21: --dry-run with discover mode works"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --mode discover --dry-run
assert_not_contains "discover --dry-run not rejected" "Unknown argument: --dry-run" "$RUN_OUTPUT"
assert_exit_code "discover --dry-run exit code is 0" 0 "$RUN_EXIT"

# =====================================================================
# Test 22: --dry-run + --focus shows single lens
# =====================================================================
# When --focus narrows to one lens, dry-run output should reflect that.

echo ""
echo "Test 22: --dry-run + --focus shows single lens"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --dry-run --focus injection
assert_contains "--dry-run focus shows Lenses" "Lenses:" "$RUN_OUTPUT"
assert_contains "--dry-run focus shows 1 lens" "Lenses:       1" "$RUN_OUTPUT"

# =====================================================================
# Test 23: --dry-run + --domain shows domain lenses only
# =====================================================================

echo ""
echo "Test 23: --dry-run + --domain shows domain lenses"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --dry-run --domain security
assert_contains "--dry-run domain shows Lenses" "Lenses:" "$RUN_OUTPUT"

# =====================================================================
# Test 24: --dry-run validates project path (invalid path produces error)
# =====================================================================
# Even in dry-run mode, an invalid project path should produce an error.

echo ""
echo "Test 24: --dry-run with invalid project path produces error"
run_repolens --stdin "" --project "/nonexistent/path/that/does/not/exist" --agent claude --dry-run
assert_exit_code "invalid path exits non-zero" 1 "$RUN_EXIT"

# =====================================================================
# SECTION C: README Legal Verification
# =====================================================================

# =====================================================================
# Test 25: README contains §202a StGB reference
# =====================================================================
# The README Legal section must reference §202a StGB after implementation.

echo ""
echo "Test 25: README contains 202a StGB reference"
readme_content="$(cat "$SCRIPT_DIR/README.md")"
assert_contains "README mentions 202a" "202a" "$readme_content"

# =====================================================================
# SECTION D: Additional coverage (coverage-test stage)
# =====================================================================

# =====================================================================
# Test 26: Deploy mode accepts full-word "yes" (lowercase)
# =====================================================================
# The case pattern [yY][eE][sS] should accept "yes", not just "y".

echo ""
echo "Test 26: Deploy mode accepts full-word yes (lowercase)"
if run_repolens_tty_multi "yes\nN" --project "$TEST_REPO" --agent claude --mode deploy; then
  assert_contains "yes reaches cost confirmation" "Proceed?" "$RUN_OUTPUT"
  assert_not_contains "yes no deploy abort" "deploy mode requires explicit authorization" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 2)); FAIL=$((FAIL + 2))
  echo "  FAIL: script(1) not available — skipped"
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 27: Deploy mode rejects arbitrary text (not just N or empty)
# =====================================================================
# Any input other than y/Y/yes/YES should abort.

echo ""
echo "Test 27: Deploy mode rejects arbitrary text"
if run_repolens_tty "no" --project "$TEST_REPO" --agent claude --mode deploy; then
  assert_contains "arbitrary text aborts with authorization message" "authorization" "$RUN_OUTPUT"
  assert_exit_code "arbitrary text exit code is 0" 0 "$RUN_EXIT"
else
  TOTAL=$((TOTAL + 2)); FAIL=$((FAIL + 2))
  echo "  FAIL: script(1) not available — skipped"
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 28: --dry-run output shows "Lenses that would run:" line
# =====================================================================

echo ""
echo "Test 28: --dry-run output shows Lenses that would run line"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --dry-run
assert_contains "dry-run shows lens listing header" "Lenses that would run" "$RUN_OUTPUT"

# =====================================================================
# Test 29: --dry-run output shows completion message
# =====================================================================

echo ""
echo "Test 29: --dry-run output shows no agents were executed message"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --dry-run
assert_contains "dry-run shows completion message" "no agents were executed" "$RUN_OUTPUT"

# =====================================================================
# Test 30: --dry-run + --yes combination works
# =====================================================================
# Both flags should coexist without conflict.

echo ""
echo "Test 30: --dry-run + --yes combination works"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --mode deploy --dry-run --yes
assert_exit_code "--dry-run + --yes exit code is 0" 0 "$RUN_EXIT"
assert_contains "--dry-run + --yes shows Dry Run" "Dry Run" "$RUN_OUTPUT"

# =====================================================================
# Test 31: --dry-run + deploy + non-interactive stdin does NOT trigger auth error
# =====================================================================
# Since dry-run exits before the authorization gate, non-interactive stdin
# with deploy mode should succeed, not die with the auth error.

echo ""
echo "Test 31: --dry-run + deploy + non-interactive stdin succeeds"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --mode deploy --dry-run
assert_not_contains "no auth error in dry-run" "authorization confirmation" "$RUN_OUTPUT"
assert_exit_code "dry-run deploy non-interactive exit 0" 0 "$RUN_EXIT"

# =====================================================================
# Test 32: Deploy mode accepts "YES" (all caps)
# =====================================================================
# The case pattern [yY][eE][sS] should accept "YES".

echo ""
echo "Test 32: Deploy mode accepts YES (all caps)"
if run_repolens_tty_multi "YES\nN" --project "$TEST_REPO" --agent claude --mode deploy; then
  assert_contains "YES reaches cost confirmation" "Proceed?" "$RUN_OUTPUT"
  assert_not_contains "YES no deploy abort" "deploy mode requires explicit authorization" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 2)); FAIL=$((FAIL + 2))
  echo "  FAIL: script(1) not available — skipped"
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 33: Non-interactive deploy error includes --yes hint
# =====================================================================
# The error message must tell the user about --yes so CI pipelines can
# easily discover the bypass. Tests the actionable part of the error.

echo ""
echo "Test 33: Non-interactive deploy error includes --yes hint"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --mode deploy
assert_contains "deploy error mentions --yes" "--yes" "$RUN_OUTPUT"

# =====================================================================
# Test 34: Deploy authorization warning mentions CFAA
# =====================================================================
# The warning text should reference both §202a StGB and CFAA.

echo ""
echo "Test 34: Deploy authorization warning mentions CFAA"
if run_repolens_tty "N" --project "$TEST_REPO" --agent claude --mode deploy; then
  assert_contains "deploy warning mentions CFAA" "Computer Fraud and Abuse Act" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 35: README contains CFAA reference
# =====================================================================
# The enhanced Legal section should reference CFAA in addition to §202a.

echo ""
echo "Test 35: README contains CFAA reference"
assert_contains "README mentions CFAA" "CFAA" "$readme_content"

# =====================================================================
# Test 36: README contains EU Directive reference
# =====================================================================

echo ""
echo "Test 36: README contains EU Directive reference"
assert_contains "README mentions EU Directive" "2013/40/EU" "$readme_content"

# =====================================================================
# Test 37: Dry-run shows lens count in general audit mode
# =====================================================================
# Verify "Lenses:" line appears in non-focus dry-run output too.

echo ""
echo "Test 37: Dry-run shows lens count in general audit mode"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --dry-run
assert_contains "dry-run shows Lenses count" "Lenses:" "$RUN_OUTPUT"

# =====================================================================
# Test 38: Discover mode does NOT show authorization prompt
# =====================================================================
# Only deploy mode should show the authorization gate.

echo ""
echo "Test 38: Discover mode does NOT show authorization prompt"
if run_repolens_tty "N" --project "$TEST_REPO" --agent claude --mode discover; then
  assert_not_contains "no Authorization Required in discover mode" "Authorization Required" "$RUN_OUTPUT"
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
