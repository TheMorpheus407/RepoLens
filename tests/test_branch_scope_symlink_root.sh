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

# repolens-r9-p3-3: scope filtering and registry ingestion must see the same
# explicit root. Follow its symlink only; nested links must remain unvisited.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/branch-scope.sh
source "$ROOT/lib/branch-scope.sh"
# shellcheck source=lib/ledger.sh
source "$ROOT/lib/ledger.sh"
TMPROOT="$(mktemp -d)"
trap 'rm -rf -- "$TMPROOT"' EXIT
MODE=branch-review
BRANCH_SCOPE_FILE="$TMPROOT/scope.json"
printf '["allowed.sh"]\n' > "$BRANCH_SCOPE_FILE"
PASS=0 FAIL=0
check() {
  local label="$1"
  shift
  if "$@"; then PASS=$((PASS + 1)); printf 'PASS: %s\n' "$label"
  else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$label"; fi
}
write_finding() {
  printf -- '---\ntitle: %s\nseverity: high\n---\nEvidence: %s:1\n' "$2" "$3" > "$1"
}
for variant in physical linked linked-slash; do
  base="$TMPROOT/$variant"
  mkdir -p "$base/real" "$base/external"
  write_finding "$base/real/rejected.md" 'Out of scope' untouched.sh
  write_finding "$base/external/untouched.md" 'Nested external evidence' untouched.sh
  external_hash="$(cksum < "$base/external/untouched.md")"
  ln -s "$base/external" "$base/real/nested-link"
  ln -s "$base/external/untouched.md" "$base/real/file-link.md"
  dir="$base/real"
  if [[ "$variant" != physical ]]; then
    ln -s "$base/real" "$base/root-link"
    dir="$base/root-link"
    [[ "$variant" != linked-slash ]] || dir="$dir/"
  fi
  rc=0
  branch_scope_filter_directory "$dir" || rc=$?
  check "$variant filtering completes" test "$rc" -eq 0
  check "$variant rejected finding is quarantined" test -f "$base/real/rejected.md.out-of-scope"
  check "$variant rejected finding leaves md consumers" test ! -e "$base/real/rejected.md"
  check "$variant records scope reason" grep -q 'out-of-scope citation: untouched.sh' "$base/real/rejected.md.out-of-scope.reason"
  build_findings_jsonl_from_local "$dir" "$base/registry.jsonl"
  check "$variant registry publishes no rejected finding" test ! -s "$base/registry.jsonl"
  check "$variant nested target stays byte-identical" test "$external_hash" = "$(cksum < "$base/external/untouched.md")"
  check "$variant nested target is never quarantined" test ! -e "$base/external/untouched.md.out-of-scope"
  check "$variant nested directory link remains a link" test -L "$base/real/nested-link"
  check "$variant nested file link remains a link" test -L "$base/real/file-link.md"
  if [[ "$variant" != physical ]]; then
    check "$variant explicit root remains a symlink" test -L "$base/root-link"
  fi
  write_finding "$base/real/accepted.md" 'Allowed finding' allowed.sh
  write_finding "$base/real/another.md" 'Another rejection' untouched.sh
  check "$variant mixed root filters successfully" branch_scope_filter_directory "$dir"
  build_findings_jsonl_from_local "$dir" "$base/mixed.jsonl"
  check "$variant registry retains only in-scope finding" jq -se 'length==1 and .[0].title=="Allowed finding" and .[0].status=="new"' "$base/mixed.jsonl"
  check "$variant accepts actual changed file" test -f "$base/real/accepted.md"
  check "$variant also quarantines later rejection" test -f "$base/real/another.md.out-of-scope"
  accepted_hash="$(cksum < "$base/real/accepted.md")"
  check "$variant repeat filtering succeeds" branch_scope_filter_directory "$dir"
  check "$variant repeat preserves accepted finding" test "$accepted_hash" = "$(cksum < "$base/real/accepted.md")"
done
printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
