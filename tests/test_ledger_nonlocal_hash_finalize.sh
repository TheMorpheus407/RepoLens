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

# Exercise the real finalization block without dispatching models or forge calls.
# shellcheck disable=SC2317,SC2329
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/lib/ledger.sh"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
FAIL=0
check() {
  if "$@"; then printf 'PASS: %s\n' "$*"; else printf 'FAIL: %s\n' "$*"; FAIL=$((FAIL + 1)); fi
}
# Extract production control flow, including both registry hooks and consumers.
awk '/^# --- Finding registry \(non-fatal\)/ { copy=1 }
     /^# Persist required delivery failure/ { exit }
     copy { print }' "$ROOT/repolens.sh" > "$fixture/finalize.sh"
check test -s "$fixture/finalize.sh"
log_info() { :; }
log_warn() { printf '%s\n' "$*" >> "$fixture/warnings"; }
finalize_summary() { :; }
# Consumers record which registry they read, and replace a report like the real
# writers. Invoking any of them on the saved registry is the regression.
record_consumer() {
  printf '%s: %s\n' "$1" "$(jq -r .title "$TRIAGE_FINDINGS")" >> "$fixture/consumers"
  printf 'new report\n' > "$LOG_BASE/final/$1"
}
generate_todo_md() { record_consumer TODO.md; }
generate_summary_md() { record_consumer SUMMARY.md; }
generate_needs_review_md() { record_consumer NEEDS_REVIEW.md; }
generate_duplicates_md() { record_consumer DUPLICATES.md; }
render_human_review_digest() { record_consumer HUMAN_REVIEW.md; }
human_review_heldback_summary() { record_consumer heldback; }
# Globals below are consumed by the extracted production block.
# shellcheck disable=SC2034
run_finalize() (
  LOCAL_MODE=false
  MODE=audit
  RUN_ID=probe
  SUMMARY_FILE="$fixture/summary.json"
  OUTPUT_DIR=""
  OUTPUT_DIR_SET=false
  HUMAN_REVIEW=true
  REPOLENS_FINAL_STATE="${1:-finished}"
  RUN_ROUNDS_RC=0
  # shellcheck source=/dev/null
  source "$fixture/finalize.sh"
  [[ "$REPOLENS_FINAL_STATE" == "${1:-finished}" && "$RUN_ROUNDS_RC" -eq 0 ]]
)
LOG_BASE="$fixture/logs"
mkdir -p "$LOG_BASE/final"
printf '[{"title":"saved finding","severity":"high","domain":"security","lens":"injection"}]\n' > "$LOG_BASE/final/manifest.json"
build_finding_registry probe || exit 1
cp "$LOG_BASE/final/findings.jsonl" "$fixture/registry.before"
cp "$LOG_BASE/final/findings.csv" "$fixture/csv.before"
reports=(TODO.md SUMMARY.md NEEDS_REVIEW.md DUPLICATES.md HUMAN_REVIEW.md)
for report in "${reports[@]}"; do printf 'saved report\n' > "$LOG_BASE/final/$report"; done
printf 'saved report\n' > "$fixture/report.before"
printf '[{"title":"current finding","severity":"high","domain":"security","lens":"injection"}]\n' > "$LOG_BASE/final/manifest.json"
sha256sum() { cat >/dev/null; printf '%064d\n' 0; return 71; }
check run_finalize
check test -s "$fixture/warnings"
check test ! -e "$fixture/consumers"
check cmp "$fixture/registry.before" "$LOG_BASE/final/findings.jsonl"
check cmp "$fixture/csv.before" "$LOG_BASE/final/findings.csv"
for report in "${reports[@]}"; do check cmp "$fixture/report.before" "$LOG_BASE/final/$report"; done
unset -f sha256sum
# An interrupted invocation and a missing source also cannot refresh saved data.
rm -f "$fixture/consumers"
check run_finalize interrupted
check test ! -e "$fixture/consumers"
mv "$LOG_BASE/final/manifest.json" "$fixture/manifest.json"
check run_finalize
check test ! -e "$fixture/consumers"
mv "$fixture/manifest.json" "$LOG_BASE/final/manifest.json"
# Repairing the hash backend permits all consumers to read the new registry.
rm -f "$fixture/consumers"
check run_finalize
check test "$(wc -l < "$fixture/consumers")" -eq 6
check test "$(jq -r .title "$LOG_BASE/final/findings.jsonl")" = 'current finding'
check test "$(sort -u "$fixture/consumers" | sed 's/^[^:]*: //' | sort -u)" = 'current finding'
for report in "${reports[@]}"; do check test "$(cat "$LOG_BASE/final/$report")" = 'new report'; done
# Fresh failures publish neither registry nor reports.
LOG_BASE="$fixture/fresh"
mkdir -p "$LOG_BASE/final"
cp "$fixture/logs/final/manifest.json" "$LOG_BASE/final/manifest.json"
rm -f "$fixture/consumers"
sha256sum() { cat >/dev/null; return 71; }
check run_finalize
check test ! -e "$fixture/consumers"
check test ! -e "$LOG_BASE/final/findings.jsonl"
check test ! -e "$LOG_BASE/final/findings.csv"
for report in "${reports[@]}"; do check test ! -e "$LOG_BASE/final/$report"; done
printf 'Results: %s failed\n' "$FAIL"
(( FAIL == 0 ))
