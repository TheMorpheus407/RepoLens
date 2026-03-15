#!/usr/bin/env bash
# RepoLens — Structured logging

# Global log file path (set by init_logging)
_REPOLENS_LOG_FILE=""

# Helper: UTC ISO-8601 timestamp
_log_ts() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# Initialize logging. Creates log dir and sets the global log file path.
# Usage: init_logging <run_id> <base_log_dir>
init_logging() {
  local run_id="$1"
  local base_log_dir="$2"
  mkdir -p "$base_log_dir"
  _REPOLENS_LOG_FILE="${base_log_dir}/${run_id}.log"
}

# Log info message to stdout and log file.
log_info() {
  local msg="[INFO] [$(_log_ts)] $*"
  printf "%s\n" "$msg"
  [[ -n "$_REPOLENS_LOG_FILE" ]] && printf "%s\n" "$msg" >> "$_REPOLENS_LOG_FILE"
}

# Log warning message to stderr and log file.
log_warn() {
  local msg="[WARN] [$(_log_ts)] $*"
  printf "%s\n" "$msg" >&2
  [[ -n "$_REPOLENS_LOG_FILE" ]] && printf "%s\n" "$msg" >> "$_REPOLENS_LOG_FILE"
}

# Log error message to stderr and log file.
log_error() {
  local msg="[ERROR] [$(_log_ts)] $*"
  printf "%s\n" "$msg" >&2
  [[ -n "$_REPOLENS_LOG_FILE" ]] && printf "%s\n" "$msg" >> "$_REPOLENS_LOG_FILE"
}

# Append raw text to log file only (no stdout).
log_raw() {
  [[ -n "$_REPOLENS_LOG_FILE" ]] && printf "%s\n" "$*" >> "$_REPOLENS_LOG_FILE"
}
