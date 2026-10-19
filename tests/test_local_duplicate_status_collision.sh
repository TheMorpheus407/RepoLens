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
set -uo pipefail
# Setup failures stop the suite; check() collects behavioral assertion failures.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
FIXTURE="$(mktemp -d)" || exit 1
trap 'rm -rf -- "$FIXTURE"' EXIT
for lib in local-dedupe ledger human_review artifacts; do
  # shellcheck source=/dev/null
  source "$REPO/lib/$lib.sh" || exit 1
done
failed=0 checks=0
# Run an assertion and count failures without ending the remaining scenarios.
check() {
  checks=$((checks + 1))
  if ! "$@" >/dev/null 2>&1; then
    printf 'FAIL: %s: %s\n' "$scenario" "$*"
    failed=$((failed + 1))
  fi
}
# A custom status on the noncanonical member must not shadow managed marks.
for variant in plain quoted single; do
    padding='' value=duplicate-pending
    case "$variant" in
      quoted) padding=' '; value='"duplicate-pending"' ;;
      single) padding=$'\t'; value="'needs-validation'" ;;
    esac
    scenario="collision/$padding/$value"
    output="$FIXTURE/collision"
    LOG_BASE="$FIXTURE/collision-run"
    mkdir -p "$output" || exit 1
    original="  status$padding: $value # original"
    for name in canonical duplicate; do
      severity=high indent='  '
      [[ "$name" != canonical ]] || { severity=critical; indent=''; }
      {
        printf '%s\n' ---
        printf '%s%s\n' "$indent" 'title: Unsafe access to shared state' "$indent" "severity: $severity"
        [[ "$name" != duplicate ]] || printf '%s\n' "$original"
        printf '%s%s\n' "$indent" 'domain: security' "$indent" "lens: probe-$name"
        printf '%s\n' --- body
      } > "$output/$name.md" || exit 1
    done
    check dedupe_local_markdown "$output"
    check test "$(grep -cE '^[[:space:]]*status[[:space:]]*:' "$output/duplicate.md")" -eq 1
    archive="$(_ledger_frontmatter_scalar "$output/duplicate.md" repolens_dedupe_original_status)" || exit 1
    check jq -ne --arg raw "$archive" --arg original "$original" '$raw | fromjson == $original'
    check build_finding_registry collision "$output"
    findings="$LOG_BASE/final/findings.jsonl"
    check jq -se 'length == 2 and any(.[]; .lens == "probe-duplicate" and .status == "duplicate")
      and any(.[]; .lens == "probe-canonical" and .status == "new"
        and .also_reported_by[0].lens == "probe-duplicate")' "$findings"
    check render_human_review_digest collision
    check generate_todo_md "$findings" "$LOG_BASE/final/TODO.md"
    check generate_duplicates_md "$findings" "$LOG_BASE/final/DUPLICATES.md"
    check test "$(grep -c '^### ' "$LOG_BASE/final/HUMAN_REVIEW.md")" -eq 1
    check test "$(grep -c '^## \[' "$LOG_BASE/final/TODO.md")" -eq 1
    check grep -q 'probe-duplicate' "$LOG_BASE/final/DUPLICATES.md"
    check test "$(tail -n +2 "$LOG_BASE/final/findings.csv" | grep -c ',"new",')" -eq 1
    check test "$(tail -n +2 "$LOG_BASE/final/findings.csv" | grep -c ',"duplicate",')" -eq 1
    before="$(sha256sum "$output/"*.md)" || exit 1
    check dedupe_local_markdown "$output"
    check test "$before" = "$(sha256sum "$output/"*.md)"
    registry_before="$(sha256sum "$findings" "$LOG_BASE/final/findings.csv")" || exit 1
    check build_finding_registry collision "$output"
    check test "$registry_before" = "$(sha256sum "$findings" "$LOG_BASE/final/findings.csv")"
    # A promotion must restore the complete original entry, without an archive.
    sed -i 's/severity: high/severity: critical/' "$output/duplicate.md" || exit 1
    sed -i 's/severity: critical/severity: low/' "$output/canonical.md" || exit 1
    check dedupe_local_markdown "$output"
    check grep -qxF "$original" "$output/duplicate.md"
    check test -z "$(_ledger_frontmatter_scalar "$output/duplicate.md" repolens_dedupe_original_status)"
    check build_finding_registry collision "$output"
    check jq -se 'any(.[]; .lens == "probe-duplicate" and .status == "new")
      and any(.[]; .lens == "probe-canonical" and .status == "duplicate")' "$findings"
done
# Archived singletons must be restored even when grouping produces no output.
for scenario in dissolved-title dissolved-threshold; do
  output="$FIXTURE/$scenario"
  mkdir -p "$output" || exit 1
  for name in a b; do
    printf '%s\n' --- 'title: Unsafe shared state access' 'severity: high' \
      'domain: security' "lens: probe-$name" --- body > "$output/$name.md" || exit 1
  done
  original=$'status\t: "duplicate-pending" # keep quotes and spacing'
  sed -i '/^severity:/a status\t: "duplicate-pending" # keep quotes and spacing' "$output/b.md" || exit 1
  check dedupe_local_markdown "$output"
  if [[ "$scenario" == dissolved-title ]]; then
    sed -i 's/^title:.*/title: Credentials exposed by request logging/' "$output/a.md" || exit 1
  else
    export DEDUPE_TITLE_SIM_PRIMARY=10001 DEDUPE_TITLE_SIM_SECONDARY=10001
  fi
  check dedupe_local_markdown "$output"
  check grep -qxF "$original" "$output/b.md"
  check test -z "$(_ledger_frontmatter_scalar "$output/b.md" repolens_dedupe_original_status)"
  check test -z "$(_ledger_frontmatter_scalar "$output/b.md" duplicate_of)"
  before="$(sha256sum "$output/"*.md)" || exit 1
  check dedupe_local_markdown "$output"
  check test "$before" = "$(sha256sum "$output/"*.md)"
  check build_findings_jsonl_from_local "$output" "$FIXTURE/dissolved.jsonl"
  check jq -se 'length == 2 and all(.[]; .status == "new")' "$FIXTURE/dissolved.jsonl"
  unset DEDUPE_TITLE_SIM_PRIMARY DEDUPE_TITLE_SIM_SECONDARY
done
# Repair the two-key collision produced by the preceding implementation too.
scenario=existing-collision
file="$FIXTURE/existing-collision.md"
printf '%s\n' --- 'title: Existing collision' 'status : "duplicate-pending"' \
  'status: duplicate' 'duplicate_of: canonical.md' --- body > "$file" || exit 1
check _local_dedupe_mark_file "$file" $'status: duplicate\nduplicate_of: canonical.md' note
check test "$(grep -cE '^status[[:space:]]*:' "$file")" -eq 1
check _local_dedupe_mark_file "$file" '' ''
check grep -qxF 'status : "duplicate-pending"' "$file"
# Reserved-key collisions and later user edits must never be overwritten.
for scenario in invalid-archive edited-status duplicate-archive block-status; do
  file="$FIXTURE/conflict.md"
  printf '%s\n' --- 'title: Status conflict' 'severity: high' \
    'status : "duplicate-pending" # keep' --- body > "$file" || exit 1
  if [[ "$scenario" != block-status ]]; then
    check _local_dedupe_mark_file "$file" $'status: duplicate\nduplicate_of: canonical.md' note
    case "$scenario" in
      invalid-archive) sed -i 's/^repolens_dedupe_original_status:.*/repolens_dedupe_original_status: {foreign: data}/' "$file" || exit 1 ;;
      edited-status) sed -i 's/^status: duplicate/status: user-updated/' "$file" || exit 1 ;;
      duplicate-archive) sed -i '/^repolens_dedupe_original_status:/p' "$file" || exit 1 ;;
    esac
  else
    sed -i 's/^status.*/status: |\n  custom block value/' "$file" || exit 1
  fi
  before="$(sha256sum "$file")" || exit 1
  rc=0
  _local_dedupe_mark_file "$file" $'status: duplicate\nduplicate_of: canonical.md' note > "$FIXTURE/conflict.log" 2>&1 || rc=$?
  check test "$rc" -ne 0
  check grep -q 'preserving' "$FIXTURE/conflict.log"
  check test "$before" = "$(sha256sum "$file")"
  if [[ "$scenario" != block-status ]]; then
    rc=0
    _local_dedupe_mark_file "$file" '' '' > "$FIXTURE/conflict.log" 2>&1 || rc=$?
    check test "$rc" -ne 0
    check test "$before" = "$(sha256sum "$file")"
  fi
done
printf 'Local duplicate status collision: %s checks, %s failures.\n' "$checks" "$failed"
(( failed == 0 ))
