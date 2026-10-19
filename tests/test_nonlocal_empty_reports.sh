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
for lib in ledger artifacts human_review; do
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
check() {
  if ! "$@"; then printf 'FAIL: %s\n' "$*"; failed=$((failed + 1)); fi
}
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
printf 'Empty non-local reports: %s failures\n' "$failed"
(( failed == 0 ))
