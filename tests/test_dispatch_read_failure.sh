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
set_stop_reason() { printf '%s\n' "$2" > "$LOG_BASE/stop-reason"; }
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
for fault in none empty partial late-custom late-generic late-presence; do
  LOG_BASE="$TMP/$fault"
  SUMMARY_FILE="$LOG_BASE/summary.json" completed_lenses_file="$LOG_BASE/.completed"
  mkdir -p "$LOG_BASE"
  printf '0\n' > "$LOG_BASE/dispatch-reads"
  fail_read=1
  case "$fault" in
    late-custom) fail_read=2 ;;
    late-generic) fail_read=3 ;;
    late-presence) fail_read=4 ;;
  esac
  cat() {
    if [[ "${!#}" == "$LOG_BASE/rounds/round-1/dispatch.md" && "$fault" != none ]]; then
      local count
      count="$(command cat "$LOG_BASE/dispatch-reads")"
      count=$((count + 1))
      printf '%s\n' "$count" > "$LOG_BASE/dispatch-reads"
      if (( count == fail_read )); then
        [[ "$fault" == empty ]] || printf 'LENS: injection\n'
        return 42
      fi
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
    case "$fault" in
      late-custom) expected_reason="custom-lens-materialization-failed" ;;
      late-generic) expected_reason="generic-dispatch-failed" ;;
      *) expected_reason="lens-dispatch-read-failed" ;;
    esac
    check test "$ROUNDS_FAILURE_REASON" = "$expected_reason"
    check grep -Fxq "$expected_reason" "$LOG_BASE/stop-reason"
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
if entries="$(_rounds_meta_dispatch_lens_entries "$TMP/unterminated")"; then
  check test "$entries" = $'security/injection\nsecurity/xss-csrf'
else
  check false
fi
# Large, readable dispatches must not need a here-string temporary file.
# All generated tuples stay small, so this isolates source buffering.
python3 - "$TMP/large" <<'DATA'
import sys
with open(sys.argv[1], 'w') as output:
    output.write(('# ' + 'x' * 1024 + '\n') * 64)
    output.write('LENS: injection\nLENS: xss-csrf')
DATA
check bash -c '
  set -euo pipefail
  source "$1/lib/rounds.sh"
  LENSES_DIR="$1/prompts/lenses" MODE=audit
  trap "" XFSZ
  ulimit -f 0
  entries="$(_rounds_meta_dispatch_lens_entries "$2")"
  [[ "$entries" == $'"'"'security/injection\nsecurity/xss-csrf'"'"' ]]
' _ "$ROOT" "$TMP/large"
# Every public dispatch parser rejects a failed prefix, even without pipefail.
printf 'LENS: injection\nGENERIC: role=broader focus="trace retries"\n' > "$TMP/readers"
for reader in lens generic has; do
  check bash -c '
    set -eu
    source "$1/lib/rounds.sh"
    LENSES_DIR="$1/prompts/lenses" MODE=audit
    cat() { builtin printf "LENS: injection\nGENERIC: role=broader\n"; return 42; }
    rc=0
    result="$(_rounds_meta_dispatch_"$3"_entries "$2")" || rc=$?
    [[ "$rc" -ne 0 && -z "$result" ]]
  ' _ "$ROOT" "$TMP/readers" "$reader" "$TMP/custom-lenses"
done
check bash -c '
  set -eu
  source "$1/lib/rounds.sh"
  cat() { builtin printf "CUSTOM: retry-check\n  Draft prompt:\n  Inspect retries.\n"; return 42; }
  rc=0
  result="$(_rounds_meta_dispatch_custom_entries "$2" "$3")" || rc=$?
  [[ "$rc" -ne 0 && -z "$result" ]]
' _ "$ROOT" "$TMP/readers" "$TMP/custom-lenses"
# A real read(2) EIO at offset zero is available even under root on Linux.
if [[ -f /proc/self/mem ]]; then
  for reader in lens custom generic has; do
    check bash -c '
      set -euo pipefail
      source "$1/lib/rounds.sh"
      rc=0
      result="$(_rounds_meta_dispatch_"$2"_entries /proc/self/mem "$3")" || rc=$?
      [[ "$rc" -ne 0 && -z "$result" ]]
    ' _ "$ROOT" "$reader" "$TMP/custom-lenses"
  done
fi
printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
