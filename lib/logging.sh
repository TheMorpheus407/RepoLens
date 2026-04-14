#!/usr/bin/env bash
# Copyright 2025 Bootstrap Academy
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
