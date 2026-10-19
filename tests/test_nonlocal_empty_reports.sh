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

# A successful empty non-local rebuild retires reports from the previous run.
# shellcheck disable=SC2034,SC2317,SC2329 # Extracted finalization uses fixture globals.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for lib in ledger artifacts human_review summary; do
  # shellcheck source=/dev/null
  source "$REPO/lib/$lib.sh"
done
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
awk '/^# --- Finding registry \(non-fatal\)/ { copy=1 }
     /^# Persist required delivery failure/ { exit }
     copy { print }' "$REPO/repolens.sh" > "$FIXTURE/finalize.sh"
# Logging and summary persistence are outside the report reconciliation scope.
log_info() { :; }
log_warn() { printf 'WARN: %s\n' "$*" >&2; }
finalize_summary() { :; }
LOG_BASE="$FIXTURE/run" RUN_ID=probe LOCAL_MODE=false MODE=bugreport
OUTPUT_DIR='' OUTPUT_DIR_SET=false HUMAN_REVIEW=false
SUMMARY_FILE="$LOG_BASE/summary.json" RUN_ROUNDS_RC=0 REPOLENS_FINAL_STATE=finished
mkdir -p "$LOG_BASE/final"
failed=0
# Accumulate assertion failures so every preservation boundary is checked.
check() {
  if ! "$@"; then printf 'FAIL: %s\n' "$*"; failed=$((failed + 1)); fi
}
# Execute production finalization against the fixture without dispatching.
finalize() {
  # shellcheck source=/dev/null
  source "$FIXTURE/finalize.sh"
}
printf '%s\n' '[{"title":"Finding removed on resume","severity":"high","domain":"security","lens":"injection"}]' > "$LOG_BASE/final/manifest.json"
check finalize
reports=(TODO.md SUMMARY.md NEEDS_REVIEW.md DUPLICATES.md)
for report in "${reports[@]}"; do
  check test -s "$LOG_BASE/final/$report"
  cp "$LOG_BASE/final/$report" "$FIXTURE/$report"
done
check grep -Fq 'Finding removed on resume' "$LOG_BASE/final/TODO.md"
printf '[]\n' > "$LOG_BASE/final/manifest.json"
# Interruption, missing source and failed rebuild must preserve saved reports.
REPOLENS_FINAL_STATE=interrupted
check finalize
REPOLENS_FINAL_STATE=finished
mv "$LOG_BASE/final/manifest.json" "$FIXTURE/manifest.json"
check finalize
mv "$FIXTURE/manifest.json" "$LOG_BASE/final/manifest.json"
# Fail only CSV publication after the new empty JSONL has been produced.
build_findings_csv() { return 1; }
check finalize
unset -f build_findings_csv
# Restore the original function after the narrowly scoped publication failure.
# shellcheck source=/dev/null
source "$REPO/lib/ledger.sh"
for report in "${reports[@]}"; do
  check cmp "$FIXTURE/$report" "$LOG_BASE/final/$report"
done
check finalize
check test -f "$LOG_BASE/final/findings.jsonl"
check test ! -s "$LOG_BASE/final/findings.jsonl"
for report in "${reports[@]}"; do check test ! -e "$LOG_BASE/final/$report"; done
# Repeated successful empty resumes remain a clean no-op.
check finalize
for report in "${reports[@]}"; do check test ! -e "$LOG_BASE/final/$report"; done
check test "$REPOLENS_FINAL_STATE" = finished
check test "$RUN_ROUNDS_RC" -eq 0
# Each isolated case returns failure; the parent counts failed cases separately.
case_failures=$failed
failed=0

# Failed phases must not consume an older manifest, whether empty or nonempty.
# Extract the actual phase gates so current synthesis acceptance is exercised.
awk '/^# --- Verifier \(post-rounds/ { copy=1 }
     /^# --- Finalize ---/ { exit }
     copy { print }' "$REPO/repolens.sh" > "$FIXTURE/phases.sh"
for failure in rounds verifier synthesis; do
  for saved in empty nonempty; do
    (
      LOG_BASE="$FIXTURE/failed-$failure-$saved"
      SUMMARY_FILE="$LOG_BASE/summary.json"
      ROUNDS=2 NO_VERIFIER=false HUMAN_REVIEW=true
      RUN_ROUNDS_RC=0 REPOLENS_FINAL_STATE=finished
      mkdir -p "$LOG_BASE/final"
      printf '{}\n' > "$SUMMARY_FILE"
      printf '%s\n' '[{"title":"Saved finding","severity":"high","domain":"security","lens":"injection"}]' > "$LOG_BASE/final/manifest.json"
      check finalize
      for report in findings.jsonl findings.csv "${reports[@]}" HUMAN_REVIEW.md; do
        cp "$LOG_BASE/final/$report" "$LOG_BASE/$report.before"
      done
      if [[ "$saved" == empty ]]; then printf '[]\n'; else
        printf '%s\n' '[{"title":"Unaccepted saved manifest","severity":"high","domain":"security","lens":"injection"}]'
      fi > "$LOG_BASE/final/manifest.json"
      run_verifier() { [[ "$failure" != verifier ]] || return 7; }
      run_synthesizer() { return 1; }
      if [[ "$failure" == rounds ]]; then RUN_ROUNDS_RC=1 REPOLENS_FINAL_STATE=failed; fi
      # shellcheck source=/dev/null
      source "$FIXTURE/phases.sh"
      check test "$RUN_ROUNDS_RC" -ne 0
      check finalize
      for report in findings.jsonl findings.csv "${reports[@]}" HUMAN_REVIEW.md; do
        check cmp "$LOG_BASE/$report.before" "$LOG_BASE/final/$report"
      done
      (( failed == 0 ))
    ) || case_failures=$((case_failures + 1))
  done
done

# Accepted current manifests remain usable after later filing/accounting failure.
for failure in filing accounting; do
  for current in empty nonempty; do
    (
      LOG_BASE="$FIXTURE/accepted-$failure-$current"
      SUMMARY_FILE="$LOG_BASE/summary.json"
      ROUNDS=2 NO_VERIFIER=true HUMAN_REVIEW=true MAX_ISSUES=0
      RUN_ROUNDS_RC=0 REPOLENS_FINAL_STATE=finished
      mkdir -p "$LOG_BASE/final/filed"
      printf '{}\n' > "$SUMMARY_FILE"
      printf '%s\n' '[{"cluster_id":"current","title":"Previous finding","severity":"high","domain":"security","lens":"injection"}]' > "$LOG_BASE/final/manifest.json"
      check finalize
      run_synthesizer() {
        if [[ "$current" == empty ]]; then printf '[]\n'; else
          printf '%s\n' '[{"cluster_id":"current","title":"Accepted finding","severity":"high","domain":"security","lens":"injection"}]'
        fi > "$LOG_BASE/final/manifest.json"
      }
      dispatch_filing_batch() { [[ "$failure" != filing ]]; }
      # The filing path is stubbed: no provider or model calls are possible.
      printf 'https://example.invalid/issue/1\n' > "$LOG_BASE/final/filed/current.url"
      # shellcheck source=/dev/null
      source "$FIXTURE/phases.sh"
      if [[ "$failure" == accounting ]]; then
        RUN_ROUNDS_RC=1 REPOLENS_FINAL_STATE=failed
      fi
      check test "$RUN_ROUNDS_RC" -ne 0
      check finalize
      if [[ "$current" == empty ]]; then
        for report in "${reports[@]}"; do check test ! -e "$LOG_BASE/final/$report"; done
        check test ! -s "$LOG_BASE/final/findings.jsonl"
      else
        check grep -Fq 'Accepted finding' "$LOG_BASE/final/TODO.md"
        check grep -Fq 'Accepted finding' "$LOG_BASE/final/HUMAN_REVIEW.md"
      fi
      (( failed == 0 ))
    ) || case_failures=$((case_failures + 1))
  done
done

# Use production's returning handlers; inject each signal after each deletion.
# A signal after the last deletion must restore the set too.
awk '/^_final_signal_generation=0/ { copy=1 }
     /^# Reconcile on failed dispatch too/ { exit }
     copy { print }' "$REPO/repolens.sh" > "$FIXTURE/handlers.sh"
for signal in HUP INT TERM; do
  for boundary in 1 2 3 4; do
    (
      LOG_BASE="$FIXTURE/signal-$signal-$boundary"
      SUMMARY_FILE="$LOG_BASE/summary.json"
      HUMAN_REVIEW=false
      RUN_ROUNDS_RC=0 REPOLENS_FINAL_STATE=finished
      mkdir -p "$LOG_BASE/final"
      printf '%s\n' '[{"title":"Before signal","severity":"high","domain":"security","lens":"injection"}]' > "$LOG_BASE/final/manifest.json"
      check finalize
      for report in "${reports[@]}"; do cp "$LOG_BASE/final/$report" "$LOG_BASE/$report.before"; done
      printf '[]\n' > "$LOG_BASE/final/manifest.json"
      # shellcheck source=/dev/null
      source "$FIXTURE/handlers.sh"
      removed=0
      rm() {
        local arg rc=0
        command rm "$@" || rc=$?
        for arg in "$@"; do
          case "$arg" in
            "$LOG_BASE/final/TODO.md"|"$LOG_BASE/final/SUMMARY.md"|"$LOG_BASE/final/NEEDS_REVIEW.md"|"$LOG_BASE/final/DUPLICATES.md")
              removed=$((removed + 1))
              if (( removed == boundary )); then kill -s "$signal" "$BASHPID"; fi
              ;;
          esac
        done
        return "$rc"
      }
      check finalize
      check test "$REPOLENS_FINAL_STATE" = interrupted
      case "$signal" in HUP) expected_rc=129 ;; INT) expected_rc=130 ;; TERM) expected_rc=143 ;; esac
      check test "$REPOLENS_INTERRUPT_EXIT_CODE" -eq "$expected_rc"
      for report in "${reports[@]}"; do check cmp "$LOG_BASE/$report.before" "$LOG_BASE/final/$report"; done
      (( failed == 0 ))
    ) || case_failures=$((case_failures + 1))
  done
done
# Snapshot/removal failures are non-fatal and preserve files, links and absence.
for failure in snapshot removal; do
  (
    LOG_BASE="$FIXTURE/io-$failure"
    REPOLENS_FINAL_STATE=finished
    mkdir -p "$LOG_BASE/final"
    printf 'Saved todo\n' > "$LOG_BASE/final/TODO.md"
    # A dangling symlink must be restored as a link, never read or followed.
    ln -s missing-target "$LOG_BASE/final/SUMMARY.md"
    printf 'Saved duplicates\n' > "$LOG_BASE/final/DUPLICATES.md"
    cp() {
      if [[ "$failure" == snapshot && "${*: -1}" == */SUMMARY.md ]]; then return 1; fi
      command cp "$@"
    }
    rm() {
      if [[ "$failure" == removal && "${*: -1}" == "$LOG_BASE/final/DUPLICATES.md" ]]; then return 1; fi
      command rm "$@"
    }
    rc=0
    retire_empty_triage_reports "$LOG_BASE/final" || rc=$?
    check test "$rc" -eq 1
    check test "$(cat "$LOG_BASE/final/TODO.md")" = 'Saved todo'
    check test "$(readlink "$LOG_BASE/final/SUMMARY.md")" = missing-target
    check test ! -e "$LOG_BASE/final/NEEDS_REVIEW.md"
    check test "$(cat "$LOG_BASE/final/DUPLICATES.md")" = 'Saved duplicates'
    check test "$REPOLENS_FINAL_STATE" = finished
    check test "$(find "$LOG_BASE/final" -name '.triage-retire.*' | wc -l)" -eq 0
    (( failed == 0 ))
  ) || case_failures=$((case_failures + 1))
done
printf 'Empty non-local reports: %s failures\n' "$case_failures"
(( case_failures == 0 ))
