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

# Bind real CLI resume restoration to newly emitted polish markdown.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$SCRIPT_DIR/logs"
TEST_DIR="$(mktemp -d "$SCRIPT_DIR/logs/test-polish-resume-hours.XXXXXX")" || exit 1
trap 'rm -rf "$TEST_DIR"' EXIT
RUN_ID="${TEST_DIR##*/}"
mkdir -p "$TEST_DIR/bin" "$TEST_DIR/polish"
printf '6\n' > "$TEST_DIR/task-hours"
cat > "$TEST_DIR/polish/suggestions.json" <<'JSON'
[{"title":"Clarify CLI loading","domain":"effort-signal","lens_id":"loading-transparency","source_path":"repolens.sh","polish_family":"effort-signal","voice_fit":"strong","voice_fit_justification":"Matches the direct CLI voice.","location_expectedness":"expected","body":"## Polish Summary\nClarify the running operation."}]
JSON
cat > "$TEST_DIR/bin/codex" <<'AGENT'
#!/usr/bin/env bash
set -uo pipefail
printf 'called\n' >> "$AGENT_CALLS"
printf 'DONE\n'
AGENT
chmod +x "$TEST_DIR/bin/codex"
export AGENT_CALLS="$TEST_DIR/agent-calls"
env -u TASK_HOURS -u REPOLENS_ROUNDS -u DONE_STREAK_REQUIRED \
  PATH="$TEST_DIR/bin:$PATH" REPOLENS_AGENT_TIMEOUT=5 REPOLENS_AGENT_KILL_GRACE=1 \
  REPOLENS_LENS_HEARTBEAT_INTERVAL=0 REPOLENS_STATUS_INTERVAL=1 \
  bash "$SCRIPT_DIR/repolens.sh" --project "$SCRIPT_DIR" --agent codex --mode polish \
    --local --yes --resume "$RUN_ID" --focus loading-transparency --rounds 1 --depth 1 \
    > "$TEST_DIR/cli.out" 2>&1
rc=$?
body="$TEST_DIR/polish/filed/effort-signal-loading-transparency.md"
if (( rc != 0 )) || [[ ! -s "$AGENT_CALLS" || ! -s "$body" ]] \
    || ! grep -q 'approximately 6 hours' "$body" \
    || grep -q 'approximately one hour' "$body"; then
  cat "$TEST_DIR/cli.out"
  printf 'FAIL: CLI resume must emit a new six-hour polish shortlist\n'
  exit 1
fi
printf 'PASS: real CLI resume emits new polish markdown using saved task-hours=6\n'
