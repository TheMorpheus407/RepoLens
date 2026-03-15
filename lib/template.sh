#!/usr/bin/env bash
# RepoLens — Prompt template engine

# Disable patsub_replacement (bash 5.2+) to prevent & in replacement strings
# from being treated as backreferences during ${param//pattern/replacement}
shopt -u patsub_replacement 2>/dev/null || true

# read_frontmatter <file> <key>
#   Extracts a value from YAML frontmatter (between --- markers).
#   Simple line-based: finds "key: value" and prints value.
read_frontmatter() {
  local file="$1" key="$2"
  sed -n '/^---$/,/^---$/p' "$file" | grep -E "^${key}:" | head -1 | sed "s/^${key}:[[:space:]]*//"
}

# read_body <file>
#   Returns everything AFTER the closing --- of frontmatter.
read_body() {
  local file="$1"
  awk 'BEGIN{n=0} /^---$/{n++; next} n>=2{print}' "$file"
}

# compose_prompt <base_template> <lens_file> <variables_string>
#   1. Reads the base template
#   2. Reads the lens body
#   3. Substitutes {{LENS_BODY}} in base template with lens body
#   4. Substitutes all other {{VARIABLE}} placeholders using an associative array
#   Variables string format: "KEY1=VALUE1|KEY2=VALUE2|..."
compose_prompt() {
  local base_file="$1" lens_file="$2" vars_string="$3"
  local base_content lens_body prompt key value

  base_content="$(cat "$base_file")"
  lens_body="$(read_body "$lens_file")"

  # Insert lens body
  prompt="${base_content//\{\{LENS_BODY\}\}/$lens_body}"

  # Substitute variables from pipe-delimited string
  IFS='|' read -ra pairs <<< "$vars_string"
  for pair in "${pairs[@]}"; do
    key="${pair%%=*}"
    value="${pair#*=}"
    prompt="${prompt//\{\{$key\}\}/$value}"
  done

  printf "%s" "$prompt"
}
