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

# RepoLens — canonical "latest result" pointer (issue #308).
#
# `logs/` accumulates one `<run-id>/` dir per run with no stable "this is THE
# result" marker; `status_latest_file` only guesses newest-by-mtime. At finalize
# we write a single canonical pointer at the TOP of the logs tree
# (`logs/latest-result.json`) describing the run that just completed, derived
# from its finalized `summary.json` (and `final/manifest.json` if present).
#
# The write is additive and strictly non-fatal: every failure path logs a
# warning and returns 0 so a pointer-write failure never changes the run's exit
# code. Guarded by `command -v jq`.

# write_latest_result_pointer <logs_dir> <run_id> <mode> <agent> \
#     <summary_file> <status> <final_dir>
#
# Writes <logs_dir>/latest-result.json atomically (temp file in <logs_dir> + mv).
# Fields:
#   run_id, mode, agent      — passed through verbatim
#   started_at, finished_at  — summary .started_at / .completed_at (renamed)
#   status                   — passed through (finished/finished-empty/failed/…)
#   findings, manifest       — ABSOLUTE paths under <final_dir> (not created here)
#   counts                   — headline counts by NORMALIZED severity from
#                              <final_dir>/manifest.json if present, else {}
#   discarded_runs           — [] placeholder (sibling issue owns it)
#
# Side effects: creates/replaces <logs_dir>/latest-result.json. Never aborts the
# caller — returns 0 on every path; warnings go to log_warn.
write_latest_result_pointer() {
  local logs_dir="$1" run_id="$2" mode="$3" agent="$4" summary_file="$5" status="$6" final_dir="$7"

  if ! command -v jq >/dev/null 2>&1; then
    log_warn "latest-result pointer: jq not available; skipping pointer write"
    return 0
  fi

  local started_at="" finished_at=""
  if [[ -f "$summary_file" ]]; then
    started_at="$(jq -r '.started_at // ""' "$summary_file" 2>/dev/null || printf '')"
    finished_at="$(jq -r '.completed_at // ""' "$summary_file" 2>/dev/null || printf '')"
  fi

  local findings_path="$final_dir/findings.jsonl"
  local manifest_path="$final_dir/manifest.json"

  # Headline counts by normalized severity. The manifest is a flat array of
  # finding objects; entries with an unrecognized severity (severity_normalize
  # returns empty) and non-finding objects (no .severity) are skipped.
  local counts_json='{}'
  if [[ -f "$manifest_path" ]]; then
    declare -A _sev_counts=()
    local _sev _norm
    while IFS= read -r _sev; do
      _norm="$(severity_normalize "$_sev")"
      [[ -n "$_norm" ]] || continue
      _sev_counts["$_norm"]=$(( ${_sev_counts["$_norm"]:-0} + 1 ))
    done < <(jq -r 'if type=="array" then .[] else empty end | objects | .severity // empty' "$manifest_path" 2>/dev/null)

    if (( ${#_sev_counts[@]} > 0 )); then
      local _k
      counts_json="$(
        for _k in "${!_sev_counts[@]}"; do
          printf '%s\t%s\n' "$_k" "${_sev_counts[$_k]}"
        done | jq -R -n '[inputs | split("\t") | {(.[0]): (.[1] | tonumber)}] | add // {}' 2>/dev/null
      )"
      [[ -n "$counts_json" ]] || counts_json='{}'
    fi
  fi

  # Atomic write: temp file inside logs_dir (same filesystem) + mv. If logs_dir
  # is not a writable directory the mktemp fails and we bail non-fatally.
  local tmp
  tmp="$(mktemp "$logs_dir/.latest-result.json.tmp.XXXXXX" 2>/dev/null)" || {
    log_warn "latest-result pointer: cannot create temp file in $logs_dir; skipping pointer write"
    return 0
  }

  if ! jq -n \
      --arg run_id "$run_id" \
      --arg mode "$mode" \
      --arg agent "$agent" \
      --arg started_at "$started_at" \
      --arg finished_at "$finished_at" \
      --arg status "$status" \
      --arg findings "$findings_path" \
      --arg manifest "$manifest_path" \
      --argjson counts "$counts_json" \
      '{
        run_id: $run_id,
        mode: $mode,
        agent: $agent,
        started_at: $started_at,
        finished_at: $finished_at,
        status: $status,
        findings: $findings,
        manifest: $manifest,
        counts: $counts,
        discarded_runs: []
      }' > "$tmp" 2>/dev/null; then
    log_warn "latest-result pointer: failed to build JSON; skipping pointer write"
    rm -f "$tmp" 2>/dev/null
    return 0
  fi

  if ! mv -f "$tmp" "$logs_dir/latest-result.json" 2>/dev/null; then
    log_warn "latest-result pointer: failed to write $logs_dir/latest-result.json; skipping pointer write"
    rm -f "$tmp" 2>/dev/null
    return 0
  fi

  return 0
}
