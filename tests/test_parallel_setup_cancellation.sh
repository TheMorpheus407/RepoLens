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

# Cancellation at setup/handshake boundaries must never release the callback.
# shellcheck disable=SC2034,SC2329
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO/lib/parallel.sh"
source "$REPO/tests/process_scope_test_support.sh"
require_process_scopes
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
log_info() { :; }
log_warn() { :; }
eval "$(declare -f _scope_call | sed '1s/_scope_call/_scope_call_real/')"
PASS=0 FAIL=0
for boundary in mktemp enrollment-file enroll; do
  (
    LOG_BASE="$FIXTURE/$boundary"
    mkdir -p "$LOG_BASE"
    export TMPDIR="$LOG_BASE"
    REPOLENS_FINAL_STATE=finished
    parent_pid="$BASHPID"
    init_parallel "$LOG_BASE/.semaphore" 1 || exit 1
    mktemp() {
      command mktemp "$@"
      if [[ "$boundary" == mktemp ]]; then kill -TERM "$parent_pid"; fi
    }
    _scope_call() {
      _scope_call_real "$@" || return 1
      if [[ "$2" == "$boundary" ]]; then kill -TERM "$parent_pid"; fi
    }
    callback() { touch "$LOG_BASE/forbidden-callback"; }
    spawn_lens c1 callback
    spawn_rc=$?
    wait_all || true
    _cleanup_children || exit 1
    [[ "$REPOLENS_FINAL_STATE" == interrupted && "$REPOLENS_INTERRUPT_EXIT_CODE" == 143 ]] || exit 1
    [[ "$spawn_rc" != 0 && ! -e "$LOG_BASE/forbidden-callback" ]] || exit 1
    [[ -z "$(find "$LOG_BASE/.semaphore" -name '*.token' -print -quit)" ]] || exit 1
    [[ -z "$(find "$LOG_BASE" -name 'repolens-scope.*' -print -quit)" ]] || exit 1
    exit 0
  )
  rc=$?
  if (( rc == 0 )); then echo "PASS: $boundary cancellation blocks GO and drains setup"; PASS=$((PASS + 1));
  else echo "FAIL: $boundary cancellation (exit $rc)"; FAIL=$((FAIL + 1)); fi
done
printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
