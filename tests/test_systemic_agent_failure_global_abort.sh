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

# Integration test for issue #212's systemic escalation path. A parallel run
# with five concurrently failing lenses should keep per-lens status as
# agent-no-progress, but escalate the run-level stopped_reason to
# agent-degraded instead of reporting only an ordinary per-lens abort.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
TOTAL=0
TMPDIR="$(mktemp -d)"
CREATED_RUNS=()
trap 'rm -rf "$TMPDIR"; for run_id in "${CREATED_RUNS[@]:-}"; do rm -rf "$SCRIPT_DIR/logs/$run_id"; done' EXIT

pass_with() {
  local desc="$1"
  PASS=$((PASS + 1))
  echo "  PASS: $desc"
}

fail_with() {
  local desc="$1" detail="${2:-}"
  FAIL=$((FAIL + 1))
  echo "  FAIL: $desc"
  if [[ -n "$detail" ]]; then
    printf '    %s\n' "$detail"
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected: $expected | Actual: $actual"
  fi
}

assert_ge() {
  local desc="$1" floor="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" =~ ^[0-9]+$ && "$actual" -ge "$floor" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected >= $floor | Actual: $actual"
  fi
}

assert_nonzero() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -ne 0 ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected non-zero exit status"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" file="$3"
  TOTAL=$((TOTAL + 1))
  if grep -qF "$needle" "$file"; then
    fail_with "$desc" "Unexpected: $needle"
  else
    pass_with "$desc"
  fi
}

assert_file_exists() {
  local desc="$1" file="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$file" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Missing file: $file"
  fi
}

create_project() {
  local project="$1"
  mkdir -p "$project"
  (
    cd "$project" || exit 1
    git init -q 2>/dev/null
    git config user.email test@example.com
    git config user.name Test
    printf '# fixture\n' > README.md
    git add README.md
    git commit -q -m init 2>/dev/null
  ) || true
}

install_failing_codex() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/codex" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
state_dir="${FAKE_AGENT_STATE_DIR:?}"
mkdir -p "$state_dir"
counter_file="$state_dir/calls"
count=0
if [[ -f "$counter_file" ]]; then
  count="$(cat "$counter_file")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$counter_file"
printf 'provider unavailable\n'
exit 1
SH
  chmod +x "$bin_dir/codex"
}

extract_run_id() {
  local output_file="$1"
  grep -oE 'RepoLens run [^ ]+ starting' "$output_file" | head -1 | awk '{print $3}'
}

echo "=== Systemic no-progress escalation (issue #212) ==="

PROJECT="$TMPDIR/project"
BIN_DIR="$TMPDIR/bin"
OUT_FILE="$TMPDIR/run.log"
create_project "$PROJECT"
install_failing_codex "$BIN_DIR"

FAKE_AGENT_STATE_DIR="$TMPDIR/state" \
PATH="$BIN_DIR:$PATH" \
REPOLENS_NO_PROGRESS_LIMIT=3 \
bash "$SCRIPT_DIR/repolens.sh" \
  --project "$PROJECT" \
  --agent codex \
  --domain security \
  --mode audit \
  --depth 1 \
  --parallel \
  --max-parallel 5 \
  --local \
  --yes \
  >"$OUT_FILE" 2>&1
exit_code=$?

run_id="$(extract_run_id "$OUT_FILE")"
if [[ -n "$run_id" ]]; then
  CREATED_RUNS+=("$run_id")
fi
summary_file="$SCRIPT_DIR/logs/$run_id/summary.json"

assert_nonzero "systemic no-progress run exits non-zero" "$exit_code"
assert_not_contains "systemic run avoids per-lens safety cap" "Hit safety cap" "$OUT_FILE"
assert_not_contains "systemic run avoids iteration 20 burn" "Iteration 20" "$OUT_FILE"
assert_file_exists "systemic run writes no-progress sentinel" "$SCRIPT_DIR/logs/$run_id/.agent-no-progress-abort"
assert_eq "systemic run stopped_reason escalates" "agent-degraded" "$(jq -r '.stopped_reason' "$summary_file" 2>/dev/null || printf missing)"
no_progress_count="$(jq '[.lenses[] | select(.status == "agent-no-progress")] | length' "$summary_file" 2>/dev/null || printf 0)"
assert_eq "five lenses record per-lens no-progress status" "5" "$no_progress_count"
bad_iteration_count="$(jq '[.lenses[] | select(.status == "agent-no-progress" and .iterations != 3)] | length' "$summary_file" 2>/dev/null || printf 999)"
assert_eq "each no-progress lens aborts at configured limit" "0" "$bad_iteration_count"
skipped_count="$(jq '[.lenses[] | select(.status == "skipped")] | length' "$summary_file" 2>/dev/null || printf 0)"
assert_ge "unstarted sibling lenses are recorded as skipped" "1" "$skipped_count"
completed_no_progress_count=0
if [[ -f "$SCRIPT_DIR/logs/$run_id/.completed" && -f "$summary_file" ]]; then
  while IFS= read -r lens_entry; do
    if grep -qxF "$lens_entry" "$SCRIPT_DIR/logs/$run_id/.completed" 2>/dev/null; then
      completed_no_progress_count=$((completed_no_progress_count + 1))
    fi
  done < <(jq -r '.lenses[] | select(.status == "agent-no-progress") | "\(.domain)/\(.lens)"' "$summary_file" 2>/dev/null)
fi
assert_eq "no-progress lenses are not marked completed" "0" "$completed_no_progress_count"

echo ""
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
