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

# repolens-r7-p3-2: accepted output must remain readable and certified at parse time.
# shellcheck disable=SC1091,SC2034,SC2329 # Library APIs consume fixture globals.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
FIXTURE="$(mktemp -d)" || exit 1
trap 'chmod -R u+rwx "$FIXTURE"; rm -rf -- "$FIXTURE"' EXIT
source "$REPO/lib/rounds.sh" || exit 1
passed=0 failed=0
must() { "$@" || exit 1; }
check() {
  if "$@"; then passed=$((passed + 1));
  else failed=$((failed + 1)); printf 'FAIL: %s\n' "$*" >&2; fi
}
LENSES_DIR="$REPO/prompts/lenses" MODE=bugreport
# The proof is read only after the real hash has succeeded. Make the NEXT
# output read fail, including under root via a deterministic cat boundary.
block_after_proof() {
  if [[ "$*" == "$saved/meta-orchestrator-success.json" ]]; then
    command cat "$@" || return 1
    chmod 000 "$saved/meta-orchestrator-output.txt" || return 1
    : > "$saved/read-blocked" || return 1
    return 0
  fi
  local arg
  for arg in "$@"; do
    if [[ "$arg" == "$saved/meta-orchestrator-output.txt" && -f "$saved/read-blocked" ]]; then return 1; fi
  done
  command cat "$@"
}
for kind in dispatch saturated; do
  saved="$FIXTURE/$kind"
  must mkdir -p "$saved"
  if [[ "$kind" == dispatch ]]; then
    must printf 'LENS: injection role=deeper focus="security check"\nHYPOTHESES_TO_VERIFY:\nKeep this accepted hypothesis\n' > "$saved/meta-orchestrator-output.txt"
  else
    must printf 'NO_FRESH_ANGLES\n' > "$saved/meta-orchestrator-output.txt"
  fi
  must _rounds_meta_certify_success "$saved"
  must _rounds_meta_restore_success "$saved"
  proof_before="$(command cat "$saved/meta-orchestrator-success.json")" || exit 1
  dispatch_before="$(command cat "$saved/dispatch.md")" || exit 1
  hypotheses_before="$(command cat "$saved/hypotheses.md")" || exit 1
  cat() { block_after_proof "$@"; }
  rc=0
  _rounds_meta_restore_success "$saved" || rc=$?
  unset -f cat
  must chmod 600 "$saved/meta-orchestrator-output.txt"
  must rm "$saved/read-blocked"
  printf '%s late-read restore_rc=%s\n' "$kind" "$rc"
  check test "$rc" -eq 2
  check test "$(command cat "$saved/meta-orchestrator-success.json")" = "$proof_before"
  check test "$(command cat "$saved/dispatch.md")" = "$dispatch_before"
  check test "$(command cat "$saved/hypotheses.md")" = "$hypotheses_before"
  check test "$(find "$saved" -maxdepth 1 -name '.handoff.*' | wc -l)" -eq 0
  must _rounds_meta_restore_success "$saved"
  if [[ "$kind" == saturated ]]; then check test "$META_ORCH_SATURATED" -eq 1; fi
done
# Readable but changed bytes after validation must not be parsed under an old proof.
saved="$FIXTURE/tampered"
must mkdir "$saved"
must printf 'LENS: injection role=accepted\n' > "$saved/meta-orchestrator-output.txt"
must _rounds_meta_certify_success "$saved"
must _rounds_meta_restore_success "$saved"
dispatch_before="$(command cat "$saved/dispatch.md")" || exit 1
cat() {
  command cat "$@" || return 1
  if [[ "$*" == "$saved/meta-orchestrator-success.json" ]]; then
    printf 'LENS: injection role=changed\n' > "$saved/meta-orchestrator-output.txt" || return 1
  fi
}
rc=0
_rounds_meta_restore_success "$saved" || rc=$?
unset -f cat
check test "$rc" -eq 1
check test "$(command cat "$saved/dispatch.md")" = "$dispatch_before"
# Full resume must stop before round 2 and retain the accepted saturation result.
log_info() { :; }
log_warn() { printf '%s\n' "$*" >&2; }
set_stop_reason() { :; }
record_lens() { :; }
compose_prompt() { printf 'meta prompt'; }
run_agent() { printf 'called\n' >> "$LOG_BASE/model-calls"; printf 'NO_FRESH_ANGLES\n'; }
run_lens() { printf '%s\n' "$1" >> "$completed_lenses_file"; printf 'called\n' >> "$LOG_BASE/lens-calls"; }
build_round_digest() { mkdir -p "$1" || return 1; printf 'digest\n' > "$1/digest.md"; }
LOCAL_MODE=false PARALLEL=false RUN_ID=probe AGENT=mock
LOG_BASE="$FIXTURE/resume" SUMMARY_FILE="$LOG_BASE/summary.json" completed_lenses_file="$LOG_BASE/.completed"
LENSES=(security/injection)
must run_rounds 2 LENSES
saved="$LOG_BASE/rounds/round-1"
RESUME_RUN_ID=probe
cat() { block_after_proof "$@"; }
rc=0
run_rounds 2 LENSES || rc=$?
unset -f cat
must chmod 600 "$saved/meta-orchestrator-output.txt"
must rm "$saved/read-blocked"
check test "$rc" -ne 0
check test "$(wc -l < "$LOG_BASE/model-calls")" -eq 1
check test "$(wc -l < "$LOG_BASE/lens-calls")" -eq 1
must run_rounds 2 LENSES
check test "$META_ORCH_SATURATED" -eq 1
check test "$(wc -l < "$LOG_BASE/model-calls")" -eq 1
check test "$(wc -l < "$LOG_BASE/lens-calls")" -eq 1
# An open file can still fail on read. Linux proc memory at offset zero gives
# a real EIO without permissions tricks, including when the suite runs as root.
if [[ -f /proc/self/mem ]]; then
  for reader in scan dispatch hypotheses; do
    must printf 'accepted dispatch\n' > "$FIXTURE/reader-dispatch"
    must printf 'accepted hypotheses\n' > "$FIXTURE/reader-hypotheses"
    rc=0
    case "$reader" in
      scan) ( _rounds_meta_no_fresh_angles /proc/self/mem ) 2>/dev/null || rc=$? ;;
      dispatch) ( _rounds_meta_parse_output /proc/self/mem "$FIXTURE/reader-dispatch" "$FIXTURE/reader-hypotheses" ) 2>/dev/null || rc=$? ;;
      hypotheses) ( _rounds_meta_extract_hypotheses /proc/self/mem "$FIXTURE/reader-hypotheses" ) 2>/dev/null || rc=$? ;;
    esac
    if [[ "$reader" == scan ]]; then check test "$rc" -eq 2;
    else check test "$rc" -eq 1; fi
    check test "$(command cat "$FIXTURE/reader-dispatch")" = 'accepted dispatch'
    check test "$(command cat "$FIXTURE/reader-hypotheses")" = 'accepted hypotheses'
  done
fi

# Fail each parsing read after emitting a valid-looking prefix. No prefix may
# replace an accepted handoff or allow resume to schedule another round/call.
LOG_BASE="$FIXTURE/partial-reads" SUMMARY_FILE="$LOG_BASE/summary.json" completed_lenses_file="$LOG_BASE/.completed"
unset RESUME_RUN_ID
run_agent() { printf 'called\n' >> "$LOG_BASE/model-calls"; printf 'LENS: injection role=accepted\nHYPOTHESES_TO_VERIFY:\naccepted hypothesis\n'; }
must run_rounds 2 LENSES
saved="$LOG_BASE/rounds/round-1"
proof_before="$(command cat "$saved/meta-orchestrator-success.json")" || exit 1
dispatch_before="$(command cat "$saved/dispatch.md")" || exit 1
hypotheses_before="$(command cat "$saved/hypotheses.md")" || exit 1
RESUME_RUN_ID=probe
for fail_read in 1 2 3; do
  must printf '0\n' > "$saved/read-count"
  cat() {
    local arg count
    for arg in "$@"; do
      if [[ "$arg" == "$saved"/.handoff.*/meta-orchestrator-output.txt ]]; then
        count="$(command cat "$saved/read-count")" || return 1
        count=$((count + 1))
        printf '%s\n' "$count" > "$saved/read-count" || return 1
        if (( count == fail_read )); then
          printf 'LENS: injection role=partial\nHYPOTHESES_TO_VERIFY:\npartial hypothesis\n'
          return 1
        fi
      fi
    done
    command cat "$@"
  }
  rc=0
  run_rounds 2 LENSES || rc=$?
  unset -f cat
  check test "$rc" -ne 0
  check test "$(command cat "$saved/meta-orchestrator-success.json")" = "$proof_before"
  check test "$(command cat "$saved/dispatch.md")" = "$dispatch_before"
  check test "$(command cat "$saved/hypotheses.md")" = "$hypotheses_before"
  check test "$(find "$saved" -maxdepth 1 -name '.handoff.*' | wc -l)" -eq 0
  check test "$(wc -l < "$LOG_BASE/model-calls")" -eq 1
  check test "$(wc -l < "$LOG_BASE/lens-calls")" -eq 2
  must run_rounds 2 LENSES
done
# Checked streaming must preserve ordinary EOF and trailing hypothesis lines.
for ending in none one two; do
  must printf 'HYPOTHESES_TO_VERIFY:\nEnds in a period.' > "$FIXTURE/eof-input"
  must printf 'Ends in a period.\n' > "$FIXTURE/eof-expected"
  if [[ "$ending" != none ]]; then must printf '\n' >> "$FIXTURE/eof-input"; fi
  if [[ "$ending" == two ]]; then
    must printf '\n' >> "$FIXTURE/eof-input"
    must printf '\n' >> "$FIXTURE/eof-expected"
  fi
  must _rounds_meta_parse_output "$FIXTURE/eof-input" "$FIXTURE/eof-dispatch" "$FIXTURE/eof-hypotheses"
  check cmp -s "$FIXTURE/eof-expected" "$FIXTURE/eof-hypotheses"
done
# A failed hypothesis append must not publish the temporary file, even when
# later lines would write successfully. Exercise header-inline and body writes.
for write_kind in inline body; do
  if [[ "$write_kind" == inline ]]; then
    must printf 'HYPOTHESES_TO_VERIFY: rejected hypothesis\nsubsequent hypothesis\n' > "$FIXTURE/write-input"
  else
    must printf 'HYPOTHESES_TO_VERIFY:\naccepted prefix\nrejected hypothesis\n' > "$FIXTURE/write-input"
  fi
  must printf 'saved hypotheses\n' > "$FIXTURE/write-hypotheses"
  printf() {
    if [[ "${FUNCNAME[1]:-}" == _rounds_meta_extract_hypotheses && "${2:-}" == 'rejected hypothesis' ]]; then return 1; fi
    # shellcheck disable=SC2059 # Forward the mocked printf's format and arguments.
    builtin printf "$@"
  }
  rc=0
  _rounds_meta_extract_hypotheses "$FIXTURE/write-input" "$FIXTURE/write-hypotheses" || rc=$?
  unset -f printf
  check test "$rc" -eq 1
  check test "$(command cat "$FIXTURE/write-hypotheses")" = 'saved hypotheses'
  check test ! -e "$FIXTURE/write-hypotheses.tmp.$$"
done
# Full resume must keep accepted artifacts and avoid new calls until the
# failed hypothesis write can be retried successfully.
proof_before="$(command cat "$saved/meta-orchestrator-success.json")" || exit 1
dispatch_before="$(command cat "$saved/dispatch.md")" || exit 1
hypotheses_before="$(command cat "$saved/hypotheses.md")" || exit 1
printf() {
  if [[ "${FUNCNAME[1]:-}" == _rounds_meta_extract_hypotheses && "${2:-}" == 'accepted hypothesis' ]]; then return 1; fi
  # shellcheck disable=SC2059 # Forward the mocked printf's format and arguments.
  builtin printf "$@"
}
rc=0
run_rounds 2 LENSES || rc=$?
unset -f printf
check test "$rc" -ne 0
check test "$(command cat "$saved/meta-orchestrator-success.json")" = "$proof_before"
check test "$(command cat "$saved/dispatch.md")" = "$dispatch_before"
check test "$(command cat "$saved/hypotheses.md")" = "$hypotheses_before"
check test "$(find "$saved" -maxdepth 1 -name '.handoff.*' | wc -l)" -eq 0
check test "$(wc -l < "$LOG_BASE/model-calls")" -eq 1
check test "$(wc -l < "$LOG_BASE/lens-calls")" -eq 2
must run_rounds 2 LENSES
check test "$(command cat "$saved/hypotheses.md")" = "$hypotheses_before"
check test "$(wc -l < "$LOG_BASE/model-calls")" -eq 1
check test "$(wc -l < "$LOG_BASE/lens-calls")" -eq 2
# Producer errors remain errors for library callers with pipefail disabled,
# including a partial stream that already contains the saturation marker.
rc=0
(
  set +o pipefail
  cat() { builtin printf 'NO_FRESH_ANGLES\n'; return 1; }
  _rounds_meta_no_fresh_angles "$FIXTURE/eof-input"
) || rc=$?
check test "$rc" -eq 2
printf 'Results: %s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
