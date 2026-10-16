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

# repolens-r9-p1-2: unreadable completion receipts preserve accepted meta work.
# shellcheck disable=SC1091,SC2034,SC2329
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
run_lens() { printf '%s\n' "$1" >> "$completed_lenses_file"; printf 'called\n' >> "$LOG_BASE/lens-calls"; }
build_round_digest() { mkdir -p "$1" || return 1; printf 'digest\n' > "$1/digest.md"; }
LOCAL_MODE=false PARALLEL=false RUN_ID=probe MODE=bugreport AGENT=mock
LOG_BASE="$FIXTURE/run" SUMMARY_FILE="$LOG_BASE/summary.json" completed_lenses_file="$LOG_BASE/.completed"
LENSES=(security/injection)
run_rounds 2 LENSES || exit 1
saved="$LOG_BASE/rounds/round-1/meta-orchestrator-success.json"
proof_before=$(cat "$saved") || exit 1
receipt="$LOG_BASE/.rounds/round-1.lenses.completed"
RESUME_RUN_ID=probe
# Deterministic I/O errors also exercise privileged test environments.
cat() { if [[ "$*" == "$receipt" ]]; then return 1; fi; command cat "$@"; }
grep() {
  local arg
  for arg in "$@"; do [[ "$arg" != "$receipt" ]] || return 2; done
  command grep "$@"
}
rc=0
_rounds_all_lenses_completed "$receipt" "${LENSES[@]}" || rc=$?
test "$rc" -eq 2 || exit 1
rc=0
run_rounds 2 LENSES || rc=$?
unset -f cat grep
printf 'read-error resume rc=%s lens=%s meta=%s\n' "$rc" "$(wc -l < "$LOG_BASE/lens-calls")" "$(wc -l < "$LOG_BASE/model-calls")"
test "$rc" -ne 0 || exit 1
test "$(cat "$saved")" = "$proof_before" || exit 1
test "$(wc -l < "$LOG_BASE/lens-calls")" -eq 1 || exit 1
test "$(wc -l < "$LOG_BASE/model-calls")" -eq 1 || exit 1
run_rounds 2 LENSES || exit 1
test "$(wc -l < "$LOG_BASE/lens-calls")" -eq 1 || exit 1
test "$(wc -l < "$LOG_BASE/model-calls")" -eq 1 || exit 1
# A genuinely absent receipt still means pending work.
rc=0
_rounds_all_lenses_completed "$FIXTURE/absent" "${LENSES[@]}" || rc=$?
test "$rc" -eq 1 || exit 1
printf 'PASS: completion I/O errors preserve work and retry without agent calls\n'
