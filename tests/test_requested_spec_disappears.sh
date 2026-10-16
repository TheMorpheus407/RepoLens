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


# repolens-r8-p1-3: every explicitly requested specification remains required.
# shellcheck disable=SC2034 # Library API consumes fixture variables.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$(mktemp -d)"
mkdir -p "$REPO/logs"
RUN_DIR="$(mktemp -d "$REPO/logs/test-spec-vanish.XXXXXX")"
trap 'rm -rf -- "$FIXTURE" "$RUN_DIR"' EXIT
# shellcheck source=lib/template.sh
source "$REPO/lib/template.sh"
PASS=0 FAIL=0
# Run an assertion and accumulate failures so the full scenario is checked.
check() {
  if "$@"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$*"; fi
}
for mode in audit feature bugfix greenfield spec-change; do
  rc=0
  rendered="$(compose_prompt "$REPO/prompts/_base/$mode.md" "$REPO/prompts/lenses/security/injection.md" '' "$FIXTURE/missing-spec.md" "$mode")" || rc=$?
  check test "$rc" -ne 0
  check test -z "$rendered"
done
mkdir -p "$FIXTURE/bin"
export SPEC_FIXTURE="$FIXTURE"
printf 'SPEC_SENTINEL_PER_LENS\n' > "$FIXTURE/spec.md"
cat > "$FIXTURE/bin/codex" <<'AGENT'
#!/usr/bin/env bash
set -euo pipefail
n=1
if [[ -f "$SPEC_FIXTURE/calls" ]]; then n=$(( $(cat "$SPEC_FIXTURE/calls") + 1 )); fi
printf '%s\n' "$n" > "$SPEC_FIXTURE/calls"
printf '%s\n' "${!#}" > "$SPEC_FIXTURE/prompt-$n.md"
if (( n == 1 )); then rm -f -- "$SPEC_FIXTURE/spec.md"; fi
printf 'DONE\n'
AGENT
cat > "$FIXTURE/bin/gh" <<'FORGE'
#!/usr/bin/env bash
set -euo pipefail
printf '[]\n'
FORGE
chmod +x "$FIXTURE/bin/codex" "$FIXTURE/bin/gh"
# Run or resume the two-lens audit with fixture-only model and forge stubs.
run_cli() {
  env -u TASK_HOURS -u REPOLENS_ROUNDS -u DONE_STREAK_REQUIRED \
    PATH="$FIXTURE/bin:$PATH" REPOLENS_AGENT_TIMEOUT=5 REPOLENS_AGENT_KILL_GRACE=1 \
    REPOLENS_LENS_HEARTBEAT_INTERVAL=0 REPOLENS_STATUS_INTERVAL=1 \
    bash "$REPO/repolens.sh" --project "$REPO" --agent codex --mode audit \
      --local --output "$FIXTURE/output" --yes --resume "${RUN_DIR##*/}" \
      --domain i18n --rounds 1 --depth 1 --spec "$FIXTURE/spec.md"
}
rc=0
run_cli > "$FIXTURE/first.log" 2>&1 || rc=$?
check test "$rc" -ne 0
check test "$(cat "$FIXTURE/calls")" -eq 1
check grep -q SPEC_SENTINEL_PER_LENS "$FIXTURE/prompt-1.md"
check test ! -e "$FIXTURE/prompt-2.md"
check jq -e '.state == "failed"' "$RUN_DIR/status.json"
check jq -e '.stopped_reason == "prompt-render-failed"' "$RUN_DIR/summary.json"
check test "$(wc -l < "$RUN_DIR/.completed")" -eq 1
check test ! -e "$RUN_DIR/rounds/round-1/.completed"
printf 'SPEC_SENTINEL_PER_LENS\n' > "$FIXTURE/spec.md"
rc=0
run_cli > "$FIXTURE/resume.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test "$(cat "$FIXTURE/calls")" -eq 2
check grep -q SPEC_SENTINEL_PER_LENS "$FIXTURE/prompt-2.md"
check test "$(wc -l < "$RUN_DIR/.completed")" -eq 2
check jq -e '.state == "finished-empty"' "$RUN_DIR/status.json"
printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
