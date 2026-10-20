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

# Registry IDs retain legacy ASCII preimages and tolerate local title bytes.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/lib/ledger.sh"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
FAIL=0
check() {
  local description="$1"
  shift
  if "$@"; then
    printf 'PASS: %s\n' "$description"
  else
    printf 'FAIL: %s\n' "$description"
    FAIL=$((FAIL + 1))
  fi
}
check_ascii() {
  local title expected actual
  # These IDs are frozen from master before PR #544, including its boundary
  # punctuation quirk (remove one boundary space before collapsing runs).
  while IFS='|' read -r title expected; do
    actual="$(finding_id security injection "$title")" || {
      printf 'FAIL: could not generate ASCII identity for %s\n' "$title"
      return 1
    }
    check "ASCII identity: $title" test "$actual" = "$expected"
  done <<'CASES'
Missing CSRF token|fnd-c85e3de3f641
Unchecked read()|fnd-2439a83c0a38
**Cache miss**|fnd-091688a03692
[High] Cache!|fnd-c96e35acdd72
CASES
}
check_ascii || FAIL=$((FAIL + 1))
# Normal production ingestion loads the synthesizer too.
# shellcheck source=/dev/null
source "$ROOT/lib/synthesize.sh"
check_ascii || FAIL=$((FAIL + 1))

# Invalid bytes separate words instead of silently concatenating their text.
invalid_id="$(finding_id security injection $'bad\xffbytes')" || exit 1
separator_id="$(finding_id security injection 'bad bytes')" || exit 1
locale_id="$(LC_ALL=C finding_id security injection $'bad\xffbytes')" || exit 1
replacement_id="$(finding_id security injection 'bad�bytes')" || exit 1
check 'invalid bytes normalize as separators' test "$invalid_id" = "$separator_id"
check 'invalid-byte identity is locale independent' test "$invalid_id" = "$locale_id"
check 'literal replacement character remains title content' test "$invalid_id" != "$replacement_id"

# An invalid byte in one ordinary finding must not stop all other records
# from refreshing. The raw Markdown evidence must remain byte-identical.
LOG_BASE="$fixture/run"
local_dir="$fixture/local"
mkdir -p "$local_dir"
printf -- '---\ntitle: café\nseverity: high\ndomain: security\nlens: injection\n---\nEvidence.\n' > "$local_dir/1.md"
check 'initial local registry builds' build_finding_registry probe "$local_dir"
printf -- '---\ntitle: Latin-1 caf\351\nseverity: high\ndomain: security\nlens: injection\n---\nEvidence.\n' > "$local_dir/2.md"
cp "$local_dir/2.md" "$fixture/invalid.before"
check 'invalid UTF-8 title does not abort registry rebuild' build_finding_registry probe "$local_dir"
check 'both local findings appear in JSONL' jq -se 'length == 2 and ([.[].id] | unique | length == 2)' "$LOG_BASE/final/findings.jsonl"
check 'both local findings appear in CSV' test "$(wc -l < "$LOG_BASE/final/findings.csv")" -eq 3
check 'invalid-byte Markdown evidence is unchanged' cmp "$fixture/invalid.before" "$local_dir/2.md"
printf 'Results: %s failed\n' "$FAIL"
(( FAIL == 0 ))
