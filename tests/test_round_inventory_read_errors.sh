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

# repolens-r10-p4-1: incomplete finding inventories are never empty successes.
# shellcheck disable=SC2034 # The phase functions consume fixture globals.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO/lib/verify.sh"
# shellcheck source=/dev/null
source "$REPO/lib/synthesize.sh"
set -euo pipefail
FIXTURE="$(mktemp -d)"
trap 'chmod -R u+rwX "$FIXTURE"; rm -rf -- "$FIXTURE"' EXIT
AGENT=mock MODE=audit PROJECT_PATH="$FIXTURE/project"
mkdir "$PROJECT_PATH"
PASS=0 FAIL=0
check() {
  local desc="$1"; shift
  if "$@"; then PASS=$((PASS + 1))
  else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$desc"; fi
}
# A complete mock boundary: no model or forge can be called by these tests.
compose_prompt() { printf 'mock prompt\n'; }
run_agent() { : > "$LOG_BASE/unexpected-agent"; return 99; }
# Fail enumeration before output, after genuine partial output, or through
# real directory permissions. Privileged readers receive the same error via
# injection instead of silently losing coverage when they bypass mode bits.
find() {
  if [[ "${1:-}" == "$LOG_BASE/rounds" ]]; then
    : > "$LOG_BASE/inventory-read"
    [[ "$fault" != interrupted* ]] || kill -TERM "$$"
    if [[ "$fault" == find-empty || "$fault" == find-partial || "$fault" == interrupted-error ]] \
        || [[ "$fault" == permission && -r "$rawdir" ]]; then
      [[ "$fault" != find-partial ]] || command find "$@"
      printf 'injected incomplete inventory\n' >&2
      return 42
    fi
  fi
  command find "$@"
}
# A failed counter can also emit a plausible zero before failing.
awk() {
  if [[ "$fault" == counter && "${1:-}" == *'count+0'* ]]; then
    command cat >/dev/null
    printf '0\n'
    return 42
  fi
  command awk "$@"
}
# Removal failures must stop before any agent can use saved output.
rm() {
  if [[ "$fault" == cleanup* && "${2:-}" == "$LOG_BASE/final/"* ]]; then
    [[ "$fault" != cleanup-interrupted ]] || kill -TERM "$$"
    printf 'injected saved-result cleanup failure\n' >&2
    return 42
  fi
  command rm "$@"
}
trap 'REPOLENS_FINAL_STATE=interrupted; REPOLENS_INTERRUPT_EXIT_CODE=143' TERM
# Compare bytes without retaining extra copies of generated metadata.
same_bytes() { [[ -f "$1" && "$(sha256sum < "$1")" == "$2" ]]; }
for phase in verifier synthesizer; do
  for fault in permission find-empty find-partial counter cleanup cleanup-interrupted interrupted interrupted-empty interrupted-error; do
    REPOLENS_FINAL_STATE=finished
    LOG_BASE="$FIXTURE/$phase-$fault/run"
    rawdir="$LOG_BASE/rounds/round-1/lens-outputs"
    mkdir -p "$rawdir" "$LOG_BASE/final"
    printf -- '---\ndomain: generic\nlens_id: probe\nseverity: high\n---\n## hypothesis\nSaved finding\n' > "$rawdir/probe.md"
    [[ "$fault" != interrupted-empty ]] || command rm "$rawdir/probe.md"
    printf '[{"finding_id":"saved","status":"VERIFIED","notes":"saved evidence"}]\n' > "$LOG_BASE/final/verification.json"
    printf '[{"cluster_id":"saved","title":"Saved finding"}]\n' > "$LOG_BASE/final/manifest.json"
    printf '[{"type":"comment","issue_number":1,"body":"saved"}]\n' > "$LOG_BASE/final/cross-link-actions.preserved.json"
    before_actions="$(sha256sum < "$LOG_BASE/final/cross-link-actions.preserved.json")"
    before_verification="$(sha256sum < "$LOG_BASE/final/verification.json")"
    before_manifest="$(sha256sum < "$LOG_BASE/final/manifest.json")"
    [[ "$fault" != permission ]] || chmod 000 "$rawdir"
    rc=0
    "run_$phase" probe > "$LOG_BASE/phase.log" 2>&1 || rc=$?
    chmod 700 "$rawdir"
    check "$phase/$fault reports failure" test "$rc" -ne 0
    check "$phase/$fault preserves verification" same_bytes "$LOG_BASE/final/verification.json" "$before_verification"
    check "$phase/$fault preserves manifest" same_bytes "$LOG_BASE/final/manifest.json" "$before_manifest"
    check "$phase/$fault preserves cross-link actions" same_bytes "$LOG_BASE/final/cross-link-actions.preserved.json" "$before_actions"
    if [[ "$fault" == interrupted* || "$fault" == cleanup-interrupted ]]; then
      check "$phase returns the interrupt code" test "$rc" -eq 143
    fi
    check "$phase/$fault invokes no model" test ! -e "$LOG_BASE/unexpected-agent"
    check "$phase/$fault reaches inventory" test -e "$LOG_BASE/inventory-read"
  done
  # Truly empty, readable inventories still publish their canonical sentinel.
  REPOLENS_FINAL_STATE=finished
  fault=none
  LOG_BASE="$FIXTURE/$phase-empty/run"
  rawdir="$LOG_BASE/rounds/round-1/lens-outputs"
  mkdir -p "$rawdir"
  "run_$phase" probe
  output=verification
  [[ "$phase" != synthesizer ]] || output=manifest
  check "$phase accepts a genuine empty inventory" test "$(cat "$LOG_BASE/final/$output.json")" = '[]'
  check "$phase empty inventory invokes no model" test ! -e "$LOG_BASE/unexpected-agent"
done
printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
test "$FAIL" -eq 0
