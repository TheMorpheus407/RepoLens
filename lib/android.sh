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

# RepoLens — Android artifact discovery

_android_file_mtime() {
  local file_path="$1"
  local mtime

  if mtime="$(stat -c '%Y' "$file_path" 2>/dev/null)"; then
    printf '%s\n' "$mtime"
    return 0
  fi

  if mtime="$(stat -f '%m' "$file_path" 2>/dev/null)"; then
    printf '%s\n' "$mtime"
    return 0
  fi

  return 1
}

_android_newest_apk() {
  local search_root="$1"
  local apk_path
  local apk_mtime
  local newest_path=""
  local newest_mtime=""

  [[ -d "$search_root" ]] || return 1

  while IFS= read -r -d '' apk_path; do
    apk_mtime="$(_android_file_mtime "$apk_path")" || continue

    if [[ -z "$newest_path" ]] ||
      (( apk_mtime > newest_mtime )) ||
      { (( apk_mtime == newest_mtime )) && [[ "$apk_path" < "$newest_path" ]]; }; then
      newest_path="$apk_path"
      newest_mtime="$apk_mtime"
    fi
  done < <(find "$search_root" -type f -name '*.apk' -print0 2>/dev/null)

  [[ -n "$newest_path" ]] || return 1
  printf '%s\n' "$newest_path"
}

_android_log_display_path() {
  printf '%s' "$1" | LC_ALL=C tr '\000-\037\177' '?'
}

# discover_android_apk <project_path>
#   Prints the newest discovered APK path. Returns 1 quietly when none exists.
discover_android_apk() {
  local project_path="${1:-}"
  local standard_apk_root
  local apk_path=""

  [[ -n "$project_path" ]] || return 1
  project_path="$(cd "$project_path" 2>/dev/null && pwd)" || return 1

  standard_apk_root="${project_path}/app/build/outputs/apk"
  apk_path="$(_android_newest_apk "$standard_apk_root")" || true

  if [[ -z "$apk_path" ]]; then
    apk_path="$(_android_newest_apk "$project_path")" || true
  fi

  [[ -n "$apk_path" ]] || return 1

  if declare -F log_info >/dev/null 2>&1; then
    log_info "Discovered Android APK: $(_android_log_display_path "$apk_path")" >&2
  fi
  printf '%s\n' "$apk_path"
}
