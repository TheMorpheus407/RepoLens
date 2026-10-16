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
CALLBACK_SOURCE="${REPOLENS_TEST_CALLBACK_SOURCE:-$REPO/repolens.sh}"
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
  eval "$(sed -n "/^${function_name}() {/,/^}/p" "$CALLBACK_SOURCE")"
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

# The direct CLI callback must stop on a complete or partial receipt read
# failure, before creating evidence or invoking the model. A repaired retry
# still skips the completed dispatch.
calls_before="$(wc -l < "$LOG_BASE/agent-calls")"
receipt_before="$(cat "$completed_lenses_file")"
for read_mode in empty partial; do
  cat() {
    if [[ "$*" == "$completed_lenses_file" ]]; then
      if [[ "$read_mode" == partial ]]; then command cat "$@"; fi
      return 1
    fi
    command cat "$@"
  }
  run_lens "${ENTRIES[0]}"
  check test "$?" -ne 0
  unset -f cat
  check test "$(wc -l < "$LOG_BASE/agent-calls")" -eq "$calls_before"
  check test "$(cat "$completed_lenses_file")" = "$receipt_before"
done
run_lens "${ENTRIES[0]}"
check test "$?" -eq 0
check test "$(wc -l < "$LOG_BASE/agent-calls")" -eq "$calls_before"

# Same-second callbacks must retain their own captures, local findings and live
# heartbeat, even when another investigation of the lens fails authentication.
# shellcheck source=/dev/null
source "$REPO/lib/streak.sh"
for function_name in sanitize_heartbeat_component lens_heartbeat_key lens_heartbeat_path lens_heartbeat_iteration_path write_lens_heartbeat_iteration write_lens_heartbeat stop_lens_heartbeat_writer extract_exit_trap_action restore_exit_trap run_lens_heartbeat_exit_trap; do
  eval "$(sed -n "/^${function_name}() {/,/^}/p" "$CALLBACK_SOURCE")"
done
resolve_lens_heartbeat_interval() { printf 1; }
start_lens_heartbeat_writer() { printf -v "$1" '%s' ''; }
date() {
  if [[ "$*" == '-u +%Y%m%dT%H%M%SZ' ]]; then printf '20261015T120000Z\n'; else command date "$@"; fi
}
wait_for_file() {
  local i
  for ((i=0; i<300; i++)); do
    [[ -f "$1" ]] && return 0
    sleep 0.01
  done
  return 1
}
# shellcheck disable=SC2154 # Callback locals are dynamically scoped.
run_agent() {
  printf '%s\n' "$6" > "$LOG_BASE/$lens_role.envelope-path"
  printf '%s\n' "$lens_local_dir" > "$LOG_BASE/$lens_role.output-dir"
  if [[ "$lens_role" == deeper ]]; then
    printf 'DONE\n'
    printf '{}\n' > "$6"
    printf '%s\n' "$lens_role" > "$lens_local_dir/001-finding.md"
    touch "$LOG_BASE/deeper-written"
    wait_for_file "$LOG_BASE/broader-written" || return 1
  else
    wait_for_file "$LOG_BASE/deeper-written" || return 1
    printf 'not logged in; please run /login\n'
    printf '{"api_error_status":401}\n' > "$6"
    printf '%s\n' "$lens_role" > "$lens_local_dir/001-finding.md"
    touch "$LOG_BASE/broader-written"
    wait_for_file "$LOG_BASE/release-broader" || return 1
    return 1
  fi
}
LOG_BASE="$FIXTURE/parallel" OUTPUT_DIR="$FIXTURE/parallel/output"
CURRENT_ROUND_OUTPUT_DIR=""
SUMMARY_FILE="$LOG_BASE/summary.json" completed_lenses_file="$LOG_BASE/.completed"
HEARTBEAT_DIR="$LOG_BASE/.heartbeat"
mkdir -p "$HEARTBEAT_DIR"
: > "$completed_lenses_file"
init_summary "$SUMMARY_FILE" probe "$PROJECT_PATH" audit codex '' '' local "$OUTPUT_DIR"
(trap - EXIT; run_lens "${ENTRIES[0]}") &
deeper_pid=$!
(trap - EXIT; run_lens "${ENTRIES[1]}") &
broader_pid=$!
wait "$deeper_pid"
check test "$?" -eq 0
check is_lens_completed "${ENTRIES[0]}"
check test "$(find "$HEARTBEAT_DIR" -name '*.json' | wc -l)" -eq 1
touch "$LOG_BASE/release-broader"
wait "$broader_pid"
check test "$?" -ne 0
if is_lens_completed "${ENTRIES[1]}"; then check false; else check true; fi
check test "$(find "$HEARTBEAT_DIR" -name '*.json' | wc -l)" -eq 0
check test "$(cat "$LOG_BASE/deeper.envelope-path")" != "$(cat "$LOG_BASE/broader.envelope-path")"
check grep -qx DONE "$(sed 's/\.envelope\.json$//' "$LOG_BASE/deeper.envelope-path")"
check grep -qx deeper "$(cat "$LOG_BASE/deeper.output-dir")/001-finding.md"
check grep -qx broader "$(cat "$LOG_BASE/broader.output-dir")/001-finding.md"
check test "$(find "$LOG_BASE/output" -name '*.envelope.json' | wc -l)" -eq 2
check test "$(jq '[.lenses[] | select(.status == "completed")] | length' "$SUMMARY_FILE")" -eq 1

# Long tuples exceed Bash's output buffer. Concurrent appenders must preserve
# whole lines, including backslashes, rather than mixing receipt fragments.
completed_lenses_file="$FIXTURE/long-receipts"
: > "$completed_lenses_file"
: > "$FIXTURE/expected-receipts"
printf -v padding '%65536s' ''
padding="${padding// /x}"
receipt_pids=()
for worker in {1..8}; do
  tuple="security/injection|deeper|$worker$padding|anchor\\|pipe|exclude"
  printf '%s\n' "$tuple" >> "$FIXTURE/expected-receipts"
  (
    for _ in {1..8}; do mark_lens_completed "$tuple" || exit 1; done
  ) &
  receipt_pids+=("$!")
done
for receipt_pid in "${receipt_pids[@]}"; do wait "$receipt_pid"; check test "$?" -eq 0; done
check python3 - "$FIXTURE/expected-receipts" "$completed_lenses_file" <<'PY'
from collections import Counter
from pathlib import Path
import sys
expected = Counter({line: 8 for line in Path(sys.argv[1]).read_text().splitlines()})
actual = Counter(Path(sys.argv[2]).read_text().splitlines())
sys.exit(0 if actual == expected else 1)
PY

# A failed receipt write must propagate through the callback so the round
# cannot certify work whose completion was never persisted.
LOG_BASE="$FIXTURE/receipt-failure" OUTPUT_DIR="$FIXTURE/receipt-failure/output"
SUMMARY_FILE="$LOG_BASE/summary.json" completed_lenses_file="$LOG_BASE/blocked-receipts"
mkdir -p "$LOG_BASE"
: > "$completed_lenses_file"
init_summary "$SUMMARY_FILE" probe "$PROJECT_PATH" audit codex '' '' local "$OUTPUT_DIR"
resolve_lens_heartbeat_interval() { printf 0; }
run_agent() { printf 'called\n' >> "$LOG_BASE/receipt-failure-agent-calls"; printf 'DONE\n'; }
# Keep lookup readable so this fixture reaches the append failure.
eval "$(declare -f mark_lens_completed | sed '1s/mark_lens_completed/real_mark_lens_completed/')"
mark_lens_completed() {
  if [[ "$completed_lenses_file" == "$LOG_BASE/blocked-receipts" ]]; then
    printf 'attempted\n' >> "$LOG_BASE/receipt-write-attempts"
    return 1
  fi
  real_mark_lens_completed "$@"
}
run_lens security/injection
check test "$?" -ne 0
LENSES=(security/injection)
run_rounds 1 LENSES
check test "$?" -ne 0
check test ! -f "$LOG_BASE/rounds/round-1/.completed"
check test "$(jq -r .stopped_reason "$SUMMARY_FILE")" = lens-execution-failed
check test ! -s "$completed_lenses_file"
check test "$(wc -l < "$LOG_BASE/receipt-write-attempts")" -eq 2
check test "$(wc -l < "$LOG_BASE/receipt-failure-agent-calls")" -eq 2
unset ROUNDS_FAILURE_REASON

# Hash/capture allocation failures stop before model execution and still clean
# an already-started heartbeat. A repaired retry remains possible.
completed_lenses_file="$LOG_BASE/.completed"
: > "$completed_lenses_file"
run_agent() { printf 'called\n' >> "$LOG_BASE/unexpected-agent"; printf 'DONE\n'; }
sha256_text() { return 1; }
run_lens "${ENTRIES[0]}"
check test "$?" -ne 0
check test ! -e "$LOG_BASE/unexpected-agent"
check test ! -s "$completed_lenses_file"
unset -f sha256_text
# shellcheck source=/dev/null
source "$REPO/lib/core.sh"
HEARTBEAT_DIR="$LOG_BASE/.heartbeat"
mkdir -p "$HEARTBEAT_DIR"
resolve_lens_heartbeat_interval() { printf 1; }
mktemp() {
  if [[ "$*" == *iteration-* ]]; then return 1; else command mktemp "$@"; fi
}
run_lens "${ENTRIES[0]}"
check test "$?" -ne 0
check test ! -e "$LOG_BASE/unexpected-agent"
check test ! -s "$completed_lenses_file"
check test "$(find "$HEARTBEAT_DIR" -type f | wc -l)" -eq 0
unset -f mktemp

# Vary each attribute on its own, including escaped pipes and Unicode. Local
# ingestion must retain canonical metadata even in nested dispatch directories.
# shellcheck source=/dev/null
source "$REPO/lib/ledger.sh"
# shellcheck disable=SC2154 # The production callback supplies these locals.
run_agent() {
  printf 'called\n' >> "$LOG_BASE/matrix-agent"
  cat > "$lens_local_dir/001-finding.md" <<EOF
---
title: $lens_role $lens_focus $prior_finding_anchor $exclusion_hints
severity: low
---
Finding without optional domain/lens frontmatter.
EOF
  printf 'DONE\n'
}
LOG_BASE="$FIXTURE/matrix" OUTPUT_DIR="$FIXTURE/matrix/output"
CURRENT_ROUND_OUTPUT_DIR=""
SUMMARY_FILE="$LOG_BASE/summary.json" completed_lenses_file="$LOG_BASE/.completed"
mkdir -p "$LOG_BASE"
: > "$completed_lenses_file"
resolve_lens_heartbeat_interval() { printf 0; }
init_summary "$SUMMARY_FILE" probe "$PROJECT_PATH" audit codex '' '' local "$OUTPUT_DIR"
MATRIX=(
  "$(_rounds_meta_tuple_serialize security/injection deeper 'src/ä|b.sh:1' a e)"
  "$(_rounds_meta_tuple_serialize security/injection broader 'src/ä|b.sh:1' a e)"
  "$(_rounds_meta_tuple_serialize security/injection deeper 'src/c.sh:1' a e)"
  "$(_rounds_meta_tuple_serialize security/injection deeper 'src/ä|b.sh:1' b e)"
  "$(_rounds_meta_tuple_serialize security/injection deeper 'src/ä|b.sh:1' a f)"
)
for tuple in "${MATRIX[@]}"; do
  run_lens "$tuple"
  check test "$?" -eq 0
  check is_lens_completed "$tuple"
done
check test "$(wc -l < "$LOG_BASE/matrix-agent")" -eq 5
check test "$(find "$OUTPUT_DIR" -name '*.md' | wc -l)" -eq 5
check build_findings_jsonl_from_local "$OUTPUT_DIR" "$LOG_BASE/registry.jsonl"
check test "$(jq -sc '[.[] | select(.domain == "security" and .lens == "injection")] | length' "$LOG_BASE/registry.jsonl")" -eq 5
printf '%s\n' "${MATRIX[0]}" > "$completed_lenses_file"
_rounds_record_skipped_lenses "${MATRIX[0]}" "${MATRIX[1]}"
check test "$(jq '[.lenses[] | select(.status == "skipped")] | length' "$SUMMARY_FILE")" -eq 1
# Apple mktemp randomizes trailing Xs only. Model that behavior while keeping
# the production capture allocator, callback, and same-second retry intact.
LOG_BASE="$FIXTURE/portable-capture" OUTPUT_DIR="$FIXTURE/portable-capture/output"
SUMMARY_FILE="$LOG_BASE/summary.json" completed_lenses_file="$LOG_BASE/.completed"
mkdir -p "$LOG_BASE"
: > "$completed_lenses_file"
init_summary "$SUMMARY_FILE" probe "$PROJECT_PATH" audit codex '' '' local "$OUTPUT_DIR"
run_agent() { printf 'DONE\n'; }
mktemp() {
  if [[ "$#" == 1 && "$1" == *iteration-* && "$1" != *XXXXXX ]]; then
    (set -o noclobber; : > "$1") 2>/dev/null || return 1
    printf '%s\n' "$1"
  else command mktemp "$@"; fi
}
run_lens "${ENTRIES[0]}"
check test "$?" -eq 0
: > "$completed_lenses_file"
run_lens "${ENTRIES[0]}"
check test "$?" -eq 0
check is_lens_completed "${ENTRIES[0]}"
check test "$(find "$LOG_BASE/security" -name 'iteration-*.txt' | wc -l)" -eq 2
unset -f mktemp

# A skipped no-clobber rename must preserve existing data, discard the
# temporary allocation, clean its heartbeat, and leave the dispatch pending.
: > "$completed_lenses_file"
HEARTBEAT_DIR="$LOG_BASE/.heartbeat"
mkdir -p "$HEARTBEAT_DIR"
resolve_lens_heartbeat_interval() { printf 1; }
mv() {
  if [[ "$#" == 3 && "$1" == -n && "$2" == *iteration-* ]]; then
    printf 'existing evidence\n' > "$3"
    return 0
  fi
  command mv "$@"
}
run_lens "${ENTRIES[0]}"
check test "$?" -ne 0
check test ! -s "$completed_lenses_file"
check test "$(find "$LOG_BASE/security" -type f ! -name '*.txt' ! -name '*.envelope.json' | wc -l)" -eq 0
check test "$(find "$HEARTBEAT_DIR" -type f | wc -l)" -eq 0
check test "$(find "$LOG_BASE/security" -name '*.txt' -exec grep -lx 'existing evidence' {} + | wc -l)" -eq 1
unset -f mv
mark_lens_completed "${ENTRIES[0]}"

# Older attributed runs left a canonical heartbeat. Retire it before the
# completion shortcut, even with heartbeats disabled; preserve a live plain
# sibling and unrelated/dispatch-owned files.
eval "$(sed -n '/^retire_legacy_lens_heartbeat() {/,/^}/p' "$CALLBACK_SOURCE")"
HEARTBEAT_DIR="$LOG_BASE/.heartbeat"
mkdir -p "$HEARTBEAT_DIR"
legacy_heartbeat="$(lens_heartbeat_path security injection)"
legacy_iteration="$(lens_heartbeat_iteration_path security injection)"
sibling_heartbeat="$(lens_heartbeat_path security dispatch-unrelated)"
printf 'unrelated\n' > "$sibling_heartbeat"
for interval in 0 1; do
  resolve_lens_heartbeat_interval() { printf '%s' "$interval"; }
  printf '{"domain":"security","lens_id":"injection","pid":0,"state":"running"}\n' > "$legacy_heartbeat"
  printf '1\n' > "$legacy_iteration"
  printf partial > "$legacy_heartbeat.tmp.123"
  printf partial > "$legacy_iteration.tmp.123"
  run_lens "${ENTRIES[0]}"
  check test "$?" -eq 0
  check test ! -e "$legacy_heartbeat"
  check test ! -e "$legacy_iteration"
  check test ! -e "$legacy_heartbeat.tmp.123"
  check test ! -e "$legacy_iteration.tmp.123"
  check grep -qx unrelated "$sibling_heartbeat"
done
printf '{"domain":"security","lens_id":"injection","pid":%s,"state":"running"}\n' "$BASHPID" > "$legacy_heartbeat"
printf '3\n' > "$legacy_iteration"
run_lens "${ENTRIES[0]}"
check test "$?" -eq 0
check test -f "$legacy_heartbeat"
check grep -qx 3 "$legacy_iteration"
# Completed-round shortcuts also perform retirement without a lens callback.
printf '{"domain":"security","lens_id":"injection","pid":0}\n' > "$legacy_heartbeat"
LENSES=("${ENTRIES[0]}")
run_rounds 1 LENSES
check test "$?" -eq 0
check test ! -e "$legacy_heartbeat"
check test ! -e "$legacy_iteration"
printf 'Results: %s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
