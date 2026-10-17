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


# Real wave driver, run_lens, exporter and accounting; local agent fixture only.
# shellcheck disable=SC2034,SC2329 # Production callbacks consume fixture globals.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source <(awk '/^LOG_BASE=/ {exit} /^REPO=/ {next} {print}' "$REPO/tests/test_generic_explicit_output.sh")
# Restore real ordinary-lens counting instead of the shared fixture's zero stub.
# shellcheck source=/dev/null
source "$REPO/lib/streak.sh"
initialize_counts() {
  # Exercise the actual CLI startup, not a copy of its resume decision.
  # shellcheck source=/dev/null
  source <(awk '/^GLOBAL_ISSUES_CREATED=0$/ {copy=1} copy && /^if \[\[ "\$MODE" == branch-review/ {exit} copy {print}' "$REPO/repolens.sh")
}
eval "$(declare -f run_agent | sed '1s/run_agent/budget_fixture_agent/')"
# shellcheck disable=SC2154 # domain is dynamically scoped by production run_lens.
run_agent() {
  [[ "${domain:-}" != generic ]] || printf 'called\n' >> "$LOG_BASE/generic-calls"
  budget_fixture_agent "$@" || return $?
  if [[ "$scenario" == multi && "${domain:-}" == generic ]]; then
    local raw text
    raw="$(tail -n 1 "$LOG_BASE/finding-paths")"
    text="$(cat "$raw")"
    printf '%s\n' "${text//Mock finding./Second independent finding.}" >> "$raw"
  fi
}
for scenario in ${1:-seeds multi mixed unlimited}; do
  (
    LOG_BASE="$FIXTURE/$scenario/run" OUTPUT_DIR="$FIXTURE/$scenario/output" PROJECT_PATH="$FIXTURE/project"
    SUMMARY_FILE="$LOG_BASE/summary.json" HEARTBEAT_DIR="$LOG_BASE/.heartbeats"
    completed_lenses_file="$LOG_BASE/.completed"
    OUTPUT_DIR_SET=true ROUNDS=2 STRATEGY=waves LOCAL_MODE=true PARALLEL=false
    GLOBAL_ISSUES_CREATED=0 HUMAN_REVIEW=true REPOLENS_FINAL_STATE=finished MAX_ISSUES=1
    expected=1
    [[ "$scenario" != mixed ]] || { MAX_ISSUES=2; expected=2; }
    [[ "$scenario" != unlimited ]] || { MAX_ISSUES=''; expected=2; }
    mkdir -p "$LOG_BASE/triage" "$OUTPUT_DIR" "$PROJECT_PATH" "$HEARTBEAT_DIR"
    printf 'First independent defect\nSecond independent defect\n' > "$LOG_BASE/triage/investigation-seeds.txt"
    : > "$completed_lenses_file"
    : > "$LOG_BASE/agent-calls"
    : > "$LOG_BASE/generic-calls"
    init_summary "$SUMMARY_FILE" probe "$PROJECT_PATH" bugreport mock '' "$MAX_ISSUES" local "$OUTPUT_DIR"
    if [[ "$scenario" == mixed ]]; then
      mkdir -p "$OUTPUT_DIR/security/injection"
      printf -- '---\ntitle: Static authorization failure\nseverity: high\ndomain: security\nlens: injection\n---\nEvidence: src/account.sh:1\n' > "$OUTPUT_DIR/security/injection/001.md"
      record_lens "$SUMMARY_FILE" security injection 1 completed 1 0
      GLOBAL_ISSUES_CREATED=1
    fi
    LENSES=(security/injection)
    initialize_counts
    run_rounds 2 LENSES
    test ! -e "$LOG_BASE/final/generic-delivery.json"
    optional_local_finalization
    files="$(find "$OUTPUT_DIR" -name '*.md' -type f | wc -l)"
    calls="$(wc -l < "$LOG_BASE/generic-calls")"
    printf 'scenario=%s cap=%s delivered=%s global=%s summary=%s investigator_calls=%s\n' "$scenario" "${MAX_ISSUES:-unlimited}" "$files" "$GLOBAL_ISSUES_CREATED" "$(jq .totals.issues_created "$SUMMARY_FILE")" "$calls"
    test "$files" -eq "$expected"
    test "$GLOBAL_ISSUES_CREATED" -eq "$expected"
    test "$(jq .totals.issues_created "$SUMMARY_FILE")" -eq "$expected"
    if [[ "$scenario" == unlimited ]]; then test "$calls" -eq 2; else test "$calls" -eq 1; fi
    # Counting and publication must share the segment cap, even if one agent
    # emits several findings. Raw evidence is retained for a later higher cap.
    if [[ "$scenario" == multi ]]; then
      test "$(grep -c '^## hypothesis' "$(head -n 1 "$LOG_BASE/finding-paths")")" -eq 2
    fi
    if [[ "$scenario" == seeds ]]; then
      before="$(sha256sum "$SUMMARY_FILE" "$LOG_BASE/final/"{findings.jsonl,generic-delivery.json})"
      find() {
        [[ "$1" != -H || "$2" != "$LOG_BASE/rounds" ]] || return 74
        command find "$@"
      }
      rc=0
      reconcile_generic_local_counts || rc=$?
      test "$rc" -ne 0
      test "$(sha256sum "$SUMMARY_FILE" "$LOG_BASE/final/"{findings.jsonl,generic-delivery.json})" = "$before"
      unset -f find
    fi
    # Repair lost counters from the saved plan without re-running investigators.
    jq '.totals.issues_created=0' "$SUMMARY_FILE" > "$LOG_BASE/reset.json"
    mv "$LOG_BASE/reset.json" "$SUMMARY_FILE"
    GLOBAL_ISSUES_CREATED=0
    initialize_counts
    initialize_counts
    test "$GLOBAL_ISSUES_CREATED" -eq "$expected"
    test "$(jq .totals.issues_created "$SUMMARY_FILE")" -eq "$expected"
    run_rounds 2 LENSES
    optional_local_finalization
    test "$(wc -l < "$LOG_BASE/generic-calls")" -eq "$calls"
    test "$(find "$OUTPUT_DIR" -name '*.md' -type f | wc -l)" -eq "$expected"
    test "$(jq .totals.issues_created "$SUMMARY_FILE")" -eq "$expected"
    if [[ "$scenario" == seeds ]]; then
      MAX_ISSUES=2
      reconcile_generic_local_counts
      run_rounds 2 LENSES
      optional_local_finalization
      test "$(wc -l < "$LOG_BASE/generic-calls")" -eq 2
      test "$(find "$OUTPUT_DIR" -name '*.md' -type f | wc -l)" -eq 2
      test "$GLOBAL_ISSUES_CREATED" -eq 2
      test "$(jq .totals.issues_created "$SUMMARY_FILE")" -eq 2
    fi
    printf 'PASS: shared Generic budget and idempotent accounting: %s\n' "$scenario"
  )
done
