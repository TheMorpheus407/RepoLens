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

# A finding can lose its delimiter after ingestion but before in-place marking.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/local-dedupe.sh
source "$REPO/lib/local-dedupe.sh"
# shellcheck source=lib/ledger.sh
source "$REPO/lib/ledger.sh"
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
passed=0 failed=0
check() {
  local description="$1"; shift
  if "$@"; then passed=$((passed + 1));
  else failed=$((failed + 1)); printf 'FAIL: %s\n' "$description" >&2; fi
}
for malformed in missing-close missing-close-no-newline missing-open empty; do
  path="$FIXTURE/$malformed.md"
  case "$malformed" in
    missing-close) printf -- '---\ntitle: Saved finding\nseverity: high\nEvidence: keep this\n' > "$path" ;;
    missing-close-no-newline) printf -- '---\ntitle: Saved finding\nseverity: high\nEvidence: keep this' > "$path" ;;
    missing-open) printf -- 'title: Saved finding\nseverity: high\n---\nEvidence: keep this\n' > "$path" ;;
    empty) : > "$path" ;;
  esac
  cp "$path" "$FIXTURE/expected"
  rc=0
  _local_dedupe_mark_file "$path" $'status: duplicate\nduplicate_of: canonical.md' 'Duplicate note' || rc=$?
  check "$malformed rejects marking" test "$rc" -ne 0
  check "$malformed preserves every byte" cmp -s "$FIXTURE/expected" "$path"
  check "$malformed cleans its staging file" test ! -e "$path.rldedupe.$$"
done

# Inject the edit at the write boundary after real ingestion and grouping.
# Both canonical and duplicate writes must preserve the changed file, warn,
# and allow the other group member to be annotated under best-effort semantics.
eval "$(declare -f _local_dedupe_mark_file | sed '1s/_local_dedupe_mark_file/original_mark_file/')"
_local_dedupe_mark_file() {
  local rc=0
  if [[ "$1" == "$damage_target" ]]; then
    command cat "$FIXTURE/expected" > "$1"
  fi
  original_mark_file "$@" || rc=$?
  if [[ "$1" == "$damage_target" ]]; then printf '%s\n' "$rc" > "$FIXTURE/mark-status"; fi
  return "$rc"
}
for role in canonical duplicate; do
  output="$FIXTURE/$role"
  mkdir -p "$output"
  canonical="$output/a.md" duplicate="$output/b.md"
  printf -- '---\ntitle: Saved authorization finding\nseverity: high\n---\nEvidence: src/account.sh:10\n' > "$canonical"
  printf -- '---\ntitle: Saved authorization finding\nseverity: low\n---\nEvidence: src/account.sh:10\n' > "$duplicate"
  damage_target="$canonical" other="$duplicate"
  [[ "$role" == canonical ]] || { damage_target="$duplicate"; other="$canonical"; }
  # Leave no final newline so an attempted reserialization is detected too.
  printf -- '---\ntitle: Concurrent edit\nseverity: high\nEvidence: preserve my edit' > "$FIXTURE/expected"
  dedupe_local_markdown "$output" > "$FIXTURE/dedupe.log" 2>&1
  check "$role write rejects the incomplete input" test "$(cat "$FIXTURE/mark-status")" -ne 0
  check "$role concurrent edit survives dedupe" cmp -s "$FIXTURE/expected" "$damage_target"
  check "$role write failure is reported" grep -q 'failed to' "$FIXTURE/dedupe.log"
  check "$role write cleans staging" test ! -e "$damage_target.rldedupe.$$"
  check 'other member is annotated' grep -q '^<!-- repolens-dedupe:begin -->$' "$other"
done
printf 'Results: %s passed, %s failed\n' "$passed" "$failed"
test "$failed" -eq 0
