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

# repolens-r5-p1-1: one receipt per distinct investigation, even for one lens.
# shellcheck disable=SC2034,SC2329 # Extracted production functions consume globals.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$(mktemp -d)" || exit 1
trap 'rm -rf -- "$FIXTURE"' EXIT
# shellcheck source=/dev/null
source "$REPO/lib/template.sh"
# shellcheck source=/dev/null
source "$REPO/lib/rounds.sh"
# shellcheck source=/dev/null
source "$REPO/lib/summary.sh"
# Exercise the live CLI callback and receipt functions without CLI preflight.
for function_name in run_lens is_lens_completed mark_lens_completed template_var_escape; do
  eval "$(sed -n "/^${function_name}() {/,/^}/p" "$REPO/repolens.sh")"
done
LOCAL_MODE=true MODE=audit AGENT=codex PARALLEL=false
RUN_ID=probe RESUME_RUN_ID=probe
LENSES_DIR="$REPO/prompts/lenses" BASE_WRAPPER_FILE="$REPO/prompts/_base/audit.md"
DOMAINS_FILE="$REPO/config/domains.json" COLORS_FILE="$REPO/config/label-colors.json"
AGENT_TIMEOUT_SECS=5 AGENT_KILL_GRACE_SECS=1
MIN_SEVERITY=low REPO_OWNER=acme REPO_NAME=repo FORGE_REPO_SLUG=acme/repo
CHANGE_STATEMENT='' SPEC_FILE='' MAX_ISSUES='' SOURCE_FILE='' HOSTED=false LOGS_PATH='' HOSTED_NETWORK=''
LENS_MAX_WALL_SECS=60 MAX_ITERATIONS_PER_LENS=2 GLOBAL_ISSUES_CREATED=0
REPOLENS_NO_PROGRESS_MIN_BYTES=1 REPOLENS_NO_PROGRESS_LIMIT=2 DONE_STREAK_REQUIRED=1
retire_legacy_lens_heartbeat() { :; }
resolve_effective_agent() { printf codex; }
resolve_agent_timeout() { printf 5; }
resolve_lens_heartbeat_interval() { printf 0; }
forge_prompt_issue_create() { :; }
forge_prompt_label_create() { :; }
forge_prompt_issue_list() { :; }
count_dry_run_issues() { printf 0; }
count_issues_in_output() { printf 0; }
classify_agent_iteration() { printf unknown; }
check_done() { return 0; }
compress_lens_iterations() { :; }
log_info() { :; }
log_warn() { :; }
log_error() { :; }
# shellcheck disable=SC2154 # Read the extracted callback's dynamically scoped locals.
run_agent() { printf '%s|%s\n' "$lens_role" "$lens_focus" >> "$LOG_BASE/dispatches"; printf 'agent\n' >> "$LOG_BASE/agent-calls"; printf 'DONE\n'; }
passed=0 failed=0
check() {
  if "$@"; then passed=$((passed + 1)); else failed=$((failed + 1)); printf 'FAIL: %s\n' "$*"; fi
}
cat > "$FIXTURE/dispatch.md" <<'DISPATCH'
LENS: injection role=deeper focus="src/a.sh:1"
LENS: injection role=broader missed_angle="src/b.sh:1"
DISPATCH
mapfile -t ENTRIES < <(_rounds_meta_dispatch_lens_entries "$FIXTURE/dispatch.md" "$LENSES_DIR")
check test "${#ENTRIES[@]}" -eq 2
for legacy in no yes; do
  LOG_BASE="$FIXTURE/$legacy" OUTPUT_DIR="$FIXTURE/$legacy/output" PROJECT_PATH="$FIXTURE/project"
  SUMMARY_FILE="$LOG_BASE/summary.json" completed_lenses_file="$LOG_BASE/.completed"
  mkdir -p "$LOG_BASE" "$PROJECT_PATH"
  : > "$completed_lenses_file"
  : > "$LOG_BASE/agent-calls"
  : > "$LOG_BASE/dispatches"
  if [[ "$legacy" == yes ]]; then printf 'security/injection\n' > "$completed_lenses_file"; fi
  init_summary "$SUMMARY_FILE" probe "$PROJECT_PATH" audit codex '' '' local "$OUTPUT_DIR"
  run_lens "${ENTRIES[0]}"
  check test "$?" -eq 0
  check test -s "$LOG_BASE/agent-calls"
  if _rounds_all_lenses_completed "$completed_lenses_file" "${ENTRIES[@]}"; then
    check false
  else check true; fi
  # A new round collector resuming after only the first tuple must run the other.
  run_rounds 1 ENTRIES
  check test "$?" -eq 0
  check test "$(wc -l < "$LOG_BASE/agent-calls" 2>/dev/null)" -eq 2
  check _rounds_all_lenses_completed "$completed_lenses_file" "${ENTRIES[@]}"
  check test -f "$LOG_BASE/rounds/round-1/.completed"
  # Exact retries must skip both completed investigations.
  run_rounds 1 ENTRIES
  check test "$?" -eq 0
  check test "$(wc -l < "$LOG_BASE/agent-calls" 2>/dev/null)" -eq 2
  check grep -Fxq 'deeper|src/a.sh:1' "$LOG_BASE/dispatches"
  check grep -Fxq 'broader|src/b.sh:1' "$LOG_BASE/dispatches"
  # Plain lens receipts retain their historical format and resume behavior.
  mark_lens_completed security/injection
  check is_lens_completed security/injection
done
printf 'Results: %s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
