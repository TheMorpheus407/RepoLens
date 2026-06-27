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

# RepoLens — JSON summary generation

_SUMMARY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
# shellcheck source=lib/locking.sh
source "$_SUMMARY_LIB_DIR/locking.sh"

# init_summary <summary_file> <run_id> <project_path> <mode> <agent> [spec_file] [max_issues] [output_mode] [output_dir] [remote_target] [remote_label]
#   Creates initial summary.json skeleton
init_summary() {
  local file="$1" run_id="$2" project="$3" mode="$4" agent="$5"
  local spec_file="${6:-}" max_issues="${7:-}"
  local output_mode="${8:-github}" output_dir="${9:-}"
  local remote_target="${10:-}" remote_label="${11:-}"
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
  local remote_target_json="null"
  if [[ -n "$remote_target" ]]; then
    remote_target_json="$(jq -n --arg v "$remote_target" '$v')"
  fi
  local remote_label_json="null"
  if [[ -n "$remote_label" ]]; then
    remote_label_json="$(jq -n --arg v "$remote_label" '$v')"
  fi
  cat > "$file" <<ENDJSON
{
  "run_id": "$run_id",
  "project": "$project",
  "mode": "$mode",
  "agent": "$agent",
  "remote_target": $remote_target_json,
  "remote_label": $remote_label_json,
  "spec": $spec_json,
  "max_issues": $max_issues_json,
  "output_mode": $output_mode_json,
  "output_dir": $output_dir_json,
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "completed_at": null,
  "stopped_reason": null,
  "lenses": [],
  "totals": {"lenses_run": 0, "iterations_total": 0, "issues_created": 0, "findings_filtered": 0}
}
ENDJSON
}

# increment_findings_filtered <summary_file> [count]
#   Adds to totals.findings_filtered. Missing files are ignored so library
#   callers without an active summary can still use filtering helpers directly.
increment_findings_filtered() {
  local file="${1:-}" count="${2:-1}"
  [[ -n "$file" && -f "$file" ]] || return 0
  [[ "$count" =~ ^[0-9]+$ ]] || count=0
  (( count > 0 )) || return 0
  with_file_lock "${file}.lock" "${REPOLENS_SUMMARY_LOCK_TIMEOUT:-30}" \
    _increment_findings_filtered_locked "$file" "$count"
}

_increment_findings_filtered_locked() {
  local file="$1" count="$2"
  local tmp

  tmp="$(mktemp "${file}.tmp.XXXXXX")" || return 1
  jq --argjson c "$count" \
    '.totals.findings_filtered = ((.totals.findings_filtered // 0) + $c)' \
    "$file" > "$tmp" && mv "$tmp" "$file"
  local rc=$?
  rm -f "$tmp" 2>/dev/null || true
  return "$rc"
}

# increment_summary_issues_created <summary_file> [count]
#   Adds to totals.issues_created for issue emission that happens outside the
#   per-lens loop, such as grouped polish issue filing after ranking.
increment_summary_issues_created() {
  local file="${1:-}" count="${2:-1}"
  [[ -n "$file" && -f "$file" ]] || return 0
  [[ "$count" =~ ^[0-9]+$ ]] || count=0
  (( count > 0 )) || return 0
  with_file_lock "${file}.lock" "${REPOLENS_SUMMARY_LOCK_TIMEOUT:-30}" \
    _increment_summary_issues_created_locked "$file" "$count"
}

_increment_summary_issues_created_locked() {
  local file="$1" count="$2"
  local tmp

  tmp="$(mktemp "${file}.tmp.XXXXXX")" || return 1
  jq --argjson c "$count" \
    '.totals.issues_created = ((.totals.issues_created // 0) + $c)' \
    "$file" > "$tmp" && mv "$tmp" "$file"
  local rc=$?
  rm -f "$tmp" 2>/dev/null || true
  return "$rc"
}

# record_lens <summary_file> <domain> <lens_id> <iterations> <status> \
#             [issues] [rate_limit_sleep_seconds] \
#             [started_at] [completed_at] [duration_seconds]
#   Appends a lens result to the summary. The `round` field is sourced from
#   the ambient CURRENT_ROUND_INDEX variable (set by `run_rounds` for
#   multi-round runs), defaulting to 0 for non-rounded runs so that
#   `(domain, lens)` no longer collides across rounds in `summary.json`.
#   The trailing timing args are optional and additive: started_at/completed_at
#   are ISO-8601 UTC strings (empty → JSON null), duration_seconds is a
#   non-negative integer (non-numeric → 0). Legacy 7-arg callers keep working
#   with timing defaulting to null/0.
record_lens() {
  local file="$1" domain="$2" lens_id="$3" iterations="$4" status="$5"
  local issues="${6:-0}"
  local rate_limit_sleep_seconds="${7:-0}"
  local started_at="${8:-}"
  local completed_at="${9:-}"
  local duration_seconds="${10:-0}"
  with_file_lock "${file}.lock" "${REPOLENS_SUMMARY_LOCK_TIMEOUT:-30}" \
    _record_lens_locked "$file" "$domain" "$lens_id" "$iterations" "$status" "$issues" "$rate_limit_sleep_seconds" \
      "$started_at" "$completed_at" "$duration_seconds"
}

_record_lens_locked() {
  local file="$1" domain="$2" lens_id="$3" iterations="$4" status="$5"
  local issues="${6:-0}"
  local rate_limit_sleep_seconds="${7:-0}"
  local started_at="${8:-}"
  local completed_at="${9:-}"
  local duration_seconds="${10:-0}"
  local tmp
  local lenses_increment=1
  local round="${CURRENT_ROUND_INDEX:-0}"
  if [[ ! "$round" =~ ^[0-9]+$ ]]; then
    round=0
  fi
  tmp="$(mktemp "${file}.tmp.XXXXXX")" || return 1
  if [[ "$status" == "skipped" ]]; then
    lenses_increment=0
  fi
  if [[ ! "$rate_limit_sleep_seconds" =~ ^[0-9]+$ ]]; then
    rate_limit_sleep_seconds=0
  fi
  if [[ ! "$duration_seconds" =~ ^[0-9]+$ ]]; then
    duration_seconds=0
  fi
  jq --arg d "$domain" --arg l "$lens_id" --argjson i "$iterations" --arg s "$status" \
     --argjson iss "$issues" --argjson rlss "$rate_limit_sleep_seconds" --argjson lr "$lenses_increment" \
     --argjson rnd "$round" \
     --arg sa "$started_at" --arg ca "$completed_at" --argjson dur "$duration_seconds" \
    '.lenses += [{"domain": $d, "lens": $l, "iterations": $i, "status": $s, "issues_created": $iss, "rate_limit_sleep_seconds": $rlss, "round": $rnd, "started_at": ($sa | if . == "" then null else . end), "completed_at": ($ca | if . == "" then null else . end), "duration_seconds": $dur}] |
     .totals.lenses_run += $lr |
     .totals.iterations_total += $i |
     .totals.issues_created += $iss' "$file" > "$tmp" && mv "$tmp" "$file"
  local rc=$?
  rm -f "$tmp" 2>/dev/null || true
  return "$rc"
}

# classify_summary_health <summary_file> [threshold_percent]
#   Prints ok, no-findings, broken, or empty for a finalized summary.
classify_summary_health() {
  local file="$1" threshold="${2:-90}"

  if [[ ! "$threshold" =~ ^[1-9][0-9]*$ ]] || (( threshold > 100 )); then
    return 2
  fi

  jq -r --argjson threshold "$threshold" '
    (.totals.issues_created // 0) as $issues
    | (.lenses // []) as $lenses
    | ($lenses | map(select(.status != "skipped"))) as $run_lenses
    | ($run_lenses | length) as $total
    | ($run_lenses | map(select(.status == "max-iterations")) | length) as $max_iterations
    | if $issues > 0 then "ok"
      elif $total == 0 then "empty"
      elif (($max_iterations * 100) >= ($threshold * $total)) then "broken"
      else "no-findings"
      end
  ' "$file"
}

# set_summary_health <summary_file> [threshold_percent]
#   Classifies a summary and stores the result in summary.json.
set_summary_health() {
  local file="$1" threshold="${2:-90}"
  local health

  health="$(classify_summary_health "$file" "$threshold")" || return $?
  with_file_lock "${file}.lock" "${REPOLENS_SUMMARY_LOCK_TIMEOUT:-30}" \
    _set_summary_health_locked "$file" "$health"
}

_set_summary_health_locked() {
  local file="$1" health="$2"
  local tmp

  tmp="$(mktemp "${file}.tmp.XXXXXX")" || return 1
  jq --arg h "$health" '
    .health = $h
    | if $h == "broken" and (.stopped_reason == null or .stopped_reason == "") then
        .stopped_reason = "degenerate-no-findings"
      else
        .
      end
  ' "$file" > "$tmp" && mv "$tmp" "$file"
  local rc=$?
  rm -f "$tmp" 2>/dev/null || true
  return "$rc"
}

# set_stop_reason <summary_file> <reason>
#   Sets the stopped_reason field in summary.json. Stop reasons are persisted
#   from abort/shutdown paths, so lock contention uses a short local timeout:
#   if the summary lock cannot be opened or acquired, this returns nonzero and
#   leaves summary.json unchanged.
set_stop_reason() {
  local file="$1" reason="${2:-}"
  local lock_timeout="${REPOLENS_SUMMARY_STOP_REASON_LOCK_TIMEOUT:-1}"
  [[ -n "$reason" ]] || return 0
  [[ "$lock_timeout" =~ ^[0-9]+$ ]] || lock_timeout=1
  with_file_lock "${file}.lock" "$lock_timeout" \
    _set_stop_reason_locked "$file" "$reason"
}

_set_stop_reason_locked() {
  local file="$1" reason="$2"
  local tmp

  tmp="$(mktemp "${file}.tmp.XXXXXX")" || return 1
  jq --arg r "$reason" '.stopped_reason = $r' "$file" > "$tmp" && mv "$tmp" "$file"
  local rc=$?
  rm -f "$tmp" 2>/dev/null || true
  return "$rc"
}

# clear_stop_reason <summary_file>
#   Clears the stopped_reason field in summary.json
clear_stop_reason() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  with_file_lock "${file}.lock" "${REPOLENS_SUMMARY_LOCK_TIMEOUT:-30}" \
    _clear_stop_reason_locked "$file"
}

_clear_stop_reason_locked() {
  local file="$1"
  local tmp

  tmp="$(mktemp "${file}.tmp.XXXXXX")" || return 1
  jq '.stopped_reason = null' "$file" > "$tmp" && mv "$tmp" "$file"
  local rc=$?
  rm -f "$tmp" 2>/dev/null || true
  return "$rc"
}

# finalize_summary <summary_file>
#   Sets completed_at timestamp
finalize_summary() {
  local file="$1"
  with_file_lock "${file}.lock" "${REPOLENS_SUMMARY_LOCK_TIMEOUT:-30}" \
    _finalize_summary_locked "$file"
}

_finalize_summary_locked() {
  local file="$1"
  local tmp

  tmp="$(mktemp "${file}.tmp.XXXXXX")" || return 1
  jq --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.completed_at = $t' "$file" > "$tmp" && mv "$tmp" "$file"
  local rc=$?
  rm -f "$tmp" 2>/dev/null || true
  return "$rc"
}

# _summary_fmt_duration <seconds>
#   Human-format a duration. Reuses status_format_duration (lib/status.sh) when
#   that library is loaded; otherwise degrades to raw seconds. Uses a runtime
#   declare -F guard because lib/summary.sh is sourced before lib/status.sh, so
#   the formatter is unavailable at source time but present at call time.
_summary_fmt_duration() {
  if declare -F status_format_duration >/dev/null 2>&1; then
    status_format_duration "$1"
  else
    printf '%ss' "$1"
  fi
}

# summary_time_breakdown <summary_file> [top_n]
#   Prints a human-readable time breakdown to stdout: total wall time, total
#   lens-seconds, the top-N slowest individual lens-runs (default 10), and
#   per-domain summed duration_seconds (descending). Degrades gracefully: if jq
#   is missing, the file is absent, or no lens has a positive duration_seconds
#   (older/legacy summaries), it prints a single "Time breakdown: no timing
#   data" line (or nothing for a missing file) and returns 0. Durations are
#   formatted via _summary_fmt_duration. Read-only; no side effects.
summary_time_breakdown() {
  local file="${1:-}" top_n="${2:-10}"
  [[ -n "$file" && -f "$file" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  [[ "$top_n" =~ ^[0-9]+$ ]] && (( top_n > 0 )) || top_n=10

  local total_lens_seconds
  total_lens_seconds="$(jq -r '[.lenses[]?.duration_seconds // 0] | add // 0' "$file" 2>/dev/null || printf '0')"
  [[ "$total_lens_seconds" =~ ^[0-9]+$ ]] || total_lens_seconds=0
  if (( total_lens_seconds == 0 )); then
    printf 'Time breakdown: no timing data\n'
    return 0
  fi

  local wall_seconds
  wall_seconds="$(jq -r '
    (.started_at // null) as $s | (.completed_at // null) as $c
    | if ($s != null and $c != null and ($s|type)=="string" and ($c|type)=="string")
      then (($c|fromdateiso8601?) // null) as $ce | (($s|fromdateiso8601?) // null) as $se
        | if ($ce != null and $se != null) then (($ce - $se) | (if . < 0 then 0 else . end)) else empty end
      else empty end
  ' "$file" 2>/dev/null || true)"

  printf 'Time breakdown\n'
  if [[ "$wall_seconds" =~ ^[0-9]+$ ]]; then
    printf '  wall time:    %s\n' "$(_summary_fmt_duration "$wall_seconds")"
  fi
  printf '  lens-seconds: %s\n' "$(_summary_fmt_duration "$total_lens_seconds")"

  printf '  slowest lenses (top %d):\n' "$top_n"
  while IFS=$'\t' read -r key dur; do
    [[ -n "$key" ]] || continue
    printf '    %-40s %s\n' "$key" "$(_summary_fmt_duration "$dur")"
  done < <(jq -r --argjson n "$top_n" '
    (.lenses // [])
    | map(select((.duration_seconds // 0) > 0))
    | sort_by([-(.duration_seconds // 0), .domain, .lens])
    | .[0:$n][]
    | [ (.domain + "/" + .lens), (.duration_seconds // 0) ] | @tsv
  ' "$file" 2>/dev/null)

  printf '  per-domain totals:\n'
  while IFS=$'\t' read -r dom dur; do
    [[ -n "$dom" ]] || continue
    printf '    %-24s %s\n' "$dom" "$(_summary_fmt_duration "$dur")"
  done < <(jq -r '
    (.lenses // [])
    | map(select((.duration_seconds // 0) > 0))
    | group_by(.domain)
    | map({domain: .[0].domain, total: (map(.duration_seconds // 0) | add)})
    | sort_by([-.total, .domain])[]
    | [ .domain, .total ] | @tsv
  ' "$file" 2>/dev/null)
}
