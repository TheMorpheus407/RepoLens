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

# Relocating an alias can bind it to a later definition of the same anchor.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/local-dedupe.sh
source "$REPO/lib/local-dedupe.sh"
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
checks=0 failed=0
# Count failures across all cases and report a failing aggregate exit status.
check() {
  checks=$((checks + 1))
  if ! "$@" >/dev/null 2>&1; then
    printf 'FAIL: %s: %s\n' "$scenario" "$*" >&2
    failed=$((failed + 1))
  fi
}
# Every refusal preserves all bytes, including an existing saved status.
refuse() {
  local additions="$1" rc=0
  cp "$FIXTURE/input.md" "$FIXTURE/expected.md"
  _local_dedupe_mark_file "$FIXTURE/input.md" "$additions" '' || rc=$?
  check test "$rc" -ne 0
  check cmp -s "$FIXTURE/expected.md" "$FIXTURE/input.md"
  check test ! -e "$FIXTURE/input.md.rldedupe.$$"
}
duplicate=$'status: duplicate\nduplicate_of: canonical.md'
for indent in '' '  '; do
  for value in '*workflow' '[*workflow]' '{phase: *workflow}' \
    '{*workflow: pending}' '{?*workflow : pending}' '[?*workflow : pending]' \
    '[pending, {phase: [*workflow]}]'; do
    scenario="alias / indent=${#indent} / $value"
    original="${indent}status : $value # keep binding"
    printf -- '---\n%stitle: Saved finding\n%scurrent: &workflow needs-validation\n%s\n%snext: &workflow approved\n---\nEvidence: keep this\n' \
      "$indent" "$indent" "$original" "$indent" > "$FIXTURE/input.md"
    cp "$FIXTURE/input.md" "$FIXTURE/original.md"
    check _local_dedupe_mark_file "$FIXTURE/input.md" '' ''
    check cmp -s "$FIXTURE/original.md" "$FIXTURE/input.md"
    refuse "$duplicate"
    refuse "$duplicate"
    check _local_dedupe_mark_file "$FIXTURE/input.md" '' ''
    check cmp -s "$FIXTURE/original.md" "$FIXTURE/input.md"

    # Backups written by an older version cannot be safely relocated either.
    backup="$(jq -nc --arg line "$original" '$line')"
    printf -- '---\n%stitle: Saved finding\n%scurrent: &workflow needs-validation\n%sstatus: duplicate\n%srepolens_dedupe_original_status: %s\n%snext: &workflow approved\n---\nEvidence: keep this\n' \
      "$indent" "$indent" "$indent" "$indent" "$backup" "$indent" > "$FIXTURE/input.md"
    refuse ''
    refuse "$duplicate"
  done
done

# Asterisks in strings, plain scalars or comments are ordinary user data.
for value in '"*workflow"' "'*workflow'" 'pending *workflow' \
  'pending # *workflow' '[pending *workflow, "*workflow"]' \
  '{phase:*workflow pending}' '?*workflow'; do
  scenario="literal asterisk / $value"
  printf -- '---\ntitle: Saved finding\nstatus: %s\n---\nEvidence: keep this\n' "$value" > "$FIXTURE/input.md"
  cp "$FIXTURE/input.md" "$FIXTURE/original.md"
  check _local_dedupe_mark_file "$FIXTURE/input.md" "$duplicate" ''
  check grep -qxF 'status: duplicate' "$FIXTURE/input.md"
  check _local_dedupe_mark_file "$FIXTURE/input.md" '' ''
  check cmp -s "$FIXTURE/original.md" "$FIXTURE/input.md"
done

# Exercise warning/registry behavior through the public grouping path. Refusal
# keeps the alias in place and both findings actionable until metadata repair.
scenario='real grouping / alias refusal and repair'
output="$FIXTURE/output"
mkdir -p "$output"
printf -- '---\ntitle: Saved finding\nseverity: high\ncurrent: &workflow needs-validation\nstatus: *workflow\nnext: &workflow approved\n---\nEvidence: src/state.sh:12\n' > "$output/a.md"
printf -- '---\ntitle: Saved finding\nseverity: critical\n---\nEvidence: src/state.sh:12\n' > "$output/b.md"
cp "$output/a.md" "$FIXTURE/original.md"
rc=0
dedupe_local_markdown "$output" > "$FIXTURE/grouping.log" 2> "$FIXTURE/warning.log" || rc=$?
check test "$rc" -eq 0
check grep -q 'failed to mark duplicate' "$FIXTURE/warning.log"
check cmp -s "$FIXTURE/original.md" "$output/a.md"
check build_findings_jsonl_from_local "$output" "$FIXTURE/records.jsonl"
check jq -se 'length == 2 and all(.[]; .status == "new")' "$FIXTURE/records.jsonl"
sed -i 's/status: \*workflow/status: needs-validation/' "$output/a.md"
check dedupe_local_markdown "$output"
check build_findings_jsonl_from_local "$output" "$FIXTURE/records.jsonl"
check jq -se 'length == 2 and ([.[] | select(.status == "duplicate")] | length) == 1' "$FIXTURE/records.jsonl"
sed -i 's/severity: high/severity: critical/' "$output/a.md"
sed -i 's/severity: critical/severity: high/' "$output/b.md"
check dedupe_local_markdown "$output"
check grep -qxF 'status: needs-validation' "$output/a.md"
check build_findings_jsonl_from_local "$output" "$FIXTURE/records.jsonl"
check jq -se 'length == 2 and ([.[] | select(.status == "duplicate")] | length) == 1' "$FIXTURE/records.jsonl"
printf 'Local dedupe status aliases: %s checks, %s failures.\n' "$checks" "$failed"
(( failed == 0 ))
