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

# repolens-r14-p7-2: report IO failures preserve saved publications for retry.
# shellcheck disable=SC2034,SC2317,SC2329
set -euo pipefail
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO/lib/synthesize.sh"
set -euo pipefail
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
MODE=branch-review AGENT=stub ROUNDS=1 REPOLENS_FINAL_STATE=finished
PROJECT_PATH="$FIXTURE/project"
# Seed independent saved publications and an out-of-scope proposal per case.
fresh() {
  LOG_BASE="$FIXTURE/$1"
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
}
# Keep synthesis deterministic without model or forge calls.
compose_prompt() { printf 'mock prompt\n'; }
run_agent() { cat "$LOG_BASE/proposal.json"; }
# Inject partial aggregation output, or a planted predictable sibling stage.
jq() {
  if [[ "$fault" == report && "${1:-}" == -s && "${2:-}" == . && "${3:-}" == *.scope.*.rejected* ]]; then
    printf 'hit\n' >> "$FIXTURE/report-fault-hit"
    printf '{"partial":'
    return 74
  fi
  if [[ "$fault" == symlink-* && "${FUNCNAME[1]:-}" == branch_scope_filter_manifest && "${1:-}" == -c && "${2:-}" == '.[]' ]]; then
    local kept_stage
    kept_stage="$(command find "$LOG_BASE/final" -maxdepth 1 -type f -name '*.scope.??????' -print -quit)"
    [[ -n "$kept_stage" ]] || return 1
    ln -s "$FIXTURE/victim" "$kept_stage.${fault#symlink-}"
    printf '%s\n' "$kept_stage.${fault#symlink-}" > "$FIXTURE/planted-stage"
  fi
  command jq "$@"
}
# Fail allocation of each rejection stage without consuming saved results.
mktemp() {
  if [[ ( "$fault" == allocation && "${1:-}" == *.report.XXXXXX ) ||
        ( "$fault" == rejected-allocation && "${1:-}" == *.rejected.XXXXXX ) ]]; then
    printf 'hit\n' >> "$FIXTURE/$fault-fault-hit"
    return 74
  fi
  command mktemp "$@"
}
# Exercise the real caller's retry branch after successful report aggregation.
eval "$(declare -f _branch_scope_replace_file | sed '1s/_branch_scope_replace_file/original_replace_file/')"
_branch_scope_replace_file() {
  if [[ "$fault" == rollback && ( "$2" == "$LOG_BASE/final/manifest.json.tmp.probe" || "$1" == *.report-backup.* ) ]]; then
    return 74
  fi
  if [[ "$fault" == replacement && "$2" == "$LOG_BASE/final/manifest.json.out-of-scope.json" ]]; then
    command jq -e 'length == 1 and .[0].finding.cluster_id == "new"' "$1" > /dev/null || return 1
    printf 'hit\n' >> "$FIXTURE/replacement-fault-hit"
    return 74
  fi
  original_replace_file "$@"
}
FAIL=0
# Accumulate assertions so injected failures expose every changed publication.
check() {
  if "$@"; then printf 'PASS: %s\n' "$*"; else printf 'FAIL: %s\n' "$*"; FAIL=$((FAIL + 1)); fi
}
for fault in report replacement allocation rejected-allocation; do
  fresh "$fault"
  rc=0
  run_synthesizer fixture > "$FIXTURE/failed.log" 2>&1 || rc=$?
  check test "$rc" -eq 5
  check test -s "$FIXTURE/$fault-fault-hit"
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
  check test ! -e "$LOG_BASE/final/manifest.scope-pending.json"
done
# A process able to plant a sibling of the visible kept stage must not cause
# report redirection to overwrite another file or publish a symlink.
for fault in symlink-report symlink-rejected; do
  fresh "$fault"
  printf 'untouched victim\n' > "$FIXTURE/victim"
  cp "$FIXTURE/victim" "$FIXTURE/victim-before"
  candidate="$LOG_BASE/final/manifest.json.tmp.probe"
  cp "$LOG_BASE/proposal.json" "$candidate"
  check branch_scope_filter_manifest "$candidate"
  check test -s "$FIXTURE/planted-stage"
  check cmp "$FIXTURE/victim-before" "$FIXTURE/victim"
  check test ! -L "$LOG_BASE/final/manifest.json.out-of-scope.json"
  check jq -e 'length == 1 and .[0].finding.cluster_id == "new"' "$LOG_BASE/final/manifest.json.out-of-scope.json"
  # Remove the attacker-owned path separately from the filter's owned stages.
  rm -f -- "$(cat "$FIXTURE/planted-stage")"
  check test -z "$(command find "$LOG_BASE/final" -name '*.scope.*' -print)"
done
# The candidate may be readable JSON through a symlink even though the exact
# replacement helper refuses that destination. Its target and the saved report
# must survive this failure, then a repaired regular candidate can be retried.
fault=none
fresh candidate-symlink
candidate="$LOG_BASE/final/manifest.json.tmp.probe"
ln -s "$LOG_BASE/proposal.json" "$candidate"
cp "$LOG_BASE/proposal.json" "$FIXTURE/proposal-before"
rc=0
branch_scope_filter_manifest "$candidate" || rc=$?
check test "$rc" -eq 2
check test -L "$candidate"
check cmp "$FIXTURE/proposal-before" "$LOG_BASE/proposal.json"
check cmp "$FIXTURE/manifest-before" "$LOG_BASE/final/manifest.json"
check cmp "$FIXTURE/actions-before" "$LOG_BASE/final/cross-link-actions.preserved.json"
check cmp "$FIXTURE/report-before" "$LOG_BASE/final/manifest.json.out-of-scope.json"
check test -z "$(command find "$LOG_BASE/final" -name '*.scope.*' -print)"
rm "$candidate"
cp "$LOG_BASE/proposal.json" "$candidate"
check branch_scope_filter_manifest "$candidate"
check jq -e 'length == 0' "$candidate"
check jq -e 'length == 1 and .[0].finding.cluster_id == "new"' "$LOG_BASE/final/manifest.json.out-of-scope.json"
check test -z "$(command find "$LOG_BASE/final" -name '*.scope.*' -print)"
# If candidate replacement and report restoration both fail, retain the saved
# report bytes and name their exact recovery path rather than deleting them.
fault=rollback
fresh rollback
candidate="$LOG_BASE/final/manifest.json.tmp.probe"
cp "$LOG_BASE/proposal.json" "$candidate"
rc=0
branch_scope_filter_manifest "$candidate" 2> "$FIXTURE/rollback.stderr" || rc=$?
check test "$rc" -eq 2
check cmp "$LOG_BASE/proposal.json" "$candidate"
backup="$(command find "$LOG_BASE/final" -name '*.report-backup.*' -type f -print)"
check test -n "$backup"
check cmp "$FIXTURE/report-before" "$backup"
check grep -Fq "saved report retained at $backup" "$FIXTURE/rollback.stderr"
fault=none
check _branch_scope_replace_file "$backup" "$LOG_BASE/final/manifest.json.out-of-scope.json"
check branch_scope_filter_manifest "$candidate"
check test -z "$(command find "$LOG_BASE/final" -name '*.scope.*' -print)"
# Never open a FIFO as a report backup source: it has no finite saved bytes.
fresh report-fifo
candidate="$LOG_BASE/final/manifest.json.tmp.probe"
cp "$LOG_BASE/proposal.json" "$candidate"
rm "$LOG_BASE/final/manifest.json.out-of-scope.json"
mkfifo "$LOG_BASE/final/manifest.json.out-of-scope.json"
rc=0
branch_scope_filter_manifest "$candidate" || rc=$?
check test "$rc" -eq 2
check test -p "$LOG_BASE/final/manifest.json.out-of-scope.json"
check cmp "$LOG_BASE/proposal.json" "$candidate"
check test -z "$(command find "$LOG_BASE/final" -name '*.scope.*' -print)"
printf 'Results: %s failed\n' "$FAIL"
(( FAIL == 0 ))
