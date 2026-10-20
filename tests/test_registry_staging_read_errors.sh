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
# Root may bypass mode bits. Re-exec with both DAC read bypass capabilities
# removed so the real denied-open regressions remain active in root runners.
# Use the checkout owner so private parent directories remain traversable.
touch "$FIXTURE/permission-probe"
chmod 000 "$FIXTURE/permission-probe"
if [[ -r "$FIXTURE/permission-probe" ]]; then
  if (( EUID == 0 )) && [[ "${REPOLENS_TEST_DAC_DROPPED:-0}" != 1 ]] \
      && command -v setpriv >/dev/null 2>&1; then
    rm -rf -- "$FIXTURE"
    export REPOLENS_TEST_DAC_DROPPED=1
    exec setpriv --bounding-set=-dac_override,-dac_read_search \
      --inh-caps=-dac_override,-dac_read_search \
      --ambient-caps=-dac_override,-dac_read_search \
      --reuid="$(stat -c %u "$REPO")" --regid="$(stat -c %g "$REPO")" \
      --clear-groups \
      bash "${BASH_SOURCE[0]}" "$@"
  fi
  printf 'Cannot exercise denied opens: mode-000 files remain readable; root requires setpriv to drop DAC read bypass capabilities.\n' >&2
  exit 1
fi
rm "$FIXTURE/permission-probe"
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
# Revoke access after the real assembly rename, immediately before validation.
# A failed input redirection must never authorize promotion of that candidate.
LOG_BASE="$FIXTURE/validator/run"
local_dir="$FIXTURE/validator/findings"
mkdir -p "$LOG_BASE/final" "$local_dir"
printf -- '---\ntitle: Saved validator finding\nseverity: high\ndomain: code\nlens: correctness\n---\nEvidence\n' > "$local_dir/one.md"
build_finding_registry fixture "$local_dir"
_registry_ready=true
triage
for artifact in "${artifacts[@]}"; do
  hashes["$artifact"]="$(sha256sum < "$LOG_BASE/final/$artifact")"
done
cp "$LOG_BASE/final/findings.jsonl" "$FIXTURE/unreadable.jsonl"
chmod 000 "$FIXTURE/unreadable.jsonl"
check 'standalone permission fault prevents reading' test ! -r "$FIXTURE/unreadable.jsonl"
rc=0
validate_findings_jsonl "$FIXTURE/unreadable.jsonl" > "$LOG_BASE/validate.log" 2>&1 || rc=$?
check 'standalone validator rejects an unreadable registry' test "$rc" -ne 0
chmod 600 "$FIXTURE/unreadable.jsonl"
printf -- '---\ntitle: Replacement validator finding\nseverity: high\ndomain: code\nlens: correctness\n---\nEvidence\n' > "$local_dir/one.md"
# shellcheck disable=SC2329 # Called indirectly by the production registry builder.
mv() {
  command mv "$@" || return $?
  if [[ "${1:-}" == "$LOG_BASE/final/findings.jsonl.tmp.$$.dedup" ]]; then
    : > "$LOG_BASE/validation-read-reached"
    chmod 000 "$2"
    if [[ ! -r "$2" ]]; then : > "$LOG_BASE/validation-read-denied"; fi
  fi
}
rc=0
build_finding_registry fixture "$local_dir" > "$LOG_BASE/rebuild.log" 2>&1 || rc=$?
unset -f mv
check 'validator input fault was reached after assembly' test -e "$LOG_BASE/validation-read-reached"
check 'staged permission fault prevents reading' test -e "$LOG_BASE/validation-read-denied"
check 'unreadable candidate fails registry rebuilding' test "$rc" -ne 0
check 'failed validation leaves the published registry readable' test -r "$LOG_BASE/final/findings.jsonl"
# Restore permissions only so a red-phase replacement can be compared/removed.
chmod 600 "$LOG_BASE/final/findings.jsonl"
_registry_ready=false
triage
for artifact in "${artifacts[@]}"; do
  check "failed validation preserves $artifact" same_bytes "$LOG_BASE/final/$artifact" "${hashes[$artifact]}"
done
check 'failed validation cleans candidate stages' test "$(command find "$LOG_BASE/final" -name '*.tmp.*' | wc -l)" -eq 0
build_finding_registry fixture "$local_dir"
_registry_ready=true
triage
check 'repaired validator publishes current findings' jq -se 'length == 1 and .[0].title == "Replacement validator finding"' "$LOG_BASE/final/findings.jsonl"
printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
test "$FAIL" -eq 0
