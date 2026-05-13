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

# Tests for issue #199 - deploy authorization and run confirmation prompts
# must show remote target context before an operator authorizes a remote run.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOLENS="$SCRIPT_DIR/repolens.sh"
TEMPLATE_LIB="$SCRIPT_DIR/lib/template.sh"
DEPLOY_BASE="$SCRIPT_DIR/prompts/_base/deploy.md"
LENS_FILE="$SCRIPT_DIR/prompts/lenses/deployment/service-health.md"

# shellcheck source=../lib/template.sh
# shellcheck disable=SC1091
source "$TEMPLATE_LIB"

PASS=0
FAIL=0
TOTAL=0

TMPROOT="$SCRIPT_DIR/tests/.tmp"
mkdir -p "$TMPROOT"
TMPDIR="$(mktemp -d "$TMPROOT/deploy-auth-prompt.XXXXXX")"
CREATED_LOG_DIRS=()

# shellcheck disable=SC2329
_cleanup() {
  rm -rf "$TMPDIR"
  rmdir "$TMPROOT" 2>/dev/null || true
  local d
  for d in "${CREATED_LOG_DIRS[@]:-}"; do
    [[ -n "$d" && -d "$d" ]] && rm -rf "$d"
  done
}
trap _cleanup EXIT

record_pass() {
  TOTAL=$((TOTAL + 1))
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

record_fail() {
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (expected to contain '$needle' in: ${haystack:0:260})"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (unexpected '$needle' present in: ${haystack:0:260})"
  fi
}

assert_before() {
  local desc="$1" first="$2" second="$3" haystack="$4"
  local first_line second_line
  first_line="$(printf '%s\n' "$haystack" | grep -n -F "$first" | head -1 | cut -d: -f1 || true)"
  second_line="$(printf '%s\n' "$haystack" | grep -n -F "$second" | head -1 | cut -d: -f1 || true)"
  if [[ -n "$first_line" && -n "$second_line" && "$first_line" -lt "$second_line" ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (expected '$first' before '$second'; lines ${first_line:-missing}/${second_line:-missing})"
  fi
}

assert_count_at_least() {
  local desc="$1" needle="$2" minimum="$3" haystack="$4"
  local count
  count="$(printf '%s\n' "$haystack" | grep -F -c "$needle" || true)"
  if [[ "$count" -ge "$minimum" ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (expected at least $minimum occurrences of '$needle', got $count)"
  fi
}

record_run_id() {
  local log_file="$1" run_id
  run_id="$(grep -oE 'RepoLens run [^ ]+ starting' "$log_file" 2>/dev/null | head -1 | awk '{print $3}' || true)"
  if [[ -n "${run_id:-}" ]]; then
    CREATED_LOG_DIRS+=("$SCRIPT_DIR/logs/$run_id")
  fi
}

FAKE_BIN="$TMPDIR/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/codex" <<'SH'
#!/usr/bin/env bash
printf 'DONE\n'
exit 0
SH
chmod +x "$FAKE_BIN/codex"
SSH_CALL_LOG="$TMPDIR/ssh-calls.log"
export SSH_CALL_LOG
cat > "$FAKE_BIN/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SSH_CALL_LOG"
printf '%s\n' "remote-preflight-host"
printf '%s\n' "Linux remote-preflight 6.1.0-test #1 SMP"
exit 0
SH
chmod +x "$FAKE_BIN/ssh"
export PATH="$FAKE_BIN:$PATH"

PLAIN_DIR="$TMPDIR/plain-server-target"
mkdir -p "$PLAIN_DIR"
printf '%s\n' "# server deploy target" > "$PLAIN_DIR/README.md"

HAVE_SCRIPT=0
if command -v script >/dev/null 2>&1; then
  HAVE_SCRIPT=1
fi

run_deploy_with_pty_to_file() {
  local project="$1" input="$2" log_file="$3"
  shift 3
  local extra_args="$*"

  : > "$log_file"
  export REPOLENS_TEST_PROJECT="$project"
  set +e
  printf '%b' "$input" | script -qfec "bash \"$REPOLENS\" --project \"\$REPOLENS_TEST_PROJECT\" --agent codex --mode deploy --local --focus service-health $extra_args" "$log_file" >/dev/null 2>&1
  local rc=$?
  set -e
  record_run_id "$log_file"
  return "$rc"
}

run_deploy_yes_to_file() {
  local project="$1" log_file="$2"
  shift 2

  : > "$log_file"
  set +e
  bash "$REPOLENS" \
    --project "$project" \
    --agent codex \
    --mode deploy \
    --local \
    --focus service-health \
    --yes \
    "$@" \
    >"$log_file" 2>&1
  local rc=$?
  set -e
  record_run_id "$log_file"
  return "$rc"
}

base_vars="PROJECT_PATH=/tmp/project|DOMAIN=deployment|DOMAIN_NAME=Deployment|DOMAIN_COLOR=ededed|LENS_ID=service-health|LENS_NAME=Service Health|LENS_LABEL=deploy:deployment/service-health|MODE=deploy|RUN_ID=test|REPO_NAME=repo|REPO_OWNER=owner|FORGE_REPO_SLUG=owner/repo|FORGE_ISSUE_CREATE=gh issue create --repo owner/repo|FORGE_LABEL_CREATE=gh label create deploy:deployment/service-health --repo owner/repo|FORGE_ISSUE_LIST_OPEN=gh issue list --repo owner/repo --state open|TARGET_TYPE=server|REPOLENS_DEPLOY_TARGET_KIND=server|ANDROID_APK_PATH=|ANDROID_PACKAGE_NAME=|ANDROID_HAS_DEVICE=|REPOLENS_ANDROID_APK_PATH="

echo ""
echo "=== Test Suite: deploy remote authorization prompt (issue #199) ==="
echo ""

if [[ "$HAVE_SCRIPT" -ne 1 ]]; then
  record_fail "script(1) is available for PTY-backed confirmation tests"
else
  record_pass "script(1) is available for PTY-backed confirmation tests"
fi

echo ""
echo "Test 1: remote authorization prompt names the target before confirmation"
LOG1="$TMPDIR/run1.log"
if [[ "$HAVE_SCRIPT" -eq 1 ]]; then
  run_deploy_with_pty_to_file "$PLAIN_DIR" 'n\n' "$LOG1" --remote ubuntu@host.example.com || true
  out1="$(cat "$LOG1")"

  assert_contains "remote auth run aborts at deploy authorization" "Aborted" "$out1"
  assert_contains "remote auth prompt shows normalized default port target" "Remote target: ubuntu@host.example.com:22" "$out1"
  assert_contains "remote auth prompt shows SSH wrapper preview" "Local commands will be wrapped in: ssh -S <socket> ubuntu@host.example.com '...'" "$out1"
  assert_contains "legal warning still references StGB" "including §202a StGB (DE), the Computer Fraud and Abuse Act (US)," "$out1"
  assert_contains "legal warning final jurisdiction line is unchanged" "and similar legislation in other jurisdictions." "$out1"
  assert_before "remote target appears before deploy authorization question" "Remote target: ubuntu@host.example.com:22" "I confirm I am authorized" "$out1"
  assert_before "wrapper preview appears before deploy authorization question" "Local commands will be wrapped in:" "I confirm I am authorized" "$out1"
  ssh_calls_after_cancel="$(cat "$SSH_CALL_LOG" 2>/dev/null || true)"
  assert_not_contains "cancelled deploy authorization does not invoke ssh preflight" "hostname && uname -a" "$ssh_calls_after_cancel"
fi

echo ""
echo "Test 2: labelled remote authorization prompt shows label and raw target"
LOG2="$TMPDIR/run2.log"
if [[ "$HAVE_SCRIPT" -eq 1 ]]; then
  run_deploy_with_pty_to_file "$PLAIN_DIR" 'n\n' "$LOG2" --remote ubuntu@host.example.com:2222 --remote-label "Server C" || true
  out2="$(cat "$LOG2")"

  assert_contains "labelled prompt shows human label as remote target" "Remote target: Server C" "$out2"
  assert_contains "labelled prompt shows raw SSH target follow-up" "Raw target: ubuntu@host.example.com:2222" "$out2"
  assert_before "label appears before raw target" "Remote target: Server C" "Raw target: ubuntu@host.example.com:2222" "$out2"
  assert_before "raw target appears before deploy authorization question" "Raw target: ubuntu@host.example.com:2222" "I confirm I am authorized" "$out2"
fi

echo ""
echo "Test 3: standard pre-run confirmation repeats remote context"
LOG3="$TMPDIR/run3.log"
if [[ "$HAVE_SCRIPT" -eq 1 ]]; then
  run_deploy_with_pty_to_file "$PLAIN_DIR" 'y\nn\n' "$LOG3" --remote ubuntu@host.example.com || true
  out3="$(cat "$LOG3")"

  assert_contains "remote run reaches standard confirmation" "=== RepoLens Confirmation ===" "$out3"
  assert_contains "remote run reaches final abort path" "Aborted." "$out3"
  assert_count_at_least "remote target appears in both prompt surfaces" "Remote target: ubuntu@host.example.com:22" 2 "$out3"
  assert_count_at_least "wrapper preview appears in both prompt surfaces" "Local commands will be wrapped in: ssh -S <socket> ubuntu@host.example.com '...'" 2 "$out3"
  assert_before "standard confirmation remote target appears before Proceed" "=== RepoLens Confirmation ===" "Proceed? [y/N]" "$out3"
  assert_before "wrapper preview appears before Proceed" "Local commands will be wrapped in:" "Proceed? [y/N]" "$out3"
fi

echo ""
echo "Test 4: non-default port preview matches the agent-facing SSH target form"
LOG4="$TMPDIR/run4.log"
if [[ "$HAVE_SCRIPT" -eq 1 ]]; then
  run_deploy_with_pty_to_file "$PLAIN_DIR" 'n\n' "$LOG4" --remote ubuntu@host.example.com:2222 || true
  out4="$(cat "$LOG4")"
  remote_vars="${base_vars}|REPOLENS_REMOTE_TARGET=ubuntu@host.example.com:2222|REPOLENS_REMOTE_LABEL=ubuntu@host.example.com:2222"
  remote_rendered="$(compose_prompt "$DEPLOY_BASE" "$LENS_FILE" "$remote_vars" "" "deploy" "" "" "false" "false" "")"

  assert_contains "operator preview shows raw non-default port target in SSH wrapper" "Local commands will be wrapped in: ssh -S <socket> ubuntu@host.example.com:2222 '...'" "$out4"
  assert_contains "agent prompt uses the same raw target variable for SSH" 'ssh -S "$REPOLENS_REMOTE_SSH_SOCKET" "$REPOLENS_REMOTE_TARGET" '\''CMD'\''' "$remote_rendered"
  assert_contains "agent prompt includes raw non-default port target as label context" "confirm the hostname matches \`ubuntu@host.example.com:2222\`" "$remote_rendered"
  assert_not_contains "operator preview does not show a divergent -p port form" "ssh -S <socket> -p 2222 ubuntu@host.example.com '...'" "$out4"
fi

echo ""
echo "Test 5: non-remote deploy prompts remain free of remote-only context"
LOG5="$TMPDIR/run5.log"
if [[ "$HAVE_SCRIPT" -eq 1 ]]; then
  run_deploy_with_pty_to_file "$PLAIN_DIR" 'y\nn\n' "$LOG5" || true
  out5="$(cat "$LOG5")"

  assert_contains "non-remote server run reaches standard confirmation" "=== RepoLens Confirmation ===" "$out5"
  assert_contains "non-remote server run reaches final abort path" "Aborted." "$out5"
  assert_not_contains "non-remote prompts omit remote target" "Remote target:" "$out5"
  assert_not_contains "non-remote prompts omit raw target" "Raw target:" "$out5"
  assert_not_contains "non-remote prompts omit SSH wrapper preview" "Local commands will be wrapped in:" "$out5"
fi

echo ""
echo "Test 6: --yes skips prompt-only remote context"
LOG6="$TMPDIR/run6.log"
run_deploy_yes_to_file "$PLAIN_DIR" "$LOG6" --remote ubuntu@host.example.com:2222 || true
out6="$(cat "$LOG6")"

assert_not_contains "--yes skips deploy authorization prompt" "I confirm I am authorized" "$out6"
assert_not_contains "--yes skips standard Proceed prompt" "Proceed? [y/N]" "$out6"
assert_not_contains "--yes skips prompt-only remote target line" "Remote target:" "$out6"
assert_not_contains "--yes skips prompt-only SSH wrapper preview" "Local commands will be wrapped in:" "$out6"

echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
