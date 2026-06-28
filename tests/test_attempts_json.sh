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

# Tests for issue #371 — Define `attempts.json` schema + writer (one attempt
# per run invocation).
#
# Behavioral contract (from the issue):
#   - A fresh `--dry-run` writes `logs/<run-id>/attempts.json`: a valid JSON
#     ARRAY with exactly ONE entry carrying { attempt_id, started_at,
#     finished_at, status, why_stopped, lenses_completed }.
#   - Resuming that SAME run appends a SECOND entry; `attempt_id` is monotonic
#     (1, then 2).
#   - `status` reflects the run's final state (REPOLENS_FINAL_STATE — one of
#     finished / finished-empty / failed / interrupted / rate-limit-pending;
#     "finished" for a clean run).
#   - A write failure is NON-FATAL: `attempts_finalize` warns and returns 0 so
#     the run's exit code is unchanged.
#
# No real models (CLAUDE.md hard rule): `--dry-run` never invokes the agent,
# and the full-run case PATH-shims a fake `codex` -> tests/mock-agent.sh (the
# same technique as tests/test_rounds_multi_round_handoff.sh:150-167).
#
# Run-id discovery uses the "RepoLens run <id> starting" line (repolens.sh:1979)
# which is emitted for EVERY invocation (including dry-run) before any exit —
# the "complete" line is NOT printed in dry-run.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMP_PARENT="$SCRIPT_DIR/logs/test-attempts-json"
mkdir -p "$TMP_PARENT"
TMPDIR="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"
CREATED_RUN_IDS=()

# shellcheck disable=SC2329  # cleanup is invoked indirectly via 'trap cleanup EXIT' below.
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

# assert_ok <desc> <cmd...> — passes iff the command exits 0. Used for every
# JSON content assertion so that a MISSING attempts.json (the TDD red phase, or
# a real regression) makes the check FAIL rather than silently capturing an
# empty `jq -r` value as a passing equality.
assert_ok() {
  local desc="$1"
  shift
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then
    pass_with "$desc"
  else
    fail_with "$desc" "command failed: $*"
  fi
}

# Fake `codex`. `make_fake_codex mock` delegates to the deterministic
# tests/mock-agent.sh (full run); any other arg makes a trivial DONE printer
# (dry-run never calls it, but `require_cmd codex` runs before the dry-run exit
# so the binary must exist on PATH).
make_fake_codex() {
  mkdir -p "$FAKE_BIN"
  if [[ "${1:-trivial}" == "mock" ]]; then
    cat > "$FAKE_BIN/codex" <<EOF
#!/usr/bin/env bash
exec "$SCRIPT_DIR/tests/mock-agent.sh" "\$@"
EOF
  else
    cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
printf 'DONE\n'
EOF
  fi
  chmod +x "$FAKE_BIN/codex"
}

make_project() {
  local project="$1"
  mkdir -p "$project"
  git -C "$project" init -q
  printf '# attempts.json fixture\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" \
    -c user.name='RepoLens Test' -c user.email='repolens@example.invalid' \
    commit -q -m 'fixture'
}

discover_run_id() {
  grep -oE 'RepoLens run [^ ]+ starting' "$1" 2>/dev/null | head -1 | awk '{print $3}'
}

echo ""
echo "=== Test Suite: attempts.json schema + writer (issue #371) ==="
echo ""

PROJECT_DIR="$TMPDIR/proj"
make_project "$PROJECT_DIR"

# ---------------------------------------------------------------------------
# Test 1 — AC#1: a fresh --dry-run writes a 1-entry attempts.json with the
# full schema.
# ---------------------------------------------------------------------------
echo "Test 1: fresh --dry-run writes attempts.json with exactly 1 entry"
make_fake_codex trivial

OUT1="$TMPDIR/out-fresh.txt"
PATH="$FAKE_BIN:$PATH" \
  bash "$SCRIPT_DIR/repolens.sh" \
    --project "$PROJECT_DIR" \
    --agent codex \
    --local \
    --focus injection \
    --depth 1 \
    --dry-run \
    --yes \
    </dev/null >"$OUT1" 2>&1
RC1=$?

RUN_ID="$(discover_run_id "$OUT1")"
if [[ -n "$RUN_ID" ]]; then
  CREATED_RUN_IDS+=("$RUN_ID")
fi
ATT="$SCRIPT_DIR/logs/$RUN_ID/attempts.json"

assert_eq "fresh dry-run exits 0" "0" "$RC1"
assert_eq "run id is discoverable from dry-run output" \
  "set" "$([[ -n "$RUN_ID" ]] && printf 'set' || printf 'missing')"
assert_ok "attempts.json is valid JSON (jq -e .)" jq -e . "$ATT"
assert_ok "attempts.json is a JSON array" jq -e 'type == "array"' "$ATT"
assert_ok "attempts.json has exactly 1 entry" jq -e 'length == 1' "$ATT"
assert_ok "entry has all six schema fields" jq -e '
  .[0]
  | has("attempt_id") and has("started_at") and has("finished_at")
    and has("status") and has("why_stopped") and has("lenses_completed")' "$ATT"
assert_ok "attempt_id is 1" jq -e '.[0].attempt_id == 1' "$ATT"
assert_ok "status is 'finished' for a clean dry-run" \
  jq -e '.[0].status == "finished"' "$ATT"
assert_ok "why_stopped is empty for a dry-run (no summary.json)" \
  jq -e '.[0].why_stopped == ""' "$ATT"
assert_ok "lenses_completed is 0 for a dry-run (no lenses ran)" \
  jq -e '.[0].lenses_completed == 0' "$ATT"
assert_ok "started_at is a UTC +%Y-%m-%dT%H:%M:%SZ timestamp" jq -e '
  .[0].started_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' "$ATT"
assert_ok "finished_at is a UTC +%Y-%m-%dT%H:%M:%SZ timestamp" jq -e '
  .[0].finished_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' "$ATT"

# ---------------------------------------------------------------------------
# Test 2 — AC#2: resuming the SAME run appends a second entry; attempt_id is
# monotonic.
# ---------------------------------------------------------------------------
echo ""
echo "Test 2: resuming the same run appends a 2nd entry (attempt_id 1, then 2)"

if [[ -z "$RUN_ID" ]]; then
  fail_with "resume requires a discoverable run id from Test 1" \
    "no run id parsed from $OUT1"
else
  OUT2="$TMPDIR/out-resume.txt"
  PATH="$FAKE_BIN:$PATH" \
    bash "$SCRIPT_DIR/repolens.sh" \
      --resume "$RUN_ID" \
      --project "$PROJECT_DIR" \
      --agent codex \
      --local \
      --focus injection \
      --depth 1 \
      --dry-run \
      --yes \
      </dev/null >"$OUT2" 2>&1
  RC2=$?

  assert_eq "resume dry-run exits 0" "0" "$RC2"
  assert_ok "attempts.json is still valid JSON after resume" jq -e . "$ATT"
  assert_ok "attempts.json has exactly 2 entries after one resume" \
    jq -e 'length == 2' "$ATT"
  assert_ok "attempt_ids are monotonic: 1 then 2" \
    jq -e '.[0].attempt_id == 1 and .[1].attempt_id == 2' "$ATT"
  assert_ok "second attempt also carries the full schema" jq -e '
    .[1]
    | has("attempt_id") and has("started_at") and has("finished_at")
      and has("status") and has("why_stopped") and has("lenses_completed")' "$ATT"
  assert_ok "second attempt status is 'finished'" \
    jq -e '.[1].status == "finished"' "$ATT"
fi

# ---------------------------------------------------------------------------
# Test 3 — AC#3: a real (non-dry-run) mock run reaches the MAIN finalize call
# site and records a true terminal state. Dry-run exits long before that block,
# so this is the only path that exercises it.
# ---------------------------------------------------------------------------
echo ""
echo "Test 3: a full mock run records one attempt with a real terminal status"
make_fake_codex mock

FULL_PROJECT="$TMPDIR/proj-full"
make_project "$FULL_PROJECT"

OUT3="$TMPDIR/out-full.txt"
env -u REPOLENS_ROUNDS -u REPOLENS_MAX_ROUNDS -u DONE_STREAK_REQUIRED \
  PATH="$FAKE_BIN:$PATH" \
  REPOLENS_AGENT_TIMEOUT=10 \
  REPOLENS_AGENT_KILL_GRACE=1 \
  bash "$SCRIPT_DIR/repolens.sh" \
    --project "$FULL_PROJECT" \
    --agent codex \
    --local \
    --focus injection \
    --depth 1 \
    --output "$TMPDIR/issues-full" \
    --yes \
    </dev/null >"$OUT3" 2>&1
RC3=$?

RUN_ID3="$(discover_run_id "$OUT3")"
if [[ -n "$RUN_ID3" ]]; then
  CREATED_RUN_IDS+=("$RUN_ID3")
fi
ATT3="$SCRIPT_DIR/logs/$RUN_ID3/attempts.json"

assert_eq "full mock run exits 0" "0" "$RC3"
assert_ok "attempts.json written at the main finalize site" jq -e . "$ATT3"
assert_ok "full run records exactly 1 attempt" jq -e 'length == 1' "$ATT3"
assert_ok "status is one of the valid REPOLENS_FINAL_STATE values" jq -e '
  .[0].status as $s
  | ["finished","finished-empty","failed","interrupted","rate-limit-pending"]
  | index($s) != null' "$ATT3"
assert_ok "lenses_completed reflects the completed injection lens (>= 1)" \
  jq -e '.[0].lenses_completed >= 1' "$ATT3"

# ---------------------------------------------------------------------------
# Test 4 — AC#4: a write failure is non-fatal. attempts_finalize must warn and
# return 0 even when the destination cannot be written, so a run's exit code is
# never changed by the audit-trail writer. Pointing the writer at a path whose
# parent is a regular file forces ENOTDIR for ANY uid (incl. root), so the
# check is not defeated by a root test runner.
# ---------------------------------------------------------------------------
echo ""
echo "Test 4: attempts_finalize is non-fatal on a write failure (warn + rc 0)"

UNIT_RC="$TMPDIR/unit-rc.txt"
UNIT_WARN="$TMPDIR/unit-warn.txt"
: > "$UNIT_RC"
: > "$UNIT_WARN"
(
  set -uo pipefail
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/core.sh" 2>/dev/null
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/logging.sh" 2>/dev/null
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/attempts.sh" 2>/dev/null
  # Seed the logging globals so log_warn is safe under `set -u` (see memory
  # note repolens-log-warn-setu-uninit-crash).
  init_logging "unit-attempts" "$TMPDIR/unit-log"
  blocker="$TMPDIR/blocker-file"
  : > "$blocker"
  attempts_finalize "$blocker/cannot-exist" "finished" "" 2>"$UNIT_WARN"
  printf '%s\n' "$?" > "$UNIT_RC"
) >/dev/null 2>&1

unit_rc="$(tr -d '[:space:]' < "$UNIT_RC" 2>/dev/null)"
[[ -n "$unit_rc" ]] || unit_rc="MISSING"
assert_eq "attempts_finalize returns 0 when the write target is unwritable" \
  "0" "$unit_rc"
assert_ok "attempts_finalize emits a [WARN] on write failure" \
  grep -q '\[WARN\]' "$UNIT_WARN"

# ---------------------------------------------------------------------------
# Test 5 — lenses_completed is the PER-ATTEMPT DELTA (current .completed count
# minus the baseline captured at attempts_begin), not a cumulative snapshot —
# the central design choice of the writer. Also asserts that a non-default
# status and a non-empty why_stopped propagate verbatim into the entry (every
# integration test above only ever sees status=="finished" / why_stopped==""),
# and that the transient .attempt-start marker is removed after a successful
# finalize. Driven directly through the lib (deterministic, no agent) so the
# baseline/delta arithmetic across two attempts is exercised exactly.
# ---------------------------------------------------------------------------
echo ""
echo "Test 5: lenses_completed is the per-attempt delta; status + why_stopped propagate"

DELTA_LB="$TMPDIR/delta-run"
DELTA_RC1="$TMPDIR/delta-rc1.txt"
DELTA_RC2="$TMPDIR/delta-rc2.txt"
DELTA_MARKER="$TMPDIR/delta-marker.txt"
(
  set -uo pipefail
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/core.sh" 2>/dev/null
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/logging.sh" 2>/dev/null
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/attempts.sh" 2>/dev/null
  init_logging "unit-attempts" "$TMPDIR/unit-log"
  mkdir -p "$DELTA_LB"

  # Attempt 1: .completed is absent at begin -> baseline 0; two lenses then
  # complete -> this attempt's delta is 2.
  attempts_begin "$DELTA_LB"
  printf 'lens-a\nlens-b\n' >> "$DELTA_LB/.completed"
  attempts_finalize "$DELTA_LB" "finished" ""
  printf '%s\n' "$?" > "$DELTA_RC1"

  # Attempt 2: baseline is now 2 (the cumulative .completed); ONE more lens
  # completes -> this attempt's delta is 1, NOT the cumulative 3.
  attempts_begin "$DELTA_LB"
  printf 'lens-c\n' >> "$DELTA_LB/.completed"
  attempts_finalize "$DELTA_LB" "rate-limit-pending" "weekly limit reached"
  printf '%s\n' "$?" > "$DELTA_RC2"

  if [[ -e "$DELTA_LB/.attempt-start" ]]; then
    printf 'present\n' > "$DELTA_MARKER"
  else
    printf 'absent\n' > "$DELTA_MARKER"
  fi
) >/dev/null 2>&1

DELTA_ATT="$DELTA_LB/attempts.json"
assert_eq "first delta finalize returns 0" \
  "0" "$(tr -d '[:space:]' < "$DELTA_RC1" 2>/dev/null)"
assert_eq "second delta finalize returns 0" \
  "0" "$(tr -d '[:space:]' < "$DELTA_RC2" 2>/dev/null)"
assert_ok "delta-run attempts.json is valid JSON" jq -e . "$DELTA_ATT"
assert_ok "two attempts recorded across two finalize calls" \
  jq -e 'length == 2' "$DELTA_ATT"
assert_ok "attempt 1 lenses_completed == 2 (delta from baseline 0)" \
  jq -e '.[0].lenses_completed == 2' "$DELTA_ATT"
assert_ok "attempt 2 lenses_completed == 1 (per-attempt delta, NOT cumulative 3)" \
  jq -e '.[1].lenses_completed == 1' "$DELTA_ATT"
assert_ok "attempt_ids are monotonic 1 then 2 at the unit level" \
  jq -e '.[0].attempt_id == 1 and .[1].attempt_id == 2' "$DELTA_ATT"
assert_ok "a non-default status propagates verbatim (rate-limit-pending)" \
  jq -e '.[1].status == "rate-limit-pending"' "$DELTA_ATT"
assert_ok "a non-empty why_stopped propagates verbatim" \
  jq -e '.[1].why_stopped == "weekly limit reached"' "$DELTA_ATT"
assert_eq "the .attempt-start marker is removed after a successful finalize" \
  "absent" "$(tr -d '[:space:]' < "$DELTA_MARKER" 2>/dev/null)"

# ---------------------------------------------------------------------------
# Test 6 — a pre-existing attempts.json that is corrupt or not a JSON array is
# NEVER clobbered: the writer warns, returns 0, and leaves the file byte-for-
# byte intact so prior attempts can never be silently dropped. This guards the
# `jq -e 'if type == "array" ...'` branch and the "do not reset to []" promise
# in lib/attempts.sh. Two cases: invalid JSON, and valid-but-non-array JSON.
# ---------------------------------------------------------------------------
echo ""
echo "Test 6: a corrupt or non-array attempts.json is preserved, never reset to []"

# --- 6a: invalid JSON ---
CORRUPT_LB="$TMPDIR/corrupt-run"
CORRUPT_RC="$TMPDIR/corrupt-rc.txt"
CORRUPT_WARN="$TMPDIR/corrupt-warn.txt"
(
  set -uo pipefail
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/core.sh" 2>/dev/null
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/logging.sh" 2>/dev/null
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/attempts.sh" 2>/dev/null
  init_logging "unit-attempts" "$TMPDIR/unit-log"
  mkdir -p "$CORRUPT_LB"
  printf '%s\n' 'THIS_IS_NOT_JSON_{{{_keep_me' > "$CORRUPT_LB/attempts.json"
  attempts_begin "$CORRUPT_LB"
  attempts_finalize "$CORRUPT_LB" "finished" "" 2>"$CORRUPT_WARN"
  printf '%s\n' "$?" > "$CORRUPT_RC"
) >/dev/null 2>&1

assert_eq "finalize returns 0 on a corrupt attempts.json" \
  "0" "$(tr -d '[:space:]' < "$CORRUPT_RC" 2>/dev/null)"
assert_ok "finalize warns instead of appending to corrupt JSON" \
  grep -q '\[WARN\]' "$CORRUPT_WARN"
assert_ok "the corrupt attempts.json is preserved (not reset to [])" \
  grep -q 'THIS_IS_NOT_JSON' "$CORRUPT_LB/attempts.json"

# --- 6b: valid JSON that is not an array ---
NONARR_LB="$TMPDIR/nonarray-run"
NONARR_RC="$TMPDIR/nonarray-rc.txt"
NONARR_WARN="$TMPDIR/nonarray-warn.txt"
(
  set -uo pipefail
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/core.sh" 2>/dev/null
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/logging.sh" 2>/dev/null
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/attempts.sh" 2>/dev/null
  init_logging "unit-attempts" "$TMPDIR/unit-log"
  mkdir -p "$NONARR_LB"
  printf '%s\n' '{"prior":"data"}' > "$NONARR_LB/attempts.json"
  attempts_begin "$NONARR_LB"
  attempts_finalize "$NONARR_LB" "finished" "" 2>"$NONARR_WARN"
  printf '%s\n' "$?" > "$NONARR_RC"
) >/dev/null 2>&1

assert_eq "finalize returns 0 on a valid-but-non-array attempts.json" \
  "0" "$(tr -d '[:space:]' < "$NONARR_RC" 2>/dev/null)"
assert_ok "finalize warns instead of appending to non-array JSON" \
  grep -q '\[WARN\]' "$NONARR_WARN"
assert_ok "the pre-existing non-array JSON object is preserved verbatim" \
  jq -e '.prior == "data"' "$NONARR_LB/attempts.json"
assert_ok "finalize did NOT wrap the object into an array" \
  jq -e 'type == "object"' "$NONARR_LB/attempts.json"

# ---------------------------------------------------------------------------
# Test 7 — attempts_finalize tolerates a MISSING .attempt-start marker (a
# finalize that somehow skipped attempts_begin): it still records an entry,
# falls back to started_at=="" and baseline 0, and still propagates status and
# why_stopped. Guards the marker-absent fallback branch in lib/attempts.sh.
# ---------------------------------------------------------------------------
echo ""
echo "Test 7: finalize without a start marker still records (started_at empty, baseline 0)"

NOMARK_LB="$TMPDIR/nomarker-run"
NOMARK_RC="$TMPDIR/nomarker-rc.txt"
(
  set -uo pipefail
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/core.sh" 2>/dev/null
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/logging.sh" 2>/dev/null
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/attempts.sh" 2>/dev/null
  init_logging "unit-attempts" "$TMPDIR/unit-log"
  mkdir -p "$NOMARK_LB"
  # No attempts_begin -> no .attempt-start marker. One lens is already recorded.
  printf 'lens-x\n' > "$NOMARK_LB/.completed"
  attempts_finalize "$NOMARK_LB" "failed" "boom"
  printf '%s\n' "$?" > "$NOMARK_RC"
) >/dev/null 2>&1

NOMARK_ATT="$NOMARK_LB/attempts.json"
assert_eq "finalize-without-begin returns 0" \
  "0" "$(tr -d '[:space:]' < "$NOMARK_RC" 2>/dev/null)"
assert_ok "an entry is still recorded with attempt_id 1" \
  jq -e 'length == 1 and .[0].attempt_id == 1' "$NOMARK_ATT"
assert_ok "started_at falls back to empty string when no marker exists" \
  jq -e '.[0].started_at == ""' "$NOMARK_ATT"
assert_ok "lenses_completed uses the baseline-0 fallback (current count == 1)" \
  jq -e '.[0].lenses_completed == 1' "$NOMARK_ATT"
assert_ok "status and why_stopped still propagate without a marker" \
  jq -e '.[0].status == "failed" and .[0].why_stopped == "boom"' "$NOMARK_ATT"

echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
