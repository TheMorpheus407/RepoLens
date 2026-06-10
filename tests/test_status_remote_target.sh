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

# Behavioral tests for issue #200: run artifacts and the public status command
# preserve the audited remote target, while local runs expose stable null fields.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
# shellcheck source=tests/status_test_lib.sh
source "$SCRIPT_DIR/tests/status_test_lib.sh"
trap status_cleanup EXIT

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    record_fail "$desc" "unexpected needle='$needle'"
  else
    record_pass "$desc"
  fi
}

run_deploy() {
  local project="$1" log_file="$2"
  shift 2
  bash "$STATUS_TEST_ROOT/repolens.sh" \
    --project "$project" \
    --agent codex \
    --mode deploy \
    --local \
    --yes \
    --focus service-health \
    "$@" \
    >"$log_file" 2>&1
}

echo "=== status artifacts capture remote target metadata ==="
status_require_jq

PROJECT="$STATUS_TEST_TMPDIR/project"
FAKE_BIN="$STATUS_TEST_TMPDIR/bin"
mkdir -p "$FAKE_BIN"
status_setup_project "$PROJECT"

cat > "$FAKE_BIN/codex" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "Analysis complete. No findings."
printf '%s\n' "DONE"
exit 0
SH
chmod +x "$FAKE_BIN/codex"

cat > "$FAKE_BIN/ssh" <<'SH'
#!/usr/bin/env bash
if [[ -n "${FAKE_SSH_ARGS_LOG:-}" ]]; then
  printf '%s\n' "$*" >> "$FAKE_SSH_ARGS_LOG"
  prev=""
  for arg in "$@"; do
    if [[ "$prev" == "-S" ]]; then
      control_path="$arg"
      control_dir="$(dirname "$control_path")"
      printf 'CONTROL_SOCKET=%s\n' "$control_path" >> "$FAKE_SSH_ARGS_LOG"
      if [[ -d "$control_dir" ]]; then
        printf 'CONTROL_DIR=%s\n' "$control_dir" >> "$FAKE_SSH_ARGS_LOG"
        printf 'CONTROL_DIR_MODE=%s\n' "$(stat -c '%a' "$control_dir")" >> "$FAKE_SSH_ARGS_LOG"
        printf 'CONTROL_DIR_OWNER=%s\n' "$(stat -c '%u' "$control_dir")" >> "$FAKE_SSH_ARGS_LOG"
      fi
    fi
    case "$arg" in
      ControlPath=*)
        control_path="${arg#ControlPath=}"
        control_dir="$(dirname "$control_path")"
        printf 'CONTROL_PATH=%s\n' "$control_path" >> "$FAKE_SSH_ARGS_LOG"
        if [[ -d "$control_dir" ]]; then
          printf 'CONTROL_DIR=%s\n' "$control_dir" >> "$FAKE_SSH_ARGS_LOG"
          printf 'CONTROL_DIR_MODE=%s\n' "$(stat -c '%a' "$control_dir")" >> "$FAKE_SSH_ARGS_LOG"
          printf 'CONTROL_DIR_OWNER=%s\n' "$(stat -c '%u' "$control_dir")" >> "$FAKE_SSH_ARGS_LOG"
        fi
        ;;
    esac
    prev="$arg"
  done
fi
if [[ "$*" == *"failhost"* ]]; then
  printf '%s\n' "simulated ssh preflight failure for failhost"
  exit 255
fi
printf '%s\n' "remote-preflight-host"
printf '%s\n' "Linux remote-preflight 6.1.0-test #1 SMP"
exit 0
SH
chmod +x "$FAKE_BIN/ssh"

REMOTE_LOG="$STATUS_TEST_TMPDIR/remote-run.log"
FAKE_SSH_ARGS_LOG="$STATUS_TEST_TMPDIR/ssh-args.log"
export FAKE_SSH_ARGS_LOG
REMOTE_LABEL='Prod "C" | check'
set +e
PATH="$FAKE_BIN:$PATH" run_deploy "$PROJECT" "$REMOTE_LOG" \
  --remote ubuntu@x:2222 \
  --remote-label "$REMOTE_LABEL"
remote_rc=$?
set -e

REMOTE_RUN_ID="$(parse_run_id "$REMOTE_LOG")"
status_register_run_id "$REMOTE_RUN_ID"
REMOTE_RUN_DIR="$STATUS_TEST_ROOT/logs/$REMOTE_RUN_ID"
REMOTE_STATUS="$REMOTE_RUN_DIR/status.json"
REMOTE_SUMMARY="$REMOTE_RUN_DIR/summary.json"
REMOTE_PREFLIGHT="$REMOTE_RUN_DIR/.remote/preflight.log"
REMOTE_JSON_OUT="$STATUS_TEST_TMPDIR/remote-status-json.out"
REMOTE_HUMAN_OUT="$STATUS_TEST_TMPDIR/remote-status-human.out"
REMOTE_HUMAN_ERR="$STATUS_TEST_TMPDIR/remote-status-human.err"

assert_eq "Remote deploy run exits 0" "0" "$remote_rc"
assert_not_contains "Remote deploy run does not call real ssh" "Could not resolve hostname" "$(cat "$REMOTE_LOG")"
assert_jq_arg "status.json records the raw remote target" "$REMOTE_STATUS" target "ubuntu@x" \
  'has("remote_target") and .remote_target == ($target + ":2222")'
assert_jq_arg "status.json records the explicit remote label" "$REMOTE_STATUS" label "$REMOTE_LABEL" \
  'has("remote_label") and .remote_label == $label'
assert_jq_arg "summary.json records the raw remote target" "$REMOTE_SUMMARY" target "ubuntu@x" \
  'has("remote_target") and .remote_target == ($target + ":2222")'
assert_jq_arg "summary.json records the explicit remote label" "$REMOTE_SUMMARY" label "$REMOTE_LABEL" \
  'has("remote_label") and .remote_label == $label'

bash "$STATUS_TEST_ROOT/repolens.sh" status "$REMOTE_RUN_ID" --json >"$REMOTE_JSON_OUT" 2>"$REMOTE_HUMAN_ERR"
json_rc=$?
assert_eq "status --json exits 0 for remote run" "0" "$json_rc"
assert_jq_arg "status --json includes remote_target" "$REMOTE_JSON_OUT" target "ubuntu@x" \
  '.remote_target == ($target + ":2222")'
assert_jq_arg "status --json includes remote_label" "$REMOTE_JSON_OUT" label "$REMOTE_LABEL" \
  '.remote_label == $label'

bash "$STATUS_TEST_ROOT/repolens.sh" status "$REMOTE_RUN_ID" --no-color >"$REMOTE_HUMAN_OUT" 2>"$REMOTE_HUMAN_ERR"
human_rc=$?
remote_human_output="$(cat "$REMOTE_HUMAN_OUT")"
assert_eq "Human status render exits 0 for remote run" "0" "$human_rc"
assert_contains "Human status renders target and label" \
  "Remote target: ubuntu@x:2222 ($REMOTE_LABEL)" "$remote_human_output"

ssh_args_output="$(cat "$FAKE_SSH_ARGS_LOG" 2>/dev/null || true)"
assert_contains "Remote preflight passes parsed SSH port option" "-p 2222" "$ssh_args_output"
assert_contains "Remote preflight passes host without colon port" "ubuntu@x hostname && uname -a" "$ssh_args_output"
assert_not_contains "Remote preflight does not pass raw host:port as SSH destination" "ubuntu@x:2222" "$ssh_args_output"
assert_contains "Remote preflight disables ControlMaster creation" "ControlMaster=no" "$ssh_args_output"
assert_not_contains "Remote preflight does not use ControlMaster=auto" "ControlMaster=auto" "$ssh_args_output"
assert_not_contains "Remote preflight does not pass a ControlPath" "ControlPath=" "$ssh_args_output"
assert_contains "Remote ControlMaster open sets ControlPersist" "ControlPersist=600" "$ssh_args_output"
expected_remote_socket_hash="$(printf '%s' 'user=ubuntu|host=x|port=2222' | sha256sum)"
expected_remote_socket_hash="${expected_remote_socket_hash%% *}"
expected_remote_socket_hash="${expected_remote_socket_hash:0:16}"
expected_remote_run_hash="$(printf '%s' "$REMOTE_RUN_ID" | sha256sum)"
expected_remote_run_hash="${expected_remote_run_hash%% *}"
expected_remote_run_hash="${expected_remote_run_hash:0:8}"
control_socket="$(awk -F= '$1=="CONTROL_SOCKET"{print $2}' "$FAKE_SSH_ARGS_LOG" | head -1)"
control_dir="$(dirname "$control_socket")"
assert_contains "Remote ControlMaster uses target-bound socket path" \
  "/cm-${expected_remote_socket_hash}-${expected_remote_run_hash}.sock" "$control_socket"
assert_contains "Remote ControlMaster uses secure runtime socket directory" \
  "/rl-cm-${expected_remote_run_hash}." "$control_dir"
assert_not_contains "Remote ControlMaster does not use predictable legacy socket directory" \
  "/tmp/repolens-ssh-" "$control_socket"
assert_not_contains "Remote ControlMaster socket is not under the run log directory" \
  "$REMOTE_RUN_DIR/.remote" "$control_socket"
TOTAL=$((TOTAL + 1))
if (( ${#control_socket} < 90 )); then
  record_pass "Remote ControlMaster socket path is length-bounded"
else
  record_fail "Remote ControlMaster socket path is length-bounded" "length=${#control_socket} path=$control_socket"
fi
assert_contains "Remote ControlMaster control dir mode is 0700" "CONTROL_DIR_MODE=700" "$ssh_args_output"
assert_contains "Remote ControlMaster control dir is owned by current uid" "CONTROL_DIR_OWNER=$(id -u)" "$ssh_args_output"

TOTAL=$((TOTAL + 1))
if [[ -f "$REMOTE_PREFLIGHT" ]] \
  && grep -Fq "remote-preflight-host" "$REMOTE_PREFLIGHT" \
  && grep -Fq "Linux remote-preflight" "$REMOTE_PREFLIGHT"; then
  record_pass "Remote preflight output is captured under .remote/preflight.log"
else
  record_fail "Remote preflight output is captured under .remote/preflight.log" "file=$REMOTE_PREFLIGHT"
fi

FAILED_PREFLIGHT_LOG="$STATUS_TEST_TMPDIR/failed-preflight-run.log"
: > "$FAKE_SSH_ARGS_LOG"
set +e
PATH="$FAKE_BIN:$PATH" run_deploy "$PROJECT" "$FAILED_PREFLIGHT_LOG" \
  --remote deploy@failhost
failed_preflight_rc=$?
set -e

FAILED_PREFLIGHT_RUN_ID="$(parse_run_id "$FAILED_PREFLIGHT_LOG")"
status_register_run_id "$FAILED_PREFLIGHT_RUN_ID"
FAILED_PREFLIGHT_RUN_DIR="$STATUS_TEST_ROOT/logs/$FAILED_PREFLIGHT_RUN_ID"
FAILED_PREFLIGHT_STATUS="$FAILED_PREFLIGHT_RUN_DIR/status.json"
FAILED_PREFLIGHT_SUMMARY="$FAILED_PREFLIGHT_RUN_DIR/summary.json"
FAILED_PREFLIGHT_REMOTE_LOG="$FAILED_PREFLIGHT_RUN_DIR/.remote/preflight.log"
FAILED_PREFLIGHT_HUMAN_OUT="$STATUS_TEST_TMPDIR/failed-preflight-status-human.out"
FAILED_PREFLIGHT_HUMAN_ERR="$STATUS_TEST_TMPDIR/failed-preflight-status-human.err"

assert_eq "Remote deploy continues when preflight ssh fails" "0" "$failed_preflight_rc"
assert_contains "Remote preflight failure is logged without aborting" \
  "Remote preflight failed for deploy@failhost" "$(cat "$FAILED_PREFLIGHT_LOG")"
failed_preflight_ssh_args="$(cat "$FAKE_SSH_ARGS_LOG" 2>/dev/null || true)"
assert_not_contains "Failed preflight does not open ControlMaster" "-fN" "$failed_preflight_ssh_args"
assert_not_contains "Failed preflight does not run ControlMaster check" "-O check" "$failed_preflight_ssh_args"
assert_jq "Failed-preflight status keeps raw remote target and null label" "$FAILED_PREFLIGHT_STATUS" \
  '.remote_target == "deploy@failhost" and .remote_label == null'
assert_jq "Failed-preflight summary keeps raw remote target and null label" "$FAILED_PREFLIGHT_SUMMARY" \
  '.remote_target == "deploy@failhost" and .remote_label == null'

bash "$STATUS_TEST_ROOT/repolens.sh" status "$FAILED_PREFLIGHT_RUN_ID" --no-color >"$FAILED_PREFLIGHT_HUMAN_OUT" 2>"$FAILED_PREFLIGHT_HUMAN_ERR"
failed_preflight_human_rc=$?
failed_preflight_human_output="$(cat "$FAILED_PREFLIGHT_HUMAN_OUT")"
assert_eq "Human status render exits 0 for failed-preflight run" "0" "$failed_preflight_human_rc"
assert_contains "Human status renders unlabelled remote target without parentheses" \
  "Remote target: deploy@failhost" "$failed_preflight_human_output"
assert_not_contains "Human status does not render empty remote label parentheses" \
  "Remote target: deploy@failhost (" "$failed_preflight_human_output"

TOTAL=$((TOTAL + 1))
if [[ -f "$FAILED_PREFLIGHT_REMOTE_LOG" ]] \
  && grep -Fq "simulated ssh preflight failure for failhost" "$FAILED_PREFLIGHT_REMOTE_LOG"; then
  record_pass "Failed remote preflight output is retained under .remote/preflight.log"
else
  record_fail "Failed remote preflight output is retained under .remote/preflight.log" "file=$FAILED_PREFLIGHT_REMOTE_LOG"
fi

LOCAL_LOG="$STATUS_TEST_TMPDIR/local-run.log"
set +e
PATH="$FAKE_BIN:$PATH" run_deploy "$PROJECT" "$LOCAL_LOG"
local_rc=$?
set -e

LOCAL_RUN_ID="$(parse_run_id "$LOCAL_LOG")"
status_register_run_id "$LOCAL_RUN_ID"
LOCAL_RUN_DIR="$STATUS_TEST_ROOT/logs/$LOCAL_RUN_ID"
LOCAL_STATUS="$LOCAL_RUN_DIR/status.json"
LOCAL_SUMMARY="$LOCAL_RUN_DIR/summary.json"
LOCAL_HUMAN_OUT="$STATUS_TEST_TMPDIR/local-status-human.out"
LOCAL_HUMAN_ERR="$STATUS_TEST_TMPDIR/local-status-human.err"

assert_eq "Local deploy run exits 0" "0" "$local_rc"
assert_jq "Local status.json exposes null remote fields" "$LOCAL_STATUS" \
  'has("remote_target") and has("remote_label") and .remote_target == null and .remote_label == null'
assert_jq "Local summary.json exposes null remote fields" "$LOCAL_SUMMARY" \
  'has("remote_target") and has("remote_label") and .remote_target == null and .remote_label == null'

bash "$STATUS_TEST_ROOT/repolens.sh" status "$LOCAL_RUN_ID" --no-color >"$LOCAL_HUMAN_OUT" 2>"$LOCAL_HUMAN_ERR"
local_human_rc=$?
local_human_output="$(cat "$LOCAL_HUMAN_OUT")"
assert_eq "Human status render exits 0 for local run" "0" "$local_human_rc"
assert_not_contains "Local human status omits remote target line" "Remote target:" "$local_human_output"

status_finish
