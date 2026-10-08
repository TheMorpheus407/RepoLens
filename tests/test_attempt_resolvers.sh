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

# Coverage tests for issue #375 — the two pure resolvers that feed
# attempts.json (and, for the exit code, the real process exit ladder):
#   - resolve_run_exit_code   (repolens.sh) — maps the resolved run state to the
#                             process exit code that BOTH attempts.json.exit_code
#                             and the exit ladder use, so they can never drift.
#   - resolve_why_stopped     (repolens.sh) — prefers summary.json.stopped_reason
#                             and, when empty, falls back to whichever abort
#                             sentinel is on disk (or interrupted-<signal>).
#
# WHY THIS FILE EXISTS (gap analysis vs. the #375 tests already in the tree):
#   tests/test_attempts_stop_reason.sh drives repolens.sh end-to-end and only
#   reaches the LENS rate-limit branch (exit 3, why_stopped from a present
#   stopped_reason) and the clean-finish branch (exit 0). The remaining branches
#   of BOTH resolvers are unexercised:
#     resolve_run_exit_code:  interrupted -> $REPOLENS_INTERRUPT_EXIT_CODE,
#       phase rate-limit -> 1, agent-no-progress/systemic -> 1, rounds-rc
#       passthrough, broken-health -> 2 (+ the degenerate override -> 0), and
#       the branch ORDERING (interrupted and rate-limit win over later branches).
#     resolve_why_stopped:    the entire sentinel FALLBACK ladder
#       (rate-limit / agent-no-progress / systemic-failure / interrupted-<sig>)
#       fires only when stopped_reason is empty — a path the integration test
#       (which always carries stopped_reason "rate-limited") never hits. The
#       #375 test-dev summary explicitly left this fallback "to code review".
#
# Both resolvers are PURE (no side effects), so we exercise the REAL production
# code by extracting the contiguous helper block from the live repolens.sh and
# sourcing it — the same extract-and-source convention as
# tests/test_forge_warn_dedup.sh:323. No copy of the logic lives in this test,
# so the asserts track repolens.sh automatically. NO real model is involved.

# The control globals below (REPOLENS_FINAL_STATE, REPOLENS_INTERRUPT_EXIT_CODE,
# RUN_ROUNDS_RC, RUN_HEALTH, REPOLENS_ALLOW_DEGENERATE) are read by the resolver
# functions sourced from repolens.sh at runtime; ShellCheck cannot follow that
# source boundary and flags them as unused.
# shellcheck disable=SC2034

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMP_PARENT="$SCRIPT_DIR/logs/test-attempt-resolvers"
mkdir -p "$TMP_PARENT"
TMPDIR="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"

# shellcheck disable=SC2329  # cleanup is invoked indirectly via 'trap cleanup EXIT' below.
cleanup() {
  rm -rf "$TMPDIR"
  rmdir "$TMP_PARENT" 2>/dev/null || true
}
trap cleanup EXIT

PASS=0
FAIL=0
TOTAL=0

pass_with() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

fail_with() {
  local desc="$1" detail="${2:-}"
  FAIL=$((FAIL + 1))
  echo "  FAIL: $desc"
  if [[ -n "$detail" ]]; then
    printf '    %s\n' "$detail"
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected: [$expected] | Actual: [$actual]"
  fi
}

echo ""
echo "=== Test Suite: attempt resolvers (resolve_run_exit_code / resolve_why_stopped, issue #375) ==="
echo ""

# ---------------------------------------------------------------------------
# Extract the contiguous resolver block from the live repolens.sh and source
# it. The block runs from rate_limit_abort_stopped_reason() (the first helper
# resolve_run_exit_code depends on) through resolve_why_stopped(); we cut at the
# next function (apply_rate_limit_abort_final_state) and drop that trailing line.
# ---------------------------------------------------------------------------
SNIPPET="$TMPDIR/resolvers.sh"
sed -n '/^rate_limit_abort_stopped_reason() {/,/^apply_rate_limit_abort_final_state() {/p' \
  "$SCRIPT_DIR/repolens.sh" | sed '$d' > "$SNIPPET"

snippet_lines=$(grep -c '' "$SNIPPET" 2>/dev/null || printf 0)
assert_eq "resolver block was extracted from repolens.sh (>= 40 lines)" "ok" \
  "$([[ "${snippet_lines:-0}" -ge 40 ]] && echo ok || echo "missing ($snippet_lines lines)")"
assert_eq "extracted block defines resolve_run_exit_code" "ok" \
  "$(grep -q '^resolve_run_exit_code() {' "$SNIPPET" && echo ok || echo missing)"
assert_eq "extracted block defines resolve_why_stopped" "ok" \
  "$(grep -q '^resolve_why_stopped() {' "$SNIPPET" && echo ok || echo missing)"
assert_eq "extracted block does NOT bleed into the next function" "ok" \
  "$(grep -q '^apply_rate_limit_abort_final_state' "$SNIPPET" && echo leaked || echo ok)"

# shellcheck source=/dev/null
source "$SNIPPET"

# Controlled state the resolvers read. LOG_BASE holds the abort sentinels;
# SUMMARY_FILE holds stopped_reason. reset_state() clears everything to the
# clean-finish baseline before each case so a case only sets what it needs.
LOG_BASE="$TMPDIR/logbase"
SUMMARY_FILE="$TMPDIR/summary.json"
mkdir -p "$LOG_BASE"

reset_state() {
  rm -f "$LOG_BASE/.rate-limit-abort" \
        "$LOG_BASE/.agent-no-progress-abort" \
        "$LOG_BASE/.systemic-failure-abort" \
        "$SUMMARY_FILE"
  REPOLENS_FINAL_STATE="finished"
  REPOLENS_INTERRUPT_EXIT_CODE="130"
  RUN_ROUNDS_RC="0"
  RUN_HEALTH="ok"
  REPOLENS_ALLOW_DEGENERATE="false"
  REPOLENS_ROUND_FAILURE_REASON=""
}

# write_summary_reason <reason> — valid summary.json carrying a stopped_reason.
write_summary_reason() {
  printf '{"stopped_reason":"%s"}\n' "$1" > "$SUMMARY_FILE"
}

# ===========================================================================
# resolve_run_exit_code — the full branch table + ordering.
# ===========================================================================
echo "resolve_run_exit_code: full branch table"

reset_state
REPOLENS_FINAL_STATE="finished"
assert_eq "clean finished run exits 0" "0" "$(resolve_run_exit_code)"

reset_state
REPOLENS_FINAL_STATE="interrupted"
REPOLENS_INTERRUPT_EXIT_CODE="130"
assert_eq "interrupted run exits REPOLENS_INTERRUPT_EXIT_CODE (130, SIGINT)" \
  "130" "$(resolve_run_exit_code)"

reset_state
REPOLENS_FINAL_STATE="interrupted"
REPOLENS_INTERRUPT_EXIT_CODE="143"
assert_eq "interrupted run honours a non-default signal code (143, SIGTERM)" \
  "143" "$(resolve_run_exit_code)"

reset_state
: > "$LOG_BASE/.rate-limit-abort"
write_summary_reason "rate-limited"
assert_eq "LENS rate-limit (stopped_reason 'rate-limited') exits 3" \
  "3" "$(resolve_run_exit_code)"

reset_state
: > "$LOG_BASE/.rate-limit-abort"
write_summary_reason "rate-limited-deploy"
assert_eq "PHASE rate-limit (stopped_reason 'rate-limited-*') exits 1" \
  "1" "$(resolve_run_exit_code)"

reset_state
: > "$LOG_BASE/.rate-limit-abort"
# No summary at all -> rate_limit_abort_stopped_reason returns "" -> not a phase
# match -> the lens default (3), never a crash on the missing file.
assert_eq "rate-limit sentinel with no summary falls back to the lens code (3)" \
  "3" "$(resolve_run_exit_code)"

reset_state
: > "$LOG_BASE/.agent-no-progress-abort"
assert_eq "agent-no-progress abort exits 1" "1" "$(resolve_run_exit_code)"

reset_state
: > "$LOG_BASE/.systemic-failure-abort"
assert_eq "systemic-failure abort exits 1" "1" "$(resolve_run_exit_code)"

reset_state
RUN_ROUNDS_RC="42"
assert_eq "a non-zero RUN_ROUNDS_RC passes through verbatim (42)" \
  "42" "$(resolve_run_exit_code)"

reset_state
RUN_HEALTH="broken"
assert_eq "broken health exits 2" "2" "$(resolve_run_exit_code)"

reset_state
RUN_HEALTH="broken"
REPOLENS_ALLOW_DEGENERATE="true"
assert_eq "broken health with REPOLENS_ALLOW_DEGENERATE=true is overridden to 0" \
  "0" "$(resolve_run_exit_code)"

# --- ordering: earlier branches win over later ones (mirrors the exit ladder) ---
echo ""
echo "resolve_run_exit_code: branch ordering matches the exit ladder"

reset_state
REPOLENS_FINAL_STATE="interrupted"
REPOLENS_INTERRUPT_EXIT_CODE="130"
: > "$LOG_BASE/.rate-limit-abort"
write_summary_reason "rate-limited"
assert_eq "interrupted wins over a present rate-limit sentinel (130, not 3)" \
  "130" "$(resolve_run_exit_code)"

reset_state
: > "$LOG_BASE/.rate-limit-abort"
: > "$LOG_BASE/.agent-no-progress-abort"
write_summary_reason "rate-limited"
assert_eq "rate-limit sentinel wins over a co-present no-progress sentinel (3, not 1)" \
  "3" "$(resolve_run_exit_code)"

reset_state
: > "$LOG_BASE/.agent-no-progress-abort"
RUN_ROUNDS_RC="7"
RUN_HEALTH="broken"
assert_eq "no-progress sentinel wins over rounds-rc and broken health (1)" \
  "1" "$(resolve_run_exit_code)"

reset_state
RUN_ROUNDS_RC="9"
RUN_HEALTH="broken"
assert_eq "rounds-rc wins over broken health (9, not 2)" \
  "9" "$(resolve_run_exit_code)"

# ===========================================================================
# resolve_why_stopped — stopped_reason preference + the sentinel fallback ladder.
# ===========================================================================
echo ""
echo "resolve_why_stopped: stopped_reason preference"

reset_state
write_summary_reason "rate-limited"
assert_eq "a present stopped_reason is returned verbatim" \
  "rate-limited" "$(resolve_why_stopped)"

reset_state
write_summary_reason "weekly limit reached"
assert_eq "an arbitrary stopped_reason string is returned verbatim" \
  "weekly limit reached" "$(resolve_why_stopped)"

# Preference over the fallback: stopped_reason present AND a sentinel on disk ->
# the summary reason wins, the fallback never fires.
reset_state
write_summary_reason "rate-limited"
: > "$LOG_BASE/.agent-no-progress-abort"
assert_eq "stopped_reason takes precedence over a co-present abort sentinel" \
  "rate-limited" "$(resolve_why_stopped)"

echo ""
echo "resolve_why_stopped: sentinel fallback ladder (empty stopped_reason)"

reset_state
: > "$LOG_BASE/.rate-limit-abort"
assert_eq "empty stopped_reason + rate-limit sentinel -> 'rate-limit'" \
  "rate-limit" "$(resolve_why_stopped)"

reset_state
: > "$LOG_BASE/.agent-no-progress-abort"
assert_eq "empty stopped_reason + no-progress sentinel -> 'agent-no-progress'" \
  "agent-no-progress" "$(resolve_why_stopped)"

reset_state
: > "$LOG_BASE/.systemic-failure-abort"
assert_eq "empty stopped_reason + systemic sentinel -> 'systemic-failure'" \
  "systemic-failure" "$(resolve_why_stopped)"

# Fallback ordering: rate-limit checked before no-progress.
reset_state
: > "$LOG_BASE/.rate-limit-abort"
: > "$LOG_BASE/.agent-no-progress-abort"
assert_eq "fallback prefers rate-limit over a co-present no-progress sentinel" \
  "rate-limit" "$(resolve_why_stopped)"

echo ""
echo "resolve_why_stopped: interrupted-<signal> fallback"

reset_state
REPOLENS_FINAL_STATE="interrupted"
REPOLENS_INTERRUPT_EXIT_CODE="130"
assert_eq "interrupted + exit 130 -> 'interrupted-sigint'" \
  "interrupted-sigint" "$(resolve_why_stopped)"

reset_state
REPOLENS_FINAL_STATE="interrupted"
REPOLENS_INTERRUPT_EXIT_CODE="129"
assert_eq "interrupted + exit 129 -> 'interrupted-sighup'" \
  "interrupted-sighup" "$(resolve_why_stopped)"

reset_state
REPOLENS_FINAL_STATE="interrupted"
REPOLENS_INTERRUPT_EXIT_CODE="143"
assert_eq "interrupted + exit 143 -> 'interrupted-sigterm'" \
  "interrupted-sigterm" "$(resolve_why_stopped)"

reset_state
REPOLENS_FINAL_STATE="interrupted"
REPOLENS_INTERRUPT_EXIT_CODE="137"
assert_eq "interrupted + an unmapped code -> 'interrupted-sigint' (default arm)" \
  "interrupted-sigint" "$(resolve_why_stopped)"

# A present sentinel is preferred over the interrupted classification (sentinel
# branches are checked before the interrupted branch in resolve_why_stopped).
reset_state
REPOLENS_FINAL_STATE="interrupted"
REPOLENS_INTERRUPT_EXIT_CODE="143"
: > "$LOG_BASE/.rate-limit-abort"
assert_eq "an abort sentinel wins over the interrupted classification" \
  "rate-limit" "$(resolve_why_stopped)"

echo ""
echo "resolve_why_stopped: clean run yields an empty why_stopped"

reset_state
assert_eq "no stopped_reason, no sentinel, not interrupted -> empty string" \
  "" "$(resolve_why_stopped)"

echo ""
echo "callback failure reporting survives absent persistence"
reset_state
RUN_ROUNDS_RC=1
REPOLENS_ROUND_FAILURE_REASON=lens-execution-failed
assert_eq "callback failure exit is nonzero without stored markers or reason" 1 "$(resolve_run_exit_code)"
assert_eq "callback reason falls back to parent memory" lens-execution-failed "$(resolve_why_stopped)"
write_summary_reason prompt-render-failed
assert_eq "saved detail wins over generic callback reason" prompt-render-failed "$(resolve_why_stopped)"
reset_state
RUN_ROUNDS_RC=1
REPOLENS_ROUND_FAILURE_REASON=lens-execution-failed
: > "$LOG_BASE/.rate-limit-abort"
assert_eq "rate-limit exit retains precedence over callback error" 3 "$(resolve_run_exit_code)"
assert_eq "rate-limit reason retains precedence over callback error" rate-limit "$(resolve_why_stopped)"
reset_state
RUN_ROUNDS_RC=1
REPOLENS_ROUND_FAILURE_REASON=lens-execution-failed
REPOLENS_FINAL_STATE=interrupted
REPOLENS_INTERRUPT_EXIT_CODE=143
assert_eq "interruption exit retains precedence over callback error" 143 "$(resolve_run_exit_code)"
assert_eq "interruption reason retains precedence over callback error" interrupted-sigterm "$(resolve_why_stopped)"

echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
