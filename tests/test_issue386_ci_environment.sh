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

# Behavioral regression coverage for issue #386's CI-only failures.
#
# The Docker scenario drives the real remote-deploy e2e entry point with only
# Docker and SSH replaced at the process boundary. The SSH double records the
# mode of the identity file it is actually asked to use, so both an in-place
# chmod and a private temporary copy satisfy the contract.
#
# The dry-run scenarios execute every directly affected suite with all real
# agent CLIs removed from PATH. This recreates the GitHub Actions environment
# and verifies that each suite supplies its own test double rather than relying
# on a developer's machine.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REMOTE_E2E="$SCRIPT_DIR/tests/test_remote_deploy_e2e.sh"
REMOTE_KEY="$SCRIPT_DIR/tests/fixtures/test_key"

PASS=0
FAIL=0
TOTAL=0

TMPROOT="$SCRIPT_DIR/tests/.tmp"
mkdir -p "$TMPROOT"
TMPDIR="$(mktemp -d "$TMPROOT/issue386-ci-environment.XXXXXX")"
ORIGINAL_KEY_MODE="$(stat -c '%a' "$REMOTE_KEY")"

# shellcheck disable=SC2329 # Invoked by the EXIT trap.
cleanup() {
  chmod "$ORIGINAL_KEY_MODE" "$REMOTE_KEY" 2>/dev/null
  rm -rf "$TMPDIR"
  rmdir "$TMPROOT" 2>/dev/null
  return 0
}
trap cleanup EXIT

record_pass() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

record_fail() {
  local desc="$1" detail="${2:-}"
  FAIL=$((FAIL + 1))
  echo "  FAIL: $desc"
  [[ -n "$detail" ]] && printf '    %s\n' "$detail"
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" == "$expected" ]]; then
    record_pass "$desc"
  else
    record_fail "$desc" "Expected '$expected', got '$actual'"
  fi
}

assert_success() {
  local desc="$1" rc="$2" detail="${3:-}"
  TOTAL=$((TOTAL + 1))
  if [[ "$rc" -eq 0 ]]; then
    record_pass "$desc"
  else
    record_fail "$desc" "Expected exit 0, got $rc${detail:+: $detail}"
  fi
}

make_remote_command_doubles() {
  local fake_bin="$1"
  mkdir -p "$fake_bin"

  cat > "$fake_bin/docker" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  info|rm) exit 0 ;;
  run) printf '%s\n' 'issue386-container'; exit 0 ;;
  inspect)
    if [[ "$*" == *'.NetworkSettings.Ports'* ]]; then
      printf '%s\n' '127.0.0.1:12222->2222/tcp'
    else
      printf '%s\n' 'issue386-host'
    fi
    exit 0
    ;;
  ps) exit 0 ;;
esac
exit 0
SH

  cat > "$fake_bin/ssh-keyscan" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '[127.0.0.1]:12222 ssh-ed25519 AAAAC3NzaIssue386'
SH

  cat > "$fake_bin/ssh" <<'SH'
#!/usr/bin/env bash
key=""
while (( $# > 0 )); do
  if [[ "$1" == "-i" && $# -ge 2 ]]; then
    key="$2"
    shift 2
  else
    shift
  fi
done
if [[ -n "$key" ]]; then
  printf '%s\t%s\n' "$(stat -c '%a' "$key")" "$key" >> "${ISSUE386_SSH_MODE_LOG:?}"
fi
printf '%s\n' 'issue386-host' 'Linux issue386 6.0 test'
exit 0
SH

  cat > "$fake_bin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH

  chmod +x "$fake_bin/docker" "$fake_bin/ssh-keyscan" "$fake_bin/ssh" "$fake_bin/sleep"
}

path_without_agent_clis() {
  # On NixOS, agents and core utilities can share a PATH directory. Mirror
  # executables individually so hiding agents never removes bash/git/jq too.
  local clean_bin="$TMPDIR/agent-free-bin" dir executable name
  mkdir -p "$clean_bin"
  local IFS=:
  for dir in $PATH; do
    [[ -n "$dir" && -d "$dir" ]] || continue
    for executable in "$dir"/*; do
      [[ -f "$executable" && -x "$executable" ]] || continue
      name="${executable##*/}"
      case "$name" in claude|codex|opencode|agy|copilot|cursor-agent) continue ;; esac
      [[ -e "$clean_bin/$name" ]] && continue
      ln -s "$executable" "$clean_bin/$name" || return 1
    done
  done
  printf '%s' "$clean_bin"
}

assert_agent_free_path() {
  local clean_path="$1" agent
  for agent in claude codex opencode agy; do
    if PATH="$clean_path" command -v "$agent" >/dev/null 2>&1; then
      echo "ERROR: failed to remove '$agent' from the CI-like PATH" >&2
      exit 2
    fi
  done
  for agent in bash git jq timeout; do
    if ! PATH="$clean_path" command -v "$agent" >/dev/null 2>&1; then
      echo "ERROR: CI-like PATH is missing required command '$agent'" >&2
      exit 2
    fi
  done
}

echo ""
echo "=== Test Suite: issue #386 CI environment contracts ==="
echo ""

echo "Test 1: remote deploy protects a freshly checked-out private key before SSH"
remote_fake_bin="$TMPDIR/remote-bin"
ssh_mode_log="$TMPDIR/ssh-modes.tsv"
remote_output="$TMPDIR/remote-e2e.out"
make_remote_command_doubles "$remote_fake_bin"
chmod 644 "$REMOTE_KEY"
REPOLENS_TEST_DOCKER=1 \
ISSUE386_SSH_MODE_LOG="$ssh_mode_log" \
PATH="$remote_fake_bin:$PATH" \
bash "$REMOTE_E2E" >"$remote_output" 2>&1
remote_rc=$?
first_ssh_mode="$(awk 'NR == 1 { print $1 }' "$ssh_mode_log" 2>/dev/null)"
if [[ "$remote_rc" -ne 0 || -z "$first_ssh_mode" ]]; then
  detail="$(grep -E 'ERROR:|FAIL:' "$remote_output" 2>/dev/null | head -3 | tr '\n' ' ')"
  record_fail "remote deploy reaches SSH with a recorded identity file" \
    "e2e rc=$remote_rc${detail:+: $detail}"
  TOTAL=$((TOTAL + 1))
else
  assert_eq "first SSH identity file is owner-only" "600" "$first_ssh_mode"
fi

echo ""
echo "Test 2: affected dry-run suites are hermetic when agent CLIs are absent"
clean_path="$(path_without_agent_clis)"
assert_agent_free_path "$clean_path"

affected_suites=(
  tests/test_human_review_e2e.sh
  tests/test_human_review_flag.sh
  tests/test_relevant_domains_flag.sh
  tests/test_relevant_domains_invalid.sh
  tests/test_rounds_default_no_regression.sh
  tests/test_scope_by_keywords.sh
  tests/test_scope_by_keywords_disabled.sh
  tests/test_strategy_flag.sh
)

for suite in "${affected_suites[@]}"; do
  suite_output="$TMPDIR/$(basename "$suite").out"
  PATH="$clean_path" bash "$SCRIPT_DIR/$suite" >"$suite_output" 2>&1
  suite_rc=$?
  detail="$(grep -E 'Missing required command|^[[:space:]]*FAIL:' "$suite_output" 2>/dev/null | head -1)"
  assert_success "$suite passes without an ambient agent CLI" "$suite_rc" "$detail"
done

echo ""
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
