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

# Exercise production finalization and real local registry/report writers.
# shellcheck disable=SC2034,SC2329 # Extracted production code consumes fixtures.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
for lib in core summary attempts result_pointer cursor_ide ledger synthesize local-dedupe human_review artifacts branch-scope; do
  # shellcheck source=/dev/null
  source "$REPO/lib/$lib.sh"
done
eval "$(sed -n '/^rate_limit_sleep_interrupt_marker() {/,/^_handle_hangup() {/p' "$REPO/repolens.sh" | sed '$d')"
log_info() { :; }
log_warn() { :; }
print_resume_hint() { :; }
# Remote report fixtures have no filed issues; never query a live forge.
filing_verified_issue_count() { printf '0\n'; }
eval "$(declare -f dedupe_local_markdown | sed '1s/dedupe_local_markdown/original_dedupe/')"
dedupe_local_markdown() {
  original_dedupe "$@" || return $?
  if [[ "$SIGNAL" != NONE && "$scenario" != triage-* ]]; then kill -s "$SIGNAL" "$SIGNAL_PARENT_PID"; fi
}
eval "$(declare -f generate_duplicates_md | sed '1s/generate_duplicates_md/original_duplicates/')"
generate_duplicates_md() {
  local duplicate_rc=0
  original_duplicates "$@" || duplicate_rc=$?
  if [[ "$scenario" == *report-*-failure ]]; then
    printf '%s\n' "$duplicate_rc" > "$LOG_BASE/duplicate-report.rc"
  fi
  (( duplicate_rc == 0 )) || return "$duplicate_rc"
  if [[ "$SIGNAL" != NONE && "$scenario" == triage-* ]]; then kill -s "$SIGNAL" "$SIGNAL_PARENT_PID"; fi
}
run_finalization() (
  SIGNAL_PARENT_PID="$BASHPID"
  REPOLENS_FINAL_STATE=finished REPOLENS_INTERRUPT_EXIT_CODE=130 RUN_ROUNDS_RC=0
  RUN_ID=20261015T000000Z-local MODE=audit AGENT=mock PARALLEL=false
  SCRIPT_DIR="${LOG_BASE%/logs/*}" LOCAL_MODE=true
  if [[ "$scenario" == remote* ]]; then LOCAL_MODE=false; OUTPUT_DIR=""; fi
  MAX_ISSUES=1 REPOLENS_DEGENERATE_THRESHOLD=90 CURSOR_IDE_ACTIVE=true
  REPOLENS_CURSOR_IDE_CTL_LOG="$LOG_BASE/control.ndjson"
  if [[ "$scenario" == registry-failure ]]; then build_finding_registry() { return 1; }; fi
  # Exercise a real pre-promotion failure with an already-published registry.
  if [[ "$scenario" == stale-registry-failure ]]; then validate_findings_jsonl() { return 1; }; fi
  if [[ "$scenario" == digest-failure ]]; then render_human_review_digest() { return 1; }; fi
  if [[ "$scenario" == duplicate-report-failure ]]; then generate_duplicates_md() { return 1; }; fi
  if [[ "$scenario" == *report-render-failure ]]; then
    jq() {
      [[ "$*" != *'# DUPLICATES — Merged Finding Groups'* ]] || return 1
      command jq "$@"
    }
  fi
  if [[ "$scenario" == *report-promote-failure ]]; then
    python3() {
      [[ "${*: -1}" != "$LOG_BASE/final/DUPLICATES.md" ]] || return 1
      command python3 "$@"
    }
  fi
  # shellcheck source=/dev/null
  source <(sed -n '/^# --- Finalize ---/,$p' "$REPO/repolens.sh")
)
failed=0 cases=0
check() {
  if ! "$@" >/dev/null 2>&1; then
    printf 'FAIL: %s/%s: %s\n' "$scenario" "$HUMAN_REVIEW" "$*"
    failed=$((failed + 1))
  fi
}
for scenario in fresh remote remote-no-source absent-HUP absent-INT absent-TERM stale-HUP stale-INT stale-TERM triage-HUP triage-INT triage-TERM empty same-lens-first same-lens-last registry-failure stale-registry-failure digest-failure duplicate-report-failure stale-report-render-failure stale-report-promote-failure remote-report-render-failure remote-report-promote-failure; do
  for HUMAN_REVIEW in true false; do
    # Digest opt-out needs fresh and resumed coverage; other cases share the path.
    [[ "$HUMAN_REVIEW" == true || "$scenario" == fresh || "$scenario" == absent-TERM ]] || continue
    LOG_BASE="$FIXTURE/$scenario-$HUMAN_REVIEW/logs/20261015T000000Z-local"
    SUMMARY_FILE="$LOG_BASE/summary.json"
    OUTPUT_DIR="$LOG_BASE/output"
    mkdir -p "$OUTPUT_DIR/security/probe"
    init_summary "$SUMMARY_FILE" local "$FIXTURE" audit mock
    if [[ "$scenario" != empty ]]; then
      for n in 1 2; do
        lens="probe-$n" filename=001-finding.md severity=high
        if [[ "$scenario" == same-lens-* ]]; then
          lens=probe filename="00$n-finding.md" severity=medium
          if [[ "$scenario-$n" == same-lens-first-1 || "$scenario-$n" == same-lens-last-2 ]]; then severity=high; fi
        fi
        mkdir -p "$OUTPUT_DIR/security/$lens"
        cat > "$OUTPUT_DIR/security/$lens/$filename" <<EOF
---
title: "Unsafe access to shared state"
severity: $severity
type: reliability-bug
domain: security
lens: $lens
---
Shared state access at src/state.sh:12 needs synchronization.
EOF
      done
    fi
    if [[ "$scenario" == stale-HUP || "$scenario" == stale-INT || "$scenario" == stale-TERM || "$scenario" == stale-registry-failure ]]; then
      build_finding_registry local "$OUTPUT_DIR"
      check jq -se 'length == 2 and all(.status == "new")' "$LOG_BASE/final/findings.jsonl"
    fi
    # Seed saved data with the real local writers, then provide the current
    # manifest required by non-local finalization. No local output is ingested.
    if [[ "$scenario" == remote* ]]; then
      original_dedupe "$OUTPUT_DIR"
      build_finding_registry local "$OUTPUT_DIR"
      if [[ "$scenario" != remote-no-source ]]; then
        jq -s 'map(. + {source_finding_paths: [.markdown_path]})' \
          "$LOG_BASE/final/findings.jsonl" > "$LOG_BASE/final/manifest.json"
      fi
    fi
    # A saved registry without current source must preserve every saved report.
    if [[ "$scenario" == remote-no-source ]]; then
      for artifact in TODO SUMMARY NEEDS_REVIEW DUPLICATES HUMAN_REVIEW; do
        printf 'Saved %s report\n' "$artifact" > "$LOG_BASE/final/$artifact.md"
      done
      saved_artifacts="$(sha256sum "$LOG_BASE/final/"*)"
    fi
    # Model retained output from an earlier attempt. Render/rename failures must
    # preserve it without advertising it as provenance for the rebuilt registry.
    retained_report=false
    if [[ "$scenario" == *report-*-failure ]]; then
      retained_report=true
      mkdir -p "$LOG_BASE/final"
      printf 'Retained previous duplicate report\n' > "$LOG_BASE/final/DUPLICATES.md"
    fi
    attempts_begin "$LOG_BASE"
    SIGNAL=NONE
    case "$scenario" in absent-*|triage-*|stale-HUP|stale-INT|stale-TERM) SIGNAL="${scenario##*-}" ;; esac
    rc=0
    run_finalization > "$LOG_BASE/first.log" 2>&1 || rc=$?
    if [[ "$SIGNAL" != NONE ]]; then
      expected=130
      case "$SIGNAL" in HUP) expected=129 ;; TERM) expected=143 ;; esac
      check test "$rc" -eq "$expected"
      check jq -e --argjson code "$expected" 'length == 1 and last.status == "interrupted" and last.exit_code == $code' "$LOG_BASE/attempts.json"
      for artifact in HUMAN_REVIEW TODO SUMMARY NEEDS_REVIEW DUPLICATES; do
        if [[ "$scenario" == triage-* && "$artifact" != HUMAN_REVIEW ]]; then
          check test -s "$LOG_BASE/final/$artifact.md"
        else
          check test ! -e "$LOG_BASE/final/$artifact.md"
        fi
      done
      if [[ "$scenario" == absent-* ]]; then
        check test ! -e "$LOG_BASE/final/findings.jsonl"
      elif [[ "$scenario" == triage-* ]]; then
        check jq -se 'length == 2 and (map(select(.status == "duplicate")) | length) == 1' "$LOG_BASE/final/findings.jsonl"
      else
        check jq -se 'all(.status == "new")' "$LOG_BASE/final/findings.jsonl"
      fi
      SIGNAL=NONE
      attempts_begin "$LOG_BASE"
      rc=0
      run_finalization > "$LOG_BASE/resume.log" 2>&1 || rc=$?
      check jq -e 'length == 2 and .[0].status == "interrupted" and last.exit_code == 0' "$LOG_BASE/attempts.json"
      check jq -se 'length == 2 and .[0].outcome == "interrupted" and (.[1].outcome | startswith("finished"))' "$LOG_BASE/control.ndjson"
    else
      check jq -e 'length == 1 and last.exit_code == 0' "$LOG_BASE/attempts.json"
      check jq -se 'length == 1 and (.[0].outcome | startswith("finished"))' "$LOG_BASE/control.ndjson"
    fi
    check test "$rc" -eq 0
    check jq -e '.status | startswith("finished")' "${LOG_BASE%/*}/latest-result.json"
    check test ! -e "$LOG_BASE/.attempt-start"
    if [[ "$scenario" == remote-no-source ]]; then
      check test "$(sha256sum "$LOG_BASE/final/"*)" = "$saved_artifacts"
      check test ! -e "$LOG_BASE/final/manifest.json"
      cases=$((cases + 1))
      continue
    fi
    if [[ "$scenario" == stale-registry-failure ]]; then
      check jq -se 'length == 2 and all(.status == "new")' "$LOG_BASE/final/findings.jsonl"
      check test ! -e "$LOG_BASE/final/HUMAN_REVIEW.md"
    elif [[ "$scenario" == registry-failure ]]; then
      check test ! -e "$LOG_BASE/final/findings.jsonl"
      check test ! -e "$LOG_BASE/final/HUMAN_REVIEW.md"
    else
      check test -f "$LOG_BASE/final/findings.csv"
      if [[ "$scenario" == empty ]]; then
        check test ! -s "$LOG_BASE/final/findings.jsonl"
      elif [[ "$scenario" == same-lens-* ]]; then
        canonical=001-finding.md
        [[ "$scenario" != same-lens-last ]] || canonical=002-finding.md
        check jq -se --arg path "$OUTPUT_DIR/security/probe/$canonical" 'length == 1 and .[0].status == "new" and .[0].severity == "high" and .[0].markdown_path == $path and (.[0].also_reported_by | length) == 1' "$LOG_BASE/final/findings.jsonl"
        check test "$(wc -l < "$LOG_BASE/final/findings.csv")" -eq 2
      else
        check jq -se 'length == 2 and (map(select(.status == "duplicate")) | length) == 1' "$LOG_BASE/final/findings.jsonl"
        check jq -se 'map(select(.status == "new")) | length == 1 and (.[0].also_reported_by | length) == 1' "$LOG_BASE/final/findings.jsonl"
      fi
      if [[ "$HUMAN_REVIEW" == true && "$scenario" != digest-failure ]]; then
        check test -s "$LOG_BASE/final/HUMAN_REVIEW.md"
        if [[ "$scenario" != empty ]]; then
          check test "$(grep -cE '^### .*Unsafe access to shared state' "$LOG_BASE/final/HUMAN_REVIEW.md" || true)" -eq 1
          if [[ "$scenario" == duplicate-report-failure || "$retained_report" == true ]]; then
            check test "$(grep -cF '[DUPLICATES.md](DUPLICATES.md)' "$LOG_BASE/final/HUMAN_REVIEW.md" || true)" -eq 0
            check grep -qF '[findings.jsonl](findings.jsonl)' "$LOG_BASE/final/HUMAN_REVIEW.md"
          elif [[ "$scenario" == same-lens-* ]]; then
            # Identical-ID collapse leaves no excluded duplicate row to link.
            check test "$(grep -cF '[DUPLICATES.md](DUPLICATES.md)' "$LOG_BASE/final/HUMAN_REVIEW.md" || true)" -eq 0
          else
            check grep -qF '[DUPLICATES.md](DUPLICATES.md)' "$LOG_BASE/final/HUMAN_REVIEW.md"
          fi
        fi
      else
        check test ! -e "$LOG_BASE/final/HUMAN_REVIEW.md"
      fi
    fi
    for artifact in TODO SUMMARY NEEDS_REVIEW DUPLICATES; do
      if [[ "$artifact" == DUPLICATES && "$retained_report" == true ]]; then
        check test "$(cat "$LOG_BASE/duplicate-report.rc")" -eq 1
        check test "$(cat "$LOG_BASE/final/DUPLICATES.md")" = 'Retained previous duplicate report'
        check test "$(find "$LOG_BASE/final" -name '.duplicates.*' | wc -l)" -eq 0
      elif [[ "$scenario" == empty || "$scenario" == registry-failure || "$scenario" == stale-registry-failure \
          || ( "$scenario" == duplicate-report-failure && "$artifact" == DUPLICATES ) ]]; then
        check test ! -e "$LOG_BASE/final/$artifact.md"
      else
        check test -s "$LOG_BASE/final/$artifact.md"
      fi
    done
    if [[ "$scenario" != empty && "$scenario" != registry-failure && "$scenario" != stale-registry-failure ]]; then
      check grep -qE 'Unsafe access to shared state' "$LOG_BASE/final/TODO.md"
      check test "$(grep -cE 'Unsafe access to shared state' "$LOG_BASE/final/TODO.md")" -eq 1
      if [[ "$scenario" != duplicate-report-failure && "$retained_report" == false ]]; then
        check grep -qE 'Unsafe access to shared state' "$LOG_BASE/final/DUPLICATES.md"
        check test "$(grep -cE 'Unsafe access to shared state' "$LOG_BASE/final/DUPLICATES.md")" -eq 1
      fi
    fi
    if $retained_report; then
      # A subsequent successful resume replaces the retained report and restores
      # its link; the failed attempt remains in the durable history.
      saved_scenario="$scenario"
      scenario=fresh
      [[ "$saved_scenario" != remote* ]] || scenario=remote
      attempts_begin "$LOG_BASE"
      rc=0
      run_finalization > "$LOG_BASE/retry.log" 2>&1 || rc=$?
      check test "$rc" -eq 0
      check grep -qF '[DUPLICATES.md](DUPLICATES.md)' "$LOG_BASE/final/HUMAN_REVIEW.md"
      check grep -qF 'Unsafe access to shared state' "$LOG_BASE/final/DUPLICATES.md"
      check jq -e 'length == 2 and all(.exit_code == 0)' "$LOG_BASE/attempts.json"
      check jq -se 'length == 2 and all(.outcome | startswith("finished"))' "$LOG_BASE/control.ndjson"
      scenario="$saved_scenario"
    fi
    cases=$((cases + 1))
  done
done
printf 'Local finalization artifacts: %s cases, %s failures.\n' "$cases" "$failed"
(( failed == 0 ))
