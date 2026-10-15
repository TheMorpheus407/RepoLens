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

# Long canonical IDs must remain usable by heartbeat and parallel bookkeeping.
# shellcheck disable=SC2034 # Production functions consume these globals.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
# shellcheck source=/dev/null
source "$REPO/lib/parallel.sh"
# Extract only these production definitions; do not execute the CLI or agents.
eval "$(awk '/^(sanitize_heartbeat_component|lens_heartbeat_key|lens_heartbeat_path|lens_heartbeat_iteration_path|write_lens_heartbeat_iteration|write_lens_heartbeat)\(\)/,/^}/' "$REPO/repolens.sh")"
_REPOLENS_SEM_DIR="$FIXTURE/semaphore"
HEARTBEAT_DIR="$FIXTURE/heartbeat"
mkdir -p "$_REPOLENS_SEM_DIR" "$HEARTBEAT_DIR"
passed=0 failed=0
check() {
  if "$@"; then passed=$((passed + 1));
  else failed=$((failed + 1)); printf 'FAIL: %s\n' "$*"; fi
}
# Existing normal filenames remain compatible.
check test "$(_sem_token_path custom/r2-retry)" = "$_REPOLENS_SEM_DIR/custom_r2-retry.token"
check test "$(lens_heartbeat_path custom r2-retry)" = "$HEARTBEAT_DIR/custom__r2-retry.json"
for tail in a b; do
  lens_id="r2-$(printf '%0248d' 0 | tr '0' a)$tail"
  check sem_token_create "custom/$lens_id" 123
  token="$(_sem_token_path "custom/$lens_id")"
  check test -f "$token"
  check grep -q '^pid=123$' "$token"
  heartbeat="$(lens_heartbeat_path custom "$lens_id")"
  iteration="$(lens_heartbeat_iteration_path custom "$lens_id")"
  check write_lens_heartbeat_iteration "$iteration" 1
  check write_lens_heartbeat "$heartbeat" probe custom "$lens_id" 123 1 2026-10-15T00:00:00Z
  check jq -e --arg id "$lens_id" '.lens_id == $id and .iteration == 1' "$heartbeat"
done
check test "$(find "$_REPOLENS_SEM_DIR" -type f | wc -l)" -eq 2
check test "$(find "$HEARTBEAT_DIR" -type f | wc -l)" -eq 4
check sem_token_remove "custom/$lens_id"
check test ! -e "$token"
printf '%s checks passed; %s failed.\n' "$passed" "$failed"
test "$failed" -eq 0
