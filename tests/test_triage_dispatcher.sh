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

# Tests for issue #171: lib/triage.sh — _triage_truncate_pack and run_triage.
# All agent invocations are stubbed via _TRIAGE_AGENT_CALLBACK so no real
# model is ever invoked (per CLAUDE.md::Tests).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRIAGE_LIB="$SCRIPT_DIR/lib/triage.sh"
TEMPLATE_LIB="$SCRIPT_DIR/lib/template.sh"
CORE_LIB="$SCRIPT_DIR/lib/core.sh"
LOGGING_LIB="$SCRIPT_DIR/lib/logging.sh"

PASS=0
FAIL=0
TOTAL=0

TMP_PARENT="$SCRIPT_DIR/logs/test-triage"
mkdir -p "$TMP_PARENT"
TMPDIR="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"

cleanup() {
  rm -rf "$TMPDIR"
  rmdir "$TMP_PARENT" 2>/dev/null || true
}
trap cleanup EXIT

pass_with() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

fail_with() {
  local desc="$1" detail="${2:-}"
  FAIL=$((FAIL + 1))
  echo "  FAIL: $desc"
  if [[ -n "$detail" ]]; then
    printf '    %s\n' "$detail"
  fi
}

assert_success() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -eq 0 ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected exit 0, got $actual"
  fi
}

assert_failure() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -ne 0 ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected non-zero exit"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Did not find '$needle' in: $haystack"
  fi
}

assert_file_exists() {
  local desc="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$path" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected file $path"
  fi
}

assert_file_missing() {
  local desc="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [[ ! -e "$path" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Did not expect file $path"
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected '$expected', got '$actual'"
  fi
}

assert_le() {
  local desc="$1" lhs="$2" rhs="$3"
  TOTAL=$((TOTAL + 1))
  if (( lhs <= rhs )); then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected $lhs <= $rhs"
  fi
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

if [[ ! -f "$TRIAGE_LIB" ]]; then
  echo "  FAIL: lib/triage.sh missing at $TRIAGE_LIB"
  exit 1
fi

# shellcheck disable=SC1090
source "$LOGGING_LIB"
# shellcheck disable=SC1090
source "$TEMPLATE_LIB"
# shellcheck disable=SC1090
source "$CORE_LIB"
# shellcheck disable=SC1090
source "$TRIAGE_LIB"

echo "=== _triage_truncate_pack ==="

# Case: small pack stays intact
small_src="$TMPDIR/small.in"
small_dst="$TMPDIR/small.out"
printf '# small pack\n- one\n- two\n' > "$small_src"
_triage_truncate_pack "$small_src" "$small_dst"
assert_eq "small pack unchanged" "$(cat "$small_src")" "$(cat "$small_dst")"

# Case: large pack truncated and ends with deterministic marker
large_src="$TMPDIR/large.in"
large_dst="$TMPDIR/large.out"
{
  printf '# large pack\n'
  for _ in $(seq 1 200); do
    printf '%s\n' '- this is a long line of triage content for testing'
  done
} > "$large_src"
_triage_truncate_pack "$large_src" "$large_dst"
truncated_size="$(wc -c < "$large_dst" | tr -d ' ')"
assert_le "large pack truncated to <= 2048 bytes" "$truncated_size" 2048
assert_contains "truncation marker present" "[... truncated, see logs/<run-id>/triage/transcript.txt ...]" "$(cat "$large_dst")"

echo ""
echo "=== run_triage dispatcher ==="

# Set up a minimal run layout under TMPDIR
RUN_ID="test-run-171"
LOG_BASE="$TMPDIR/logs/$RUN_ID"
TRIAGE_DIR="$LOG_BASE/triage"
mkdir -p "$LOG_BASE"

# A real project path
PROJECT_PATH="$TMPDIR/project"
mkdir -p "$PROJECT_PATH"
printf 'placeholder\n' > "$PROJECT_PATH/sample.go"

BUG_REPORT_FILE="$LOG_BASE/bug-report.txt"
printf 'Symptom: foo crashes when bar runs.\nMentioned: sample.go and issue #42.\n' > "$BUG_REPORT_FILE"

AGENT="claude"
MODE="bugreport"
REPO_OWNER="owner"
REPO_NAME="repo"
export RUN_ID LOG_BASE PROJECT_PATH AGENT MODE REPO_OWNER REPO_NAME BUG_REPORT_FILE

# Case 1: happy path — callback emits a well-formed pack
_triage_callback_ok() {
  cat <<'PACK'
# Triage context pack

## Mentioned files
- sample.go

## Linked issues
- #42 — example linked issue summary

## Suspect commits (last 10 touching mentioned files)
- abc1234 (2026-04-22, alice) — example commit summary

## Recent activity by suspect-commit authors
- alice: sample.go (2 days ago)

## Initial hypothesis tree
1. Hypothesis one about sample.go
2. Hypothesis two about commit abc1234
DONE
PACK
}
_TRIAGE_AGENT_CALLBACK=_triage_callback_ok
run_triage "$RUN_ID" >"$TMPDIR/ok.out" 2>"$TMPDIR/ok.err"
status=$?
assert_success "happy-path run_triage returns 0" "$status"
assert_file_exists "happy-path: context-pack.md exists" "$TRIAGE_DIR/context-pack.md"
assert_file_exists "happy-path: transcript.txt exists" "$TRIAGE_DIR/transcript.txt"
assert_contains "context-pack contains schema heading" "# Triage context pack" "$(cat "$TRIAGE_DIR/context-pack.md")"
assert_contains "context-pack contains hypothesis tree" "Initial hypothesis tree" "$(cat "$TRIAGE_DIR/context-pack.md")"

# Case 2: idempotence — invoking again with existing pack does not re-invoke
# the callback (resume case).
COUNTER_FILE="$TMPDIR/counter"
echo "0" > "$COUNTER_FILE"
_triage_callback_counting() {
  local n
  n="$(cat "$COUNTER_FILE")"
  printf '%d\n' "$((n + 1))" > "$COUNTER_FILE"
  printf '# Triage context pack\n## Mentioned files\n- (none)\nDONE\n'
}
_TRIAGE_AGENT_CALLBACK=_triage_callback_counting
run_triage "$RUN_ID" >"$TMPDIR/idem.out" 2>"$TMPDIR/idem.err"
assert_success "idempotent: returns 0 when pack already exists" "$?"
assert_eq "idempotent: callback NOT invoked when pack present" "0" "$(cat "$COUNTER_FILE")"

# Case 3: clean slate — remove pack, then dispatch again, callback fires exactly once
rm -f "$TRIAGE_DIR/context-pack.md"
run_triage "$RUN_ID" >"$TMPDIR/fresh.out" 2>"$TMPDIR/fresh.err"
assert_success "fresh dispatch returns 0" "$?"
assert_eq "fresh dispatch: callback called exactly once" "1" "$(cat "$COUNTER_FILE")"
assert_file_exists "fresh dispatch: pack re-created" "$TRIAGE_DIR/context-pack.md"

# Case 4: callback emits >2 KB — pack is truncated to <=2048 bytes
_triage_callback_huge() {
  printf '# Triage context pack\n## Mentioned files\n'
  local i line
  for i in $(seq 1 200); do
    line="$(printf '/path/very/long/with/lots/of/words/per/line/file-%03d.ext' "$i")"
    printf '%s\n' "- $line"
  done
  printf 'DONE\n'
}
rm -f "$TRIAGE_DIR/context-pack.md"
_TRIAGE_AGENT_CALLBACK=_triage_callback_huge
run_triage "$RUN_ID" >"$TMPDIR/huge.out" 2>"$TMPDIR/huge.err"
status=$?
assert_success "huge pack returns 0" "$status"
assert_file_exists "huge pack: context-pack.md exists" "$TRIAGE_DIR/context-pack.md"
huge_size="$(wc -c < "$TRIAGE_DIR/context-pack.md" | tr -d ' ')"
assert_le "huge pack truncated to <= 2048 bytes" "$huge_size" 2048
assert_contains "huge pack carries deterministic truncation marker" "[... truncated, see logs/<run-id>/triage/transcript.txt ...]" "$(cat "$TRIAGE_DIR/context-pack.md")"
huge_transcript_size="$(wc -c < "$TRIAGE_DIR/transcript.txt" | tr -d ' ')"
assert_le "huge transcript keeps full untruncated output (> pack)" "$huge_size" "$huge_transcript_size"

# Case 5: callback failure → run_triage returns non-zero and no consumable pack
_triage_callback_fail() {
  echo "synthetic triage failure" >&2
  return 1
}
rm -f "$TRIAGE_DIR/context-pack.md"
_TRIAGE_AGENT_CALLBACK=_triage_callback_fail
run_triage "$RUN_ID" >"$TMPDIR/fail.out" 2>"$TMPDIR/fail.err"
status=$?
assert_failure "callback failure returns non-zero" "$status"
assert_file_missing "callback failure: no consumable pack" "$TRIAGE_DIR/context-pack.md"

# Case 6: direct agent dispatch leaves unset timeout blank for run_agent resolution
unset _TRIAGE_AGENT_CALLBACK
unset AGENT_TIMEOUT_SECS
AGENT="codex"
RUN_AGENT_ARGS_FILE="$TMPDIR/triage-run-agent-args.txt"
run_agent() {
  printf '%s\n%s\n' "${4-}" "${5-}" > "$RUN_AGENT_ARGS_FILE"
  cat <<'PACK'
# Triage context pack

## Mentioned files
- sample.go

## Initial hypothesis tree
1. Direct agent path.
DONE
PACK
}
rm -f "$TRIAGE_DIR/context-pack.md"
run_triage "$RUN_ID" >"$TMPDIR/direct-agent.out" 2>"$TMPDIR/direct-agent.err"
status=$?
assert_success "direct agent dispatch returns 0" "$status"
assert_eq "direct agent dispatch passes empty timeout when AGENT_TIMEOUT_SECS is unset" "" "$(sed -n '1p' "$RUN_AGENT_ARGS_FILE")"
assert_eq "direct agent dispatch keeps default kill grace" "30" "$(sed -n '2p' "$RUN_AGENT_ARGS_FILE")"

# Case 7: missing AGENT
unset AGENT
_TRIAGE_AGENT_CALLBACK=_triage_callback_ok
rm -f "$TRIAGE_DIR/context-pack.md"
run_triage "$RUN_ID" >"$TMPDIR/noagent.out" 2>"$TMPDIR/noagent.err"
status=$?
assert_failure "missing AGENT returns non-zero" "$status"
assert_contains "missing AGENT error message" "AGENT" "$(cat "$TMPDIR/noagent.err")"
AGENT="claude"

# Case 8: missing PROJECT_PATH
saved_path="$PROJECT_PATH"
PROJECT_PATH="$TMPDIR/does-not-exist"
run_triage "$RUN_ID" >"$TMPDIR/nopath.out" 2>"$TMPDIR/nopath.err"
status=$?
assert_failure "missing PROJECT_PATH returns non-zero" "$status"
PROJECT_PATH="$saved_path"

# Case 9: missing run_id
run_triage "" >"$TMPDIR/norun.out" 2>"$TMPDIR/norun.err"
status=$?
assert_failure "missing run_id returns non-zero" "$status"

echo ""
echo "=== bugreport.md slot wiring ==="

# Compose the bugreport template with a pre-populated triage pack and assert
# the slot is substituted byte-for-byte into the lens prompt.
cat > "$TMPDIR/lens.md" <<'EOF'
---
id: test-lens
domain: test
name: Test Lens
role: tester
---
## Your Expert Focus
Focus on bug-report symptoms.
EOF

cat > "$TMPDIR/pack.md" <<'EOF'
# Triage context pack

## Mentioned files
- sample.go

## Initial hypothesis tree
1. Hypothesis one with a | pipe character
EOF

base_vars="LENS_NAME=BugBot|REPO_OWNER=owner|REPO_NAME=repo|PROJECT_PATH=/tmp/project|LENS_LABEL=bugreport:test/lens|DOMAIN=test|LENS_ID=test-lens|MODE=bugreport|RUN_ID=test-run|ROUND_INDEX=1|ROUND_TOTAL=1"
rendered_with_pack="$(compose_prompt "$SCRIPT_DIR/prompts/_base/bugreport.md" "$TMPDIR/lens.md" "${base_vars}|BUG_REPORT=Symptom payload|TRIAGE_CONTEXT_PACK=@${TMPDIR}/pack.md" "" "bugreport")"
assert_contains "rendered prompt embeds triage pack heading" "# Triage context pack" "$rendered_with_pack"
assert_contains "rendered prompt embeds triage pack pipe content" "Hypothesis one with a | pipe character" "$rendered_with_pack"
assert_contains "rendered prompt keeps triage pack section header" "Triage Context Pack" "$rendered_with_pack"
TOTAL=$((TOTAL + 1))
if [[ "$rendered_with_pack" != *"{{TRIAGE_CONTEXT_PACK}}"* ]]; then
  pass_with "rendered prompt consumes the {{TRIAGE_CONTEXT_PACK}} placeholder"
else
  fail_with "rendered prompt consumes the {{TRIAGE_CONTEXT_PACK}} placeholder" "placeholder still present"
fi

# When no triage var is provided, the slot resolves to empty (no leftover token)
rendered_empty="$(compose_prompt "$SCRIPT_DIR/prompts/_base/bugreport.md" "$TMPDIR/lens.md" "${base_vars}|BUG_REPORT=Symptom payload" "" "bugreport")"
TOTAL=$((TOTAL + 1))
if [[ "$rendered_empty" != *"{{TRIAGE_CONTEXT_PACK}}"* ]]; then
  pass_with "no-triage render still consumes the {{TRIAGE_CONTEXT_PACK}} placeholder"
else
  fail_with "no-triage render still consumes the {{TRIAGE_CONTEXT_PACK}} placeholder" "placeholder still present"
fi

finish
