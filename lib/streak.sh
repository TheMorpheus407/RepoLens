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
#   Prints count on stdout and returns 0 on success.
#   On failure (gh unreachable, auth/rate-limit, malformed JSON, gh missing),
#   prints nothing to stdout, emits a log_warn diagnostic, and returns 1.
#   Callers MUST check the exit status — do not merge "unknown" with "zero".
count_repo_issues() {
  local repo="$1" label="$2"
  local gh_err gh_out gh_rc
  gh_err="$(mktemp 2>/dev/null)" || gh_err=""
  if [[ -n "$gh_err" ]]; then
    gh_out="$(gh issue list -R "$repo" --label "$label" --state open \
      --limit 1000 --json number 2>"$gh_err")"
    gh_rc=$?
  else
    gh_out="$(gh issue list -R "$repo" --label "$label" --state open \
      --limit 1000 --json number 2>/dev/null)"
    gh_rc=$?
  fi
  if [[ "$gh_rc" -ne 0 ]]; then
    local first_err=""
    if [[ -n "$gh_err" && -s "$gh_err" ]]; then
      first_err="$(head -n1 "$gh_err" 2>/dev/null || true)"
    fi
    [[ -n "$gh_err" ]] && rm -f "$gh_err"
    _streak_warn "count_repo_issues: gh failed for repo=$repo label=$label rc=$gh_rc err=${first_err:-<empty>}"
    return 1
  fi
  [[ -n "$gh_err" ]] && rm -f "$gh_err"
  local n
  if ! n="$(printf '%s' "$gh_out" | jq 'length' 2>/dev/null)"; then
    _streak_warn "count_repo_issues: jq failed to parse gh output for repo=$repo label=$label"
    return 1
  fi
  if ! [[ "$n" =~ ^[0-9]+$ ]]; then
    _streak_warn "count_repo_issues: unexpected non-integer from jq for repo=$repo label=$label: '$n'"
    return 1
  fi
  printf '%s\n' "$n"
  return 0
}

# Internal: delegates to log_warn when logging.sh is sourced, otherwise
# falls back to writing a plain diagnostic to stderr so streak.sh remains
# usable in isolation (e.g. from unit tests that don't source logging.sh).
_streak_warn() {
  if declare -F log_warn >/dev/null 2>&1; then
    log_warn "$*"
  else
    printf '[WARN] %s\n' "$*" >&2
  fi
}

# count_dry_run_issues <dir>
#   Counts .md files in a directory (maxdepth 1, no subdirectories).
#   Returns count on stdout. Returns 0 if directory is empty or missing.
count_dry_run_issues() {
  local dir="$1"
  [[ -d "$dir" ]] || { echo 0; return 0; }
  find "$dir" -maxdepth 1 -name '*.md' -type f 2>/dev/null | wc -l
}

# Rate-limit / quota / auth-failure signatures emitted by agent CLIs
# (claude, codex, spark, opencode). Case-insensitive ERE patterns.
# Extend this list when new agent error strings surface. False positives
# matter less than false negatives here — a false abort costs one run;
# a false negative costs a night of wasted iterations.
_REPOLENS_RATE_LIMIT_PATTERNS=(
  "you('|\xe2\x80\x99)?ve hit your usage limit"
  "usage limit"
  "rate[- ]?limit(ed|ing|s)?"
  "try again (at|in)"
  "quota exceeded"
  "401 unauthorized"
  "403 forbidden"
)

# detect_agent_rate_limit <output_file>
#   Returns 0 if any known rate-limit / quota / auth-failure signature is
#   found in the file, 1 otherwise. Matching is case-insensitive and
#   applied to ANSI-stripped output (so colored terminal output still
#   matches).
#
#   On match, prints "PATTERN|SNIPPET" to stdout where PATTERN is the
#   signature that matched and SNIPPET is the first 200 characters of
#   the matching line. Callers can split on the first "|" to extract
#   both fields for logging.
#
#   Intentionally avoids matching the orchestrator's own `gh` 401 errors
#   because `run_agent`'s stdout/stderr is captured separately — only the
#   agent subprocess writes to <output_file>.
detect_agent_rate_limit() {
  local file="$1"
  [[ -s "$file" ]] || return 1

  local stripped pat line
  stripped="$(strip_ansi < "$file" 2>/dev/null)"
  [[ -n "$stripped" ]] || return 1

  for pat in "${_REPOLENS_RATE_LIMIT_PATTERNS[@]}"; do
    line="$(printf '%s\n' "$stripped" | grep -iE -m1 "$pat" 2>/dev/null || true)"
    if [[ -n "$line" ]]; then
      # Trim leading whitespace for a cleaner snippet
      line="${line#"${line%%[![:space:]]*}"}"
      printf '%s|%s\n' "$pat" "${line:0:200}"
      return 0
    fi
  done
  return 1
}
