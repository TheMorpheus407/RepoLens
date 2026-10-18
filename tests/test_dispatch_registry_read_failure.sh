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


# repolens-r15-p6-4: registry outages must leave requested dispatch work pending.
# shellcheck disable=SC2034,SC2329 # Fixture callbacks/globals drive run_rounds.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Reuse the existing round-driver fixture before its scenario loop.
# shellcheck source=/dev/null
source <(awk '/^for fault in / {exit} /^ROOT=/ {next} {print}' "$ROOT/tests/test_dispatch_read_failure.sh")
if (( $# == 0 )); then set -- unreadable empty partial; fi
for registry_fault in "$@"; do (
  DOMAINS_FILE="$TMP/$registry_fault-domains.json"
  printf '{"domains":[{"id":"security","order":1,"lenses":["injection","xss-csrf"]}]}\n' > "$DOMAINS_FILE"
  trap 'chmod u+rw "$DOMAINS_FILE" 2>/dev/null || true' EXIT
  LOG_BASE="$TMP/registry-$registry_fault"
  SUMMARY_FILE="$LOG_BASE/summary.json" completed_lenses_file="$LOG_BASE/.completed"
  mkdir -p "$LOG_BASE"
  registry_broken=false break_registry=true
  # Count only the fixture model invocation; no real provider is called.
  eval "$(declare -f run_agent | sed '1s/run_agent/registry_fixture_agent/')"
  run_agent() { printf 'call\n' >> "$LOG_BASE/model-calls"; registry_fixture_agent "$@"; }
  eval "$(declare -f run_meta_orchestrator | sed '1s/run_meta_orchestrator/registry_fixture_meta/')"
  run_meta_orchestrator() {
    registry_fixture_meta "$@" || return $?
    if [[ "$break_registry" == true ]]; then
      registry_broken=true
      [[ "$registry_fault" != unreadable ]] || chmod 000 "$DOMAINS_FILE"
    fi
  }
  # Fault only registry enumeration after a complete meta handoff. Actual chmod
  # is used for unreadability; root-only test environments emulate EACCES.
  jq() {
    if [[ "$registry_broken" == true && "${!#}" == "$DOMAINS_FILE" ]]; then
      case "$registry_fault" in
        empty) printf 'fault\n' >> "$LOG_BASE/fault-hit"; return 74 ;;
        partial) printf 'fault\n' >> "$LOG_BASE/fault-hit"; printf 'security/injection\n'; return 74 ;;
        unreadable) if [[ "$(id -u)" == 0 ]]; then return 74; fi ;;
      esac
    fi
    command jq "$@"
  }
  rc=0
  run_rounds 2 LENSES || rc=$?
  printf 'Registry fault reached: %s; rounds_rc=%s\n' "$registry_fault" "$rc"
  [[ "$registry_fault" == unreadable ]] || check test -s "$LOG_BASE/fault-hit"
  check test "$rc" -ne 0
  check test ! -f "$LOG_BASE/rounds/round-2/.completed"
  check test "$(cat "$LOG_BASE/executed")" = '1:security/injection'
  check test "$(wc -l < "$LOG_BASE/model-calls")" -eq 1
  check test -s "$LOG_BASE/rounds/round-1/dispatch.md"
  for reader in _rounds_meta_all_lens_entries _rounds_meta_active_lens_entries; do
    rc=0
    entries="$("$reader" "$LENSES_DIR" "$DOMAINS_FILE")" || rc=$?
    check test "$rc" -ne 0
    check test -z "$entries"
  done
  rc=0
  entries="$(_rounds_meta_dispatch_lens_entries "$LOG_BASE/rounds/round-1/dispatch.md")" || rc=$?
  check test "$rc" -ne 0
  check test -z "$entries"
  # Initial handoff parsing must preserve previous outputs on the same outage.
  raw_meta="$LOG_BASE/rounds/round-1/meta-orchestrator-output.txt"
  check grep -q 'LENS: injection' "$raw_meta"
  printf 'saved dispatch\n' > "$LOG_BASE/saved-dispatch.md"
  printf 'saved hypotheses\n' > "$LOG_BASE/saved-hypotheses.md"
  before="$(sha256sum "$LOG_BASE/saved-dispatch.md" "$LOG_BASE/saved-hypotheses.md")"
  rc=0
  _rounds_meta_parse_output "$raw_meta" "$LOG_BASE/saved-dispatch.md" "$LOG_BASE/saved-hypotheses.md" "$LENSES_DIR" || rc=$?
  check test "$rc" -ne 0
  check test "$(sha256sum "$LOG_BASE/saved-dispatch.md" "$LOG_BASE/saved-hypotheses.md")" = "$before"
  # Repair permissions/reader and resume the accepted handoff exactly once.
  chmod 600 "$DOMAINS_FILE"
  registry_broken=false break_registry=false RESUME_RUN_ID=probe
  check run_rounds 2 LENSES
  check test "$(grep -Fxc '2:security/injection' "$LOG_BASE/executed")" -eq 1
  check test "$(grep -Fxc '2:security/xss-csrf' "$LOG_BASE/executed")" -eq 1
  check test "$(wc -l < "$LOG_BASE/model-calls")" -eq 1
  check test -f "$LOG_BASE/rounds/round-2/.completed"
  # Unknown IDs in a readable catalog retain their warning-and-skip behavior.
  printf 'LENS: unknown-id\n' > "$LOG_BASE/unknown.md"
  entries="$(_rounds_meta_dispatch_lens_entries "$LOG_BASE/unknown.md")"
  check test -z "$entries"
  [[ "$FAIL" -eq 0 ]] || exit 1
  printf 'Results: registry %s failure and repaired resume passed\n' "$registry_fault"
); done
