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

# Regression coverage for issue #221: a stale running status snapshot that
# began before shutdown must not publish after the terminal snapshot.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
# shellcheck source=tests/status_test_lib.sh
source "$SCRIPT_DIR/tests/status_test_lib.sh"
source "$SCRIPT_DIR/lib/status.sh"
trap status_cleanup EXIT

# shellcheck disable=SC2329 # Invoked indirectly by write_status_snapshot in sourced lib/status.sh.
log_warn() {
  :
}

echo "=== status.json terminal snapshot wins stale running writer race ==="
status_require_jq

LOG_BASE="$STATUS_TEST_TMPDIR/status-race"
HEARTBEAT_DIR="$LOG_BASE/.heartbeat"
COMPLETED_FILE="$LOG_BASE/.completed"
SUMMARY_FILE="$LOG_BASE/summary.json"
LENSES_FILE="$LOG_BASE/.status-lenses"
STATUS_FILE="$LOG_BASE/status.json"
RUNNING_MV_READY="$STATUS_TEST_TMPDIR/running-mv-ready"
RUNNING_MV_RELEASE="$STATUS_TEST_TMPDIR/running-mv-release"
mkdir -p "$HEARTBEAT_DIR"

cat > "$SUMMARY_FILE" <<'JSON'
{
  "run_id": "status-race",
  "started_at": "2026-01-02T03:04:05Z",
  "totals": {
    "issues_created": 0
  }
}
JSON
printf '%s\n' "security/xss" > "$LENSES_FILE"

# shellcheck disable=SC2329 # Command override invoked by write_status_snapshot.
mv() {
  local args=("$@")
  local argc="${#args[@]}"
  local src="" dest="" state

  if (( argc >= 2 )); then
    src="${args[$((argc - 2))]}"
    dest="${args[$((argc - 1))]}"
  fi

  if [[ "${BLOCK_RUNNING_STATUS_MV:-}" == "1" && "$dest" == "$STATUS_FILE" && "$src" == "$STATUS_FILE".tmp.* ]]; then
    state="$(jq -r '.state // empty' "$src" 2>/dev/null || true)"
    if [[ "$state" == "running" ]]; then
      : > "$RUNNING_MV_READY"
      for _ in {1..80}; do
        [[ -f "$RUNNING_MV_RELEASE" ]] && break
        sleep 0.05
      done
    fi
  fi

  command mv "$@"
}

BLOCK_RUNNING_STATUS_MV=1 write_status_snapshot \
  "running" \
  "status-race" \
  "$LOG_BASE" \
  "$HEARTBEAT_DIR" \
  "$COMPLETED_FILE" \
  "$SUMMARY_FILE" \
  "$STATUS_TEST_TMPDIR/project" \
  "owner/repo" \
  "audit" \
  "codex" \
  "true" \
  "2" \
  "$LENSES_FILE" &
stale_writer_pid=$!

TOTAL=$((TOTAL + 1))
for _ in {1..40}; do
  [[ -f "$RUNNING_MV_READY" ]] && break
  sleep 0.05
done
if [[ -f "$RUNNING_MV_READY" ]]; then
  record_pass "Stale running writer paused before publishing"
else
  record_fail "Stale running writer paused before publishing" "pause marker was not created"
fi

write_status_snapshot \
  "finished" \
  "status-race" \
  "$LOG_BASE" \
  "$HEARTBEAT_DIR" \
  "$COMPLETED_FILE" \
  "$SUMMARY_FILE" \
  "$STATUS_TEST_TMPDIR/project" \
  "owner/repo" \
  "audit" \
  "codex" \
  "true" \
  "2" \
  "$LENSES_FILE" &
terminal_writer_pid=$!

sleep 0.2
: > "$RUNNING_MV_RELEASE"
wait "$stale_writer_pid" 2>/dev/null || true
wait "$terminal_writer_pid" 2>/dev/null || true

assert_jq "Final status file is valid JSON" "$STATUS_FILE" '.'
assert_jq "Terminal state is not overwritten by stale running snapshot" "$STATUS_FILE" '.state == "finished"'

write_status_snapshot \
  "interrupted" \
  "status-race" \
  "$LOG_BASE" \
  "$HEARTBEAT_DIR" \
  "$COMPLETED_FILE" \
  "$SUMMARY_FILE" \
  "$STATUS_TEST_TMPDIR/project" \
  "owner/repo" \
  "audit" \
  "codex" \
  "true" \
  "2" \
  "$LENSES_FILE"

write_status_snapshot \
  "running" \
  "status-race" \
  "$LOG_BASE" \
  "$HEARTBEAT_DIR" \
  "$COMPLETED_FILE" \
  "$SUMMARY_FILE" \
  "$STATUS_TEST_TMPDIR/project" \
  "owner/repo" \
  "audit" \
  "codex" \
  "true" \
  "2" \
  "$LENSES_FILE"

assert_jq "Running snapshot does not overwrite existing interrupted terminal state" "$STATUS_FILE" '.state == "interrupted"'

write_status_snapshot \
  "rate-limit-pending" \
  "status-race" \
  "$LOG_BASE" \
  "$HEARTBEAT_DIR" \
  "$COMPLETED_FILE" \
  "$SUMMARY_FILE" \
  "$STATUS_TEST_TMPDIR/project" \
  "owner/repo" \
  "audit" \
  "codex" \
  "true" \
  "2" \
  "$LENSES_FILE"

write_status_snapshot \
  "running" \
  "status-race" \
  "$LOG_BASE" \
  "$HEARTBEAT_DIR" \
  "$COMPLETED_FILE" \
  "$SUMMARY_FILE" \
  "$STATUS_TEST_TMPDIR/project" \
  "owner/repo" \
  "audit" \
  "codex" \
  "true" \
  "2" \
  "$LENSES_FILE"

assert_jq "Running snapshot does not overwrite existing rate-limit-pending terminal state" "$STATUS_FILE" '.state == "rate-limit-pending"'

REPOLENS_STATUS_ALLOW_RUNNING_OVER_TERMINAL=true write_status_snapshot \
  "running" \
  "status-race" \
  "$LOG_BASE" \
  "$HEARTBEAT_DIR" \
  "$COMPLETED_FILE" \
  "$SUMMARY_FILE" \
  "$STATUS_TEST_TMPDIR/project" \
  "owner/repo" \
  "audit" \
  "codex" \
  "true" \
  "2" \
  "$LENSES_FILE"

assert_jq "Resume override allows running snapshot to replace terminal state" "$STATUS_FILE" '.state == "running"'

touch \
  "$LOG_BASE/status.json.tmp.123" \
  "$LOG_BASE/.status.active.123" \
  "$LOG_BASE/.status.completed.123" \
  "$LOG_BASE/.status.lenses.123"
cleanup_status_snapshot_temps "$LOG_BASE"

TOTAL=$((TOTAL + 1))
if compgen -G "$LOG_BASE/status.json.tmp.*" >/dev/null \
  || compgen -G "$LOG_BASE/.status.active.*" >/dev/null \
  || compgen -G "$LOG_BASE/.status.completed.*" >/dev/null \
  || compgen -G "$LOG_BASE/.status.lenses.*" >/dev/null; then
  record_fail "Status snapshot temp cleanup removes stale helper files"
else
  record_pass "Status snapshot temp cleanup removes stale helper files"
fi

status_finish
