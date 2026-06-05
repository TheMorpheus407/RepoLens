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

# Regression coverage for issue #280: stop-reason persistence is used from
# shutdown paths, so lock contention must be bounded and deterministic.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$SCRIPT_DIR/logs"
# shellcheck disable=SC1091
# shellcheck source=tests/status_test_lib.sh
source "$SCRIPT_DIR/tests/status_test_lib.sh"
source "$SCRIPT_DIR/lib/summary.sh"
trap status_cleanup EXIT

echo "=== summary stop-reason signal-safe locking ==="
status_require_jq

for required_cmd in timeout flock; do
  if ! command -v "$required_cmd" >/dev/null 2>&1; then
    echo "  SKIP: $required_cmd not available"
    status_finish
  fi
done

run_stop_reason_with_watchdog() {
  local summary_file="$1" reason="$2" watchdog_seconds="$3" output_file="$4"
  shift 4

  env -u REPOLENS_SUMMARY_LOCK_TIMEOUT "$@" timeout "$watchdog_seconds" bash -c '
    source "$1"
    set_stop_reason "$2" "$3"
  ' _ "$SCRIPT_DIR/lib/summary.sh" "$summary_file" "$reason" >"$output_file" 2>&1
}

assert_not_watchdog_timeout() {
  local desc="$1" rc="$2"

  TOTAL=$((TOTAL + 1))
  if [[ "$rc" == "124" ]]; then
    record_fail "$desc" "set_stop_reason exceeded the watchdog"
  else
    record_pass "$desc"
  fi
}

assert_nonzero_not_timeout() {
  local desc="$1" rc="$2"

  TOTAL=$((TOTAL + 1))
  if [[ "$rc" != "0" && "$rc" != "124" ]]; then
    record_pass "$desc"
  else
    record_fail "$desc" "expected nonzero non-timeout rc, got $rc"
  fi
}

SUMMARY_FILE="$STATUS_TEST_TMPDIR/summary-stop-reason.json"
init_summary "$SUMMARY_FILE" "summary-stop-reason" "$STATUS_TEST_TMPDIR/project" "audit" "codex" "" ""

set_stop_reason "$SUMMARY_FILE" "normal-stop"
normal_rc=$?
assert_eq "set_stop_reason succeeds when the lock is available" "0" "$normal_rc"
assert_jq "set_stop_reason persists the requested reason" "$SUMMARY_FILE" \
  '.stopped_reason == "normal-stop"'

set_stop_reason "$SUMMARY_FILE" ""
empty_rc=$?
assert_eq "set_stop_reason keeps empty reasons as a no-op" "0" "$empty_rc"
assert_jq "empty stop reason leaves the existing reason unchanged" "$SUMMARY_FILE" \
  '.stopped_reason == "normal-stop"'

HELD_SUMMARY_FILE="$STATUS_TEST_TMPDIR/summary-held-lock.json"
HELD_OUTPUT="$STATUS_TEST_TMPDIR/held-lock.out"
init_summary "$HELD_SUMMARY_FILE" "summary-held-lock" "$STATUS_TEST_TMPDIR/project" "audit" "codex" "" ""

exec {held_lock_fd}>>"$HELD_SUMMARY_FILE.lock"
TOTAL=$((TOTAL + 1))
if flock -n "$held_lock_fd"; then
  record_pass "test harness holds the summary lock"
else
  record_fail "test harness holds the summary lock" "could not acquire setup lock"
fi

run_stop_reason_with_watchdog "$HELD_SUMMARY_FILE" "held-lock" 3 "$HELD_OUTPUT"
held_rc=$?

assert_not_watchdog_timeout "held summary lock does not block stop-reason persistence past the watchdog" "$held_rc"
assert_nonzero_not_timeout "held summary lock reports that stop-reason persistence was skipped" "$held_rc"
assert_jq "held summary lock leaves stopped_reason unchanged" "$HELD_SUMMARY_FILE" \
  '.stopped_reason == null'

run_stop_reason_with_watchdog "$HELD_SUMMARY_FILE" "held-lock-long-summary-timeout" 3 "$HELD_OUTPUT" \
  REPOLENS_SUMMARY_LOCK_TIMEOUT=30
held_with_general_rc=$?

assert_not_watchdog_timeout "long general summary timeout does not delay stop-reason persistence" "$held_with_general_rc"
assert_nonzero_not_timeout "long general summary timeout still reports skipped stop-reason persistence" "$held_with_general_rc"
assert_jq "long general summary timeout leaves stopped_reason unchanged" "$HELD_SUMMARY_FILE" \
  '.stopped_reason == null'

run_stop_reason_with_watchdog "$HELD_SUMMARY_FILE" "held-lock-invalid-stop-timeout" 3 "$HELD_OUTPUT" \
  REPOLENS_SUMMARY_STOP_REASON_LOCK_TIMEOUT=not-a-number
held_with_invalid_stop_rc=$?

assert_not_watchdog_timeout "invalid stop-reason timeout falls back to bounded persistence" "$held_with_invalid_stop_rc"
assert_nonzero_not_timeout "invalid stop-reason timeout reports skipped stop-reason persistence" "$held_with_invalid_stop_rc"
assert_jq "invalid stop-reason timeout leaves stopped_reason unchanged" "$HELD_SUMMARY_FILE" \
  '.stopped_reason == null'

flock -u "$held_lock_fd" 2>/dev/null || true
exec {held_lock_fd}>&-

set_stop_reason "$HELD_SUMMARY_FILE" "after-release"
after_release_rc=$?
assert_eq "set_stop_reason recovers after the held lock is released" "0" "$after_release_rc"
assert_jq "released summary lock allows stop reason persistence" "$HELD_SUMMARY_FILE" \
  '.stopped_reason == "after-release"'

CUSTOM_TIMEOUT_SUMMARY_FILE="$STATUS_TEST_TMPDIR/summary-custom-stop-timeout.json"
CUSTOM_TIMEOUT_OUTPUT="$STATUS_TEST_TMPDIR/custom-stop-timeout.out"
CUSTOM_TIMEOUT_READY="$STATUS_TEST_TMPDIR/custom-stop-timeout.ready"
init_summary "$CUSTOM_TIMEOUT_SUMMARY_FILE" "summary-custom-stop-timeout" "$STATUS_TEST_TMPDIR/project" "audit" "codex" "" ""

exec {custom_timeout_lock_fd}>>"$CUSTOM_TIMEOUT_SUMMARY_FILE.lock"
TOTAL=$((TOTAL + 1))
if flock -n "$custom_timeout_lock_fd"; then
  record_pass "test harness holds the custom-timeout summary lock"
else
  record_fail "test harness holds the custom-timeout summary lock" "could not acquire setup lock"
fi

env -u REPOLENS_SUMMARY_LOCK_TIMEOUT REPOLENS_SUMMARY_STOP_REASON_LOCK_TIMEOUT=4 timeout 6 bash -c '
  source "$1"
  : > "$4"
  set_stop_reason "$2" "$3"
' _ "$SCRIPT_DIR/lib/summary.sh" "$CUSTOM_TIMEOUT_SUMMARY_FILE" "custom-timeout-release" "$CUSTOM_TIMEOUT_READY" \
  >"$CUSTOM_TIMEOUT_OUTPUT" 2>&1 &
custom_timeout_pid=$!
for _ in {1..50}; do
  [[ -e "$CUSTOM_TIMEOUT_READY" ]] && break
  sleep 0.1
done
TOTAL=$((TOTAL + 1))
if [[ -e "$CUSTOM_TIMEOUT_READY" ]]; then
  record_pass "custom-timeout child reaches stop-reason persistence before release"
else
  record_fail "custom-timeout child reaches stop-reason persistence before release" "ready marker was not written"
fi
sleep 2
flock -u "$custom_timeout_lock_fd" 2>/dev/null || true
exec {custom_timeout_lock_fd}>&-
wait "$custom_timeout_pid"
custom_timeout_rc=$?

assert_eq "custom stop-reason timeout can wait for a released lock" "0" "$custom_timeout_rc"
assert_jq "custom stop-reason timeout persists after delayed release" "$CUSTOM_TIMEOUT_SUMMARY_FILE" \
  '.stopped_reason == "custom-timeout-release"'

STALE_SUMMARY_FILE="$STATUS_TEST_TMPDIR/summary-stale-directory-lock.json"
STALE_OUTPUT="$STATUS_TEST_TMPDIR/stale-directory-lock.out"
init_summary "$STALE_SUMMARY_FILE" "summary-stale-directory-lock" "$STATUS_TEST_TMPDIR/project" "audit" "codex" "" ""
mkdir "$STALE_SUMMARY_FILE.lock"

run_stop_reason_with_watchdog "$STALE_SUMMARY_FILE" "stale-lock" 3 "$STALE_OUTPUT"
stale_rc=$?

assert_not_watchdog_timeout "stale summary lock directory does not block stop-reason persistence" "$stale_rc"
assert_nonzero_not_timeout "stale summary lock directory reports that stop-reason persistence was skipped" "$stale_rc"
assert_jq "stale summary lock directory leaves stopped_reason unchanged" "$STALE_SUMMARY_FILE" \
  '.stopped_reason == null'

status_finish
