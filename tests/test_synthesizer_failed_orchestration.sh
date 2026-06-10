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

# Integration coverage for issue #279: a real multi-round bugreport run that
# reaches the post-round synthesizer must finish as failed with a
# synthesizer-failed stop reason when synthesis cannot produce a JSON manifest,
# while preserving the phase-specific reason for synthesizer rate limits.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
TOTAL=0
KEEP_ARTIFACTS=0
RUN_LOG_DIR=""
RUN_LOG_DIRS=()

TMP_PARENT="$SCRIPT_DIR/logs/test-synthesizer-failed-orchestration"
mkdir -p "$TMP_PARENT"
TMPDIR="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"

cleanup() {
  if (( KEEP_ARTIFACTS == 0 )); then
    if (( ${#RUN_LOG_DIRS[@]} > 0 )); then
      rm -rf "${RUN_LOG_DIRS[@]}"
    fi
    rm -rf "$TMPDIR"
    rmdir "$TMP_PARENT" 2>/dev/null || true
  else
    printf 'Preserved test artifacts: %s\n' "$TMPDIR"
    if (( ${#RUN_LOG_DIRS[@]} > 0 )); then
      printf 'Preserved RepoLens log dirs:\n'
      printf '  %s\n' "${RUN_LOG_DIRS[@]}"
    fi
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

assert_file_absent() {
  local desc="$1" file="$2"
  TOTAL=$((TOTAL + 1))
  if [[ ! -e "$file" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Did not expect path at $file"
  fi
}

assert_contains_file() {
  local desc="$1" needle="$2" file="$3"
  TOTAL=$((TOTAL + 1))
  if grep -Fq "$needle" "$file" 2>/dev/null; then
    pass_with "$desc"
  else
    fail_with "$desc" "Missing '$needle' in $file"
  fi
}

assert_jq_eq() {
  local desc="$1" file="$2" filter="$3" expected="$4" actual
  TOTAL=$((TOTAL + 1))
  actual="$(jq -r "$filter" "$file" 2>/dev/null || printf '__jq_error__')"
  if [[ "$expected" == "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected: $expected | Actual: $actual | Filter: $filter"
  fi
}

count_role() {
  local role="$1" file="$2" count
  count="$(grep -cx "$role" "$file" 2>/dev/null || true)"
  printf '%s\n' "${count:-0}"
}

finish() {
  echo ""
  echo "Results: $PASS/$TOTAL passed, $FAIL failed"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

parse_run_id() {
  local output_file="$1"
  sed -n 's/.*RepoLens run \([^ ]*\) starting.*/\1/p' "$output_file" | head -1
}

echo "=== synthesizer-failed orchestration (issue #279) ==="

PROJECT_DIR="$TMPDIR/project"
FAKE_BIN="$TMPDIR/bin"
MOCK_LOG="$TMPDIR/mock-agent.log"
BUG_FILE="$TMPDIR/bug-report.md"
mkdir -p "$PROJECT_DIR" "$FAKE_BIN"

git -C "$PROJECT_DIR" init -q
printf '# RepoLens issue 279 fixture\n' > "$PROJECT_DIR/README.md"
git -C "$PROJECT_DIR" add README.md
git -C "$PROJECT_DIR" -c user.name='RepoLens Test' -c user.email='repolens@example.invalid' commit -q -m 'fixture'

cat > "$BUG_FILE" <<'EOF'
The README example has an injection-shaped failure at README.md:1 that should
be investigated across multiple rounds before synthesis.
EOF

cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

prompt="${!#}"
if [[ "$prompt" == *"RepoLens Synthesizer"* ]]; then
  if [[ -n "${REPOLENS_MOCK_AGENT_LOG:-}" ]]; then
    printf 'synthesizer\n' >> "$REPOLENS_MOCK_AGENT_LOG"
  fi
  if [[ "${REPOLENS_MOCK_SYNTHESIZER_MODE:-no-json}" == "rate-limit" ]]; then
    printf "ERROR: You've hit your usage limit. Try again at May 14th, 2026 11:00 PM.\n"
    exit 42
  fi
  printf 'The synthesizer could not produce a JSON array for this run.\n'
  printf 'DONE\n'
  exit 0
fi

exec bash "$REPOLENS_TEST_SCRIPT_DIR/tests/mock-agent.sh" "$@"
EOF
chmod +x "$FAKE_BIN/codex"

run_output="$TMPDIR/repolens-output.txt"
PATH="$FAKE_BIN:$PATH" \
  REPOLENS_AGENT_TIMEOUT=10 \
  REPOLENS_AGENT_KILL_GRACE=1 \
  REPOLENS_MOCK_AGENT_LOG="$MOCK_LOG" \
  REPOLENS_TEST_SCRIPT_DIR="$SCRIPT_DIR" \
  bash "$SCRIPT_DIR/repolens.sh" \
    --project "$PROJECT_DIR" \
    --agent codex \
    --local \
    --mode bugreport \
    --bug-report "$BUG_FILE" \
    --focus injection \
    --rounds 2 \
    --depth 1 \
    --yes \
    >"$run_output" 2>&1
run_rc=$?

assert_eq "synthesizer failure exits with documented generic failure code" "1" "$run_rc"

RUN_ID="$(parse_run_id "$run_output")"
assert_eq "run id is discoverable from output" "set" "$([[ -n "$RUN_ID" ]] && printf 'set' || printf 'missing')"
if [[ -n "$RUN_ID" ]]; then
  RUN_LOG_DIR="$SCRIPT_DIR/logs/$RUN_ID"
  RUN_LOG_DIRS+=("$RUN_LOG_DIR")
fi

if [[ -z "$RUN_ID" || ! -d "$RUN_LOG_DIR" ]]; then
  fail_with "run log directory exists" "Could not resolve run log from $run_output"
  finish
fi

SUMMARY_FILE="$RUN_LOG_DIR/summary.json"
STATUS_FILE="$RUN_LOG_DIR/status.json"
SYNTH_OUTPUT="$RUN_LOG_DIR/final/synthesizer-output.txt"
MANIFEST_FILE="$RUN_LOG_DIR/final/manifest.json"

assert_file_exists "summary.json exists" "$SUMMARY_FILE"
assert_file_exists "status.json exists" "$STATUS_FILE"
assert_file_exists "synthesizer transcript exists" "$SYNTH_OUTPUT"
assert_file_absent "failed synthesizer does not promote manifest.json" "$MANIFEST_FILE"

assert_jq_eq "terminal status state is failed" "$STATUS_FILE" '.state // empty' "failed"
assert_jq_eq "terminal status reason is synthesizer-failed" "$STATUS_FILE" '.stopped_reason' "synthesizer-failed"
assert_jq_eq "summary reason is synthesizer-failed" "$SUMMARY_FILE" '.stopped_reason' "synthesizer-failed"

assert_eq "mock agent handled one triage prompt" "1" "$(count_role "triage" "$MOCK_LOG")"
assert_eq "mock agent handled two lens prompts" "2" "$(count_role "lens" "$MOCK_LOG")"
assert_eq "mock agent handled one meta prompt" "1" "$(count_role "meta" "$MOCK_LOG")"
assert_eq "mock agent handled one verifier prompt" "1" "$(count_role "verifier" "$MOCK_LOG")"
assert_eq "fake wrapper handled one synthesizer prompt" "1" "$(count_role "synthesizer" "$MOCK_LOG")"
assert_eq "local run does not invoke filing agent" "0" "$(count_role "filing" "$MOCK_LOG")"

assert_contains_file "orchestrator logs no-json synthesizer warning" "Synthesizer: agent output did not contain a JSON array; see final/synthesizer-output.txt" "$run_output"
assert_contains_file "synthesizer transcript preserves raw agent output" "could not produce a JSON array" "$SYNTH_OUTPUT"

echo ""
echo "=== synthesizer rate-limit orchestration exception ==="

MOCK_LOG="$TMPDIR/rate-limit-agent.log"
run_output="$TMPDIR/repolens-rate-limit-output.txt"
PATH="$FAKE_BIN:$PATH" \
  REPOLENS_AGENT_TIMEOUT=10 \
  REPOLENS_AGENT_KILL_GRACE=1 \
  REPOLENS_MOCK_AGENT_LOG="$MOCK_LOG" \
  REPOLENS_MOCK_SYNTHESIZER_MODE=rate-limit \
  REPOLENS_TEST_SCRIPT_DIR="$SCRIPT_DIR" \
  bash "$SCRIPT_DIR/repolens.sh" \
    --project "$PROJECT_DIR" \
    --agent codex \
    --local \
    --mode bugreport \
    --bug-report "$BUG_FILE" \
    --focus injection \
    --rounds 2 \
    --depth 1 \
    --yes \
    >"$run_output" 2>&1
run_rc=$?

assert_eq "rate-limited synthesizer exits with generic failure code" "1" "$run_rc"

RUN_ID="$(parse_run_id "$run_output")"
assert_eq "rate-limited run id is discoverable from output" "set" "$([[ -n "$RUN_ID" ]] && printf 'set' || printf 'missing')"
if [[ -n "$RUN_ID" ]]; then
  RUN_LOG_DIR="$SCRIPT_DIR/logs/$RUN_ID"
  RUN_LOG_DIRS+=("$RUN_LOG_DIR")
fi

if [[ -z "$RUN_ID" || ! -d "$RUN_LOG_DIR" ]]; then
  fail_with "rate-limited run log directory exists" "Could not resolve run log from $run_output"
  finish
fi

SUMMARY_FILE="$RUN_LOG_DIR/summary.json"
STATUS_FILE="$RUN_LOG_DIR/status.json"
SYNTH_OUTPUT="$RUN_LOG_DIR/final/synthesizer-output.txt"
MANIFEST_FILE="$RUN_LOG_DIR/final/manifest.json"

assert_file_exists "rate-limited summary.json exists" "$SUMMARY_FILE"
assert_file_exists "rate-limited status.json exists" "$STATUS_FILE"
assert_file_exists "rate-limited synthesizer transcript exists" "$SYNTH_OUTPUT"
assert_file_exists "rate-limited abort sentinel exists" "$RUN_LOG_DIR/.rate-limit-abort"
assert_file_absent "rate-limited synthesizer does not promote manifest.json" "$MANIFEST_FILE"

assert_jq_eq "rate-limited terminal status state is failed" "$STATUS_FILE" '.state // empty' "failed"
assert_jq_eq "rate-limited terminal status reason is phase-specific" "$STATUS_FILE" '.stopped_reason' "rate-limited-synthesizer"
assert_jq_eq "rate-limited summary reason is phase-specific" "$SUMMARY_FILE" '.stopped_reason' "rate-limited-synthesizer"

assert_eq "rate-limited run reaches one synthesizer prompt" "1" "$(count_role "synthesizer" "$MOCK_LOG")"
assert_eq "rate-limited local run does not invoke filing agent" "0" "$(count_role "filing" "$MOCK_LOG")"
assert_contains_file "orchestrator logs synthesizer rate-limit warning" "Synthesizer: stopped due to rate limit" "$run_output"
assert_contains_file "rate-limited transcript preserves raw agent output" "usage limit" "$SYNTH_OUTPUT"

finish
