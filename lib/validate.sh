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

# RepoLens — post-audit finding validator (issue #379).
#
# Implements the decoupled "Radar → Filter" workflow: a cheap model produces a
# findings artifact, then a separate `repolens --validate <file> --agent <flagship>`
# pass re-reads the cited code with a flagship model and drops the cheap model's
# false positives — WITHOUT re-running the expensive DONE×3 lens loop.
#
# This is the standalone sibling of the in-run verifier (lib/verify.sh, issue
# #168): it reuses that module's verdict shape (VERIFIED / STALE / WRONG),
# balanced-array extractor (`_verify_extract_json_array`), and manifest schema
# validator (`validate_verification_manifest`), but ingests a *pre-existing*
# external artifact instead of the run's own rounds/ layout, and dispatches the
# agent named on *this* command line (the flagship "Filter") rather than the
# audit agent that produced the findings.
#
# This module is sourceable; it defines functions only and has no top-level
# side effects beyond depending on shared helpers (run_agent from lib/core.sh,
# the logging helpers, and the verify.sh helpers named above).

# _validate_repo_root
#   Resolves the repository root from this file's location so the validator can
#   locate prompts/_base/validator.md and the default logs/ base independent of
#   the caller's cwd.
_validate_repo_root() {
  local source_dir
  source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s' "$(cd "$source_dir/.." && pwd)"
}

# _validate_count_nonblank_lines <file>
#   Prints the number of non-blank lines in the file (0 for an empty or
#   whitespace-only file). Used to detect the "nothing to validate" no-op before
#   any JSON parsing or agent dispatch.
_validate_count_nonblank_lines() {
  local file="$1" n
  n="$(grep -cvE '^[[:space:]]*$' "$file" 2>/dev/null)"
  printf '%s' "${n:-0}"
}

# _validate_ingest_findings <file>
#   Reads a findings artifact and prints a compact JSON array of finding objects
#   on stdout. Accepts either:
#     - a whole-file JSON array (manifest.json style), or
#     - JSON Lines (findings.jsonl registry style — one JSON object per line), or
#     - a single whole-file JSON object (treated as a one-element array).
#   Returns non-zero (printing nothing) when the input is not parseable JSON, so
#   the caller can reject malformed input loudly without dispatching the agent.
_validate_ingest_findings() {
  local file="$1" arr=""

  # Whole-file JSON array (manifest style) takes precedence.
  if arr="$(jq -ce 'if type == "array" then . else empty end' "$file" 2>/dev/null)" \
     && [[ -n "$arr" ]]; then
    printf '%s' "$arr"
    return 0
  fi

  # Otherwise slurp the input as a stream of JSON values (JSON Lines, or a
  # single object) into an array. jq -s fails loudly on malformed JSON.
  if arr="$(jq -cse '.' "$file" 2>/dev/null)" && [[ -n "$arr" ]]; then
    printf '%s' "$arr"
    return 0
  fi

  return 1
}

# _validate_normalize_findings <findings_array_json>
#   Reads a JSON array of raw findings on stdin and prints a JSON array where
#   each element is augmented with a stable `_validate_fid` join key derived
#   from the finding's own id (`id` / `finding_id` / `cluster_id`, falling back
#   to a positional id). The join key is what the flagship echoes back and what
#   the survivor filter matches on, so it must be computed identically here and
#   in the prompt projection.
_validate_normalize_findings() {
  jq -c '
    [ to_entries[]
      | .key as $idx
      | .value as $f
      | ($f + { _validate_fid:
          (($f.id // $f.finding_id // $f.cluster_id // ("finding-" + ($idx | tostring))) | tostring) })
    ]'
}

# _validate_project_repo_slug <project_path>
#   Best-effort owner/name derivation for the prompt header. Falls back to an
#   empty owner and the directory basename when there is no git remote. Purely
#   cosmetic — never fails the validation run.
_validate_project_repo_slug() {
  local project="$1" url owner="" name
  name="$(basename "$project")"
  url="$(git -C "$project" config --get remote.origin.url 2>/dev/null || true)"
  if [[ "$url" =~ [:/]([^/:]+)/([^/]+)$ ]]; then
    owner="${BASH_REMATCH[1]}"
    name="${BASH_REMATCH[2]%.git}"
  fi
  printf '%s\t%s' "$owner" "$name"
}

# run_validate_command
#   Post-audit validation entry point. Ingests an existing findings artifact,
#   re-verifies each finding with the flagship AGENT, drops the false positives,
#   writes a cleaned findings file, and reports honest verified/dropped counts.
#
#   Required globals: VALIDATE_INPUT (the findings file), AGENT (the flagship),
#                     PROJECT_PATH (the repo re-read for context).
#   Optional globals: SCRIPT_DIR, MODE, AGENT_TIMEOUT_SECS, AGENT_KILL_GRACE_SECS.
#
#   Returns 0 on a completed validation (including the graceful empty-input
#   no-op), non-zero on any error: missing/unreadable/malformed input, a missing
#   validator prompt, an agent dispatch failure, or an unusable agent response.
#   Never swallows an agent failure into a clean "everything was a false
#   positive" result.
run_validate_command() {
  local input="${VALIDATE_INPUT:-}"
  local agent="${AGENT:-}"
  local project="${PROJECT_PATH:-}"

  if [[ -z "$input" ]]; then
    log_error "--validate requires a findings file argument."
    return 1
  fi
  if [[ -z "$agent" ]]; then
    log_error "--validate requires --agent <flagship> (the model that filters the findings)."
    return 1
  fi
  if [[ -z "$project" || ! -d "$project" ]]; then
    log_error "--validate requires --project <path> pointing at the repository to re-read for context: $project"
    return 1
  fi

  # --- Input existence / readability: reject loudly, never dispatch a typo. ---
  if [[ ! -e "$input" ]]; then
    log_error "Input findings file not found: $input"
    return 1
  fi
  if [[ ! -f "$input" || ! -r "$input" ]]; then
    log_error "Input findings file is not a readable file: $input"
    return 1
  fi

  # --- Empty artifact: graceful no-op, no flagship dispatch. ---
  local nonblank
  nonblank="$(_validate_count_nonblank_lines "$input")"
  if (( nonblank == 0 )); then
    log_info "Nothing to validate: 0 findings in $input."
    return 0
  fi

  # --- Parse: malformed JSON is rejected without dispatching the agent. ---
  local findings_json
  if ! findings_json="$(_validate_ingest_findings "$input")"; then
    log_error "Cannot parse findings input as JSON (expected a JSON array or JSON Lines): $input"
    return 1
  fi

  local finding_count
  finding_count="$(printf '%s' "$findings_json" | jq 'length' 2>/dev/null)"
  finding_count="${finding_count:-0}"
  if (( finding_count == 0 )); then
    log_info "Nothing to validate: 0 findings in $input."
    return 0
  fi

  # --- Locate the validator prompt. ---
  local repo_root
  repo_root="${SCRIPT_DIR:-$(_validate_repo_root)}"
  local validator_template="$repo_root/prompts/_base/validator.md"
  if [[ ! -f "$validator_template" ]]; then
    log_error "Validator prompt missing: $validator_template"
    return 1
  fi

  if ! declare -F run_agent >/dev/null 2>&1; then
    log_error "run_validate_command: run_agent is not available (source lib/core.sh)."
    return 1
  fi

  # --- Set up an output/log directory under logs/ (runtime-only, gitignored). ---
  local run_id run_log_base
  run_id="validate-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  run_log_base="$repo_root/logs/$run_id"
  if ! mkdir -p "$run_log_base"; then
    log_error "Cannot create validation output directory: $run_log_base"
    return 1
  fi
  if declare -F init_logging >/dev/null 2>&1; then
    init_logging "$run_id" "$run_log_base"
  fi

  # --- Augment findings with the stable join key and project a thin,
  #     agent-facing view (id + claim + citation + any evidence body). ---
  local aug prompt_findings
  aug="$(printf '%s' "$findings_json" | _validate_normalize_findings)"
  if [[ -z "$aug" ]]; then
    log_error "Failed to normalize findings for validation: $input"
    return 1
  fi
  prompt_findings="$(printf '%s' "$aug" | jq '
    [ .[] | {
        finding_id: ._validate_fid,
        title: ((.title // "") | tostring),
        severity: ((.severity // "") | tostring),
        domain: ((.domain // "") | tostring),
        lens: ((.lens // "") | tostring),
        primary_location: ((.primary_location // .location // "") | tostring),
        context: ((.body // .evidence // .markdown_path // "") | tostring)
      } ]')"

  # --- Compose the flagship prompt. The findings are UNTRUSTED cheap-model
  #     output; the template tells the flagship to treat them as inert data. ---
  local repo_slug repo_owner repo_name
  repo_slug="$(_validate_project_repo_slug "$project")"
  repo_owner="${repo_slug%%$'\t'*}"
  repo_name="${repo_slug#*$'\t'}"

  local template_body prompt_text
  template_body="$(cat "$validator_template")"
  prompt_text="${template_body//\{\{PROJECT_PATH\}\}/$project}"
  prompt_text="${prompt_text//\{\{REPO_OWNER\}\}/$repo_owner}"
  prompt_text="${prompt_text//\{\{REPO_NAME\}\}/$repo_name}"
  prompt_text="${prompt_text//\{\{FINDING_COUNT\}\}/$finding_count}"
  prompt_text="${prompt_text//\{\{FINDINGS_JSON\}\}/$prompt_findings}"

  log_info "Validating $finding_count finding(s) from $input with flagship agent '$agent'..."

  # --- Dispatch the flagship exactly once over all findings. ---
  local transcript="$run_log_base/validator-output.txt"
  local envelope="$run_log_base/validator-output.envelope.json"
  local agent_output agent_rc=0
  run_agent "$agent" "$prompt_text" "$project" \
    "${AGENT_TIMEOUT_SECS:-}" "${AGENT_KILL_GRACE_SECS:-30}" "$envelope" \
    > "$transcript" 2>&1 || agent_rc=$?
  agent_output="$(cat "$transcript" 2>/dev/null || true)"

  if (( agent_rc != 0 )); then
    log_error "Validation aborted: flagship agent '$agent' failed (exit code $agent_rc). No findings were dropped — re-run after resolving the agent error."
    return 1
  fi

  # --- Extract + schema-validate the verdict array. A response with no usable
  #     verdicts is an error, NOT a silent "all verified" pass. ---
  local verdict_array
  if ! verdict_array="$(_verify_extract_json_array "$agent_output")"; then
    log_error "Validation failed: flagship agent '$agent' did not return a JSON verdict array."
    return 1
  fi

  local verdicts_file="$run_log_base/verdicts.json"
  printf '%s\n' "$verdict_array" > "$verdicts_file"
  if ! validate_verification_manifest "$verdicts_file"; then
    log_error "Validation failed: flagship verdict manifest did not pass schema validation ($verdicts_file)."
    return 1
  fi

  # --- Join verdicts back onto the findings and classify. Only WRONG drops a
  #     finding (a false positive); VERIFIED and STALE survive (STALE is
  #     downranked downstream, not dropped — mirrors lib/verify.sh). ---
  local status_map
  status_map="$(printf '%s' "$verdict_array" | jq -c '
    map({ key: (.finding_id | tostring), value: (.status | ascii_upcase) }) | from_entries' 2>/dev/null)"
  status_map="${status_map:-{\}}"

  local counts verified_count wrong_count stale_count kept_count
  counts="$(printf '%s' "$aug" | jq -c --argjson sm "$status_map" '
    (map(.["_validate_fid"] as $fid | ($sm[$fid] // "")) ) as $st
    | {
        verified: ([ $st[] | select(. == "VERIFIED") ] | length),
        wrong:    ([ $st[] | select(. == "WRONG") ]    | length),
        stale:    ([ $st[] | select(. == "STALE") ]    | length)
      }' 2>/dev/null)"
  verified_count="$(printf '%s' "$counts" | jq -r '.verified // 0' 2>/dev/null)"
  wrong_count="$(printf '%s' "$counts" | jq -r '.wrong // 0' 2>/dev/null)"
  stale_count="$(printf '%s' "$counts" | jq -r '.stale // 0' 2>/dev/null)"
  verified_count="${verified_count:-0}"
  wrong_count="${wrong_count:-0}"
  stale_count="${stale_count:-0}"

  # --- Write the cleaned output (survivors = everything not voted WRONG). ---
  local out_file="$run_log_base/validated-findings.jsonl"
  local survivors
  survivors="$(printf '%s' "$aug" | jq -c --argjson sm "$status_map" '
    map(select(($sm[.["_validate_fid"]] // "") != "WRONG")) | map(del(.["_validate_fid"]))' 2>/dev/null)"
  survivors="${survivors:-[]}"
  printf '%s' "$survivors" | jq -c '.[]' > "$out_file" 2>/dev/null || : > "$out_file"
  kept_count="$(printf '%s' "$survivors" | jq 'length' 2>/dev/null)"
  kept_count="${kept_count:-0}"

  # --- Report the outcome. Counts are printed explicitly — never a silent
  #     truncation (mirrors the --min-severity "Findings filtered by" line). ---
  log_info "Post-audit validation complete for $input (flagship agent: $agent)."
  printf 'Findings validated: %d\n' "$finding_count"
  printf 'Verified (survivors): %d\n' "$verified_count"
  printf 'Dropped (false positives): %d\n' "$wrong_count"
  if (( stale_count > 0 )); then
    printf 'Stale (kept, downranked): %d\n' "$stale_count"
  fi
  printf 'Cleaned findings written to: %s (%d kept)\n' "$out_file" "$kept_count"

  return 0
}
