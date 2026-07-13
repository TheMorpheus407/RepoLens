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

# domain_default_finding_type <domain>
#   Back-compat fallback: maps a finding's domain (a config/domains.json id) to a
#   sensible default canonical finding-type, used when a finding carries no
#   explicit (or no recognizable) `type:` — older runs, or lenses not yet emitting
#   `type:`. Documented mappings (issue #344 body):
#     security, llm-security                       -> security-vulnerability
#     testing                                      -> test-gap
#     performance                                  -> performance-risk
#     error-handling, concurrency, database        -> reliability-bug
#     code-quality, maintainability, architecture,
#       documentation, i18n                        -> maintainability
#   config/domains.json carries many more domains than are enumerated here
#   (compliance, observability, devops, frontend, the deploy/android/discovery/
#   logs/toolgate families, …); they intentionally fall through to the safe,
#   non-security `maintainability` default — that is the designed behavior, not a
#   gap. ALWAYS prints exactly one of the six canonical ids; never empty. The
#   value is trimmed and lowercased so a slightly-dirty frontmatter domain still
#   maps. Pure; set -u safe with a missing/empty arg.
domain_default_finding_type() {
  local domain="${1:-}"

  domain="${domain#"${domain%%[![:space:]]*}"}"
  domain="${domain%"${domain##*[![:space:]]}"}"
  domain="${domain,,}"

  case "$domain" in
    security|llm-security) printf '%s\n' 'security-vulnerability' ;;
    testing)              printf '%s\n' 'test-gap' ;;
    performance)          printf '%s\n' 'performance-risk' ;;
    error-handling|concurrency|database)
                          printf '%s\n' 'reliability-bug' ;;
    # Listed explicitly for self-documentation; these also match the default arm.
    code-quality|maintainability|architecture|documentation|i18n)
                          printf '%s\n' 'maintainability' ;;
    *)                    printf '%s\n' 'maintainability' ;;
  esac
}

# _finding_frontmatter_scalar <file> <key>
#   Prints the trimmed/de-quoted value of a scalar <key> from the leading `---`
#   frontmatter block ONLY (stops at the closing `---`), or empty string when the
#   key, file, or block is absent. A `key:`-looking line in the markdown body is
#   never misparsed. Self-contained awk replica (mirrors
#   lib/ledger.sh::_ledger_frontmatter_scalar) so lib/core.sh stays sourceable on
#   its own with no cross-file dependency. Pure; set -u safe.
_finding_frontmatter_scalar() {
  local file="${1:-}" key="${2:-}" val
  [[ -n "$file" && -f "$file" && -n "$key" ]] || { printf ''; return 0; }

  val="$(awk -v key="$key" '
    NR==1 && $0!="---" { exit 0 }
    NR==1 { next }
    $0=="---" { exit 0 }
    $0 ~ "^[[:space:]]*" key "[[:space:]]*:" {
      sub("^[[:space:]]*" key "[[:space:]]*:[[:space:]]*", "")
      print
      exit 0
    }
  ' "$file")"

  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  val="${val#\"}"; val="${val%\"}"
  val="${val#\'}"; val="${val%\'}"
  printf '%s' "$val"
}

# finding_resolve_type <file>
#   Canonical finding-type for a finding markdown file: an explicit, valid `type:`
#   in the leading frontmatter wins (run through finding_type_normalize, so short
#   aliases like `perf` are repaired); a missing or unrecognized `type:` falls
#   back to domain_default_finding_type(domain:). ALWAYS prints exactly one of the
#   six canonical ids — never empty (AC: registry records are always typed). Ready
#   for the registry writer to call per finding. set -u safe with a missing arg or
#   a missing file (both resolve to the maintainability default).
finding_resolve_type() {
  local file="${1:-}" raw_type domain norm
  raw_type="$(_finding_frontmatter_scalar "$file" type)"
  domain="$(_finding_frontmatter_scalar "$file" domain)"
  norm="$(finding_type_normalize "$raw_type")"
  [[ -n "$norm" ]] || norm="$(domain_default_finding_type "$domain")"
  printf '%s\n' "$norm"
}

# severity_from_title <title>
#   Extracts a normalized severity from a leading "[SEVERITY]" title prefix,
#   reusing the strict prefix regex from _synthesize_normalize_title
#   (^\[([A-Za-z]+)\][[:space:]]*(.*)$). This is ADVISORY / display-only and must
#   NEVER be used as a data source — frontmatter `severity:` is the single source
#   of truth (issue #331). Prints the canonical severity (via severity_normalize)
#   when the bracketed word is a recognized severity, or empty string when there
#   is no prefix or the bracketed word is not a severity. Pure; set -u safe.
severity_from_title() {
  local title="${1:-}"
  if [[ "$title" =~ ^\[([A-Za-z]+)\][[:space:]]*(.*)$ ]]; then
    severity_normalize "${BASH_REMATCH[1]}"
    return 0
  fi
  printf ''
}

# detect_severity_mismatch <frontmatter_severity> <title_or_filename>
#   Frontmatter is the single source of truth (issue #331). Compares the
#   canonical frontmatter severity against any severity carried by the title's
#   "[SEVERITY]" prefix. ALWAYS prints the canonical frontmatter severity on
#   stdout (the data channel), so callers consume it as the authoritative value
#   regardless of outcome. The exit code is the only mismatch signal:
#     Returns 0 when they agree OR the title carries no severity prefix.
#     Returns non-zero when the title severity is present and disagrees.
#   Emits no log itself — the caller decides how to warn. Pure; set -u safe.
detect_severity_mismatch() {
  local fm_raw="${1:-}" title="${2:-}" fm title_sev
  fm="$(severity_normalize "$fm_raw")"
  printf '%s' "$fm"
  title_sev="$(severity_from_title "$title")"
  [[ -z "$title_sev" || "$title_sev" == "$fm" ]]
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
    claude|codex|spark|sparc|opencode|antigravity|copilot) ;;
    claude/*|codex/*|opencode/*|antigravity/*|copilot/*)
      # <agent>/<model> targets a specific model on the CLI (issue #384). The
      # empty-model guard mirrors the original opencode/* one so a trailing slash
      # (a typo) never silently routes to a blank model.
      [[ -n "${agent#*/}" ]] || die "Invalid agent: $agent (missing model after '${agent%%/*}/')."
      ;;
    spark/*|sparc/*)
      # spark/sparc are fixed presets (hardcoded -m gpt-5.3-codex-spark); a
      # /model suffix would fight the preset, so it is rejected with a hint.
      die "Invalid agent: $agent (spark/sparc are fixed presets; use codex/<model> to target a specific model)"
      ;;
    *) die "Invalid agent: $agent (expected claude, codex, spark/sparc, opencode, antigravity, copilot, or <agent>/<model> for claude/codex/opencode/antigravity/copilot)" ;;
  esac
}

# Map an agent value to its underlying CLI binary and require that binary.
# Centralizes the agent->binary mapping so the global --agent and every
# --agent-override target (issue #380) share one require_cmd code path — a
# typo'd or uninstalled override agent then fails at startup, not 200 lenses in.
require_agent_cmd() {
  local agent="$1"
  case "$agent" in
    claude|claude/*) require_cmd claude ;;
    codex|codex/*|spark|sparc) require_cmd codex ;;
    opencode|opencode/*) require_cmd opencode ;;
    antigravity|antigravity/*) require_cmd agy ;;
    copilot|copilot/*) require_cmd gh ;;
    *) die "Internal error: unsupported agent '$agent' for command check" ;;
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
  [spec-change]=1
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
  [spec-change]=1
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
  [spec-change]=1
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
    audit|feature|bugfix|bugreport|discover|deploy|custom|opensource|content|greenfield|polish|spec-change) printf '%s\n' 1800 ;;
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
    claude|claude/*) agent_vars=(REPOLENS_AGENT_TIMEOUT_CLAUDE) ;;
    codex|codex/*) agent_vars=(REPOLENS_AGENT_TIMEOUT_CODEX) ;;
    spark) agent_vars=(REPOLENS_AGENT_TIMEOUT_SPARK REPOLENS_AGENT_TIMEOUT_SPARC) ;;
    sparc) agent_vars=(REPOLENS_AGENT_TIMEOUT_SPARC REPOLENS_AGENT_TIMEOUT_SPARK) ;;
    opencode|opencode/*) agent_vars=(REPOLENS_AGENT_TIMEOUT_OPENCODE) ;;
    antigravity|antigravity/*) agent_vars=(REPOLENS_AGENT_TIMEOUT_ANTIGRAVITY) ;;
    copilot|copilot/*) agent_vars=(REPOLENS_AGENT_TIMEOUT_COPILOT) ;;
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
      claude|claude/*)
        # <agent>/<model> selects a model via `claude --model <model>` (issue
        # #384). The flag goes BEFORE -p "$prompt" and leaves the JSON-envelope
        # path (--output-format json + .result extraction) untouched. For bare
        # claude the array is empty, so the argv is byte-for-byte unchanged. The
        # "${a[@]+"${a[@]}"}" expansion is required for the empty case: a plain
        # "${a[@]}" aborts with "unbound variable" under set -u on bash < 4.4
        # (the project floor is 4.0), so the alternate form keeps bare claude
        # working on every supported bash.
        local claude_model_args=()
        if [[ "$agent" == claude/* ]]; then
          claude_model_args=(--model "${agent#claude/}")
        fi
        local raw raw_json rc
        raw="$(
          timeout --kill-after="${kill_grace_secs}s" "${timeout_secs}s" claude --dangerously-skip-permissions "${claude_model_args[@]+"${claude_model_args[@]}"}" --output-format json -p "$prompt" 2>&1
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
      codex/*)
        # `codex exec -m <model>` is the proven model-selection flag (the spark
        # preset below already uses -m), so codex/<model> reuses it (issue #384).
        timeout --kill-after="${kill_grace_secs}s" "${timeout_secs}s" codex exec --yolo -m "${agent#codex/}" "$prompt"
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
      antigravity)
        timeout --kill-after="${kill_grace_secs}s" "${timeout_secs}s" agy --dangerously-skip-permissions -p "$prompt"
        ;;
      antigravity/*)
        # antigravity/<model> selects a model via `agy --model <model>` (issue
        # #384), keeping the autonomy + headless -p flags proven by #383.
        timeout --kill-after="${kill_grace_secs}s" "${timeout_secs}s" agy --dangerously-skip-permissions --model "${agent#antigravity/}" -p "$prompt"
        ;;
      copilot|copilot/*)
        # Invoked through `gh copilot` (the GitHub CLI extension that wraps the
        # official GitHub Copilot CLI), so a bare `gh` install is all users need
        # — `gh` auto-downloads the `copilot` binary on first run if missing.
        # `-p` runs headless/non-interactive; `--allow-all-tools` is the
        # required auto-approve flag for non-interactive mode (an unattended
        # lens must never block on a tool-permission prompt, and stdin is
        # already closed above); `--no-ask-user` disables the ask_user tool for
        # the same reason; `-s`/`--silent` and `--no-color` keep stdout to just
        # the agent's plain-text response so the DONE-streak detector reads it
        # unchanged. copilot/<model> adds `--model <model>` to pin a model.
        local copilot_model_args=()
        if [[ "$agent" == copilot/* ]]; then
          copilot_model_args=(--model "${agent#copilot/}")
        fi
        timeout --kill-after="${kill_grace_secs}s" "${timeout_secs}s" gh copilot -p "$prompt" --allow-all-tools --no-ask-user --no-color -s "${copilot_model_args[@]+"${copilot_model_args[@]}"}"
        ;;
      *)
        die "Internal error: unsupported agent '$agent'"
        ;;
    esac
  )
}
