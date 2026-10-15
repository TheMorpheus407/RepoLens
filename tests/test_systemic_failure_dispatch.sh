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

# repolens-r5-p1-3: failed diagnostic persistence cannot hide agent failure.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$SCRIPT_DIR/logs"
TEST_DIR="$(mktemp -d "$SCRIPT_DIR/logs/test-systemic-dispatch.XXXXXX")" || exit 1
CASE_DIRS=()
trap 'rm -rf "$TEST_DIR" "${CASE_DIRS[@]}"' EXIT
mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/codex" <<'AGENT'
#!/usr/bin/env bash
set -uo pipefail
printf 'called\n' >> "$AGENT_CALLS"
if [[ "${FAIL_AGENT:-true}" == true ]]; then
  printf 'not logged in; please run /login\n'
  exit 1
fi
printf 'DONE\n'
AGENT
cat > "$TEST_DIR/bin/gh" <<'FORGE'
#!/usr/bin/env bash
set -uo pipefail
printf '[]\n'
FORGE
chmod +x "$TEST_DIR/bin/"*
export PATH="$TEST_DIR/bin:$PATH"
passed=0 failed=0
check() {
  if "$@"; then passed=$((passed + 1)); else failed=$((failed + 1)); printf 'FAIL: %s\n' "$*"; fi
}
json_matches() { jq -e "$@" >/dev/null; }
for marker in writable blocked; do
  LOG_BASE="$SCRIPT_DIR/logs/${TEST_DIR##*/}-$marker"
  CASE_DIRS+=("$LOG_BASE")
  mkdir -p "$LOG_BASE"
  RUN_ID="${LOG_BASE#"$SCRIPT_DIR/logs/"}"
  export AGENT_CALLS="$LOG_BASE/agent-calls" FAIL_AGENT=true
  if [[ "$marker" == blocked ]]; then mkdir "$LOG_BASE/.systemic-failure-abort"; fi
  args=(--mode audit --resume "$RUN_ID" --rounds 1 --depth 1 --focus injection --local --output "$LOG_BASE/output")
  env -u TASK_HOURS -u REPOLENS_ROUNDS -u DONE_STREAK_REQUIRED \
    REPOLENS_AGENT_TIMEOUT=5 REPOLENS_AGENT_KILL_GRACE=1 \
    REPOLENS_LENS_HEARTBEAT_INTERVAL=0 REPOLENS_STATUS_INTERVAL=1 \
    bash "$SCRIPT_DIR/repolens.sh" --project "$SCRIPT_DIR" --agent codex --yes \
      "${args[@]}" > "$LOG_BASE/cli.out" 2>&1
  check test "$?" -ne 0
  check test "$(wc -l < "$AGENT_CALLS")" -eq 1
  check json_matches 'any(.lenses[]; .status == "auth-expired")' "$LOG_BASE/summary.json"
  check json_matches '.state == "failed"' "$LOG_BASE/status.json"
  check test ! -f "$LOG_BASE/rounds/round-1/.completed"
  check test ! -s "$LOG_BASE/.completed"
  # The identical pending lens must run successfully once authentication recovers.
  if [[ "$marker" == blocked ]]; then rmdir "$LOG_BASE/.systemic-failure-abort"; fi
  export FAIL_AGENT=false
  env -u TASK_HOURS -u REPOLENS_ROUNDS -u DONE_STREAK_REQUIRED \
    REPOLENS_AGENT_TIMEOUT=5 REPOLENS_AGENT_KILL_GRACE=1 \
    REPOLENS_LENS_HEARTBEAT_INTERVAL=0 REPOLENS_STATUS_INTERVAL=1 \
    bash "$SCRIPT_DIR/repolens.sh" --project "$SCRIPT_DIR" --agent codex --yes \
      "${args[@]}" > "$LOG_BASE/resume.out" 2>&1
  check test "$?" -eq 0
  check test "$(wc -l < "$AGENT_CALLS")" -gt 1
  check test -s "$LOG_BASE/.completed"
done
printf 'Results: %s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
