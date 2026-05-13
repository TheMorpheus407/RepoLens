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

# RepoLens - round-aware lens execution driver

# run_rounds <rounds_total> <lens_list_array_name>
#   Runs the current per-lens dispatch path for rounds 1..rounds_total.
#   The second argument is the name of a Bash array, for example LENS_LIST.
#   This deliberately avoids Bash namerefs so the module stays compatible
#   with the project's Bash 4 baseline.
#
#   Required globals are provided by repolens.sh when R4 wires this in:
#   PARALLEL, MAX_PARALLEL, LOG_BASE, SUMMARY_FILE, MAX_ISSUES,
#   GLOBAL_ISSUES_CREATED, and TOTAL_LENSES.
#
#   R1 only validates the round count; it does not define per-round issue
#   budgets. Keep GLOBAL_ISSUES_CREATED cumulative across rounds until that
#   contract changes.

declare -A META_ORCH_TEMPLATE_BY_MODE=(
  [discover]="meta_orchestrator_discover.md"
  [content]="meta_orchestrator_content.md"
)

_rounds_valid_array_name() {
  local name="$1"
  [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

_rounds_nonnegative_integer() {
  local value="$1"
  [[ "$value" =~ ^[0-9]+$ ]]
}

_rounds_positive_integer() {
  local value="$1"
  [[ "$value" =~ ^[1-9][0-9]*$ ]]
}

round_dir() {
  local round_number="${2:-}" base="${LOG_BASE:-}"

  if [[ -z "$base" || -z "$round_number" ]]; then
    return 2
  fi

  printf '%s/rounds/round-%s' "$base" "$round_number"
}

round_lens_outputs_dir() {
  local run_id="${1:-}" round_number="${2:-}" dir
  dir="$(round_dir "$run_id" "$round_number")" || return $?
  printf '%s/lens-outputs' "$dir"
}

round_digest_path() {
  local run_id="${1:-}" round_number="${2:-}" dir
  dir="$(round_dir "$run_id" "$round_number")" || return $?
  printf '%s/digest.md' "$dir"
}

round_prior_digest_path() {
  local run_id="${1:-}" round_number="${2:-}" dir
  dir="$(round_dir "$run_id" "$round_number")" || return $?
  printf '%s/prior-round-digest.md' "$dir"
}

round_hypotheses_path() {
  local run_id="${1:-}" round_number="${2:-}" dir
  dir="$(round_dir "$run_id" "$round_number")" || return $?
  printf '%s/hypotheses.md' "$dir"
}

round_metadata_path() {
  local run_id="${1:-}" round_number="${2:-}" dir
  dir="$(round_dir "$run_id" "$round_number")" || return $?
  printf '%s/metadata.json' "$dir"
}

round_completed_marker() {
  local run_id="${1:-}" round_number="${2:-}" dir
  dir="$(round_dir "$run_id" "$round_number")" || return $?
  printf '%s/.completed' "$dir"
}

final_dir() {
  local base="${LOG_BASE:-}"
  if [[ -z "$base" ]]; then
    return 2
  fi

  printf '%s/final' "$base"
}

final_filed_dir() {
  local run_id="${1:-}" dir
  dir="$(final_dir "$run_id")" || return $?
  printf '%s/filed' "$dir"
}

_rounds_legacy_marker_path() {
  local round="$1"
  printf '%s/.rounds/round-%s.completed\n' "$LOG_BASE" "$round"
}

_rounds_lens_completion_path() {
  local round="$1"
  printf '%s/.rounds/round-%s.lenses.completed\n' "$LOG_BASE" "$round"
}

_rounds_restore_completed_lenses_file() {
  local had_completed_file="$1" original_completed_file="$2"

  if (( had_completed_file )); then
    completed_lenses_file="$original_completed_file"
  else
    unset completed_lenses_file
  fi
}

_rounds_all_lenses_completed() {
  local completion_file="$1"
  shift
  local lens_entry

  [[ -n "$completion_file" && -f "$completion_file" ]] || return 1

  for lens_entry in "$@"; do
    grep -qxF "$lens_entry" "$completion_file" 2>/dev/null || return 1
  done

  return 0
}

write_round_metadata() {
  local run_id="$1" round_number="$2" breadth="$3" rounds_total="$4"
  shift 4
  local metadata_path metadata_dir tmp_metadata start_ts lens_count lens_ids_json
  local -a lens_ids=("$@")

  if ! _rounds_positive_integer "$round_number" \
      || ! _rounds_nonnegative_integer "$breadth" \
      || ! _rounds_positive_integer "$rounds_total"; then
    return 2
  fi

  metadata_path="$(round_metadata_path "$run_id" "$round_number")" || return $?
  metadata_dir="${metadata_path%/*}"
  mkdir -p "$metadata_dir" || return 1

  start_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  lens_count="${#lens_ids[@]}"
  if (( lens_count > 0 )); then
    lens_ids_json="$(printf '%s\n' "${lens_ids[@]}" | jq -R . | jq -s .)" || return 1
  else
    lens_ids_json='[]'
  fi

  tmp_metadata="${metadata_path}.tmp.$$"
  if ! jq -n \
      --arg start_ts "$start_ts" \
      --argjson round_number "$round_number" \
      --argjson breadth "$breadth" \
      --argjson rounds_total "$rounds_total" \
      --argjson lens_count "$lens_count" \
      --argjson lens_ids "$lens_ids_json" \
      '{
        round_number: $round_number,
        breadth: $breadth,
        rounds_total: $rounds_total,
        start_ts: $start_ts,
        lens_count: $lens_count,
        lens_ids: $lens_ids
      }' > "$tmp_metadata"; then
    rm -f "$tmp_metadata"
    return 1
  fi

  mv "$tmp_metadata" "$metadata_path"
}

init_round_layout() {
  local run_id="$1" round_number="$2" breadth="$3" rounds_total="$4"
  shift 4
  local round_path lens_outputs_path metadata_path
  local -a lens_ids=("$@")

  round_path="$(round_dir "$run_id" "$round_number")" || return $?
  lens_outputs_path="$(round_lens_outputs_dir "$run_id" "$round_number")" || return $?
  metadata_path="$(round_metadata_path "$run_id" "$round_number")" || return $?

  mkdir -p "$round_path" "$lens_outputs_path" || return 1
  if [[ ! -f "$metadata_path" ]]; then
    write_round_metadata "$run_id" "$round_number" "$breadth" "$rounds_total" "${lens_ids[@]}" || return $?
  fi
}

init_run_layout() {
  local run_id="$1" rounds_total="$2"
  shift 2
  local breadth round final_path filed_path
  local -a lens_ids=()

  if ! _rounds_positive_integer "$rounds_total"; then
    return 2
  fi

  if (( $# > 0 )) && _rounds_nonnegative_integer "$1"; then
    breadth="$1"
    shift
    lens_ids=("$@")
  else
    lens_ids=("$@")
    breadth="${#lens_ids[@]}"
  fi

  final_path="$(final_dir "$run_id")" || return $?
  filed_path="$(final_filed_dir "$run_id")" || return $?
  mkdir -p "$final_path" "$filed_path" || return 1

  for (( round = 1; round <= rounds_total; round++ )); do
    init_round_layout "$run_id" "$round" "$breadth" "$rounds_total" "${lens_ids[@]}" || return $?
  done
}

_rounds_best_effort_sync() {
  local path="$1"

  if command -v sync >/dev/null 2>&1; then
    sync -d "$path" >/dev/null 2>&1 || sync "$path" >/dev/null 2>&1 || true
  fi
}

finalize_round() {
  local run_id round_number
  if (( $# == 1 )); then
    run_id="${RUN_ID:-}"
    round_number="$1"
  else
    run_id="$1"
    round_number="$2"
  fi

  local metadata_path marker marker_dir tmp_metadata tmp_marker end_ts

  if ! _rounds_positive_integer "$round_number"; then
    return 2
  fi

  metadata_path="$(round_metadata_path "$run_id" "$round_number")" || return $?
  marker="$(round_completed_marker "$run_id" "$round_number")" || return $?
  marker_dir="${marker%/*}"
  mkdir -p "$marker_dir" || return 1

  end_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  tmp_metadata="${metadata_path}.tmp.$$"
  if [[ -f "$metadata_path" ]]; then
    if ! jq --arg end_ts "$end_ts" '. + {end_ts: $end_ts}' "$metadata_path" > "$tmp_metadata"; then
      rm -f "$tmp_metadata"
      return 1
    fi
  else
    if ! jq -n \
        --arg end_ts "$end_ts" \
        --argjson round_number "$round_number" \
        '{
          round_number: $round_number,
          breadth: 0,
          rounds_total: $round_number,
          start_ts: $end_ts,
          end_ts: $end_ts,
          lens_count: 0,
          lens_ids: []
        }' > "$tmp_metadata"; then
      rm -f "$tmp_metadata"
      return 1
    fi
  fi
  mv "$tmp_metadata" "$metadata_path" || return 1

  tmp_marker="${marker}.tmp.$$"
  if ! printf '%s\n' "$end_ts" > "$tmp_marker"; then
    rm -f "$tmp_marker"
    return 1
  fi
  mv "$tmp_marker" "$marker" || return 1
  _rounds_best_effort_sync "$marker"
  _rounds_best_effort_sync "$marker_dir"
}

is_round_completed() {
  local run_id round marker legacy_marker
  if (( $# >= 2 )); then
    run_id="$1"
    round="$2"
    marker="$(round_completed_marker "$run_id" "$round")" || return $?
    [[ -f "$marker" ]]
    return
  fi

  round="$1"
  marker="$(round_completed_marker "${RUN_ID:-}" "$round")" || return $?
  legacy_marker="$(_rounds_legacy_marker_path "$round")"
  [[ -f "$marker" || -f "$legacy_marker" ]]
}

mark_round_completed() {
  local run_id round legacy_marker legacy_marker_dir
  if (( $# >= 2 )); then
    finalize_round "$1" "$2"
    return $?
  fi

  run_id="${RUN_ID:-}"
  round="$1"
  finalize_round "$run_id" "$round" || return $?

  legacy_marker="$(_rounds_legacy_marker_path "$round")"
  legacy_marker_dir="${legacy_marker%/*}"
  mkdir -p "$legacy_marker_dir" || return 1
  : > "$legacy_marker" || return 1
  _rounds_best_effort_sync "$legacy_marker"
  _rounds_best_effort_sync "$legacy_marker_dir"
}

run_meta_orchestrator() {
  local prev_arg="$1" next_arg="$2"
  local run_id="${RUN_ID:-}" repo_root prev_round_dir next_round_dir
  local round next_round digest_path dispatch_path hypotheses_path
  local prompt_path output_path template_name template_file project_path prompt vars
  local agent_rc=0

  if [[ "$prev_arg" == */* ]]; then
    prev_round_dir="$prev_arg"
    round="$(_rounds_meta_round_number_from_dir "$prev_round_dir")"
  else
    round="$prev_arg"
    prev_round_dir="$(round_dir "$run_id" "$round")" || return $?
  fi

  if [[ "$next_arg" == */* ]]; then
    next_round_dir="$next_arg"
    next_round="$(_rounds_meta_round_number_from_dir "$next_round_dir")"
  else
    next_round="$next_arg"
    next_round_dir="$(round_dir "$run_id" "$next_round")" || return $?
  fi

  [[ -n "$round" ]] || round="${CURRENT_ROUND_INDEX:-1}"
  [[ -n "$next_round" ]] || next_round="$((round + 1))"

  repo_root="$(_rounds_repo_root)"
  digest_path="$prev_round_dir/digest.md"
  dispatch_path="$prev_round_dir/dispatch.md"
  hypotheses_path="$prev_round_dir/hypotheses.md"
  prompt_path="$prev_round_dir/meta-orchestrator-prompt.md"
  output_path="$prev_round_dir/meta-orchestrator-output.txt"
  template_name="$(_rounds_meta_template_name_for_mode "${MODE:-}")"
  template_file="${BASE_PROMPTS_DIR:-$repo_root/prompts/_base}/$template_name"
  project_path="${PROJECT_PATH:-$repo_root}"

  if ! mkdir -p "$prev_round_dir" "$next_round_dir"; then
    _rounds_meta_warn "Unable to create round directory for meta-orchestrator handoff"
    return 1
  fi
  if [[ ! -f "$template_file" ]]; then
    _rounds_meta_warn "Meta-orchestrator template missing: $template_file"
    return 1
  fi
  if ! declare -F compose_prompt >/dev/null 2>&1; then
    _rounds_meta_warn "compose_prompt is not available for meta-orchestrator prompt rendering"
    return 1
  fi
  if ! declare -F run_agent >/dev/null 2>&1; then
    _rounds_meta_warn "run_agent is not available for meta-orchestrator dispatch"
    return 1
  fi
  if [[ -z "${AGENT:-}" ]]; then
    _rounds_meta_warn "AGENT is not configured for meta-orchestrator dispatch"
    return 1
  fi

  vars="$(_rounds_meta_prompt_vars "$round" "$next_round" "$digest_path" "$project_path")"
  prompt="$(compose_prompt "$template_file" "$template_file" "$vars" "" "${MODE:-audit}")"
  printf '%s\n' "$prompt" > "$prompt_path" || return 1

  log_info "[round $round] Running meta-orchestrator for round $next_round"
  run_agent "$AGENT" "$prompt" "$project_path" "${AGENT_TIMEOUT_SECS:-}" "${AGENT_KILL_GRACE_SECS:-30}" > "$output_path" 2>&1 || agent_rc=$?
  if (( agent_rc != 0 )); then
    _rounds_meta_warn "Meta-orchestrator exited with status $agent_rc"
    return "$agent_rc"
  fi

  if _rounds_meta_no_fresh_angles "$output_path"; then
    _rounds_meta_write_no_fresh_dispatch "$dispatch_path" "$hypotheses_path" || return $?
    log_info "[round $round] Meta-orchestrator reported NO_FRESH_ANGLES"
    return 2
  fi

  _rounds_meta_parse_output "$output_path" "$dispatch_path" "$hypotheses_path" || return $?
  log_info "[round $round] Meta-orchestrator dispatch written to $dispatch_path"
  return 0
}

_rounds_meta_template_name_for_mode() {
  local mode="${1:-}"

  if [[ -n "$mode" && -n "${META_ORCH_TEMPLATE_BY_MODE[$mode]+x}" ]]; then
    printf '%s\n' "${META_ORCH_TEMPLATE_BY_MODE[$mode]}"
  else
    printf '%s\n' "meta_orchestrator.md"
  fi
}

_rounds_repo_root() {
  local rounds_lib_dir
  rounds_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s\n' "${rounds_lib_dir%/lib}"
}

_rounds_meta_warn() {
  if declare -F log_warn >/dev/null 2>&1; then
    log_warn "$*"
  else
    printf 'WARN: %s\n' "$*" >&2
  fi
}

_rounds_meta_trim() {
  local value="$*"

  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "$value"
}

_rounds_meta_prompt_escape_value() {
  local value="$1"

  value="${value//\\/\\\\}"
  value="${value//|/\\|}"
  printf '%s' "$value"
}

_rounds_meta_slug() {
  local value="$*"

  value="$(_rounds_meta_trim "$value")"
  printf '%s\n' "$value" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E \
        -e 's/[^a-z0-9]+/-/g' \
        -e 's/-+/-/g' \
        -e 's/^-+//' \
        -e 's/-+$//'
}

_rounds_meta_custom_category_from_payload() {
  local payload="$1" line trimmed category

  while IFS= read -r line || [[ -n "$line" ]]; do
    trimmed="$(_rounds_meta_trim "$line")"
    [[ -n "$trimmed" ]] || continue
    if [[ "$trimmed" =~ ^-?[[:space:]]*CUSTOM:[[:space:]]*(.+)$ ]]; then
      category="${BASH_REMATCH[1]}"
      if [[ "$category" =~ ^(.+)[[:space:]]-[[:space:]] ]]; then
        category="${BASH_REMATCH[1]}"
      fi
      _rounds_meta_trim "$category"
      return 0
    fi
    break
  done <<< "$payload"

  return 1
}

_rounds_meta_dispatch_boundary() {
  local trimmed="$1"

  [[ "$trimmed" =~ ^-?[[:space:]]*(LENS|CUSTOM):[[:space:]]* ]] \
    || [[ "$trimmed" =~ ^#*[[:space:]]*HYPOTHESES[_[:space:]-]*TO[_[:space:]-]*VERIFY[[:space:]]*:?[[:space:]]* ]] \
    || [[ "$trimmed" =~ ^#{1,6}[[:space:]]+ ]]
}

_rounds_meta_round_number_from_dir() {
  local dir="$1" base

  base="$(basename "$dir")"
  if [[ "$base" =~ ^round-([0-9]+)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  fi
}

_rounds_meta_prompt_vars() {
  local round="$1" next_round="$2" digest_path="$3" project_path="$4"
  local round_total original_scope between_round_task coverage_dimension prior_output_anchor

  round_total="${CURRENT_ROUND_TOTAL:-${ROUND_TOTAL:-$next_round}}"
  original_scope="${ORIGINAL_BUG_REPORT_OR_SCOPE:-}"
  if [[ -z "$original_scope" ]]; then
    if [[ "${MODE:-}" == "bugreport" && -n "${BUG_REPORT:-}" ]]; then
      original_scope="$BUG_REPORT"
    elif [[ -n "${CHANGE_STATEMENT:-}" ]]; then
      original_scope="$CHANGE_STATEMENT"
    elif [[ -n "${SPEC_FILE:-}" ]]; then
      original_scope="Use the configured spec file as the original scope."
    else
      original_scope="Continue the configured ${MODE:-audit} investigation for this repository."
    fi
  fi

  case "${MODE:-audit}" in
    feature|discover)
      between_round_task="${BETWEEN_ROUND_TASK:-find fresh product, feature, and workflow angles for the next round}"
      coverage_dimension="${COVERAGE_DIMENSION:-product and workflow coverage}"
      prior_output_anchor="${PRIOR_OUTPUT_ANCHOR:-prior discovery output}"
      ;;
    bugfix)
      between_round_task="${BETWEEN_ROUND_TASK:-find fresh bug-hunting angles for the next round}"
      coverage_dimension="${COVERAGE_DIMENSION:-failure mode and defect coverage}"
      prior_output_anchor="${PRIOR_OUTPUT_ANCHOR:-prior bug findings}"
      ;;
    bugreport)
      between_round_task="${BETWEEN_ROUND_TASK:-find fresh symptom-causation angles for the next round}"
      coverage_dimension="${COVERAGE_DIMENSION:-symptom causation coverage}"
      prior_output_anchor="${PRIOR_OUTPUT_ANCHOR:-prior bug-report findings}"
      ;;
    deploy)
      between_round_task="${BETWEEN_ROUND_TASK:-find fresh deployment and operations audit angles for the next round}"
      coverage_dimension="${COVERAGE_DIMENSION:-deployment surface coverage}"
      prior_output_anchor="${PRIOR_OUTPUT_ANCHOR:-prior deployment findings}"
      ;;
    opensource)
      between_round_task="${BETWEEN_ROUND_TASK:-find fresh open-source readiness angles for the next round}"
      coverage_dimension="${COVERAGE_DIMENSION:-readiness and release-risk coverage}"
      prior_output_anchor="${PRIOR_OUTPUT_ANCHOR:-prior readiness findings}"
      ;;
    content)
      between_round_task="${BETWEEN_ROUND_TASK:-find fresh content quality angles for the next round}"
      coverage_dimension="${COVERAGE_DIMENSION:-content coverage}"
      prior_output_anchor="${PRIOR_OUTPUT_ANCHOR:-prior content findings}"
      ;;
    custom)
      between_round_task="${BETWEEN_ROUND_TASK:-find fresh change-impact angles for the next round}"
      coverage_dimension="${COVERAGE_DIMENSION:-change-impact coverage}"
      prior_output_anchor="${PRIOR_OUTPUT_ANCHOR:-prior change-impact findings}"
      ;;
    *)
      between_round_task="${BETWEEN_ROUND_TASK:-find fresh audit angles for the next round}"
      coverage_dimension="${COVERAGE_DIMENSION:-code audit coverage}"
      prior_output_anchor="${PRIOR_OUTPUT_ANCHOR:-prior audit findings}"
      ;;
  esac

  printf 'PROJECT_PATH=%s' "$(_rounds_meta_prompt_escape_value "$project_path")"
  printf '|REPO_OWNER=%s' "$(_rounds_meta_prompt_escape_value "${REPO_OWNER:-local}")"
  printf '|REPO_NAME=%s' "$(_rounds_meta_prompt_escape_value "${REPO_NAME:-$(basename "$project_path")}")"
  printf '|MODE=%s' "$(_rounds_meta_prompt_escape_value "${MODE:-audit}")"
  printf '|RUN_ID=%s' "$(_rounds_meta_prompt_escape_value "${RUN_ID:-}")"
  printf '|ROUND_INDEX=%s' "$(_rounds_meta_prompt_escape_value "$round")"
  printf '|ROUND_INDEX+1=%s' "$(_rounds_meta_prompt_escape_value "$next_round")"
  printf '|ROUND_TOTAL=%s' "$(_rounds_meta_prompt_escape_value "$round_total")"
  printf '|PRIOR_ROUND_DIGEST=@%s' "$(_rounds_meta_prompt_escape_value "$digest_path")"
  printf '|ORIGINAL_BUG_REPORT_OR_SCOPE=%s' "$(_rounds_meta_prompt_escape_value "$original_scope")"
  printf '|BETWEEN_ROUND_TASK=%s' "$(_rounds_meta_prompt_escape_value "$between_round_task")"
  printf '|COVERAGE_DIMENSION=%s' "$(_rounds_meta_prompt_escape_value "$coverage_dimension")"
  printf '|PRIOR_OUTPUT_ANCHOR=%s' "$(_rounds_meta_prompt_escape_value "$prior_output_anchor")"
}

_rounds_meta_lenses_dir() {
  local repo_root
  repo_root="$(_rounds_repo_root)"
  printf '%s\n' "${LENSES_DIR:-$repo_root/prompts/lenses}"
}

_rounds_meta_domains_file() {
  local repo_root
  repo_root="$(_rounds_repo_root)"
  printf '%s\n' "${DOMAINS_FILE:-$repo_root/config/domains.json}"
}

_rounds_meta_active_lens_entries() {
  local lenses_dir="${1:-}" domains_file="${2:-}" mode deploy_domain entry

  [[ -n "$lenses_dir" ]] || lenses_dir="$(_rounds_meta_lenses_dir)"
  [[ -n "$domains_file" ]] || domains_file="$(_rounds_meta_domains_file)"
  [[ -d "$lenses_dir" && -f "$domains_file" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1

  mode="${MODE:-audit}"
  deploy_domain="deployment"
  if [[ "$mode" == "deploy" && "${TARGET_TYPE:-server}" == "android" ]]; then
    deploy_domain="android"
  fi

  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    if [[ -n "${FOCUS:-}" && "${entry#*/}" != "$FOCUS" ]]; then
      continue
    fi
    if [[ -n "${DOMAIN_FILTER:-}" && "${entry%%/*}" != "$DOMAIN_FILTER" ]]; then
      continue
    fi
    if [[ -f "$lenses_dir/$entry.md" ]]; then
      printf '%s\n' "$entry"
    fi
  done < <(
    jq -r --arg mode "$mode" --arg deploy_domain "$deploy_domain" \
      '.domains | sort_by(.order)[] | (if $mode == "discover" then select(.mode == "discover") elif $mode == "deploy" then select(.mode == "deploy" and .id == $deploy_domain) elif $mode == "opensource" then select(.mode == "opensource") elif $mode == "content" then select(.mode == "content") else select(.mode != "discover" and .mode != "deploy" and .mode != "opensource" and .mode != "content") end) | .id as $d | .lenses[] | $d + "/" + .' "$domains_file"
  )
}

_rounds_meta_validate_lens_id() {
  local lens_id="$1" lenses_dir="${2:-}"

  [[ "$lens_id" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  _rounds_meta_lens_entry_for_id "$lens_id" "$lenses_dir" >/dev/null
}

_rounds_meta_lens_entry_for_id() {
  local lens_id="$1" lenses_dir="${2:-}" entry

  [[ -n "$lenses_dir" ]] || lenses_dir="$(_rounds_meta_lenses_dir)"
  [[ "$lens_id" =~ ^[A-Za-z0-9_-]+$ && -d "$lenses_dir" ]] || return 1

  while IFS= read -r entry; do
    [[ "${entry#*/}" == "$lens_id" ]] || continue
    printf '%s\n' "$entry"
    return 0
  done < <(_rounds_meta_active_lens_entries "$lenses_dir" || true)

  return 1
}

_rounds_meta_dispatch_lens_entries() {
  local dispatch_file="$1" lenses_dir="${2:-}" line trimmed lens_id lens_entry
  local -A seen_entries=()

  [[ -f "$dispatch_file" ]] || return 0
  [[ -n "$lenses_dir" ]] || lenses_dir="$(_rounds_meta_lenses_dir)"

  while IFS= read -r line || [[ -n "$line" ]]; do
    trimmed="$(_rounds_meta_trim "$line")"
    if [[ "$trimmed" =~ ^-?[[:space:]]*LENS:[[:space:]]*([A-Za-z0-9_-]+)([[:space:]]+-[[:space:]].*)?$ ]]; then
      lens_id="${BASH_REMATCH[1]}"
      if lens_entry="$(_rounds_meta_lens_entry_for_id "$lens_id" "$lenses_dir")"; then
        if [[ -z "${seen_entries[$lens_entry]:-}" ]]; then
          seen_entries["$lens_entry"]=1
          printf '%s\n' "$lens_entry"
        fi
      else
        _rounds_meta_warn "Skipping invalid dispatched lens id: $lens_id"
      fi
    fi
  done < "$dispatch_file"
}

_rounds_meta_write_custom_lens() {
  local custom_lenses_dir="$1" payload="$2" index="$3"
  local category slug lens_dir lens_file

  category="$(_rounds_meta_custom_category_from_payload "$payload")" || return 1
  slug="$(_rounds_meta_slug "$category")"
  [[ -n "$slug" ]] || slug="custom-$index"
  lens_dir="$custom_lenses_dir/custom"
  lens_file="$lens_dir/$slug.md"

  mkdir -p "$lens_dir" || return 1
  {
    printf -- '---\n'
    printf 'id: %s\n' "$slug"
    printf 'domain: custom\n'
    printf 'name: Custom %s\n' "$slug"
    printf 'role: meta-orchestrator custom follow-up\n'
    printf -- '---\n'
    printf '## Your Expert Focus\n\n'
    printf 'Category: %s\n\n' "$category"
    printf '%s\n' "$payload"
  } > "$lens_file" || return 1

  printf 'custom/%s\n' "$slug"
}

_rounds_meta_dispatch_custom_entries() {
  local dispatch_file="$1" custom_lenses_dir="$2"
  local line trimmed payload="" custom_entry index=0
  local in_custom=0
  local -A seen_entries=()

  [[ -f "$dispatch_file" ]] || return 0
  [[ -n "$custom_lenses_dir" ]] || return 1

  while IFS= read -r line || [[ -n "$line" ]]; do
    trimmed="$(_rounds_meta_trim "$line")"
    if (( in_custom )) && _rounds_meta_dispatch_boundary "$trimmed"; then
      index=$((index + 1))
      if custom_entry="$(_rounds_meta_write_custom_lens "$custom_lenses_dir" "$payload" "$index")"; then
        if [[ -z "${seen_entries[$custom_entry]:-}" ]]; then
          seen_entries["$custom_entry"]=1
          printf '%s\n' "$custom_entry"
        fi
      fi
      payload=""
      in_custom=0
    fi

    if [[ "$trimmed" =~ ^-?[[:space:]]*CUSTOM:[[:space:]]*(.+)$ ]]; then
      payload="$trimmed"
      in_custom=1
      continue
    fi

    if (( in_custom )); then
      payload+=$'\n'"$line"
    fi
  done < "$dispatch_file"

  if (( in_custom )); then
    index=$((index + 1))
    if custom_entry="$(_rounds_meta_write_custom_lens "$custom_lenses_dir" "$payload" "$index")"; then
      if [[ -z "${seen_entries[$custom_entry]:-}" ]]; then
        seen_entries["$custom_entry"]=1
        printf '%s\n' "$custom_entry"
      fi
    fi
  fi
}

_rounds_meta_dispatch_has_entries() {
  local dispatch_file="$1" line trimmed

  [[ -f "$dispatch_file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    trimmed="$(_rounds_meta_trim "$line")"
    if [[ "$trimmed" =~ ^-?[[:space:]]*(LENS|CUSTOM):[[:space:]]* ]]; then
      return 0
    fi
  done < "$dispatch_file"

  return 1
}

_rounds_meta_no_fresh_angles() {
  local output_file="$1" first_norm last_norm

  if ! declare -F first_word >/dev/null 2>&1 \
      || ! declare -F last_word >/dev/null 2>&1 \
      || ! declare -F normalize_word >/dev/null 2>&1; then
    _rounds_meta_warn "streak helpers are not available for NO_FRESH_ANGLES detection"
    return 1
  fi

  first_norm="$(normalize_word "$(first_word "$output_file")")"
  last_norm="$(normalize_word "$(last_word "$output_file")")"
  [[ "$first_norm" == "NO_FRESH_ANGLES" || "$last_norm" == "NO_FRESH_ANGLES" ]]
}

_rounds_meta_extract_hypotheses() {
  local output_file="$1" hypotheses_file="$2"
  local line trimmed rest in_block=0 tmp_file

  tmp_file="${hypotheses_file}.tmp.$$"
  : > "$tmp_file" || return 1

  while IFS= read -r line || [[ -n "$line" ]]; do
    trimmed="$(_rounds_meta_trim "$line")"

    if (( in_block == 0 )); then
      if [[ "$trimmed" =~ ^#*[[:space:]]*HYPOTHESES[_[:space:]-]*TO[_[:space:]-]*VERIFY[[:space:]]*:?[[:space:]]*(.*)$ ]]; then
        in_block=1
        rest="$(_rounds_meta_trim "${BASH_REMATCH[1]}")"
        [[ -n "$rest" ]] && printf '%s\n' "$rest" >> "$tmp_file"
      fi
      continue
    fi

    if [[ "$trimmed" =~ ^#{1,6}[[:space:]]+ ]] \
        || [[ "$trimmed" =~ ^-?[[:space:]]*(LENS|CUSTOM):[[:space:]]* ]]; then
      break
    fi

    printf '%s\n' "$line" >> "$tmp_file"
  done < "$output_file"

  mv "$tmp_file" "$hypotheses_file"
}

_rounds_meta_parse_output() {
  local output_file="$1" dispatch_file="$2" hypotheses_file="$3" lenses_dir="${4:-}"
  local dispatch_dir hypotheses_dir tmp_dispatch line trimmed lens_id custom_payload custom_category
  local in_custom=0
  local -a lens_ids=() custom_payloads=()
  local -A seen_lenses=() seen_custom=()

  [[ -n "$lenses_dir" ]] || lenses_dir="$(_rounds_meta_lenses_dir)"
  dispatch_dir="${dispatch_file%/*}"
  hypotheses_dir="${hypotheses_file%/*}"
  mkdir -p "$dispatch_dir" "$hypotheses_dir" || return 1

  while IFS= read -r line || [[ -n "$line" ]]; do
    trimmed="$(_rounds_meta_trim "$line")"

    if (( in_custom )) && _rounds_meta_dispatch_boundary "$trimmed"; then
      custom_category="$(_rounds_meta_custom_category_from_payload "$custom_payload")"
      if [[ -n "$custom_category" && -z "${seen_custom[$custom_category]:-}" ]]; then
        seen_custom["$custom_category"]=1
        custom_payloads+=("$custom_payload")
      fi
      custom_payload=""
      in_custom=0
    fi

    if (( in_custom )); then
      custom_payload+=$'\n'"$line"
      continue
    fi

    [[ -n "$trimmed" ]] || continue

    if [[ "$trimmed" =~ ^-?[[:space:]]*LENS:[[:space:]]*([A-Za-z0-9_-]+)([[:space:]]+-[[:space:]].*)?$ ]]; then
      lens_id="${BASH_REMATCH[1]}"
      if _rounds_meta_validate_lens_id "$lens_id" "$lenses_dir"; then
        if [[ -z "${seen_lenses[$lens_id]:-}" ]]; then
          seen_lenses["$lens_id"]=1
          lens_ids+=("$lens_id")
        fi
      else
        _rounds_meta_warn "Dropping hallucinated meta-orchestrator lens id: $lens_id"
      fi
      continue
    fi

    if [[ "$trimmed" =~ ^-?[[:space:]]*CUSTOM:[[:space:]]*(.+)$ ]]; then
      custom_payload="$trimmed"
      in_custom=1
    fi
  done < "$output_file"

  if (( in_custom )); then
    custom_category="$(_rounds_meta_custom_category_from_payload "$custom_payload")"
    if [[ -n "$custom_category" && -z "${seen_custom[$custom_category]:-}" ]]; then
      seen_custom["$custom_category"]=1
      custom_payloads+=("$custom_payload")
    fi
  fi

  tmp_dispatch="${dispatch_file}.tmp.$$"
  {
    printf '# Meta-Orchestrator Dispatch\n\n'
    for lens_id in "${lens_ids[@]}"; do
      printf 'LENS: %s\n' "$lens_id"
    done
    for custom_payload in "${custom_payloads[@]}"; do
      printf '%s\n' "$custom_payload"
    done
  } > "$tmp_dispatch" || {
    rm -f "$tmp_dispatch"
    return 1
  }
  mv "$tmp_dispatch" "$dispatch_file" || return 1

  _rounds_meta_extract_hypotheses "$output_file" "$hypotheses_file"
}

_rounds_meta_write_no_fresh_dispatch() {
  local dispatch_file="$1" hypotheses_file="$2"
  local dispatch_dir hypotheses_dir tmp_dispatch tmp_hypotheses

  dispatch_dir="${dispatch_file%/*}"
  hypotheses_dir="${hypotheses_file%/*}"
  mkdir -p "$dispatch_dir" "$hypotheses_dir" || return 1

  tmp_dispatch="${dispatch_file}.tmp.$$"
  {
    printf '# Meta-Orchestrator Dispatch\n\n'
    printf 'NO_FRESH_ANGLES\n'
  } > "$tmp_dispatch" || {
    rm -f "$tmp_dispatch"
    return 1
  }
  mv "$tmp_dispatch" "$dispatch_file" || return 1

  tmp_hypotheses="${hypotheses_file}.tmp.$$"
  : > "$tmp_hypotheses" || return 1
  mv "$tmp_hypotheses" "$hypotheses_file"
}

_round_digest_warn() {
  if declare -F log_warn >/dev/null 2>&1; then
    log_warn "$*"
  else
    printf 'WARN: %s\n' "$*" >&2
  fi
}

_round_digest_repo_root() {
  local rounds_lib_dir
  rounds_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s\n' "${rounds_lib_dir%/lib}"
}

_round_digest_audit_domains() {
  local domains_file="$1"

  if [[ ! -f "$domains_file" ]]; then
    return 1
  fi

  awk '
    /"id"[[:space:]]*:/ {
      id = $0
      sub(/^.*"id"[[:space:]]*:[[:space:]]*"/, "", id)
      sub(/".*$/, "", id)
      mode = ""
    }
    /"mode"[[:space:]]*:/ {
      mode = $0
      sub(/^.*"mode"[[:space:]]*:[[:space:]]*"/, "", mode)
      sub(/".*$/, "", mode)
    }
    /^[[:space:]]*}[,]?[[:space:]]*$/ {
      if (id != "" && mode != "discover" && mode != "deploy" && mode != "opensource" && mode != "content") {
        print id
      }
      id = ""
      mode = ""
    }
  ' "$domains_file"
}

_round_digest_registered_lenses() {
  local domains_file="$1"

  if [[ ! -f "$domains_file" ]]; then
    return 1
  fi

  awk '
    {
      line = $0
      if (!collecting) {
        if (line !~ /"lenses"[[:space:]]*:/) {
          next
        }
        collecting = 1
        sub(/^.*"lenses"[[:space:]]*:[[:space:]]*/, "", line)
      }

      scan = line
      while (match(scan, /"[^"]+"/)) {
        value = substr(scan, RSTART + 1, RLENGTH - 2)
        if (value != "") {
          print value
        }
        scan = substr(scan, RSTART + RLENGTH)
      }

      if (line ~ /\]/) {
        collecting = 0
      }
    }
  ' "$domains_file"
}

_round_digest_frontmatter_block() {
  local file="$1"

  awk '
    NR == 1 && $0 == "---" {
      in_frontmatter = 1
      next
    }
    NR == 1 {
      exit 1
    }
    in_frontmatter && $0 == "---" {
      found_end = 1
      exit 0
    }
    in_frontmatter {
      print
    }
    END {
      if (!found_end) {
        exit 1
      }
    }
  ' "$file"
}

_round_digest_trim_yaml_value() {
  local value="$*"

  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  value="${value#\"}"
  value="${value%\"}"
  value="${value#\'}"
  value="${value%\'}"
  printf '%s\n' "$value"
}

_round_digest_frontmatter_values() {
  local key="$1"

  awk -v key="$key" '
    function emit(value) {
      sub(/^[[:space:]]*/, "", value)
      sub(/[[:space:]]*$/, "", value)
      if (value != "") {
        print value
      }
    }
    $0 ~ "^[[:space:]]*" key "[[:space:]]*:" {
      collecting = 1
      value = $0
      sub("^[[:space:]]*" key "[[:space:]]*:[[:space:]]*", "", value)
      if (value != "") {
        emit(value)
        exit 0
      }
      next
    }
    collecting && $0 ~ "^[[:space:]]*-[[:space:]]*" {
      value = $0
      sub("^[[:space:]]*-[[:space:]]*", "", value)
      emit(value)
      next
    }
    collecting && $0 ~ "^[A-Za-z0-9_][A-Za-z0-9_-]*[[:space:]]*:" {
      exit 0
    }
  '
}

_round_digest_frontmatter_scalar() {
  local key="$1" value

  value="$(_round_digest_frontmatter_values "$key" | sed -n '1p')"
  _round_digest_trim_yaml_value "$value"
}

_round_digest_sanitize_identifier() {
  local value="$*"

  value="$(_round_digest_trim_yaml_value "$value")"
  printf '%s\n' "$value" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E \
        -e 's/[^a-z0-9]+/-/g' \
        -e 's/-+/-/g' \
        -e 's/^-+//' \
        -e 's/-+$//'
}

_round_digest_normalize_label() {
  _round_digest_sanitize_identifier "$@"
}

_round_digest_rank_lens_categories() {
  local lens="$1" limit="$2" key category count

  for key in "${!_round_digest_lens_category_counts[@]}"; do
    [[ "$key" == "$lens|"* ]] || continue
    category="${key#*|}"
    count="${_round_digest_lens_category_counts[$key]}"
    printf '%s\t%s\n' "$count" "$category"
  done | LC_ALL=C sort -t "$(printf '\t')" -k1,1nr -k2,2 | head -n "$limit" | cut -f2-
}

_round_digest_rank_themes() {
  local limit="$1" category count

  for category in "${!_round_digest_category_counts[@]}"; do
    count="${_round_digest_category_counts[$category]}"
    printf '%s\t%s\n' "$count" "$category"
  done | LC_ALL=C sort -t "$(printf '\t')" -k1,1nr -k2,2 | head -n "$limit"
}

_round_digest_join_lines() {
  local result="" line sanitized

  while IFS= read -r line; do
    sanitized="$(_round_digest_sanitize_identifier "$line")"
    [[ -n "$sanitized" ]] || continue
    if [[ -n "$result" ]]; then
      result+=", "
    fi
    result+="$sanitized"
  done

  printf '%s\n' "${result:-none}"
}

build_round_digest() {
  local round_dir="${1:-}" lens_outputs_dir digest_path repo_root domains_file
  local file frontmatter severity domain lens category normalized category_seen
  local suspect_file audit_domain audit_total coverage_count coverage_domains registered_lens display_lens
  local tmp_digest digest_lines
  local -a md_files=() sorted_lenses=() touched_domains=()
  local -A _round_digest_lens_counts=()
  local -A _round_digest_lens_category_counts=()
  local -A _round_digest_category_counts=()
  local -A _round_digest_touched_domains=()
  local -A _round_digest_audit_domain_set=()
  local -A _round_digest_registered_lens_set=()
  local -A _round_digest_suspect_file_counts=()

  if [[ -z "$round_dir" ]]; then
    _round_digest_warn "build_round_digest requires a round directory"
    return 2
  fi

  if ! mkdir -p "$round_dir"; then
    _round_digest_warn "Unable to create round directory for digest: $round_dir"
    return 1
  fi

  lens_outputs_dir="$round_dir/lens-outputs"
  digest_path="$round_dir/digest.md"
  repo_root="$(_round_digest_repo_root)"
  domains_file="$repo_root/config/domains.json"

  while IFS= read -r audit_domain; do
    [[ -n "$audit_domain" ]] || continue
    _round_digest_audit_domain_set["$audit_domain"]=1
  done < <(_round_digest_audit_domains "$domains_file" || true)
  while IFS= read -r registered_lens; do
    [[ -n "$registered_lens" ]] || continue
    _round_digest_registered_lens_set["$registered_lens"]=1
  done < <(_round_digest_registered_lenses "$domains_file" || true)
  audit_total="${#_round_digest_audit_domain_set[@]}"
  if (( audit_total == 0 )); then
    audit_total=27
  fi

  if [[ -d "$lens_outputs_dir" ]]; then
    mapfile -t md_files < <(find "$lens_outputs_dir" -type f -name '*.md' -print | LC_ALL=C sort)
  fi

  for file in "${md_files[@]}"; do
    if ! frontmatter="$(_round_digest_frontmatter_block "$file")"; then
      _round_digest_warn "Skipping malformed lens output $(basename "$file"): missing or unterminated YAML frontmatter"
      continue
    fi

    severity="$(printf '%s\n' "$frontmatter" | _round_digest_frontmatter_scalar "severity")"
    domain="$(printf '%s\n' "$frontmatter" | _round_digest_frontmatter_scalar "domain")"
    lens="$(printf '%s\n' "$frontmatter" | _round_digest_frontmatter_scalar "lens")"

    if [[ -z "$severity" || -z "$domain" || -z "$lens" ]]; then
      _round_digest_warn "Skipping malformed lens output $(basename "$file"): required frontmatter keys severity, domain, and lens are required"
      continue
    fi
    if [[ -z "${_round_digest_registered_lens_set[$lens]:-}" ]]; then
      _round_digest_warn "Skipping untrusted lens output $(basename "$file"): lens id is not registered"
      continue
    fi

    _round_digest_lens_counts["$lens"]=$(( ${_round_digest_lens_counts["$lens"]:-0} + 1 ))
    if [[ -n "${_round_digest_audit_domain_set[$domain]:-}" ]]; then
      _round_digest_touched_domains["$domain"]=1
    fi

    category_seen=0
    while IFS= read -r category; do
      normalized="$(_round_digest_normalize_label "$category")"
      [[ -n "$normalized" ]] || continue
      category_seen=1
      _round_digest_lens_category_counts["$lens|$normalized"]=$(( ${_round_digest_lens_category_counts["$lens|$normalized"]:-0} + 1 ))
      _round_digest_category_counts["$normalized"]=$(( ${_round_digest_category_counts["$normalized"]:-0} + 1 ))
    done < <(printf '%s\n' "$frontmatter" | _round_digest_frontmatter_values "root_cause_category")

    if (( category_seen == 0 )); then
      _round_digest_lens_category_counts["$lens|uncategorized"]=$(( ${_round_digest_lens_category_counts["$lens|uncategorized"]:-0} + 1 ))
      _round_digest_category_counts["uncategorized"]=$(( ${_round_digest_category_counts["uncategorized"]:-0} + 1 ))
    fi

    while IFS= read -r suspect_file; do
      suspect_file="$(_round_digest_trim_yaml_value "$suspect_file")"
      [[ -n "$suspect_file" ]] || continue
      _round_digest_suspect_file_counts["$suspect_file"]=$(( ${_round_digest_suspect_file_counts["$suspect_file"]:-0} + 1 ))
    done < <(printf '%s\n' "$frontmatter" | _round_digest_frontmatter_values "suspect_files")
  done

  tmp_digest="${digest_path}.tmp.$$"
  {
    printf '# Round Digest\n\n'

    if (( ${#_round_digest_lens_counts[@]} == 0 )); then
      printf 'No findings this round.\n\n'
    else
      mapfile -t sorted_lenses < <(printf '%s\n' "${!_round_digest_lens_counts[@]}" | LC_ALL=C sort)
      printf '## Lens Findings\n'
      for lens in "${sorted_lenses[@]}"; do
        display_lens="$(_round_digest_sanitize_identifier "$lens")"
        [[ -n "$display_lens" ]] || continue
        printf -- '- %s: %s finding' "$display_lens" "${_round_digest_lens_counts[$lens]}"
        if (( ${_round_digest_lens_counts[$lens]} != 1 )); then
          printf 's'
        fi
        printf '; top categories: %s\n' "$(_round_digest_join_lines < <(_round_digest_rank_lens_categories "$lens" 3))"
      done
      printf '\n'

      printf '## Top Themes\n'
      if (( ${#_round_digest_category_counts[@]} == 0 )); then
        printf 'none\n'
      else
        local rank=1 line count theme
        while IFS=$'\t' read -r count theme; do
          theme="$(_round_digest_sanitize_identifier "$theme")"
          [[ -n "$theme" ]] || continue
          printf '%s. %s (%s)\n' "$rank" "$theme" "$count"
          rank=$((rank + 1))
        done < <(_round_digest_rank_themes 3)
      fi
      printf '\n'
    fi

    if (( ${#_round_digest_touched_domains[@]} > 0 )); then
      mapfile -t touched_domains < <(printf '%s\n' "${!_round_digest_touched_domains[@]}" | LC_ALL=C sort)
      coverage_count="${#touched_domains[@]}"
      coverage_domains="$(_round_digest_join_lines < <(printf '%s\n' "${touched_domains[@]}"))"
    else
      coverage_count=0
      coverage_domains="none"
    fi

    printf '## Coverage\n'
    printf 'Touched %s/%s audit domains: %s\n' "$coverage_count" "$audit_total" "$coverage_domains"
  } > "$tmp_digest" || {
    rm -f "$tmp_digest"
    return 1
  }

  digest_lines="$(wc -l < "$tmp_digest" | tr -d '[:space:]')"
  if [[ "$digest_lines" =~ ^[0-9]+$ && "$digest_lines" -gt 500 ]]; then
    head -n 499 "$tmp_digest" > "$digest_path"
    printf 'Digest truncated at 500 lines.\n' >> "$digest_path"
    rm -f "$tmp_digest"
  else
    mv "$tmp_digest" "$digest_path"
  fi
}

_rounds_record_skipped_lenses() {
  local skip_entry skip_domain skip_lens

  for skip_entry in "$@"; do
    skip_domain="${skip_entry%%/*}"
    skip_lens="${skip_entry#*/}"
    if ! is_lens_completed "$skip_entry"; then
      record_lens "$SUMMARY_FILE" "$skip_domain" "$skip_lens" 0 "skipped" 0 0
    fi
  done
}

_rounds_build_prior_digest_context() {
  local run_id="$1" current_round="$2"
  local prior_digest context_path context_dir previous_round digest_path

  if (( current_round <= 1 )); then
    return 2
  fi

  if (( current_round == 2 )); then
    prior_digest="$(round_digest_path "$run_id" 1)" || return $?
    [[ -f "$prior_digest" ]] || return 1
    printf '%s' "$prior_digest"
    return 0
  fi

  context_path="$(round_prior_digest_path "$run_id" "$current_round")" || return $?
  context_dir="${context_path%/*}"
  mkdir -p "$context_dir" || return 1

  : > "$context_path" || return 1
  for previous_round in $(seq 1 "$((current_round - 1))"); do
    digest_path="$(round_digest_path "$run_id" "$previous_round")" || return $?
    [[ -f "$digest_path" ]] || continue
    {
      printf '# Prior Round %s Digest\n\n' "$previous_round"
      cat "$digest_path"
      printf '\n\n'
    } >> "$context_path" || return 1
  done

  [[ -s "$context_path" ]] || return 1
  printf '%s' "$context_path"
}

run_rounds() {
  local rounds_total="$1" lens_list_var="$2"
  local -a lens_list=() active_lens_list=()
  local round lens_entry parallel_count local_count lens_total
  local original_completed_lenses_file had_completed_lenses_file
  local round_completed_lenses_file round_completed_lenses_dir round_rc
  local current_round_dir prior_digest_path previous_hypotheses_path current_hypotheses_path
  local dispatch_path dispatched_lenses_output dispatched_custom_output
  local round_custom_lenses_dir dispatch_has_entries

  if [[ ! "$rounds_total" =~ ^[1-9][0-9]*$ ]]; then
    log_warn "Invalid rounds_total: $rounds_total"
    return 2
  fi
  if ! _rounds_valid_array_name "$lens_list_var"; then
    log_warn "Invalid lens list array name: $lens_list_var"
    return 2
  fi

  eval "lens_list=(\"\${${lens_list_var}[@]}\")"
  lens_total="${TOTAL_LENSES:-${#lens_list[@]}}"

  # shellcheck disable=SC2046 # The issue explicitly requires seq-driven rounds.
  for round in $(seq 1 "$rounds_total"); do
    active_lens_list=("${lens_list[@]}")
    round_custom_lenses_dir=""
    dispatch_has_entries=0
    current_round_dir="$(round_dir "${RUN_ID:-}" "$round")"
    round_rc=$?
    if (( round_rc != 0 )); then
      return "$round_rc"
    fi

    if (( rounds_total > 1 )); then
      dispatch_path=""
      if (( round > 1 )); then
        local previous_round_dir
        previous_round_dir="$(round_dir "${RUN_ID:-}" "$((round - 1))")" || return $?
        dispatch_path="$previous_round_dir/dispatch.md"
      fi
      if [[ -n "$dispatch_path" && -f "$dispatch_path" ]]; then
        dispatched_lenses_output="$(_rounds_meta_dispatch_lens_entries "$dispatch_path")"
        round_custom_lenses_dir="${dispatch_path%/*}/custom-lenses"
        dispatched_custom_output="$(_rounds_meta_dispatch_custom_entries "$dispatch_path" "$round_custom_lenses_dir")"
        if _rounds_meta_dispatch_has_entries "$dispatch_path"; then
          dispatch_has_entries=1
        fi
        if [[ -n "$dispatched_lenses_output" || -n "$dispatched_custom_output" || "$dispatch_has_entries" -eq 1 ]]; then
          active_lens_list=()
          while IFS= read -r lens_entry; do
            [[ -n "$lens_entry" ]] && active_lens_list+=("$lens_entry")
          done <<< "$dispatched_lenses_output"
          while IFS= read -r lens_entry; do
            [[ -n "$lens_entry" ]] && active_lens_list+=("$lens_entry")
          done <<< "$dispatched_custom_output"
          log_info "[round $round/$rounds_total] Using meta-orchestrator dispatch (${#active_lens_list[@]} lens(es))"
        fi
      fi
    fi
    lens_total="${#active_lens_list[@]}"

    if is_round_completed "$round"; then
      round_completed_lenses_file="${completed_lenses_file:-}"
      if (( rounds_total > 1 )); then
        round_completed_lenses_file="$(_rounds_lens_completion_path "$round")"
      fi

      if [[ -n "${RESUME_RUN_ID:-}" ]] \
          && ! _rounds_all_lenses_completed "$round_completed_lenses_file" "${active_lens_list[@]}"; then
        log_info "[round $round/$rounds_total] Completed marker has pending lenses for current selection; resuming"
      else
        log_info "[round $round/$rounds_total] Skipping completed round"
        continue
      fi
    fi

    if [[ -f "$LOG_BASE/.rate-limit-abort" ]]; then
      set_stop_reason "$SUMMARY_FILE" "rate-limited"
      return 1
    fi

    if (( rounds_total > 1 )); then
      log_info "[round $round/$rounds_total] Starting"
    fi

    CURRENT_ROUND_INDEX=""
    CURRENT_ROUND_TOTAL=""
    PRIOR_ROUND_DIGEST_FILE=""
    HYPOTHESES_TO_VERIFY_FILE=""
    CURRENT_ROUND_CUSTOM_LENSES_DIR=""
    CURRENT_ROUND_OUTPUT_DIR="${OUTPUT_DIR:-}"

    if (( rounds_total > 1 )); then
      CURRENT_ROUND_INDEX="$round"
      CURRENT_ROUND_TOTAL="$rounds_total"
      if [[ -n "$round_custom_lenses_dir" && -d "$round_custom_lenses_dir" ]]; then
        # shellcheck disable=SC2034 # Read by prompt rendering during the round.
        CURRENT_ROUND_CUSTOM_LENSES_DIR="$round_custom_lenses_dir"
      fi

      if (( round > 1 )); then
        previous_hypotheses_path="$(round_hypotheses_path "${RUN_ID:-}" "$((round - 1))")" || return $?
        current_hypotheses_path="$(round_hypotheses_path "${RUN_ID:-}" "$round")" || return $?
        # shellcheck disable=SC2034 # Read by prompt rendering during the round.
        prior_digest_path="$(_rounds_build_prior_digest_context "${RUN_ID:-}" "$round")" && PRIOR_ROUND_DIGEST_FILE="$prior_digest_path"
        if [[ -f "$current_hypotheses_path" ]]; then
          # shellcheck disable=SC2034 # Read by prompt rendering during the round.
          HYPOTHESES_TO_VERIFY_FILE="$current_hypotheses_path"
        elif [[ -f "$previous_hypotheses_path" ]]; then
          # shellcheck disable=SC2034 # Read by prompt rendering during the round.
          HYPOTHESES_TO_VERIFY_FILE="$previous_hypotheses_path"
        fi
      fi
    fi

    if ${LOCAL_MODE:-false} && ! ${OUTPUT_DIR_SET:-false}; then
      # shellcheck disable=SC2034 # Read by prompt rendering during the round.
      CURRENT_ROUND_OUTPUT_DIR="$(round_lens_outputs_dir "${RUN_ID:-}" "$round")" || return $?
    fi

    had_completed_lenses_file=0
    original_completed_lenses_file="${completed_lenses_file:-}"
    if [[ ${completed_lenses_file+x} == x ]]; then
      had_completed_lenses_file=1
    fi

    if (( rounds_total > 1 )); then
      round_completed_lenses_file="$(_rounds_lens_completion_path "$round")"
      round_completed_lenses_dir="${round_completed_lenses_file%/*}"
      if ! mkdir -p "$round_completed_lenses_dir" || ! touch "$round_completed_lenses_file"; then
        _rounds_restore_completed_lenses_file "$had_completed_lenses_file" "$original_completed_lenses_file"
        return 1
      fi
      completed_lenses_file="$round_completed_lenses_file"
    fi

    if ${PARALLEL:-false}; then
      log_info "Running in parallel mode (max ${MAX_PARALLEL:-8} concurrent)"
      init_parallel "$LOG_BASE/.semaphore" "${MAX_PARALLEL:-8}"

      parallel_count=0
      for lens_entry in "${active_lens_list[@]}"; do
        # Skip spawning new lenses if a sibling tripped the rate-limit detector.
        # In-flight children continue; the summary still records skipped lenses
        # so --resume picks them up.
        if [[ -f "$LOG_BASE/.rate-limit-abort" ]]; then
          log_warn "Rate-limit abort detected. Skipping remaining lenses."
          _rounds_record_skipped_lenses "${active_lens_list[@]:$parallel_count}"
          set_stop_reason "$SUMMARY_FILE" "rate-limited"
          break
        fi
        parallel_count=$((parallel_count + 1))
        spawn_lens "$lens_entry" run_lens "$lens_entry"
      done

      if ! wait_all; then
        log_warn "Some lenses exited with errors."
      fi

      # Children may have tripped the abort after the spawn loop finished.
      # Make sure the stop_reason is recorded even then.
      if [[ -f "$LOG_BASE/.rate-limit-abort" ]]; then
        set_stop_reason "$SUMMARY_FILE" "rate-limited"
      fi
    else
      log_info "Running in sequential mode"
      local_count=0
      for lens_entry in "${active_lens_list[@]}"; do
        # Check for rate-limit abort from a previous lens in this run.
        if [[ -f "$LOG_BASE/.rate-limit-abort" ]]; then
          log_warn "Rate-limit abort detected. Skipping remaining lenses."
          _rounds_record_skipped_lenses "${active_lens_list[@]:$local_count}"
          set_stop_reason "$SUMMARY_FILE" "rate-limited"
          break
        fi

        # Check global issue budget before starting next lens.
        if [[ -n "${MAX_ISSUES:-}" && "${GLOBAL_ISSUES_CREATED:-0}" -ge "$MAX_ISSUES" ]]; then
          log_info "Global issue budget exhausted (${GLOBAL_ISSUES_CREATED:-0}/$MAX_ISSUES). Skipping remaining lenses."
          _rounds_record_skipped_lenses "${active_lens_list[@]:$local_count}"
          set_stop_reason "$SUMMARY_FILE" "max-issues-reached"
          break
        fi

        local_count=$((local_count + 1))
        log_info "--- Lens $local_count/$lens_total ---"
        run_lens "$lens_entry"
      done
    fi

    if [[ -f "$LOG_BASE/.rate-limit-abort" ]]; then
      set_stop_reason "$SUMMARY_FILE" "rate-limited"
      _rounds_restore_completed_lenses_file "$had_completed_lenses_file" "$original_completed_lenses_file"
      return 1
    fi

    build_round_digest "$current_round_dir"
    round_rc=$?
    if (( round_rc != 0 )); then
      _rounds_restore_completed_lenses_file "$had_completed_lenses_file" "$original_completed_lenses_file"
      return "$round_rc"
    fi

    mark_round_completed "$round"
    round_rc=$?
    _rounds_restore_completed_lenses_file "$had_completed_lenses_file" "$original_completed_lenses_file"
    if (( round_rc != 0 )); then
      return "$round_rc"
    fi

    if (( round < rounds_total )); then
      run_meta_orchestrator "$round" "$((round + 1))" || return $?
    fi
  done
}
