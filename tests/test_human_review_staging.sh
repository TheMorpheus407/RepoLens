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

# repolens-r15-p5-1: a predictable staging symlink must never redirect output.
# shellcheck disable=SC2034 # Production functions consume LOG_BASE.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/human_review.sh"
set -euo pipefail
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
LOG_BASE="$FIXTURE/run"
mkdir -p "$LOG_BASE/final"
printf '%s\n' '{"id":"f1","title":"Current finding","severity":"high","status":"new"}' > "$LOG_BASE/final/findings.jsonl"
printf 'Unrelated original bytes\n' > "$FIXTURE/unrelated"
ln -s "$FIXTURE/unrelated" "$LOG_BASE/final/HUMAN_REVIEW.md.tmp.$$"
render_human_review_digest probe
[[ "$(cat "$FIXTURE/unrelated")" == 'Unrelated original bytes' ]]
[[ ! -L "$LOG_BASE/final/HUMAN_REVIEW.md" ]]
grep -q 'Current finding' "$LOG_BASE/final/HUMAN_REVIEW.md"
# Allocation failure preserves the saved report rather than using a fallback.
cp "$LOG_BASE/final/HUMAN_REVIEW.md" "$FIXTURE/saved"
# Simulate an allocator failure without creating a stage.
mktemp() { return 74; }
rc=0
render_human_review_digest probe || rc=$?
unset -f mktemp
[[ "$rc" != 0 ]]
cmp "$FIXTURE/saved" "$LOG_BASE/final/HUMAN_REVIEW.md"
[[ "$(cat "$FIXTURE/unrelated")" == 'Unrelated original bytes' ]]
# Failed rendering removes only its own unique stage.
# Simulate a renderer failure after successful stage allocation.
jq() { return 74; }
rc=0
render_human_review_digest probe || rc=$?
unset -f jq
[[ "$rc" != 0 ]]
cmp "$FIXTURE/saved" "$LOG_BASE/final/HUMAN_REVIEW.md"
[[ "$(find "$LOG_BASE/final" -maxdepth 1 -type f -name 'HUMAN_REVIEW.md.tmp.*' | wc -l)" -eq 0 ]]
# Simulate exact-path promotion failure after a complete successful render.
# shellcheck disable=SC2329 # Called indirectly by the sourced artifact helper.
python3() { return 74; }
rc=0
render_human_review_digest probe || rc=$?
unset -f python3
[[ "$rc" != 0 ]]
cmp "$FIXTURE/saved" "$LOG_BASE/final/HUMAN_REVIEW.md"
[[ "$(find "$LOG_BASE/final" -maxdepth 1 -type f -name 'HUMAN_REVIEW.md.tmp.*' | wc -l)" -eq 0 ]]
[[ "$(readlink "$LOG_BASE/final/HUMAN_REVIEW.md.tmp.$$")" == "$FIXTURE/unrelated" ]]
[[ "$(cat "$FIXTURE/unrelated")" == 'Unrelated original bytes' ]]
printf 'Results: staging symlink, allocation, render and promotion failures passed\n'
