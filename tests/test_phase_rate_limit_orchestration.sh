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

# Integration coverage for issue #211: non-lens phase rate limits must
# short-circuit the top-level orchestrator instead of continuing into later
# agent phases.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
TOTAL=0
TMP_PARENT="$SCRIPT_DIR/logs/test-phase-rate-limit-orchestration"
mkdir -p "$TMP_PARENT"
TMPDIR="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"
RUN_LOG_DIRS=()

cleanup() {
  rm -rf "$TMPDIR" "${RUN_LOG_DIRS[@]}"
  rmdir "$TMP_PARENT" 2>/dev/null || true
}
trap cleanup EXIT

pass_with() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

fail_with() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1 ($2)"
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "expected='$expected' actual='$actual'"
  fi
}

assert_file_exists() {
  local desc="$1" file="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$file" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "missing $file"
  fi
}

assert_file_absent() {
  local desc="$1" file="$2"
  TOTAL=$((TOTAL + 1))
  if [[ ! -e "$file" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "unexpected $file"
  fi
}

assert_not_contains_file() {
  local desc="$1" needle="$2" file="$3"
  TOTAL=$((TOTAL + 1))
  if ! grep -Fq "$needle" "$file" 2>/dev/null; then
    pass_with "$desc"
  else
    fail_with "$desc" "unexpected '$needle' in $file"
  fi
}

assert_contains_file() {
  local desc="$1" needle="$2" file="$3"
  TOTAL=$((TOTAL + 1))
  if grep -Fq "$needle" "$file" 2>/dev/null; then
    pass_with "$desc"
  else
    fail_with "$desc" "missing '$needle' in $file"
  fi
}

assert_find_count() {
  local desc="$1" expected="$2" dir="$3"
  local actual
  TOTAL=$((TOTAL + 1))
  actual="$(find "$dir" -type f 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$expected" == "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "expected='$expected' actual='$actual'"
  fi
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

setup_project() {
  PROJECT_DIR="$TMPDIR/project"
  mkdir -p "$PROJECT_DIR"
  git -C "$PROJECT_DIR" init -q
  printf '# RepoLens issue 211 fixture\n' > "$PROJECT_DIR/README.md"
  git -C "$PROJECT_DIR" add README.md
  git -C "$PROJECT_DIR" -c user.name='RepoLens Test' -c user.email='repolens@example.invalid' commit -q -m 'fixture'
}

setup_fake_agent() {
  FAKE_BIN="$TMPDIR/bin"
  mkdir -p "$FAKE_BIN"
  cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
prompt="${!#}"
if [[ "${REPOLENS_FORCE_TRIAGE_RATE_LIMIT:-0}" == "1" && "$prompt" == *"RepoLens Triage Agent"* ]]; then
  [[ -n "${REPOLENS_MOCK_AGENT_LOG:-}" ]] && printf 'triage\n' >> "$REPOLENS_MOCK_AGENT_LOG"
  printf "ERROR: You've hit your usage limit. Try again at May 14th, 2026 11:00 PM.\n"
  exit 42
fi
if [[ "${REPOLENS_FORCE_VERIFIER_RATE_LIMIT:-0}" == "1" && "$prompt" == *"RepoLens Verifier"* ]]; then
  [[ -n "${REPOLENS_MOCK_AGENT_LOG:-}" ]] && printf 'verifier\n' >> "$REPOLENS_MOCK_AGENT_LOG"
  printf 'HTTP 429: Retry-After: 90 seconds\n'
  exit 42
fi
"$REPOLENS_TEST_SCRIPT_DIR/tests/mock-agent.sh" "$@"
agent_rc=$?
if [[ "$agent_rc" -eq 0 && "$prompt" == *"Write all findings to:"* ]]; then
  output_dir="$(printf '%s\n' "$prompt" | sed -n 's/^Write all findings to: `\(.*\)`$/\1/p' | sed -n '1p')"
  if [[ -n "$output_dir" ]]; then
    round_dir="${output_dir%/lens-outputs/*}"
    root_outputs="$round_dir/lens-outputs"
    first_finding="$(find "$output_dir" -name '*.md' -type f 2>/dev/null | sed -n '1p')"
    if [[ -n "$first_finding" ]]; then
      cp "$first_finding" "$root_outputs/issue-211-verifier-fixture.md"
    fi
  fi
fi
if [[ "$agent_rc" -eq 0 && "$prompt" == *"Write your findings to a single Markdown file at:"* && -n "${LOG_BASE:-}" ]]; then
  round="$(printf '%s\n' "$prompt" | sed -n 's/.*round \*\*\([0-9][0-9]*\) of [0-9][0-9]*\*\*.*/\1/p' | sed -n '1p')"
  [[ -n "$round" ]] || round=1
  root_outputs="$LOG_BASE/rounds/round-$round/lens-outputs"
  mkdir -p "$root_outputs"
  cat > "$root_outputs/issue-211-verifier-fixture.md" <<'MD'
---
lens_id: injection
domain: security
round: 1
severity: low
confidence: medium
root_cause_category: test-fixture
suspect_files:
  - README.md:1
---
## suspect_files
- README.md:1
## hypothesis
Verifier should inspect this deterministic finding.
## evidence
- README.md:1 exists in the fixture repository.
## next_steps_for_synthesizer
Keep this finding for orchestration coverage.
MD
fi
exit "$agent_rc"
EOF
  chmod +x "$FAKE_BIN/codex" "$SCRIPT_DIR/tests/mock-agent.sh"
}

run_bugreport_case() {
  local name="$1" force_triage="$2" force_verifier="$3"
  local output_file="$TMPDIR/$name.out" mock_log="$TMPDIR/$name-agent.log" run_rc run_id

  : > "$mock_log"
  PATH="$FAKE_BIN:$PATH" \
    REPOLENS_AGENT_TIMEOUT=10 \
    REPOLENS_AGENT_KILL_GRACE=1 \
    REPOLENS_MOCK_AGENT_LOG="$mock_log" \
    REPOLENS_TEST_SCRIPT_DIR="$SCRIPT_DIR" \
    REPOLENS_FORCE_TRIAGE_RATE_LIMIT="$force_triage" \
    REPOLENS_FORCE_VERIFIER_RATE_LIMIT="$force_verifier" \
    bash "$SCRIPT_DIR/repolens.sh" \
      --project "$PROJECT_DIR" \
      --agent codex \
      --local \
      --mode bugreport \
      --bug-report "README.md fails when issue #211 reproduces" \
      --focus injection \
      --rounds 2 \
      --depth 1 \
      --yes \
      >"$output_file" 2>&1
  run_rc=$?

  run_id="$(parse_run_id "$output_file")"
  if [[ -n "$run_id" ]]; then
    RUN_LOG_DIRS+=("$SCRIPT_DIR/logs/$run_id")
  fi

  CASE_RC="$run_rc"
  CASE_RUN_ID="$run_id"
  CASE_OUTPUT="$output_file"
  CASE_MOCK_LOG="$mock_log"
}

echo "=== Phase rate-limit orchestration (issue #211) ==="

setup_project
setup_fake_agent

run_bugreport_case "triage-rate-limit" 1 0
assert_eq "triage rate-limit exits non-zero" "1" "$CASE_RC"
assert_eq "triage rate-limit exposes a run id" "set" "$([[ -n "$CASE_RUN_ID" ]] && printf 'set' || printf 'missing')"
TRIAGE_LOG_DIR="$SCRIPT_DIR/logs/$CASE_RUN_ID"
TRIAGE_SUMMARY="$TRIAGE_LOG_DIR/summary.json"
TRIAGE_STATUS="$TRIAGE_LOG_DIR/status.json"
assert_file_exists "triage rate-limit summary exists" "$TRIAGE_SUMMARY"
assert_file_exists "triage rate-limit status exists" "$TRIAGE_STATUS"
assert_file_exists "triage rate-limit sentinel exists" "$TRIAGE_LOG_DIR/.rate-limit-abort"
assert_eq "triage rate-limit final status is failed" "failed" "$(jq -r '.state // empty' "$TRIAGE_STATUS")"
assert_eq "triage rate-limit records phase stop reason" "rate-limited-triage" "$(jq -r '.stopped_reason' "$TRIAGE_SUMMARY")"
assert_eq "triage rate-limit only invokes triage agent" "triage" "$(tr '\n' ' ' < "$CASE_MOCK_LOG" | sed -E 's/[[:space:]]+$//')"
assert_find_count "triage rate-limit leaves round-1 lens output empty" "0" "$TRIAGE_LOG_DIR/rounds/round-1/lens-outputs"
assert_contains_file "triage rate-limit log explains short-circuit" "Triage: rate-limited" "$CASE_OUTPUT"

run_bugreport_case "verifier-rate-limit" 0 1
assert_eq "verifier rate-limit exits non-zero" "1" "$CASE_RC"
assert_eq "verifier rate-limit exposes a run id" "set" "$([[ -n "$CASE_RUN_ID" ]] && printf 'set' || printf 'missing')"
VERIFIER_LOG_DIR="$SCRIPT_DIR/logs/$CASE_RUN_ID"
VERIFIER_SUMMARY="$VERIFIER_LOG_DIR/summary.json"
VERIFIER_STATUS="$VERIFIER_LOG_DIR/status.json"
assert_file_exists "verifier rate-limit summary exists" "$VERIFIER_SUMMARY"
assert_file_exists "verifier rate-limit status exists" "$VERIFIER_STATUS"
assert_file_exists "verifier rate-limit sentinel exists" "$VERIFIER_LOG_DIR/.rate-limit-abort"
assert_eq "verifier rate-limit final status is failed" "failed" "$(jq -r '.state // empty' "$VERIFIER_STATUS")"
assert_eq "verifier rate-limit records phase stop reason" "rate-limited-verifier" "$(jq -r '.stopped_reason' "$VERIFIER_SUMMARY")"
assert_contains_file "verifier rate-limit runs verifier" "verifier" "$CASE_MOCK_LOG"
assert_contains_file "verifier rate-limit reached lens rounds before abort" "lens" "$CASE_MOCK_LOG"
assert_not_contains_file "verifier rate-limit does not run synthesizer" "synthesizer" "$CASE_MOCK_LOG"
assert_file_absent "verifier rate-limit does not promote manifest" "$VERIFIER_LOG_DIR/final/manifest.json"
assert_contains_file "verifier rate-limit log explains short-circuit" "Verifier: rate-limited" "$CASE_OUTPUT"

finish
