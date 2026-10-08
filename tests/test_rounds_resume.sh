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

# Tests for issue #172: round-aware `--resume` semantics.
#
# Covers the four acceptance scenarios:
#  1. Partial round-2 resume of a 3-round run: round-1 skipped, only missing
#     round-2 lenses re-run, round-2 marker written, round-3 fresh.
#  2. Fully-completed round-1 marker (plus its lens completion file) causes
#     round-1 to be skipped entirely with zero run_lens calls.
#  3. Pre-existing round-(N-1)/dispatch.md with zero lens-outputs causes lens
#     dispatch to run from dispatch.md WITHOUT invoking the meta-orchestrator
#     for that round.
#  4. `--resume <run-id>` with a `--rounds N` value that differs from the
#     persisted value rejects non-zero with a clear error mentioning the flag.
#
# Tests 1-3 drive lib/rounds.sh `run_rounds` directly with the real
# round-completion helpers and filesystem markers, mocking only the agent-
# facing seams (`run_lens`, `run_meta_orchestrator`, lens completion helpers,
# digest builder, summary recorders).
# Test 4 is an integration test that invokes repolens.sh under `--dry-run`
# with a fabricated `round-1/metadata.json` to force the mismatch path.
#
# shellcheck disable=SC2034  # Test globals are read by the sourced rounds module.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROUNDS_LIB="$SCRIPT_DIR/lib/rounds.sh"

PASS=0
FAIL=0
TOTAL=0

TMP_PARENT="$SCRIPT_DIR/logs/test-rounds-resume"
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

pass_with() {
  local desc="$1"
  PASS=$((PASS + 1))
  echo "  PASS: $desc"
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
    fail_with "$desc" "Expected to find: $needle"
  fi
}

assert_nonzero() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -ne 0 ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected non-zero exit status"
  fi
}

assert_file_exists() {
  local desc="$1" file="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$file" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected file at $file"
  fi
}

join_by() {
  local sep="$1"
  shift
  local IFS="$sep"
  printf '%s' "$*"
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

echo "=== rounds.sh resume semantics (issue #172) ==="

TOTAL=$((TOTAL + 1))
if [[ -f "$ROUNDS_LIB" ]]; then
  pass_with "lib/rounds.sh exists"
else
  fail_with "lib/rounds.sh exists" "Expected module at $ROUNDS_LIB"
  finish
fi

log_info() { LOG_LINES+=("INFO:$*"); }
log_warn() { LOG_LINES+=("WARN:$*"); }

# shellcheck disable=SC1090
source "$SCRIPT_DIR/lib/streak.sh"
# shellcheck disable=SC1090
source "$SCRIPT_DIR/lib/template.sh"
# shellcheck disable=SC1090
source "$ROUNDS_LIB"

# Mocks: keep agent-facing seams quiet and side-effect free.
run_meta_orchestrator() {
  META_CALLS+=("$1->$2")
  return 0
}
init_parallel() { :; }
spawn_lens() { :; }
wait_all() { return 0; }
record_lens() { :; }
set_stop_reason() { :; }
# Override build_round_digest as a noop — we are not testing digest content here.
build_round_digest() { return 0; }

# Real-filesystem-backed lens completion that swaps with completed_lenses_file
# (mirrors the production behavior in repolens.sh:1122-1128).
is_lens_completed() {
  local lens_entry="$1"
  [[ -n "${completed_lenses_file:-}" ]] || return 1
  grep -qxF "$lens_entry" "$completed_lenses_file" 2>/dev/null
}

mark_lens_completed() {
  local lens_entry="$1"
  [[ -n "${completed_lenses_file:-}" ]] || return 0
  echo "$lens_entry" >> "$completed_lenses_file"
}

# Real run_lens-equivalent: honor the resume guard, record the call when run
# fresh, mark the lens completed (round-scoped via completed_lenses_file swap).
run_lens() {
  local lens_entry="$1"

  if is_lens_completed "$lens_entry"; then
    RUN_LENS_SKIPS+=("$lens_entry")
    return 0
  fi
  RUN_LENS_CALLS+=("$lens_entry:round=${CURRENT_ROUND_INDEX:-1}")
  mark_lens_completed "$lens_entry"
}

reset_case() {
  local name="$1"
  CASE_DIR="$TMPDIR/$name"
  LOG_BASE="$CASE_DIR/logs/$name"
  SUMMARY_FILE="$CASE_DIR/summary.json"
  mkdir -p "$LOG_BASE"
  printf '{"stopped_reason":null,"lenses":[]}\n' > "$SUMMARY_FILE"

  PARALLEL=false
  MAX_PARALLEL=2
  MAX_ISSUES=""
  GLOBAL_ISSUES_CREATED=0
  TOTAL_LENSES=0
  RUN_ID="$name"
  RESUME_RUN_ID=""

  LOG_LINES=()
  RUN_LENS_CALLS=()
  RUN_LENS_SKIPS=()
  META_CALLS=()

  completed_lenses_file="$LOG_BASE/.completed"
  : > "$completed_lenses_file"
}

count_calls_for_round() {
  local round="$1" entry count=0
  for entry in "${RUN_LENS_CALLS[@]}"; do
    [[ "$entry" == *":round=$round" ]] && count=$((count + 1))
  done
  printf '%s' "$count"
}

# Acceptance fixture: a 3-round, 4-lens run that died mid-round-2.
# Round 1 fully complete (round marker + all 4 lens entries in completion file).
# Round 2 partially complete (2 of 4 lens entries, no round marker).
# Round 3 untouched.
FIXTURE_LENSES=("security/injection" "security/xss-csrf" "security/auth-session" "security/authorization")

echo ""
echo "Test 1: partial round-2 resume of a --rounds 3 run"
reset_case "partial-round2"
TOTAL_LENSES=${#FIXTURE_LENSES[@]}
init_run_layout "$RUN_ID" 3 "${#FIXTURE_LENSES[@]}" "${FIXTURE_LENSES[@]}"
finalize_round "$RUN_ID" 1
mkdir -p "$LOG_BASE/.rounds"
printf '%s\n' "${FIXTURE_LENSES[@]}" > "$LOG_BASE/.rounds/round-1.lenses.completed"
# A cleanly completed non-final round includes its successful handoff.
printf 'LENS: %s\n' "${FIXTURE_LENSES[@]##*/}" > "$LOG_BASE/rounds/round-1/dispatch.md"
printf '%s\n%s\n' "${FIXTURE_LENSES[0]}" "${FIXTURE_LENSES[1]}" > "$LOG_BASE/.rounds/round-2.lenses.completed"
RESUME_RUN_ID="$RUN_ID"

LENSES=("${FIXTURE_LENSES[@]}")
run_rounds 3 LENSES
rc=$?

assert_eq "partial round-2 resume exits successfully" "0" "$rc"
assert_eq "round-1 is fully skipped (no run_lens calls)" "0" "$(count_calls_for_round 1)"
assert_eq "round-2 runs exactly the 2 missing lenses" "2" "$(count_calls_for_round 2)"
assert_eq "round-3 runs all 4 lenses fresh" "4" "$(count_calls_for_round 3)"
assert_file_exists "round-2 .completed marker is written after resume" \
  "$LOG_BASE/rounds/round-2/.completed"
assert_file_exists "round-3 .completed marker is written after resume" \
  "$LOG_BASE/rounds/round-3/.completed"
# Meta-orchestrator must dispatch the next round between completed rounds 2 and 3.
assert_eq "meta orchestrator dispatches round 3 after the resumed round 2" \
  "2->3" "$(join_by " " "${META_CALLS[@]}")"

echo ""
echo "Test 2: fully-completed round-1 marker causes round-1 to be skipped entirely"
reset_case "skip-round1"
LENSES2=("security/injection" "security/xss-csrf")
TOTAL_LENSES=${#LENSES2[@]}
init_run_layout "$RUN_ID" 2 "${#LENSES2[@]}" "${LENSES2[@]}"
finalize_round "$RUN_ID" 1
mkdir -p "$LOG_BASE/.rounds"
printf '%s\n' "${LENSES2[@]}" > "$LOG_BASE/.rounds/round-1.lenses.completed"
printf 'LENS: %s\n' "${LENSES2[@]##*/}" > "$LOG_BASE/rounds/round-1/dispatch.md"
RESUME_RUN_ID="$RUN_ID"

run_rounds 2 LENSES2
rc=$?

assert_eq "fully-skipped round-1 resume exits successfully" "0" "$rc"
assert_eq "round-1 records zero agent invocations" "0" "$(count_calls_for_round 1)"
assert_eq "round-2 still runs every lens" "${#LENSES2[@]}" "$(count_calls_for_round 2)"
# Operator audit: the log must clearly indicate round 1 was skipped.
assert_contains "skipped round is logged for operator audit (Skip-keyword)" \
  "Skip" "$(join_by " " "${LOG_LINES[@]}")"
assert_contains "skipped round audit log references round 1" \
  "round 1" "$(join_by " " "${LOG_LINES[@]}")"

echo ""
echo "Test 3: pre-existing dispatch.md skips meta-orchestrator for that round"
reset_case "preexisting-dispatch"
LENSES3=("security/injection" "security/xss-csrf")
TOTAL_LENSES=${#LENSES3[@]}
init_run_layout "$RUN_ID" 2 "${#LENSES3[@]}" "${LENSES3[@]}"
finalize_round "$RUN_ID" 1
mkdir -p "$LOG_BASE/.rounds"
printf '%s\n' "${LENSES3[@]}" > "$LOG_BASE/.rounds/round-1.lenses.completed"
# Round 2 dispatch was written at the end of round 1 by the prior run; zero
# round-2 lens outputs exist yet.
mkdir -p "$LOG_BASE/rounds/round-1"
cat > "$LOG_BASE/rounds/round-1/dispatch.md" <<'DISPATCH'
# Meta-Orchestrator Dispatch

LENS: injection
DISPATCH
RESUME_RUN_ID="$RUN_ID"
# The active_lens_list seeded by the caller is the full set; dispatch.md must
# narrow it down to the single dispatched lens for round 2.

run_rounds 2 LENSES3
rc=$?

assert_eq "pre-existing dispatch.md resume exits successfully" "0" "$rc"
assert_eq "round-1 is fully skipped" "0" "$(count_calls_for_round 1)"
assert_eq "round-2 runs only the dispatched lens" "1" "$(count_calls_for_round 2)"
assert_eq "round-2 dispatch consumes exactly the LENS line" \
  "security/injection:round=2" "${RUN_LENS_CALLS[0]}"
# The critical assertion: meta-orchestrator must NOT be invoked for round 2
# because its dispatch.md is already present (and round 1 was skipped, so no
# end-of-round-1 meta hand-off should have run either).
assert_eq "meta orchestrator is not invoked when dispatch.md is pre-existing" \
  "" "$(join_by " " "${META_CALLS[@]}")"

# ------------------------------------------------------------------------
# Test 4: integration — mismatched --rounds on resume must reject non-zero
# ------------------------------------------------------------------------
echo ""
echo "Test 4: mismatched --rounds on resume rejects with a clear error"

FAKE_BIN="$TMPDIR/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/codex" <<'SH'
#!/usr/bin/env bash
echo "DONE"
SH
chmod +x "$FAKE_BIN/codex"

mismatch_project="$TMPDIR/project-mismatch"
mkdir -p "$mismatch_project"
git -C "$mismatch_project" init -q
printf '# resume mismatch project\n' > "$mismatch_project/README.md"

BUG_FILE="$TMPDIR/bug-report.md"
printf 'Resume gate fixture bug report — placeholder text.\n' > "$BUG_FILE"

# Fabricate a prior run's round-1/metadata.json with rounds_total=3 so that the
# resume-time gate can read it back.
FAKE_RUN_ID="20260101T000000Z-resumetest"
CREATED_RUN_IDS+=("$FAKE_RUN_ID")
FAKE_LOG_BASE="$SCRIPT_DIR/logs/$FAKE_RUN_ID"
mkdir -p "$FAKE_LOG_BASE/rounds/round-1"
jq -n '{round_number:1,breadth:2,rounds_total:3,start_ts:"2026-01-01T00:00:00Z",lens_count:2,lens_ids:["injection","xss-csrf"]}' \
  > "$FAKE_LOG_BASE/rounds/round-1/metadata.json"

mismatch_out="$TMPDIR/mismatch-out.txt"
env -u REPOLENS_ROUNDS -u DONE_STREAK_REQUIRED REPOLENS_MAX_ROUNDS=99 PATH="$FAKE_BIN:$PATH" \
  bash "$SCRIPT_DIR/repolens.sh" \
    --project "$mismatch_project" \
    --agent codex \
    --mode bugreport \
    --bug-report "$BUG_FILE" \
    --local \
    --output "$TMPDIR/issues-mismatch" \
    --yes \
    --dry-run \
    --i-know-this-is-expensive \
    --resume "$FAKE_RUN_ID" \
    --rounds 5 >"$mismatch_out" 2>&1
mismatch_rc=$?

assert_nonzero "mismatched --rounds on resume exits non-zero" "$mismatch_rc"
assert_contains "mismatch error mentions --rounds" "--rounds" "$(cat "$mismatch_out")"
assert_contains "mismatch error names the persisted round count" \
  "3" "$(cat "$mismatch_out")"
assert_contains "mismatch error names the requested round count" \
  "5" "$(cat "$mismatch_out")"

# Sanity check: matching --rounds passes the gate (i.e. dry-run completes).
matching_out="$TMPDIR/matching-out.txt"
env -u REPOLENS_ROUNDS -u DONE_STREAK_REQUIRED PATH="$FAKE_BIN:$PATH" \
  bash "$SCRIPT_DIR/repolens.sh" \
    --project "$mismatch_project" \
    --agent codex \
    --mode bugreport \
    --bug-report "$BUG_FILE" \
    --local \
    --output "$TMPDIR/issues-matching" \
    --yes \
    --dry-run \
    --resume "$FAKE_RUN_ID" \
    --rounds 3 >"$matching_out" 2>&1
matching_rc=$?

assert_eq "matching --rounds on resume passes the gate (dry-run exits 0)" \
  "0" "$matching_rc"

# ------------------------------------------------------------------------
# Test 5: legacy pre-#147 resume (no round-1/metadata.json) passes the gate.
# Implementation contract: absent metadata is treated as "no constraint" so
# legacy resumes don't crash on the new gate.
# ------------------------------------------------------------------------
echo ""
echo "Test 5: legacy run without round-1/metadata.json passes the gate"

LEGACY_RUN_ID="20260101T000000Z-resumelegacy"
CREATED_RUN_IDS+=("$LEGACY_RUN_ID")
LEGACY_LOG_BASE="$SCRIPT_DIR/logs/$LEGACY_RUN_ID"
# Deliberately create the run log dir WITHOUT rounds/round-1/metadata.json,
# simulating a pre-#147 run layout.
mkdir -p "$LEGACY_LOG_BASE"
: > "$LEGACY_LOG_BASE/.completed"

legacy_project="$TMPDIR/project-legacy"
mkdir -p "$legacy_project"
git -C "$legacy_project" init -q
printf '# legacy resume project\n' > "$legacy_project/README.md"

legacy_out="$TMPDIR/legacy-out.txt"
env -u REPOLENS_ROUNDS -u DONE_STREAK_REQUIRED REPOLENS_MAX_ROUNDS=99 PATH="$FAKE_BIN:$PATH" \
  bash "$SCRIPT_DIR/repolens.sh" \
    --project "$legacy_project" \
    --agent codex \
    --mode bugreport \
    --bug-report "$BUG_FILE" \
    --local \
    --output "$TMPDIR/issues-legacy" \
    --yes \
    --dry-run \
    --i-know-this-is-expensive \
    --resume "$LEGACY_RUN_ID" \
    --rounds 4 >"$legacy_out" 2>&1
legacy_rc=$?

assert_eq "legacy resume (no metadata.json) passes the gate (dry-run exits 0)" \
  "0" "$legacy_rc"
# The gate must NOT produce the mismatch die-message when metadata is absent.
legacy_haystack="$(cat "$legacy_out")"
TOTAL=$((TOTAL + 1))
if [[ "$legacy_haystack" != *"round count is part of the run identity"* ]]; then
  pass_with "legacy resume does not trigger the mismatch error"
else
  fail_with "legacy resume does not trigger the mismatch error" \
    "Gate fired on a legacy run lacking round-1/metadata.json"
fi

finish
