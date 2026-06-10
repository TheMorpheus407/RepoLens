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

# RepoLens - aggregated run status snapshots

STATUS_INTERVAL_DEFAULT=10
STATUS_STALE_WARN_DEFAULT=120
STATUS_STALE_ERROR_DEFAULT=600
STATUS_UPDATER_PID=""
STATUS_UPDATER_PGID=""
STATUS_LENSES_FILE=""
# shellcheck disable=SC2034 # Shared with repolens.sh after this file is sourced.
REPOLENS_FINAL_STATE="finished"
# shellcheck disable=SC2034 # Shared with repolens.sh after this file is sourced.
REPOLENS_STOP_REASON=""

set_final_state() {
  local state="${1:-}" reason="${2:-}"

  case "$state" in
    finished|finished-empty|failed|rate-limit-pending|interrupted) ;;
    *) return 2 ;;
  esac

  # shellcheck disable=SC2034 # Shared with callers after this file is sourced.
  REPOLENS_FINAL_STATE="$state"
  if (($# >= 2)); then
    # shellcheck disable=SC2034 # Shared with callers after this file is sourced.
    REPOLENS_STOP_REASON="$reason"
  fi

  [[ -n "$reason" ]] || return 0
  [[ -n "${SUMMARY_FILE:-}" && -f "${SUMMARY_FILE:-}" ]] || return 0
  declare -F set_stop_reason >/dev/null 2>&1 || return 0

  set_stop_reason "$SUMMARY_FILE" "$reason" || true
}

_STATUS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_STATUS_LIB_DIR/locking.sh"

status_log_warn() {
  if declare -F log_warn >/dev/null 2>&1; then
    log_warn "$1"
  else
    printf 'WARN: %s\n' "$1" >&2
  fi
}

status_emit_transition_log() {
  local level="$1" run_id="$2" log_base="$3" message="$4"
  local log_file

  case "$level" in
    INFO)
      if declare -F log_info >/dev/null 2>&1 && [[ -n "${_REPOLENS_LOG_FILE:-}" ]]; then
        log_info "$message"
        return
      fi
      ;;
    WARN)
      if declare -F log_warn >/dev/null 2>&1 && [[ -n "${_REPOLENS_LOG_FILE:-}" ]]; then
        log_warn "$message"
        return
      fi
      ;;
    ERROR)
      if declare -F log_error >/dev/null 2>&1 && [[ -n "${_REPOLENS_LOG_FILE:-}" ]]; then
        log_error "$message"
        return
      fi
      ;;
  esac

  if [[ -n "$run_id" && -n "$log_base" ]]; then
    mkdir -p "$log_base" 2>/dev/null || true
    log_file="$log_base/$run_id.log"
    printf '[%s] [%s] %s\n' "$level" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$message" >> "$log_file" 2>/dev/null || true
  fi
}

resolve_status_interval() {
  local interval="${REPOLENS_STATUS_INTERVAL:-$STATUS_INTERVAL_DEFAULT}"

  if [[ ! "$interval" =~ ^[0-9]+$ ]]; then
    status_log_warn "Invalid REPOLENS_STATUS_INTERVAL='$interval'; using default ${STATUS_INTERVAL_DEFAULT}s for status.json refreshes."
    interval="$STATUS_INTERVAL_DEFAULT"
  else
    interval=$((10#$interval))
    if (( interval <= 0 )); then
      status_log_warn "Invalid REPOLENS_STATUS_INTERVAL='$interval'; using default ${STATUS_INTERVAL_DEFAULT}s for status.json refreshes."
      interval="$STATUS_INTERVAL_DEFAULT"
    fi
  fi

  printf '%s\n' "$interval"
}

status_resolve_nonnegative_seconds() {
  local env_name="$1" default_value="$2" purpose="$3"
  local raw_value="${!env_name:-$default_value}"
  local value

  if [[ ! "$raw_value" =~ ^[0-9]+$ ]]; then
    status_log_warn "Invalid $env_name='$raw_value'; using default ${default_value}s for $purpose."
    printf '%s\n' "$default_value"
    return
  fi

  value=$((10#$raw_value))
  printf '%s\n' "$value"
}

resolve_status_stale_thresholds() {
  local warn_seconds error_seconds

  warn_seconds="$(status_resolve_nonnegative_seconds "REPOLENS_STALE_WARN_SECONDS" "$STATUS_STALE_WARN_DEFAULT" "stale heartbeat warnings")"
  error_seconds="$(status_resolve_nonnegative_seconds "REPOLENS_STALE_ERROR_SECONDS" "$STATUS_STALE_ERROR_DEFAULT" "stale heartbeat errors")"

  if (( error_seconds <= warn_seconds )); then
    if (( STATUS_STALE_ERROR_DEFAULT > warn_seconds )); then
      status_log_warn "Invalid stale heartbeat thresholds: REPOLENS_STALE_ERROR_SECONDS (${error_seconds}s) must be greater than warning threshold (${warn_seconds}s); using default ${STATUS_STALE_ERROR_DEFAULT}s for errors."
      error_seconds="$STATUS_STALE_ERROR_DEFAULT"
    else
      status_log_warn "Invalid stale heartbeat thresholds: REPOLENS_STALE_ERROR_SECONDS (${error_seconds}s) must be greater than warning threshold (${warn_seconds}s); using ${warn_seconds}s + 1 for errors."
      error_seconds=$((warn_seconds + 1))
    fi
  fi

  printf '%s %s\n' "$warn_seconds" "$error_seconds"
}

resolve_status_stale_warn_seconds() {
  local warn_seconds _error_seconds
  read -r warn_seconds _error_seconds < <(resolve_status_stale_thresholds)
  printf '%s\n' "$warn_seconds"
}

resolve_status_stale_error_seconds() {
  local _warn_seconds error_seconds
  read -r _warn_seconds error_seconds < <(resolve_status_stale_thresholds)
  printf '%s\n' "$error_seconds"
}

write_status_snapshot() {
  local state="$1" log_base="$3"
  local status_file="$log_base/status.json"

  with_file_lock "${status_file}.lock" "${REPOLENS_STATUS_LOCK_TIMEOUT:-30}" \
    _write_status_snapshot_locked "$@"
}

cleanup_status_snapshot_temps() {
  local log_base="$1"
  [[ -n "$log_base" && -d "$log_base" ]] || return 0

  rm -f \
    "$log_base"/status.json.tmp.* \
    "$log_base"/.status.active.* \
    "$log_base"/.status.completed.* \
    "$log_base"/.status.lenses.* \
    2>/dev/null || true
}

status_rate_limit_next_action_earliest_at() {
  local log_base="$1" marker key value earliest_at=""

  marker="$log_base/.rate-limit-abort"
  [[ -f "$marker" ]] || { printf '\n'; return 0; }

  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    case "$key" in
      earliest_at) earliest_at="$value" ;;
    esac
  done < "$marker"

  if [[ "$earliest_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    printf '%s\n' "$earliest_at"
  else
    printf '\n'
  fi
}

_write_status_snapshot_locked() {
  local state="$1" run_id="$2" log_base="$3" heartbeat_dir="$4" completed_file="$5" summary_file="$6"
  local project="$7" repo="$8" mode="$9" agent="${10}" parallel="${11}" max_parallel="${12}" lenses_file="${13}"
  local remote_target="${14:-}" remote_label="${15:-}"
  local status_file="$log_base/status.json"
  local tmp_file="${status_file}.tmp.${BASHPID}"
  local active_tmp completed_tmp lenses_tmp
  local now_iso now_epoch started_at issues_created health stopped_reason next_action_earliest_at
  local heartbeat_file

  if [[ "$state" == "running" && -f "$status_file" && "${REPOLENS_STATUS_ALLOW_RUNNING_OVER_TERMINAL:-false}" != "true" ]]; then
    case "$(jq -r '.state // empty' "$status_file" 2>/dev/null || true)" in
      finished|finished-empty|failed|interrupted|rate-limit-pending)
        return 0
        ;;
    esac
  fi

  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  now_epoch="$(date -u +%s)"

  started_at=""
  if [[ -f "$summary_file" ]]; then
    started_at="$(jq -r '.started_at // empty' "$summary_file" 2>/dev/null || true)"
  fi
  if [[ -z "$started_at" ]]; then
    started_at="$now_iso"
  fi
  if [[ -f "$summary_file" ]]; then
    if [[ -z "$remote_target" ]]; then
      remote_target="$(jq -r '.remote_target // empty' "$summary_file" 2>/dev/null || true)"
    fi
    if [[ -z "$remote_label" ]]; then
      remote_label="$(jq -r '.remote_label // empty' "$summary_file" 2>/dev/null || true)"
    fi
  fi

  issues_created=0
  if [[ -f "$summary_file" ]]; then
    issues_created="$(jq -r '.totals.issues_created // 0' "$summary_file" 2>/dev/null || printf '0')"
  fi
  if [[ ! "$issues_created" =~ ^[0-9]+$ ]]; then
    issues_created=0
  else
    issues_created=$((10#$issues_created))
  fi
  health=""
  if [[ -f "$summary_file" ]]; then
    health="$(jq -r '.health // empty' "$summary_file" 2>/dev/null || true)"
  fi
  stopped_reason=""
  if [[ -f "$summary_file" ]]; then
    stopped_reason="$(jq -r '.stopped_reason // empty' "$summary_file" 2>/dev/null || true)"
  fi
  next_action_earliest_at=""
  if [[ "$state" == "rate-limit-pending" ]]; then
    next_action_earliest_at="$(status_rate_limit_next_action_earliest_at "$log_base")"
  fi

  if [[ "$parallel" != "true" && "$parallel" != "false" ]]; then
    parallel=false
  fi
  if [[ ! "$max_parallel" =~ ^[0-9]+$ ]]; then
    max_parallel=0
  else
    max_parallel=$((10#$max_parallel))
  fi

  active_tmp="$(mktemp "$log_base/.status.active.XXXXXX")" || return 1
  completed_tmp="$(mktemp "$log_base/.status.completed.XXXXXX")" || {
    rm -f "$active_tmp"
    return 1
  }
  lenses_tmp="$(mktemp "$log_base/.status.lenses.XXXXXX")" || {
    rm -f "$active_tmp" "$completed_tmp"
    return 1
  }

  : > "$active_tmp"
  if [[ -d "$heartbeat_dir" ]]; then
    for heartbeat_file in "$heartbeat_dir"/*.json; do
      [[ -f "$heartbeat_file" ]] || continue
      jq -c --argjson now_epoch "$now_epoch" '
        def number_value($fallback):
          if type == "number" then .
          elif type == "string" then (tonumber? // $fallback)
          else $fallback
          end;
        def age_from($now):
          if type == "string" then
            ($now - (try fromdateiso8601 catch $now) | floor) as $age
            | if $age < 0 then 0 else $age end
          else 0
          end;
        select((.domain | type) == "string" and (.lens_id | type) == "string")
        | {
            domain: .domain,
            lens_id: .lens_id,
            pid: ((.pid // 0) | number_value(0)),
            iteration: ((.iteration // 0) | number_value(0)),
            started_at: (.started_at // ""),
            last_heartbeat_at: (.last_heartbeat_at // ""),
            age_seconds: ((.started_at // "") | age_from($now_epoch)),
            heartbeat_age_seconds: ((.last_heartbeat_at // "") | age_from($now_epoch))
          }
      ' "$heartbeat_file" >> "$active_tmp" 2>/dev/null || true
    done
  fi

  if [[ -f "$completed_file" ]]; then
    grep -v '^[[:space:]]*$' "$completed_file" 2>/dev/null | sort -u > "$completed_tmp" || : > "$completed_tmp"
  else
    : > "$completed_tmp"
  fi

  if [[ -f "$lenses_file" ]]; then
    grep -v '^[[:space:]]*$' "$lenses_file" 2>/dev/null > "$lenses_tmp" || : > "$lenses_tmp"
  else
    : > "$lenses_tmp"
  fi

  jq -n \
    --arg run_id "$run_id" \
    --arg project "$project" \
    --arg repo "$repo" \
    --arg mode "$mode" \
    --arg agent "$agent" \
    --arg remote_target "$remote_target" \
    --arg remote_label "$remote_label" \
    --argjson parallel "$parallel" \
    --argjson max_parallel "$max_parallel" \
    --arg started_at "$started_at" \
    --arg updated_at "$now_iso" \
    --arg state "$state" \
    --arg health "$health" \
    --arg stopped_reason "$stopped_reason" \
    --arg next_action_earliest_at "$next_action_earliest_at" \
    --argjson issues_created "$issues_created" \
    --slurpfile active_raw <(jq -s 'sort_by(.domain, .lens_id)' "$active_tmp" 2>/dev/null || printf '[]') \
    --rawfile completed_raw "$completed_tmp" \
    --rawfile lenses_raw "$lenses_tmp" \
    '
      def lines_array($text):
        $text
        | split("\n")
        | map(select(length > 0));

      ($active_raw[0] // []) as $active
      | (lines_array($lenses_raw)) as $lenses
      | (lines_array($completed_raw) | unique) as $completed_all
      | ($lenses | unique) as $lens_set
      | ($active | map(.domain + "/" + .lens_id) | unique) as $active_keys
      | ($completed_all | map(select(. as $item | $lens_set | index($item))) | unique) as $completed
      | ($lenses | map(select(. as $item | (($active_keys | index($item)) | not) and (($completed | index($item)) | not)))) as $queued
      | ($lenses | length) as $total
      | ($completed | length) as $completed_count
      | {
          run_id: $run_id,
          project: $project,
          repo: $repo,
          mode: $mode,
          agent: $agent,
          remote_target: (if $remote_target == "" then null else $remote_target end),
          remote_label: (if $remote_label == "" then null else $remote_label end),
          parallel: $parallel,
          max_parallel: $max_parallel,
          started_at: $started_at,
          updated_at: $updated_at,
          state: $state,
          health: (if $health == "" then null else $health end),
          stopped_reason: (if $stopped_reason == "" then null else $stopped_reason end),
          total_lenses: $total,
          counts: {
            queued: ($queued | length),
            active: ($active | length),
            completed: $completed_count,
            issues_created: $issues_created
          },
          completion_percentage: (if $total == 0 then 0 else (($completed_count * 10000 / $total) | round / 100) end),
          active: $active,
          queued: $queued,
          completed: $completed
        }
      | if $state == "rate-limit-pending" and $next_action_earliest_at != "" then
          . + {next_action: {earliest_at: $next_action_earliest_at}}
        else
          .
        end
    ' > "$tmp_file" && mv -f "$tmp_file" "$status_file"

  local rc=$?
  rm -f "$active_tmp" "$completed_tmp" "$lenses_tmp" "$tmp_file"
  return "$rc"
}

status_stale_state_path() {
  local heartbeat_file="$1"
  printf '%s.state\n' "${heartbeat_file%.json}"
}

status_stale_age_path() {
  local heartbeat_file="$1"
  printf '%s.state-age\n' "${heartbeat_file%.json}"
}

status_read_stale_state() {
  local state_file="$1"
  local state="ok"

  if [[ -f "$state_file" ]]; then
    IFS= read -r state < "$state_file" || state="ok"
  fi

  case "$state" in
    ok|warn|error)
      printf '%s\n' "$state"
      ;;
    *)
      printf 'ok\n'
      ;;
  esac
}

status_read_stale_age() {
  local age_file="$1" fallback="$2"
  local age="$fallback"

  if [[ -f "$age_file" ]]; then
    IFS= read -r age < "$age_file" || age="$fallback"
  fi

  if [[ ! "$age" =~ ^[0-9]+$ ]]; then
    age="$fallback"
  else
    age=$((10#$age))
  fi

  printf '%s\n' "$age"
}

status_write_stale_state() {
  local state_file="$1" state="$2"
  local tmp_file="${state_file}.tmp.${BASHPID}"

  printf '%s\n' "$state" > "$tmp_file" && mv -f "$tmp_file" "$state_file"
}

status_write_stale_age() {
  local age_file="$1" age="$2"
  local tmp_file="${age_file}.tmp.${BASHPID}"

  [[ "$age" =~ ^[0-9]+$ ]] || age=0
  printf '%s\n' "$age" > "$tmp_file" && mv -f "$tmp_file" "$age_file"
}

cleanup_stale_heartbeat_state() {
  local heartbeat_dir="$1"
  local state_file age_file

  [[ -d "$heartbeat_dir" ]] || return 0

  for state_file in "$heartbeat_dir"/*.state "$heartbeat_dir"/.*.state; do
    [[ -e "$state_file" ]] || continue
    rm -f "$state_file" "${state_file}.tmp."* 2>/dev/null || true
  done
  for age_file in "$heartbeat_dir"/*.state-age "$heartbeat_dir"/.*.state-age; do
    [[ -e "$age_file" ]] || continue
    rm -f "$age_file" "${age_file}.tmp."* 2>/dev/null || true
  done
}

cleanup_orphan_stale_heartbeat_state() {
  local heartbeat_dir="$1"
  local state_file age_file heartbeat_file

  [[ -d "$heartbeat_dir" ]] || return 0

  for state_file in "$heartbeat_dir"/*.state "$heartbeat_dir"/.*.state; do
    [[ -e "$state_file" ]] || continue
    heartbeat_file="${state_file%.state}.json"
    if [[ ! -f "$heartbeat_file" ]]; then
      rm -f "$state_file" "${state_file}.tmp."* 2>/dev/null || true
      age_file="${state_file%.state}.state-age"
      rm -f "$age_file" "${age_file}.tmp."* 2>/dev/null || true
    fi
  done
  for age_file in "$heartbeat_dir"/*.state-age "$heartbeat_dir"/.*.state-age; do
    [[ -e "$age_file" ]] || continue
    heartbeat_file="${age_file%.state-age}.json"
    [[ -f "$heartbeat_file" ]] || rm -f "$age_file" "${age_file}.tmp."* 2>/dev/null || true
  done
}

check_stale_heartbeats() {
  local run_id="$1" log_base="$2" heartbeat_dir="$3"
  local warn_seconds="${4:-}" error_seconds="${5:-}"
  local resolved_thresholds
  local now_epoch heartbeat_file state_file age_file row
  local domain lens_id pid iteration age_seconds previous_state new_state recovery_age

  [[ -d "$heartbeat_dir" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  if [[ ! "$warn_seconds" =~ ^[0-9]+$ || ! "$error_seconds" =~ ^[0-9]+$ ]]; then
    resolved_thresholds="$(resolve_status_stale_thresholds)"
    read -r warn_seconds error_seconds <<< "$resolved_thresholds"
  else
    warn_seconds=$((10#$warn_seconds))
    error_seconds=$((10#$error_seconds))
    if (( error_seconds <= warn_seconds )); then
      resolved_thresholds="$(resolve_status_stale_thresholds)"
      read -r warn_seconds error_seconds <<< "$resolved_thresholds"
    fi
  fi

  now_epoch="$(date -u +%s)"

  cleanup_orphan_stale_heartbeat_state "$heartbeat_dir"

  for heartbeat_file in "$heartbeat_dir"/*.json; do
    [[ -f "$heartbeat_file" ]] || continue

    row="$(jq -r --argjson now_epoch "$now_epoch" '
      def number_value($fallback):
        if type == "number" then .
        elif type == "string" then (tonumber? // $fallback)
        else $fallback
        end;
      def age_from($now):
        if type == "string" then
          ($now - (try fromdateiso8601 catch $now) | floor) as $age
          | if $age < 0 then 0 else $age end
        else 0
        end;
      select((.domain | type) == "string" and (.lens_id | type) == "string")
      | [
          .domain,
          .lens_id,
          (((.pid // 0) | number_value(0)) | floor | tostring),
          (((.iteration // 0) | number_value(0)) | floor | tostring),
          (((.last_heartbeat_at // "") | age_from($now_epoch)) | tostring)
        ]
      | @tsv
    ' "$heartbeat_file" 2>/dev/null || true)"
    [[ -n "$row" ]] || continue

    IFS=$'\t' read -r domain lens_id pid iteration age_seconds <<< "$row"
    [[ "$pid" =~ ^[0-9]+$ ]] || pid=0
    [[ "$iteration" =~ ^[0-9]+$ ]] || iteration=0
    [[ "$age_seconds" =~ ^[0-9]+$ ]] || age_seconds=0
    pid=$((10#$pid))
    iteration=$((10#$iteration))
    age_seconds=$((10#$age_seconds))

    state_file="$(status_stale_state_path "$heartbeat_file")"
    age_file="$(status_stale_age_path "$heartbeat_file")"
    previous_state="$(status_read_stale_state "$state_file")"
    new_state="$previous_state"

    case "$previous_state" in
      ok)
        if (( age_seconds >= warn_seconds )); then
          status_emit_transition_log "WARN" "$run_id" "$log_base" "[$domain/$lens_id] heartbeat stale — last update ${age_seconds}s ago (pid $pid, iter $iteration)"
          new_state="warn"
        fi
        ;;
      warn)
        if (( age_seconds < warn_seconds )); then
          recovery_age="$(status_read_stale_age "$age_file" "$age_seconds")"
          status_emit_transition_log "INFO" "$run_id" "$log_base" "[$domain/$lens_id] heartbeat recovered after ${recovery_age}s of silence"
          new_state="ok"
        elif (( age_seconds >= error_seconds )); then
          status_emit_transition_log "ERROR" "$run_id" "$log_base" "[$domain/$lens_id] heartbeat silent for ${age_seconds}s — worker likely hung (pid $pid, iter $iteration)"
          new_state="error"
        fi
        ;;
      error)
        if (( age_seconds < warn_seconds )); then
          recovery_age="$(status_read_stale_age "$age_file" "$age_seconds")"
          status_emit_transition_log "INFO" "$run_id" "$log_base" "[$domain/$lens_id] heartbeat recovered after ${recovery_age}s of silence"
          new_state="ok"
        fi
        ;;
    esac

    status_write_stale_state "$state_file" "$new_state" || true
    if [[ "$new_state" == "warn" || "$new_state" == "error" ]]; then
      status_write_stale_age "$age_file" "$age_seconds" || true
    else
      rm -f "$age_file" "${age_file}.tmp."* 2>/dev/null || true
    fi
  done
}

status_updater_loop() {
  local interval="$1"
  local parent_pid="$2"
  local run_id log_base heartbeat_dir warn_seconds error_seconds resolved_thresholds
  shift 2
  local sleep_pid=""

  run_id="${1:-}"
  log_base="${2:-}"
  heartbeat_dir="${3:-}"
  resolved_thresholds="$(resolve_status_stale_thresholds)"
  read -r warn_seconds error_seconds <<< "$resolved_thresholds"

  trap '[[ -n "$sleep_pid" ]] && kill "$sleep_pid" 2>/dev/null; exit 0' TERM INT

  while true; do
    if [[ "$parent_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$parent_pid" 2>/dev/null; then
      exit 0
    fi
    command -p sleep "$interval" &
    sleep_pid=$!
    wait "$sleep_pid" 2>/dev/null || exit 0
    sleep_pid=""
    if [[ "$parent_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$parent_pid" 2>/dev/null; then
      exit 0
    fi
    write_status_snapshot "running" "$@" || true
    check_stale_heartbeats "$run_id" "$log_base" "$heartbeat_dir" "$warn_seconds" "$error_seconds" || true
  done
}

start_status_updater() {
  local run_id="$1" log_base="$2" heartbeat_dir="$3" completed_file="$4" summary_file="$5"
  local project="$6" repo="$7" mode="$8" agent="$9" parallel="${10}" max_parallel="${11}"
  local remote_target="${12:-}" remote_label="${13:-}"
  local interval

  STATUS_LENSES_FILE="$log_base/.status-lenses"
  printf '%s\n' "${LENS_LIST[@]}" > "$STATUS_LENSES_FILE"

  interval="$(resolve_status_interval)"
  cleanup_status_snapshot_temps "$log_base"
  write_status_snapshot "running" "$run_id" "$log_base" "$heartbeat_dir" "$completed_file" "$summary_file" "$project" "$repo" "$mode" "$agent" "$parallel" "$max_parallel" "$STATUS_LENSES_FILE" "$remote_target" "$remote_label" || true

  local updater_cmd=(bash -c '
    if [[ -n "${REPOLENS_RUN_LOCK_FD:-}" ]]; then
      exec {REPOLENS_RUN_LOCK_FD}>&-
      unset REPOLENS_RUN_LOCK_FD
    fi
    source "$1"
    source "$2"
    init_logging "$5" "$6"
    shift 2
    status_updater_loop "$@"
  ' "repolens-status-updater:$run_id" "$SCRIPT_DIR/lib/status.sh" "$SCRIPT_DIR/lib/logging.sh" \
    "$interval" "$$" "$run_id" "$log_base" "$heartbeat_dir" "$completed_file" "$summary_file" \
    "$project" "$repo" "$mode" "$agent" "$parallel" "$max_parallel" "$STATUS_LENSES_FILE" \
    "$remote_target" "$remote_label")

  if command -v setsid >/dev/null 2>&1; then
    setsid "${updater_cmd[@]}" >/dev/null 2>&1 &
    STATUS_UPDATER_PID="$!"
    STATUS_UPDATER_PGID="$STATUS_UPDATER_PID"
  else
    "${updater_cmd[@]}" >/dev/null 2>&1 &
    STATUS_UPDATER_PID="$!"
    STATUS_UPDATER_PGID=""
  fi

}

stop_status_updater() {
  local final_state="${1:-finished}"

  if [[ "${STATUS_UPDATER_PID:-}" =~ ^[0-9]+$ ]]; then
    if [[ "${STATUS_UPDATER_PGID:-}" =~ ^[0-9]+$ ]]; then
      kill -TERM -- "-$STATUS_UPDATER_PGID" 2>/dev/null || true
    elif kill -0 "$STATUS_UPDATER_PID" 2>/dev/null; then
      kill "$STATUS_UPDATER_PID" 2>/dev/null || true
    fi
    wait "$STATUS_UPDATER_PID" 2>/dev/null || true

    if [[ "${STATUS_UPDATER_PGID:-}" =~ ^[0-9]+$ ]] && command -v pgrep >/dev/null 2>&1; then
      local i=0
      while pgrep -g "$STATUS_UPDATER_PGID" >/dev/null 2>&1 && (( i < 20 )); do
        sleep 0.05
        i=$((i + 1))
      done
    fi
  fi
  STATUS_UPDATER_PID=""
  STATUS_UPDATER_PGID=""

  if [[ -n "${RUN_ID:-}" && -n "${LOG_BASE:-}" && -n "${HEARTBEAT_DIR:-}" && -n "${completed_lenses_file:-}" && -n "${SUMMARY_FILE:-}" && -n "${STATUS_LENSES_FILE:-}" ]]; then
    write_status_snapshot \
      "$final_state" "${RUN_ID:-}" "${LOG_BASE:-}" "${HEARTBEAT_DIR:-}" "${completed_lenses_file:-}" \
      "${SUMMARY_FILE:-}" "${PROJECT_PATH:-}" "${FORGE_REPO_SLUG:-}" "${MODE:-}" "${AGENT:-}" \
      "${PARALLEL:-}" "${MAX_PARALLEL:-}" "${STATUS_LENSES_FILE:-}" "${REMOTE_TARGET:-}" "${REMOTE_LABEL:-}" || true
  fi

  if [[ -n "${HEARTBEAT_DIR:-}" ]]; then
    cleanup_stale_heartbeat_state "${HEARTBEAT_DIR:-}" || true
  fi
}

status_cmd_usage() {
  cat <<'EOF'
Usage: repolens.sh status [run-id] [OPTIONS]

Print a live RepoLens run snapshot from logs/<run-id>/status.json.

Options:
  --json                    Print status.json verbatim.
  --watch [seconds]         Re-render every N seconds until interrupted (default: 5).
  --stale-after <seconds>   Mark active lenses stale after this heartbeat age (default: 120).
  --no-color                Suppress ANSI color.
  -h, --help                Show status command help.
EOF
}

status_format_duration() {
  local seconds="${1:-0}"
  local days hours minutes remainder

  if [[ ! "$seconds" =~ ^-?[0-9]+$ ]]; then
    seconds=0
  fi
  if (( seconds < 0 )); then
    seconds=0
  fi

  days=$((seconds / 86400))
  hours=$(((seconds % 86400) / 3600))
  minutes=$(((seconds % 3600) / 60))
  remainder=$((seconds % 60))

  if (( days > 0 )); then
    printf '%dd %dh' "$days" "$hours"
  elif (( hours > 0 )); then
    printf '%dh %02dm' "$hours" "$minutes"
  elif (( minutes > 0 )); then
    printf '%dm %02ds' "$minutes" "$remainder"
  else
    printf '%ds' "$remainder"
  fi
}

status_format_iso_utc() {
  local timestamp="${1:-}"

  if [[ "$timestamp" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})Z$ ]]; then
    printf '%s-%s-%s %s:%s:%s UTC' \
      "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" \
      "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}" "${BASH_REMATCH[6]}"
  elif [[ -n "$timestamp" ]]; then
    printf '%s' "$timestamp"
  else
    printf 'unknown'
  fi
}

status_relative_from_iso() {
  local timestamp="${1:-}"
  local seconds

  seconds="$(jq -nr --arg ts "$timestamp" '
    ($ts | fromdateiso8601? // empty) as $epoch
    | if $epoch == "" then empty else ((now - $epoch) | floor) end
  ' 2>/dev/null || true)"

  if [[ ! "$seconds" =~ ^-?[0-9]+$ ]]; then
    printf 'unknown'
    return
  fi
  status_format_duration "$seconds"
}

status_truncate() {
  local value="$1" max_length="$2"

  if (( ${#value} <= max_length )); then
    printf '%s' "$value"
  elif (( max_length > 3 )); then
    printf '%s...' "${value:0:max_length - 3}"
  else
    printf '%s' "${value:0:max_length}"
  fi
}

status_sanitize_display() {
  local value="${1:-}"

  if command -v jq >/dev/null 2>&1; then
    jq -Rrsr 'gsub("[\u0000-\u001f\u007f-\u009f]"; "")' <<< "$value" 2>/dev/null && return
  fi

  LC_ALL=C printf '%s' "$value" | tr -d '[:cntrl:]'
}

status_available_runs() {
  local limit="${1:-10}"
  local logs_dir="${SCRIPT_DIR:-.}/logs"
  local dir newest_dir newest_status status_file count=0
  local -a pending=()

  [[ -d "$logs_dir" ]] || return 0

  for dir in "$logs_dir"/*; do
    [[ -d "$dir" && -f "$dir/status.json" ]] || continue
    pending+=("$dir")
  done

  while (( ${#pending[@]} > 0 )); do
    newest_dir=""
    newest_status=""
    local -a remaining=()
    for dir in "${pending[@]}"; do
      status_file="$dir/status.json"
      if [[ -z "$newest_status" || "$status_file" -nt "$newest_status" ]]; then
        [[ -n "$newest_dir" ]] && remaining+=("$newest_dir")
        newest_dir="$dir"
        newest_status="$status_file"
      else
        remaining+=("$dir")
      fi
    done

    [[ -n "$newest_dir" ]] || break
    printf '%s\n' "$(status_sanitize_display "${newest_dir##*/}")"
    count=$((count + 1))
    if (( count >= limit )); then
      break
    fi
    pending=("${remaining[@]}")
  done
}

status_print_available_runs() {
  local runs=()
  local run

  mapfile -t runs < <(status_available_runs 10)
  if (( ${#runs[@]} == 0 )); then
    printf 'Available runs: none\n' >&2
    return
  fi

  printf 'Available runs:\n' >&2
  for run in "${runs[@]}"; do
    printf '  %s\n' "$(status_sanitize_display "$run")" >&2
  done
}

status_latest_file() {
  local logs_dir="${SCRIPT_DIR:-.}/logs"
  local dir status_file newest_file=""

  [[ -d "$logs_dir" ]] || return 1

  for dir in "$logs_dir"/*; do
    status_file="$dir/status.json"
    [[ -d "$dir" && -f "$status_file" ]] || continue
    if [[ -z "$newest_file" || "$status_file" -nt "$newest_file" ]]; then
      newest_file="$status_file"
    fi
  done

  [[ -n "$newest_file" ]] || return 1
  printf '%s\n' "$newest_file"
}

status_resolve_file() {
  local run_id="${1:-}"
  local logs_dir="${SCRIPT_DIR:-.}/logs"
  local status_file

  if [[ -n "$run_id" ]]; then
    if [[ "$run_id" == *"/"* || "$run_id" == "." || "$run_id" == ".." ]]; then
      printf "Invalid run id '%s'. Run ids must be direct logs/ children.\n" "$(status_sanitize_display "$run_id")" >&2
      status_print_available_runs
      return 1
    fi

    status_file="$logs_dir/$run_id/status.json"
    if [[ ! -f "$status_file" ]]; then
      printf "No status.json for run '%s'.\n" "$(status_sanitize_display "$run_id")" >&2
      status_print_available_runs
      return 1
    fi

    printf '%s\n' "$status_file"
    return 0
  fi

  if ! status_file="$(status_latest_file)"; then
    printf 'No RepoLens status files found under logs/.\n' >&2
    return 1
  fi
  printf '%s\n' "$status_file"
}

status_validate_json() {
  local status_file="$1"

  if ! jq -e 'type == "object"' "$status_file" >/dev/null 2>&1; then
    printf 'Invalid status.json: %s\n' "$(status_sanitize_display "$status_file")" >&2
    return 1
  fi
}

status_any_stale() {
  local status_file="$1" stale_after="$2"

  jq -e --argjson stale_after "$stale_after" '
    def number_value:
      if type == "number" then .
      elif type == "string" then (tonumber? // 0)
      else 0
      end;
    any(.active[]?; ((.heartbeat_age_seconds // 0) | number_value) > $stale_after)
  ' "$status_file" >/dev/null 2>&1
}

status_render_human() {
  local status_file="$1" stale_after="$2" use_color="$3"
  local meta=()
  local run_id project repo mode agent parallel max_parallel started_at updated_at total_lenses
  local completed_count active_count queued_count issues_created project_display parallel_display
  local remote_target remote_label
  local stale_red color_reset
  local rows=()
  local row lens_key iteration age_seconds heartbeat_age_seconds lens_display marker

  mapfile -t meta < <(jq -r '
    (.run_id // ""),
    (.project // ""),
    (.repo // ""),
    (.mode // ""),
    (.agent // ""),
    (.remote_target // ""),
    (.remote_label // ""),
    ((.parallel // false) | tostring),
    ((.max_parallel // 0) | tostring),
    (.started_at // ""),
    (.updated_at // ""),
    ((.total_lenses // 0) | tostring),
    ((.counts.completed // 0) | tostring),
    ((.counts.active // 0) | tostring),
    ((.counts.queued // 0) | tostring),
    ((.counts.issues_created // 0) | tostring)
  ' "$status_file") || return 1

  if (( ${#meta[@]} < 16 )); then
    printf 'Invalid status.json: missing expected fields in %s\n' "$(status_sanitize_display "$status_file")" >&2
    return 1
  fi

  run_id="$(status_sanitize_display "${meta[0]}")"
  project="$(status_sanitize_display "${meta[1]}")"
  repo="$(status_sanitize_display "${meta[2]}")"
  mode="$(status_sanitize_display "${meta[3]}")"
  agent="$(status_sanitize_display "${meta[4]}")"
  remote_target="$(status_sanitize_display "${meta[5]}")"
  remote_label="$(status_sanitize_display "${meta[6]}")"
  parallel="$(status_sanitize_display "${meta[7]}")"
  max_parallel="$(status_sanitize_display "${meta[8]}")"
  started_at="$(status_sanitize_display "${meta[9]}")"
  updated_at="$(status_sanitize_display "${meta[10]}")"
  total_lenses="$(status_sanitize_display "${meta[11]}")"
  completed_count="$(status_sanitize_display "${meta[12]}")"
  active_count="$(status_sanitize_display "${meta[13]}")"
  queued_count="$(status_sanitize_display "${meta[14]}")"
  issues_created="$(status_sanitize_display "${meta[15]}")"

  project_display="$repo"
  [[ -n "$project_display" ]] || project_display="$project"
  [[ -n "$project_display" ]] || project_display="unknown"

  if [[ "$parallel" == "true" ]]; then
    if [[ "$max_parallel" =~ ^[0-9]+$ && "$max_parallel" -gt 0 ]]; then
      parallel_display="parallel x$max_parallel"
    else
      parallel_display="parallel"
    fi
  else
    parallel_display="sequential"
  fi

  stale_red=""
  color_reset=""
  if [[ "$use_color" == "true" ]]; then
    stale_red=$'\033[31m'
    color_reset=$'\033[0m'
  fi

  printf 'RepoLens run %s\n' "${run_id:-unknown}"
  printf '  project:   %s  (%s, %s, %s)\n' "$project_display" "${mode:-unknown}" "${agent:-unknown}" "$parallel_display"
  if [[ -n "$remote_target" ]]; then
    if [[ -n "$remote_label" ]]; then
      printf '  Remote target: %s (%s)\n' "$remote_target" "$remote_label"
    else
      printf '  Remote target: %s\n' "$remote_target"
    fi
  fi
  printf '  started:   %s  (%s ago)\n' "$(status_format_iso_utc "$started_at")" "$(status_relative_from_iso "$started_at")"
  printf '  updated:   %s  (%s ago)\n' "$(status_format_iso_utc "$updated_at")" "$(status_relative_from_iso "$updated_at")"
  printf '  progress:  %s/%s completed  |  %s active  |  %s queued  |  %s issues created\n' \
    "$completed_count" "$total_lenses" "$active_count" "$queued_count" "$issues_created"
  printf '\n'
  printf 'Active lenses:\n'

  mapfile -t rows < <(jq -r '
    def number_value:
      if type == "number" then .
      elif type == "string" then (tonumber? // 0)
      else 0
      end;
    .active[]?
    | [
        (((.domain // "") | tostring) + "/" + ((.lens_id // "") | tostring)),
        (((.iteration // 0) | number_value) | tostring),
        (((.age_seconds // 0) | number_value | floor) | tostring),
        (((.heartbeat_age_seconds // 0) | number_value | floor) | tostring)
      ]
    | @tsv
  ' "$status_file") || return 1

  if (( ${#rows[@]} == 0 )); then
    printf '  No active lenses.\n'
    return 0
  fi

  for row in "${rows[@]}"; do
    IFS=$'\t' read -r lens_key iteration age_seconds heartbeat_age_seconds <<< "$row"
    lens_key="$(status_sanitize_display "$lens_key")"
    iteration="$(status_sanitize_display "$iteration")"
    age_seconds="$(status_sanitize_display "$age_seconds")"
    heartbeat_age_seconds="$(status_sanitize_display "$heartbeat_age_seconds")"
    lens_display="$(status_truncate "$lens_key" 26)"
    marker=""
    if [[ "$heartbeat_age_seconds" =~ ^[0-9]+$ && "$heartbeat_age_seconds" -gt "$stale_after" ]]; then
      marker="   ${stale_red}[STALE?]${color_reset}"
    fi
    printf '  %-26s  iter %-3s running %s   hb %s ago%s\n' \
      "$lens_display" "${iteration:-0}" "$(status_format_duration "${age_seconds:-0}")" \
      "$(status_format_duration "${heartbeat_age_seconds:-0}")" "$marker"
  done
}

status_render_once() {
  local status_file="$1" raw_json="$2" stale_after="$3" use_color="$4"

  status_validate_json "$status_file" || return 1

  if [[ "$raw_json" == "true" ]]; then
    cat "$status_file" || return 1
  else
    status_render_human "$status_file" "$stale_after" "$use_color" || return 1
  fi

  if status_any_stale "$status_file" "$stale_after"; then
    return 2
  fi
  return 0
}

status_command() {
  local run_id="" raw_json=false watch=false watch_interval=5 stale_after=120 no_color=false
  local status_file use_color=false rc

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json)
        raw_json=true
        shift
        ;;
      --watch)
        watch=true
        shift
        if [[ $# -gt 0 && "$1" != --* && "$1" =~ ^[0-9]+$ ]]; then
          watch_interval=$((10#$1))
          shift
        fi
        if (( watch_interval <= 0 )); then
          printf 'Invalid --watch interval: must be a positive integer.\n' >&2
          return 1
        fi
        ;;
      --stale-after)
        if [[ $# -lt 2 || ! "$2" =~ ^[0-9]+$ ]]; then
          printf 'Invalid --stale-after: must be a non-negative integer.\n' >&2
          return 1
        fi
        stale_after=$((10#$2))
        shift 2
        ;;
      --no-color)
        no_color=true
        shift
        ;;
      -h|--help)
        status_cmd_usage
        return 0
        ;;
      --*)
        printf 'Unknown status option: %s\n' "$(status_sanitize_display "$1")" >&2
        status_cmd_usage >&2
        return 1
        ;;
      *)
        if [[ -n "$run_id" ]]; then
          printf 'Unexpected status argument: %s\n' "$(status_sanitize_display "$1")" >&2
          status_cmd_usage >&2
          return 1
        fi
        run_id="$1"
        shift
        ;;
    esac
  done

  if ! command -v jq >/dev/null 2>&1; then
    printf 'ERROR: status requires jq to read status.json.\n' >&2
    return 1
  fi

  status_file="$(status_resolve_file "$run_id")" || return 1

  if [[ "$no_color" == "false" && -t 1 ]]; then
    use_color=true
  fi

  if [[ "$watch" == "true" ]]; then
    trap 'printf "\n"; exit 0' INT
    trap 'exit 0' TERM
    while true; do
      status_render_once "$status_file" "$raw_json" "$stale_after" "$use_color"
      rc=$?
      if (( rc == 1 )); then
        return 1
      fi
      printf '\n'
      sleep "$watch_interval" || return 0
    done
  fi

  status_render_once "$status_file" "$raw_json" "$stale_after" "$use_color"
}
