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
TMP="$(mktemp -d)"
RUN_DIRS=()
cleanup() { rm -rf "$TMP"; local dir; for dir in "${RUN_DIRS[@]}"; do rm -rf "$dir"; done; }
trap cleanup EXIT
PASS=0 FAIL=0
check() { local d="$1"; shift; if "$@" >/dev/null; then PASS=$((PASS+1)); echo "  PASS: $d"; else FAIL=$((FAIL+1)); echo "  FAIL: $d"; fi; }
mkdir -p "$TMP/bin" "$TMP/project/src"
git -C "$TMP/project" init -q
git -C "$TMP/project" config user.name Test
git -C "$TMP/project" config user.email test@example.invalid
printf 'return 1\n' > "$TMP/project/src/app.sh"
printf 'unchanged\n' > "$TMP/project/src/untouched.sh"
git -C "$TMP/project" add .
git -C "$TMP/project" commit -qm base
printf 'return 0\n' > "$TMP/project/src/app.sh"
git -C "$TMP/project" commit -qam head
git -C "$TMP/project" remote add origin https://github.com/acme/gate.git
cat > "$TMP/body.md" <<'MD'
## Summary
src/app.sh:1 changed the return value.
## Introduced By
The review head removed the failure return.
```diff
-return 1
+return 0
```
## Before / After
Head evidence:
src/app.sh:1

Historical merge-base evidence from `git show BASE:src/app.sh`:
```sh
return 1
```
The base returned one; the head returns zero. Historical documentation mentions 1 hour.
## Impact
The caller accepts an invalid request.
## Complexity
- **Complexity:** 2 (Easy)
## Recommended Fix
Restore the expected return contract.
## References
src/app.sh:1
## Validation
- attacker_source: n/a
- missing_guard: n/a
- sink_effect: n/a
- preconditions: none
- proof_anchors: src/app.sh:1
- suggested_validation: run the return-code test
MD
branch_test_base="$(git -C "$TMP/project" rev-parse HEAD~1)"
sed -i "s/BASE/$branch_test_base/g" "$TMP/body.md"
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
prompt="${!#}"
[[ "$prompt" == *'6 hours'* ]] || exit 98
output_dir="$(sed -n 's/^Write all findings to: `\(.*\)`$/\1/p' <<< "$prompt" | head -1)"
if [[ -n "$output_dir" ]]; then
  printf 'lens\n' >> "$GATE_TEST_TMP/models"
  mkdir -p "$output_dir/nested"
  {
    printf '%s\n' '---' 'title: "[REGRESSION][HIGH] Restore return contract"' 'severity: high' 'complexity: 2' 'domain: security' 'lens: injection' 'labels: ["regression:security/injection", "repolens/complexity/2"]' '---'
    cat "$GATE_TEST_TMP/body.md"
  } > "$output_dir/001-valid.md"
  printf '%s\n' '---' 'title: "[HIGH] unrelated"' 'severity: high' 'domain: security' 'lens: injection' '---' 'src/untouched.sh:1' > "$output_dir/nested/002-unrelated.md"
  printf '%s\n' "$output_dir/001-valid.md" > "$GATE_TEST_TMP/source-path"
  printf 'DONE\nWrote regression fixture.\nDONE\n'
else
  printf 'synthesizer\n' >> "$GATE_TEST_TMP/models"
  [[ "${GATE_TEST_LOCAL:-0}" == 1 ]] && exit 99
  jq -n --rawfile body "$GATE_TEST_TMP/body.md" --arg source "$(cat "$GATE_TEST_TMP/source-path")" \
    --arg two "${GATE_TEST_TWO:-0}" \
    '[{cluster_id:"regression::return",title:"[high] Restore return contract",severity:"high",complexity:2,domain:"security",lens:"injection",root_cause_category:"return-code",source_finding_paths:[$source],dedup_against_existing:[],proposed_labels:["regression:security/injection","repolens/complexity/2"],cross_link_actions:[],granularity:"independent",body:$body}] | if $two=="1" then . + [.[0] | .cluster_id="regression::second" | .title="[high] Second return contract"] else . end'
fi
STUB
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
command="$1 ${2:-}"; shift 2
case "$command" in
  'auth status'|'label create') exit 0 ;;
  'label list') printf '[]\n' ;;
  'issue list')
    if [[ "${GATE_TEST_DEDUP:-0}" == 1 ]]; then
      printf '%s\n' '[{"number":10,"title":"[REGRESSION][HIGH] Restore return contract","body":"existing","labels":[],"state":"OPEN","url":"https://github.com/acme/gate/issues/10"}]'
    else printf '[]\n'; fi ;;
  'issue create')
    title='' body_file='' labels='[]'
    while (( $# )); do
      case "$1" in
        --title) title="$2"; shift 2 ;;
        --body-file) body_file="$2"; shift 2 ;;
        --label) labels="$(jq -c --arg label "$2" '.+[$label]' <<< "$labels")"; shift 2 ;;
        -R) shift 2 ;;
        *) exit 99 ;;
      esac
    done
    number=17
    [[ "$title" != *'Second return contract'* ]] || number=18
    jq -n --arg title "$title" --rawfile body "$body_file" --argjson labels "$labels" --argjson number "$number" \
      '{number:$number,title:$title,body:$body,labels:$labels,state:"OPEN",url:("https://github.com/acme/gate/issues/"+($number|tostring))}' > "$GATE_TEST_TMP/created.json"
    cp "$GATE_TEST_TMP/created.json" "$GATE_TEST_TMP/created-$number.json"
    printf 'create\n' >> "$GATE_TEST_TMP/mutations"
    [[ "${GATE_TEST_POSTFAIL:-0}" != 1 || "$number" != 18 ]] || exit 1
    jq -r '.url' "$GATE_TEST_TMP/created.json" ;;
  'issue view') cat "$GATE_TEST_TMP/created-$1.json" ;;
  *) exit 99 ;;
esac
STUB
chmod +x "$TMP/bin/codex" "$TMP/bin/gh"
for kind in remote local; do
  : > "$TMP/models"
  : > "$TMP/mutations"
  extra=()
  [[ "$kind" == local ]] && extra=(--local --output "$TMP/local-output")
  env REPOLENS_MODE=audit PATH="$TMP/bin:$PATH" GATE_TEST_TMP="$TMP" GATE_TEST_LOCAL="$([[ "$kind" == local ]] && printf 1 || printf 0)" \
    REPOLENS_AGENT_TIMEOUT=10 REPOLENS_AGENT_KILL_GRACE=1 REPOLENS_LENS_HEARTBEAT_INTERVAL=0 \
    bash "$SCRIPT_DIR/repolens.sh" --project "$TMP/project" --agent codex \
    --mode branch-review --branch-base HEAD~1 --focus injection --depth 1 --task-hours 6 --no-verifier --yes "${extra[@]}" > "$TMP/$kind.log" 2>&1
  rc=$?
  run_id="$(sed -n 's/.*RepoLens run \([^ ]*\) complete.*/\1/p' "$TMP/$kind.log" | tail -1)"
  if [[ -n "$run_id" ]]; then RUN_DIRS+=("$SCRIPT_DIR/logs/$run_id"); fi
  check "$kind branch run completes with a stubbed model" test "$rc" = 0
  source_path="$(cat "$TMP/source-path" 2>/dev/null || true)"
  check "$kind CLI branch mode overrides conflicting ambient audit mode" test -f "${source_path%/*}/nested/002-unrelated.md.out-of-scope"
  if [[ "$kind" == remote ]]; then
    check 'remote branch creates exactly one issue through governor' test "$(wc -l < "$TMP/mutations")" = 1
    check 'remote branch preserves regression title and complexity label' jq -e '.title=="[REGRESSION][HIGH] Restore return contract" and (.labels|index("repolens/complexity/2"))!=null' "$TMP/created.json"
    check 'six-hour sizing preserves exact historical head/base evidence including original one-hour text' jq -e --rawfile body "$TMP/body.md" '.body==$body' "$TMP/created.json"
    check 'remote branch runs investigator then synthesizer without a filing model' test "$(paste -sd, "$TMP/models")" = lens,synthesizer
    check 'remote summary separates draft progress from one verified creation' jq -e '.totals.issues_created==1 and .totals.findings_drafted==1 and .lenses[0].issues_created==0' "$SCRIPT_DIR/logs/$run_id/summary.json"
  else
    check 'local branch retains findings without invoking optional synthesizer' test "$(cat "$TMP/models")" = lens
    check 'local branch never invokes a mutation' test ! -s "$TMP/mutations"
    check 'local findings keep existing issue accounting' jq -e '.totals.issues_created==1 and .lenses[0].issues_created==1' "$SCRIPT_DIR/logs/$run_id/summary.json"
    check 'local registry excludes nested off-instruction finding' jq -se 'length==1 and .[0].complexity==2' "$SCRIPT_DIR/logs/$run_id/final/findings.jsonl"
  fi
done
# A duplicate draft cannot consume the remote publication cap or prevent the
# remaining selected investigators from running. Resume keeps that cap and count.
: > "$TMP/models"
: > "$TMP/mutations"
env PATH="$TMP/bin:$PATH" GATE_TEST_TMP="$TMP" GATE_TEST_DEDUP=1 \
  REPOLENS_AGENT_TIMEOUT=10 REPOLENS_AGENT_KILL_GRACE=1 REPOLENS_LENS_HEARTBEAT_INTERVAL=0 \
  bash "$SCRIPT_DIR/repolens.sh" --project "$TMP/project" --agent codex \
  --mode branch-review --branch-base HEAD~1 --domain security --max-issues 1 \
  --task-hours 6 --no-verifier --yes > "$TMP/dedup-cap.log" 2>&1
rc=$?
run_id="$(sed -n 's/.*RepoLens run \([^ ]*\) complete.*/\1/p' "$TMP/dedup-cap.log" | tail -1)"
[[ -z "$run_id" ]] || RUN_DIRS+=("$SCRIPT_DIR/logs/$run_id")
check 'dedup under a one-issue cap completes' test "$rc" = 0
check 'dedup performs zero remote posts' test ! -s "$TMP/mutations"
check 'duplicate draft does not skip other security lenses' test "$(grep -c '^lens$' "$TMP/models")" = 11
check 'dedup reports zero issues, eleven drafts and no budget stop' jq -e '.totals.issues_created==0 and .totals.findings_drafted==11 and .stopped_reason==null and ([.lenses[]|select(.status=="skipped")]|length)==0' "$SCRIPT_DIR/logs/$run_id/summary.json"
: > "$TMP/models"
env PATH="$TMP/bin:$PATH" GATE_TEST_TMP="$TMP" GATE_TEST_DEDUP=1 \
  REPOLENS_AGENT_TIMEOUT=10 REPOLENS_AGENT_KILL_GRACE=1 REPOLENS_LENS_HEARTBEAT_INTERVAL=0 \
  bash "$SCRIPT_DIR/repolens.sh" --project "$TMP/project" --agent codex \
  --mode branch-review --resume "$run_id" --domain security \
  --no-verifier --yes > "$TMP/dedup-resume.log" 2>&1
check 'dedup run resumes without an explicit cap' test "$?" = 0
check 'resume preserves the prior cap without inflating totals' jq -e '.max_issues==1 and .totals.issues_created==0 and .totals.findings_drafted==11 and .stopped_reason==null' "$SCRIPT_DIR/logs/$run_id/summary.json"
check 'resume does not repeat completed investigators' test "$(grep -c '^lens$' "$TMP/models")" = 0
check 'resume still performs zero remote posts' test ! -s "$TMP/mutations"

: > "$TMP/models"
: > "$TMP/mutations"
env PATH="$TMP/bin:$PATH" GATE_TEST_TMP="$TMP" GATE_TEST_TWO=1 \
  REPOLENS_LENS_HEARTBEAT_INTERVAL=0 bash "$SCRIPT_DIR/repolens.sh" \
  --project "$TMP/project" --agent codex --mode branch-review --branch-base HEAD~1 \
  --focus injection --max-issues 1 --task-hours 6 --no-verifier --yes > "$TMP/cap.log" 2>&1
rc=$?
run_id="$(sed -n 's/.*RepoLens run \([^ ]*\) complete.*/\1/p' "$TMP/cap.log" | tail -1)"
[[ -z "$run_id" ]] || RUN_DIRS+=("$SCRIPT_DIR/logs/$run_id")
check 'eligible findings beyond the cap defer without failure' test "$rc" = 0
check 'CLI governor enforces one actual post' test "$(wc -l < "$TMP/mutations")" = 1
check 'CLI reports one created issue and a budget stop' jq -e '.totals.issues_created==1 and .stopped_reason=="max-issues-reached"' "$SCRIPT_DIR/logs/$run_id/summary.json"
check 'unposted finding remains explicitly deferred' test -f "$SCRIPT_DIR/logs/$run_id/final/filed/regression::second.deferred"
env PATH="$TMP/bin:$PATH" GATE_TEST_TMP="$TMP" GATE_TEST_TWO=1 \
  REPOLENS_LENS_HEARTBEAT_INTERVAL=0 bash "$SCRIPT_DIR/repolens.sh" \
  --project "$TMP/project" --agent codex --mode branch-review --resume "$run_id" \
  --focus injection --max-issues 2 --no-verifier --yes > "$TMP/increased-cap.log" 2>&1
check 'increased cap resumes deferred creation' test "$?" = 0
check 'resume posts only the deferred issue' test "$(wc -l < "$TMP/mutations")" = 2
check 'resume counts both issues once and clears the old stop reason' jq -e '.max_issues==2 and .totals.issues_created==2 and .stopped_reason==null' "$SCRIPT_DIR/logs/$run_id/summary.json"

: > "$TMP/mutations"
env PATH="$TMP/bin:$PATH" GATE_TEST_TMP="$TMP" GATE_TEST_TWO=1 GATE_TEST_POSTFAIL=1 \
  REPOLENS_LENS_HEARTBEAT_INTERVAL=0 bash "$SCRIPT_DIR/repolens.sh" \
  --project "$TMP/project" --agent codex --mode branch-review --branch-base HEAD~1 \
  --focus injection --max-issues 2 --task-hours 6 --no-verifier --yes > "$TMP/partial.log" 2>&1
rc=$?
run_id="$(sed -n 's/.*RepoLens run \([^ ]*\) starting.*/\1/p' "$TMP/partial.log" | head -1)"
[[ -z "$run_id" ]] || RUN_DIRS+=("$SCRIPT_DIR/logs/$run_id")
check 'ambiguous later POST makes the CLI fail' test "$rc" -ne 0
check 'partial failure still records the earlier verified creation' jq -e '.totals.issues_created==1 and .stopped_reason=="filing-failed"' "$SCRIPT_DIR/logs/$run_id/summary.json"
echo "Results: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
