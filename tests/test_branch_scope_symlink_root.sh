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
# Record each assertion and continue so the summary includes every failure.
check() {
  local label="$1"
  shift
  if "$@"; then PASS=$((PASS + 1)); printf 'PASS: %s\n' "$label"
  else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$label"; fi
}
# Write a valid registry fixture with a caller-selected title and citation.
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
  check "$variant registry rebuild succeeds" build_findings_jsonl_from_local "$dir" "$base/registry.jsonl"
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
  check "$variant mixed registry rebuild succeeds" build_findings_jsonl_from_local "$dir" "$base/mixed.jsonl"
  check "$variant registry retains only in-scope finding" jq -se 'length==1 and .[0].title=="Allowed finding" and .[0].status=="new"' "$base/mixed.jsonl"
  check "$variant accepts actual changed file" test -f "$base/real/accepted.md"
  check "$variant also quarantines later rejection" test -f "$base/real/another.md.out-of-scope"
  accepted_hash="$(cksum < "$base/real/accepted.md")"
  check "$variant repeat filtering succeeds" branch_scope_filter_directory "$dir"
  check "$variant repeat preserves accepted finding" test "$accepted_hash" = "$(cksum < "$base/real/accepted.md")"
done
# repolens-r12-p5-5: derived diagnostic paths must not follow file symlinks.
for variant in physical linked dangling; do
  base="$TMPROOT/reason-$variant"
  mkdir -p "$base/real"
  printf 'unrelated original contents\n' > "$base/external.txt"
  write_finding "$base/real/rejected.md" 'Rejected finding' untouched.sh
  source_hash="$(cksum < "$base/real/rejected.md")"
  target="$base/external.txt"
  [[ "$variant" != dangling ]] || target="$base/missing.txt"
  ln -s "$target" "$base/real/rejected.md.out-of-scope.reason"
  dir="$base/real"
  if [[ "$variant" == linked ]]; then
    ln -s "$base/real" "$base/root-link"
    dir="$base/root-link"
  fi
  rc=0
  branch_scope_filter_directory "$dir" || rc=$?
  check "$variant diagnostic link fails filtering" test "$rc" -ne 0
  check "$variant external contents unchanged" grep -Fxq 'unrelated original contents' "$base/external.txt"
  check "$variant diagnostic remains a symlink" test -L "$base/real/rejected.md.out-of-scope.reason"
  check "$variant pending finding unchanged" test "$source_hash" = "$(cksum < "$base/real/rejected.md")"
  check "$variant no quarantine published" test ! -e "$base/real/rejected.md.out-of-scope"
  check "$variant dangling target not created" test ! -e "$base/missing.txt"
  rm -- "$base/real/rejected.md.out-of-scope.reason"
  check "$variant repaired diagnostic retries successfully" branch_scope_filter_directory "$dir"
  check "$variant retry quarantines finding" test -f "$base/real/rejected.md.out-of-scope"
done
# Exercise portable publication and failures after staging, rather than only
# destinations rejected before mktemp. No native BSD host is needed to model
# its mv option contract; all ordinary moves still use the real executable.
for fault in bsd-mv stage-write publish; do
  base="$TMPROOT/publication-$fault"
  mkdir -p "$base/real/nested dir"
  rejected="$base/real/nested dir/rejected.md"
  write_finding "$rejected" 'Rejected finding' untouched.sh
  cp -- "$rejected" "$base/original"
  printf 'previous diagnostic\n' > "$rejected.out-of-scope.reason"
  mv() {
    local arg
    if [[ "$fault" == bsd-mv ]]; then
      for arg in "$@"; do
        if [[ "$arg" == -T ]]; then
          printf 'mv: illegal option -- T\n' >&2
          return 64
        fi
      done
    fi
    if [[ "$fault" == publish && "${!#}" == "$rejected.out-of-scope.reason" ]]; then
      : > "$base/publication-attempted"
      return 1
    fi
    command mv "$@"
  }
  python3() {
    if [[ "$fault" == publish && "${!#}" == "$rejected.out-of-scope.reason" ]]; then
      : > "$base/publication-attempted"
      return 1
    fi
    command python3 "$@"
  }
  # shellcheck disable=SC2329 # Invoked by the sourced scope filter.
  printf() {
    if [[ "$fault" == stage-write && "${1:-}" == '%s\n' &&
        "${2:-}" == 'out-of-scope citation: untouched.sh' ]]; then
      : > "$base/write-attempted"
      builtin printf 'partial reason'
      return 1
    fi
    # shellcheck disable=SC2059 # Forward the caller's original format and args.
    builtin printf "$@"
  }
  rc=0
  branch_scope_filter_directory "$base/real" || rc=$?
  unset -f mv python3 printf
  if [[ "$fault" == bsd-mv ]]; then
    check 'BSD mv permits rejection publication' test "$rc" -eq 0
    check 'BSD mv quarantines source' test -f "$rejected.out-of-scope"
    check 'BSD mv publishes full reason' grep -Fxq 'out-of-scope citation: untouched.sh' "$rejected.out-of-scope.reason"
  else
    marker="$base/write-attempted"
    [[ "$fault" != publish ]] || marker="$base/publication-attempted"
    check "$fault reaches staged failure" test -f "$marker"
    check "$fault reports failure" test "$rc" -ne 0
    check "$fault preserves source bytes" cmp -s "$base/original" "$rejected"
    check "$fault publishes no quarantine" test ! -e "$rejected.out-of-scope"
    check "$fault preserves previous diagnostic" grep -Fxq 'previous diagnostic' "$rejected.out-of-scope.reason"
    check "$fault cleans failed staging before retry" test -z "$(find "$base/real" -name '.branch-scope-*' -print)"
    check "$fault retry succeeds" branch_scope_filter_directory "$base/real"
    check "$fault retry quarantines exact source" cmp -s "$base/original" "$rejected.out-of-scope"
    check "$fault retry publishes full reason" grep -Fxq 'out-of-scope citation: untouched.sh' "$rejected.out-of-scope.reason"
  fi
  check "$fault removes staged scratch files" test -z "$(find "$base/real" -name '.branch-scope-*' -print)"
done
printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
