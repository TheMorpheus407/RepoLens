#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Source libraries ---
source "$SCRIPT_DIR/lib/core.sh"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/streak.sh"
source "$SCRIPT_DIR/lib/template.sh"
source "$SCRIPT_DIR/lib/summary.sh"
source "$SCRIPT_DIR/lib/parallel.sh"
source "$SCRIPT_DIR/lib/hosted.sh"

# --- Usage ---
usage() {
  cat <<'EOF'
Usage: repolens.sh --project <path> --agent <agent> [OPTIONS]

RepoLens — Multi-lens code audit tool. Runs expert analysis agents against
any git repository and creates GitHub issues for real findings.

Required:
  --project <path|url>    Local path or remote Git URL (cloned read-only if URL)
  --agent <agent>         claude | codex | spark | sparc | opencode | opencode/<model>

Options:
  --mode <mode>           audit (default) | feature | bugfix | discover | deploy | custom | opensource | content
  --change <statement>    Change impact analysis — propagates statement across all lenses (implies --mode custom)
  --source <file>         Source material for content creation (PDF, text, markdown — agent reads directly)
  --focus <lens-id>       Run a single lens (e.g., "injection", "dead-code")
  --domain <domain-id>    Run all lenses in one domain (e.g., "security")
  --parallel              Run lenses in parallel (one agent process per lens)
  --max-parallel <n>      Max concurrent agents in parallel mode (default: 8)
  --resume <run-id>       Resume a previous interrupted run
  --spec <file>           Spec/PRD/roadmap to guide analysis (any text file)
  --max-issues <n>        Stop after creating n total issues (dry-run quality check)
  --hosted                Spin up project's Docker Compose in isolated network for DAST scanning and testing
  --yes, -y               Skip confirmation prompt (for CI/automation)
  --max-cost <amount>     Warn if estimated cost exceeds this dollar amount
  --dry-run               Validate config and show what would run, then exit (no agents executed)
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
  repolens.sh --project ~/myapp --agent claude --hosted --domain toolgate
  repolens.sh --project ~/myapp --agent claude --hosted --focus dast-web
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
  echo "Domains (audit/feature/bugfix/custom — ${code_total} lenses):"
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
CHANGE_STATEMENT=""
SOURCE_FILE=""
HOSTED=false
AUTO_YES=false
MAX_COST=""
DRY_RUN=false

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
    --focus)
      [[ $# -ge 2 ]] || die "Option --focus requires an argument."
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
    --change)
      [[ $# -ge 2 ]] || die "Option --change requires a statement string."
      CHANGE_STATEMENT="$2"
      shift 2
      ;;
    --source)
      [[ $# -ge 2 ]] || die "Option --source requires a file path argument."
      SOURCE_FILE="$2"
      shift 2
      ;;
    --hosted)
      HOSTED=true
      shift
      ;;
    --yes|-y)
      AUTO_YES=true
      shift
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

# --- Handle --change flag ---
if [[ -n "$CHANGE_STATEMENT" ]]; then
  if [[ "$MODE" != "audit" && "$MODE" != "custom" ]]; then
    die "--change cannot be combined with --mode $MODE (it implies --mode custom)"
  fi
  MODE="custom"
fi

# --- Validate mode ---
case "$MODE" in
  audit|feature|bugfix|discover|deploy|custom|opensource|content) ;;
  *) die "Invalid mode: $MODE (expected 'audit', 'feature', 'bugfix', 'discover', 'deploy', 'custom', 'opensource', or 'content')" ;;
esac

# --- Validate --change requirement ---
if [[ "$MODE" == "custom" && -z "$CHANGE_STATEMENT" ]]; then
  die "Mode 'custom' requires --change \"your change statement\""
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
  if $HOSTED 2>/dev/null; then
    cleanup_hosted "${RUN_ID:-}" 2>/dev/null
  fi
  _cleanup_clone
}
trap _cleanup_all EXIT

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

# --- Validate project is a git repo ---
_orig_project="$PROJECT_PATH"
PROJECT_PATH="$(cd "$PROJECT_PATH" 2>/dev/null && pwd)" || die "Cannot access project path: $_orig_project"
if [[ "$MODE" != "deploy" ]]; then
  git -C "$PROJECT_PATH" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not a git repository: $PROJECT_PATH"
fi

# --- Validate spec file ---
if [[ -n "$SPEC_FILE" ]]; then
  [[ -f "$SPEC_FILE" ]] || die "Spec file not found: $SPEC_FILE"
  [[ -r "$SPEC_FILE" ]] || die "Spec file not readable: $SPEC_FILE"
  SPEC_FILE="$(cd "$(dirname "$SPEC_FILE")" && pwd)/$(basename "$SPEC_FILE")"
  _spec_size="$(wc -c < "$SPEC_FILE")"
  [[ "$_spec_size" -le 102400 ]] || die "Spec file too large (${_spec_size} bytes, max 100KB): $SPEC_FILE"
  # Reject binary files (NUL byte check via tr/cmp)
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

# --- Validate max-issues ---
if [[ -n "$MAX_ISSUES" ]]; then
  [[ "$MAX_ISSUES" =~ ^[1-9][0-9]*$ ]] || die "--max-issues must be a positive integer, got: $MAX_ISSUES"
fi

# --- Validate max-cost ---
if [[ -n "$MAX_COST" ]]; then
  [[ "$MAX_COST" =~ ^[0-9]+\.?[0-9]*$ ]] || die "--max-cost must be a numeric value, got: $MAX_COST"
fi

# --- Derive DONE streak threshold ---
if [[ -n "$MAX_ISSUES" ]] || [[ "$MODE" == "discover" ]] || [[ "$MODE" == "deploy" ]] || [[ "$MODE" == "custom" ]] || [[ "$MODE" == "opensource" ]] || [[ "$MODE" == "content" ]]; then
  DONE_STREAK_REQUIRED=1
else
  DONE_STREAK_REQUIRED=3
fi

# --- Safety cap: maximum iterations per lens ---
MAX_ITERATIONS_PER_LENS=20

# --- Derive repo metadata ---
REPO_NAME="$(basename "$PROJECT_PATH")"
REPO_OWNER="$(git -C "$PROJECT_PATH" remote get-url origin 2>/dev/null | sed -E 's#.*/([^/]+)/[^/]+(.git)?$#\1#' || echo "local")"
if [[ -z "$REPO_OWNER" || "$REPO_OWNER" == "$REPO_NAME" ]]; then
  REPO_OWNER="local"
fi

# --- Validate agent and dependencies ---
validate_agent "$AGENT"
require_cmd git
require_cmd gh
require_cmd jq

case "$AGENT" in
  claude) require_cmd claude ;;
  codex|spark|sparc) require_cmd codex ;;
  opencode|opencode/*) require_cmd opencode ;;
esac

# --- Validate gh auth ---
gh auth status >/dev/null 2>&1 || die "gh is not authenticated. Run 'gh auth login'."

# --- Generate or resume run ID ---
if [[ -n "$RESUME_RUN_ID" ]]; then
  RUN_ID="$RESUME_RUN_ID"
else
  RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$(od -An -tx1 -N4 /dev/urandom | tr -d ' \n')"
fi

# --- Directories ---
LOG_BASE="$SCRIPT_DIR/logs/$RUN_ID"
mkdir -p "$LOG_BASE"
SUMMARY_FILE="$LOG_BASE/summary.json"
DOMAINS_FILE="$SCRIPT_DIR/config/domains.json"
COLORS_FILE="$SCRIPT_DIR/config/label-colors.json"
BASE_PROMPTS_DIR="$SCRIPT_DIR/prompts/_base"
LENSES_DIR="$SCRIPT_DIR/prompts/lenses"

# --- Validate config files exist ---
[[ -f "$DOMAINS_FILE" ]] || die "Missing config: $DOMAINS_FILE"
[[ -f "$COLORS_FILE" ]] || die "Missing config: $COLORS_FILE"
[[ -f "$BASE_PROMPTS_DIR/$MODE.md" ]] || die "Missing base template: $BASE_PROMPTS_DIR/$MODE.md"

# --- Initialize logging ---
init_logging "$RUN_ID" "$LOG_BASE"

log_info "RepoLens run $RUN_ID starting"
log_info "Project: $PROJECT_PATH ($REPO_OWNER/$REPO_NAME)"
log_info "Agent: $AGENT | Mode: $MODE | Parallel: $PARALLEL"
[[ -n "$SPEC_FILE" ]] && log_info "Spec: $SPEC_FILE"
[[ -n "$MAX_ISSUES" ]] && log_info "Max issues: $MAX_ISSUES (DONE streak: 1)"
[[ "$MODE" == "discover" ]] && log_info "Discover mode: single-pass brainstorming (DONE streak: 1)"
[[ "$MODE" == "deploy" ]] && log_info "Deploy mode: single-pass server audit (DONE streak: 1)"
[[ "$MODE" == "custom" ]] && log_info "Custom mode: change impact analysis (DONE streak: 1)"
[[ "$MODE" == "opensource" ]] && log_info "Open source mode: readiness audit (DONE streak: 1)"
[[ "$MODE" == "content" ]] && log_info "Content mode: content audit & creation (DONE streak: 1)"
[[ -n "$CHANGE_STATEMENT" ]] && log_info "Change: $CHANGE_STATEMENT"
[[ -n "$SOURCE_FILE" ]] && log_info "Source: $SOURCE_FILE"
if $HOSTED; then
  log_info "Hosted mode: spinning up Docker environment..."
  if ! setup_hosted_env "$PROJECT_PATH" "$RUN_ID"; then
    die "Failed to set up hosted environment. Check Docker and compose file."
  fi
  log_info "Hosted environment ready: $HOSTED_SERVICES"
fi

# --- Resolve lens list ---
resolve_lenses() {
  # Mode-aware jq filter: discover sees only discover domains, others exclude them
  if [[ -n "$FOCUS" ]]; then
    # Single lens mode — find which domain it belongs to
    local found_domain=""
    found_domain="$(jq -r --arg lens "$FOCUS" --arg mode "$MODE" \
      '.domains[] | (if $mode == "discover" then select(.mode == "discover") elif $mode == "deploy" then select(.mode == "deploy") elif $mode == "opensource" then select(.mode == "opensource") elif $mode == "content" then select(.mode == "content") else select(.mode != "discover" and .mode != "deploy" and .mode != "opensource" and .mode != "content") end) | select(.lenses[] == $lens) | .id' "$DOMAINS_FILE" | head -1)"
    [[ -n "$found_domain" ]] || die "Lens '$FOCUS' not found in domains.json (mode: $MODE)"

    local lens_file="$LENSES_DIR/$found_domain/$FOCUS.md"
    [[ -f "$lens_file" ]] || die "Lens prompt file missing: $lens_file"

    echo "$found_domain/$FOCUS"
    return
  fi

  if [[ -n "$DOMAIN_FILTER" ]]; then
    # Domain filter mode
    local domain_exists=""
    domain_exists="$(jq -r --arg d "$DOMAIN_FILTER" --arg mode "$MODE" \
      '.domains[] | (if $mode == "discover" then select(.mode == "discover") elif $mode == "deploy" then select(.mode == "deploy") elif $mode == "opensource" then select(.mode == "opensource") elif $mode == "content" then select(.mode == "content") else select(.mode != "discover" and .mode != "deploy" and .mode != "opensource" and .mode != "content") end) | select(.id == $d) | .id' "$DOMAINS_FILE")"
    [[ -n "$domain_exists" ]] || die "Domain '$DOMAIN_FILTER' not found in domains.json (mode: $MODE)"

    jq -r --arg d "$DOMAIN_FILTER" \
      '.domains[] | select(.id == $d) | .lenses[] | $d + "/" + .' "$DOMAINS_FILE"
    return
  fi

  # All lenses — ordered by domain order
  jq -r --arg mode "$MODE" \
    '.domains | sort_by(.order)[] | (if $mode == "discover" then select(.mode == "discover") elif $mode == "deploy" then select(.mode == "deploy") elif $mode == "opensource" then select(.mode == "opensource") elif $mode == "content" then select(.mode == "content") else select(.mode != "discover" and .mode != "deploy" and .mode != "opensource" and .mode != "content") end) | .id as $d | .lenses[] | $d + "/" + .' "$DOMAINS_FILE"
}

LENS_LIST=()
while IFS= read -r lens_entry; do
  LENS_LIST+=("$lens_entry")
done < <(resolve_lenses)

TOTAL_LENSES=${#LENS_LIST[@]}
[[ "$TOTAL_LENSES" -gt 0 ]] || die "No lenses to run."

log_info "Resolved $TOTAL_LENSES lens(es) to run"

# --- Validate all lens files exist ---
for lens_entry in "${LENS_LIST[@]}"; do
  domain="${lens_entry%%/*}"
  lens_id="${lens_entry#*/}"
  lens_file="$LENSES_DIR/$domain/$lens_id.md"
  [[ -f "$lens_file" ]] || die "Missing lens prompt: $lens_file"
done

# --- Check resume state ---
completed_lenses_file="$LOG_BASE/.completed"
touch "$completed_lenses_file"

is_lens_completed() {
  grep -qxF "$1" "$completed_lenses_file" 2>/dev/null
}

mark_lens_completed() {
  echo "$1" >> "$completed_lenses_file"
}

# --- Cost per call lookup ---
get_cost_per_call() {
  local agent="$1"
  case "$agent" in
    claude)              echo "0.15" ;;
    codex)               echo "0.10" ;;
    spark|sparc)         echo "0.20" ;;
    opencode|opencode/*) echo "0.10" ;;
    *)                   echo "0.10" ;;
  esac
}

# --- Confirmation gate ---
confirm_run() {
  if $AUTO_YES; then
    return 0
  fi

  # Non-interactive detection (piped stdin)
  if [[ ! -t 0 ]]; then
    die "Running non-interactively without --yes flag. Use --yes to skip confirmation."
  fi

  # Cost estimation
  local cost_per_call
  cost_per_call="$(get_cost_per_call "$AGENT")"
  local est_cost
  est_cost="$(awk -v n="$TOTAL_LENSES" -v s="$DONE_STREAK_REQUIRED" -v c="$cost_per_call" 'BEGIN { printf "%.2f", n * s * c }')"

  echo ""
  echo "=== RepoLens Confirmation ==="
  echo "Target repo:  $REPO_OWNER/$REPO_NAME"
  echo "Mode:         $MODE"
  echo "Agent:        $AGENT"
  echo "Lenses:       $TOTAL_LENSES"
  if [[ -n "$MAX_ISSUES" ]]; then
    echo "Max issues:   $MAX_ISSUES"
  else
    echo "Max issues:   (unlimited)"
  fi
  echo "Est. cost:    ~\$${est_cost}  (~\$${cost_per_call}/call x ${TOTAL_LENSES} lenses x ${DONE_STREAK_REQUIRED} iterations)"

  # Threshold warning
  if [[ -n "$MAX_COST" ]]; then
    local exceeds
    exceeds="$(awk -v est="$est_cost" -v max="$MAX_COST" 'BEGIN { print (est > max) ? 1 : 0 }')"
    if [[ "$exceeds" -eq 1 ]]; then
      echo ""
      echo "WARNING: Estimated cost (~\$${est_cost}) exceeds --max-cost threshold (\$${MAX_COST})"
    fi
  fi

  echo ""
  echo "This will run $TOTAL_LENSES analysis agent(s) against the repository above."
  echo "Each agent may create GitHub issues directly."
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
  echo "Deploy mode runs read-only inspection commands on a live server"
  echo "(e.g., systemctl, journalctl, ss, df)."
  echo ""
  echo "WARNING: Running this against infrastructure you do not own or"
  echo "are not authorized to audit may violate computer crime laws,"
  echo "including §202a StGB (DE), the Computer Fraud and Abuse Act (US),"
  echo "and similar legislation in other jurisdictions."
  echo ""
  read -rp "I confirm I am authorized to audit this server [y/N] " answer
  case "$answer" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) echo "Aborted — deploy mode requires explicit authorization."; exit 0 ;;
  esac
}

# --- Dry-run output ---
if $DRY_RUN; then
  echo ""
  echo "=== Dry Run ==="
  echo "Mode:         $MODE"
  echo "Agent:        $AGENT"
  echo "Project:      $PROJECT_PATH"
  echo "Lenses:       $TOTAL_LENSES"
  echo ""
  echo "Lenses that would run:"
  for lens_entry in "${LENS_LIST[@]}"; do
    echo "  $lens_entry"
  done
  echo ""
  echo "Dry run complete — no agents were executed."
  exit 0
fi

confirm_deploy_authorization
confirm_run

# --- Ensure GitHub labels ---
ensure_labels() {
  log_info "Ensuring GitHub labels exist..."
  local label_prefix
  case "$MODE" in
    audit)    label_prefix="audit" ;;
    feature)  label_prefix="feature" ;;
    bugfix)   label_prefix="bugfix" ;;
    discover) label_prefix="discover" ;;
    deploy)   label_prefix="deploy" ;;
    custom)      label_prefix="change" ;;
    opensource)  label_prefix="opensource" ;;
    content)     label_prefix="content" ;;
  esac

  for lens_entry in "${LENS_LIST[@]}"; do
    local domain="${lens_entry%%/*}"
    local lens_id="${lens_entry#*/}"
    local label="${label_prefix}:${domain}/${lens_id}"
    local color
    color="$(jq -r --arg d "$domain" '.[$d] // "ededed"' "$COLORS_FILE")"

    gh label create "$label" --color "$color" --force -R "$REPO_OWNER/$REPO_NAME" 2>/dev/null || true
  done

  # Ensure enhancement label for discover mode
  if [[ "$MODE" == "discover" ]]; then
    gh label create "enhancement" --color "a2eeef" --force -R "$REPO_OWNER/$REPO_NAME" 2>/dev/null || true
  fi

  if [[ -n "$SPEC_FILE" ]]; then
    local spec_basename
    spec_basename="$(basename "$SPEC_FILE" | sed 's/\.[^.]*$//')"
    local spec_label="spec:${spec_basename}"
    gh label create "$spec_label" --color "c9b1ff" --force -R "$REPO_OWNER/$REPO_NAME" 2>/dev/null || true
  fi

  log_info "Labels ready."
}

# Only create labels if we have a remote repo
if git -C "$PROJECT_PATH" remote get-url origin >/dev/null 2>&1; then
  ensure_labels
else
  log_warn "No remote origin — skipping label creation. Agent will create labels locally."
fi

# --- Initialize summary ---
if [[ ! -f "$SUMMARY_FILE" ]] || [[ -z "$RESUME_RUN_ID" ]]; then
  init_summary "$SUMMARY_FILE" "$RUN_ID" "$PROJECT_PATH" "$MODE" "$AGENT" "$SPEC_FILE" "$MAX_ISSUES"
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

# --- Run a single lens ---
run_lens() {
  local lens_entry="$1"
  local domain="${lens_entry%%/*}"
  local lens_id="${lens_entry#*/}"
  local lens_file="$LENSES_DIR/$domain/$lens_id.md"
  local base_file="$BASE_PROMPTS_DIR/$MODE.md"

  # Check resume
  if is_lens_completed "$lens_entry"; then
    log_info "[$domain/$lens_id] Skipping (already completed in previous run)"
    return 0
  fi

  # Read lens metadata
  local lens_name domain_name lens_label domain_color
  lens_name="$(read_frontmatter "$lens_file" "name")"
  domain_name="$(jq -r --arg d "$domain" '.domains[] | select(.id == $d) | .name' "$DOMAINS_FILE")"
  domain_color="$(jq -r --arg d "$domain" '.[$d] // "ededed"' "$COLORS_FILE")"

  local label_prefix
  case "$MODE" in
    audit)    label_prefix="audit" ;;
    feature)  label_prefix="feature" ;;
    bugfix)   label_prefix="bugfix" ;;
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
  vars+="|REPO_NAME=${REPO_NAME}"
  vars+="|REPO_OWNER=${REPO_OWNER}"
  [[ -n "$CHANGE_STATEMENT" ]] && vars+="|CHANGE_STATEMENT=${CHANGE_STATEMENT}"
  [[ -n "$SOURCE_FILE" ]] && vars+="|SOURCE_PATH=${SOURCE_FILE}"
  [[ -n "$HOSTED_NETWORK" ]] && vars+="|HOSTED_NETWORK=${HOSTED_NETWORK}"

  # Compose prompt
  local prompt
  prompt="$(compose_prompt "$base_file" "$lens_file" "$vars" "$SPEC_FILE" "$MODE" "$MAX_ISSUES" "$SOURCE_FILE" "$HOSTED")"

  # Create lens log directory
  local lens_log_dir="$LOG_BASE/$domain/$lens_id"
  mkdir -p "$lens_log_dir"

  log_info "[$domain/$lens_id] Starting lens: $lens_name"

  # Snapshot issue count before loop (deterministic counting via gh API)
  local issues_baseline=0
  issues_baseline="$(count_repo_issues "$REPO_OWNER/$REPO_NAME" "$lens_label")"

  # Run lens loop with DONE streak detection
  local iteration=0
  local done_streak=0
  local lens_issues=0
  local prev_lens_issues=0
  local exit_status="completed"

  while true; do
    iteration=$((iteration + 1))
    local timestamp
    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    local output_file="$lens_log_dir/iteration-${iteration}-${timestamp}.txt"

    log_info "[$domain/$lens_id] Iteration $iteration"

    if ! run_agent "$AGENT" "$prompt" "$PROJECT_PATH" >"$output_file" 2>&1; then
      log_warn "[$domain/$lens_id] Agent returned non-zero on iteration $iteration. Continuing."
    fi

    # Count issues created by this lens (deterministic: gh issue list delta)
    local current_issue_count
    current_issue_count="$(count_repo_issues "$REPO_OWNER/$REPO_NAME" "$lens_label")"
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

  # Record result
  record_lens "$SUMMARY_FILE" "$domain" "$lens_id" "$iteration" "$exit_status" "$lens_issues"
  mark_lens_completed "$lens_entry"

  log_info "[$domain/$lens_id] Finished after $iteration iteration(s), $lens_issues issue(s)"
}

# --- Execute lenses ---
if $PARALLEL; then
  log_info "Running in parallel mode (max $MAX_PARALLEL concurrent)"
  init_parallel "$LOG_BASE/.semaphore" "$MAX_PARALLEL"

  for lens_entry in "${LENS_LIST[@]}"; do
    spawn_lens "${lens_entry#*/}" run_lens "$lens_entry"
  done

  if ! wait_all; then
    log_warn "Some lenses exited with errors."
  fi
else
  log_info "Running in sequential mode"
  local_count=0
  for lens_entry in "${LENS_LIST[@]}"; do
    # Check global issue budget before starting next lens
    if [[ -n "$MAX_ISSUES" && "$GLOBAL_ISSUES_CREATED" -ge "$MAX_ISSUES" ]]; then
      log_info "Global issue budget exhausted ($GLOBAL_ISSUES_CREATED/$MAX_ISSUES). Skipping remaining lenses."
      # Record remaining lenses as skipped
      for skip_entry in "${LENS_LIST[@]:$local_count}"; do
        skip_domain="${skip_entry%%/*}"
        skip_lens="${skip_entry#*/}"
        if ! is_lens_completed "$skip_entry"; then
          record_lens "$SUMMARY_FILE" "$skip_domain" "$skip_lens" 0 "skipped" 0
        fi
      done
      set_stop_reason "$SUMMARY_FILE" "max-issues-reached"
      break
    fi
    local_count=$((local_count + 1))
    log_info "--- Lens $local_count/$TOTAL_LENSES ---"
    run_lens "$lens_entry"
  done
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
