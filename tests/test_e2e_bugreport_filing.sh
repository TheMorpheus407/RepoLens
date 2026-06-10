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

# Integration test for issue #204: bugreport multi-round synthesis must invoke
# dispatch_filing_batch in non-local mode and treat filing sentinels as terminal
# run state.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
TOTAL=0
RUN_LOG_DIR=""
RUN_LOG_DIRS=()
KEEP_ARTIFACTS=0

TMP_PARENT="$SCRIPT_DIR/logs/test-e2e-bugreport-filing"
mkdir -p "$TMP_PARENT"
TMPDIR="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"

cleanup() {
  if (( KEEP_ARTIFACTS == 0 )); then
    for run_log_dir in "${RUN_LOG_DIRS[@]:-}"; do
      [[ -n "$run_log_dir" ]] && rm -rf "$run_log_dir"
    done
    rm -rf "$TMPDIR"
    rmdir "$TMP_PARENT" 2>/dev/null || true
  else
    printf 'Preserved test artifacts: %s\n' "$TMPDIR"
    for run_log_dir in "${RUN_LOG_DIRS[@]:-}"; do
      [[ -n "$run_log_dir" ]] && printf 'Preserved RepoLens log dir: %s\n' "$run_log_dir"
    done
  fi
}
trap cleanup EXIT

pass_with() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

fail_with() {
  local desc="$1" detail="${2:-}"
  FAIL=$((FAIL + 1))
  KEEP_ARTIFACTS=1
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

assert_file_exists() {
  local desc="$1" file="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$file" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected file at $file"
  fi
}

assert_file_not_exists() {
  local desc="$1" file="$2"
  TOTAL=$((TOTAL + 1))
  if [[ ! -e "$file" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected no file at $file"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack_file="$3"
  TOTAL=$((TOTAL + 1))
  if grep -Fq "$needle" "$haystack_file" 2>/dev/null; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected $haystack_file to contain: $needle"
  fi
}

assert_jq() {
  local desc="$1" file="$2" filter="$3"
  TOTAL=$((TOTAL + 1))
  if jq -e "$filter" "$file" >/dev/null 2>&1; then
    pass_with "$desc"
  else
    fail_with "$desc" "jq assertion failed for $file: $filter"
  fi
}

run_bugreport_case() {
  local name="$1" filing_mode="${2:-url}"

  RUN_LOG_DIR=""
  run_output="$TMPDIR/repolens-${name}.txt"
  case "$filing_mode" in
    dedup)
      PATH="$FAKE_BIN:$PATH" \
        REPOLENS_AGENT_TIMEOUT=10 \
        REPOLENS_AGENT_KILL_GRACE=1 \
        REPOLENS_MOCK_AGENT_LOG="$MOCK_LOG" \
        REPOLENS_MOCK_FILING_DEDUP=1 \
        REPOLENS_FAKE_GH_LOG="$GH_LOG" \
        bash "$SCRIPT_DIR/repolens.sh" \
          --project "$PROJECT_DIR" \
          --agent codex \
          --mode bugreport \
          --bug-report "$BUG_FILE" \
          --focus injection \
          --rounds 3 \
          --depth 1 \
          --yes \
          >"$run_output" 2>&1
      ;;
    fail)
      PATH="$FAKE_BIN:$PATH" \
        REPOLENS_AGENT_TIMEOUT=10 \
        REPOLENS_AGENT_KILL_GRACE=1 \
        REPOLENS_MOCK_AGENT_LOG="$MOCK_LOG" \
        REPOLENS_MOCK_FILING_FAIL=1 \
        REPOLENS_FAKE_GH_LOG="$GH_LOG" \
        bash "$SCRIPT_DIR/repolens.sh" \
          --project "$PROJECT_DIR" \
          --agent codex \
          --mode bugreport \
          --bug-report "$BUG_FILE" \
          --focus injection \
          --rounds 3 \
          --depth 1 \
          --yes \
          >"$run_output" 2>&1
      ;;
    missing)
      PATH="$FAKE_BIN:$PATH" \
        REPOLENS_AGENT_TIMEOUT=10 \
        REPOLENS_AGENT_KILL_GRACE=1 \
        REPOLENS_MOCK_AGENT_LOG="$MOCK_LOG" \
        REPOLENS_MOCK_FILING_MISSING=1 \
        REPOLENS_FAKE_GH_LOG="$GH_LOG" \
        bash "$SCRIPT_DIR/repolens.sh" \
          --project "$PROJECT_DIR" \
          --agent codex \
          --mode bugreport \
          --bug-report "$BUG_FILE" \
          --focus injection \
          --rounds 3 \
          --depth 1 \
          --yes \
          >"$run_output" 2>&1
      ;;
    prompt-path)
      PATH="$FAKE_BIN:$PATH" \
        REPOLENS_AGENT_TIMEOUT=10 \
        REPOLENS_AGENT_KILL_GRACE=1 \
        REPOLENS_MOCK_AGENT_LOG="$MOCK_LOG" \
        REPOLENS_MOCK_IGNORE_LOG_BASE=1 \
        REPOLENS_FAKE_GH_LOG="$GH_LOG" \
        bash "$SCRIPT_DIR/repolens.sh" \
          --project "$PROJECT_DIR" \
          --agent codex \
          --mode bugreport \
          --bug-report "$BUG_FILE" \
          --focus injection \
          --rounds 3 \
          --depth 1 \
          --yes \
          >"$run_output" 2>&1
      ;;
    *)
      PATH="$FAKE_BIN:$PATH" \
        REPOLENS_AGENT_TIMEOUT=10 \
        REPOLENS_AGENT_KILL_GRACE=1 \
        REPOLENS_MOCK_AGENT_LOG="$MOCK_LOG" \
        REPOLENS_FAKE_GH_LOG="$GH_LOG" \
        bash "$SCRIPT_DIR/repolens.sh" \
          --project "$PROJECT_DIR" \
          --agent codex \
          --mode bugreport \
          --bug-report "$BUG_FILE" \
          --focus injection \
          --rounds 3 \
          --depth 1 \
          --yes \
          >"$run_output" 2>&1
      ;;
  esac
  run_rc=$?

  RUN_ID="$(sed -n 's/.*RepoLens run \([^ ]*\) complete.*/\1/p' "$run_output" | tail -1)"
  if [[ -n "$RUN_ID" ]]; then
    RUN_LOG_DIR="$SCRIPT_DIR/logs/$RUN_ID"
    RUN_LOG_DIRS+=("$RUN_LOG_DIR")
  fi
}

finish() {
  echo ""
  echo "Results: $PASS/$TOTAL passed, $FAIL failed"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

echo "=== bugreport synthesized filing integration (issue #204) ==="

PROJECT_DIR="$TMPDIR/project"
FAKE_BIN="$TMPDIR/bin"
MOCK_LOG="$TMPDIR/mock-agent.log"
GH_LOG="$TMPDIR/gh.log"
BUG_FILE="$TMPDIR/bug-report.md"
mkdir -p "$PROJECT_DIR" "$FAKE_BIN"
export REPOLENS_MOCK_WRITE_FINDINGS_WITHOUT_LOCAL=1
git -C "$PROJECT_DIR" init -q
git -C "$PROJECT_DIR" remote add origin https://github.com/example/repo.git
printf '# RepoLens issue 204 fixture\n' > "$PROJECT_DIR/README.md"
git -C "$PROJECT_DIR" add README.md
git -C "$PROJECT_DIR" -c user.name='RepoLens Test' -c user.email='repolens@example.invalid' commit -q -m 'fixture'
printf 'The bugreport path produced findings but did not file synthesized issues.\n' > "$BUG_FILE"

cat > "$FAKE_BIN/codex" <<EOF
#!/usr/bin/env bash
exec "$SCRIPT_DIR/tests/mock-agent.sh" "\$@"
EOF
cat > "$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${REPOLENS_FAKE_GH_LOG:-/dev/null}"
case "$1 $2" in
  "auth status") exit 0 ;;
  "label list") printf '[]\n'; exit 0 ;;
  "label create") exit 0 ;;
  "issue list") printf '[]\n'; exit 0 ;;
  "issue create") printf 'https://github.com/example/repo/issues/2040\n'; exit 0 ;;
esac
exit 0
EOF
chmod +x "$FAKE_BIN/codex" "$FAKE_BIN/gh" "$SCRIPT_DIR/tests/mock-agent.sh"

run_bugreport_case "url" "url"
assert_eq "bugreport multi-round run exits successfully" "0" "$run_rc"
assert_eq "run id is discoverable from output" "set" "$([[ -n "$RUN_ID" ]] && printf 'set' || printf 'missing')"

if [[ -z "$RUN_ID" || ! -d "$RUN_LOG_DIR" ]]; then
  fail_with "run log directory exists" "Could not resolve run log from $run_output"
  finish
fi

manifest="$RUN_LOG_DIR/final/manifest.json"
assert_file_exists "final manifest.json exists" "$manifest"
assert_jq "manifest has synthesized finding" "$manifest" 'type == "array" and length >= 1'
assert_file_exists "filing marker url exists" "$RUN_LOG_DIR/final/filed/mock-round-handoff.url"
assert_contains "filing marker contains issue URL" "https://example.invalid/issues/mock-round-handoff" "$RUN_LOG_DIR/final/filed/mock-round-handoff.url"
assert_eq "mock agent handled one filing prompt" "1" "$(grep -c '^filing$' "$MOCK_LOG" 2>/dev/null || printf '0')"
assert_contains "orchestrator logged filing completion" "Filing: batch complete" "$run_output"
assert_contains "fake gh auth was checked" "auth status" "$GH_LOG"

run_bugreport_case "prompt-filed-dir" "prompt-path"
assert_eq "prompt-provided filed dir exits successfully" "0" "$run_rc"
assert_eq "prompt-provided filed dir run id is discoverable" "set" "$([[ -n "$RUN_ID" ]] && printf 'set' || printf 'missing')"
if [[ -n "$RUN_ID" && -d "$RUN_LOG_DIR" ]]; then
  assert_file_exists "prompt-provided filed dir marker exists in RepoLens log" "$RUN_LOG_DIR/final/filed/mock-round-handoff.url"
  assert_file_not_exists "prompt-provided filed dir does not write under audited project cwd" "$PROJECT_DIR/logs/$RUN_ID/final/filed/mock-round-handoff.url"
fi

run_bugreport_case "dedup" "dedup"
assert_eq "dedup .failed sentinel exits successfully" "0" "$run_rc"
assert_eq "dedup run id is discoverable" "set" "$([[ -n "$RUN_ID" ]] && printf 'set' || printf 'missing')"
if [[ -n "$RUN_ID" && -d "$RUN_LOG_DIR" ]]; then
  assert_file_exists "dedup marker failed exists" "$RUN_LOG_DIR/final/filed/mock-round-handoff.failed"
  assert_contains "dedup marker records dedup hit" "DEDUP_HIT: #204" "$RUN_LOG_DIR/final/filed/mock-round-handoff.failed"
  assert_contains "dedup run logs filing completion" "Filing: batch complete" "$run_output"
  assert_jq "dedup status remains successful without filing stop reason" "$RUN_LOG_DIR/status.json" \
    'has("stopped_reason") and .state != "failed" and .stopped_reason == null'
fi

run_bugreport_case "verification-failed" "fail"
assert_eq "verification .failed sentinel exits non-zero" "1" "$run_rc"
assert_eq "verification failure run id is discoverable" "set" "$([[ -n "$RUN_ID" ]] && printf 'set' || printf 'missing')"
if [[ -n "$RUN_ID" && -d "$RUN_LOG_DIR" ]]; then
  assert_file_exists "verification failure marker exists" "$RUN_LOG_DIR/final/filed/mock-round-handoff.failed"
  assert_contains "verification marker records failure" "VERIFICATION_FAILED: mock filing failure" "$RUN_LOG_DIR/final/filed/mock-round-handoff.failed"
  assert_contains "verification failure logs incomplete batch" "Filing: incomplete batch (failed=1, dedup=0, missing=0)" "$run_output"
  assert_file_exists "verification failure status exists" "$RUN_LOG_DIR/status.json"
  assert_jq "verification failure status records filing failure" "$RUN_LOG_DIR/status.json" \
    '.state == "failed" and .stopped_reason == "filing-failed"'
fi

run_bugreport_case "missing" "missing"
assert_eq "missing filing sentinel exits non-zero" "1" "$run_rc"
assert_eq "missing sentinel run id is discoverable" "set" "$([[ -n "$RUN_ID" ]] && printf 'set' || printf 'missing')"
if [[ -n "$RUN_ID" && -d "$RUN_LOG_DIR" ]]; then
  assert_contains "missing sentinel logs incomplete batch" "Filing: incomplete batch (failed=0, dedup=0, missing=1)" "$run_output"
  assert_file_exists "missing sentinel status exists" "$RUN_LOG_DIR/status.json"
  assert_jq "missing sentinel status records filing failure" "$RUN_LOG_DIR/status.json" \
    '.state == "failed" and .stopped_reason == "filing-failed"'
fi

finish
