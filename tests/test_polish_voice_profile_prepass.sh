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

# Tests for issue #294: polish voice profile pre-pass.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/template.sh
source "$SCRIPT_DIR/lib/template.sh"
# shellcheck source=../lib/polish.sh
source "$SCRIPT_DIR/lib/polish.sh"

PASS=0
FAIL=0
TOTAL=0

TMP_PARENT="$SCRIPT_DIR/logs/test-polish-voice-profile-prepass"
mkdir -p "$TMP_PARENT"
TMPDIR="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"

cleanup() {
  rm -rf "$TMPDIR"
  rmdir "$TMP_PARENT" 2>/dev/null || true
}
trap cleanup EXIT

pass_with() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

fail_with() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
  if [[ -n "${2:-}" ]]; then
    printf '    %s\n' "$2"
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

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected: $expected | Actual: $actual"
  fi
}

assert_file_exists() {
  local desc="$1" file="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$file" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected file at $file"
  fi
}

assert_file_not_exists() {
  local desc="$1" file="$2"
  TOTAL=$((TOTAL + 1))
  if [[ ! -e "$file" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Did not expect file at $file"
  fi
}

assert_file_contains() {
  local desc="$1" file="$2" needle="$3"
  TOTAL=$((TOTAL + 1))
  if grep -qF "$needle" "$file"; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected $file to contain: $needle"
  fi
}

assert_file_not_contains_regex() {
  local desc="$1" file="$2" pattern="$3"
  TOTAL=$((TOTAL + 1))
  if ! grep -qiE "$pattern" "$file"; then
    pass_with "$desc"
  else
    fail_with "$desc" "Did not expect $file to match regex: $pattern"
  fi
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

echo "=== polish voice profile pre-pass (issue #294) ==="

prompt_file="$SCRIPT_DIR/prompts/_base/meta_orchestrator_polish.md"

echo ""
echo "Test 1: prompt contract"
assert_file_exists "polish voice profile pre-pass prompt exists" "$prompt_file"
assert_file_contains "prompt names polish mode" "$prompt_file" "single-pass polishing run"
assert_file_contains "prompt requires voice profile" "$prompt_file" "project voice profile"
assert_file_contains "prompt requires register" "$prompt_file" "Register:"
assert_file_contains "prompt requires who it is for" "$prompt_file" "Who it is for / who loves it:"
assert_file_contains "prompt requires product purpose" "$prompt_file" "Product purpose:"
assert_file_contains "prompt requires soul" "$prompt_file" "Soul:"
assert_file_contains "prompt requires off-brand list" "$prompt_file" "Off-brand here:"
assert_file_contains "prompt tells agent to inspect README" "$prompt_file" "README"
assert_file_contains "prompt tells agent to inspect docs" "$prompt_file" "docs"
assert_file_contains "prompt tells agent to inspect CLI copy" "$prompt_file" "CLI copy"
assert_file_contains "prompt tells agent to inspect naming" "$prompt_file" "Naming patterns"
assert_file_contains "prompt tells agent to inspect tone" "$prompt_file" "tone"
assert_file_contains "prompt has untrusted data contract" "$prompt_file" "Untrusted Reference Data Contract"
assert_file_not_contains_regex "prompt does not introduce scoring language" "$prompt_file" "scor(e|ing)"

echo ""
echo "Test 2: VOICE_PROFILE file-backed rendering is pipe-safe and late"
cat > "$TMPDIR/lens.md" <<'EOF'
---
id: polish-test
domain: test
name: Polish Test
role: tester
---
## Your Expert Focus
Check polish voice fit.
EOF

cat > "$TMPDIR/profile.md" <<'EOF'
## Project Voice Profile
Register: plain - Keep the wording direct.
Who it is for / who loves it: Builders who value concise automation.
Product purpose: Audit repositories and create useful issues.

Soul:
- Precise | practical | direct.
- Literal placeholder must stay literal: {{FORGE_ISSUE_CREATE}}.
- Section placeholder must stay literal: {{SPEC_SECTION}}.

Off-brand here:
- Generic polishing without repository evidence.
EOF

base_vars="LENS_NAME=PolishBot|DOMAIN_NAME=Test|REPO_OWNER=owner|REPO_NAME=repo|PROJECT_PATH=/tmp/project|LENS_LABEL=polish:test/polish-test|DOMAIN_COLOR=ededed|DOMAIN=test|LENS_ID=polish-test|MODE=polish|RUN_ID=test-run"
rendered="$(compose_prompt "$SCRIPT_DIR/prompts/_base/polish.md" "$TMPDIR/lens.md" "${base_vars}|VOICE_PROFILE=@${TMPDIR}/profile.md" "" "polish")"

assert_contains "rendered prompt includes voice profile body" "Register: plain - Keep the wording direct." "$rendered"
assert_contains "rendered profile preserves pipe characters" "Precise | practical | direct." "$rendered"
assert_contains "voice profile keeps forge placeholder literal" "{{FORGE_ISSUE_CREATE}}" "$rendered"
assert_contains "voice profile keeps section placeholder literal" "{{SPEC_SECTION}}" "$rendered"
assert_not_contains "rendered prompt consumes VOICE_PROFILE placeholder" "{{VOICE_PROFILE}}" "$rendered"
assert_not_contains "rendered prompt does not leave @path token" "@${TMPDIR}/profile.md" "$rendered"

echo ""
echo "Test 3: pre-pass writes once and reuses existing profile"
MODE="polish"
RUN_ID="test-run"
LOG_BASE="$TMPDIR/logs/test-run"
PROJECT_PATH="$SCRIPT_DIR"
BASE_PROMPTS_DIR="$SCRIPT_DIR/prompts/_base"
REPO_OWNER="owner"
REPO_NAME="repo"
FORGE_REPO_SLUG="owner/repo"
AGENT="mock"
AGENT_TIMEOUT_SECS="10"
AGENT_KILL_GRACE_SECS="1"
RUN_AGENT_CALLS=0

run_agent() {
  RUN_AGENT_CALLS=$((RUN_AGENT_CALLS + 1))
  printf '%s\n' '## Project Voice Profile'
  printf '%s\n' 'Register: plain - Mocked profile.'
  printf '%s\n' 'Who it is for / who loves it: Mock users.'
  printf '%s\n' 'Product purpose: Mock purpose.'
  printf '%s\n' ''
  printf '%s\n' 'Soul:'
  printf '%s\n' '- Mock soul.'
  printf '%s\n' '- Keeps {{SPEC_SECTION}} literal.'
  printf '%s\n' '- Keeps polish grounded.'
  printf '%s\n' ''
  printf '%s\n' 'Off-brand here:'
  printf '%s\n' '- Mock off-brand.'
}

run_polish_voice_profile_prepass "$RUN_ID"
rc=$?
profile_path="$LOG_BASE/polish/voice-profile.md"
prompt_path="$LOG_BASE/polish/voice-profile-prompt.md"

assert_eq "pre-pass exits successfully" "0" "$rc"
assert_eq "pre-pass invokes agent once" "1" "$RUN_AGENT_CALLS"
assert_file_exists "pre-pass writes profile" "$profile_path"
assert_file_exists "pre-pass writes rendered prompt" "$prompt_path"
assert_file_contains "profile contains mocked register" "$profile_path" "Register: plain - Mocked profile."
assert_file_contains "profile preserves placeholder as data" "$profile_path" 'Keeps {{SPEC_SECTION}} literal.'
assert_file_contains "rendered prompt contains output format" "$prompt_path" "## Project Voice Profile"

run_polish_voice_profile_prepass "$RUN_ID"
rc=$?
assert_eq "reuse exits successfully" "0" "$rc"
assert_eq "reuse does not invoke agent again" "1" "$RUN_AGENT_CALLS"

echo ""
echo "Test 3b: dry-run skips the pre-pass helper"
DRY_RUN="true"
RUN_AGENT_CALLS=0
LOG_BASE="$TMPDIR/logs/dry-run"
POLISH_VOICE_PROFILE_FILE="$LOG_BASE/polish/voice-profile.md"
run_polish_voice_profile_prepass "$RUN_ID"
rc=$?
assert_eq "dry-run pre-pass exits successfully" "0" "$rc"
assert_eq "dry-run does not invoke agent" "0" "$RUN_AGENT_CALLS"
assert_file_not_exists "dry-run does not write a profile" "$POLISH_VOICE_PROFILE_FILE"
DRY_RUN="false"
unset TOTAL_LENSES

echo ""
echo "Test 4: repolens.sh wires the generated profile into polish lenses"
assert_file_contains "repolens passes VOICE_PROFILE by @file" \
                     "$SCRIPT_DIR/repolens.sh" \
                     'vars+="|VOICE_PROFILE=@${POLISH_VOICE_PROFILE_FILE}"'
assert_file_contains "repolens runs pre-pass before round execution" \
                     "$SCRIPT_DIR/repolens.sh" \
                     'run_polish_voice_profile_prepass "$RUN_ID"'

finish
