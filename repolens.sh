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

# --- Usage ---
usage() {
  cat <<'EOF'
Usage: repolens.sh --project <path> --agent <agent> [OPTIONS]

RepoLens — Multi-lens code audit tool. Runs expert analysis agents against
any git repository and creates GitHub issues for real findings.

Required:
  --project <path>        Path to git repository to audit (MUST be a git repo)
  --agent <agent>         claude | codex | spark | sparc | opencode | opencode/<model>

Options:
  --mode <mode>           audit (default) | feature | bugfix
  --focus <lens-id>       Run a single lens (e.g., "injection", "dead-code")
  --domain <domain-id>    Run all lenses in one domain (e.g., "security")
  --parallel              Run lenses in parallel (one agent process per lens)
  --max-parallel <n>      Max concurrent agents in parallel mode (default: 8)
  --resume <run-id>       Resume a previous interrupted run
  -h, --help              Show help

Examples:
  repolens.sh --project ~/myapp --agent claude
  repolens.sh --project ~/myapp --agent claude --focus injection
  repolens.sh --project ~/myapp --agent codex --domain security --parallel
  repolens.sh --project ~/myapp --agent spark --mode bugfix --parallel --max-parallel 4
EOF
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

# --- Validate mode ---
case "$MODE" in
  audit|feature|bugfix) ;;
  *) die "Invalid mode: $MODE (expected 'audit', 'feature', or 'bugfix')" ;;
esac

# --- Validate project is a git repo ---
_orig_project="$PROJECT_PATH"
PROJECT_PATH="$(cd "$PROJECT_PATH" 2>/dev/null && pwd)" || die "Cannot access project path: $_orig_project"
git -C "$PROJECT_PATH" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not a git repository: $PROJECT_PATH"

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
  RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$(head -c 4 /dev/urandom | xxd -p)"
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

# --- Resolve lens list ---
resolve_lenses() {
  local lenses_json=""

  if [[ -n "$FOCUS" ]]; then
    # Single lens mode — find which domain it belongs to
    local found_domain=""
    found_domain="$(jq -r --arg lens "$FOCUS" \
      '.domains[] | select(.lenses[] == $lens) | .id' "$DOMAINS_FILE" | head -1)"
    [[ -n "$found_domain" ]] || die "Lens '$FOCUS' not found in domains.json"

    local lens_file="$LENSES_DIR/$found_domain/$FOCUS.md"
    [[ -f "$lens_file" ]] || die "Lens prompt file missing: $lens_file"

    echo "$found_domain/$FOCUS"
    return
  fi

  if [[ -n "$DOMAIN_FILTER" ]]; then
    # Domain filter mode
    local domain_exists=""
    domain_exists="$(jq -r --arg d "$DOMAIN_FILTER" \
      '.domains[] | select(.id == $d) | .id' "$DOMAINS_FILE")"
    [[ -n "$domain_exists" ]] || die "Domain '$DOMAIN_FILTER' not found in domains.json"

    jq -r --arg d "$DOMAIN_FILTER" \
      '.domains[] | select(.id == $d) | .lenses[] | $d + "/" + .' "$DOMAINS_FILE"
    return
  fi

  # All lenses — ordered by domain order
  jq -r '.domains | sort_by(.order)[] | .id as $d | .lenses[] | $d + "/" + .' "$DOMAINS_FILE"
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

# --- Ensure GitHub labels ---
ensure_labels() {
  log_info "Ensuring GitHub labels exist..."
  local label_prefix
  case "$MODE" in
    audit)   label_prefix="audit" ;;
    feature) label_prefix="feature" ;;
    bugfix)  label_prefix="bugfix" ;;
  esac

  for lens_entry in "${LENS_LIST[@]}"; do
    local domain="${lens_entry%%/*}"
    local lens_id="${lens_entry#*/}"
    local label="${label_prefix}:${domain}/${lens_id}"
    local color
    color="$(jq -r --arg d "$domain" '.[$d] // "ededed"' "$COLORS_FILE")"

    gh label create "$label" --color "$color" --force -R "$REPO_OWNER/$REPO_NAME" 2>/dev/null || true
  done
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
  init_summary "$SUMMARY_FILE" "$RUN_ID" "$PROJECT_PATH" "$MODE" "$AGENT"
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
    audit)   label_prefix="audit" ;;
    feature) label_prefix="feature" ;;
    bugfix)  label_prefix="bugfix" ;;
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

  # Compose prompt
  local prompt
  prompt="$(compose_prompt "$base_file" "$lens_file" "$vars")"

  # Create lens log directory
  local lens_log_dir="$LOG_BASE/$domain/$lens_id"
  mkdir -p "$lens_log_dir"

  log_info "[$domain/$lens_id] Starting lens: $lens_name"

  # Run lens loop with DONE x3 streak detection
  local iteration=0
  local done_streak=0

  while true; do
    iteration=$((iteration + 1))
    local timestamp
    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    local output_file="$lens_log_dir/iteration-${iteration}-${timestamp}.txt"

    log_info "[$domain/$lens_id] Iteration $iteration"

    if ! run_agent "$AGENT" "$prompt" "$PROJECT_PATH" >"$output_file" 2>&1; then
      log_warn "[$domain/$lens_id] Agent returned non-zero on iteration $iteration. Continuing."
    fi

    # Check for DONE
    if check_done "$output_file"; then
      done_streak=$((done_streak + 1))
      log_info "[$domain/$lens_id] DONE detected ($done_streak/3 consecutive)"
      if [[ "$done_streak" -ge 3 ]]; then
        log_info "[$domain/$lens_id] DONE x3 — lens complete."
        break
      fi
    else
      if [[ "$done_streak" -gt 0 ]]; then
        log_info "[$domain/$lens_id] DONE streak reset."
      fi
      done_streak=0
    fi
  done

  # Record result
  record_lens "$SUMMARY_FILE" "$domain" "$lens_id" "$iteration" "completed"
  mark_lens_completed "$lens_entry"

  log_info "[$domain/$lens_id] Finished after $iteration iteration(s)"
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
