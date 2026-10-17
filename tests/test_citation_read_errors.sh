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

# repolens-r10-p1-1: failed source reads must never certify citations.
# shellcheck disable=SC2034 # Production filing consumes these globals.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO/lib/filing.sh"
set -euo pipefail
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
PROJECT_PATH="$FIXTURE/project" MODE=audit FORGE_REPO=acme/origin
LOG_BASE="$FIXTURE/run"
mkdir -p "$PROJECT_PATH/src" "$LOG_BASE/final"
printf 'return 0\n' > "$PROJECT_PATH/src/source.sh"
FAIL=0 PASS=0
check() {
  local desc="$1"; shift
  if "$@"; then PASS=$((PASS + 1))
  else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$desc"; fi
}
# Fail exactly the production read in question, optionally after partial output.
read_failure=none partial=false
wc() {
  if [[ "$read_failure" == wc ]]; then
    [[ "$partial" != true ]] || printf '1\n'
    return 42
  fi
  command wc "$@"
}
tail() {
  if [[ "$read_failure" == tail && "${!#}" == "$PROJECT_PATH/src/source.sh" ]]; then
    [[ "$partial" != true ]] || printf x
    return 42
  fi
  command tail "$@"
}
sed() {
  if [[ "$read_failure" == sed && "${!#}" == "$PROJECT_PATH/src/source.sh" ]]; then
    [[ "$partial" != true ]] || printf 'return 0\n'
    return 42
  fi
  command sed "$@"
}
entry='{"cluster_id":"c1","title":"Read failure","body":"src/source.sh:2","proposed_labels":[],"dedup_against_existing":[],"cross_link_actions":[]}'
rc=0
filing_verify_cluster_citations "$PROJECT_PATH" "$entry" > "$FIXTURE/control" || rc=$?
check 'ordinary nonexistent second line rejected' test "$rc" -ne 0
for read_failure in wc tail sed; do
  for partial in false true; do
    # Include a snippet only for the snippet-read test.
    body='src/source.sh:1'
    [[ "$read_failure" != sed ]] || body='src/source.sh:1 — `return 0`'
    probe="$(jq -cn --arg body "$body" '{body:$body}')"
    rc=0
    filing_verify_cluster_citations "$PROJECT_PATH" "$probe" > "$FIXTURE/error" || rc=$?
    check "$read_failure failure (partial=$partial) rejected" test "$rc" -ne 0
  done
done
# The credential-bearing governor must not POST or write a success receipt.
forge_filing_capable() { return 0; }
forge_issue_list_json() { printf '[]\n'; }
forge_issue_create_once() { printf 'POST\n' >> "$FIXTURE/posts"; return 99; }
read_failure=tail partial=false
printf '[%s]\n' "$entry" > "$LOG_BASE/final/manifest.json"
rc=0
_filing_real_agent probe c1 > "$FIXTURE/governor" 2>&1 || rc=$?
check 'governor rejects failed final-byte read' test "$rc" -ne 0
check 'governor sends no POST' test ! -e "$FIXTURE/posts"
check 'governor writes no success receipt' test ! -e "$LOG_BASE/final/filed/c1.url"
# Preserve valid newline-terminated and unterminated final lines, plus empties.
read_failure=none
for content in $'return 0\n' 'return 0' ''; do
  printf '%s' "$content" > "$PROJECT_PATH/src/source.sh"
  probe='{"body":"src/source.sh:1"}'
  rc=0
  filing_verify_cluster_citations "$PROJECT_PATH" "$probe" > "$FIXTURE/valid" || rc=$?
  if [[ -n "$content" ]]; then
    check 'existing final line verifies' test "$rc" -eq 0
  else
    check 'empty file has no first line' test "$rc" -ne 0
  fi
done
printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
test "$FAIL" -eq 0
