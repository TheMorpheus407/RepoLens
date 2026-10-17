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


# Real delivery/finalization/exit ladder with a local stub investigator.
# shellcheck disable=SC2034,SC2329 # Extracted production code consumes globals.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source <(awk '/^LOG_BASE=/ {exit} /^REPO=/ {next} {print}' "$REPO/tests/test_generic_explicit_output.sh")
for lib in attempts result_pointer cursor_ide status; do
  # shellcheck source=/dev/null
  source "$REPO/lib/$lib.sh"
done
# shellcheck source=/dev/null
source <(sed -n '/^rate_limit_abort_stopped_reason() {/,/^apply_rate_limit_abort_final_state() {/p' "$REPO/repolens.sh" | sed '$d')
print_resume_hint() { printf 'RESUME_HINT\n'; }
record_delivery_outcome() {
  # Execute the terminal reason write separately from artifact transactions.
  # shellcheck source=/dev/null
  source <(sed -n '/^# Persist required delivery failure/,/^apply_rate_limit_abort_final_state || true/p' "$REPO/repolens.sh" | sed '$d')
}
record_status() {
  write_status_snapshot "$REPOLENS_FINAL_STATE" "$RUN_ID" "$LOG_BASE" "$HEARTBEAT_DIR" \
    "$completed_lenses_file" "$SUMMARY_FILE" "$PROJECT_PATH" acme/repo "$MODE" mock false 1 "$completed_lenses_file"
}
exit_ladder() (
  RUN_EXIT_CODE="$(resolve_run_exit_code)"
  # shellcheck source=/dev/null
  source <(sed -n '/^# Exit-code ladder/,$p' "$REPO/repolens.sh")
)

LOG_BASE="$FIXTURE/run" OUTPUT_DIR="$FIXTURE/output" PROJECT_PATH="$FIXTURE/project"
SUMMARY_FILE="$LOG_BASE/summary.json" HEARTBEAT_DIR="$LOG_BASE/.heartbeats"
completed_lenses_file="$LOG_BASE/.completed"
RUN_ID=probe ROUNDS=1 MODE=bugreport LOCAL_MODE=true OUTPUT_DIR_SET=true HUMAN_REVIEW=true
REPOLENS_FINAL_STATE=finished RUN_ROUNDS_RC=0 RUN_HEALTH=ok
mkdir -p "$LOG_BASE/rounds/round-1/lens-outputs" "$OUTPUT_DIR" "$PROJECT_PATH" "$HEARTBEAT_DIR"
: > "$completed_lenses_file"
: > "$LOG_BASE/agent-calls"
printf '%s\n' '{"lens_ids":["generic/probe"]}' > "$LOG_BASE/rounds/round-1/metadata.json"
init_summary "$SUMMARY_FILE" probe "$PROJECT_PATH" bugreport mock '' '' local "$OUTPUT_DIR"
run_lens generic/probe || exit 1
optional_local_finalization
test "$(resolve_run_exit_code)" = 0
saved=("$completed_lenses_file" "$LOG_BASE/agent-calls"
  "$LOG_BASE/rounds/round-1/lens-outputs/probe.md"
  "$LOG_BASE/final/"{generic-delivery.json,findings.jsonl,findings.csv,TODO.md,SUMMARY.md,NEEDS_REVIEW.md,DUPLICATES.md,HUMAN_REVIEW.md})
before="$(sha256sum "${saved[@]}")"
mv "$OUTPUT_DIR/generic" "$FIXTURE/saved-generic"
mkdir "$FIXTURE/outside"
ln -s "$FIXTURE/outside" "$OUTPUT_DIR/generic"
optional_local_finalization
test "$REPOLENS_FINAL_STATE" = failed
test "$RUN_ROUNDS_RC" -ne 0
test "$(resolve_why_stopped)" = generic-delivery-failed
test "$(resolve_run_exit_code)" = 1
test "$(sha256sum "${saved[@]}")" = "$before"
# A stale cap reason or failed terminal metadata write must not hide delivery.
set_stop_reason "$SUMMARY_FILE" max-issues-reached
(
  set_stop_reason() { return 74; }
  record_delivery_outcome
  test "$(resolve_why_stopped)" = generic-delivery-failed
  test "$(resolve_run_exit_code)" = 1
)
record_delivery_outcome
jq -e '.stopped_reason == "generic-delivery-failed"' "$SUMMARY_FILE" >/dev/null
attempts_finalize "$LOG_BASE" "$REPOLENS_FINAL_STATE" "$(resolve_why_stopped)" "$(resolve_run_exit_code)"
jq -e 'last | .status == "failed" and .exit_code == 1 and .why_stopped == "generic-delivery-failed"' "$LOG_BASE/attempts.json" >/dev/null
record_status
jq -e '.state == "failed" and .stopped_reason == "generic-delivery-failed" and .attempts[-1].status == "failed"' "$LOG_BASE/status.json" >/dev/null
write_latest_result_pointer "$FIXTURE" "$RUN_ID" "$MODE" mock "$SUMMARY_FILE" "$REPOLENS_FINAL_STATE" "$LOG_BASE/final"
jq -e '.status == "failed"' "$FIXTURE/latest-result.json" >/dev/null
cursor_ide_run_complete_json "$RUN_ID" "$REPOLENS_FINAL_STATE" "$SUMMARY_FILE" | jq -e '.outcome == "failed"' >/dev/null
rc=0
exit_ladder > "$FIXTURE/hint" || rc=$?
test "$rc" = 1
test "$(grep -c '^RESUME_HINT$' "$FIXTURE/hint")" = 1
printf 'PASS: failed delivery preserves evidence and reports; status, attempt, event and exit agree\n'

# Fresh resume restores completed work, retries delivery and clears its failure.
rm "$OUTPUT_DIR/generic"
mv "$FIXTURE/saved-generic" "$OUTPUT_DIR/generic"
REPOLENS_FINAL_STATE=finished RUN_ROUNDS_RC=0 ROUNDS_FAILURE_REASON=''
LENSES=(generic/probe)
run_rounds 1 LENSES
optional_local_finalization
test "$(sha256sum "${saved[@]}")" = "$before"
test "$GLOBAL_ISSUES_CREATED" = 1
jq -e '.totals.issues_created == 1 and (.stopped_reason // "") == ""' "$SUMMARY_FILE" >/dev/null
attempts_finalize "$LOG_BASE" "$REPOLENS_FINAL_STATE" "$(resolve_why_stopped)" "$(resolve_run_exit_code)"
jq -e 'last | .status == "finished" and .exit_code == 0 and .why_stopped == ""' "$LOG_BASE/attempts.json" >/dev/null
record_status
jq -e '.state == "finished" and .stopped_reason == null and .attempts[-1].status == "finished"' "$LOG_BASE/status.json" >/dev/null
write_latest_result_pointer "$FIXTURE" "$RUN_ID" "$MODE" mock "$SUMMARY_FILE" "$REPOLENS_FINAL_STATE" "$LOG_BASE/final"
jq -e '.status == "finished"' "$FIXTURE/latest-result.json" >/dev/null
exit_ladder > "$FIXTURE/hint"
test ! -s "$FIXTURE/hint"
printf 'PASS: successful resume retries publication without investigators or double counting\n'

# Keep an earlier operational failure's code and reason when delivery also fails.
(
  REPOLENS_FINAL_STATE=failed RUN_ROUNDS_RC=7 ROUNDS_FAILURE_REASON=verifier-preparation-failed
  set_stop_reason "$SUMMARY_FILE" "$ROUNDS_FAILURE_REASON"
  export_generic_local_findings() { return 1; }
  optional_local_finalization
  test "$(resolve_run_exit_code)" = 7
  test "$(resolve_why_stopped)" = verifier-preparation-failed
)
clear_stop_reason "$SUMMARY_FILE"

# A parent signal accepted during the publisher takes precedence over failure.
export_generic_local_findings() {
  REPOLENS_FINAL_STATE=interrupted REPOLENS_INTERRUPT_EXIT_CODE=143
  return 1
}
optional_local_finalization
test "$REPOLENS_FINAL_STATE" = interrupted
test "$(resolve_run_exit_code)" = 143
test "$(resolve_why_stopped)" = interrupted-sigterm
test "$(sha256sum "${saved[@]}")" = "$before"
rc=0
exit_ladder > "$FIXTURE/hint" || rc=$?
test "$rc" = 143
test "$(grep -c '^RESUME_HINT$' "$FIXTURE/hint")" = 1
printf 'PASS: delivery failure preserves interruption precedence\n'
