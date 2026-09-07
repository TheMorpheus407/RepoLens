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
printf 'Results: %s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
