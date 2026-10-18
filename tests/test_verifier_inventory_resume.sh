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

# A full mocked CLI attempt must fail closed on verifier inventory errors and
# resume preparation successfully without rerunning completed lenses.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$(mktemp -d)"
RUN_LOG_DIR=''
cleanup() {
  command rm -rf -- "$FIXTURE"
  [[ -z "$RUN_LOG_DIR" ]] || command rm -rf -- "$RUN_LOG_DIR"
}
trap cleanup EXIT
mkdir -p "$FIXTURE/project" "$FIXTURE/bin"
git -C "$FIXTURE/project" init -q
printf '# Inventory resume fixture\n' > "$FIXTURE/project/README.md"
git -C "$FIXTURE/project" add README.md
git -C "$FIXTURE/project" -c user.name='RepoLens Test' -c user.email='repolens@example.invalid' commit -qm fixture
cat > "$FIXTURE/bin/codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
exec bash "$REPOLENS_TEST_REPO/tests/mock-agent.sh" "$@"
SH
cat > "$FIXTURE/bin/find" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
inventory_args=("$@")
[[ "${inventory_args[0]:-}" != -H ]] || inventory_args=("${inventory_args[@]:1}")
if [[ -e "$REPOLENS_TEST_FAULT" && "${inventory_args[0]:-}" == */rounds && "${inventory_args[2]:-}" == '*/lens-outputs/*.md' ]]; then
  # Recreate saved output from a previous attempt at the inventory boundary.
  cp "$REPOLENS_TEST_SAVED/verification.json" "$LOG_BASE/final/verification.json"
  cp "$REPOLENS_TEST_SAVED/manifest.json" "$LOG_BASE/final/manifest.json"
  printf 'injected transient verifier inventory failure\n' >&2
  exit 42
fi
exec "$REPOLENS_TEST_REAL_FIND" "$@"
SH
chmod +x "$FIXTURE/bin/codex" "$FIXTURE/bin/find"
mkdir "$FIXTURE/saved"
printf '[{"finding_id":"saved","status":"WRONG","notes":"prior attempt"}]\n' > "$FIXTURE/saved/verification.json"
printf '[]\n' > "$FIXTURE/saved/manifest.json"
export REPOLENS_TEST_REPO="$REPO" REPOLENS_TEST_FAULT="$FIXTURE/fault"
export REPOLENS_TEST_REAL_FIND REPOLENS_TEST_SAVED="$FIXTURE/saved"
REPOLENS_TEST_REAL_FIND="$(type -P find)"
export REPOLENS_MOCK_AGENT_LOG="$FIXTURE/agent.log"
export REPOLENS_AGENT_TIMEOUT=10 REPOLENS_AGENT_KILL_GRACE=1
export PATH="$FIXTURE/bin:$PATH"
: > "$REPOLENS_TEST_FAULT"
rc=0
bash "$REPO/repolens.sh" --project "$FIXTURE/project" --agent codex --local \
  --mode bugreport --bug-report 'Check README.md:1' --focus injection \
  --rounds 2 --depth 1 --yes > "$FIXTURE/failed.log" 2>&1 || rc=$?
RUN_ID="$(sed -n 's/.*RepoLens run \([^ ]*\) starting.*/\1/p' "$FIXTURE/failed.log")"
[[ -n "$RUN_ID" && "$RUN_ID" != */* ]]
RUN_LOG_DIR="$REPO/logs/$RUN_ID"
PASS=0 FAIL=0
check() {
  local desc="$1"; shift
  if "$@"; then PASS=$((PASS + 1))
  else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$desc"; fi
}
count_role() { local n; n="$(grep -cx "$1" "$REPOLENS_MOCK_AGENT_LOG" || true)"; printf '%s' "${n:-0}"; }
check 'CLI inventory failure exits 1' test "$rc" -eq 1
check 'CLI terminal state is failed' test "$(jq -r .state "$RUN_LOG_DIR/status.json")" = failed
check 'CLI terminal status reports verifier preparation' test "$(jq -r .stopped_reason "$RUN_LOG_DIR/status.json")" = verifier-preparation-failed
check 'CLI summary reports verifier preparation' test "$(jq -r .stopped_reason "$RUN_LOG_DIR/summary.json")" = verifier-preparation-failed
check 'CLI retains saved verifier bytes' cmp -s "$FIXTURE/saved/verification.json" "$RUN_LOG_DIR/final/verification.json"
check 'CLI retains saved manifest bytes' cmp -s "$FIXTURE/saved/manifest.json" "$RUN_LOG_DIR/final/manifest.json"
check 'CLI admits no synthesis after inventory failure' test "$(count_role synthesizer)" -eq 0
lens_calls="$(count_role lens)"
meta_calls="$(count_role meta)"
check 'initial attempt completed lens work' test "$lens_calls" -gt 0
command rm "$REPOLENS_TEST_FAULT"
rc=0
bash "$REPO/repolens.sh" --project "$FIXTURE/project" --agent codex --local \
  --mode bugreport --focus injection --rounds 2 --depth 1 \
  --resume "$RUN_ID" --yes > "$FIXTURE/resume.log" 2>&1 || rc=$?
check 'resume succeeds once inventory is repaired' test "$rc" -eq 0
check 'resume does not repeat completed lenses' test "$(count_role lens)" -eq "$lens_calls"
check 'resume reuses successful round handoff' test "$(count_role meta)" -eq "$meta_calls"
check 'resume invokes verifier on the fresh inventory' test "$(count_role verifier)" -eq 1
check 'resume synthesizes once' test "$(count_role synthesizer)" -eq 1
check 'resume replaces stale verification' test "$(cat "$RUN_LOG_DIR/final/verification.json")" = '[]'
check 'resume clears preparation reason from status' test "$(jq -r '.stopped_reason // ""' "$RUN_LOG_DIR/status.json")" != verifier-preparation-failed
check 'resume clears preparation reason from summary' test "$(jq -r '.stopped_reason // ""' "$RUN_LOG_DIR/summary.json")" != verifier-preparation-failed
printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  tail -n 20 "$FIXTURE/failed.log" "$FIXTURE/resume.log"
fi
test "$FAIL" -eq 0
