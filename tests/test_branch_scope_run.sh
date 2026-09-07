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
The base returned one; the head returns zero.
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
    '[{cluster_id:"regression::return",title:"[high] Restore return contract",severity:"high",complexity:2,domain:"security",lens:"injection",root_cause_category:"return-code",source_finding_paths:[$source],dedup_against_existing:[],proposed_labels:["regression:security/injection","repolens/complexity/2"],cross_link_actions:[],granularity:"independent",body:$body}]'
fi
STUB
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
command="$1 ${2:-}"; shift 2
case "$command" in
  'auth status'|'label create') exit 0 ;;
  'label list') printf '[]\n' ;;
  'issue list') printf '[]\n' ;;
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
    jq -n --arg title "$title" --rawfile body "$body_file" --argjson labels "$labels" \
      '{number:17,title:$title,body:$body,labels:$labels,state:"OPEN",url:"https://github.com/acme/gate/issues/17"}' > "$GATE_TEST_TMP/created.json"
    printf 'create\n' >> "$GATE_TEST_TMP/mutations"
    printf 'https://github.com/acme/gate/issues/17\n' ;;
  'issue view') cat "$GATE_TEST_TMP/created.json" ;;
  *) exit 99 ;;
esac
STUB
chmod +x "$TMP/bin/codex" "$TMP/bin/gh"
for kind in remote local; do
  : > "$TMP/models"
  : > "$TMP/mutations"
  extra=()
  [[ "$kind" == local ]] && extra=(--local --output "$TMP/local-output")
  env PATH="$TMP/bin:$PATH" GATE_TEST_TMP="$TMP" GATE_TEST_LOCAL="$([[ "$kind" == local ]] && printf 1 || printf 0)" \
    REPOLENS_AGENT_TIMEOUT=10 REPOLENS_AGENT_KILL_GRACE=1 REPOLENS_LENS_HEARTBEAT_INTERVAL=0 \
    bash "$SCRIPT_DIR/repolens.sh" --project "$TMP/project" --agent codex \
    --mode branch-review --branch-base HEAD~1 --focus injection --depth 1 --no-verifier --yes "${extra[@]}" > "$TMP/$kind.log" 2>&1
  rc=$?
  run_id="$(sed -n 's/.*RepoLens run \([^ ]*\) complete.*/\1/p' "$TMP/$kind.log" | tail -1)"
  if [[ -n "$run_id" ]]; then RUN_DIRS+=("$SCRIPT_DIR/logs/$run_id"); fi
  check "$kind branch run completes with a stubbed model" test "$rc" = 0
  source_path="$(cat "$TMP/source-path" 2>/dev/null || true)"
  check "$kind nested out-of-scope finding is quarantined" test -f "${source_path%/*}/nested/002-unrelated.md.out-of-scope"
  if [[ "$kind" == remote ]]; then
    check 'remote branch creates exactly one issue through governor' test "$(wc -l < "$TMP/mutations")" = 1
    check 'remote branch preserves regression title and complexity label' jq -e '.title=="[REGRESSION][HIGH] Restore return contract" and (.labels|index("repolens/complexity/2"))!=null' "$TMP/created.json"
    check 'remote branch preserves all exact source body sections and evidence' jq -e --rawfile body "$TMP/body.md" '.body==$body' "$TMP/created.json"
    check 'remote branch runs investigator then synthesizer without a filing model' test "$(paste -sd, "$TMP/models")" = lens,synthesizer
  else
    check 'local branch retains findings without invoking optional synthesizer' test "$(cat "$TMP/models")" = lens
    check 'local branch never invokes a mutation' test ! -s "$TMP/mutations"
    check 'local registry excludes nested off-instruction finding' jq -se 'length==1 and .[0].complexity==2' "$SCRIPT_DIR/logs/$run_id/final/findings.jsonl"
  fi
done
echo "Results: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
