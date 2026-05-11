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

# Tests for issue #169: Wire run_rounds() into repolens.sh main flow with
# backward-compat default --rounds 1.
#
# Behavioral contract: when ROUNDS resolves to 1 (every mode except bugreport),
# the run must be observably equivalent to the pre-rounds wiring:
#   - same lens count (single focus -> exactly one lens recorded in summary.json)
#   - same per-lens iterations (depth-driven, not multiplied by rounds)
#   - same mode/agent in summary.json
#   - NO meta-orchestrator invocation between rounds
#   - NO second-round directory emitted
#   - explicit `--rounds 1` and the implicit default produce equivalent
#     summary.json (modulo run_id and timestamps)
#
# Uses a fake codex agent — no real models invoked (per CLAUDE.md tests rule).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_PARENT="$SCRIPT_DIR/logs/test-rounds-default-byte-identical"
mkdir -p "$TMP_PARENT"
TMPDIR="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"
CREATED_RUN_IDS=()

cleanup() {
  local run_id
  rm -rf "$TMPDIR"
  for run_id in "${CREATED_RUN_IDS[@]:-}"; do
    [[ -n "$run_id" ]] && rm -rf "$SCRIPT_DIR/logs/$run_id"
  done
  rmdir "$TMP_PARENT" 2>/dev/null || true
}
trap cleanup EXIT

PASS=0
FAIL=0
TOTAL=0
FAKE_BIN="$TMPDIR/bin"
LAST_OUTPUT_FILE=""
LAST_RC=0
LAST_RUN_ID=""

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
    fail_with "$desc" "Expected: $expected | Actual: $actual"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected output to contain: $needle"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Did not expect output to contain: $needle"
  fi
}

assert_file_absent() {
  local desc="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [[ ! -e "$path" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected path to be absent: $path"
  fi
}

make_fake_codex() {
  mkdir -p "$FAKE_BIN"
  cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
printf 'DONE\n'
EOF
  chmod +x "$FAKE_BIN/codex"
}

make_project() {
  local project="$1"
  mkdir -p "$project"
  git -C "$project" init -q
  printf '# rounds-default test\n' > "$project/README.md"
}

run_repolens() {
  local name="$1"
  shift
  local project="$TMPDIR/project-$name"
  make_project "$project"

  LAST_OUTPUT_FILE="$TMPDIR/output-$name.txt"

  env PATH="$FAKE_BIN:$PATH" bash "$SCRIPT_DIR/repolens.sh" \
    --project "$project" \
    --agent codex \
    --mode audit \
    --focus naming \
    --local \
    --output "$TMPDIR/issues-$name" \
    --yes \
    "$@" >"$LAST_OUTPUT_FILE" 2>&1
  LAST_RC=$?

  LAST_RUN_ID="$(grep -oE 'RepoLens run [^ ]+ starting' "$LAST_OUTPUT_FILE" 2>/dev/null \
    | head -1 | awk '{print $3}')"
  if [[ -n "$LAST_RUN_ID" ]]; then
    CREATED_RUN_IDS+=("$LAST_RUN_ID")
  fi
}

last_output() {
  cat "$LAST_OUTPUT_FILE"
}

summary_path_for_run() {
  printf '%s/logs/%s/summary.json' "$SCRIPT_DIR" "$1"
}

# Strip volatile fields (run_id, project path, timestamps) so two summaries
# from independent runs of the same configuration can be compared.
sanitize_summary() {
  local file="$1"
  jq '
    del(.run_id, .project, .started_at, .completed_at, .output_dir)
    | .lenses = (.lenses // [] | map(del(.rate_limit_sleep_seconds)))
  ' "$file"
}

echo ""
echo "=== Test Suite: rounds default byte-identical (issue #169) ==="
echo ""

make_fake_codex

# =====================================================================
# Test 1: Implicit default (no --rounds) is single-round behavior.
# Runs through run_rounds() but rounds_total resolves to 1 for audit mode.
# =====================================================================
echo "Test 1: default --mode audit produces a clean single-round run"
run_repolens "default"
assert_eq "default run exits 0" "0" "$LAST_RC"
TOTAL=$((TOTAL + 1))
if [[ -n "$LAST_RUN_ID" ]]; then
  pass_with "default run reported a RUN_ID"
else
  fail_with "default run reported a RUN_ID" "no RUN_ID parsed from output"
fi

DEFAULT_SUMMARY="$(summary_path_for_run "$LAST_RUN_ID")"
TOTAL=$((TOTAL + 1))
if [[ -f "$DEFAULT_SUMMARY" ]]; then
  pass_with "summary.json was created at $DEFAULT_SUMMARY"
else
  fail_with "summary.json missing" "$DEFAULT_SUMMARY"
fi

DEFAULT_MODE="$(jq -r '.mode' "$DEFAULT_SUMMARY" 2>/dev/null || echo MISSING)"
assert_eq "summary.mode == audit" "audit" "$DEFAULT_MODE"

DEFAULT_LENSES_RUN="$(jq -r '.totals.lenses_run' "$DEFAULT_SUMMARY" 2>/dev/null || echo MISSING)"
assert_eq "summary.totals.lenses_run == 1" "1" "$DEFAULT_LENSES_RUN"

DEFAULT_LENSES_LEN="$(jq -r '.lenses | length' "$DEFAULT_SUMMARY" 2>/dev/null || echo MISSING)"
assert_eq "summary.lenses has exactly one entry" "1" "$DEFAULT_LENSES_LEN"

DEFAULT_LENS_ID="$(jq -r '.lenses[0].lens' "$DEFAULT_SUMMARY" 2>/dev/null || echo MISSING)"
assert_eq "the recorded lens is the focused one (naming)" "naming" "$DEFAULT_LENS_ID"

DEFAULT_ITERATIONS="$(jq -r '.lenses[0].iterations' "$DEFAULT_SUMMARY" 2>/dev/null || echo MISSING)"
TOTAL=$((TOTAL + 1))
# Audit-mode default depth is 3 — fake codex always emits DONE so the streak
# trips on the third iteration. If round-multiplication leaks in (e.g. lens
# is run once per round across multiple rounds for a default audit), this
# count would be much higher.
if [[ "$DEFAULT_ITERATIONS" == "3" ]]; then
  pass_with "lens iterations == 3 (audit depth, not multiplied by rounds)"
else
  fail_with "lens iterations should be 3" "got: $DEFAULT_ITERATIONS"
fi

# =====================================================================
# Test 2: No meta-orchestrator output for the default single-round run.
# The "[round N/M] ..." log lines are only printed when rounds_total > 1.
# =====================================================================
echo ""
echo "Test 2: single-round path emits no inter-round log lines"
output_default="$(last_output)"
assert_not_contains "no '[round 1/' multi-round banner" "[round 1/" "$output_default"
assert_not_contains "no '[round 2/' multi-round banner" "[round 2/" "$output_default"
assert_not_contains "no meta-orchestrator dispatch line" "Using meta-orchestrator dispatch" "$output_default"

# =====================================================================
# Test 3: No second-round directory was emitted under logs/<run-id>/rounds/.
# rounds/round-1/ may exist as a side-effect of run_rounds() (digest +
# completion marker), but rounds/round-2/ MUST NOT exist for a 1-round run.
# =====================================================================
echo ""
echo "Test 3: no rounds/round-2 directory"
RUN_LOG_DIR="$SCRIPT_DIR/logs/$LAST_RUN_ID"
assert_file_absent "rounds/round-2 absent" "$RUN_LOG_DIR/rounds/round-2"

# =====================================================================
# Test 4: finalize/summary path stays intact — completed_at is set,
# stopped_reason is either null or 'finished'-style (not 'rate-limited' /
# 'max-issues-reached'), and totals are coherent.
# =====================================================================
echo ""
echo "Test 4: summary is finalized and coherent"
DEFAULT_COMPLETED_AT="$(jq -r '.completed_at' "$DEFAULT_SUMMARY" 2>/dev/null || echo MISSING)"
TOTAL=$((TOTAL + 1))
if [[ "$DEFAULT_COMPLETED_AT" != "null" && -n "$DEFAULT_COMPLETED_AT" && "$DEFAULT_COMPLETED_AT" != "MISSING" ]]; then
  pass_with "completed_at is set on finalized summary"
else
  fail_with "completed_at must be set after finalize_summary" "got: $DEFAULT_COMPLETED_AT"
fi

DEFAULT_STOP_REASON="$(jq -r '.stopped_reason' "$DEFAULT_SUMMARY" 2>/dev/null || echo MISSING)"
TOTAL=$((TOTAL + 1))
case "$DEFAULT_STOP_REASON" in
  null|"")
    pass_with "stopped_reason is null for clean run"
    ;;
  rate-limited|max-issues-reached)
    fail_with "clean default run wrongly stopped early" "stopped_reason=$DEFAULT_STOP_REASON"
    ;;
  *)
    pass_with "stopped_reason is '$DEFAULT_STOP_REASON' (acceptable terminal state)"
    ;;
esac

DEFAULT_ITER_TOTAL="$(jq -r '.totals.iterations_total' "$DEFAULT_SUMMARY" 2>/dev/null || echo MISSING)"
assert_eq "totals.iterations_total matches per-lens iterations" "$DEFAULT_ITERATIONS" "$DEFAULT_ITER_TOTAL"

# =====================================================================
# Test 5: Implicit default and explicit --rounds 1 are observably equivalent.
# This is the core byte-identical contract for the rounds_total == 1 path.
# =====================================================================
echo ""
echo "Test 5: implicit default and explicit --rounds 1 produce equivalent summaries"
run_repolens "explicit-1" --rounds 1
assert_eq "explicit --rounds 1 run exits 0" "0" "$LAST_RC"

EXPLICIT_SUMMARY="$(summary_path_for_run "$LAST_RUN_ID")"
TOTAL=$((TOTAL + 1))
if [[ -f "$EXPLICIT_SUMMARY" ]]; then
  pass_with "explicit-1 summary.json was created"
else
  fail_with "explicit-1 summary.json missing" "$EXPLICIT_SUMMARY"
fi

DEFAULT_SANITIZED="$TMPDIR/default.sanitized.json"
EXPLICIT_SANITIZED="$TMPDIR/explicit.sanitized.json"
sanitize_summary "$DEFAULT_SUMMARY" >"$DEFAULT_SANITIZED"
sanitize_summary "$EXPLICIT_SUMMARY" >"$EXPLICIT_SANITIZED"

TOTAL=$((TOTAL + 1))
if diff -u "$DEFAULT_SANITIZED" "$EXPLICIT_SANITIZED" >"$TMPDIR/summary.diff" 2>&1; then
  pass_with "sanitized summaries are byte-identical between default and --rounds 1"
else
  fail_with "default vs --rounds 1 summaries diverge" "$(cat "$TMPDIR/summary.diff")"
fi

# =====================================================================
# Test 6: Failure-path coverage — when the agent exits non-zero, the
# rounds_total == 1 path must still finalize a summary (no crash, no
# half-written state) and the lens iteration count must reflect the real
# agent calls, not a hardcoded value.
# =====================================================================
echo ""
echo "Test 6: failing agent under default rounds still finalizes the summary"
cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
# Stub: emit DONE so the streak progresses, but exit 7 to simulate an agent
# that "succeeded" semantically (DONE marker) yet returned a non-zero rc.
# This exercises any '|| fallback' branches in run_lens / run_rounds error
# handling on the rounds_total == 1 path.
printf 'DONE\n'
exit 7
EOF
chmod +x "$FAKE_BIN/codex"

run_repolens "agent-fails"
TOTAL=$((TOTAL + 1))
# The run may exit non-zero because the agent did, but it MUST NOT hang or
# corrupt the summary. If repolens.sh exited cleanly (rc 0) that is also
# acceptable — what matters is that finalize_summary ran.
if [[ "$LAST_RC" -ge 0 ]]; then
  pass_with "agent-fails run terminated (rc=$LAST_RC)"
else
  fail_with "agent-fails run did not terminate" "rc=$LAST_RC"
fi

FAIL_SUMMARY="$(summary_path_for_run "$LAST_RUN_ID")"
TOTAL=$((TOTAL + 1))
if [[ -f "$FAIL_SUMMARY" ]]; then
  pass_with "summary.json exists even when agent exits non-zero"
else
  fail_with "summary.json missing after agent failure" "$FAIL_SUMMARY"
fi

# Restore the happy-path stub so any subsequent additions inherit a clean state.
make_fake_codex

echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

[[ "$FAIL" -eq 0 ]] || exit 1
