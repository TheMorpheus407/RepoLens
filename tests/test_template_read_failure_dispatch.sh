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
REAL_AWK="$(command -v awk)"
REAL_SED="$(command -v sed)"
export REAL_CAT REAL_AWK REAL_SED
cat > "$TEST_DIR/bin/cat" <<'CAT'
#!/usr/bin/env bash
set -uo pipefail
if [[ "$#" -eq 1 && "$1" == "${FAIL_TEMPLATE:-}" ]]; then
  printf 'Partial template read.'
  exit 42
fi
exec "$REAL_CAT" "$@"
CAT
cat > "$TEST_DIR/bin/awk" <<'AWK'
#!/usr/bin/env bash
set -uo pipefail
for arg in "$@"; do
  if [[ "$arg" == "${DENY_LENS:-}" ]]; then
    printf 'awk: %s: Permission denied\n' "$arg" >&2
    exit 13
  fi
  if [[ "$arg" == "${FAIL_LENS:-}" ]]; then
    printf 'Partial lens read.'
    exit 42
  fi
done
exec "$REAL_AWK" "$@"
AWK
cat > "$TEST_DIR/bin/sed" <<'SED'
#!/usr/bin/env bash
set -uo pipefail
if [[ "${!#}" == "${FAIL_SPEC:-}" ]]; then
  printf 'Partial spec read.'
  exit 42
fi
exec "$REAL_SED" "$@"
SED
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
# Run one assertion, accumulate its result, and print failures for the runner.
check() {
  if "$@"; then passed=$((passed + 1)); else failed=$((failed + 1)); printf 'FAIL: %s\n' "$*"; fi
}
# Accept only JSON matching the supplied jq predicate; suppress query output.
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
# Lens read errors, including partial reads, must discard the entire prompt.
# Inject permission denial so this case also works with read-bypass privileges.
printf '%s\n' '---' 'id: unreadable-lens' '---' 'Unreadable lens' > "$TEST_DIR/unreadable-lens.md"
for lens in "$TEST_DIR/missing-lens.md" "$TEST_DIR/unreadable-lens.md" "$SCRIPT_DIR/prompts/lenses/security/injection.md"; do
  if [[ "$lens" == "$TEST_DIR/unreadable-lens.md" ]]; then export DENY_LENS="$lens"; else unset DENY_LENS; fi
  if [[ "$lens" == "$SCRIPT_DIR/prompts/lenses/security/injection.md" ]]; then export FAIL_LENS="$lens"; else unset FAIL_LENS; fi
  rendered="$(compose_prompt "$SCRIPT_DIR/prompts/_base/audit.md" "$lens" '' '' audit)"
  render_rc=$?
  check test "$render_rc" -ne 0
  check test -z "$rendered"
done
unset FAIL_LENS DENY_LENS
printf 'Plan a small command-line audit tool.\n' > "$TEST_DIR/spec.md"

# repolens-r5-p1-4: every requested file-backed context is atomic.
printf 'Actual nonempty branch delta\n' > "$TEST_DIR/context.md"
for key in PRIOR_ROUND_DIGEST HYPOTHESES_TO_VERIFY BUG_REPORT TRIAGE_CONTEXT_PACK PRIOR_FINDING_ANCHOR CURRENT_BACKLOG VOICE_PROFILE SPEC_DIFF BRANCH_DIFF_SUMMARY; do
  export FAIL_TEMPLATE="$TEST_DIR/context.md"
  rendered="$(compose_prompt "$SCRIPT_DIR/prompts/_base/audit.md" "$SCRIPT_DIR/prompts/lenses/security/injection.md" "$key=@$TEST_DIR/context.md" '' audit)"
  check test "$?" -ne 0
  check test -z "$rendered"
  unset FAIL_TEMPLATE
  rendered="$(compose_prompt "$SCRIPT_DIR/prompts/_base/audit.md" "$SCRIPT_DIR/prompts/lenses/security/injection.md" "$key=@$TEST_DIR/missing-context.md" '' audit)"
  check test "$?" -ne 0
  check test -z "$rendered"
done
rendered="$(compose_prompt "$SCRIPT_DIR/prompts/_base/branch-review.md" "$SCRIPT_DIR/prompts/lenses/security/injection.md" "BRANCH_DIFF_SUMMARY=@$TEST_DIR/context.md" '' branch-review)"
check test "$?" -eq 0
check grep -Fq 'Actual nonempty branch delta' <<< "$rendered"
for mode in audit greenfield; do
  export FAIL_SPEC="$TEST_DIR/spec.md"
  rendered="$(compose_prompt "$SCRIPT_DIR/prompts/_base/$mode.md" "$SCRIPT_DIR/prompts/lenses/security/injection.md" '' "$TEST_DIR/spec.md" "$mode")"
  check test "$?" -ne 0
  check test -z "$rendered"
  unset FAIL_SPEC
  rendered="$(compose_prompt "$SCRIPT_DIR/prompts/_base/$mode.md" "$SCRIPT_DIR/prompts/lenses/security/injection.md" '' "$TEST_DIR/spec.md" "$mode")"
  check test "$?" -eq 0
  check grep -Fq 'Plan a small command-line audit tool.' <<< "$rendered"
done
rendered="$(compose_prompt "$SCRIPT_DIR/prompts/_base/greenfield.md" "$SCRIPT_DIR/prompts/lenses/security/injection.md" '' "$TEST_DIR/missing-spec.md" greenfield)"
check test "$?" -ne 0
check test -z "$rendered"
# Delete only the fixture at the read call, after the existence guard passed.
# DEBUG tracing makes the check-to-read race deterministic without sleeps.
vanish_spec_at_read() {
  if [[ "$1" == 'read_spec_file "$spec_file"' && "${spec_file:-}" == "$TEST_DIR/vanishing-spec.md" ]]; then
    printf 'read reached\n' > "$TEST_DIR/spec-read-reached"
    rm -f "$TEST_DIR/vanishing-spec.md"
  fi
}
for mode in audit greenfield spec-change; do
  printf 'Required product intent.\n' > "$TEST_DIR/vanishing-spec.md"
  rm -f "$TEST_DIR/spec-read-reached"
  rendered="$(
    set -T
    trap 'vanish_spec_at_read "$BASH_COMMAND"' DEBUG
    compose_prompt "$SCRIPT_DIR/prompts/_base/$mode.md" "$SCRIPT_DIR/prompts/lenses/security/injection.md" '' "$TEST_DIR/vanishing-spec.md" "$mode"
  )"
  check test "$?" -ne 0
  check test -z "$rendered"
  check test ! -e "$TEST_DIR/vanishing-spec.md"
  # Prove the test reached the read instead of failing at the existence guard.
  check test -s "$TEST_DIR/spec-read-reached"
done
# Remote execution partials remain optional when absent. A failed read of an
# existing partial must stop composition before dispatch.
export FAIL_TEMPLATE="$SCRIPT_DIR/prompts/_base/_remote_execution.md"
rendered="$(compose_prompt "$SCRIPT_DIR/prompts/_base/deploy.md" "$SCRIPT_DIR/prompts/lenses/security/injection.md" 'REPOLENS_REMOTE_TARGET=ops@example.invalid|REPOLENS_DEPLOY_TARGET_KIND=server' '' deploy)"
check test "$?" -ne 0
check test -z "$rendered"
unset FAIL_TEMPLATE

for failure_source in base lens spec; do
for mode in audit greenfield; do
  [[ "$failure_source" == lens && "$mode" == greenfield ]] && continue
  [[ "$failure_source" == spec && "$mode" != greenfield ]] && continue
  for sink in local forge blocked-marker; do
    LOG_BASE="$(mktemp -d "$SCRIPT_DIR/logs/test-template-$mode-$sink.XXXXXX")" || exit 1
    CASE_DIRS+=("$LOG_BASE")
    RUN_ID="${LOG_BASE#"$SCRIPT_DIR/logs/"}"
    unset FAIL_TEMPLATE FAIL_LENS FAIL_SPEC
    if [[ "$failure_source" == base ]]; then
      export FAIL_TEMPLATE="$SCRIPT_DIR/prompts/_base/$mode.md"
    elif [[ "$failure_source" == spec ]]; then
      export FAIL_SPEC="$TEST_DIR/spec.md"
    else
      export FAIL_LENS="$SCRIPT_DIR/prompts/lenses/security/injection.md"
    fi
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
      unset FAIL_TEMPLATE FAIL_LENS FAIL_SPEC
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
      # Old attempt diagnostics must not keep a clean explicit retry resumable.
      # shellcheck source=/dev/null
      source "$SCRIPT_DIR/lib/clean.sh"
      retry_is_complete() { ! _clean_is_incomplete "$1"; }
      for previous_reason in prompt-render-failed lens-execution-failed \
          interrupted-sighup interrupted-sigint interrupted-sigterm process-scope-cleanup-failed \
          custom-lens-materialization-failed; do
        jq --arg reason "$previous_reason" '.stopped_reason = $reason' "$LOG_BASE/summary.json" > "$LOG_BASE/seed.json"
        mv "$LOG_BASE/seed.json" "$LOG_BASE/summary.json"
        env -u TASK_HOURS -u REPOLENS_ROUNDS -u DONE_STREAK_REQUIRED \
          REPOLENS_LENS_HEARTBEAT_INTERVAL=0 REPOLENS_STATUS_INTERVAL=1 \
          bash "$SCRIPT_DIR/repolens.sh" --project "$SCRIPT_DIR" --agent codex --yes \
            "${args[@]}" > "$LOG_BASE/resume-marker-lost-$previous_reason.out" 2>&1
        check test "$?" -eq 0
        check json_matches '.stopped_reason == null' "$LOG_BASE/summary.json"
        check json_matches '.[-1].why_stopped == ""' "$LOG_BASE/attempts.json"
        check retry_is_complete "$LOG_BASE"
      done
    fi
  done
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

# An already accepted signal stops before inspecting a missing template.
# The signal reason remains available without fabricating a prompt failure.
BASE_PROMPTS_DIR="$TEST_DIR/no-templates"
rm -f "$LOG_BASE/.systemic-failure-abort"
printf '{"stopped_reason":null}\n' > "$SUMMARY_FILE"
REPOLENS_FINAL_STATE=interrupted
run_meta_orchestrator "$TEST_DIR/meta/missing/round-1" "$TEST_DIR/meta/missing/round-2"
check test "$?" -eq "${REPOLENS_INTERRUPT_EXIT_CODE:-130}"
check test "$REPOLENS_FINAL_STATE" = interrupted
check test "$(_rounds_agent_abort_reason)" = interrupted-sigint
check json_matches '.stopped_reason == null' "$SUMMARY_FILE"
check test ! -e "$LOG_BASE/.systemic-failure-abort"
check test ! -e "$AGENT_CALLS"

printf 'Results: %s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
