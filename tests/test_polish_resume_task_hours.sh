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

# #428: persisted task hours reach newly emitted polish bodies via the real CLI.
# The only agent executable is a deterministic PATH shim; no model or forge runs.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$SCRIPT_DIR/logs"
LOG_BASE="$(mktemp -d "$SCRIPT_DIR/logs/test-polish-resume-hours.XXXXXX")" || exit 1
RUN_ID="${LOG_BASE##*/}"
trap 'rm -rf "$LOG_BASE"' EXIT
mkdir -p "$LOG_BASE/polish" "$LOG_BASE/bin"

passed=0
failed=0
check() {
  if "$@"; then passed=$((passed + 1)); else failed=$((failed + 1)); printf 'FAIL: %s\n' "$*"; fi
}
contains() { [[ "$1" == *"$2"* ]]; }
not_contains() { [[ "$1" != *"$2"* ]]; }

# Seed an interrupted run with suggestions, but no filed bodies or URL markers.
printf '6\n' > "$LOG_BASE/task-hours"
cat > "$LOG_BASE/polish/suggestions.json" <<'JSON'
[
  {
    "title": "Clarify progress reporting",
    "domain": "effort-signal",
    "lens_id": "loading-transparency",
    "source_path": "repolens.sh",
    "polish_family": "effort-signal",
    "voice_fit": "strong",
    "location_expectedness": "expected",
    "body": "Keep progress messages concise during long-running audits."
  }
]
JSON
cat > "$LOG_BASE/bin/codex" <<'AGENT'
#!/usr/bin/env bash
# A valid voice profile for the prepass and DONE for the single focused lens.
cat <<'PROFILE'
## Project Voice Profile
Register: plain - Direct and practical.
Who it is for / who loves it: Developers who value concise audit reports.
Product purpose: Audit repositories and report actionable findings.

Soul:
- Precise.
- Practical.
- Restrained.

Off-brand here:
- Decorative or playful progress messages.

DONE
PROFILE
AGENT
chmod +x "$LOG_BASE/bin/codex"

# Omit --task-hours and remove inherited hours so the saved file supplies 6.
env -u TASK_HOURS -u REPOLENS_ROUNDS -u DONE_STREAK_REQUIRED \
  PATH="$LOG_BASE/bin:$PATH" REPOLENS_AGENT_TIMEOUT=5 REPOLENS_AGENT_KILL_GRACE=1 \
  bash "$SCRIPT_DIR/repolens.sh" --project "$SCRIPT_DIR" --agent codex \
    --mode polish --local --yes --focus loading-transparency \
    --resume "$RUN_ID" --rounds 1 --depth 1 --output "$LOG_BASE/output" \
    >"$LOG_BASE/cli.out" 2>&1
cli_rc=$?
check test "$cli_rc" -eq 0
if (( cli_rc != 0 )); then
  cat "$LOG_BASE/cli.out"
fi
body_file="$LOG_BASE/polish/filed/effort-signal-loading-transparency.md"
check test -s "$body_file"
body="$(cat "$body_file" 2>/dev/null)"
check contains "$body" 'Clarify progress reporting'
check contains "$body" '- Each accepted polish item remains scoped to approximately 6 hours.'
check not_contains "$body" '- Each accepted polish item remains scoped to approximately one hour.'

printf 'Results: %s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
