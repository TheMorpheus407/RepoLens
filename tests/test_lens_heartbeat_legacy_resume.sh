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
eval "$(awk '/^(sanitize_heartbeat_component|lens_heartbeat_key|lens_heartbeat_path|lens_heartbeat_iteration_path|retire_legacy_lens_heartbeat|run_lens)\(\)/,/^}/' "$REPO/repolens.sh")"
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
  run_lens "custom/$lens_id"
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
run_lens custom/retry
test "$(cat "$ordinary")" = current
# Longer IDs have no valid legacy basename; cleanup must still allow resume.
lens_id="r2-$(printf '%0300d' 0 | tr '0' a)"
run_lens "custom/$lens_id"
test "$(cat "$unrelated")" = unrelated
printf 'PASS: resumed completed lenses retire legacy artifacts, including disabled heartbeats.\n'
