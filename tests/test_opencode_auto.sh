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

# Regression for #409: headless OpenCode must allow external output writes.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/core.sh
source "$SCRIPT_DIR/lib/core.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/bin" "$TEST_DIR/repo" "$TEST_DIR/reports"
cat > "$TEST_DIR/bin/opencode" <<'SHIM'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$@" > "$OPENCODE_TEST_ARGV"
[[ "$1" == run && "$2" == --auto ]] || exit 91
shift 2
if [[ "${1:-}" == -m ]]; then
  [[ "$2" == 'minimax-coding-plan/MiniMax-M3' ]] || exit 92
  shift 2
fi
[[ $# == 1 && "$1" == "$OPENCODE_TEST_PROMPT" ]] || exit 93
[[ "$PWD" == "$OPENCODE_TEST_REPO" ]] || exit 94
[[ "${OPENCODE_TEST_DENY:-0}" == 1 ]] && exit 17
printf '# [HIGH] external output\n' > "$OPENCODE_TEST_OUTPUT"
printf 'DONE\n'
SHIM
chmod +x "$TEST_DIR/bin/opencode"
export PATH="$TEST_DIR/bin:$PATH"
export OPENCODE_TEST_ARGV="$TEST_DIR/argv" OPENCODE_TEST_REPO="$TEST_DIR/repo"
export OPENCODE_TEST_OUTPUT="$TEST_DIR/reports/finding.md"
export OPENCODE_TEST_PROMPT=$'Write one finding outside the repository.\nKeep "quotes" and $variables literal.'
passed=0
failed=0
check() {
  if "$@"; then passed=$((passed + 1)); else failed=$((failed + 1)); printf 'FAIL: %s\n' "$*"; fi
}
for agent in opencode opencode/minimax-coding-plan/MiniMax-M3; do
  rm -f "$OPENCODE_TEST_OUTPUT"
  output="$(run_agent "$agent" "$OPENCODE_TEST_PROMPT" "$OPENCODE_TEST_REPO")"
  rc=$?
  check test "$rc" -eq 0
  check test "$output" = DONE
  check test -s "$OPENCODE_TEST_OUTPUT"
  export OPENCODE_TEST_DENY=1
  output="$(run_agent "$agent" "$OPENCODE_TEST_PROMPT" "$OPENCODE_TEST_REPO")"
  rc=$?
  check test "$rc" -eq 17
  unset OPENCODE_TEST_DENY
done
check jq -e '.models["minimax-coding-plan/MiniMax-M3"] | .input_per_mtok == 0.30 and .output_per_mtok == 1.20' "$SCRIPT_DIR/config/agent-pricing.json"
printf 'Results: %s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
