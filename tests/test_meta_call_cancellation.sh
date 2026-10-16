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

# Regression: repolens-r6-p1-1. Real returning TERM trap; model boundary mocked.
# shellcheck disable=SC1091,SC2034,SC2329 # sourced APIs use named arrays and globals
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
PROBE_DIR="$(mktemp -d)" || exit 1
trap 'rm -rf -- "$PROBE_DIR"' EXIT
source "$REPO/lib/rounds.sh" || exit 1
source "$REPO/lib/parallel.sh" || exit 1
source "$REPO/lib/template.sh" || exit 1
source "$REPO/lib/summary.sh" || exit 1
LOG_BASE="$PROBE_DIR/run" SUMMARY_FILE="$PROBE_DIR/summary.json"
mkdir -p "$LOG_BASE" || exit 1
printf '{"stopped_reason":null,"lenses":[]}\n' > "$SUMMARY_FILE" || exit 1
RUN_ID=signal-repro MODE=audit AGENT=codex PROJECT_PATH="$REPO"
BASE_PROMPTS_DIR="$REPO/prompts/_base" LENSES_DIR="$REPO/prompts/lenses"
PARALLEL=true LOCAL_MODE=false MAX_PARALLEL=1 REPOLENS_FINAL_STATE=finished
completed_lenses_file="$LOG_BASE/.completed"
LENSES=(security/injection)
log_info() { :; }
log_warn() { :; }
parallel_preflight() { _REPOLENS_SCOPE_READY=1; }
spawn_lens() { printf '%s\n' "$1" >> "$completed_lenses_file"; }
build_round_digest() { mkdir -p "$1" || return 1; printf 'No findings\n' > "$1/digest.md"; }
cat() {
  command cat "$@"
  if [[ "$*" == "$BASE_PROMPTS_DIR/meta_orchestrator.md" && ! -e "$PROBE_DIR/signalled" ]]; then
    : > "$PROBE_DIR/signalled"
    kill -TERM "$$"
  fi
}
# This is the only dispatch mock; no provider executable is invoked.
run_agent() {
  printf 'agent_dispatched_with_state=%s\n' "$REPOLENS_FINAL_STATE" >> "$PROBE_DIR/dispatch"
  printf 'NO_FRESH_ANGLES\n'
}
if run_rounds 2 LENSES; then rc=0; else rc=$?; fi
printf 'run_rounds_rc=%s final_state=%s\n' "$rc" "$REPOLENS_FINAL_STATE"
if [[ -f "$PROBE_DIR/dispatch" ]]; then command cat "$PROBE_DIR/dispatch"; fi
[[ -e "$PROBE_DIR/signalled" ]] || exit 1
[[ "$REPOLENS_FINAL_STATE" == interrupted ]] || exit 1
[[ ! -e "$PROBE_DIR/dispatch" ]] || exit 1
[[ "$rc" == "${REPOLENS_INTERRUPT_EXIT_CODE:-130}" ]] || exit 1
printf 'Results: no meta dispatch after accepted parent SIGTERM\n'

# A nonzero composition result after a returning TERM trap is cancellation,
# with no persistent prompt-render-failed marker to poison resume.
unset -f cat || exit 1
REPOLENS_FINAL_STATE=finished
ROUNDS_FAILURE_REASON=""
compose_prompt() { kill -TERM "$$"; return 42; }
rc=0
run_meta_orchestrator 1 2 || rc=$?
printf 'failed composition after TERM: rc=%s reason=%s\n' "$rc" "$ROUNDS_FAILURE_REASON"
[[ "$rc" -eq 143 ]] || exit 1
[[ "$REPOLENS_FINAL_STATE" == interrupted ]] || exit 1
[[ ! -e "$LOG_BASE/.systemic-failure-abort" ]] || exit 1
[[ ! -e "$PROBE_DIR/dispatch" ]] || exit 1
printf 'Results: failed composition retains cancellation status and resumability\n'
