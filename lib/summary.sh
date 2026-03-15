#!/usr/bin/env bash
# RepoLens — JSON summary generation

# init_summary <summary_file> <run_id> <project_path> <mode> <agent>
#   Creates initial summary.json skeleton
init_summary() {
  local file="$1" run_id="$2" project="$3" mode="$4" agent="$5"
  cat > "$file" <<ENDJSON
{
  "run_id": "$run_id",
  "project": "$project",
  "mode": "$mode",
  "agent": "$agent",
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "completed_at": null,
  "lenses": [],
  "totals": {"lenses_run": 0, "iterations_total": 0, "issues_created": 0}
}
ENDJSON
}

# record_lens <summary_file> <domain> <lens_id> <iterations> <status>
#   Appends a lens result to the summary
record_lens() {
  local file="$1" domain="$2" lens_id="$3" iterations="$4" status="$5"
  local tmp="${file}.tmp"
  jq --arg d "$domain" --arg l "$lens_id" --argjson i "$iterations" --arg s "$status" \
    '.lenses += [{"domain": $d, "lens": $l, "iterations": $i, "status": $s}] |
     .totals.lenses_run += 1 |
     .totals.iterations_total += $i' "$file" > "$tmp" && mv "$tmp" "$file"
}

# finalize_summary <summary_file>
#   Sets completed_at timestamp
finalize_summary() {
  local file="$1"
  local tmp="${file}.tmp"
  jq --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.completed_at = $t' "$file" > "$tmp" && mv "$tmp" "$file"
}
