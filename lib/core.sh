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

# RepoLens — Core utilities
# Sourced by lens scripts. Do NOT execute directly.
set -uo pipefail

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------

die() {
  echo "ERROR: $*" >&2
  exit 1
}

warn() {
  echo "WARN: $*" >&2
}

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

# ---------------------------------------------------------------------------
# Agent validation
# ---------------------------------------------------------------------------

validate_agent() {
  local agent="$1"
  case "$agent" in
    claude|codex|spark|sparc|opencode) ;;
    opencode/*)
      [[ -n "${agent#opencode/}" ]] || die "Invalid agent: $agent (missing model after 'opencode/')."
      ;;
    *) die "Invalid agent: $agent (expected claude, codex, spark/sparc, opencode, or opencode/<model>)" ;;
  esac
}

# ---------------------------------------------------------------------------
# Agent runner
# ---------------------------------------------------------------------------

declare -A MODE_DEFAULT_DEPTH=(
  [audit]=3
  [feature]=3
  [bugfix]=3
  [custom]=1
  [discover]=1
  [deploy]=1
  [opensource]=1
  [content]=1
)

declare -A ROUNDS_CAP_BY_MODE=(
  [audit]=10
  [feature]=10
  [bugfix]=10
  [custom]=10
  [bugreport]=10
  [deploy]=1
  [opensource]=1
  [content]=1
  [discover]=1
)

mode_default_depth() {
  local mode="$1"
  local depth="${MODE_DEFAULT_DEPTH[$mode]:-}"
  [[ -n "$depth" ]] || die "Internal error: unsupported mode '$mode' for depth default"
  printf '%s\n' "$depth"
}

validate_rounds() {
  local mode="$1"
  local value="$2"
  local source="${3:---rounds}"
  local cap="${ROUNDS_CAP_BY_MODE[$mode]:-}"

  [[ -n "$cap" ]] || die "Internal error: unsupported mode '$mode' for rounds cap"
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || die "$source must be a positive integer, got: $value"

  if (( value > cap )); then
    die "$source $value exceeds cap for mode '$mode' (max: $cap)"
  fi
}

agent_timeout_default_for_mode() {
  local mode="$1"
  case "$mode" in
    deploy) printf '%s\n' 1800 ;;
    audit|feature|bugfix|discover|custom|opensource|content) printf '%s\n' 600 ;;
    *) die "Internal error: unsupported mode '$mode' for timeout default" ;;
  esac
}

resolve_agent_timeout() {
  local mode="$1"
  local mode_upper="${mode^^}"
  mode_upper="${mode_upper//-/_}"
  local mode_var="REPOLENS_AGENT_TIMEOUT_${mode_upper}"

  if [[ -n "${REPOLENS_AGENT_TIMEOUT:-}" ]]; then
    printf '%s\n' "$REPOLENS_AGENT_TIMEOUT"
    return
  fi

  if [[ -n "${!mode_var:-}" ]]; then
    printf '%s\n' "${!mode_var}"
    return
  fi

  agent_timeout_default_for_mode "$mode"
}

resolve_agent_kill_grace() {
  printf '%s\n' "${REPOLENS_AGENT_KILL_GRACE:-30}"
}

# Usage: run_agent <agent> <prompt> <project_path> [timeout_secs] [kill_grace_secs]
#
# Executes the given agent inside the target repository directory.
# The work happens in a subshell so the caller's cwd is never affected.

run_agent() {
  local agent="$1"
  local prompt="$2"
  local project_path="$3"
  local timeout_secs="${4:-${REPOLENS_AGENT_TIMEOUT:-600}}"
  local kill_grace_secs="${5:-${REPOLENS_AGENT_KILL_GRACE:-30}}"

  [[ -d "$project_path" ]] || die "Project path does not exist: $project_path"
  if [[ ! "$kill_grace_secs" =~ ^[0-9]+$ || "$kill_grace_secs" -le 0 ]]; then
    die "REPOLENS_AGENT_KILL_GRACE must be a positive integer number of seconds"
  fi

  (
    cd "$project_path" || die "Failed to cd into: $project_path"
    export PROJECT_PATH="$PWD"
    # Close stdin so agents that fall back to interactive prompts (auth
    # failure, login wizard) exit quickly instead of blocking on a read
    # that will never deliver input.
    exec </dev/null

    case "$agent" in
      claude)
        timeout --kill-after="${kill_grace_secs}s" "${timeout_secs}s" claude --dangerously-skip-permissions -p "$prompt"
        ;;
      codex)
        timeout --kill-after="${kill_grace_secs}s" "${timeout_secs}s" codex exec --yolo "$prompt"
        ;;
      spark|sparc)
        timeout --kill-after="${kill_grace_secs}s" "${timeout_secs}s" codex exec --yolo -m gpt-5.3-codex-spark -c reasoning_effort="xhigh" "$prompt"
        ;;
      opencode)
        timeout --kill-after="${kill_grace_secs}s" "${timeout_secs}s" opencode run "$prompt"
        ;;
      opencode/*)
        local opencode_model="${agent#opencode/}"
        timeout --kill-after="${kill_grace_secs}s" "${timeout_secs}s" opencode run -m "$opencode_model" "$prompt"
        ;;
      *)
        die "Internal error: unsupported agent '$agent'"
        ;;
    esac
  )
}
