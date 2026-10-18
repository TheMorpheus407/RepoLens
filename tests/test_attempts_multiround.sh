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

# repolens-r13-p2-2: accounting must include actual per-round lens receipts.
# shellcheck disable=SC2034,SC2329 # Globals/callbacks consumed by sourced APIs.
set -euo pipefail
check() { "$@" || { printf 'FAIL: %s\n' "$*" >&2; exit 1; }; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/lib/rounds.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/attempts.sh"
# Exercise the CLI's actual receipt writer and completion lookup.
for fn in is_lens_completed mark_lens_completed; do
  eval "$(sed -n "/^$fn() {/,/^}/p" "$ROOT/repolens.sh")"
done
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
MODE=bugreport LOCAL_MODE=true OUTPUT_DIR_SET=false PARALLEL=false
TOTAL_LENSES=1 MAX_ISSUES=''
LENSES=(security/injection)
log_info() { :; }
log_warn() { printf '%s\n' "$*" >&2; }
set_stop_reason() { :; }
record_lens() { :; }
build_round_digest() { printf 'Mock digest\n' > "$1/digest.md"; }
run_meta_orchestrator() { return 0; }
run_lens() {
  # Match the production callback: completed tuples do no new agent work.
  if is_lens_completed "$1"; then return 0; fi
  [[ "$CURRENT_ROUND_INDEX" != "$FAIL_ROUND" ]] || return 1
  printf '%s:%s\n' "$CURRENT_ROUND_INDEX" "$1" >> "$LOG_BASE/work"
  mark_lens_completed "$1"
}
fresh() {
  RUN_ID="$1" ROUNDS="$2" LOG_BASE="$TMP/$1" FAIL_ROUND=0
  SUMMARY_FILE="$LOG_BASE/summary.json"
  OUTPUT_DIR="$LOG_BASE/rounds/round-1/lens-outputs"
  completed_lenses_file="$LOG_BASE/.completed"
  check init_run_layout "$RUN_ID" "$ROUNDS" 1 "${LENSES[@]}"
  check touch "$completed_lenses_file"
}

fresh complete 2
check attempts_begin "$LOG_BASE"
check run_rounds 2 LENSES
for round in 1 2; do
  check test -f "$LOG_BASE/rounds/round-$round/.completed"
  check grep -qx security/injection "$LOG_BASE/.rounds/round-$round.lenses.completed"
done
check test ! -s "$LOG_BASE/.completed"
check attempts_finalize "$LOG_BASE" finished '' 0 1
jq 'last | {lenses_completed_this_attempt,lenses_completed_total}' "$LOG_BASE/attempts.json"
check jq -e '.[0] | .lenses_completed_this_attempt == 2 and .lenses_completed_total == 2' "$LOG_BASE/attempts.json"

fresh resumed 3
check attempts_begin "$LOG_BASE"
FAIL_ROUND=2
rc=0
run_rounds 3 LENSES || rc=$?
check test "$rc" -ne 0
check attempts_finalize "$LOG_BASE" failed fixture 1 1
check jq -e '.[0] | .lenses_completed_this_attempt == 1 and .lenses_completed_total == 1' "$LOG_BASE/attempts.json"
check attempts_begin "$LOG_BASE"
FAIL_ROUND=0
check run_rounds 3 LENSES
check attempts_finalize "$LOG_BASE" finished '' 0 2
check jq -e '.[1] | .lenses_completed_this_attempt == 2 and .lenses_completed_total == 3' "$LOG_BASE/attempts.json"
check test "$(wc -l < "$LOG_BASE/work")" -eq 3
check attempts_begin "$LOG_BASE"
check run_rounds 3 LENSES
check attempts_finalize "$LOG_BASE" finished '' 0 3
check jq -e '.[2] | .lenses_completed_this_attempt == 0 and .lenses_completed_total == 3' "$LOG_BASE/attempts.json"
check test "$(wc -l < "$LOG_BASE/work")" -eq 3

# Single-round accounting keeps using the root receipt file; round barriers
# themselves, pending files and unrelated .completed files are not lens work.
mkdir -p "$TMP/single/.rounds"
printf 'security/injection\nsecurity/auth\n' > "$TMP/single/.completed"
touch "$TMP/single/.rounds/round-1.completed"
printf 'not a receipt\n' > "$TMP/single/.rounds/round-2.lenses.completed.tmp"
check test "$(_attempts_completed_count "$TMP/single")" -eq 2
check test "$(_attempts_completed_count "$TMP/missing")" -eq 0
printf 'PASS: completed rounds, interrupted/resumed deltas and single-round receipts counted.\n'
