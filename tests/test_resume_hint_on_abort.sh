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

# Behavioral tests for issue #372: print a resume hint on every abort/interrupt
# exit path.
#
# `--resume <run-id>` works, but no abort/interrupt exit tells the user it
# exists. The fix adds a `print_resume_hint` helper (issue suggests
# `lib/logging.sh`) that prints ONE stderr line on every *resumable* exit:
#
#   To resume this run: ./repolens.sh --project <path> --agent <agent> --resume <run-id>
#
# These tests assert the OBSERVABLE contract from the issue's acceptance
# criteria — they do NOT couple to internal call-site line numbers or the
# helper's private guard variable:
#   AC1  an interrupted run prints the hint to stderr before a non-zero exit
#   AC2  a rate-limit-pending finalize prints the hint before `exit 3`
#   AC3  a clean `finished` run prints NO resume hint
#   AC4  the hint carries the ACTUAL run id, not a `<run-id>` placeholder
#   AC5  `bash tests/run-all.sh` stays green (covered by the suite as a whole)
#
# No real model is ever invoked: a fake `codex` (and, where a sleep would
# otherwise block, a fake `sleep`) is placed on PATH, exactly like
# tests/test_rate_limit_sleep_retry.sh and tests/test_rate_limit_sleep_interrupt.sh.
#
# Unlike those tests, the integration cases split stdout from stderr
# (`>out 2>err`) so the "the hint goes to *stderr*" assertion is meaningful.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_SLEEP="$(command -v sleep)"

PASS=0
FAIL=0
TOTAL=0
TMPDIR="$(mktemp -d)"
RUN_IDS=()

# shellcheck disable=SC2329
cleanup() {
  local run_id
  # Reap any still-running backgrounded repolens from the interrupt case so the
  # suite never leaks orphan processes (CLAUDE.md test contract).
  if [[ -n "${RUN_PID:-}" ]] && kill -0 "$RUN_PID" 2>/dev/null; then
    kill -TERM "-$RUN_PID" 2>/dev/null || kill -TERM "$RUN_PID" 2>/dev/null || true
  fi
  rm -rf "$TMPDIR"
  for run_id in "${RUN_IDS[@]:-}"; do
    [[ -n "$run_id" ]] && rm -rf "$SCRIPT_DIR/logs/$run_id"
  done
}
trap cleanup EXIT

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

setup_project() {
  local project="$1"
  mkdir -p "$project"
  git -C "$project" init -q 2>/dev/null || true
  printf '# test project\n' > "$project/README.md"
}

install_fake_sleep() {
  # Record-only sleep so a run that *would* sleep never burns wall-clock time.
  local fake_bin="$1"
  cat > "$fake_bin/sleep" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${REPOLENS_TEST_SLEEP_LOG:?}"
exit 0
SH
  chmod +x "$fake_bin/sleep"
}

parse_run_id() {
  # The "RepoLens run <id> starting" banner is logged to stdout (log_info).
  local output_file="$1"
  grep -oE 'RepoLens run [^ ]+ starting' "$output_file" | head -1 | awk '{print $3}'
}

# ---------------------------------------------------------------------------
# Case 1 (AC1 + AC4 — unit): the helper itself.
#
# The three signal handlers (_handle_hangup/_handle_interrupt/
# _handle_termination) and the resumable finalize branches all call
# `print_resume_hint`. This unit case pins the helper's contract directly,
# deterministically, and without a racy real signal:
#   - it emits the resume line to STDERR (never stdout),
#   - the line carries the real run id (no `<run-id>` placeholder),
#   - with RUN_ID empty it is a silent no-op that does NOT abort its caller
#     under `set -u` (a signal can arrive before RUN_ID is assigned).
# ---------------------------------------------------------------------------
echo "=== Helper print_resume_hint: prints the resume line to stderr ==="

UNIT_OUT="$TMPDIR/unit.out"
UNIT_ERR="$TMPDIR/unit.err"
UNIT_RUN_ID="unit-run-20260629T000000Z-deadbeef"

RUN_ID="$UNIT_RUN_ID" PROJECT_PATH="/tmp/unit-project" AGENT="codex" \
  bash -c 'set -uo pipefail; source "$1/lib/logging.sh"; print_resume_hint' \
  _ "$SCRIPT_DIR" >"$UNIT_OUT" 2>"$UNIT_ERR"

unit_out="$(cat "$UNIT_OUT" 2>/dev/null || true)"
unit_err="$(cat "$UNIT_ERR" 2>/dev/null || true)"

assert_contains "Helper emits the resume preamble" "To resume this run:" "$unit_err"
assert_contains "Helper emits the actual run id after --resume" "--resume $UNIT_RUN_ID" "$unit_err"
assert_contains "Helper echoes the --project flag" "--project" "$unit_err"
assert_contains "Helper echoes the --agent flag" "--agent" "$unit_err"
assert_not_contains "Helper does not leave a <run-id> placeholder" "<run-id>" "$unit_err"
assert_eq "Helper writes the hint to stderr, not stdout" "" "$unit_out"

echo ""
echo "=== Helper print_resume_hint: no-op + set -u safe when RUN_ID is unset ==="

NOID_OUT="$TMPDIR/noid.out"
NOID_ERR="$TMPDIR/noid.err"

# RUN_ID deliberately never set: simulate a signal during early arg parsing.
bash -c 'set -uo pipefail; unset RUN_ID PROJECT_PATH AGENT 2>/dev/null; source "$1/lib/logging.sh"; print_resume_hint' \
  _ "$SCRIPT_DIR" >"$NOID_OUT" 2>"$NOID_ERR"
noid_rc=$?

noid_out="$(cat "$NOID_OUT" 2>/dev/null || true)"
noid_err="$(cat "$NOID_ERR" 2>/dev/null || true)"

assert_eq "Helper returns success when RUN_ID is unset (no set -u abort)" "0" "$noid_rc"
assert_eq "Helper prints nothing to stdout when RUN_ID is unset" "" "$noid_out"
assert_not_contains "Helper prints no resume hint when RUN_ID is unset" "To resume this run:" "$noid_err"

# ---------------------------------------------------------------------------
# Case 1c (idempotency): the helper prints the hint AT MOST ONCE per process.
#
# `_REPOLENS_RESUME_HINT_PRINTED` is load-bearing: resumable exits can be reached
# more than once in a single process (e.g. a finalize-path print followed by a
# late signal trap, or the sequential vs. finalize split for a sleep-interrupt).
# The guard is what keeps those from emitting two "To resume this run:" lines.
# No other case calls the helper twice, so without this test the guard could be
# deleted and the whole suite would still pass.
# ---------------------------------------------------------------------------
echo ""
echo "=== Helper print_resume_hint: idempotent — prints at most once per process ==="

IDEM_ERR="$TMPDIR/idem.err"
IDEM_OUT="$TMPDIR/idem.out"
IDEM_RUN_ID="idem-run-20260629T000000Z-cafef00d"

RUN_ID="$IDEM_RUN_ID" PROJECT_PATH="/tmp/idem-project" AGENT="codex" \
  bash -c 'set -uo pipefail; source "$1/lib/logging.sh"; print_resume_hint; print_resume_hint; print_resume_hint' \
  _ "$SCRIPT_DIR" >"$IDEM_OUT" 2>"$IDEM_ERR"

idem_out="$(cat "$IDEM_OUT" 2>/dev/null || true)"
idem_count="$(grep -c 'To resume this run:' "$IDEM_ERR" 2>/dev/null || true)"

assert_eq "Helper emits the hint exactly once across three calls" "1" "$idem_count"
assert_eq "Helper still prints nothing to stdout under repeated calls" "" "$idem_out"

# ---------------------------------------------------------------------------
# Case 1d (placeholder fallback): with RUN_ID resolvable but PROJECT_PATH/AGENT
# unset, the helper still emits the hint, substituting `<path>`/`<agent>` for the
# missing context. This is the documented `${VAR:-<placeholder>}` default branch
# (a signal can land after RUN_ID is set but before — defensively — the others),
# and the run id, the load-bearing resume token (AC4), must still be real.
# ---------------------------------------------------------------------------
echo ""
echo "=== Helper print_resume_hint: <path>/<agent> fallback when project/agent unset ==="

FB_ERR="$TMPDIR/fallback.err"
FB_RUN_ID="fallback-run-20260629T000000Z-12345678"

RUN_ID="$FB_RUN_ID" \
  bash -c 'set -uo pipefail; unset PROJECT_PATH AGENT 2>/dev/null; source "$1/lib/logging.sh"; print_resume_hint' \
  _ "$SCRIPT_DIR" >/dev/null 2>"$FB_ERR"

fb_err="$(cat "$FB_ERR" 2>/dev/null || true)"

assert_contains "Helper emits the real run id even when project/agent are unset" "--resume $FB_RUN_ID" "$fb_err"
assert_contains "Helper falls back to <path> when PROJECT_PATH is unset" "--project <path>" "$fb_err"
assert_contains "Helper falls back to <agent> when AGENT is unset" "--agent <agent>" "$fb_err"

# ---------------------------------------------------------------------------
# Case 2 (AC2 + AC4 — integration): rate-limit-pending finalize prints the
# hint before `exit 3`.
#
# A fake codex reporting a 7-hour usage limit pushes the parsed wait beyond the
# default sleep cap, so the run aborts to rate-limit-pending and exits 3 (verified
# against HEAD). The hint must appear on stderr carrying the real run id.
# ---------------------------------------------------------------------------
echo ""
echo "=== rate-limit-pending abort prints the resume hint to stderr (exit 3) ==="

RL_DIR="$TMPDIR/rate-limit"
RL_PROJECT="$RL_DIR/project"
RL_BIN="$RL_DIR/bin"
RL_OUT="$RL_DIR/out"
RL_ERR="$RL_DIR/err"
mkdir -p "$RL_BIN"
setup_project "$RL_PROJECT"
install_fake_sleep "$RL_BIN"
cat > "$RL_BIN/codex" <<'SH'
#!/usr/bin/env bash
echo "ERROR: You've hit your usage limit. Please try again in 7 hours."
exit 1
SH
chmod +x "$RL_BIN/codex"

env PATH="$RL_BIN:$PATH" \
  REPOLENS_TEST_SLEEP_LOG="$RL_DIR/sleep.log" \
  REPOLENS_AGENT_TIMEOUT=10 \
  bash "$SCRIPT_DIR/repolens.sh" \
    --project "$RL_PROJECT" \
    --agent codex \
    --focus i18n-strings \
    --mode audit \
    --local \
    --max-issues 99 \
    --yes \
    >"$RL_OUT" 2>"$RL_ERR"
rl_exit=$?

rl_run_id="$(parse_run_id "$RL_OUT")"
[[ -n "$rl_run_id" ]] && RUN_IDS+=("$rl_run_id")
rl_out="$(cat "$RL_OUT" 2>/dev/null || true)"
rl_err="$(cat "$RL_ERR" 2>/dev/null || true)"

assert_eq "rate-limit-pending run exits 3" "3" "$rl_exit"
assert_contains "rate-limit-pending prints the resume preamble to stderr" "To resume this run:" "$rl_err"
assert_contains "rate-limit-pending hint carries the actual run id" "--resume $rl_run_id" "$rl_err"
assert_contains "rate-limit-pending hint echoes the agent" "--agent codex" "$rl_err"
assert_not_contains "rate-limit-pending hint has no <run-id> placeholder" "<run-id>" "$rl_err"
assert_not_contains "rate-limit-pending hint is not on stdout" "To resume this run:" "$rl_out"

# ---------------------------------------------------------------------------
# Case 3 (AC3 — integration): a clean `finished` run prints NO resume hint.
#
# A fake codex that prints DONE lets the lens complete its streak and the run
# exits 0. The hint must appear on neither stream. (This is a guard/absence
# test: it passes before AND after implementation, by design — its job is to
# pin AC3 so a future change cannot start printing the hint on a clean exit.)
# ---------------------------------------------------------------------------
echo ""
echo "=== clean finished run prints NO resume hint (exit 0) ==="

OK_DIR="$TMPDIR/clean"
OK_PROJECT="$OK_DIR/project"
OK_BIN="$OK_DIR/bin"
OK_OUT="$OK_DIR/out"
OK_ERR="$OK_DIR/err"
mkdir -p "$OK_BIN"
setup_project "$OK_PROJECT"
cat > "$OK_BIN/codex" <<'SH'
#!/usr/bin/env bash
echo "Analysis complete. No issues found."
echo "DONE"
exit 0
SH
chmod +x "$OK_BIN/codex"

env PATH="$OK_BIN:$PATH" \
  REPOLENS_AGENT_TIMEOUT=10 \
  bash "$SCRIPT_DIR/repolens.sh" \
    --project "$OK_PROJECT" \
    --agent codex \
    --focus i18n-strings \
    --mode audit \
    --local \
    --max-issues 99 \
    --yes \
    >"$OK_OUT" 2>"$OK_ERR"
ok_exit=$?

ok_run_id="$(parse_run_id "$OK_OUT")"
[[ -n "$ok_run_id" ]] && RUN_IDS+=("$ok_run_id")
ok_out="$(cat "$OK_OUT" 2>/dev/null || true)"
ok_err="$(cat "$OK_ERR" 2>/dev/null || true)"

assert_eq "clean run exits 0" "0" "$ok_exit"
assert_not_contains "clean run prints no resume hint on stderr" "To resume this run:" "$ok_err"
assert_not_contains "clean run prints no resume hint on stdout" "To resume this run:" "$ok_out"

# ---------------------------------------------------------------------------
# Case 4 (AC1 — integration): an interrupted run prints the hint to stderr
# before a non-zero exit.
#
# Reuses the proven, non-racy pattern from tests/test_rate_limit_sleep_interrupt.sh:
# a fake codex triggers a parseable rate-limit sleep, a fake sleep blocks and
# records when it started; once it is sleeping we signal the process group and
# the abort/interrupt exit path runs. The resume hint must land on stderr with
# the real run id, and the run must exit non-zero.
# ---------------------------------------------------------------------------
echo ""
echo "=== interrupted run prints the resume hint to stderr (non-zero exit) ==="

INT_DIR="$TMPDIR/interrupt"
INT_PROJECT="$INT_DIR/project"
INT_BIN="$INT_DIR/bin"
INT_OUT="$INT_DIR/out"
INT_ERR="$INT_DIR/err"
INT_STARTED="$INT_DIR/sleep-started"
mkdir -p "$INT_BIN"
setup_project "$INT_PROJECT"
cat > "$INT_BIN/codex" <<'SH'
#!/usr/bin/env bash
echo "ERROR: You've hit your usage limit. Please try again in 30 seconds."
exit 1
SH
chmod +x "$INT_BIN/codex"
cat > "$INT_BIN/sleep" <<'SH'
#!/usr/bin/env bash
touch "${REPOLENS_TEST_SLEEP_STARTED:?}"
trap 'exit 130' INT TERM
while :; do "${REPOLENS_TEST_REAL_SLEEP:?}" 1; done
SH
chmod +x "$INT_BIN/sleep"

RUN_PID=""
if command -v setsid >/dev/null 2>&1; then
  env PATH="$INT_BIN:$PATH" \
    REPOLENS_TEST_SLEEP_STARTED="$INT_STARTED" \
    REPOLENS_TEST_REAL_SLEEP="$REAL_SLEEP" \
    REPOLENS_RATE_LIMIT_MAX_SLEEP=120 \
    REPOLENS_AGENT_TIMEOUT=10 \
    setsid bash "$SCRIPT_DIR/repolens.sh" \
      --project "$INT_PROJECT" \
      --agent codex \
      --focus i18n-strings \
      --mode audit \
      --local \
      --max-issues 99 \
      --yes \
      >"$INT_OUT" 2>"$INT_ERR" &
  RUN_PID=$!
else
  env PATH="$INT_BIN:$PATH" \
    REPOLENS_TEST_SLEEP_STARTED="$INT_STARTED" \
    REPOLENS_TEST_REAL_SLEEP="$REAL_SLEEP" \
    REPOLENS_RATE_LIMIT_MAX_SLEEP=120 \
    REPOLENS_AGENT_TIMEOUT=10 \
    bash "$SCRIPT_DIR/repolens.sh" \
      --project "$INT_PROJECT" \
      --agent codex \
      --focus i18n-strings \
      --mode audit \
      --local \
      --max-issues 99 \
      --yes \
      >"$INT_OUT" 2>"$INT_ERR" &
  RUN_PID=$!
fi

# Wait (bounded) until the rate-limit sleep is in progress, then interrupt.
for _ in $(seq 1 40); do
  [[ -f "$INT_STARTED" ]] && break
  kill -0 "$RUN_PID" 2>/dev/null || break
  "$REAL_SLEEP" 0.25
done

int_run_id="$(parse_run_id "$INT_OUT")"
[[ -n "$int_run_id" ]] && RUN_IDS+=("$int_run_id")

if kill -0 "$RUN_PID" 2>/dev/null; then
  kill -INT "-$RUN_PID" 2>/dev/null || kill -INT "$RUN_PID" 2>/dev/null || true
fi

for _ in $(seq 1 40); do
  kill -0 "$RUN_PID" 2>/dev/null || break
  "$REAL_SLEEP" 0.25
done
# Belt-and-suspenders: hard-stop if it somehow survived, so we never hang/leak.
if kill -0 "$RUN_PID" 2>/dev/null; then
  kill -KILL "-$RUN_PID" 2>/dev/null || kill -KILL "$RUN_PID" 2>/dev/null || true
fi

wait "$RUN_PID" 2>/dev/null
int_exit=$?
RUN_PID=""

int_out="$(cat "$INT_OUT" 2>/dev/null || true)"
int_err="$(cat "$INT_ERR" 2>/dev/null || true)"

TOTAL=$((TOTAL + 1))
if [[ "$int_exit" -ne 0 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: interrupted run exits non-zero"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: interrupted run exited 0 (expected non-zero)"
fi
assert_contains "interrupted run prints the resume preamble to stderr" "To resume this run:" "$int_err"
assert_contains "interrupted run hint carries the actual run id" "--resume $int_run_id" "$int_err"
assert_not_contains "interrupted run hint is not on stdout" "To resume this run:" "$int_out"

echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
exit "$FAIL"
