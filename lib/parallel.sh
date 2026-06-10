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
# _REPOLENS_CHILD_PIDS, _REPOLENS_CHILD_LENS_IDS, and
# _REPOLENS_CHILD_STARTED_AT are parallel arrays kept index-aligned.
# spawn_lens appends to all three; wait_all clears all three. Any future
# edit that inserts/removes elements must update all three in lockstep so
# wait_all can map PID -> lens id and elapsed runtime.
_REPOLENS_CHILD_PIDS=()
_REPOLENS_CHILD_LENS_IDS=()
_REPOLENS_CHILD_STARTED_AT=()
_REPOLENS_SEM_DIR=""
_REPOLENS_SEM_OWNER=""
_REPOLENS_MAX_PARALLEL=8
_REPOLENS_CLEANUP_IN_PROGRESS=0
_REPOLENS_CLEANUP_FORCE_KILL=0

_parallel_agent_abort_pending() {
  [[ -n "${LOG_BASE:-}" ]] || return 1
  [[ -f "$LOG_BASE/.rate-limit-abort" || -f "$LOG_BASE/.rate-limit-sleep-interrupt" \
    || -f "$LOG_BASE/.agent-no-progress-abort" || -f "$LOG_BASE/.systemic-failure-abort" ]]
}

# init_parallel <sem_dir> <max_parallel>
#   Creates semaphore directory, sets max parallel count.
#   Installs signal handlers for clean shutdown.
init_parallel() {
  local sem_dir="$1" max_parallel="${2:-8}"
  _REPOLENS_SEM_DIR="$sem_dir"
  _REPOLENS_SEM_OWNER="${RUN_ID:-manual}:$$"
  _REPOLENS_MAX_PARALLEL="$max_parallel"
  _REPOLENS_CLEANUP_IN_PROGRESS=0
  _REPOLENS_CLEANUP_FORCE_KILL=0
  _REPOLENS_CHILD_PIDS=()
  _REPOLENS_CHILD_LENS_IDS=()
  _REPOLENS_CHILD_STARTED_AT=()
  mkdir -p "$_REPOLENS_SEM_DIR"
  _sem_gc_stale
  trap 'REPOLENS_FINAL_STATE="interrupted"; REPOLENS_INTERRUPT_EXIT_CODE=130; _cleanup_children' INT
  trap 'REPOLENS_FINAL_STATE="interrupted"; REPOLENS_INTERRUPT_EXIT_CODE=143; _cleanup_children' TERM
}

# _sem_read_token <token_file> <pid_var> <owner_var>
#   Parse current owner/pid metadata and legacy PID-only token files.
_sem_read_token() {
  local token_file="$1" pid_var="$2" owner_var="$3"
  local line first_line parsed_pid="" parsed_owner=""

  if [[ ! -s "$token_file" ]]; then
    printf -v "$pid_var" '%s' ""
    printf -v "$owner_var" '%s' ""
    return 1
  fi

  IFS= read -r first_line < "$token_file" || first_line=""
  if [[ "$first_line" =~ ^[0-9]+$ ]]; then
    parsed_pid="$first_line"
  else
    while IFS= read -r line || [[ -n "$line" ]]; do
      case "$line" in
        pid=*) parsed_pid="${line#pid=}" ;;
        owner=*) parsed_owner="${line#owner=}" ;;
      esac
    done < "$token_file"
  fi

  printf -v "$pid_var" '%s' "$parsed_pid"
  printf -v "$owner_var" '%s' "$parsed_owner"
  [[ "$parsed_pid" =~ ^[0-9]+$ ]]
}

# _sem_gc_stale
#   Remove stale semaphore token files from a previous crashed run.
_sem_gc_stale() {
  local token pid owner

  [[ -n "$_REPOLENS_SEM_DIR" && -d "$_REPOLENS_SEM_DIR" ]] || return 0

  for token in "$_REPOLENS_SEM_DIR"/*.token; do
    [[ -e "$token" ]] || continue

    if ! _sem_read_token "$token" pid owner; then
      rm -f "$token"
      continue
    fi

    # PID liveness alone is vulnerable to reuse. New tokens carry the
    # init_parallel owner, so foreign owners are stale even if their PID
    # currently exists; legacy PID-only tokens fall back to kill -0.
    if [[ -n "$owner" && "$owner" != "$_REPOLENS_SEM_OWNER" ]]; then
      rm -f "$token"
      continue
    fi

    if ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$token"
    fi
  done
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
    _REPOLENS_CHILD_STARTED_AT=()
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
  _REPOLENS_CHILD_STARTED_AT=()
  _REPOLENS_CLEANUP_IN_PROGRESS=0
  _REPOLENS_CLEANUP_FORCE_KILL=0
  log_warn "Stopped ${total_children} children (${sigkill_count} SIGKILL'd)"
}

# sem_acquire
#   Block until fewer than max_parallel token files exist in sem_dir.
#   Uses polling with 2-second sleep.
sem_acquire() {
  local max_wait="${REPOLENS_CHILD_MAX_WAIT:-144000}"
  local heartbeat_interval="${REPOLENS_HEARTBEAT_INTERVAL:-60}"
  local next_heartbeat now

  if [[ ! "$max_wait" =~ ^[0-9]+$ ]]; then
    max_wait=144000
  else
    max_wait=$((10#$max_wait))
  fi

  if [[ ! "$heartbeat_interval" =~ ^[0-9]+$ ]]; then
    log_warn "Invalid REPOLENS_HEARTBEAT_INTERVAL='$heartbeat_interval'; using default 60s."
    heartbeat_interval=60
  else
    heartbeat_interval=$((10#$heartbeat_interval))
  fi

  now="$(date +%s)"
  next_heartbeat=$((now + heartbeat_interval))

  while true; do
    if _parallel_agent_abort_pending; then
      return 1
    fi

    local count
    count="$(find "$_REPOLENS_SEM_DIR" -maxdepth 1 -name '*.token' 2>/dev/null | wc -l)"
    if [[ "$count" -lt "$_REPOLENS_MAX_PARALLEL" ]]; then
      break
    fi
    _sem_gc_stale
    count="$(find "$_REPOLENS_SEM_DIR" -maxdepth 1 -name '*.token' 2>/dev/null | wc -l)"
    if [[ "$count" -lt "$_REPOLENS_MAX_PARALLEL" ]]; then
      break
    fi

    if (( heartbeat_interval > 0 )); then
      now="$(date +%s)"
      if (( now >= next_heartbeat )); then
        _repolens_emit_heartbeat "$now" "$max_wait" "[heartbeat]"
        next_heartbeat=$((now + heartbeat_interval))
      fi
    fi

    sleep 2
  done
}

# _sem_token_path <lens_id>
#   Return the semaphore token path for a lens id. Lens ids are user-visible
#   strings and may contain path separators when they include domain/lens.
_sem_token_path() {
  local lens_id="$1" token_id
  token_id="${lens_id//[![:alnum:]_.-]/_}"
  [[ -n "$token_id" ]] || token_id="lens"
  printf '%s/%s.token\n' "$_REPOLENS_SEM_DIR" "$token_id"
}

# sem_token_create <lens_id>
#   Write a token file for this lens with owner and holder PID metadata.
sem_token_create() {
  local lens_id="$1" token tmp

  token="$(_sem_token_path "$lens_id")"
  tmp="$(mktemp "$_REPOLENS_SEM_DIR/.${token##*/}.XXXXXX")" || return 1
  {
    printf 'owner=%s\n' "${_REPOLENS_SEM_OWNER:-manual:$$}"
    printf 'pid=%s\n' "$BASHPID"
  } > "$tmp" || {
    rm -f "$tmp"
    return 1
  }

  mv -f "$tmp" "$token" || {
    rm -f "$tmp"
    return 1
  }
}

# sem_token_remove <lens_id>
#   Remove the token file for this lens.
sem_token_remove() {
  rm -f "$(_sem_token_path "$1")"
}

_format_elapsed() {
  local elapsed="$1"

  if (( elapsed < 60 )); then
    printf '%ss' "$elapsed"
  elif (( elapsed < 3600 )); then
    printf '%dm%02ds' $((elapsed / 60)) $((elapsed % 60))
  else
    printf '%dh%02dm%02ds' $((elapsed / 3600)) $(((elapsed % 3600) / 60)) $((elapsed % 60))
  fi
}

_repolens_emit_heartbeat() {
  local now="$1" max_wait="$2" label="$3"
  local i pid lens_id started_at elapsed running near_deadline parts sep threshold

  running=0
  near_deadline=0
  parts=""
  sep=""
  threshold=$((max_wait * 80 / 100))

  for i in "${!_REPOLENS_CHILD_PIDS[@]}"; do
    pid="${_REPOLENS_CHILD_PIDS[$i]:-}"
    [[ -n "$pid" ]] || continue
    if kill -0 "$pid" 2>/dev/null; then
      lens_id="${_REPOLENS_CHILD_LENS_IDS[$i]:-<unknown>}"
      started_at="${_REPOLENS_CHILD_STARTED_AT[$i]:-$now}"
      if [[ ! "$started_at" =~ ^[0-9]+$ ]]; then
        started_at="$now"
      else
        started_at=$((10#$started_at))
      fi
      elapsed=$((now - started_at))
      (( elapsed < 0 )) && elapsed=0

      running=$((running + 1))
      parts="${parts}${sep}${lens_id} ($(_format_elapsed "$elapsed"))"
      sep=", "

      if (( max_wait > 0 && threshold > 0 && elapsed >= threshold )); then
        near_deadline=1
      fi
    fi
  done

  (( running > 1 )) || return 0

  if (( near_deadline == 1 )); then
    log_warn "${label} ${running} running: ${parts}"
  else
    log_info "${label} ${running} running: ${parts}"
  fi
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

  sem_acquire || return 1
  if _parallel_agent_abort_pending; then
    return 1
  fi
  sem_token_create "$lens_id"

  (
    sem_token_create "$lens_id"
    # EXIT trap fires on every bash-trappable exit path (clean return,
    # exit N, errexit, SIGTERM, SIGHUP, SIGINT) so the token is always
    # released. SIGKILL / OOM still leak a token, but its recorded child
    # PID lets startup-time GC remove it on resume.
    trap 'sem_token_remove "$lens_id"' EXIT
    "$callback" "$@"
  ) &

  _REPOLENS_CHILD_PIDS+=($!)
  _REPOLENS_CHILD_LENS_IDS+=("$lens_id")
  _REPOLENS_CHILD_STARTED_AT+=("$(date +%s)")
}

# wait_batch_complete <barrier_dir> [timeout_seconds]
#   Blocks until <barrier_dir>/.completed exists. Returns 0 on success,
#   1 on timeout. BATCH_WAIT_TIMEOUT defaults to 7200s; BATCH_POLL_INTERVAL
#   defaults to 5s.
wait_batch_complete() {
  local barrier_dir="${1:-}"
  local timeout_seconds="${2:-${BATCH_WAIT_TIMEOUT:-7200}}"
  local poll_interval="${BATCH_POLL_INTERVAL:-5}"
  local timeout_source="BATCH_WAIT_TIMEOUT"
  local raw_timeout raw_poll_interval barrier_file start now elapsed sleep_seconds remaining

  if [[ -z "$barrier_dir" ]]; then
    log_warn "wait_batch_complete requires a non-empty barrier_dir."
    return 1
  fi

  if (( $# >= 2 )); then
    timeout_source="timeout_seconds"
  fi

  raw_timeout="$timeout_seconds"
  if [[ ! "$timeout_seconds" =~ ^[0-9]+$ ]]; then
    log_warn "Invalid ${timeout_source}='$raw_timeout'; using default 7200s."
    timeout_seconds=7200
  else
    timeout_seconds=$((10#$timeout_seconds))
  fi

  raw_poll_interval="$poll_interval"
  if [[ ! "$poll_interval" =~ ^[0-9]+$ ]]; then
    log_warn "Invalid BATCH_POLL_INTERVAL='$raw_poll_interval'; using default 5s."
    poll_interval=5
  else
    poll_interval=$((10#$poll_interval))
    if (( poll_interval <= 0 )); then
      log_warn "Invalid BATCH_POLL_INTERVAL='$raw_poll_interval'; using default 5s."
      poll_interval=5
    fi
  fi

  barrier_file="$barrier_dir/.completed"
  start="$(date +%s)"
  log_info "Waiting for batch barrier: dir=$barrier_dir elapsed=0s timeout=${timeout_seconds}s poll=${poll_interval}s"

  while true; do
    now="$(date +%s)"
    elapsed=$((now - start))
    (( elapsed < 0 )) && elapsed=0

    if [[ -e "$barrier_file" ]]; then
      log_info "Batch barrier completed: dir=$barrier_dir elapsed=${elapsed}s"
      return 0
    fi

    if (( elapsed >= timeout_seconds )); then
      log_warn "Batch barrier timeout: dir=$barrier_dir elapsed=${elapsed}s timeout=${timeout_seconds}s"
      return 1
    fi

    sleep_seconds="$poll_interval"
    remaining=$((timeout_seconds - elapsed))
    if (( remaining < sleep_seconds )); then
      sleep_seconds="$remaining"
    fi
    (( sleep_seconds > 0 )) || sleep_seconds=1
    sleep "$sleep_seconds"
  done
}

# wait_all
#   Wait for all tracked children with a per-child deadline. Returns 0 if
#   all succeeded, 1 if any child failed or was killed by the deadline.
#
#   REPOLENS_CHILD_MAX_WAIT (env, seconds): hard ceiling per child.
#     Default: 144000 (40h). This is an outer backstop above the per-lens
#     REPOLENS_LENS_MAX_WALL budget. Keep it large enough for the configured
#     lens wall budget plus rate-limit sleep and non-agent I/O (gh queries,
#     file locks, etc.).
#
#   Bash 4.0-compatible: polls with `kill -0` + `sleep 1`, NOT `wait -t`
#   (bash 5.1+ only). If a child exceeds the deadline, it is sent SIGTERM,
#   given up to 10s to exit gracefully, then SIGKILL'd if still alive. The
#   stuck lens id is logged and rc=1 is returned, but the remaining
#   children are still processed — one stall must not block the rest.
wait_all() {
  local max_wait="${REPOLENS_CHILD_MAX_WAIT:-144000}"
  local heartbeat_interval="${REPOLENS_HEARTBEAT_INTERVAL:-60}"
  local rc=0
  local i pid lens_id started_at now elapsed grace remaining next_heartbeat

  if [[ ! "$max_wait" =~ ^[0-9]+$ ]]; then
    log_warn "Invalid REPOLENS_CHILD_MAX_WAIT='$max_wait'; using default 144000s."
    max_wait=144000
  else
    max_wait=$((10#$max_wait))
  fi

  if [[ ! "$heartbeat_interval" =~ ^[0-9]+$ ]]; then
    log_warn "Invalid REPOLENS_HEARTBEAT_INTERVAL='$heartbeat_interval'; using default 60s."
    heartbeat_interval=60
  else
    heartbeat_interval=$((10#$heartbeat_interval))
  fi

  now="$(date +%s)"
  next_heartbeat=$((now + heartbeat_interval))

  while true; do
    now="$(date +%s)"
    remaining=0

    for i in "${!_REPOLENS_CHILD_PIDS[@]}"; do
      pid="${_REPOLENS_CHILD_PIDS[$i]:-}"
      [[ -n "$pid" ]] || continue
      lens_id="${_REPOLENS_CHILD_LENS_IDS[$i]:-<unknown>}"
      started_at="${_REPOLENS_CHILD_STARTED_AT[$i]:-$now}"
      if [[ ! "$started_at" =~ ^[0-9]+$ ]]; then
        started_at="$now"
      else
        started_at=$((10#$started_at))
      fi
      elapsed=$((now - started_at))
      (( elapsed < 0 )) && elapsed=0

      if kill -0 "$pid" 2>/dev/null; then
        if (( elapsed >= max_wait )); then
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
          wait "$pid" 2>/dev/null || true
          _REPOLENS_CHILD_PIDS[i]=""
          _REPOLENS_CHILD_LENS_IDS[i]=""
          _REPOLENS_CHILD_STARTED_AT[i]=""
        else
          remaining=$((remaining + 1))
        fi
      else
        # Reap the child (non-blocking if it is already dead) and surface
        # its exit status. A non-zero exit here is a callback failure or
        # signal termination that happened outside the deadline path.
        if ! wait "$pid" 2>/dev/null; then
          rc=1
        fi
        _REPOLENS_CHILD_PIDS[i]=""
        _REPOLENS_CHILD_LENS_IDS[i]=""
        _REPOLENS_CHILD_STARTED_AT[i]=""
      fi
    done

    (( remaining == 0 )) && break

    if (( heartbeat_interval > 0 && now >= next_heartbeat )); then
      _repolens_emit_heartbeat "$now" "$max_wait" "[heartbeat]"
      next_heartbeat=$((now + heartbeat_interval))
    fi

    sleep 1
  done

  _REPOLENS_CHILD_PIDS=()
  _REPOLENS_CHILD_LENS_IDS=()
  _REPOLENS_CHILD_STARTED_AT=()
  return "$rc"
}
