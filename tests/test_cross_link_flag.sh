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

# Tests for issue #174: --cross-link flag + synthesizer/filing integration.
#
# Covers:
#   1. CLI arg parsing: invalid values rejected, valid values accepted.
#   2. --help advertises the flag and at least one example uses it.
#   3. validate_manifest enforces CROSS_LINK_MODE=off => empty actions.
#   4. validate_manifest rejects malformed cross-link actions (unknown
#      type, missing issue_number, empty body, non-number issue_number).
#   5. validate_manifest enforces comment mode forbids reopen-suggestion.
#   6. dispatch_filing_batch enacts cross-link actions via forge stubs
#      with idempotent sentinel files; failures do not abort the run.
#   7. Tripwire: no auto-reopen primitive exists anywhere in lib/ or
#      prompts/_base/.

# shellcheck disable=SC2034 # Test globals are consumed by sourced modules.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOLENS_SH="$SCRIPT_DIR/repolens.sh"
SYNTHESIZE_LIB="$SCRIPT_DIR/lib/synthesize.sh"
TEMPLATE_LIB="$SCRIPT_DIR/lib/template.sh"
CORE_LIB="$SCRIPT_DIR/lib/core.sh"
FILING_LIB="$SCRIPT_DIR/lib/filing.sh"
PARALLEL_LIB="$SCRIPT_DIR/lib/parallel.sh"
LOGGING_LIB="$SCRIPT_DIR/lib/logging.sh"

PASS=0
FAIL=0
TOTAL=0

TMP_PARENT="$SCRIPT_DIR/logs/test-cross-link"
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

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected '$expected', got '$actual'"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Did not find '$needle' in output"
  fi
}

assert_file_exists() {
  local desc="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -e "$path" ]]; then
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

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

echo "=== CLI: --cross-link arg parsing & help ==="

# Invalid value rejected with informative error.
out="$(bash "$REPOLENS_SH" --project "$TMPDIR" --agent claude --cross-link bogus 2>&1)"
status=$?
assert_failure "--cross-link bogus exits non-zero" "$status"
assert_contains "error mentions cross-link" "cross-link" "$out"
assert_contains "error mentions valid values" "suggest-reopen" "$out"

# Help text advertises the flag.
help_out="$(bash "$REPOLENS_SH" --help 2>&1)"
status=$?
assert_success "--help exits 0" "$status"
assert_contains "help text mentions --cross-link" "--cross-link" "$help_out"
assert_contains "help text shows suggest-reopen value" "suggest-reopen" "$help_out"

# Help block lists an example using suggest-reopen.
example_count=$(grep -c -- '--cross-link suggest-reopen' <<< "$help_out")
TOTAL=$((TOTAL + 1))
if (( example_count >= 1 )); then
  pass_with "help block includes a suggest-reopen example"
else
  fail_with "help block includes a suggest-reopen example" \
    "Got $example_count examples"
fi

# Environment-variable doc present.
assert_contains "help text documents REPOLENS_CROSS_LINK env fallback" \
  "REPOLENS_CROSS_LINK" "$help_out"

echo ""
echo "=== validate_manifest: CROSS_LINK_MODE gate ==="

# shellcheck disable=SC1090
source "$TEMPLATE_LIB"
# shellcheck disable=SC1090
source "$CORE_LIB"
# shellcheck disable=SC1090
source "$SYNTHESIZE_LIB"

write_entry_with_actions() {
  local path="$1" actions_json="$2"
  cat > "$path" <<JSON
[
  {
    "cluster_id": "missing-validation::lib-upload-handler",
    "title": "[high] Validate upload filenames before writing files",
    "severity": "high",
    "domain": "code",
    "lens": "input-validation",
    "root_cause_category": "missing-validation",
    "source_finding_paths": [
      "logs/run-1/rounds/round-1/lens-outputs/code/input-validation.md"
    ],
    "dedup_against_existing": [],
    "proposed_labels": ["bug"],
    "cross_link_actions": $actions_json,
    "granularity": "independent",
    "body": "Summary body content with enough text to pass validation."
  }
]
JSON
}

# off mode: any cross-link action is a hard error
off_path="$TMPDIR/off.json"
write_entry_with_actions "$off_path" \
  '[{"type":"comment","issue_number":42,"body":"see new evidence"}]'
CROSS_LINK_MODE="off" validate_manifest "$off_path" 2>"$TMPDIR/off.err"
status=$?
assert_failure "off mode rejects non-empty cross_link_actions" "$status"
assert_contains "off-mode error mentions CROSS_LINK_MODE=off" \
  "CROSS_LINK_MODE=off" "$(cat "$TMPDIR/off.err")"

# off mode: empty actions accepted
empty_path="$TMPDIR/empty.json"
write_entry_with_actions "$empty_path" '[]'
CROSS_LINK_MODE="off" validate_manifest "$empty_path" 2>/dev/null
status=$?
assert_success "off mode accepts empty cross_link_actions" "$status"

# comment mode: reopen-suggestion rejected
reopen_path="$TMPDIR/reopen-in-comment.json"
write_entry_with_actions "$reopen_path" \
  '[{"type":"reopen-suggestion","issue_number":99,"body":"closed but relevant"}]'
CROSS_LINK_MODE="comment" validate_manifest "$reopen_path" 2>"$TMPDIR/reopen.err"
status=$?
assert_failure "comment mode rejects reopen-suggestion" "$status"
assert_contains "comment-mode error mentions reopen-suggestion not allowed" \
  "reopen-suggestion not allowed" "$(cat "$TMPDIR/reopen.err")"

# comment mode: comment accepted
comment_ok="$TMPDIR/comment-ok.json"
write_entry_with_actions "$comment_ok" \
  '[{"type":"comment","issue_number":42,"body":"see new evidence"}]'
CROSS_LINK_MODE="comment" validate_manifest "$comment_ok" 2>/dev/null
status=$?
assert_success "comment mode accepts comment actions" "$status"

# suggest-reopen mode: both types accepted
both_path="$TMPDIR/both.json"
write_entry_with_actions "$both_path" \
  '[{"type":"comment","issue_number":42,"body":"see new"},{"type":"reopen-suggestion","issue_number":99,"body":"closed but relevant"}]'
CROSS_LINK_MODE="suggest-reopen" validate_manifest "$both_path" 2>/dev/null
status=$?
assert_success "suggest-reopen mode accepts both types" "$status"

# Schema: unknown action type rejected
unknown_type="$TMPDIR/unknown-type.json"
write_entry_with_actions "$unknown_type" \
  '[{"type":"close","issue_number":42,"body":"x"}]'
CROSS_LINK_MODE="suggest-reopen" validate_manifest "$unknown_type" 2>"$TMPDIR/unknown.err"
status=$?
assert_failure "unknown action type rejected" "$status"
assert_contains "unknown-type error mentions invalid type" \
  "invalid type" "$(cat "$TMPDIR/unknown.err")"

# Schema: missing issue_number rejected
missing_num="$TMPDIR/missing-num.json"
write_entry_with_actions "$missing_num" \
  '[{"type":"comment","body":"see new evidence"}]'
CROSS_LINK_MODE="suggest-reopen" validate_manifest "$missing_num" 2>"$TMPDIR/missing-num.err"
status=$?
assert_failure "missing issue_number rejected" "$status"
assert_contains "missing-num error mentions issue_number" \
  "issue_number" "$(cat "$TMPDIR/missing-num.err")"

# Schema: empty body rejected
empty_body="$TMPDIR/empty-body.json"
write_entry_with_actions "$empty_body" \
  '[{"type":"comment","issue_number":42,"body":""}]'
CROSS_LINK_MODE="suggest-reopen" validate_manifest "$empty_body" 2>"$TMPDIR/empty-body.err"
status=$?
assert_failure "empty body rejected" "$status"
assert_contains "empty-body error mentions body" \
  "body" "$(cat "$TMPDIR/empty-body.err")"

# Schema: non-number issue_number rejected
bad_num="$TMPDIR/bad-num.json"
write_entry_with_actions "$bad_num" \
  '[{"type":"comment","issue_number":"forty-two","body":"x"}]'
CROSS_LINK_MODE="suggest-reopen" validate_manifest "$bad_num" 2>"$TMPDIR/bad-num.err"
status=$?
assert_failure "non-number issue_number rejected" "$status"

echo ""
echo "=== dispatch_filing_batch: cross-link enactment ==="

# shellcheck disable=SC1090
source "$LOGGING_LIB"
# shellcheck disable=SC1090
source "$PARALLEL_LIB"
# shellcheck disable=SC1090
source "$SCRIPT_DIR/lib/forge.sh"
# shellcheck disable=SC1090
source "$FILING_LIB"

# Stub the forge helpers. They record their args into log files and write a
# success/failure exit code controlled by the FORGE_STUB_BEHAVIOR env var.
forge_comment_log=""
forge_create_log=""
forge_issue_comment_once() {
  printf 'comment %s %s %s\n' "$1" "$2" "$3" >> "$forge_comment_log"
  local url="https://github.com/Example/Repo/${FORGE_STUB_COMMENT_PATH:-issues}/$2#issuecomment-1"
  jq -n --rawfile body "$3" --arg url "$url" '{body:$body,url:$url}' > "$TMPDIR/comment-readback.json"
  printf '%s\n' "$url"
  return "${FORGE_STUB_COMMENT_RC:-0}"
}
forge_issue_create_once() {
  printf 'create %s %s %s\n' "$1" "$2" "$3" >> "$forge_create_log"
  jq -n --arg title "$2" --rawfile body "$3" '{title:$title,body:$body,state:"open",url:"https://github.com/example/repo/issues/900"}' > "$TMPDIR/create-readback.json"
  printf 'https://github.com/example/repo/issues/900\n'
  shift 3
  for lbl in "$@"; do
    printf '  label=%s\n' "$lbl" >> "$forge_create_log"
  done
  return "${FORGE_STUB_CREATE_RC:-0}"
}

forge_filing_capable() { return 0; }
# No pre-existing open issues: the reopen-candidate dedup lookup (issue #412)
# never hits, so these scenarios keep exercising the one-shot create path.
forge_issue_list_json() { printf '[]\n'; }
forge_issue_number_from_url() { printf '900\n'; }
forge_issue_read_json() {
  if [[ "$2" == 900 ]]; then cat "$TMPDIR/create-readback.json";
  elif [[ "$2" == 99 ]]; then printf '{"state":"closed"}\n';
  else printf '{"state":"open"}\n'; fi
}
# Keep the real comment validator; stub only its external CLI readback.
FORGE_PROVIDER=gh FORGE_HOST=github.com
gh() {
  [[ "$*" == "issue view "*" -R example/repo --json comments" ]] || return 99
  jq '{comments:[.]}' "$TMPDIR/comment-readback.json"
}
PROJECT_PATH="$TMPDIR/evidence"
mkdir -p "$PROJECT_PATH"
printf 'verified source\n' > "$PROJECT_PATH/evidence.sh"

# Stub callback that immediately writes a .url marker.
test_stub_filing_callback() {
  local run_id="$1" cluster_id="$2"
  local log_base
  log_base="$(_filing_log_base "$run_id")"
  printf 'https://example.invalid/issues/%s\n' "$cluster_id" \
    > "$log_base/final/filed/$cluster_id.url"
  rm -f "$log_base/final/filed/$cluster_id.lock"
}

# Build a manifest with two clusters and three cross-link actions.
RUN_LOG="$TMPDIR/cross-link-run"
mkdir -p "$RUN_LOG/final/filed"
export LOG_BASE="$RUN_LOG"
export FORGE_REPO="example/repo"

cat > "$RUN_LOG/final/manifest.json" <<'JSON'
[
  {
    "cluster_id": "cluster-1",
    "title": "[high] Validate upload filenames before writing files",
    "severity": "high",
    "domain": "code",
    "lens": "input-validation",
    "root_cause_category": "missing-validation",
    "source_finding_paths": ["logs/run-1/rounds/round-1/lens-outputs/code/input-validation.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["bug"],
    "cross_link_actions": [
      { "type": "comment", "issue_number": 142, "body": "Round 1 reproduces issue #142.\nSee the new evidence." }
    ],
    "granularity": "independent",
    "body": "body alpha bravo charlie delta echo foxtrot golf hotel evidence.sh:1"
  },
  {
    "cluster_id": "cluster-2",
    "title": "[medium] Audit log redaction is incomplete",
    "severity": "medium",
    "domain": "logs",
    "lens": "audit-redaction",
    "root_cause_category": "logging-leak",
    "source_finding_paths": ["logs/run-1/rounds/round-2/lens-outputs/logs/audit-redaction.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["security"],
    "cross_link_actions": [
      { "type": "reopen-suggestion", "issue_number": 99, "body": "Closed issue #99 root cause has resurfaced." },
      { "type": "comment", "issue_number": 142, "body": "Duplicate hit from cluster-2 should de-dup." }
    ],
    "granularity": "independent",
    "body": "body kilo lima mike november oscar papa quebec romeo sierra evidence.sh:1"
  }
]
JSON

forge_comment_log="$TMPDIR/comment.log"
forge_create_log="$TMPDIR/create.log"
: > "$forge_comment_log"
: > "$forge_create_log"

export _FILING_AGENT_CALLBACK="test_stub_filing_callback"
export CROSS_LINK_MODE="suggest-reopen"

output="$(dispatch_filing_batch "cross-link-run" 2>"$TMPDIR/cross-link.err")"
status=$?
assert_success "dispatcher succeeds with cross-link actions" "$status"
assert_eq "aggregate counts include both filed clusters" \
  "Filed: 2, Verification-failed: 0, Skipped-existing: 0" "$output"

# forge_issue_comment should fire exactly once for #142 (de-duped across two
# clusters that both target the same issue).
comment_lines=$(wc -l < "$forge_comment_log" | tr -d ' ')
assert_eq "forge_issue_comment invoked exactly once (deduped)" \
  "1" "$comment_lines"
assert_contains "comment targets issue 142" "142" "$(cat "$forge_comment_log")"
assert_contains "comment uses FORGE_REPO" "example/repo" \
  "$(cat "$forge_comment_log")"

# forge_issue_create fired exactly once for the reopen-suggestion.
create_lines=$(grep -c '^create ' "$forge_create_log" || true)
assert_eq "forge_issue_create invoked once for reopen-suggestion" \
  "1" "$create_lines"
assert_contains "reopen-suggestion title carries reopen-candidate prefix" \
  "reopen-candidate" "$(cat "$forge_create_log")"
assert_contains "reopen-suggestion targets closed #99" \
  "99" "$(cat "$forge_create_log")"

# AC #13: label name must appear ONLY as a string inside the issue body —
# never as a `--label` flag passed to forge_issue_create. Verify the body file
# (3rd positional captured by the stub) contains the label string, and that
# the call site emitted no extra positional arguments after the body-file path.
create_body_file="$(awk '/^create /{print $NF; exit}' "$forge_create_log")"
assert_contains "reopen-suggestion body file path captured" \
  "$RUN_LOG" "$create_body_file"
assert_file_exists "reopen-suggestion body file exists on disk" \
  "$create_body_file"
if [[ -e "$create_body_file" ]]; then
  assert_contains "reopen-suggestion body embeds repolens:reopen-candidate label string" \
    "repolens:reopen-candidate" "$(cat "$create_body_file")"
fi

# Negative assertions: no `--label` CLI flag injected, and no 4th positional
# argument was recorded by the stub (the stub renders extras as `  label=…`).
if grep -q -- '--label' "$forge_create_log"; then
  fail_with "forge_issue_create called without --label flag" \
    "Found --label in $forge_create_log"
else
  TOTAL=$((TOTAL + 1))
  pass_with "forge_issue_create called without --label flag"
fi
if grep -q '^  label=' "$forge_create_log"; then
  fail_with "forge_issue_create receives no 4th positional argument" \
    "Found trailing positional label in $forge_create_log"
else
  TOTAL=$((TOTAL + 1))
  pass_with "forge_issue_create receives no 4th positional argument"
fi

# Sentinels: .done for each enacted action.
assert_file_exists "comment sentinel .done" \
  "$RUN_LOG/final/filed/cross-link/comment-142.done"
assert_file_exists "reopen-suggestion sentinel .done" \
  "$RUN_LOG/final/filed/cross-link/reopen-suggestion-99.done"

# Re-running the dispatcher must NOT re-invoke the stubs (idempotency).
: > "$forge_comment_log"
: > "$forge_create_log"
output2="$(dispatch_filing_batch "cross-link-run" 2>/dev/null)"
status=$?
assert_success "second dispatch exits 0" "$status"
comment_lines=$(wc -l < "$forge_comment_log" | tr -d ' ')
create_lines=$(grep -c '^create ' "$forge_create_log" || true)
assert_eq "comment NOT re-invoked on second run" "0" "$comment_lines"
assert_eq "create NOT re-invoked on second run" "0" "$create_lines"

unset LOG_BASE
unset _FILING_AGENT_CALLBACK
unset CROSS_LINK_MODE
unset FORGE_REPO

echo ""
echo "=== dispatch_filing_batch: cross-link failure is non-fatal ==="

RUN_LOG="$TMPDIR/cross-link-fail"
mkdir -p "$RUN_LOG/final/filed"
export LOG_BASE="$RUN_LOG"
export FORGE_REPO="example/repo"
export CROSS_LINK_MODE="comment"

cat > "$RUN_LOG/final/manifest.json" <<'JSON'
[
  {
    "cluster_id": "cluster-1",
    "title": "[high] Some independent issue title alpha",
    "severity": "high",
    "domain": "code",
    "lens": "input-validation",
    "root_cause_category": "missing-validation",
    "source_finding_paths": ["logs/run-1/rounds/round-1/lens-outputs/code/input-validation.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["bug"],
    "cross_link_actions": [
      { "type": "comment", "issue_number": 7, "body": "Round 1 evidence." }
    ],
    "granularity": "independent",
    "body": "body alpha bravo charlie delta echo foxtrot golf hotel evidence.sh:1"
  }
]
JSON

forge_comment_log="$TMPDIR/fail-comment.log"
: > "$forge_comment_log"

export _FILING_AGENT_CALLBACK="test_stub_filing_callback"
export FORGE_STUB_COMMENT_RC=1

output="$(dispatch_filing_batch "cross-link-fail" 2>"$TMPDIR/fail.err")"
status=$?
assert_success "dispatcher succeeds even when cross-link action fails" "$status"
assert_eq "aggregate counts unaffected by failed cross-link action" \
  "Filed: 1, Verification-failed: 0, Skipped-existing: 0" "$output"
assert_file_exists "failed cross-link sentinel written" \
  "$RUN_LOG/final/filed/cross-link/comment-7.failed"
assert_file_missing "no .done for failed action" \
  "$RUN_LOG/final/filed/cross-link/comment-7.done"

# A successful POST with a noncanonical path must fail real URL validation,
# even when the CLI fixture repeats precisely the same URL and body.
unset FORGE_STUB_COMMENT_RC
export FORGE_STUB_COMMENT_PATH=ISSUES
RUN_LOG="$TMPDIR/cross-link-invalid-path"
mkdir -p "$RUN_LOG/final/filed"
cp "$LOG_BASE/final/manifest.json" "$RUN_LOG/final/manifest.json"
export LOG_BASE="$RUN_LOG"
output="$(dispatch_filing_batch "cross-link-invalid-path" 2>"$TMPDIR/invalid-path.err")"
status=$?
assert_success "dispatcher continues after malformed comment URL" "$status"
assert_file_exists "malformed comment URL records failure" "$RUN_LOG/final/filed/cross-link/comment-7.failed"
assert_file_missing "malformed comment URL cannot record success" "$RUN_LOG/final/filed/cross-link/comment-7.done"
unset FORGE_STUB_COMMENT_PATH

unset LOG_BASE
unset FORGE_REPO
unset CROSS_LINK_MODE
unset FORGE_STUB_COMMENT_RC
unset _FILING_AGENT_CALLBACK

echo ""
echo "=== dispatch_filing_batch: off mode skips enactment entirely ==="

RUN_LOG="$TMPDIR/cross-link-off"
mkdir -p "$RUN_LOG/final/filed"
export LOG_BASE="$RUN_LOG"
export FORGE_REPO="example/repo"
export CROSS_LINK_MODE="off"

# Manifest with empty cross_link_actions (valid under off mode).
cat > "$RUN_LOG/final/manifest.json" <<'JSON'
[
  {
    "cluster_id": "cluster-1",
    "title": "[high] Some independent issue title bravo",
    "severity": "high",
    "domain": "code",
    "lens": "input-validation",
    "root_cause_category": "missing-validation",
    "source_finding_paths": ["logs/run-1/rounds/round-1/lens-outputs/code/input-validation.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["bug"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "body alpha bravo charlie delta echo foxtrot golf hotel evidence.sh:1"
  }
]
JSON

forge_comment_log="$TMPDIR/off-comment.log"
: > "$forge_comment_log"

export _FILING_AGENT_CALLBACK="test_stub_filing_callback"

output="$(dispatch_filing_batch "cross-link-off" 2>/dev/null)"
status=$?
assert_success "off-mode dispatcher succeeds" "$status"
comment_lines=$(wc -l < "$forge_comment_log" | tr -d ' ')
assert_eq "off mode never invokes forge_issue_comment" "0" "$comment_lines"
assert_file_missing "off-mode does not create cross-link sentinel dir" \
  "$RUN_LOG/final/filed/cross-link"

unset LOG_BASE
unset FORGE_REPO
unset CROSS_LINK_MODE
unset _FILING_AGENT_CALLBACK

echo ""
echo "=== Tripwire: no auto-reopen primitive ==="

# RepoLens MUST NEVER call a reopen API. Grep the libraries and base prompts
# for any reopen primitive — only documentation references in comments that
# explicitly forbid this are allowed; any actual `gh issue reopen`, etc.
TOTAL=$((TOTAL + 1))
violations=$(grep -rn -E '(gh|tea|fj)[[:space:]]+(issue[[:space:]]+)?reopen' \
  "$SCRIPT_DIR/lib" "$SCRIPT_DIR/prompts/_base" 2>/dev/null \
  | grep -vE '(MUST NOT|never|forbid|must never|do not|disallow)' || true)
if [[ -z "$violations" ]]; then
  pass_with "no auto-reopen primitive present in lib/ or prompts/_base/"
else
  fail_with "no auto-reopen primitive present in lib/ or prompts/_base/" \
    "Violations: $violations"
fi

finish
