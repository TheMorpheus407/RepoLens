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

# RepoLens - polish mode pre-pass helpers

_polish_repo_root() {
  local polish_lib_dir
  polish_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s\n' "${polish_lib_dir%/lib}"
}

_polish_log_info() {
  if declare -F log_info >/dev/null 2>&1; then
    log_info "$*"
  else
    printf 'INFO: %s\n' "$*" >&2
  fi
}

_polish_log_warn() {
  if declare -F log_warn >/dev/null 2>&1; then
    log_warn "$*"
  else
    printf 'WARN: %s\n' "$*" >&2
  fi
}

_polish_template_var_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//|/\\|}"
  printf '%s' "$value"
}

_polish_has_ui_source_extension() {
  local project_path="$1"
  local marker

  marker="$(find "$project_path" -type f \
    \( -name '*.tsx' -o -name '*.jsx' -o -name '*.vue' -o -name '*.svelte' -o -name '*.astro' \) \
    -not -path '*/.git/*' -not -path '*/node_modules/*' -not -path '*/vendor/*' \
    -not -path '*/dist/*' -not -path '*/build/*' -not -path '*/coverage/*' \
    -not -path '*/.cache/*' -not -path '*/generated/*' -not -path '*/docs/*' \
    -print -quit 2>/dev/null)"

  [[ -n "$marker" ]]
}

_polish_has_ui_package_marker() {
  local project_path="$1"
  local package_file

  while IFS= read -r package_file; do
    [[ -n "$package_file" ]] || continue
    if grep -qiE '"(@vitejs/plugin-react|@vitejs/plugin-vue|@vitejs/plugin-svelte|react|react-dom|next|vue|nuxt|svelte|@sveltejs/kit|vite|astro|@angular/core|@remix-run/react|solid-js|tailwindcss)"[[:space:]]*:' "$package_file"; then
      return 0
    fi
  done < <(find "$project_path" -type f -name package.json \
    -not -path '*/.git/*' -not -path '*/node_modules/*' -not -path '*/vendor/*' \
    -not -path '*/dist/*' -not -path '*/build/*' -not -path '*/coverage/*' \
    -not -path '*/.cache/*' -not -path '*/generated/*' -not -path '*/docs/*' \
    -print 2>/dev/null)

  return 1
}

_polish_has_app_markup_or_styles() {
  local project_path="$1"
  local marker

  marker="$(find "$project_path" -type f \
    \( -name '*.html' -o -name '*.htm' -o -name '*.css' -o -name '*.scss' -o -name '*.sass' -o -name '*.less' -o -name '*.mdx' -o -name '*.erb' -o -name '*.hbs' -o -name '*.jinja' -o -name '*.jinja2' -o -name '*.twig' \) \
    -not -path '*/.git/*' -not -path '*/node_modules/*' -not -path '*/vendor/*' \
    -not -path '*/generated/*' -not -path '*/dist/*' -not -path '*/build/*' \
    -not -path '*/coverage/*' -not -path '*/.cache/*' -not -path '*/docs/*' \
    -print -quit 2>/dev/null)"

  [[ -n "$marker" ]]
}

_polish_has_flutter_marker() {
  local project_path="$1"
  local pubspec_file

  while IFS= read -r pubspec_file; do
    [[ -n "$pubspec_file" ]] || continue
    if grep -qiE '(^|[[:space:]])flutter:|sdk:[[:space:]]*flutter' "$pubspec_file"; then
      return 0
    fi
  done < <(find "$project_path" -type f -name pubspec.yaml \
    -not -path '*/.git/*' -not -path '*/vendor/*' -not -path '*/generated/*' \
    -not -path '*/build/*' -not -path '*/.dart_tool/*' \
    -not -path '*/docs/*' \
    -print 2>/dev/null)

  return 1
}

_polish_has_mobile_ui_marker() {
  local project_path="$1"
  local marker

  if _polish_has_flutter_marker "$project_path"; then
    return 0
  fi

  marker="$(find "$project_path" -type f \
    \( -path '*/src/main/res/layout/*.xml' -o -path '*/src/main/res/layout-*/*.xml' -o -name '*.storyboard' -o -name '*.xib' \) \
    -not -path '*/.git/*' -not -path '*/vendor/*' -not -path '*/generated/*' \
    -not -path '*/build/*' -not -path '*/.gradle/*' \
    -not -path '*/docs/*' \
    -print -quit 2>/dev/null)"

  [[ -n "$marker" ]]
}

# detect_polish_surface <project_path>
#   Prints visual-ui when the target tree has strong UI markers, otherwise
#   cli-backend. Mixed repositories prefer visual-ui so fluency polish is not
#   skipped when a real UI is present.
detect_polish_surface() {
  local project_path="${1:-}"

  [[ -n "$project_path" ]] || { printf '%s\n' "cli-backend"; return 0; }
  project_path="$(cd "$project_path" 2>/dev/null && pwd)" || { printf '%s\n' "cli-backend"; return 0; }
  [[ -d "$project_path" ]] || { printf '%s\n' "cli-backend"; return 0; }

  if _polish_has_ui_package_marker "$project_path" ||
    _polish_has_ui_source_extension "$project_path" ||
    _polish_has_app_markup_or_styles "$project_path" ||
    _polish_has_mobile_ui_marker "$project_path"; then
    printf '%s\n' "visual-ui"
  else
    printf '%s\n' "cli-backend"
  fi
}

_polish_voice_profile_fallback() {
  cat <<'EOF'
## Project Voice Profile
Register: unavailable - No polish voice profile was generated.
Who it is for / who loves it: Use direct repository evidence only.
Product purpose: Use direct repository evidence only.

Soul:
- Use direct repository evidence only.
- Prefer restraint when voice fit is unclear.
- Skip polish suggestions that cannot explain voice fit.

Off-brand here:
- Generic polish that is not grounded in this repository.
- Any refinement whose voice fit cannot be explained from repository evidence.
EOF
}

_polish_run_base() {
  if [[ -n "${LOG_BASE:-}" ]]; then
    printf '%s\n' "$LOG_BASE"
    return 0
  fi

  local run_id="${1:-}"
  if [[ -z "$run_id" ]]; then
    return 1
  fi

  printf '%s/logs/%s\n' "$(_polish_repo_root)" "$run_id"
}

_polish_collect_suggestions_json() {
  local canonical_file="$1" fragment_dir="$2"
  shift 2 || true
  local -a inputs=()
  local local_output_root fragment

  if [[ -s "$canonical_file" ]]; then
    inputs+=("$canonical_file")
  fi

  if [[ -d "$fragment_dir" ]]; then
    while IFS= read -r fragment; do
      [[ -n "$fragment" ]] && inputs+=("$fragment")
    done < <(find "$fragment_dir" -type f -name '*.json' | LC_ALL=C sort)
  fi

  for local_output_root in "$@"; do
    [[ -d "$local_output_root" ]] || continue
    while IFS= read -r fragment; do
      [[ -n "$fragment" ]] && inputs+=("$fragment")
    done < <(find "$local_output_root" -mindepth 3 -maxdepth 3 -type f -name '*.json' | LC_ALL=C sort)
  done

  if (( ${#inputs[@]} == 0 )); then
    printf '[]\n'
    return 0
  fi

  mapfile -t inputs < <(printf '%s\n' "${inputs[@]}" | LC_ALL=C sort -u)

  jq -s '
    def as_array:
      if type == "array" then .
      elif type == "object" then [.]
      else []
      end;
    map(as_array) | add
  ' "${inputs[@]}"
}

# run_polish_ranking [run_id]
#   Reads logs/<run-id>/polish/suggestions.json, per-lens JSON fragments under
#   logs/<run-id>/polish/suggestions/, and local polish JSON outputs under
#   round lens-output trees. Adds deterministic polish rank factors and writes
#   logs/<run-id>/polish/ranked-suggestions.json.
run_polish_ranking() {
  local run_id="${1:-${RUN_ID:-}}" base_dir polish_dir suggestions_file fragments_dir ranked_file tmp_file
  local -a local_output_roots=()
  local local_output_root

  if [[ -z "$run_id" ]]; then
    _polish_log_warn "Polish ranking: missing RUN_ID"
    return 1
  fi

  base_dir="$(_polish_run_base "$run_id")" || return 1
  polish_dir="$base_dir/polish"
  suggestions_file="$polish_dir/suggestions.json"
  fragments_dir="$polish_dir/suggestions"
  ranked_file="$polish_dir/ranked-suggestions.json"
  tmp_file="$ranked_file.tmp.$$"

  mkdir -p "$polish_dir" || return 1

  if [[ -d "$base_dir/rounds" ]]; then
    while IFS= read -r local_output_root; do
      [[ -n "$local_output_root" ]] && local_output_roots+=("$local_output_root")
    done < <(find "$base_dir/rounds" -type d -path '*/lens-outputs' | LC_ALL=C sort)
  fi
  if [[ -n "${OUTPUT_DIR:-}" && -d "${OUTPUT_DIR:-}" ]]; then
    local_output_roots+=("$OUTPUT_DIR")
  fi
  if [[ -n "${CURRENT_ROUND_OUTPUT_DIR:-}" && -d "${CURRENT_ROUND_OUTPUT_DIR:-}" ]]; then
    local_output_roots+=("$CURRENT_ROUND_OUTPUT_DIR")
  fi

  if ! _polish_collect_suggestions_json "$suggestions_file" "$fragments_dir" "${local_output_roots[@]}" \
      | jq '
          def norm_string:
            tostring | ascii_downcase | gsub("_"; "-") | gsub("[[:space:]]+"; "-");
          def soul_fit_value:
            ((.voice_fit // "") | norm_string) as $fit
            | if $fit == "strong" then 1
              elif $fit == "medium" then 0.65
              elif $fit == "weak" then 0.15
              elif $fit == "off-brand" or $fit == "offbrand" then 0
              else 0
              end;
          def effort_gap_value:
            ((.location_expectedness // "") | norm_string) as $expectedness
            | if $expectedness == "forgotten-corner" or $expectedness == "forgotten-corners" then 1.5
              elif $expectedness == "no-benchmark" then 1.35
              elif $expectedness == "low-expectation" then 1.2
              elif $expectedness == "expected" then 1
              else 1
              end;
          def stable_text($key): (.[$key] // "" | tostring | ascii_downcase);

          if type == "array" then .
          else []
          end
          | map(
              . as $suggestion
              | ($suggestion | soul_fit_value) as $soul_fit
              | ($suggestion | effort_gap_value) as $effort_gap
              | . + {
                  fluency_baseline: 1,
                  soul_fit: $soul_fit,
                  effort_gap_multiplier: $effort_gap,
                  polish_rank_x1000: (($soul_fit * $effort_gap * 1000) | floor)
                }
            )
          | sort_by(
              -(.polish_rank_x1000 // 0),
              -(.soul_fit // 0),
              -(.effort_gap_multiplier // 0),
              stable_text("domain"),
              stable_text("lens_id"),
              stable_text("title"),
              stable_text("source_path")
            )
        ' > "$tmp_file"; then
    rm -f "$tmp_file"
    _polish_log_warn "Polish ranking: failed to build ranked suggestions"
    return 1
  fi

  mv "$tmp_file" "$ranked_file" || return 1
  _polish_log_info "Polish ranking: written to $ranked_file"
  return 0
}

_polish_slugify() {
  local value="$*"

  printf '%s\n' "$value" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E \
        -e 's/[^a-z0-9]+/-/g' \
        -e 's/-+/-/g' \
        -e 's/^-+//' \
        -e 's/-+$//'
}

_polish_build_issue_groups() {
  local ranked_file="$1" top_n="$2"

  jq -c --argjson top_n "$top_n" '
    def norm_string:
      tostring | ascii_downcase | gsub("_"; "-") | gsub("[[:space:]]+"; "-");
    def rank_value:
      ((.polish_rank_x1000 // 0) | tonumber? // 0);

    if type == "array" then .
    else error("ranked polish suggestions must be a JSON array")
    end
    | to_entries
    | map(
        select(
          ((.value.domain // "" | tostring | length) > 0)
          and ((.value.lens_id // "" | tostring | length) > 0)
          and ((.value.title // "" | tostring | length) > 0)
          and ((.value.body // "" | tostring | length) > 0)
          and ((.value.voice_fit // "" | norm_string) != "off-brand")
          and ((.value | rank_value) > 0)
        )
      )
    | group_by((.value.domain | tostring) + "\u0000" + (.value.lens_id | tostring))
    | map(
        (sort_by(.key)) as $entries
        | {
            first_index: ($entries[0].key),
            domain: ($entries[0].value.domain | tostring),
            lens_id: ($entries[0].value.lens_id | tostring),
            items: ($entries[:$top_n] | map(.value))
          }
      )
    | sort_by(.first_index)
    | .[]
  ' "$ranked_file"
}

_polish_render_issue_body() {
  local group_json="$1" body_file="$2" run_id="$3" ranked_file="$4"

  jq -r --arg run_id "$run_id" --arg ranked_file "$ranked_file" '
    def one_line:
      tostring
      | gsub("[\r\n]+"; " ")
      | gsub("[[:space:]]+"; " ")
      | sub("^[[:space:]]+"; "")
      | sub("[[:space:]]+$"; "");
    def body_voice_fit:
      (.body // "" | tostring | split("Voice Profile Fit")) as $parts
      | if ($parts | length) > 1 then
          ($parts[1]
            | split("\n")
            | map(one_line)
            | map(select(length > 0 and (startswith("#") | not)))
            | .[0] // "")
        else ""
        end;
    def voice_justification:
      (.voice_fit_justification // "" | one_line) as $explicit
      | if $explicit != "" then $explicit
        else (body_voice_fit) as $body_fit
        | if $body_fit != "" then $body_fit
          else "Voice fit tag: \((.voice_fit // "unspecified") | one_line)."
          end
        end;
    def suggested_refinement:
      (.body // "" | tostring
        | split("\n")
        | map(one_line)
        | map(select(length > 0 and (startswith("#") | not)))
        | .[0] // "See the polish suggestion body for details.");

    "## Polish Scope",
    "",
    "This issue groups ranked polish suggestions for the `\(.domain)/\(.lens_id)` lens from run `\($run_id)`.",
    "",
    "## Ranked Polish Suggestions",
    "",
    (.items | to_entries[] |
      "\(.key + 1). **\(.value.title | one_line)**\n   - Source: `\((.value.source_path // "not specified") | one_line)`\n   - Rank: \((.value.polish_rank_x1000 // 0) | tostring)\n   - Voice-fit justification: \(.value | voice_justification)\n   - Suggested refinement: \(.value | suggested_refinement)\n"
    ),
    "## Acceptance Criteria",
    "",
    "- The selected polishing refinements are reviewed independently.",
    "- Each accepted polish item remains scoped to approximately one hour.",
    "",
    "## References",
    "",
    "- `\($ranked_file)`"
  ' <<< "$group_json" > "$body_file"
}

_polish_increment_issue_counts() {
  GLOBAL_ISSUES_CREATED=$(( ${GLOBAL_ISSUES_CREATED:-0} + 1 ))

  if [[ -n "${SUMMARY_FILE:-}" && -f "${SUMMARY_FILE:-}" ]]; then
    if declare -F increment_summary_issues_created >/dev/null 2>&1; then
      increment_summary_issues_created "$SUMMARY_FILE" 1
      return $?
    fi
  fi

  return 0
}

_polish_issue_budget_available() {
  local max_issues="${MAX_ISSUES:-}" global_issues="${GLOBAL_ISSUES_CREATED:-0}"

  [[ "$global_issues" =~ ^[0-9]+$ ]] || global_issues=0
  if [[ "$max_issues" =~ ^[1-9][0-9]*$ ]] && (( global_issues >= max_issues )); then
    return 1
  fi

  return 0
}

# run_polish_issue_emission [run_id] [top_n]
#   Reads logs/<run-id>/polish/ranked-suggestions.json and emits one grouped
#   polish issue per lens, containing that lens's ranked top-N suggestions.
run_polish_issue_emission() {
  local run_id="${1:-${RUN_ID:-}}" top_n="${2:-${REPOLENS_POLISH_TOP_N:-3}}"
  local base_dir polish_dir ranked_file groups_file filed_dir group_json
  local emitted=0 forge_rc=0 emission_rc=0

  if [[ -z "$run_id" ]]; then
    _polish_log_warn "Polish issue emission: missing RUN_ID"
    return 1
  fi
  if [[ ! "$top_n" =~ ^[1-9][0-9]*$ ]]; then
    _polish_log_warn "Polish issue emission: top-N must be a positive integer, got: $top_n"
    return 1
  fi

  base_dir="$(_polish_run_base "$run_id")" || return 1
  polish_dir="$base_dir/polish"
  ranked_file="$polish_dir/ranked-suggestions.json"
  filed_dir="$polish_dir/filed"
  groups_file="$polish_dir/issue-groups.jsonl.tmp.$$"

  if [[ ! -f "$ranked_file" ]]; then
    _polish_log_warn "Polish issue emission: ranked suggestions missing: $ranked_file"
    return 1
  fi

  mkdir -p "$filed_dir" || return 1

  if ! _polish_build_issue_groups "$ranked_file" "$top_n" > "$groups_file"; then
    rm -f "$groups_file"
    _polish_log_warn "Polish issue emission: failed to group ranked suggestions"
    return 1
  fi

  while IFS= read -r group_json || [[ -n "$group_json" ]]; do
    [[ -n "$group_json" ]] || continue

    if ! _polish_issue_budget_available; then
      _polish_log_info "Polish issue emission: global issue budget exhausted (${GLOBAL_ISSUES_CREATED:-0}/${MAX_ISSUES:-})"
      break
    fi

    local domain lens_id safe_name body_file tmp_body title sentinel issue_url label
    domain="$(jq -r '.domain // empty' <<< "$group_json")"
    lens_id="$(jq -r '.lens_id // empty' <<< "$group_json")"
    safe_name="$(_polish_slugify "$domain--$lens_id")"
    [[ -n "$safe_name" ]] || safe_name="polish-lens-$emitted"

    body_file="$filed_dir/$safe_name.md"
    tmp_body="$body_file.tmp.$$"
    sentinel="$filed_dir/$safe_name.url"
    title="[POLISH] $domain/$lens_id polishing shortlist"
    label="polish:$domain/$lens_id"

    if [[ -s "$sentinel" ]]; then
      _polish_log_info "Polish issue emission: reusing existing filed marker for $domain/$lens_id"
      continue
    fi

    if ! _polish_render_issue_body "$group_json" "$tmp_body" "$run_id" "$ranked_file"; then
      rm -f "$tmp_body"
      _polish_log_warn "Polish issue emission: failed to render issue body for $domain/$lens_id"
      emission_rc=1
      break
    fi
    mv "$tmp_body" "$body_file" || {
      rm -f "$tmp_body"
      emission_rc=1
      break
    }

    if ${LOCAL_MODE:-false}; then
      issue_url="local:$body_file"
    else
      if ! declare -F forge_issue_create >/dev/null 2>&1; then
        _polish_log_warn "Polish issue emission: forge_issue_create is not available"
        emission_rc=1
        break
      fi
      if [[ -z "${FORGE_REPO_SLUG:-}" ]]; then
        _polish_log_warn "Polish issue emission: missing FORGE_REPO_SLUG"
        emission_rc=1
        break
      fi

      issue_url="$(forge_issue_create "$FORGE_REPO_SLUG" "$title" "$body_file" "$label" "enhancement")"
      forge_rc=$?
      if (( forge_rc != 0 )); then
        printf 'forge_issue_create failed with status %s\n' "$forge_rc" > "$filed_dir/$safe_name.failed" 2>/dev/null || true
        _polish_log_warn "Polish issue emission: forge issue create failed for $domain/$lens_id"
        emission_rc="$forge_rc"
        break
      fi
    fi

    printf '%s\n' "$issue_url" > "$sentinel" || {
      emission_rc=1
      break
    }
    if ! _polish_increment_issue_counts; then
      _polish_log_warn "Polish issue emission: failed to update summary issue count"
      emission_rc=1
      break
    fi
    emitted=$((emitted + 1))
  done < "$groups_file"

  rm -f "$groups_file"
  if (( emission_rc != 0 )); then
    return "$emission_rc"
  fi

  _polish_log_info "Polish issue emission: emitted $emitted grouped polish issue(s)"
  return 0
}

# run_polish_voice_profile_prepass [run_id]
#   Builds logs/<run-id>/polish/voice-profile.md once before polish lenses run.
run_polish_voice_profile_prepass() {
  local run_id="${1:-${RUN_ID:-}}" repo_root prompt_dir template_file project_path
  local profile_dir prompt_path profile_path envelope_path vars prompt agent_rc phase_rc
  local total_lenses="${TOTAL_LENSES:-1}"

  [[ "${MODE:-}" == "polish" ]] || return 0
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    _polish_log_info "Polish voice profile: dry-run skips pre-pass"
    return 0
  fi
  if [[ "$total_lenses" =~ ^[0-9]+$ ]] && (( total_lenses == 0 )); then
    _polish_log_info "Polish voice profile: no polish lenses queued"
    return 0
  fi

  if [[ -z "$run_id" || -z "${LOG_BASE:-}" ]]; then
    _polish_log_warn "Polish voice profile pre-pass missing RUN_ID or LOG_BASE"
    return 1
  fi

  profile_path="${POLISH_VOICE_PROFILE_FILE:-$LOG_BASE/polish/voice-profile.md}"
  POLISH_VOICE_PROFILE_FILE="$profile_path"
  export POLISH_VOICE_PROFILE_FILE
  profile_dir="$(dirname "$profile_path")"

  if [[ -s "$profile_path" ]]; then
    _polish_log_info "Polish voice profile: reusing $profile_path"
    return 0
  fi

  repo_root="$(_polish_repo_root)"
  prompt_dir="${BASE_PROMPTS_DIR:-$repo_root/prompts/_base}"
  template_file="$prompt_dir/meta_orchestrator_polish.md"
  project_path="${PROJECT_PATH:-$repo_root}"
  prompt_path="$profile_dir/voice-profile-prompt.md"
  envelope_path="$profile_path.envelope.json"
  agent_rc=0

  if [[ ! -f "$template_file" ]]; then
    _polish_log_warn "Polish voice profile template missing: $template_file"
    return 1
  fi
  if ! declare -F compose_prompt >/dev/null 2>&1; then
    _polish_log_warn "compose_prompt is not available for polish voice profile rendering"
    return 1
  fi
  if ! declare -F run_agent >/dev/null 2>&1; then
    _polish_log_warn "run_agent is not available for polish voice profile pre-pass"
    return 1
  fi
  if [[ -z "${AGENT:-}" ]]; then
    _polish_log_warn "AGENT is not configured for polish voice profile pre-pass"
    return 1
  fi

  mkdir -p "$profile_dir" || return 1

  vars="PROJECT_PATH=$(_polish_template_var_escape "$project_path")"
  vars+="|REPO_OWNER=$(_polish_template_var_escape "${REPO_OWNER:-}")"
  vars+="|REPO_NAME=$(_polish_template_var_escape "${REPO_NAME:-}")"
  vars+="|FORGE_REPO_SLUG=$(_polish_template_var_escape "${FORGE_REPO_SLUG:-}")"
  vars+="|MODE=polish"
  vars+="|RUN_ID=$(_polish_template_var_escape "$run_id")"

  prompt="$(compose_prompt "$template_file" "$template_file" "$vars" "" "polish")" || return 1
  printf '%s\n' "$prompt" > "$prompt_path" || return 1

  _polish_log_info "Polish voice profile: running pre-pass"
  run_agent "$AGENT" "$prompt" "$project_path" "${AGENT_TIMEOUT_SECS:-}" "${AGENT_KILL_GRACE_SECS:-30}" "$envelope_path" > "$profile_path" 2>&1 || agent_rc=$?

  if declare -F handle_agent_failure_in_phase >/dev/null 2>&1; then
    handle_agent_failure_in_phase "polish" "$profile_path" "$agent_rc" "$envelope_path" "Polish voice profile pre-pass" >/dev/null
    phase_rc=$?
    if (( phase_rc == 3 )); then
      return 3
    elif (( phase_rc != 0 )); then
      _polish_log_warn "Polish voice profile pre-pass failed"
      return 1
    fi
  elif (( agent_rc != 0 )); then
    _polish_log_warn "Polish voice profile pre-pass exited with status $agent_rc"
    return "$agent_rc"
  fi

  if ! grep -q '[^[:space:]]' "$profile_path" 2>/dev/null; then
    _polish_voice_profile_fallback > "$profile_path" || return 1
  fi

  _polish_log_info "Polish voice profile: written to $profile_path"
  return 0
}
