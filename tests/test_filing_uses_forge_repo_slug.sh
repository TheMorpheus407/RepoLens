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

# Tests for issue #205: filing and synthesize callbacks must use the
# origin-derived FORGE_REPO target, not the local checkout basename fallback.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_LIB="$SCRIPT_DIR/lib/template.sh"
FORGE_LIB="$SCRIPT_DIR/lib/forge.sh"
FILING_LIB="$SCRIPT_DIR/lib/filing.sh"
SYNTHESIZE_LIB="$SCRIPT_DIR/lib/synthesize.sh"
REPOLENS_SH="$SCRIPT_DIR/repolens.sh"

PASS=0
FAIL=0
TOTAL=0

TMPROOT="$SCRIPT_DIR/tests/.tmp"
mkdir -p "$TMPROOT"
TMPDIR="$(mktemp -d "$TMPROOT/filing-forge-repo.XXXXXX")"
trap 'rm -rf "$TMPDIR"; rmdir "$TMPROOT" 2>/dev/null || true' EXIT

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

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Did not find '$needle'"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Did not expect '$needle'"
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

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

write_manifest() {
  local path="$1"
  cat > "$path" <<'JSON'
[
  {
    "cluster_id": "missing-validation::upload-handler",
    "title": "[high] Validate upload filenames before writing files",
    "severity": "high",
    "domain": "code",
    "lens": "input-validation",
    "root_cause_category": "missing-validation",
    "source_finding_paths": [
      "logs/issue-205/rounds/round-1/lens-outputs/code/input-validation.md"
    ],
    "dedup_against_existing": [],
    "proposed_labels": ["bug", "input-validation"],
    "cross_link_actions": [
      {
        "type": "comment",
        "issue_number": 42,
        "body": "Run issue-205 produced fresh evidence for this open issue."
      }
    ],
    "granularity": "independent",
    "verification_status": "verified",
    "body": "## Summary\nUpload filenames are not validated.\n\n## References\nlib/upload.sh:12"
  }
]
JSON
}

reset_issue_205_env() {
  RUN_ID="issue-205"
  CID="missing-validation::upload-handler"
  LOG_BASE="$TMPDIR/logs/$RUN_ID"
  PROJECT_PATH="$TMPDIR/local-dir"
  AGENT="stub-agent"
  REPO_OWNER="acme"
  REPO_NAME="local-dir"
  FORGE_REPO="acme/origin-repo"
  FORGE_PROVIDER="gh"
  FORGE_HOST="github.com"
  FORGE_PROJECT_PATH="$PROJECT_PATH"
  FORGE_REMOTE_NAME="origin"
  CROSS_LINK_MODE="comment"
  ROUNDS=1
  GRANULARITY_HINT="auto"

  export LOG_BASE PROJECT_PATH AGENT REPO_OWNER REPO_NAME FORGE_REPO
  export FORGE_PROVIDER FORGE_HOST FORGE_PROJECT_PATH FORGE_REMOTE_NAME
  export CROSS_LINK_MODE ROUNDS GRANULARITY_HINT

  rm -rf "$LOG_BASE" "$PROJECT_PATH"
  mkdir -p "$LOG_BASE/final/filed" \
    "$LOG_BASE/rounds/round-1/lens-outputs/code" \
    "$PROJECT_PATH"
  write_manifest "$LOG_BASE/final/manifest.json"
  mkdir -p "$PROJECT_PATH/lib"
  for (( line=1; line<=12; line++ )); do printf 'upload source\n'; done > "$PROJECT_PATH/lib/upload.sh"
  printf 'raw lens evidence\n' > "$LOG_BASE/rounds/round-1/lens-outputs/code/input-validation.md"
}

# shellcheck disable=SC1090
source "$TEMPLATE_LIB"
# shellcheck disable=SC1090
source "$FORGE_LIB"
# shellcheck disable=SC1090
source "$FILING_LIB"
# shellcheck disable=SC1090
source "$SYNTHESIZE_LIB"

run_agent() {
  local _agent="$1" prompt_text="$2" _project_path="$3"
  printf '%s\n' "$prompt_text" > "$TMPDIR/last-agent-prompt.md"
  if [[ -n "${RUN_AGENT_SENTINEL_CLUSTER:-}" ]]; then
    printf 'https://github.com/acme/origin-repo/issues/123\n' \
      > "$LOG_BASE/final/filed/$RUN_AGENT_SENTINEL_CLUSTER.url"
  fi
  printf '[]\n'
}

echo "=== issue #205: filing callbacks use FORGE_REPO ==="

entrypoint_repo_block="$(
  awk '
    /^# --- Derive repo metadata ---$/ { in_repo_block = 1 }
    /^# --- Resolve and validate forge provider ---$/ { in_repo_block = 0 }
    in_repo_block { print }
  ' "$REPOLENS_SH"
)"

ENTRYPOINT_PROJECT="$TMPDIR/local-dir-entrypoint"
mkdir -p "$ENTRYPOINT_PROJECT"
git -C "$ENTRYPOINT_PROJECT" init -q
git -C "$ENTRYPOINT_PROJECT" remote add origin "https://github.com/acme/origin-repo.git"

entrypoint_result="$(
  bash -c '
    set -uo pipefail
    source "$1"
    validate_agent() { :; }
    require_cmd() { :; }
    PROJECT_PATH="$2"
    AGENT="stub-agent"
    eval "$3"
    # Drain the export listing so pipefail cannot mistake SIGPIPE for no match.
    if export -p | grep "FORGE_REPO=" > /dev/null; then
      exported=yes
    else
      exported=no
    fi
    printf "FORGE_REPO_SLUG=%s\nFORGE_REPO=%s\nEXPORTED=%s\n" \
      "$FORGE_REPO_SLUG" "$FORGE_REPO" "$exported"
  ' bash "$FORGE_LIB" "$ENTRYPOINT_PROJECT" "$entrypoint_repo_block" 2>"$TMPDIR/entrypoint.err"
)"
status=$?
assert_success "repolens.sh repo metadata block completes for renamed checkout" "$status"
assert_contains "repolens.sh derives forge slug from origin remote" \
  "FORGE_REPO_SLUG=acme/origin-repo" "$entrypoint_result"
assert_contains "repolens.sh assigns FORGE_REPO from origin slug" \
  "FORGE_REPO=acme/origin-repo" "$entrypoint_result"
assert_contains "repolens.sh exports FORGE_REPO for callbacks" \
  "EXPORTED=yes" "$entrypoint_result"
assert_not_contains "repolens.sh exported target does not use checkout basename" \
  "FORGE_REPO=acme/local-dir-entrypoint" "$entrypoint_result"

forge_issue_list_json() { printf '%s\n' "$1" > "$TMPDIR/list-repo.txt"; printf '[]\n'; }
forge_label_create() { printf '%s\n' "$3" > "$TMPDIR/label-repo.txt"; }
forge_issue_create_once() {
  printf '%s\n' "$1" > "$TMPDIR/create-repo.txt"
  jq -n --arg title "$2" --rawfile body "$3" '{number:123,title:$title,body:$body,state:"open",labels:["bug","input-validation"],url:"https://github.com/acme/origin-repo/issues/123"}' > "$TMPDIR/created.json"
  printf 'https://github.com/acme/origin-repo/issues/123\n'
}
forge_issue_read_json() {
  if [[ "$2" == 42 ]]; then printf '{"state":"open"}\n'; else cat "$TMPDIR/created.json"; fi
}
reset_issue_205_env
_filing_real_agent "$RUN_ID" "$CID" >/dev/null 2>"$TMPDIR/filing.err"
status=$?
assert_success "deterministic filing completes after provider readback" "$status"
assert_eq "filing create targets origin slug" "acme/origin-repo" "$(cat "$TMPDIR/create-repo.txt")"
assert_eq "filing list targets origin slug" "acme/origin-repo" "$(cat "$TMPDIR/list-repo.txt")"
assert_eq "filing labels target origin slug" "acme/origin-repo" "$(cat "$TMPDIR/label-repo.txt")"
assert_not_contains "filing create does not target checkout basename" "acme/local-dir" "$(cat "$TMPDIR/create-repo.txt")"
assert_not_contains "filing list does not target checkout basename" "acme/local-dir" "$(cat "$TMPDIR/list-repo.txt")"

echo ""
echo "=== issue #205: cross-link enactment uses FORGE_REPO ==="

forge_issue_comment_once() {
  printf '%s\n' "$1" > "$TMPDIR/comment-repo.txt"
  printf '%s\n' "$2" > "$TMPDIR/comment-issue.txt"
  cat "$3" > "$TMPDIR/comment-body.md"
  printf 'https://github.com/acme/origin-repo/issues/42#issuecomment-1\n'
  return 0
}

forge_issue_comment_read_json() {
  jq -n --rawfile body "$TMPDIR/comment-body.md" --arg url "$3" '{body:$body,url:$url}'
}

reset_issue_205_env
printf 'https://github.com/acme/origin-repo/issues/123\n' > "$LOG_BASE/final/filed/$CID.url"
_filing_cross_link_enact "$RUN_ID" >/dev/null 2>"$TMPDIR/cross-link.err"
status=$?
assert_success "_filing_cross_link_enact completes" "$status"
assert_eq "cross-link comment targets origin slug" \
  "acme/origin-repo" "$(cat "$TMPDIR/comment-repo.txt")"
assert_eq "cross-link comment keeps issue number" "42" "$(cat "$TMPDIR/comment-issue.txt")"
assert_not_contains "cross-link comment does not target checkout basename" \
  "acme/local-dir" "$(cat "$TMPDIR/comment-repo.txt")"

echo ""
echo "=== issue #205: synthesizer issue-list command uses FORGE_REPO ==="

reset_issue_205_env
unset RUN_AGENT_SENTINEL_CLUSTER
run_synthesizer "$RUN_ID" >/dev/null 2>"$TMPDIR/synthesize.err"
status=$?
synth_prompt="$(cat "$TMPDIR/last-agent-prompt.md")"
assert_success "run_synthesizer accepts empty manifest from stub agent" "$status"
assert_contains "synthesizer issue-list command targets origin slug" \
  "gh issue list -R acme/origin-repo --state open" "$synth_prompt"
assert_not_contains "synthesizer issue-list command does not target checkout basename" \
  "gh issue list -R acme/local-dir" "$synth_prompt"

finish
