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

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
# shellcheck source=lib/core.sh
source "$SCRIPT_DIR/lib/core.sh"
# shellcheck source=lib/forge.sh
source "$SCRIPT_DIR/lib/forge.sh"
# shellcheck source=lib/filing.sh
source "$SCRIPT_DIR/lib/filing.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0 FAIL=0
check() {
  local description="$1"; shift
  if "$@"; then PASS=$((PASS + 1)); echo "  PASS: $description";
  else FAIL=$((FAIL + 1)); echo "  FAIL: $description"; fi
}
# Use the real governor and typed adapters. Only the external CLI is stubbed.
# Any accidental LLM invocation fails visibly and cannot touch a real model.
run_agent() { : > "$TMP/model-called"; return 99; }
gh() {
  local command="$1 ${2:-}"; shift 2
  printf '%s\n' "$command" >> "$TMP/calls"
  printf '%s\n' "${GH_HOST:-unset}" >> "$TMP/hosts"
  case "$command" in
    'label create') return 0 ;;
    'issue list')
      [[ "$FAULT" == list-failed ]] && return 1
      [[ "$FAULT" == bad-list ]] && { printf '{}\n'; return 0; }
      cat "$TMP/issues.json" ;;
    'issue create')
      local title='' body_file='' label repo='' stub_labels_json='[]'
      while (( $# )); do
        case "$1" in
          --title) title="$2"; shift 2 ;;
          --body-file) body_file="$2"; shift 2 ;;
          -R) repo="$2"; shift 2 ;;
          --label) label="$2"; stub_labels_json="$(jq -c --arg label "$label" '. + [$label]' <<< "$stub_labels_json")"; shift 2 ;;
          *) return 99 ;;
        esac
      done
      jq -n --arg title "$title" --rawfile body "$body_file" --argjson labels "$stub_labels_json" \
        --arg url "https://github.com/$repo/issues/17" \
        '{number:17,title:$title,body:$body,labels:$labels,url:$url,state:"OPEN"}' > "$TMP/created.json"
      [[ "$FAULT" == create-failed ]] && return 1
      if [[ "$FAULT" == wrong-url ]]; then printf 'https://evil.invalid/steal/issues/17\n';
      else jq -r '.url' "$TMP/created.json"; fi ;;
    'issue comment')
      local issue_number="$1" body_file=''; shift
      while (( $# )); do
        case "$1" in
          --body-file) body_file="$2"; shift 2 ;;
          -R) shift 2 ;;
          *) return 99 ;;
        esac
      done
      jq -n --rawfile body "$body_file" --arg url "https://github.com/acme/origin/issues/$issue_number#issuecomment-42" \
        '{body:$body,url:$url}' > "$TMP/comment.json"
      jq -r '.url' "$TMP/comment.json" ;;
    'issue view')
      if [[ "$*" == *'--json comments'* ]]; then
        if [[ "$FAULT" == wrong-comment ]]; then jq '{comments:[. + {body:"changed"}]}' "$TMP/comment.json";
        else jq '{comments:[.]}' "$TMP/comment.json"; fi
        return 0
      fi
      if [[ "$1" == 9 ]]; then printf '{"number":9,"title":"existing","body":"prior","state":"OPEN","labels":[],"url":"https://github.com/acme/origin/issues/9"}\n'; return 0; fi
      [[ "$FAULT" == read-failed ]] && return 1
      case "$FAULT" in
        wrong-body) jq '.body="mismatched"' "$TMP/created.json" ;;
        wrong-labels) jq '.labels=[]' "$TMP/created.json" ;;
        wrong-number) jq '.number=18' "$TMP/created.json" ;;
        *) cat "$TMP/created.json" ;;
      esac ;;
    *) return 99 ;;
  esac
}
fresh() {
  rm -rf "$TMP/run"
  LOG_BASE="$TMP/run" PROJECT_PATH="$TMP/project"
  FORGE_REPO='acme/origin' REPO_NAME='wrong-checkout-name' FORGE_PROVIDER=gh FORGE_HOST=github.com
  MODE=audit FAULT=''
  unset REPOLENS_MODE
  mkdir -p "$LOG_BASE/final/filed" "$PROJECT_PATH/src"
  printf 'return 0\n' > "$PROJECT_PATH/src/a.sh"
  printf '[]\n' > "$TMP/issues.json"
  : > "$TMP/calls"
  : > "$TMP/hosts"
  jq -n '[{cluster_id:"test::cluster", title:"[high] fix literal $(touch /tmp/never-evaluate)",
    body:"src/a.sh:1 — `return 0`", proposed_labels:["bug"],dedup_against_existing:[],cross_link_actions:[]}]' > "$LOG_BASE/final/manifest.json"
}
run() { _filing_real_agent run 'test::cluster' > "$TMP/stdout" 2> "$TMP/stderr"; }
no_create() { ! grep -q '^issue create$' "$TMP/calls"; }
failed() { [[ -f "$LOG_BASE/final/filed/test::cluster.failed" && ! -e "$LOG_BASE/final/filed/test::cluster.url" ]]; }
set_body() {
  jq --arg body "$1" '.[0].body=$body' "$LOG_BASE/final/manifest.json" > "$TMP/change.json"
  mv "$TMP/change.json" "$LOG_BASE/final/manifest.json"
}

fresh
check 'real default callback files a verified request' run
check 'default callback never runs a model' test ! -e "$TMP/model-called"
check 'success marker follows structured readback' test -s "$LOG_BASE/final/filed/test::cluster.readback.json"
check 'origin repo and exact payload survive provider round trip' jq -e '.url=="https://github.com/acme/origin/issues/17" and .title=="[high] fix literal $(touch /tmp/never-evaluate)" and .body=="src/a.sh:1 — `return 0`"' "$TMP/created.json"
check 'second direct callback is idempotent' run
check 'only one create across repeated default callbacks' test "$(grep -c '^issue create$' "$TMP/calls")" = 1


fresh
GH_HOST=untrusted.example
check 'configured GitHub host overrides ambient GH_HOST' run
check 'all typed calls and governed labels bind configured host before mutation' test "$(sort -u "$TMP/hosts")" = github.com
unset GH_HOST
fresh
set_body 'src/a.sh:1 observed at 12:30 and https://example.org:8443/status plus `http://127.0.0.1:8080` and `12:30` and `12:30:45`'
check 'timestamps and URL ports are not mistaken for citations' run
fresh
cp "$PROJECT_PATH/src/a.sh" "$PROJECT_PATH/src/with spaces.sh"
set_body '`src/with spaces.sh:1` — `return 0`'
check 'quoted citations support spaces in source paths' run

fresh
printf 'https://github.com/acme/origin/issues/17\n' > "$LOG_BASE/final/filed/test::cluster.url"
run || true
check 'default callback rejects an unattested legacy success marker' failed
check 'unattested marker is kept for reconciliation' test -f "$LOG_BASE/final/filed/test::cluster.unverified-url"
check 'unattested marker never causes a replacement POST' no_create
# Exercise the dispatcher without a replacement filing callback.
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/parallel.sh"
fresh
printf 'https://github.com/acme/origin/issues/17\n' > "$LOG_BASE/final/filed/test::cluster.url"
result="$(dispatch_filing_batch run 2> "$TMP/stderr")"
check 'dispatcher never reports a forged old URL as skipped success' test "$result" = 'Filed: 0, Verification-failed: 1, Skipped-existing: 0'
check 'dispatcher does not repost after rejecting old marker' no_create
fresh
run || true
FAULT=wrong-body
run || true
check 'previously attested success requires a fresh matching readback' failed
check 'changed remote body cannot cause duplicate POST' test "$(grep -c '^issue create$' "$TMP/calls")" = 1


for invalid_title in '"bad\nmultiline"' '"bad\u0000title"'; do
  fresh
  jq --argjson title "$invalid_title" '.[0].title=$title' "$LOG_BASE/final/manifest.json" > "$TMP/change.json"
  mv "$TMP/change.json" "$LOG_BASE/final/manifest.json"
  run || true
  check 'invalid title fails before any provider mutation' test ! -s "$TMP/calls"
  check 'invalid title records diagnostic' failed
done
fresh
jq -n '[{number:9,title:"[high] fix literal $(touch /tmp/never-evaluate)",body:"existing",state:"CLOSED",url:"https://github.com/acme/origin/issues/9",labels:[]}]' > "$TMP/issues.json"
run || true
check 'closed issue in an open-list response is never a terminal dedup success' failed
check 'invalid provider list state causes zero mutations' no_create
for body in 'src/missing.sh:1' 'src/a.sh:999' 'src/a.sh:1 — `phantom`' '../outside.sh:1' '/etc/passwd:1' 'src/a.sh:99999999999999999999999' 'no citations'; do
  fresh
  set_body "$body"
  run || true
  check "unverified body gets a failure marker: $body" failed
  check "unverified body never reaches create: $body" no_create
done
fresh
ln -s "$PROJECT_PATH/src/a.sh" "$PROJECT_PATH/link.sh"
set_body 'link.sh:1'
run || true
check 'symlink citation never reaches create' no_create
fresh
set_body '`src/a.sh:01` — `return 0`'
check 'backtick citations and decimal leading-zero lines verify' run

for FAULT_VALUE in list-failed bad-list create-failed wrong-url read-failed wrong-body wrong-labels wrong-number; do
  fresh
  FAULT="$FAULT_VALUE"
  run || true
  check "provider anomaly fails closed: $FAULT_VALUE" failed
  if [[ "$FAULT_VALUE" == list-failed || "$FAULT_VALUE" == bad-list ]]; then
    check "failed dedup causes zero creates: $FAULT_VALUE" no_create
  else
    rm -f "$LOG_BASE/final/filed/test::cluster.failed"
    FAULT=''
    run || true
    check "ambiguous POST never retried after removing failure: $FAULT_VALUE" test "$(grep -c '^issue create$' "$TMP/calls")" = 1
  fi
done
fresh
jq '[{number:9,title:"[high] fix literal $(touch /tmp/never-evaluate)",body:"existing",state:"OPEN",url:"https://github.com/acme/origin/issues/9",labels:[]}]' -n > "$TMP/issues.json"
check 'fresh duplicate is terminal without a new issue' run
check 'fresh duplicate never reaches create' no_create
check 'dedup marker identifies existing issue' grep -q '^DEDUP_HIT: #9$' "$LOG_BASE/final/filed/test::cluster.failed"
fresh
FORGE_PROVIDER=fj
run || true
check 'unsupported structured adapter fails before any mutation' test ! -s "$TMP/calls"
check 'unsupported adapter records diagnostic' failed

fresh
MODE=branch-review
BRANCH_SCOPE_FILE="$TMP/scope.json"
printf '["src/changed.sh"]\n' > "$BRANCH_SCOPE_FILE"
run || true
check 'final governor rejects out-of-scope valid citations' no_create
check 'out-of-scope cluster records failure' failed
fresh
MODE=branch-review
printf '["src/a.sh"]\n' > "$BRANCH_SCOPE_FILE"
check 'final governor allows scoped verified body' run


for FAULT_VALUE in valid wrong-comment stale-evidence; do
  fresh
  CROSS_LINK_MODE=comment
  jq '.[0].cross_link_actions=[{type:"comment",issue_number:9,body:"Fresh verified evidence at `12:30`. Literal \\n and tab\t plus CR\r\n\n"}]' "$LOG_BASE/final/manifest.json" > "$TMP/change.json"
  mv "$TMP/change.json" "$LOG_BASE/final/manifest.json"
  FAULT="$FAULT_VALUE"
  [[ "$FAULT" == stale-evidence ]] && set_body 'src/missing.sh:1'
  _filing_cross_link_enact run > "$TMP/stdout" 2> "$TMP/stderr"
  if [[ "$FAULT" == valid ]]; then
    check 'comment success requires exact structured body readback' test -f "$LOG_BASE/final/filed/cross-link/comment-9.done"
    check 'published comment preserves the original proposed JSON body exactly' jq -e --slurpfile manifest "$LOG_BASE/final/manifest.json" '.body == $manifest[0][0].cross_link_actions[0].body' "$TMP/comment.json"
  else
    check "cross-link anomaly records terminal failure: $FAULT" test -f "$LOG_BASE/final/filed/cross-link/comment-9.failed"
    check "cross-link anomaly cannot produce success: $FAULT" test ! -e "$LOG_BASE/final/filed/cross-link/comment-9.done"
  fi
  if [[ "$FAULT" == stale-evidence ]]; then
    check 'stale cross-link parent evidence causes zero comments' test "$(grep -c '^issue comment$' "$TMP/calls")" = 0
  else
    rm -f "$LOG_BASE/final/filed/cross-link/comment-9.failed"
    _filing_cross_link_enact run > "$TMP/stdout" 2> "$TMP/stderr"
    check 'cross-link reservation prevents repeat comments' test "$(grep -c '^issue comment$' "$TMP/calls")" = 1
  fi
done


fresh
CROSS_LINK_MODE=comment
jq '.[0].cross_link_actions=[{type:"comment",issue_number:9,body:"Fresh evidence."}]' "$LOG_BASE/final/manifest.json" > "$TMP/change.json"
mv "$TMP/change.json" "$LOG_BASE/final/manifest.json"
mkdir -p "$LOG_BASE/final/filed/cross-link"
: > "$LOG_BASE/final/filed/cross-link/comment-9.done"
_filing_cross_link_enact run > "$TMP/stdout" 2> "$TMP/stderr"
check 'unattested cross-link success is quarantined' test -f "$LOG_BASE/final/filed/cross-link/comment-9.unverified-done"
check 'unattested cross-link cannot remain successful' test ! -e "$LOG_BASE/final/filed/cross-link/comment-9.done"
check 'unattested cross-link never triggers a replacement comment' test "$(grep -c '^issue comment$' "$TMP/calls")" = 0
fresh
CROSS_LINK_MODE=comment
jq '.[0].cross_link_actions=[{type:"comment",issue_number:9,body:"bad\u0000body"}]' "$LOG_BASE/final/manifest.json" > "$TMP/change.json"
mv "$TMP/change.json" "$LOG_BASE/final/manifest.json"
_filing_cross_link_enact run > "$TMP/stdout" 2> "$TMP/stderr"
check 'NUL cross-link payload is rejected before provider calls' test ! -s "$TMP/calls"
check 'NUL cross-link payload records terminal failure' test -f "$LOG_BASE/final/filed/cross-link/comment-9.failed"

# The tea adapter uses authenticated raw API JSON; its display output has
# flattened label names and is not a reliable readback contract.
tea() {
  [[ "$1" == api ]] || return 99
  local endpoint="${!#}"
  printf '%s\n' "$endpoint" >> "$TMP/tea-calls"
  case "$endpoint" in
    *'/labels?limit=50&page=1') printf '[{"id":5,"name":"bug"},{"id":7,"name":"needs review"}]\n' ;;
    *'/labels?limit=50&page=2') printf '[]\n' ;;
    *'/issues?state=open&type=issues&limit=50&page=1') cat "$TMP/tea-issues.json" ;;
    *'/issues?state=open&type=issues&limit=50&page=2') printf '[]\n' ;;
    'repos/acme/origin/issues/17') jq '.[0]' "$TMP/tea-issues.json" ;;
    'repos/acme/origin/issues')
      [[ "$*" == *'--method POST --data @-'* ]] || return 99
      cat > "$TMP/tea-post.json"
      printf '{"html_url":"https://tea.example/acme/origin/issues/17"}\n' ;;
    *) return 99 ;;
  esac
}
fresh
FORGE_PROVIDER=tea FORGE_HOST=tea.example FORGE_TEA_LOGIN=work
unset FORGE_PROJECT_PATH
printf '[{"number":17,"title":"hello","body":"exact body","state":"open","url":"https://tea.example/api/v1/repos/acme/origin/issues/17","html_url":"https://tea.example/acme/origin/issues/17","labels":[{"name":"bug"},{"name":"needs review"}]}]\n' > "$TMP/tea-issues.json"
check 'tea paginates and normalizes typed issue data' forge_issue_list_json acme/origin open
check 'tea reads a specific issue as a structured object' forge_issue_read_json acme/origin 17
printf 'body with `literal`\n' > "$TMP/tea-body.md"
check 'tea sends one typed create without CLI display parsing' forge_issue_create_once acme/origin hello "$TMP/tea-body.md" bug 'needs review'
check 'tea maps exact label names to numeric IDs and preserves body bytes' jq -e '.labels==[5,7] and .body=="body with `literal`\n"' "$TMP/tea-post.json"
check 'tea performs exactly one POST' test "$(grep -c '^repos/acme/origin/issues$' "$TMP/tea-calls")" = 1
FORGE_PROVIDER=tea FORGE_HOST=https://tea.example/git
check 'tea URL binding preserves configured secure instance base path' test "$(forge_issue_number_from_url acme/origin https://tea.example/git/acme/origin/issues/17)" = 17
echo "Results: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
