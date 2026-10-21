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

# repolens-r18-p10-3: an operational body read must not retire valid findings.
# shellcheck disable=SC2034,SC2329
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/lib/filing.sh"
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
PROJECT_PATH="$FIXTURE/project" MODE=audit FORGE_REPO=acme/probe
mkdir -p "$PROJECT_PATH/src"
printf 'actual source\n' > "$PROJECT_PATH/src/probe.sh"
PASS=0 FAIL=0
check() {
  local description="$1"; shift
  if "$@"; then PASS=$((PASS + 1));
  else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$description"; fi
}
fault=none
# Fail exactly the verifier read, after real manifest selection/validation.
jq() {
  if [[ "$fault" != none && "${1:-}" == -r && "${2:-}" == '.body // empty' ]]; then
    [[ "$fault" != partial ]] || printf 'src/probe.sh:1\n'
    return 74
  fi
  command jq "$@"
}
forge_filing_capable() { return 0; }
forge_issue_list_json() { printf '[]\n'; }
forge_issue_create_once() {
  printf 'POST\n' >> "$LOG_BASE/posts"
  printf 'https://github.com/acme/probe/issues/17\n'
}
forge_issue_number_from_url() { printf '17\n'; }
forge_issue_read_json() {
  command jq '.[0] | {number:17,title,body,labels:.proposed_labels,state:"open",url:"https://github.com/acme/probe/issues/17"}' "$LOG_BASE/final/manifest.json"
}
entry='{"cluster_id":"c1","title":"Finding","body":"src/probe.sh:1","proposed_labels":[],"dedup_against_existing":[],"cross_link_actions":[]}'
for output in empty partial; do
  LOG_BASE="$FIXTURE/$output"
  mkdir -p "$LOG_BASE/final/filed"
  printf '[%s]\n' "$entry" > "$LOG_BASE/final/manifest.json"
  fault="$output" rc=0
  reason="$(filing_verify_cluster_citations "$PROJECT_PATH" "$entry")" || rc=$?
  check "$output body read is retryable" test "$rc" -eq 2
  check "$output body read has operational diagnostic" test "$reason" = 'could not read manifest entry body'
  # Exercise real governor reservation/verification, then retry the same cluster.
  printf 'owned\n' > "$LOG_BASE/final/filed/c1.lock"
  rc=0
  _filing_real_agent probe c1 > "$LOG_BASE/governor.log" 2>&1 || rc=$?
  check "$output governor returns retryable status" test "$rc" -eq 2
  check "$output governor sends no POST" test ! -e "$LOG_BASE/posts"
  for suffix in failed attempted url governor lock; do
    check "$output leaves no $suffix marker" test ! -e "$LOG_BASE/final/filed/c1.$suffix"
  done
  fault=none rc=0
  _filing_real_agent probe c1 > "$LOG_BASE/retry.log" 2>&1 || rc=$?
  check "$output repaired governor succeeds" test "$rc" -eq 0
  check "$output repaired governor writes receipt" test -s "$LOG_BASE/final/filed/c1.url"
  posts=0
  [[ ! -f "$LOG_BASE/posts" ]] || posts="$(wc -l < "$LOG_BASE/posts")"
  check "$output repaired governor posts once" test "$posts" -eq 1
  # A subsequent repeat reattests the receipt and must not create twice.
  rc=0
  _filing_real_agent probe c1 >> "$LOG_BASE/retry.log" 2>&1 || rc=$?
  check "$output successful repeat succeeds" test "$rc" -eq 0
  posts=0
  [[ ! -f "$LOG_BASE/posts" ]] || posts="$(wc -l < "$LOG_BASE/posts")"
  check "$output successful repeat does not post" test "$posts" -eq 1
done
fault=none rc=0
filing_verify_cluster_citations "$PROJECT_PATH" '{"body":""}' >/dev/null || rc=$?
check 'successfully read empty body remains semantic failure' test "$rc" -eq 1
printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
test "$FAIL" -eq 0
