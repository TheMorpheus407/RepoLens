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

# Failed atomic promotion must retain prior output and report failure honestly.
# shellcheck disable=SC2329 # mv is called indirectly by the generators.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO/lib/artifacts.sh"
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
failed=0 checks=0
check() {
  checks=$((checks + 1))
  if ! "$@"; then
    printf 'FAIL: %s: %s\n' "$generator" "$*"
    failed=$((failed + 1))
  fi
}
mv() {
  [[ "$fail_promotion" == false ]] || return 1
  command mv "$@"
}
printf '%s\n' '{"id":"probe","title":"Current finding","severity":"high","status":"new","also_reported_by":[{"domain":"security","lens":"probe"}]}' > "$FIXTURE/findings.jsonl"
for generator in generate_todo_md generate_summary_md generate_needs_review_md generate_duplicates_md; do
  mkdir "$FIXTURE/$generator"
  out="$FIXTURE/$generator/report.md"
  for prior in false true; do
    rm -f "$out"
    if $prior; then printf 'Prior complete report\n' > "$out"; fi
    fail_promotion=true
    rc=0
    "$generator" "$FIXTURE/findings.jsonl" "$out" || rc=$?
    check test "$rc" -eq 1
    if $prior; then
      check test "$(cat "$out")" = 'Prior complete report'
    else
      check test ! -e "$out"
    fi
    check test "$(find "$FIXTURE/$generator" -type f -name '.*' | wc -l)" -eq 0
    fail_promotion=false
    check "$generator" "$FIXTURE/findings.jsonl" "$out"
    check test -s "$out"
    check test "$(find "$FIXTURE/$generator" -type f -name '.*' | wc -l)" -eq 0
  done
  # repolens-r6-p2-5: mv must replace a report, never place scratch files
  # inside an existing directory (including a symlink to a directory).
  for kind in directory symlink; do
    rm -f "$out"
    target="$out"
    if [[ "$kind" == symlink ]]; then target="$FIXTURE/$generator/target"; fi
    mkdir "$target"
    printf 'Keep this existing content\n' > "$target/sentinel"
    if [[ "$kind" == symlink ]]; then ln -s "$target" "$out"; fi
    for _attempt in 1 2; do
      rc=0
      "$generator" "$FIXTURE/findings.jsonl" "$out" || rc=$?
      check test "$rc" -eq 1
      check test -d "$out"
      check test "$(cat "$out/sentinel")" = 'Keep this existing content'
      check test "$(find "$FIXTURE/$generator" -type f -name '.*' | wc -l)" -eq 0
    done
    rm -rf -- "$out"
    if [[ "$kind" == symlink ]]; then rm -rf -- "$target"; fi
    check "$generator" "$FIXTURE/findings.jsonl" "$out"
    check test -s "$out"
  done
done
printf 'Triage atomic failure: %s checks, %s failures.\n' "$checks" "$failed"
(( failed == 0 ))
