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

# Bash 4-compatible client for the descriptor-owning cgroup supervisor.
set -uo pipefail
_REPOLENS_SCOPE_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/process_scope.py"
_REPOLENS_SCOPE_READY=0
_REPOLENS_SCOPE_FAILED=0
_REPOLENS_SCOPE_RUNTIMES=()
_REPOLENS_SCOPE_NONCES=()
_REPOLENS_SCOPE_SERVERS=()
_REPOLENS_SCOPE_BATCH_RESULTS=()

# Resolve before run state or lens dispatch; only this pre-run boundary may
# choose sequential execution. A failure after launch always stops new spawns.
parallel_preflight() {
  local backend="${REPOLENS_PROCESS_SCOPE:-auto}"
  local fallback="${REPOLENS_PARALLEL_FALLBACK:-error}" reason
  case "$backend" in auto|linux-cgroup-v2) ;; *)
    log_warn "Invalid REPOLENS_PROCESS_SCOPE='$backend' (expected auto or linux-cgroup-v2)."
    return 1 ;;
  esac
  case "$fallback" in error|sequential) ;; *)
    log_warn "Invalid REPOLENS_PARALLEL_FALLBACK='$fallback' (expected error or sequential)."
    return 1 ;;
  esac
  if (( _REPOLENS_SCOPE_READY == 1 )); then return 0; fi
  if [[ "$(uname -s)" == Linux ]] && command -v python3 >/dev/null 2>&1; then
    if reason="$(python3 "$_REPOLENS_SCOPE_HELPER" probe 2>&1)"; then
      _REPOLENS_SCOPE_READY=1
      REPOLENS_PROCESS_SCOPE_RESOLVED=linux-cgroup-v2
      export REPOLENS_PROCESS_SCOPE_RESOLVED
      return 0
    fi
  else
    reason="Linux cgroup v2 and Python 3.9+ with pidfds are required; no macOS backend is enabled."
  fi
  if [[ "$backend" == auto && "$fallback" == sequential ]]; then
    REPOLENS_PROCESS_SCOPE_RESOLVED=sequential-fallback
    export PARALLEL=false
    export MAX_PARALLEL=1
    export REPOLENS_PROCESS_SCOPE_RESOLVED
    log_warn "PARALLEL DISABLED: explicit sequential fallback selected. $reason"
    return 0
  fi
  log_warn "Parallel execution refused before callback launch: $reason"
  log_warn "Use a delegated Linux cgroup v2 scope, or explicitly select REPOLENS_PARALLEL_FALLBACK=sequential with the auto backend."
  return 1
}

# Allocate only unused descriptors without Bash 4.1's {var} redirection.
# eval receives generated decimal digits and a quoted variable reference.
_scope_open_fd() {
  # shellcheck disable=SC2034 # path is expanded by the controlled eval below.
  local output_var="$1" path="$2" direction="$3" candidate=10
  while [[ -e "/proc/$BASHPID/fd/$candidate" ]]; do
    candidate=$((candidate + 1))
    (( candidate < 256 )) || return 1
  done
  case "$direction" in
    write) eval "exec ${candidate}>\"\${path}\"" || return 1 ;;
    fifo) eval "exec ${candidate}<>\"\${path}\"" || return 1 ;;
    *) return 1 ;;
  esac
  printf -v "$output_var" '%s' "$candidate"
}

_scope_call() {
  local index="$1"; shift
  python3 "$_REPOLENS_SCOPE_HELPER" call "${_REPOLENS_SCOPE_RUNTIMES[$index]}" \
    "${_REPOLENS_SCOPE_NONCES[$index]}" "$@"
}

_scope_terminal_failure() {
  local index="$1"
  _REPOLENS_SCOPE_FAILED=1
  log_warn "[${_REPOLENS_CHILD_LENS_IDS[$index]:-launch}] terminal-cleanup failure; stopping new spawns. Diagnostics retained at ${_REPOLENS_SCOPE_RUNTIMES[$index]}. No numeric PID/PGID cleanup is permitted."
}

_scope_destroy() {
  local index="$1"
  if ! _scope_call "$index" destroy >/dev/null; then
    _scope_terminal_failure "$index"
    return 1
  fi
  wait "${_REPOLENS_SCOPE_SERVERS[$index]}" 2>/dev/null || true
  rm -rf -- "${_REPOLENS_SCOPE_RUNTIMES[$index]}"
  _REPOLENS_SCOPE_RUNTIMES[index]=""
  _REPOLENS_SCOPE_NONCES[index]=""
  _REPOLENS_SCOPE_SERVERS[index]=""
}

# Start every grace period together. The parent waits on request clients with
# interruptible Bash builtins; a second signal writes nonce force flags.
_scope_terminate_batch() {
  local grace="$1"; shift
  local index request rc result failed=0
  local requests=()
  _REPOLENS_SCOPE_BATCH_RESULTS=()
  for index in "$@"; do
    _scope_call "$index" terminate "$grace" > "${_REPOLENS_SCOPE_RUNTIMES[$index]}/terminate.result" &
    requests[index]=$!
  done
  for index in "$@"; do
    request="${requests[$index]}"
    while true; do
      wait "$request"; rc=$?
      if (( rc >= 128 )) && kill -0 "$request" 2>/dev/null; then continue; fi
      break
    done
    _REPOLENS_SCOPE_BATCH_RESULTS[index]="$rc"
    if (( rc != 0 )); then
      _scope_terminal_failure "$index"
      failed=1
      continue
    fi
    IFS= read -r result < "${_REPOLENS_SCOPE_RUNTIMES[$index]}/terminate.result" || result=""
    if [[ "$result" == killed ]]; then
      log_warn "[${_REPOLENS_CHILD_LENS_IDS[$index]}] scope required SIGKILL escalation"
      _REPOLENS_SCOPE_KILLED=$((_REPOLENS_SCOPE_KILLED + 1))
    fi
  done
  return "$failed"
}

_scope_terminate() {
  _scope_terminate_batch "$2" "$1"
}

# Collect each *scope*, even when the direct callback has already exited.
# The callback PID is used only to retrieve Bash's child exit status.
_parallel_poll_once() {
  local i pid state now elapsed started_at lens_id failed=0
  local expired=() completed=()
  local max_wait="${REPOLENS_CHILD_MAX_WAIT:-144000}"
  [[ "$max_wait" =~ ^[0-9]+$ ]] || max_wait=144000
  max_wait=$((10#$max_wait))
  now="$(date +%s)"
  _REPOLENS_SCOPE_REMAINING=0
  for i in "${!_REPOLENS_CHILD_PIDS[@]}"; do
    pid="${_REPOLENS_CHILD_PIDS[$i]:-}"
    [[ -n "$pid" ]] || continue
    lens_id="${_REPOLENS_CHILD_LENS_IDS[$i]}"
    if ! state="$(_scope_call "$i" state)"; then
      _scope_terminal_failure "$i"
      failed=1
      continue
    fi
    started_at="${_REPOLENS_CHILD_STARTED_AT[$i]}"
    [[ "$started_at" =~ ^[0-9]+$ ]] || started_at="$now"
    elapsed=$((now - 10#$started_at))
    if [[ "$state" != empty ]]; then
      if (( elapsed >= max_wait )); then
        log_warn "[$lens_id] exceeded REPOLENS_CHILD_MAX_WAIT=${max_wait}s; terminating owned process scope"
        _REPOLENS_WAIT_RC=1
        expired+=("$i")
      elif [[ "$state" == orphaned ]]; then
        log_warn "[$lens_id] callback exited with live descendants; draining owned process scope"
        _REPOLENS_WAIT_RC=1
        expired+=("$i")
      else
        _REPOLENS_SCOPE_REMAINING=$((_REPOLENS_SCOPE_REMAINING + 1))
        continue
      fi
    fi
    completed+=("$i")
  done
  if (( ${#expired[@]} > 0 )); then
    _scope_terminate_batch 10 "${expired[@]}" || failed=1
  fi
  for i in "${completed[@]:-}"; do
    [[ -n "$i" ]] || continue
    [[ "${_REPOLENS_SCOPE_BATCH_RESULTS[$i]:-0}" == 0 ]] || continue
    pid="${_REPOLENS_CHILD_PIDS[$i]}"
    lens_id="${_REPOLENS_CHILD_LENS_IDS[$i]}"
    # Kernel-confirmed empty: no member can still own an output descriptor.
    wait "$pid" 2>/dev/null || _REPOLENS_WAIT_RC=1
    _scope_destroy "$i" || { failed=1; continue; }
    sem_token_remove "$lens_id"
    _REPOLENS_CHILD_PIDS[i]=""
    _REPOLENS_CHILD_LENS_IDS[i]=""
    _REPOLENS_CHILD_STARTED_AT[i]=""
  done
  return "$failed"
}
