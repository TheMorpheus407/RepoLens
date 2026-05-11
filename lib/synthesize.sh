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

# RepoLens — synthesizer dispatcher and manifest validator.
#
# This module is sourceable; it defines functions only and has no top-level
# side effects beyond loading shared helpers.

# _synthesize_repo_root
#   Resolves the repository root from this file's location. Used to locate
#   prompts/_base/synthesize.md and to compute default LOG_BASE values when
#   the caller has not exported one.
_synthesize_repo_root() {
  local source_dir
  source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s' "$(cd "$source_dir/.." && pwd)"
}

# _synthesize_log_base <run_id>
#   Returns the run log base directory. Honors the global LOG_BASE when set
#   (so the orchestrator and tests can redirect output) and otherwise falls
#   back to <repo_root>/logs/<run_id>.
_synthesize_log_base() {
  local run_id="${1:-}"
  if [[ -n "${LOG_BASE:-}" ]]; then
    printf '%s' "$LOG_BASE"
    return 0
  fi
  printf '%s/logs/%s' "$(_synthesize_repo_root)" "$run_id"
}

# _synthesize_extract_json_array <text>
#   Reads stdin and prints the first balanced top-level JSON array found in
#   the input. Strips Markdown code fences (```json … ```), then walks the
#   string keeping track of string and escape state to find the outermost
#   '[' … ']' pair. Returns 1 if no balanced array is found.
_synthesize_extract_json_array() {
  local input="$1" stripped="" line
  while IFS= read -r line; do
    case "$line" in
      '```'*|'~~~'*) continue ;;
    esac
    stripped+="$line"$'\n'
  done <<< "$input"

  local len="${#stripped}" i=0 ch start=-1 depth=0 in_string=0 escaped=0
  for (( i = 0; i < len; i++ )); do
    ch="${stripped:i:1}"
    if (( in_string )); then
      if (( escaped )); then
        escaped=0
      elif [[ "$ch" == "\\" ]]; then
        escaped=1
      elif [[ "$ch" == '"' ]]; then
        in_string=0
      fi
      continue
    fi

    case "$ch" in
      '"') in_string=1 ;;
      '[')
        if (( depth == 0 )); then
          start=$i
        fi
        depth=$((depth + 1))
        ;;
      ']')
        depth=$((depth - 1))
        if (( depth == 0 && start >= 0 )); then
          printf '%s' "${stripped:start:i - start + 1}"
          return 0
        fi
        ;;
    esac
  done
  return 1
}

# _synthesize_normalize_title <title>
#   Lowercases the title, strips an optional leading "[severity]" prefix,
#   collapses non-alphanumeric runs to single spaces, and trims.
_synthesize_normalize_title() {
  local title="${1:-}"
  title="${title,,}"
  if [[ "$title" =~ ^\[[a-z]+\][[:space:]]*(.*)$ ]]; then
    title="${BASH_REMATCH[1]}"
  fi
  local out="" ch i len="${#title}"
  for (( i = 0; i < len; i++ )); do
    ch="${title:i:1}"
    case "$ch" in
      [a-z0-9]) out+="$ch" ;;
      *) out+=' ' ;;
    esac
  done
  out="${out## }"
  out="${out%% }"
  while [[ "$out" == *"  "* ]]; do
    out="${out//  / }"
  done
  printf '%s' "$out"
}

# _synthesize_title_ngrams <normalized_title>
#   Emits one n-gram per line. Uses trigrams when the title has at least
#   three tokens, bigrams for two tokens, and unigrams for one. Returns
#   nothing for empty input.
_synthesize_title_ngrams() {
  local normalized="${1:-}"
  [[ -n "$normalized" ]] || return 0
  local -a tokens=()
  read -ra tokens <<< "$normalized"
  local n="${#tokens[@]}" i
  if (( n >= 3 )); then
    for (( i = 0; i + 2 < n; i++ )); do
      printf '%s %s %s\n' "${tokens[i]}" "${tokens[i+1]}" "${tokens[i+2]}"
    done
  elif (( n == 2 )); then
    printf '%s %s\n' "${tokens[0]}" "${tokens[1]}"
  elif (( n == 1 )); then
    printf '%s\n' "${tokens[0]}"
  fi
}

# _synthesize_jaccard_x10000 <ngrams_a> <ngrams_b>
#   Computes Jaccard similarity scaled to 10000. The two arguments are
#   newline-separated n-gram lists. Returns 0 when both lists are empty.
_synthesize_jaccard_x10000() {
  local a="$1" b="$2"
  local -A set_a=() set_b=()
  local line union=0 intersection=0
  if [[ -n "$a" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      set_a["$line"]=1
    done <<< "$a"
  fi
  if [[ -n "$b" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      set_b["$line"]=1
    done <<< "$b"
  fi
  for line in "${!set_a[@]}"; do
    union=$((union + 1))
    if [[ -n "${set_b[$line]:-}" ]]; then
      intersection=$((intersection + 1))
    fi
  done
  for line in "${!set_b[@]}"; do
    [[ -n "${set_a[$line]:-}" ]] && continue
    union=$((union + 1))
  done
  if (( union == 0 )); then
    printf '0'
    return 0
  fi
  printf '%d' $(( intersection * 10000 / union ))
}

# validate_manifest <manifest_path>
#   Validates a synthesizer manifest. Performs:
#     1. JSON parse and top-level-array shape check.
#     2. Per-entry schema check on required S1 fields.
#     3. Pairwise Jaccard title-similarity check (> 0.85 threshold).
#   Reports every failure to stderr. Returns 0 on success, non-zero on any
#   failure. Extra fields are accepted (forward compatibility).
validate_manifest() {
  local manifest="${1:-}"
  if [[ -z "$manifest" ]]; then
    echo "validate_manifest: missing manifest path" >&2
    return 2
  fi
  if [[ ! -f "$manifest" ]]; then
    echo "validate_manifest: manifest not found: $manifest" >&2
    return 2
  fi

  if ! jq -e . "$manifest" >/dev/null 2>&1; then
    echo "validate_manifest: not valid JSON: $manifest" >&2
    return 1
  fi

  if ! jq -e 'type == "array"' "$manifest" >/dev/null 2>&1; then
    echo "validate_manifest: top-level value is not an array" >&2
    return 1
  fi

  local errors=0 entry_count
  entry_count="$(jq 'length' "$manifest")" || return 1

  if (( entry_count == 0 )); then
    return 0
  fi

  local schema_errors
  schema_errors="$(jq -r '
    def is_nonempty_string: type == "string" and length > 0;
    def severities: ["critical","high","medium","low"];
    def granularities: ["independent","cluster"];
    def cross_link_types: ["comment","reopen-suggestion"];
    def verification_statuses: ["verified","stale","wrong","unknown"];

    to_entries[] as $e
    | $e.key as $i
    | $e.value as $v
    | (
        if ($v | type) != "object" then "entry \($i): not an object" else empty end,
        if ($v.title // "" | is_nonempty_string | not) then "entry \($i): missing or empty title" else empty end,
        if ($v.body // "" | is_nonempty_string | not) then "entry \($i): missing or empty body" else empty end,
        if ($v.cluster_id // "" | is_nonempty_string | not) then "entry \($i): missing or empty cluster_id" else empty end,
        if ($v.root_cause_category // "" | is_nonempty_string | not) then "entry \($i): missing or empty root_cause_category" else empty end,
        if ($v.domain // "" | is_nonempty_string | not) then "entry \($i): missing or empty domain" else empty end,
        if ($v.lens // "" | is_nonempty_string | not) then "entry \($i): missing or empty lens" else empty end,
        if (severities | index($v.severity // "")) == null then "entry \($i): invalid severity \($v.severity // null | tostring)" else empty end,
        if (granularities | index($v.granularity // "")) == null then "entry \($i): invalid granularity \($v.granularity // null | tostring)" else empty end,
        if ($v | has("verification_status")) and (verification_statuses | index($v.verification_status // "")) == null then "entry \($i): invalid verification_status \($v.verification_status // null | tostring)" else empty end,
        if ($v.source_finding_paths | type) != "array" then "entry \($i): source_finding_paths must be an array"
          elif ($v.source_finding_paths | length) == 0 then "entry \($i): source_finding_paths must be non-empty"
          elif ([ $v.source_finding_paths[] | is_nonempty_string ] | all | not) then "entry \($i): source_finding_paths entries must be non-empty strings"
          else empty end,
        if ($v.dedup_against_existing | type) != "array" then "entry \($i): dedup_against_existing must be an array"
          else (
            $v.dedup_against_existing | to_entries[] as $de
            | (
                if ($de.value | type) != "object" then "entry \($i).dedup_against_existing[\($de.key)]: not an object"
                  elif ($de.value.issue_number | type) != "number" then "entry \($i).dedup_against_existing[\($de.key)]: issue_number must be a number"
                  elif ($de.value.reason // "" | is_nonempty_string | not) then "entry \($i).dedup_against_existing[\($de.key)]: reason must be non-empty"
                  else empty end
              )
          ) end,
        if ($v.proposed_labels | type) != "array" then "entry \($i): proposed_labels must be an array"
          elif ([ $v.proposed_labels[]? | is_nonempty_string ] | all | not) then "entry \($i): proposed_labels entries must be non-empty strings"
          else empty end,
        if ($v.cross_link_actions | type) != "array" then "entry \($i): cross_link_actions must be an array"
          else (
            $v.cross_link_actions | to_entries[] as $ca
            | (
                if ($ca.value | type) != "object" then "entry \($i).cross_link_actions[\($ca.key)]: not an object"
                  elif (cross_link_types | index($ca.value.type // "")) == null then "entry \($i).cross_link_actions[\($ca.key)]: invalid type \($ca.value.type // null | tostring)"
                  elif ($ca.value.issue_number | type) != "number" then "entry \($i).cross_link_actions[\($ca.key)]: issue_number must be a number"
                  elif ($ca.value.body // "" | is_nonempty_string | not) then "entry \($i).cross_link_actions[\($ca.key)]: body must be non-empty"
                  else empty end
              )
          ) end
      )
  ' "$manifest" 2>/dev/null)"

  if [[ -n "$schema_errors" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      echo "validate_manifest: schema error: $line" >&2
      errors=$((errors + 1))
    done <<< "$schema_errors"
  fi

  if (( errors > 0 )); then
    return 1
  fi

  local -a titles=()
  local title
  while IFS= read -r title; do
    titles+=("$title")
  done < <(jq -r '.[].title // ""' "$manifest")

  local n="${#titles[@]}" i j sim normalized
  local -a normalized_titles=() ngram_lists=()
  for (( i = 0; i < n; i++ )); do
    normalized="$(_synthesize_normalize_title "${titles[i]}")"
    normalized_titles+=("$normalized")
    ngram_lists+=("$(_synthesize_title_ngrams "$normalized")")
  done

  for (( i = 0; i < n; i++ )); do
    for (( j = i + 1; j < n; j++ )); do
      if [[ -z "${normalized_titles[i]}" && -z "${normalized_titles[j]}" ]]; then
        continue
      fi
      sim="$(_synthesize_jaccard_x10000 "${ngram_lists[i]}" "${ngram_lists[j]}")"
      if (( sim > 8500 )); then
        echo "validate_manifest: near-duplicate titles (similarity ${sim}/10000):" >&2
        echo "  [${i}] ${titles[i]}" >&2
        echo "  [${j}] ${titles[j]}" >&2
        errors=$((errors + 1))
      fi
    done
  done

  if (( errors > 0 )); then
    return 1
  fi
  return 0
}

# run_synthesizer <run_id>
#   Composes the synthesizer prompt, invokes the active agent exactly once,
#   captures the JSON manifest from stdout, validates it, and atomically
#   promotes it to logs/<run-id>/final/manifest.json. If validation fails,
#   the candidate is discarded and no consumable manifest.json remains.
#
#   Required globals: AGENT, PROJECT_PATH.
#   Optional globals: REPO_OWNER, REPO_NAME, FORGE_REPO, ROUNDS,
#                     GRANULARITY_HINT, LOG_BASE.
run_synthesizer() {
  local run_id="${1:-}"
  if [[ -z "$run_id" ]]; then
    echo "run_synthesizer: missing run_id" >&2
    return 2
  fi

  local repo_root run_log_base rounds_dir final_dir candidate prompt_text agent_output
  repo_root="$(_synthesize_repo_root)"
  run_log_base="$(_synthesize_log_base "$run_id")"
  rounds_dir="$run_log_base/rounds"
  final_dir="$run_log_base/final"

  local synthesize_template="$repo_root/prompts/_base/synthesize.md"
  if [[ ! -f "$synthesize_template" ]]; then
    echo "run_synthesizer: synthesizer template missing: $synthesize_template" >&2
    return 2
  fi

  local agent="${AGENT:-}"
  if [[ -z "$agent" ]]; then
    echo "run_synthesizer: AGENT is not set" >&2
    return 2
  fi
  local project_path="${PROJECT_PATH:-}"
  if [[ -z "$project_path" || ! -d "$project_path" ]]; then
    echo "run_synthesizer: PROJECT_PATH must be a directory: $project_path" >&2
    return 2
  fi

  mkdir -p "$final_dir" || {
    echo "run_synthesizer: cannot create final dir: $final_dir" >&2
    return 1
  }

  # Clear any stale manifest from a previous run before invoking the agent.
  # This makes the "fatal validation leaves nothing consumable" guarantee
  # hold across every failure path, not just post-validation failures.
  rm -f "$final_dir/manifest.json"

  local total_findings=0
  if [[ -d "$rounds_dir" ]]; then
    total_findings=$(find "$rounds_dir" -path '*/lens-outputs/*.md' -type f 2>/dev/null | wc -l | tr -d ' ')
  fi

  local total_rounds="${ROUNDS:-1}"
  local granularity_hint="${GRANULARITY_HINT:-auto}"
  local repo_owner="${REPO_OWNER:-}"
  local repo_name="${REPO_NAME:-}"
  local forge_repo="${FORGE_REPO:-}"
  if [[ -z "$forge_repo" && -n "$repo_owner" && -n "$repo_name" ]]; then
    forge_repo="$repo_owner/$repo_name"
  fi

  local forge_issue_list_open=""
  if declare -F forge_prompt_issue_list >/dev/null 2>&1; then
    forge_issue_list_open="$(forge_prompt_issue_list "open" "$forge_repo" "$project_path")"
  else
    forge_issue_list_open="Use the active forge CLI to list open issues"
  fi

  local vars
  vars="RUN_ID=$run_id"
  vars+="|PROJECT_PATH=$project_path"
  vars+="|REPO_OWNER=$repo_owner"
  vars+="|REPO_NAME=$repo_name"
  vars+="|TOTAL_ROUNDS=$total_rounds"
  vars+="|TOTAL_FINDINGS=$total_findings"
  vars+="|GRANULARITY_HINT=$granularity_hint"
  vars+="|FORGE_ISSUE_LIST_OPEN=$forge_issue_list_open"

  if ! declare -F compose_prompt >/dev/null 2>&1; then
    echo "run_synthesizer: compose_prompt is not available (source lib/template.sh)" >&2
    return 2
  fi
  if ! declare -F run_agent >/dev/null 2>&1; then
    echo "run_synthesizer: run_agent is not available (source lib/core.sh)" >&2
    return 2
  fi

  prompt_text="$(compose_prompt "$synthesize_template" "$synthesize_template" "$vars")" || {
    echo "run_synthesizer: prompt composition failed" >&2
    return 1
  }

  agent_output="$(run_agent "$agent" "$prompt_text" "$project_path")" || {
    echo "run_synthesizer: agent invocation failed" >&2
    return 1
  }

  local extracted
  extracted="$(_synthesize_extract_json_array "$agent_output")" || {
    echo "run_synthesizer: agent output did not contain a JSON array" >&2
    return 1
  }

  candidate="$final_dir/manifest.json.tmp.$$"
  if ! printf '%s\n' "$extracted" > "$candidate"; then
    echo "run_synthesizer: failed to write candidate manifest" >&2
    rm -f "$candidate"
    return 1
  fi

  if ! validate_manifest "$candidate"; then
    rm -f "$candidate"
    rm -f "$final_dir/manifest.json"
    return 1
  fi

  if ! mv "$candidate" "$final_dir/manifest.json"; then
    echo "run_synthesizer: failed to promote manifest" >&2
    rm -f "$candidate"
    return 1
  fi

  return 0
}
