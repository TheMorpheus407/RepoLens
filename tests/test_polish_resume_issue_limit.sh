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

# repolens-r18-p4-2: resume must retain the saved creation limit.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
mkdir -p "$ROOT/logs" || exit 1
RUN_DIR="$(mktemp -d "$ROOT/logs/test-polish-resume-limit.XXXXXX")" || exit 1
trap 'rm -rf -- "$RUN_DIR"' EXIT
RUN_ID="${RUN_DIR##*/}"
mkdir -p "$RUN_DIR/bin" "$RUN_DIR/polish" || exit 1
cat > "$RUN_DIR/bin/codex" <<'AGENT' || exit 1
#!/usr/bin/env bash
set -uo pipefail
printf 'DONE\n' || exit 1
AGENT
cat > "$RUN_DIR/bin/gh" <<'FORGE' || exit 1
#!/usr/bin/env bash
set -uo pipefail
printf '[]\n' || exit 1
FORGE
chmod +x "$RUN_DIR/bin/codex" "$RUN_DIR/bin/gh" || exit 1
printf 'Saved voice profile.\n' > "$RUN_DIR/polish/voice-profile.md" || exit 1
cat > "$RUN_DIR/polish/suggestions.json" <<'JSON' || exit 1
[{"domain":"effort-signal","lens_id":"loading-transparency","title":"First shortlist","body":"First concrete refinement","voice_fit":"strong","location_expectedness":"expected"},{"domain":"effort-signal","lens_id":"error-specificity","title":"Second shortlist","body":"Second concrete refinement","voice_fit":"strong","location_expectedness":"expected"}]
JSON
# Fail on either receipt enumeration errors or an unexpected count.
assert_receipts() {
  local count
  count="$(find "$RUN_DIR/polish/filed" -name '*.url' | wc -l)" || return 1
  test "$count" -eq "$1"
}
# Resume the fixture through the CLI with local agent and forge stubs.
run_cli() {
  env -u TASK_HOURS -u REPOLENS_ROUNDS -u DONE_STREAK_REQUIRED \
    PATH="$RUN_DIR/bin:$PATH" REPOLENS_AGENT_TIMEOUT=5 REPOLENS_AGENT_KILL_GRACE=1 \
    REPOLENS_LENS_HEARTBEAT_INTERVAL=0 REPOLENS_STATUS_INTERVAL=1 \
    bash "$ROOT/repolens.sh" --project "$ROOT" --agent codex --mode polish \
    --local --output "$RUN_DIR/output" --yes --resume "$RUN_ID" \
    --focus loading-transparency --rounds 1 --depth 1 "$@"
}
run_cli --max-issues 1 > "$RUN_DIR/first.log" 2>&1 || { cat "$RUN_DIR/first.log"; exit 1; }
assert_receipts 1 || exit 1
jq -e '.max_issues == 1 and .totals.issues_created == 1' "$RUN_DIR/summary.json" >/dev/null || exit 1
run_cli > "$RUN_DIR/resume.log" 2>&1 || { cat "$RUN_DIR/resume.log"; exit 1; }
receipts="$(find "$RUN_DIR/polish/filed" -name '*.url' | wc -l)" || exit 1
printf 'saved_limit=1 receipts_after_resume=%s\n' "$receipts" || exit 1
test "$receipts" -eq 1 || exit 1
jq -e '.max_issues == 1 and .totals.issues_created == 1' "$RUN_DIR/summary.json" >/dev/null || exit 1
# A deliberate replacement still permits the remaining shortlist exactly once.
run_cli --max-issues 2 > "$RUN_DIR/override.log" 2>&1 || { cat "$RUN_DIR/override.log"; exit 1; }
assert_receipts 2 || exit 1
jq -e '.max_issues == 2 and .totals.issues_created == 2' "$RUN_DIR/summary.json" >/dev/null || { cat "$RUN_DIR/summary.json"; cat "$RUN_DIR/override.log"; exit 1; }
# The replacement becomes the saved cap for subsequent flag-free resumes.
run_cli > "$RUN_DIR/replaced-resume.log" 2>&1 || { cat "$RUN_DIR/replaced-resume.log"; exit 1; }
assert_receipts 2 || exit 1
jq -e '.max_issues == 2 and .totals.issues_created == 2' "$RUN_DIR/summary.json" >/dev/null || exit 1
printf 'Results: saved polish limit retained; explicit replacement respected and persisted\n'
