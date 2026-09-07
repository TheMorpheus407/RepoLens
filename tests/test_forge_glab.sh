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

# Hermetic GitLab provider contracts: no network, real forge, or model calls.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/lib/forge.sh"
PASS=0 FAIL=0
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/bin"
export GLAB_TEST_LOG="$SCRATCH/calls.jsonl" GLAB_BODY_COPY="$SCRATCH/body.copy"
export GLAB_TEST_RESPONSE="$SCRATCH/response.json" GLAB_TEST_RC=0
export FORGE_PROVIDER=glab FORGE_HOST=https://code.example.com:8443
export GLAB_EXPECT_HOST=code.example.com:8443
export PATH="$SCRATCH/bin:$PATH"
cat > "$SCRATCH/bin/glab" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
jq -cn --args '$ARGS.positional' -- "$@" >> "$GLAB_TEST_LOG"
if [[ "$1 $2" == 'auth status' ]]; then
  [[ "$3" == --hostname && "$4" == "$GLAB_EXPECT_HOST" ]] || exit 90
  exit "$GLAB_TEST_RC"
fi
[[ "$1" == api && "$3" == --hostname && "$4" == "$GLAB_EXPECT_HOST" ]] || exit 91
[[ "$2" == projects/team%2Fplatform%2Fservice/* ]] || exit 92
prev=""
for arg in "$@"; do
  if [[ "$prev" == --field && "$arg" == *=@* ]]; then
    cp -- "${arg#*=@}" "$GLAB_BODY_COPY" || exit 93
  fi
  prev="$arg"
done
cat "$GLAB_TEST_RESPONSE"
exit "$GLAB_TEST_RC"
STUB
chmod +x "$SCRATCH/bin/glab"
for cli in gh tea fj; do
  printf '#!/usr/bin/env bash\nexit 99\n' > "$SCRATCH/bin/$cli"
  chmod +x "$SCRATCH/bin/$cli"
done
die() { printf '%s\n' "$*" >&2; exit 1; }
check() {
  local label="$1"
  shift
  if "$@"; then PASS=$((PASS + 1)); printf '  PASS: %s\n' "$label"
  else FAIL=$((FAIL + 1)); printf '  FAIL: %s\n' "$label"; fi
}
eq() { [[ "$1" == "$2" ]]; }
contains() { [[ "$1" == *"$2"* ]]; }
fixture() { printf '%s\n' "$1" > "$GLAB_TEST_RESPONSE"; }
issue='{"id":900,"iid":7,"title":"Fix upload","description":"Details","state":"opened","web_url":"https://code.example.com:8443/team/platform/service/-/issues/7","labels":["bug","audit"]}'
repo=team/platform/service
url=https://code.example.com:8443/team/platform/service/-/issues/7

check 'GitLab auto detection requires a full DNS label' eq unknown "$(detect_forge_provider https://my-gitlab.example.com/team/repo.git)"
check 'nested GitLab DNS label is detected' eq glab "$(detect_forge_provider https://EU.GitLab.example.com/team/repo.git)"
for remote in https://gitlab.com/team/platform/service.git git@gitlab.com:team/platform/service.git ssh://git@gitlab.com:2222/team/platform/service.git; do
  check "GitLab preserves subgroups: $remote" eq "$repo" "$(forge_remote_repo_slug "$remote")"
done
check 'custom host override preserves subgroups' eq "$repo" "$(forge_remote_repo_slug https://code.example.com:8443/team/platform/service.git glab)"
check 'GitLab HTTPS host retains port, excludes namespace and credentials' eq https://code.example.com:8443 "$(detect_forge_host https://alice@Code.Example.com:8443/team/platform/service.git glab)"
check 'GitLab SSH host excludes SSH transport port' eq code.example.com "$(detect_forge_host ssh://git@code.example.com:2222/team/platform/service.git glab)"
check 'GitLab HTTP origin has no authenticated binding' eq '' "$(detect_forge_host http://code.example.com/team/platform/service.git glab)"
for provider in gh tea fj; do
  check "$provider keeps final owner/repo after hosting base path" eq platform/service "$(forge_remote_repo_slug https://forge.example.com/team/platform/service.git "$provider")"
  check "$provider keeps hosting base path" eq https://forge.example.com/team "$(detect_forge_host https://forge.example.com/team/platform/service.git "$provider")"
done
check 'GitLab missing namespace rejected' eq '' "$(forge_remote_repo_slug https://gitlab.com/service.git)"
check 'GitLab empty namespace component rejected' eq '' "$(forge_remote_repo_slug https://gitlab.com/team//service.git)"

check 'auth explicitly uses custom host and port' forge_auth_status
GLAB_TEST_RC=1
check 'failed GitLab auth fails' bash -c '! (source "$1/lib/forge.sh"; die() { exit 1; }; forge_auth_status)' bash "$ROOT"
GLAB_TEST_RC=0

fixture '[{"name":"bug"},{"name":"audit"}]'
check 'labels returned as names' eq $'bug\naudit' "$(forge_label_list_names "$repo")"
check 'label list requests all pages' jq -e 'select(.[0] == "api") | index("--paginate") != null' "$GLAB_TEST_LOG"
fixture '[]'
check 'empty label array succeeds' forge_label_list_names "$repo"
fixture '{"message":"not an array"}'
out="$(forge_label_list_names "$repo" 2>/dev/null)"; rc=$?
check 'malformed label response fails without output' eq '1:' "$rc:$out"
fixture '{}'
check 'label creation is best effort' forge_label_create bug '#abcdef' "$repo"
check 'label create passes one color prefix' jq -e 'select(.[1] == "projects/team%2Fplatform%2Fservice/labels") | index("color=#abcdef") != null' "$GLAB_TEST_LOG"

# Simulate older paginated glab output: separate arrays in one JSON stream.
fixture "[$issue]"$'\n'"[$issue]"
check 'issue count includes every page' eq 2 "$(forge_issue_list_count "$repo" audit)"
check 'issue count requests opened state and label filter' jq -se 'last | index("state=opened") != null and index("labels=audit") != null and index("--paginate") != null' "$GLAB_TEST_LOG"
jq -n --argjson issue "$issue" '[range(0;150) | $issue]' > "$GLAB_TEST_RESPONSE"
check 'issue count is not capped at 100' eq 150 "$(forge_issue_list_count "$repo" audit)"
fixture "[$issue]"
check 'backlog uses IID rather than global ID' contains "$(forge_open_issue_backlog_snapshot "$repo")" 'Open issue #7: Fix upload'
check 'typed list normalizes issue shape' eq "$(jq -c '{number:7,title:"Fix upload",body:"Details",state:"open",url:.web_url,labels}' <<< "$issue")" "$( _forge_glab_issue_list_json "$repo" open | jq -c '.[0]')"
fixture "$issue"
check 'typed read uses same repository and IID' eq 7 "$(_forge_glab_issue_read_json "$repo" 7 | jq '.number')"
out="$(_forge_glab_issue_read_json "$repo" 8 2>/dev/null)"; rc=$?
check 'typed read rejects wrong issue response' eq '1:' "$rc:$out"
fixture '{"message":"forbidden"}'
out="$(forge_issue_list_count "$repo" audit 2>/dev/null)"; rc=$?
check 'object-shaped error is never an issue count' eq '1:' "$rc:$out"
fixture "[$issue]"; GLAB_TEST_RC=1
out="$(forge_issue_list_count "$repo" audit 2>/dev/null)"; rc=$?
check 'partial successful output from failed query is rejected' eq '1:' "$rc:$out"
GLAB_TEST_RC=0
fixture '[{"iid":7}]'
out="$(_forge_glab_issue_list_json "$repo" open 2>/dev/null)"; rc=$?
check 'incomplete issue rows fail schema validation' eq '1:' "$rc:$out"

printf '## Body\n`literal` $(do_not_run)\n\n' > "$SCRATCH/body.md"
fixture "$issue"
: > "$GLAB_TEST_LOG"
check 'one-shot create emits issue URL' eq "$url" "$(_forge_glab_issue_create_once "$repo" 'Fix upload' "$SCRATCH/body.md" bug audit)"
check 'one-shot create performs exactly one API request' eq 1 "$(wc -l < "$GLAB_TEST_LOG" | tr -d ' ')"
check 'create body retains exact bytes including final blank line' cmp "$SCRATCH/body.md" "$GLAB_BODY_COPY"
check 'create labels passed in single parameter' jq -e 'index("labels=bug,audit") != null and index("--method") != null and index("POST") != null' "$GLAB_TEST_LOG"
fixture "[$issue]"
: > "$GLAB_TEST_LOG"
check 'legacy create reuses exact open title match' eq "$url" "$(forge_issue_create "$repo" 'Fix upload' "$SCRATCH/body.md" bug)"
check 'legacy dedup hit does not mutate' jq -e 'index("POST") == null' "$GLAB_TEST_LOG"
fixture '{"id":15}'
check 'comment produces bound note URL' eq "$url#note_15" "$(forge_issue_comment "$repo" 7 "$SCRATCH/body.md")"
check 'comment retains exact body bytes' cmp "$SCRATCH/body.md" "$GLAB_BODY_COPY"
GLAB_TEST_RC=1
: > "$GLAB_TEST_LOG"
out="$(_forge_glab_issue_create_once "$repo" 'Fix upload' "$SCRATCH/body.md" bug 2>/dev/null)"; rc=$?
check 'failed create is not reported as success' eq '1:' "$rc:$out"
check 'failed one-shot create is never retried' eq 1 "$(wc -l < "$GLAB_TEST_LOG" | tr -d ' ')"
GLAB_TEST_RC=0
FORGE_HOST=''
: > "$GLAB_TEST_LOG"
out="$(_forge_glab_issue_list_json "$repo" open 2>/dev/null)"; rc=$?
check 'missing host fails without calling default forge' eq '1:0' "$rc:$(wc -l < "$GLAB_TEST_LOG" | tr -d ' ')"
FORGE_HOST=https://gitlab.com
GLAB_EXPECT_HOST=gitlab.com
check 'GitLab.com auth binds SaaS host explicitly' forge_auth_status
FORGE_HOST=https://code.example.com:8443
GLAB_EXPECT_HOST=code.example.com:8443
create_prompt="$(forge_prompt_issue_create audit "$repo" /tmp/elsewhere)"
check 'creation prompt uses supported file input flag' contains "$create_prompt" '--description-file "$body_file"'
check 'creation prompt includes explicit host and subgroup URL' contains "$create_prompt" "'https://code.example.com:8443/$repo'"
check 'creation prompt suppresses confirmation' contains "$create_prompt" '--yes'
check 'open list prompt uses glab default open state' eq "glab issue list -R 'https://code.example.com:8443/$repo' --per-page 100" "$(forge_prompt_issue_list open "$repo" /tmp/elsewhere)"
check 'closed list prompt uses supported flag' contains "$(forge_prompt_issue_list closed "$repo" /tmp/elsewhere)" '--closed'
check 'all list prompt uses supported flag' contains "$(forge_prompt_issue_list all "$repo" /tmp/elsewhere)" '--all'
check 'label prompt quotes color prefix' contains "$(forge_prompt_label_create audit abcdef "$repo" /tmp/elsewhere)" "--color '#abcdef'"
# Canonical prompt identity keeps the full namespace separate from the project.
# shellcheck source=/dev/null
source "$ROOT/lib/template.sh"
printf '{{REPO_OWNER}}:{{REPO_NAME}}\n' > "$SCRATCH/template.md"
printf '%s\n' '---' 'id: test' '---' 'lens' > "$SCRATCH/lens.md"
check 'prompt identity splits only at final slash' eq 'team/platform:service' \
  "$(compose_prompt "$SCRATCH/template.md" "$SCRATCH/lens.md" "FORGE_REPO_SLUG=$repo")"
printf '\nResults: %s/%s passed, %s failed\n' "$PASS" "$((PASS + FAIL))" "$FAIL"
(( FAIL == 0 ))
