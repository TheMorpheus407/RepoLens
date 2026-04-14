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

# Tests for the cost estimation and --max-cost threshold (issues #8 and #65).
# Tests are BEHAVIORAL: they execute repolens.sh and assert on exit codes + output,
# never on source code patterns.
#
# Issue #65: The estimator is now token-based and model-aware. These tests pin
# structural properties (banner label, per-MTok price lines, repo-size scaling,
# agent-differentiated pricing) rather than specific dollar amounts. Hard-coded
# dollar assertions were removed because the formula intentionally depends on
# repo size, pricing table, and iteration-factor — pinning them would ossify
# the estimator and defeat the honesty fix.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOLENS="$SCRIPT_DIR/repolens.sh"

TIMEOUT=20

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

# Run repolens.sh with a piped stdin. Used for --yes / non-interactive tests.
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

# Run with script(1) for TTY simulation. Sends a multi-line stdin so the
# autonomous-mode gate (claude), deploy-authorization gate (deploy), and
# confirm_run gate (all) each get their own answer.
#
# Usage: run_repolens_tty "stdin_data" [args...]
#   stdin_data: literal string; "\n" joined lines as needed.
# For claude + non-deploy: send "y\nN" → y accepts autonomous, N declines cost.
# For deploy + claude:    send "y\ny\nN" → autonomous, authorization, cost.
# For codex/opencode + non-deploy: send "N" is enough.
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
  printf "%b\n" "$stdin_data" | timeout "$TIMEOUT" script -qec "bash '$REPOLENS' $args_str" /dev/null >"$tmp_out" 2>&1
  RUN_EXIT=$?
  RUN_OUTPUT="$(cat "$tmp_out")"
  rm -f "$tmp_out"
  return 0
}

# Helper: extract the "Min. cost estimate" dollar amount from captured output.
# Returns the bare number (e.g. "94.50"). Empty if not found.
extract_min_cost() {
  printf "%s\n" "$1" | grep -Eo 'Min\. cost estimate[^$]*\$[0-9]+\.[0-9]+' \
    | grep -Eo '\$[0-9]+\.[0-9]+' | tr -d '$' | tail -1
}

# --- Setup test fixtures ---
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# Minimal git repo (small — few source tokens)
setup_small_repo() {
  local repo_dir="$TMPDIR/small-repo"
  mkdir -p "$repo_dir"
  git -C "$repo_dir" init -q
  git -C "$repo_dir" config user.email "test@test.com"
  git -C "$repo_dir" config user.name "Test"
  echo "test" > "$repo_dir/README.md"
  git -C "$repo_dir" add .
  git -C "$repo_dir" commit -q -m "init"
  echo "$repo_dir"
}

# Larger git repo — fixed 200 KB of Python source so the token estimator has
# a non-trivial input and the size-sensitivity test can compare against small.
setup_large_repo() {
  local repo_dir="$TMPDIR/large-repo"
  mkdir -p "$repo_dir"
  git -C "$repo_dir" init -q
  git -C "$repo_dir" config user.email "test@test.com"
  git -C "$repo_dir" config user.name "Test"
  local i
  for i in $(seq 1 20); do
    # ~10 KB per file, 20 files → ~200 KB source
    yes "def fn_${i}(x):" | head -c 10000 > "$repo_dir/mod_${i}.py"
  done
  echo "test" > "$repo_dir/README.md"
  git -C "$repo_dir" add .
  git -C "$repo_dir" commit -q -m "init"
  echo "$repo_dir"
}

SMALL_REPO="$(setup_small_repo)"
LARGE_REPO="$(setup_large_repo)"

echo ""
echo "=== Test Suite: Cost estimation and --max-cost threshold (issues #8, #65) ==="
echo ""

# =====================================================================
# Test 1: --max-cost flag is accepted by argument parser
# =====================================================================

echo "Test 1: --max-cost flag accepted by argument parser"
run_repolens --stdin "" --project "$SMALL_REPO" --agent claude --yes --max-cost 10
assert_not_contains "--max-cost not rejected as unknown" "Unknown argument: --max-cost" "$RUN_OUTPUT"

# =====================================================================
# Test 2: --help output includes --max-cost documentation
# =====================================================================

echo ""
echo "Test 2: --help mentions --max-cost flag"
help_output="$(timeout "$TIMEOUT" bash "$REPOLENS" --help 2>&1)"
assert_contains "--max-cost in help text" "--max-cost" "$help_output"

# =====================================================================
# Test 3: --max-cost requires a dollar amount argument
# =====================================================================

echo ""
echo "Test 3: --max-cost without value produces error"
run_repolens --stdin "" --project "$SMALL_REPO" --agent claude --yes --max-cost
assert_exit_code "exits with error" 1 "$RUN_EXIT"

# =====================================================================
# Test 4: Confirmation banner uses honest "Min. cost estimate" label
# =====================================================================
# Post-#65: the label was changed from "Est. cost:" to the honest
# "Min. cost estimate (lower bound — real runs typically 2–5x higher)".

echo ""
echo "Test 4: Banner shows honest Min. cost estimate label"
if run_repolens_tty "N" --project "$SMALL_REPO" --agent codex; then
  assert_contains "banner shows Min. cost estimate" "Min. cost estimate" "$RUN_OUTPUT"
  assert_contains "banner notes lower bound" "lower bound" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 2)); FAIL=$((FAIL + 2))
  echo "  FAIL: script(1) not available — skipped (x2)"
fi

# =====================================================================
# Test 5: Cost estimate contains a dollar sign
# =====================================================================

echo ""
echo "Test 5: Cost estimate contains dollar sign"
if run_repolens_tty "N" --project "$SMALL_REPO" --agent codex; then
  local_output="$(echo "$RUN_OUTPUT" | grep -i "Min. cost")"
  assert_contains "cost line has dollar sign" '$' "$local_output"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 6: Threshold warning appears when estimate exceeds --max-cost
# =====================================================================

echo ""
echo "Test 6: Threshold warning when cost exceeds --max-cost"
if run_repolens_tty "N" --project "$SMALL_REPO" --agent codex --max-cost 0.01; then
  assert_contains "warning about exceeding threshold" "WARNING" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 7: No threshold warning when --max-cost is not specified
# =====================================================================

echo ""
echo "Test 7: No threshold warning without --max-cost"
if run_repolens_tty "N" --project "$SMALL_REPO" --agent codex; then
  assert_not_contains "no 'exceeds --max-cost' warning" "exceeds --max-cost" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 8: No threshold warning when estimate is below --max-cost
# =====================================================================

echo ""
echo "Test 8: No threshold warning when cost is below --max-cost"
if run_repolens_tty "N" --project "$SMALL_REPO" --agent codex --max-cost 99999; then
  assert_not_contains "no warning when below threshold" "exceeds --max-cost" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 9: Discover mode shows lower cost than audit mode
# =====================================================================
# Discover: 14 lenses × streak 1. Audit: 210 lenses × streak 3. Discover
# must be materially cheaper.

echo ""
echo "Test 9: Discover mode cost lower than audit mode cost"
discover_cost=""
audit_cost=""
if run_repolens_tty "N" --project "$SMALL_REPO" --agent codex --mode discover; then
  discover_cost="$(extract_min_cost "$RUN_OUTPUT")"
fi
if run_repolens_tty "N" --project "$SMALL_REPO" --agent codex; then
  audit_cost="$(extract_min_cost "$RUN_OUTPUT")"
fi
TOTAL=$((TOTAL + 1))
if [[ -n "$discover_cost" && -n "$audit_cost" ]] \
   && awk -v d="$discover_cost" -v a="$audit_cost" 'BEGIN { exit !(d < a) }'; then
  PASS=$((PASS + 1))
  echo "  PASS: discover ($discover_cost) < audit ($audit_cost)"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: discover ($discover_cost) should be < audit ($audit_cost)"
fi

# =====================================================================
# Test 10: --focus single lens shows cost for 1 lens
# =====================================================================

echo ""
echo "Test 10: --focus single lens shows cost for 1 lens"
if run_repolens_tty "N" --project "$SMALL_REPO" --agent codex --focus injection; then
  assert_contains "focus shows Min. cost" "Min. cost estimate" "$RUN_OUTPUT"
  assert_contains "focus shows 1 lens" "Lenses:       1" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 2)); FAIL=$((FAIL + 2))
  echo "  FAIL: script(1) not available — skipped (x2)"
fi

# =====================================================================
# Test 11: Cost estimate shows for codex agent with GPT-5 pricing
# =====================================================================

echo ""
echo "Test 11: Cost estimate shows for codex agent"
if run_repolens_tty "N" --project "$SMALL_REPO" --agent codex; then
  assert_contains "codex banner shows Min. cost" "Min. cost estimate" "$RUN_OUTPUT"
  assert_contains "codex shows GPT-5 model label" "GPT-5" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 2)); FAIL=$((FAIL + 2))
  echo "  FAIL: script(1) not available — skipped (x2)"
fi

# =====================================================================
# Test 12: Cost estimate shows for opencode agent (fallback model)
# =====================================================================

echo ""
echo "Test 12: Cost estimate shows for opencode agent (fallback)"
if run_repolens_tty "N" --project "$SMALL_REPO" --agent opencode; then
  assert_contains "opencode banner shows Min. cost" "Min. cost estimate" "$RUN_OUTPUT"
  assert_contains "opencode falls back to Sonnet-class label" "opencode" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 2)); FAIL=$((FAIL + 2))
  echo "  FAIL: script(1) not available — skipped (x2)"
fi

# =====================================================================
# Test 13: Threshold warning mentions the configured threshold amount
# =====================================================================

echo ""
echo "Test 13: Threshold warning mentions the threshold value"
if run_repolens_tty "N" --project "$SMALL_REPO" --agent codex --max-cost 5; then
  assert_contains "warning mentions threshold value" "5" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 14: --max-cost with --yes still exits cleanly
# =====================================================================

echo ""
echo "Test 14: --max-cost with --yes exits cleanly (no crash)"
run_repolens --stdin "" --project "$SMALL_REPO" --agent claude --yes --max-cost 0.01
assert_not_contains "--max-cost with --yes does not crash" "Unknown argument" "$RUN_OUTPUT"

# =====================================================================
# Test 15: --max-cost rejects non-numeric input
# =====================================================================

echo ""
echo "Test 15: --max-cost rejects non-numeric input"
run_repolens --stdin "" --project "$SMALL_REPO" --agent claude --yes --max-cost abc
assert_exit_code "non-numeric --max-cost exits with error" 1 "$RUN_EXIT"

# =====================================================================
# Test 16: Cost estimate for discover mode shows streak 1
# =====================================================================

echo ""
echo "Test 16: Discover mode banner reflects single-pass (streak 1)"
if run_repolens_tty "N" --project "$SMALL_REPO" --agent codex --mode discover; then
  assert_contains "discover mode shows Min. cost" "Min. cost estimate" "$RUN_OUTPUT"
  assert_contains "discover shows streak 1" "streak 1" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 2)); FAIL=$((FAIL + 2))
  echo "  FAIL: script(1) not available — skipped (x2)"
fi

# =====================================================================
# Test 17: Deploy mode shows cost estimate
# =====================================================================
# Deploy adds an authorization gate before the cost banner → send y then N.

echo ""
echo "Test 17: Deploy mode shows cost estimate"
if run_repolens_tty "y\nN" --project "$SMALL_REPO" --agent codex --mode deploy; then
  assert_contains "deploy mode shows Min. cost" "Min. cost estimate" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 18: --max-cost with decimal values is accepted
# =====================================================================

echo ""
echo "Test 18: --max-cost accepts decimal values"
run_repolens --stdin "" --project "$SMALL_REPO" --agent claude --yes --max-cost 2.50
assert_not_contains "--max-cost decimal not rejected" "Unknown argument" "$RUN_OUTPUT"
assert_not_contains "--max-cost decimal does not error" "must be" "$RUN_OUTPUT"

# =====================================================================
# Test 19: Audit mode exceeds low --max-cost threshold
# =====================================================================

echo ""
echo "Test 19: Audit mode exceeds low --max-cost threshold"
if run_repolens_tty "N" --project "$SMALL_REPO" --agent codex --max-cost 0.50; then
  assert_contains "audit mode exceeds low threshold" "WARNING" "$RUN_OUTPUT"
  assert_contains "audit mode still shows Proceed?" "Proceed?" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 2)); FAIL=$((FAIL + 2))
  echo "  FAIL: script(1) not available — skipped (x2)"
fi

# =====================================================================
# Test 20: User can still proceed with y after cost warning
# =====================================================================

echo ""
echo "Test 20: User can proceed with y after cost warning"
if run_repolens_tty "y" --project "$SMALL_REPO" --agent codex --max-cost 0.01; then
  assert_not_contains "y proceeds past warning" "Aborted." "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 21: --max-cost 0 triggers warning for any non-zero cost
# =====================================================================

echo ""
echo "Test 21: --max-cost 0 triggers warning"
if run_repolens_tty "N" --project "$SMALL_REPO" --agent codex --max-cost 0; then
  assert_contains "--max-cost 0 triggers warning" "WARNING" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 22: Opensource mode shows cost estimate
# =====================================================================

echo ""
echo "Test 22: OpenSource mode shows cost estimate"
if run_repolens_tty "N" --project "$SMALL_REPO" --agent codex --mode opensource; then
  assert_contains "opensource mode shows Min. cost" "Min. cost estimate" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 23: Content mode shows cost estimate
# =====================================================================

echo ""
echo "Test 23: Content mode shows cost estimate"
if run_repolens_tty "N" --project "$SMALL_REPO" --agent codex --mode content; then
  assert_contains "content mode shows Min. cost" "Min. cost estimate" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 24: --max-cost with --domain works
# =====================================================================

echo ""
echo "Test 24: --max-cost with --domain works"
if run_repolens_tty "N" --project "$SMALL_REPO" --agent codex --domain security --max-cost 1; then
  assert_contains "domain filter shows Min. cost" "Min. cost estimate" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 25: --max-issues forces streak=1 → banner reflects that
# =====================================================================

echo ""
echo "Test 25: --max-issues affects cost estimate (streak 1)"
if run_repolens_tty "N" --project "$SMALL_REPO" --agent codex --max-issues 3; then
  assert_contains "max-issues shows Min. cost" "Min. cost estimate" "$RUN_OUTPUT"
  assert_contains "max-issues shows streak 1" "streak 1" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 2)); FAIL=$((FAIL + 2))
  echo "  FAIL: script(1) not available — skipped (x2)"
fi

# =====================================================================
# Test 26: Larger repo produces higher estimate than small repo
# =====================================================================
# New in #65: estimator samples repo bytes and feeds them into per-session
# input tokens. A 200 KB source tree MUST cost more than a 5-byte README.

echo ""
echo "Test 26: Larger repo → higher cost estimate"
small_cost=""
large_cost=""
if run_repolens_tty "N" --project "$SMALL_REPO" --agent codex --mode discover; then
  small_cost="$(extract_min_cost "$RUN_OUTPUT")"
fi
if run_repolens_tty "N" --project "$LARGE_REPO" --agent codex --mode discover; then
  large_cost="$(extract_min_cost "$RUN_OUTPUT")"
fi
TOTAL=$((TOTAL + 1))
if [[ -n "$small_cost" && -n "$large_cost" ]] \
   && awk -v s="$small_cost" -v l="$large_cost" 'BEGIN { exit !(l > s) }'; then
  PASS=$((PASS + 1))
  echo "  PASS: large ($large_cost) > small ($small_cost)"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: large ($large_cost) should be > small ($small_cost)"
fi

# =====================================================================
# Test 27: Spark agent shows Spark/GPT-5 class pricing
# =====================================================================

echo ""
echo "Test 27: Spark agent shows GPT-5 class pricing"
if run_repolens_tty "N" --project "$SMALL_REPO" --agent spark --mode discover; then
  assert_contains "spark shows Min. cost" "Min. cost estimate" "$RUN_OUTPUT"
  assert_contains "spark shows Spark label" "Spark" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 2)); FAIL=$((FAIL + 2))
  echo "  FAIL: script(1) not available — skipped (x2)"
fi

# =====================================================================
# Test 28: Audit mode banner reflects streak 3
# =====================================================================

echo ""
echo "Test 28: Audit mode banner shows streak 3"
if run_repolens_tty "N" --project "$SMALL_REPO" --agent codex; then
  assert_contains "audit banner shows streak 3" "streak 3" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 29: Feature mode banner reflects streak 3
# =====================================================================

echo ""
echo "Test 29: Feature mode banner shows streak 3"
if run_repolens_tty "N" --project "$SMALL_REPO" --agent codex --mode feature; then
  assert_contains "feature banner shows Min. cost" "Min. cost estimate" "$RUN_OUTPUT"
  assert_contains "feature banner shows streak 3" "streak 3" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 2)); FAIL=$((FAIL + 2))
  echo "  FAIL: script(1) not available — skipped (x2)"
fi

# =====================================================================
# Test 30: Bugfix mode banner reflects streak 3
# =====================================================================

echo ""
echo "Test 30: Bugfix mode banner shows streak 3"
if run_repolens_tty "N" --project "$SMALL_REPO" --agent codex --mode bugfix; then
  assert_contains "bugfix banner shows Min. cost" "Min. cost estimate" "$RUN_OUTPUT"
  assert_contains "bugfix banner shows streak 3" "streak 3" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 2)); FAIL=$((FAIL + 2))
  echo "  FAIL: script(1) not available — skipped (x2)"
fi

# =====================================================================
# Test 31: --yes mode does not display cost estimate
# =====================================================================

echo ""
echo "Test 31: --yes mode skips cost display"
run_repolens --stdin "" --project "$SMALL_REPO" --agent codex --yes --mode discover
assert_not_contains "--yes skips Min. cost line" "Min. cost estimate" "$RUN_OUTPUT"

# =====================================================================
# Test 32: --max-cost rejects negative values
# =====================================================================

echo ""
echo "Test 32: --max-cost rejects negative value"
run_repolens --stdin "" --project "$SMALL_REPO" --agent claude --yes --max-cost -5
assert_exit_code "negative --max-cost exits with error" 1 "$RUN_EXIT"

# =====================================================================
# Test 33: Different agents produce different cost estimates
# =====================================================================
# codex (GPT-5: $1.25/$10.00) and opencode-default (Sonnet-class: $3/$15)
# should produce clearly different estimates for the same mode.

echo ""
echo "Test 33: codex and opencode costs differ (different pricing)"
codex_cost=""
opencode_cost=""
if run_repolens_tty "N" --project "$SMALL_REPO" --agent codex --mode discover; then
  codex_cost="$(extract_min_cost "$RUN_OUTPUT")"
fi
if run_repolens_tty "N" --project "$SMALL_REPO" --agent opencode --mode discover; then
  opencode_cost="$(extract_min_cost "$RUN_OUTPUT")"
fi
TOTAL=$((TOTAL + 1))
if [[ -n "$codex_cost" && -n "$opencode_cost" && "$codex_cost" != "$opencode_cost" ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: codex ($codex_cost) != opencode ($opencode_cost)"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: codex ($codex_cost) should differ from opencode ($opencode_cost)"
fi

# =====================================================================
# Test 34: Cost breakdown shows per-MTok pricing (input + output)
# =====================================================================
# Replaces the old "$0.15/call" assertion. The honest breakdown shows the
# model pricing in "USD per MTok" form.

echo ""
echo "Test 34: Cost breakdown shows per-MTok pricing"
if run_repolens_tty "N" --project "$SMALL_REPO" --agent codex --mode discover; then
  assert_contains "breakdown shows 'per MTok'" "per MTok" "$RUN_OUTPUT"
  assert_contains "breakdown shows lens count" "14 lenses" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 2)); FAIL=$((FAIL + 2))
  echo "  FAIL: script(1) not available — skipped (x2)"
fi

# =====================================================================
# Test 35: opencode/<model> parses the model and picks matching pricing
# =====================================================================
# opencode/claude-opus-4-6 → Opus pricing ($15/$75), much higher than
# opencode (defaults to Sonnet-class $3/$15).

echo ""
echo "Test 35: opencode/<model> picks up model-specific pricing (Opus > default)"
default_cost=""
opus_cost=""
if run_repolens_tty "N" --project "$LARGE_REPO" --agent opencode --mode discover; then
  default_cost="$(extract_min_cost "$RUN_OUTPUT")"
fi
if run_repolens_tty "N" --project "$LARGE_REPO" --agent opencode/claude-opus-4-6 --mode discover; then
  opus_cost="$(extract_min_cost "$RUN_OUTPUT")"
fi
TOTAL=$((TOTAL + 1))
if [[ -n "$default_cost" && -n "$opus_cost" ]] \
   && awk -v d="$default_cost" -v o="$opus_cost" 'BEGIN { exit !(o > d) }'; then
  PASS=$((PASS + 1))
  echo "  PASS: opencode/opus ($opus_cost) > opencode default ($default_cost)"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: opencode/opus ($opus_cost) should be > opencode default ($default_cost)"
fi

# =====================================================================
# Test 36: opencode/<unknown-model> falls back to default pricing
# =====================================================================

echo ""
echo "Test 36: opencode/<unknown-model> falls back to default pricing"
if run_repolens_tty "N" --project "$SMALL_REPO" --agent opencode/does-not-exist --mode discover; then
  assert_contains "unknown model falls back" "opencode" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# Test 37: Banner includes the lower-bound disclaimer note
# =====================================================================

echo ""
echo "Test 37: Banner includes 'Note:' disclaimer about real cost"
if run_repolens_tty "N" --project "$SMALL_REPO" --agent codex --mode discover; then
  assert_contains "banner has Note: disclaimer" "Note:" "$RUN_OUTPUT"
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
