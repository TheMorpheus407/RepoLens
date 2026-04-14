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

# Tests for autonomous mode confirmation gate (issue #10)
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

# Helper: run with TTY and multiple lines of stdin input (for multi-prompt scenarios)
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
echo "=== Test Suite: Autonomous mode gate for --dangerously-skip-permissions (issue #10) ==="
echo ""

# =====================================================================
# SECTION A: Gate Visibility — claude-only
# =====================================================================

# =====================================================================
# Test 1: Claude agent shows "Autonomous Mode" header
# =====================================================================
# When running with --agent claude via TTY, an "Autonomous Mode" banner
# must appear as the FIRST gate before any other prompts.

echo "Test 1: Claude agent shows Autonomous Mode header"
if run_repolens_tty "N" --project "$TEST_REPO" --agent claude; then
  assert_contains "claude shows Autonomous Mode" "Autonomous Mode" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped (counts as failure for TDD)"
fi

# =====================================================================
# Test 2: Codex agent does NOT show Autonomous Mode gate
# =====================================================================
# The gate is claude-specific because only claude uses
# --dangerously-skip-permissions. Codex uses --yolo instead.

echo ""
echo "Test 2: Codex agent does NOT show Autonomous Mode gate"
if run_repolens_tty "N" --project "$TEST_REPO" --agent codex; then
  assert_not_contains "codex has no Autonomous Mode" "Autonomous Mode" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 3: Opencode agent does NOT show Autonomous Mode gate
# =====================================================================
# Opencode has no equivalent flag at all.

echo ""
echo "Test 3: Opencode agent does NOT show Autonomous Mode gate"
if run_repolens_tty "N" --project "$TEST_REPO" --agent opencode; then
  assert_not_contains "opencode has no Autonomous Mode" "Autonomous Mode" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# SECTION B: Gate Bypass
# =====================================================================

# =====================================================================
# Test 4: --yes bypasses the autonomous mode gate
# =====================================================================
# With --yes, the gate must be silently bypassed.

echo ""
echo "Test 4: --yes bypasses autonomous mode gate"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --yes
assert_not_contains "--yes skips Autonomous Mode prompt" "Autonomous Mode" "$RUN_OUTPUT"

# =====================================================================
# Test 5: -y also bypasses the autonomous mode gate
# =====================================================================

echo ""
echo "Test 5: -y bypasses autonomous mode gate"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude -y
assert_not_contains "-y skips Autonomous Mode prompt" "Autonomous Mode" "$RUN_OUTPUT"

# =====================================================================
# Test 6: --dry-run bypasses the autonomous mode gate
# =====================================================================
# Dry-run exits before any gates, so no autonomous mode prompt.

echo ""
echo "Test 6: --dry-run bypasses autonomous mode gate"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --dry-run
assert_not_contains "--dry-run skips Autonomous Mode" "Autonomous Mode" "$RUN_OUTPUT"

# =====================================================================
# Test 7: Non-interactive stdin without --yes produces error
# =====================================================================
# When stdin is not a TTY and --yes is not passed, the autonomous mode
# gate must die with an error. For claude agent, this is the first gate
# to check, so the error should reference the autonomous mode or
# --dangerously-skip-permissions.

echo ""
echo "Test 7: Non-interactive stdin without --yes produces error for claude"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude
assert_exit_code "non-interactive exits with code 1" 1 "$RUN_EXIT"

# =====================================================================
# SECTION C: Accept / Reject Behavior
# =====================================================================

# =====================================================================
# Test 8: Answer y proceeds past autonomous mode gate to cost gate
# =====================================================================
# Sending "y" for autonomous gate, then "N" for cost gate.
# Must see both prompts: Autonomous Mode and Proceed?

echo ""
echo "Test 8: Answer y proceeds past autonomous mode gate"
if run_repolens_tty_multi "y\nN" --project "$TEST_REPO" --agent claude; then
  assert_contains "autonomous gate was shown" "Autonomous Mode" "$RUN_OUTPUT"
  assert_contains "reaches cost confirmation" "Proceed?" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 2)); FAIL=$((FAIL + 2))
  echo "  FAIL: script(1) not available — skipped"
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 9: Answer Y (uppercase) proceeds past autonomous mode gate
# =====================================================================

echo ""
echo "Test 9: Answer Y (uppercase) proceeds past autonomous mode gate"
if run_repolens_tty_multi "Y\nN" --project "$TEST_REPO" --agent claude; then
  assert_contains "Y reaches cost confirmation" "Proceed?" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 10: Answer yes (full word) proceeds past autonomous mode gate
# =====================================================================

echo ""
echo "Test 10: Answer yes proceeds past autonomous mode gate"
if run_repolens_tty_multi "yes\nN" --project "$TEST_REPO" --agent claude; then
  assert_contains "yes reaches cost confirmation" "Proceed?" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 11: Answer YES (all caps) proceeds past autonomous mode gate
# =====================================================================

echo ""
echo "Test 11: Answer YES proceeds past autonomous mode gate"
if run_repolens_tty_multi "YES\nN" --project "$TEST_REPO" --agent claude; then
  assert_contains "YES reaches cost confirmation" "Proceed?" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 12: Empty input defaults to N (abort)
# =====================================================================
# Default is N — empty input should abort at the autonomous mode gate.

echo ""
echo "Test 12: Empty input to autonomous mode gate defaults to N"
if run_repolens_tty "" --project "$TEST_REPO" --agent claude; then
  assert_contains "empty input aborts" "Aborted" "$RUN_OUTPUT"
  assert_not_contains "empty input does not reach cost gate" "Proceed?" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 2)); FAIL=$((FAIL + 2))
  echo "  FAIL: script(1) not available — skipped"
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 13: Answer n aborts at autonomous mode gate
# =====================================================================

echo ""
echo "Test 13: Answer n aborts at autonomous mode gate"
if run_repolens_tty "n" --project "$TEST_REPO" --agent claude; then
  assert_contains "n aborts" "Aborted" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 14: Answer N aborts at autonomous mode gate
# =====================================================================

echo ""
echo "Test 14: Answer N aborts at autonomous mode gate"
if run_repolens_tty "N" --project "$TEST_REPO" --agent claude; then
  assert_contains "N aborts" "Aborted" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 15: Arbitrary text aborts at autonomous mode gate
# =====================================================================

echo ""
echo "Test 15: Arbitrary text aborts at autonomous mode gate"
if run_repolens_tty "hello" --project "$TEST_REPO" --agent claude; then
  assert_contains "arbitrary text aborts" "Aborted" "$RUN_OUTPUT"
  assert_exit_code "arbitrary text exit code is 0" 0 "$RUN_EXIT"
else
  TOTAL=$((TOTAL + 2)); FAIL=$((FAIL + 2))
  echo "  FAIL: script(1) not available — skipped"
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 16: Abort exit code is 0 (clean abort, not error)
# =====================================================================

echo ""
echo "Test 16: Abort at autonomous mode gate exits with code 0"
if run_repolens_tty "N" --project "$TEST_REPO" --agent claude; then
  assert_exit_code "N abort exit code is 0" 0 "$RUN_EXIT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# SECTION D: Gate Ordering
# =====================================================================

# =====================================================================
# Test 17: Autonomous mode gate appears BEFORE deploy authorization
# =====================================================================
# In deploy mode with claude agent, answering N to the autonomous mode
# gate should abort without ever showing the deploy authorization prompt.

echo ""
echo "Test 17: Autonomous mode gate appears BEFORE deploy authorization"
if run_repolens_tty "N" --project "$TEST_REPO" --agent claude --mode deploy; then
  assert_contains "autonomous gate shown" "Autonomous Mode" "$RUN_OUTPUT"
  assert_not_contains "deploy gate NOT shown (aborted at autonomous)" "Authorization Required" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 2)); FAIL=$((FAIL + 2))
  echo "  FAIL: script(1) not available — skipped"
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 18: Deploy mode with claude shows all three gates in order
# =====================================================================
# When the user passes autonomous (y) and deploy auth (y) but rejects
# cost (N), all three banners should appear in order.

echo ""
echo "Test 18: Deploy + claude shows autonomous, deploy auth, and cost gates in order"
if run_repolens_tty_multi "y\ny\nN" --project "$TEST_REPO" --agent claude --mode deploy; then
  assert_contains "autonomous gate appeared" "Autonomous Mode" "$RUN_OUTPUT"
  assert_contains "deploy auth gate appeared" "Authorization Required" "$RUN_OUTPUT"
  assert_contains "cost gate appeared" "Proceed?" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 3)); FAIL=$((FAIL + 3))
  echo "  FAIL: script(1) not available — skipped"
  echo "  FAIL: script(1) not available — skipped"
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 19: Audit mode with claude shows autonomous then cost gate
# =====================================================================
# Non-deploy mode: two gates (autonomous + cost), no deploy auth.

echo ""
echo "Test 19: Audit + claude shows autonomous gate then cost gate"
if run_repolens_tty_multi "y\nN" --project "$TEST_REPO" --agent claude; then
  assert_contains "autonomous gate appeared" "Autonomous Mode" "$RUN_OUTPUT"
  assert_not_contains "no deploy auth in audit mode" "Authorization Required" "$RUN_OUTPUT"
  assert_contains "cost gate appeared" "Proceed?" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 3)); FAIL=$((FAIL + 3))
  echo "  FAIL: script(1) not available — skipped"
  echo "  FAIL: script(1) not available — skipped"
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# SECTION E: Prompt Content
# =====================================================================

# =====================================================================
# Test 20: Prompt text contains "dangerously-skip-permissions"
# =====================================================================
# The educational purpose of the gate requires mentioning the flag by name.

echo ""
echo "Test 20: Prompt text contains dangerously-skip-permissions"
if run_repolens_tty "N" --project "$TEST_REPO" --agent claude; then
  assert_contains "prompt mentions the flag" "dangerously-skip-permissions" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 21: Prompt text clarifies that safety filters are NOT disabled
# =====================================================================
# The gate must clearly state that safety/content filters remain active.

echo ""
echo "Test 21: Prompt text clarifies safety filters are not disabled"
if run_repolens_tty "N" --project "$TEST_REPO" --agent claude; then
  assert_contains "prompt clarifies safety is intact" "does NOT disable safety" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 22: Prompt text explains what the flag actually does
# =====================================================================
# The gate must explain that the flag skips interactive permission prompts.

echo ""
echo "Test 22: Prompt explains what the flag does"
if run_repolens_tty "N" --project "$TEST_REPO" --agent claude; then
  assert_contains "prompt explains permission prompts" "permission prompts" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 23: Prompt text contains acknowledgment question
# =====================================================================
# The gate asks the user to acknowledge understanding, not just y/N.

echo ""
echo "Test 23: Prompt contains acknowledgment question"
if run_repolens_tty "N" --project "$TEST_REPO" --agent claude; then
  assert_contains "prompt has acknowledgment" "[y/N]" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# SECTION F: README FAQ
# =====================================================================

# =====================================================================
# Test 24: README contains FAQ section about --dangerously-skip-permissions
# =====================================================================
# The issue requires a README FAQ section explaining the flag.
# The section should use FAQ-style formatting (question + answer).

echo ""
echo "Test 24: README has FAQ or detailed section about the flag"
readme_content="$(cat "$SCRIPT_DIR/README.md")"
assert_contains "README explains dangerously-skip-permissions" "dangerously-skip-permissions" "$readme_content"

# =====================================================================
# Test 25: README FAQ explains the flag does NOT disable safety
# =====================================================================
# The FAQ must clarify the misconception about the flag name.

echo ""
echo "Test 25: README explains that safety filters remain active"
assert_contains "README mentions safety filters" "safety" "$readme_content"

# =====================================================================
# SECTION G: Edge Cases
# =====================================================================

# =====================================================================
# Test 26: --dry-run + deploy + claude does NOT show autonomous gate
# =====================================================================
# Dry-run exits before any gates, even in deploy mode with claude.

echo ""
echo "Test 26: --dry-run + deploy + claude does NOT show autonomous gate"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --mode deploy --dry-run
assert_not_contains "dry-run deploy skips autonomous gate" "Autonomous Mode" "$RUN_OUTPUT"
assert_exit_code "dry-run deploy exits 0" 0 "$RUN_EXIT"

# =====================================================================
# Test 27: --yes + deploy + claude skips both autonomous and deploy gates
# =====================================================================
# With --yes, BOTH the autonomous mode gate and deploy authorization
# must be silently bypassed.

echo ""
echo "Test 27: --yes skips both autonomous and deploy gates"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --mode deploy --yes
assert_not_contains "--yes skips autonomous gate" "Autonomous Mode" "$RUN_OUTPUT"
assert_not_contains "--yes skips deploy gate" "Authorization Required" "$RUN_OUTPUT"

# =====================================================================
# Test 28: Non-interactive + deploy + claude errors at autonomous gate
# =====================================================================
# The autonomous gate fires BEFORE the deploy gate. Non-interactive
# without --yes should hit the autonomous gate's non-interactive check
# first (not the deploy gate's).

echo ""
echo "Test 28: Non-interactive + deploy + claude errors at autonomous gate first"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --mode deploy
assert_exit_code "non-interactive deploy exits 1" 1 "$RUN_EXIT"
assert_contains "error mentions --yes" "--yes" "$RUN_OUTPUT"

# =====================================================================
# Test 29: Discover mode with claude shows autonomous gate
# =====================================================================
# The autonomous gate applies to ALL modes when agent is claude,
# not just audit or deploy.

echo ""
echo "Test 29: Discover mode with claude shows autonomous gate"
if run_repolens_tty "N" --project "$TEST_REPO" --agent claude --mode discover; then
  assert_contains "discover mode shows autonomous gate" "Autonomous Mode" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 30: Discover mode with codex does NOT show autonomous gate
# =====================================================================
# Codex should never see the autonomous mode gate regardless of mode.

echo ""
echo "Test 30: Discover mode with codex does NOT show autonomous gate"
if run_repolens_tty "N" --project "$TEST_REPO" --agent codex --mode discover; then
  assert_not_contains "codex discover has no autonomous gate" "Autonomous Mode" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# SECTION H: Coverage — Additional gap tests (coverage-test stage)
# =====================================================================

# =====================================================================
# Test 31: Non-interactive error message mentions --yes hint
# =====================================================================
# Test 7 only checks exit code. The message must guide the user.

echo ""
echo "Test 31: Non-interactive error message mentions --yes hint"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude
assert_contains "non-interactive error mentions --yes" "--yes" "$RUN_OUTPUT"

# =====================================================================
# Test 32: Prompt text mentions read-only enforcement
# =====================================================================
# The implementation explains that agents are restricted to read-only
# analysis. This is a key safety message.

echo ""
echo "Test 32: Prompt text mentions read-only enforcement"
if run_repolens_tty "N" --project "$TEST_REPO" --agent claude; then
  assert_contains "prompt mentions read-only" "read-only" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 33: Prompt text mentions content guardrails
# =====================================================================
# The implementation states "content guardrails" remain active.

echo ""
echo "Test 33: Prompt text mentions content guardrails"
if run_repolens_tty "N" --project "$TEST_REPO" --agent claude; then
  assert_contains "prompt mentions guardrails" "content guardrails" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 34: Prompt text mentions ethical guidelines
# =====================================================================
# The implementation states "ethical guidelines" remain active.

echo ""
echo "Test 34: Prompt text mentions ethical guidelines"
if run_repolens_tty "N" --project "$TEST_REPO" --agent claude; then
  assert_contains "prompt mentions ethical guidelines" "ethical guidelines" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 35: Prompt text mentions gh issue create
# =====================================================================
# The implementation explains agents are restricted to 'gh issue create'.

echo ""
echo "Test 35: Prompt text mentions gh issue create"
if run_repolens_tty "N" --project "$TEST_REPO" --agent claude; then
  assert_contains "prompt mentions gh issue create" "gh issue create" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 36: spark agent does NOT show Autonomous Mode gate
# =====================================================================
# spark/sparc is another supported agent type — must not see the gate.

echo ""
echo "Test 36: spark agent does NOT show Autonomous Mode gate"
if run_repolens_tty "N" --project "$TEST_REPO" --agent spark; then
  assert_not_contains "spark has no Autonomous Mode" "Autonomous Mode" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 37: Feature mode with claude shows autonomous gate
# =====================================================================
# The gate applies to ALL modes with claude, including feature mode.

echo ""
echo "Test 37: Feature mode with claude shows autonomous gate"
if run_repolens_tty "N" --project "$TEST_REPO" --agent claude --mode feature; then
  assert_contains "feature mode shows autonomous gate" "Autonomous Mode" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 38: Bugfix mode with claude shows autonomous gate
# =====================================================================
# The gate applies to ALL modes with claude, including bugfix mode.

echo ""
echo "Test 38: Bugfix mode with claude shows autonomous gate"
if run_repolens_tty "N" --project "$TEST_REPO" --agent claude --mode bugfix; then
  assert_contains "bugfix mode shows autonomous gate" "Autonomous Mode" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 39: Non-interactive error message mentions "non-interactively"
# =====================================================================
# The die message should explain WHY it's failing — not just suggest --yes.

echo ""
echo "Test 39: Non-interactive error message explains the cause"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude
assert_contains "error explains non-interactive cause" "non-interactively" "$RUN_OUTPUT"

# --- Summary ---
echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
