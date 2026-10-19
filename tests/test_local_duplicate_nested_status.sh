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

# Nested statuses and block-scalar text must not prevent root-status surgery.
# shellcheck disable=SC2034 # LOG_BASE is consumed by the report libraries.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
FIXTURE="$(mktemp -d)" || exit 1
trap 'rm -rf -- "$FIXTURE"' EXIT
for lib in local-dedupe ledger human_review artifacts; do
  # shellcheck source=/dev/null
  source "$REPO/lib/$lib.sh" || exit 1
done
failed=0 checks=0
check() {
  checks=$((checks + 1))
  if ! "$@" >/dev/null 2>&1; then
    printf 'FAIL: %s: %s\n' "$scenario" "$*"
    failed=$((failed + 1))
  fi
}
metadata() {
  local indent="$1" kind="$2"
  case "$kind" in
    nested) printf '%s%s\n' "$indent" 'provenance:' "$indent" '  status: [pending, reviewed]' ;;
    literal) printf '%s%s\n' "$indent" 'description: |' "$indent" '  status: [draft]' ;;
    folded) printf '%s%s\n' "$indent" 'description: >-' "$indent" '  status: "unfinished literal text' ;;
  esac
}
# Put unrelated metadata first, so root inference must use its parent mapping.
# Cover absent and custom root statuses, indentation, both rewrite roles and
# restore-only cleanup of the archived custom entry.
for indent in '' '  '; do
  for kind in nested literal folded; do
    for status in absent custom; do
      for mode in canonical duplicate; do
        scenario="$kind/${#indent}/$status/$mode"
        file="$FIXTURE/direct.md"
        {
          printf '%s\n' ---
          metadata "$indent" "$kind"
          printf '%s%s\n' "$indent" 'title: Shared state'
          [[ "$status" != custom ]] || printf '%sstatus : "duplicate-pending" # original\n' "$indent"
          printf '%s\n' --- body
        } > "$file" || exit 1
        cp "$file" "$FIXTURE/expected.md" || exit 1
        addition=''
        [[ "$mode" != duplicate ]] || addition=$'status: duplicate\nduplicate_of: canonical.md'
        check _local_dedupe_mark_file "$file" "$addition" ''
        if [[ "$mode" == duplicate ]]; then
          check test "$(_ledger_frontmatter_scalar "$file" status)" = duplicate
          # With no displaced custom status, ordinary canonical cleanup removes
          # the marks. Archived statuses also exercise singleton restoration.
          restore=canonical
          [[ "$status" != custom ]] || restore='restore-only'
          check _local_dedupe_mark_file "$file" '' '' "$restore"
        fi
        check cmp -s "$file" "$FIXTURE/expected.md"
        check test "$(find "$FIXTURE" -name '*.rldedupe.*' | wc -l)" -eq 0
      done
    done
  done
done
# Real grouping and every downstream actionable report must still suppress the
# duplicate, retain provenance, and restore its custom status on promotion.
for kind in nested literal; do
  scenario="grouped/$kind"
  output="$FIXTURE/$kind"
  LOG_BASE="$FIXTURE/$kind-run"
  mkdir -p "$output" || exit 1
  for name in canonical duplicate; do
    severity=high indent='  '
    [[ "$name" != canonical ]] || { severity=critical; indent=''; }
    {
      printf '%s\n' ---
      metadata "$indent" "$kind"
      printf '%s%s\n' "$indent" 'title: Unsafe access to shared state' "$indent" "severity: $severity"
      [[ "$name" != duplicate ]] || printf '%sstatus : "duplicate-pending" # original\n' "$indent"
      printf '%s%s\n' "$indent" 'domain: security' "$indent" "lens: probe-$name"
      printf '%s\n' --- body
    } > "$output/$name.md" || exit 1
  done
  check dedupe_local_markdown "$output"
  check build_finding_registry nested-status "$output"
  findings="$LOG_BASE/final/findings.jsonl"
  check jq -se 'length == 2 and any(.[]; .lens == "probe-duplicate" and .status == "duplicate")
    and any(.[]; .lens == "probe-canonical" and .status == "new"
      and .also_reported_by[0].lens == "probe-duplicate")' "$findings"
  check render_human_review_digest nested-status
  check generate_todo_md "$findings" "$LOG_BASE/final/TODO.md"
  check generate_duplicates_md "$findings" "$LOG_BASE/final/DUPLICATES.md"
  check test "$(grep -c '^### ' "$LOG_BASE/final/HUMAN_REVIEW.md")" -eq 1
  check test "$(grep -c '^## \[' "$LOG_BASE/final/TODO.md")" -eq 1
  check grep -q 'probe-duplicate' "$LOG_BASE/final/DUPLICATES.md"
  check test "$(grep -c ',"duplicate",' "$LOG_BASE/final/findings.csv")" -eq 1
  before="$(sha256sum "$output/"*.md)" || exit 1
  check dedupe_local_markdown "$output"
  check test "$before" = "$(sha256sum "$output/"*.md)"
  sed -i 's/severity: high/severity: critical/' "$output/duplicate.md" || exit 1
  sed -i 's/severity: critical/severity: low/' "$output/canonical.md" || exit 1
  check dedupe_local_markdown "$output"
  check grep -qxF '  status : "duplicate-pending" # original' "$output/duplicate.md"
  check test -z "$(_ledger_frontmatter_scalar "$output/duplicate.md" repolens_dedupe_original_status)"
  check build_finding_registry nested-status "$output"
  check jq -se 'any(.[]; .lens == "probe-duplicate" and .status == "new")
    and any(.[]; .lens == "probe-canonical" and .status == "duplicate")' "$findings"
done
printf 'Local duplicate nested status: %s checks, %s failures.\n' "$checks" "$failed"
(( failed == 0 ))
