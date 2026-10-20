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

# Regression: repolens-r6-p2-2. No real model calls.
# shellcheck disable=SC1091,SC2034,SC2329 # sourced APIs use named arrays and globals
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
FIXTURE="$(mktemp -d)" || exit 1
trap 'chmod -R u+rwx "$FIXTURE"; rm -rf -- "$FIXTURE"' EXIT
source "$REPO/lib/rounds.sh" || exit 1
log_info() { :; }
log_warn() { printf '%s\n' "$*" >&2; }
set_stop_reason() { :; }
record_lens() { :; }
compose_prompt() { printf 'meta prompt'; }
run_agent() { printf 'called\n' >> "$LOG_BASE/model-calls"; printf 'NO_FRESH_ANGLES\n'; }
run_lens() { printf '%s\n' "$1" >> "$completed_lenses_file"; }
build_round_digest() { mkdir -p "$1" || return 1; printf 'digest\n' > "$1/digest.md"; }
LOCAL_MODE=false PARALLEL=false RUN_ID=probe MODE=bugreport AGENT=mock
LOG_BASE="$FIXTURE/run" SUMMARY_FILE="$LOG_BASE/summary.json" completed_lenses_file="$LOG_BASE/.completed"
LENSES=(security/injection)
rc=0
run_rounds 2 LENSES || rc=$?
test "$rc" -eq 0 || exit 1
saved="$LOG_BASE/rounds/round-1"
test -s "$saved/meta-orchestrator-success.json" || exit 1
proof_before=$(cat "$saved/meta-orchestrator-success.json") || exit 1
RESUME_RUN_ID=probe
chmod 000 "$saved/meta-orchestrator-output.txt" || exit 1
if [[ -r "$saved/meta-orchestrator-output.txt" ]]; then
  _rounds_meta_git() { return 1; }
fi
# Keep this result distinct from artifact-helper locals across the reload below.
output_restore_rc=0
_rounds_meta_restore_success "$saved" || output_restore_rc=$?
printf 'unreadable saved output: restore_rc=%s (2 is pending/verification-unavailable)\n' "$output_restore_rc"
resume_rc=0
run_rounds 2 LENSES || resume_rc=$?
printf 'resume_rc=%s proof=%s calls=%s\n' "$resume_rc" "$(test -s "$saved/meta-orchestrator-success.json" && echo present || echo DELETED)" "$(wc -l < "$LOG_BASE/model-calls")"
chmod 600 "$saved/meta-orchestrator-output.txt" || exit 1
# Reload the real hash helper after the root-only failure injection.
source "$REPO/lib/rounds.sh" || exit 1
repair_rc=0
run_rounds 2 LENSES || repair_rc=$?
test "$repair_rc" -eq 0 || exit 1
printf 'after permission repair: model calls=%s (expected 1)\n' "$(wc -l < "$LOG_BASE/model-calls")"
test "$output_restore_rc" -eq 2 || exit 1
test "$resume_rc" -ne 0 || exit 1
test "$(cat "$saved/meta-orchestrator-success.json")" = "$proof_before" || exit 1
test "$(wc -l < "$LOG_BASE/model-calls")" -eq 1 || exit 1
printf 'Results: unreadable handoff preserves proof and resumes without a model call\n'

# Missing/non-file output is invalid evidence. A directory at the output path
# blocks dispatch until repaired; the subsequent resume makes one replacement call.
for output_kind in missing directory; do
  LOG_BASE="$FIXTURE/$output_kind-output"
  completed_lenses_file="$LOG_BASE/.completed"
  run_rounds 2 LENSES || exit 1
  saved="$LOG_BASE/rounds/round-1"
  rm "$saved/meta-orchestrator-output.txt" || exit 1
  if [[ "$output_kind" == directory ]]; then
    mkdir "$saved/meta-orchestrator-output.txt" || exit 1
  fi
  restore_rc=0
  _rounds_meta_restore_success "$saved" || restore_rc=$?
  printf '%s saved output: restore_rc=%s (expected 1)\n' "$output_kind" "$restore_rc"
  test "$restore_rc" -eq 1 || exit 1
  if [[ "$output_kind" == directory ]]; then
    resume_rc=0
    run_rounds 2 LENSES || resume_rc=$?
    printf 'directory still obstructs output: resume_rc=%s calls=%s\n' \
      "$resume_rc" "$(wc -l < "$LOG_BASE/model-calls")"
    test "$resume_rc" -ne 0 || exit 1
    test "$(wc -l < "$LOG_BASE/model-calls")" -eq 1 || exit 1
    test -d "$saved/meta-orchestrator-output.txt" || exit 1
    rmdir "$saved/meta-orchestrator-output.txt" || exit 1
  fi
  run_rounds 2 LENSES || exit 1
  test "$(wc -l < "$LOG_BASE/model-calls")" -eq 2 || exit 1
done

# Inject a certificate read error even when running as root. Both historical
# jq file reads and the certificate snapshot read must see the same IO failure.
LOG_BASE="$FIXTURE/unreadable-certificate"
completed_lenses_file="$LOG_BASE/.completed"
run_rounds 2 LENSES || exit 1
saved="$LOG_BASE/rounds/round-1"
proof_before=$(cat "$saved/meta-orchestrator-success.json") || exit 1
UNREADABLE_CERT="$saved/meta-orchestrator-success.json"
cat() {
  if [[ "$*" == "$UNREADABLE_CERT" ]]; then return 1; fi
  command cat "$@"
}
jq() {
  local arg
  for arg in "$@"; do
    if [[ "$arg" == "$UNREADABLE_CERT" ]]; then return 2; fi
  done
  command jq "$@"
}
restore_rc=0
_rounds_meta_restore_success "$saved" || restore_rc=$?
resume_rc=0
run_rounds 2 LENSES || resume_rc=$?
printf 'unreadable certificate: restore_rc=%s resume_rc=%s calls=%s\n' \
  "$restore_rc" "$resume_rc" "$(wc -l < "$LOG_BASE/model-calls")"
unset -f cat jq || exit 1
test "$restore_rc" -eq 2 || exit 1
test "$resume_rc" -ne 0 || exit 1
test "$(cat "$saved/meta-orchestrator-success.json")" = "$proof_before" || exit 1
test "$(wc -l < "$LOG_BASE/model-calls")" -eq 1 || exit 1
run_rounds 2 LENSES || exit 1
test "$(wc -l < "$LOG_BASE/model-calls")" -eq 1 || exit 1
printf 'Results: missing output regenerates; certificate read errors preserve acceptance\n'
