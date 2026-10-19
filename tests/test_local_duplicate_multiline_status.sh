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

# Refuse multiline status rewrites before a managed-looking first line is removed.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
FIXTURE="$(mktemp -d)" || exit 1
trap 'rm -rf -- "$FIXTURE"' EXIT
# shellcheck source=/dev/null
source "$REPO/lib/local-dedupe.sh" || exit 1
failed=0 checks=0
check() {
  checks=$((checks + 1))
  if ! "$@" >/dev/null 2>&1; then
    printf 'FAIL: %s: %s\n' "$scenario" "$*"
    failed=$((failed + 1))
  fi
}
# The valid plain YAML scalar folds to "duplicate pending". Deleting only its
# first line would attach "pending" to the preceding title and lose the status.
for indent in '' '  '; do
  for padding in '' ' ' $'\t'; do
    for mode in canonical duplicate; do
      scenario="folded/$indent/$padding/$mode"
      file="$FIXTURE/folded.md"
      printf '%s\n' --- "${indent}title: Shared state" \
        "${indent}status$padding: duplicate" "${indent}  pending" \
        "${indent}severity: high" --- body > "$file" || exit 1
      cp "$file" "$FIXTURE/expected.md" || exit 1
      addition=''
      [[ "$mode" != duplicate ]] || addition=$'status: duplicate\nduplicate_of: canonical.md'
      rc=0
      _local_dedupe_mark_file "$file" "$addition" note > "$FIXTURE/rewrite.log" 2>&1 || rc=$?
      check test "$rc" -ne 0
      check grep -q 'not a single-line scalar' "$FIXTURE/rewrite.log"
      check cmp -s "$file" "$FIXTURE/expected.md"
      check test "$(find "$FIXTURE" -name '*.rldedupe.*' | wc -l)" -eq 0
    done
  done
done
# Exercise the real grouped caller in both roles, including repeated dedupe.
for role in canonical duplicate; do
  scenario="grouped/$role"
  output="$FIXTURE/$role"
  mkdir -p "$output" || exit 1
  for name in canonical duplicate; do
    severity=high
    [[ "$name" != canonical ]] || severity=critical
    {
      printf '%s\n' --- 'title: Unsafe access to shared state'
      [[ "$name" != "$role" ]] || printf '%s\n' 'status : duplicate' '  pending'
      printf '%s\n' "severity: $severity" 'domain: security' "lens: probe-$name" --- body
    } > "$output/$name.md" || exit 1
  done
  cp "$output/$role.md" "$FIXTURE/expected.md" || exit 1
  check dedupe_local_markdown "$output"
  check cmp -s "$output/$role.md" "$FIXTURE/expected.md"
  check dedupe_local_markdown "$output"
  check cmp -s "$output/$role.md" "$FIXTURE/expected.md"
done
# Blank lines and comments after a complete scalar do not extend its value.
scenario=single-line-with-comments
file="$FIXTURE/comments.md"
printf '%s\n' --- 'title: Shared state' 'status : duplicate # managed' \
  '' '  # status comment' 'severity: high' --- body > "$file" || exit 1
check _local_dedupe_mark_file "$file" '' ''
check test "$(grep -cE '^status[[:space:]]*:' "$file" || true)" -eq 0
check grep -qxF '  # status comment' "$file"
printf 'Local duplicate multiline status: %s checks, %s failures.\n' "$checks" "$failed"
(( failed == 0 ))
