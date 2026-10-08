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

# #397: task sizing propagates without rewriting repository/spec evidence.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/template.sh"
TEST_DIR="$(mktemp -d)"
RUN_ID="test-task-hours-$$"
trap 'rm -rf "$TEST_DIR" "$SCRIPT_DIR/logs/$RUN_ID"' EXIT
mkdir -p "$TEST_DIR/bin" "$SCRIPT_DIR/logs/$RUN_ID"
printf '#!/usr/bin/env bash\nexit 99\n' > "$TEST_DIR/bin/claude"
chmod +x "$TEST_DIR/bin/claude"
export PATH="$TEST_DIR/bin:$PATH"
cat > "$TEST_DIR/lens.md" <<'LENS'
---
id: sizing
domain: testing
name: Sizing
role: tester
---
Observe runtime data for at least 1 hour.
LENS
printf 'The imported spec says 1 hour and {{TASK_HOURS}} verbatim.\n' > "$TEST_DIR/spec.md"
passed=0
failed=0
check() {
  if "$@"; then passed=$((passed + 1)); else failed=$((failed + 1)); printf 'FAIL: %s\n' "$*"; fi
}
contains() { [[ "$1" == *"$2"* ]]; }
for mode in audit branch-review bugfix feature discover deploy opensource content custom polish greenfield spec-change synthesize; do
  template="$SCRIPT_DIR/prompts/_base/$mode.md"
  export TASK_HOURS=1
  output="$(compose_prompt "$template" "$TEST_DIR/lens.md" '' "$TEST_DIR/spec.md" "$mode" '' '' false true "$TEST_DIR/one-hour 1 hour ~1h")"
  check contains "$output" 'approximately 1 hour'
  export TASK_HOURS=6
  output="$(compose_prompt "$template" "$TEST_DIR/lens.md" '' "$TEST_DIR/spec.md" "$mode" '' '' false true "$TEST_DIR/one-hour 1 hour ~1h")"
  check contains "$output" 'approximately 6 hours'
  if [[ "$mode" != synthesize ]]; then
    check contains "$output" "$TEST_DIR/one-hour 1 hour ~1h"
    check contains "$output" 'Observe runtime data for at least 1 hour.'
    check contains "$output" 'The imported spec says 1 hour and {{TASK_HOURS}} verbatim.'
  fi
  check test "$(printf '%s' "$output" | grep -c 'approximately 1 hour')" -eq 0
  check test "$(printf '%s' "$output" | grep -c '~1 Hour Rule')" -eq 0
done
# Real shipped lenses must defer to the base cap, including specialized modes.
# Keep operational lookback windows and evidence thresholds independent of it.
for pair in \
  'spec-change:spec-change/spec-change-planning' \
  'greenfield:greenfield/backlog-planning' \
  'content:content-quality/okf-compliance' \
  'audit:logs/race-condition-signals' \
  'deploy:android/apk-overview'; do
  mode="${pair%%:*}"
  lens="${pair#*:}"
  for hours in 1 6; do
    export TASK_HOURS="$hours"
    output="$(compose_prompt "$SCRIPT_DIR/prompts/_base/$mode.md" \
      "$SCRIPT_DIR/prompts/lenses/$lens.md" '' '' "$mode")"
    check contains "$output" "approximately $hours hour"
    check contains "$output" 'configured human implementation-hour limit'
  done
done
export TASK_HOURS=6
output="$(compose_prompt "$SCRIPT_DIR/prompts/_base/deploy.md" \
  "$SCRIPT_DIR/prompts/lenses/deployment/log-analysis.md" '' '' deploy)"
check contains "$output" 'journalctl -u <unit> --since "1 hour ago"'
output="$(compose_prompt "$SCRIPT_DIR/prompts/_base/audit.md" \
  "$SCRIPT_DIR/prompts/lenses/logs/resource-leaks.md" '' '' audit)"
check contains "$output" 'at least 5 `(timestamp, value)` samples spanning at least 1 hour'
for value in 0 -1 1.5 abc 01 '1;touch unsafe'; do
  output="$(bash "$SCRIPT_DIR/repolens.sh" --task-hours "$value" 2>&1)"
  check test "$?" -ne 0
  check contains "$output" '--task-hours requires a positive integer'
done
output="$(bash "$SCRIPT_DIR/repolens.sh" --task-hours 2>&1)"
check test "$?" -ne 0
check contains "$output" '--task-hours requires a positive integer'
run_preview() {
  bash "$SCRIPT_DIR/repolens.sh" --project "$SCRIPT_DIR" --agent claude --local \
    --yes --focus injection --resume "$RUN_ID" --output "$TEST_DIR/output" --dry-run "$@" 2>&1
}
unset TASK_HOURS
output="$(run_preview)"
check test "$?" -eq 0
check contains "$output" 'Task scope: up to 1 human implementation hour(s)'
output="$(run_preview --task-hours 6)"
check test "$?" -eq 0
check contains "$output" 'Task scope: up to 6 human implementation hour(s)'
check test "$(cat "$SCRIPT_DIR/logs/$RUN_ID/task-hours")" = 6
output="$(run_preview)"
check test "$?" -eq 0
check contains "$output" 'Task scope: up to 6 human implementation hour(s)'
printf 'invalid\n' > "$SCRIPT_DIR/logs/$RUN_ID/task-hours"
output="$(run_preview)"
check test "$?" -ne 0
check contains "$output" 'Persisted task hours must be a positive integer'
# #428: a failed base-template read must fail the caller, even with valid hours.
export TASK_HOURS=6
output="$(
  # Simulate a command that emits partial data and then fails. Keep the stub
  # confined to this subshell and this one base-template path.
  # shellcheck disable=SC2329 # compose_prompt invokes this override indirectly.
  cat() {
    if [[ "$#" -eq 1 && "$1" == "$SCRIPT_DIR/prompts/_base/polish.md" ]]; then
      printf 'Partially read base template.'
      return 42
    fi
    command cat "$@"
  }
  compose_prompt "$SCRIPT_DIR/prompts/_base/polish.md" "$TEST_DIR/lens.md" '' '' polish
)"
read_rc=$?
check test "$read_rc" -ne 0
check test -z "$output"

# #428: exercise adversarial hours at the renderer boundary, independently of
# CLI validation. The current renderer rejects invalid values without output.
output="$(
  cd "$TEST_DIR" || exit 1
  TASK_HOURS='1;touch unsafe' compose_prompt "$SCRIPT_DIR/prompts/_base/polish.md" "$TEST_DIR/lens.md" '' '' polish \
    '' '' false true "$TEST_DIR/output" 2>"$TEST_DIR/invalid-hours-error"
)"
renderer_rc=$?
check test "$renderer_rc" -ne 0
check test -z "$output"
check test ! -e "$TEST_DIR/unsafe"

# Polish body rendering has an existing fallback rather than rejection.
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/polish.sh"
injection_group='{"domain":"effort-signal","lens_id":"loading-transparency","items":[{"title":"Clarify progress","body":"Keep progress concise.","voice_fit":"strong","polish_rank_x1000":1000}]}'
(
  cd "$TEST_DIR" || exit 1
  TASK_HOURS='1;touch unsafe' _polish_render_issue_body "$injection_group" "$TEST_DIR/injection-body.md" "test-hours" "ranked.json"
)
polish_rc=$?
check test "$polish_rc" -eq 0
output="$(cat "$TEST_DIR/injection-body.md")"
check contains "$output" '- Each accepted polish item remains scoped to approximately one hour.'
check test "$(printf '%s' "$output" | grep -cF '1;touch unsafe')" -eq 0
check test ! -e "$TEST_DIR/unsafe"

printf 'Results: %s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
