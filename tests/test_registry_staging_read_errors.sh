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

# repolens-r10-p2-1: staged-source IO errors cannot publish a partial registry.
# shellcheck disable=SC2034 # The extracted production caller consumes globals.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for lib in core ledger artifacts; do
  # shellcheck source=/dev/null
  source "$REPO/lib/$lib.sh"
done
set -euo pipefail
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
PASS=0 FAIL=0
# Record every assertion, including independent publication boundaries.
check() {
  local desc="$1"; shift
  if "$@"; then PASS=$((PASS + 1))
  else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$desc"; fi
}
# Quiet logs from the real triage block; warnings remain visible in case logs.
log_info() { :; }
log_warn() { printf '%s\n' "$*" >&2; }
# Exercise the actual success/empty-registry gates without launching the CLI.
triage() {
  # shellcheck source=/dev/null
  source <(sed -n '/^# --- Human-triage artifacts/,/^# --- Human review digest/p' "$REPO/repolens.sh" | sed '$d')
}
# Hash comparison proves preservation of exact bytes without extra snapshots.
same_bytes() { [[ -f "$1" && "$(sha256sum < "$1")" == "$2" ]]; }
# Fail only the final append from a successfully produced staged source.
cat() {
  if [[ "${1:-}" == "$LOG_BASE/final/.fr-$fault_stage."* ]]; then
    : > "$LOG_BASE/stage-read"
    [[ "$payload" != partial ]] || command head -n 1 -- "$1"
    printf 'injected staged source read failure\n' >&2
    return 42
  fi
  command cat "$@"
}
for scenario in manifest-empty manifest-partial local-empty local-partial combined-local-partial; do
  LOG_BASE="$FIXTURE/$scenario/run"
  local_dir=""
  spec="${scenario#combined-}"
  stage="${spec%-*}" payload="${spec##*-}" fault_stage=none
  MODE=audit LOCAL_MODE=true REPOLENS_FINAL_STATE=finished
  mkdir -p "$LOG_BASE/final"
  if [[ "$stage" == manifest || "$scenario" == combined-* ]]; then
    printf '[{"cluster_id":"C1","title":"First manifest finding","severity":"high","domain":"security","lens":"injection"},{"cluster_id":"C2","title":"Second manifest finding","severity":"high","domain":"security","lens":"injection"}]\n' > "$LOG_BASE/final/manifest.json"
  fi
  if [[ "$stage" == local ]]; then
    local_dir="$FIXTURE/$scenario/findings"
    mkdir -p "$local_dir"
    for n in 1 2; do
      printf -- '---\ntitle: Local finding %s\nseverity: high\ndomain: code\nlens: correctness\n---\nEvidence\n' "$n" > "$local_dir/$n.md"
    done
  fi
  build_finding_registry fixture "$local_dir"
  before_count="$(jq -s length "$LOG_BASE/final/findings.jsonl")"
  _registry_ready=true
  triage
  artifacts=(findings.jsonl findings.csv TODO.md SUMMARY.md NEEDS_REVIEW.md DUPLICATES.md)
  declare -A hashes=()
  for artifact in "${artifacts[@]}"; do
    hashes["$artifact"]="$(sha256sum < "$LOG_BASE/final/$artifact")"
  done
  fault_stage="$stage" rc=0
  build_finding_registry fixture "$local_dir" > "$LOG_BASE/rebuild.log" 2>&1 || rc=$?
  check "$scenario reports a failed rebuild" test "$rc" -ne 0
  check "$scenario reaches staged-source read" test -e "$LOG_BASE/stage-read"
  _registry_ready=false
  if (( rc == 0 )); then _registry_ready=true; fi
  triage
  for artifact in "${artifacts[@]}"; do
    check "$scenario preserves $artifact" same_bytes "$LOG_BASE/final/$artifact" "${hashes[$artifact]}"
  done
  check "$scenario cleans staging" test "$(command find "$LOG_BASE/final" -type f     \( -name '.fr-*' -o -name '*.tmp.*' \) | wc -l)" -eq 0
  # A repaired read must refresh current findings rather than pin old output.
  fault_stage=none
  if [[ "$stage" == manifest ]]; then
    printf '[{"cluster_id":"C1","title":"First manifest finding","severity":"high","domain":"security","lens":"injection"}]\n' > "$LOG_BASE/final/manifest.json"
  else
    rm "$local_dir/2.md"
  fi
  build_finding_registry fixture "$local_dir"
  _registry_ready=true
  triage
  check "$scenario retry refreshes the registry" test "$(jq -s length "$LOG_BASE/final/findings.jsonl")" -eq "$((before_count - 1))"
done
printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
test "$FAIL" -eq 0
