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

# RepoLens — Parallel execution engine

# Uses a file-based semaphore approach for controlling max concurrent processes.
# Background child PIDs are tracked for cleanup on SIGINT/SIGTERM.

# Global state
# _REPOLENS_CHILD_PIDS and _REPOLENS_CHILD_LENS_IDS are parallel arrays
# kept index-aligned. spawn_lens appends to both; wait_all clears both.
# Any future edit that inserts/removes elements must update both in lockstep
# so wait_all can map PID -> lens id on deadline expiry (issue #111).
_REPOLENS_CHILD_PIDS=()
_REPOLENS_CHILD_LENS_IDS=()
_REPOLENS_SEM_DIR=""
_REPOLENS_MAX_PARALLEL=8
_REPOLENS_CLEANUP_IN_PROGRESS=0
_REPOLENS_CLEANUP_FORCE_KILL=0

# init_parallel <sem_dir> <max_parallel>
#   Creates semaphore directory, sets max parallel count.
#   Installs signal handlers for clean shutdown.
init_parallel() {
  local sem_dir="$1" max_parallel="${2:-8}"
  _REPOLENS_SEM_DIR="$sem_dir"
  _REPOLENS_MAX_PARALLEL="$max_parallel"
  _REPOLENS_CLEANUP_IN_PROGRESS=0
  _REPOLENS_CLEANUP_FORCE_KILL=0
  mkdir -p "$_REPOLENS_SEM_DIR"
  trap '_cleanup_children' INT TERM
}

# _cleanup_children
#   Kill all tracked child processes with bounded TERM-to-KILL cleanup.
_cleanup_children() {
  local pid cleanup_grace waited remaining sigkill_count total_children
  local tracked_pids=("${_REPOLENS_CHILD_PIDS[@]}")

  echo ""

  if [[ "$_REPOLENS_CLEANUP_IN_PROGRESS" == "1" ]]; then
    _REPOLENS_CLEANUP_FORCE_KILL=1
    log_warn "Cleanup already in progress; forcing SIGKILL for remaining children."
    for pid in "${tracked_pids[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null
      fi
    done
    _REPOLENS_CHILD_PIDS=()
    _REPOLENS_CHILD_LENS_IDS=()
    return 0
  fi

  _REPOLENS_CLEANUP_IN_PROGRESS=1
  _REPOLENS_CLEANUP_FORCE_KILL=0
  total_children="${#tracked_pids[@]}"
  sigkill_count=0

  cleanup_grace="${REPOLENS_CLEANUP_GRACE:-5}"
  if [[ ! "$cleanup_grace" =~ ^[0-9]+$ ]]; then
    log_warn "Invalid REPOLENS_CLEANUP_GRACE='$cleanup_grace'; using default 5s."
    cleanup_grace=5
  else
    cleanup_grace=$((10#$cleanup_grace))
  fi

  log_warn "Interrupt received. Stopping ${total_children} child processes..."
  for pid in "${tracked_pids[@]}"; do
    kill -TERM "$pid" 2>/dev/null
  done

  waited=0
  while (( waited < cleanup_grace )); do
    remaining=0
    for pid in "${tracked_pids[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        remaining=$((remaining + 1))
      else
        wait "$pid" 2>/dev/null || true
      fi
    done
    (( remaining == 0 || _REPOLENS_CLEANUP_FORCE_KILL == 1 )) && break
    sleep 1
    waited=$((waited + 1))
  done

  for pid in "${tracked_pids[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null
      sigkill_count=$((sigkill_count + 1))
    else
      wait "$pid" 2>/dev/null || true
    fi
  done

  waited=0
  while (( waited < 2 )); do
    remaining=0
    for pid in "${tracked_pids[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        remaining=$((remaining + 1))
      else
        wait "$pid" 2>/dev/null || true
      fi
    done
    (( remaining == 0 )) && break
    sleep 1
    waited=$((waited + 1))
  done

  _REPOLENS_CHILD_PIDS=()
  _REPOLENS_CHILD_LENS_IDS=()
  _REPOLENS_CLEANUP_IN_PROGRESS=0
  _REPOLENS_CLEANUP_FORCE_KILL=0
  log_warn "Stopped ${total_children} children (${sigkill_count} SIGKILL'd)"
}

# sem_acquire
#   Block until fewer than max_parallel token files exist in sem_dir.
#   Uses polling with 2-second sleep.
sem_acquire() {
  while true; do
    local count
    count="$(find "$_REPOLENS_SEM_DIR" -maxdepth 1 -name '*.token' 2>/dev/null | wc -l)"
    if [[ "$count" -lt "$_REPOLENS_MAX_PARALLEL" ]]; then
      break
    fi
    sleep 2
  done
}

# sem_token_create <lens_id>
#   Touch a token file for this lens.
sem_token_create() {
  touch "$_REPOLENS_SEM_DIR/${1}.token"
}

# sem_token_remove <lens_id>
#   Remove the token file for this lens.
sem_token_remove() {
  rm -f "$_REPOLENS_SEM_DIR/${1}.token"
}

# spawn_lens <lens_id> <callback_function> [args...]
#   Acquires semaphore, runs callback in background, tracks PID.
#   The callback function receives lens_id + any extra args.
#   On completion, releases semaphore token.
spawn_lens() {
  local lens_id="$1"
  shift
  local callback="$1"
  shift

  sem_acquire
  sem_token_create "$lens_id"

  (
    # EXIT trap fires on every bash-trappable exit path (clean return,
    # exit N, errexit, SIGTERM, SIGHUP, SIGINT) so the token is always
    # released. SIGKILL / OOM still leak — see issue #117 for the
    # startup-time stale-token GC that handles that case.
    trap 'sem_token_remove "$lens_id"' EXIT
    "$callback" "$@"
  ) &

  _REPOLENS_CHILD_PIDS+=($!)
  _REPOLENS_CHILD_LENS_IDS+=("$lens_id")
}

# wait_all
#   Wait for all tracked children with a per-child deadline. Returns 0 if
#   all succeeded, 1 if any child failed or was killed by the deadline.
#
#   REPOLENS_CHILD_MAX_WAIT (env, seconds): hard ceiling per child.
#     Default: 144000 (40h). Should be >= MAX_ITERATIONS_PER_LENS *
#     resolved agent timeout plus a safety buffer for non-agent I/O
#     (gh queries, file locks, etc.). With the longest default of 20
#     iterations * 1800s deploy timeout = 36000s, 144000s gives a large
#     buffer for explicit high timeout overrides.
#
#   Bash 4.0-compatible: polls with `kill -0` + `sleep 1`, NOT `wait -t`
#   (bash 5.1+ only). If a child exceeds the deadline, it is sent SIGTERM,
#   given up to 10s to exit gracefully, then SIGKILL'd if still alive. The
#   stuck lens id is logged and rc=1 is returned, but the remaining
#   children are still processed — one stall must not block the rest.
wait_all() {
  local max_wait="${REPOLENS_CHILD_MAX_WAIT:-144000}"
  local rc=0
  local i pid lens_id waited grace

  for i in "${!_REPOLENS_CHILD_PIDS[@]}"; do
    pid="${_REPOLENS_CHILD_PIDS[$i]}"
    lens_id="${_REPOLENS_CHILD_LENS_IDS[$i]:-<unknown>}"
    waited=0

    while kill -0 "$pid" 2>/dev/null; do
      if (( waited >= max_wait )); then
        log_warn "[$lens_id] exceeded REPOLENS_CHILD_MAX_WAIT=${max_wait}s, terminating (pid=$pid)"
        kill -TERM "$pid" 2>/dev/null
        grace=0
        while kill -0 "$pid" 2>/dev/null && (( grace < 10 )); do
          sleep 1
          grace=$((grace + 1))
        done
        if kill -0 "$pid" 2>/dev/null; then
          log_warn "[$lens_id] did not exit after SIGTERM; sending SIGKILL"
          kill -KILL "$pid" 2>/dev/null
        fi
        rc=1
        break
      fi
      sleep 1
      waited=$((waited + 1))
    done

    # Reap the child (non-blocking if it is already dead) and surface
    # its exit status. A non-zero exit here could be either a genuine
    # callback failure or the SIGTERM/SIGKILL we just sent.
    if ! wait "$pid" 2>/dev/null; then
      rc=1
    fi
  done

  _REPOLENS_CHILD_PIDS=()
  _REPOLENS_CHILD_LENS_IDS=()
  return "$rc"
}
