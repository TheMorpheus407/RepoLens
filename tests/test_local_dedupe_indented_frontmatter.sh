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

# Real dedupe/rebuild must preserve uniformly indented root mappings.
# shellcheck disable=SC2034 # LOG_BASE is consumed by the registry builder.
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
for scenario in plain-2 plain-4 space-2 space-4 tab-2 tab-4; do
  spacing="${scenario%-*}"
  printf -v indent '%*s' "${scenario##*-}" ''
  padding=''
  case "$spacing" in space) padding=' ' ;; tab) padding=$'\t' ;; esac
  output="$FIXTURE/$spacing/indent-${#indent}"
  mkdir -p "$output/performance/algorithm" "$output/security/authorization"
  canonical="$output/performance/algorithm/a.md"
  duplicate="$output/security/authorization/b.md"
  for path in "$canonical" "$duplicate"; do
    severity=high
    [[ "$path" == "$canonical" ]] || severity=low
    {
      printf '%s\n' '---'
      # An old provenance block BEFORE other root fields exercises stripping
      # without consuming equally indented canonical metadata on the next pass.
      printf '%salso_reported_by%s:\n' "$indent" "$padding"
      printf '%s  - lens: stale\n%s    domain: stale\n' "$indent" "$indent"
      printf '%stitle: Repeated work for the same request\n' "$indent"
      printf '%sseverity: %s\n' "$indent" "$severity"
      printf '%scomplexity: 3\n' "$indent"
      # Nested names owned by dedupe are user data, not root dedupe marks.
      printf '%s%s\n' "$indent" 'details:'
      printf '%s  status: duplicate\n%s  duplicate_of: nested-only.md\n%s  also_reported_by: keep nested data\n' "$indent" "$indent" "$indent"
      printf '%s\n' '---' 'Evidence: src/account.sh:10'
    } > "$path"
  done
  build_findings_jsonl_from_local "$output" "$FIXTURE/before.jsonl"
  jq -cs 'map(del(.also_reported_by) | .status = "new")' "$FIXTURE/before.jsonl" > "$FIXTURE/metadata.json"
  dedupe_local_markdown "$output"
  build_findings_jsonl_from_local "$output" "$FIXTURE/after.jsonl"
  jq -cs 'map(del(.also_reported_by) | .status = "new")' "$FIXTURE/after.jsonl" > "$FIXTURE/rebuilt-metadata.json"
  check "${#indent}-space metadata and stable IDs survive dedupe" cmp -s "$FIXTURE/metadata.json" "$FIXTURE/rebuilt-metadata.json"
  check 'canonical keeps directory fallback, type, complexity and contributor' jq -se '
    length == 2 and any(.[]; .severity == "high" and .status == "new"
      and .domain == "performance" and .lens == "algorithm"
      and .type == "performance-risk" and .complexity == 3
      and .also_reported_by[0].domain == "security")
      and any(.[]; .severity == "low" and .status == "duplicate")' "$FIXTURE/after.jsonl"
  LOG_BASE="$FIXTURE/run-${#indent}"
  check 'registry validates and publishes after dedupe' build_finding_registry fixture "$output"
  for path in "$canonical" "$duplicate"; do
    check 'stale root provenance is removed' test "$(grep -c 'lens: stale' "$path" || true)" -eq 0
    check 'nested status is preserved' grep -qxF "${indent}  status: duplicate" "$path"
    check 'nested link is preserved' grep -qxF "${indent}  duplicate_of: nested-only.md" "$path"
    check 'nested provenance is preserved' grep -qxF "${indent}  also_reported_by: keep nested data" "$path"
  done
  before="$(git hash-object -- "$canonical" "$duplicate")"
  dedupe_local_markdown "$output"
  check 'repeated dedupe is byte-identical' test "$(git hash-object -- "$canonical" "$duplicate")" = "$before"
  build_findings_jsonl_from_local "$output" "$FIXTURE/repeated.jsonl"
  check 'repeated registry is byte-identical' cmp -s "$FIXTURE/after.jsonl" "$FIXTURE/repeated.jsonl"
done
printf 'Results: %s passed, %s failed\n' "$passed" "$failed"
test "$failed" -eq 0
