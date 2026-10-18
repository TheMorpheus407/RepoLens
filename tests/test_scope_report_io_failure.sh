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

# repolens-r14-p7-2: failed rejection aggregation preserves saved publications.
# shellcheck disable=SC2034,SC2317,SC2329
set -euo pipefail
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO/lib/synthesize.sh"
set -euo pipefail
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
MODE=branch-review AGENT=stub ROUNDS=1 REPOLENS_FINAL_STATE=finished
LOG_BASE="$FIXTURE/run" PROJECT_PATH="$FIXTURE/project"
mkdir -p "$LOG_BASE/rounds/round-1/lens-outputs/security" "$LOG_BASE/final" "$PROJECT_PATH"
printf '["src/changed.sh"]\n' > "$LOG_BASE/branch-scope.json"
printf 'src/changed.sh:1\n' > "$LOG_BASE/rounds/round-1/lens-outputs/security/finding.md"
printf '[{"cluster_id":"new","title":"New finding","severity":"high","domain":"security","lens":"injection","root_cause_category":"validation","source_finding_paths":["finding.md"],"dedup_against_existing":[],"proposed_labels":[],"cross_link_actions":[],"granularity":"independent","body":"src/unchanged.sh:1"}]\n' > "$LOG_BASE/proposal.json"
printf '[{"cluster_id":"saved"}]\n' > "$LOG_BASE/final/manifest.json"
printf '[{"cluster_id":"saved","body":"old action"}]\n' > "$LOG_BASE/final/cross-link-actions.preserved.json"
printf '[{"finding":{"cluster_id":"previous"},"reason":"old rejection"}]\n' > "$LOG_BASE/final/manifest.json.out-of-scope.json"
cp "$LOG_BASE/final/manifest.json" "$FIXTURE/manifest-before"
cp "$LOG_BASE/final/cross-link-actions.preserved.json" "$FIXTURE/actions-before"
cp "$LOG_BASE/final/manifest.json.out-of-scope.json" "$FIXTURE/report-before"
compose_prompt() { printf 'mock prompt\n'; }
run_agent() { cat "$LOG_BASE/proposal.json"; }
fault=report
jq() {
  if [[ "$fault" == report && "${1:-}" == -s && "${2:-}" == . && "${3:-}" == *.scope.*.rejected ]]; then
    printf 'hit\n' >> "$FIXTURE/report-fault-hit"
    printf '{"partial":'
    return 74
  fi
  command jq "$@"
}
FAIL=0
check() {
  if "$@"; then printf 'PASS: %s\n' "$*"; else printf 'FAIL: %s\n' "$*"; FAIL=$((FAIL + 1)); fi
}
rc=0
run_synthesizer fixture > "$FIXTURE/failed.log" 2>&1 || rc=$?
check test "$rc" -eq 5
check test -s "$FIXTURE/report-fault-hit"
check cmp "$FIXTURE/manifest-before" "$LOG_BASE/final/manifest.json"
check cmp "$FIXTURE/actions-before" "$LOG_BASE/final/cross-link-actions.preserved.json"
check cmp "$FIXTURE/report-before" "$LOG_BASE/final/manifest.json.out-of-scope.json"
check jq -e 'length == 1 and .[0].cluster_id == "new" and .[0].body == "src/unchanged.sh:1"' "$LOG_BASE/final/manifest.scope-pending.json"
check test -z "$(command find "$LOG_BASE/final" -name '*.scope.*' -print)"
# A repaired retry completes the rejection and publishes a valid empty manifest.
fault=none
check run_synthesizer fixture
check jq -e 'length == 0' "$LOG_BASE/final/manifest.json"
check jq -e 'length == 1 and .[0].finding.cluster_id == "new"' "$LOG_BASE/final/manifest.json.out-of-scope.json"
check test -z "$(command find "$LOG_BASE/final" -name '*.scope.*' -print)"
printf 'Results: %s failed\n' "$FAIL"
(( FAIL == 0 ))
