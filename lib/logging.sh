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

# RepoLens — Structured logging
#
# Three log-hygiene features (issue #250):
#  1. Fork-free UTC timestamp via `printf -v ... '%(...T'` builtin.
#  2. Level filter via REPOLENS_LOG_LEVEL env var
#     (debug < info < warn < error < silent; default info).
#  3. Size-based rotation via REPOLENS_LOG_MAX_BYTES + REPOLENS_LOG_KEEP.
#     Only the process that called init_logging rotates; child processes
#     just append. This avoids races when parallel.sh forks workers.

# Global log file path (set by init_logging)
_REPOLENS_LOG_FILE=""

# PID of the process that called init_logging. Only this PID rotates so
# parallel workers that inherit the env don't race on mv/truncate.
_REPOLENS_LOG_PID=""

# Cache so the env var is parsed once per change. The hot path reads
# _REPOLENS_LOG_LEVEL_NUM directly — no subshell, no command substitution.
_REPOLENS_LOG_LEVEL_CACHE_KEY=""
_REPOLENS_LOG_LEVEL_NUM=1

# Recompute _REPOLENS_LOG_LEVEL_NUM if REPOLENS_LOG_LEVEL changed since
# the last call. Cheap when the env var is stable (string compare only).
_log_level_resolve() {
  local key="${REPOLENS_LOG_LEVEL:-info}"
  if [[ "$key" == "$_REPOLENS_LOG_LEVEL_CACHE_KEY" ]]; then
    return 0
  fi
  _REPOLENS_LOG_LEVEL_CACHE_KEY="$key"
  case "$key" in
    debug)  _REPOLENS_LOG_LEVEL_NUM=0 ;;
    info)   _REPOLENS_LOG_LEVEL_NUM=1 ;;
    warn)   _REPOLENS_LOG_LEVEL_NUM=2 ;;
    error)  _REPOLENS_LOG_LEVEL_NUM=3 ;;
    silent) _REPOLENS_LOG_LEVEL_NUM=4 ;;
    *)      _REPOLENS_LOG_LEVEL_NUM=1 ;;  # unknown -> info
  esac
}

# Helper: UTC ISO-8601 timestamp via bash 4.2+ builtin (zero forks).
# TZ=UTC0 forces UTC; without it `printf '%(...)T'` uses local time.
# Returns the timestamp via the named variable, eliminating the
# command-substitution subshell that the legacy $(_log_ts) pattern used.
_log_ts_var() {
  TZ=UTC0 printf -v "$1" '%(%Y-%m-%dT%H:%M:%SZ)T' -1
}

# Back-compat wrapper that still echoes a timestamp on stdout. Retained
# for any external caller; internal logging functions use _log_ts_var
# directly so the hot path stays fork-free.
_log_ts() {
  local ts
  _log_ts_var ts
  printf '%s\n' "$ts"
}

# Rotate the log file when it grows past REPOLENS_LOG_MAX_BYTES.
# Keep at most REPOLENS_LOG_KEEP numbered backups (.log.1, .log.2, ...).
# Only invoked by the init_logging owner PID; workers skip rotation.
_log_maybe_rotate() {
  [[ -n "$_REPOLENS_LOG_FILE" ]] || return 0
  [[ -f "$_REPOLENS_LOG_FILE" ]] || return 0
  [[ "$$" == "$_REPOLENS_LOG_PID" ]] || return 0

  local max_bytes="${REPOLENS_LOG_MAX_BYTES:-104857600}"  # 100 MiB
  # Treat non-numeric or zero as "rotation disabled".
  [[ "$max_bytes" =~ ^[0-9]+$ ]] || return 0
  (( max_bytes > 0 )) || return 0

  local size
  size="$(stat -c %s "$_REPOLENS_LOG_FILE" 2>/dev/null || stat -f %z "$_REPOLENS_LOG_FILE" 2>/dev/null || printf '0')"
  [[ "$size" =~ ^[0-9]+$ ]] || size=0
  (( size >= max_bytes )) || return 0

  local keep="${REPOLENS_LOG_KEEP:-5}"
  [[ "$keep" =~ ^[0-9]+$ ]] || keep=5
  (( keep >= 1 )) || keep=1

  local i
  # Drop the oldest beyond the keep limit.
  if [[ -f "${_REPOLENS_LOG_FILE}.${keep}" ]]; then
    rm -f -- "${_REPOLENS_LOG_FILE}.${keep}"
  fi
  # Shift .log.(keep-1) -> .log.keep, ..., .log.1 -> .log.2
  for (( i = keep - 1; i >= 1; i-- )); do
    if [[ -f "${_REPOLENS_LOG_FILE}.${i}" ]]; then
      mv -f -- "${_REPOLENS_LOG_FILE}.${i}" "${_REPOLENS_LOG_FILE}.$((i + 1))"
    fi
  done
  # Current log becomes .log.1; create a fresh empty current log.
  mv -f -- "$_REPOLENS_LOG_FILE" "${_REPOLENS_LOG_FILE}.1"
  : > "$_REPOLENS_LOG_FILE"
}

# Initialize logging. Creates log dir and sets the global log file path.
# Usage: init_logging <run_id> <base_log_dir>
init_logging() {
  local run_id="$1"
  local base_log_dir="$2"
  mkdir -p "$base_log_dir"
  _REPOLENS_LOG_FILE="${base_log_dir}/${run_id}.log"
  _REPOLENS_LOG_PID="$$"
  # Force a fresh level resolution next time we log.
  _REPOLENS_LOG_LEVEL_CACHE_KEY=""
}

# Log info message to stdout and log file.
log_info() {
  _log_level_resolve
  (( _REPOLENS_LOG_LEVEL_NUM <= 1 )) || return 0
  local ts; _log_ts_var ts
  local msg="[INFO] [$ts] $*"
  printf "%s\n" "$msg"
  if [[ -n "$_REPOLENS_LOG_FILE" ]]; then
    _log_maybe_rotate
    printf "%s\n" "$msg" >> "$_REPOLENS_LOG_FILE"
  fi
}

# Log warning message to stderr and log file.
log_warn() {
  _log_level_resolve
  (( _REPOLENS_LOG_LEVEL_NUM <= 2 )) || return 0
  local ts; _log_ts_var ts
  local msg="[WARN] [$ts] $*"
  printf "%s\n" "$msg" >&2
  if [[ -n "$_REPOLENS_LOG_FILE" ]]; then
    _log_maybe_rotate
    printf "%s\n" "$msg" >> "$_REPOLENS_LOG_FILE"
  fi
}

# Log error message to stderr and log file.
log_error() {
  _log_level_resolve
  (( _REPOLENS_LOG_LEVEL_NUM <= 3 )) || return 0
  local ts; _log_ts_var ts
  local msg="[ERROR] [$ts] $*"
  printf "%s\n" "$msg" >&2
  if [[ -n "$_REPOLENS_LOG_FILE" ]]; then
    _log_maybe_rotate
    printf "%s\n" "$msg" >> "$_REPOLENS_LOG_FILE"
  fi
}

# Append raw text to log file only (no stdout, no level gate).
# log_raw is never silenced by the level filter — the contract is
# "raw bytes in, raw bytes out" for agent stdout capture.
log_raw() {
  if [[ -n "$_REPOLENS_LOG_FILE" ]]; then
    _log_maybe_rotate
    printf "%s\n" "$*" >> "$_REPOLENS_LOG_FILE"
  fi
}
