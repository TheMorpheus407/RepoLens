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

# Custom status is user metadata; duplicate projection still needs one canonical.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
for lib in ledger local-dedupe human_review artifacts; do
  # shellcheck source=/dev/null
  source "$REPO/lib/$lib.sh"
done
failed=0 checks=0
# Count public-behavior assertions without aborting on the first failure.
check() {
  local description="$1"; shift
  checks=$((checks + 1))
  if ! "$@" >/dev/null 2>&1; then
    printf 'FAIL: %s: %s\n' "$scenario" "$description"
    failed=$((failed + 1))
  fi
}
# Write a valid finding with literal custom metadata and a nested-name control.
write_finding() {
  local path="$1" lens="$2" severity="$3" custom="$4"
  {
    printf '%s\n' '---'
    printf '%stitle: Unsafe access to shared state\n' "$indent"
    printf '%sseverity: %s\n' "$indent" "$severity"
    printf '%sdomain: security\n%slens: %s\n' "$indent" "$indent" "$lens"
    printf '%s%s\n' "$indent" "$custom"
    printf '%smetadata:\n%s  status: duplicate\n%s  duplicate_of: nested-only.md\n' "$indent" "$indent" "$indent"
    printf '%s\n' '---' 'Evidence at src/state.sh:12.'
  } > "$path"
}
# Require the complete original scalar/block and exactly one root status key.
custom_preserved() {
  python3 -B - "$1" "${indent}$2" "$indent" <<'PY'
from pathlib import Path
import re
import sys
text = Path(sys.argv[1]).read_text()
keys = re.findall(r"^" + re.escape(sys.argv[3]) + r"status[ \t]*:", text, re.M)
sys.exit(0 if sys.argv[2] + "\n" in text and len(keys) == 1 else 1)
PY
}
# Exercise the real registry and, once per fixture, its rendered review views.
projection() {
  local actions="$1" duplicates="$2" canonical="$3" reports="${4:-0}"
  check 'registry builds' build_finding_registry fixture "$OUTPUT_DIR"
  findings="$LOG_BASE/final/findings.jsonl"
  check 'derived action/duplicate counts' jq -se --argjson n "$actions" --argjson d "$duplicates" \
    '(map(select(.status == "new")) | length) == $n and
     (map(select(.status == "duplicate")) | length) == $d' "$findings"
  check 'current contributor provenance' jq -se --argjson d "$duplicates" \
    '[.[].also_reported_by[]?] | length == $d' "$findings"
  if (( duplicates )); then
    check 'expected canonical is actionable' jq -se --arg lens "$canonical" \
      'map(select(.status == "new")) | length == 1 and .[0].lens == $lens' "$findings"
  fi
  if (( reports )); then
    check 'review renders' render_human_review_digest fixture
    check 'TODO renders' generate_todo_md "$findings" "$LOG_BASE/final/TODO.md"
    check 'review includes only actionable findings' test "$(grep -c '^### ' "$LOG_BASE/final/HUMAN_REVIEW.md" || true)" -eq "$actions"
    check 'CSV matches derived status' test "$(tail -n +2 "$LOG_BASE/final/findings.csv" | grep -c ',"new",' || true)" -eq "$actions"
  fi
}
for scenario in indented quoted-and-block; do
  OUTPUT_DIR="$FIXTURE/$scenario/output"
  LOG_BASE="$FIXTURE/$scenario/logs/run"
  mkdir -p "$OUTPUT_DIR"
  indent='  '
  a_custom='status: reviewed'
  b_custom='status : "needs owner" # retain this comment'
  if [[ "$scenario" == quoted-and-block ]]; then
    indent=''
    a_custom="status: 'reviewed' # original"
    b_custom=$'status: |-\n  reviewed\n  owner pending'
  fi
  a="$OUTPUT_DIR/a.md" b="$OUTPUT_DIR/b.md"
  write_finding "$a" probe-a critical "$a_custom"
  write_finding "$b" probe-b high "$b_custom"
  check 'dedupe succeeds' dedupe_local_markdown "$OUTPUT_DIR"
  check 'canonical custom status retained' custom_preserved "$a" "$a_custom"
  check 'duplicate custom status retained without second key' custom_preserved "$b" "$b_custom"
  check 'nested status retained' grep -qxF "${indent}  status: duplicate" "$b"
  check 'nested duplicate link retained' grep -qxF "${indent}  duplicate_of: nested-only.md" "$b"
  projection 1 1 probe-a 1
  before="$(sha256sum "$a" "$b")"
  check 'repeated dedupe succeeds' dedupe_local_markdown "$OUTPUT_DIR"
  check 'repeated dedupe is byte-identical' test "$before" = "$(sha256sum "$a" "$b")"

  # Change user metadata only, leaving the completed pass receipt and link.
  manual=$'status\t: reviewer_changed # retain manual edit'
  python3 -B - "$b" "${indent}${b_custom}" "${indent}${manual}" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
old, new = sys.argv[2] + "\n", sys.argv[3] + "\n"
if text.count(old) != 1:
    raise SystemExit("fixture custom status is not unique")
path.write_text(text.replace(old, new, 1))
PY
  b_custom="$manual"
  projection 1 1 probe-a
  check 'manual status edit remains untouched' custom_preserved "$b" "$b_custom"
  # Removing ownership restores eligibility even while the matching link stays.
  sed -i '/^<!-- repolens-dedupe:begin -->$/,$d' "$b"
  projection 2 0 ''
  check 'next pass can re-mark a continuing match' dedupe_local_markdown "$OUTPUT_DIR"
  projection 1 1 probe-a

  # Promotion removes duplicate ownership, while both user statuses survive.
  sed -i "s/^${indent}severity:.*/${indent}severity: high/" "$a"
  sed -i "s/^${indent}severity:.*/${indent}severity: critical/" "$b"
  check 'promotion dedupe succeeds' dedupe_local_markdown "$OUTPUT_DIR"
  check 'new duplicate keeps custom status' custom_preserved "$a" "$a_custom"
  check 'promoted canonical keeps manual status' custom_preserved "$b" "$b_custom"
  projection 1 1 probe-b
  before="$(sha256sum "$a" "$b")"
  check 'promoted rerun succeeds' dedupe_local_markdown "$OUTPUT_DIR"
  check 'promoted rerun is byte-identical' test "$before" = "$(sha256sum "$a" "$b")"

  # Older complete human-readable notes remain valid without the new type line.
  sed -i '/^<!-- repolens-dedupe:duplicate -->$/d' "$a"
  projection 1 1 probe-b

  # A stale link/receipt cannot suppress an unrelated finding after title edit.
  sed -i "s/^${indent}title:.*/${indent}title: Cross-site scripting through template rendering/" "$b"
  check 'group dissolution succeeds' dedupe_local_markdown "$OUTPUT_DIR"
  before="$(sha256sum "$a" "$b")"
  projection 2 0 ''
  check 'former duplicate retains custom status' custom_preserved "$a" "$a_custom"
  check 'former canonical retains manual status' custom_preserved "$b" "$b_custom"
  check 'registry never rewrites markdown evidence' test "$before" = "$(sha256sum "$a" "$b")"
done
printf 'Results: %s checks, %s failures\n' "$checks" "$failed"
test "$failed" -eq 0
