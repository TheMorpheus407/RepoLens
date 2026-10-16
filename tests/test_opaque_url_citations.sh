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

# repolens-r9-p1-1: URL bytes are opaque for all supported URI schemes.
# shellcheck disable=SC2034 # Filing consumes the fixture globals.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO/lib/filing.sh"
set -euo pipefail
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
PROJECT_PATH="$FIXTURE/project" MODE=audit CROSS_LINK_MODE=comment FORGE_REPO=acme/origin
mkdir -p "$PROJECT_PATH/src"
printf 'return 0\n' > "$PROJECT_PATH/src/a.sh"
# Allow the local adapter stubs without provider authentication.
forge_filing_capable() { return 0; }
# Supply an open target for the governed comment action.
forge_issue_read_json() { printf '{"number":9,"state":"open"}\n'; }
# Record each simulated POST and preserve its exact body for readback.
forge_issue_comment_once() {
  printf 'POST\n' >> "$LOG_BASE/posts"
  cp -- "$3" "$LOG_BASE/posted-body"
  printf 'https://github.com/acme/origin/issues/9#issuecomment-42\n'
}
# Return the recorded payload in the governor's structured readback format.
forge_issue_comment_read_json() {
  jq -cn --arg url "$3" --rawfile body "$LOG_BASE/posted-body" '{url:$url,body:$body}'
}
PASS=0 FAIL=0 case_index=0
# Count expected assertion failures without triggering errexit.
check() {
  local description="$1"; shift
  if "$@"; then PASS=$((PASS + 1))
  else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$description"; fi
}
for scheme in https HTTPS ssh git+ssh h9.test-1; do
  for delimiter in ',' ';'; do
    case_index=$((case_index + 1))
    LOG_BASE="$FIXTURE/$case_index"
    mkdir -p "$LOG_BASE/final"
    url="$scheme://example.test:443/path${delimiter}missing.sh:9"
    body="Source src/a.sh:1. See $url for the log."
    rc=0 references=''
    references="$(repolens_extract_citations "$body")" || rc=$?
    check "$scheme/$delimiter extractor succeeds" test "$rc" -eq 0
    check "$scheme/$delimiter only independent source anchor" test "$references" = src/a.sh:1
    entry="$(jq -cn --arg body "$body" '{body:$body}')"
    rc=0
    filing_verify_cluster_citations "$PROJECT_PATH" "$entry" > "$LOG_BASE/verify.log" || rc=$?
    check "$scheme/$delimiter parent evidence validates" test "$rc" -eq 0

    action_body="See $url for the log."
    jq -cn --arg body "$action_body" '[{cluster_id:"c1",body:"src/a.sh:1",cross_link_actions:[{type:"comment",issue_number:9,body:$body}]}]' > "$LOG_BASE/final/manifest.json"
    rc=0
    _filing_cross_link_enact url-probe || rc=$?
    posts=0
    if [[ -f "$LOG_BASE/posts" ]]; then posts="$(wc -l < "$LOG_BASE/posts")"; fi
    check "$scheme/$delimiter publication returns success" test "$rc" -eq 0
    check "$scheme/$delimiter exactly one comment posted" test "$posts" -eq 1
    posted=''
    if [[ -f "$LOG_BASE/posted-body" ]]; then posted="$(cat "$LOG_BASE/posted-body")"; fi
    check "$scheme/$delimiter URL preserved in posted body" test "$posted" = "$action_body"

    # URL contents cannot supply grounding even when their path names a real
    # existing source file; independent source evidence is still mandatory.
    entry="$(jq -cn --arg body "$scheme://example.test/path${delimiter}src/a.sh:1" '{body:$body}')"
    rc=0
    filing_verify_cluster_citations "$PROJECT_PATH" "$entry" > "$LOG_BASE/url-only.log" || rc=$?
    check "$scheme/$delimiter opaque bytes are not independent evidence" test "$rc" -eq 1

    # Masked URL lengths must preserve the following citation's source offsets.
    # A citation-shaped URL tail also must not steal the preceding citation's
    # snippet or let mismatched evidence escape verification.
    body="$url src/a.sh:1 — \`return 0\`"
    rc=0 snippets=''
    snippets="$(repolens_citation_snippets "$body" src/a.sh:1)" || rc=$?
    check "$scheme/$delimiter snippet scan succeeds after URL" test "$rc" -eq 0
    check "$scheme/$delimiter snippet offsets survive URL masking" test "$snippets" = 'return 0'
    entry="$(jq -cn --arg body "$body" '{body:$body}')"
    rc=0
    filing_verify_cluster_citations "$PROJECT_PATH" "$entry" > "$LOG_BASE/snippet.log" || rc=$?
    check "$scheme/$delimiter source and snippet after URL validate" test "$rc" -eq 0

    body="src/a.sh:1 $url — \`return 999\`"
    entry="$(jq -cn --arg body "$body" '{body:$body}')"
    rc=0 reason=''
    reason="$(filing_verify_cluster_citations "$PROJECT_PATH" "$entry")" || rc=$?
    check "$scheme/$delimiter URL cannot hide a mismatched snippet" test "$rc" -eq 1
    check "$scheme/$delimiter mismatch names the independent citation" test "$reason" = \
      'src/a.sh:1 snippet not found near cited line'
  done
done
# Keep rejecting genuinely malformed citation lists, even alongside a valid
# independent anchor. This fix must not disable list validation generally.
rc=0
repolens_extract_citations 'src/a.sh:1 prose,missing.sh:9' > "$FIXTURE/malformed.log" || rc=$?
check 'malformed non-URL list still rejected' test "$rc" -ne 0
printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
test "$FAIL" -eq 0
