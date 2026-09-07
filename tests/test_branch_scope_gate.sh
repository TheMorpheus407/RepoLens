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
source "$SCRIPT_DIR/lib/streak.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0 FAIL=0
check() {
  local description="$1"; shift
  if "$@" >/dev/null; then PASS=$((PASS + 1)); echo "  PASS: $description";
  else FAIL=$((FAIL + 1)); echo "  FAIL: $description"; fi
}
MODE=branch-review
unset REPOLENS_MODE REPOLENS_MIN_SEVERITY
BRANCH_SCOPE_FILE="$TMP/scope.json"
printf '["src/changed.sh","Makefile"]\n' > "$BRANCH_SCOPE_FILE"
mkdir -p "$TMP/findings"
printf '## Summary\nsrc/changed.sh:1\n' > "$TMP/findings/001-valid.md"
printf '## Summary\nsrc/unchanged.sh:1\n' > "$TMP/findings/002-out.md"
printf '## Summary\nNo verifiable location\n' > "$TMP/findings/003-no-cite.md"
printf '## Summary\nMakefile:2\n' > "$TMP/findings/004-extensionless.md"
mkdir -p "$TMP/findings/nested"
printf 'src/unchanged.sh:1\n' > "$TMP/findings/nested/off.md"
check 'ingestion counts only scoped findings without severity filtering' test "$(count_dry_run_issues "$TMP/findings")" = 2
check 'off-instruction finding is quarantined before *.md consumers' test -f "$TMP/findings/002-out.md.out-of-scope"
check 'nested out-of-scope findings cannot reach recursive consumers' test -f "$TMP/findings/nested/off.md.out-of-scope"
check 'scope rejection keeps a diagnostic' grep -q 'out-of-scope' "$TMP/findings/002-out.md.out-of-scope.reason"
check 'missing citation is quarantined too' test -f "$TMP/findings/003-no-cite.md.out-of-scope"
check 'scope filtering is idempotent' test "$(count_dry_run_issues "$TMP/findings")" = 2
check 'relative-dot citation is accepted' branch_scope_verify_body './src/changed.sh:1'
check 'unchanged supporting citations fail conservatively' bash -c 'source "$1"; MODE=branch-review; BRANCH_SCOPE_FILE="$2"; ! branch_scope_verify_body "src/changed.sh:1 src/unchanged.sh:2"' bash "$SCRIPT_DIR/lib/branch-scope.sh" "$BRANCH_SCOPE_FILE"

jq -n '[{cluster_id:"a",title:"[high] Correct changed code",severity:"high",body:"src/changed.sh:1"},{cluster_id:"b",title:"[low] unrelated",severity:"low",body:"src/unchanged.sh:1"}]' > "$TMP/manifest.json"
check 'synthesized proposals pass an independent manifest scope filter' branch_scope_filter_manifest "$TMP/manifest.json"
check 'hallucinated out-of-scope cluster is absent from published manifest' jq -e 'length==1 and .[0].cluster_id=="a"' "$TMP/manifest.json"
check 'published branch title retains regression convention' jq -e '.[0].title=="[REGRESSION][HIGH] Correct changed code"' "$TMP/manifest.json"
check 'rejected manifest evidence remains inspectable' jq -e 'length==1 and .[0].finding.cluster_id=="b"' "$TMP/manifest.json.out-of-scope.json"
check 'second manifest pass is idempotent' branch_scope_filter_manifest "$TMP/manifest.json"
check 'branch title prefix never duplicates' jq -e '.[0].title=="[REGRESSION][HIGH] Correct changed code"' "$TMP/manifest.json"

printf '["src/with spaces.sh"]\n' > "$BRANCH_SCOPE_FILE"
check 'scope supports quoted paths with spaces' branch_scope_verify_body '`src/with spaces.sh:1`'
# A rename contributes both names to the allowlist used by the entrypoint.
git init -q "$TMP/rename-repo"
git -C "$TMP/rename-repo" config user.name Test
git -C "$TMP/rename-repo" config user.email test@example.invalid
printf 'unchanged contents\n' > "$TMP/rename-repo/old.sh"
git -C "$TMP/rename-repo" add old.sh
git -C "$TMP/rename-repo" commit -qm base
git -C "$TMP/rename-repo" mv old.sh new.sh
git -C "$TMP/rename-repo" commit -qm rename
# Read the exact entrypoint expression so this pins its --no-renames switch.
scope_command="$(sed -n '/git -C "$PROJECT_PATH" diff --no-ext-diff --no-renames --name-only -z/,/Unable to compute branch scope/p' "$SCRIPT_DIR/repolens.sh")"
export PROJECT_PATH="$TMP/rename-repo" BRANCH_MERGE_BASE=HEAD~1 BRANCH_HEAD_SHA=HEAD
die() { return 1; }
eval "$scope_command"
check 'rename allowlist contains both original and destination paths' jq -e 'sort==["new.sh","old.sh"]' "$BRANCH_SCOPE_FILE"
printf '[]\n' > "$BRANCH_SCOPE_FILE"
check 'empty delta accepts no findings' test "$(count_dry_run_issues "$TMP/findings")" = 0
printf 'src/changed.sh:1\n' > "$TMP/findings/missing-scope.md"
rm "$BRANCH_SCOPE_FILE"
check 'missing scope fails closed at ingestion' test "$(count_dry_run_issues "$TMP/findings")" = 0
MODE=audit
printf 'anything\n' > "$TMP/findings/audit.md"
check 'audit findings retain their existing behavior' test "$(count_dry_run_issues "$TMP/findings")" = 1

echo "Results: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
