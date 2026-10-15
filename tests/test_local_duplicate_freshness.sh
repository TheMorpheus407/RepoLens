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

# Live duplicate links must still represent the current deterministic group.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
for lib in ledger local-dedupe human_review artifacts; do
  # shellcheck source=/dev/null
  source "$REPO/lib/$lib.sh"
done
failed=0 checks=0
check() {
  checks=$((checks + 1))
  if ! "$@" >/dev/null 2>&1; then
    printf 'FAIL: %s: %s\n' "$scenario" "$*"
    failed=$((failed + 1))
  fi
}
write_finding() {
  cat > "$OUTPUT_DIR/$1.md" <<EOF
---
title: $2
severity: $3
domain: security
lens: probe-$1
---
Evidence for $2 at src/state.sh:12.
EOF
}
for scenario in edited-duplicate edited-canonical threshold valid transitive; do
  LOG_BASE="$FIXTURE/$scenario/logs/probe"
  OUTPUT_DIR="$FIXTURE/$scenario/output"
  mkdir -p "$OUTPUT_DIR"
  unset DEDUPE_TITLE_SIM_PRIMARY DEDUPE_TITLE_SIM_SECONDARY
  write_finding a 'Unsafe access to shared state' high
  write_finding b 'Unsafe access to shared state' critical
  expected_new=1 expected_duplicates=1
  if [[ "$scenario" == transitive ]]; then
    # A matches B and B matches C; A does not directly match canonical C.
    export DEDUPE_TITLE_SIM_PRIMARY=5000
    write_finding a 'alpha beta gamma delta' high
    write_finding b 'alpha beta gamma delta epsilon' high
    write_finding c 'beta gamma delta epsilon' critical
    expected_duplicates=2
  fi
  dedupe_local_markdown "$OUTPUT_DIR" >/dev/null 2>&1
  check grep -qE '^status: duplicate$' "$OUTPUT_DIR/a.md"
  case "$scenario" in
    edited-duplicate) sed -i 's/^title:.*/title: Credentials exposed through request logs/' "$OUTPUT_DIR/a.md" ;;
    edited-canonical) sed -i 's/^title:.*/title: Credentials exposed through request logs/' "$OUTPUT_DIR/b.md" ;;
    threshold) export DEDUPE_TITLE_SIM_PRIMARY=10001 DEDUPE_TITLE_SIM_SECONDARY=10001 ;;
  esac
  if [[ "$scenario" != valid && "$scenario" != transitive ]]; then
    expected_new=2 expected_duplicates=0
    # Successful no-group dedupe intentionally preserves singleton markdown.
    dedupe_local_markdown "$OUTPUT_DIR" >/dev/null 2>&1
    check grep -qE '^status: duplicate$' "$OUTPUT_DIR/a.md"
  fi
  before="$(sha256sum "$OUTPUT_DIR/"*.md)"
  build_finding_registry probe "$OUTPUT_DIR"
  findings="$LOG_BASE/final/findings.jsonl"
  # Standalone ledger loading must resolve the same grouping helpers lazily.
  bash -c 'set -euo pipefail; source "$1/lib/ledger.sh"; build_findings_jsonl_from_local "$2" "$3"' \
    _ "$REPO" "$OUTPUT_DIR" "$LOG_BASE/standalone.jsonl"
  check cmp -s "$findings" "$LOG_BASE/standalone.jsonl"
  if [[ "$scenario" == transitive ]]; then
    # The old implementation loads this helper only in a grouping subshell.
    # shellcheck source=/dev/null
    source "$REPO/lib/dedupe.sh"
    a="$(jq -c 'select(.lens == "probe-a")' "$findings")"
    c="$(jq -c 'select(.lens == "probe-c")' "$findings")"
    check test "$(if _dedupe_is_match "$a" "$c"; then echo match; else echo distinct; fi)" = distinct
  fi
  check jq -se --argjson actions "$expected_new" --argjson duplicates "$expected_duplicates" \
    '(map(select(.status == "new")) | length) == $actions
      and (map(select(.status == "duplicate")) | length) == $duplicates' "$findings"
  check jq -se --argjson duplicates "$expected_duplicates" \
    '[.[].also_reported_by[]?] | length == $duplicates' "$findings"
  render_human_review_digest probe
  generate_todo_md "$findings" "$LOG_BASE/final/TODO.md"
  generate_duplicates_md "$findings" "$LOG_BASE/final/DUPLICATES.md"
  check test "$(grep -c '^### ' "$LOG_BASE/final/HUMAN_REVIEW.md" || true)" -eq "$expected_new"
  check test "$(tail -n +2 "$LOG_BASE/final/findings.csv" | grep -c ',"new",' || true)" -eq "$expected_new"
  if [[ "$scenario" == edited-* ]]; then
    check grep -q 'Credentials exposed through request logs' "$LOG_BASE/final/TODO.md"
    check grep -q 'No duplicate groups' "$LOG_BASE/final/DUPLICATES.md"
  fi
  check test "$before" = "$(sha256sum "$OUTPUT_DIR/"*.md)"
  registry_before="$(sha256sum "$findings")"
  build_finding_registry probe "$OUTPUT_DIR"
  check test "$registry_before" = "$(sha256sum "$findings")"
done
unset DEDUPE_TITLE_SIM_PRIMARY DEDUPE_TITLE_SIM_SECONDARY
# Failed grouping and cancellation preserve the previous published registry.
for scenario in grouping-failure grouping-cancelled; do
  (
    OUTPUT_DIR="$FIXTURE/valid/output"
    out="$FIXTURE/$scenario.jsonl"
    printf 'previous complete registry\n' > "$out"
    before="$(sha256sum "$out")"
    # shellcheck disable=SC2329 # Called by production ledger ingestion.
    _synthesize_compute_duplicate_groups() {
      if [[ "$scenario" == grouping-failure ]]; then return 1; fi
      # shellcheck disable=SC2034 # Production ledger reads cancellation state.
      REPOLENS_FINAL_STATE=interrupted REPOLENS_INTERRUPT_EXIT_CODE=143
      return 0
    }
    rc=0 expected=1
    [[ "$scenario" != grouping-cancelled ]] || expected=143
    build_findings_jsonl_from_local "$OUTPUT_DIR" "$out" || rc=$?
    [[ "$rc" == "$expected" && "$before" == "$(sha256sum "$out")" ]] \
      && [[ "$(find "$FIXTURE" -maxdepth 1 -name "$scenario.jsonl.tmp.*" | wc -l)" == 0 ]]
  ) && result=0 || result=$?
  check test "$result" -eq 0
done
# A returning signal during successful JSON assembly must not admit grouping.
# Exercise the production handlers, real parser/grouping and resumable output.
eval "$(declare -f _synthesize_compute_duplicate_groups | sed '1s/_synthesize_compute_duplicate_groups/original_compute_duplicate_groups/')"
for signal in HUP INT TERM NONE; do
  scenario="assembly-$signal"
  out="$FIXTURE/$scenario.jsonl"
  groups="$FIXTURE/$scenario.groups"
  signalled="$FIXTURE/$scenario.signalled"
  printf 'previous complete registry\n' > "$out"
  before="$(sha256sum "$out")"
  rc=0 expected=0
  case "$signal" in HUP) expected=129 ;; INT) expected=130 ;; TERM) expected=143 ;; esac
  (
    signal_parent="$BASHPID"
    # shellcheck disable=SC2034 # Sourced ingestion and production traps read it.
    REPOLENS_FINAL_STATE=finished
    eval "$(sed -n '/^_final_signal_generation=0/,/^_install_finalization_signal_handlers$/p' "$REPO/repolens.sh")"
    # shellcheck disable=SC2329 # Invoked by the real ingestion path.
    _synthesize_compute_duplicate_groups() {
      printf 'grouping\n' >> "$groups"
      original_compute_duplicate_groups "$@"
    }
    # shellcheck disable=SC2329 # Inject after the real successful assembly.
    jq() {
      command jq "$@" || return $?
      if [[ "$signal" != NONE && "${1:-}" == -s && "${2:-}" == . && ! -e "$signalled" ]]; then
        : > "$signalled"
        kill -s "$signal" "$signal_parent"
      fi
    }
    build_findings_jsonl_from_local "$FIXTURE/valid/output" "$out"
  ) || rc=$?
  check test "$rc" -eq "$expected"
  check test "$(find "$FIXTURE" -maxdepth 1 -name "$scenario.jsonl.tmp.*" | wc -l)" -eq 0
  if [[ "$signal" == NONE ]]; then
    check test "$(wc -l < "$groups")" -eq 1
    check cmp -s "$out" "$FIXTURE/valid/logs/probe/final/findings.jsonl"
  else
    check test -f "$signalled"
    check test ! -e "$groups"
    check test "$before" = "$(sha256sum "$out")"
    # Resume without cancellation produces the same complete registry.
    build_findings_jsonl_from_local "$FIXTURE/valid/output" "$out"
    check cmp -s "$out" "$FIXTURE/valid/logs/probe/final/findings.jsonl"
  fi
done
printf 'Local duplicate freshness: %s checks, %s failures.\n' "$checks" "$failed"
(( failed == 0 ))
