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

# shellcheck disable=SC2034,SC2329 # Production driver consumes globals/callbacks.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
# shellcheck source=/dev/null
source "$REPO/lib/rounds.sh"
log_info() { :; }
log_warn() { :; }
set_stop_reason() { :; }
record_lens() { :; }
compose_prompt() { printf 'mock prompt'; }
run_agent() {
  printf 'meta\n' >> "$LOG_BASE/meta-calls"
  printf 'CUSTOM: Payment retry race\nDraft prompt:\nCheck payment retry races.\n'
}
run_lens() {
  local canonical role focus anchor exclude
  _rounds_meta_tuple_parse "$1" canonical role focus anchor exclude
  if ! grep -qxF "$canonical" "$completed_lenses_file" 2>/dev/null; then
    printf '%s:%s\n' "$CURRENT_ROUND_INDEX" "$canonical" >> "$LOG_BASE/lens-calls"
    printf '%s\n' "$canonical" >> "$completed_lenses_file"
  fi
  return 0
}
build_round_digest() { mkdir -p "$1"; printf 'mock digest\n' > "$1/digest.md"; }
LOCAL_MODE=false PARALLEL=false
RUN_ID=probe MODE=audit AGENT=mock
LENSES_DIR="$REPO/prompts/lenses"
LENSES=(security/injection)
LOG_BASE="$FIXTURE/run"
PROJECT_PATH="$FIXTURE"
SUMMARY_FILE="$FIXTURE/summary.json"
mkdir -p "$LOG_BASE"
completed_lenses_file="$LOG_BASE/.completed"
# Force local custom-lens materialization to fail while the certified meta
# output is valid. This is an owned regular file, not a permission assumption.
mkdir -p "$LOG_BASE/rounds/round-1"
printf 'blocked directory\n' > "$LOG_BASE/rounds/round-1/custom-lenses"
rc=0
run_rounds 2 LENSES || rc=$?
printf 'run_rounds rc=%s; completed lens callbacks=%s\n' "$rc" "$(wc -l < "$LOG_BASE/lens-calls")"
cat "$LOG_BASE/lens-calls"
printf 'round-2 complete marker=%s\n' "$(test -f "$LOG_BASE/rounds/round-2/.completed" && printf present || printf absent)"
test "$rc" -ne 0
test "$ROUNDS_FAILURE_REASON" = custom-lens-materialization-failed
test "$(wc -l < "$LOG_BASE/lens-calls")" -eq 1
test ! -f "$LOG_BASE/rounds/round-2/.completed"
# Repair the owned obstruction and resume without repeating round 1.
rm "$LOG_BASE/rounds/round-1/custom-lenses"
RESUME_RUN_ID=probe
run_rounds 2 LENSES || exit $?
test "$(wc -l < "$LOG_BASE/lens-calls")" -eq 2
test -f "$LOG_BASE/rounds/round-2/.completed"
printf 'PASS: failed materialization blocks completion and remains resumable.\n'
# The parser must propagate failure both at EOF (covered by run_rounds above)
# and while flushing a CUSTOM payload before the next directive.
printf 'blocked\n' > "$FIXTURE/blocked"
printf 'CUSTOM: retry\nDraft prompt:\nInspect retries.\nLENS: security/injection\n' > "$FIXTURE/boundary.md"
rc=0
_rounds_meta_dispatch_custom_entries "$FIXTURE/boundary.md" "$FIXTURE/blocked" > "$FIXTURE/boundary-output" || rc=$?
test "$rc" -ne 0
test ! -s "$FIXTURE/boundary-output"
printf 'PASS: boundary materialization failure propagates.\n'
