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

# Regression coverage for issue #277: terminal rate-limit-pending snapshots
# expose a known retry timestamp, while stale retry metadata is hidden for
# every other terminal state.

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

echo "=== status.json next_action retry metadata ==="
status_require_jq

LOG_BASE="$STATUS_TEST_TMPDIR/next-action"
HEARTBEAT_DIR="$LOG_BASE/.heartbeat"
COMPLETED_FILE="$LOG_BASE/.completed"
SUMMARY_FILE="$LOG_BASE/summary.json"
LENSES_FILE="$LOG_BASE/.status-lenses"
STATUS_FILE="$LOG_BASE/status.json"
mkdir -p "$HEARTBEAT_DIR"

cat > "$SUMMARY_FILE" <<'JSON'
{
  "run_id": "next-action",
  "started_at": "2026-05-14T13:00:00Z",
  "totals": {
    "issues_created": 0
  }
}
JSON
printf '%s\n' "i18n/i18n-strings" > "$LENSES_FILE"
printf '%s\n' "i18n/i18n-strings" > "$COMPLETED_FILE"

write_snapshot() {
  local state="$1"
  write_status_snapshot \
    "$state" \
    "next-action" \
    "$LOG_BASE" \
    "$HEARTBEAT_DIR" \
    "$COMPLETED_FILE" \
    "$SUMMARY_FILE" \
    "$STATUS_TEST_TMPDIR/project" \
    "owner/repo" \
    "audit" \
    "codex" \
    "false" \
    "1" \
    "$LENSES_FILE"
}

cat > "$LOG_BASE/.rate-limit-abort" <<'EOF_MARKER'
earliest_at=2026-05-14T21:30:00Z
resume_epoch=1778794200
source=lens-rate-limit
EOF_MARKER

if write_snapshot "rate-limit-pending"; then
  assert_eq "rate-limit-pending snapshot write succeeds" "0" "0"
else
  assert_eq "rate-limit-pending snapshot write succeeds" "0" "1"
fi
assert_jq "rate-limit-pending exposes the known UTC retry timestamp" "$STATUS_FILE" \
  '.state == "rate-limit-pending"
   and (.next_action | type == "object")
   and .next_action.earliest_at == "2026-05-14T21:30:00Z"'

cat > "$LOG_BASE/.rate-limit-abort" <<'EOF_MARKER'
earliest_at=not-a-timestamp
resume_epoch=1778794200
source=lens-rate-limit
EOF_MARKER
write_snapshot "rate-limit-pending"
assert_jq "rate-limit-pending omits malformed retry metadata" "$STATUS_FILE" \
  '.state == "rate-limit-pending" and (has("next_action") | not)'

cat > "$LOG_BASE/.rate-limit-abort" <<'EOF_MARKER'
earliest_at=2026-05-14T21:30:00Z
resume_epoch=1778794200
source=lens-rate-limit
EOF_MARKER

for terminal_state in finished finished-empty failed interrupted; do
  write_snapshot "$terminal_state"
  assert_jq "$terminal_state omits stale retry metadata" "$STATUS_FILE" \
    ".state == \"$terminal_state\" and (has(\"next_action\") | not)"
done

status_finish
