#!/usr/bin/env bash
# Copyright 2025 Bootstrap Academy
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

# RepoLens — JSON summary generation

# init_summary <summary_file> <run_id> <project_path> <mode> <agent> [spec_file] [max_issues] [output_mode] [output_dir]
#   Creates initial summary.json skeleton
init_summary() {
  local file="$1" run_id="$2" project="$3" mode="$4" agent="$5"
  local spec_file="${6:-}" max_issues="${7:-}"
  local output_mode="${8:-github}" output_dir="${9:-}"
  local spec_json="null"
  if [[ -n "$spec_file" ]]; then
    spec_json="$(jq -n --arg p "$spec_file" '$p')"
  fi
  local max_issues_json="null"
  if [[ -n "$max_issues" ]]; then
    max_issues_json="$max_issues"
  fi
  local output_dir_json="null"
  if [[ -n "$output_dir" ]]; then
    output_dir_json="$(jq -n --arg p "$output_dir" '$p')"
  fi
  local output_mode_json
  output_mode_json="$(jq -n --arg m "$output_mode" '$m')"
  cat > "$file" <<ENDJSON
{
  "run_id": "$run_id",
  "project": "$project",
  "mode": "$mode",
  "agent": "$agent",
  "spec": $spec_json,
  "max_issues": $max_issues_json,
  "output_mode": $output_mode_json,
  "output_dir": $output_dir_json,
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "completed_at": null,
  "stopped_reason": null,
  "lenses": [],
  "totals": {"lenses_run": 0, "iterations_total": 0, "issues_created": 0}
}
ENDJSON
}

# record_lens <summary_file> <domain> <lens_id> <iterations> <status> [issues]
#   Appends a lens result to the summary
record_lens() {
  local file="$1" domain="$2" lens_id="$3" iterations="$4" status="$5"
  local issues="${6:-0}"
  local tmp="${file}.tmp"
  local lenses_increment=1
  if [[ "$status" == "skipped" ]]; then
    lenses_increment=0
  fi
  jq --arg d "$domain" --arg l "$lens_id" --argjson i "$iterations" --arg s "$status" \
     --argjson iss "$issues" --argjson lr "$lenses_increment" \
    '.lenses += [{"domain": $d, "lens": $l, "iterations": $i, "status": $s, "issues_created": $iss}] |
     .totals.lenses_run += $lr |
     .totals.iterations_total += $i |
     .totals.issues_created += $iss' "$file" > "$tmp" && mv "$tmp" "$file"
}

# set_stop_reason <summary_file> <reason>
#   Sets the stopped_reason field in summary.json
set_stop_reason() {
  local file="$1" reason="${2:-}"
  [[ -n "$reason" ]] || return 0
  local tmp="${file}.tmp"
  jq --arg r "$reason" '.stopped_reason = $r' "$file" > "$tmp" && mv "$tmp" "$file"
}

# finalize_summary <summary_file>
#   Sets completed_at timestamp
finalize_summary() {
  local file="$1"
  local tmp="${file}.tmp"
  jq --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.completed_at = $t' "$file" > "$tmp" && mv "$tmp" "$file"
}
