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

# Tests for issue #158: mode-specific degraded meta-orchestrator templates.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/streak.sh
source "$SCRIPT_DIR/lib/streak.sh"
# shellcheck source=../lib/template.sh
source "$SCRIPT_DIR/lib/template.sh"
# shellcheck source=../lib/rounds.sh
source "$SCRIPT_DIR/lib/rounds.sh"

PASS=0
FAIL=0
TOTAL=0

TMP_PARENT="$SCRIPT_DIR/logs/test-meta-orchestrator-mode-templates"
mkdir -p "$TMP_PARENT"
TMPDIR="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"

cleanup() {
  rm -rf "$TMPDIR"
  rmdir "$TMP_PARENT" 2>/dev/null || true
}
trap cleanup EXIT

pass_with() {
  local desc="$1"
  PASS=$((PASS + 1))
  echo "  PASS: $desc"
}

fail_with() {
  local desc="$1" detail="${2:-}"
  FAIL=$((FAIL + 1))
  echo "  FAIL: $desc"
  if [[ -n "$detail" ]]; then
    printf '    %s\n' "$detail"
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected: $expected | Actual: $actual"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected to find: $needle"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Did not expect to find: $needle"
  fi
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

log_info() {
  LOG_LINES+=("INFO:$*")
}

log_warn() {
  LOG_LINES+=("WARN:$*")
}

run_agent() {
  printf '%s\n' "NO_FRESH_ANGLES"
}

render_meta_prompt_for_mode() {
  local mode="$1" run_id="mode-template-$mode"

  RUN_ID="$run_id"
  LOG_BASE="$TMPDIR/logs-$mode"
  PROJECT_PATH="$SCRIPT_DIR"
  REPO_OWNER="local"
  REPO_NAME="RepoLens"
  MODE="$mode"
  AGENT="codex"
  AGENT_TIMEOUT_SECS=5
  AGENT_KILL_GRACE_SECS=1
  BASE_PROMPTS_DIR="$SCRIPT_DIR/prompts/_base"
  CURRENT_ROUND_TOTAL=2
  ORIGINAL_BUG_REPORT_OR_SCOPE="template routing test"
  LOG_LINES=()

  mkdir -p "$LOG_BASE/rounds/round-1"
  printf '%s\n' "# Round Digest" "Prior output for $mode." > "$LOG_BASE/rounds/round-1/digest.md"

  run_meta_orchestrator 1 2 >/dev/null
  cat "$LOG_BASE/rounds/round-2/meta-orchestrator-prompt.md"
}

echo "=== meta-orchestrator mode templates (issue #158) ==="

echo ""
echo "Test 1: helper resolves mode-specific templates"
assert_eq "discover uses discover template" \
          "meta_orchestrator_discover.md" \
          "$(_rounds_meta_template_name_for_mode "discover")"
assert_eq "content uses content template" \
          "meta_orchestrator_content.md" \
          "$(_rounds_meta_template_name_for_mode "content")"

for mode in audit bugfix feature deploy opensource custom unknown ""; do
  assert_eq "$mode falls back to default template" \
            "meta_orchestrator.md" \
            "$(_rounds_meta_template_name_for_mode "$mode")"
done

echo ""
echo "Test 2: run_meta_orchestrator renders the active mode template"
discover_prompt="$(render_meta_prompt_for_mode "discover")"
assert_contains "discover prompt uses lateral expansion wording" \
                "lateral expansion" \
                "$discover_prompt"
assert_not_contains "discover prompt does not use default coverage section" \
                    "Coverage gap detection" \
                    "$discover_prompt"

content_prompt="$(render_meta_prompt_for_mode "content")"
assert_contains "content prompt uses lens rotation wording" \
                "lens rotation" \
                "$content_prompt"
assert_contains "content prompt keeps content audit vocabulary" \
                "content audit" \
                "$content_prompt"
assert_not_contains "content prompt does not use default coverage section" \
                    "Coverage gap detection" \
                    "$content_prompt"

audit_prompt="$(render_meta_prompt_for_mode "audit")"
assert_contains "audit prompt still uses default template" \
                "Coverage gap detection" \
                "$audit_prompt"

finish
