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

# #428: a blocked lens abort marker must still fail the round and allow retry.
# Pass --parallel inside a delegated process scope to also exercise real workers.
# Optional lock outcome: normal, once, stop (all short writes), or all writes.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$SCRIPT_DIR/logs"
TEST_DIR="$(mktemp -d "$SCRIPT_DIR/logs/test-lens-marker.XXXXXX")" || exit 1
CASE_DIRS=()
trap 'rm -rf "$TEST_DIR" "${CASE_DIRS[@]}"' EXIT
mkdir -p "$TEST_DIR/bin"
export REAL_CAT REAL_FLOCK
REAL_CAT="$(command -v cat)"
REAL_FLOCK="$(command -v flock)"
cat > "$TEST_DIR/bin/cat" <<'CAT'
#!/usr/bin/env bash
if [[ "$#" -eq 1 && "$1" == "${FAIL_TEMPLATE:-}" ]]; then
  : > "$AGENT_CALLS.lock-contention"
  printf 'Partial template read.'
  exit 42
fi
exec "$REAL_CAT" "$@"
CAT
cat > "$TEST_DIR/bin/flock" <<'LOCK'
#!/usr/bin/env bash
# Deterministic acquisition outcomes: the real lock helper still opens/closes
# its descriptor, and record_lens uses its longer lock after a short timeout.
if [[ "${1:-}" == -w && -e "$AGENT_CALLS.lock-contention" \
    && "$(readlink "/proc/$PPID/fd/${3:-0}")" == */summary.json.lock ]]; then
  case "${LOCK_OUTCOME:-normal}" in
    once)
      if [[ "$2" == 1 && ! -e "$AGENT_CALLS.lock-timeout" ]]; then
        : > "$AGENT_CALLS.lock-timeout"
        exit 1
      fi ;;
    stop) [[ "$2" != 1 ]] || exit 1 ;;
    all) exit 1 ;;
  esac
fi
exec "$REAL_FLOCK" "$@"
LOCK
cat > "$TEST_DIR/bin/codex" <<'AGENT'
#!/usr/bin/env bash
printf 'called\n' >> "$AGENT_CALLS"
printf 'DONE\n'
AGENT
cat > "$TEST_DIR/bin/gh" <<'FORGE'
#!/usr/bin/env bash
printf '[]\n'
FORGE
chmod +x "$TEST_DIR/bin/"*
export PATH="$TEST_DIR/bin:$PATH"
passed=0
failed=0
check() {
  if "$@"; then passed=$((passed + 1)); else failed=$((failed + 1)); printf 'FAIL: %s\n' "$*"; fi
}
json_matches() { jq -e "$@" >/dev/null; }
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/clean.sh"
is_complete() { ! _clean_is_incomplete "$@"; }
printf 'Plan a small command-line audit tool.\n' > "$TEST_DIR/spec.md"
export LOCK_OUTCOME="${2:-normal}"

for mode in audit greenfield; do
  for sink in local forge; do
    LOG_BASE="$(mktemp -d "$SCRIPT_DIR/logs/test-lens-marker-$mode-$sink.XXXXXX")" || exit 1
    CASE_DIRS+=("$LOG_BASE")
    RUN_ID="${LOG_BASE##*/}"
    # The rest of the log directory remains writable, isolating marker failure.
    mkdir "$LOG_BASE/.systemic-failure-abort"
    export FAIL_TEMPLATE="$SCRIPT_DIR/prompts/_base/$mode.md"
    export AGENT_CALLS="$LOG_BASE/agent-calls"
    args=(--mode "$mode" --resume "$RUN_ID" --rounds 1 --depth 1)
    if [[ "$mode" == greenfield ]]; then
      args+=(--spec "$TEST_DIR/spec.md" --focus backlog-planning)
    else
      args+=(--focus injection)
    fi
    if [[ "$sink" == local ]]; then
      args+=(--local --output "$LOG_BASE/output")
    else
      args+=(--forge gh)
    fi
    if [[ "${1:-}" == --parallel ]]; then
      args+=(--parallel --max-parallel 2)
    fi
    env -u TASK_HOURS -u REPOLENS_ROUNDS -u DONE_STREAK_REQUIRED \
      REPOLENS_AGENT_TIMEOUT=5 REPOLENS_AGENT_KILL_GRACE=1 \
      REPOLENS_LENS_HEARTBEAT_INTERVAL=0 REPOLENS_STATUS_INTERVAL=1 \
      bash "$SCRIPT_DIR/repolens.sh" --project "$SCRIPT_DIR" --agent codex --yes \
        "${args[@]}" > "$LOG_BASE/cli.out" 2>&1
    cli_rc=$?
    check test "$cli_rc" -ne 0
    check test ! -e "$AGENT_CALLS"
    if [[ "$LOCK_OUTCOME" == normal ]]; then
      check json_matches '.stopped_reason == "prompt-render-failed"' "$LOG_BASE/summary.json"
      expected_reason=prompt-render-failed
    else
      # When detail cannot persist, the callback status provides a truthful
      # generic reason in memory, independent of either summary write.
      expected_reason=lens-execution-failed
      if [[ "$LOCK_OUTCOME" == once ]]; then
        check test -f "$AGENT_CALLS.lock-timeout"
        check json_matches '.stopped_reason == "lens-execution-failed"' "$LOG_BASE/summary.json"
      else
        check json_matches '.stopped_reason == null' "$LOG_BASE/summary.json"
      fi
    fi
    if [[ "$LOCK_OUTCOME" == all ]]; then
      check json_matches '.lenses == []' "$LOG_BASE/summary.json"
    else
      check json_matches 'any(.lenses[]; .status == "prompt-render-failed")' "$LOG_BASE/summary.json"
    fi
    check json_matches '.state == "failed"' "$LOG_BASE/status.json"
    check json_matches --arg reason "$expected_reason" '.[-1].status == "failed" and .[-1].exit_code != 0 and .[-1].why_stopped == $reason' "$LOG_BASE/attempts.json"
    check test ! -s "$LOG_BASE/.completed"
    check test ! -e "$LOG_BASE/rounds/round-1/.completed"
    check test ! -e "$LOG_BASE/.rounds/round-1.completed"
    check grep -qF 'Unable to persist systemic-abort marker' "$LOG_BASE/cli.out"
    check _clean_is_incomplete "$LOG_BASE"
    if [[ "$sink" == local ]]; then
      # Recovery has no regular abort marker to trigger the old cleanup block.
      rmdir "$LOG_BASE/.systemic-failure-abort"
      unset FAIL_TEMPLATE
      rm -f "$AGENT_CALLS.lock-contention"
      env -u TASK_HOURS -u REPOLENS_ROUNDS -u DONE_STREAK_REQUIRED \
        REPOLENS_AGENT_TIMEOUT=5 REPOLENS_AGENT_KILL_GRACE=1 \
        REPOLENS_LENS_HEARTBEAT_INTERVAL=0 REPOLENS_STATUS_INTERVAL=1 \
        bash "$SCRIPT_DIR/repolens.sh" --project "$SCRIPT_DIR" --agent codex --yes \
          "${args[@]}" > "$LOG_BASE/resume.out" 2>&1
      resume_rc=$?
      check test "$resume_rc" -eq 0
      check test -s "$AGENT_CALLS"
      check test -s "$LOG_BASE/.completed"
      check test -f "$LOG_BASE/rounds/round-1/.completed"
      check json_matches '.state == "finished-empty"' "$LOG_BASE/status.json"
      check json_matches '.stopped_reason == null' "$LOG_BASE/summary.json"
      check json_matches '.[-1].status == "finished-empty" and .[-1].exit_code == 0 and .[-1].why_stopped == ""' "$LOG_BASE/attempts.json"
      check is_complete "$LOG_BASE"
    fi
  done
done

if [[ "$LOCK_OUTCOME" == normal && "${1:-}" != --parallel ]]; then
  # Prove the short-write/long-record ordering with a real contended lock.
  # The zero-second timeout makes the contention deterministic without sleeps.
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/summary.sh"
  lock_summary="$TEST_DIR/lock-summary.json"
  init_summary "$lock_summary" test "$SCRIPT_DIR" audit codex
  exec {held_lock}>>"$lock_summary.lock"
  "$REAL_FLOCK" -n "$held_lock" || exit 1
  REPOLENS_SUMMARY_STOP_REASON_LOCK_TIMEOUT=0 set_stop_reason "$lock_summary" prompt-render-failed
  check test "$?" -ne 0
  check json_matches '.stopped_reason == null' "$lock_summary"
  "$REAL_FLOCK" -u "$held_lock"
  exec {held_lock}>&-
  record_lens "$lock_summary" security injection 0 prompt-render-failed 0 0
  check test "$?" -eq 0
  check json_matches '.stopped_reason == null and any(.lenses[]; .status == "prompt-render-failed")' "$lock_summary"
fi

if [[ "$LOCK_OUTCOME" == normal && "${1:-}" == --parallel ]]; then
  # Exercise the real exit-status collector with both sibling finish orders,
  # and with a failure reaped before capacity is released to the next spawn.
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/logging.sh"
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/parallel.sh"
  # Match the dynamically scoped collection policy used by run_rounds.
  # shellcheck disable=SC2034 # sem_acquire reads this across the source boundary.
  _REPOLENS_STOP_ON_CALLBACK_ERROR=1
  ordered_callback() {
    local marker="$1" rc="$2" prerequisite="$3" deadline=$((SECONDS + 5))
    while [[ ! -e "$prerequisite" ]]; do
      (( SECONDS < deadline )) || return 99
      sleep 0.01
    done
    : > "$marker"
    return "$rc"
  }
  for first in success failure; do
    init_parallel "$TEST_DIR/sem-$first" 2 || exit 1
    release="$TEST_DIR/release-$first"
    first_rc=0 second_rc=42
    if [[ "$first" == failure ]]; then first_rc=42; second_rc=0; fi
    spawn_lens first ordered_callback "$TEST_DIR/$first-first" "$first_rc" "$release" || exit 1
    spawn_lens second ordered_callback "$TEST_DIR/$first-second" "$second_rc" "$TEST_DIR/$first-first" || exit 1
    : > "$release"
    wait_all
    check test "$?" -ne 0
    check test -f "$TEST_DIR/$first-first"
    check test -f "$TEST_DIR/$first-second"
    check test "${#_REPOLENS_CHILD_PIDS[@]}" -eq 0
  done
  init_parallel "$TEST_DIR/sem-early" 1 || exit 1
  : > "$TEST_DIR/release-early"
  spawn_lens failed ordered_callback "$TEST_DIR/early-failed" 42 "$TEST_DIR/release-early" || exit 1
  deadline=$((SECONDS + 5))
  while [[ "${_REPOLENS_WAIT_RC:-0}" == 0 ]]; do
    (( SECONDS < deadline )) || exit 1
    _parallel_poll_once || exit 1
    sleep 0.01
  done
  spawn_lens refused ordered_callback "$TEST_DIR/should-not-start" 0 "$TEST_DIR/release-early"
  check test "$?" -ne 0
  check test ! -e "$TEST_DIR/should-not-start"
  wait_all
  check test "$?" -ne 0
  check test "${#_REPOLENS_CHILD_PIDS[@]}" -eq 0
fi

printf 'Results: %s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
