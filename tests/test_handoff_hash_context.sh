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

# shellcheck disable=SC2034,SC2329 # Production driver globals and mock callbacks.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/rounds.sh"
passed=0 failed=0
check() {
  if "$@"; then passed=$((passed + 1)); else
    failed=$((failed + 1)); printf 'FAIL: %s\n' "$*"
  fi
}
git init -q --object-format=sha1 "$TEST_DIR/sha1"
git init -q --object-format=sha256 "$TEST_DIR/sha256"
mkdir "$TEST_DIR/plain"
sha1_hash="$(printf 'same bytes\n' | git -C "$TEST_DIR/sha1" hash-object --stdin)"
sha256_hash="$(printf 'same bytes\n' | git -C "$TEST_DIR/sha256" hash-object --stdin)"
check test "$sha1_hash" != "$sha256_hash"

log_info() { :; }
log_warn() { :; }
set_stop_reason() { :; }
record_lens() { :; }
compose_prompt() { printf 'meta prompt'; }
run_agent() {
  printf 'meta\n' >> "$LOG_BASE/meta-calls"
  if [[ "$envelope" == present ]]; then
    printf '{"is_error":false}\n' > "$6"
  fi
  printf 'NO_FRESH_ANGLES\n'
}
run_lens() {
  if ! grep -qxF "$1" "$completed_lenses_file" 2>/dev/null; then
    printf '%s\n' "$1" >> "$completed_lenses_file"
  fi
}
build_round_digest() { mkdir -p "$1"; printf 'digest\n' > "$1/digest.md"; }
LOCAL_MODE=false PARALLEL=false
RUN_ID=probe RESUME_RUN_ID=probe MODE=audit AGENT=mock

# Keep the run files fixed while changing only the invocation directory.
# Exercise both hash sites, including runs stored inside SHA-256 repositories.
for storage in plain sha1 sha256; do
  for envelope in absent present; do
    printf 'Case: storage=%s envelope=%s\n' "$storage" "$envelope"
    LOG_BASE="$TEST_DIR/$storage/run-$envelope"
    SUMMARY_FILE="$LOG_BASE/summary.json"
    completed_lenses_file="$LOG_BASE/.completed"
    LENSES=(security/injection)
    # Fail only the final compatibility barrier, after successful certification.
    mkdir -p "$LOG_BASE/.rounds/round-1.completed"
    cd "$TEST_DIR/sha1"
    first_rc=0
    run_rounds 2 LENSES || first_rc=$?
    check test "$first_rc" -ne 0
    check test "$(wc -l < "$LOG_BASE/meta-calls")" -eq 1
    round_dir="$LOG_BASE/rounds/round-1"
    check test -f "$round_dir/meta-orchestrator-success.json"
    saved_proof="$(cat "$round_dir/meta-orchestrator-success.json")"
    saved_fingerprint="$(_rounds_meta_result_fingerprint "$round_dir")"
    rmdir "$LOG_BASE/.rounds/round-1.completed"
    control_rc=0
    _rounds_meta_restore_success "$round_dir" || control_rc=$?
    check test "$control_rc" -eq 0

    cd "$TEST_DIR/sha256"
    check test "$(_rounds_meta_result_fingerprint "$round_dir")" = "$saved_fingerprint"
    resume_rc=0
    run_rounds 2 LENSES || resume_rc=$?
    check test "$resume_rc" -eq 0
    check test "$(wc -l < "$LOG_BASE/meta-calls")" -eq 1
    check test "$(cat "$round_dir/meta-orchestrator-success.json")" = "$saved_proof"
    check test -f "$LOG_BASE/.rounds/round-1.completed"
    check test ! -e "$LOG_BASE/rounds/round-2/digest.md"
    cd "$TEST_DIR/plain"
    check test "$(_rounds_meta_result_fingerprint "$round_dir")" = "$saved_fingerprint"

    # Context invariance must not allow changed certified bytes to be reused.
    printf '\n' >> "$round_dir/meta-orchestrator-output.txt"
    restore_rc=0
    _rounds_meta_restore_success "$round_dir" || restore_rc=$?
    check test "$restore_rc" -ne 0
    check test "$(wc -l < "$LOG_BASE/meta-calls")" -eq 1
  done
done
printf 'Results: %s passed, %s failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
