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

# RepoLens — DONE streak detection

# Strip ANSI escape sequences from stdin.
# Uses a bash variable for the ESC byte instead of \x1b hex escapes in sed,
# because BSD sed (macOS) does not support \x1b — only GNU sed does.
strip_ansi() {
  local esc=$'\x1b'
  sed -E "s/${esc}\[[0-9;]*[a-zA-Z]//g; s/${esc}\([0-9;]*[a-zA-Z]//g; s/${esc}\]8;[^\\\\]*\\\\//g"
}

# Strip non-alphanumeric (keep _), uppercase.
normalize_word() {
  local word="${1:-}"
  printf "%s" "$word" | tr -cd '[:alnum:]_' | tr '[:lower:]' '[:upper:]'
}

# Extract first word from file. Returns "" if file empty/missing.
# Strips ANSI escape codes before extraction so colored agent output is handled.
first_word() {
  local file="$1"
  [[ -s "$file" ]] || { echo ""; return 0; }
  strip_ansi < "$file" | awk 'NF {for (i = 1; i <= NF; i++) { print $i; exit }}'
}

# Extract last word from file. Returns "" if file empty/missing.
# Strips ANSI escape codes before extraction so colored agent output is handled.
last_word() {
  local file="$1"
  [[ -s "$file" ]] || { echo ""; return 0; }
  strip_ansi < "$file" | awk '{for (i = 1; i <= NF; i++) { last = $i }} END { if (last) print last }'
}

# Returns 0 if first OR last normalized word is "DONE", 1 otherwise.
check_done() {
  local file="$1"
  local first_norm last_norm
  first_norm="$(normalize_word "$(first_word "$file")")"
  last_norm="$(normalize_word "$(last_word "$file")")"
  [[ "$first_norm" == "DONE" || "$last_norm" == "DONE" ]]
}

# count_issues_in_output <file>
#   Counts GitHub issue URLs in agent output (printed by `gh issue create` on success).
#   Best-effort fallback — agents may not echo the full URL. Prefer count_repo_issues.
#   Returns count on stdout.
count_issues_in_output() {
  local file="$1"
  [[ -s "$file" ]] || { echo 0; return 0; }
  grep -oE 'https://github\.com/[^/]+/[^/]+/issues/[0-9]+' "$file" 2>/dev/null | wc -l
}

# count_repo_issues <repo> <label>
#   Deterministically counts open issues in a repo with a given label via gh API.
#   Returns count on stdout. Returns 0 on any failure (no remote, no auth, etc).
count_repo_issues() {
  local repo="$1" label="$2"
  gh issue list -R "$repo" --label "$label" --state open --limit 1000 --json number 2>/dev/null \
    | jq 'length' 2>/dev/null || echo 0
}

# count_dry_run_issues <dir>
#   Counts .md files in a directory (maxdepth 1, no subdirectories).
#   Returns count on stdout. Returns 0 if directory is empty or missing.
count_dry_run_issues() {
  local dir="$1"
  [[ -d "$dir" ]] || { echo 0; return 0; }
  find "$dir" -maxdepth 1 -name '*.md' -type f 2>/dev/null | wc -l
}
