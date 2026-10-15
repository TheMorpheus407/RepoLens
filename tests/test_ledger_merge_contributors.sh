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

# Collapsing an ID must retain each canonical record's contributor evidence.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
for lib in ledger artifacts; do
  # shellcheck source=/dev/null
  source "$REPO/lib/$lib.sh"
done
failed=0 checks=0
check() {
  checks=$((checks + 1))
  if ! "$@" >/dev/null 2>&1; then
    printf 'FAIL: %s: %s\n' "$scenario" "$*"
    failed=$((failed + 1))
  fi
}
write_finding() {
  local file="$1" lens="$2" target="${3:-}"
  cat > "$OUTPUT_DIR/$file" <<EOF
---
title: Shared state access
severity: high
domain: security
lens: $lens
${target:+status: duplicate}
${target:+duplicate_of: $target}
---
Shared state at src/state.sh:12 needs synchronization.
EOF
}
for scenario in mixed local plain; do
  LOG_BASE="$FIXTURE/$scenario/logs/probe"
  OUTPUT_DIR="$FIXTURE/$scenario/output"
  mkdir -p "$OUTPUT_DIR" "$LOG_BASE/final"
  write_finding 001.md canonical
  if [[ "$scenario" != plain ]]; then
    write_finding 002.md contributor-a 001.md
    write_finding 003.md canonical
    write_finding 004.md contributor-b 003.md
  fi
  if [[ "$scenario" == mixed ]]; then
    printf '%s\n' '[{"title":"Shared state access","domain":"security","lens":"canonical","severity":"low","cluster_id":"manifest-winner","source_finding_paths":["manifest-evidence.md"]}]' \
      > "$LOG_BASE/final/manifest.json"
  fi
  build_finding_registry probe "$OUTPUT_DIR"
  findings="$LOG_BASE/final/findings.jsonl"
  check jq -se 'map(select(.lens == "canonical")) | length == 1 and .[0].status == "new"' "$findings"
  if [[ "$scenario" == mixed ]]; then
    check jq -se 'map(select(.lens == "canonical")) | .[0] | .severity == "low" and .markdown_path == null and .duplicate_group == "manifest-winner" and .source_finding_paths == ["manifest-evidence.md"]' "$findings"
  else
    check jq -se --arg path "$OUTPUT_DIR/001.md" 'map(select(.lens == "canonical")) | .[0] | .severity == "high" and .markdown_path == $path' "$findings"
  fi
  generate_duplicates_md "$findings" "$LOG_BASE/final/DUPLICATES.md"
  if [[ "$scenario" == plain ]]; then
    check jq -se 'all(has("also_reported_by") | not)' "$findings"
    check rg -q 'No duplicate groups' "$LOG_BASE/final/DUPLICATES.md"
  else
    check jq -se --arg dir "$OUTPUT_DIR" 'map(select(.lens == "canonical")) | .[0].also_reported_by == [
      {domain:"security",lens:"contributor-a",markdown_path:($dir+"/002.md")},
      {domain:"security",lens:"contributor-b",markdown_path:($dir+"/004.md")} ]' "$findings"
    check rg -q 'Shared state access' "$LOG_BASE/final/DUPLICATES.md"
    check rg -q 'security/contributor-a' "$LOG_BASE/final/DUPLICATES.md"
    check rg -q 'security/contributor-b' "$LOG_BASE/final/DUPLICATES.md"
  fi
  check test "$(wc -l < "$LOG_BASE/final/findings.csv")" -eq "$(($(wc -l < "$findings") + 1))"
  before="$(sha256sum "$findings" "$LOG_BASE/final/findings.csv")"
  build_finding_registry probe "$OUTPUT_DIR"
  check test "$(sha256sum "$findings" "$LOG_BASE/final/findings.csv")" = "$before"
done
printf 'Registry contributor merge: %s checks, %s failures.\n' "$checks" "$failed"
(( failed == 0 ))
