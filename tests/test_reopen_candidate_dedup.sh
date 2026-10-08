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

# Tests for issue #412: a suggest-reopen run must not file a second
# "[reopen-candidate] consider re-opening #N" issue when an open issue with
# that exact title already exists. Before reserving new-issue budget or
# POSTing, the reopen path must run a fresh, complete exact-title dedup lookup
# against open issues in the configured repository. A hit suppresses the
# create without charging MAX_ISSUES and without claiming the existing issue
# as newly created; a lookup failure or malformed result fails closed. With
# no hit, the one-shot create plus exact readback stays, and an ambiguous
# POST is never retried on resume.
#
# The forge is stubbed at the `gh` CLI layer over a shared issues.json file,
# so the real typed adapters (forge_issue_list_json / forge_issue_create_once
# / forge_issue_read_json) and their fail-closed normalization stay under
# test. No forge, model, or network is contacted.

# shellcheck disable=SC2034 # Test globals are consumed by sourced modules.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090
source "$SCRIPT_DIR/lib/forge.sh"
# shellcheck disable=SC1090
source "$SCRIPT_DIR/lib/filing.sh"

PASS=0
FAIL=0
check() {
  local description="$1"; shift
  if "$@"; then
    PASS=$((PASS + 1))
    printf 'PASS: %s\n' "$description"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n' "$description"
  fi
}

FIXTURE="$(mktemp -d /tmp/repolens-reopen-dedup.XXXXXXXX)"
trap 'rm -rf "$FIXTURE"' EXIT

PROJECT_PATH="$FIXTURE/project"
mkdir -p "$PROJECT_PATH/src"
printf 'return 0\n' > "$PROJECT_PATH/src/a.sh"
FORGE_PROVIDER=gh FORGE_HOST=github.com FORGE_REPO=acme/origin
MODE=bugreport CROSS_LINK_MODE=suggest-reopen
# shellcheck disable=SC2329 # Guard against accidental model invocation.
run_agent() { touch "$FIXTURE/model-called"; return 99; }

STUB_ISSUES="$FIXTURE/issues.json"
STUB_CALLS=''
STUB_LIST_RC=0
STUB_LIST_PAYLOAD=''
STUB_AMBIGUOUS=0

# In-memory forge: all state lives in $STUB_ISSUES so consecutive runs share
# it exactly like a real remote. Every CLI call is traced to $STUB_CALLS.
gh() {
  printf '%s\n' "$*" >> "$STUB_CALLS"
  case "$1 ${2:-}" in
    'issue list')
      (( STUB_LIST_RC == 0 )) || return "$STUB_LIST_RC"
      if [[ -n "$STUB_LIST_PAYLOAD" ]]; then
        printf '%s\n' "$STUB_LIST_PAYLOAD"
      else
        jq '[.[] | select(.state == "OPEN")]' "$STUB_ISSUES"
      fi ;;
    'issue create')
      shift 2
      local title='' body_file='' number
      while (( $# )); do
        case "$1" in
          --title) title="$2"; shift 2 ;;
          --body-file) body_file="$2"; shift 2 ;;
          --label) shift 2 ;;
          -R) shift 2 ;;
          *) return 99 ;;
        esac
      done
      number="$(jq '[.[].number] | max + 1' "$STUB_ISSUES")"
      jq --arg title "$title" --rawfile body "$body_file" --argjson number "$number" \
        '. + [{number:$number,title:$title,body:$body,labels:[],
               url:("https://github.com/acme/origin/issues/" + ($number | tostring)),state:"OPEN"}]' \
        "$STUB_ISSUES" > "$STUB_ISSUES.new"
      mv "$STUB_ISSUES.new" "$STUB_ISSUES"
      # Ambiguous POST: the issue lands remotely but the client sees a
      # transport failure. The governor must never retry it.
      if (( STUB_AMBIGUOUS )) && [[ "$title" == '[reopen-candidate]'* ]]; then
        return 1
      fi
      jq -r 'last.url' "$STUB_ISSUES" ;;
    'issue view')
      jq --argjson n "$3" '.[] | select(.number == $n)' "$STUB_ISSUES" ;;
    'issue comment')
      shift 2
      local target="$1" comment_file='' comment_url
      shift
      while (( $# )); do
        case "$1" in
          --body-file) comment_file="$2"; shift 2 ;;
          -R) shift 2 ;;
          *) return 99 ;;
        esac
      done
      comment_url="https://github.com/acme/origin/issues/$target#issuecomment-1"
      jq --argjson n "$target" --arg url "$comment_url" --rawfile body "$comment_file" \
        '(.[] | select(.number == $n)).comments += [{url:$url, body:$body}]' \
        "$STUB_ISSUES" > "$STUB_ISSUES.new"
      mv "$STUB_ISSUES.new" "$STUB_ISSUES"
      printf '%s\n' "$comment_url" ;;
    'label create') return 0 ;;
    *) return 99 ;;
  esac
}

REOPEN_TITLE='[reopen-candidate] consider re-opening #9'
RUN_LOG=''
XL_KEY=''

new_run() {
  local name="$1" parent_title="$2"
  local action_body="${3:-The new evidence warrants reconsidering the old issue.}"
  RUN_LOG="$FIXTURE/$name"
  mkdir -p "$RUN_LOG/final"
  jq -n --arg title "$parent_title" --arg abody "$action_body" \
    '[{cluster_id:"cluster",title:$title,body:"src/a.sh:1",proposed_labels:[],
       dedup_against_existing:[],
       cross_link_actions:[{type:"reopen-suggestion",issue_number:9,body:$abody}]}]' \
    > "$RUN_LOG/final/manifest.json"
  LOG_BASE="$RUN_LOG"
  STUB_CALLS="$FIXTURE/$name.calls"
  : > "$STUB_CALLS"
  XL_KEY="$RUN_LOG/final/filed/cross-link/reopen-suggestion-9"
}

seed_closed_9() {
  jq -n '[{number:9,title:"Old issue",body:"old",labels:[],
            url:"https://github.com/acme/origin/issues/9",state:"CLOSED"}]' > "$STUB_ISSUES"
}

add_open_candidate_17() {
  jq --arg title "$REOPEN_TITLE" \
    '. + [{number:17,title:$title,body:"Existing reopen candidate from prior run",labels:[],
           url:"https://github.com/acme/origin/issues/17",state:"OPEN"}]' \
    "$STUB_ISSUES" > "$STUB_ISSUES.tmp"
  mv "$STUB_ISSUES.tmp" "$STUB_ISSUES"
}

candidate_count() {
  jq --arg title "$REOPEN_TITLE" '[.[] | select(.title == $title)] | length' "$STUB_ISSUES"
}

open_candidate_count() {
  jq --arg title "$REOPEN_TITLE" '[.[] | select(.title == $title and .state == "OPEN")] | length' "$STUB_ISSUES"
}

# Count literal title fragments only in create traces; an absent match prints zero.
creates_for() { grep '^issue create ' "$STUB_CALLS" | grep -Fc -- "$1" || true; }
# Count all creation attempts, including those with an ambiguous response.
total_creates() { grep -c 'issue create ' "$STUB_CALLS" || true; }
# Require both a saved marker and its expected literal diagnostic.
file_contains() { [[ -f "$1" ]] && grep -qF -- "$2" "$1"; }

# The dedup lookup must be fresh and run inside the cross-link phase: the last
# issue-list request in the trace comes after the reopen target was read.
fresh_lookup_after_target_read() {
  local last_list first_view
  last_list="$(grep -n '^issue list ' "$STUB_CALLS" | tail -1 | cut -d: -f1 || true)"
  first_view="$(grep -n '^issue view 9 ' "$STUB_CALLS" | head -1 | cut -d: -f1 || true)"
  [[ -n "$last_list" && -n "$first_view" ]] && (( last_list > first_view ))
}

# A parent-phase listing cannot serve as the cross-link snapshot, even if
# it was fetched moments earlier in the same run.
fresh_lookup_after_parent_phase() {
  local first_list parent_list
  parent_list="$(head -n "$PARENT_TRACE_END" "$STUB_CALLS" | grep -n '^issue list ' | head -1 | cut -d: -f1 || true)"
  first_list="$(awk -v boundary="$PARENT_TRACE_END" 'NR > boundary && /^issue list / { print NR; exit }' "$STUB_CALLS")"
  [[ -n "$parent_list" && -n "$first_list" ]] && (( first_list > PARENT_TRACE_END ))
}

# Add a distinct closed target to the same enact pass. The issue registry
# remains shared with the real typed adapters and create/readback path.
add_second_reopen_action() {
  jq '.[0].cross_link_actions += [{type:"reopen-suggestion",issue_number:10,
       body:"The second closed issue also warrants reconsideration."}]' \
    "$RUN_LOG/final/manifest.json" > "$RUN_LOG/final/manifest.tmp"
  mv "$RUN_LOG/final/manifest.tmp" "$RUN_LOG/final/manifest.json"
  jq '. + [{number:10,title:"Second old issue",body:"old",labels:[],
       url:"https://github.com/acme/origin/issues/10",state:"CLOSED"}]' \
    "$STUB_ISSUES" > "$STUB_ISSUES.tmp"
  mv "$STUB_ISSUES.tmp" "$STUB_ISSUES"
}

# The dedup lookup's request is part of the contract: it must bind to the
# configured repository and scope to open issues, not just return any list.
last_lookup_binds_configured_repo() {
  grep '^issue list ' "$STUB_CALLS" | tail -1 | grep -q -- '-R acme/origin '
}

# A successful stub response alone cannot prove that the request scoped to open issues.
last_lookup_scopes_open_issues() {
  grep '^issue list ' "$STUB_CALLS" | tail -1 | grep -q -- '--state open '
}

echo '=== create counting treats bracketed titles literally ==='

STUB_CALLS="$FIXTURE/literal-count.calls"
printf '%s\n' "issue create -R acme/origin --title $REOPEN_TITLE --body-file body.md" > "$STUB_CALLS"
check 'create counter finds the full bracketed title' test "$(creates_for "$REOPEN_TITLE")" = 1
printf '%s\n' \
  'issue create -R acme/origin --title r consider re-opening #9 --body-file body.md' \
  "issue view 17 --title $REOPEN_TITLE" > "$STUB_CALLS"
check 'create counter excludes regex near-matches and non-create lines' test "$(creates_for "$REOPEN_TITLE")" = 0
check 'create counter returns zero for an absent literal title' test "$(creates_for '[missing]')" = 0

echo '=== existing open candidate: fresh exact-title dedup suppresses the POST ==='

new_run run-existing 'A distinct newly found regression'
seed_closed_9
_filing_real_agent run-existing cluster > "$RUN_LOG/primary.log" 2>&1
primary_rc=$?
PARENT_TRACE_END="$(wc -l < "$STUB_CALLS")"
# Another actor files the candidate after the parent governor's own lookup.
add_open_candidate_17
_filing_cross_link_enact run-existing > "$RUN_LOG/cross-link.log" 2>&1
xl_rc=$?
check 'primary governor files the independently titled parent' test "$primary_rc" -eq 0
check 'cross-link enact stays best-effort green' test "$xl_rc" -eq 0
check 'reopen-candidate count stays at one' test "$(candidate_count)" = 1
check 'no create request for the existing candidate title' test "$(creates_for reopen-candidate)" = 0
check 'parent issue is still filed' test -f "$RUN_LOG/final/filed/cluster.url"
check 'only the parent issue was created' test "$(total_creates)" = 1
check 'existing candidate is recorded as a dedup hit' file_contains "$XL_KEY.failed" 'DEDUP_HIT: #17'
check 'existing candidate is not claimed as created' test ! -e "$XL_KEY.done"
check 'no created-response appropriates the existing issue' test ! -e "$XL_KEY.created-response"
check 'suppressed action never reserves new-issue budget' test ! -e "$XL_KEY.attempted"
check 'verified count excludes the pre-existing candidate' test "$(filing_verified_issue_count run-existing)" = 1
check 'fresh issue lookup runs after the target read' fresh_lookup_after_target_read
check 'cross-link lookup runs after the parent phase finishes' fresh_lookup_after_parent_phase
check 'parent and cross-link phases each perform their own lookup' test "$(grep -c '^issue list ' "$STUB_CALLS" || true)" = 2
check 'fresh issue lookup binds the configured repository' last_lookup_binds_configured_repo
check 'fresh issue lookup scopes to open issues' last_lookup_scopes_open_issues

echo ''
echo '=== consecutive runs sharing forge state: first run creates the candidate ==='

new_run run-a 'first regression'
seed_closed_9
_filing_real_agent run-a cluster > "$RUN_LOG/primary.log" 2>&1
check 'run A parent files' test $? -eq 0
_filing_cross_link_enact run-a > "$RUN_LOG/cross-link.log" 2>&1
check 'run A cross-link enact succeeds' test $? -eq 0
check 'run A creates exactly one reopen candidate' test "$(candidate_count)" = 1
check 'run A POSTs the candidate exactly once' test "$(creates_for reopen-candidate)" = 1
check 'run A reopen action completes with a success marker' test -f "$XL_KEY.done"
check 'run A verified count covers parent and new candidate' test "$(filing_verified_issue_count run-a)" = 2
_filing_cross_link_enact run-a > "$RUN_LOG/resume.log" 2>&1
check 'run A resume enact succeeds' test $? -eq 0
check 'run A resume does not re-POST the candidate' test "$(creates_for reopen-candidate)" = 1
check 'run A resume keeps the candidate count at one' test "$(candidate_count)" = 1
check 'run A resume restores the success marker' test -f "$XL_KEY.done"
check 'run A resume leaves no failure marker' test ! -e "$XL_KEY.failed"
check 'run A resume clears the quarantine marker' test ! -e "$XL_KEY.unverified-done"

echo ''
echo '=== consecutive runs sharing forge state: next run dedups against the live list ==='

new_run run-b 'second regression'
MAX_ISSUES=1
_filing_real_agent run-b cluster > "$RUN_LOG/primary.log" 2>&1
check 'run B parent files within the issue cap' test $? -eq 0
_filing_cross_link_enact run-b > "$RUN_LOG/cross-link.log" 2>&1
check 'run B cross-link enact succeeds' test $? -eq 0
check 'candidate count stays one across runs' test "$(candidate_count)" = 1
check 'run B makes no create for the candidate title' test "$(creates_for reopen-candidate)" = 0
check 'run B still files its distinct parent' test -f "$RUN_LOG/final/filed/cluster.url"
check 'run B records the cross-run dedup hit' file_contains "$XL_KEY.failed" 'DEDUP_HIT'
check 'run B dedup happens before any budget deferral' test ! -e "$XL_KEY.deferred"
check 'run B dedup reserves no new-issue budget' test ! -e "$XL_KEY.attempted"
check 'run B claims no creation for the existing candidate' test ! -e "$XL_KEY.done"
unset MAX_ISSUES

echo ''
echo '=== multiple reopen actions share one listing within an enact pass ==='

for scenario in empty mixed; do
  new_run "run-cache-$scenario" "snapshot $scenario regression"
  seed_closed_9
  add_second_reopen_action
  if [[ "$scenario" == mixed ]]; then
    add_open_candidate_17
  fi
  # Empty and populated successful snapshots both permit independent actions.
  MAX_ISSUES=2
  _filing_cross_link_enact "run-cache-$scenario" > "$RUN_LOG/cross-link.log" 2>&1
  check "$scenario snapshot enact succeeds" test $? -eq 0
  check "$scenario snapshot needs only one forge listing" test "$(grep -c '^issue list ' "$STUB_CALLS" || true)" = 1
  check "$scenario snapshot follows the first eligible target read" fresh_lookup_after_target_read
  second_key="$RUN_LOG/final/filed/cross-link/reopen-suggestion-10"
  check "$scenario second target has an independent success receipt" test -f "$second_key.done"
  check "$scenario second target reserves its own create budget" test -f "$second_key.attempted"
  if [[ "$scenario" == empty ]]; then
    check 'empty snapshot creates both candidates' test "$(total_creates)" = 2
    check 'empty snapshot first action succeeds independently' test -f "$XL_KEY.done"
    check 'empty snapshot verified count includes both creates' test "$(filing_verified_issue_count run-cache-empty)" = 2
  else
    check 'mixed snapshot creates only the unmatched candidate' test "$(total_creates)" = 1
    check 'mixed snapshot records the existing first candidate' file_contains "$XL_KEY.failed" 'DEDUP_HIT: #17'
    check 'mixed snapshot dedup reserves no budget' test ! -e "$XL_KEY.attempted"
    check 'mixed snapshot verified count excludes the existing candidate' test "$(filing_verified_issue_count run-cache-mixed)" = 1
  fi
  unset MAX_ISSUES
done

echo ''
echo '=== dedup lookup failure fails closed ==='

new_run run-list-error 'lookup failure regression'
seed_closed_9
STUB_LIST_RC=1
_filing_cross_link_enact run-list-error > "$RUN_LOG/cross-link.log" 2>&1
check 'lookup failure keeps the enact best-effort' test $? -eq 0
check 'lookup failure is recorded as a verification failure' file_contains "$XL_KEY.failed" 'VERIFICATION_FAILED'
check 'lookup failure message names the dedup query' file_contains "$XL_KEY.failed" 'VERIFICATION_FAILED: fresh reopen-candidate dedup query failed'
check 'lookup failure makes no create request' test "$(total_creates)" = 0
check 'lookup failure reserves no budget' test ! -e "$XL_KEY.attempted"
check 'lookup failure claims no success' test ! -e "$XL_KEY.done"
STUB_LIST_RC=0

echo ''
echo '=== malformed dedup lookup result fails closed ==='

new_run run-list-garbage 'malformed lookup regression'
seed_closed_9
STUB_LIST_PAYLOAD='this is not json'
_filing_cross_link_enact run-list-garbage > "$RUN_LOG/cross-link.log" 2>&1
check 'malformed lookup keeps the enact best-effort' test $? -eq 0
check 'malformed lookup is recorded as a verification failure' file_contains "$XL_KEY.failed" 'VERIFICATION_FAILED'
check 'malformed lookup message names the dedup query' file_contains "$XL_KEY.failed" 'VERIFICATION_FAILED: fresh reopen-candidate dedup query failed'
check 'malformed lookup makes no create request' test "$(total_creates)" = 0
check 'malformed lookup reserves no budget' test ! -e "$XL_KEY.attempted"
check 'malformed lookup claims no success' test ! -e "$XL_KEY.done"
STUB_LIST_PAYLOAD=''

echo ''
echo '=== ambiguous POST is never retried, within or across runs ==='

new_run run-ambiguous 'ambiguous regression'
seed_closed_9
STUB_AMBIGUOUS=1
_filing_real_agent run-ambiguous cluster > "$RUN_LOG/primary.log" 2>&1
check 'parent files before the ambiguous reopen POST' test $? -eq 0
_filing_cross_link_enact run-ambiguous > "$RUN_LOG/cross-link.log" 2>&1
check 'ambiguous POST keeps the enact best-effort' test $? -eq 0
check 'ambiguous POST records a terminal failure' test -f "$XL_KEY.failed"
check 'ambiguous POST lands remotely exactly once' test "$(candidate_count)" = 1
check 'ambiguous POST is attempted exactly once' test "$(creates_for reopen-candidate)" = 1
check 'ambiguous POST claims no success' test ! -e "$XL_KEY.done"
STUB_AMBIGUOUS=0
new_run run-after-ambiguous 'post-ambiguous regression'
_filing_real_agent run-after-ambiguous cluster > "$RUN_LOG/primary.log" 2>&1
check 'follow-up run parent files' test $? -eq 0
_filing_cross_link_enact run-after-ambiguous > "$RUN_LOG/cross-link.log" 2>&1
check 'follow-up run enact succeeds' test $? -eq 0
check 'follow-up run does not retry the ambiguous POST' test "$(candidate_count)" = 1
check 'follow-up run records the dedup hit' file_contains "$XL_KEY.failed" 'DEDUP_HIT'
check 'follow-up run claims no success' test ! -e "$XL_KEY.done"

echo ''
echo '=== target-state verification is preserved ahead of dedup ==='

new_run run-open-target 'open target regression'
seed_closed_9
jq '(.[] | select(.number == 9)).state = "OPEN"' "$STUB_ISSUES" > "$STUB_ISSUES.tmp"
mv "$STUB_ISSUES.tmp" "$STUB_ISSUES"
add_open_candidate_17
_filing_real_agent run-open-target cluster > "$RUN_LOG/primary.log" 2>&1
check 'parent files when the reopen target is open' test $? -eq 0
_filing_cross_link_enact run-open-target > "$RUN_LOG/cross-link.log" 2>&1
check 'open target keeps the enact best-effort' test $? -eq 0
check 'open target fails target-state verification' file_contains "$XL_KEY.failed" 'VERIFICATION_FAILED'
check 'open target yields no candidate create' test "$(creates_for reopen-candidate)" = 0
check 'open target claims no success' test ! -e "$XL_KEY.done"

echo ''
echo '=== citation verification is preserved ahead of dedup ==='

new_run run-bad-citation 'citation regression' 'src/a.sh:999'
seed_closed_9
add_open_candidate_17
_filing_real_agent run-bad-citation cluster > "$RUN_LOG/primary.log" 2>&1
check 'parent files when the action citation is invalid' test $? -eq 0
_filing_cross_link_enact run-bad-citation > "$RUN_LOG/cross-link.log" 2>&1
check 'bad citation keeps the enact best-effort' test $? -eq 0
check 'bad action citation fails citation verification' file_contains "$XL_KEY.failed" 'VERIFICATION_FAILED'
check 'bad citation yields no candidate create' test "$(creates_for reopen-candidate)" = 0
check 'bad citation claims no success' test ! -e "$XL_KEY.done"

echo ''
echo '=== incomplete (truncated) dedup lookup result fails closed ==='

new_run run-list-truncated 'truncated lookup regression'
seed_closed_9
# A bounded CLI listing that hits its 1000-result limit may be truncated; the
# adapter must refuse it as an incomplete dedup check rather than treat it as
# a complete list with no match.
STUB_LIST_PAYLOAD="$(jq -nc '[range(1000) | {number: (. + 1000), title: "unrelated issue \(.)",
  body: "noise", state: "OPEN",
  url: ("https://github.com/acme/origin/issues/" + ((. + 1000) | tostring)), labels: []}]')"
_filing_cross_link_enact run-list-truncated > "$RUN_LOG/cross-link.log" 2>&1
check 'truncated lookup keeps the enact best-effort' test $? -eq 0
check 'truncated lookup is recorded as a dedup query failure' file_contains "$XL_KEY.failed" 'VERIFICATION_FAILED: fresh reopen-candidate dedup query failed'
check 'truncated lookup makes no create request' test "$(total_creates)" = 0
check 'truncated lookup reserves no budget' test ! -e "$XL_KEY.attempted"
check 'truncated lookup claims no success' test ! -e "$XL_KEY.done"
STUB_LIST_PAYLOAD=''

echo ''
echo '=== state-mismatched dedup lookup entry fails closed ==='

new_run run-list-state-mismatch 'state mismatch regression'
seed_closed_9
# A well-formed payload that smuggles a closed entry into an open listing is
# not authoritative: the adapter fails closed instead of matching on it.
STUB_LIST_PAYLOAD="$(jq -nc --arg title "$REOPEN_TITLE" '[{number: 17, title: $title,
  body: "closed candidate", state: "CLOSED",
  url: "https://github.com/acme/origin/issues/17", labels: []}]')"
_filing_cross_link_enact run-list-state-mismatch > "$RUN_LOG/cross-link.log" 2>&1
check 'state-mismatched lookup keeps the enact best-effort' test $? -eq 0
check 'state-mismatched lookup is recorded as a dedup query failure' file_contains "$XL_KEY.failed" 'VERIFICATION_FAILED: fresh reopen-candidate dedup query failed'
check 'state-mismatched lookup makes no create request' test "$(total_creates)" = 0
check 'state-mismatched lookup reserves no budget' test ! -e "$XL_KEY.attempted"
check 'state-mismatched lookup claims no success' test ! -e "$XL_KEY.done"
STUB_LIST_PAYLOAD=''

echo ''
echo '=== closed candidate from a prior run does not suppress a fresh candidate ==='

new_run run-closed-candidate 'regression after candidate closure'
seed_closed_9
# The dedup check matches open issues only: a prior run's candidate that has
# since been closed must not block filing a fresh one.
jq --arg title "$REOPEN_TITLE" \
  '. + [{number:17,title:$title,body:"Prior candidate, since closed",labels:[],
         url:"https://github.com/acme/origin/issues/17",state:"CLOSED"}]' \
  "$STUB_ISSUES" > "$STUB_ISSUES.tmp"
mv "$STUB_ISSUES.tmp" "$STUB_ISSUES"
_filing_real_agent run-closed-candidate cluster > "$RUN_LOG/primary.log" 2>&1
check 'parent files when only a closed candidate exists' test $? -eq 0
_filing_cross_link_enact run-closed-candidate > "$RUN_LOG/cross-link.log" 2>&1
check 'closed candidate keeps the enact best-effort' test $? -eq 0
check 'closed candidate does not suppress a fresh create' test "$(creates_for reopen-candidate)" = 1
check 'a fresh open candidate is filed' test "$(open_candidate_count)" = 1
check 'the closed candidate is left untouched' test "$(candidate_count)" = 2
check 'fresh candidate completes with a success marker' test -f "$XL_KEY.done"
check 'fresh candidate records no failure' test ! -e "$XL_KEY.failed"
check 'verified count covers parent and fresh candidate' test "$(filing_verified_issue_count run-closed-candidate)" = 2

echo ''
echo '=== near-miss open titles do not suppress a fresh candidate ==='

new_run run-near-miss 'near-miss title regression'
seed_closed_9
# Only an exact title match may suppress the create: open issues whose titles
# merely resemble the candidate title (different issue number, trailing
# suffix, different case) are not duplicates of it.
jq '. + [{number:21,title:"[reopen-candidate] consider re-opening #99",
          body:"A different closed issue",labels:[],
          url:"https://github.com/acme/origin/issues/21",state:"OPEN"},
         {number:22,title:"[reopen-candidate] consider re-opening #9 (follow-up)",
          body:"Suffixed title",labels:[],
          url:"https://github.com/acme/origin/issues/22",state:"OPEN"},
         {number:23,title:"[Reopen-Candidate] consider re-opening #9",
          body:"Different case",labels:[],
          url:"https://github.com/acme/origin/issues/23",state:"OPEN"}]' \
  "$STUB_ISSUES" > "$STUB_ISSUES.tmp"
mv "$STUB_ISSUES.tmp" "$STUB_ISSUES"
_filing_real_agent run-near-miss cluster > "$RUN_LOG/primary.log" 2>&1
check 'parent files when only near-miss titles exist' test $? -eq 0
_filing_cross_link_enact run-near-miss > "$RUN_LOG/cross-link.log" 2>&1
check 'near-miss titles keep the enact best-effort' test $? -eq 0
check 'near-miss titles do not suppress the candidate create' test "$(creates_for reopen-candidate)" = 1
check 'a fresh open candidate with the exact title is filed' test "$(open_candidate_count)" = 1
check 'only the parent and the fresh candidate were added' test "$(jq 'length' "$STUB_ISSUES")" = 6
check 'fresh candidate completes with a success marker' test -f "$XL_KEY.done"
check 'no dedup hit is recorded for near-miss titles' test ! -e "$XL_KEY.failed"
check 'verified count covers parent and fresh candidate' test "$(filing_verified_issue_count run-near-miss)" = 2

echo ''
echo '=== dedup lookup is gated to reopen-suggestion actions ==='

new_run run-comment-gate 'comment gate regression'
jq -n '[{cluster_id:"cluster",title:"comment gate regression",body:"src/a.sh:1",
         proposed_labels:[],dedup_against_existing:[],
         cross_link_actions:[{type:"comment",issue_number:8,body:"Fresh evidence for the open issue."},
                             {type:"reopen-suggestion",issue_number:9,
                              body:"The new evidence warrants reconsidering the old issue."}]}]' \
  > "$RUN_LOG/final/manifest.json"
jq -n '[{number:8,title:"Open issue",body:"open",labels:[],
          url:"https://github.com/acme/origin/issues/8",state:"OPEN"},
        {number:9,title:"Old issue",body:"old",labels:[],
          url:"https://github.com/acme/origin/issues/9",state:"CLOSED"},
        {number:11,title:"Later open issue",body:"open",labels:[],
          url:"https://github.com/acme/origin/issues/11",state:"OPEN"}]' > "$STUB_ISSUES"
add_second_reopen_action
# Keep the original comment before the failure and exercise another after both
# reopen actions, when the unsuccessful listing is already cached.
jq '.[0].cross_link_actions += [{type:"comment",issue_number:11,
     body:"Fresh evidence after the cached lookup failure."}]' \
  "$RUN_LOG/final/manifest.json" > "$RUN_LOG/final/manifest.tmp"
mv "$RUN_LOG/final/manifest.tmp" "$RUN_LOG/final/manifest.json"
STUB_LIST_RC=1
_filing_cross_link_enact run-comment-gate > "$RUN_LOG/cross-link.log" 2>&1
check 'comment gate keeps the enact best-effort' test $? -eq 0
check 'comment action succeeds despite the lookup failure' test -f "$RUN_LOG/final/filed/cross-link/comment-8.done"
check 'comment action records no failure' test ! -e "$RUN_LOG/final/filed/cross-link/comment-8.failed"
check 'comments before and after the failure each post once' test "$(grep -c '^issue comment ' "$STUB_CALLS" || true)" = 2
check 'later comment succeeds after the cached lookup failure' test -f "$RUN_LOG/final/filed/cross-link/comment-11.done"
check 'later comment records no failure' test ! -e "$RUN_LOG/final/filed/cross-link/comment-11.failed"
check 'later comment readback preserves its exact body' test "$(jq -r '.body' "$RUN_LOG/final/filed/cross-link/comment-11.readback.json")" = 'Fresh evidence after the cached lookup failure.'
lookup_line="$(grep -n '^issue list ' "$STUB_CALLS" | cut -d: -f1)"
second_target_line="$(grep -n '^issue view 10 ' "$STUB_CALLS" | cut -d: -f1)"
later_comment_line="$(grep -n '^issue comment 11 ' "$STUB_CALLS" | cut -d: -f1)"
check 'later comment follows the failed lookup and second reopen target' \
  test "${later_comment_line:-0}" -gt "${second_target_line:-0}"
check 'second reopen target follows the failed lookup' test "${second_target_line:-0}" -gt "${lookup_line:-0}"
check 'failed lookup is shared by both reopen actions' test "$(grep -c '^issue list ' "$STUB_CALLS" || true)" = 1
check 'reopen action still fails closed on the lookup failure' file_contains "$XL_KEY.failed" 'VERIFICATION_FAILED: fresh reopen-candidate dedup query failed'
second_key="$RUN_LOG/final/filed/cross-link/reopen-suggestion-10"
check 'second reopen action also records the lookup failure' file_contains "$second_key.failed" 'VERIFICATION_FAILED: fresh reopen-candidate dedup query failed'
check 'first failed lookup reserves no budget' test ! -e "$XL_KEY.attempted"
check 'second failed lookup reserves no budget' test ! -e "$second_key.attempted"
check 'second failed lookup claims no creation' test ! -e "$second_key.done"
check 'comment gate makes no create request' test "$(total_creates)" = 0
STUB_LIST_RC=0

check 'reopen dedup tests never invoke a model' test ! -e "$FIXTURE/model-called"

printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
