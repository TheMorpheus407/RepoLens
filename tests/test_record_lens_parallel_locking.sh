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

# Regression coverage for issue #221: parallel record_lens mutations must keep
# every result, and lock contention must fail boundedly rather than hanging.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
# shellcheck source=tests/status_test_lib.sh
source "$SCRIPT_DIR/tests/status_test_lib.sh"
source "$SCRIPT_DIR/lib/summary.sh"
trap status_cleanup EXIT

echo "=== summary.json record_lens parallel locking ==="
status_require_jq

SUMMARY_FILE="$STATUS_TEST_TMPDIR/summary-parallel.json"
init_summary "$SUMMARY_FILE" "summary-parallel" "$STATUS_TEST_TMPDIR/project" "audit" "codex" "" ""

pids=()
for i in {1..16}; do
  record_lens "$SUMMARY_FILE" "domain" "lens-$i" "$i" "completed" 1 0 &
  pids+=("$!")
done

parallel_rc=0
for pid in "${pids[@]}"; do
  wait "$pid" || parallel_rc=1
done

assert_eq "All parallel record_lens calls exit cleanly" "0" "$parallel_rc"
assert_jq "Parallel record_lens preserves every lens record" "$SUMMARY_FILE" \
  '(.lenses | length) == 16
   and ([.lenses[].lens] | unique | length) == 16
   and .totals.lenses_run == 16
   and .totals.iterations_total == 136
   and .totals.issues_created == 16'

STALE_SUMMARY_FILE="$STATUS_TEST_TMPDIR/summary-stale-lock.json"
init_summary "$STALE_SUMMARY_FILE" "summary-stale-lock" "$STATUS_TEST_TMPDIR/project" "audit" "codex" "" ""
mkdir "$STALE_SUMMARY_FILE.lock"

TOTAL=$((TOTAL + 1))
if ! command -v timeout >/dev/null 2>&1; then
  record_fail "record_lens lock acquisition is bounded" "timeout command unavailable"
else
  timeout 2 bash -c '
    source "$1"
    shift
    record_lens "$@"
  ' _ "$SCRIPT_DIR/lib/summary.sh" "$STALE_SUMMARY_FILE" "domain" "blocked" 1 "completed" 0 0
  lock_rc=$?
  if [[ "$lock_rc" == "124" ]]; then
    record_fail "record_lens lock acquisition is bounded" "record_lens hung behind a stale lock"
  else
    record_pass "record_lens lock acquisition is bounded"
  fi
fi

assert_jq "Failed lock acquisition leaves summary unchanged" "$STALE_SUMMARY_FILE" \
  '(.lenses | length) == 0
   and .totals.lenses_run == 0
   and .totals.iterations_total == 0
   and .totals.issues_created == 0'

for mutator in set_summary_health set_stop_reason clear_stop_reason finalize_summary; do
  blocked_file="$STATUS_TEST_TMPDIR/summary-${mutator}.json"
  init_summary "$blocked_file" "summary-${mutator}" "$STATUS_TEST_TMPDIR/project" "audit" "codex" "" ""
  mkdir "$blocked_file.lock"

  TOTAL=$((TOTAL + 1))
  if ! command -v timeout >/dev/null 2>&1; then
    record_fail "$mutator lock acquisition is bounded" "timeout command unavailable"
    continue
  fi

  case "$mutator" in
    set_summary_health)
      timeout 2 bash -c '
        source "$1"
        set_summary_health "$2" 90
      ' _ "$SCRIPT_DIR/lib/summary.sh" "$blocked_file"
      ;;
    set_stop_reason)
      timeout 2 bash -c '
        source "$1"
        set_stop_reason "$2" "blocked-reason"
      ' _ "$SCRIPT_DIR/lib/summary.sh" "$blocked_file"
      ;;
    clear_stop_reason)
      timeout 2 bash -c '
        source "$1"
        clear_stop_reason "$2"
      ' _ "$SCRIPT_DIR/lib/summary.sh" "$blocked_file"
      ;;
    finalize_summary)
      timeout 2 bash -c '
        source "$1"
        finalize_summary "$2"
      ' _ "$SCRIPT_DIR/lib/summary.sh" "$blocked_file"
      ;;
  esac
  mutator_rc=$?

  if [[ "$mutator_rc" == "124" ]]; then
    record_fail "$mutator lock acquisition is bounded" "$mutator hung behind a stale lock"
  else
    record_pass "$mutator lock acquisition is bounded"
  fi
done

status_finish
