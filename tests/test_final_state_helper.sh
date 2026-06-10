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

# Regression coverage for issue #281: final-state shell updates must not be
# blocked or lost when best-effort summary stop-reason persistence is skipped.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$SCRIPT_DIR/logs"
# shellcheck disable=SC1091
# shellcheck source=tests/status_test_lib.sh
source "$SCRIPT_DIR/tests/status_test_lib.sh"
# shellcheck disable=SC1091 # Project-root helper sourced through SCRIPT_DIR.
source "$SCRIPT_DIR/lib/summary.sh"
# shellcheck disable=SC1091 # Project-root helper sourced through SCRIPT_DIR.
source "$SCRIPT_DIR/lib/status.sh"
trap status_cleanup EXIT

echo "=== final-state helper signal-safe persistence ==="
status_require_jq

for required_cmd in timeout flock; do
  if ! command -v "$required_cmd" >/dev/null 2>&1; then
    echo "  SKIP: $required_cmd not available"
    status_finish
  fi
done

assert_not_watchdog_timeout() {
  local desc="$1" rc="$2"

  TOTAL=$((TOTAL + 1))
  if [[ "$rc" == "124" ]]; then
    record_fail "$desc" "set_final_state exceeded the watchdog"
  else
    record_pass "$desc"
  fi
}

assert_valid_terminal_states() {
  local failures=()
  local state reason rc

  if ! declare -F set_final_state >/dev/null 2>&1; then
    TOTAL=$((TOTAL + 1))
    record_fail "set_final_state accepts and records all valid terminal states" "set_final_state is not defined"
    return
  fi

  unset SUMMARY_FILE
  for state in finished finished-empty failed rate-limit-pending interrupted; do
    reason="reason-${state}"
    set_final_state "$state" "$reason"
    rc=$?
    if [[ "$rc" != "0" || "${REPOLENS_FINAL_STATE-}" != "$state" || "${REPOLENS_STOP_REASON-}" != "$reason" ]]; then
      failures+=("${state}:rc=${rc}:state=${REPOLENS_FINAL_STATE-}:reason=${REPOLENS_STOP_REASON-}")
    fi
  done

  TOTAL=$((TOTAL + 1))
  if ((${#failures[@]} == 0)); then
    record_pass "set_final_state accepts and records all valid terminal states"
  else
    record_fail "set_final_state accepts and records all valid terminal states" "${failures[*]}"
  fi
}

STANDALONE_OUTPUT="$STATUS_TEST_TMPDIR/standalone-final-state.out"
env -u SUMMARY_FILE timeout 3 bash -c '
  source "$1"
  unset SUMMARY_FILE
  set_final_state "interrupted" "sigint"
  rc=$?
  printf "rc=%s\n" "$rc"
  printf "state=%s\n" "${REPOLENS_FINAL_STATE-}"
  printf "reason=%s\n" "${REPOLENS_STOP_REASON-}"
  exit "$rc"
' _ "$SCRIPT_DIR/lib/status.sh" >"$STANDALONE_OUTPUT" 2>&1
standalone_rc=$?
standalone_output="$(cat "$STANDALONE_OUTPUT" 2>/dev/null || true)"

assert_not_watchdog_timeout "standalone status helper call does not exceed the watchdog" "$standalone_rc"
assert_eq "standalone status helper succeeds without summary persistence helpers" "0" "$standalone_rc"
assert_contains "standalone status helper records interrupted state" "state=interrupted" "$standalone_output"
assert_contains "standalone status helper retains sigint stop reason" "reason=sigint" "$standalone_output"

STANDALONE_SUMMARY_FILE="$STATUS_TEST_TMPDIR/standalone-summary-file.json"
STANDALONE_SUMMARY_OUTPUT="$STATUS_TEST_TMPDIR/standalone-summary-file.out"
printf '{"stopped_reason":null}\n' > "$STANDALONE_SUMMARY_FILE"
timeout 3 bash -c '
  source "$1"
  SUMMARY_FILE="$2"
  set_final_state "interrupted" "sigterm"
  rc=$?
  printf "rc=%s\n" "$rc"
  printf "state=%s\n" "${REPOLENS_FINAL_STATE-}"
  printf "reason=%s\n" "${REPOLENS_STOP_REASON-}"
  exit "$rc"
' _ "$SCRIPT_DIR/lib/status.sh" "$STANDALONE_SUMMARY_FILE" >"$STANDALONE_SUMMARY_OUTPUT" 2>&1
standalone_summary_rc=$?
standalone_summary_output="$(cat "$STANDALONE_SUMMARY_OUTPUT" 2>/dev/null || true)"

assert_not_watchdog_timeout "standalone status helper with a summary file does not exceed the watchdog" "$standalone_summary_rc"
assert_eq "standalone status helper succeeds when stop-reason helper is unavailable" "0" "$standalone_summary_rc"
assert_contains "standalone summary-file path records interrupted state" "state=interrupted" "$standalone_summary_output"
assert_contains "standalone summary-file path retains sigterm stop reason" "reason=sigterm" "$standalone_summary_output"
assert_jq "standalone summary-file path leaves summary unchanged without persistence helper" "$STANDALONE_SUMMARY_FILE" \
  '.stopped_reason == null'

assert_valid_terminal_states

INVALID_SUMMARY_FILE="$STATUS_TEST_TMPDIR/summary-invalid-final-state.json"
init_summary "$INVALID_SUMMARY_FILE" "final-state-invalid" "$STATUS_TEST_TMPDIR/project" "audit" "codex" "" ""
set_stop_reason "$INVALID_SUMMARY_FILE" "previous-summary-reason"
SUMMARY_FILE="$INVALID_SUMMARY_FILE"
REPOLENS_FINAL_STATE="failed"
REPOLENS_STOP_REASON="previous-shell-reason"

TOTAL=$((TOTAL + 1))
if ! declare -F set_final_state >/dev/null 2>&1; then
  record_fail "set_final_state rejects invalid terminal states" "set_final_state is not defined"
else
  set_final_state "not-a-terminal-state" "bad-reason"
  invalid_rc=$?
  if [[ "$invalid_rc" != "0" ]]; then
    record_pass "set_final_state rejects invalid terminal states"
  else
    record_fail "set_final_state rejects invalid terminal states" "expected nonzero rc"
  fi
fi
assert_eq "invalid terminal state leaves REPOLENS_FINAL_STATE unchanged" "failed" "${REPOLENS_FINAL_STATE-}"
assert_eq "invalid terminal state leaves REPOLENS_STOP_REASON unchanged" "previous-shell-reason" "${REPOLENS_STOP_REASON-}"
assert_jq "invalid terminal state leaves summary stopped_reason unchanged" "$INVALID_SUMMARY_FILE" \
  '.stopped_reason == "previous-summary-reason"'

NORMAL_SUMMARY_FILE="$STATUS_TEST_TMPDIR/summary-normal-final-state.json"
init_summary "$NORMAL_SUMMARY_FILE" "final-state-normal" "$STATUS_TEST_TMPDIR/project" "audit" "codex" "" ""
SUMMARY_FILE="$NORMAL_SUMMARY_FILE"
REPOLENS_FINAL_STATE="finished"
REPOLENS_STOP_REASON="pre-normal-reason"
if declare -F set_final_state >/dev/null 2>&1; then
  set_final_state "failed" "synthesizer-failed"
  normal_rc=$?
else
  normal_rc=127
fi

assert_eq "set_final_state succeeds when summary persistence is available" "0" "$normal_rc"
assert_eq "set_final_state records failed state in shell" "failed" "${REPOLENS_FINAL_STATE-}"
assert_eq "set_final_state records stop reason in shell" "synthesizer-failed" "${REPOLENS_STOP_REASON-}"
assert_jq "set_final_state persists stop reason for normal callers" "$NORMAL_SUMMARY_FILE" \
  '.stopped_reason == "synthesizer-failed"'

EMPTY_REASON_SUMMARY_FILE="$STATUS_TEST_TMPDIR/summary-empty-final-state.json"
init_summary "$EMPTY_REASON_SUMMARY_FILE" "final-state-empty-reason" "$STATUS_TEST_TMPDIR/project" "audit" "codex" "" ""
set_stop_reason "$EMPTY_REASON_SUMMARY_FILE" "previous-empty-summary-reason"
SUMMARY_FILE="$EMPTY_REASON_SUMMARY_FILE"
REPOLENS_FINAL_STATE="failed"
REPOLENS_STOP_REASON="previous-empty-shell-reason"
set_final_state "finished" ""
empty_reason_rc=$?

assert_eq "set_final_state succeeds with an explicit empty stop reason" "0" "$empty_reason_rc"
assert_eq "explicit empty stop reason updates final state" "finished" "${REPOLENS_FINAL_STATE-}"
assert_eq "explicit empty stop reason clears shell stop reason" "" "${REPOLENS_STOP_REASON-}"
assert_jq "explicit empty stop reason leaves summary stopped_reason unchanged" "$EMPTY_REASON_SUMMARY_FILE" \
  '.stopped_reason == "previous-empty-summary-reason"'

OMITTED_REASON_SUMMARY_FILE="$STATUS_TEST_TMPDIR/summary-omitted-final-state.json"
init_summary "$OMITTED_REASON_SUMMARY_FILE" "final-state-omitted-reason" "$STATUS_TEST_TMPDIR/project" "audit" "codex" "" ""
set_stop_reason "$OMITTED_REASON_SUMMARY_FILE" "previous-omitted-summary-reason"
SUMMARY_FILE="$OMITTED_REASON_SUMMARY_FILE"
REPOLENS_FINAL_STATE="failed"
REPOLENS_STOP_REASON="previous-omitted-shell-reason"
set_final_state "finished-empty"
omitted_reason_rc=$?

assert_eq "set_final_state succeeds when stop reason is omitted" "0" "$omitted_reason_rc"
assert_eq "omitted stop reason updates final state" "finished-empty" "${REPOLENS_FINAL_STATE-}"
assert_eq "omitted stop reason leaves shell stop reason unchanged" "previous-omitted-shell-reason" "${REPOLENS_STOP_REASON-}"
assert_jq "omitted stop reason leaves summary stopped_reason unchanged" "$OMITTED_REASON_SUMMARY_FILE" \
  '.stopped_reason == "previous-omitted-summary-reason"'

HELD_SUMMARY_FILE="$STATUS_TEST_TMPDIR/summary-held-final-state.json"
HELD_OUTPUT="$STATUS_TEST_TMPDIR/held-final-state.out"
init_summary "$HELD_SUMMARY_FILE" "final-state-held-lock" "$STATUS_TEST_TMPDIR/project" "audit" "codex" "" ""

exec {held_lock_fd}>>"$HELD_SUMMARY_FILE.lock"
TOTAL=$((TOTAL + 1))
if flock -n "$held_lock_fd"; then
  record_pass "test harness holds the summary lock for set_final_state"
else
  record_fail "test harness holds the summary lock for set_final_state" "could not acquire setup lock"
fi

env -u REPOLENS_SUMMARY_LOCK_TIMEOUT REPOLENS_SUMMARY_STOP_REASON_LOCK_TIMEOUT=1 timeout 3 bash -c '
  source "$1"
  source "$2"
  SUMMARY_FILE="$3"
  set_final_state "interrupted" "sigint"
  rc=$?
  printf "rc=%s\n" "$rc"
  printf "state=%s\n" "${REPOLENS_FINAL_STATE-}"
  printf "reason=%s\n" "${REPOLENS_STOP_REASON-}"
  printf "summary_reason=%s\n" "$(jq -r ".stopped_reason // \"null\"" "$SUMMARY_FILE")"
  exit "$rc"
' _ "$SCRIPT_DIR/lib/summary.sh" "$SCRIPT_DIR/lib/status.sh" "$HELD_SUMMARY_FILE" >"$HELD_OUTPUT" 2>&1
held_rc=$?
held_output="$(cat "$HELD_OUTPUT" 2>/dev/null || true)"

assert_not_watchdog_timeout "held summary lock does not block set_final_state past the watchdog" "$held_rc"
assert_eq "held summary lock leaves set_final_state success visible to callers" "0" "$held_rc"
assert_contains "held summary lock still records interrupted shell state" "state=interrupted" "$held_output"
assert_contains "held summary lock still retains sigint shell reason" "reason=sigint" "$held_output"
assert_contains "held summary lock leaves child summary reason unset" "summary_reason=null" "$held_output"
assert_jq "held summary lock leaves stopped_reason unchanged on disk" "$HELD_SUMMARY_FILE" \
  '.stopped_reason == null'

flock -u "$held_lock_fd" 2>/dev/null || true
exec {held_lock_fd}>&-

status_finish
