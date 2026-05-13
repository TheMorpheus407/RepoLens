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

# Docker-backed smoke test for issue #202.
#
# The Docker path is opt-in via REPOLENS_TEST_DOCKER=1. The default path still
# checks the non-Docker contract that keeps normal `make check` deterministic.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOLENS="$SCRIPT_DIR/repolens.sh"
README_FILE="$SCRIPT_DIR/README.md"
CI_FILE="$SCRIPT_DIR/.github/workflows/ci.yml"
CONTRIBUTING_FILE="$SCRIPT_DIR/CONTRIBUTING.md"
REMOTE_KEY="$SCRIPT_DIR/tests/fixtures/test_key"
REMOTE_PUBKEY="$SCRIPT_DIR/tests/fixtures/test_key.pub"
DOCKER_CONTAINER="repolens-sshd-test"
DOCKER_PORT_PUBLISH="127.0.0.1:12222:2222"
BROAD_DOCKER_PORT_PUBLISH="12222:2222"
DOCKER_IMAGE="lscr.io/linuxserver/openssh-server@sha256:29d4e3f887596c4c2fc609f4e07040b08890a238178da400ffa2a602b55245bc"

PASS=0
FAIL=0
TOTAL=0
mkdir -p "$SCRIPT_DIR/tests/.tmp"
TMPDIR="$(mktemp -d "$SCRIPT_DIR/tests/.tmp/remote-deploy-e2e.XXXXXX")"
CREATED_LOG_DIRS=()
CONTAINER_STARTED=false

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

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (expected '$expected', got '$actual')"
  fi
}

assert_file_contains() {
  local desc="$1" file="$2" needle="$3"
  if [[ -f "$file" ]] && grep -Fq -- "$needle" "$file"; then
    record_pass "$desc"
  else
    record_fail "$desc (expected '$needle' in $file)"
  fi
}

assert_file_matches() {
  local desc="$1" file="$2" pattern="$3"
  if [[ -f "$file" ]] && grep -Eq -- "$pattern" "$file"; then
    record_pass "$desc"
  else
    record_fail "$desc (expected pattern '$pattern' in $file)"
  fi
}

assert_not_file_contains() {
  local desc="$1" file="$2" needle="$3"
  if [[ -f "$file" ]] && ! grep -Fq -- "$needle" "$file"; then
    record_pass "$desc"
  else
    record_fail "$desc (unexpected '$needle' in $file)"
  fi
}

assert_path_absent() {
  local desc="$1" path="$2"
  if [[ -n "$path" && ! -e "$path" ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (path still exists: $path)"
  fi
}

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: REPOLENS_TEST_DOCKER=1 requires '$cmd'." >&2
    exit 1
  fi
}

cleanup_container() {
  docker rm -f "$DOCKER_CONTAINER" >/dev/null 2>&1 || true
  CONTAINER_STARTED=false
}

# shellcheck disable=SC2329
cleanup() {
  if [[ "$CONTAINER_STARTED" == "true" ]]; then
    cleanup_container
  fi
  rm -rf "$TMPDIR"
  local d
  for d in "${CREATED_LOG_DIRS[@]:-}"; do
    [[ -n "$d" && -d "$d" ]] && rm -rf "$d"
  done
}
trap cleanup EXIT

parse_run_id() {
  local log_file="$1"
  grep -oE 'RepoLens run [^ ]+ starting' "$log_file" 2>/dev/null | head -1 | awk '{print $3}' || true
}

assert_no_bare_deploy_commands() {
  local desc="$1" file="$2" bad_lines
  bad_lines="$(
    awk '
      /(systemctl|journalctl[[:space:]]+-|ss[[:space:]]+-tlnp|df[[:space:]]+-h|cat[[:space:]]+\/etc\/)/ {
        if ($0 !~ /ssh[[:space:]].*'\''.*(systemctl|journalctl|ss -tlnp|df -h|cat \/etc\/)/) {
          print
        }
      }
    ' "$file"
  )"
  if [[ -z "$bad_lines" ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (bare command lines: ${bad_lines:0:240})"
  fi
}

wait_for_sshd() {
  local known_hosts="$1" login_log="$2"
  local attempts=0
  while (( attempts < 30 )); do
    attempts=$((attempts + 1))
    if ssh-keyscan -p 12222 127.0.0.1 >"$known_hosts.tmp" 2>/dev/null; then
      cat "$known_hosts.tmp" >> "$known_hosts"
      rm -f "$known_hosts.tmp"
      if ssh \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=yes \
        -o UserKnownHostsFile="$known_hosts" \
        -i "$REMOTE_KEY" \
        -p 12222 \
        tester@127.0.0.1 \
        'hostname && uname -a' >"$login_log" 2>&1; then
        return 0
      fi
    fi
    sleep 1
  done
  return 1
}

setup_dummy_repo() {
  local project="$1"
  mkdir -p "$project"
  git -C "$project" init -q
  git -C "$project" config user.name "RepoLens Test"
  git -C "$project" config user.email "repolens-test@example.invalid"
  printf '%s\n' "# test target" > "$project/README.md"
  printf '%s\n' "service-health smoke target" > "$project/service.txt"
  printf '%s\n' "127.0.0.1 test-target" > "$project/hosts.txt"
  git -C "$project" add README.md service.txt hosts.txt
  git -C "$project" commit -q -m "Initial test target"
}

setup_fake_agent() {
  local fake_bin="$1"
  local real_ssh
  real_ssh="$(command -v ssh)"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/ssh" <<SH
#!/usr/bin/env bash
exec "$real_ssh" \
  -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile="\${REPOLENS_TEST_KNOWN_HOSTS:?}" \
  "\$@"
SH
  chmod +x "$fake_bin/ssh"
  cat > "$fake_bin/codex" <<'SH'
#!/usr/bin/env bash
prompt="${*: -1}"
if [[ -n "${REPOLENS_FAKE_PROMPT_LOG:-}" ]]; then
  printf '%s\n' "$prompt" > "$REPOLENS_FAKE_PROMPT_LOG"
fi
if [[ -n "${REPOLENS_FAKE_CONTROL_DIR_LOG:-}" ]]; then
  printf '%s\n' "${REPOLENS_REMOTE_SSH_CONTROL_DIR:-}" > "$REPOLENS_FAKE_CONTROL_DIR_LOG"
fi
printf 'CONTROL_DIR=%s\n' "${REPOLENS_REMOTE_SSH_CONTROL_DIR:-}"
printf 'ssh -S %s %s '\''hostname && uname -a'\''\n' "${REPOLENS_REMOTE_SSH_SOCKET:-}" "${REPOLENS_REMOTE_TARGET:-}"
ssh -S "$REPOLENS_REMOTE_SSH_SOCKET" "$REPOLENS_REMOTE_TARGET" 'hostname && uname -a'
printf 'ssh -S %s %s '\''cat /etc/hostname'\''\n' "${REPOLENS_REMOTE_SSH_SOCKET:-}" "${REPOLENS_REMOTE_TARGET:-}"
ssh -S "$REPOLENS_REMOTE_SSH_SOCKET" "$REPOLENS_REMOTE_TARGET" 'cat /etc/hostname'
printf '%s\n' DONE
SH
  chmod +x "$fake_bin/codex"
}

echo ""
echo "=== Test Suite: remote deploy Docker e2e (issue #202) ==="
echo ""

echo "Test 1: documentation and CI describe the Docker opt-in"
assert_file_contains "README documents Docker integration opt-in" \
  "$README_FILE" "Set \`REPOLENS_TEST_DOCKER=1\` to also run integration tests requiring Docker."
assert_file_contains "CI exports REPOLENS_TEST_DOCKER=1" \
  "$CI_FILE" "REPOLENS_TEST_DOCKER: 1"
assert_file_contains "CI runs the remote deploy e2e test" \
  "$CI_FILE" "tests/test_remote_deploy_e2e.sh"
assert_file_contains "CONTRIBUTING documents the Docker integration opt-in" \
  "$CONTRIBUTING_FILE" "REPOLENS_TEST_DOCKER=1"
assert_file_contains "CONTRIBUTING describes Docker integration CI coverage" \
  "$CONTRIBUTING_FILE" "Docker integration"

echo ""
echo "Test 2: Docker target contract is loopback-only and reproducible"
assert_eq "Docker port publish is loopback-only" \
  "127.0.0.1:12222:2222" "$DOCKER_PORT_PUBLISH"
assert_file_matches "Docker SSH integration image is pinned by immutable digest" \
  "$0" 'DOCKER_IMAGE="lscr\.io/linuxserver/openssh-server@sha256:[0-9a-f]{64}"'
assert_not_file_contains "Test source does not use broad Docker port publishing" \
  "$0" "-p $BROAD_DOCKER_PORT_PUBLISH"

if [[ "${REPOLENS_TEST_DOCKER:-}" != "1" ]]; then
  echo ""
  echo "SKIP: set REPOLENS_TEST_DOCKER=1 to run Docker SSH integration test"
  echo ""
  echo "Results: $PASS/$TOTAL passed, $FAIL failed"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
  exit 0
fi

echo ""
echo "Test 3: Docker SSH remote deploy run produces expected artifacts"
require_command docker
require_command git
require_command jq
require_command ssh
require_command ssh-keyscan

if ! docker info >/dev/null 2>&1; then
  echo "ERROR: REPOLENS_TEST_DOCKER=1 requires a reachable Docker daemon." >&2
  exit 1
fi

if [[ ! -f "$REMOTE_KEY" || ! -f "$REMOTE_PUBKEY" ]]; then
  echo "ERROR: missing test SSH key fixtures under tests/fixtures." >&2
  exit 1
fi

HOME_DIR="$TMPDIR/home"
SSH_DIR="$HOME_DIR/.ssh"
KNOWN_HOSTS="$SSH_DIR/known_hosts"
DUMMY_REPO="$TMPDIR/dummy-repo"
FAKE_BIN="$TMPDIR/bin"
RUN_LOG="$TMPDIR/repolens-run.log"
LOGIN_LOG="$TMPDIR/ssh-login.log"
CONTROL_DIR_LOG="$TMPDIR/control-dir.log"
PROMPT_LOG="$TMPDIR/agent-prompt.log"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
: > "$KNOWN_HOSTS"
chmod 600 "$KNOWN_HOSTS"

setup_dummy_repo "$DUMMY_REPO"
setup_fake_agent "$FAKE_BIN"

cleanup_container

set +e
docker run -d --rm \
  --name "$DOCKER_CONTAINER" \
  -p "$DOCKER_PORT_PUBLISH" \
  -e PUBLIC_KEY="$(cat "$REMOTE_PUBKEY")" \
  -e USER_NAME=tester \
  "$DOCKER_IMAGE" >"$TMPDIR/docker-run.out" 2>"$TMPDIR/docker-run.err"
docker_rc=$?
set -e

if [[ "$docker_rc" -ne 0 ]]; then
  record_fail "Docker OpenSSH container starts (rc=$docker_rc, $(cat "$TMPDIR/docker-run.err"))"
else
  CONTAINER_STARTED=true
  record_pass "Docker OpenSSH container starts"
fi

ports="$(docker inspect -f '{{range $p, $bindings := .NetworkSettings.Ports}}{{range $bindings}}{{.HostIp}}:{{.HostPort}}->{{$p}} {{end}}{{end}}' "$DOCKER_CONTAINER" 2>/dev/null || true)"
if [[ "$ports" == *"127.0.0.1:12222->2222/tcp"* && "$ports" != *"0.0.0.0:12222"* && "$ports" != *":::12222"* ]]; then
  record_pass "Docker publishes SSH only on loopback"
else
  record_fail "Docker publishes SSH only on loopback (ports='$ports')"
fi

if wait_for_sshd "$KNOWN_HOSTS" "$LOGIN_LOG"; then
  record_pass "Docker sshd becomes reachable with the test key"
else
  record_fail "Docker sshd becomes reachable with the test key ($(cat "$LOGIN_LOG" 2>/dev/null || true))"
fi

container_hostname="$(docker inspect -f '{{.Config.Hostname}}' "$DOCKER_CONTAINER" 2>/dev/null || true)"

set +e
HOME="$HOME_DIR" \
PATH="$FAKE_BIN:$PATH" \
REPOLENS_FAKE_CONTROL_DIR_LOG="$CONTROL_DIR_LOG" \
REPOLENS_FAKE_PROMPT_LOG="$PROMPT_LOG" \
REPOLENS_TEST_KNOWN_HOSTS="$KNOWN_HOSTS" \
bash "$REPOLENS" \
  --project "$DUMMY_REPO" \
  --agent codex \
  --mode deploy \
  --remote tester@127.0.0.1:12222 \
  --remote-key "$REMOTE_KEY" \
  --remote-label "test-target" \
  --focus service-health \
  --max-issues 1 \
  --local \
  --yes >"$RUN_LOG" 2>&1
run_rc=$?
set -e

run_id="$(parse_run_id "$RUN_LOG")"
if [[ -n "$run_id" ]]; then
  CREATED_LOG_DIRS+=("$SCRIPT_DIR/logs/$run_id")
fi
run_dir="$SCRIPT_DIR/logs/$run_id"
preflight_log="$run_dir/.remote/preflight.log"
status_json="$run_dir/status.json"
transcript="$(find "$run_dir/deployment/service-health" -maxdepth 1 -type f -name 'iteration-*.txt' 2>/dev/null | sort | head -1 || true)"
control_dir="$(cat "$CONTROL_DIR_LOG" 2>/dev/null || true)"

assert_eq "RepoLens remote deploy exits zero" "0" "$run_rc"
assert_file_contains "Preflight log contains the container hostname" \
  "$preflight_log" "$container_hostname"
assert_file_contains "Preflight log contains Linux uname output" \
  "$preflight_log" "Linux"
assert_eq "status.json records remote_target" \
  "tester@127.0.0.1:12222" "$(jq -r '.remote_target // empty' "$status_json" 2>/dev/null || true)"
assert_eq "status.json records remote_label" \
  "test-target" "$(jq -r '.remote_label // empty' "$status_json" 2>/dev/null || true)"
assert_file_matches "Transcript contains SSH ControlMaster invocation" \
  "$transcript" "ssh -S .+ tester@127\\.0\\.0\\.1:12222 'hostname && uname -a'"
assert_file_contains "Transcript contains SSH-wrapped /etc command" \
  "$transcript" "tester@127.0.0.1:12222 'cat /etc/hostname'"
assert_no_bare_deploy_commands "Transcript has no bare deploy commands" "$transcript"
assert_path_absent "ControlMaster directory is removed after run" "$control_dir"

cleanup_container
remaining_container="$(docker ps -a --filter "name=^/${DOCKER_CONTAINER}$" --format '{{.Names}}' 2>/dev/null || true)"
assert_eq "Docker container is removed after cleanup" "" "$remaining_container"

echo ""
echo "=== Results ==="
echo "Total: $TOTAL"
echo "Passed: $PASS"
echo "Failed: $FAIL"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi

exit 0
