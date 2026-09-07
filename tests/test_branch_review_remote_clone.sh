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
trap 'rm -rf "$TEST_DIR"' EXIT
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
head="$(git -C "$TEST_DIR/source" rev-parse HEAD)"
git -C "$TEST_DIR/source" switch -q main
printf 'base-only\n' > "$TEST_DIR/source/base.txt"
git -C "$TEST_DIR/source" add base.txt
git -C "$TEST_DIR/source" commit -qm base-only
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
clone_project_for_mode "file://$TEST_DIR/source" "$TEST_DIR/missing" branch-review main does-not-exist >/dev/null 2>&1
check test "$?" -ne 0
printf 'Results: %s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
