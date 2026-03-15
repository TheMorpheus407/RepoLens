#!/usr/bin/env bash
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
# Usage: run_agent <agent> <prompt> <project_path>
#
# Executes the given agent inside the target repository directory.
# The work happens in a subshell so the caller's cwd is never affected.

run_agent() {
  local agent="$1"
  local prompt="$2"
  local project_path="$3"

  [[ -d "$project_path" ]] || die "Project path does not exist: $project_path"

  (
    cd "$project_path" || die "Failed to cd into: $project_path"

    case "$agent" in
      claude)
        claude --dangerously-skip-permissions -p "$prompt"
        ;;
      codex)
        codex exec --yolo "$prompt"
        ;;
      spark|sparc)
        codex exec --yolo -m gpt-5.3-codex-spark -c reasoning_effort="xhigh" "$prompt"
        ;;
      opencode)
        opencode run "$prompt"
        ;;
      opencode/*)
        local opencode_model="${agent#opencode/}"
        opencode run -m "$opencode_model" "$prompt"
        ;;
      *)
        die "Internal error: unsupported agent '$agent'"
        ;;
    esac
  )
}
