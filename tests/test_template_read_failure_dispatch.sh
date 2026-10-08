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
if [[ "$#" -eq 1 && "$1" == "${FAIL_TEMPLATE:-}" ]]; then
  printf 'Partial template read.'
  exit 42
fi
exec "$REAL_CAT" "$@"
CAT
cat > "$TEST_DIR/bin/codex" <<'AGENT'
#!/usr/bin/env bash
# Capture the recovered handoff and lens context only for the multi-round case.
if [[ -n "${HANDOFF_CAPTURE:-}" ]]; then
  prompt="${!#}"
  if [[ "$prompt" == *'You are the META-ORCHESTRATOR'* ]]; then
    printf 'meta\n' >> "$AGENT_CALLS"
    cat <<'DISPATCH'
LENS: xss-csrf - `repolens.sh:1`; investigate a fresh angle.
HYPOTHESES_TO_VERIFY:
- Recovered handoff hypothesis.
DISPATCH
    exit 0
  fi
  printf 'lens\n' >> "$AGENT_CALLS"
  printf '%s\n' "$prompt" > "$HANDOFF_CAPTURE/last-lens-prompt.md"
else
  printf 'called\n' >> "$AGENT_CALLS"
fi
printf 'DONE\n'
AGENT
# Every forge command stays in this shim, including auth and label bootstrap.
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
printf 'Plan a small command-line audit tool.\n' > "$TEST_DIR/spec.md"

for mode in audit greenfield; do
  for sink in local forge; do
    LOG_BASE="$(mktemp -d "$SCRIPT_DIR/logs/test-template-$mode-$sink.XXXXXX")" || exit 1
    CASE_DIRS+=("$LOG_BASE")
    RUN_ID="${LOG_BASE#"$SCRIPT_DIR/logs/"}"
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
    env -u TASK_HOURS -u REPOLENS_ROUNDS -u DONE_STREAK_REQUIRED \
      REPOLENS_AGENT_TIMEOUT=5 REPOLENS_AGENT_KILL_GRACE=1 \
      REPOLENS_LENS_HEARTBEAT_INTERVAL=0 REPOLENS_STATUS_INTERVAL=1 \
      bash "$SCRIPT_DIR/repolens.sh" --project "$SCRIPT_DIR" --agent codex --yes \
        "${args[@]}" > "$LOG_BASE/cli.out" 2>&1
    cli_rc=$?
    check test "$cli_rc" -ne 0
    check test ! -e "$AGENT_CALLS"
    check json_matches '.stopped_reason == "prompt-render-failed" and any(.lenses[]; .status == "prompt-render-failed")' "$LOG_BASE/summary.json"
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
    fi
  done
done

# A meta render failure must use the normal abort recovery path on CLI resume.
# Round-1 lens work completes before meta rendering fails. Resume must retry
# the pending handoff, preserve that work, and use its selection and hypotheses.
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/clean.sh"
is_complete() { ! _clean_is_incomplete "$@"; }
LOG_BASE="$(mktemp -d "$SCRIPT_DIR/logs/test-template-meta-resume.XXXXXX")" || exit 1
CASE_DIRS+=("$LOG_BASE")
RUN_ID="${LOG_BASE##*/}"
export FAIL_TEMPLATE="$SCRIPT_DIR/prompts/_base/meta_orchestrator.md"
export AGENT_CALLS="$LOG_BASE/agent-calls"
export HANDOFF_CAPTURE="$LOG_BASE"
args=(--mode bugreport --bug-report 'Check the audit output.' --no-triage --strategy fanout
  --local --focus injection --resume "$RUN_ID" --rounds 2 --depth 1)
env -u TASK_HOURS -u REPOLENS_ROUNDS -u DONE_STREAK_REQUIRED \
  REPOLENS_AGENT_TIMEOUT=5 REPOLENS_AGENT_KILL_GRACE=1 \
  REPOLENS_LENS_HEARTBEAT_INTERVAL=0 REPOLENS_STATUS_INTERVAL=1 \
  bash "$SCRIPT_DIR/repolens.sh" --project "$SCRIPT_DIR" --agent codex --yes \
    "${args[@]}" > "$LOG_BASE/cli.out" 2>&1
cli_rc=$?
check test "$cli_rc" -ne 0
check json_matches '.state == "failed"' "$LOG_BASE/status.json"
check json_matches '.stopped_reason == "prompt-render-failed"' "$LOG_BASE/summary.json"
check test ! -e "$LOG_BASE/rounds/round-1/.completed"
check test ! -e "$LOG_BASE/.rounds/round-1.completed"
check grep -qxF 'security/injection' "$LOG_BASE/.rounds/round-1.lenses.completed"
check test "$(wc -l < "$AGENT_CALLS")" -eq 1
check test ! -e "$LOG_BASE/rounds/round-2/.completed"
check test -f "$LOG_BASE/.systemic-failure-abort"
check _clean_is_incomplete "$LOG_BASE"
unset FAIL_TEMPLATE
env -u TASK_HOURS -u REPOLENS_ROUNDS -u DONE_STREAK_REQUIRED \
  REPOLENS_AGENT_TIMEOUT=5 REPOLENS_AGENT_KILL_GRACE=1 \
  REPOLENS_LENS_HEARTBEAT_INTERVAL=0 REPOLENS_STATUS_INTERVAL=1 \
  bash "$SCRIPT_DIR/repolens.sh" --project "$SCRIPT_DIR" --agent codex --yes \
    "${args[@]}" > "$LOG_BASE/resume.out" 2>&1
resume_rc=$?
check test "$resume_rc" -eq 0
check test ! -e "$LOG_BASE/.systemic-failure-abort"
check test -f "$LOG_BASE/rounds/round-1/.completed"
check test -f "$LOG_BASE/rounds/round-2/.completed"
check json_matches '.state == "finished-empty"' "$LOG_BASE/status.json"
check json_matches '.stopped_reason == null' "$LOG_BASE/summary.json"
check json_matches '.[-1].status == "finished-empty" and .[-1].why_stopped == ""' "$LOG_BASE/attempts.json"
check test "$(cat "$AGENT_CALLS")" = $'lens\nmeta\nlens'
check test -s "$LOG_BASE/rounds/round-1/meta-orchestrator-prompt.md"
check grep -qxF 'LENS: xss-csrf' "$LOG_BASE/rounds/round-1/dispatch.md"
check grep -qxF 'security/xss-csrf' "$LOG_BASE/.rounds/round-2.lenses.completed"
check test "$(wc -l < "$LOG_BASE/.rounds/round-1.lenses.completed")" -eq 1
check grep -qF 'Recovered handoff hypothesis.' "$LOG_BASE/last-lens-prompt.md"
check is_complete "$LOG_BASE"
unset HANDOFF_CAPTURE

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
check test "$REPOLENS_FINAL_STATE" = failed
check json_matches '.stopped_reason == "prompt-render-failed"' "$SUMMARY_FILE"
check test -f "$LOG_BASE/.systemic-failure-abort"
check test "$(_rounds_agent_abort_reason)" = prompt-render-failed

printf 'Results: %s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
