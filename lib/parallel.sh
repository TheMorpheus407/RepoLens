#!/usr/bin/env bash
# RepoLens — Parallel execution engine

# Uses a file-based semaphore approach for controlling max concurrent processes.
# Background child PIDs are tracked for cleanup on SIGINT/SIGTERM.

# Global state
_REPOLENS_CHILD_PIDS=()
_REPOLENS_SEM_DIR=""
_REPOLENS_MAX_PARALLEL=8

# init_parallel <sem_dir> <max_parallel>
#   Creates semaphore directory, sets max parallel count.
#   Installs signal handlers for clean shutdown.
init_parallel() {
  local sem_dir="$1" max_parallel="${2:-8}"
  _REPOLENS_SEM_DIR="$sem_dir"
  _REPOLENS_MAX_PARALLEL="$max_parallel"
  mkdir -p "$_REPOLENS_SEM_DIR"
  trap '_cleanup_children' INT TERM
}

# _cleanup_children
#   Kill all tracked child processes. Called on signal.
_cleanup_children() {
  local pid
  echo ""
  log_warn "Interrupt received. Stopping ${#_REPOLENS_CHILD_PIDS[@]} child processes..."
  for pid in "${_REPOLENS_CHILD_PIDS[@]}"; do
    kill "$pid" 2>/dev/null
  done
  wait 2>/dev/null
  log_warn "All children stopped."
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
    "$callback" "$@"
    sem_token_remove "$lens_id"
  ) &

  _REPOLENS_CHILD_PIDS+=($!)
}

# wait_all
#   Wait for all tracked children. Returns 0 if all succeeded.
wait_all() {
  local pid rc=0
  for pid in "${_REPOLENS_CHILD_PIDS[@]}"; do
    wait "$pid" 2>/dev/null || rc=1
  done
  _REPOLENS_CHILD_PIDS=()
  return "$rc"
}
