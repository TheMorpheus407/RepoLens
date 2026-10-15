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

# Exercise the real lens callback and round driver with failed SHA backends.
# No models or authenticated forge commands run; all state belongs to FIXTURE.
# shellcheck disable=SC2034,SC2329 # Production functions consume globals/mocks.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
# shellcheck source=/dev/null
source "$REPO/lib/rounds.sh"
# shellcheck source=/dev/null
source "$REPO/lib/summary.sh"
eval "$(awk '/^(sanitize_heartbeat_component|lens_heartbeat_key|lens_heartbeat_path|lens_heartbeat_iteration_path|retire_legacy_lens_heartbeat|resolve_lens_heartbeat_interval|read_lens_heartbeat_iteration|write_lens_heartbeat_iteration|write_lens_heartbeat|start_lens_heartbeat_writer|stop_lens_heartbeat_writer|extract_exit_trap_action|restore_exit_trap|run_lens_heartbeat_exit_trap|is_lens_completed|mark_lens_completed|run_lens)\(\)/,/^}/' "$REPO/repolens.sh")"
log_info() { :; }
log_warn() { :; }
log_error() { printf '%s\n' "$*" >&2; }
resolve_effective_agent() { printf mock; }
resolve_agent_timeout() { printf 10; }
read_frontmatter() { printf 'Mock lens'; }
compose_prompt() { printf 'Mock prompt'; }
template_var_escape() { printf '%s' "$1"; }
forge_prompt_issue_create() { :; }
forge_prompt_label_create() { :; }
forge_prompt_issue_list() { :; }
count_dry_run_issues() { printf 0; }
count_issues_in_output() { printf 0; }
classify_agent_iteration() { printf unknown; }
json_matches() { jq -e "$@" >/dev/null; }
check_done() { grep -qx DONE "$1"; }
compress_lens_iterations() { :; }
build_round_digest() { mkdir -p "$1"; printf 'mock digest\n' > "$1/digest.md"; }
run_agent() { printf 'called\n' >> "$LOG_BASE/agent-calls"; printf 'DONE\n'; }
# Keep the real hash helper, but simulate a backend failing on either call.
sha256sum() {
  local calls
  calls="$(cat "$LOG_BASE/hash-calls")"
  calls=$((calls + 1))
  printf '%s\n' "$calls" > "$LOG_BASE/hash-calls"
  if [[ "$hash_mode" == first || ( "$hash_mode" == second && "$calls" -eq 2 ) ]]; then return 71; fi
  command sha256sum
}
LOCAL_MODE=true OUTPUT_DIR_SET=true PARALLEL=false MODE=audit AGENT=mock RUN_ID=heartbeat-failure
DOMAINS_FILE="$REPO/config/domains.json" COLORS_FILE="$REPO/config/label-colors.json"
LENSES_DIR="$FIXTURE/lenses" BASE_WRAPPER_FILE="$REPO/prompts/_base/audit.md"
PROJECT_PATH="$FIXTURE" BASE_PROMPTS_DIR="$REPO/prompts/_base"
MIN_SEVERITY=low REPO_NAME=mock REPO_OWNER=mock FORGE_REPO_SLUG=mock/mock
CHANGE_STATEMENT='' SPEC_DIFF_FILE='' BRANCH_MANIFEST_FILE='' BUG_REPORT_FILE=''
SOURCE_FILE='' LOGS_PATH='' HOSTED_NETWORK='' SPEC_FILE='' HOSTED=false MAX_ISSUES=''
AGENT_TIMEOUT_SECS=10 AGENT_KILL_GRACE_SECS=1 LENS_MAX_WALL_SECS=10
MAX_ITERATIONS_PER_LENS=3 DONE_STREAK_REQUIRED=1
REPOLENS_NO_PROGRESS_MIN_BYTES=1 REPOLENS_NO_PROGRESS_LIMIT=3
LENS_HEARTBEAT_INTERVAL_DEFAULT=15
long_id="r2-$(printf '%0200d' 0 | tr 0 a)"
passed=0 failed=0
check() {
  if "$@"; then passed=$((passed + 1));
  else failed=$((failed + 1)); printf 'FAIL: %s\n' "$*"; fi
}
# Run from an owned directory so any escaped .tmp.PID writes are observable.
cd "$FIXTURE"
for hash_mode in first second; do
  LOG_BASE="$FIXTURE/$hash_mode" HEARTBEAT_DIR="$FIXTURE/$hash_mode/.heartbeat"
  OUTPUT_DIR="$LOG_BASE/output" SUMMARY_FILE="$LOG_BASE/summary.json"
  completed_lenses_file="$LOG_BASE/.completed" GLOBAL_ISSUES_CREATED=0
  mkdir -p "$HEARTBEAT_DIR"
  printf '0\n' > "$LOG_BASE/hash-calls"
  init_summary "$SUMMARY_FILE" "$RUN_ID" "$PROJECT_PATH" "$MODE" "$AGENT"
  LENSES=("custom/$long_id")
  REPOLENS_LENS_HEARTBEAT_INTERVAL=15
  prior_trap="$(trap -p EXIT)"
  rc=0
  run_rounds 1 LENSES || rc=$?
  check test "$rc" -ne 0
  check test "$ROUNDS_FAILURE_REASON" = lens-execution-failed
  check json_matches '.stopped_reason == "lens-execution-failed" and any(.lenses[]; .status == "lens-execution-failed" and .iterations == 0)' "$SUMMARY_FILE"
  check test ! -e "$LOG_BASE/agent-calls"
  check test ! -s "$completed_lenses_file"
  check test ! -e "$LOG_BASE/rounds/round-1/.completed"
  check test -z "$(find "$FIXTURE" -name '.tmp.*' -o -name '*.tmp.*')"
  check test -z "$(find "$HEARTBEAT_DIR" -type f)"
  check test "$(trap -p EXIT)" = "$prior_trap"
  if [[ "$hash_mode" == first ]]; then expected_calls=1; else expected_calls=2; fi
  check test "$(cat "$LOG_BASE/hash-calls")" -eq "$expected_calls"
  rm -f -- "$FIXTURE"/.tmp.*
  # Model the existing explicit-resume reset, then retry the same real callback.
  hash_mode=working
  rm -f "$LOG_BASE/.systemic-failure-abort"
  clear_stop_reason "$SUMMARY_FILE"
  RESUME_RUN_ID="$RUN_ID"
  run_rounds 1 LENSES || exit $?
  check test "$(wc -l < "$LOG_BASE/agent-calls")" -eq 1
  check grep -qxF "custom/$long_id" "$completed_lenses_file"
  check json_matches '.stopped_reason == null and any(.lenses[]; .status == "completed")' "$SUMMARY_FILE"
  check test -z "$(find "$HEARTBEAT_DIR" -type f)"
  check test -z "$(find "$FIXTURE" -name '.tmp.*' -o -name '*.tmp.*')"
  run_rounds 1 LENSES || exit $?
  check test "$(wc -l < "$LOG_BASE/agent-calls")" -eq 1
  unset RESUME_RUN_ID
done
# Disabled heartbeats and ordinary short keys never need the failing backend.
for scenario in disabled short; do
  LOG_BASE="$FIXTURE/$scenario" HEARTBEAT_DIR="$FIXTURE/$scenario/.heartbeat"
  OUTPUT_DIR="$LOG_BASE/output" SUMMARY_FILE="$LOG_BASE/summary.json"
  completed_lenses_file="$LOG_BASE/.completed" GLOBAL_ISSUES_CREATED=0 hash_mode=first
  mkdir -p "$HEARTBEAT_DIR"
  printf '0\n' > "$LOG_BASE/hash-calls"
  init_summary "$SUMMARY_FILE" "$RUN_ID" "$PROJECT_PATH" "$MODE" "$AGENT"
  if [[ "$scenario" == disabled ]]; then
    REPOLENS_LENS_HEARTBEAT_INTERVAL=0 LENSES=("custom/$long_id")
  else
    REPOLENS_LENS_HEARTBEAT_INTERVAL=15 LENSES=(custom/short)
  fi
  run_rounds 1 LENSES || exit $?
  check test "$(cat "$LOG_BASE/hash-calls")" -eq 0
  check test "$(wc -l < "$LOG_BASE/agent-calls")" -eq 1
  check test -z "$(find "$HEARTBEAT_DIR" -type f)"
  check test -z "$(find "$FIXTURE" -name '.tmp.*' -o -name '*.tmp.*')"
done
printf '%s checks passed; %s failed.\n' "$passed" "$failed"
test "$failed" -eq 0
