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

# Regression tests for issue #114 — _cleanup_children must be a bounded
# interrupt cleanup path. It should SIGTERM tracked workers, poll for a
# short configurable grace period, SIGKILL stubborn workers, avoid bare
# wait, and short-circuit a second interrupt while cleanup is in progress.
#
# No AI models are invoked. Tests source lib/parallel.sh directly and use
# synthetic callbacks only.

# shellcheck disable=SC2329  # cb_* callbacks are invoked indirectly via spawn_lens string dispatch.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/logging.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/parallel.sh"

PASS=0
FAIL=0
TOTAL=0

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

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

assert_lt() {
  local desc="$1" bound="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if (( actual < bound )); then
    PASS=$((PASS + 1))
    echo "  PASS: $desc ($actual < $bound)"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (actual=$actual, expected < $bound)"
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
    echo "  FAIL: $desc (missing '$needle' in output)"
    echo "  ---- haystack ----"
    printf '%s\n' "$haystack" | sed 's/^/    /'
    echo "  ------------------"
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
    echo "  FAIL: $desc (unexpected '$needle' in output)"
    echo "  ---- haystack ----"
    printf '%s\n' "$haystack" | sed 's/^/    /'
    echo "  ------------------"
  fi
}

assert_success() {
  local desc="$1" rc="$2" output="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$rc" -eq 0 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (rc=$rc)"
    echo "  ---- output ----"
    printf '%s\n' "$output" | sed 's/^/    /'
    echo "  ----------------"
  fi
}

line_count() {
  local file="$1"
  if [[ -f "$file" ]]; then
    wc -l < "$file" | tr -d ' '
  else
    printf '0\n'
  fi
}

wait_for_lines() {
  local file="$1" expected="$2" max_wait="$3" waited=0
  while (( waited < max_wait )); do
    if (( $(line_count "$file") >= expected )); then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

fresh_sem() {
  local case_dir
  case_dir="$(mktemp -d -p "$TMPROOT" sem.XXXXXX)"
  init_parallel "$case_dir" 8
}

run_timeout_scenario() {
  local desc="$1" scenario="$2" timeout_secs="$3" case_dir output rc
  case_dir="$(mktemp -d -p "$TMPROOT" scenario.XXXXXX)"

  if ! command -v timeout >/dev/null 2>&1; then
    echo "  SKIP: $desc (timeout(1) unavailable)"
    return 0
  fi

  output="$(timeout --kill-after=1 "$timeout_secs" bash "$scenario" "$SCRIPT_DIR" "$case_dir" 2>&1)"
  rc=$?
  assert_success "$desc" "$rc" "$output"
}

cb_record_term_and_exit() {
  local term_marker="$1" ready_marker="$2"
  trap 'printf "term\n" >> "$term_marker"; exit 0' TERM
  printf 'ready\n' >> "$ready_marker"
  while true; do
    sleep 1
  done
}

echo "=== parallel.sh bounded interrupt cleanup (issue #114) ==="

# ---------------------------------------------------------------------------
# 1. Clean SIGTERM path — every tracked worker receives SIGTERM, exits
#    without SIGKILL, cleanup logs the final count, and tracked arrays are
#    cleared so a later wait_all has nothing stale to process.
# ---------------------------------------------------------------------------
fresh_sem
term_marker="$(mktemp -p "$TMPROOT")"
ready_marker="$(mktemp -p "$TMPROOT")"
spawn_lens "term-a" cb_record_term_and_exit "$term_marker" "$ready_marker"
spawn_lens "term-b" cb_record_term_and_exit "$term_marker" "$ready_marker"
if ! wait_for_lines "$ready_marker" 2 5; then
  echo "  FAIL: Clean SIGTERM path workers did not become ready"
  FAIL=$((FAIL + 1))
  TOTAL=$((TOTAL + 1))
else
  echo "  PASS: Clean SIGTERM path workers became ready"
  PASS=$((PASS + 1))
  TOTAL=$((TOTAL + 1))
fi

REPOLENS_CLEANUP_GRACE=2
export REPOLENS_CLEANUP_GRACE
stderr_log="$(mktemp -p "$TMPROOT")"
start=$SECONDS
_cleanup_children 2>"$stderr_log"
elapsed=$((SECONDS - start))
stderr_out="$(cat "$stderr_log")"

assert_eq "Clean SIGTERM path: SIGTERM delivered to both workers" "2" "$(line_count "$term_marker")"
assert_lt "Clean SIGTERM path: cleanup returns promptly" 5 "$elapsed"
assert_contains "Clean SIGTERM path: log reports no SIGKILL fallback" "Stopped 2 children (0 SIGKILL'd)" "$stderr_out"
assert_eq "Clean SIGTERM path: child PIDs cleared" "0" "${#_REPOLENS_CHILD_PIDS[@]}"
assert_eq "Clean SIGTERM path: child lens ids cleared" "0" "${#_REPOLENS_CHILD_LENS_IDS[@]}"
unset REPOLENS_CLEANUP_GRACE

# ---------------------------------------------------------------------------
# 2. Invalid cleanup grace — signal handlers should fall back to the safe
#    default and keep stopping children instead of failing on a bad env var.
# ---------------------------------------------------------------------------
fresh_sem
term_marker="$(mktemp -p "$TMPROOT")"
ready_marker="$(mktemp -p "$TMPROOT")"
spawn_lens "invalid-grace" cb_record_term_and_exit "$term_marker" "$ready_marker"
if ! wait_for_lines "$ready_marker" 1 5; then
  echo "  FAIL: Invalid grace path worker did not become ready"
  FAIL=$((FAIL + 1))
  TOTAL=$((TOTAL + 1))
else
  echo "  PASS: Invalid grace path worker became ready"
  PASS=$((PASS + 1))
  TOTAL=$((TOTAL + 1))
fi

REPOLENS_CLEANUP_GRACE=abc
export REPOLENS_CLEANUP_GRACE
stderr_log="$(mktemp -p "$TMPROOT")"
_cleanup_children 2>"$stderr_log"
stderr_out="$(cat "$stderr_log")"

assert_eq "Invalid grace path: SIGTERM still delivered" "1" "$(line_count "$term_marker")"
assert_contains "Invalid grace path: logs fallback to default" "Invalid REPOLENS_CLEANUP_GRACE='abc'; using default 5s." "$stderr_out"
assert_contains "Invalid grace path: cleanup still completes" "Stopped 1 children (0 SIGKILL'd)" "$stderr_out"
assert_eq "Invalid grace path: child PIDs cleared" "0" "${#_REPOLENS_CHILD_PIDS[@]}"
assert_eq "Invalid grace path: child lens ids cleared" "0" "${#_REPOLENS_CHILD_LENS_IDS[@]}"
unset REPOLENS_CLEANUP_GRACE

# ---------------------------------------------------------------------------
# 3. TERM-resistant workers — _cleanup_children must honor the configured
#    grace, escalate to SIGKILL, and return well before the fake workers'
#    natural runtime. The outer timeout is a red-phase guard so the old
#    bare-wait implementation fails quickly instead of hanging the suite.
# ---------------------------------------------------------------------------
stubborn_scenario="$(mktemp -p "$TMPROOT" stubborn.XXXXXX.sh)"
cat > "$stubborn_scenario" <<'SCENARIO'
#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$1"
CASE_DIR="$2"

source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/parallel.sh"

line_count() {
  local file="$1"
  if [[ -f "$file" ]]; then
    wc -l < "$file" | tr -d ' '
  else
    printf '0\n'
  fi
}

wait_for_lines() {
  local file="$1" expected="$2" max_wait="$3" waited=0
  while (( waited < max_wait )); do
    if (( $(line_count "$file") >= expected )); then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

cb_ignore_term() {
  local ready_marker="$1"
  trap '' TERM
  printf 'ready\n' >> "$ready_marker"
  while true; do
    sleep 1
  done
}

ready_marker="$CASE_DIR/ready"
stderr_log="$CASE_DIR/stderr.log"
: > "$ready_marker"

init_parallel "$CASE_DIR/sem" 8
REPOLENS_CLEANUP_GRACE=2
export REPOLENS_CLEANUP_GRACE

spawn_lens "stubborn-a" cb_ignore_term "$ready_marker"
spawn_lens "stubborn-b" cb_ignore_term "$ready_marker"
wait_for_lines "$ready_marker" 2 5 || { echo "workers did not become ready"; exit 10; }

start=$SECONDS
_cleanup_children 2>"$stderr_log"
elapsed=$((SECONDS - start))
stderr_out="$(cat "$stderr_log")"

(( elapsed < 8 )) || { echo "cleanup took ${elapsed}s"; exit 11; }
[[ "$stderr_out" == *"Stopped 2 children (2 SIGKILL'd)"* ]] || {
  echo "missing SIGKILL count in cleanup log"
  printf '%s\n' "$stderr_out"
  exit 12
}
[[ "${#_REPOLENS_CHILD_PIDS[@]}" == "0" ]] || { echo "child PIDs not cleared"; exit 13; }
[[ "${#_REPOLENS_CHILD_LENS_IDS[@]}" == "0" ]] || { echo "child lens ids not cleared"; exit 14; }
SCENARIO

run_timeout_scenario "TERM-resistant path: cleanup escalates to SIGKILL within bounded grace" "$stubborn_scenario" 12

# ---------------------------------------------------------------------------
# 4. Re-entry path — a second TERM while cleanup is already in progress
#    must not wait through the original grace again. The second signal is
#    observable: elapsed time should be below the configured 6s grace.
# ---------------------------------------------------------------------------
reentry_scenario="$(mktemp -p "$TMPROOT" reentry.XXXXXX.sh)"
cat > "$reentry_scenario" <<'SCENARIO'
#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$1"
CASE_DIR="$2"

source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/parallel.sh"

cb_ignore_term() {
  local ready_marker="$1"
  trap '' TERM
  printf 'ready\n' >> "$ready_marker"
  while true; do
    sleep 1
  done
}

ready_marker="$CASE_DIR/ready"
stderr_log="$CASE_DIR/stderr.log"
: > "$ready_marker"

init_parallel "$CASE_DIR/sem" 8
REPOLENS_CLEANUP_GRACE=6
export REPOLENS_CLEANUP_GRACE

spawn_lens "reentry-stubborn" cb_ignore_term "$ready_marker"

waited=0
while (( waited < 5 )); do
  if [[ "$(wc -l < "$ready_marker" | tr -d ' ')" == "1" ]]; then
    break
  fi
  sleep 1
  waited=$((waited + 1))
done
[[ "$(wc -l < "$ready_marker" | tr -d ' ')" == "1" ]] || { echo "worker did not become ready"; exit 20; }

parent_pid="$BASHPID"
( sleep 1; kill -TERM "$parent_pid" 2>/dev/null || true ) &

start=$SECONDS
_cleanup_children 2>"$stderr_log"
elapsed=$((SECONDS - start))

(( elapsed < 5 )) || { echo "re-entry cleanup took ${elapsed}s"; cat "$stderr_log"; exit 21; }
[[ "${#_REPOLENS_CHILD_PIDS[@]}" == "0" ]] || { echo "child PIDs not cleared"; exit 22; }
[[ "${#_REPOLENS_CHILD_LENS_IDS[@]}" == "0" ]] || { echo "child lens ids not cleared"; exit 23; }
SCENARIO

run_timeout_scenario "Re-entry path: second interrupt forces cleanup without waiting full grace" "$reentry_scenario" 12

# ---------------------------------------------------------------------------
# 5. Structural guard for the public cleanup function. Bash 4.0 rules out
#    wait -t/-n/-p, and the issue explicitly forbids bare wait in this
#    signal handler.
# ---------------------------------------------------------------------------
cleanup_src="$(declare -f _cleanup_children)"

TOTAL=$((TOTAL + 1))
if [[ "$cleanup_src" == *"REPOLENS_CLEANUP_GRACE"* ]] \
   && [[ "$cleanup_src" == *":-5"* ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: _cleanup_children uses REPOLENS_CLEANUP_GRACE default 5"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: _cleanup_children missing REPOLENS_CLEANUP_GRACE default 5"
fi

TOTAL=$((TOTAL + 1))
if [[ "$cleanup_src" == *"kill -0"* ]] \
   && [[ "$cleanup_src" == *"sleep 1"* ]] \
   && [[ "$cleanup_src" == *"kill -TERM"* ]] \
   && [[ "$cleanup_src" == *"kill -KILL"* ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: _cleanup_children uses bounded poll and TERM-to-KILL escalation"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: _cleanup_children missing bounded cleanup primitives"
  echo "  ---- current _cleanup_children body ----"
  printf '%s\n' "$cleanup_src" | sed 's/^/    /'
  echo "  ----------------------------------------"
fi

bare_wait_lines="$(printf '%s\n' "$cleanup_src" | grep -E '^[[:space:]]*wait([[:space:]]*(#.*)?$|[[:space:]]+[0-9]?>|[[:space:]]+2>|[[:space:]]*;)' || true)"
assert_eq "Structural guard: _cleanup_children does not call bare wait" "" "$bare_wait_lines"
assert_not_contains "Structural guard: no Bash 5 wait -t" "wait -t" "$cleanup_src"
assert_not_contains "Structural guard: no Bash 4-incompatible wait -n" "wait -n" "$cleanup_src"
assert_not_contains "Structural guard: no Bash 5 wait -p" "wait -p" "$cleanup_src"

# ---------------------------------------------------------------------------
# 6. Documentation coverage — the new operator-facing cleanup grace knob
#    must be discoverable from usage() and the README environment table.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
if grep -q 'REPOLENS_CLEANUP_GRACE' "$SCRIPT_DIR/repolens.sh"; then
  PASS=$((PASS + 1))
  echo "  PASS: repolens.sh documents REPOLENS_CLEANUP_GRACE"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: repolens.sh usage() missing REPOLENS_CLEANUP_GRACE"
fi

TOTAL=$((TOTAL + 1))
if grep -q 'REPOLENS_CLEANUP_GRACE' "$SCRIPT_DIR/README.md"; then
  PASS=$((PASS + 1))
  echo "  PASS: README.md documents REPOLENS_CLEANUP_GRACE"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: README.md missing REPOLENS_CLEANUP_GRACE"
fi

echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
exit "$FAIL"
