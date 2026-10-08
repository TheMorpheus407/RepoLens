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

# #428: a blocked lens abort marker must still fail the round and allow retry.
# Pass --parallel inside a delegated process scope to also exercise real workers.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$SCRIPT_DIR/logs"
TEST_DIR="$(mktemp -d "$SCRIPT_DIR/logs/test-lens-marker.XXXXXX")" || exit 1
CASE_DIRS=()
trap 'rm -rf "$TEST_DIR" "${CASE_DIRS[@]}"' EXIT
mkdir -p "$TEST_DIR/bin"
export REAL_CAT
REAL_CAT="$(command -v cat)"
cat > "$TEST_DIR/bin/cat" <<'CAT'
#!/usr/bin/env bash
if [[ "$#" -eq 1 && "$1" == "${FAIL_TEMPLATE:-}" ]]; then
  printf 'Partial template read.'
  exit 42
fi
exec "$REAL_CAT" "$@"
CAT
cat > "$TEST_DIR/bin/codex" <<'AGENT'
#!/usr/bin/env bash
printf 'called\n' >> "$AGENT_CALLS"
printf 'DONE\n'
AGENT
cat > "$TEST_DIR/bin/gh" <<'FORGE'
#!/usr/bin/env bash
printf '[]\n'
FORGE
chmod +x "$TEST_DIR/bin/"*
export PATH="$TEST_DIR/bin:$PATH"
passed=0
failed=0
check() {
  if "$@"; then passed=$((passed + 1)); else failed=$((failed + 1)); printf 'FAIL: %s\n' "$*"; fi
}
json_matches() { jq -e "$@" >/dev/null; }
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/clean.sh"
is_complete() { ! _clean_is_incomplete "$@"; }
printf 'Plan a small command-line audit tool.\n' > "$TEST_DIR/spec.md"

for mode in audit greenfield; do
  for sink in local forge; do
    LOG_BASE="$(mktemp -d "$SCRIPT_DIR/logs/test-lens-marker-$mode-$sink.XXXXXX")" || exit 1
    CASE_DIRS+=("$LOG_BASE")
    RUN_ID="${LOG_BASE##*/}"
    # The rest of the log directory remains writable, isolating marker failure.
    mkdir "$LOG_BASE/.systemic-failure-abort"
    export FAIL_TEMPLATE="$SCRIPT_DIR/prompts/_base/$mode.md"
    export AGENT_CALLS="$LOG_BASE/agent-calls"
    args=(--mode "$mode" --resume "$RUN_ID" --rounds 1 --depth 1)
    if [[ "$mode" == greenfield ]]; then
      args+=(--spec "$TEST_DIR/spec.md" --focus backlog-planning)
    else
      args+=(--focus injection)
    fi
    if [[ "$sink" == local ]]; then
      args+=(--local --output "$LOG_BASE/output")
    else
      args+=(--forge gh)
    fi
    if [[ "${1:-}" == --parallel ]]; then
      args+=(--parallel --max-parallel 2)
    fi
    env -u TASK_HOURS -u REPOLENS_ROUNDS -u DONE_STREAK_REQUIRED \
      REPOLENS_AGENT_TIMEOUT=5 REPOLENS_AGENT_KILL_GRACE=1 \
      REPOLENS_LENS_HEARTBEAT_INTERVAL=0 REPOLENS_STATUS_INTERVAL=1 \
      bash "$SCRIPT_DIR/repolens.sh" --project "$SCRIPT_DIR" --agent codex --yes \
        "${args[@]}" > "$LOG_BASE/cli.out" 2>&1
    cli_rc=$?
    check test "$cli_rc" -ne 0
    check test ! -e "$AGENT_CALLS"
    check json_matches '.stopped_reason == "prompt-render-failed" and any(.lenses[]; .status == "prompt-render-failed")' "$LOG_BASE/summary.json"
    check json_matches '.state == "failed"' "$LOG_BASE/status.json"
    check json_matches '.[-1].status == "failed" and .[-1].exit_code != 0 and .[-1].why_stopped == "prompt-render-failed"' "$LOG_BASE/attempts.json"
    check test ! -s "$LOG_BASE/.completed"
    check test ! -e "$LOG_BASE/rounds/round-1/.completed"
    check test ! -e "$LOG_BASE/.rounds/round-1.completed"
    check grep -qF 'Unable to persist systemic-abort marker' "$LOG_BASE/cli.out"
    check _clean_is_incomplete "$LOG_BASE"
    if [[ "$sink" == local ]]; then
      # Recovery has no regular abort marker to trigger the old cleanup block.
      rmdir "$LOG_BASE/.systemic-failure-abort"
      unset FAIL_TEMPLATE
      env -u TASK_HOURS -u REPOLENS_ROUNDS -u DONE_STREAK_REQUIRED \
        REPOLENS_AGENT_TIMEOUT=5 REPOLENS_AGENT_KILL_GRACE=1 \
        REPOLENS_LENS_HEARTBEAT_INTERVAL=0 REPOLENS_STATUS_INTERVAL=1 \
        bash "$SCRIPT_DIR/repolens.sh" --project "$SCRIPT_DIR" --agent codex --yes \
          "${args[@]}" > "$LOG_BASE/resume.out" 2>&1
      resume_rc=$?
      check test "$resume_rc" -eq 0
      check test -s "$AGENT_CALLS"
      check test -s "$LOG_BASE/.completed"
      check test -f "$LOG_BASE/rounds/round-1/.completed"
      check json_matches '.state == "finished-empty"' "$LOG_BASE/status.json"
      check json_matches '.stopped_reason == null' "$LOG_BASE/summary.json"
      check json_matches '.[-1].status == "finished-empty" and .[-1].exit_code == 0 and .[-1].why_stopped == ""' "$LOG_BASE/attempts.json"
      check is_complete "$LOG_BASE"
    fi
  done
done

printf 'Results: %s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
