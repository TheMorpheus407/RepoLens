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

# Focused coverage for issue #121 status snapshot file sources. The CLI
# integration tests cover live lifecycle behavior; this test covers the
# parser branches that are hard to force through a full run.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
# shellcheck source=tests/status_test_lib.sh
source "$SCRIPT_DIR/tests/status_test_lib.sh"
source "$SCRIPT_DIR/lib/status.sh"
trap status_cleanup EXIT

log_warn() {
  :
}

echo "=== status.json file-backed snapshot sources ==="
status_require_jq

unset REPOLENS_STATUS_INTERVAL
assert_eq "Status interval defaults to 10 seconds" "10" "$(resolve_status_interval 2>/dev/null)"

REPOLENS_STATUS_INTERVAL=1
assert_eq "Status interval accepts a positive integer override" "1" "$(resolve_status_interval 2>/dev/null)"

REPOLENS_STATUS_INTERVAL=001
assert_eq "Status interval normalizes leading-zero values" "1" "$(resolve_status_interval 2>/dev/null)"

REPOLENS_STATUS_INTERVAL=0
assert_eq "Status interval rejects zero to avoid a busy loop" "10" "$(resolve_status_interval 2>/dev/null)"

REPOLENS_STATUS_INTERVAL=abc
assert_eq "Status interval rejects non-numeric values" "10" "$(resolve_status_interval 2>/dev/null)"
unset REPOLENS_STATUS_INTERVAL

LOG_BASE="$STATUS_TEST_TMPDIR/run-files"
HEARTBEAT_DIR="$LOG_BASE/.heartbeat"
COMPLETED_FILE="$LOG_BASE/.completed"
SUMMARY_FILE="$LOG_BASE/summary.json"
LENSES_FILE="$LOG_BASE/.status-lenses"
STATUS_FILE="$LOG_BASE/status.json"
mkdir -p "$HEARTBEAT_DIR"

cat > "$SUMMARY_FILE" <<'JSON'
{
  "run_id": "run-files",
  "started_at": "2026-01-02T03:04:05Z",
  "remote_target": "deploy@example.com",
  "remote_label": "Recovered target",
  "stopped_reason": "filing-failed",
  "totals": {
    "issues_created": 7
  }
}
JSON

cat > "$HEARTBEAT_DIR/security__xss.json" <<'JSON'
{
  "run_id": "run-files",
  "domain": "security",
  "lens_id": "xss",
  "pid": 999999999,
  "iteration": "3",
  "started_at": "2026-01-02T03:05:00Z",
  "last_heartbeat_at": "2026-01-02T03:06:00Z",
  "state": "running"
}
JSON

printf 'not valid json\n' > "$HEARTBEAT_DIR/ignored.json"
printf '%s\n' "security/xss" "security/ssrf" "arch/boundaries" > "$LENSES_FILE"
printf '%s\n' "arch/boundaries" "arch/boundaries" > "$COMPLETED_FILE"

if write_status_snapshot \
  "running" \
  "run-files" \
  "$LOG_BASE" \
  "$HEARTBEAT_DIR" \
  "$COMPLETED_FILE" \
  "$SUMMARY_FILE" \
  "/tmp/project path" \
  "owner/repo" \
  "audit" \
  "codex" \
  "true" \
  "8" \
  "$LENSES_FILE"; then
  assert_eq "Snapshot write succeeds from file-backed inputs" "0" "0"
else
  assert_eq "Snapshot write succeeds from file-backed inputs" "0" "1"
fi

assert_jq "Snapshot output is valid JSON" "$STATUS_FILE" '.'
assert_jq "Snapshot reads metadata and issue totals from summary.json" "$STATUS_FILE" \
  '.run_id == "run-files"
   and .repo == "owner/repo"
   and .mode == "audit"
   and .agent == "codex"
   and .remote_target == "deploy@example.com"
   and .remote_label == "Recovered target"
   and .stopped_reason == "filing-failed"
   and .parallel == true
   and .max_parallel == 8
   and .started_at == "2026-01-02T03:04:05Z"
   and .counts.issues_created == 7'
assert_jq "Snapshot keeps stale heartbeat files in active list" "$STATUS_FILE" \
  '.counts.active == 1
   and (.active | length == 1)
   and (.active[0].domain == "security")
   and (.active[0].lens_id == "xss")
   and (.active[0].pid == 999999999)
   and (.active[0].iteration == 3)
   and (.active[0].age_seconds | type == "number")
   and (.active[0].heartbeat_age_seconds | type == "number")'
assert_jq "Snapshot partitions resolved lenses from heartbeat and completed files" "$STATUS_FILE" \
  '.total_lenses == 3
   and .counts.active == 1
   and .counts.completed == 1
   and .counts.queued == 1
   and (.queued == ["security/ssrf"])
   and (.completed == ["arch/boundaries"])
   and (.counts.queued + .counts.active + .counts.completed == .total_lenses)'
assert_jq "Invalid heartbeat files are ignored as transient read failures" "$STATUS_FILE" \
  '(.active | all(.domain != null and .lens_id != null))'

status_finish
