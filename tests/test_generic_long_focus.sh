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


# repolens-r8-p2-3. Real parser, round driver and run_lens; local agent stub only.
# shellcheck disable=SC2034,SC2329 # Extracted driver functions consume globals/callbacks.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
# shellcheck source=lib/template.sh
source "$REPO/lib/template.sh"
# shellcheck source=lib/rounds.sh
source "$REPO/lib/rounds.sh"
# shellcheck source=lib/summary.sh
source "$REPO/lib/summary.sh"
for function_name in run_lens is_lens_completed mark_lens_completed template_var_escape; do
  eval "$(sed -n "/^${function_name}() {/,/^}/p" "$REPO/repolens.sh")"
done

set -euo pipefail
LOCAL_MODE=true MODE=bugreport AGENT=mock PARALLEL=false
RUN_ID=probe RESUME_RUN_ID=probe
LENSES_DIR="$REPO/prompts/lenses" BASE_WRAPPER_FILE="$REPO/prompts/_base/bugreport.md"
BASE_PROMPTS_DIR="$REPO/prompts/_base"
DOMAINS_FILE="$REPO/config/domains.json" COLORS_FILE="$REPO/config/label-colors.json"
AGENT_TIMEOUT_SECS=5 AGENT_KILL_GRACE_SECS=1
MIN_SEVERITY=low REPO_OWNER=acme REPO_NAME=repo FORGE_REPO_SLUG=acme/repo
CHANGE_STATEMENT='' SPEC_FILE='' MAX_ISSUES='' SOURCE_FILE='' HOSTED=false LOGS_PATH='' HOSTED_NETWORK=''
BUG_REPORT_FILE='' TRIAGE_CONTEXT_PACK_FILE=''
LENS_MAX_WALL_SECS=60 MAX_ITERATIONS_PER_LENS=2 GLOBAL_ISSUES_CREATED=0
REPOLENS_NO_PROGRESS_MIN_BYTES=1 REPOLENS_NO_PROGRESS_LIMIT=2 DONE_STREAK_REQUIRED=1
retire_legacy_lens_heartbeat() { :; }
resolve_effective_agent() { printf mock; }
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
log_warn() { printf '%s\n' "$*" >&2; }
log_error() { printf '%s\n' "$*" >&2; }
run_agent() { printf 'called\n' >> "$LOG_BASE/agent-calls"; printf 'DONE\n'; }
for scenario in short boundary long; do
  LOG_BASE="$FIXTURE/$scenario" OUTPUT_DIR="$FIXTURE/$scenario/output" PROJECT_PATH="$FIXTURE/project"
  SUMMARY_FILE="$LOG_BASE/summary.json" completed_lenses_file="$LOG_BASE/.completed"
  mkdir -p "$LOG_BASE" "$PROJECT_PATH"
  : > "$completed_lenses_file"
  : > "$LOG_BASE/agent-calls"
  focus='Check query construction'
  if [[ "$scenario" == boundary ]]; then
    focus="$(printf '%0248d' 0 | tr 0 a)"
  elif [[ "$scenario" == long ]]; then
    focus='Trace the complete request lifecycle from the public HTTP route through authentication and authorization middleware into the database transaction and asynchronous worker callback, checking error propagation, cancellation, retry behavior, resource cleanup, and concurrent updates to the same account.'
  fi
  printf 'GENERIC: role=deeper focus="%s"\n' "$focus" > "$LOG_BASE/dispatch.md"
  mapfile -t ENTRIES < <(_rounds_meta_dispatch_generic_entries "$LOG_BASE/dispatch.md")
  test "${#ENTRIES[@]}" -eq 1
  canonical="${ENTRIES[0]%%|*}"
  if [[ "$scenario" == boundary ]]; then test "$canonical" = "generic/deeper-$focus"; fi
  init_summary "$SUMMARY_FILE" probe "$PROJECT_PATH" bugreport mock '' '' local "$OUTPUT_DIR"
  for attempt in first resume; do
    rc=0
    run_rounds 1 ENTRIES || rc=$?
    printf '%s/%s: generated_basename_bytes=%s run_rounds_rc=%s model_calls=%s completion_receipts=%s stopped_reason=%s\n' \
      "$scenario" "$attempt" "${#canonical}" "$rc" "$(wc -l < "$LOG_BASE/agent-calls")" \
      "$(wc -l < "$completed_lenses_file")" "$(jq -r .stopped_reason "$SUMMARY_FILE")"
    test "$rc" -eq 0
    test "$(wc -l < "$LOG_BASE/agent-calls")" -eq 1
    test "$(wc -l < "$completed_lenses_file")" -eq 1
    test -e "$LOG_BASE/rounds/round-1/.completed"
  done
done

# Reach the same failure through the public bugreport waves path: real triage
# seed -> wave selector -> dispatch parser -> round driver -> lens callback.
LOG_BASE="$FIXTURE/waves" OUTPUT_DIR="$FIXTURE/waves/output" PROJECT_PATH="$FIXTURE/project"
SUMMARY_FILE="$LOG_BASE/summary.json" completed_lenses_file="$LOG_BASE/.completed"
CURRENT_ROUND_OUTPUT_DIR='' STRATEGY=waves
mkdir -p "$LOG_BASE/triage"
printf '%s\n' "$focus" > "$LOG_BASE/triage/investigation-seeds.txt"
: > "$completed_lenses_file"
: > "$LOG_BASE/agent-calls"
init_summary "$SUMMARY_FILE" probe "$PROJECT_PATH" bugreport mock '' '' local "$OUTPUT_DIR"
LENSES=(security/injection)
for attempt in first resume; do
  rc=0
  run_rounds 2 LENSES || rc=$?
  printf 'waves/%s: run_rounds_rc=%s model_calls=%s round1_complete=%s\n' "$attempt" "$rc" \
    "$(wc -l < "$LOG_BASE/agent-calls")" \
    "$(if [[ -e "$LOG_BASE/rounds/round-1/.completed" ]]; then echo yes; else echo no; fi)"
  test "$rc" -eq 0
  test -s "$LOG_BASE/agent-calls"
  test -e "$LOG_BASE/rounds/round-1/.completed"
  if [[ "$attempt" == first ]]; then wave_calls="$(wc -l < "$LOG_BASE/agent-calls")";
  else test "$(wc -l < "$LOG_BASE/agent-calls")" -eq "$wave_calls"; fi
done

# Same long prefix, different tails: retain focus text and stable distinct IDs.
LOG_BASE="$FIXTURE/identities"
mkdir -p "$LOG_BASE"
prefix="$(printf '%0400d' 0 | tr 0 a)"
ids=()
for tail in b c; do
  focus="$prefix$tail"
  printf 'GENERIC: role=deeper focus="%s"\n' "$focus" > "$LOG_BASE/dispatch.md"
  tuple="$(_rounds_meta_dispatch_generic_entries "$LOG_BASE/dispatch.md")"
  identity='' role='' restored_focus='' anchor='' exclude=''
  _rounds_meta_tuple_parse "$tuple" identity role restored_focus anchor exclude
  test "$restored_focus" = "$focus"
  test "${#identity}" -le 263
  test "$(_rounds_meta_dispatch_generic_entries "$LOG_BASE/dispatch.md")" = "$tuple"
  ids+=("$identity")
done
test "${ids[0]}" != "${ids[1]}"
rc=0
( sha256_text() { return 1; }; _rounds_meta_dispatch_generic_entries "$LOG_BASE/dispatch.md" ) || rc=$?
test "$rc" -ne 0
printf 'Results: 4 integration scenarios and stable distinct bounded identities passed, 0 failed\n' 
