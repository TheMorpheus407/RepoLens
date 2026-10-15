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
check printf -- '---\ntitle: Unsafe query\nseverity: high\n---\nEvidence\n' > "$TMP/output/security/injection/001.md"
check printf -- '---\ntitle: Missing authorization\nseverity: high\n---\nEvidence\n' > "$TMP/output/security/injection/002.md"
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
          if [[ "$fault" == sort-partial ]]; then command sort "$@"; fi
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
(
  LOG_BASE="$TMP/run" OUTPUT_DIR="$TMP/output"
  RUN_ID=probe MODE=audit LOCAL_MODE=true OUTPUT_DIR_SET=true
  HUMAN_REVIEW=true REPOLENS_FINAL_STATE=finished
  check finalize_local
  artifacts=(findings.jsonl findings.csv TODO.md SUMMARY.md NEEDS_REVIEW.md DUPLICATES.md HUMAN_REVIEW.md)
  for artifact in "${artifacts[@]}"; do check test -s "$LOG_BASE/final/$artifact"; done
  check mkdir "$TMP/published"
  for artifact in "${artifacts[@]}"; do check cp "$LOG_BASE/final/$artifact" "$TMP/published/$artifact"; done
  # Fail with no output, the case that previously removed the triage reports.
  find() { return 1; }
  check finalize_local
  unset -f find
  for artifact in "${artifacts[@]}"; do check cmp "$TMP/published/$artifact" "$LOG_BASE/final/$artifact"; done
  check test "$(command find "$LOG_BASE/final" -type f | wc -l)" -eq "${#artifacts[@]}"
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
printf 'Results: registry traversal failure checks passed\n'
