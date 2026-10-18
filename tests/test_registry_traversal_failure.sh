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
  # The non-local hook initializes readiness before this local-only slice.
  _registry_ready=false
  # shellcheck source=/dev/null
  source <(sed -n '/^# --- Local-mode deterministic dedupe/,/^unset _registry_ready _duplicate_report_ready/p' "$ROOT/repolens.sh")
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
# Also exercise opening/reading the completed list and both quarantine writes.
for fault in empty partial reason reopen move read-empty read-partial; do
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
  if [[ "$fault" == reason ]]; then
    # A directory makes the diagnostic redirection fail even as root.
    check mkdir "$rejected.out-of-scope.reason"
  fi
  python3() {
    if [[ "$fault" == move && "${!#}" == "$rejected.out-of-scope" ]]; then
      : > "$TMP/scope-$fault-attempted"
      return 1
    fi
    command python3 "$@"
  }
  scope_reads=0
  read() {
    if [[ "${FUNCNAME[1]:-}" == branch_scope_filter_directory ]]; then
      case "$fault" in
        read-empty) return 1 ;;
        read-partial)
          # The first filename is rejected. Fail on the next read, before
          # the remaining filenames or a completion marker can be consumed.
          if (( scope_reads > 0 )); then return 1; fi
          scope_reads=$((scope_reads + 1))
          ;;
      esac
    fi
    # shellcheck disable=SC2162 # Delegate the caller's flags, including -r.
    builtin read "$@"
  }
  # Every consumer except the scope filter sees a successful complete find.
  find() {
    if [[ "${FUNCNAME[1]:-}" == branch_scope_filter_directory ]]; then
      case "$fault" in
        empty|partial)
          if [[ "$fault" == partial ]]; then printf '%s\0' "$rejected"; fi
          printf 'find: injected scope traversal failure\n' >&2
          return 1
          ;;
        reopen)
          command find "$@" || return 1
          # Enumeration succeeds, but the staged list disappears before open.
          command rm -f -- "$OUTPUT_DIR"/.branch-scope-files.*
          return "$?"
          ;;
        read-partial)
          printf '%s\0' "$rejected" "$OUTPUT_DIR/security/injection/001.md" "$OUTPUT_DIR/security/injection/002.md"
          return 0
          ;;
      esac
    fi
    command find "$@"
  }
  check finalize_local
  printf 'scope fault=%s registry_records=%s\n' "$fault" "$(jq -s length "$LOG_BASE/final/findings.jsonl")"
  if [[ "$fault" == move ]]; then check test -f "$TMP/scope-$fault-attempted"; fi
  # A failed list read must precede every quarantine and preserve publication.
  check test -f "$rejected"
  check test ! -e "$rejected.out-of-scope"
  scope_reads=0
  rc=0
  branch_scope_filter_directory "$OUTPUT_DIR" || rc=$?
  check test "$rc" -ne 0
  unset -f find python3 read
  check test -f "$rejected"
  check test ! -e "$rejected.out-of-scope"
  if [[ "$fault" == reason ]]; then
    check rmdir "$rejected.out-of-scope.reason"
  else
    check test ! -e "$rejected.out-of-scope.reason"
  fi
  for artifact in "${artifacts[@]}"; do
    check cmp "$TMP/scope-$fault-published/$artifact" "$LOG_BASE/final/$artifact"
  done
  check test "$(command find "$OUTPUT_DIR" -name '.branch-scope-files.*' | wc -l)" -eq 0
  check finalize_local
  check test ! -e "$rejected"
  check test -f "$rejected.out-of-scope"
  check grep -q 'out-of-scope citation: src/unchanged.sh' "$rejected.out-of-scope.reason"
  check jq -se 'length == 2 and all(.[]; .title != "Unchanged source")' "$LOG_BASE/final/findings.jsonl"
  printf 'PASS: %s scope failure preserves all published artifacts; retry filters before publishing\n' "$fault"
) || exit 1
done
# repolens-r9-p3-1: a successfully produced list can still disappear or
# fail during consumption. Preserve the index, CSV and all published reports.
for list_fault in missing read-empty read-partial truncated; do
(
  LOG_BASE="$TMP/list-$list_fault-run" OUTPUT_DIR="$TMP/list-$list_fault-output"
  check cp -R "$TMP/output" "$OUTPUT_DIR"
  RUN_ID=probe MODE=audit LOCAL_MODE=true OUTPUT_DIR_SET=true
  HUMAN_REVIEW=true REPOLENS_FINAL_STATE=finished
  check finalize_local
  artifacts=(findings.jsonl findings.csv TODO.md SUMMARY.md NEEDS_REVIEW.md DUPLICATES.md HUMAN_REVIEW.md)
  check mkdir "$TMP/list-$list_fault-published"
  for artifact in "${artifacts[@]}"; do
    check cp "$LOG_BASE/final/$artifact" "$TMP/list-$list_fault-published/$artifact"
  done
  list_reads=0
  # Allocate normally, then inject list loss/truncation before ingestion opens it.
  mktemp() {
    local created
    created="$(command mktemp "$@")" || return 1
    # Snapshot allocation follows enumeration and precedes the list open.
    if [[ "${1:-}" == *.source.XXXXXX ]]; then
      case "$list_fault" in
        missing) command rm -- "${1%.source.XXXXXX}.files" || return 1 ;;
        truncated) command truncate -s -1 -- "${1%.source.XXXXXX}.files" || return 1 ;;
      esac
    fi
    printf '%s\n' "$created"
  }
  # Fail only the registry's list reads, leaving other callers' reads intact.
  read() {
    if [[ "${FUNCNAME[1]:-}" == build_findings_jsonl_from_local ]]; then
      case "$list_fault" in
        read-empty) return 1 ;;
        read-partial)
          if (( list_reads > 0 )); then return 1; fi
          list_reads=$((list_reads + 1))
          ;;
      esac
    fi
    # shellcheck disable=SC2162 # Preserve the delegated caller's -r/-d flags.
    builtin read "$@"
  }
  rc=0
  build_findings_jsonl_from_local "$OUTPUT_DIR" "$LOG_BASE/final/findings.jsonl" || rc=$?
  check test "$rc" -ne 0
  check cmp "$TMP/list-$list_fault-published/findings.jsonl" "$LOG_BASE/final/findings.jsonl"
  list_reads=0
  check finalize_local
  unset -f mktemp read
  for artifact in "${artifacts[@]}"; do
    check cmp "$TMP/list-$list_fault-published/$artifact" "$LOG_BASE/final/$artifact"
  done
  check test "$(command find "$LOG_BASE/final" -name '*.tmp.*' | wc -l)" -eq 0
  check test "$(command find "$OUTPUT_DIR" -name '*.md' | wc -l)" -eq 2
  # Access repair must allow a real refresh rather than pinning old artifacts.
  check rm "$OUTPUT_DIR/security/injection/002.md"
  check finalize_local
  check jq -se 'length == 1 and .[0].title == "Unsafe query"' "$LOG_BASE/final/findings.jsonl"
  check test "$(wc -l < "$LOG_BASE/final/findings.csv")" -eq 2
  printf 'PASS: %s staged-list failure preserves registry, CSV and reports; retry refreshes\n' "$list_fault"
) || exit 1
done
# repolens-r9-p4-3: unavailable scope evidence is an operational failure,
# never a reason to quarantine a valid finding or replace current reports.
for scope_fault in unreadable missing malformed; do
(
  LOG_BASE="$TMP/scope-io-$scope_fault-run" OUTPUT_DIR="$TMP/scope-io-$scope_fault-output"
  check cp -R "$TMP/output" "$OUTPUT_DIR"
  BRANCH_SCOPE_FILE="$TMP/scope-io-$scope_fault.json"
  check printf '["src/changed.sh"]\n' > "$BRANCH_SCOPE_FILE"
  RUN_ID=probe MODE=branch-review LOCAL_MODE=true OUTPUT_DIR_SET=true
  HUMAN_REVIEW=true REPOLENS_FINAL_STATE=finished
  check finalize_local
  artifacts=(findings.jsonl findings.csv TODO.md SUMMARY.md NEEDS_REVIEW.md DUPLICATES.md HUMAN_REVIEW.md)
  check mkdir "$TMP/scope-io-$scope_fault-published"
  for artifact in "${artifacts[@]}"; do
    check cp "$LOG_BASE/final/$artifact" "$TMP/scope-io-$scope_fault-published/$artifact"
  done
  check printf -- '---\ntitle: Newly confirmed valid finding\nseverity: high\n---\nsrc/changed.sh:1 Evidence\n' > "$OUTPUT_DIR/security/injection/003.md"
  check printf -- '---\ntitle: Genuinely out of scope\nseverity: high\n---\nsrc/unchanged.sh:1 Evidence\n' > "$OUTPUT_DIR/security/injection/004.md"
  case "$scope_fault" in
    unreadable)
      check chmod 000 "$BRANCH_SCOPE_FILE"
      if [[ -r "$BRANCH_SCOPE_FILE" ]]; then
        jq() {
          local arg
          for arg in "$@"; do [[ "$arg" != "$BRANCH_SCOPE_FILE" ]] || return 2; done
          command jq "$@"
        }
      fi
      ;;
    missing) check rm "$BRANCH_SCOPE_FILE" ;;
    malformed) check printf '{invalid scope\n' > "$BRANCH_SCOPE_FILE" ;;
  esac
  rc=0
  branch_scope_verify_body 'src/changed.sh:1' > "$TMP/scope-reason" || rc=$?
  check test "$rc" -eq 2
  rc=0
  branch_scope_filter_directory "$OUTPUT_DIR" || rc=$?
  check test "$rc" -ne 0
  check test "$(command find "$OUTPUT_DIR" -name '*.md' | wc -l)" -eq 4
  check test "$(command find "$OUTPUT_DIR" -name '*.out-of-scope*' | wc -l)" -eq 0
  manifest="$LOG_BASE/proposals.json"
  check printf '[{"title":"Valid proposal","severity":"high","body":"src/changed.sh:1"}]\n' > "$manifest"
  check printf '[]\n' > "$manifest.out-of-scope.json"
  manifest_before="$(sha256sum "$manifest" "$manifest.out-of-scope.json")"
  rc=0
  branch_scope_filter_manifest "$manifest" || rc=$?
  check test "$rc" -ne 0
  check test "$(sha256sum "$manifest" "$manifest.out-of-scope.json")" = "$manifest_before"
  check finalize_local
  for artifact in "${artifacts[@]}"; do
    check cmp "$TMP/scope-io-$scope_fault-published/$artifact" "$LOG_BASE/final/$artifact"
  done
  check test -f "$OUTPUT_DIR/security/injection/003.md"
  check test -f "$OUTPUT_DIR/security/injection/004.md"
  unset -f jq
  if [[ -e "$BRANCH_SCOPE_FILE" ]]; then check chmod 600 "$BRANCH_SCOPE_FILE"; fi
  check printf '["src/changed.sh"]\n' > "$BRANCH_SCOPE_FILE"
  check finalize_local
  check test -f "$OUTPUT_DIR/security/injection/003.md"
  check test -f "$OUTPUT_DIR/security/injection/004.md.out-of-scope"
  check jq -se 'length == 3 and any(.[]; .title == "Newly confirmed valid finding")' "$LOG_BASE/final/findings.jsonl"
  check grep -q 'Newly confirmed valid finding' "$LOG_BASE/final/TODO.md"
  check branch_scope_filter_manifest "$manifest"
  check jq -e 'length == 1' "$manifest"
  printf 'PASS: %s scope preserves findings, manifest, registry and reports; repair retries\n' "$scope_fault"
) || exit 1
done
# Scope access can fail after the initial preflight. Both filters must still
# stop without turning valid evidence into an out-of-scope rejection.
for scope_consumer in directory manifest; do
(
  MODE=branch-review BRANCH_SCOPE_FILE="$TMP/late-scope-$scope_consumer.json"
  check printf '["src/changed.sh"]\n' > "$BRANCH_SCOPE_FILE"
  check mkdir "$TMP/late-scope-$scope_consumer"
  late_dir="$TMP/late-scope-$scope_consumer"
  check printf 'src/changed.sh:1\n' > "$late_dir/valid.md"
  late_manifest="$late_dir/proposals.json"
  check printf '[{"title":"Valid","severity":"high","body":"src/changed.sh:1"}]\n' > "$late_manifest"
  check printf '[]\n' > "$late_manifest.out-of-scope.json"
  before="$(sha256sum "$late_dir/valid.md" "$late_manifest" "$late_manifest.out-of-scope.json")"
  jq() {
    local arg scope_read=0
    for arg in "$@"; do [[ "$arg" != "$BRANCH_SCOPE_FILE" ]] || scope_read=1; done
    if (( scope_read )) && [[ -e "$late_dir/read-once" ]]; then return 2; fi
    command jq "$@" || return $?
    if (( scope_read )); then
      : > "$late_dir/read-once" || return 1
      chmod 000 "$BRANCH_SCOPE_FILE" || return 1
    fi
  }
  rc=0
  if [[ "$scope_consumer" == directory ]]; then
    branch_scope_filter_directory "$late_dir" || rc=$?
  else
    branch_scope_filter_manifest "$late_manifest" || rc=$?
  fi
  unset -f jq
  check chmod 600 "$BRANCH_SCOPE_FILE"
  check test "$rc" -ne 0
  check test "$(sha256sum "$late_dir/valid.md" "$late_manifest" "$late_manifest.out-of-scope.json")" = "$before"
  check test ! -e "$late_dir/valid.md.out-of-scope"
  check test "$(command find "$late_dir" -name '*.scope.*' | wc -l)" -eq 0
  if [[ "$scope_consumer" == directory ]]; then
    check branch_scope_filter_directory "$late_dir"
  else
    check branch_scope_filter_manifest "$late_manifest"
    check jq -e 'length == 1' "$late_manifest"
  fi
  printf 'PASS: late scope-read failure preserves %s input and retries\n' "$scope_consumer"
) || exit 1
done
printf 'Results: registry traversal failure checks passed\n'
