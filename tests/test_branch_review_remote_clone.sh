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

# #400: real git graphs verify URL clone ancestry and selected head semantics.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/core.sh"
TEST_DIR="$(mktemp -d)"
RUN_IDS=()
# shellcheck disable=SC2329 # Invoked by EXIT.
cleanup() {
  local run_id
  for run_id in "${RUN_IDS[@]:-}"; do
    [[ -z "$run_id" ]] || rm -rf -- "$SCRIPT_DIR/logs/$run_id"
  done
  rm -rf -- "$TEST_DIR"
}
trap cleanup EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$TEST_DIR/gitconfig"
git config --file "$GIT_CONFIG_GLOBAL" "url.file://$TEST_DIR/source.insteadOf" https://refs.example.invalid/project.git
export GIT_AUTHOR_NAME=RepoLens GIT_COMMITTER_NAME=RepoLens
export GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_EMAIL=test@example.invalid
git init -q --initial-branch main "$TEST_DIR/source"
printf 'before\n' > "$TEST_DIR/source/app.txt"
git -C "$TEST_DIR/source" add app.txt
git -C "$TEST_DIR/source" commit -qm base
base="$(git -C "$TEST_DIR/source" rev-parse HEAD)"
git -C "$TEST_DIR/source" tag v1
git -C "$TEST_DIR/source" switch -qc feature
printf 'after\n' > "$TEST_DIR/source/app.txt"
git -C "$TEST_DIR/source" commit -qam feature
first_feature="$(git -C "$TEST_DIR/source" rev-parse HEAD)"
printf 'second feature\n' > "$TEST_DIR/source/app.txt"
git -C "$TEST_DIR/source" commit -qam feature-two
head="$(git -C "$TEST_DIR/source" rev-parse HEAD)"
git -C "$TEST_DIR/source" branch 'topic/nested' "$head"
git -C "$TEST_DIR/source" branch 'topic/$literal;name' "$head"
git -C "$TEST_DIR/source" branch release "$head"
git -C "$TEST_DIR/source" tag release "$first_feature"
git -C "$TEST_DIR/source" tag -am 'annotated release' annotated "$first_feature"
git -C "$TEST_DIR/source" switch -q main
printf 'base-only\n' > "$TEST_DIR/source/base.txt"
git -C "$TEST_DIR/source" add base.txt
git -C "$TEST_DIR/source" commit -qm base-only
default_parent="$(git -C "$TEST_DIR/source" rev-parse HEAD)"
printf 'base-only two\n' > "$TEST_DIR/source/base.txt"
git -C "$TEST_DIR/source" commit -qam base-only-two
default_head="$(git -C "$TEST_DIR/source" rev-parse HEAD)"
source_refs="$(git -C "$TEST_DIR/source" for-each-ref --format='%(refname) %(objectname)')"
passed=0
failed=0
check() {
  if "$@"; then passed=$((passed + 1)); else failed=$((failed + 1)); printf 'FAIL: %s\n' "$*"; fi
}
check clone_project_for_mode "file://$TEST_DIR/source" "$TEST_DIR/review" branch-review main feature
check test "$(git -C "$TEST_DIR/review" rev-parse --is-shallow-repository)" = false
check test "$(git -C "$TEST_DIR/review" rev-parse HEAD)" = "$head"
check test "$(git -C "$TEST_DIR/review" merge-base main HEAD)" = "$base"
check test "$(git -C "$TEST_DIR/review" diff --name-only main...HEAD)" = app.txt
check clone_project_for_mode "file://$TEST_DIR/source" "$TEST_DIR/remote-base" branch-review feature HEAD
check test "$(git -C "$TEST_DIR/remote-base" merge-base feature HEAD)" = "$base"
check clone_project_for_mode "file://$TEST_DIR/source" "$TEST_DIR/tag" branch-review main v1
check test "$(git -C "$TEST_DIR/tag" rev-parse HEAD)" = "$base"
check clone_project_for_mode "file://$TEST_DIR/source" "$TEST_DIR/sha" branch-review main "$head"
check test "$(git -C "$TEST_DIR/sha" rev-parse HEAD)" = "$head"
check clone_project_for_mode "file://$TEST_DIR/source" "$TEST_DIR/audit" audit
check test "$(git -C "$TEST_DIR/audit" rev-parse --is-shallow-repository)" = true
check test "${CLONED_BRANCH_BASE_SHA:-}" = ''
check test "${CLONED_BRANCH_HEAD_SHA:-}" = ''
clone_project_for_mode "file://$TEST_DIR/source" "$TEST_DIR/missing" branch-review main does-not-exist >/dev/null 2>&1
check test "$?" -ne 0

# Branch names are aliases; revision expressions must remain Git expressions.
case_index=0
ref_cases=(
  "main|feature~1|$default_head|$first_feature"
  "feature~1|feature|$first_feature|$head"
  "refs/heads/feature~1|refs/heads/feature|$first_feature|$head"
  "main|refs/heads/feature~1|$default_head|$first_feature"
  "main|heads/feature|$default_head|$head"
  "main|topic/nested^|$default_head|$first_feature"
  "main|topic/\$literal;name~1|$default_head|$first_feature"
  "main|refs/heads/release|$default_head|$head"
  "main|release|$default_head|$first_feature"
  "main|refs/tags/release|$default_head|$first_feature"
  "main|annotated|$default_head|$first_feature"
  "main|annotated^{}|$default_head|$first_feature"
  "$base|$head|$base|$head"
  "origin/feature~1|refs/remotes/origin/feature|$first_feature|$head"
  "HEAD|feature|$default_head|$head"
  "HEAD~1|feature|$default_parent|$head"
  "main|HEAD~1|$default_head|$default_parent"
)
for ref_case in "${ref_cases[@]}"; do
  IFS='|' read -r base_ref head_ref expected_base expected_head <<< "$ref_case"
  case_index=$((case_index + 1))
  destination="$TEST_DIR/ref-$case_index"
  clone_project_for_mode "file://$TEST_DIR/source" "$destination" branch-review "$base_ref" "$head_ref" > "$TEST_DIR/ref-$case_index.log" 2>&1
  check test "$?" = 0
  check test "$(git -C "$destination" rev-parse HEAD)" = "$expected_head"
  check test "${CLONED_BRANCH_BASE_SHA:-}" = "$expected_base"
  check test "${CLONED_BRANCH_HEAD_SHA:-}" = "$expected_head"
done
for bad_ref in does-not-exist 'feature~999' 'feature:app.txt' '--help' 'refs/heads/feature:app.txt'; do
  for target in base head; do
    case_index=$((case_index + 1))
    base_ref=main head_ref=feature
    if [[ "$target" == base ]]; then base_ref="$bad_ref"; else head_ref="$bad_ref"; fi
    clone_project_for_mode "file://$TEST_DIR/source" "$TEST_DIR/invalid-$case_index" branch-review "$base_ref" "$head_ref" > "$TEST_DIR/invalid-$case_index.log" 2>&1
    check test "$?" -ne 0
  done
done
check test "${CLONED_BRANCH_BASE_SHA:-}" = ''
check test "${CLONED_BRANCH_HEAD_SHA:-}" = ''

# Actual CLI: downstream provenance must keep the pre-checkout interpretation,
# especially when HEAD~1 would mean a different commit after detached checkout.
mkdir -p "$TEST_DIR/bin"
export REPOLENS_REF_TEST_DIR="$TEST_DIR"
for executable in codex gh glab tea fj; do
  cat > "$TEST_DIR/bin/$executable" <<'FORBIDDEN'
#!/usr/bin/env bash
touch "$REPOLENS_REF_TEST_DIR/forbidden-executable"
exit 99
FORBIDDEN
  chmod +x "$TEST_DIR/bin/$executable"
done
export PATH="$TEST_DIR/bin:$PATH"
contains() { [[ "$1" == *"$2"* ]]; }
for ref_case in "${ref_cases[@]}"; do
  IFS='|' read -r base_ref head_ref expected_base expected_head <<< "$ref_case"
  case_index=$((case_index + 1))
  bash "$SCRIPT_DIR/repolens.sh" --project https://refs.example.invalid/project.git \
    --agent codex --mode branch-review --branch-base "$base_ref" --branch-head "$head_ref" \
    --local --output "$TEST_DIR/reports" --focus injection --dry-run --yes \
    > "$TEST_DIR/cli-$case_index.log" 2>&1
  check test "$?" = 0
  output="$(cat "$TEST_DIR/cli-$case_index.log")"
  run_id="$(sed -n 's/.*RepoLens run \([^ ]*\) starting.*/\1/p' "$TEST_DIR/cli-$case_index.log")"
  [[ -z "$run_id" ]] || RUN_IDS+=("$run_id")
  check contains "$output" "Branch base:  $base_ref ($expected_base)"
  check contains "$output" "Branch head:  $head_ref ($expected_head)"
done
for bad_ref in does-not-exist 'feature~999' 'feature:app.txt' '--help'; do
  for target in base head; do
    case_index=$((case_index + 1))
    base_ref=main head_ref=feature
    if [[ "$target" == base ]]; then base_ref="$bad_ref"; else head_ref="$bad_ref"; fi
    output="$(bash "$SCRIPT_DIR/repolens.sh" --project https://refs.example.invalid/project.git \
      --agent codex --mode branch-review --branch-base "$base_ref" --branch-head "$head_ref" \
      --local --output "$TEST_DIR/reports" --focus injection --dry-run --yes 2>&1)"
    check test "$?" -ne 0
    check contains "$output" "Unable to resolve --branch-$target $bad_ref"
  done
done
check test ! -e "$TEST_DIR/forbidden-executable"
check test "$(git -C "$TEST_DIR/source" for-each-ref --format='%(refname) %(objectname)')" = "$source_refs"
printf 'Results: %s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
