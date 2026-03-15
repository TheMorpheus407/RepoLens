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
