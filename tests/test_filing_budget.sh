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
root="$SCRIPT_DIR"
# shellcheck source=lib/core.sh
source "$root/lib/core.sh"
# shellcheck source=lib/forge.sh
source "$root/lib/forge.sh"
# shellcheck source=lib/filing.sh
source "$root/lib/filing.sh"
# shellcheck source=lib/summary.sh
source "$root/lib/summary.sh"
budget_fixture="$(mktemp -d /tmp/repolens-p5-root.XXXXXXXX)"
trap 'rm -rf "$budget_fixture"' EXIT
PASS=0 FAIL=0
check() {
  local description="$1"; shift
  if "$@"; then PASS=$((PASS+1)); printf 'PASS: %s\n' "$description";
  else FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$description"; fi
}
PROJECT_PATH="$budget_fixture/project"
mkdir -p "$PROJECT_PATH/src"
printf 'valid source\n' > "$PROJECT_PATH/src/app.sh"
FORGE_PROVIDER=gh FORGE_HOST=github.com FORGE_REPO=acme/origin
MODE=branch-review MAX_ISSUES=1 PARALLEL=false
# shellcheck disable=SC2329 # Guard against accidental model invocation.
run_agent() { touch "$budget_fixture/model-called"; return 99; }
gh() {
  local operation="$1 ${2:-}"; shift 2
  printf '%s\n' "$operation" >> "$LOG_BASE/calls"
  case "$operation" in
    'label create') return 0 ;;
    'issue list') cat "$LOG_BASE/open.json" ;;
    'issue create')
      local title='' body_file='' stub_labels='[]' number
      while (( $# )); do
        case "$1" in
          --title) title="$2"; shift 2 ;;
          --body-file) body_file="$2"; shift 2 ;;
          --label) stub_labels="$(jq -c --arg v "$2" '.+[$v]' <<< "$stub_labels")"; shift 2 ;;
          -R) shift 2 ;;
          *) return 99 ;;
        esac
      done
      case "$title" in
        'first fix') number=17 ;;
        'second fix') number=18 ;;
        *) number=19 ;;
      esac
      printf '%s\n' "$title" >> "$LOG_BASE/posts"
      jq -n --arg title "$title" --rawfile body "$body_file" --argjson labels "$stub_labels" --argjson n "$number" \
        '{number:$n,title:$title,body:$body,labels:$labels,state:"OPEN",url:("https://github.com/acme/origin/issues/"+($n|tostring))}' > "$LOG_BASE/$number.json"
      [[ "$fault" == ambiguous && "$number" == 17 ]] && return 1
      jq -r '.url' "$LOG_BASE/$number.json" ;;
    'issue view')
      if [[ "$1" == 9 ]]; then
        printf '{"number":9,"title":"old","body":"prior","labels":[],"state":"CLOSED","url":"https://github.com/acme/origin/issues/9"}\n'
      else cat "$LOG_BASE/$1.json"; fi ;;
    *) return 99 ;;
  esac
}
fresh() {
  LOG_BASE="$budget_fixture/$1" fault="$1" CROSS_LINK_MODE=off MAX_ISSUES=1
  mkdir -p "$LOG_BASE/final/filed"
  printf '["src/app.sh"]\n' > "$LOG_BASE/branch-scope.json"
  printf '[]\n' > "$LOG_BASE/open.json"
  : > "$LOG_BASE/calls"
  : > "$LOG_BASE/posts"
  jq -n '[{cluster_id:"first",title:"first fix",body:"src/app.sh:1",proposed_labels:[],dedup_against_existing:[],cross_link_actions:[]},{cluster_id:"second",title:"second fix",body:"src/app.sh:1",proposed_labels:[],dedup_against_existing:[],cross_link_actions:[]}]' > "$LOG_BASE/final/manifest.json"
}
for scenario in two-valid ambiguous dedup-first invalid-first reopen concurrent; do
  fresh "$scenario"
  case "$scenario" in
    dedup-first)
      jq -n '[{number:8,title:"first fix",body:"old",state:"OPEN",labels:[],url:"https://github.com/acme/origin/issues/8"}]' > "$LOG_BASE/open.json" ;;
    invalid-first)
      jq '.[0].body="src/app.sh:999"' "$LOG_BASE/final/manifest.json" > "$LOG_BASE/temp.json"
      mv "$LOG_BASE/temp.json" "$LOG_BASE/final/manifest.json" ;;
    reopen)
      CROSS_LINK_MODE=suggest-reopen
      jq '[.[0] | .cross_link_actions=[{type:"reopen-suggestion",issue_number:9,body:"src/app.sh:1"}]]' "$LOG_BASE/final/manifest.json" > "$LOG_BASE/temp.json"
      mv "$LOG_BASE/temp.json" "$LOG_BASE/final/manifest.json" ;;
  esac
  if [[ "$scenario" == concurrent ]]; then
    _filing_real_agent root-budget first > "$LOG_BASE/first.log" 2>&1 & first_pid=$!
    _filing_real_agent root-budget second > "$LOG_BASE/second.log" 2>&1 & second_pid=$!
    wait "$first_pid"; first_rc=$?
    wait "$second_pid"; second_rc=$?
    result=$((first_rc + second_rc))
  else
    dispatch_filing_batch root-budget > "$LOG_BASE/dispatch.log" 2>&1
    result=$?
  fi
  check "$scenario dispatcher records its outcome" test "$result" = 0
  check "$scenario cap permits at most one POST" test "$(wc -l < "$LOG_BASE/posts")" = 1
  expected_verified=1
  [[ "$scenario" != ambiguous ]] || expected_verified=0
  check "$scenario summary counts only verified creations" test "$(filing_verified_issue_count root-budget)" = "$expected_verified"
  dispatch_filing_batch root-budget > "$LOG_BASE/resume.log" 2>&1
  check "$scenario repeated dispatch succeeds" test "$?" = 0
  check "$scenario resume preserves one POST" test "$(wc -l < "$LOG_BASE/posts")" = 1
  MAX_ISSUES=2
  dispatch_filing_batch root-budget > "$LOG_BASE/increase.log" 2>&1
  check "$scenario increased cap dispatch succeeds" test "$?" = 0
  expected_posts=2
  case "$scenario" in dedup-first|invalid-first) expected_posts=1 ;; esac
  check "$scenario increased cap releases only eligible deferrals" test "$(wc -l < "$LOG_BASE/posts")" = "$expected_posts"
  expected_verified="$expected_posts"
  [[ "$scenario" != ambiguous ]] || expected_verified=1
  check "$scenario resumed count includes reopen creations" test "$(filing_verified_issue_count root-budget)" = "$expected_verified"
  if [[ "$scenario" == reopen ]]; then
    rm "$LOG_BASE/final/filed/cross-link/reopen-suggestion-9.readback.json"
    check 'legacy reopen receipt is freshly attested without a cached readback' test "$(filing_verified_issue_count root-budget)" = 2
  fi
done

# A regenerated manifest must not erase historical receipts or cap reservations.
printf '[]\n' > "$LOG_BASE/final/manifest.json"
check 'historical creations survive regenerated manifest IDs' test "$(filing_verified_issue_count root-budget)" = 2
printf 'https://github.com/acme/origin/issues/99\n' > "$LOG_BASE/final/filed/forged.url"
printf '{}\n' > "$LOG_BASE/final/filed/forged.request.json"
printf '{}\n' > "$LOG_BASE/final/filed/forged.readback.json"
count="$(filing_verified_issue_count root-budget 2>/dev/null)"; rc=$?
check 'forged orphan receipt reports failed reconciliation' test "$rc" -ne 0
check 'failed reconciliation retains the verified partial count' test "$count" = 2
check 'forged orphan receipt is quarantined' test -f "$LOG_BASE/final/filed/forged.unverified-url"
check 'quarantined orphan reserves uncertain creation capacity' test -f "$LOG_BASE/final/filed/forged.attempted"

# Repeated reconciliation replaces the governed component, and migrates old
# branch draft counts once while keeping the progress history.
summary="$budget_fixture/summary.json"
init_summary "$summary" fixture "$PROJECT_PATH" branch-review codex '' 2 github
record_lens "$summary" security first 1 'done' 3
check 'legacy draft counts migrate to separate progress' reconcile_summary_filing "$summary" 2 2
check 'migration preserves three drafts and two creations' jq -e '.totals.issues_created==2 and .totals.findings_drafted==3 and .lenses[0].issues_created==0' "$summary"
check 'repeated snapshot reconciliation succeeds' reconcile_summary_filing "$summary" 2 2
check 'repeated snapshot cannot double count' jq -e '.totals.issues_created==2 and .totals.findings_drafted==3' "$summary"
record_lens "$summary" security second 1 'done' 0 0 '' '' 0 4
reconcile_summary_filing "$summary" 1 3
check 'new drafts retain progress while invalidated receipt drops out' jq -e '.totals.issues_created==1 and .totals.findings_drafted==7 and .max_issues==3' "$summary"
init_summary "$summary" fixture "$PROJECT_PATH" audit codex '' 2 github
record_lens "$summary" security first 1 'done' 3
reconcile_summary_filing "$summary" 2 2
reconcile_summary_filing "$summary" 1 2
check 'nonbranch reconciliation preserves direct issue counts' jq -e '.totals.issues_created==4 and .totals.governed_issues_created==1' "$summary"
check 'governed budget tests never invoke a model' test ! -e "$budget_fixture/model-called"
printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
