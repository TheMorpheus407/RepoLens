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

# RepoLens — verifier dispatcher and manifest validator.
#
# Implements the post-rounds / pre-synthesizer accuracy gate from issue #168.
# Walks logs/<run-id>/rounds/round-*/lens-outputs/*.md, dispatches the active
# agent against prompts/_base/verifier.md, captures a JSON array from stdout,
# validates it, and atomically promotes it to
# logs/<run-id>/final/verification.json.
#
# This module is sourceable; it defines functions only and has no top-level
# side effects beyond loading shared helpers.

# _verify_repo_root
#   Resolves the repository root from this file's location. Used to locate
#   prompts/_base/verifier.md and to compute default LOG_BASE values when
#   the caller has not exported one.
_verify_repo_root() {
  local source_dir
  source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s' "$(cd "$source_dir/.." && pwd)"
}

# _verify_log_base <run_id>
#   Returns the run log base directory. Honors the global LOG_BASE when set
#   (so the orchestrator and tests can redirect output) and otherwise falls
#   back to <repo_root>/logs/<run_id>.
_verify_log_base() {
  local run_id="${1:-}"
  if [[ -n "${LOG_BASE:-}" ]]; then
    printf '%s' "$LOG_BASE"
    return 0
  fi
  printf '%s/logs/%s' "$(_verify_repo_root)" "$run_id"
}

# _verify_extract_json_array <text>
#   Reads a string and prints the first balanced top-level JSON array found in
#   the input. Strips Markdown code fences (```json … ```), then walks the
#   string keeping track of string and escape state to find the outermost
#   '[' … ']' pair. Returns 1 if no balanced array is found.
_verify_extract_json_array() {
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

# validate_verification_manifest <manifest_path>
#   Validates a verification manifest written to verification.json. Performs:
#     1. JSON parse and top-level-array shape check.
#     2. Per-entry schema check:
#        - finding_id: non-empty string
#        - status: one of VERIFIED | STALE | WRONG
#        - notes: non-empty string
#     3. finding_id uniqueness across the array.
#   Reports every failure to stderr. Returns 0 on success, non-zero on any
#   failure. Extra fields are accepted (forward compatibility).
validate_verification_manifest() {
  local manifest="${1:-}"
  if [[ -z "$manifest" ]]; then
    echo "validate_verification_manifest: missing manifest path" >&2
    return 2
  fi
  if [[ ! -f "$manifest" ]]; then
    echo "validate_verification_manifest: manifest not found: $manifest" >&2
    return 2
  fi

  if ! jq -e . "$manifest" >/dev/null 2>&1; then
    echo "validate_verification_manifest: not valid JSON: $manifest" >&2
    return 1
  fi

  if ! jq -e 'type == "array"' "$manifest" >/dev/null 2>&1; then
    echo "validate_verification_manifest: top-level value is not an array" >&2
    return 1
  fi

  local entry_count
  entry_count="$(jq 'length' "$manifest")" || return 1

  if (( entry_count == 0 )); then
    return 0
  fi

  local errors=0 schema_errors
  schema_errors="$(jq -r '
    def is_nonempty_string: type == "string" and length > 0;
    def statuses: ["VERIFIED","STALE","WRONG"];

    to_entries[] as $e
    | $e.key as $i
    | $e.value as $v
    | (
        if ($v | type) != "object" then "entry \($i): not an object" else empty end,
        if ($v.finding_id // "" | is_nonempty_string | not) then "entry \($i): missing or empty finding_id" else empty end,
        if (statuses | index($v.status // "")) == null then "entry \($i): invalid status \($v.status // null | tostring)" else empty end,
        if ($v.notes // "" | is_nonempty_string | not) then "entry \($i): missing or empty notes" else empty end
      )
  ' "$manifest" 2>/dev/null)"

  if [[ -n "$schema_errors" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      echo "validate_verification_manifest: schema error: $line" >&2
      errors=$((errors + 1))
    done <<< "$schema_errors"
  fi

  if (( errors > 0 )); then
    return 1
  fi

  local duplicates
  duplicates="$(jq -r '
    [.[].finding_id]
    | group_by(.)
    | map(select(length > 1))
    | map(.[0])
    | .[]
  ' "$manifest" 2>/dev/null)"

  if [[ -n "$duplicates" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      echo "validate_verification_manifest: duplicate finding_id: $line" >&2
      errors=$((errors + 1))
    done <<< "$duplicates"
  fi

  if (( errors > 0 )); then
    return 1
  fi
  return 0
}

# run_verifier <run_id>
#   Composes the verifier prompt, invokes the active agent exactly once,
#   captures the JSON array from stdout, validates it, and atomically promotes
#   it to logs/<run-id>/final/verification.json. If validation fails, the
#   candidate is discarded and no consumable verification.json remains: the
#   synthesizer then proceeds without verification filtering.
#
#   Required globals: AGENT, PROJECT_PATH.
#   Optional globals: REPO_OWNER, REPO_NAME, ROUNDS, LOG_BASE,
#                     AGENT_TIMEOUT_SECS, AGENT_KILL_GRACE_SECS.
#
#   Returns 0 on success (verification.json promoted or no findings to verify),
#   non-zero on dispatch / validation failure.
run_verifier() {
  local run_id="${1:-}"
  if [[ -z "$run_id" ]]; then
    echo "run_verifier: missing run_id" >&2
    return 2
  fi

  local repo_root run_log_base rounds_dir final_dir candidate prompt_text agent_output
  repo_root="$(_verify_repo_root)"
  run_log_base="$(_verify_log_base "$run_id")"
  rounds_dir="$run_log_base/rounds"
  final_dir="$run_log_base/final"

  local verifier_template="$repo_root/prompts/_base/verifier.md"
  if [[ ! -f "$verifier_template" ]]; then
    echo "run_verifier: verifier template missing: $verifier_template" >&2
    return 2
  fi

  local agent="${AGENT:-}"
  if [[ -z "$agent" ]]; then
    echo "run_verifier: AGENT is not set" >&2
    return 2
  fi
  local project_path="${PROJECT_PATH:-}"
  if [[ -z "$project_path" || ! -d "$project_path" ]]; then
    echo "run_verifier: PROJECT_PATH must be a directory: $project_path" >&2
    return 2
  fi

  mkdir -p "$final_dir" || {
    echo "run_verifier: cannot create final dir: $final_dir" >&2
    return 1
  }

  # Clear any stale verification.json from a previous run before invoking the
  # agent. This makes the "fatal validation leaves nothing consumable"
  # guarantee hold across every failure path. The synthesizer treats a missing
  # verification.json as "no verifier ran" and proceeds without filtering,
  # which is the safe fallback per the issue.
  rm -f "$final_dir/verification.json"

  local total_findings=0
  if [[ -d "$rounds_dir" ]]; then
    total_findings=$(find "$rounds_dir" -path '*/lens-outputs/*.md' -type f 2>/dev/null | wc -l | tr -d ' ')
  fi

  # Zero findings → no verifier work needed. Write an empty array as the
  # canonical sentinel so the synthesizer sees an explicit "verifier ran,
  # nothing to verify" rather than the "verifier did not run" state.
  if (( total_findings == 0 )); then
    candidate="$final_dir/verification.json.tmp.$$"
    if ! printf '[]\n' > "$candidate"; then
      echo "run_verifier: failed to write empty verification.json" >&2
      rm -f "$candidate"
      return 1
    fi
    if ! mv "$candidate" "$final_dir/verification.json"; then
      echo "run_verifier: failed to promote empty verification.json" >&2
      rm -f "$candidate"
      return 1
    fi
    return 0
  fi

  local total_rounds="${ROUNDS:-1}"
  local repo_owner="${REPO_OWNER:-}"
  local repo_name="${REPO_NAME:-}"

  if ! declare -F compose_prompt >/dev/null 2>&1; then
    echo "run_verifier: compose_prompt is not available (source lib/template.sh)" >&2
    return 2
  fi
  if ! declare -F run_agent >/dev/null 2>&1; then
    echo "run_verifier: run_agent is not available (source lib/core.sh)" >&2
    return 2
  fi

  local vars
  vars="RUN_ID=$run_id"
  vars+="|PROJECT_PATH=$project_path"
  vars+="|REPO_OWNER=$repo_owner"
  vars+="|REPO_NAME=$repo_name"
  vars+="|TOTAL_ROUNDS=$total_rounds"
  vars+="|TOTAL_FINDINGS=$total_findings"

  prompt_text="$(compose_prompt "$verifier_template" "$verifier_template" "$vars")" || {
    echo "run_verifier: prompt composition failed" >&2
    return 1
  }

  # Test/integration hook: allow callers to inject a synthetic agent response
  # via a callback function. Mirrors the _FILING_AGENT_CALLBACK pattern used
  # by lib/filing.sh and makes verifier tests possible without real agent
  # invocations (per CLAUDE.md::Tests, real models are forbidden in tests).
  if [[ -n "${_VERIFIER_AGENT_CALLBACK:-}" ]] && declare -F "${_VERIFIER_AGENT_CALLBACK}" >/dev/null 2>&1; then
    agent_output="$("${_VERIFIER_AGENT_CALLBACK}" "$run_id" "$prompt_text")" || {
      echo "run_verifier: verifier callback failed" >&2
      return 1
    }
  else
    agent_output="$(run_agent "$agent" "$prompt_text" "$project_path" "${AGENT_TIMEOUT_SECS:-600}" "${AGENT_KILL_GRACE_SECS:-30}")" || {
      echo "run_verifier: agent invocation failed" >&2
      return 1
    }
  fi

  local transcript_path="$final_dir/verifier-output.txt"
  printf '%s\n' "$agent_output" > "$transcript_path" 2>/dev/null || true

  local extracted
  extracted="$(_verify_extract_json_array "$agent_output")" || {
    echo "run_verifier: agent output did not contain a JSON array" >&2
    return 1
  }

  candidate="$final_dir/verification.json.tmp.$$"
  if ! printf '%s\n' "$extracted" > "$candidate"; then
    echo "run_verifier: failed to write candidate manifest" >&2
    rm -f "$candidate"
    return 1
  fi

  if ! validate_verification_manifest "$candidate"; then
    rm -f "$candidate"
    rm -f "$final_dir/verification.json"
    return 1
  fi

  if ! mv "$candidate" "$final_dir/verification.json"; then
    echo "run_verifier: failed to promote verification.json" >&2
    rm -f "$candidate"
    return 1
  fi

  return 0
}
