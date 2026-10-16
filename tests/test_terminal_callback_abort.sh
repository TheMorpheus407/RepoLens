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

# repolens-r7-p1-1 / repolens-r7-p2-1: marker IO cannot hide aborts.
# shellcheck disable=SC1091,SC2034,SC2329 # Extracted CLI functions consume fixture globals.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JOB="$REPO"
source "$REPO/lib/template.sh"
source "$REPO/lib/rounds.sh"
source "$REPO/lib/summary.sh"
for name in run_lens is_lens_completed mark_lens_completed template_var_escape resolve_run_exit_code write_rate_limit_abort_marker read_rate_limit_abort_earliest_at rate_limit_abort_stopped_reason is_phase_rate_limit_stopped_reason; do
  eval "$(sed -n "/^${name}() {/,/^}/p" "$REPO/repolens.sh")"
done
LOCAL_MODE=true MODE=audit AGENT=codex PARALLEL=false
RUN_ID=probe RESUME_RUN_ID=probe OUTPUT_DIR_SET=true
LENSES_DIR="$REPO/prompts/lenses" BASE_WRAPPER_FILE="$REPO/prompts/_base/audit.md"
DOMAINS_FILE="$REPO/config/domains.json" COLORS_FILE="$REPO/config/label-colors.json"
AGENT_TIMEOUT_SECS=5 AGENT_KILL_GRACE_SECS=1 RATE_LIMIT_MAX_SLEEP_SECS=0
MIN_SEVERITY=low REPO_OWNER=acme REPO_NAME=repo FORGE_REPO_SLUG=acme/repo
CHANGE_STATEMENT='' SPEC_FILE='' MAX_ISSUES='' SOURCE_FILE='' HOSTED=false LOGS_PATH='' HOSTED_NETWORK=''
LENS_MAX_WALL_SECS=60 MAX_ITERATIONS_PER_LENS=2 GLOBAL_ISSUES_CREATED=0
REPOLENS_NO_PROGRESS_MIN_BYTES=1 REPOLENS_NO_PROGRESS_LIMIT=1 DONE_STREAK_REQUIRED=1
retire_legacy_lens_heartbeat() { :; }
resolve_effective_agent() { printf codex; }
resolve_agent_timeout() { printf 5; }
resolve_lens_heartbeat_interval() { printf 0; }
forge_prompt_issue_create() { :; }
forge_prompt_label_create() { :; }
forge_prompt_issue_list() { :; }
count_dry_run_issues() { printf 0; }
count_issues_in_output() { printf 0; }
classify_agent_iteration() { printf "%s" "$classification"; }
detect_agent_rate_limit() { printf "mock-rate-limit|retry later"; }
parse_rate_limit_resume_epoch() { return 1; }
check_done() { return 1; }
compress_lens_iterations() { :; }
log_info() { :; }
log_warn() { printf '%s\n' "$*" >&2; }
log_error() { printf '%s\n' "$*" >&2; }
run_agent() { printf 'temporary provider error\n'; return 1; }
LENSES=(security/injection)
case_root="$(mktemp -d)"
trap 'rm -rf -- "$case_root"' EXIT
for failure in no-progress rate-limited; do
classification=unknown
marker_name=.agent-no-progress-abort
if [[ "$failure" == rate-limited ]]; then classification=rate-limited; marker_name=.rate-limit-abort; fi
for marker in writable blocked; do
  LOG_BASE="$case_root/$failure-$marker"
  OUTPUT_DIR="$LOG_BASE/output" PROJECT_PATH="$JOB"
  SUMMARY_FILE="$LOG_BASE/summary.json" completed_lenses_file="$LOG_BASE/.completed"
  mkdir -p "$LOG_BASE"
  : > "$completed_lenses_file"
  if [[ "$marker" == blocked ]]; then mkdir -p "$LOG_BASE/$marker_name"; fi
  init_summary "$SUMMARY_FILE" probe "$PROJECT_PATH" audit codex '' '' local "$OUTPUT_DIR"
  rc=0
  run_rounds 1 LENSES || rc=$?
  round_complete=false receipt=false
  [[ ! -f "$LOG_BASE/rounds/round-1/.completed" ]] || round_complete=true
  [[ ! -s "$completed_lenses_file" ]] || receipt=true
  RUN_ROUNDS_RC="$rc" REPOLENS_FINAL_STATE=finished RUN_HEALTH=no-findings
  printf 'failure=%s marker=%s run_rounds_rc=%s round_completed=%s lens_receipt=%s statuses=%s process_exit_resolution=%s\n' "$failure" "$marker" "$rc" "$round_complete" "$receipt" "$(jq -c '[.lenses[].status]' "$SUMMARY_FILE")" "$(resolve_run_exit_code)"
  if [[ "$marker" == blocked ]]; then
    test "$rc" -ne 0; test "$round_complete" == false; test "$receipt" == false; test "$(resolve_run_exit_code)" -ne 0
  else
    test "$rc" -ne 0; test "$round_complete" == false
  fi
done
done
