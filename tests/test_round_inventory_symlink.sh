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

# repolens-r14-p5-4: an explicit rounds-directory symlink is a real inventory.
# shellcheck disable=SC2034,SC2317,SC2329
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/lib/verify.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/synthesize.sh"
set -euo pipefail
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
AGENT=mock MODE=bugreport ROUNDS=1 PROJECT_PATH="$fixture/project"
LOG_BASE="$fixture/run"
mkdir -p "$PROJECT_PATH/src" "$fixture/stored-rounds/round-1/lens-outputs/security/injection" "$LOG_BASE/final"
ln -s "$fixture/stored-rounds" "$LOG_BASE/rounds"
finding="$LOG_BASE/rounds/round-1/lens-outputs/security/injection/001.md"
printf 'query fixture\n' > "$PROJECT_PATH/src/query.sh"
printf -- '---\ntitle: SQL injection in query construction\nseverity: high\ndomain: security\nlens: injection\n---\nEvidence: src/query.sh:1\n' > "$finding"
printf '[{"finding_id":"saved","status":"VERIFIED","notes":"Saved verification"}]\n' > "$LOG_BASE/final/verification.json"
printf '[{"cluster_id":"saved","title":"Saved result"}]\n' > "$LOG_BASE/final/manifest.json"
jq -n --arg source "$finding" '[{cluster_id:"fresh",title:"Fresh symlink finding",severity:"high",domain:"security",lens:"injection",root_cause_category:"injection",source_finding_paths:[$source],cross_link_actions:[],granularity:"independent",verification_status:"verified",body:"Evidence: src/query.sh:1",proposed_labels:[],dedup_against_existing:[]}]' > "$fixture/proposal.json"
: > "$fixture/calls"
compose_prompt() { printf 'mock prompt\n'; }
verify_callback() {
  printf v >> "$fixture/calls"
  printf '[{"finding_id":"fresh-finding","status":"VERIFIED","notes":"Fresh verification"}]\n'
}
_VERIFIER_AGENT_CALLBACK=verify_callback
run_agent() { printf s >> "$fixture/calls"; cat "$fixture/proposal.json"; }
FAIL=0
check() {
  if "$@"; then printf 'PASS: %s\n' "$*"; else printf 'FAIL: %s\n' "$*"; FAIL=$((FAIL + 1)); fi
}
check run_verifier fixture
check jq -e 'length == 1 and .[0].notes == "Fresh verification"' "$LOG_BASE/final/verification.json"
check run_synthesizer fixture
check jq -e 'length == 1 and .[0].title == "Fresh symlink finding"' "$LOG_BASE/final/manifest.json"
check test "$(cat "$fixture/calls")" = vs
# Empty symlink roots still publish canonical empties without admitting agents.
mkdir "$fixture/empty-rounds"
rm "$LOG_BASE/rounds"
ln -s "$fixture/empty-rounds" "$LOG_BASE/rounds"
check run_verifier fixture
check jq -e 'length == 0' "$LOG_BASE/final/verification.json"
check run_synthesizer fixture
check jq -e 'length == 0' "$LOG_BASE/final/manifest.json"
check test "$(cat "$fixture/calls")" = vs
# Existing invalid roots are unavailable inventories, not legitimate empties.
# No model callback or retirement may run until the source is repaired.
for kind in dangling loop file-target regular-file; do
  rm "$LOG_BASE/rounds"
  case "$kind" in
    dangling) ln -s "$fixture/unavailable-rounds" "$LOG_BASE/rounds" ;;
    loop) ln -s rounds "$LOG_BASE/rounds" ;;
    file-target)
      printf 'not an inventory\n' > "$fixture/not-directory"
      ln -s "$fixture/not-directory" "$LOG_BASE/rounds"
      ;;
    regular-file) printf 'not an inventory\n' > "$LOG_BASE/rounds" ;;
  esac
  printf '[{"finding_id":"saved","status":"VERIFIED","notes":"Saved verification"}]\n' > "$LOG_BASE/final/verification.json"
  printf '[{"cluster_id":"saved","title":"Saved result"}]\n' > "$LOG_BASE/final/manifest.json"
  printf '[{"body":"Saved action"}]\n' > "$LOG_BASE/final/cross-link-actions.preserved.json"
  verification_hash="$(sha256sum < "$LOG_BASE/final/verification.json")"
  manifest_hash="$(sha256sum < "$LOG_BASE/final/manifest.json")"
  actions_hash="$(sha256sum < "$LOG_BASE/final/cross-link-actions.preserved.json")"
  vrc=0; run_verifier fixture || vrc=$?
  src=0; run_synthesizer fixture || src=$?
  printf '%s: verification=%s synthesis=%s\n' "$kind" "$vrc" "$src"
  check test "$vrc" -eq 7
  check test "$src" -ne 0
  check test "$(sha256sum < "$LOG_BASE/final/verification.json")" = "$verification_hash"
  check test "$(sha256sum < "$LOG_BASE/final/manifest.json")" = "$manifest_hash"
  check test "$(sha256sum < "$LOG_BASE/final/cross-link-actions.preserved.json")" = "$actions_hash"
  check test "$(cat "$fixture/calls")" = vs
  check test -z "$(find "$LOG_BASE/final" -name '.synthesis-cleanup.*' -print)"
  # Repair to a readable empty directory; successful retries publish empties.
  rm "$LOG_BASE/rounds"
  ln -s "$fixture/empty-rounds" "$LOG_BASE/rounds"
  check run_verifier fixture
  check run_synthesizer fixture
  check jq -e 'length == 0' "$LOG_BASE/final/verification.json"
  check jq -e 'length == 0' "$LOG_BASE/final/manifest.json"
  check test ! -e "$LOG_BASE/final/cross-link-actions.preserved.json"
done
# A genuinely absent root remains a valid empty inventory.
rm "$LOG_BASE/rounds"
check run_verifier fixture
check run_synthesizer fixture
check jq -e 'length == 0' "$LOG_BASE/final/verification.json"
check jq -e 'length == 0' "$LOG_BASE/final/manifest.json"
check test "$(cat "$fixture/calls")" = vs
# Deterministically take a valid symlink target offline after initial validation,
# either just before/after find or during synthesis's intervening scope pass.
race_stage=none
same_bytes() { [[ -f "$1" && "$(sha256sum < "$1")" == "$2" ]]; }
take_rounds_offline() {
  mv "$fixture/stored-rounds" "$fixture/offline-rounds"
  : > "$fixture/race-reached"
}
find() {
  local inventory_root="${1:-}"
  [[ "$inventory_root" != -H ]] || inventory_root="${2:-}"
  if [[ "$inventory_root" == "$LOG_BASE/rounds" ]]; then
    [[ "$race_stage" != find-before ]] || take_rounds_offline
    command find "$@" || return $?
    [[ "$race_stage" != find-after ]] || take_rounds_offline
    return 0
  fi
  command find "$@"
}
branch_scope_filter_directory() {
  [[ "$race_stage" != scope ]] || take_rounds_offline
  return 0
}
for phase in verifier synthesizer; do
  for race_stage in find-before find-after scope; do
    [[ "$race_stage" != scope || "$phase" == synthesizer ]] || continue
    ln -s "$fixture/stored-rounds" "$LOG_BASE/rounds"
    printf '[{"finding_id":"saved","status":"VERIFIED","notes":"Saved verification"}]\n' > "$LOG_BASE/final/verification.json"
    printf '[{"cluster_id":"saved","title":"Saved result"}]\n' > "$LOG_BASE/final/manifest.json"
    printf '[{"body":"Saved action"}]\n' > "$LOG_BASE/final/cross-link-actions.preserved.json"
    verification_hash="$(sha256sum < "$LOG_BASE/final/verification.json")"
    manifest_hash="$(sha256sum < "$LOG_BASE/final/manifest.json")"
    actions_hash="$(sha256sum < "$LOG_BASE/final/cross-link-actions.preserved.json")"
    printf vs > "$fixture/calls"
    rc=0; "run_$phase" fixture || rc=$?
    printf '%s/%s: status=%s\n' "$phase" "$race_stage" "$rc"
    expected_rc=1
    [[ "$phase" != verifier ]] || expected_rc=7
    check test "$rc" -eq "$expected_rc"
    check test -f "$fixture/race-reached"
    check same_bytes "$LOG_BASE/final/verification.json" "$verification_hash"
    check same_bytes "$LOG_BASE/final/manifest.json" "$manifest_hash"
    check same_bytes "$LOG_BASE/final/cross-link-actions.preserved.json" "$actions_hash"
    check test "$(cat "$fixture/calls")" = vs
    check test -z "$(command find "$LOG_BASE/final" -name '.synthesis-cleanup.*' -print)"
    # A repaired readable empty root remains a successful, model-free retry.
    rm "$LOG_BASE/rounds" "$fixture/race-reached"
    mv "$fixture/offline-rounds" "$fixture/stored-rounds"
    ln -s "$fixture/empty-rounds" "$LOG_BASE/rounds"
    race_stage=none
    calls_before_retry="$(cat "$fixture/calls")"
    check "run_$phase" fixture
    output=manifest
    [[ "$phase" != verifier ]] || output=verification
    check jq -e 'length == 0' "$LOG_BASE/final/$output.json"
    check test "$(cat "$fixture/calls")" = "$calls_before_retry"
    rm "$LOG_BASE/rounds"
  done
done
printf 'Results: %s failed\n' "$FAIL"
(( FAIL == 0 ))
