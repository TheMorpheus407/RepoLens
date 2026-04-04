#!/usr/bin/env bash
# RepoLens — DONE streak detection

# Strip non-alphanumeric (keep _), uppercase.
normalize_word() {
  local word="${1:-}"
  printf "%s" "$word" | tr -cd '[:alnum:]_' | tr '[:lower:]' '[:upper:]'
}

# Extract first word from file. Returns "" if file empty/missing.
first_word() {
  local file="$1"
  [[ -s "$file" ]] || { echo ""; return 0; }
  awk '{for (i = 1; i <= NF; i++) { print $i; exit }}' "$file"
}

# Extract last word from file. Returns "" if file empty/missing.
last_word() {
  local file="$1"
  [[ -s "$file" ]] || { echo ""; return 0; }
  awk '{for (i = 1; i <= NF; i++) { last = $i }} END { print last }' "$file"
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
