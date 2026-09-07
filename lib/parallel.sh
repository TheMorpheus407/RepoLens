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

# shellcheck source=lib/process_scope.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/process_scope.sh"

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

# detect_nproc
#   Prints the host CPU core count as a base-10 positive integer. Resolution
#   order, set -u-safe at every step (a non-numeric value falls through):
#     1. REPOLENS_NPROC env override — deterministic pin for tests, parsed
#        before the clamp so suites can assert floor/mid/cap behavior.
#     2. nproc(1) when available.
#     3. getconf _NPROCESSORS_ONLN — minimal containers without nproc(1).
#     4. last-resort floor of 8.
#   Pure: no side effects beyond reading REPOLENS_NPROC and shelling out to
#   nproc/getconf. Output is always a clean base-10 integer.
detect_nproc() {
  local n="${REPOLENS_NPROC:-}"
  if [[ "$n" =~ ^[0-9]+$ ]]; then
    printf '%d\n' "$((10#$n))"
    return 0
  fi
  n=""
  if command -v nproc >/dev/null 2>&1; then
    n="$(nproc 2>/dev/null || true)"
  fi
  [[ "$n" =~ ^[0-9]+$ ]] || n="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
  [[ "$n" =~ ^[0-9]+$ ]] || n=8
  printf '%d\n' "$((10#$n))"
}

# repolens_auto_max_parallel <detected_cores>
#   Pure clamp of a detected core count into the auto-default concurrency band:
#     clamp(cores, FLOOR=8, CAP=32)
#   FLOOR=8 equals today's static default, so small/CI hosts never regress;
#   CAP=32 bounds host-RAM blow-up and provider rate-limit exposure. Empty,
#   zero, and non-numeric inputs collapse to the floor. Parsed base-10 so a
#   zero-padded value ("08") is not read as octal.
repolens_auto_max_parallel() {
  local cores="${1:-}" floor=8 cap=32 n
  [[ "$cores" =~ ^[0-9]+$ ]] || cores=0
  n=$((10#$cores))
  (( n < floor )) && n=$floor
  (( n > cap )) && n=$cap
  printf '%d\n' "$n"
}

_parallel_agent_abort_pending() {
  [[ -n "${LOG_BASE:-}" ]] || return 1
  [[ -f "$LOG_BASE/.rate-limit-abort" || -f "$LOG_BASE/.rate-limit-sleep-interrupt" \
    || -f "$LOG_BASE/.agent-no-progress-abort" || -f "$LOG_BASE/.systemic-failure-abort" ]]
}

# init_parallel <sem_dir> <max_parallel>
#   Creates semaphore directory, sets max parallel count.
#   Installs signal handlers for clean shutdown.
init_parallel() {
  local sem_dir="$1" max_parallel="${2:-8}" tracked
  for tracked in "${_REPOLENS_CHILD_PIDS[@]:-}"; do
    [[ -z "$tracked" ]] || { log_warn "Cannot reinitialize parallel state with owned scopes still tracked."; return 1; }
  done
  parallel_preflight || { _REPOLENS_SCOPE_FAILED=1; return 1; }
  (( _REPOLENS_SCOPE_READY == 1 )) || return 1
  (( _REPOLENS_SCOPE_FAILED == 0 )) || return 1
  _REPOLENS_SCOPE_KILLED=0
  _REPOLENS_WAIT_RC=0
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
  local token pid owner i owned

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

    # Wrapper exit cannot free capacity while its scope remains tracked.
    owned=0
    for i in "${!_REPOLENS_CHILD_PIDS[@]}"; do
      if [[ "${_REPOLENS_CHILD_PIDS[$i]:-}" == "$pid" && -n "${_REPOLENS_SCOPE_RUNTIMES[$i]:-}" ]]; then
        owned=1
        break
      fi
    done
    if (( owned == 0 )) && ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$token"
    fi
  done
}

# _cleanup_children
#   Kill all tracked child processes with bounded TERM-to-KILL cleanup.
_cleanup_children() {
  local i grace="${REPOLENS_CLEANUP_GRACE:-5}" count=0 result=0
  local active=()
  if (( _REPOLENS_CLEANUP_IN_PROGRESS == 1 )); then
    # Do not re-enter an in-flight request or signal numeric identities.
    _REPOLENS_CLEANUP_FORCE_KILL=1
    for i in "${!_REPOLENS_SCOPE_RUNTIMES[@]}"; do
      [[ -d "${_REPOLENS_SCOPE_RUNTIMES[$i]:-}" ]] || continue
      printf '%s\n' "${_REPOLENS_SCOPE_NONCES[$i]}" > "${_REPOLENS_SCOPE_RUNTIMES[$i]}/force-kill"
    done
    log_warn "Cleanup already in progress; forcing owned scopes to SIGKILL."
    return 0
  fi
  _REPOLENS_CLEANUP_IN_PROGRESS=1
  if [[ ! "$grace" =~ ^[0-9]+$ ]]; then
    log_warn "Invalid REPOLENS_CLEANUP_GRACE='$grace'; using default 5s."
    grace=5
  fi
  grace=$((10#$grace))
  _REPOLENS_SCOPE_KILLED=0
  for i in "${!_REPOLENS_CHILD_PIDS[@]}"; do
    [[ -n "${_REPOLENS_CHILD_PIDS[$i]:-}" ]] || continue
    active+=("$i")
    count=$((count + 1))
  done
  if (( count > 0 )); then
    _scope_terminate_batch "$grace" "${active[@]}" || result=1
  fi
  for i in "${active[@]:-}"; do
    [[ -n "$i" ]] || continue
    if [[ "${_REPOLENS_SCOPE_BATCH_RESULTS[$i]:-1}" == 0 ]]; then
      wait "${_REPOLENS_CHILD_PIDS[$i]}" 2>/dev/null || true
      if _scope_destroy "$i"; then
        sem_token_remove "${_REPOLENS_CHILD_LENS_IDS[$i]}"
        _REPOLENS_CHILD_PIDS[i]=""
        _REPOLENS_CHILD_LENS_IDS[i]=""
        _REPOLENS_CHILD_STARTED_AT[i]=""
      else
        result=1
      fi
    else
      result=1
    fi
  done
  if (( result == 0 )); then
    _REPOLENS_CHILD_PIDS=()
    _REPOLENS_CHILD_LENS_IDS=()
    _REPOLENS_CHILD_STARTED_AT=()
  fi
  _REPOLENS_CLEANUP_IN_PROGRESS=0
  log_warn "Stopped $count children (${_REPOLENS_SCOPE_KILLED} SIGKILL'd)"
  return "$result"
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
    (( _REPOLENS_SCOPE_FAILED == 0 )) || return 1
    _parallel_poll_once || return 1
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
    printf 'pid=%s\n' "${2:-$BASHPID}"
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
  local lens_id="$1" callback="$2"
  shift 2
  local index runtime nonce server ready child gate deadline enrollment_path enrollment_fd ready_fd go_fd
  local scope_owner="$BASHPID"
  (( _REPOLENS_SCOPE_READY == 1 && _REPOLENS_SCOPE_FAILED == 0 )) || {
    log_warn "Parallel callback refused: process-scope capability was not established."
    return 1
  }
  sem_acquire || return 1
  _parallel_agent_abort_pending && return 1
  runtime="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/repolens-scope.XXXXXXXX")" || return 1
  nonce="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
  mkfifo -m 600 "$runtime/ready" "$runtime/go" || return 1
  python3 "$_REPOLENS_SCOPE_HELPER" serve "$runtime" "$nonce" "$scope_owner" \
    >"$runtime/supervisor.log" 2>&1 &
  server=$!
  index=${#_REPOLENS_CHILD_PIDS[@]}
  _REPOLENS_SCOPE_RUNTIMES[index]="$runtime"
  _REPOLENS_SCOPE_NONCES[index]="$nonce"
  _REPOLENS_SCOPE_SERVERS[index]="$server"
  deadline=$((SECONDS + 5))
  while [[ ! -e "$runtime/server.ready" ]]; do
    if (( SECONDS >= deadline )) || ! kill -0 "$server" 2>/dev/null; then
      _scope_terminal_failure "$index"
      return 1
    fi
    sleep 0.02
  done
  enrollment_path="$(_scope_call "$index" enrollment-file)" || { _scope_terminal_failure "$index"; return 1; }
  _scope_open_fd enrollment_fd "$enrollment_path" write || { _scope_terminal_failure "$index"; return 1; }
  if ! _scope_call "$index" verify-enrollment-file "$BASHPID" "$enrollment_fd" >/dev/null; then
    eval "exec ${enrollment_fd}>&-"
    _scope_terminal_failure "$index"
    return 1
  fi
  # FIFO O_RDWR avoids an unbounded open. Spare descriptors preserve every
  # existing caller descriptor in both parent and callback.
  if ! _scope_open_fd ready_fd "$runtime/ready" fifo; then
    eval "exec ${enrollment_fd}>&-"
    _scope_terminal_failure "$index"
    return 1
  fi
  if ! _scope_open_fd go_fd "$runtime/go" fifo; then
    eval "exec ${enrollment_fd}>&- ${ready_fd}>&-"
    _scope_terminal_failure "$index"
    return 1
  fi
  (
    printf '%s %s\n' "$nonce" "$BASHPID" >&"$ready_fd"
    IFS= read -r -t 5 gate <&"$go_fd" || exit 125
    [[ "$gate" == "$nonce ENROLL" ]] || exit 125
    # Kernel self-enrollment cannot migrate a reused numeric PID.
    builtin printf '0' >&"$enrollment_fd" || exit 125
    eval "exec ${enrollment_fd}>&-"
    builtin printf '%s %s ENROLLED\n' "$nonce" "$BASHPID" >&"$ready_fd"
    IFS= read -r -t 5 gate <&"$go_fd" || exit 125
    [[ "$gate" == "$nonce GO" ]] || exit 125
    eval "exec ${ready_fd}>&- ${go_fd}>&-"
    "$callback" ${1+"$@"}
  ) &
  child=$!
  eval "exec ${enrollment_fd}>&-"
  _REPOLENS_CHILD_PIDS[index]="$child"
  _REPOLENS_CHILD_LENS_IDS[index]="$lens_id"
  _REPOLENS_CHILD_STARTED_AT[index]="$(date +%s)"
  sem_token_create "$lens_id" "$child" || { eval "exec ${ready_fd}>&- ${go_fd}>&-"; _scope_terminal_failure "$index"; return 1; }
  # The parent and child each retain independent copies of the FIFO FDs.
  if ! (
    IFS= read -r -t 5 ready <&"$ready_fd" || exit 1
    [[ "$ready" == "$nonce $child" ]] || exit 1
    builtin printf '%s ENROLL\n' "$nonce" >&"$go_fd"
    IFS= read -r -t 5 ready <&"$ready_fd" || exit 1
    [[ "$ready" == "$nonce $child ENROLLED" ]] || exit 1
    _scope_call "$index" enroll "$child" >/dev/null || exit 1
    printf '%s GO\n' "$nonce" >&"$go_fd"
  ); then
    eval "exec ${ready_fd}>&- ${go_fd}>&-"
    # No callback has been released. The bounded gate self-exits without signals.
    _scope_terminal_failure "$index"
    _scope_terminate "$index" 0 || return 1
    deadline=$((SECONDS + 6))
    while kill -0 "$child" 2>/dev/null && (( SECONDS < deadline )); do sleep 0.02; done
    if kill -0 "$child" 2>/dev/null; then return 1; fi
    wait "$child" 2>/dev/null || true
    _scope_destroy "$index" || return 1
    _REPOLENS_CHILD_PIDS[index]=""
    return 1
  fi
  eval "exec ${ready_fd}>&- ${go_fd}>&-"
  return 0
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

# wait_all: an outer per-scope deadline; GNU timeout agent semantics are unchanged.
wait_all() {
  local max_wait="${REPOLENS_CHILD_MAX_WAIT:-144000}"
  local heartbeat_interval="${REPOLENS_HEARTBEAT_INTERVAL:-60}" next_heartbeat now
  if [[ ! "$max_wait" =~ ^[0-9]+$ ]]; then
    log_warn "Invalid REPOLENS_CHILD_MAX_WAIT='$max_wait'; using default 144000s."
    max_wait=144000
  else
    max_wait=$((10#$max_wait))
  fi
  if [[ ! "$heartbeat_interval" =~ ^[0-9]+$ ]]; then
    log_warn "Invalid REPOLENS_HEARTBEAT_INTERVAL='$heartbeat_interval'; using default 60s."
    heartbeat_interval=60
  fi
  heartbeat_interval=$((10#$heartbeat_interval))
  next_heartbeat=$(( $(date +%s) + heartbeat_interval ))
  while true; do
    _parallel_poll_once || return 1
    (( _REPOLENS_SCOPE_REMAINING == 0 )) && break
    now="$(date +%s)"
    if (( heartbeat_interval > 0 && now >= next_heartbeat )); then
      _repolens_emit_heartbeat "$now" "$max_wait" "[heartbeat]"
      next_heartbeat=$((now + heartbeat_interval))
    fi
    sleep 1
  done
  _REPOLENS_CHILD_PIDS=()
  _REPOLENS_CHILD_LENS_IDS=()
  _REPOLENS_CHILD_STARTED_AT=()
  (( _REPOLENS_SCOPE_FAILED == 0 )) || return 1
  return "${_REPOLENS_WAIT_RC:-0}"
}
