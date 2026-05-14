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

# RepoLens - bounded file locking helpers

with_file_lock() {
  local lock_path="$1" timeout_seconds="$2"
  local fd rc
  shift 2

  [[ -n "$lock_path" && -n "$timeout_seconds" ]] || return 1
  [[ "$timeout_seconds" =~ ^[0-9]+$ ]] || timeout_seconds=30

  { exec {fd}>>"$lock_path"; } 2>/dev/null || return 1
  flock -w "$timeout_seconds" "$fd" || {
    rc=$?
    exec {fd}>&-
    return "$rc"
  }

  "$@"
  rc=$?

  flock -u "$fd" 2>/dev/null || true
  exec {fd}>&-
  return "$rc"
}
