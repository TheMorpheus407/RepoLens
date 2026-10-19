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

# Dedupe owns the exact duplicate scalar; status prefixes remain user data.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/local-dedupe.sh
source "$REPO/lib/local-dedupe.sh"
# shellcheck source=lib/ledger.sh
source "$REPO/lib/ledger.sh"
# shellcheck source=lib/human_review.sh
source "$REPO/lib/human_review.sh"
# shellcheck source=lib/artifacts.sh
source "$REPO/lib/artifacts.sh"
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
failed=0 checks=0
check() {
  checks=$((checks + 1))
  if ! "$@" >/dev/null 2>&1; then
    printf 'FAIL: %s: %s\n' "$scenario" "$*" >&2
    failed=$((failed + 1))
  fi
}

# Compare complete documents: only the owned root status may disappear.
for indent in '' '  '; do
  for padding in '' ' ' $'\t'; do
    for action in remove preserve; do
      values=(duplicate '"duplicate"' "'duplicate'" 'duplicate  ' 'duplicate # old mark' '"duplicate" # old mark' "'duplicate' # old mark")
      if [[ "$action" == preserve ]]; then
        values=(duplicate_candidate duplicate_of '"duplicate pending"' "'duplicate pending'" '"duplicate # literal"' duplicate#literal needs-validation)
      fi
      for value in "${values[@]}"; do
        scenario="$action / indent=${#indent} / padding=${#padding} / $value"
        {
          printf -- '---\n%stitle: Status ownership\n' "$indent"
          printf '%sstatus%s: %s\n' "$indent" "$padding" "$value"
          printf '%sdetails:\n%s  status : duplicate\n---\nEvidence: src/state.sh:12\n' "$indent" "$indent"
        } > "$FIXTURE/input.md"
        if [[ "$action" == remove ]]; then
          # The root status is the third line; nested metadata must stay intact.
          sed '3d' "$FIXTURE/input.md" > "$FIXTURE/expected.md"
        else
          cp "$FIXTURE/input.md" "$FIXTURE/expected.md"
        fi
        check _local_dedupe_mark_file "$FIXTURE/input.md" '' ''
        check cmp -s "$FIXTURE/expected.md" "$FIXTURE/input.md"
      done
    done
  done
done

# Reach the same cleanup through real grouping and canonical promotion.
output="$FIXTURE/output"
mkdir -p "$output"
scenario=grouped-statuses
for group in 1 2 3; do
  case "$group" in
    1) title='Unsafe authorization in account deletion' ;;
    2) title='Unbounded memory allocation in image conversion' ;;
    3) title='Credentials exposed through request logging' ;;
  esac
  for member in a b; do
    severity=high
    [[ "$member" != b ]] || severity=critical
    printf -- '---\ntitle: %s\nseverity: %s\nlens: probe-%s-%s\n---\nEvidence: src/state.sh:12\n' \
      "$title" "$severity" "$group" "$member" > "$output/$group-$member.md"
  done
done
check dedupe_local_markdown "$output"
for group in 1 2 3; do
  case "$group" in 1) value=duplicate_candidate ;; 2) value=duplicate_of ;; 3) value='"duplicate pending"' ;; esac
  sed -i "s/^status:.*/status : $value/; s/^severity:.*/severity: critical/" "$output/$group-a.md"
  sed -i 's/^severity:.*/severity: high/' "$output/$group-b.md"
done
check dedupe_local_markdown "$output"
for group in 1 2 3; do
  case "$group" in 1) value=duplicate_candidate ;; 2) value=duplicate_of ;; 3) value='"duplicate pending"' ;; esac
  scenario="group $group canonical promotion"
  check grep -qxF "status : $value" "$output/$group-a.md"
  check grep -qxF 'status: duplicate' "$output/$group-b.md"
done
check build_findings_jsonl_from_local "$output" "$FIXTURE/findings.jsonl"
check jq -se 'length == 6 and (map(select(.status == "new")) | length) == 3
  and (map(select(.status == "duplicate")) | length) == 3' "$FIXTURE/findings.jsonl"
before="$(sha256sum "$output/"*.md)"
check dedupe_local_markdown "$output"
check test "$before" = "$(sha256sum "$output/"*.md)"

# Assigning duplicate status must not leave an earlier root status in charge.
for group in 1 2 3; do
  sed -i 's/^status:.*/status : needs-validation/' "$output/$group-b.md"
done
check dedupe_local_markdown "$output"
for group in 1 2 3; do
  scenario="group $group non-canonical custom status"
  check test "$(grep -cE '^status[[:space:]]*:' "$output/$group-b.md")" -eq 1
done
check build_findings_jsonl_from_local "$output" "$FIXTURE/findings.jsonl"
check jq -se '(map(select(.status == "duplicate")) | length) == 3' "$FIXTURE/findings.jsonl"

# Swap roles again: archived statuses return and current duplicates stay hidden.
sed -i 's/^severity:.*/severity: high/' "$output/"*-a.md
sed -i 's/^severity:.*/severity: critical/' "$output/"*-b.md
check dedupe_local_markdown "$output"
for group in 1 2 3; do
  scenario="group $group restores non-canonical custom status"
  check grep -qxF 'status : needs-validation' "$output/$group-b.md"
done
LOG_BASE="$FIXTURE/logs/probe"
check build_finding_registry probe "$output"
check render_human_review_digest probe
check generate_todo_md "$LOG_BASE/final/findings.jsonl" "$LOG_BASE/final/TODO.md"
check test "$(grep -c '^### ' "$LOG_BASE/final/HUMAN_REVIEW.md")" -eq 3
check test "$(grep -c ',"new",' "$LOG_BASE/final/findings.csv")" -eq 3
check test "$(grep -c '^## ' "$LOG_BASE/final/TODO.md")" -eq 3
# An edited duplicate is actionable again even while its old mark is retained.
sed -i 's/^title:.*/title: Insecure database connection defaults/' "$output/1-a.md"
check build_finding_registry probe "$output"
check jq -se '(map(select(.status == "new")) | length) == 4
  and (map(select(.status == "duplicate")) | length) == 2' "$LOG_BASE/final/findings.jsonl"
printf 'Local dedupe status values: %s checks, %s failures.\n' "$checks" "$failed"
(( failed == 0 ))
