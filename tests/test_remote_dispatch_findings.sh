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

# Follow the actual bugreport output instruction with a deterministic agent.
# shellcheck disable=SC2034,SC2329,SC2154 # Extracted callback consumes globals and supplies locals.
set -euo pipefail
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO/lib/template.sh"
# shellcheck source=/dev/null
source "$REPO/lib/rounds.sh"
# shellcheck source=/dev/null
source "$REPO/lib/summary.sh"
for fn in run_lens is_lens_completed mark_lens_completed template_var_escape; do
  eval "$(sed -n "/^$fn() {/,/^}/p" "$REPO/repolens.sh")"
done
FIXTURE="$(mktemp -d)"
JOB="$FIXTURE"
trap 'rm -rf -- "$FIXTURE"' EXIT
LOG_BASE="$FIXTURE/logs/probe" RUN_ID=probe MODE=bugreport ROUNDS=2
PROJECT_PATH="$FIXTURE" LOCAL_MODE=false OUTPUT_DIR_SET=false PARALLEL=false AGENT=mock
OUTPUT_DIR='' CURRENT_ROUND_OUTPUT_DIR='' CURRENT_ROUND_INDEX=2 CURRENT_ROUND_TOTAL=2
SUMMARY_FILE="$LOG_BASE/summary.json" completed_lenses_file="$LOG_BASE/.completed"
LENSES_DIR="$REPO/prompts/lenses" BASE_WRAPPER_FILE="$REPO/prompts/_base/bugreport.md"
BASE_PROMPTS_DIR="$REPO/prompts/_base" DOMAINS_FILE="$REPO/config/domains.json" COLORS_FILE="$REPO/config/label-colors.json"
AGENT_TIMEOUT_SECS=5 AGENT_KILL_GRACE_SECS=1 MIN_SEVERITY=low
REPO_OWNER=acme REPO_NAME=repo FORGE_REPO_SLUG=acme/repo
CHANGE_STATEMENT='' SPEC_FILE='' MAX_ISSUES='' SOURCE_FILE='' HOSTED=false LOGS_PATH='' HOSTED_NETWORK=''
BUG_REPORT_FILE='' TRIAGE_CONTEXT_PACK_FILE='' LENS_MAX_WALL_SECS=60
MAX_ITERATIONS_PER_LENS=2 GLOBAL_ISSUES_CREATED=0
REPOLENS_NO_PROGRESS_MIN_BYTES=1 REPOLENS_NO_PROGRESS_LIMIT=2 DONE_STREAK_REQUIRED=1
retire_legacy_lens_heartbeat() { :; }
resolve_effective_agent() { printf mock; }
resolve_agent_timeout() { printf 5; }
resolve_lens_heartbeat_interval() { printf 0; }
forge_prompt_issue_create() { :; }
forge_prompt_label_create() { :; }
forge_prompt_issue_list() { :; }
forge_issue_list_count() { printf 0; }
count_issues_in_output() { printf 0; }
classify_agent_iteration() { printf unknown; }
check_done() { return 0; }
compress_lens_iterations() { :; }
log_info() { :; }
log_warn() { :; }
log_error() { :; }
run_agent() {
  local instruction target
  printf '%s\n' "$2" > "$JOB/remote-prompt-$lens_role.md"
  instruction="$(printf '%s\n' "$2" | awk '/Write your findings to a single Markdown file at:/ {getline; getline; getline; print; exit}')"
  test -n "$instruction"
  printf '%s: %s\n' "$lens_role" "$instruction" >> "$JOB/remote-output-instructions.txt"
  target="${instruction//<run-id>/$RUN_ID}"
  target="${target//<lens_id>/$lens_id}"
  [[ "$target" == /* ]] || target="$PROJECT_PATH/$target"
  mkdir -p "$(dirname "$target")"
  cat > "$target" <<EOF
---
title: $lens_role investigation
lens_id: injection
domain: security
severity: high
root_cause_category: missing-validation
suspect_files:
  - src/a.sh:1
---
## Hypothesis
$lens_role evidence
EOF
  printf 'DONE\n'
}
mkdir -p "$LOG_BASE"
touch "$completed_lenses_file"
: > "$JOB/remote-output-instructions.txt"
init_summary "$SUMMARY_FILE" probe "$PROJECT_PATH" bugreport mock '' '' forge ''
first="$(_rounds_meta_tuple_serialize security/injection deeper 'src/a.sh:1' '' '')"
second="$(_rounds_meta_tuple_serialize security/injection broader 'src/b.sh:1' '' '')"
if run_lens "$first"; then :; else exit 1; fi
if run_lens "$second"; then :; else exit 1; fi
_rounds_all_lenses_completed "$completed_lenses_file" "$first" "$second"
test "$(wc -l < "$completed_lenses_file")" -eq 2
count="$(find "$LOG_BASE/rounds" -type f -name '*.md' | wc -l)"
printf 'Findings files: %s (expected 2)\n' "$count"
test "$count" -eq 2
for role in deeper broader; do
  target="$(sed -n "s/^$role: //p" "$JOB/remote-output-instructions.txt")"
  grep -Fxq "$role evidence" "$target"
done
build_round_digest "$LOG_BASE/rounds/round-2"
grep -Fq 'deeper' "$LOG_BASE/rounds/round-2/digest.md"
grep -Fq 'broader' "$LOG_BASE/rounds/round-2/digest.md"
before="$(cat "$JOB/remote-output-instructions.txt")"
run_lens "$first"
run_lens "$second"
test "$(cat "$JOB/remote-output-instructions.txt")" = "$before"
printf 'PASS: separate findings and completion receipts survive exact retries.\n'
