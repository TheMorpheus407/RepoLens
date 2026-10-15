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

# Run the real run_lens resume guard: completed work must retire old heartbeat
# names too, without starting an agent or touching another lens's heartbeat.
# shellcheck disable=SC2034,SC2329 # Extracted production functions consume globals/mocks.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
# shellcheck source=/dev/null
source "$REPO/lib/core.sh"
eval "$(awk '/^(sanitize_heartbeat_component|lens_heartbeat_key|lens_heartbeat_path|lens_heartbeat_iteration_path|retire_legacy_lens_heartbeat|run_lens)\(\)/,/^}/' "$REPO/repolens.sh" | sed 's/^run_lens()/production_run_lens()/')"
# Keep the real function separate from the later rounds callback mock.
declare -F production_run_lens >/dev/null || exit 1
log_info() { :; }
is_lens_completed() { return 0; }
LOCAL_MODE=true MODE=audit
LENSES_DIR="$FIXTURE/lenses" BASE_WRAPPER_FILE="$FIXTURE/base.md"
HEARTBEAT_DIR="$FIXTURE/heartbeat"
mkdir -p "$HEARTBEAT_DIR"
lens_id="r2-$(printf '%0200d' 0 | tr '0' a)"
legacy="$HEARTBEAT_DIR/custom__$lens_id.json"
legacy_iteration="$HEARTBEAT_DIR/.custom__$lens_id.iteration"
unrelated="$HEARTBEAT_DIR/custom__other.json"
printf 'unrelated\n' > "$unrelated"
for interval in 15 0; do
  REPOLENS_LENS_HEARTBEAT_INTERVAL="$interval"
  printf '{"domain":"custom","lens_id":"%s","state":"running"}\n' "$lens_id" > "$legacy"
  printf '1\n' > "$legacy_iteration"
  printf 'partial\n' > "$legacy.tmp.123"
  printf 'partial\n' > "$legacy_iteration.tmp.123"
  production_run_lens "custom/$lens_id"
  test ! -e "$legacy" || {
    printf 'FAIL: run_lens leaves a legacy heartbeat for a completed lens.\n' >&2
    exit 1
  }
  test ! -e "$legacy_iteration"
  test ! -e "$legacy.tmp.123"
  test ! -e "$legacy_iteration.tmp.123"
  test "$(cat "$unrelated")" = unrelated
done
# Ordinary paths remain compatible; cleanup must not remove their current file.
ordinary="$(lens_heartbeat_path custom retry)"
printf 'current\n' > "$ordinary"
production_run_lens custom/retry
test "$(cat "$ordinary")" = current
# Longer IDs have no valid legacy basename; cleanup must still allow resume.
lens_id="r2-$(printf '%0300d' 0 | tr '0' a)"
production_run_lens "custom/$lens_id"
test "$(cat "$unrelated")" = unrelated
printf 'PASS: resumed completed lenses retire legacy artifacts, including disabled heartbeats.\n'

# Completed-round shortcuts must retire artifacts without calling run_lens.
# shellcheck source=/dev/null
source "$REPO/lib/rounds.sh"
log_warn() { :; }
set_stop_reason() { :; }
record_lens() { :; }
compose_prompt() { printf 'mock prompt'; }
run_agent() {
  if [[ "$scenario" == saturated ]]; then printf 'NO_FRESH_ANGLES\n';
  else printf 'CUSTOM: %s\nDraft prompt:\nInspect retries.\n' "$category"; fi
}
run_lens() {
  local canonical role focus anchor exclude
  _rounds_meta_tuple_parse "$1" canonical role focus anchor exclude
  printf '%s\n' "$canonical" >> "$LOG_BASE/callbacks"
  printf '%s\n' "$canonical" >> "$completed_lenses_file"
}
build_round_digest() { mkdir -p "$1"; printf 'mock digest\n' > "$1/digest.md"; }
LOCAL_MODE=false PARALLEL=false AGENT=mock RUN_ID="legacy-resume"
LENSES_DIR="$REPO/prompts/lenses" PROJECT_PATH="$FIXTURE"
category="$(printf '%0200d' 0 | tr '0' a)"
LENSES=("custom/r1-$category")
for scenario in handoff saturated; do
  LOG_BASE="$FIXTURE/$scenario"
  HEARTBEAT_DIR="$LOG_BASE/.heartbeat"
  SUMMARY_FILE="$LOG_BASE/summary.json"
  completed_lenses_file="$LOG_BASE/.completed"
  mkdir -p "$HEARTBEAT_DIR"
  run_rounds 2 LENSES || exit $?
  callbacks="$(wc -l < "$LOG_BASE/callbacks")"
  test "$callbacks" -eq "$([[ "$scenario" == handoff ]] && printf 2 || printf 1)"
  for interval in 15 0; do
    REPOLENS_LENS_HEARTBEAT_INTERVAL="$interval"
    for round in 1 2; do
      [[ "$scenario" == handoff || "$round" == 1 ]] || continue
      legacy="$HEARTBEAT_DIR/custom__r$round-$category.json"
      legacy_iteration="$HEARTBEAT_DIR/.custom__r$round-$category.iteration"
      printf '{"domain":"custom","lens_id":"r%s-%s","state":"running"}\n' "$round" "$category" > "$legacy"
      printf '1\n' > "$legacy_iteration"
      printf partial > "$legacy.tmp.123"
      printf partial > "$legacy_iteration.tmp.123"
    done
    printf unrelated > "$HEARTBEAT_DIR/custom__other.json"
    RESUME_RUN_ID="legacy-resume"
    run_rounds 2 LENSES || exit $?
    test "$(wc -l < "$LOG_BASE/callbacks")" -eq "$callbacks"
    for round in 1 2; do
      test ! -e "$HEARTBEAT_DIR/custom__r$round-$category.json" || {
        printf 'FAIL: completed %s round %s retains legacy heartbeat.\n' "$scenario" "$round" >&2
        exit 1
      }
      test ! -e "$HEARTBEAT_DIR/.custom__r$round-$category.iteration"
      test ! -e "$HEARTBEAT_DIR/custom__r$round-$category.json.tmp.123"
      test ! -e "$HEARTBEAT_DIR/.custom__r$round-$category.iteration.tmp.123"
    done
    test "$(cat "$HEARTBEAT_DIR/custom__other.json")" = unrelated
  done
done
printf 'PASS: verified handoff, final-round and saturation shortcuts retire legacy artifacts without callbacks.\n'
