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

# Tests for issue #227: triage emits `## Relevant domains`; dispatcher prunes
# the default-mode lens list against it. All agent invocations are stubbed
# via _TRIAGE_AGENT_CALLBACK so no real model is ever invoked (CLAUDE.md::Tests).
# shellcheck disable=SC2034,SC2329

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/logging.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/streak.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/summary.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/template.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/core.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/triage.sh"

PASS=0
FAIL=0
TOTAL=0

TMP_PARENT="$SCRIPT_DIR/logs/test-relevant-domains"
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

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected: '$expected' | Actual: '$actual'"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected to find '$needle'"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Did NOT expect to find '$needle'"
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

assert_success() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -eq 0 ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected exit 0, got $actual"
  fi
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

DOMAINS_FILE="$SCRIPT_DIR/config/domains.json"

echo "=== triage prompt schema ==="

triage_prompt="$(cat "$SCRIPT_DIR/prompts/_base/triage.md")"
assert_contains "triage prompt has Relevant domains step prose" "Relevant domains" "$triage_prompt"
assert_contains "triage prompt has ## Relevant domains schema heading" "## Relevant domains" "$triage_prompt"
assert_contains "triage prompt has {{AVAILABLE_DOMAINS}} placeholder" "{{AVAILABLE_DOMAINS}}" "$triage_prompt"

echo ""
echo "=== _triage_default_mode_domain_ids ==="

ids_output="$(_triage_default_mode_domain_ids "$DOMAINS_FILE")"
assert_contains "default-mode ids include security" "security" "$ids_output"
assert_contains "default-mode ids include concurrency" "concurrency" "$ids_output"
assert_not_contains "default-mode ids exclude discovery (mode=discover)" "discovery" "$ids_output"
assert_not_contains "default-mode ids exclude deployment (mode=deploy)" "deployment" "$ids_output"
assert_not_contains "default-mode ids exclude android (mode=deploy)" $'\nandroid\n' $'\n'"$ids_output"$'\n'
assert_not_contains "default-mode ids exclude greenfield (mode=greenfield)" "greenfield" "$ids_output"

echo ""
echo "=== _triage_extract_relevant_domains ==="

# Case: well-formed pack with valid domain ids
pack_ok="$TMPDIR/pack-ok.md"
dst_ok="$TMPDIR/relevant-ok.txt"
cat > "$pack_ok" <<'PACK'
# Triage context pack

## Initial hypothesis tree
1. Some hypothesis.

## Relevant domains
- security
- concurrency
- error-handling

## Investigation seeds (broader-mode wave-1 dispatch)
1. one
PACK
_triage_extract_relevant_domains "$pack_ok" "$dst_ok" "$DOMAINS_FILE"
assert_success "well-formed extraction returns 0" "$?"
assert_file_exists "relevant-domains file created" "$dst_ok"
count_ok="$(wc -l < "$dst_ok" | tr -d ' ')"
assert_eq "well-formed extraction has 3 domains" "3" "$count_ok"
assert_eq "first relevant domain is security" "security" "$(sed -n '1p' "$dst_ok")"
assert_eq "second relevant domain is concurrency" "concurrency" "$(sed -n '2p' "$dst_ok")"
assert_eq "third relevant domain is error-handling" "error-handling" "$(sed -n '3p' "$dst_ok")"

# Case: mixed list-markers and parentheticals are sanitized to clean ids
pack_mixed="$TMPDIR/pack-mixed.md"
dst_mixed="$TMPDIR/relevant-mixed.txt"
cat > "$pack_mixed" <<'PACK'
## Relevant domains
- security (authn angle)
* concurrency
1. error-handling: race conditions
2) performance
+ database
`logs`
PACK
_triage_extract_relevant_domains "$pack_mixed" "$dst_mixed" "$DOMAINS_FILE"
mixed_content="$(cat "$dst_mixed")"
assert_contains "list-marker sanitization keeps security" "security" "$mixed_content"
assert_contains "list-marker sanitization keeps concurrency" "concurrency" "$mixed_content"
assert_contains "list-marker sanitization keeps error-handling" "error-handling" "$mixed_content"
assert_contains "list-marker sanitization keeps performance" "performance" "$mixed_content"
assert_contains "list-marker sanitization keeps database" "database" "$mixed_content"
assert_contains "list-marker sanitization keeps logs" "logs" "$mixed_content"
assert_not_contains "trailing parenthetical stripped" "authn angle" "$mixed_content"
assert_not_contains "trailing colon-note stripped" "race conditions" "$mixed_content"

# Case: unknown domains are silently dropped via whitelist
pack_unknown="$TMPDIR/pack-unknown.md"
dst_unknown="$TMPDIR/relevant-unknown.txt"
cat > "$pack_unknown" <<'PACK'
## Relevant domains
- security
- frobnicator
- discovery
- concurrency
PACK
_triage_extract_relevant_domains "$pack_unknown" "$dst_unknown" "$DOMAINS_FILE"
unknown_content="$(cat "$dst_unknown")"
assert_contains "whitelist keeps known security id" "security" "$unknown_content"
assert_contains "whitelist keeps known concurrency id" "concurrency" "$unknown_content"
assert_not_contains "whitelist drops unknown frobnicator" "frobnicator" "$unknown_content"
assert_not_contains "whitelist drops discovery (wrong mode)" "discovery" "$unknown_content"

# Case: duplicates are deduped
pack_dupes="$TMPDIR/pack-dupes.md"
dst_dupes="$TMPDIR/relevant-dupes.txt"
cat > "$pack_dupes" <<'PACK'
## Relevant domains
- security
- security
- concurrency
- concurrency
- security
PACK
_triage_extract_relevant_domains "$pack_dupes" "$dst_dupes" "$DOMAINS_FILE"
dupe_count="$(wc -l < "$dst_dupes" | tr -d ' ')"
assert_eq "duplicates collapsed to 2 entries" "2" "$dupe_count"

# Case: (none) / DONE / blank lines are dropped → empty output
pack_none="$TMPDIR/pack-none.md"
dst_none="$TMPDIR/relevant-none.txt"
cat > "$pack_none" <<'PACK'
## Relevant domains
- (none)
- DONE

## Investigation seeds
1. foo
PACK
_triage_extract_relevant_domains "$pack_none" "$dst_none" "$DOMAINS_FILE"
none_size="$(wc -c < "$dst_none" | tr -d ' ')"
assert_eq "empty/(none)/DONE produces empty file" "0" "$none_size"

# Case: missing ## Relevant domains heading → empty output
pack_missing="$TMPDIR/pack-missing.md"
dst_missing="$TMPDIR/relevant-missing.txt"
cat > "$pack_missing" <<'PACK'
# Triage context pack

## Mentioned files
- sample.go

## Investigation seeds
1. foo
PACK
_triage_extract_relevant_domains "$pack_missing" "$dst_missing" "$DOMAINS_FILE"
missing_size="$(wc -c < "$dst_missing" | tr -d ' ')"
assert_eq "missing section produces empty file" "0" "$missing_size"
assert_file_exists "missing section still creates dst file" "$dst_missing"

# Case: pipes/backticks are stripped from ids before whitelist check
pack_pipe="$TMPDIR/pack-pipe.md"
dst_pipe="$TMPDIR/relevant-pipe.txt"
cat > "$pack_pipe" <<'PACK'
## Relevant domains
- security|injected payload
- `concurrency`
PACK
_triage_extract_relevant_domains "$pack_pipe" "$dst_pipe" "$DOMAINS_FILE"
pipe_content="$(cat "$dst_pipe")"
assert_contains "pipe-suffixed entry collapses to bare id" "security" "$pipe_content"
assert_contains "backtick-wrapped entry collapses to bare id" "concurrency" "$pipe_content"
assert_not_contains "extracted ids drop pipes" "|" "$pipe_content"

echo ""
echo "=== run_triage emits relevant-domains.txt ==="

RUN_ID="test-run-227"
LOG_BASE="$TMPDIR/logs/$RUN_ID"
TRIAGE_DIR="$LOG_BASE/triage"
mkdir -p "$LOG_BASE"

PROJECT_PATH="$TMPDIR/project"
mkdir -p "$PROJECT_PATH"
printf 'placeholder\n' > "$PROJECT_PATH/sample.go"

BUG_REPORT_FILE="$LOG_BASE/bug-report.txt"
printf 'Symptom: foo crashes when bar runs.\n' > "$BUG_REPORT_FILE"

AGENT="claude"
MODE="bugreport"
REPO_OWNER="owner"
REPO_NAME="repo"
export RUN_ID LOG_BASE PROJECT_PATH AGENT MODE REPO_OWNER REPO_NAME BUG_REPORT_FILE DOMAINS_FILE

_relevant_triage_callback_with_domains() {
  cat <<'PACK'
# Triage context pack

## Mentioned files
- sample.go

## Initial hypothesis tree
1. Some hypothesis.

## Relevant domains
- security
- concurrency
- error-handling

## Investigation seeds (broader-mode wave-1 dispatch)
1. session refresh path
DONE
PACK
}
_TRIAGE_AGENT_CALLBACK=_relevant_triage_callback_with_domains
run_triage "$RUN_ID" >"$TMPDIR/relevant.out" 2>"$TMPDIR/relevant.err"
assert_success "run_triage with domains returns 0" "$?"
assert_file_exists "context-pack.md created" "$TRIAGE_DIR/context-pack.md"
assert_file_exists "relevant-domains.txt created" "$TRIAGE_DIR/relevant-domains.txt"
rd_actual_count="$(wc -l < "$TRIAGE_DIR/relevant-domains.txt" | tr -d ' ')"
assert_eq "relevant-domains.txt contains 3 entries" "3" "$rd_actual_count"

# Case: backfill on resume — pack already exists, relevant-domains.txt missing.
# The orchestrator re-enters run_triage and it must backfill from the saved
# transcript (or pack) without re-invoking the agent.
RESUME_RUN_ID="test-run-227-resume"
RESUME_LOG_BASE="$TMPDIR/logs/$RESUME_RUN_ID"
RESUME_TRIAGE="$RESUME_LOG_BASE/triage"
mkdir -p "$RESUME_TRIAGE"
cat > "$RESUME_TRIAGE/context-pack.md" <<'PACK'
# Triage context pack

## Mentioned files
- sample.go

## Relevant domains
- security
- database

## Investigation seeds
1. cached resume
DONE
PACK
cp "$RESUME_TRIAGE/context-pack.md" "$RESUME_TRIAGE/transcript.txt"

LOG_BASE="$RESUME_LOG_BASE"
export LOG_BASE
# Stub callback that, if invoked, would record a failure marker
RESUME_CALLBACK_FIRED="$TMPDIR/resume-callback-fired"
_relevant_resume_callback() {
  : > "$RESUME_CALLBACK_FIRED"
  printf 'fresh pack\n'
}
_TRIAGE_AGENT_CALLBACK=_relevant_resume_callback
run_triage "$RESUME_RUN_ID" >"$TMPDIR/resume.out" 2>"$TMPDIR/resume.err"
assert_success "resume backfill returns 0" "$?"
assert_file_exists "resume backfill produced relevant-domains.txt" "$RESUME_TRIAGE/relevant-domains.txt"
resume_count="$(wc -l < "$RESUME_TRIAGE/relevant-domains.txt" | tr -d ' ')"
assert_eq "resume backfill has 2 entries (security, database)" "2" "$resume_count"
TOTAL=$((TOTAL + 1))
if [[ ! -e "$RESUME_CALLBACK_FIRED" ]]; then
  pass_with "resume backfill does NOT re-invoke triage agent"
else
  fail_with "resume backfill does NOT re-invoke triage agent" "callback fired"
fi

# Restore LOG_BASE for any downstream cases
LOG_BASE="$TMPDIR/logs/$RUN_ID"
export LOG_BASE

finish
