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

# Reuse only verified successful meta output after handoff/barrier persistence fails.
# All scheduling, agent and filesystem failure outcomes are deterministic mocks.
# shellcheck disable=SC2034,SC2329 # Sourced driver calls these mocks and reads control globals.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/streak.sh
source "$SCRIPT_DIR/lib/streak.sh"
# shellcheck source=lib/template.sh
source "$SCRIPT_DIR/lib/template.sh"
# shellcheck source=lib/rounds.sh
source "$SCRIPT_DIR/lib/rounds.sh"
TEST_DIR="$(mktemp -d)" || exit 1
trap 'rm -rf "$TEST_DIR"' EXIT
passed=0 failed=0
check() {
  if "$@"; then passed=$((passed + 1)); else failed=$((failed + 1)); printf 'FAIL: %s\n' "$*"; fi
}
log_info() { :; }
log_warn() { :; }
set_stop_reason() { :; }
record_lens() { :; }
build_round_digest() { printf 'Completed mocked lenses.\n' > "$1/digest.md"; }
is_lens_completed() { grep -qxF "$1" "$completed_lenses_file"; }
run_lens() {
  is_lens_completed "$1" && return 0
  LENS_CALLS+=("$CURRENT_ROUND_INDEX:$1")
  printf '%s\n' "$1" >> "$completed_lenses_file"
}
mark_round_completed() {
  if [[ "$BLOCK_BARRIER" == true && "$1" == 1 ]]; then return 41; fi
  : > "$LOG_BASE/rounds/round-$1/.completed"
}
mv() {
  if [[ "$BLOCK_HYPOTHESES" == true && "${!#}" == "$ROUND_DIR/hypotheses.md" ]]; then return 42; fi
  if [[ "$BLOCK_ACCEPTED" == true && "${!#}" == "$ROUND_DIR/meta-orchestrator-output.txt.accepted" ]]; then return 44; fi
  command mv "$@"
}
run_agent() {
  AGENT_CALLS=$((AGENT_CALLS + 1))
  if [[ "$REPLACE_REPEAT" == true && "$AGENT_CALLS" -gt 1 ]]; then
    printf 'LENS: injection\nHYPOTHESES_TO_VERIFY:\n- Replacement hypothesis.\n'
  elif [[ "$OUTPUT_KIND" == saturated ]]; then
    printf 'NO_FRESH_ANGLES\n'
  else
    printf 'LENS: xss-csrf\nHYPOTHESES_TO_VERIFY:\n- Saved successful hypothesis.\n'
  fi
  if [[ "$AGENT_FAILURE" == structured ]]; then
    printf '{"is_error":true,"subtype":"error_max_budget_usd"}\n' > "$6"
  elif [[ "$AGENT_FAILURE" == nonzero ]]; then
    return 43
  fi
}
reset_case() {
  LOG_BASE="$TEST_DIR/$1"
  RUN_ID="$1"
  ROUND_DIR="$LOG_BASE/rounds/round-1"
  mkdir -p "$ROUND_DIR"
  SUMMARY_FILE="$LOG_BASE/summary.json"
  printf '{"stopped_reason":null,"lenses":[]}\n' > "$SUMMARY_FILE"
  completed_lenses_file="$LOG_BASE/.completed"
  : > "$completed_lenses_file"
  PROJECT_PATH="$SCRIPT_DIR" BASE_PROMPTS_DIR="$SCRIPT_DIR/prompts/_base"
  LENSES_DIR="$SCRIPT_DIR/prompts/lenses" AGENT=codex MODE=bugreport
  RESUME_RUN_ID="" PARALLEL=false LOCAL_MODE=false MAX_ISSUES=""
  BLOCK_BARRIER=false BLOCK_HYPOTHESES=false BLOCK_ACCEPTED=false REPLACE_REPEAT=false
  OUTPUT_KIND=normal AGENT_FAILURE=""
  REPOLENS_FINAL_STATE=finished AGENT_CALLS=0
  LENS_CALLS=() LENSES=(security/injection)
}
retry() { RESUME_RUN_ID="$RUN_ID"; run_rounds 2 LENSES; }

for OUTPUT in normal saturated; do
  reset_case "barrier-$OUTPUT"
  OUTPUT_KIND="$OUTPUT" BLOCK_BARRIER=true
  run_rounds 2 LENSES
  check test "$?" -eq 41
  check test "$AGENT_CALLS" -eq 1
  check test ! -f "$ROUND_DIR/.completed"
  saved_dispatch="$(cat "$ROUND_DIR/dispatch.md")"
  saved_hypotheses="$(cat "$ROUND_DIR/hypotheses.md")"
  # Complete cached hypotheses must be preserved even if another write would
  # now fail. Only missing or inconsistent artifacts need installation.
  BLOCK_BARRIER=false REPLACE_REPEAT=true BLOCK_HYPOTHESES=true
  retry
  check test "$?" -eq 0
  check test "$AGENT_CALLS" -eq 1
  check test "$(cat "$ROUND_DIR/dispatch.md")" = "$saved_dispatch"
  check test "$(cat "$ROUND_DIR/hypotheses.md")" = "$saved_hypotheses"
  check test -f "$ROUND_DIR/.completed"
  if [[ "$OUTPUT" == saturated ]]; then
    check test "$META_ORCH_SATURATED" -eq 1
    check test "${#LENS_CALLS[@]}" -eq 1
    check test ! -f "$LOG_BASE/rounds/round-2/.completed"
  else
    check test "${LENS_CALLS[*]}" = '1:security/injection 2:security/xss-csrf'
  fi
done

for prior in missing stale; do
  reset_case "hypotheses-$prior"
  if [[ "$prior" == stale ]]; then printf 'Stale hypothesis.\n' > "$ROUND_DIR/hypotheses.md"; fi
  BLOCK_HYPOTHESES=true
  run_rounds 2 LENSES
  check test "$?" -ne 0
  check test -f "$ROUND_DIR/dispatch.md"
  check test ! -f "$ROUND_DIR/.completed"
  REPLACE_REPEAT=true
  retry # Continued storage failure must stop, without another model call.
  check test "$?" -ne 0
  check test "$AGENT_CALLS" -eq 1
  check test ! -f "$ROUND_DIR/.completed"
  BLOCK_HYPOTHESES=false
  retry
  check test "$?" -eq 0
  check test "$AGENT_CALLS" -eq 1
  check grep -qxF -- '- Saved successful hypothesis.' "$ROUND_DIR/hypotheses.md"
  check test "${LENS_CALLS[*]}" = '1:security/injection 2:security/xss-csrf'
done

for failure in nonzero structured; do
  reset_case "agent-$failure"
  AGENT_FAILURE="$failure"
  run_rounds 2 LENSES
  check test "$?" -ne 0
  check test ! -f "$ROUND_DIR/meta-orchestrator-output.txt.accepted"
  # A dispatch and stale hypotheses cannot certify this failed raw output.
  printf 'LENS: injection\n' > "$ROUND_DIR/dispatch.md"
  printf 'Stale hypothesis.\n' > "$ROUND_DIR/hypotheses.md"
  AGENT_FAILURE=""
  retry
  check test "$?" -eq 0
  check test "$AGENT_CALLS" -eq 2
  check grep -qxF 'LENS: xss-csrf' "$ROUND_DIR/dispatch.md"
  check grep -qxF -- '- Saved successful hypothesis.' "$ROUND_DIR/hypotheses.md"
done

reset_case accepted-write
BLOCK_ACCEPTED=true
run_rounds 2 LENSES
check test "$?" -ne 0
check test ! -f "$ROUND_DIR/.completed"
check test ! -f "$ROUND_DIR/dispatch.md"
BLOCK_ACCEPTED=false
retry
check test "$?" -eq 0
check test "$AGENT_CALLS" -eq 2

reset_case changed-envelope
BLOCK_BARRIER=true
run_rounds 2 LENSES
check test "$?" -eq 41
printf '{"is_error":true,"subtype":"error_max_budget_usd"}\n' > "$ROUND_DIR/meta-orchestrator-output.txt.envelope.json"
BLOCK_BARRIER=false
retry
check test "$?" -eq 0
check test "$AGENT_CALLS" -eq 2
check grep -qxF 'LENS: xss-csrf' "$ROUND_DIR/dispatch.md"

reset_case changed-output
BLOCK_BARRIER=true
run_rounds 2 LENSES
check test "$?" -eq 41
printf 'NO_FRESH_ANGLES\n' > "$ROUND_DIR/meta-orchestrator-output.txt"
BLOCK_BARRIER=false
retry
check test "$?" -eq 0
check test "$AGENT_CALLS" -eq 2
check test "${LENS_CALLS[*]}" = '1:security/injection 2:security/xss-csrf'

reset_case pending-selection
BLOCK_BARRIER=true
run_rounds 2 LENSES
check test "$?" -eq 41
BLOCK_BARRIER=false
LENSES+=(security/xss-csrf)
retry
check test "$?" -eq 0
check test "$AGENT_CALLS" -eq 2
check test "${LENS_CALLS[*]}" = '1:security/injection 1:security/xss-csrf 2:security/xss-csrf'

reset_case legacy-marker
AGENT_FAILURE=nonzero
run_rounds 2 LENSES
check test "$?" -ne 0
: > "$ROUND_DIR/.completed" # Older runs marked completion before the handoff.
AGENT_FAILURE=""
retry
check test "$?" -eq 0
check test "$AGENT_CALLS" -eq 2
check test "${LENS_CALLS[*]}" = '1:security/injection 2:security/xss-csrf'

printf 'Results: %s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
