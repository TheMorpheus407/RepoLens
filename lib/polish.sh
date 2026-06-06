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
