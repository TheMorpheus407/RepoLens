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
source "$SCRIPT_DIR/lib/core.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/forge.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/filing.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0 FAIL=0
check() { local d="$1"; shift; if "$@" >/dev/null; then PASS=$((PASS+1)); echo "  PASS: $d"; else FAIL=$((FAIL+1)); echo "  FAIL: $d"; fi; }
run_agent() { : > "$TMP/model-called"; return 99; }
glab() {
  jq -cn --args '$ARGS.positional' -- "$@" >> "$TMP/glab-calls"
  [[ "$1" == api && "$3" == --hostname && "$4" == code.example.com:8443 ]] || return 91
  local endpoint="$2" method='' title='' body_file='' labels_json='[]' arg
  shift 4
  while (( $# )); do
    case "$1" in
      --method) method="$2"; shift 2 ;;
      --raw-field|--field)
        arg="$2"; shift 2
        case "$arg" in
          title=*) title="${arg#title=}" ;;
          description=@*) body_file="${arg#description=@}" ;;
          labels=*) labels_json="$(jq -cn --arg value "${arg#labels=}" '$value | split(",")')" ;;
        esac ;;
      --paginate) shift ;;
      *) return 92 ;;
    esac
  done
  case "$endpoint:$method" in
    'projects/company%2Fplatform%2Fservice/labels:POST') printf '{}\n' ;;
    'projects/company%2Fplatform%2Fservice/issues:GET')
      if [[ "$PROVIDER_FAULT" == closed-list ]]; then
        printf '[{"id":999,"iid":17,"title":"existing","description":"prior","state":"closed","web_url":"https://code.example.com:8443/company/platform/service/-/issues/17","labels":[]}]\n'
      else printf '[]\n'; fi ;;
    'projects/company%2Fplatform%2Fservice/issues:POST')
      jq -n --arg title "$title" --rawfile body "$body_file" --argjson labels "$labels_json" \
        '{id:999,iid:17,title:$title,description:$body,labels:$labels,state:"opened",web_url:"https://code.example.com:8443/company/platform/service/-/issues/17"}' > "$TMP/glab-created.json"
      [[ "$PROVIDER_FAULT" == post-failed ]] && return 1
      cat "$TMP/glab-created.json" ;;
    'projects/company%2Fplatform%2Fservice/issues/17:GET')
      case "$PROVIDER_FAULT" in
        wrong-host) jq '.web_url="https://other.example/company/platform/service/-/issues/17"' "$TMP/glab-created.json" ;;
        wrong-iid) jq '.iid=999' "$TMP/glab-created.json" ;;
        wrong-body) jq '.description="different"' "$TMP/glab-created.json" ;;
        *) cat "$TMP/glab-created.json" ;;
      esac ;;
    *) return 93 ;;
  esac
}
tea() {
  jq -cn --args '$ARGS.positional' -- "$@" >> "$TMP/tea-calls"
  [[ "$1" == api && "$2" == --repo && "$3" == company/service && "$4" == --login && "$5" == work ]] || return 91
  local endpoint="${!#}"
  case "$endpoint" in
    'repos/company/service/issues?state=open&type=issues&limit=50&page=1') printf '[]\n' ;;
    'repos/company/service/issues')
      [[ "$*" == *'--method POST --data @-'* ]] || return 92
      jq '. + {number:17,state:"open",url:"https://tea.example/git/api/v1/repos/company/service/issues/17",html_url:"https://tea.example/git/company/service/issues/17"}' > "$TMP/tea-created.json"
      cat "$TMP/tea-created.json" ;;
    'repos/company/service/issues/17') cat "$TMP/tea-created.json" ;;
    *) return 93 ;;
  esac
}
fresh() {
  rm -rf "$TMP/run"
  LOG_BASE="$TMP/run" PROJECT_PATH="$TMP/project" MODE=audit
  FORGE_PROVIDER=glab FORGE_HOST=https://code.example.com:8443 FORGE_REPO=company/platform/service
  PROVIDER_FAULT=''
  unset FORGE_PROJECT_PATH
  FORGE_TEA_LOGIN=work
  mkdir -p "$LOG_BASE/final/filed" "$PROJECT_PATH/src"
  printf 'return 0\n' > "$PROJECT_PATH/src/check.sh"
  : > "$TMP/glab-calls"
  : > "$TMP/tea-calls"
  jq -n '[{cluster_id:"provider::test",title:"[high] Fix literal $(not_a_command)",body:"src/check.sh:1\n\nHistorical documentation says 1 hour.\n\n",proposed_labels:["bug","repolens/complexity/2"],dedup_against_existing:[],cross_link_actions:[]}]' > "$LOG_BASE/final/manifest.json"
}
run() { _filing_real_agent integration provider::test > "$TMP/stdout" 2> "$TMP/stderr"; }
failed() { [[ -f "$LOG_BASE/final/filed/provider::test.failed" && ! -e "$LOG_BASE/final/filed/provider::test.url" ]]; }
issue_post_count() { jq -s '[.[] | select(.[1]=="projects/company%2Fplatform%2Fservice/issues" and index("POST")!=null)]|length' "$TMP/glab-calls"; }
no_provider_calls() { [[ ! -s "$TMP/glab-calls" && ! -s "$TMP/tea-calls" ]]; }

fresh
export GITLAB_HOST=ambient.invalid GH_HOST=ambient.invalid TASK_HOURS=6
check 'governor supports GitLab custom host, port, and full subgroup namespace' run
check 'GitLab preserves exact title/body/labels through governed readback' jq -e --slurpfile entry "$LOG_BASE/final/manifest.json" '.title==$entry[0][0].title and .description==$entry[0][0].body and .labels==$entry[0][0].proposed_labels' "$TMP/glab-created.json"
check 'governor records GitLab IID rather than global ID' jq -e '.number==17 and .url=="https://code.example.com:8443/company/platform/service/-/issues/17"' "$LOG_BASE/final/filed/provider::test.readback.json"
check 'GitLab performed exactly one issue POST' test "$(issue_post_count)" = 1
check 'GitLab callback never invokes a filing model' test ! -e "$TMP/model-called"
check 'GitLab persisted success is freshly reattested on resume' run
check 'GitLab resume cannot repeat the issue POST' test "$(issue_post_count)" = 1
unset GITLAB_HOST GH_HOST TASK_HOURS

for fault in closed-list wrong-host wrong-iid wrong-body post-failed; do
  fresh
  PROVIDER_FAULT="$fault"
  run || true
  check "GitLab anomaly fails the default governor: $fault" failed
  if [[ "$fault" == closed-list ]]; then
    check 'closed-only response cannot satisfy an open issue query' jq -se 'all(.[]; index("POST")==null)' "$TMP/glab-calls"
  else
    rm -f "$LOG_BASE/final/filed/provider::test.failed"
    PROVIDER_FAULT=''
    run || true
    check "GitLab ambiguous attempt never retries: $fault" test "$(issue_post_count)" = 1
  fi
done

for provider in tea glab; do
  for host in '' http://unsafe.example https://bad.example/path?query https://user@unsafe.example 'https://bad.example/a\b'; do
    fresh
    FORGE_PROVIDER="$provider" FORGE_HOST="$host"
    run || true
    check "$provider rejects unusable host before credentials reach a provider: $host" no_provider_calls
    check "$provider host preflight records a failure: $host" failed
  done
done
fresh
FORGE_PROVIDER=tea FORGE_HOST=https://tea.example/git FORGE_REPO=company/service
jq '.[0].proposed_labels=[]' "$LOG_BASE/final/manifest.json" > "$TMP/change.json"
mv "$TMP/change.json" "$LOG_BASE/final/manifest.json"
check 'valid HTTPS Gitea instance base path passes the actual governor' run
check 'Gitea base-path readback preserves exact payload and browser URL' jq -e --slurpfile entry "$LOG_BASE/final/manifest.json" '.body==$entry[0][0].body and .url=="https://tea.example/git/company/service/issues/17"' "$LOG_BASE/final/filed/provider::test.readback.json"
check 'Gitea base-path publication makes one POST' jq -se '[.[]|select(index("POST")!=null)]|length==1' "$TMP/tea-calls"

echo "Results: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
