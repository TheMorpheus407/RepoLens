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

# Integration test: orchestrator aborts cleanly when agent returns a
# rate-limit / quota / auth-failure signature.
#
# Strategy: stub a fake `codex` binary on PATH that emits a rate-limit
# error string and exits non-zero. Invoke repolens.sh with --local so no
# gh / GitHub access is required. Verify:
#   1. Exit code is non-zero.
#   2. [ERROR] line is logged with the detected signature.
#   3. Iteration count is 1 (not MAX_ITERATIONS_PER_LENS == 20).
#   4. summary.json marks the aborting lens status=rate-limited.
#   5. Remaining lenses in the run are recorded as status=skipped.
#   6. summary.json has stopped_reason=rate-limited.
#   7. The aborted lens is NOT marked completed, so --resume re-runs it.
#
# Does NOT invoke any real AI model (enforced by PATH override).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
TOTAL=0
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (expected='$expected' actual='$actual')"
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
    echo "  FAIL: $desc (needle='$needle' not found)"
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
    echo "  FAIL: $desc (unexpected needle='$needle' found)"
  fi
}

echo "=== Orchestrator rate-limit abort — integration ==="

# Set up a minimal git project (repolens.sh validates the project path).
PROJECT="$TMPDIR/project"
mkdir -p "$PROJECT"
(
  cd "$PROJECT"
  git init -q 2>/dev/null
  git config user.email test@example.com
  git config user.name Test
  echo "# test" > README.md
  git add README.md
  git commit -q -m init 2>/dev/null
) || true

# Fake agent: emits the exact Claude user-tier rate-limit string and exits non-zero.
# repolens.sh's run_agent invokes `codex exec --yolo <prompt>`; the stub
# ignores all args and just prints the signature.
FAKE_BIN="$TMPDIR/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/codex" <<'SH'
#!/usr/bin/env bash
cat <<'MSG'
You've hit your limit · resets 11:30pm (Europe/Berlin)
MSG
exit 1
SH
chmod +x "$FAKE_BIN/codex"

# PATH override: fake codex first, then system PATH. No real AI model runs.
export PATH="$FAKE_BIN:$PATH"

# Sanity-check: the PATH override points to the fake.
which_codex="$(command -v codex 2>/dev/null || true)"
assert_eq "Fake codex is first on PATH" "$FAKE_BIN/codex" "$which_codex"

# Invoke repolens.sh with a 2-lens domain so we can verify skip behavior.
# Uses --local to avoid needing gh auth.
OUT_FILE="$TMPDIR/run.log"
set +e
REPOLENS_RATE_LIMIT_MAX_SLEEP=0 \
bash "$SCRIPT_DIR/repolens.sh" \
  --project "$PROJECT" \
  --agent codex \
  --domain i18n \
  --mode audit \
  --local \
  --yes \
  >"$OUT_FILE" 2>&1
exit_code=$?
set -e

# Extract run_id from log (logged as "RepoLens run <id> starting").
run_id="$(grep -oE 'RepoLens run [^ ]+ starting' "$OUT_FILE" | head -1 | awk '{print $3}')"
if [[ -z "${run_id:-}" ]]; then
  echo "FAIL: could not parse run_id from repolens.sh output" >&2
  echo "---- run.log ----"
  cat "$OUT_FILE"
  echo "-----------------"
  exit 1
fi
summary_file="$SCRIPT_DIR/logs/$run_id/summary.json"

# Best-effort cleanup of the test run log directory on exit.
trap 'rm -rf "$TMPDIR" "$SCRIPT_DIR/logs/$run_id"' EXIT

# ----------------------------------------------------------------------
# Assertion 1: non-zero exit code
# ----------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
if [[ "$exit_code" -ne 0 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: Orchestrator exits non-zero on rate-limit (exit=$exit_code)"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: Expected non-zero exit, got 0"
  echo "---- run.log ----"
  cat "$OUT_FILE"
  echo "-----------------"
fi

# ----------------------------------------------------------------------
# Assertion 2: [ERROR] line present with rate-limit context
# ----------------------------------------------------------------------
log_contents="$(cat "$OUT_FILE")"
assert_contains "Log contains [ERROR] prefix" "[ERROR]" "$log_contents"
assert_contains "Log mentions rate-limited / quota exceeded" "rate-limited" "$log_contents"
assert_contains "Log surfaces the matched snippet" "resets 11:30pm" "$log_contents"

# ----------------------------------------------------------------------
# Assertion 3: did NOT iterate to the safety cap
# ----------------------------------------------------------------------
assert_not_contains "Did not hit MAX_ITERATIONS_PER_LENS safety cap" "Hit safety cap" "$log_contents"
assert_not_contains "Did not run 20 iterations" "Iteration 20" "$log_contents"

# ----------------------------------------------------------------------
# Assertion 4+: summary.json structure
# ----------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
if [[ -f "$summary_file" ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: summary.json was created at $summary_file"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: summary.json missing (expected $summary_file)"
  echo "---- run.log ----"
  cat "$OUT_FILE"
  echo "-----------------"
  echo ""
  echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
  exit "$FAIL"
fi

stopped_reason="$(jq -r '.stopped_reason' "$summary_file")"
assert_eq "summary.stopped_reason == 'rate-limited'" "rate-limited" "$stopped_reason"

rate_limited_count="$(jq '[.lenses[] | select(.status == "rate-limited")] | length' "$summary_file")"
assert_eq "Exactly one lens has status=rate-limited" "1" "$rate_limited_count"

skipped_count="$(jq '[.lenses[] | select(.status == "skipped")] | length' "$summary_file")"
TOTAL=$((TOTAL + 1))
if [[ "$skipped_count" -ge 1 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: At least one lens marked skipped (got $skipped_count)"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: Expected >=1 skipped lens, got $skipped_count"
fi

# Iteration count on the aborting lens should be 1 (not 20).
rl_iters="$(jq '[.lenses[] | select(.status == "rate-limited") | .iterations] | .[0]' "$summary_file")"
assert_eq "Aborted lens did exactly 1 iteration" "1" "$rl_iters"

# ----------------------------------------------------------------------
# Assertion: resume semantics — aborted lens NOT marked completed
# ----------------------------------------------------------------------
completed_file="$SCRIPT_DIR/logs/$run_id/.completed"
TOTAL=$((TOTAL + 1))
if [[ -f "$completed_file" ]]; then
  rl_lens_id="$(jq -r '[.lenses[] | select(.status == "rate-limited")] | .[0] | "\(.domain)/\(.lens)"' "$summary_file")"
  if grep -qxF "$rl_lens_id" "$completed_file" 2>/dev/null; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: Rate-limited lens '$rl_lens_id' was incorrectly marked completed"
  else
    PASS=$((PASS + 1))
    echo "  PASS: Rate-limited lens not in .completed (resume will re-run it)"
  fi
else
  PASS=$((PASS + 1))
  echo "  PASS: .completed file not present — resume correctness preserved"
fi

# ----------------------------------------------------------------------
# Assertion: --resume clears the stale rate-limit sentinel and retries
# ----------------------------------------------------------------------
cat > "$FAKE_BIN/codex" <<'SH'
#!/usr/bin/env bash
state_dir="${FAKE_AGENT_STATE_DIR:-}"
if [[ -n "$state_dir" ]]; then
  mkdir -p "$state_dir"
  calls_file="$state_dir/calls"
  calls=0
  [[ -f "$calls_file" ]] && calls="$(cat "$calls_file" 2>/dev/null || printf 0)"
  calls=$((calls + 1))
  printf '%s\n' "$calls" > "$calls_file"
fi
cat <<'MSG'
DONE
MSG
exit 0
SH
chmod +x "$FAKE_BIN/codex"

RESUME_OUT_FILE="$TMPDIR/resume.log"
RESUME_STATE="$TMPDIR/resume-state"
set +e
FAKE_AGENT_STATE_DIR="$RESUME_STATE" \
bash "$SCRIPT_DIR/repolens.sh" \
  --project "$PROJECT" \
  --agent codex \
  --domain i18n \
  --mode audit \
  --local \
  --yes \
  --resume "$run_id" \
  >"$RESUME_OUT_FILE" 2>&1
resume_exit_code=$?
set -e

assert_eq "Resume after rate-limit succeeds" "0" "$resume_exit_code"
TOTAL=$((TOTAL + 1))
if [[ ! -f "$SCRIPT_DIR/logs/$run_id/.rate-limit-abort" ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: Resume removes stale rate-limit sentinel"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: Resume left stale rate-limit sentinel in place"
fi
assert_eq "Resume clears stale stopped_reason" "null" "$(jq -r '.stopped_reason' "$summary_file" 2>/dev/null || printf missing)"
assert_contains "Resume marks rate-limited lens completed" "$rl_lens_id" "$(cat "$completed_file" 2>/dev/null || true)"
TOTAL=$((TOTAL + 1))
resume_calls="$(cat "$RESUME_STATE/calls" 2>/dev/null || printf 0)"
if [[ "$resume_calls" -ge 1 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: Resume invoked fake agent for pending lens work"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: Resume did not invoke fake agent"
fi

echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
exit "$FAIL"
