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
source "$SCRIPT_DIR/lib/remote.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/streak.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/template.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/summary.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/status.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/clean.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/parallel.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/rounds.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/polish.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/verify.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/validate.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/triage.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/synthesize.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/ledger.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/result_pointer.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/filing.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/hosted.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/android.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/forge.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/human_review.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/artifacts.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/local-dedupe.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/attempts.sh"

VERSION="0.2.0"

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

acquire_run_lock() {
  local lock_file holder

  [[ -n "${RUN_ID:-}" && -n "${LOG_BASE:-}" ]] || die "Run lock requires RUN_ID and LOG_BASE"
  mkdir -p "$LOG_BASE" || die "Unable to create run directory: $LOG_BASE"

  command -v flock >/dev/null 2>&1 || die "flock is required to guard run $RUN_ID against concurrent resume"

  lock_file="$LOG_BASE/.repolens.flock"
  exec {REPOLENS_RUN_LOCK_FD}>"$lock_file" || die "Unable to open run lock: $lock_file"
  export REPOLENS_RUN_LOCK_FD

  if ! flock -n "$REPOLENS_RUN_LOCK_FD"; then
    holder=""
    if command -v fuser >/dev/null 2>&1; then
      holder="$(fuser "$lock_file" 2>/dev/null | tr -s ' ' ' ' | sed 's/^ *//;s/ *$//' || true)"
    fi
    [[ -n "$holder" ]] || holder="unknown"
    die "Another repolens process (PID $holder) already owns run $RUN_ID"
  fi
}

# --- Usage ---
usage() {
  cat <<'EOF'
Usage: repolens.sh --project <path> --agent <agent> [OPTIONS]
       repolens.sh status [run-id] [OPTIONS]
       repolens.sh clean [OPTIONS]
       repolens.sh supersede <run-id>

RepoLens — Multi-lens code audit tool. Runs expert analysis agents against
any git repository and creates remote issues for real findings.

Required:
  --project <path|url>    Local path or remote Git URL (cloned read-only if URL)
  --agent <agent>         claude | codex | spark | sparc | opencode | opencode/<model> | antigravity | copilot

Commands:
  status [run-id]         Show a live run snapshot from logs/<run-id>/status.json
  clean [OPTIONS]         Remove old run directories under logs/ (see clean --help)
  supersede <run-id>      Mark a run dir no-longer-authoritative (.superseded):
                          hidden from status auto-select, eligible for clean

Options:
  --mode <mode>           audit (default) | feature | bugfix | bugreport | discover | deploy | custom | opensource | content | greenfield | polish | spec-change
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
  --relevant-domains <csv>
                          Comma-separated allowlist of domain ids — the "missing
                          middle" between --focus (1 lens) and full fan-out.
                          Intersects with the mode-filtered lens list. Bypassed
                          when --focus or --domain is set (those win).
                          Example: --relevant-domains concurrency,database
  --agent-override <csv>  Route specific domains or lenses to a different agent
                          than the global --agent (cost vs. logic optimization).
                          Comma-separated key=agent pairs. Keys are a domain id
                          or a fully-qualified domain/lens (lens ids are not
                          globally unique, so lens scope requires domain/lens).
                          Precedence: domain/lens > domain > global --agent.
                          Example: --agent opencode \
                                   --agent-override security=claude,architecture=claude,information-architecture/empty-states=claude
  --scope-by-keywords     Deterministic, LLM-free pruning: substring-match the
                          bug-report text against each domain's "keywords" field
                          in config/domains.json (case-insensitive). Domains
                          without a "keywords" field are always kept (back-compat).
                          Only effective in --mode bugreport. Env var fallback:
                          REPOLENS_SCOPE_BY_KEYWORDS=1.
  --parallel              Run lenses in parallel (one agent process per lens)
  --max-parallel <n>      Max concurrent agents in parallel mode. When unset the
                          default is nproc-aware: clamp(detected cores, 8, 32).
                          An explicit value is always authoritative and is never
                          re-clamped. Higher concurrency trips provider rate
                          limits faster. See REPOLENS_NPROC to pin the count.
  --resume [<run-id>]     Resume a previous interrupted run (reuses its dir,
                          skips completed lenses; add --focus/--domain to
                          narrow). With no id, picks the latest interrupted run.
  --validate <file>       Post-audit validation: re-verify an existing findings
                          artifact (findings.jsonl / manifest.json, produced by a
                          cheap "Radar" agent) with the flagship --agent, drop the
                          false positives, and write a cleaned findings file. Does
                          not run the lens scan. Needs --agent and --project.
  --spec <file>           Spec/PRD/roadmap to guide analysis (required for --mode greenfield / spec-change)
  --spec-base <ref>       Git base ref/range to diff the --spec file against in
                          --mode spec-change (default: HEAD — working-tree-vs-HEAD,
                          i.e. the uncommitted edit). Accepts a ref (HEAD~1) or a
                          range (HEAD~1..HEAD). Only valid with --mode spec-change.
  --max-issues <n>        Stop after creating n total issues (dry-run quality check)
  --min-severity <level>  Only file findings at or above level: critical|high|medium|low
  --depth <n>             DONE streak depth per lens. Defaults: 3 for audit/feature/bugfix,
                           1 otherwise. Must be between 1 and 19.
  --rounds <n>            Cross-lens rounds (default: 1, except --mode
                           bugreport which defaults to 3; only --mode bugreport
                           supports multi-round — all other modes locked to 1)
  --strategy <name>       Bugreport round-1 strategy: fanout (default — all
                           lenses run as the round-1 dispatch) | waves (N
                           triage-seeded GENERIC investigators, width =
                           REPOLENS_WAVE_WIDTH, default 7, clamped to 1..50).
                           Requires --mode bugreport when set to waves.
  --no-verifier           Skip the post-rounds verifier step. The verifier
                           runs by default for --mode bugreport (evidence
                           accuracy is critical when filing bug reports) and
                           is skipped by default for every other mode. Pass
                           --no-verifier to also skip it for bugreport.
  --no-triage             Skip the pre-rounds triage step (round-0 context pack
                           for --mode bugreport). Defaults: OFF for --mode
                           bugreport; ON for every other mode (no-op there).
  --cross-link <mode>     Synthesizer cross-link behavior for existing issues:
                           off | comment | suggest-reopen. Defaults: comment
                           for --mode bugreport; off for every other mode.
                           Never auto-reopens — suggest-reopen files a small
                           repolens:reopen-candidate issue instead.
  --human-review          Curated, noise-budgeted human-review digest at
                          finalize time instead of dumping every finding.
                          Env var fallback: REPOLENS_HUMAN_REVIEW=1.
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
  --flat-rate             Flat-rate / subscription costing (or REPOLENS_FLAT_RATE=true):
                          show $0.00 marginal cost and expected request/quota
                          consumption instead of a per-token dollar estimate
                          (Claude Pro / ChatGPT Plus / Gemini Advanced / free tiers)
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
  repolens.sh --project ~/myapp --agent claude --mode polish
  repolens.sh --project ~/myapp --agent claude --mode audit --source ~/docs/threat-report.pdf
  repolens.sh --project ~/myapp --agent claude --mode content --focus topic-extraction --source ~/docs/textbook.pdf
  repolens.sh --project ~/myapp --agent claude --mode bugreport --bug-report ~/reports/crash-on-login.txt
  repolens.sh --project ~/myapp --agent claude --mode audit --cross-link suggest-reopen
  repolens.sh --project ~/myapp --agent claude --human-review
  repolens.sh --project ~/AutoDev --agent claude --logs ~/CybersecurityAssessment/logs/auto-develop/ --domain logs --parallel
  repolens.sh --project ~/myapp --agent claude --hosted --domain toolgate
  repolens.sh --project ~/myapp --agent claude --hosted --focus dast-web
  repolens.sh --project ~/myapp --agent claude --local
  repolens.sh --project ~/myapp --agent claude --local --output ~/reports/myapp-audit
  repolens.sh --project ~/myapp --agent claude --local --domain security --parallel
  repolens.sh --project ~/myapp --agent copilot
  repolens.sh --project ~/myapp --agent copilot --domain security --parallel

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
  REPOLENS_AGENT_TIMEOUT_ANTIGRAVITY
                           Antigravity per-invocation timeout override; wins over
                           REPOLENS_AGENT_TIMEOUT and the mode-specific timeouts
                           when --agent antigravity is selected.
  REPOLENS_AGENT_TIMEOUT_COPILOT
                           GitHub Copilot CLI per-invocation timeout override;
                           also used for copilot/<model>.
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
  REPOLENS_AGENT_TIMEOUT_GREENFIELD
                           Greenfield default: 1800.
  REPOLENS_AGENT_TIMEOUT_POLISH
                           Polish default: 1800.
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
  REPOLENS_EST_WARN_HOURS  Wall-clock estimate threshold in hours (default: 24).
                           When the startup estimate exceeds this, a loud warning
                           lists tuning levers (--max-parallel, --agent, --depth,
                           --domain/--focus, --max-issues). Set 0 to disable the
                           warning; a non-numeric value falls back to 24.
  REPOLENS_EST_PER_ITER_SECS
                           Per-iteration wall-clock guess in seconds used by the
                           startup estimate (default: 90). Higher values raise the
                           estimate; non-numeric values fall back to the default.
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
  REPOLENS_NPROC           Override the detected CPU core count used to derive
                           the nproc-aware --max-parallel default. When
                           --max-parallel is unset, the default is
                           clamp(REPOLENS_NPROC, 8, 32), parsed base-10. An
                           explicit --max-parallel always wins. Primarily a
                           determinism knob for tests; a non-numeric value falls
                           back to nproc(1)/getconf, then a floor of 8.
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
  REPOLENS_HUMAN_REVIEW    Fallback for --human-review. Set to "true"/"1" to
                           enable the curated human-review digest when the CLI
                           flag is not used.
  REPOLENS_STRATEGY        Fallback for --strategy when the CLI flag is unset.
                           Accepted values: fanout, waves. Only meaningful for
                           --mode bugreport.
  REPOLENS_WAVE_WIDTH      Number of GENERIC investigators dispatched in
                           bugreport waves round 1 (default 7, clamped to
                           1..50).
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
  DEDUPE_TITLE_SIM_PRIMARY Near-duplicate title-similarity bar on the Jaccard
                           x10000 integer scale (0..10000; default 8500 = 0.85).
                           Shared knob: gates both validate_manifest's pairwise
                           title check (strict >) and _dedupe_is_match's primary
                           title signal (inclusive >=). Lower = more aggressive
                           deduping. A value > 10000 effectively disables the
                           bar (no pair can reach it). Non-numeric/negative input
                           falls back to the default with a warning (never
                           crashes). Breaks the REPOLENS_ prefix on purpose, to
                           match the shipped dedupe match helper.
  DEDUPE_TITLE_SIM_SECONDARY
                           Lower secondary title-similarity bar (Jaccard x10000;
                           default 6000 = 0.60) used by _dedupe_is_match only
                           when two records share a non-empty location. Same
                           scale, validation, and > 10000 = disabled semantics
                           as DEDUPE_TITLE_SIM_PRIMARY.
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
  echo "  greenfield  Spec-to-backlog planning — creates one implementation issue per iteration (requires --spec)"
  echo "  polish      Polish — proposes small, additive craft refinements"
  echo "  bugreport   Symptom-driven investigation — runs lenses on a user bug report (requires --bug-report)"
  echo "  spec-change Spec-diff impact — derives code changes from a tracked spec's git diff (requires --spec)"

  # Parse all domains in one jq call
  local domain_data
  domain_data="$(jq -r '.domains | sort_by(.order)[] | .id + "|" + .name + "|" + (.mode // "code") + "|" + ([.lenses[] | if type == "string" then . else .id end] | join(","))' "$domains_file")"

  local code_total=0 discover_total=0 deploy_total=0 opensource_total=0 content_total=0 greenfield_total=0 polish_total=0 spec_change_total=0
  local code_output="" discover_output="" deploy_output="" opensource_output="" content_output="" greenfield_output="" polish_output="" spec_change_output=""

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
    elif [[ "$dmode" == "greenfield" ]]; then
      greenfield_total=$((greenfield_total + lcount))
      greenfield_output+="$section"$'\n'
    elif [[ "$dmode" == "polish" ]]; then
      polish_total=$((polish_total + lcount))
      polish_output+="$section"$'\n'
    elif [[ "$dmode" == "spec-change" ]]; then
      spec_change_total=$((spec_change_total + lcount))
      spec_change_output+="$section"$'\n'
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
  echo "Domains (greenfield mode — ${greenfield_total} lenses):"
  echo ""
  printf "%s" "$greenfield_output"
  echo "Domains (polish mode — ${polish_total} lenses):"
  echo ""
  printf "%s" "$polish_output"
  echo "Domains (spec-change mode — ${spec_change_total} lenses):"
  echo ""
  printf "%s" "$spec_change_output"
}

# Dispatch read-only subcommands before normal run validation.
if [[ "${1:-}" == "status" ]]; then
  shift
  status_command "$@"
  exit "$?"
fi

# `clean` removes old run dirs; it needs no --project/--agent, so dispatch it
# here alongside status, before run validation.
if [[ "${1:-}" == "clean" ]]; then
  shift
  clean_command "$@"
  exit "$?"
fi

# `supersede` marks a run dir no-longer-authoritative by writing a .superseded
# marker; like clean/status it needs no --project/--agent, so dispatch it here.
if [[ "${1:-}" == "supersede" ]]; then
  shift
  supersede_command "$@"
  exit "$?"
fi

# --- Argument parsing ---
PROJECT_PATH=""
AGENT=""
# Issue #380: per-domain / per-lens agent routing. AGENT_OVERRIDE_CSV holds the
# raw --agent-override CSV (accumulated across repeated flags); AGENT_OVERRIDES
# is the validated key->agent map (domain or domain/lens key), populated by
# validate_agent_overrides once domains.json is available.
AGENT_OVERRIDE_CSV=""
declare -A AGENT_OVERRIDES=()
MODE="audit"
FOCUS=""
DOMAIN_FILTER=""
RELEVANT_DOMAINS_CSV=""
RELEVANT_DOMAINS_SET=false
SCOPE_BY_KEYWORDS=false
SCOPE_BY_KEYWORDS_SET=false
PARALLEL=false
MAX_PARALLEL=8
MAX_PARALLEL_SET=false
RESUME_RUN_ID=""
VALIDATE_INPUT=""
VALIDATE_MODE=false
SPEC_FILE=""
SPEC_BASE="HEAD"
SPEC_BASE_SET=false
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
HUMAN_REVIEW=false
HUMAN_REVIEW_SET=false
STRATEGY=""
STRATEGY_SET=false
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
# Flat-rate / subscription costing (issue #384): marginal per-token cost is $0
# for Claude Pro / ChatGPT Plus / Gemini Advanced / free-tier users, so the
# estimator shows expected request/quota consumption instead of a dollar figure.
# Seed from the env var (true/1/yes); the --flat-rate flag can also enable it.
case "${REPOLENS_FLAT_RATE:-}" in
  true|1|yes|TRUE|YES) FLAT_RATE=true ;;
  *) FLAT_RATE=false ;;
esac
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
    --agent-override)
      [[ $# -ge 2 ]] || die "Option --agent-override requires a comma-separated key=agent argument."
      # Accumulate across repeated flags; validated later in validate_agent_overrides.
      AGENT_OVERRIDE_CSV="${AGENT_OVERRIDE_CSV:+$AGENT_OVERRIDE_CSV,}$2"
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
    --relevant-domains)
      [[ $# -ge 2 ]] || die "Option --relevant-domains requires a comma-separated argument."
      RELEVANT_DOMAINS_CSV="$2"
      RELEVANT_DOMAINS_SET=true
      shift 2
      ;;
    --scope-by-keywords)
      SCOPE_BY_KEYWORDS=true
      SCOPE_BY_KEYWORDS_SET=true
      shift
      ;;
    --parallel)
      PARALLEL=true
      shift
      ;;
    --max-parallel)
      [[ $# -ge 2 ]] || die "Option --max-parallel requires an argument."
      MAX_PARALLEL="$2"
      MAX_PARALLEL_SET=true
      shift 2
      ;;
    --resume)
      # With an explicit run id (any non-flag token), resume that id. With no
      # following token, or when the next token is itself a flag (e.g.
      # `--resume --dry-run`), defer to auto-selecting the latest interrupted
      # run. Run ids never start with `--`, so `--*` is a safe discriminator and
      # this avoids swallowing a trailing flag as the run id.
      if [[ $# -ge 2 && "$2" != --* ]]; then
        RESUME_RUN_ID="$2"
        shift 2
      else
        RESUME_RUN_ID="@latest"
        shift
      fi
      ;;
    --validate)
      # Post-audit validation: re-verify an existing findings artifact with a
      # flagship agent and drop the false positives, instead of running a scan.
      [[ $# -ge 2 ]] || die "Option --validate requires a findings file/path argument."
      # shellcheck disable=SC2034 # Read by run_validate_command in lib/validate.sh.
      VALIDATE_INPUT="$2"
      VALIDATE_MODE=true
      shift 2
      ;;
    --spec)
      [[ $# -ge 2 ]] || die "Option --spec requires a file path argument."
      SPEC_FILE="$2"
      shift 2
      ;;
    --spec-base)
      [[ $# -ge 2 ]] || die "Option --spec-base requires a git ref/range argument."
      SPEC_BASE="$2"
      SPEC_BASE_SET=true
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
    --human-review)
      HUMAN_REVIEW=true
      HUMAN_REVIEW_SET=true
      shift
      ;;
    --strategy)
      [[ $# -ge 2 ]] || die "Option --strategy requires an argument (fanout|waves)."
      case "$2" in
        fanout|waves) STRATEGY="$2" ;;
        *) die "Invalid --strategy: '$2' (expected 'fanout' or 'waves')." ;;
      esac
      STRATEGY_SET=true
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
    --flat-rate)
      FLAT_RATE=true
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

# --- Post-audit validation short-circuit (--validate) ---
# Operates on a pre-existing findings artifact plus the repo on disk; it does
# NOT run the lens fan-out, DONE×3 streak, rounds, or synthesizer. Short-circuit
# here (like clean/status/supersede) before any run-pipeline setup so the heavy
# machinery never engages.
if [[ "$VALIDATE_MODE" == "true" ]]; then
  run_validate_command
  exit "$?"
fi

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
  audit|feature|bugfix|bugreport|discover|deploy|custom|opensource|content|greenfield|polish|spec-change) ;;
  *) die "Invalid mode: $MODE (expected 'audit', 'feature', 'bugfix', 'bugreport', 'discover', 'deploy', 'custom', 'opensource', 'content', 'greenfield', 'polish', or 'spec-change')" ;;
esac

# --- Resolve --strategy (CLI flag wins over REPOLENS_STRATEGY env) ---
# The wave-controller branch in lib/rounds.sh reads ${STRATEGY:-} to decide
# whether round-1 dispatches a narrow set of triage-seeded GENERIC investigators
# (waves) or the full lens list (fanout). Exporting STRATEGY here lets the
# branch fire from parallel workers / subshells.
if ! $STRATEGY_SET && [[ -n "${REPOLENS_STRATEGY:-}" ]]; then
  case "$REPOLENS_STRATEGY" in
    fanout|waves) STRATEGY="$REPOLENS_STRATEGY" ;;
    *) die "Invalid REPOLENS_STRATEGY: '$REPOLENS_STRATEGY' (expected 'fanout' or 'waves')." ;;
  esac
  STRATEGY_SET=true
fi
[[ -n "$STRATEGY" ]] || STRATEGY="fanout"
if [[ "$STRATEGY" == "waves" && "$MODE" != "bugreport" ]]; then
  die "--strategy waves requires --mode bugreport (got --mode $MODE)."
fi
export STRATEGY

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

remote_hash() {
  local value="$1" len="$2" hash
  hash="$(printf '%s' "$value" | sha256sum)"
  hash="${hash%% *}"
  printf '%s\n' "${hash:0:$len}"
}

remote_assert_private_dir() {
  local dir="$1" owner mode
  [[ -d "$dir" && ! -L "$dir" ]] || return 1
  owner="$(stat -c '%u' "$dir" 2>/dev/null)" || return 1
  mode="$(stat -c '%a' "$dir" 2>/dev/null)" || return 1
  [[ "$owner" == "$(id -u)" ]] || return 1
  [[ "$mode" =~ ^0?700$ ]] || return 1
}

remote_control_socket_base() {
  local owner mode
  if [[ -n "${XDG_RUNTIME_DIR:-}" && "$XDG_RUNTIME_DIR" == /* && -d "$XDG_RUNTIME_DIR" && ! -L "$XDG_RUNTIME_DIR" ]]; then
    owner="$(stat -c '%u' "$XDG_RUNTIME_DIR" 2>/dev/null || true)"
    mode="$(stat -c '%a' "$XDG_RUNTIME_DIR" 2>/dev/null || true)"
    if [[ "$owner" == "$(id -u)" && "$mode" =~ ^0?700$ ]]; then
      printf '%s\n' "$XDG_RUNTIME_DIR"
      return 0
    fi
  fi
  printf '%s\n' /tmp
}

remote_control_socket_dir_in_base() {
  local dir="$1" base="$2" leaf
  [[ "$dir" == "${base%/}"/rl-cm-* ]] || return 1
  leaf="${dir##*/}"
  [[ "$leaf" == rl-cm-* && "$leaf" != *"/"* ]] || return 1
}

remote_control_socket_dir() {
  local state_file="$REMOTE_RUN_DIR/control-dir"
  local base dir tmp old_umask run_hash

  base="$(remote_control_socket_base)"
  run_hash="$(remote_hash "$RUN_ID" 8)"

  if [[ -f "$state_file" ]]; then
    IFS= read -r dir < "$state_file" || dir=""
    if [[ -n "$dir" && -d "$dir" ]]; then
      remote_control_socket_dir_in_base "$dir" "$base" || die "Unsafe persisted remote SSH control socket directory: $dir"
      remote_assert_private_dir "$dir" || die "Unsafe persisted remote SSH control socket directory: $dir"
      REMOTE_CONTROL_SOCKET_DIR_RESULT="$dir"
      return 0
    fi
  fi

  old_umask="$(umask)"
  umask 077
  dir="$(mktemp -d "${base%/}/rl-cm-${run_hash}.XXXXXX")" || {
    umask "$old_umask"
    die "Unable to create remote SSH control socket directory under $base"
  }
  umask "$old_umask"

  chmod 700 "$dir" || die "Unable to set mode 0700 on remote SSH control socket directory: $dir"
  remote_assert_private_dir "$dir" || die "Unsafe remote SSH control socket directory: $dir"

  tmp="$state_file.tmp.$$"
  printf '%s\n' "$dir" > "$tmp" || die "Unable to write remote SSH control socket metadata"
  mv "$tmp" "$state_file" || die "Unable to persist remote SSH control socket metadata"
  REMOTE_CONTROL_SOCKET_DIR_RESULT="$dir"
}

remote_control_socket_path() {
  local tuple target_hash run_hash socket_dir socket_path
  socket_dir="$1"
  tuple="user=${REMOTE_USER}|host=${REMOTE_HOST}|port=${REMOTE_PORT}"
  target_hash="$(remote_hash "$tuple" 16)"
  run_hash="$(remote_hash "$RUN_ID" 8)"
  socket_path="$socket_dir/cm-${target_hash}-${run_hash}.sock"
  (( ${#socket_path} < 90 )) || die "Remote SSH control socket path is too long for OpenSSH: $socket_path"
  printf '%s\n' "$socket_path"
}

template_var_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//|/\\|}"
  printf '%s' "$value"
}

greenfield_backlog_inline_text() {
  local value="${1:-}" max_len="${2:-3000}"
  value="${value//$'\r'/ }"
  value="${value//$'\n'/ }"
  value="${value//$'\t'/ }"
  while [[ "$value" == *"  "* ]]; do
    value="${value//  / }"
  done
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  if [[ "$max_len" =~ ^[0-9]+$ && "$max_len" -gt 0 && "${#value}" -gt "$max_len" ]]; then
    value="${value:0:max_len}..."
  fi
  printf '%s' "$value"
}

greenfield_frontmatter_scalar() {
  local file="$1" key="$2" value
  value="$(read_frontmatter "$file" "$key" 2>/dev/null || true)"
  value="${value%$'\r'}"
  if [[ "$value" == \"*\" && "$value" == *\" ]]; then
    value="${value#\"}"
    value="${value%\"}"
  elif [[ "$value" == \'* && "$value" == *\' ]]; then
    value="${value#\'}"
    value="${value%\'}"
  fi
  greenfield_backlog_inline_text "$value" 500
}

greenfield_local_backlog_snapshot() {
  local dir="$1" file count=0 title priority body filename

  if [[ ! -d "$dir" ]]; then
    printf 'No current local draft backlog items were found.\n'
    return 0
  fi

  while IFS= read -r file; do
    [[ -f "$file" ]] || continue
    count=$((count + 1))
    filename="$(basename "$file")"
    title="$(greenfield_frontmatter_scalar "$file" "title")"
    priority="$(greenfield_frontmatter_scalar "$file" "priority")"
    body="$(read_body "$file" 2>/dev/null || true)"
    if [[ -z "$body" ]]; then
      body="$(sed 's/\r$//' "$file" 2>/dev/null || true)"
    fi
    body="$(greenfield_backlog_inline_text "$body" 3000)"

    [[ -n "$title" ]] || title="<untitled>"
    [[ -n "$priority" ]] || priority="<unspecified>"

    printf '### Local draft: %s\n' "$filename"
    printf -- '- Title: %s\n' "$title"
    printf -- '- Priority: %s\n' "$priority"
    if [[ -n "$body" ]]; then
      printf -- '- Body excerpt: %s\n' "$body"
    else
      printf -- '- Body excerpt: <empty>\n'
    fi
    printf '\n'
  done < <(find "$dir" -maxdepth 1 -type f -name '*.md' -print 2>/dev/null | sort)

  if (( count == 0 )); then
    printf 'No current local draft backlog items were found.\n'
  fi
}

greenfield_write_current_backlog_snapshot() {
  local target_file="$1" lens_local_dir="$2" repo="$3"

  if $LOCAL_MODE; then
    greenfield_local_backlog_snapshot "$lens_local_dir" > "$target_file"
    return 0
  fi

  if forge_open_issue_backlog_snapshot "$repo" > "$target_file"; then
    return 0
  fi

  log_warn "Greenfield current backlog snapshot failed; rendering a stop-safe snapshot for this iteration."
  cat > "$target_file" <<'EOF'
Current forge backlog state could not be loaded for this planning iteration.
Do not create a new issue while current backlog coverage is unavailable. Output DONE.
EOF
  return 1
}

# --- Validate deploy target intent ---
if $DEPLOY_TARGET_SET && [[ "$MODE" != "deploy" ]]; then
  die "--deploy-target requires --mode deploy"
fi
if $SPEC_BASE_SET && [[ "$MODE" != "spec-change" ]]; then
  die "--spec-base requires --mode spec-change"
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
  export REPOLENS_REMOTE_TARGET REPOLENS_REMOTE_LABEL
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

# --- Resolve --scope-by-keywords (#228) ---
# Boolean opt-in: CLI flag wins, then REPOLENS_SCOPE_BY_KEYWORDS env var,
# then default (off). Only meaningful in --mode bugreport (the only mode
# with a bug-report text corpus to match against).
if $SCOPE_BY_KEYWORDS_SET; then
  : # explicit CLI flag wins
elif [[ -n "${REPOLENS_SCOPE_BY_KEYWORDS:-}" ]]; then
  case "${REPOLENS_SCOPE_BY_KEYWORDS}" in
    1|true|TRUE|True|yes|YES|on|ON)  SCOPE_BY_KEYWORDS=true ;;
    0|false|FALSE|False|no|NO|off|OFF|"") SCOPE_BY_KEYWORDS=false ;;
    *) SCOPE_BY_KEYWORDS=false ;;
  esac
fi
export SCOPE_BY_KEYWORDS

# --- Resolve --human-review ---
# Noise-budget / curated-digest mode. A full run can emit hundreds of findings;
# this opt-in will eventually render a curated, noise-budgeted digest from the
# finding registry at finalize time instead of dumping every finding. The
# bucketing/renderer/accounting land in sibling issues — this is plumbing only,
# no behavior change beyond resolving + exporting the boolean. CLI flag wins,
# then the REPOLENS_HUMAN_REVIEW env var; default off. No mode-driven default
# (no mode should auto-enable it).
if $HUMAN_REVIEW_SET; then
  : # explicit CLI flag wins
elif [[ -n "${REPOLENS_HUMAN_REVIEW:-}" ]]; then
  case "${REPOLENS_HUMAN_REVIEW,,}" in
    1|true|yes|on) HUMAN_REVIEW=true ;;
    0|false|no|off|"") HUMAN_REVIEW=false ;;
    *) die "REPOLENS_HUMAN_REVIEW must be a boolean (true/false), got: $REPOLENS_HUMAN_REVIEW" ;;
  esac
fi
export HUMAN_REVIEW

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

REPOLENS_NO_PROGRESS_MIN_BYTES="${REPOLENS_NO_PROGRESS_MIN_BYTES:-512}"
if [[ ! "$REPOLENS_NO_PROGRESS_MIN_BYTES" =~ ^[0-9]+$ ]]; then
  die "REPOLENS_NO_PROGRESS_MIN_BYTES must be a non-negative integer byte count"
fi
REPOLENS_NO_PROGRESS_MIN_BYTES=$((10#$REPOLENS_NO_PROGRESS_MIN_BYTES))
if (( REPOLENS_NO_PROGRESS_MIN_BYTES > 1048576 )); then
  die "REPOLENS_NO_PROGRESS_MIN_BYTES must be <= 1048576"
fi

REPOLENS_DEGENERATE_THRESHOLD="${REPOLENS_DEGENERATE_THRESHOLD:-90}"
if [[ ! "$REPOLENS_DEGENERATE_THRESHOLD" =~ ^[1-9][0-9]*$ ]] || (( REPOLENS_DEGENERATE_THRESHOLD > 100 )); then
  die "REPOLENS_DEGENERATE_THRESHOLD must be an integer from 1 to 100"
fi
REPOLENS_DEGENERATE_THRESHOLD=$((10#$REPOLENS_DEGENERATE_THRESHOLD))

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

# --- Validate greenfield spec requirement ---
if [[ "$MODE" == "greenfield" && -z "$SPEC_FILE" ]]; then
  die "Mode 'greenfield' requires --spec <file>"
fi

# --- Validate spec-change spec requirement ---
if [[ "$MODE" == "spec-change" && -z "$SPEC_FILE" ]]; then
  die "Mode 'spec-change' requires --spec <file>"
fi

# --- Handle remote repository URL ---
CLONE_DIR=""

_cleanup_clone() {
  if [[ -n "${CLONE_DIR:-}" && -d "$CLONE_DIR" ]]; then
    chmod -R u+w "$CLONE_DIR" 2>/dev/null
    rm -rf "$CLONE_DIR"
  fi
}

_cleanup_remote_control_socket() {
  [[ -n "${REPOLENS_REMOTE_SSH_CONTROL_DIR:-}" ]] || return 0
  local base
  base="$(remote_control_socket_base)"
  if remote_control_socket_dir_in_base "$REPOLENS_REMOTE_SSH_CONTROL_DIR" "$base" && remote_assert_private_dir "$REPOLENS_REMOTE_SSH_CONTROL_DIR"; then
    rm -rf -- "$REPOLENS_REMOTE_SSH_CONTROL_DIR"
  fi
}

_cleanup_all() {
  stop_status_updater "${REPOLENS_FINAL_STATE:-finished}" 2>/dev/null || true
  if $HOSTED 2>/dev/null; then
    cleanup_hosted "${RUN_ID:-}" 2>/dev/null
  fi
  if declare -F remote_close_master >/dev/null 2>&1; then
    remote_close_master 2>/dev/null || true
  else
    _cleanup_remote_control_socket 2>/dev/null || true
  fi
  _cleanup_clone
}
trap _cleanup_all EXIT

rate_limit_sleep_interrupt_marker() {
  printf '%s\n' "${LOG_BASE:-}/.rate-limit-sleep-interrupt"
}

rate_limit_sleep_signal_name() {
  case "$1" in
    129) printf '%s\n' "SIGHUP" ;;
    130) printf '%s\n' "SIGINT" ;;
    143) printf '%s\n' "SIGTERM" ;;
    *) return 1 ;;
  esac
}

rate_limit_sleep_stopped_reason() {
  case "$1" in
    129) printf '%s\n' "interrupted-sighup" ;;
    130) printf '%s\n' "interrupted-sigint" ;;
    143) printf '%s\n' "interrupted-sigterm" ;;
    *) return 1 ;;
  esac
}

write_rate_limit_sleep_interrupt_marker() {
  local exit_code="$1" signal_name="$2" stopped_reason="$3"
  local marker tmp

  [[ -n "${LOG_BASE:-}" ]] || return 0
  marker="$(rate_limit_sleep_interrupt_marker)"
  tmp="${marker}.tmp.${BASHPID}"
  {
    printf 'exit_code=%s\n' "$exit_code"
    printf 'signal=%s\n' "$signal_name"
    printf 'stopped_reason=%s\n' "$stopped_reason"
    printf 'source=rate-limit-sleep\n'
  } > "$tmp" && mv -f "$tmp" "$marker"
  rm -f "$tmp" 2>/dev/null || true
}

read_rate_limit_abort_earliest_at() {
  local marker key value earliest_at=""

  [[ -n "${LOG_BASE:-}" ]] || { printf '\n'; return 0; }
  marker="$LOG_BASE/.rate-limit-abort"
  [[ -f "$marker" ]] || { printf '\n'; return 0; }

  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    case "$key" in
      earliest_at) earliest_at="$value" ;;
    esac
  done < "$marker"

  if [[ "$earliest_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    printf '%s\n' "$earliest_at"
  else
    printf '\n'
  fi
}

write_rate_limit_abort_marker() {
  local resume_epoch="${1:-}" marker tmp now_epoch earliest_at existing_earliest_at

  [[ -n "${LOG_BASE:-}" ]] || return 0
  marker="$LOG_BASE/.rate-limit-abort"
  tmp="${marker}.tmp.${BASHPID}"
  earliest_at=""

  if [[ "$resume_epoch" =~ ^[0-9]+$ ]]; then
    now_epoch="$(date +%s 2>/dev/null || printf '0')"
    if [[ "$now_epoch" =~ ^[0-9]+$ && "$resume_epoch" -ge $((now_epoch - 60)) ]]; then
      earliest_at="$(date -u -d "@$resume_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
    fi
  fi
  if [[ ! "$earliest_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    earliest_at=""
  fi

  if [[ -z "$earliest_at" ]]; then
    existing_earliest_at="$(read_rate_limit_abort_earliest_at)"
    earliest_at="$existing_earliest_at"
  fi

  {
    if [[ -n "$earliest_at" ]]; then
      printf 'earliest_at=%s\n' "$earliest_at"
    fi
    if [[ "$resume_epoch" =~ ^[0-9]+$ ]]; then
      printf 'resume_epoch=%s\n' "$resume_epoch"
    fi
    printf 'source=lens-rate-limit\n'
  } > "$tmp" && mv -f "$tmp" "$marker"
  rm -f "$tmp" 2>/dev/null || true
}

rate_limit_abort_stopped_reason() {
  [[ -n "${SUMMARY_FILE:-}" && -f "$SUMMARY_FILE" ]] || return 0
  jq -r '.stopped_reason // empty' "$SUMMARY_FILE" 2>/dev/null || true
}

is_phase_rate_limit_stopped_reason() {
  case "$1" in
    rate-limited-*) return 0 ;;
    *) return 1 ;;
  esac
}

# resolve_run_exit_code — print the process exit code implied by the already-
# resolved run state. PURE map (no side effects); it mirrors the exit-code
# ladder at the end of main so the value recorded in attempts.json and the real
# process exit can never drift. Must be called after REPOLENS_FINAL_STATE /
# RUN_HEALTH / RUN_ROUNDS_RC are final. Keep the order identical to the ladder:
# interrupted -> rate-limit-abort -> no-progress/systemic -> rounds-rc ->
# broken-health -> 0.
resolve_run_exit_code() {
  if [[ "${REPOLENS_FINAL_STATE:-finished}" == "interrupted" ]]; then
    printf '%s' "${REPOLENS_INTERRUPT_EXIT_CODE:-130}"
    return 0
  fi
  if [[ -f "$LOG_BASE/.rate-limit-abort" ]]; then
    if is_phase_rate_limit_stopped_reason "$(rate_limit_abort_stopped_reason)"; then
      printf '1'
    else
      printf '3'
    fi
    return 0
  fi
  if [[ -f "$LOG_BASE/.agent-no-progress-abort" || -f "$LOG_BASE/.systemic-failure-abort" ]]; then
    printf '1'
    return 0
  fi
  if [[ "${RUN_ROUNDS_RC:-0}" -ne 0 ]]; then
    printf '%s' "${RUN_ROUNDS_RC:-0}"
    return 0
  fi
  if [[ "${RUN_HEALTH:-ok}" == "broken" && "${REPOLENS_ALLOW_DEGENERATE:-false}" != "true" ]]; then
    printf '2'
    return 0
  fi
  printf '0'
}

# resolve_why_stopped — print the attempt's why_stopped string. Prefers
# summary.json's stopped_reason; when that is empty (e.g. a summary-write race or
# a sentinel dropped without a stop reason) it falls back to whichever abort
# sentinel is present so the attempt entry is never blank while the run clearly
# aborted. Reads SUMMARY_FILE + the LOG_BASE sentinels; no side effects.
resolve_why_stopped() {
  local reason
  reason="$(jq -r '.stopped_reason // empty' "$SUMMARY_FILE" 2>/dev/null || printf '')"
  if [[ -n "$reason" ]]; then
    printf '%s' "$reason"
    return 0
  fi
  if [[ -f "$LOG_BASE/.rate-limit-abort" ]]; then
    printf 'rate-limit'
    return 0
  fi
  if [[ -f "$LOG_BASE/.agent-no-progress-abort" ]]; then
    printf 'agent-no-progress'
    return 0
  fi
  if [[ -f "$LOG_BASE/.systemic-failure-abort" ]]; then
    printf 'systemic-failure'
    return 0
  fi
  if [[ "${REPOLENS_FINAL_STATE:-finished}" == "interrupted" ]]; then
    case "${REPOLENS_INTERRUPT_EXIT_CODE:-130}" in
      129) printf 'interrupted-sighup' ;;
      143) printf 'interrupted-sigterm' ;;
      *) printf 'interrupted-sigint' ;;
    esac
    return 0
  fi
  printf ''
}

apply_rate_limit_abort_final_state() {
  local marker key value exit_code="" stopped_reason="" existing_reason

  marker="$(rate_limit_sleep_interrupt_marker)"
  if [[ -f "$marker" ]]; then
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
      case "$key" in
        exit_code) exit_code="$value" ;;
        stopped_reason) stopped_reason="$value" ;;
      esac
    done < "$marker"

    case "$exit_code" in
      129|130|143) ;;
      *) exit_code=130 ;;
    esac
    case "$stopped_reason" in
      interrupted-sighup|interrupted-sigint|interrupted-sigterm) ;;
      *) stopped_reason="$(rate_limit_sleep_stopped_reason "$exit_code" 2>/dev/null || printf '%s\n' "interrupted-sigint")" ;;
    esac

    REPOLENS_FINAL_STATE="interrupted"
    REPOLENS_INTERRUPT_EXIT_CODE="$exit_code"
    set_stop_reason "$SUMMARY_FILE" "$stopped_reason"
    return 0
  fi

  if [[ -f "$LOG_BASE/.rate-limit-abort" ]]; then
    existing_reason="$(rate_limit_abort_stopped_reason)"
    if is_phase_rate_limit_stopped_reason "$existing_reason"; then
      REPOLENS_FINAL_STATE="failed"
      return 0
    fi

    REPOLENS_FINAL_STATE="rate-limit-pending"
    if [[ -z "$existing_reason" ]]; then
      set_stop_reason "$SUMMARY_FILE" "rate-limited"
    fi
    return 0
  fi

  return 1
}

_handle_hangup() {
  REPOLENS_FINAL_STATE="interrupted"
  REPOLENS_INTERRUPT_EXIT_CODE=129
  print_resume_hint
  exit 129
}

_handle_interrupt() {
  REPOLENS_FINAL_STATE="interrupted"
  REPOLENS_INTERRUPT_EXIT_CODE=130
  print_resume_hint
  exit 130
}

_handle_termination() {
  REPOLENS_FINAL_STATE="interrupted"
  REPOLENS_INTERRUPT_EXIT_CODE=143
  print_resume_hint
  exit 143
}

trap _handle_hangup HUP
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
MIN_SEVERITY_MODE_EXEMPT=""
case "$MODE" in
  discover|feature|custom|greenfield|polish|spec-change)
    if [[ -n "$MIN_SEVERITY" ]]; then
      MIN_SEVERITY_MODE_EXEMPT="$MODE"
      MIN_SEVERITY=""
    fi
    ;;
esac
REPOLENS_MIN_SEVERITY="$MIN_SEVERITY"
export REPOLENS_MIN_SEVERITY

# --- Validate max-cost ---
if [[ -n "$MAX_COST" ]]; then
  [[ "$MAX_COST" =~ ^[0-9]+\.?[0-9]*$ ]] || die "--max-cost must be a numeric value, got: $MAX_COST"
fi

# --- Resolve max-parallel (issue #367) ---
# An explicit --max-parallel is always authoritative: it is validated as a
# positive integer but never re-clamped, so a user may deliberately run below
# the auto-default floor or above its cap. When the flag is unset, the default
# becomes nproc-aware: clamp(detect_nproc(), FLOOR=8, CAP=32). FLOOR=8 keeps
# today's static default as a floor (no small-host regression); CAP=32 bounds
# host-RAM blow-up and provider rate-limit exposure. detect_nproc honors the
# REPOLENS_NPROC env override (parsed before the clamp) for deterministic tests.
# Resolved here, upstream of every consumer (print_wall_estimate, init_parallel,
# the status snapshot), so they all observe the same value — even in sequential
# runs, where the wall-clock preview still divides by MAX_PARALLEL.
if $MAX_PARALLEL_SET; then
  [[ "$MAX_PARALLEL" =~ ^[1-9][0-9]*$ ]] \
    || die "--max-parallel must be a positive integer, got: $MAX_PARALLEL"
else
  MAX_PARALLEL="$(repolens_auto_max_parallel "$(detect_nproc)")"
fi

# --- Derive DONE streak threshold ---
DONE_STREAK_REQUIRED_ENV="${DONE_STREAK_REQUIRED:-}"
DONE_STREAK_REQUIRED="$(mode_default_depth "$MODE")"
if [[ -n "$MAX_ISSUES" ]]; then
  DONE_STREAK_REQUIRED=1
fi

# --- Safety cap: maximum iterations per lens ---
MAX_ITERATIONS_PER_LENS=20

REPOLENS_NO_PROGRESS_LIMIT="${REPOLENS_NO_PROGRESS_LIMIT:-3}"
if [[ ! "$REPOLENS_NO_PROGRESS_LIMIT" =~ ^[1-9][0-9]*$ ]]; then
  die "REPOLENS_NO_PROGRESS_LIMIT must be a positive integer"
fi
REPOLENS_NO_PROGRESS_LIMIT=$((10#$REPOLENS_NO_PROGRESS_LIMIT))
if (( REPOLENS_NO_PROGRESS_LIMIT > MAX_ITERATIONS_PER_LENS )); then
  die "REPOLENS_NO_PROGRESS_LIMIT must be <= MAX_ITERATIONS_PER_LENS=$MAX_ITERATIONS_PER_LENS"
fi

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
_origin_url="$(git -C "$PROJECT_PATH" remote get-url origin 2>/dev/null || true)"
FORGE_HOST="$(detect_forge_host "$_origin_url")"
FORGE_REPO_SLUG="$(forge_remote_repo_slug "$_origin_url")"
if [[ -n "$FORGE_REPO_SLUG" ]]; then
  REPO_OWNER="${FORGE_REPO_SLUG%%/*}"
  REPO_NAME="${FORGE_REPO_SLUG#*/}"
else
  REPO_OWNER="local"
  REPO_NAME="$(basename "$PROJECT_PATH")"
  FORGE_REPO_SLUG="$REPO_OWNER/$REPO_NAME"
fi
# Filing and synthesize callbacks read FORGE_REPO directly; keep it on
# the origin-derived slug so renamed checkouts do not file against basename.
FORGE_REPO="$FORGE_REPO_SLUG"
export FORGE_REPO

# --- Validate agent and dependencies ---
validate_agent "$AGENT"
require_cmd git
require_cmd jq
require_cmd timeout

require_agent_cmd "$AGENT"

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
  # `--resume` with no explicit id resolves to the newest interrupted run.
  # Resolve here — before LOG_BASE/acquire_run_lock/mkdir below — so a
  # no-candidate die leaks no fresh run dir.
  if [[ "$RESUME_RUN_ID" == "@latest" ]]; then
    RESUME_RUN_ID="$(_resolve_latest_incomplete_run)" \
      || die "No interrupted run found to resume; pass an explicit run id or start a fresh run."
    log_info "Auto-resuming latest interrupted run: $RESUME_RUN_ID"
  fi
  if [[ "$RESUME_RUN_ID" == *"/"* || "$RESUME_RUN_ID" == "." || "$RESUME_RUN_ID" == ".." ]]; then
    die "Invalid run id '$(status_sanitize_display "$RESUME_RUN_ID")'. Run ids must be direct logs/ children."
  fi
  RUN_ID="$RESUME_RUN_ID"
else
  RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$(od -An -tx1 -N4 /dev/urandom | tr -d ' \n')"
fi

# --- Directories ---
LOG_BASE="$SCRIPT_DIR/logs/$RUN_ID"
export LOG_BASE
acquire_run_lock
HEARTBEAT_DIR="$LOG_BASE/.heartbeat"
mkdir -p "$HEARTBEAT_DIR"
# Record the start of THIS invocation for the per-attempt audit trail (#371).
# Runs for every invocation incl. --dry-run and --resume; before .completed is
# touched so a fresh-run baseline is correctly 0. Non-fatal.
attempts_begin "$LOG_BASE"
SUMMARY_FILE="$LOG_BASE/summary.json"
if [[ -n "$RESUME_RUN_ID" && -f "$LOG_BASE/.agent-no-progress-abort" ]]; then
  rm -f "$LOG_BASE/.agent-no-progress-abort"
  clear_stop_reason "$SUMMARY_FILE"
fi
if [[ -n "$RESUME_RUN_ID" && -f "$LOG_BASE/.rate-limit-abort" ]]; then
  rm -f "$LOG_BASE/.rate-limit-abort" "$LOG_BASE/.rate-limit-abort.tmp."*
  clear_stop_reason "$SUMMARY_FILE"
fi
if [[ -n "$RESUME_RUN_ID" && -f "$LOG_BASE/.rate-limit-sleep-interrupt" ]]; then
  rm -f "$LOG_BASE/.rate-limit-sleep-interrupt" "$LOG_BASE/.rate-limit-sleep-interrupt.tmp."*
  clear_stop_reason "$SUMMARY_FILE"
fi
if [[ -n "$RESUME_RUN_ID" && -f "$LOG_BASE/.systemic-failure-abort" ]]; then
  rm -f "$LOG_BASE/.systemic-failure-abort"
  clear_stop_reason "$SUMMARY_FILE"
fi
if [[ -n "$REMOTE_TARGET" ]]; then
  REMOTE_RUN_DIR="$LOG_BASE/.remote"
  mkdir -p "$REMOTE_RUN_DIR"
  remote_control_socket_dir
  REPOLENS_REMOTE_SSH_CONTROL_DIR="$REMOTE_CONTROL_SOCKET_DIR_RESULT"
  REPOLENS_REMOTE_SSH_SOCKET="$(remote_control_socket_path "$REPOLENS_REMOTE_SSH_CONTROL_DIR")"
  export REPOLENS_REMOTE_SSH_CONTROL_DIR REPOLENS_REMOTE_SSH_SOCKET
fi

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

# --- Compute / rehydrate the spec diff for spec-change mode ---
# spec-change derives its work from the git diff of the tracked --spec file
# against --spec-base (default HEAD = working-tree-vs-HEAD, i.e. the uncommitted
# edit). The diff is the authoritative change signal: it is computed ONCE here,
# persisted verbatim to logs/<run-id>/spec-diff.txt so every lens (and every
# --resume) renders the identical diff, and passed into compose_prompt via the
# SPEC_DIFF file-backed template var. The spec must be a file tracked by git
# inside the repo so a diff baseline exists (mirrors the greenfield/custom
# fail-fast guards). An empty diff is valid — it renders a "no changes" notice
# and the wrapper terminates early without filing issues.
SPEC_DIFF_FILE="$LOG_BASE/spec-diff.txt"
if [[ "$MODE" == "spec-change" ]]; then
  if [[ -n "$RESUME_RUN_ID" && -f "$SPEC_DIFF_FILE" ]]; then
    : # Reuse the diff captured at the original run start for reproducibility.
  else
    git -C "$PROJECT_PATH" ls-files --error-unmatch -- "$SPEC_FILE" >/dev/null 2>&1 \
      || die "Mode 'spec-change' requires --spec to be a file tracked by git inside $PROJECT_PATH (so a diff baseline exists): $SPEC_FILE"
    if ! _spec_diff_output="$(git -C "$PROJECT_PATH" diff "$SPEC_BASE" -- "$SPEC_FILE" 2>/dev/null)"; then
      die "Mode 'spec-change' could not compute the spec diff against base ref '$SPEC_BASE' — check that it is a valid git ref or range."
    fi
    printf '%s' "$_spec_diff_output" > "$SPEC_DIFF_FILE" \
      || die "Unable to persist spec diff to $SPEC_DIFF_FILE"
    unset _spec_diff_output
  fi
fi

# Path to the round-0 triage context pack. Populated by run_triage when
# --no-triage is off in bugreport mode; substituted into round-1 lens prompts
# via the {{TRIAGE_CONTEXT_PACK}} slot. When the file is absent (other modes,
# --no-triage, or triage failure) the slot resolves to empty in lens prompts.
TRIAGE_CONTEXT_PACK_FILE="$LOG_BASE/triage/context-pack.md"
POLISH_VOICE_PROFILE_FILE="$LOG_BASE/polish/voice-profile.md"
export POLISH_VOICE_PROFILE_FILE
if [[ "$MODE" == "polish" ]]; then
  mkdir -p "$LOG_BASE/polish/suggestions" || die "Unable to initialize polish suggestions directory"
fi
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

# resolve_effective_agent <domain> <lens_id> — return the agent that should run
# this lens. Precedence: fully-qualified lens key (domain/lens) > domain key >
# global $AGENT. Reads the AGENT_OVERRIDES map populated by
# validate_agent_overrides; with no overrides it always returns $AGENT, so the
# no-override path is byte-for-byte unchanged (issue #380).
resolve_effective_agent() {
  local domain="$1" lens_id="$2"
  local lens_key="$domain/$lens_id"
  if [[ -n "${AGENT_OVERRIDES[$lens_key]:-}" ]]; then
    printf '%s\n' "${AGENT_OVERRIDES[$lens_key]}"
  elif [[ -n "${AGENT_OVERRIDES[$domain]:-}" ]]; then
    printf '%s\n' "${AGENT_OVERRIDES[$domain]}"
  else
    printf '%s\n' "$AGENT"
  fi
}

# overrides_active — true when at least one --agent-override pair is in effect.
overrides_active() {
  [[ "${#AGENT_OVERRIDES[@]}" -gt 0 ]]
}

# validate_agent_overrides — parse AGENT_OVERRIDE_CSV, validate every pair up
# front (fail fast, before any lens runs), and populate AGENT_OVERRIDES. Each
# pair is key=agent split on the FIRST '=' only so opencode/<model> values
# survive. The agent value goes through the same validate_agent allow-list and
# require_agent_cmd binary check as the global --agent. The key must be a known
# domain id or a fully-qualified domain/lens tuple from domains.json; a bare
# lens id (ambiguous — lens ids are not globally unique) or an unknown key is
# rejected loudly so a typo never silently no-ops the routing the operator asked
# for.
validate_agent_overrides() {
  [[ -n "$AGENT_OVERRIDE_CSV" ]] || return 0

  local -A _known_domains=() _known_tuples=() _known_lens_ids=()
  local _row
  while IFS= read -r _row; do
    [[ -n "$_row" ]] && _known_domains["$_row"]=1
  done < <(jq -r '.domains[].id' "$DOMAINS_FILE")
  while IFS= read -r _row; do
    [[ -n "$_row" ]] && _known_tuples["$_row"]=1
  done < <(jq -r '.domains[] | .id as $d | .lenses[]
                  | (if type == "string" then . else .id end)
                  | "\($d)/\(.)"' "$DOMAINS_FILE")
  while IFS= read -r _row; do
    [[ -n "$_row" ]] && _known_lens_ids["$_row"]=1
  done < <(jq -r '.domains[].lenses[] | (if type == "string" then . else .id end)' "$DOMAINS_FILE")

  local -a _pairs=()
  IFS=',' read -ra _pairs <<< "$AGENT_OVERRIDE_CSV"
  local _pair _key _val
  for _pair in "${_pairs[@]}"; do
    # Trim surrounding whitespace.
    _pair="${_pair#"${_pair%%[![:space:]]*}"}"
    _pair="${_pair%"${_pair##*[![:space:]]}"}"
    [[ -z "$_pair" ]] && continue
    [[ "$_pair" == *=* ]] || die "--agent-override: '$_pair' is not in key=agent form"
    # Split on the FIRST '=' only so opencode/<model> values are preserved.
    _key="${_pair%%=*}"
    _val="${_pair#*=}"
    _key="${_key#"${_key%%[![:space:]]*}"}"; _key="${_key%"${_key##*[![:space:]]}"}"
    _val="${_val#"${_val%%[![:space:]]*}"}"; _val="${_val%"${_val##*[![:space:]]}"}"
    [[ -n "$_key" ]] || die "--agent-override: empty override key in '$_pair'"
    [[ -n "$_val" ]] || die "--agent-override: empty agent for override key '$_key'"

    # Validate the agent value against the same allow-list + binary check the
    # global --agent uses. validate_agent names the offending value on failure.
    validate_agent "$_val"
    require_agent_cmd "$_val"

    # Validate the key. A '/' means a fully-qualified lens key.
    if [[ "$_key" == */* ]]; then
      [[ -n "${_known_tuples[$_key]:-}" ]] \
        || die "--agent-override: unknown domain/lens key '$_key' (no such lens in $DOMAINS_FILE)"
    elif [[ -n "${_known_domains[$_key]:-}" ]]; then
      :
    elif [[ -n "${_known_lens_ids[$_key]:-}" ]]; then
      die "--agent-override: bare lens key '$_key' is ambiguous (lens ids are not unique across domains); use the fully-qualified domain/lens form"
    else
      die "--agent-override: unknown override key '$_key' (expected a domain id or domain/lens from $DOMAINS_FILE)"
    fi

    AGENT_OVERRIDES["$_key"]="$_val"
  done
}

validate_agent_overrides
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

# Opt-in startup retention: prune old run dirs in the background (no-op unless
# REPOLENS_AUTO_CLEAN=true). Never blocks or fails the run.
maybe_auto_clean

log_info "RepoLens run $RUN_ID starting"
log_info "Project: $PROJECT_PATH ($FORGE_REPO_SLUG)"
log_info "Agent: $AGENT | Mode: $MODE | Parallel: $PARALLEL"
log_info "Agent timeout: ${AGENT_TIMEOUT_SECS}s"
log_info "Agent timeout kill grace: ${AGENT_KILL_GRACE_SECS}s"
log_info "Lens wall-clock budget: ${LENS_MAX_WALL_SECS}s"
[[ -n "$SPEC_FILE" ]] && log_info "Spec: $SPEC_FILE"
[[ -n "$MAX_ISSUES" ]] && log_info "Max issues: $MAX_ISSUES (DONE streak: 1)"
if [[ -n "$MIN_SEVERITY_MODE_EXEMPT" ]]; then
  log_warn "--min-severity has no effect in ${MIN_SEVERITY_MODE_EXEMPT} mode (this mode does not use severity)"
fi
[[ -n "$MIN_SEVERITY" ]] && log_info "Min severity: $MIN_SEVERITY"
[[ "$MODE" == "discover" ]] && log_info "Discover mode: single-pass brainstorming (DONE streak: 1)"
[[ "$MODE" == "deploy" ]] && log_info "Deploy mode: single-pass server audit (DONE streak: 1)"
if [[ "$MODE" == "deploy" && "${TARGET_TYPE:-server}" == "android" && -n "${ANDROID_APK_PATH:-}" ]]; then
  log_info "Android deploy APK path: $(android_apk_display_path "$ANDROID_APK_PATH")"
fi

run_remote_preflight() {
  remote_preflight
}

[[ "$MODE" == "custom" ]] && log_info "Custom mode: change impact analysis (DONE streak: 1)"
[[ "$MODE" == "opensource" ]] && log_info "Open source mode: readiness audit (DONE streak: 1)"
[[ "$MODE" == "content" ]] && log_info "Content mode: content audit & creation (DONE streak: 1)"
[[ "$MODE" == "greenfield" ]] && log_info "Greenfield mode: spec-to-backlog planning (DONE streak: 1)"
[[ "$MODE" == "polish" ]] && log_info "Polish mode: single-pass polishing (DONE streak: 1)"
[[ "$MODE" == "spec-change" ]] && log_info "Spec-change mode: spec-diff impact analysis vs base '$SPEC_BASE' (DONE streak: 1)"
POLISH_SURFACE=""
if [[ "$MODE" == "polish" ]]; then
  POLISH_SURFACE="$(detect_polish_surface "$PROJECT_PATH")"
  export POLISH_SURFACE
  log_info "Polish surface: $POLISH_SURFACE"
fi
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
  # Mode-aware jq filter: isolated modes see only their own domains, default
  # code modes exclude isolated domains. Deploy additionally narrows to a
  # single domain based on TARGET_TYPE so server and Android lens families
  # never co-run. Polish additionally narrows visual-only domains to visual
  # polish surfaces.
  local deploy_domain="deployment"
  if [[ "$MODE" == "deploy" && "${TARGET_TYPE:-server}" == "android" ]]; then
    deploy_domain="android"
  fi
  local polish_surface="${POLISH_SURFACE:-}"
  local active_domain_jq='
    def active_domain:
      if $mode == "discover" then
        select(.mode == "discover")
      elif $mode == "deploy" then
        select(.mode == "deploy" and .id == $deploy_domain)
      elif $mode == "opensource" then
        select(.mode == "opensource")
      elif $mode == "content" then
        select(.mode == "content")
      elif $mode == "greenfield" then
        select(.mode == "greenfield")
      elif $mode == "polish" then
        select(.mode == "polish")
        | select(
            ($polish_surface == "")
            or ((.polish_surfaces // ["visual-ui", "cli-backend"]) | index($polish_surface))
          )
      elif $mode == "spec-change" then
        select(.mode == "spec-change")
      else
        select(
          .mode != "discover"
          and .mode != "deploy"
          and .mode != "opensource"
          and .mode != "content"
          and .mode != "greenfield"
          and .mode != "polish"
          and .mode != "spec-change"
        )
      end;
  '

  if [[ -n "$FOCUS" ]]; then
    # Single lens mode — find which domain it belongs to. If a domain filter is
    # also present, use it to disambiguate duplicate lens IDs across domains.
    local found_domain=""
    if [[ -n "$DOMAIN_FILTER" ]]; then
      found_domain="$(jq -r --arg lens "$FOCUS" --arg d "$DOMAIN_FILTER" --arg mode "$MODE" --arg deploy_domain "$deploy_domain" --arg polish_surface "$polish_surface" \
        "$active_domain_jq
        .domains[]
        | active_domain
        | select(.id == \$d)
        | select([.lenses[] | if type == \"string\" then . else .id end] | index(\$lens))
        | .id" "$DOMAINS_FILE" | head -1)"
      if [[ -z "$found_domain" ]]; then
        if [[ "$MODE" == "polish" ]]; then
          die "Lens '$FOCUS' not available in domain '$DOMAIN_FILTER' for current polish surface: ${polish_surface:-unknown}"
        fi
        die "Lens '$FOCUS' not found in domain '$DOMAIN_FILTER' (mode: $MODE)"
      fi
    else
      found_domain="$(jq -r --arg lens "$FOCUS" --arg mode "$MODE" --arg deploy_domain "$deploy_domain" --arg polish_surface "$polish_surface" \
        "$active_domain_jq
        .domains[]
        | active_domain
        | select([.lenses[] | if type == \"string\" then . else .id end] | index(\$lens))
        | .id" "$DOMAINS_FILE" | head -1)"
      if [[ -z "$found_domain" ]]; then
        if [[ "$MODE" == "polish" ]]; then
          die "Lens '$FOCUS' not available for current polish surface: ${polish_surface:-unknown}"
        fi
        die "Lens '$FOCUS' not found in domains.json (mode: $MODE)"
      fi
    fi

    local lens_file="$LENSES_DIR/$found_domain/$FOCUS.md"
    [[ -f "$lens_file" ]] || die "Lens prompt file missing: $lens_file"

    echo "$found_domain/$FOCUS"
    return
  fi

  if [[ -n "$DOMAIN_FILTER" ]]; then
    # Domain filter mode
    local domain_exists=""
    domain_exists="$(jq -r --arg d "$DOMAIN_FILTER" --arg mode "$MODE" --arg deploy_domain "$deploy_domain" --arg polish_surface "$polish_surface" \
      "$active_domain_jq
      .domains[]
      | active_domain
      | select(.id == \$d)
      | .id" "$DOMAINS_FILE")"
    if [[ -z "$domain_exists" ]]; then
      if [[ "$MODE" == "polish" ]]; then
        die "Domain '$DOMAIN_FILTER' not available for current polish surface: ${polish_surface:-unknown}"
      fi
      die "Domain '$DOMAIN_FILTER' not found in domains.json (mode: $MODE)"
    fi

    jq -r --arg d "$DOMAIN_FILTER" --arg mode "$MODE" --arg deploy_domain "$deploy_domain" --arg polish_surface "$polish_surface" \
      "$active_domain_jq
      .domains[]
      | active_domain
      | select(.id == \$d)
      | .id as \$d
      | .lenses[]
      | (if type == \"string\" then {id: ., skip_modes: []} else . end)
      | select(((.skip_modes // []) | index(\$mode)) | not)
      | \$d + \"/\" + .id" "$DOMAINS_FILE"
    return
  fi

  # All lenses — ordered by domain order
  local _all_lenses
  _all_lenses="$(jq -r --arg mode "$MODE" --arg deploy_domain "$deploy_domain" --arg polish_surface "$polish_surface" \
    "$active_domain_jq
    .domains
    | sort_by(.order)[]
    | active_domain
    | .id as \$d
    | .lenses[]
    | (if type == \"string\" then {id: ., skip_modes: []} else . end)
    | select(((.skip_modes // []) | index(\$mode)) | not)
    | \$d + \"/\" + .id" "$DOMAINS_FILE")"

  # Issue #228: --relevant-domains <csv> deterministic allowlist. Operator-given
  # CSV of domain ids; intersects with the mode-filtered lens list. Validated
  # against the mode's domain whitelist so typos or wrong-mode ids fail loudly.
  if [[ "$RELEVANT_DOMAINS_SET" == "true" ]]; then
    local -A _rd_allowed=()
    local _rd_allow_id
    while IFS= read -r _rd_allow_id; do
      [[ -z "$_rd_allow_id" ]] && continue
      _rd_allowed["$_rd_allow_id"]=1
    done < <(jq -r --arg mode "$MODE" --arg deploy_domain "$deploy_domain" --arg polish_surface "$polish_surface" \
      "$active_domain_jq
      .domains[]
      | active_domain
      | .id" "$DOMAINS_FILE")

    local -A _rd_keep=()
    local _rd_token _rd_count=0
    local _rd_csv="$RELEVANT_DOMAINS_CSV"
    local -a _rd_arr=()
    IFS=',' read -ra _rd_arr <<< "$_rd_csv"
    for _rd_token in "${_rd_arr[@]}"; do
      # Trim whitespace
      _rd_token="${_rd_token#"${_rd_token%%[![:space:]]*}"}"
      _rd_token="${_rd_token%"${_rd_token##*[![:space:]]}"}"
      [[ -z "$_rd_token" ]] && continue
      if [[ -z "${_rd_allowed[$_rd_token]:-}" ]]; then
        if [[ "$MODE" == "polish" ]]; then
          die "--relevant-domains: domain id '$_rd_token' not available for current polish surface: ${polish_surface:-unknown}"
        fi
        die "--relevant-domains: unknown or wrong-mode domain id '$_rd_token' (mode: $MODE)"
      fi
      _rd_keep["$_rd_token"]=1
      _rd_count=$((_rd_count + 1))
    done

    if (( _rd_count == 0 )); then
      die "--relevant-domains: CSV contains no valid domain ids: '$RELEVANT_DOMAINS_CSV'"
    fi

    local _rd_pruned="" _rd_entry _rd_entry_domain
    while IFS= read -r _rd_entry; do
      [[ -z "$_rd_entry" ]] && continue
      _rd_entry_domain="${_rd_entry%%/*}"
      if [[ -n "${_rd_keep[$_rd_entry_domain]:-}" ]]; then
        _rd_pruned+="$_rd_entry"$'\n'
      fi
    done <<< "$_all_lenses"
    _rd_pruned="${_rd_pruned%$'\n'}"
    _all_lenses="$_rd_pruned"
  fi

  # Issue #228: --scope-by-keywords deterministic, LLM-free pruning. Substring
  # match the bug-report text (case-insensitive) against each domain's
  # "keywords" field. Missing/empty keywords → keep (back-compat). Zero match
  # across the whole set → fall through with no pruning (avoid empty lens list).
  if [[ "$SCOPE_BY_KEYWORDS" == "true" && "$MODE" == "bugreport" && -n "${BUG_REPORT:-}" ]]; then
    local _kw_bug_lower
    _kw_bug_lower="$(printf '%s' "$BUG_REPORT" | tr '[:upper:]' '[:lower:]')"

    local -A _kw_keep=()
    local -a _kw_parts=()
    local _kw_dom _kw_match _kw_i _kw_w
    while IFS=$'\t' read -r -a _kw_parts; do
      _kw_dom="${_kw_parts[0]:-}"
      [[ -z "$_kw_dom" ]] && continue
      if (( ${#_kw_parts[@]} <= 1 )); then
        # No keywords field (or empty list) — back-compat: always keep.
        _kw_keep["$_kw_dom"]=1
        continue
      fi
      _kw_match=0
      for (( _kw_i = 1; _kw_i < ${#_kw_parts[@]}; _kw_i++ )); do
        _kw_w="${_kw_parts[$_kw_i]}"
        [[ -z "$_kw_w" ]] && continue
        if [[ "$_kw_bug_lower" == *"$_kw_w"* ]]; then
          _kw_match=1
          break
        fi
      done
      if (( _kw_match == 1 )); then
        _kw_keep["$_kw_dom"]=1
      fi
    done < <(jq -r --arg mode "$MODE" --arg deploy_domain "$deploy_domain" --arg polish_surface "$polish_surface" "
      $active_domain_jq
      .domains[]
      | active_domain
      | [.id] + ((.keywords // []) | map(ascii_downcase))
      | @tsv
    " "$DOMAINS_FILE")

    if (( ${#_kw_keep[@]} > 0 )); then
      local _kw_pruned="" _kw_entry _kw_entry_domain
      while IFS= read -r _kw_entry; do
        [[ -z "$_kw_entry" ]] && continue
        _kw_entry_domain="${_kw_entry%%/*}"
        if [[ -n "${_kw_keep[$_kw_entry_domain]:-}" ]]; then
          _kw_pruned+="$_kw_entry"$'\n'
        fi
      done <<< "$_all_lenses"
      _kw_pruned="${_kw_pruned%$'\n'}"
      if [[ -n "$_kw_pruned" ]]; then
        _all_lenses="$_kw_pruned"
      fi
    fi
  fi

  # Bugreport mode: when the triage agent has produced a relevant-domains
  # whitelist, intersect by domain prefix. Missing-or-empty file → full
  # fanout (the safe path: matches behavior pre-issue #227 and avoids the
  # zero-lens edge case from agent over-pruning).
  local _relevant_file="${LOG_BASE:-}/triage/relevant-domains.txt"
  if [[ "$MODE" == "bugreport" && -s "$_relevant_file" ]]; then
    local -A _keep=()
    local _dom_keep _kept_count=0
    while IFS= read -r _dom_keep; do
      [[ -z "$_dom_keep" ]] && continue
      _keep["$_dom_keep"]=1
      _kept_count=$((_kept_count + 1))
    done < "$_relevant_file"

    if (( _kept_count > 0 )); then
      local _pruned _entry _entry_domain
      _pruned=""
      while IFS= read -r _entry; do
        [[ -z "$_entry" ]] && continue
        _entry_domain="${_entry%%/*}"
        if [[ -n "${_keep[$_entry_domain]:-}" ]]; then
          _pruned+="$_entry"$'\n'
        fi
      done <<< "$_all_lenses"
      _pruned="${_pruned%$'\n'}"
      if [[ -n "$_pruned" ]]; then
        _all_lenses="$_pruned"
      fi
    fi
  fi

  printf '%s\n' "$_all_lenses"
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
  elif [[ "$MODE" == "polish" && "$DRY_RUN" == true ]]; then
    log_info "Polish mode has no lenses to run yet."
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
# Handles: claude, codex, spark, sparc, opencode, antigravity, copilot, and the
# <agent>/<model> forms claude/, codex/, opencode/, antigravity/, copilot/
# (issue #384).
# For a slashed agent: an explicit id in models{} is priced directly; otherwise
# a keyword heuristic buckets the model name into a generic-{flash,pro,premium}
# class so a brand-new model name is approximated instead of falling back to an
# arbitrary high default. opencode/<model> keeps its historical opencode-default
# fallback. Bare agents resolve via agent_default_model.
resolve_agent_model() {
  local agent="$1" pricing_file="$2"
  local default_model model_check requested req_lower
  if [[ "$agent" == */* ]]; then
    requested="${agent#*/}"
    # Explicit id wins over the keyword heuristic, so a known model is priced
    # exactly rather than mis-bucketed by an unlucky substring in its name.
    model_check="$(jq -r --arg m "$requested" '.models[$m] | .input_per_mtok // empty' "$pricing_file" 2>/dev/null)"
    if [[ -n "$model_check" ]]; then
      echo "$requested"
      return
    fi
    # opencode retains its single documented fallback for unknown models.
    if [[ "$agent" == opencode/* ]]; then
      echo "opencode-default"
      return
    fi
    # Keyword heuristic for the native agents. Cheap keywords are checked BEFORE
    # premium so a name like *-flash-preview lands in the cheap bucket, not the
    # premium one 'preview' would otherwise imply. Match case-insensitively.
    # 'mini' is boundary-anchored (start-of-string or preceded by a delimiter) so
    # the substring in "geMINI" no longer buckets every Gemini model as cheap,
    # while o3-mini / gpt-4o-mini still match. A trailing-delimiter form (*mini-*)
    # would NOT help: "gemini-3-pro" contains "mini-", so it must stay leading-only.
    req_lower="$(printf '%s' "$requested" | tr '[:upper:]' '[:lower:]')"
    if [[ "$req_lower" == *flash* || "$req_lower" == *haiku* \
          || "$req_lower" == mini* || "$req_lower" == *-mini* || "$req_lower" == *_mini* || "$req_lower" == *.mini* \
          || "$req_lower" == *8b* || "$req_lower" == *lite* || "$req_lower" == *nano* ]]; then
      echo "generic-flash-default"
    elif [[ "$req_lower" == *opus* || "$req_lower" == *ultra* || "$req_lower" == *preview* ]]; then
      echo "generic-premium-default"
    else
      echo "generic-pro-default"
    fi
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

# Cost breakdown for a routed run (issue #380). When --agent-override sends some
# lenses to a pricier/cheaper model, a single-model estimate silently misprices
# the exact budgeting use case this feature serves. Partition LENS_LIST by
# effective agent, price each group with the shared compute_cost_breakdown, and
# emit a combined total. Output shape matches compute_cost_breakdown: a first
# MIN_COST=<total> line (callers extract it) followed by human-readable lines.
compute_cost_breakdown_routed() {
  local streak="$1" path="$2" pricing_file="$3" rounds="$4"

  local -A _agent_counts=()
  local _entry _dom _lid _eff
  for _entry in "${LENS_LIST[@]}"; do
    _dom="${_entry%%/*}"
    _lid="${_entry#*/}"
    _eff="$(resolve_effective_agent "$_dom" "$_lid")"
    _agent_counts["$_eff"]=$(( ${_agent_counts["$_eff"]:-0} + 1 ))
  done

  local _total="0.00" _lines="" _a _cnt _sub _sub_min _sub_lines
  for _a in "${!_agent_counts[@]}"; do
    _cnt="${_agent_counts[$_a]}"
    _sub="$(compute_cost_breakdown "$_a" "$_cnt" "$streak" "$path" "$pricing_file" "$rounds")"
    _sub_min="$(printf '%s\n' "$_sub" | awk -F= '/^MIN_COST=/ {print $2; exit}')"
    _sub_lines="$(printf '%s\n' "$_sub" | grep -v '^MIN_COST=')"
    _total="$(awk -v a="$_total" -v b="${_sub_min:-0}" 'BEGIN { printf "%.2f", a + b }')"
    _lines+="  agent '$_a' — ${_cnt} lens(es):"$'\n'"$_sub_lines"$'\n'
  done

  printf 'MIN_COST=%s\n' "$_total"
  printf '%s' "$_lines"
}

# Flat-rate / subscription cost view (issue #384). For Claude Pro / ChatGPT Plus
# / Gemini Advanced / free-tier users the marginal per-token cost is $0.00, so a
# dollar estimate is misleading. This renders "$0.00" plus the expected request
# count (the same lenses x avg_iters x rounds the token estimate uses) and the
# quota/rate-limit consumption to weigh against a subscription cap or free-tier
# budget. Reads TOTAL_LENSES, DONE_STREAK_REQUIRED, ROUNDS, PROJECT_PATH.
print_flat_rate_cost() {
  local pricing_file="$1"
  local iter_factor base_prompt input_cap out_per bytes_per_tok
  iter_factor="$(jq -r '.session_model.iteration_factor // 1.7' "$pricing_file" 2>/dev/null)"
  base_prompt="$(jq -r '.session_model.base_prompt_tokens // 3000' "$pricing_file" 2>/dev/null)"
  input_cap="$(jq -r '.session_model.per_session_input_cap_tokens // 200000' "$pricing_file" 2>/dev/null)"
  out_per="$(jq -r '.session_model.per_session_output_tokens // 8000' "$pricing_file" 2>/dev/null)"
  bytes_per_tok="$(jq -r '.session_model.bytes_per_token // 4' "$pricing_file" 2>/dev/null)"
  # set -u-safe fallbacks: a malformed/absent value must not abort the estimate.
  [[ "$iter_factor" =~ ^[0-9]+(\.[0-9]+)?$ ]] || iter_factor="1.7"
  [[ "$base_prompt" =~ ^[0-9]+$ ]] || base_prompt=3000
  [[ "$input_cap" =~ ^[0-9]+$ ]] || input_cap=200000
  [[ "$out_per" =~ ^[0-9]+$ ]] || out_per=8000
  [[ "$bytes_per_tok" =~ ^[1-9][0-9]*$ ]] || bytes_per_tok=4

  local repo_bytes
  repo_bytes="$(estimate_repo_bytes "$PROJECT_PATH")"

  awk -v lenses="$TOTAL_LENSES" -v streak="$DONE_STREAK_REQUIRED" -v rounds="$ROUNDS" \
      -v iter_factor="$iter_factor" -v base_prompt="$base_prompt" \
      -v input_cap="$input_cap" -v out_per="$out_per" \
      -v repo_bytes="$repo_bytes" -v bytes_per_tok="$bytes_per_tok" \
      'BEGIN {
        if (rounds < 1) rounds = 1
        avg_iters = streak * iter_factor
        requests = lenses * avg_iters * rounds
        if (requests < 1) requests = 1
        repo_tokens = int(repo_bytes / bytes_per_tok)
        session_input = (repo_tokens < input_cap ? repo_tokens : input_cap) + base_prompt

        printf "Estimated cost: ~$0.00 (Flat-Rate / Subscription / Free Tier)\n"
        printf "  Total expected requests: ~%.0f LLM calls  (%d lenses x ~%.1f iterations x %d round(s))\n", requests, lenses, avg_iters, rounds
        printf "  - Consumes your plan message/rate quota, not a per-token bill. Weigh ~%.0f calls against:\n", requests
        printf "      a typical 3-hour subscription cap (e.g. Claude Pro / Gemini Advanced, ~45-50 messages), or\n"
        printf "      a free-tier rate budget (e.g. Google AI Studio 15 RPM / 1500 RPD).\n"
        printf "  - Pace or split large runs so you do not lock yourself out of your plan mid-audit.\n"
        if (session_input >= 1000) {
          printf "  Total expected tokens: ~%.0fk input + ~%d output per session\n", session_input/1000.0, out_per
        } else {
          printf "  Total expected tokens: ~%d input + ~%d output per session\n", session_input, out_per
        }
      }'
}

# Print the active --agent-override routing map (one 'key -> agent' per line),
# sorted for stable output. No-op when no overrides are set.
print_agent_override_map() {
  overrides_active || return 0
  local _k
  echo "Agent overrides:"
  while IFS= read -r _k; do
    [[ -n "$_k" ]] && echo "  $_k -> ${AGENT_OVERRIDES[$_k]}"
  done < <(printf '%s\n' "${!AGENT_OVERRIDES[@]}" | sort)
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

check_pricing_freshness() {
  local pricing_file="$1"
  local updated_at
  updated_at="$(jq -r '.updated_at // empty' "$pricing_file" 2>/dev/null)"
  if [[ -z "$updated_at" ]]; then
    return 0
  fi
  local updated_epoch now_epoch days_old
  updated_epoch="$(date -d "$updated_at" +%s 2>/dev/null)" || return 0
  now_epoch="$(date +%s)"
  days_old=$(( (now_epoch - updated_epoch) / 86400 ))
  if [[ "$days_old" -gt 60 ]]; then
    log_warn "Pricing data is ${days_old} days old — estimates may be inaccurate"
  fi
}

# Print the estimated wall-clock line and, when the estimate exceeds the
# REPOLENS_EST_WARN_HOURS threshold (default 24h; 0 disables), a loud warning
# listing concrete tuning levers. Reads the resolved run globals
# (TOTAL_LENSES / DONE_STREAK_REQUIRED / ROUNDS / MAX_PARALLEL). Pure
# presentation — wired into both confirm_run() and the dry-run preview. The
# line is omitted gracefully when the estimator helper is unavailable or
# returns a non-numeric result; a non-numeric threshold falls back to 24h.
print_wall_estimate() {
  declare -F estimate_run_wall_seconds >/dev/null 2>&1 || return 0

  local secs
  secs="$(estimate_run_wall_seconds "$TOTAL_LENSES" "$DONE_STREAK_REQUIRED" "$ROUNDS" "$MAX_PARALLEL" 2>/dev/null)"
  # Graceful omission (AC4): a missing/empty/non-numeric estimate prints nothing.
  [[ "$secs" =~ ^[0-9]+$ ]] || return 0

  local human="${secs}s"
  if declare -F status_format_duration >/dev/null 2>&1; then
    human="$(status_format_duration "$secs")"
  fi
  echo "Estimated wall-clock: ~${human} at --max-parallel ${MAX_PARALLEL}  (rough; faster/cheaper agents and scoping reduce this)."

  # Over-threshold warning with concrete tuning levers. The threshold is
  # REPOLENS_EST_WARN_HOURS (default 24h); a non-numeric value falls back to the
  # default and 0 disables the warning entirely. ${VAR:-default} keeps the read
  # set -u-safe even when the env var is unset.
  local warn_hours="${REPOLENS_EST_WARN_HOURS:-24}"
  [[ "$warn_hours" =~ ^[0-9]+$ ]] || warn_hours=24
  # Force base-10 so a zero-padded value ("08"/"09"/"024") is not read as octal,
  # which would abort the (( )) test or silently shift the threshold. Matches the
  # 10#$ guard the sibling estimator already uses in lib/summary.sh.
  warn_hours=$((10#$warn_hours))
  if (( warn_hours > 0 )) && (( secs > warn_hours * 3600 )); then
    log_warn "Estimated wall-clock ~${human} exceeds ${warn_hours}h. To cut it down:"
    log_warn "  - raise --max-parallel so more lenses run concurrently"
    log_warn "  - pick a faster/cheaper --agent"
    log_warn "  - lower --depth (fewer DONE-streak iterations per lens)"
    log_warn "  - scope the run with --domain / --focus"
    log_warn "  - use --max-issues N for a spot check"
  fi
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
  check_pricing_freshness "$pricing_file"
  local breakdown min_cost breakdown_lines
  # Flat-rate mode ($0 marginal cost) skips the per-token breakdown entirely and
  # renders the request/quota view instead. min_cost stays "0.00" so the
  # --max-cost guardrail below is inert (0 never exceeds any threshold).
  if ! $FLAT_RATE; then
    if overrides_active; then
      breakdown="$(compute_cost_breakdown_routed "$DONE_STREAK_REQUIRED" "$PROJECT_PATH" "$pricing_file" "$ROUNDS")"
    else
      breakdown="$(compute_cost_breakdown "$AGENT" "$TOTAL_LENSES" "$DONE_STREAK_REQUIRED" "$PROJECT_PATH" "$pricing_file" "$ROUNDS")"
    fi
    min_cost="$(printf "%s\n" "$breakdown" | awk -F= '/^MIN_COST=/ {print $2; exit}')"
    breakdown_lines="$(printf "%s\n" "$breakdown" | grep -v '^MIN_COST=')"
  else
    min_cost="0.00"
  fi

  echo ""
  echo "=== RepoLens Confirmation ==="
  echo "Target repo:  $FORGE_REPO_SLUG"
  print_remote_confirmation_context
  echo "Mode:         $MODE"
  echo "Agent:        $AGENT"
  print_agent_override_map
  echo "Lenses:       $TOTAL_LENSES"
  if [[ -n "$MAX_ISSUES" ]]; then
    echo "Max issues:   $MAX_ISSUES"
  else
    echo "Max issues:   (unlimited)"
  fi
  echo ""
  if $FLAT_RATE; then
    print_flat_rate_cost "$pricing_file"
  else
    echo "Estimated cost: ~\$${min_cost}  (lens_count=${TOTAL_LENSES} x depth=${DONE_STREAK_REQUIRED} x rounds=${ROUNDS}, lower bound — real runs typically 2-5x higher)"
    printf "%s\n" "$breakdown_lines"
    echo "  Note: Estimator assumes one model per agent, 4 bytes/token, and a"
    echo "  capped per-session input budget. Tool-call churn and iteration"
    echo "  non-convergence push real cost higher. Budget accordingly."
  fi
  print_wall_estimate

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
  [[ "$AGENT" == "claude" || "$AGENT" == claude/* ]] || return 0

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
  print_agent_override_map
  echo "Project:      $PROJECT_PATH"
  echo "Rounds:      $ROUNDS"
  if [[ "$MODE" == "bugreport" ]]; then
    echo "Strategy:     $STRATEGY"
  fi
  echo "Human review: $HUMAN_REVIEW"
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
      check_pricing_freshness "$_dry_pricing_file"
      if $FLAT_RATE; then
        # Flat-rate: $0 marginal cost + request/quota consumption (issue #384).
        print_flat_rate_cost "$_dry_pricing_file"
        unset _dry_pricing_file
      else
        if overrides_active; then
          _dry_breakdown="$(compute_cost_breakdown_routed "$DONE_STREAK_REQUIRED" "$PROJECT_PATH" "$_dry_pricing_file" "$ROUNDS")"
        else
          _dry_breakdown="$(compute_cost_breakdown "$AGENT" "$TOTAL_LENSES" "$DONE_STREAK_REQUIRED" "$PROJECT_PATH" "$_dry_pricing_file" "$ROUNDS")"
        fi
        _dry_min_cost="$(printf "%s\n" "$_dry_breakdown" | awk -F= '/^MIN_COST=/ {print $2; exit}')"
        _dry_breakdown_lines="$(printf "%s\n" "$_dry_breakdown" | grep -v '^MIN_COST=')"
        echo "Estimated cost: ~\$${_dry_min_cost}  (lens_count=${TOTAL_LENSES} x depth=${DONE_STREAK_REQUIRED} x rounds=${ROUNDS}, lower bound — real runs typically 2-5x higher)"
        printf "%s\n" "$_dry_breakdown_lines"
        unset _dry_pricing_file _dry_breakdown _dry_min_cost _dry_breakdown_lines
      fi
    fi
    # The wall-clock estimate needs no pricing data, so emit it whenever lenses
    # are queued — even if config/agent-pricing.json is absent and the cost block
    # above was skipped. With the pricing file present (the baseline-capture case)
    # the line order is unchanged: cost block, then the estimate, then the blank.
    print_wall_estimate
    echo ""
  fi
  echo "Lenses that would run:"
  for lens_entry in "${LENS_LIST[@]}"; do
    echo "  $lens_entry"
  done
  echo ""
  echo "Dry run complete — no agents were executed."
  # Record this invocation before the dry-run exit (#371). --dry-run exits far
  # before the main finalize block, so without this call a dry-run would leave
  # no attempt entry. summary.json does not exist yet here, so why_stopped is
  # empty and status defaults to "finished". The dry-run path always exits 0, so
  # record exit_code 0 (#375). Non-fatal.
  attempts_finalize "$LOG_BASE" "${REPOLENS_FINAL_STATE:-finished}" "" 0 || true
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
if [[ -n "${REMOTE_TARGET:-}" ]]; then
  if run_remote_preflight; then
    remote_open_master || die "Remote ControlMaster failed for $REMOTE_TARGET"
  fi
fi
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
    greenfield)  label_prefix="greenfield" ;;
    polish)      label_prefix="polish" ;;
    spec-change) label_prefix="change" ;;
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

  # Ensure enhancement label for generative issue-creation modes.
  if [[ "$MODE" == "discover" || "$MODE" == "polish" ]]; then
    printf '%s=%s\n' "enhancement" "a2eeef" >> "$label_set_file"
  fi

  # Pre-create the task-complexity routing labels (#385) only for the audit and
  # bugreport modes that estimate implementation effort (1-5) — audit.md and
  # synthesize.md are the sole prompts that instruct the agent to apply the
  # `repolens/complexity/<n>` label. Idempotent: the agents only apply the
  # labels, which already exist. green -> red gradient (trivial -> complex).
  case "$MODE" in
    audit|bugreport)
      local -a complexity_colors=(c2e0c6 bfd4f2 fbca04 ff9800 d73a4a)
      local cx
      for cx in 1 2 3 4 5; do
        printf '%s=%s\n' "repolens/complexity/${cx}" "${complexity_colors[cx-1]}" >> "$label_set_file"
      done
      ;;
    *) ;;
  esac

  if [[ -n "$SPEC_FILE" ]]; then
    local spec_basename
    spec_basename="$(basename "$SPEC_FILE" | sed 's/\.[^.]*$//')"
    local spec_label="spec:${spec_basename}"
    printf '%s=%s\n' "$spec_label" "c9b1ff" >> "$label_set_file"
  fi

  forge_label_bootstrap "$FORGE_REPO_SLUG" "$label_set_file"
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

if [[ -n "$RESUME_RUN_ID" ]]; then
  # shellcheck disable=SC2034 # Consumed by write_status_snapshot in sourced lib/status.sh.
  REPOLENS_STATUS_ALLOW_RUNNING_OVER_TERMINAL=true
  start_status_updater "$RUN_ID" "$LOG_BASE" "$HEARTBEAT_DIR" "$completed_lenses_file" "$SUMMARY_FILE" "$PROJECT_PATH" "$FORGE_REPO_SLUG" "$MODE" "$AGENT" "$PARALLEL" "$MAX_PARALLEL" "${REMOTE_TARGET:-}" "${REMOTE_LABEL:-}"
  unset REPOLENS_STATUS_ALLOW_RUNNING_OVER_TERMINAL
else
  start_status_updater "$RUN_ID" "$LOG_BASE" "$HEARTBEAT_DIR" "$completed_lenses_file" "$SUMMARY_FILE" "$PROJECT_PATH" "$FORGE_REPO_SLUG" "$MODE" "$AGENT" "$PARALLEL" "$MAX_PARALLEL" "${REMOTE_TARGET:-}" "${REMOTE_LABEL:-}"
fi

# --- Run a single lens ---
run_lens() {
  local lens_tuple="$1"
  local lens_entry="" lens_role="" lens_focus="" prior_finding_anchor="" exclusion_hints=""

  if declare -F _rounds_meta_tuple_parse >/dev/null 2>&1; then
    _rounds_meta_tuple_parse "$lens_tuple" lens_entry lens_role lens_focus prior_finding_anchor exclusion_hints
  else
    lens_entry="${lens_tuple%%|*}"
  fi
  [[ -n "$lens_entry" ]] || lens_entry="$lens_tuple"

  local domain="${lens_entry%%/*}"
  local lens_id="${lens_entry#*/}"
  local lens_file="$LENSES_DIR/$domain/$lens_id.md"
  local base_file="$BASE_WRAPPER_FILE"

  if [[ "$domain" == "custom" \
      && -n "${CURRENT_ROUND_CUSTOM_LENSES_DIR:-}" \
      && -f "${CURRENT_ROUND_CUSTOM_LENSES_DIR}/$domain/$lens_id.md" ]]; then
    lens_file="${CURRENT_ROUND_CUSTOM_LENSES_DIR}/$domain/$lens_id.md"
  fi

  if [[ "$domain" == "generic" ]]; then
    base_file="$BASE_PROMPTS_DIR/investigator.md"
    if [[ ! -f "$lens_file" ]]; then
      lens_file="$base_file"
    fi
  fi

  # Check resume
  if is_lens_completed "$lens_entry"; then
    log_info "[$domain/$lens_id] Skipping (already completed in previous run)"
    return 0
  fi

  # Issue #380: resolve the effective agent for this lens (domain/lens > domain >
  # global --agent) and its per-agent timeout. Different agents can carry
  # different REPOLENS_AGENT_TIMEOUT_* budgets, so resolve the timeout for the
  # agent that will actually run rather than reusing the global default.
  local effective_agent effective_agent_timeout_secs
  effective_agent="$(resolve_effective_agent "$domain" "$lens_id")"
  effective_agent_timeout_secs="$(resolve_agent_timeout "$MODE" "$effective_agent")"
  if [[ ! "$effective_agent_timeout_secs" =~ ^[1-9][0-9]*$ ]]; then
    effective_agent_timeout_secs="$AGENT_TIMEOUT_SECS"
  fi
  effective_agent_timeout_secs=$((10#$effective_agent_timeout_secs))
  if [[ "$effective_agent" != "$AGENT" ]]; then
    log_info "[$domain/$lens_id] Routed to agent '$effective_agent' via --agent-override (global: $AGENT)"
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
    greenfield)  label_prefix="greenfield" ;;
    polish)      label_prefix="polish" ;;
    spec-change) label_prefix="change" ;;
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
  vars+="|LENS_ROLE=$(template_var_escape "$lens_role")"
  vars+="|LENS_FOCUS=$(template_var_escape "$lens_focus")"
  vars+="|PRIOR_FINDING_ANCHOR=$(template_var_escape "$prior_finding_anchor")"
  vars+="|EXCLUSION_HINTS=$(template_var_escape "$exclusion_hints")"
  if [[ -n "${PRIOR_ROUND_DIGEST_FILE:-}" ]]; then
    vars+="|PRIOR_ROUND_DIGEST=@${PRIOR_ROUND_DIGEST_FILE}"
  fi
  if [[ -n "${HYPOTHESES_TO_VERIFY_FILE:-}" ]]; then
    vars+="|HYPOTHESES_TO_VERIFY=@${HYPOTHESES_TO_VERIFY_FILE}"
  fi
  if [[ "$MODE" == "polish" ]]; then
    vars+="|POLISH_SUGGESTIONS_FILE=$(template_var_escape "$LOG_BASE/polish/suggestions/${domain}--${lens_id}.json")"
    if [[ -f "${POLISH_VOICE_PROFILE_FILE:-}" ]]; then
      vars+="|VOICE_PROFILE=@${POLISH_VOICE_PROFILE_FILE}"
    else
      vars+="|VOICE_PROFILE=No polish voice profile was generated; use direct repository evidence only."
    fi
  fi
  [[ -n "$CHANGE_STATEMENT" ]] && vars+="|CHANGE_STATEMENT=${CHANGE_STATEMENT}"
  if [[ "$MODE" == "spec-change" && -f "$SPEC_DIFF_FILE" ]]; then
    vars+="|SPEC_DIFF=@${SPEC_DIFF_FILE}"
  fi
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
  local prompt="" lens_local_dir=""
  if $LOCAL_MODE; then
    lens_local_dir="${CURRENT_ROUND_OUTPUT_DIR:-$OUTPUT_DIR}/$domain/$lens_id"
    mkdir -p "$lens_local_dir"
    if [[ "$MODE" != "greenfield" ]]; then
      prompt="$(compose_prompt "$base_file" "$lens_file" "$vars" "$SPEC_FILE" "$MODE" "$MAX_ISSUES" "$SOURCE_FILE" "$HOSTED" "true" "$lens_local_dir")"
    fi
  else
    if [[ "$MODE" != "greenfield" ]]; then
      prompt="$(compose_prompt "$base_file" "$lens_file" "$vars" "$SPEC_FILE" "$MODE" "$MAX_ISSUES" "$SOURCE_FILE" "$HOSTED")"
    fi
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
    if _baseline_out="$(forge_issue_list_count "$FORGE_REPO_SLUG" "$lens_label")"; then
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
  local no_progress_count=0
  local lens_start_epoch lens_start_iso
  lens_start_epoch="$(date +%s)"
  lens_start_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

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
    local envelope_file="$output_file.envelope.json"
    local output_envelope_file
    output_envelope_file="$LOG_BASE/output/$domain/$lens_id/$(basename "$output_file").envelope.json"

    log_info "[$domain/$lens_id] Iteration $iteration"
    if (( heartbeat_interval > 0 )); then
      write_lens_heartbeat_iteration "$heartbeat_iteration_file" "$iteration" || true
      write_lens_heartbeat "$heartbeat_file" "$RUN_ID" "$domain" "$lens_id" "$heartbeat_owner_pid" "$iteration" "$heartbeat_started_at" || true
    fi

    local agent_rc=0
    local effective_timeout_secs="$effective_agent_timeout_secs"
    if (( remaining_wall_secs < effective_timeout_secs )); then
      effective_timeout_secs="$remaining_wall_secs"
    fi

    if [[ "$MODE" == "greenfield" ]]; then
      local current_backlog_file iteration_vars
      current_backlog_file="$lens_log_dir/current-backlog-${iteration}.md"
      greenfield_write_current_backlog_snapshot "$current_backlog_file" "$lens_local_dir" "$FORGE_REPO_SLUG" || true
      iteration_vars="${vars}|CURRENT_BACKLOG=@${current_backlog_file}"
      if $LOCAL_MODE; then
        prompt="$(compose_prompt "$base_file" "$lens_file" "$iteration_vars" "$SPEC_FILE" "$MODE" "$MAX_ISSUES" "$SOURCE_FILE" "$HOSTED" "true" "$lens_local_dir")"
      else
        prompt="$(compose_prompt "$base_file" "$lens_file" "$iteration_vars" "$SPEC_FILE" "$MODE" "$MAX_ISSUES" "$SOURCE_FILE" "$HOSTED")"
      fi
    fi

    run_agent "$effective_agent" "$prompt" "$PROJECT_PATH" "$effective_timeout_secs" "$AGENT_KILL_GRACE_SECS" "$envelope_file" >"$output_file" 2>&1 || agent_rc=$?
    if [[ -s "$envelope_file" && "$output_envelope_file" != "$envelope_file" ]]; then
      mkdir -p "$(dirname "$output_envelope_file")" 2>/dev/null || true
      cp "$envelope_file" "$output_envelope_file" 2>/dev/null || true
    fi
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
    # Text fallback stays gated on agent_rc != 0 (issue #128), but Claude JSON
    # envelopes can classify structured failures even when the CLI exits 0.
    local failure_class rl_hit rl_sig rl_snip
    failure_class="$(classify_agent_iteration "$output_file" "$agent_rc" "$envelope_file" || printf '%s' "unknown")"
    if [[ "$failure_class" != "unknown" ]]; then
      case "$failure_class" in
        auth-expired|model-unavailable|budget-exhausted|agent-refused|max-tokens-truncation|agent-error)
          log_error "[$domain/$lens_id] Persistent agent failure: $failure_class. Aborting run."
          printf '%s\n' "$failure_class" > "$LOG_BASE/.systemic-failure-abort"
          exit_status="$failure_class"
          break
          ;;
        rate-limited)
          rl_hit="$(detect_agent_rate_limit "$output_file" || true)"
          if [[ -z "$rl_hit" ]]; then
            rl_hit="structured-envelope|Claude JSON envelope reported rate limit"
          fi
          ;;
        *)
          rl_hit=""
          ;;
      esac

      if [[ -n "$rl_hit" ]]; then
        rl_sig="${rl_hit%%|*}"
        rl_snip="${rl_hit#*|}"

        local rl_resume_epoch="" rl_abort_resume_epoch="" rl_now_epoch="" wait_delta sleep_seconds resume_label
        rl_resume_epoch="$(parse_rate_limit_resume_epoch "$output_file" || true)"
        if [[ "$rl_resume_epoch" =~ ^[0-9]+$ ]]; then
          rl_now_epoch="$(date +%s)"
          if [[ "$rl_resume_epoch" -lt $((rl_now_epoch - 60)) ]]; then
            rl_resume_epoch=""
          else
            rl_abort_resume_epoch="$rl_resume_epoch"
            wait_delta=$((rl_resume_epoch - rl_now_epoch))
            if [[ "$wait_delta" -lt 0 ]]; then
              wait_delta=0
            fi

            if ! $rate_limit_retry_attempted && (( wait_delta <= RATE_LIMIT_MAX_SLEEP_SECS )); then
              sleep_seconds=$((wait_delta + 60))
              resume_label="$(date -u -d "@$rl_resume_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '%s' "$rl_resume_epoch")"
              log_warn "[$domain/$lens_id] Agent rate-limited. Resume at $resume_label (${sleep_seconds}s from now). Sleeping."
              rate_limit_retry_attempted=true
              rate_limit_sleep_seconds=$((rate_limit_sleep_seconds + sleep_seconds))
              local sleep_rc sleep_signal sleep_stopped_reason
              if env --help 2>&1 | grep -q -- '--default-signal'; then
                env --default-signal=INT sleep "$sleep_seconds"
                sleep_rc=$?
              else
                sleep "$sleep_seconds"
                sleep_rc=$?
              fi

              if (( sleep_rc != 0 )); then
                log_warn "[$domain/$lens_id] Rate-limit sleep interrupted."
                write_rate_limit_abort_marker "$rl_abort_resume_epoch"
                if sleep_stopped_reason="$(rate_limit_sleep_stopped_reason "$sleep_rc" 2>/dev/null)"; then
                  sleep_signal="$(rate_limit_sleep_signal_name "$sleep_rc" 2>/dev/null || printf '%s\n' "UNKNOWN")"
                  write_rate_limit_sleep_interrupt_marker "$sleep_rc" "$sleep_signal" "$sleep_stopped_reason"
                  # In sequential mode run_lens executes inline in the main
                  # process, so this exit terminates the run before the finalize
                  # block — print the resume hint here. In parallel mode this is
                  # a worker subshell; the main process prints it at the finalize
                  # `interrupted` branch (via the sleep-interrupt marker), so
                  # gating on sequential mode avoids a duplicate line.
                  $PARALLEL || print_resume_hint
                  exit "$sleep_rc"
                fi

                log_warn "[$domain/$lens_id] Rate-limit sleep failed with exit $sleep_rc; leaving run pending for resume."
                exit_status="rate-limited"
                break
              fi
              continue
            fi
          fi
        fi

        log_error "[$domain/$lens_id] Agent rate-limited / quota exceeded. Aborting run. Matched: $rl_sig. Snippet: $rl_snip"
        write_rate_limit_abort_marker "$rl_abort_resume_epoch"
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
      if ! current_issue_count="$(forge_issue_list_count "$FORGE_REPO_SLUG" "$lens_label")"; then
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

    local done_detected=false
    if [[ "$agent_rc" -eq 0 ]] && check_done "$output_file"; then
      done_detected=true
    fi

    local output_bytes output_issue_urls degraded_iteration
    output_bytes="$(wc -c < "$output_file" | tr -d '[:space:]')"
    [[ "$output_bytes" =~ ^[0-9]+$ ]] || output_bytes=0
    output_issue_urls="$(count_issues_in_output "$output_file")"
    [[ "$output_issue_urls" =~ ^[0-9]+$ ]] || output_issue_urls=0

    degraded_iteration=false
    if [[ "$agent_rc" -ne 0 ]] || (( output_bytes < REPOLENS_NO_PROGRESS_MIN_BYTES )); then
      degraded_iteration=true
    fi

    if $degraded_iteration \
        && ! $done_detected \
        && (( output_issue_urls == 0 )) \
        && (( iter_issues == 0 )); then
      no_progress_count=$((no_progress_count + 1))
      log_warn "[$domain/$lens_id] No-progress iteration $no_progress_count/$REPOLENS_NO_PROGRESS_LIMIT (agent_rc=$agent_rc, output_bytes=$output_bytes)"
      if (( no_progress_count >= REPOLENS_NO_PROGRESS_LIMIT )); then
        log_warn "[$domain/$lens_id] No-progress circuit breaker tripped after $no_progress_count consecutive degraded iterations"
        : > "$LOG_BASE/.agent-no-progress-abort"
        exit_status="agent-no-progress"
        break
      fi
    else
      if (( no_progress_count > 0 )); then
        log_info "[$domain/$lens_id] No-progress streak reset."
      fi
      no_progress_count=0
    fi

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
    if $done_detected; then
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

  # Record result. Terminal agent guard lenses are recorded but NOT marked completed,
  # so --resume will re-run them on the next invocation.
  # Capture end-of-lens timing for summary.json analysis. duration is wall-clock
  # for the whole lens loop (including any rate-limit sleeps); clamp negatives in
  # case the clock stepped backward (NTP) mid-lens, mirroring the lens_issues clamp.
  local lens_end_epoch lens_end_iso lens_duration_seconds
  lens_end_epoch="$(date +%s)"
  lens_end_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  lens_duration_seconds=$((lens_end_epoch - lens_start_epoch))
  (( lens_duration_seconds < 0 )) && lens_duration_seconds=0
  record_lens "$SUMMARY_FILE" "$domain" "$lens_id" "$iteration" "$exit_status" "$lens_issues" "$rate_limit_sleep_seconds" \
    "$lens_start_iso" "$lens_end_iso" "$lens_duration_seconds"
  if [[ "$exit_status" != "rate-limited" && "$exit_status" != "agent-no-progress" \
      && "$exit_status" != "auth-expired" && "$exit_status" != "model-unavailable" \
      && "$exit_status" != "budget-exhausted" && "$exit_status" != "agent-refused" \
      && "$exit_status" != "max-tokens-truncation" && "$exit_status" != "agent-error" ]]; then
    mark_lens_completed "$lens_entry"
  fi

  # Compress this lens's forensic iteration captures, keeping the most recent
  # few uncompressed. Forensic-only — synth/verify/--resume read lens-outputs/,
  # not iteration-*.txt — so this is safe and non-fatal.
  compress_lens_iterations "$lens_log_dir" "${REPOLENS_ITERATION_KEEP:-3}"

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

# --- Phase execution state ---
RUN_ROUNDS_RC=0

# --- Triage (pre-rounds, round-0 context pack) ---
# Single-shot agent that produces logs/<run-id>/triage/context-pack.md so every
# round-1 lens shares a compact briefing of suspect commits, linked-issue
# summaries, recent author activity, and an initial hypothesis tree. Failure is
# non-fatal: round-1 lenses fall back to doing their own initial history scan.
if [[ "$MODE" == "bugreport" && "${NO_TRIAGE:-true}" != "true" ]]; then
  log_info "Triage: building round-0 context pack"
  if run_triage "$RUN_ID"; then
    log_info "Triage: context-pack.md promoted ($TRIAGE_CONTEXT_PACK_FILE)"
  elif [[ -f "$LOG_BASE/.rate-limit-abort" ]]; then
    log_warn "Triage: rate-limited — aborting before lens rounds"
    RUN_ROUNDS_RC=1
  else
    log_warn "Triage: failed — proceeding with empty context pack"
  fi
fi

# Issue #227: re-prune LENS_LIST against the relevant-domains whitelist that
# triage just produced. resolve_lenses already consults the file (used by the
# resume path), but on a fresh run LENS_LIST was computed before triage. Only
# applies when the catch-all branch was taken — explicit --focus / --domain
# user overrides bypass the whitelist entirely.
if [[ "$MODE" == "bugreport" && -z "$FOCUS" && -z "$DOMAIN_FILTER" \
      && -s "$LOG_BASE/triage/relevant-domains.txt" ]]; then
  declare -A _RELEVANT_DOMAINS_KEEP=()
  while IFS= read -r _relevant_domain_id; do
    [[ -z "$_relevant_domain_id" ]] && continue
    _RELEVANT_DOMAINS_KEEP["$_relevant_domain_id"]=1
  done < "$LOG_BASE/triage/relevant-domains.txt"

  if (( ${#_RELEVANT_DOMAINS_KEEP[@]} > 0 )); then
    _PRUNED_LENS_LIST=()
    for _lens_entry in "${LENS_LIST[@]}"; do
      _lens_entry_domain="${_lens_entry%%/*}"
      if [[ -n "${_RELEVANT_DOMAINS_KEEP[$_lens_entry_domain]:-}" ]]; then
        _PRUNED_LENS_LIST+=("$_lens_entry")
      fi
    done
    if (( ${#_PRUNED_LENS_LIST[@]} > 0 )); then
      _ORIGINAL_LENS_COUNT="${#LENS_LIST[@]}"
      LENS_LIST=("${_PRUNED_LENS_LIST[@]}")
      TOTAL_LENSES=${#LENS_LIST[@]}
      log_info "Triage relevant-domains filter: pruned $((_ORIGINAL_LENS_COUNT - TOTAL_LENSES))/$_ORIGINAL_LENS_COUNT lenses, kept $TOTAL_LENSES"
    fi
  fi
  unset _RELEVANT_DOMAINS_KEEP _PRUNED_LENS_LIST _lens_entry _lens_entry_domain _relevant_domain_id _ORIGINAL_LENS_COUNT
fi

# --- Polish voice profile (pre-round, shared by every polish lens) ---
if [[ "$RUN_ROUNDS_RC" -eq 0 && "$MODE" == "polish" ]] && (( TOTAL_LENSES > 0 )); then
  if run_polish_voice_profile_prepass "$RUN_ID"; then
    log_info "Polish voice profile: ready ($POLISH_VOICE_PROFILE_FILE)"
  elif [[ -f "$LOG_BASE/.rate-limit-abort" ]]; then
    log_warn "Polish voice profile: rate-limited - aborting before lens rounds"
    RUN_ROUNDS_RC=1
  else
    die "Polish voice profile pre-pass failed"
  fi
fi

# --- Execute lenses ---
if [[ "$RUN_ROUNDS_RC" -eq 0 ]]; then
  run_rounds "$ROUNDS" LENS_LIST
  RUN_ROUNDS_RC=$?
fi

# --- Polish ranking (post-rounds, pre-verifier) ---
if [[ "$RUN_ROUNDS_RC" -eq 0 && "$MODE" == "polish" ]]; then
  log_info "Polish ranking: ordering surfaced suggestions"
  if run_polish_ranking "$RUN_ID"; then
    log_info "Polish ranking: ranked-suggestions.json promoted"
    log_info "Polish issue emission: filing ranked lens shortlists"
    if run_polish_issue_emission "$RUN_ID" "${REPOLENS_POLISH_TOP_N:-3}"; then
      log_info "Polish issue emission: ranked lens shortlists processed"
    else
      die "Polish issue emission failed"
    fi
  else
    die "Polish ranking failed"
  fi
fi

# --- Verifier (post-rounds, pre-synthesizer) ---
# Re-reads every finding's cited code locations and emits
# logs/<run-id>/final/verification.json so the synthesizer can skip WRONG
# findings and downrank STALE ones. Verifier failures are non-fatal: a missing
# verification.json simply means the synthesizer proceeds without filtering.
if [[ "$RUN_ROUNDS_RC" -eq 0 && "${NO_VERIFIER:-true}" != "true" ]]; then
  log_info "Verifier: re-reading cited code locations for evidence accuracy"
  if run_verifier "$RUN_ID"; then
    log_info "Verifier: verification.json promoted"
  elif [[ -f "$LOG_BASE/.rate-limit-abort" ]]; then
    log_warn "Verifier: rate-limited — aborting before synthesis"
    RUN_ROUNDS_RC=1
  else
    log_warn "Verifier: failed — synthesizer will proceed without verification filtering"
  fi
fi

# --- Synthesizer (post-rounds, post-verifier) ---
# Multi-round runs finish by consolidating round findings into a schema-checked
# manifest under logs/<run-id>/final/manifest.json. Single-round runs keep the
# legacy direct-filing/local-output behavior.
if [[ "$RUN_ROUNDS_RC" -eq 0 && "$MODE" == "bugreport" && "${ROUNDS:-1}" -gt 1 ]]; then
  log_info "Synthesizer: consolidating multi-round findings"
  if run_synthesizer "$RUN_ID"; then
    log_info "Synthesizer: manifest.json promoted"
    if ! $LOCAL_MODE; then
      log_info "Filing: dispatching synthesized manifest"
      filing_output=""
      if filing_output="$(dispatch_filing_batch "$RUN_ID" 2>&1)"; then
        while IFS= read -r filing_line; do
          [[ -n "$filing_line" ]] && log_info "Filing: $filing_line"
        done <<< "$filing_output"

        filing_missing=0
        filing_failed=0
        filing_dedup=0
        manifest_path="$LOG_BASE/final/manifest.json"
        filed_dir="$LOG_BASE/final/filed"
        while IFS= read -r filing_cluster_id; do
          [[ -n "$filing_cluster_id" ]] || continue
          if [[ -e "$filed_dir/$filing_cluster_id.url" ]]; then
            continue
          fi
          if [[ -e "$filed_dir/$filing_cluster_id.failed" ]]; then
            filing_failed_first_line="$(head -n 1 "$filed_dir/$filing_cluster_id.failed" 2>/dev/null || true)"
            if [[ "$filing_failed_first_line" == DEDUP_HIT:* ]]; then
              filing_dedup=$((filing_dedup + 1))
            else
              filing_failed=$((filing_failed + 1))
            fi
          else
            filing_missing=$((filing_missing + 1))
          fi
        done < <(jq -r '.[].cluster_id' "$manifest_path")

        if (( filing_failed > 0 || filing_missing > 0 )); then
          log_warn "Filing: incomplete batch (failed=$filing_failed, dedup=$filing_dedup, missing=$filing_missing)"
          REPOLENS_FINAL_STATE="failed"
          set_stop_reason "$SUMMARY_FILE" "filing-failed"
          RUN_ROUNDS_RC=1
        else
          log_info "Filing: batch complete"
        fi
      else
        while IFS= read -r filing_line; do
          [[ -n "$filing_line" ]] && log_warn "Filing: $filing_line"
        done <<< "$filing_output"
        log_warn "Filing: failed to dispatch synthesized manifest"
        REPOLENS_FINAL_STATE="failed"
        set_stop_reason "$SUMMARY_FILE" "filing-failed"
        RUN_ROUNDS_RC=1
      fi
    fi
  else
    synth_rc=$?
    case "$synth_rc" in
      3)
        log_warn "Synthesizer: stopped due to rate limit"
        ;;
      4)
        log_warn "Synthesizer: agent output did not contain a JSON array; see final/synthesizer-output.txt"
        ;;
      5)
        log_warn "Synthesizer: manifest validation failed"
        ;;
      6)
        log_warn "Synthesizer: agent invocation failed; see final/synthesizer-output.txt"
        ;;
      *)
        log_warn "Synthesizer: failed to produce a valid manifest"
        ;;
    esac
    if [[ "$synth_rc" -ne 3 ]]; then
      REPOLENS_FINAL_STATE="failed"
      set_stop_reason "$SUMMARY_FILE" "synthesizer-failed"
    fi
    RUN_ROUNDS_RC=1
  fi
fi

# --- Finalize ---
# Emit deduped forge-warning rollup so the operator still sees the suppressed
# total (issue #246). Parallel workers carry their own _FORGE_WARN_SEEN map and
# their counts don't cross fork boundaries — what we report here is what the
# parent process accumulated (baseline calls plus anything that ran serially).
if declare -p _FORGE_WARN_SEEN >/dev/null 2>&1 && (( ${#_FORGE_WARN_SEEN[@]} > 0 )); then
  log_info "Forge warning rollup (deduped):"
  while IFS= read -r _rollup_key; do
    log_info "  ${_rollup_key} — ${_FORGE_WARN_SEEN[$_rollup_key]} times"
  done < <(printf '%s\n' "${!_FORGE_WARN_SEEN[@]}" | LC_ALL=C sort)
  unset _rollup_key
fi

# --- Finding registry (non-fatal) ---
# Produce the canonical finding index (final/findings.jsonl + findings.csv) from
# the synthesized manifest so the human-review digest and triage artifacts below
# have a registry to render. Non-local path only — --local invokes the builder
# separately (sibling issue). Non-fatal, mirroring the verifier/synthesizer/
# triage precedent: the registry is a convenience index, not a gate, so a failure
# warns and never flips the run's final state or return code.
if ! $LOCAL_MODE && [[ -f "$LOG_BASE/final/manifest.json" ]]; then
  if build_finding_registry "$RUN_ID"; then
    log_info "Finding registry: findings.jsonl + findings.csv written"
  else
    log_warn "Finding registry: build failed (findings index not produced)"
  fi
fi

finalize_summary "$SUMMARY_FILE"

# --- Local-mode deterministic dedupe (non-fatal) ---
# In --local mode the NNN-<slug>.md tree under $OUTPUT_DIR is the deliverable.
# Reconcile cross-lens/cross-domain duplicate findings into canonical + duplicate
# using the SAME match + canonical-selection helpers as the manifest path,
# marking files IN PLACE (never deleting). Deterministic, idempotent, model-free.
# Non-fatal, mirroring the verifier / synthesizer / triage precedent: a failure
# warns and NEVER touches REPOLENS_FINAL_STATE or RUN_ROUNDS_RC.
if $LOCAL_MODE && [[ -n "$OUTPUT_DIR" && -d "$OUTPUT_DIR" ]]; then
  if dedupe_local_markdown "$OUTPUT_DIR"; then
    log_info "Local dedupe: reconciled duplicate markdown findings under $OUTPUT_DIR"
  else
    log_warn "Local dedupe: failed (findings left un-deduped)"
  fi
fi

# --- Human review digest (non-fatal) ---
# When --human-review is set and the finding registry exists, render the curated
# final/HUMAN_REVIEW.md from the bucketed findings. Non-fatal, matching the
# verifier precedent: a render failure logs a warning and NEVER touches
# REPOLENS_FINAL_STATE or RUN_ROUNDS_RC. No HUMAN_REVIEW.md is written when the
# flag is off or no findings.jsonl exists.
if [[ "${HUMAN_REVIEW:-false}" == "true" && -f "$LOG_BASE/final/findings.jsonl" ]]; then
  if render_human_review_digest "$RUN_ID"; then
    log_info "Human review: HUMAN_REVIEW.md written"
  else
    log_warn "Human review: failed to render HUMAN_REVIEW.md"
  fi
  # No silent truncation: one structured line reconciling the curated digest
  # against the full registry (total / surfaced / held-back per bucket). The
  # helper is pure (returns the string); log_info owns the emission so the
  # log_*-under-set -u trap stays out of the library. Gated by the same block,
  # so it only fires when --human-review is active. Non-fatal.
  log_info "$(human_review_heldback_summary "$RUN_ID")"
fi

# --- Human-triage artifacts (non-fatal) ---
# Render the four post-run triage Markdown files (TODO / SUMMARY / NEEDS_REVIEW /
# DUPLICATES) from the finding registry into final/. Clean no-op when the registry
# is absent or empty (dry-run, single-round, or any run where the ledger did not
# produce findings.jsonl): one info line, zero files written. Gating on `-s`
# (exists AND non-empty) — not on generator return codes — keeps a present-but-empty
# registry from leaking four placeholder files. Each generator failure is non-fatal
# (warn + continue), matching the verifier/synthesizer/human-review precedent; none
# of these touch REPOLENS_FINAL_STATE or RUN_ROUNDS_RC.
TRIAGE_FINDINGS="$LOG_BASE/final/findings.jsonl"
if [[ -s "$TRIAGE_FINDINGS" ]]; then
  for _triage_spec in \
    "generate_todo_md:TODO.md" \
    "generate_summary_md:SUMMARY.md" \
    "generate_needs_review_md:NEEDS_REVIEW.md" \
    "generate_duplicates_md:DUPLICATES.md"; do
    _triage_fn="${_triage_spec%%:*}"
    _triage_out="$LOG_BASE/final/${_triage_spec##*:}"
    if "$_triage_fn" "$TRIAGE_FINDINGS" "$_triage_out"; then
      log_info "Triage artifact: $_triage_out"
    else
      log_warn "Triage artifact: failed to render $_triage_out ($_triage_fn, rc $?)"
    fi
  done
  unset _triage_spec _triage_fn _triage_out
else
  log_info "Triage artifacts: no finding registry at $TRIAGE_FINDINGS; skipping"
fi

# --- Local-mode finding registry (non-fatal) ---
# --local bypasses the synthesizer/manifest path, so the non-local registry hook
# above ( ! $LOCAL_MODE) never fires. Build the canonical index directly from the
# NNN-<slug>.md tree under $OUTPUT_DIR. The orchestrator writes only into
# logs/<run-id>/final/ (resolved from LOG_BASE, NOT $OUTPUT_DIR), so the user's
# output dir stays pure md. Placed after the triage block so triage/human-review
# stay non-local-only (strict issue scope): the local change produces ONLY
# findings.jsonl + findings.csv. Non-fatal, mirroring the verifier/synthesizer/
# triage precedent: a failure warns and NEVER flips REPOLENS_FINAL_STATE or
# RUN_ROUNDS_RC.
if $LOCAL_MODE && [[ -n "$OUTPUT_DIR" && -d "$OUTPUT_DIR" ]]; then
  if build_finding_registry "$RUN_ID" "$OUTPUT_DIR"; then
    log_info "Finding registry: findings.jsonl + findings.csv written -> $LOG_BASE/final/ (index for $OUTPUT_DIR)"
  else
    log_warn "Finding registry: build failed (findings index not produced)"
  fi
fi

apply_rate_limit_abort_final_state || true
set_summary_health "$SUMMARY_FILE" "$REPOLENS_DEGENERATE_THRESHOLD"
RUN_HEALTH="$(jq -r '.health // "ok"' "$SUMMARY_FILE" 2>/dev/null || printf 'ok')"

case "$RUN_HEALTH" in
  broken)
    if [[ "${REPOLENS_FINAL_STATE:-finished}" == "finished" ]]; then
      REPOLENS_FINAL_STATE="failed"
    fi
    read -r HEALTH_MAX_ITERATIONS HEALTH_RUN_LENSES HEALTH_ISSUES < <(
      jq -r '
        (.lenses // [] | map(select(.status != "skipped"))) as $run_lenses
        | [
            ($run_lenses | map(select(.status == "max-iterations")) | length),
            ($run_lenses | length),
            (.totals.issues_created // 0)
          ]
        | @tsv
      ' "$SUMMARY_FILE" 2>/dev/null || printf '0\t0\t0\n'
    )
    log_error "Run health: BROKEN - ${HEALTH_MAX_ITERATIONS:-0}/${HEALTH_RUN_LENSES:-0} run lenses reached max-iterations with ${HEALTH_ISSUES:-0} findings"
    ;;
  no-findings|empty)
    if [[ "${REPOLENS_FINAL_STATE:-finished}" == "finished" ]]; then
      REPOLENS_FINAL_STATE="finished-empty"
    fi
    ;;
esac

# Resolve the process exit code ONCE, up front, from the now-final run state
# (REPOLENS_FINAL_STATE / RUN_HEALTH / RUN_ROUNDS_RC). The exit-code ladder below
# routes through this same value so the code recorded in attempts.json can never
# drift from the real process exit (#375).
RUN_EXIT_CODE="$(resolve_run_exit_code)"

# Record this invocation in the per-attempt audit trail (#371), enriched for
# triage (#375), now that REPOLENS_FINAL_STATE / RUN_HEALTH are resolved and
# summary.json exists. why_stopped prefers summary.json's stopped_reason and
# falls back to the present abort sentinel; exit_code is the resolved code above.
# Non-fatal: a write failure logs a warning and never changes the exit code.
attempts_finalize \
  "$LOG_BASE" \
  "${REPOLENS_FINAL_STATE:-finished}" \
  "$(resolve_why_stopped)" \
  "$RUN_EXIT_CODE" || true

# Emit the canonical latest-result pointer at the top of the logs tree (#308).
# Non-fatal: a pointer-write failure logs a warning and never changes exit code.
write_latest_result_pointer \
  "$SCRIPT_DIR/logs" \
  "$RUN_ID" \
  "$MODE" \
  "$AGENT" \
  "$SUMMARY_FILE" \
  "${REPOLENS_FINAL_STATE:-finished}" \
  "$LOG_BASE/final" || true

log_info "=============================="
log_info "RepoLens run $RUN_ID complete"
log_info "Summary: $SUMMARY_FILE"
log_info "=============================="

FINAL_FINDINGS_FILTERED="$(jq -r '.totals.findings_filtered // 0' "$SUMMARY_FILE" 2>/dev/null || printf '0')"
if [[ "$FINAL_FINDINGS_FILTERED" =~ ^[0-9]+$ ]] && (( 10#$FINAL_FINDINGS_FILTERED > 0 )); then
  echo "Findings filtered by --min-severity: $FINAL_FINDINGS_FILTERED"
fi

# Print time breakdown (no-op on older summaries without duration data).
echo ""
summary_time_breakdown "$SUMMARY_FILE" 10

# Local-mode end-of-run output pointers: the md deliverable plus, when produced,
# the machine-readable finding index (findings.jsonl + findings.csv under final/).
if $LOCAL_MODE; then
  echo ""
  echo "Output:       local markdown ($OUTPUT_DIR)"
  if [[ -f "$LOG_BASE/final/findings.jsonl" ]]; then
    echo "Finding index: $LOG_BASE/final/findings.jsonl (+ findings.csv)"
  fi
fi

# Print summary to stdout
echo ""
echo "=== RepoLens Run Summary ==="
jq '.' "$SUMMARY_FILE"

# Surface the parent-run + attempts model (#377): when this run dir represents
# one parent that took more than one attempt (a fresh start plus one or more
# --resume invocations), print a single legible note pointing at the full
# continuation history. attempts_finalize (above) has already appended the
# current attempt, so the count includes it. Single-attempt runs print nothing.
# Non-fatal: jq-guarded and tolerant of an absent/corrupt attempts.json.
if command -v jq >/dev/null 2>&1 && [[ -f "$LOG_BASE/attempts.json" ]]; then
  _attempts_n="$(jq -r 'if type == "array" then length else 0 end' "$LOG_BASE/attempts.json" 2>/dev/null || printf '0')"
  [[ "$_attempts_n" =~ ^[0-9]+$ ]] || _attempts_n=0
  if (( _attempts_n > 1 )); then
    _attempts_latest="$(jq -r 'if type == "array" then (last.status // "") else "" end' "$LOG_BASE/attempts.json" 2>/dev/null || printf '')"
    echo "This run took ${_attempts_n} attempts (latest: ${_attempts_latest}). Full continuation history: logs/${RUN_ID}/attempts.json"
  fi
  unset _attempts_n _attempts_latest
fi

# Exit-code ladder. The numeric code comes from RUN_EXIT_CODE (resolved above by
# resolve_run_exit_code) so it can never drift from the attempts.json record;
# each branch below only decides WHICH side effects (resume hints) to emit. Keep
# the branch order identical to resolve_run_exit_code.
if [[ "${REPOLENS_FINAL_STATE:-finished}" == "interrupted" ]]; then
  print_resume_hint
  exit "$RUN_EXIT_CODE"
fi

if [[ -f "$LOG_BASE/.rate-limit-abort" ]]; then
  # Both the phase rate-limit (exit 1) and rate-limit-pending (exit 3) outcomes
  # are resumable; RUN_EXIT_CODE already carries the right one.
  print_resume_hint
  exit "$RUN_EXIT_CODE"
fi

if [[ -f "$LOG_BASE/.agent-no-progress-abort" || -f "$LOG_BASE/.systemic-failure-abort" ]]; then
  print_resume_hint
  exit "$RUN_EXIT_CODE"
fi

if [[ "$RUN_ROUNDS_RC" -ne 0 ]]; then
  exit "$RUN_EXIT_CODE"
fi

if [[ "$RUN_HEALTH" == "broken" && "${REPOLENS_ALLOW_DEGENERATE:-false}" != "true" ]]; then
  exit "$RUN_EXIT_CODE"
fi
