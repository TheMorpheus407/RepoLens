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

# Issues #407/#408: a captured-output watchdog is part of the assertion.
# shellcheck disable=SC2329
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/parallel.sh"
source "$SCRIPT_DIR/tests/process_scope_test_support.sh"
require_process_scopes
if [[ "${1:-}" != --captured ]]; then
  start=$SECONDS
  output="$(timeout --kill-after=2 40 bash "$0" --captured 2>&1)"; rc=$?
  printf '%s\n' "$output"
  (( rc == 0 && SECONDS - start < 40 )) || {
    echo "FAIL: captured output did not close inside the deadline/grace watchdog"; exit 1;
  }
  echo "PASS: captured stdout/stderr closed without natural sleep expiry"
  exit 0
fi
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
PASS=0 FAIL=0
check() {
  local description="$1"; shift
  if "$@"; then echo "PASS: $description"; PASS=$((PASS + 1));
  else echo "FAIL: $description"; FAIL=$((FAIL + 1)); fi
}
record_sleep() {
  local marker="$1"
  sleep 120 &
  awk '{print $1, $22}' "/proc/$!/stat" > "$marker"
  wait
}
ignore_term() { trap '' TERM; record_sleep "$1"; }
fast() { printf 'finished\n' > "$1"; }
leader_exits() { sleep 120 & awk '{print $1, $22}' "/proc/$!/stat" > "$1"; }
assert_dead() {
  local marker="$1" pid state started current_started
  [[ -s "$marker" ]] || return 1
  read -r pid started < "$marker"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  if [[ -e "/proc/$pid/stat" ]]; then
    read -r state current_started < <(awk '{print $3, $22}' "/proc/$pid/stat")
    [[ "$started" != "$current_started" || "$state" == Z || "$state" == X ]] || return 1
  fi
}
for scenario in clean mixed ignore leader; do
  init_parallel "$TMPROOT/$scenario-sem" 2 || exit 1
  REPOLENS_CHILD_MAX_WAIT=2
  case "$scenario" in
    clean) spawn_lens "$scenario" record_sleep "$TMPROOT/$scenario.pid" ;;
    mixed)
      spawn_lens fast fast "$TMPROOT/fast"
      spawn_lens "$scenario" record_sleep "$TMPROOT/$scenario.pid" ;;
    ignore) spawn_lens "$scenario" ignore_term "$TMPROOT/$scenario.pid" ;;
    leader) spawn_lens "$scenario" leader_exits "$TMPROOT/$scenario.pid" ;;
  esac
  # Prove the descendant actually started, then test its exact recorded PID.
  deadline=$((SECONDS + 3))
  while [[ ! -s "$TMPROOT/$scenario.pid" ]] && (( SECONDS < deadline )); do sleep 0.02; done
  read -r observed observed_start < "$TMPROOT/$scenario.pid"
  [[ "$observed_start" =~ ^[0-9]+$ ]] || exit 1
  check "$scenario descendant was live before cleanup" kill -0 "$observed"
  owned_path="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["path"])' "${_REPOLENS_SCOPE_RUNTIMES[${#_REPOLENS_CHILD_PIDS[@]}-1]}/manifest.json")"
  start=$SECONDS
  wait_all; rc=$?
  check "$scenario reports outer timeout or orphan cleanup" test "$rc" = 1
  check "$scenario finishes before 120-second natural expiry" test "$((SECONDS - start))" -lt 20
  check "$scenario recorded descendant is dead" assert_dead "$TMPROOT/$scenario.pid"
  check "$scenario kernel-confirmed empty scope removed" test ! -e "$owned_path"
done
check "concurrent successful callback completed" test -s "$TMPROOT/fast"
init_parallel "$TMPROOT/happy" 2 || exit 1
spawn_lens happy fast "$TMPROOT/happy-done" || exit 1
check "ordinary successful callback succeeds" wait_all
echo "Results: $PASS passed, $FAIL failed"
exit "$FAIL"
