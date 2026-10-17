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

# repolens-r12-p1-1: consume dispatch completely before executing its entries.
# shellcheck disable=SC2034,SC2329 # Mock callbacks and globals are used by run_rounds.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/rounds.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
PASS=0 FAIL=0
check() { if "$@"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$*" >&2; fi; }
log_info() { :; }
log_warn() { :; }
set_stop_reason() { :; }
record_lens() { :; }
compose_prompt() { printf 'mock prompt\n'; }
run_agent() { printf 'LENS: injection\nLENS: xss-csrf\nHYPOTHESES_TO_VERIFY:\nInspect both.\n'; }
run_lens() {
  printf '%s:%s\n' "$CURRENT_ROUND_INDEX" "$1" >> "$LOG_BASE/executed"
  printf '%s\n' "$1" >> "$completed_lenses_file"
}
build_round_digest() { mkdir -p "$1"; printf 'digest\n' > "$1/digest.md"; }
LOCAL_MODE=false PARALLEL=false RUN_ID=probe RESUME_RUN_ID='' MODE=audit AGENT=mock
LENSES_DIR="$ROOT/prompts/lenses" PROJECT_PATH="$ROOT"
LENSES=(security/injection)
for fault in none empty partial; do
  LOG_BASE="$TMP/$fault"
  SUMMARY_FILE="$LOG_BASE/summary.json" completed_lenses_file="$LOG_BASE/.completed"
  mkdir -p "$LOG_BASE"
  cat() {
    if [[ "${!#}" == "$LOG_BASE/rounds/round-1/dispatch.md" && "$fault" != none ]]; then
      [[ "$fault" != partial ]] || printf 'LENS: injection\n'
      return 42
    fi
    command cat "$@"
  }
  rc=0
  run_rounds 2 LENSES || rc=$?
  unset -f cat
  if [[ "$fault" == none ]]; then
    check test "$rc" -eq 0
    check grep -Fxq '2:security/injection' "$LOG_BASE/executed"
    check grep -Fxq '2:security/xss-csrf' "$LOG_BASE/executed"
    check test -f "$LOG_BASE/rounds/round-2/.completed"
  else
    check test "$rc" -ne 0
    check test "$(wc -l < "$LOG_BASE/executed")" -eq 1
    check test ! -e "$LOG_BASE/rounds/round-2/.completed"
    check test -s "$LOG_BASE/rounds/round-1/meta-orchestrator-output.txt"
    # Repair the read and resume: both accepted lenses must execute exactly once.
    RESUME_RUN_ID=probe
    check run_rounds 2 LENSES
    RESUME_RUN_ID=''
    check test "$(grep -Fxc '2:security/injection' "$LOG_BASE/executed")" -eq 1
    check test "$(grep -Fxc '2:security/xss-csrf' "$LOG_BASE/executed")" -eq 1
    check test -f "$LOG_BASE/rounds/round-2/.completed"
  fi
done
# A successful read without a final linefeed retains the final accepted lens.
printf 'LENS: injection\nLENS: xss-csrf' > "$TMP/unterminated"
entries="$(_rounds_meta_dispatch_lens_entries "$TMP/unterminated")"
check test "$(printf '%s\n' "$entries" | wc -l)" -eq 2
printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
