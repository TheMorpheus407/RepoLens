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

# Exercise the actual verifier -> synthesizer orchestration with real phase
# functions and mocked model/filing boundaries. No provider CLI is invoked.
# shellcheck disable=SC1090,SC1091,SC2034,SC2329
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO/lib/verify.sh"
source "$REPO/lib/synthesize.sh"
set -euo pipefail
FIXTURE="$(mktemp -d)"
trap 'command rm -rf -- "$FIXTURE"' EXIT
# Keep this test on the production caller rather than copying its decisions.
command awk '/^# --- Verifier / {copy=1} /^# --- Finalize ---/ {exit} copy {print}' \
  "$REPO/repolens.sh" > "$FIXTURE/phases.sh"
[[ -s "$FIXTURE/phases.sh" ]]
PASS=0 FAIL=0
check() {
  local desc="$1"; shift
  if "$@"; then PASS=$((PASS + 1))
  else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$desc"; fi
}
log_info() { printf '%s\n' "$*" >> "$LOG_BASE/caller.log"; }
log_warn() { log_info "$@"; }
set_stop_reason() { printf '%s\n' "$2" > "$LOG_BASE/stop-reason"; }
compose_prompt() { printf 'mock prompt\n'; }
run_agent() { : > "$LOG_BASE/model-called"; printf '[]\n'; }
dispatch_filing_batch() { : > "$LOG_BASE/filing-called"; }
_verifier_bad_output() { printf 'No verifier JSON available\n'; }
find() {
  # Only the verifier enumeration fails; synthesis would succeed on retry.
  if [[ "$fault" == inventory && "${3:-}" == '*/lens-outputs/*.md' ]]; then
    printf 'transient verifier inventory failure\n' >&2
    return 42
  fi
  command find "$@"
}
rm() {
  if [[ "$fault" == cleanup && "${2:-}" == "$LOG_BASE/final/verification.json" ]]; then
    printf 'saved verification removal failed\n' >&2
    return 42
  fi
  command rm "$@"
}
same_bytes() { [[ -f "$1" && "$(sha256sum < "$1")" == "$2" ]]; }
AGENT=mock MODE=bugreport ROUNDS=2 LOCAL_MODE=false NO_VERIFIER=false RUN_ID=probe
PROJECT_PATH="$FIXTURE/project"
mkdir -p "$PROJECT_PATH"
_VERIFIER_AGENT_CALLBACK=_verifier_bad_output
for fault in inventory cleanup setup ordinary; do
  LOG_BASE="$FIXTURE/$fault"
  mkdir -p "$LOG_BASE/rounds/round-1/lens-outputs" "$LOG_BASE/final"
  printf 'Current finding\n' > "$LOG_BASE/rounds/round-1/lens-outputs/probe.md"
  printf '[{"finding_id":"saved","status":"WRONG","notes":"old evidence","source_finding_path":"rounds/round-1/lens-outputs/probe.md"}]\n' > "$LOG_BASE/final/verification.json"
  printf '[{"cluster_id":"saved","title":"Saved publication"}]\n' > "$LOG_BASE/final/manifest.json"
  printf '[{"type":"comment","issue_number":1,"body":"saved"}]\n' > "$LOG_BASE/final/cross-link-actions.preserved.json"
  before_verification="$(sha256sum < "$LOG_BASE/final/verification.json")"
  before_manifest="$(sha256sum < "$LOG_BASE/final/manifest.json")"
  before_actions="$(sha256sum < "$LOG_BASE/final/cross-link-actions.preserved.json")"
  RUN_ROUNDS_RC=0 REPOLENS_FINAL_STATE=finished
  SUMMARY_FILE="$LOG_BASE/summary.json"
  AGENT=mock
  [[ "$fault" != setup ]] || AGENT=''
  source "$FIXTURE/phases.sh" > "$LOG_BASE/phase.log" 2>&1
  if [[ "$fault" != ordinary ]]; then
    check "$fault aborts this attempt" test "$RUN_ROUNDS_RC" -ne 0
    check "$fault marks the attempt failed" test "$REPOLENS_FINAL_STATE" = failed
    check "$fault has a preparation stop reason" test "$(cat "$LOG_BASE/stop-reason" 2>/dev/null || true)" = verifier-preparation-failed
    check "$fault preserves saved verification" same_bytes "$LOG_BASE/final/verification.json" "$before_verification"
    check "$fault preserves saved manifest" same_bytes "$LOG_BASE/final/manifest.json" "$before_manifest"
    check "$fault preserves saved actions" same_bytes "$LOG_BASE/final/cross-link-actions.preserved.json" "$before_actions"
    check "$fault admits no synthesis model" test ! -e "$LOG_BASE/model-called"
    check "$fault admits no filing" test ! -e "$LOG_BASE/filing-called"
  else
    check 'ordinary verifier output failure stays nonfatal' test "$RUN_ROUNDS_RC" -eq 0
    check 'ordinary failure retires stale verification' test ! -e "$LOG_BASE/final/verification.json"
    check 'ordinary failure proceeds to synthesis' test -e "$LOG_BASE/model-called"
    check 'ordinary failure produces a fresh manifest' test "$(cat "$LOG_BASE/final/manifest.json")" = '[]'
    check 'ordinary failure permits filing the fresh manifest' test -e "$LOG_BASE/filing-called"
  fi
done
printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
test "$FAIL" -eq 0
