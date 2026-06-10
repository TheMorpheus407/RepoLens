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

# Integration test for issue #121: a clean run leaves a final finished
# status.json snapshot with no active lenses.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
# shellcheck source=tests/status_test_lib.sh
source "$SCRIPT_DIR/tests/status_test_lib.sh"
trap status_cleanup EXIT

echo "=== status.json final finished state ==="
status_require_jq

PROJECT="$STATUS_TEST_TMPDIR/project"
FAKE_BIN="$STATUS_TEST_TMPDIR/bin"
OUT_FILE="$STATUS_TEST_TMPDIR/run.log"
mkdir -p "$FAKE_BIN"
status_setup_project "$PROJECT"

cat > "$FAKE_BIN/codex" <<'SH'
#!/usr/bin/env bash
echo "Analysis complete. No findings."
echo "DONE"
exit 0
SH
chmod +x "$FAKE_BIN/codex"

set +e
env \
  PATH="$FAKE_BIN:$PATH" \
  REPOLENS_STATUS_INTERVAL=1 \
  REPOLENS_LENS_HEARTBEAT_INTERVAL=1 \
  REPOLENS_AGENT_TIMEOUT=15 \
  bash "$STATUS_TEST_ROOT/repolens.sh" \
    --project "$PROJECT" \
    --agent codex \
    --focus i18n-strings \
    --change "status final test" \
    --local \
    --yes \
    >"$OUT_FILE" 2>&1
run_rc=$?
set -e

RUN_ID="$(parse_run_id "$OUT_FILE")"
status_register_run_id "$RUN_ID"
STATUS_FILE="$STATUS_TEST_ROOT/logs/$RUN_ID/status.json"
SUMMARY_FILE="$STATUS_TEST_ROOT/logs/$RUN_ID/summary.json"

assert_eq "RepoLens run exits cleanly" "0" "$run_rc"
assert_jq "Final status file is valid JSON" "$STATUS_FILE" '.'
assert_jq "Final status records terminal finished state" "$STATUS_FILE" '.state | IN("finished", "finished-empty")'
assert_jq "Final status exposes unset stopped reason as null" "$STATUS_FILE" \
  'has("stopped_reason") and .stopped_reason == null'
assert_jq "Final status has no active lenses" "$STATUS_FILE" '.counts.active == 0 and (.active | length == 0)'
assert_jq "Final status marks the focused lens completed" "$STATUS_FILE" \
  '.total_lenses == 1
   and .counts.completed == 1
   and .counts.queued == 0
   and (.completed | index("i18n/i18n-strings"))'

summary_issues="$(jq -r '.totals.issues_created // empty' "$SUMMARY_FILE" 2>/dev/null || true)"
status_issues="$(jq -r '.counts.issues_created // empty' "$STATUS_FILE" 2>/dev/null || true)"
assert_eq "Final status issue count matches summary totals" "$summary_issues" "$status_issues"

status_finish
