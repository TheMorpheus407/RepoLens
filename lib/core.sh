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

# severity_normalize <value>
#   Canonicalizes structured severity values. Display-only title prefixes may
#   remain uppercase, but data fields use critical|high|medium|low.
severity_normalize() {
  local value="${1:-}"

  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"

  if [[ "$value" == \[*\] ]]; then
    value="${value#\[}"
    value="${value%\]}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
  fi

  value="${value,,}"
  case "$value" in
    critical|high|medium|low) printf '%s\n' "$value" ;;
    *) printf '' ;;
  esac
}

# severity_rank <value>
#   Maps canonical severities to an ordered numeric rank. Higher means more
#   severe. Returns non-zero for invalid values.
severity_rank() {
  local severity
  severity="$(severity_normalize "${1:-}")"

  case "$severity" in
    low) printf '0\n' ;;
    medium) printf '1\n' ;;
    high) printf '2\n' ;;
    critical) printf '3\n' ;;
    *) return 1 ;;
  esac
}

# severity_meets_min <severity> <min>
#   Returns success when <severity> is at or above the inclusive threshold.
severity_meets_min() {
  local severity_rank_value min_rank_value

  severity_rank_value="$(severity_rank "${1:-}")" || return 1
  min_rank_value="$(severity_rank "${2:-}")" || return 1

  (( severity_rank_value >= min_rank_value ))
}

# finding_type_normalize <value>
#   Canonicalizes a raw finding-TYPE string to one of the six closed taxonomy
#   ids (see issue #320 / config/finding-types.json). The set is hardcoded here
#   to avoid a runtime jq dependency, mirroring severity_normalize. A short,
#   documented alias set repairs common variants (the schema-doc short forms
#   plus obvious synonyms). Prints the canonical id on success; prints empty
#   string for unknown/unrepairable/empty input and never errors under set -u.
finding_type_normalize() {
  local value="${1:-}"

  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"

  if [[ "$value" == \[*\] ]]; then
    value="${value#\[}"
    value="${value%\]}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
  fi

  value="${value,,}"
  case "$value" in
    # canonical ids (round-trip to themselves)
    security-vulnerability) printf '%s\n' 'security-vulnerability' ;;
    reliability-bug)        printf '%s\n' 'reliability-bug' ;;
    performance-risk)       printf '%s\n' 'performance-risk' ;;
    maintainability)        printf '%s\n' 'maintainability' ;;
    test-gap)               printf '%s\n' 'test-gap' ;;
    external-dependency)    printf '%s\n' 'external-dependency' ;;
    # aliases -> canonical (short forms = schema-doc enum + obvious synonyms)
    security)               printf '%s\n' 'security-vulnerability' ;;
    bug|correctness|reliability)
                            printf '%s\n' 'reliability-bug' ;;
    perf|performance)       printf '%s\n' 'performance-risk' ;;
    tests|testing)          printf '%s\n' 'test-gap' ;;
    cve|dependency)         printf '%s\n' 'external-dependency' ;;
    *) printf '' ;;
  esac
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
  [bugreport]=1
  [custom]=1
  [discover]=1
  [deploy]=1
  [opensource]=1
  [content]=1
  [greenfield]=1
  [polish]=1
)

declare -A MODE_DEFAULT_ROUNDS=(
  [audit]=1
  [feature]=1
  [bugfix]=1
  [bugreport]=3
  [custom]=1
  [discover]=1
  [deploy]=1
  [opensource]=1
  [content]=1
  [greenfield]=1
  [polish]=1
)

declare -A ROUNDS_CAP_BY_MODE=(
  [audit]=1
  [feature]=1
  [bugfix]=1
  [custom]=1
  [bugreport]=10
  [deploy]=1
  [opensource]=1
  [content]=1
  [discover]=1
  [greenfield]=1
  [polish]=1
)

mode_default_depth() {
  local mode="$1"
  local depth="${MODE_DEFAULT_DEPTH[$mode]:-}"
  [[ -n "$depth" ]] || die "Internal error: unsupported mode '$mode' for depth default"
  printf '%s\n' "$depth"
}

mode_default_rounds() {
  local mode="$1"
  local rounds="${MODE_DEFAULT_ROUNDS[$mode]:-}"
  [[ -n "$rounds" ]] || die "Internal error: unsupported mode '$mode' for rounds default"
  printf '%s\n' "$rounds"
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
    audit|feature|bugfix|bugreport|discover|deploy|custom|opensource|content|greenfield|polish) printf '%s\n' 1800 ;;
    *) die "Internal error: unsupported mode '$mode' for timeout default" ;;
  esac
}

resolve_agent_timeout() {
  local mode="$1"
  local agent="${2:-}"
  local mode_upper="${mode^^}"
  mode_upper="${mode_upper//-/_}"
  local mode_var="REPOLENS_AGENT_TIMEOUT_${mode_upper}"
  local agent_vars=()
  local agent_var=""

  case "$agent" in
    claude) agent_vars=(REPOLENS_AGENT_TIMEOUT_CLAUDE) ;;
    codex) agent_vars=(REPOLENS_AGENT_TIMEOUT_CODEX) ;;
    spark) agent_vars=(REPOLENS_AGENT_TIMEOUT_SPARK REPOLENS_AGENT_TIMEOUT_SPARC) ;;
    sparc) agent_vars=(REPOLENS_AGENT_TIMEOUT_SPARC REPOLENS_AGENT_TIMEOUT_SPARK) ;;
    opencode|opencode/*) agent_vars=(REPOLENS_AGENT_TIMEOUT_OPENCODE) ;;
    "") ;;
    *) ;;
  esac

  for agent_var in "${agent_vars[@]}"; do
    if [[ -n "${!agent_var:-}" ]]; then
      printf '%s\n' "${!agent_var}"
      return
    fi
  done

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

resolve_lens_max_wall() {
  local value="${REPOLENS_LENS_MAX_WALL:-3600}"

  if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
    die "REPOLENS_LENS_MAX_WALL must be a positive integer number of seconds"
  fi

  printf '%s\n' "$((10#$value))"
}

# Usage: run_agent <agent> <prompt> <project_path> [timeout_secs] [kill_grace_secs] [envelope_file]
#
# Executes the given agent inside the target repository directory.
# The work happens in a subshell so the caller's cwd is never affected.

run_agent() {
  local agent="$1"
  local prompt="$2"
  local project_path="$3"
  local timeout_secs="${4:-}"
  local kill_grace_secs="${5:-${REPOLENS_AGENT_KILL_GRACE:-30}}"
  local envelope_file="${6:-${REPOLENS_AGENT_ENVELOPE_FILE:-}}"

  if [[ -z "$timeout_secs" ]]; then
    timeout_secs="$(resolve_agent_timeout "${MODE:-audit}" "$agent")"
  fi

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
    if [[ -n "${REPOLENS_RUN_LOCK_FD:-}" ]]; then
      exec {REPOLENS_RUN_LOCK_FD}>&-
      unset REPOLENS_RUN_LOCK_FD
    fi

    case "$agent" in
      claude)
        local raw raw_json rc
        raw="$(
          timeout --kill-after="${kill_grace_secs}s" "${timeout_secs}s" claude --dangerously-skip-permissions --output-format json -p "$prompt" 2>&1
        )"
        rc=$?

        raw_json="$raw"
        if command -v jq >/dev/null 2>&1 && ! printf '%s' "$raw_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
          raw_json="${raw//$'\n'/\\n}"
        fi

        if command -v jq >/dev/null 2>&1 && printf '%s' "$raw_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
          if [[ -n "$envelope_file" ]]; then
            mkdir -p "$(dirname "$envelope_file")" 2>/dev/null || true
            printf '%s' "$raw_json" > "$envelope_file" 2>/dev/null || true
          fi
          printf '%s' "$raw_json" | jq -r '.result // ""' 2>/dev/null || true
        else
          printf '%s' "$raw"
        fi
        return "$rc"
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
