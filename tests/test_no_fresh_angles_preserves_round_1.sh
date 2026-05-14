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

# Regression for issue #217: a multi-round run that saturates after round 1 via
# NO_FRESH_ANGLES must still run verifier + synthesizer, exit 0, and preserve
# round-1 findings in final/manifest.json.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
TOTAL=0
RUN_LOG_DIR=""
KEEP_ARTIFACTS=0

TMP_PARENT="$SCRIPT_DIR/logs/test-no-fresh-angles-preserves-round-1"
mkdir -p "$TMP_PARENT"
TMPDIR="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"

cleanup() {
  if (( KEEP_ARTIFACTS == 0 )); then
    [[ -n "$RUN_LOG_DIR" ]] && rm -rf "$RUN_LOG_DIR"
    rm -rf "$TMPDIR"
    rmdir "$TMP_PARENT" 2>/dev/null || true
  else
    printf 'Preserved test artifacts: %s\n' "$TMPDIR"
    [[ -n "$RUN_LOG_DIR" ]] && printf 'Preserved RepoLens log dir: %s\n' "$RUN_LOG_DIR"
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
  [[ -n "$detail" ]] && printf '    %s\n' "$detail"
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

assert_path_absent() {
  local desc="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [[ ! -e "$path" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Did not expect path at $path"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" file="$3"
  TOTAL=$((TOTAL + 1))
  if grep -Fq "$needle" "$file" 2>/dev/null; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected $file to contain: $needle"
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

finish() {
  echo ""
  echo "Results: $PASS/$TOTAL passed, $FAIL failed"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

echo "=== NO_FRESH_ANGLES preserves round-1 findings integration (issue #217) ==="

PROJECT_DIR="$TMPDIR/project"
FAKE_BIN="$TMPDIR/bin"
MOCK_LOG="$TMPDIR/mock-agent.log"
mkdir -p "$PROJECT_DIR" "$FAKE_BIN"
git -C "$PROJECT_DIR" init -q
printf '# RepoLens issue 217 fixture\n' > "$PROJECT_DIR/README.md"
git -C "$PROJECT_DIR" add README.md
git -C "$PROJECT_DIR" -c user.name='RepoLens Test' -c user.email='repolens@example.invalid' commit -q -m 'fixture'

cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

prompt="${!#}"

log_role() {
  if [[ -n "${REPOLENS_MOCK_AGENT_LOG:-}" ]]; then
    printf '%s\n' "$1" >> "$REPOLENS_MOCK_AGENT_LOG"
  fi
}

extract_backtick_after() {
  local label="$1"
  printf '%s\n' "$prompt" | sed -n "s/.*${label} \`\([^\`]*\)\`.*/\1/p" | sed -n '1p'
}

if [[ "$prompt" == *"META-ORCHESTRATOR"* ]]; then
  log_role "meta"
  printf 'NO_FRESH_ANGLES\n'
  exit 0
fi

if [[ "$prompt" == *"RepoLens Verifier"* ]]; then
  log_role "verifier"
  printf '[]\n'
  exit 0
fi

if [[ "$prompt" == *"RepoLens Synthesizer"* ]]; then
  log_role "synthesizer"
  run_id="$(extract_backtick_after "run")"
  [[ -n "$run_id" ]] || run_id="mock-run"
  jq -n --arg run_id "$run_id" '
    [
      {
        cluster_id: "issue-217-round-1-preserved",
        title: "[low] Preserve saturated round-one finding",
        severity: "low",
        domain: "security",
        lens: "injection",
        root_cause_category: "test-regression",
        source_finding_paths: [
          ("logs/" + $run_id + "/rounds/round-1/lens-outputs/security/injection/001-issue-217-round-1.md")
        ],
        dedup_against_existing: [],
        proposed_labels: ["bug", "audit:security/injection"],
        cross_link_actions: [],
        granularity: "independent",
        verification_status: "unknown",
        body: "## Summary\nRound-one finding survived NO_FRESH_ANGLES saturation.\n\n## Expected\nSaturation skips later rounds without aborting synthesis.\n\n## Actual\nThe manifest includes the round-one finding path.\n\n## Root Cause\nRegression fixture.\n\n## Reproduction\nRun tests/test_no_fresh_angles_preserves_round_1.sh.\n\n## Recommended Fix\nKeep saturation success-shaped.\n\n## Impact\nPrevents dropping already-collected findings."
      }
    ]
  '
  exit 0
fi

log_role "lens"
output_dir="$(printf '%s\n' "$prompt" | sed -n 's/^Write all findings to: `\(.*\)`$/\1/p' | sed -n '1p')"
if [[ -n "$output_dir" ]]; then
  mkdir -p "$output_dir"
  cat > "$output_dir/001-issue-217-round-1.md" <<'FINDING'
---
title: "[LOW] issue-217-round-1"
severity: low
domain: security
lens: injection
labels:
  - "audit:security/injection"
root_cause_category: test-regression
---

## Summary
Round-one finding that must survive NO_FRESH_ANGLES saturation.

## Impact
Regression coverage for preserving already collected findings.

## Evidence
README.md:1 is the stable fixture anchor.

## Recommended Fix
Treat saturation as graceful success and continue to synthesis.
FINDING
fi
printf 'DONE\nCreated issue 217 round-one finding.\nDONE\n'
EOF
chmod +x "$FAKE_BIN/codex"

run_output="$TMPDIR/repolens-output.txt"
PATH="$FAKE_BIN:$PATH" \
  REPOLENS_AGENT_TIMEOUT=10 \
  REPOLENS_AGENT_KILL_GRACE=1 \
  REPOLENS_MOCK_AGENT_LOG="$MOCK_LOG" \
  REPOLENS_NO_VERIFIER=false \
  bash "$SCRIPT_DIR/repolens.sh" \
    --project "$PROJECT_DIR" \
    --agent codex \
    --local \
    --mode audit \
    --focus injection \
    --rounds 3 \
    --depth 1 \
    --yes \
    >"$run_output" 2>&1
run_rc=$?

assert_eq "saturated multi-round run exits successfully" "0" "$run_rc"
RUN_ID="$(sed -n 's/.*RepoLens run \([^ ]*\) complete.*/\1/p' "$run_output" | tail -1)"
[[ -n "$RUN_ID" ]] && RUN_LOG_DIR="$SCRIPT_DIR/logs/$RUN_ID"
assert_eq "run id is discoverable from output" "set" "$([[ -n "$RUN_ID" ]] && printf 'set' || printf 'missing')"

if [[ -z "$RUN_ID" || ! -d "$RUN_LOG_DIR" ]]; then
  fail_with "run log directory exists" "Could not resolve run log from $run_output"
  finish
fi

manifest="$RUN_LOG_DIR/final/manifest.json"
verification="$RUN_LOG_DIR/final/verification.json"
round1_finding="$RUN_LOG_DIR/rounds/round-1/lens-outputs/security/injection/001-issue-217-round-1.md"

assert_file_exists "round-1 finding exists" "$round1_finding"
assert_file_exists "round-1 saturation dispatch exists" "$RUN_LOG_DIR/rounds/round-1/dispatch.md"
assert_contains "dispatch records NO_FRESH_ANGLES" "NO_FRESH_ANGLES" "$RUN_LOG_DIR/rounds/round-1/dispatch.md"
assert_path_absent "round-2 lens finding is skipped after saturation" \
  "$RUN_LOG_DIR/rounds/round-2/lens-outputs/security/injection/001-issue-217-round-1.md"
assert_path_absent "round-2 completion marker is absent after saturation" "$RUN_LOG_DIR/rounds/round-2/.completed"
assert_file_exists "verifier still promotes verification.json" "$verification"
assert_file_exists "synthesizer promotes final manifest.json" "$manifest"
assert_jq "manifest is valid JSON array" "$manifest" 'type == "array" and length == 1'
assert_jq "manifest preserves the round-1 finding path" "$manifest" \
  '
    .[0].cluster_id == "issue-217-round-1-preserved" and
    (.[0].source_finding_paths | index("logs/'"$RUN_ID"'/rounds/round-1/lens-outputs/security/injection/001-issue-217-round-1.md") != null)
  '
assert_contains "run logs saturation skip" "Investigation saturated; skipping remaining rounds" "$run_output"
assert_eq "mock agent handled one lens prompt" "1" "$(grep -c '^lens$' "$MOCK_LOG" 2>/dev/null || printf '0')"
assert_eq "mock agent handled one saturated meta prompt" "1" "$(grep -c '^meta$' "$MOCK_LOG" 2>/dev/null || printf '0')"
assert_eq "mock agent handled verifier prompt" "1" "$(grep -c '^verifier$' "$MOCK_LOG" 2>/dev/null || printf '0')"
assert_eq "mock agent handled synthesizer prompt" "1" "$(grep -c '^synthesizer$' "$MOCK_LOG" 2>/dev/null || printf '0')"

finish
