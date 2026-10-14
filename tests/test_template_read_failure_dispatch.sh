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

# Reuses the regression from f7614721d8b34f12b9f9a1fe332a04fc97e193d7 (#429).
# #428: template read failures stop dispatch and leave failed lenses resumable.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$SCRIPT_DIR/logs"
TEST_DIR="$(mktemp -d "$SCRIPT_DIR/logs/test-template-read.XXXXXX")" || exit 1
CASE_DIRS=()
trap 'rm -rf "$TEST_DIR" "${CASE_DIRS[@]}"' EXIT
mkdir -p "$TEST_DIR/bin"
REAL_CAT="$(command -v cat)"
export REAL_CAT
cat > "$TEST_DIR/bin/cat" <<'CAT'
#!/usr/bin/env bash
set -uo pipefail
if [[ "$#" -eq 1 && "$1" == "${FAIL_TEMPLATE:-}" ]]; then
  printf 'Partial template read.'
  exit 42
fi
exec "$REAL_CAT" "$@"
CAT
cat > "$TEST_DIR/bin/codex" <<'AGENT'
#!/usr/bin/env bash
set -uo pipefail
printf 'called\n' >> "$AGENT_CALLS"
printf 'DONE\n'
AGENT
# Every forge command stays in this shim, including auth and label bootstrap.
cat > "$TEST_DIR/bin/gh" <<'FORGE'
#!/usr/bin/env bash
set -uo pipefail
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
# A failed base read must return no partial prompt, including an actual missing file.
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/template.sh"
mkdir "$TEST_DIR/directory-base"
for template in "$TEST_DIR/missing-base.md" "$TEST_DIR/directory-base" "$SCRIPT_DIR/prompts/_base/audit.md"; do
  if [[ -f "$template" ]]; then export FAIL_TEMPLATE="$template"; else unset FAIL_TEMPLATE; fi
  rendered="$(compose_prompt "$template" "$SCRIPT_DIR/prompts/lenses/security/injection.md" '' '' audit)"
  render_rc=$?
  check test "$render_rc" -ne 0
  check test -z "$rendered"
done
unset FAIL_TEMPLATE
printf 'Plan a small command-line audit tool.\n' > "$TEST_DIR/spec.md"

for mode in audit greenfield; do
  for sink in local forge blocked-marker; do
    LOG_BASE="$(mktemp -d "$SCRIPT_DIR/logs/test-template-$mode-$sink.XXXXXX")" || exit 1
    CASE_DIRS+=("$LOG_BASE")
    RUN_ID="${LOG_BASE#"$SCRIPT_DIR/logs/"}"
    export FAIL_TEMPLATE="$SCRIPT_DIR/prompts/_base/$mode.md"
    export AGENT_CALLS="$LOG_BASE/agent-calls"
    if [[ "$sink" == blocked-marker ]]; then mkdir "$LOG_BASE/.systemic-failure-abort"; fi
    args=(--mode "$mode" --resume "$RUN_ID" --rounds 1 --depth 1)
    if [[ "$mode" == greenfield ]]; then
      args+=(--spec "$TEST_DIR/spec.md" --focus backlog-planning)
    else
      args+=(--focus injection)
    fi
    if [[ "$sink" != forge ]]; then
      args+=(--local --output "$LOG_BASE/output")
    else
      args+=(--forge gh)
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
    check test ! -e "$LOG_BASE/rounds/round-1/.completed"
    check test ! -s "$LOG_BASE/.completed"
    check json_matches '.state == "failed"' "$LOG_BASE/status.json"
    if [[ "$mode" == audit && "$sink" == local ]]; then
      # Once readable, the same run clears the abort and retries the lens.
      unset FAIL_TEMPLATE
      env -u TASK_HOURS -u REPOLENS_ROUNDS -u DONE_STREAK_REQUIRED \
        REPOLENS_AGENT_TIMEOUT=5 REPOLENS_AGENT_KILL_GRACE=1 \
        REPOLENS_LENS_HEARTBEAT_INTERVAL=0 REPOLENS_STATUS_INTERVAL=1 \
        bash "$SCRIPT_DIR/repolens.sh" --project "$SCRIPT_DIR" --agent codex --yes \
          "${args[@]}" > "$LOG_BASE/resume.out" 2>&1
      resume_rc=$?
      check test "$resume_rc" -eq 0
      check test -s "$AGENT_CALLS"
      check test ! -e "$LOG_BASE/.systemic-failure-abort"
      check test -s "$LOG_BASE/.completed"
      check json_matches '.state == "finished-empty"' "$LOG_BASE/status.json"
      # Retry also clears a prompt error if its companion marker was lost.
      jq '.stopped_reason = "prompt-render-failed"' "$LOG_BASE/summary.json" > "$LOG_BASE/seed.json"
      mv "$LOG_BASE/seed.json" "$LOG_BASE/summary.json"
      env -u TASK_HOURS -u REPOLENS_ROUNDS -u DONE_STREAK_REQUIRED \
        REPOLENS_LENS_HEARTBEAT_INTERVAL=0 REPOLENS_STATUS_INTERVAL=1 \
        bash "$SCRIPT_DIR/repolens.sh" --project "$SCRIPT_DIR" --agent codex --yes \
          "${args[@]}" > "$LOG_BASE/resume-marker-lost.out" 2>&1
      check test "$?" -eq 0
      check json_matches '.stopped_reason == null' "$LOG_BASE/summary.json"
    fi
  done
done

# The between-round meta caller must also stop before writing or dispatching.
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/template.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/rounds.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/summary.sh"
LOG_BASE="$TEST_DIR/meta"
mkdir -p "$LOG_BASE"
SUMMARY_FILE="$LOG_BASE/summary.json"
printf '{"stopped_reason":null}\n' > "$SUMMARY_FILE"
RUN_ID="${LOG_BASE#"$SCRIPT_DIR/logs/"}"
BASE_PROMPTS_DIR="$SCRIPT_DIR/prompts/_base"
export MODE=audit AGENT=codex
export FAIL_TEMPLATE="$BASE_PROMPTS_DIR/meta_orchestrator.md"
export AGENT_CALLS="$TEST_DIR/meta-agent-calls"
log_info() { :; }
log_warn() { printf '%s\n' "$*"; }
run_agent() { printf 'called\n' >> "$AGENT_CALLS"; printf 'NO_FRESH_ANGLES\n'; }
run_meta_orchestrator "$TEST_DIR/meta/round-1" "$TEST_DIR/meta/round-2"
meta_rc=$?
check test "$meta_rc" -ne 0
check test ! -e "$AGENT_CALLS"
check test ! -e "$TEST_DIR/meta/round-1/meta-orchestrator-prompt.md"
check test "${REPOLENS_FINAL_STATE:-}" = failed
check json_matches '.stopped_reason == "prompt-render-failed"' "$SUMMARY_FILE"
check test -s "$LOG_BASE/.systemic-failure-abort"
check test "$(_rounds_agent_abort_reason)" = prompt-render-failed

# Missing templates must use the same diagnostic path, including signal precedence.
BASE_PROMPTS_DIR="$TEST_DIR/no-templates"
rm -f "$LOG_BASE/.systemic-failure-abort"
printf '{"stopped_reason":null}\n' > "$SUMMARY_FILE"
REPOLENS_FINAL_STATE=interrupted
run_meta_orchestrator "$TEST_DIR/meta/missing/round-1" "$TEST_DIR/meta/missing/round-2"
check test "$?" -ne 0
check test "$REPOLENS_FINAL_STATE" = interrupted
check json_matches '.stopped_reason == "interrupted-sigint"' "$SUMMARY_FILE"
check test -f "$LOG_BASE/.systemic-failure-abort"
check test ! -e "$AGENT_CALLS"

printf 'Results: %s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
