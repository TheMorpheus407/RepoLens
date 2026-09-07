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

# Integration test for issue #234: full --mode bugreport pipeline against a
# mocked agent. Drives triage → round-1 lens → round-2 meta-orchestrator reshape
# → round-3 lens → synthesizer → filing, and asserts each stage produced its
# canonical artifact. Prevents the wave-1 orphaned-filing-batch / missing-source
# class of regressions by exercising the orchestrator end-to-end rather than the
# individual library functions.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
TOTAL=0
RUN_LOG_DIR=""
KEEP_ARTIFACTS=0

TMP_PARENT="$SCRIPT_DIR/logs/test-e2e-bugreport"
mkdir -p "$TMP_PARENT"
TMPDIR="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"

cleanup() {
  if (( KEEP_ARTIFACTS == 0 )); then
    if [[ -n "$RUN_LOG_DIR" ]]; then
      rm -rf "$RUN_LOG_DIR"
    fi
    rm -rf "$TMPDIR"
    rmdir "$TMP_PARENT" 2>/dev/null || true
  else
    printf 'Preserved test artifacts: %s\n' "$TMPDIR"
    if [[ -n "$RUN_LOG_DIR" ]]; then
      printf 'Preserved RepoLens log dir: %s\n' "$RUN_LOG_DIR"
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

assert_nonempty_file() {
  local desc="$1" file="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -s "$file" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected non-empty file at $file"
  fi
}

assert_contains_file() {
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

finish() {
  echo ""
  echo "Results: $PASS/$TOTAL passed, $FAIL failed"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

echo "=== --mode bugreport end-to-end (issue #234) ==="

PROJECT_DIR="$TMPDIR/project"
FAKE_BIN="$TMPDIR/bin"
MOCK_LOG="$TMPDIR/mock-agent.log"
GH_LOG="$TMPDIR/gh.log"
BUG_FILE="$TMPDIR/bug-report.md"
mkdir -p "$PROJECT_DIR" "$FAKE_BIN"

git -C "$PROJECT_DIR" init -q
git -C "$PROJECT_DIR" remote add origin https://github.com/example/repo.git
printf '# RepoLens issue 234 fixture\nIf [ "$a" = "$b" ]; then echo broken; fi\n' > "$PROJECT_DIR/README.md"
git -C "$PROJECT_DIR" add README.md
git -C "$PROJECT_DIR" \
  -c user.name='RepoLens Test' \
  -c user.email='repolens@example.invalid' \
  commit -q -m 'fixture'

cat > "$BUG_FILE" <<'EOF'
The README example assigns when it should compare; users see unexpected output
when reading the project intro at README.md:1.
EOF

export REPOLENS_GOVERNOR_MOCK_AGENT="$SCRIPT_DIR/tests/mock-agent.sh"
cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
output="$("$REPOLENS_GOVERNOR_MOCK_AGENT" "$@")" || exit $?
if jq -e 'type == "array"' <<< "$output" >/dev/null 2>&1; then
  jq 'map(if .cluster_id == "mock-round-handoff" then .body += "\n\n## References\nREADME.md:1" else . end)' <<< "$output"
else
  printf '%s\n' "$output"
fi
EOF
cat > "$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >> "${REPOLENS_FAKE_GH_LOG:-/dev/null}"
command="$1 $2"; shift 2
case "$command" in
  'auth status'|'label create') exit 0 ;;
  'label list') printf '[]\n' ;;
  'issue list')
    if [[ "${REPOLENS_MOCK_FILING_DEDUP:-0}" == 1 ]]; then
      printf '[{"number":204,"title":"[low] Keep deterministic mock finding wired","body":"existing","state":"OPEN","url":"https://github.com/example/repo/issues/204","labels":[]}]\n'
    else printf '[]\n'; fi ;;
  'issue create')
    [[ "${REPOLENS_MOCK_FILING_FAIL:-0}" == 1 ]] && exit 1
    title='' body_file='' labels='[]'
    while (( $# )); do
      case "$1" in
        --title) title="$2"; shift 2 ;;
        --body-file) body_file="$2"; shift 2 ;;
        --label) labels="$(jq -c --arg label "$2" '.+[$label]' <<< "$labels")"; shift 2 ;;
        -R) shift 2 ;;
        *) exit 99 ;;
      esac
    done
    jq -n --arg title "$title" --rawfile body "$body_file" --argjson labels "$labels" \
      '{number:2040,title:$title,body:$body,labels:$labels,state:"OPEN",url:"https://github.com/example/repo/issues/2040"}' > "$REPOLENS_FAKE_GH_LOG.readback"
    printf 'https://github.com/example/repo/issues/2040\n' ;;
  'issue view')
    [[ "${REPOLENS_MOCK_FILING_MISSING:-0}" == 1 ]] && exit 1
    cat "$REPOLENS_FAKE_GH_LOG.readback" ;;
  *) exit 99 ;;
esac
EOF
chmod +x "$FAKE_BIN/codex" "$FAKE_BIN/gh" "$SCRIPT_DIR/tests/mock-agent.sh"

run_output="$TMPDIR/repolens-output.txt"
export REPOLENS_MOCK_WRITE_FINDINGS_WITHOUT_LOCAL=1
PATH="$FAKE_BIN:$PATH" \
  REPOLENS_AGENT_TIMEOUT=10 \
  REPOLENS_AGENT_KILL_GRACE=1 \
  REPOLENS_MOCK_AGENT_LOG="$MOCK_LOG" \
  REPOLENS_MOCK_TRIAGE_DOMAINS="security" \
  REPOLENS_MOCK_META_LENS="injection" \
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
run_rc=$?

assert_eq "bugreport e2e run exits successfully" "0" "$run_rc"

RUN_ID="$(sed -n 's/.*RepoLens run \([^ ]*\) complete.*/\1/p' "$run_output" | tail -1)"
if [[ -n "$RUN_ID" ]]; then
  RUN_LOG_DIR="$SCRIPT_DIR/logs/$RUN_ID"
fi
assert_eq "run id is discoverable from output" "set" "$([[ -n "$RUN_ID" ]] && printf 'set' || printf 'missing')"

if [[ -z "$RUN_ID" || ! -d "$RUN_LOG_DIR" ]]; then
  fail_with "run log directory exists" "Could not resolve run log from $run_output"
  finish
fi

# Triage produced a schema-valid context pack and seed/domain artifacts.
assert_file_exists "triage/context-pack.md exists" "$RUN_LOG_DIR/triage/context-pack.md"
assert_contains_file "context pack carries schema heading" "# Triage context pack" "$RUN_LOG_DIR/triage/context-pack.md"
assert_contains_file "context pack lists relevant domains" "## Relevant domains" "$RUN_LOG_DIR/triage/context-pack.md"
assert_contains_file "context pack lists investigation seeds" "## Investigation seeds" "$RUN_LOG_DIR/triage/context-pack.md"
assert_file_exists "triage/investigation-seeds.txt exists" "$RUN_LOG_DIR/triage/investigation-seeds.txt"
assert_nonempty_file "triage/investigation-seeds.txt is non-empty" "$RUN_LOG_DIR/triage/investigation-seeds.txt"
assert_file_exists "triage/relevant-domains.txt exists" "$RUN_LOG_DIR/triage/relevant-domains.txt"
assert_nonempty_file "triage/relevant-domains.txt is non-empty" "$RUN_LOG_DIR/triage/relevant-domains.txt"
assert_contains_file "relevant-domains.txt includes security" "security" "$RUN_LOG_DIR/triage/relevant-domains.txt"
assert_eq "mock agent saw exactly one triage prompt" "1" "$(grep -c '^triage$' "$MOCK_LOG" 2>/dev/null || printf '0')"

# Round layout: round-1, round-2, round-3 must each have lens outputs and
# captured prompts. The mock meta dispatch.md keeps the lens stable so the
# reshape resolves to security/injection in every round.
for round in 1 2 3; do
  assert_file_exists "round-$round captured injection prompt" \
    "$RUN_LOG_DIR/rounds/round-$round/captured-prompts/security__injection.prompt.md"
done

# Round-2 captures evidence that the meta-orchestrator dispatch was applied:
# the previous round's dispatch.md must exist and have been consumed.
assert_file_exists "round-1 dispatch.md exists" "$RUN_LOG_DIR/rounds/round-1/dispatch.md"
assert_file_exists "round-2 dispatch.md exists" "$RUN_LOG_DIR/rounds/round-2/dispatch.md"
assert_contains_file "round-1 dispatch names the meta-selected lens" \
  "LENS: injection" "$RUN_LOG_DIR/rounds/round-1/dispatch.md"
assert_contains_file "orchestrator logged meta-dispatch reshape" \
  "Using meta-orchestrator dispatch" "$run_output"

# Synthesizer wrote a manifest and the filing batch ran against the fake gh.
manifest="$RUN_LOG_DIR/final/manifest.json"
assert_file_exists "final/manifest.json exists" "$manifest"
assert_jq "manifest is non-empty array" "$manifest" 'type == "array" and length >= 1'
assert_file_exists "filing marker exists" "$RUN_LOG_DIR/final/filed/mock-round-handoff.url"
assert_contains_file "filing marker carries issue URL" \
  "https://github.com/example/repo/issues/2040" \
  "$RUN_LOG_DIR/final/filed/mock-round-handoff.url"
assert_contains_file "orchestrator logged filing batch complete" \
  "Filing: batch complete" "$run_output"
assert_eq "governor never invokes a filing model" "0" \
  "$(grep -c '^filing$' "$MOCK_LOG" 2>/dev/null || true)"
assert_eq "mock agent handled one synthesizer prompt" "1" \
  "$(grep -c '^synthesizer$' "$MOCK_LOG" 2>/dev/null || printf '0')"
assert_eq "mock agent handled two meta-orchestrator prompts" "2" \
  "$(grep -c '^meta$' "$MOCK_LOG" 2>/dev/null || printf '0')"
assert_contains_file "fake gh auth was checked" "auth status" "$GH_LOG"

# Final status: the run terminator wrote status.json with a terminal state
# indicating successful completion (either "finished" or "finished-empty" —
# multi-round bugreport runs route findings through the synthesizer manifest,
# so per-lens issues_created stays 0 and the health classifier reports
# "no-findings" even when filing succeeds).
assert_file_exists "status.json exists" "$RUN_LOG_DIR/status.json"
assert_jq "status.json state indicates successful completion" \
  "$RUN_LOG_DIR/status.json" \
  '.state | IN("finished", "finished-empty")'

finish
