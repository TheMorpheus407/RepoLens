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

# Local dedupe owns only the exact duplicate scalar, never a status prefix.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
# shellcheck source=/dev/null
source "$REPO/lib/local-dedupe.sh"
failed=0 checks=0
check() {
  checks=$((checks + 1))
  if ! "$@" >/dev/null 2>&1; then
    printf 'FAIL: %s: %s\n' "$scenario" "$*"
    failed=$((failed + 1))
  fi
}
for padding in '' ' ' $'\t'; do
  for value in duplicate 'duplicate  ' '"duplicate"' "'duplicate'" \
      'duplicate # managed' '"duplicate" # managed' "'duplicate' # managed"; do
    scenario="managed/$padding/$value"
    printf '%s\n' --- 'title: Duplicate status probe' "status$padding: $value" --- body > "$FIXTURE/managed.md"
    _local_dedupe_mark_file "$FIXTURE/managed.md" '' ''
    check test "$(grep -cE '^status[[:space:]]*:' "$FIXTURE/managed.md" || true)" -eq 0
  done
  for value in duplicate-pending duplicate_pending 'duplicate pending' 'duplicate#literal' \
      '"duplicate-pending"' "'duplicate-pending'" '"duplicate pending"' "'duplicate pending'" \
      '"duplicate\"pending"' "'duplicate''pending'" '"duplicate' "'duplicate" \
      "duplicate'" 'duplicate"' '"duplicate-pending" # foreign'; do
    scenario="foreign/$padding/$value"
    printf '%s\n' --- 'title: Duplicate status probe' "status$padding: $value" --- body > "$FIXTURE/foreign.md"
    cp "$FIXTURE/foreign.md" "$FIXTURE/expected.md"
    _local_dedupe_mark_file "$FIXTURE/foreign.md" '' ''
    check cmp -s "$FIXTURE/foreign.md" "$FIXTURE/expected.md"
  done
done
# Exercise the actual grouping path: a padded foreign status on the canonical
# must survive repeated dedupe while the other finding receives managed marks.
for padding in ' ' $'\t'; do
  scenario="grouped/$padding"
  output="$FIXTURE/group"
  mkdir -p "$output"
  for name in canonical duplicate; do
    severity=high
    [[ "$name" != canonical ]] || severity=critical
    printf '%s\n' --- 'title: Unsafe access to shared state' "severity: $severity" \
      'domain: security' "lens: probe-$name" --- body > "$output/$name.md"
  done
  sed -i "/^severity:/a status$padding: \"duplicate-pending\"" "$output/canonical.md"
  dedupe_local_markdown "$output" >/dev/null 2>&1
  check grep -qxF "status$padding: \"duplicate-pending\"" "$output/canonical.md"
  check grep -qxF 'status: duplicate' "$output/duplicate.md"
  before="$(sha256sum "$output/"*.md)"
  dedupe_local_markdown "$output" >/dev/null 2>&1
  check test "$before" = "$(sha256sum "$output/"*.md)"
done
printf 'Local duplicate status values: %s checks, %s failures.\n' "$checks" "$failed"
(( failed == 0 ))
