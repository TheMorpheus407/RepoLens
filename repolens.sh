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

set -uo pipefail

# Bash 4.0+ is required: associative arrays (declare -A), read -ra into arrays,
# and other features used throughout repolens.sh and lib/. macOS ships bash 3.2
# by default (GPLv3 avoidance), so this check fires loudly with a fix hint
# instead of letting a cryptic syntax error surface deeper in the script.
if (( BASH_VERSINFO[0] < 4 )); then
  echo "ERROR: RepoLens requires bash 4.0 or newer. Detected: ${BASH_VERSION}" >&2
  echo "  macOS: brew install bash (then run with /usr/local/bin/bash or /opt/homebrew/bin/bash)" >&2
  echo "  Linux: upgrade via your package manager (apt install bash, etc.)" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Source libraries ---
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/core.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/logging.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/streak.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/template.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/summary.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/status.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/parallel.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/rounds.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/verify.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/triage.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/synthesize.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/hosted.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/android.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/forge.sh"

VERSION="0.1.0"

show_version() {
  local sponsors_file="$SCRIPT_DIR/config/sponsors.json"
  echo "RepoLens v${VERSION}"
  echo ""
  if [[ -f "$sponsors_file" ]] && command -v jq >/dev/null 2>&1; then
    echo "Sponsors:"
    jq -r '.sponsors[] | "  \(.name): \(.url)"' "$sponsors_file" 2>/dev/null
  fi
}

show_about() {
  local sponsors_file="$SCRIPT_DIR/config/sponsors.json"
  echo "RepoLens v${VERSION}"
  echo ""
  echo "A standalone multi-lens code audit and analysis tool."
  echo "Runs expert analysis agents against any git repository or live server"
  echo "and creates remote issues for real findings."
  echo ""
  if [[ -f "$sponsors_file" ]] && command -v jq >/dev/null 2>&1; then
    echo "Sponsors:"
    jq -r '.sponsors[] | "  \(.name): \(.url)"' "$sponsors_file" 2>/dev/null
  fi
}

# --- Usage ---
usage() {
  cat <<'EOF'
Usage: repolens.sh --project <path> --agent <agent> [OPTIONS]
       repolens.sh status [run-id] [OPTIONS]

RepoLens — Multi-lens code audit tool. Runs expert analysis agents against
any git repository and creates remote issues for real findings.

Required:
  --project <path|url>    Local path or remote Git URL (cloned read-only if URL)
  --agent <agent>         claude | codex | spark | sparc | opencode | opencode/<model>

Commands:
  status [run-id]         Show a live run snapshot from logs/<run-id>/status.json

Options:
  --mode <mode>           audit (default) | feature | bugfix | bugreport | discover | deploy | custom | opensource | content
  --change <statement>    Change impact analysis — propagates statement across all lenses (implies --mode custom)
  --bug-report <file|text>
                          Symptom report for --mode bugreport. Accepts a file path (read verbatim)
                          or inline text. Required when --mode bugreport is set
                          (or REPOLENS_BUG_REPORT_PATH is exported).
  --source <file>         Source material for content creation (PDF, text, markdown — agent reads directly)
  --logs <path>           Runtime log file or directory for the 'logs' domain (path string only — agent reads it)
  --focus <lens-id>       Run a single lens (e.g., "injection", "dead-code")
  --lens <lens-id>        Alias for --focus
  --domain <domain-id>    Run all lenses in one domain (e.g., "security")
  --parallel              Run lenses in parallel (one agent process per lens)
  --max-parallel <n>      Max concurrent agents in parallel mode (default: 8)
  --resume <run-id>       Resume a previous interrupted run
  --spec <file>           Spec/PRD/roadmap to guide analysis (any text file)
  --max-issues <n>        Stop after creating n total issues (dry-run quality check)
  --min-severity <level>  Only file findings at or above level: critical|high|medium|low
  --depth <n>             DONE streak depth per lens. Defaults: 3 for audit/feature/bugfix,
                           1 otherwise. Must be between 1 and 19.
  --rounds <n>            Cross-lens rounds (default: 1; capped per mode —
                           deploy/opensource/content/discover locked to 1)
  --no-verifier           Skip the post-rounds verifier step. Defaults: ON for
                           --mode bugreport (evidence accuracy is critical when
                           filing bug reports); OFF for every other mode.
  --no-triage             Skip the pre-rounds triage step (round-0 context pack
                           for --mode bugreport). Defaults: OFF for --mode
                           bugreport; ON for every other mode (no-op there).
  --cross-link <mode>     Synthesizer cross-link behavior for existing issues:
                           off | comment | suggest-reopen. Defaults: comment
                           for --mode bugreport; off for every other mode.
                           Never auto-reopens — suggest-reopen files a small
                           repolens:reopen-candidate issue instead.
  --local                 Write findings as local markdown files instead of creating remote issues
  --output <path>         Output directory for local markdown files (requires --local, default: logs/<run-id>/issues/)
  --forge <provider>      gh (GitHub) | tea (Gitea) | fj (Forgejo/Codeberg) — overrides auto-detection from origin
  --hosted                Spin up project's Docker Compose in isolated network for DAST scanning and testing
  --remote <ssh-target>   Deploy mode server target reachable by SSH (host, user@host, or user@host:port)
  --remote-key <path>     SSH private key path for --remote; must be an existing regular file
  --remote-label <text>   Human-readable remote target label for later auth prompts
  --deploy-target <target>
                          Deploy mode target: auto (default) | server | android
  --build-android-apk     In deploy mode, explicitly allow building Android source with ./gradlew assembleDebug
  --yes, -y               Skip confirmation prompt (for CI/automation)
  --max-cost <amount>     Warn if min. cost estimate exceeds this dollar amount (real cost typically 2–5x higher)
  --i-know-this-is-expensive
                          Acknowledge high --rounds cost. Bypasses the
                          rounds>=4 abort gate (which otherwise demands
                          --max-cost AND --yes). Does NOT bypass the
                          REPOLENS_MAX_ROUNDS cross-mode hard ceiling.
  --dry-run               Validate config and show what would run, then exit (no agents executed)
  --version               Show version and sponsor information, then exit
  --about                 Show tool description and sponsor information, then exit
  -h, --help              Show help

Examples:
  repolens.sh --project ~/myapp --agent claude
  repolens.sh --project ~/myapp --agent claude --focus injection
  repolens.sh --project ~/myapp --agent codex --domain security --parallel
  repolens.sh --project ~/myapp --agent spark --mode bugfix --parallel --max-parallel 4
  repolens.sh --project ~/myapp --agent claude --spec ~/docs/prd.md --domain architecture
  repolens.sh --project ~/myapp --agent claude --focus injection --max-issues 1
  repolens.sh --project ~/myapp --agent claude --mode discover
  repolens.sh --project ~/myapp --agent claude --mode discover --focus monetization
  repolens.sh --project https://github.com/org/repo.git --agent claude --max-issues 3
  repolens.sh --project /srv/myapp --agent claude --mode deploy
  repolens.sh --project /srv/myapp --agent claude --mode deploy --deploy-target server
  repolens.sh --project /srv/myapp --agent claude --mode deploy --focus tls-certificates
  repolens.sh --project /srv/myapp --agent claude --mode deploy --parallel --max-issues 5
  repolens.sh --project ~/myapp --agent claude --change "Switching from REST to GraphQL"
  repolens.sh --project ~/myapp --agent claude --change "Adding WCAG 2.2 AA compliance" --domain frontend
  repolens.sh --project ~/myapp --agent claude --change "Dropping IE11 support" --parallel
  repolens.sh --project ~/myapp --agent claude --mode opensource
  repolens.sh --project ~/myapp --agent claude --mode opensource --focus license-compliance
  repolens.sh --project ~/myapp --agent claude --mode content
  repolens.sh --project ~/myapp --agent claude --mode content --source ~/docs/math-book.pdf
  repolens.sh --project ~/myapp --agent claude --mode content --source ~/docs/curriculum.md --spec lesson-format.md
  repolens.sh --project ~/myapp --agent claude --mode audit --source ~/docs/threat-report.pdf
  repolens.sh --project ~/myapp --agent claude --mode content --focus topic-extraction --source ~/docs/textbook.pdf
  repolens.sh --project ~/myapp --agent claude --mode bugreport --bug-report ~/reports/crash-on-login.txt
  repolens.sh --project ~/myapp --agent claude --mode audit --cross-link suggest-reopen
  repolens.sh --project ~/AutoDev --agent claude --logs ~/CybersecurityAssessment/logs/auto-develop/ --domain logs --parallel
  repolens.sh --project ~/myapp --agent claude --hosted --domain toolgate
  repolens.sh --project ~/myapp --agent claude --hosted --focus dast-web
  repolens.sh --project ~/myapp --agent claude --local
  repolens.sh --project ~/myapp --agent claude --local --output ~/reports/myapp-audit
  repolens.sh --project ~/myapp --agent claude --local --domain security --parallel

Environment:
  REPOLENS_AGENT_TIMEOUT   Global per-invocation timeout override in seconds.
                           Wins over every mode-specific value; agent-specific
                           values below win over this global value.
  REPOLENS_AGENT_TIMEOUT_CLAUDE
                           Claude per-invocation timeout override.
  REPOLENS_AGENT_TIMEOUT_CODEX
                           Codex per-invocation timeout override.
  REPOLENS_AGENT_TIMEOUT_OPENCODE
                           OpenCode per-invocation timeout override; also used
                           for opencode/<model>.
  REPOLENS_AGENT_TIMEOUT_SPARK
                           Codex Spark per-invocation timeout override; also
                           applies to the sparc alias when SPARC is unset.
  REPOLENS_AGENT_TIMEOUT_SPARC
                           SPARC alias timeout override; also applies to spark
                           when SPARK is unset.
  REPOLENS_AGENT_TIMEOUT_AUDIT
                           Audit default: 1800.
  REPOLENS_AGENT_TIMEOUT_FEATURE
                           Feature default: 1800.
  REPOLENS_AGENT_TIMEOUT_BUGFIX
                           Bugfix default: 1800.
  REPOLENS_AGENT_TIMEOUT_DISCOVER
                           Discover default: 1800.
  REPOLENS_AGENT_TIMEOUT_DEPLOY
                           Deploy default: 1800.
  REPOLENS_AGENT_TIMEOUT_CUSTOM
                           Custom/change-impact default: 1800.
  REPOLENS_AGENT_TIMEOUT_OPENSOURCE
                           Open-source readiness default: 1800.
  REPOLENS_AGENT_TIMEOUT_CONTENT
                           Content default: 1800.
  REPOLENS_AGENT_TIMEOUT_BUGREPORT
                           Bug report default: 1800.
  REPOLENS_BUG_REPORT_PATH Fallback for --bug-report when the CLI flag is unset.
                           Path to a text file read verbatim as the bug report.
  REPOLENS_AGENT_KILL_GRACE
                           Seconds after an agent timeout to wait after SIGTERM
                           before timeout(1) escalates to SIGKILL (default: 30).
  REPOLENS_LENS_MAX_WALL   Per-lens wall-clock budget in seconds (default: 3600).
                           Each agent invocation is capped to the remaining
                           lens budget; exhausted lenses stop with max-wall.
                           Raw worst-case wall time is timeout * iterations:
                           with defaults, 30 min * 20 = 10 hours before this
                           wall budget is applied.
  REPOLENS_RATE_LIMIT_MAX_SLEEP
                           Maximum parsed agent rate-limit wait in seconds
                           before falling back to abort behavior (default: 21600).
  REPOLENS_CHILD_MAX_WAIT  Per-child parallel-worker deadline in seconds
                           (default: 144000). Outer safety net for parallel mode:
                           wait_all polls each background lens and SIGTERM/KILLs
                           any child that exceeds this deadline, then continues
                           with the remaining children. Should be >=
                           the lens wall budget plus a buffer for rate-limit
                           sleep and non-agent I/O.
  DONE_STREAK_REQUIRED     DEPRECATED alias for --depth. Used only when --depth
                           is unset; must be between 1 and 19.
  REPOLENS_ROUNDS          Fallback for --rounds when the CLI flag is unset.
                           Must be a positive integer within the mode cap.
  REPOLENS_MIN_SEVERITY    Fallback for --min-severity when the CLI flag is
                           unset. Accepted values: critical, high, medium, low.
  REPOLENS_MAX_ROUNDS      Cross-mode hard ceiling for --rounds (default: 5).
                           --rounds >= REPOLENS_MAX_ROUNDS aborts unconditionally,
                           regardless of any CLI flag or --i-know-this-is-expensive
                           ack. Raise this value in CI when high rounds are
                           intentional. Must be a positive integer.
  REPOLENS_NO_VERIFIER     Fallback for --no-verifier. Set to "true"/"1" to
                           disable the verifier when the CLI flag is not used.
  REPOLENS_NO_TRIAGE       Fallback for --no-triage. Set to "true"/"1" to
                           disable the triage prefix phase in bugreport mode
                           when the CLI flag is not used.
  REPOLENS_CROSS_LINK      Fallback for --cross-link. Accepts off|comment|
                           suggest-reopen. Used only when the CLI flag is unset.
  REPOLENS_HEARTBEAT_INTERVAL
                           Per-lens heartbeat file interval in seconds
                           (default: 15), and parallel-worker log heartbeat
                           interval in seconds (default: 60). Set to 0 to
                           disable both when this shared variable is used.
  REPOLENS_LENS_HEARTBEAT_INTERVAL
                           Per-lens heartbeat file interval override in
                           seconds. Wins over REPOLENS_HEARTBEAT_INTERVAL.
  REPOLENS_CLEANUP_GRACE   Interrupt cleanup grace in seconds (default: 5).
                           On Ctrl-C or TERM, tracked parallel workers receive
                           SIGTERM, are polled for this grace period, then any
                           remaining workers are SIGKILL'd before cleanup returns.
EOF

  # Dynamic section: list modes, domains, and lenses from config
  local domains_file="$SCRIPT_DIR/config/domains.json"
  local lenses_dir="$SCRIPT_DIR/prompts/lenses"

  if ! [[ -f "$domains_file" ]] || ! command -v jq >/dev/null 2>&1; then
    return
  fi

  # Build lens name lookup keyed by domain/lens-id (single pass over all files)
  declare -A lens_names
  local f
  for f in "$lenses_dir"/*/*.md; do
    [[ -f "$f" ]] || continue
    local ddir lid
    ddir="$(basename "$(dirname "$f")")"
    lid="$(basename "$f" .md)"
    lens_names["${ddir}/${lid}"]="$(sed -n '/^---$/,/^---$/{ /^name:/{ s/^name:[[:space:]]*//; p; q; } }' "$f")"
  done

  echo ""
  echo "Modes:"
  echo "  audit       (default) Code audit — finds issues in existing code"
  echo "  feature     Feature analysis — discovers missing features and improvements"
  echo "  bugfix      Bug hunting — finds potential bugs and defects"
  echo "  discover    Product discovery — brainstorming for product strategy"
  echo "  deploy      Server audit — inspects live server for operational issues"
  echo "  custom      Change impact — analyzes what needs adapting (requires --change)"
  echo "  opensource  Open source readiness — audits if a repo can go public safely"
  echo "  content     Content audit & creation — audits existing content, creates from --source"
  echo "  bugreport   Symptom-driven investigation — runs lenses on a user bug report (requires --bug-report)"

  # Parse all domains in one jq call
  local domain_data
  domain_data="$(jq -r '.domains | sort_by(.order)[] | .id + "|" + .name + "|" + (.mode // "code") + "|" + (.lenses | join(","))' "$domains_file")"

  local code_total=0 discover_total=0 deploy_total=0 opensource_total=0 content_total=0
  local code_output="" discover_output="" deploy_output="" opensource_output="" content_output=""

  while IFS='|' read -r did dname dmode dlenses; do
    IFS=',' read -ra lens_arr <<< "$dlenses"
    local lcount=${#lens_arr[@]}

    local section
    section="$(printf "  %-22s %s (%d lenses)\n" "$did" "$dname" "$lcount")"
    for lid in "${lens_arr[@]}"; do
      section+="$(printf "\n    %-24s %s" "$lid" "${lens_names[${did}/${lid}]:-}")"
    done
    section+=$'\n'

    if [[ "$dmode" == "discover" ]]; then
      discover_total=$((discover_total + lcount))
      discover_output+="$section"$'\n'
    elif [[ "$dmode" == "deploy" ]]; then
      deploy_total=$((deploy_total + lcount))
      deploy_output+="$section"$'\n'
    elif [[ "$dmode" == "opensource" ]]; then
      opensource_total=$((opensource_total + lcount))
      opensource_output+="$section"$'\n'
    elif [[ "$dmode" == "content" ]]; then
      content_total=$((content_total + lcount))
      content_output+="$section"$'\n'
    else
      code_total=$((code_total + lcount))
      code_output+="$section"$'\n'
    fi
  done <<< "$domain_data"

  echo ""
  echo "Domains (audit/feature/bugfix/bugreport/custom — ${code_total} lenses):"
  echo ""
  printf "%s" "$code_output"
  echo "Domains (discover mode — ${discover_total} lenses):"
  echo ""
  printf "%s" "$discover_output"
  echo "Domains (deploy mode — ${deploy_total} lenses):"
  echo ""
  printf "%s" "$deploy_output"
  echo "Domains (opensource mode — ${opensource_total} lenses):"
  echo ""
  printf "%s" "$opensource_output"
  echo "Domains (content mode — ${content_total} lenses):"
  echo ""
  printf "%s" "$content_output"
}

# Dispatch read-only subcommands before normal run validation.
if [[ "${1:-}" == "status" ]]; then
  shift
  status_command "$@"
  exit "$?"
fi

# --- Argument parsing ---
PROJECT_PATH=""
AGENT=""
MODE="audit"
FOCUS=""
DOMAIN_FILTER=""
PARALLEL=false
MAX_PARALLEL=8
RESUME_RUN_ID=""
SPEC_FILE=""
MAX_ISSUES=""
MIN_SEVERITY=""
DEPTH=""
DEPTH_SET=false
ROUNDS=""
ROUNDS_SET=false
NO_VERIFIER=""
NO_VERIFIER_SET=false
NO_TRIAGE=""
NO_TRIAGE_SET=false
CROSS_LINK_MODE=""
CROSS_LINK_MODE_SET=false
CHANGE_STATEMENT=""
BUG_REPORT=""
BUG_REPORT_SET=false
SOURCE_FILE=""
LOGS_PATH=""
HOSTED=false
REMOTE_TARGET=""
REMOTE_USER=""
REMOTE_HOST=""
REMOTE_PORT="22"
REMOTE_KEY=""
REMOTE_LABEL=""
AUTO_YES=false
MAX_COST=""
EXPENSIVE_ACK=false
DRY_RUN=false
LOCAL_MODE=false
DEPLOY_TARGET="auto"
DEPLOY_TARGET_SET=false
BUILD_ANDROID_APK=false
OUTPUT_DIR=""
OUTPUT_DIR_SET=false
FORGE_PROVIDER=""
FORGE_HOST=""
FORGE_REPO_SLUG=""
FORGE_PROJECT_PATH=""
FORGE_REMOTE_NAME="origin"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      [[ $# -ge 2 ]] || die "Option --project requires an argument."
      PROJECT_PATH="$2"
      shift 2
      ;;
    --agent)
      [[ $# -ge 2 ]] || die "Option --agent requires an argument."
      AGENT="$2"
      shift 2
      ;;
    --mode)
      [[ $# -ge 2 ]] || die "Option --mode requires an argument."
      MODE="$2"
      shift 2
      ;;
    --focus|--lens)
      [[ $# -ge 2 ]] || die "Option $1 requires an argument."
      FOCUS="$2"
      shift 2
      ;;
    --domain)
      [[ $# -ge 2 ]] || die "Option --domain requires an argument."
      DOMAIN_FILTER="$2"
      shift 2
      ;;
    --parallel)
      PARALLEL=true
      shift
      ;;
    --max-parallel)
      [[ $# -ge 2 ]] || die "Option --max-parallel requires an argument."
      MAX_PARALLEL="$2"
      shift 2
      ;;
    --resume)
      [[ $# -ge 2 ]] || die "Option --resume requires an argument."
      RESUME_RUN_ID="$2"
      shift 2
      ;;
    --spec)
      [[ $# -ge 2 ]] || die "Option --spec requires a file path argument."
      SPEC_FILE="$2"
      shift 2
      ;;
    --max-issues)
      [[ $# -ge 2 ]] || die "Option --max-issues requires a positive integer argument."
      MAX_ISSUES="$2"
      shift 2
      ;;
    --min-severity)
      [[ $# -ge 2 ]] || die "Option --min-severity requires an argument (critical|high|medium|low)."
      MIN_SEVERITY="$2"
      shift 2
      ;;
    --depth)
      [[ $# -ge 2 ]] || die "Option --depth requires a positive integer argument."
      DEPTH="$2"
      DEPTH_SET=true
      shift 2
      ;;
    --rounds)
      [[ $# -ge 2 ]] || die "Option --rounds requires a positive integer argument."
      ROUNDS="$2"
      ROUNDS_SET=true
      shift 2
      ;;
    --no-verifier)
      NO_VERIFIER=true
      NO_VERIFIER_SET=true
      shift
      ;;
    --no-triage)
      NO_TRIAGE=true
      NO_TRIAGE_SET=true
      shift
      ;;
    --cross-link)
      [[ $# -ge 2 ]] || die "Option --cross-link requires an argument (off|comment|suggest-reopen)."
      CROSS_LINK_MODE="$2"
      CROSS_LINK_MODE_SET=true
      shift 2
      ;;
    --change)
      [[ $# -ge 2 ]] || die "Option --change requires a statement string."
      CHANGE_STATEMENT="$2"
      shift 2
      ;;
    --bug-report)
      [[ $# -ge 2 ]] || die "Option --bug-report requires a file path or inline text argument."
      if [[ -f "$2" ]]; then
        [[ -r "$2" ]] || die "Bug report file not readable: $2"
        _bug_report_size="$(wc -c < "$2")"
        [[ "$_bug_report_size" -le 102400 ]] || die "Bug report file too large (${_bug_report_size} bytes, max 100KB): $2"
        # shellcheck disable=SC2094
        if ! tr -d '\0' < "$2" | cmp -s - "$2"; then
          die "Bug report file appears to be binary: $2 — only text files are supported."
        fi
        BUG_REPORT="$(cat "$2")"
        unset _bug_report_size
      else
        BUG_REPORT="$2"
      fi
      BUG_REPORT_SET=true
      shift 2
      ;;
    --source)
      [[ $# -ge 2 ]] || die "Option --source requires a file path argument."
      SOURCE_FILE="$2"
      shift 2
      ;;
    --logs)
      [[ $# -ge 2 ]] || die "Option --logs requires a file or directory path argument."
      LOGS_PATH="$2"
      shift 2
      ;;
    --hosted)
      HOSTED=true
      shift
      ;;
    --remote)
      [[ $# -ge 2 ]] || die "Option --remote requires an argument."
      REMOTE_TARGET="$2"
      shift 2
      ;;
    --remote-key)
      [[ $# -ge 2 ]] || die "Option --remote-key requires a path argument."
      REMOTE_KEY="$2"
      shift 2
      ;;
    --remote-label)
      [[ $# -ge 2 ]] || die "Option --remote-label requires a text argument."
      shift
      REMOTE_LABEL="$1"
      shift
      while [[ $# -gt 0 && "$1" != --* ]]; do
        REMOTE_LABEL+=" $1"
        shift
      done
      ;;
    --yes|-y)
      AUTO_YES=true
      shift
      ;;
    --local)
      LOCAL_MODE=true
      shift
      ;;
    --deploy-target)
      [[ $# -ge 2 ]] || die "Option --deploy-target requires an argument."
      DEPLOY_TARGET="$2"
      DEPLOY_TARGET_SET=true
      shift 2
      ;;
    --build-android-apk)
      BUILD_ANDROID_APK=true
      shift
      ;;
    --output)
      [[ $# -ge 2 ]] || die "Option --output requires a path argument."
      OUTPUT_DIR="$2"
      # shellcheck disable=SC2034
      OUTPUT_DIR_SET=true
      shift 2
      ;;
    --forge)
      [[ $# -ge 2 ]] || die "Option --forge requires an argument (gh|tea|fj)."
      FORGE_PROVIDER="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --max-cost)
      [[ $# -ge 2 ]] || die "Option --max-cost requires a dollar amount."
      MAX_COST="$2"
      shift 2
      ;;
    --i-know-this-is-expensive)
      EXPENSIVE_ACK=true
      shift
      ;;
    --version)
      show_version
      exit 0
      ;;
    --about)
      show_about
      exit 0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

# --- Validate required args ---
[[ -n "$AGENT" ]] || { usage; die "Missing required argument: --agent"; }
[[ -n "$PROJECT_PATH" ]] || { usage; die "Missing required argument: --project"; }

# --- Validate --output requires --local ---
if [[ -n "$OUTPUT_DIR" ]] && ! $LOCAL_MODE; then
  die "--output requires --local (use --local to write findings as local markdown files)"
fi

# --- Handle --change flag ---
if [[ -n "$CHANGE_STATEMENT" ]]; then
  if [[ "$MODE" != "audit" && "$MODE" != "custom" ]]; then
    die "--change cannot be combined with --mode $MODE (it implies --mode custom)"
  fi
  MODE="custom"
fi

# --- Validate mode ---
case "$MODE" in
  audit|feature|bugfix|bugreport|discover|deploy|custom|opensource|content) ;;
  *) die "Invalid mode: $MODE (expected 'audit', 'feature', 'bugfix', 'bugreport', 'discover', 'deploy', 'custom', 'opensource', or 'content')" ;;
esac

parse_remote_target() {
  local target="$1"
  [[ "$target" =~ ^[A-Za-z0-9._@:-]+$ ]] || die "Invalid --remote target: $target"

  REMOTE_TARGET="$target"
  REMOTE_USER=""
  REMOTE_HOST=""
  REMOTE_PORT="22"

  local hostpart="$target"
  if [[ "$hostpart" == *@* ]]; then
    REMOTE_USER="${hostpart%@*}"
    hostpart="${hostpart##*@}"
    [[ -n "$REMOTE_USER" ]] || die "Invalid --remote target: $target"
  fi

  if [[ "$hostpart" == *:* ]]; then
    REMOTE_HOST="${hostpart%:*}"
    REMOTE_PORT="${hostpart##*:}"
  else
    REMOTE_HOST="$hostpart"
  fi

  [[ -n "$REMOTE_HOST" ]] || die "Invalid --remote target: $target"
  [[ "$REMOTE_PORT" =~ ^[0-9]+$ ]] || die "Invalid --remote port: $REMOTE_PORT"
  export REMOTE_TARGET REMOTE_USER REMOTE_HOST REMOTE_PORT
}

template_var_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//|/\\|}"
  printf '%s' "$value"
}

# --- Validate deploy target intent ---
if $DEPLOY_TARGET_SET && [[ "$MODE" != "deploy" ]]; then
  die "--deploy-target requires --mode deploy"
fi
if [[ -n "$REMOTE_TARGET" && "$MODE" != "deploy" ]]; then
  die "--remote requires --mode deploy"
fi
if [[ -n "$REMOTE_TARGET" && "$HOSTED" == "true" ]]; then
  die "--remote and --hosted are mutually exclusive"
fi
case "$DEPLOY_TARGET" in
  auto|server|android) ;;
  *) die "Invalid --deploy-target: $DEPLOY_TARGET (expected auto, server, or android)" ;;
esac
if [[ -n "$REMOTE_TARGET" ]]; then
  parse_remote_target "$REMOTE_TARGET"
fi
if [[ -n "$REMOTE_KEY" && ! -f "$REMOTE_KEY" ]]; then
  die "Remote key file does not exist or is not a regular file: $REMOTE_KEY"
fi
export REMOTE_KEY REMOTE_LABEL
if [[ -n "$REMOTE_TARGET" ]]; then
  REPOLENS_REMOTE_TARGET="$REMOTE_TARGET"
  REPOLENS_REMOTE_LABEL="${REMOTE_LABEL:-$REMOTE_TARGET}"
  REPOLENS_REMOTE_SSH_SOCKET="${REPOLENS_REMOTE_SSH_SOCKET:-none}"
  export REPOLENS_REMOTE_TARGET REPOLENS_REMOTE_LABEL REPOLENS_REMOTE_SSH_SOCKET
fi

# --- Handle --bug-report flag ---
if $BUG_REPORT_SET && [[ "$MODE" != "bugreport" ]]; then
  die "--bug-report requires --mode bugreport (got --mode $MODE)"
fi

if [[ "$MODE" == "bugreport" ]]; then
  if ! $BUG_REPORT_SET && [[ -z "$BUG_REPORT" ]] && [[ -n "${REPOLENS_BUG_REPORT_PATH:-}" ]]; then
    [[ -f "$REPOLENS_BUG_REPORT_PATH" ]] || die "REPOLENS_BUG_REPORT_PATH points to a non-existent file: $REPOLENS_BUG_REPORT_PATH"
    [[ -r "$REPOLENS_BUG_REPORT_PATH" ]] || die "REPOLENS_BUG_REPORT_PATH points to an unreadable file: $REPOLENS_BUG_REPORT_PATH"
    _bug_report_env_size="$(wc -c < "$REPOLENS_BUG_REPORT_PATH")"
    [[ "$_bug_report_env_size" -le 102400 ]] || die "Bug report file too large (${_bug_report_env_size} bytes, max 100KB): $REPOLENS_BUG_REPORT_PATH"
    # shellcheck disable=SC2094
    if ! tr -d '\0' < "$REPOLENS_BUG_REPORT_PATH" | cmp -s - "$REPOLENS_BUG_REPORT_PATH"; then
      die "Bug report file appears to be binary: $REPOLENS_BUG_REPORT_PATH — only text files are supported."
    fi
    BUG_REPORT="$(cat "$REPOLENS_BUG_REPORT_PATH")"
    BUG_REPORT_SET=true
    unset _bug_report_env_size
  fi
fi

if $ROUNDS_SET; then
  validate_rounds "$MODE" "$ROUNDS" "--rounds"
elif [[ ${REPOLENS_ROUNDS+x} ]]; then
  ROUNDS="$REPOLENS_ROUNDS"
  validate_rounds "$MODE" "$ROUNDS" "REPOLENS_ROUNDS"
else
  ROUNDS="$(mode_default_rounds "$MODE")"
  validate_rounds "$MODE" "$ROUNDS" "--rounds"
fi

if [[ -z "$MIN_SEVERITY" && ${REPOLENS_MIN_SEVERITY+x} ]]; then
  MIN_SEVERITY="$REPOLENS_MIN_SEVERITY"
fi

# --- Cross-mode hard ceiling for --rounds (CI cost-runaway safety net) ---
# REPOLENS_MAX_ROUNDS is independent of the per-mode ROUNDS_CAP_BY_MODE caps in
# lib/core.sh; it is an additional ceiling that applies across every mode and
# can be raised in CI by exporting a higher value. Uses >= semantics per the
# issue's test plan: with the default of 5, --rounds 5 already aborts.
REPOLENS_MAX_ROUNDS="${REPOLENS_MAX_ROUNDS:-5}"
if ! [[ "$REPOLENS_MAX_ROUNDS" =~ ^[1-9][0-9]*$ ]]; then
  die "REPOLENS_MAX_ROUNDS must be a positive integer, got: $REPOLENS_MAX_ROUNDS"
fi
if (( ROUNDS >= REPOLENS_MAX_ROUNDS )); then
  die "--rounds $ROUNDS >= REPOLENS_MAX_ROUNDS=$REPOLENS_MAX_ROUNDS (cross-mode safety ceiling). Override by exporting REPOLENS_MAX_ROUNDS=<higher>."
fi

# --- Resolve --no-verifier ---
# Verifier runs once after run_rounds completes and before the synthesizer.
# Default ON only for bugreport mode, where evidence accuracy is critical and
# the cost of filing a bug report on bad evidence is high. Every other mode
# defaults OFF; lens-level DONE x3 already provides per-lens self-verification
# and the verifier roughly doubles agent spend on a run-wide basis.
if $NO_VERIFIER_SET; then
  : # explicit CLI flag wins
elif [[ -n "${REPOLENS_NO_VERIFIER:-}" ]]; then
  case "${REPOLENS_NO_VERIFIER,,}" in
    1|true|yes|on) NO_VERIFIER=true ;;
    0|false|no|off|"") NO_VERIFIER=false ;;
    *) die "REPOLENS_NO_VERIFIER must be a boolean (true/false), got: $REPOLENS_NO_VERIFIER" ;;
  esac
else
  case "$MODE" in
    bugreport) NO_VERIFIER=false ;;
    *) NO_VERIFIER=true ;;
  esac
fi

# --- Resolve --no-triage ---
# Triage runs once before run_rounds and only does work in bugreport mode.
# Default OFF only for bugreport, where the round-0 context pack saves every
# round-1 lens from independently re-discovering the same surface-level history.
# Every other mode defaults ON: no triage prompt is composed and no agent call
# is spent. CLI flag wins, then env var, then mode-driven default.
if $NO_TRIAGE_SET; then
  : # explicit CLI flag wins
elif [[ -n "${REPOLENS_NO_TRIAGE:-}" ]]; then
  case "${REPOLENS_NO_TRIAGE,,}" in
    1|true|yes|on) NO_TRIAGE=true ;;
    0|false|no|off|"") NO_TRIAGE=false ;;
    *) die "REPOLENS_NO_TRIAGE must be a boolean (true/false), got: $REPOLENS_NO_TRIAGE" ;;
  esac
else
  case "$MODE" in
    bugreport) NO_TRIAGE=false ;;
    *) NO_TRIAGE=true ;;
  esac
fi

# --- Resolve --cross-link ---
# Synthesizer cross-link behavior: how to react when a newly synthesized
# cluster matches (or supersedes) an existing open/closed issue.
#   off            — emit nothing.
#   comment        — comment on open issues subsumed by new findings.
#   suggest-reopen — additionally file repolens:reopen-candidate issues for
#                    closed issues with freshly relevant evidence.
# RepoLens never auto-reopens. CLI flag wins, then env var, then mode default.
if $CROSS_LINK_MODE_SET; then
  : # explicit CLI flag wins
elif [[ -n "${REPOLENS_CROSS_LINK:-}" ]]; then
  CROSS_LINK_MODE="$REPOLENS_CROSS_LINK"
else
  case "$MODE" in
    bugreport) CROSS_LINK_MODE="comment" ;;
    *) CROSS_LINK_MODE="off" ;;
  esac
fi

case "$CROSS_LINK_MODE" in
  off|comment|suggest-reopen) ;;
  *) die "Invalid value for --cross-link: '$CROSS_LINK_MODE' (expected 'off', 'comment', or 'suggest-reopen')" ;;
esac

export CROSS_LINK_MODE

CURRENT_ROUND_INDEX=""
CURRENT_ROUND_TOTAL=""
CURRENT_ROUND_OUTPUT_DIR=""
PRIOR_ROUND_DIGEST_FILE=""
HYPOTHESES_TO_VERIFY_FILE=""

AGENT_TIMEOUT_SECS="$(resolve_agent_timeout "$MODE" "$AGENT")"
AGENT_KILL_GRACE_SECS="$(resolve_agent_kill_grace)"
LENS_MAX_WALL_SECS="$(resolve_lens_max_wall)"
if [[ ! "$AGENT_TIMEOUT_SECS" =~ ^[1-9][0-9]*$ ]]; then
  die "REPOLENS_AGENT_TIMEOUT must resolve to a positive integer number of seconds"
fi
AGENT_TIMEOUT_SECS=$((10#$AGENT_TIMEOUT_SECS))
if [[ ! "$AGENT_KILL_GRACE_SECS" =~ ^[0-9]+$ || "$AGENT_KILL_GRACE_SECS" -le 0 ]]; then
  die "REPOLENS_AGENT_KILL_GRACE must be a positive integer number of seconds"
fi
AGENT_KILL_GRACE_SECS=$((10#$AGENT_KILL_GRACE_SECS))
RATE_LIMIT_MAX_SLEEP_SECS="${REPOLENS_RATE_LIMIT_MAX_SLEEP:-21600}"
if [[ ! "$RATE_LIMIT_MAX_SLEEP_SECS" =~ ^[0-9]+$ ]]; then
  die "REPOLENS_RATE_LIMIT_MAX_SLEEP must be a non-negative integer number of seconds"
fi
RATE_LIMIT_MAX_SLEEP_SECS=$((10#$RATE_LIMIT_MAX_SLEEP_SECS))

# --- Validate --change requirement ---
if [[ "$MODE" == "custom" && -z "$CHANGE_STATEMENT" ]]; then
  die "Mode 'custom' requires --change \"your change statement\""
fi

# --- Validate --bug-report requirement ---
# Resume runs may rehydrate BUG_REPORT from logs/<run-id>/bug-report.txt later;
# defer the empty-bug-report check until after resume rehydration.
if [[ "$MODE" == "bugreport" && -z "$BUG_REPORT" && -z "$RESUME_RUN_ID" ]]; then
  die "Mode 'bugreport' requires --bug-report <file|text> (or REPOLENS_BUG_REPORT_PATH env var)"
fi

# --- Handle remote repository URL ---
CLONE_DIR=""

_cleanup_clone() {
  if [[ -n "${CLONE_DIR:-}" && -d "$CLONE_DIR" ]]; then
    chmod -R u+w "$CLONE_DIR" 2>/dev/null
    rm -rf "$CLONE_DIR"
  fi
}
_cleanup_all() {
  stop_status_updater "${REPOLENS_FINAL_STATE:-finished}" 2>/dev/null || true
  if $HOSTED 2>/dev/null; then
    cleanup_hosted "${RUN_ID:-}" 2>/dev/null
  fi
  _cleanup_clone
}
trap _cleanup_all EXIT

_handle_interrupt() {
  REPOLENS_FINAL_STATE="interrupted"
  REPOLENS_INTERRUPT_EXIT_CODE=130
  exit 130
}

_handle_termination() {
  REPOLENS_FINAL_STATE="interrupted"
  REPOLENS_INTERRUPT_EXIT_CODE=143
  exit 143
}

trap _handle_interrupt INT
trap _handle_termination TERM

if [[ "$PROJECT_PATH" =~ ^(https://|git@|ssh://|git://) ]]; then
  CLONE_DIR="$(mktemp -d)"
  _repo_basename="$(basename "$PROJECT_PATH" .git)"
  echo "Cloning remote repository: $PROJECT_PATH"
  git clone --depth 1 "$PROJECT_PATH" "$CLONE_DIR/$_repo_basename" || die "Failed to clone: $PROJECT_PATH"
  PROJECT_PATH="$CLONE_DIR/$_repo_basename"

  # Read-only isolation: prevent agent from modifying or executing repo files
  chmod -R a-w "$PROJECT_PATH"
  find "$PROJECT_PATH" -type f -exec chmod a-x {} +
  echo "Read-only isolation applied to clone."
  unset _repo_basename
fi

# --- Deploy target dispatch state (issue #88) ---
# Deploy mode dispatches between two targets:
#   - server : live host inspection (uses the `deployment` domain)
#   - android: APK/source audit      (uses the `android` domain)
#   - auto   : android only when an APK or shallow source marker is detected;
#              otherwise server
# TRUST BOUNDARY: classification must not execute project-controlled build
# tooling (gradlew, gradle, mvnw, etc.) unless the caller explicitly opted in
# with --build-android-apk. APK discovery and source marker checks are pure
# filesystem probes.
TARGET_TYPE="server"
ANDROID_APK_PATH=""
ANDROID_PACKAGE_NAME=""
ANDROID_HAS_DEVICE="false"
ANDROID_DEVICE_ID=""
ANDROID_DEVICE_MODEL=""
ANDROID_BUILT_FROM_SOURCE="false"
ANDROID_SOURCE_BUILDABLE="false"
NO_ANDROID_TARGET_MSG="No APK found and project does not appear to be an Android source tree (no build.gradle / gradlew). Either supply a project containing an APK, an Android source tree, or use --mode deploy with a server target."

android_apk_display_path() {
  _android_log_display_path "${1:-}"
}

# --- Validate project is a git repo ---
_orig_project="$PROJECT_PATH"
# Deploy mode also accepts a direct path to a pre-built .apk file. Resolve
# it for auto/android targets, and rebase PROJECT_PATH onto the APK's parent
# directory so downstream `cd "$PROJECT_PATH"` continues to work. An explicit
# server target uses the parent directory but deliberately skips Android
# handling.
if [[ "$MODE" == "deploy" && -f "$PROJECT_PATH" && "$PROJECT_PATH" == *.apk ]]; then
  _apk_dir="$(cd "$(dirname "$PROJECT_PATH")" 2>/dev/null && pwd)" || die "Cannot access project path: $_orig_project"
  PROJECT_PATH="$_apk_dir"
  if [[ "$DEPLOY_TARGET" != "server" ]]; then
    ANDROID_APK_PATH="$_apk_dir/$(basename "$_orig_project")"
    TARGET_TYPE="android"
  fi
  unset _apk_dir
else
  PROJECT_PATH="$(cd "$PROJECT_PATH" 2>/dev/null && pwd)" || die "Cannot access project path: $_orig_project"
fi
if [[ "$MODE" != "deploy" ]]; then
  git -C "$PROJECT_PATH" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not a git repository: $PROJECT_PATH"
fi

# --- Classify deploy target ---
# Explicit server skips all Android discovery, marker checks, and build
# handling. Auto and explicit Android use only pure filesystem probes for
# classification; optional source builds remain behind --build-android-apk and
# never demote an already selected Android target back to server.
if [[ "$MODE" == "deploy" && "$DEPLOY_TARGET" != "server" ]]; then
  if [[ "$TARGET_TYPE" != "android" ]]; then
    _discovered_apk="$(discover_android_apk "$PROJECT_PATH" 2>/dev/null || true)"
    if [[ -n "$_discovered_apk" ]]; then
      ANDROID_APK_PATH="$_discovered_apk"
      TARGET_TYPE="android"
    fi
    unset _discovered_apk
  fi

  if [[ -z "$ANDROID_APK_PATH" ]] && android_project_appears_buildable "$PROJECT_PATH"; then
    ANDROID_SOURCE_BUILDABLE="true"
    TARGET_TYPE="android"
  fi

  if [[ "$DEPLOY_TARGET" == "android" && "$TARGET_TYPE" != "android" ]]; then
    printf '%s\n' "$NO_ANDROID_TARGET_MSG"
    exit 0
  fi

fi

if [[ -n "$REMOTE_TARGET" && "$MODE" == "deploy" && "${TARGET_TYPE:-server}" == "android" ]]; then
  die "--remote is incompatible with android deploy targets"
fi

export_android_deploy_env() {
  REPOLENS_DEPLOY_TARGET_KIND="${TARGET_TYPE:-server}"
  REPOLENS_ANDROID_APK_PATH="${ANDROID_APK_PATH:-}"
  export TARGET_TYPE ANDROID_APK_PATH ANDROID_PACKAGE_NAME ANDROID_HAS_DEVICE
  export REPOLENS_DEPLOY_TARGET_KIND REPOLENS_ANDROID_APK_PATH
}

refresh_android_metadata() {
  ANDROID_PACKAGE_NAME=""
  ANDROID_HAS_DEVICE="false"
  ANDROID_DEVICE_ID=""
  ANDROID_DEVICE_MODEL=""

  [[ "$MODE" == "deploy" && "$TARGET_TYPE" == "android" && -n "$ANDROID_APK_PATH" ]] || {
    export_android_deploy_env
    return 0
  }

  if command -v aapt >/dev/null 2>&1; then
    ANDROID_PACKAGE_NAME="$(aapt dump badging "$ANDROID_APK_PATH" 2>/dev/null \
      | sed -n "s/^package: name='\([^']*\)'.*/\1/p" | head -1)"
  elif command -v aapt2 >/dev/null 2>&1; then
    ANDROID_PACKAGE_NAME="$(aapt2 dump badging "$ANDROID_APK_PATH" 2>/dev/null \
      | sed -n "s/^package: name='\([^']*\)'.*/\1/p" | head -1)"
  fi
  if command -v adb >/dev/null 2>&1; then
    _android_device_line="$(adb devices -l 2>/dev/null | awk 'NR>1 && $2=="device" {print; exit}')"
    if [[ -n "$_android_device_line" ]]; then
      ANDROID_HAS_DEVICE="true"
      ANDROID_DEVICE_ID="$(awk '{print $1}' <<< "$_android_device_line")"
      ANDROID_DEVICE_MODEL="$(awk '{
        for (i = 1; i <= NF; i++) {
          if ($i ~ /^model:/) {
            sub(/^model:/, "", $i)
            print $i
            exit
          }
        }
      }' <<< "$_android_device_line")"
    fi
    unset _android_device_line
  fi

  export_android_deploy_env
}

maybe_build_android_apk_after_gates() {
  [[ "$MODE" == "deploy" ]] || return 0
  [[ "${TARGET_TYPE:-server}" == "android" ]] || return 0
  [[ -z "${ANDROID_APK_PATH:-}" ]] || return 0
  [[ "${ANDROID_SOURCE_BUILDABLE:-false}" == "true" ]] || return 0

  $BUILD_ANDROID_APK || return 0

  if ! declare -F build_android_apk >/dev/null 2>&1; then
    die "Android APK build requested, but build_android_apk is unavailable"
  fi

  local built_apk build_rc rediscovered_apk
  built_apk="$(build_android_apk "$PROJECT_PATH")"
  build_rc=$?
  if [[ "$build_rc" -ne 0 ]]; then
    die "Android APK build failed with status $build_rc"
  fi

  rediscovered_apk="$(discover_android_apk "$PROJECT_PATH" 2>/dev/null || true)"
  if [[ -n "$rediscovered_apk" ]]; then
    ANDROID_APK_PATH="$rediscovered_apk"
  else
    ANDROID_APK_PATH="$built_apk"
  fi
  ANDROID_BUILT_FROM_SOURCE="true"
  refresh_android_metadata
  log_info "Android deploy APK path after build: $(android_apk_display_path "$ANDROID_APK_PATH")"
}

# Extract Android metadata only after an APK is resolved. All probes are
# read-only; absence of any tool (aapt, adb) leaves the corresponding
# variable at its safe default rather than failing the run.
refresh_android_metadata
# shellcheck disable=SC2034 # Read by forge_* wrappers in lib/forge.sh.
FORGE_PROJECT_PATH="$PROJECT_PATH"
# shellcheck disable=SC2034 # Read by forge_* wrappers in lib/forge.sh.
FORGE_REMOTE_NAME="origin"

# --- Validate spec file ---
if [[ -n "$SPEC_FILE" ]]; then
  [[ -f "$SPEC_FILE" ]] || die "Spec file not found: $SPEC_FILE"
  [[ -r "$SPEC_FILE" ]] || die "Spec file not readable: $SPEC_FILE"
  SPEC_FILE="$(cd "$(dirname "$SPEC_FILE")" && pwd)/$(basename "$SPEC_FILE")"
  _spec_size="$(wc -c < "$SPEC_FILE")"
  [[ "$_spec_size" -le 102400 ]] || die "Spec file too large (${_spec_size} bytes, max 100KB): $SPEC_FILE"
  # Reject binary files (NUL byte check via tr/cmp)
  # shellcheck disable=SC2094  # cmp reads stdin and compares to the file — it never writes.
  if ! tr -d '\0' < "$SPEC_FILE" | cmp -s - "$SPEC_FILE"; then
    die "Spec file appears to be binary: $SPEC_FILE — only text files are supported."
  fi
  unset _spec_size
fi

# --- Validate --hosted prerequisites ---
if $HOSTED; then
  command -v docker >/dev/null 2>&1 || die "--hosted requires Docker to be installed"
  detect_compose_file "$PROJECT_PATH" >/dev/null || die "--hosted requires a docker-compose.yml or compose.yml in the project"
fi

# --- Validate source file ---
if [[ -n "$SOURCE_FILE" ]]; then
  [[ -f "$SOURCE_FILE" ]] || die "Source file not found: $SOURCE_FILE"
  [[ -r "$SOURCE_FILE" ]] || die "Source file not readable: $SOURCE_FILE"
  SOURCE_FILE="$(cd "$(dirname "$SOURCE_FILE")" && pwd)/$(basename "$SOURCE_FILE")"
fi

# --- Validate logs path ---
if [[ -n "$LOGS_PATH" ]]; then
  [[ -e "$LOGS_PATH" ]] || die "Logs path not found: $LOGS_PATH"
  if [[ -d "$LOGS_PATH" ]]; then
    LOGS_PATH="$(cd "$LOGS_PATH" && pwd)"
  else
    LOGS_PATH="$(cd "$(dirname "$LOGS_PATH")" && pwd)/$(basename "$LOGS_PATH")"
  fi
fi

# --- Validate max-issues ---
if [[ -n "$MAX_ISSUES" ]]; then
  [[ "$MAX_ISSUES" =~ ^[1-9][0-9]*$ ]] || die "--max-issues must be a positive integer, got: $MAX_ISSUES"
fi

# --- Validate min-severity ---
if [[ -n "$MIN_SEVERITY" ]]; then
  MIN_SEVERITY_RAW="$MIN_SEVERITY"
  MIN_SEVERITY="$(severity_normalize "$MIN_SEVERITY")"
  [[ -n "$MIN_SEVERITY" ]] || die "--min-severity must be one of critical, high, medium, low; got: $MIN_SEVERITY_RAW"
fi
REPOLENS_MIN_SEVERITY="$MIN_SEVERITY"
export REPOLENS_MIN_SEVERITY

# --- Validate max-cost ---
if [[ -n "$MAX_COST" ]]; then
  [[ "$MAX_COST" =~ ^[0-9]+\.?[0-9]*$ ]] || die "--max-cost must be a numeric value, got: $MAX_COST"
fi

# --- Derive DONE streak threshold ---
DONE_STREAK_REQUIRED_ENV="${DONE_STREAK_REQUIRED:-}"
DONE_STREAK_REQUIRED="$(mode_default_depth "$MODE")"
if [[ -n "$MAX_ISSUES" ]]; then
  DONE_STREAK_REQUIRED=1
fi

# --- Safety cap: maximum iterations per lens ---
MAX_ITERATIONS_PER_LENS=20

validate_done_depth() {
  local source="$1"
  local value="$2"
  local max_depth=$((MAX_ITERATIONS_PER_LENS - 1))

  if [[ ! "$value" =~ ^[1-9][0-9]*$ ]] || (( value >= MAX_ITERATIONS_PER_LENS )); then
    die "$source must be between 1 and $max_depth (exclusive of MAX_ITERATIONS_PER_LENS=$MAX_ITERATIONS_PER_LENS), got: $value"
  fi
}

if [[ -n "$DONE_STREAK_REQUIRED_ENV" ]]; then
  log_warn "DONE_STREAK_REQUIRED is deprecated; use --depth N instead"
fi

if $DEPTH_SET; then
  validate_done_depth "--depth" "$DEPTH"
  DONE_STREAK_REQUIRED="$DEPTH"
elif [[ -n "$DONE_STREAK_REQUIRED_ENV" ]]; then
  validate_done_depth "DONE_STREAK_REQUIRED" "$DONE_STREAK_REQUIRED_ENV"
  DONE_STREAK_REQUIRED="$DONE_STREAK_REQUIRED_ENV"
fi

# --- Derive repo metadata ---
REPO_NAME="$(basename "$PROJECT_PATH")"
REPO_OWNER="$(git -C "$PROJECT_PATH" remote get-url origin 2>/dev/null | sed -E 's#.*/([^/]+)/[^/]+(.git)?$#\1#' || echo "local")"
if [[ -z "$REPO_OWNER" || "$REPO_OWNER" == "$REPO_NAME" ]]; then
  REPO_OWNER="local"
fi

# --- Validate agent and dependencies ---
validate_agent "$AGENT"
require_cmd git
require_cmd jq
require_cmd timeout

case "$AGENT" in
  claude) require_cmd claude ;;
  codex|spark|sparc) require_cmd codex ;;
  opencode|opencode/*) require_cmd opencode ;;
esac

_origin_url="$(git -C "$PROJECT_PATH" remote get-url origin 2>/dev/null || true)"
FORGE_HOST="$(detect_forge_host "$_origin_url")"
FORGE_REPO_SLUG="$(forge_remote_repo_slug "$_origin_url")"
if [[ -z "$FORGE_REPO_SLUG" ]]; then
  FORGE_REPO_SLUG="$REPO_OWNER/$REPO_NAME"
fi

# --- Resolve and validate forge provider ---
if [[ -n "$FORGE_PROVIDER" ]]; then
  case "$FORGE_PROVIDER" in
    gh|tea|fj) ;;
    *) die "Invalid --forge: $FORGE_PROVIDER (expected gh, tea, or fj)" ;;
  esac
else
  FORGE_PROVIDER="$(detect_forge_provider "$_origin_url")"
fi
unset _origin_url

if ! $LOCAL_MODE; then
  if [[ "$FORGE_PROVIDER" == "unknown" ]]; then
    die "Could not detect forge provider from origin remote. Pass --forge <gh|tea|fj> explicitly (required for self-hosted Gitea/Forgejo instances)."
  fi
  if [[ "$FORGE_PROVIDER" == "fj" && -z "${FORGE_HOST:-}" ]]; then
    die "Forgejo fj backend requires an HTTPS or SSH origin remote so RepoLens can pass fj --host; insecure HTTP origins are not supported."
  fi
  require_forge_cli "$FORGE_PROVIDER"
fi

# --- Validate forge auth ---
if ! $LOCAL_MODE; then
  forge_auth_status
fi

# --- Generate or resume run ID ---
if [[ -n "$RESUME_RUN_ID" ]]; then
  RUN_ID="$RESUME_RUN_ID"
else
  RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$(od -An -tx1 -N4 /dev/urandom | tr -d ' \n')"
fi

# --- Directories ---
LOG_BASE="$SCRIPT_DIR/logs/$RUN_ID"
mkdir -p "$LOG_BASE"
HEARTBEAT_DIR="$LOG_BASE/.heartbeat"
mkdir -p "$HEARTBEAT_DIR"
SUMMARY_FILE="$LOG_BASE/summary.json"

# --- Persist / rehydrate bug report for bugreport mode ---
# The resolved bug report is copied verbatim to logs/<run-id>/bug-report.txt so
# the run is fully reproducible from the log dir alone (matches how --spec and
# --source inputs are captured into the run context). On --resume, if the
# caller did not pass a fresh --bug-report, read the persisted copy back so
# downstream lens prompts substitute {{BUG_REPORT}} correctly.
BUG_REPORT_FILE="$LOG_BASE/bug-report.txt"
if [[ "$MODE" == "bugreport" ]]; then
  if [[ -n "$BUG_REPORT" ]]; then
    printf '%s' "$BUG_REPORT" > "$BUG_REPORT_FILE"
  elif [[ -n "$RESUME_RUN_ID" && -f "$BUG_REPORT_FILE" ]]; then
    BUG_REPORT="$(cat "$BUG_REPORT_FILE")"
  fi
  [[ -n "$BUG_REPORT" ]] || die "Mode 'bugreport' could not resolve a bug report (and resume could not recover one from $BUG_REPORT_FILE)"
fi

# Path to the round-0 triage context pack. Populated by run_triage when
# --no-triage is off in bugreport mode; substituted into round-1 lens prompts
# via the {{TRIAGE_CONTEXT_PACK}} slot. When the file is absent (other modes,
# --no-triage, or triage failure) the slot resolves to empty in lens prompts.
TRIAGE_CONTEXT_PACK_FILE="$LOG_BASE/triage/context-pack.md"
DOMAINS_FILE="$SCRIPT_DIR/config/domains.json"
COLORS_FILE="$SCRIPT_DIR/config/label-colors.json"
BASE_PROMPTS_DIR="$SCRIPT_DIR/prompts/_base"
LENSES_DIR="$SCRIPT_DIR/prompts/lenses"

# resolve_base_wrapper — return the absolute path to the base wrapper file
# for the active mode and (deploy-only) target type. Pure path resolver:
# no logging, no filesystem checks, no exit. Caller is responsible for
# verifying the returned path exists on disk.
#
# Routing:
#   MODE=deploy + TARGET_TYPE=android  -> prompts/_base/android.md
#   everything else                    -> prompts/_base/<MODE>.md
#
# TARGET_TYPE is read with a `server` default so this works under `set -u`
# even when the deploy dispatcher hasn't run (non-deploy modes).
resolve_base_wrapper() {
  if [[ "$MODE" == "deploy" && "${TARGET_TYPE:-server}" == "android" ]]; then
    printf '%s\n' "$BASE_PROMPTS_DIR/android.md"
  else
    printf '%s\n' "$BASE_PROMPTS_DIR/$MODE.md"
  fi
}

# --- Resolve local mode output directory ---
if $LOCAL_MODE; then
  if [[ -z "$OUTPUT_DIR" ]]; then
    if ! OUTPUT_DIR="$(round_lens_outputs_dir "$RUN_ID" 1)"; then
      die "Unable to resolve round lens output directory"
    fi
  fi
  mkdir -p "$OUTPUT_DIR"
  OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
fi

# --- Validate config files exist ---
[[ -f "$DOMAINS_FILE" ]] || die "Missing config: $DOMAINS_FILE"
[[ -f "$COLORS_FILE" ]] || die "Missing config: $COLORS_FILE"
# Resolve the base wrapper file once at startup. The pure resolver
# returns the canonical mapping (deploy/android -> android.md, else
# <MODE>.md); we then fall back to deploy.md when the canonical file is
# absent in the deploy/android case so the run can complete with
# degraded server-flavored safety wording until sibling #92 lands.
BASE_WRAPPER_FILE="$(resolve_base_wrapper)"
BASE_WRAPPER_FALLBACK=false
if [[ ! -f "$BASE_WRAPPER_FILE" ]]; then
  if [[ "$MODE" == "deploy" && "${TARGET_TYPE:-server}" == "android" \
        && -f "$BASE_PROMPTS_DIR/deploy.md" ]]; then
    BASE_WRAPPER_FILE="$BASE_PROMPTS_DIR/deploy.md"
    BASE_WRAPPER_FALLBACK=true
  else
    die "Missing base template: $(resolve_base_wrapper)"
  fi
fi

# --- Initialize logging ---
init_logging "$RUN_ID" "$LOG_BASE"

if $BASE_WRAPPER_FALLBACK; then
  log_warn "Base wrapper $BASE_PROMPTS_DIR/android.md missing; falling back to deploy.md (server-flavored safety wording on an Android target)"
fi

log_info "RepoLens run $RUN_ID starting"
log_info "Project: $PROJECT_PATH ($REPO_OWNER/$REPO_NAME)"
log_info "Agent: $AGENT | Mode: $MODE | Parallel: $PARALLEL"
log_info "Agent timeout: ${AGENT_TIMEOUT_SECS}s"
log_info "Agent timeout kill grace: ${AGENT_KILL_GRACE_SECS}s"
log_info "Lens wall-clock budget: ${LENS_MAX_WALL_SECS}s"
[[ -n "$SPEC_FILE" ]] && log_info "Spec: $SPEC_FILE"
[[ -n "$MAX_ISSUES" ]] && log_info "Max issues: $MAX_ISSUES (DONE streak: 1)"
[[ -n "$MIN_SEVERITY" ]] && log_info "Min severity: $MIN_SEVERITY"
[[ "$MODE" == "discover" ]] && log_info "Discover mode: single-pass brainstorming (DONE streak: 1)"
[[ "$MODE" == "deploy" ]] && log_info "Deploy mode: single-pass server audit (DONE streak: 1)"
if [[ "$MODE" == "deploy" && "${TARGET_TYPE:-server}" == "android" && -n "${ANDROID_APK_PATH:-}" ]]; then
  log_info "Android deploy APK path: $(android_apk_display_path "$ANDROID_APK_PATH")"
fi

run_remote_preflight() {
  [[ -n "${REMOTE_TARGET:-}" ]] || return 0

  local remote_dir="$LOG_BASE/.remote"
  local preflight_log="$remote_dir/preflight.log"
  local ssh_args=(-o BatchMode=yes -o ConnectTimeout=5)
  local ssh_target="$REMOTE_HOST"

  mkdir -p "$remote_dir"
  if [[ -n "${REMOTE_KEY:-}" ]]; then
    ssh_args+=(-i "$REMOTE_KEY")
  fi
  if [[ -n "${REMOTE_PORT:-}" ]]; then
    ssh_args+=(-p "$REMOTE_PORT")
  fi
  if [[ -n "${REMOTE_USER:-}" ]]; then
    ssh_target="${REMOTE_USER}@${REMOTE_HOST}"
  fi

  if ssh "${ssh_args[@]}" "$ssh_target" 'hostname && uname -a' > "$preflight_log" 2>&1; then
    log_info "Remote preflight captured: $preflight_log"
    return 0
  fi

  local preflight_rc=$?
  log_warn "Remote preflight failed for $REMOTE_TARGET (exit $preflight_rc); see $preflight_log"
  return "$preflight_rc"
}

[[ "$MODE" == "custom" ]] && log_info "Custom mode: change impact analysis (DONE streak: 1)"
[[ "$MODE" == "opensource" ]] && log_info "Open source mode: readiness audit (DONE streak: 1)"
[[ "$MODE" == "content" ]] && log_info "Content mode: content audit & creation (DONE streak: 1)"
[[ "$MODE" == "bugreport" ]] && log_info "Bug report mode: rounds-driven symptom investigation (rounds: $ROUNDS, DONE streak: $DONE_STREAK_REQUIRED)"
[[ -n "$CHANGE_STATEMENT" ]] && log_info "Change: $CHANGE_STATEMENT"
[[ -n "$SOURCE_FILE" ]] && log_info "Source: $SOURCE_FILE"
[[ -n "$LOGS_PATH" ]] && log_info "Logs: $LOGS_PATH"
$LOCAL_MODE && log_info "Local mode: writing local markdown files to $OUTPUT_DIR"
if $HOSTED; then
  log_info "Hosted mode: spinning up Docker environment..."
  if ! setup_hosted_env "$PROJECT_PATH" "$RUN_ID"; then
    die "Failed to set up hosted environment. Check Docker and compose file."
  fi
  log_info "Hosted environment ready: $HOSTED_SERVICES"
fi

# --- Resolve lens list ---
resolve_lenses() {
  # Mode-aware jq filter: discover sees only discover domains, others exclude
  # them. Deploy mode additionally narrows to a single domain based on
  # TARGET_TYPE so server and Android lens families never co-run.
  local deploy_domain="deployment"
  if [[ "$MODE" == "deploy" && "${TARGET_TYPE:-server}" == "android" ]]; then
    deploy_domain="android"
  fi

  if [[ -n "$FOCUS" ]]; then
    # Single lens mode — find which domain it belongs to. If a domain filter is
    # also present, use it to disambiguate duplicate lens IDs across domains.
    local found_domain=""
    if [[ -n "$DOMAIN_FILTER" ]]; then
      found_domain="$(jq -r --arg lens "$FOCUS" --arg d "$DOMAIN_FILTER" --arg mode "$MODE" --arg deploy_domain "$deploy_domain" \
        '.domains[] | (if $mode == "discover" then select(.mode == "discover") elif $mode == "deploy" then select(.mode == "deploy" and .id == $deploy_domain) elif $mode == "opensource" then select(.mode == "opensource") elif $mode == "content" then select(.mode == "content") else select(.mode != "discover" and .mode != "deploy" and .mode != "opensource" and .mode != "content") end) | select(.id == $d) | select(.lenses[] == $lens) | .id' "$DOMAINS_FILE" | head -1)"
      [[ -n "$found_domain" ]] || die "Lens '$FOCUS' not found in domain '$DOMAIN_FILTER' (mode: $MODE)"
    else
      found_domain="$(jq -r --arg lens "$FOCUS" --arg mode "$MODE" --arg deploy_domain "$deploy_domain" \
        '.domains[] | (if $mode == "discover" then select(.mode == "discover") elif $mode == "deploy" then select(.mode == "deploy" and .id == $deploy_domain) elif $mode == "opensource" then select(.mode == "opensource") elif $mode == "content" then select(.mode == "content") else select(.mode != "discover" and .mode != "deploy" and .mode != "opensource" and .mode != "content") end) | select(.lenses[] == $lens) | .id' "$DOMAINS_FILE" | head -1)"
      [[ -n "$found_domain" ]] || die "Lens '$FOCUS' not found in domains.json (mode: $MODE)"
    fi

    local lens_file="$LENSES_DIR/$found_domain/$FOCUS.md"
    [[ -f "$lens_file" ]] || die "Lens prompt file missing: $lens_file"

    echo "$found_domain/$FOCUS"
    return
  fi

  if [[ -n "$DOMAIN_FILTER" ]]; then
    # Domain filter mode
    local domain_exists=""
    domain_exists="$(jq -r --arg d "$DOMAIN_FILTER" --arg mode "$MODE" --arg deploy_domain "$deploy_domain" \
      '.domains[] | (if $mode == "discover" then select(.mode == "discover") elif $mode == "deploy" then select(.mode == "deploy" and .id == $deploy_domain) elif $mode == "opensource" then select(.mode == "opensource") elif $mode == "content" then select(.mode == "content") else select(.mode != "discover" and .mode != "deploy" and .mode != "opensource" and .mode != "content") end) | select(.id == $d) | .id' "$DOMAINS_FILE")"
    [[ -n "$domain_exists" ]] || die "Domain '$DOMAIN_FILTER' not found in domains.json (mode: $MODE)"

    jq -r --arg d "$DOMAIN_FILTER" \
      '.domains[] | select(.id == $d) | .lenses[] | $d + "/" + .' "$DOMAINS_FILE"
    return
  fi

  # All lenses — ordered by domain order
  jq -r --arg mode "$MODE" --arg deploy_domain "$deploy_domain" \
    '.domains | sort_by(.order)[] | (if $mode == "discover" then select(.mode == "discover") elif $mode == "deploy" then select(.mode == "deploy" and .id == $deploy_domain) elif $mode == "opensource" then select(.mode == "opensource") elif $mode == "content" then select(.mode == "content") else select(.mode != "discover" and .mode != "deploy" and .mode != "opensource" and .mode != "content") end) | .id as $d | .lenses[] | $d + "/" + .' "$DOMAINS_FILE"
}

LENS_LIST=()
resolved_lenses_output=""
if ! resolved_lenses_output="$(resolve_lenses)"; then
  exit 1
fi
if [[ -n "$resolved_lenses_output" ]]; then
  while IFS= read -r lens_entry; do
    LENS_LIST+=("$lens_entry")
  done <<< "$resolved_lenses_output"
fi

TOTAL_LENSES=${#LENS_LIST[@]}
EMPTY_DOMAIN_SELECTED=false
if [[ "$TOTAL_LENSES" -eq 0 ]]; then
  if [[ -n "$DOMAIN_FILTER" ]]; then
    EMPTY_DOMAIN_SELECTED=true
    log_info "Domain '$DOMAIN_FILTER' has no lenses to run."
  else
    die "No lenses to run."
  fi
fi

log_info "Resolved $TOTAL_LENSES lens(es) to run"

# --- Validate all lens files exist ---
for lens_entry in "${LENS_LIST[@]}"; do
  domain="${lens_entry%%/*}"
  lens_id="${lens_entry#*/}"
  lens_file="$LENSES_DIR/$domain/$lens_id.md"
  [[ -f "$lens_file" ]] || die "Missing lens prompt: $lens_file"
done

# --- Round-count mismatch gate on --resume ---
# The original --rounds value of a resumed run is persisted in
# rounds/round-1/metadata.json (written by init_run_layout). If a caller resumes
# with a different --rounds value, the run identity changes silently: extra
# rounds would execute from scratch with stale prior digests, or a smaller
# count would silently stop short. Reject the mismatch with a clear error.
# Legacy pre-#147 runs without per-round metadata are treated as unconstrained.
if [[ -n "$RESUME_RUN_ID" ]]; then
  resume_round1_metadata="$LOG_BASE/rounds/round-1/metadata.json"
  if [[ -f "$resume_round1_metadata" ]]; then
    persisted_rounds_total="$(jq -r '.rounds_total // empty' "$resume_round1_metadata" 2>/dev/null || true)"
    if [[ -n "$persisted_rounds_total" && "$persisted_rounds_total" != "$ROUNDS" ]]; then
      die "Resume of run $RUN_ID was originally executed with --rounds $persisted_rounds_total, cannot resume with --rounds $ROUNDS (round count is part of the run identity)"
    fi
  fi
fi

init_run_layout "$RUN_ID" "$ROUNDS" "$TOTAL_LENSES" "${LENS_LIST[@]}" || die "Unable to initialize round layout"

# --- Check resume state ---
completed_lenses_file="$LOG_BASE/.completed"
touch "$completed_lenses_file"

is_lens_completed() {
  grep -qxF "$1" "$completed_lenses_file" 2>/dev/null
}

mark_lens_completed() {
  echo "$1" >> "$completed_lenses_file"
}

LENS_HEARTBEAT_INTERVAL_DEFAULT=15

resolve_lens_heartbeat_interval() {
  local interval source_name

  if [[ -n "${REPOLENS_LENS_HEARTBEAT_INTERVAL:-}" ]]; then
    interval="$REPOLENS_LENS_HEARTBEAT_INTERVAL"
    source_name="REPOLENS_LENS_HEARTBEAT_INTERVAL"
  elif [[ -n "${REPOLENS_HEARTBEAT_INTERVAL:-}" ]]; then
    interval="$REPOLENS_HEARTBEAT_INTERVAL"
    source_name="REPOLENS_HEARTBEAT_INTERVAL"
  else
    interval="$LENS_HEARTBEAT_INTERVAL_DEFAULT"
    source_name="default"
  fi

  if [[ ! "$interval" =~ ^[0-9]+$ ]]; then
    log_warn "Invalid $source_name='$interval'; using default ${LENS_HEARTBEAT_INTERVAL_DEFAULT}s for per-lens heartbeat files."
    interval="$LENS_HEARTBEAT_INTERVAL_DEFAULT"
  else
    interval=$((10#$interval))
  fi

  printf '%s\n' "$interval"
}

sanitize_heartbeat_component() {
  printf '%s' "$1" | sed 's/[^A-Za-z0-9_.-]/_/g'
}

lens_heartbeat_key() {
  local domain="$1" lens_id="$2"
  local safe_domain safe_lens_id
  safe_domain="$(sanitize_heartbeat_component "$domain")"
  safe_lens_id="$(sanitize_heartbeat_component "$lens_id")"
  printf '%s__%s\n' "$safe_domain" "$safe_lens_id"
}

lens_heartbeat_path() {
  local domain="$1" lens_id="$2"
  printf '%s/%s.json\n' "$HEARTBEAT_DIR" "$(lens_heartbeat_key "$domain" "$lens_id")"
}

lens_heartbeat_iteration_path() {
  local domain="$1" lens_id="$2"
  printf '%s/.%s.iteration\n' "$HEARTBEAT_DIR" "$(lens_heartbeat_key "$domain" "$lens_id")"
}

read_lens_heartbeat_iteration() {
  local iteration_file="$1"
  local iteration=0

  if [[ -f "$iteration_file" ]]; then
    IFS= read -r iteration < "$iteration_file" || iteration=0
  fi
  if [[ ! "$iteration" =~ ^[0-9]+$ ]]; then
    iteration=0
  else
    iteration=$((10#$iteration))
  fi

  printf '%s\n' "$iteration"
}

write_lens_heartbeat_iteration() {
  local iteration_file="$1" iteration="$2"
  local tmp_file="${iteration_file}.tmp.${BASHPID}"

  printf '%s\n' "$iteration" > "$tmp_file" && mv -f "$tmp_file" "$iteration_file"
}

write_lens_heartbeat() {
  local heartbeat_file="$1" run_id="$2" domain="$3" lens_id="$4" owner_pid="$5" iteration="$6" started_at="$7"
  local tmp_file="${heartbeat_file}.tmp.${BASHPID}"

  [[ "$owner_pid" =~ ^[0-9]+$ ]] || owner_pid=0
  [[ "$iteration" =~ ^[0-9]+$ ]] || iteration=0

  jq -cn \
    --arg run_id "$run_id" \
    --arg domain "$domain" \
    --arg lens_id "$lens_id" \
    --arg started_at "$started_at" \
    --arg last_heartbeat_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg state "running" \
    --argjson pid "$owner_pid" \
    --argjson iteration "$iteration" \
    '{
      run_id: $run_id,
      domain: $domain,
      lens_id: $lens_id,
      pid: $pid,
      iteration: $iteration,
      started_at: $started_at,
      last_heartbeat_at: $last_heartbeat_at,
      state: $state
    }' > "$tmp_file" && mv -f "$tmp_file" "$heartbeat_file"
}

start_lens_heartbeat_writer() {
  local __result_var="$1"
  local heartbeat_file="$2" iteration_file="$3" run_id="$4" domain="$5" lens_id="$6" owner_pid="$7" started_at="$8" interval="$9"

  printf -v "$__result_var" '%s' ""
  (( interval > 0 )) || return 0

  (
    heartbeat_sleep_pid=""
    trap '[[ -n "$heartbeat_sleep_pid" ]] && kill "$heartbeat_sleep_pid" 2>/dev/null; exit 0' TERM INT

    while true; do
      command -p sleep "$interval" &
      heartbeat_sleep_pid=$!
      wait "$heartbeat_sleep_pid" 2>/dev/null || exit 0
      heartbeat_sleep_pid=""

      kill -0 "$owner_pid" 2>/dev/null || exit 0
      iteration="$(read_lens_heartbeat_iteration "$iteration_file")"
      write_lens_heartbeat "$heartbeat_file" "$run_id" "$domain" "$lens_id" "$owner_pid" "$iteration" "$started_at" || true
    done
  ) &

  printf -v "$__result_var" '%s' "$!"
}

stop_lens_heartbeat_writer() {
  local writer_pid="$1" heartbeat_file="$2" iteration_file="$3" clean_completion="${4:-false}"

  if [[ "$writer_pid" =~ ^[0-9]+$ ]]; then
    if kill -0 "$writer_pid" 2>/dev/null; then
      kill "$writer_pid" 2>/dev/null || true
    fi
    wait "$writer_pid" 2>/dev/null || true
  fi

  if [[ -n "$iteration_file" ]]; then
    rm -f "${iteration_file}" "${iteration_file}.tmp."*
  fi
  if [[ -n "$heartbeat_file" ]]; then
    rm -f "${heartbeat_file}.tmp."*
  fi
  if [[ "$clean_completion" == "true" && -n "$heartbeat_file" ]]; then
    rm -f "$heartbeat_file"
  fi

  return 0
}

extract_exit_trap_action() {
  local trap_spec="$1"
  [[ -n "$trap_spec" ]] || return 0
  printf '%s\n' "$trap_spec" | sed -n "s/^trap -- '\(.*\)' EXIT$/\1/p"
}

restore_exit_trap() {
  local trap_spec="$1"
  if [[ -n "$trap_spec" ]]; then
    eval "$trap_spec"
  else
    trap - EXIT
  fi
}

run_lens_heartbeat_exit_trap() {
  local previous_action="${_REPOLENS_LENS_PREVIOUS_EXIT_ACTION:-}"

  stop_lens_heartbeat_writer \
    "${_REPOLENS_LENS_HEARTBEAT_WRITER_PID:-}" \
    "${_REPOLENS_LENS_HEARTBEAT_FILE:-}" \
    "${_REPOLENS_LENS_HEARTBEAT_ITERATION_FILE:-}" \
    "false"

  if [[ "$previous_action" == *"sem_token_remove"* ]]; then
    sem_token_remove "${_REPOLENS_LENS_HEARTBEAT_LENS_ENTRY:-}"
  elif [[ -n "$previous_action" ]]; then
    eval "$previous_action"
  fi
}

# --- Cost estimation (token-based, model-aware, repo-size-aware) ---
# Resolve an --agent value to a model id in agent-pricing.json.
# Handles: claude, codex, spark, sparc, opencode, opencode/<model>.
# Unknown opencode/<model> falls back to "opencode-default".
resolve_agent_model() {
  local agent="$1" pricing_file="$2"
  local default_model model_check
  if [[ "$agent" == opencode/* ]]; then
    local requested="${agent#opencode/}"
    model_check="$(jq -r --arg m "$requested" '.models[$m] | .input_per_mtok // empty' "$pricing_file" 2>/dev/null)"
    if [[ -n "$model_check" ]]; then
      echo "$requested"
      return
    fi
    echo "opencode-default"
    return
  fi
  default_model="$(jq -r --arg a "$agent" '.agent_default_model[$a] // empty' "$pricing_file" 2>/dev/null)"
  if [[ -n "$default_model" ]]; then
    echo "$default_model"
  else
    echo "opencode-default"
  fi
}

# Sum bytes of likely-source files in a project path, excluding common vendor dirs.
# Prints integer byte count on stdout. Returns 0 on any failure.
estimate_repo_bytes() {
  local path="$1"
  [[ -d "$path" ]] || { echo 0; return 0; }
  find "$path" -type f \
    \( -name '*.py' -o -name '*.js' -o -name '*.jsx' -o -name '*.ts' -o -name '*.tsx' \
       -o -name '*.mjs' -o -name '*.cjs' -o -name '*.go' -o -name '*.rs' \
       -o -name '*.rb' -o -name '*.java' -o -name '*.kt' -o -name '*.swift' \
       -o -name '*.c' -o -name '*.cpp' -o -name '*.cc' -o -name '*.h' -o -name '*.hpp' \
       -o -name '*.cs' -o -name '*.php' -o -name '*.sh' -o -name '*.bash' -o -name '*.zsh' \
       -o -name '*.html' -o -name '*.htm' -o -name '*.css' -o -name '*.scss' -o -name '*.sass' \
       -o -name '*.vue' -o -name '*.svelte' -o -name '*.dart' -o -name '*.ex' -o -name '*.exs' \
       -o -name '*.clj' -o -name '*.scala' -o -name '*.elm' -o -name '*.sql' \
       -o -name '*.md' -o -name '*.mdx' -o -name '*.rst' -o -name '*.txt' \
       -o -name '*.yml' -o -name '*.yaml' -o -name '*.json' -o -name '*.toml' -o -name '*.xml' \
       -o -name 'Dockerfile' -o -name 'Makefile' -o -name 'CMakeLists.txt' \) \
    -not -path '*/.git/*' -not -path '*/node_modules/*' -not -path '*/vendor/*' \
    -not -path '*/dist/*' -not -path '*/build/*' -not -path '*/.venv/*' \
    -not -path '*/venv/*' -not -path '*/target/*' -not -path '*/.next/*' \
    -not -path '*/coverage/*' -not -path '*/.cache/*' -not -path '*/logs/*' \
    -printf '%s\n' 2>/dev/null \
    | awk 'BEGIN{s=0} {s+=$1} END{print s+0}'
}

# Compute min. cost estimate and emit a rich breakdown block on stdout.
# Args: agent, lens_count, streak_required, project_path, pricing_file.
# Emits a multi-line block whose first line is the min cost dollar string
# prefixed with "MIN_COST="; subsequent lines are human-readable breakdown.
compute_cost_breakdown() {
  local agent="$1" lenses="$2" streak="$3" path="$4" pricing_file="$5" rounds="${6:-1}"

  local model
  model="$(resolve_agent_model "$agent" "$pricing_file")"

  local model_label in_price out_price
  model_label="$(jq -r --arg m "$model" '.models[$m].label // $m' "$pricing_file" 2>/dev/null)"
  in_price="$(jq -r --arg m "$model" '.models[$m].input_per_mtok // 3' "$pricing_file" 2>/dev/null)"
  out_price="$(jq -r --arg m "$model" '.models[$m].output_per_mtok // 15' "$pricing_file" 2>/dev/null)"

  local base_prompt input_cap out_per bytes_per_tok iter_factor
  base_prompt="$(jq -r '.session_model.base_prompt_tokens // 3000' "$pricing_file" 2>/dev/null)"
  input_cap="$(jq -r '.session_model.per_session_input_cap_tokens // 200000' "$pricing_file" 2>/dev/null)"
  out_per="$(jq -r '.session_model.per_session_output_tokens // 8000' "$pricing_file" 2>/dev/null)"
  bytes_per_tok="$(jq -r '.session_model.bytes_per_token // 4' "$pricing_file" 2>/dev/null)"
  iter_factor="$(jq -r '.session_model.iteration_factor // 1.7' "$pricing_file" 2>/dev/null)"

  local repo_bytes repo_tokens
  repo_bytes="$(estimate_repo_bytes "$path")"
  repo_tokens=$((repo_bytes / bytes_per_tok))

  awk -v model_label="$model_label" -v model="$model" \
      -v in_price="$in_price" -v out_price="$out_price" \
      -v base_prompt="$base_prompt" -v input_cap="$input_cap" \
      -v out_per="$out_per" -v repo_tokens="$repo_tokens" \
      -v lenses="$lenses" -v streak="$streak" -v iter_factor="$iter_factor" \
      -v rounds="$rounds" \
      'BEGIN {
        session_input = (repo_tokens < input_cap ? repo_tokens : input_cap) + base_prompt
        cost_per_session = (session_input / 1000000.0) * in_price + (out_per / 1000000.0) * out_price
        avg_iters = streak * iter_factor
        per_round_est = lenses * avg_iters * cost_per_session
        if (rounds < 1) rounds = 1
        est = per_round_est * rounds

        printf "MIN_COST=%.2f\n", est

        # Human-readable summary
        if (repo_tokens >= 1000) {
          repo_k = repo_tokens / 1000.0
          printf "  model:      %s  —  $%.2f in / $%.2f out per MTok\n", model_label, in_price, out_price
          printf "  repo:       ~%.0fk source tokens  (input capped at %dk/session)\n", repo_k, input_cap/1000
        } else {
          printf "  model:      %s  —  $%.2f in / $%.2f out per MTok\n", model_label, in_price, out_price
          printf "  repo:       ~%d source tokens  (input capped at %dk/session)\n", repo_tokens, input_cap/1000
        }
        printf "  per session: ~$%.4f  (~%d in + %d out tokens)\n", cost_per_session, session_input, out_per
        printf "  sessions:   %d lenses x ~%.1f iterations (streak %d x %.1f iter-factor) x %d round(s)\n", lenses, avg_iters, streak, iter_factor, rounds
        if (rounds > 1) {
          printf "  per round:  ~$%.2f  (total = per-round x %d rounds)\n", per_round_est, rounds
          for (r = 1; r <= rounds; r++) {
            printf "    round-%d: ~$%.2f\n", r, per_round_est
          }
        }
      }'
}

# --- Confirmation gate ---
print_android_deploy_preview() {
  [[ "${TARGET_TYPE:-server}" == "android" ]] || return 0

  local apk_display package_display device_display
  apk_display="$(android_apk_display_path "${ANDROID_APK_PATH:-}")"
  package_display="${ANDROID_PACKAGE_NAME:-unknown}"

  if [[ "${ANDROID_HAS_DEVICE:-false}" == "true" && -n "${ANDROID_DEVICE_ID:-}" ]]; then
    device_display="$ANDROID_DEVICE_ID"
    if [[ -n "${ANDROID_DEVICE_MODEL:-}" ]]; then
      device_display+=" (${ANDROID_DEVICE_MODEL})"
    fi
  else
    device_display="none connected - dynamic lenses will report no device and exit cleanly"
  fi

  echo ""
  echo "RepoLens Deploy - Android APK target"
  echo ""
  echo "  APK:        ${apk_display:-unknown}"
  if [[ "${ANDROID_BUILT_FROM_SOURCE:-false}" == "true" ]]; then
    echo "              (built from source via gradlew assembleDebug)"
  fi
  echo "  Package:    $package_display"
  echo "  Device:     $device_display"
  echo ""
  echo "  Domain:     android"
  echo "  Lenses:     $TOTAL_LENSES queued"
  echo "  Agent:      $AGENT"
}

remote_target_display() {
  local display="${REMOTE_HOST}:${REMOTE_PORT}"
  [[ -n "${REMOTE_USER:-}" ]] && display="${REMOTE_USER}@${display}"
  printf '%s' "$display"
}

print_remote_confirmation_context() {
  [[ -n "${REMOTE_TARGET:-}" ]] || return 0

  local socket_display="${REPOLENS_REMOTE_SSH_SOCKET:-<socket>}"
  [[ "$socket_display" == "none" ]] && socket_display="<socket>"

  if [[ -n "${REMOTE_LABEL:-}" ]]; then
    echo "Remote target: ${REMOTE_LABEL}"
    echo "Raw target: ${REMOTE_TARGET}"
  else
    echo "Remote target: $(remote_target_display)"
  fi
  echo "Local commands will be wrapped in: ssh -S ${socket_display} ${REMOTE_TARGET} '...'"
}

confirm_run() {
  if $AUTO_YES; then
    return 0
  fi

  # Non-interactive detection (piped stdin)
  if [[ ! -t 0 ]]; then
    die "Running non-interactively without --yes flag. Use --yes to skip confirmation."
  fi

  local pricing_file="$SCRIPT_DIR/config/agent-pricing.json"
  local breakdown min_cost
  breakdown="$(compute_cost_breakdown "$AGENT" "$TOTAL_LENSES" "$DONE_STREAK_REQUIRED" "$PROJECT_PATH" "$pricing_file" "$ROUNDS")"
  min_cost="$(printf "%s\n" "$breakdown" | awk -F= '/^MIN_COST=/ {print $2; exit}')"
  local breakdown_lines
  breakdown_lines="$(printf "%s\n" "$breakdown" | grep -v '^MIN_COST=')"

  echo ""
  echo "=== RepoLens Confirmation ==="
  echo "Target repo:  $REPO_OWNER/$REPO_NAME"
  print_remote_confirmation_context
  echo "Mode:         $MODE"
  echo "Agent:        $AGENT"
  echo "Lenses:       $TOTAL_LENSES"
  if [[ -n "$MAX_ISSUES" ]]; then
    echo "Max issues:   $MAX_ISSUES"
  else
    echo "Max issues:   (unlimited)"
  fi
  echo ""
  echo "Estimated cost: ~\$${min_cost}  (lens_count=${TOTAL_LENSES} x depth=${DONE_STREAK_REQUIRED} x rounds=${ROUNDS}, lower bound — real runs typically 2-5x higher)"
  printf "%s\n" "$breakdown_lines"
  echo "  Note: Estimator assumes one model per agent, 4 bytes/token, and a"
  echo "  capped per-session input budget. Tool-call churn and iteration"
  echo "  non-convergence push real cost higher. Budget accordingly."

  # Threshold warning
  if [[ -n "$MAX_COST" ]]; then
    local exceeds
    exceeds="$(awk -v est="$min_cost" -v max="$MAX_COST" 'BEGIN { print (est > max) ? 1 : 0 }')"
    if [[ "$exceeds" -eq 1 ]]; then
      echo ""
      echo "WARNING: Min. cost estimate (~\$${min_cost}) exceeds --max-cost threshold (\$${MAX_COST})"
    fi
  fi

  echo ""
  echo "This will run $TOTAL_LENSES analysis agent(s) against the repository above."
  if $LOCAL_MODE; then
    echo "Findings will be written as local markdown files to: $OUTPUT_DIR"
  else
    echo "Each agent may create remote issues directly on the active forge."
  fi
  print_android_deploy_preview
  echo ""
  read -rp "Proceed? [y/N] " answer
  case "$answer" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) echo "Aborted."; exit 0 ;;
  esac
}

# --- Deploy authorization gate ---
confirm_deploy_authorization() {
  [[ "$MODE" == "deploy" ]] || return 0

  if $AUTO_YES; then
    return 0
  fi

  if [[ ! -t 0 ]]; then
    die "Deploy mode requires authorization confirmation. Use --yes to skip (implies you accept responsibility)."
  fi

  echo ""
  echo "=== Deploy Mode — Authorization Required ==="
  echo ""
  if [[ "${TARGET_TYPE:-server}" == "android" ]]; then
    echo "Deploy mode runs read-only inspection commands against an Android APK"
    echo "and may inspect the project source directory."
  else
    echo "Deploy mode runs read-only inspection commands on a live server"
    echo "(e.g., systemctl, journalctl, ss, df)."
  fi
  echo ""
  print_remote_confirmation_context
  [[ -n "${REMOTE_TARGET:-}" ]] && echo ""
  echo "WARNING: Running this against infrastructure you do not own or"
  echo "are not authorized to audit may violate computer crime laws,"
  echo "including §202a StGB (DE), the Computer Fraud and Abuse Act (US),"
  echo "and similar legislation in other jurisdictions."
  echo ""
  read -rp "I confirm I am authorized to audit this deploy target [y/N] " answer
  case "$answer" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) echo "Aborted — deploy mode requires explicit authorization."; exit 0 ;;
  esac
}

# --- Autonomous mode gate (claude-only) ---
confirm_autonomous_mode() {
  [[ "$AGENT" == "claude" ]] || return 0

  if $AUTO_YES; then
    return 0
  fi

  if [[ ! -t 0 ]]; then
    die "Running non-interactively without --yes flag. Use --yes to skip confirmation."
  fi

  echo ""
  echo "=== Autonomous Mode ==="
  echo ""
  echo "RepoLens passes --dangerously-skip-permissions to the Claude CLI."
  echo "Despite its name, this flag ONLY skips interactive permission prompts"
  echo "(file reads, shell commands). It does NOT disable safety filters,"
  echo "content guardrails, or ethical guidelines."
  echo ""
  echo "Safety is enforced through prompt instructions that restrict agents"
  echo "to read-only code analysis and active forge issue creation commands."
  echo ""
  read -rp "I understand what --dangerously-skip-permissions does [y/N] " answer
  case "$answer" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) echo "Aborted."; exit 0 ;;
  esac
}

# --- High-rounds explicit-ack gate ---
# rounds >= 4 require either (--max-cost AND --yes) or --i-know-this-is-expensive.
# This fires before --dry-run output too: a misconfigured CI runner with
# --rounds 5 --dry-run still signals someone is about to drop --dry-run next.
# Does NOT bypass REPOLENS_MAX_ROUNDS (the ceiling fires earlier, above).
if (( ROUNDS >= 4 )) && ! $EXPENSIVE_ACK; then
  if [[ -z "$MAX_COST" ]] || ! $AUTO_YES; then
    die "rounds >= 4 requires --max-cost <USD> AND --yes (or pass --i-know-this-is-expensive)"
  fi
fi

# --- Dry-run output ---
if $DRY_RUN; then
  echo ""
  echo "=== Dry Run ==="
  echo "Mode:         $MODE"
  echo "Agent:        $AGENT"
  echo "Project:      $PROJECT_PATH"
  echo "Rounds:      $ROUNDS"
  echo "Lenses:       $TOTAL_LENSES"
  if [[ -n "$REMOTE_TARGET" ]]; then
    if [[ -n "$REMOTE_KEY" ]]; then
      echo "Remote target: $(remote_target_display) (key: $REMOTE_KEY)"
    else
      echo "Remote target: $(remote_target_display)"
    fi
  fi
  if $LOCAL_MODE; then
    echo "Output:       local markdown ($OUTPUT_DIR)"
  fi
  echo ""
  if [[ "$TOTAL_LENSES" -gt 0 ]]; then
    _dry_pricing_file="$SCRIPT_DIR/config/agent-pricing.json"
    if [[ -f "$_dry_pricing_file" ]]; then
      _dry_breakdown="$(compute_cost_breakdown "$AGENT" "$TOTAL_LENSES" "$DONE_STREAK_REQUIRED" "$PROJECT_PATH" "$_dry_pricing_file" "$ROUNDS")"
      _dry_min_cost="$(printf "%s\n" "$_dry_breakdown" | awk -F= '/^MIN_COST=/ {print $2; exit}')"
      _dry_breakdown_lines="$(printf "%s\n" "$_dry_breakdown" | grep -v '^MIN_COST=')"
      echo "Estimated cost: ~\$${_dry_min_cost}  (lens_count=${TOTAL_LENSES} x depth=${DONE_STREAK_REQUIRED} x rounds=${ROUNDS}, lower bound — real runs typically 2-5x higher)"
      printf "%s\n" "$_dry_breakdown_lines"
      unset _dry_pricing_file _dry_breakdown _dry_min_cost _dry_breakdown_lines
      echo ""
    fi
  fi
  echo "Lenses that would run:"
  for lens_entry in "${LENS_LIST[@]}"; do
    echo "  $lens_entry"
  done
  echo ""
  echo "Dry run complete — no agents were executed."
  exit 0
fi

if $EMPTY_DOMAIN_SELECTED; then
  log_info "No lenses queued for domain '$DOMAIN_FILTER'; exiting cleanly."
  echo "No lenses to run for domain '$DOMAIN_FILTER'."
  exit 0
fi

confirm_autonomous_mode
confirm_deploy_authorization
confirm_run
run_remote_preflight || true
maybe_build_android_apk_after_gates

# --- Ensure forge labels ---
ensure_labels() {
  log_info "Ensuring forge labels exist..."
  local label_prefix
  case "$MODE" in
    audit)    label_prefix="audit" ;;
    feature)  label_prefix="feature" ;;
    bugfix)   label_prefix="bugfix" ;;
    bugreport) label_prefix="bugreport" ;;
    discover) label_prefix="discover" ;;
    deploy)   label_prefix="deploy" ;;
    custom)      label_prefix="change" ;;
    opensource)  label_prefix="opensource" ;;
    content)     label_prefix="content" ;;
  esac

  local label_set_file
  label_set_file="$(mktemp 2>/dev/null)" || die "Unable to create temporary label bootstrap file"

  for lens_entry in "${LENS_LIST[@]}"; do
    local domain="${lens_entry%%/*}"
    local lens_id="${lens_entry#*/}"
    local label="${label_prefix}:${domain}/${lens_id}"
    local color
    color="$(jq -r --arg d "$domain" '.[$d] // "ededed"' "$COLORS_FILE")"

    printf '%s=%s\n' "$label" "$color" >> "$label_set_file"
  done

  # Ensure enhancement label for discover mode
  if [[ "$MODE" == "discover" ]]; then
    printf '%s=%s\n' "enhancement" "a2eeef" >> "$label_set_file"
  fi

  if [[ -n "$SPEC_FILE" ]]; then
    local spec_basename
    spec_basename="$(basename "$SPEC_FILE" | sed 's/\.[^.]*$//')"
    local spec_label="spec:${spec_basename}"
    printf '%s=%s\n' "$spec_label" "c9b1ff" >> "$label_set_file"
  fi

  forge_label_bootstrap "$REPO_OWNER/$REPO_NAME" "$label_set_file"
  rm -f "$label_set_file"

  log_info "Labels ready."
}

# Only create labels if we have a remote repo and not in local mode
if $LOCAL_MODE; then
  log_info "Local mode — skipping label creation."
elif git -C "$PROJECT_PATH" remote get-url origin >/dev/null 2>&1; then
  ensure_labels
else
  log_warn "No remote origin — skipping label creation. Agent will create labels locally."
fi

# --- Initialize summary ---
if [[ ! -f "$SUMMARY_FILE" ]] || [[ -z "$RESUME_RUN_ID" ]]; then
  if $LOCAL_MODE; then
    init_summary "$SUMMARY_FILE" "$RUN_ID" "$PROJECT_PATH" "$MODE" "$AGENT" "$SPEC_FILE" "$MAX_ISSUES" "local" "$OUTPUT_DIR" "${REMOTE_TARGET:-}" "${REMOTE_LABEL:-}"
  else
    init_summary "$SUMMARY_FILE" "$RUN_ID" "$PROJECT_PATH" "$MODE" "$AGENT" "$SPEC_FILE" "$MAX_ISSUES" "github" "" "${REMOTE_TARGET:-}" "${REMOTE_LABEL:-}"
  fi
fi

# --- Global issue counter ---
GLOBAL_ISSUES_CREATED=0

# --- Force sequential when --max-issues or --hosted is active ---
if [[ -n "$MAX_ISSUES" ]] && $PARALLEL; then
  log_warn "Forcing sequential mode: --max-issues requires sequential execution to enforce global limit."
  PARALLEL=false
fi
if $HOSTED && $PARALLEL; then
  log_warn "Forcing sequential mode: --hosted requires sequential execution to avoid concurrent DAST conflicts."
  PARALLEL=false
fi

start_status_updater "$RUN_ID" "$LOG_BASE" "$HEARTBEAT_DIR" "$completed_lenses_file" "$SUMMARY_FILE" "$PROJECT_PATH" "$FORGE_REPO_SLUG" "$MODE" "$AGENT" "$PARALLEL" "$MAX_PARALLEL" "${REMOTE_TARGET:-}" "${REMOTE_LABEL:-}"

# --- Run a single lens ---
run_lens() {
  local lens_entry="$1"
  local domain="${lens_entry%%/*}"
  local lens_id="${lens_entry#*/}"
  local lens_file="$LENSES_DIR/$domain/$lens_id.md"
  local base_file="$BASE_WRAPPER_FILE"

  if [[ "$domain" == "custom" \
      && -n "${CURRENT_ROUND_CUSTOM_LENSES_DIR:-}" \
      && -f "${CURRENT_ROUND_CUSTOM_LENSES_DIR}/$domain/$lens_id.md" ]]; then
    lens_file="${CURRENT_ROUND_CUSTOM_LENSES_DIR}/$domain/$lens_id.md"
  fi

  # Check resume
  if is_lens_completed "$lens_entry"; then
    log_info "[$domain/$lens_id] Skipping (already completed in previous run)"
    return 0
  fi

  # Read lens metadata
  local lens_name domain_name lens_label domain_color
  lens_name="$(read_frontmatter "$lens_file" "name")"
  domain_name="$(jq -r --arg d "$domain" '.domains[] | select(.id == $d) | .name' "$DOMAINS_FILE")"
  if [[ -z "$domain_name" && "$domain" == "custom" ]]; then
    domain_name="Custom"
  fi
  domain_color="$(jq -r --arg d "$domain" '.[$d] // "ededed"' "$COLORS_FILE")"

  local label_prefix
  case "$MODE" in
    audit)    label_prefix="audit" ;;
    feature)  label_prefix="feature" ;;
    bugfix)   label_prefix="bugfix" ;;
    bugreport) label_prefix="bugreport" ;;
    discover) label_prefix="discover" ;;
    deploy)   label_prefix="deploy" ;;
    custom)      label_prefix="change" ;;
    opensource)  label_prefix="opensource" ;;
    content)     label_prefix="content" ;;
  esac
  lens_label="${label_prefix}:${domain}/${lens_id}"

  # Build variable substitution string
  local vars=""
  vars="PROJECT_PATH=${PROJECT_PATH}"
  vars+="|DOMAIN=${domain}"
  vars+="|DOMAIN_NAME=${domain_name}"
  vars+="|DOMAIN_COLOR=${domain_color}"
  vars+="|LENS_ID=${lens_id}"
  vars+="|LENS_NAME=${lens_name}"
  vars+="|LENS_LABEL=${lens_label}"
  vars+="|MODE=${MODE}"
  vars+="|RUN_ID=${RUN_ID}"
  vars+="|MIN_SEVERITY=${MIN_SEVERITY}"
  vars+="|REPO_NAME=${REPO_NAME}"
  vars+="|REPO_OWNER=${REPO_OWNER}"
  vars+="|FORGE_REPO_SLUG=${FORGE_REPO_SLUG}"
  vars+="|FORGE_ISSUE_CREATE=$(forge_prompt_issue_create "$lens_label" "$FORGE_REPO_SLUG" "$PROJECT_PATH")"
  vars+="|FORGE_LABEL_CREATE=$(forge_prompt_label_create "$lens_label" "$domain_color" "$FORGE_REPO_SLUG" "$PROJECT_PATH")"
  vars+="|FORGE_ENHANCEMENT_LABEL_CREATE=$(forge_prompt_label_create "enhancement" "a2eeef" "$FORGE_REPO_SLUG" "$PROJECT_PATH")"
  vars+="|FORGE_ISSUE_LIST_OPEN=$(forge_prompt_issue_list "open" "$FORGE_REPO_SLUG" "$PROJECT_PATH")"
  vars+="|FORGE_ISSUE_LIST_CLOSED=$(forge_prompt_issue_list "closed" "$FORGE_REPO_SLUG" "$PROJECT_PATH")"
  [[ -n "${CURRENT_ROUND_INDEX:-}" ]] && vars+="|ROUND_INDEX=${CURRENT_ROUND_INDEX}"
  [[ -n "${CURRENT_ROUND_TOTAL:-}" ]] && vars+="|ROUND_TOTAL=${CURRENT_ROUND_TOTAL}"
  if [[ -n "${PRIOR_ROUND_DIGEST_FILE:-}" ]]; then
    vars+="|PRIOR_ROUND_DIGEST=@${PRIOR_ROUND_DIGEST_FILE}"
  fi
  if [[ -n "${HYPOTHESES_TO_VERIFY_FILE:-}" ]]; then
    vars+="|HYPOTHESES_TO_VERIFY=@${HYPOTHESES_TO_VERIFY_FILE}"
  fi
  [[ -n "$CHANGE_STATEMENT" ]] && vars+="|CHANGE_STATEMENT=${CHANGE_STATEMENT}"
  if [[ "$MODE" == "bugreport" && -f "$BUG_REPORT_FILE" ]]; then
    vars+="|BUG_REPORT=@${BUG_REPORT_FILE}"
  fi
  if [[ "$MODE" == "bugreport" && -f "$TRIAGE_CONTEXT_PACK_FILE" ]]; then
    vars+="|TRIAGE_CONTEXT_PACK=@${TRIAGE_CONTEXT_PACK_FILE}"
  fi
  [[ -n "$SOURCE_FILE" ]] && vars+="|SOURCE_PATH=${SOURCE_FILE}"
  [[ -n "$LOGS_PATH" ]] && vars+="|LOGS_PATH=${LOGS_PATH}"
  [[ -n "$HOSTED_NETWORK" ]] && vars+="|HOSTED_NETWORK=${HOSTED_NETWORK}"
  if [[ "$MODE" == "deploy" ]]; then
    vars+="|TARGET_TYPE=${TARGET_TYPE}"
    vars+="|ANDROID_APK_PATH=${ANDROID_APK_PATH}"
    vars+="|ANDROID_PACKAGE_NAME=${ANDROID_PACKAGE_NAME}"
    vars+="|ANDROID_HAS_DEVICE=${ANDROID_HAS_DEVICE}"
    vars+="|REPOLENS_DEPLOY_TARGET_KIND=${REPOLENS_DEPLOY_TARGET_KIND:-${TARGET_TYPE}}"
    vars+="|REPOLENS_ANDROID_APK_PATH=${REPOLENS_ANDROID_APK_PATH:-${ANDROID_APK_PATH}}"
    if [[ -n "${REMOTE_TARGET:-}" ]]; then
      vars+="|REPOLENS_REMOTE_TARGET=$(template_var_escape "${REPOLENS_REMOTE_TARGET:-${REMOTE_TARGET}}")"
      vars+="|REPOLENS_REMOTE_LABEL=$(template_var_escape "${REPOLENS_REMOTE_LABEL:-${REMOTE_LABEL:-${REMOTE_TARGET}}}")"
    fi
  fi

  # Compose prompt (pass local mode params)
  local prompt lens_local_dir=""
  if $LOCAL_MODE; then
    lens_local_dir="${CURRENT_ROUND_OUTPUT_DIR:-$OUTPUT_DIR}/$domain/$lens_id"
    mkdir -p "$lens_local_dir"
    prompt="$(compose_prompt "$base_file" "$lens_file" "$vars" "$SPEC_FILE" "$MODE" "$MAX_ISSUES" "$SOURCE_FILE" "$HOSTED" "true" "$lens_local_dir")"
  else
    prompt="$(compose_prompt "$base_file" "$lens_file" "$vars" "$SPEC_FILE" "$MODE" "$MAX_ISSUES" "$SOURCE_FILE" "$HOSTED")"
  fi

  # Create lens log directory
  local lens_log_dir="$LOG_BASE/$domain/$lens_id"
  mkdir -p "$lens_log_dir"

  local heartbeat_interval heartbeat_file heartbeat_iteration_file heartbeat_started_at heartbeat_owner_pid heartbeat_writer_pid
  local previous_exit_trap previous_exit_action
  heartbeat_interval="$(resolve_lens_heartbeat_interval)"
  heartbeat_file="$(lens_heartbeat_path "$domain" "$lens_id")"
  heartbeat_iteration_file="$(lens_heartbeat_iteration_path "$domain" "$lens_id")"
  heartbeat_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  heartbeat_owner_pid="$BASHPID"
  heartbeat_writer_pid=""

  if (( heartbeat_interval > 0 )); then
    previous_exit_trap="$(trap -p EXIT || true)"
    previous_exit_action="$(extract_exit_trap_action "$previous_exit_trap")"
    _REPOLENS_LENS_PREVIOUS_EXIT_ACTION="$previous_exit_action"
    _REPOLENS_LENS_HEARTBEAT_LENS_ENTRY="$lens_entry"
    _REPOLENS_LENS_HEARTBEAT_FILE="$heartbeat_file"
    _REPOLENS_LENS_HEARTBEAT_ITERATION_FILE="$heartbeat_iteration_file"
    _REPOLENS_LENS_HEARTBEAT_WRITER_PID=""
    trap 'run_lens_heartbeat_exit_trap' EXIT

    write_lens_heartbeat_iteration "$heartbeat_iteration_file" 0 || true
    start_lens_heartbeat_writer heartbeat_writer_pid "$heartbeat_file" "$heartbeat_iteration_file" "$RUN_ID" "$domain" "$lens_id" "$heartbeat_owner_pid" "$heartbeat_started_at" "$heartbeat_interval"
    _REPOLENS_LENS_HEARTBEAT_WRITER_PID="$heartbeat_writer_pid"
  fi

  log_info "[$domain/$lens_id] Starting lens: $lens_name"

  # Snapshot issue count before loop.
  # forge_issue_list_count returns non-zero + empty stdout when the forge query fails;
  # we must NOT collapse that back into 0 (it would reintroduce the silent
  # failure bug). If the baseline cannot be established, fall back to 0
  # with a prominent warning. This may over-count later deltas, which is
  # safe — at worst we trip MAX_ISSUES earlier. Under-counting was the
  # original bug: summary claimed 0 while the forge actually held N > 0.
  local issues_baseline=0
  if $LOCAL_MODE; then
    issues_baseline="$(count_dry_run_issues "$lens_local_dir")"
  else
    local _baseline_out=""
    if _baseline_out="$(forge_issue_list_count "$REPO_OWNER/$REPO_NAME" "$lens_label")"; then
      issues_baseline="$_baseline_out"
    else
      issues_baseline=0
      log_warn "[$domain/$lens_id] Baseline forge issue count failed; using fallback baseline count 0. Per-lens counts may be inflated if pre-existing issues carry label '$lens_label'."
    fi
  fi

  # Run lens loop with DONE streak detection
  local iteration=0
  local done_streak=0
  local lens_issues=0
  local prev_lens_issues=0
  local exit_status="completed"
  local rate_limit_retry_attempted=false
  local rate_limit_sleep_seconds=0
  local lens_start_epoch
  lens_start_epoch="$(date +%s)"

  while true; do
    local now_epoch elapsed_seconds remaining_wall_secs
    now_epoch="$(date +%s)"
    elapsed_seconds=$((now_epoch - lens_start_epoch))
    remaining_wall_secs=$((LENS_MAX_WALL_SECS - elapsed_seconds))
    if (( remaining_wall_secs <= 0 )); then
      log_warn "[$domain/$lens_id] Hit lens wall-clock budget (${LENS_MAX_WALL_SECS}s elapsed). Stopping lens."
      exit_status="max-wall"
      break
    fi

    iteration=$((iteration + 1))
    local timestamp
    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    local output_file="$lens_log_dir/iteration-${iteration}-${timestamp}.txt"

    log_info "[$domain/$lens_id] Iteration $iteration"
    if (( heartbeat_interval > 0 )); then
      write_lens_heartbeat_iteration "$heartbeat_iteration_file" "$iteration" || true
      write_lens_heartbeat "$heartbeat_file" "$RUN_ID" "$domain" "$lens_id" "$heartbeat_owner_pid" "$iteration" "$heartbeat_started_at" || true
    fi

    local agent_rc=0
    local effective_timeout_secs="$AGENT_TIMEOUT_SECS"
    if (( remaining_wall_secs < effective_timeout_secs )); then
      effective_timeout_secs="$remaining_wall_secs"
    fi

    run_agent "$AGENT" "$prompt" "$PROJECT_PATH" "$effective_timeout_secs" "$AGENT_KILL_GRACE_SECS" >"$output_file" 2>&1 || agent_rc=$?
    if [[ "$agent_rc" -eq 124 ]]; then
      log_error "[$domain/$lens_id] agent timed out after ${effective_timeout_secs}s and exited during ${AGENT_KILL_GRACE_SECS}s grace on iteration $iteration"
    elif [[ "$agent_rc" -eq 137 ]]; then
      log_error "[$domain/$lens_id] agent timed out after ${effective_timeout_secs}s and was hard-killed after ${AGENT_KILL_GRACE_SECS}s grace on iteration $iteration"
    elif [[ "$agent_rc" -ne 0 ]]; then
      log_warn "[$domain/$lens_id] Agent returned non-zero on iteration $iteration. Continuing."
    fi

    # Detect rate-limit / quota / auth-failure signatures in agent output.
    # A match means retrying will not help (the agent is gated upstream) —
    # abort the whole run instead of burning MAX_ITERATIONS_PER_LENS * lenses
    # worth of no-op invocations. Checked BEFORE check_done so a rate-limited
    # agent cannot accidentally trip the DONE path.
    #
    # Gate on agent_rc != 0 (issue #128): all supported agent CLIs exit
    # non-zero on an upstream rate-limit / quota / auth error. A successful
    # iteration (rc == 0) that happens to quote user code containing
    # "usage limit" / "rate limit" / "try again in" is a finding, not an
    # API failure — running the detector there produces false aborts that
    # skip every remaining lens.
    local rl_hit rl_sig rl_snip
    if [[ "$agent_rc" -ne 0 ]]; then
      rl_hit="$(detect_agent_rate_limit "$output_file" || true)"
      if [[ -n "$rl_hit" ]]; then
        rl_sig="${rl_hit%%|*}"
        rl_snip="${rl_hit#*|}"

        if ! $rate_limit_retry_attempted; then
          local resume_epoch now_epoch wait_delta sleep_seconds resume_label
          resume_epoch="$(parse_rate_limit_resume_epoch "$output_file" || true)"
          if [[ "$resume_epoch" =~ ^[0-9]+$ ]]; then
            now_epoch="$(date +%s)"
            if [[ "$resume_epoch" -lt $((now_epoch - 60)) ]]; then
              resume_epoch=""
            else
              wait_delta=$((resume_epoch - now_epoch))
              if [[ "$wait_delta" -lt 0 ]]; then
                wait_delta=0
              fi

              if [[ "$wait_delta" -le "$RATE_LIMIT_MAX_SLEEP_SECS" ]]; then
                sleep_seconds=$((wait_delta + 60))
                resume_label="$(date -u -d "@$resume_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '%s' "$resume_epoch")"
                log_warn "[$domain/$lens_id] Agent rate-limited. Resume at $resume_label (${sleep_seconds}s from now). Sleeping."
                rate_limit_retry_attempted=true
                rate_limit_sleep_seconds=$((rate_limit_sleep_seconds + sleep_seconds))
                if env --help 2>&1 | grep -q -- '--default-signal'; then
                  if ! env --default-signal=INT sleep "$sleep_seconds"; then
                    log_warn "[$domain/$lens_id] Rate-limit sleep interrupted."
                    exit 130
                  fi
                elif ! sleep "$sleep_seconds"; then
                  log_warn "[$domain/$lens_id] Rate-limit sleep interrupted."
                  exit 130
                fi
                continue
              fi
            fi
          fi
        fi

        log_error "[$domain/$lens_id] Agent rate-limited / quota exceeded. Aborting run. Matched: $rl_sig. Snippet: $rl_snip"
        : > "$LOG_BASE/.rate-limit-abort"
        exit_status="rate-limited"
        break
      fi
    fi

    # Count issues created by this lens.
    # If forge_issue_list_count fails (rate-limited, auth expired, network
    # blip, repo gone, etc.) we MUST NOT treat that as "0 issues" — that
    # was the original bug. Fall back to issue URLs emitted in this
    # iteration's captured agent output; they are a best-effort per-iteration
    # delta, not an authoritative forge total.
    local current_issue_count=""
    if $LOCAL_MODE; then
      current_issue_count="$(count_dry_run_issues "$lens_local_dir")"
    else
      if ! current_issue_count="$(forge_issue_list_count "$REPO_OWNER/$REPO_NAME" "$lens_label")"; then
        local fallback_issue_count
        fallback_issue_count="$(count_issues_in_output "$output_file")"
        log_warn "[$domain/$lens_id] Iteration $iteration: forge issue count failed; falling back to GitHub issue URLs in agent output ($fallback_issue_count issue(s) found)."
        current_issue_count=$((issues_baseline + prev_lens_issues + fallback_issue_count))
      fi
    fi
    lens_issues=$((current_issue_count - issues_baseline))
    [[ "$lens_issues" -lt 0 ]] && lens_issues=0
    local iter_issues=$((lens_issues - prev_lens_issues))
    [[ "$iter_issues" -gt 0 ]] && log_info "[$domain/$lens_id] $iter_issues issue(s) created this iteration ($lens_issues lens total)"
    prev_lens_issues="$lens_issues"

    # Check global issue budget
    if [[ -n "$MAX_ISSUES" ]]; then
      local projected=$((GLOBAL_ISSUES_CREATED + lens_issues))
      if [[ "$projected" -ge "$MAX_ISSUES" ]]; then
        log_info "[$domain/$lens_id] Global issue limit reached ($projected/$MAX_ISSUES). Stopping lens."
        exit_status="max-issues"
        break
      fi
    fi

    now_epoch="$(date +%s)"
    elapsed_seconds=$((now_epoch - lens_start_epoch))
    if (( elapsed_seconds >= LENS_MAX_WALL_SECS )); then
      log_warn "[$domain/$lens_id] Hit lens wall-clock budget (${LENS_MAX_WALL_SECS}s elapsed). Stopping lens."
      exit_status="max-wall"
      break
    fi

    # Safety cap: prevent runaway lenses
    if [[ "$iteration" -ge "$MAX_ITERATIONS_PER_LENS" ]]; then
      log_warn "[$domain/$lens_id] Hit safety cap ($MAX_ITERATIONS_PER_LENS iterations). Stopping lens."
      exit_status="max-iterations"
      break
    fi

    # Check for DONE
    if check_done "$output_file"; then
      done_streak=$((done_streak + 1))
      log_info "[$domain/$lens_id] DONE detected ($done_streak/$DONE_STREAK_REQUIRED consecutive)"
      if [[ "$done_streak" -ge "$DONE_STREAK_REQUIRED" ]]; then
        log_info "[$domain/$lens_id] DONE x${DONE_STREAK_REQUIRED} — lens complete."
        break
      fi
    else
      if [[ "$done_streak" -gt 0 ]]; then
        log_info "[$domain/$lens_id] DONE streak reset."
      fi
      done_streak=0
    fi
  done

  # Update global counter
  GLOBAL_ISSUES_CREATED=$((GLOBAL_ISSUES_CREATED + lens_issues))

  # Record result. Rate-limited lenses are recorded but NOT marked completed,
  # so --resume will re-run them on the next invocation.
  record_lens "$SUMMARY_FILE" "$domain" "$lens_id" "$iteration" "$exit_status" "$lens_issues" "$rate_limit_sleep_seconds"
  if [[ "$exit_status" != "rate-limited" ]]; then
    mark_lens_completed "$lens_entry"
  fi

  if (( heartbeat_interval > 0 )); then
    stop_lens_heartbeat_writer "$heartbeat_writer_pid" "$heartbeat_file" "$heartbeat_iteration_file" "true"
    restore_exit_trap "$previous_exit_trap"
    _REPOLENS_LENS_PREVIOUS_EXIT_ACTION=""
    _REPOLENS_LENS_HEARTBEAT_LENS_ENTRY=""
    _REPOLENS_LENS_HEARTBEAT_FILE=""
    _REPOLENS_LENS_HEARTBEAT_ITERATION_FILE=""
    _REPOLENS_LENS_HEARTBEAT_WRITER_PID=""
  fi

  log_info "[$domain/$lens_id] Finished after $iteration iteration(s), $lens_issues issue(s)"
}

# --- Triage (pre-rounds, round-0 context pack) ---
# Single-shot agent that produces logs/<run-id>/triage/context-pack.md so every
# round-1 lens shares a compact briefing of suspect commits, linked-issue
# summaries, recent author activity, and an initial hypothesis tree. Failure is
# non-fatal: round-1 lenses fall back to doing their own initial history scan.
if [[ "$MODE" == "bugreport" && "${NO_TRIAGE:-true}" != "true" ]]; then
  log_info "Triage: building round-0 context pack"
  if run_triage "$RUN_ID"; then
    log_info "Triage: context-pack.md promoted ($TRIAGE_CONTEXT_PACK_FILE)"
  else
    log_warn "Triage: failed — proceeding with empty context pack"
  fi
fi

# --- Execute lenses ---
RUN_ROUNDS_RC=0
run_rounds "$ROUNDS" LENS_LIST
RUN_ROUNDS_RC=$?

# --- Verifier (post-rounds, pre-synthesizer) ---
# Re-reads every finding's cited code locations and emits
# logs/<run-id>/final/verification.json so the synthesizer can skip WRONG
# findings and downrank STALE ones. Verifier failures are non-fatal: a missing
# verification.json simply means the synthesizer proceeds without filtering.
if [[ "$RUN_ROUNDS_RC" -eq 0 && "${NO_VERIFIER:-true}" != "true" ]]; then
  log_info "Verifier: re-reading cited code locations for evidence accuracy"
  if run_verifier "$RUN_ID"; then
    log_info "Verifier: verification.json promoted"
  else
    log_warn "Verifier: failed — synthesizer will proceed without verification filtering"
  fi
fi

# --- Synthesizer (post-rounds, post-verifier) ---
# Multi-round runs finish by consolidating round findings into a schema-checked
# manifest under logs/<run-id>/final/manifest.json. Single-round runs keep the
# legacy direct-filing/local-output behavior.
if [[ "$RUN_ROUNDS_RC" -eq 0 && "${ROUNDS:-1}" -gt 1 ]]; then
  log_info "Synthesizer: consolidating multi-round findings"
  if run_synthesizer "$RUN_ID"; then
    log_info "Synthesizer: manifest.json promoted"
  else
    log_warn "Synthesizer: failed to produce a valid manifest"
    RUN_ROUNDS_RC=1
  fi
fi

# --- Finalize ---
finalize_summary "$SUMMARY_FILE"

log_info "=============================="
log_info "RepoLens run $RUN_ID complete"
log_info "Summary: $SUMMARY_FILE"
log_info "=============================="

# Print summary to stdout
echo ""
echo "=== RepoLens Run Summary ==="
jq '.' "$SUMMARY_FILE"

# If the rate-limit detector fired, exit non-zero so CI / operators see the
# run as failed. The summary is already finalized with stopped_reason and
# per-lens statuses, so --resume picks up seamlessly.
if [[ -f "$LOG_BASE/.rate-limit-abort" ]]; then
  exit 1
fi

if [[ "$RUN_ROUNDS_RC" -ne 0 ]]; then
  exit "$RUN_ROUNDS_RC"
fi

if [[ "${REPOLENS_FINAL_STATE:-finished}" == "interrupted" ]]; then
  exit "${REPOLENS_INTERRUPT_EXIT_CODE:-130}"
fi
