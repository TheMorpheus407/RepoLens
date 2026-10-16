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

# Regression: repolens-r6-p2-1. No real model or forge calls.
# shellcheck disable=SC2034,SC2329 # Extracted finalization consumes fixture globals.
set -euo pipefail
# Fail explicitly as well, including when a caller disables errexit.
check() { "$@" || { printf 'FAIL: %s\n' "$*" >&2; exit 1; }; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
source "$ROOT/lib/ledger.sh" || exit 1
TMP="$(mktemp -d)" || exit 1
# Restore permissions before removing the unreadable-directory fixture.
cleanup() { chmod -R u+rwx "$TMP"; rm -rf "$TMP"; }
trap cleanup EXIT
check mkdir -p "$TMP/output/security/injection"
check printf -- '---\ntitle: Unsafe query\nseverity: high\n---\nsrc/changed.sh:1 Evidence\n' > "$TMP/output/security/injection/001.md"
check printf -- '---\ntitle: Missing authorization\nseverity: high\n---\nsrc/changed.sh:1 Evidence\n' > "$TMP/output/security/injection/002.md"
OUT="$TMP/findings.jsonl"
check build_findings_jsonl_from_local "$TMP/output" "$OUT"
expected="$(cat "$OUT")" || exit 1
check jq -se 'length == 2' "$OUT"
# Both pipeline commands may fail before output or after useful output. A
# partial traversal must preserve BOTH records, even when sort succeeds.
for fault in find-empty find-partial sort-empty sort-partial; do
  (
    case "$fault" in
      find-*)
        find() {
          if [[ "$fault" == find-partial ]]; then
            printf '%s\0' "$TMP/output/security/injection/001.md"
          fi
          return 1
        }
        ;;
      sort-*)
        sort() {
          if [[ "$fault" == sort-partial ]]; then
            command sort "$@" | head -z -n 1
          fi
          return 1
        }
        ;;
    esac
    rc=0
    build_findings_jsonl_from_local "$TMP/output" "$OUT" || rc=$?
    check test "$rc" -ne 0
    check test "$(cat "$OUT")" = "$expected"
    check test "$(command find "$TMP" -name '*.tmp.*' | wc -l)" -eq 0
    printf 'PASS: %s preserves registry and cleans staging files\n' "$fault"
  ) || exit 1
done
# Exercise a real permission failure as a normal user as well.
check chmod 000 "$TMP/output/security"
if [[ ! -r "$TMP/output/security" ]]; then
  rc=0
  build_findings_jsonl_from_local "$TMP/output" "$OUT" || rc=$?
  check test "$rc" -ne 0
  check test "$(cat "$OUT")" = "$expected"
  printf 'PASS: unreadable subtree preserves registry\n'
else
  printf 'SKIP: permissions do not prevent this user from reading the subtree\n'
fi
check chmod 700 "$TMP/output/security"
check test "$(command find "$TMP" -name '*.tmp.*' | wc -l)" -eq 0
check build_findings_jsonl_from_local "$TMP/output" "$OUT"
check test "$(cat "$OUT")" = "$expected"

# repolens-r7-p2-2 / repolens-r7-p3-1: enumeration success does not
# excuse a read failure for one valid source file. Preserve the whole projection.
unreadable="$TMP/output/security/injection/002.md"
check chmod 000 "$unreadable"
# Root can bypass mode bits; keep the same IO failure at both read boundaries.
if [[ -r "$unreadable" ]]; then
  cat() {
    local arg
    for arg in "$@"; do [[ "$arg" != "$unreadable" ]] || return 1; done
    command cat "$@"
  }
  awk() {
    local arg
    for arg in "$@"; do [[ "$arg" != "$unreadable" ]] || return 2; done
    command awk "$@"
  }
fi
rc=0
build_findings_jsonl_from_local "$TMP/output" "$OUT" || rc=$?
check test "$rc" -ne 0
check test "$(cat "$OUT")" = "$expected"
check test "$(command find "$TMP" -name '*.tmp.*' | wc -l)" -eq 0
check chmod 600 "$unreadable"
unset -f cat awk
check build_findings_jsonl_from_local "$TMP/output" "$OUT"
check test "$(cat "$OUT")" = "$expected"
printf 'PASS: unreadable finding preserves the complete registry and retries\n'

# Exercise the actual finalization callers, including the non-fatal dedupe and
# registry failures. Published CSV and all five reports must also survive.
for lib in core synthesize local-dedupe human_review artifacts branch-scope; do
  # shellcheck source=/dev/null
  source "$ROOT/lib/$lib.sh" || exit 1
done
log_info() { :; }
log_warn() { printf '%s\n' "$*" >&2; }
finalize_local() {
  # shellcheck source=/dev/null
  source <(sed -n '/^# --- Local-mode deterministic dedupe/,/^unset _local_registry_ready _duplicate_report_ready/p' "$ROOT/repolens.sh")
}
for mode in audit branch-review; do
(
  LOG_BASE="$TMP/$mode-run" OUTPUT_DIR="$TMP/$mode-output"
  check cp -R "$TMP/output" "$OUTPUT_DIR"
  unreadable="$OUTPUT_DIR/security/injection/002.md"
  BRANCH_SCOPE_FILE="$TMP/scope.json"
  check printf '["src/changed.sh"]\n' > "$BRANCH_SCOPE_FILE"
  RUN_ID=probe MODE="$mode" LOCAL_MODE=true OUTPUT_DIR_SET=true
  HUMAN_REVIEW=true REPOLENS_FINAL_STATE=finished
  check finalize_local
  artifacts=(findings.jsonl findings.csv TODO.md SUMMARY.md NEEDS_REVIEW.md DUPLICATES.md HUMAN_REVIEW.md)
  for artifact in "${artifacts[@]}"; do check test -s "$LOG_BASE/final/$artifact"; done
  check mkdir "$TMP/$mode-published"
  for artifact in "${artifacts[@]}"; do check cp "$LOG_BASE/final/$artifact" "$TMP/$mode-published/$artifact"; done
  # Fail with no output, the case that previously removed the triage reports.
  find() { return 1; }
  check finalize_local
  unset -f find
  for artifact in "${artifacts[@]}"; do check cmp "$TMP/$mode-published/$artifact" "$LOG_BASE/final/$artifact"; done
  check test "$(command find "$LOG_BASE/final" -type f | wc -l)" -eq "${#artifacts[@]}"
  check chmod 000 "$unreadable"
  if [[ -r "$unreadable" ]]; then
    cat() {
      local arg
      for arg in "$@"; do [[ "$arg" != "$unreadable" ]] || return 1; done
      command cat "$@"
    }
    awk() {
      local arg
      for arg in "$@"; do [[ "$arg" != "$unreadable" ]] || return 2; done
      command awk "$@"
    }
  fi
  check finalize_local
  check test -f "$unreadable"
  check test ! -e "$unreadable.out-of-scope"
  check test ! -e "$unreadable.out-of-scope.reason"
  check chmod 600 "$unreadable"
  unset -f cat awk
  for artifact in "${artifacts[@]}"; do check cmp "$TMP/$mode-published/$artifact" "$LOG_BASE/final/$artifact"; done
  check test "$(command find "$LOG_BASE/final" -type f | wc -l)" -eq "${#artifacts[@]}"
  printf 'PASS: %s unreadable finding preserves source, registry, CSV and all five reports\n' "$mode"
  # A successful retry must rebuild from current findings rather than leaving
  # the preserved registry/report snapshot in place forever.
  check rm "$OUTPUT_DIR/security/injection/002.md"
  check finalize_local
  check jq -se 'length == 1 and .[0].title == "Unsafe query"' "$LOG_BASE/final/findings.jsonl"
  check test "$(wc -l < "$LOG_BASE/final/findings.csv")" -eq 2
  rc=0
  grep -q 'Missing authorization' "$LOG_BASE/final/TODO.md" || rc=$?
  check test "$rc" -eq 1
  printf 'PASS: finalization preserves published artifacts and retry refreshes them\n'
) || exit 1
done
# repolens-r8-p3-1: fail only the scope traversal. Later registry traversal
# succeeds, so ignoring the first failure would publish an out-of-scope source.
for fault in empty partial; do
(
  LOG_BASE="$TMP/scope-$fault-run" OUTPUT_DIR="$TMP/scope-$fault-output"
  check cp -R "$TMP/output" "$OUTPUT_DIR"
  BRANCH_SCOPE_FILE="$TMP/scope-$fault.json"
  check printf '["src/changed.sh"]\n' > "$BRANCH_SCOPE_FILE"
  RUN_ID=probe MODE=branch-review LOCAL_MODE=true OUTPUT_DIR_SET=true
  HUMAN_REVIEW=true REPOLENS_FINAL_STATE=finished
  check finalize_local
  artifacts=(findings.jsonl findings.csv TODO.md SUMMARY.md NEEDS_REVIEW.md DUPLICATES.md HUMAN_REVIEW.md)
  check mkdir "$TMP/scope-$fault-published"
  for artifact in "${artifacts[@]}"; do
    check cp "$LOG_BASE/final/$artifact" "$TMP/scope-$fault-published/$artifact"
  done
  rejected="$OUTPUT_DIR/security/injection/003.md"
  check printf -- '---\ntitle: Unchanged source\nseverity: high\n---\nsrc/unchanged.sh:1 Evidence\n' > "$rejected"
  # Every consumer except the scope filter sees a successful complete find.
  find() {
    if [[ "${FUNCNAME[1]:-}" == branch_scope_filter_directory ]]; then
      if [[ "$fault" == partial ]]; then
        printf '%s\0' "$OUTPUT_DIR/security/injection/001.md"
      fi
      printf 'find: injected scope traversal failure\n' >&2
      return 1
    fi
    command find "$@"
  }
  check finalize_local
  printf 'scope fault=%s registry_records=%s\n' "$fault" "$(jq -s length "$LOG_BASE/final/findings.jsonl")"
  rc=0
  branch_scope_filter_directory "$OUTPUT_DIR" || rc=$?
  check test "$rc" -ne 0
  unset -f find
  check test -f "$rejected"
  check test ! -e "$rejected.out-of-scope"
  for artifact in "${artifacts[@]}"; do
    check cmp "$TMP/scope-$fault-published/$artifact" "$LOG_BASE/final/$artifact"
  done
  check test "$(command find "$OUTPUT_DIR" -name '.branch-scope-files.*' | wc -l)" -eq 0
  check finalize_local
  check test ! -e "$rejected"
  check test -f "$rejected.out-of-scope"
  check jq -se 'length == 2 and all(.[]; .title != "Unchanged source")' "$LOG_BASE/final/findings.jsonl"
  printf 'PASS: %s scope traversal failure preserves all published artifacts; retry filters before publishing\n' "$fault"
) || exit 1
done
printf 'Results: registry traversal failure checks passed\n'
