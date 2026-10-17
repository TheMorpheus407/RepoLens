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


# Recovery probes use real counting, finalization and lens execution with a stub agent.
# shellcheck disable=SC2034,SC2329 # Production consumes fixture globals/callbacks.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source <(awk '/^LOG_BASE=/ {exit} /^REPO=/ {next} {print}' "$REPO/tests/test_generic_explicit_output.sh")
# shellcheck source=/dev/null
source "$REPO/lib/streak.sh"
# The local agent emits no forge URLs; retain the fixture's URL-count stub.
count_issues_in_output() { printf 0; }
restore_cap() {
  # Run the CLI's persisted-cap restoration, with a fresh invocation's flags.
  # shellcheck source=/dev/null
  source <(sed -n '/^  # A resumed governed branch review/,/^  if \[\[ -f "\$_resume_metadata"/ { /^  if \[\[ -f "\$_resume_metadata"/!p; }' "$REPO/repolens.sh")
}
initialize_counts() {
  # shellcheck source=/dev/null
  source <(awk '/^GLOBAL_ISSUES_CREATED=0$/ {copy=1} copy && /^if \[\[ "\$MODE" == branch-review/ {exit} copy {print}' "$REPO/repolens.sh")
}
for scenario in ${1:-cap ordinary partial publication admission reuse-below reuse-at reuse-above severity}; do
  (
    LOG_BASE="$FIXTURE/$scenario/run" OUTPUT_DIR="$FIXTURE/$scenario/output"
    PROJECT_PATH="$FIXTURE/project" SUMMARY_FILE="$LOG_BASE/summary.json"
    completed_lenses_file="$LOG_BASE/.completed" HEARTBEAT_DIR="$LOG_BASE/.heartbeats"
    OUTPUT_DIR_SET=true ROUNDS=1 LOCAL_MODE=true MODE=bugreport MAX_ISSUES=1
    HUMAN_REVIEW=true REPOLENS_FINAL_STATE=finished GLOBAL_ISSUES_CREATED=0
    raw="$LOG_BASE/rounds/round-1/lens-outputs/probe.md"
    mkdir -p "$(dirname "$raw")" "$OUTPUT_DIR" "$PROJECT_PATH" "$HEARTBEAT_DIR"
    : > "$completed_lenses_file"
    : > "$LOG_BASE/agent-calls"
    init_summary "$SUMMARY_FILE" probe "$PROJECT_PATH" bugreport mock '' 1 local "$OUTPUT_DIR"
    printf '%s\n' '{"lens_ids":["generic/probe|deeper|Probe||"]}' > "$LOG_BASE/rounds/round-1/metadata.json"
    printf -- '---\ndomain: generic\nlens_id: probe\nseverity: high\n---\n## hypothesis\nSaved finding\n## evidence\nSaved evidence\n' > "$raw"
    case "$scenario" in
      cap)
        cat "$raw" "$raw" > "$FIXTURE/two.md"
        mv "$FIXTURE/two.md" "$raw"
        optional_local_finalization
        # A new invocation does not inherit MAX_ISSUES from the previous shell.
        MAX_ISSUES='' _resume_summary="$SUMMARY_FILE"
        restore_cap
        initialize_counts
        optional_local_finalization
        test "$MAX_ISSUES" = 1
        test "$GLOBAL_ISSUES_CREATED" = 1
        jq -se 'length == 1' "$LOG_BASE/final/findings.jsonl" >/dev/null
        MAX_ISSUES=2
        restore_cap
        initialize_counts
        optional_local_finalization
        jq -se 'length == 2' "$LOG_BASE/final/findings.jsonl" >/dev/null
        ;;
      reuse-below|reuse-at|reuse-above)
        rm "$raw"
        mkdir -p "$OUTPUT_DIR/security/injection"
        ordinary=1 expected=1 expected_calls=0
        [[ "$scenario" != reuse-below ]] || { MAX_ISSUES=2; expected=2; expected_calls=1; }
        [[ "$scenario" != reuse-above ]] || { ordinary=2; expected=2; }
        for ((i=1; i<=ordinary; i++)); do
          printf -- '---\ntitle: Existing ordinary %s\nseverity: high\ndomain: security\nlens: injection\n---\nSaved evidence\n' "$i" > "$OUTPUT_DIR/security/injection/$i.md"
        done
        before="$(sha256sum "$OUTPUT_DIR/security/injection/"*.md)"
        initialize_counts
        test "$GLOBAL_ISSUES_CREATED" -eq "$ordinary"
        LENSES=(generic/probe)
        run_rounds 1 LENSES
        optional_local_finalization
        test "$(wc -l < "$LOG_BASE/agent-calls")" -eq "$expected_calls"
        test "$GLOBAL_ISSUES_CREATED" -eq "$expected"
        test "$(jq .totals.ordinary_issues_created "$SUMMARY_FILE")" -eq "$ordinary"
        test "$(sha256sum "$OUTPUT_DIR/security/injection/"*.md)" = "$before"
        initialize_counts
        initialize_counts
        test "$GLOBAL_ISSUES_CREATED" -eq "$expected"
        # A failed ordinary inventory cannot become zero reserved capacity.
        saved="$(sha256sum "$SUMMARY_FILE" "$LOG_BASE/final/"{generic-delivery.json,findings.jsonl,TODO.md})"
        find() {
          [[ "${2:-}" != "$OUTPUT_DIR" ]] || return 74
          command find "$@"
        }
        if reconcile_generic_local_counts; then echo 'Failed inventory accepted' >&2; exit 1; fi
        optional_local_finalization
        test "$(sha256sum "$SUMMARY_FILE" "$LOG_BASE/final/"{generic-delivery.json,findings.jsonl,TODO.md})" = "$saved"
        ;;
      severity)
        mkdir -p "$OUTPUT_DIR/security/injection"
        printf -- '---\ntitle: Ineligible existing ordinary\nseverity: low\ndomain: security\nlens: injection\n---\nSaved evidence\n' > "$OUTPUT_DIR/security/injection/1.md"
        REPOLENS_MIN_SEVERITY=high
        initialize_counts
        test "$GLOBAL_ISSUES_CREATED" = 1
        test "$(jq .totals.ordinary_issues_created "$SUMMARY_FILE")" = 0
        optional_local_finalization
        jq -e 'length == 1' "$LOG_BASE/final/generic-delivery.json" >/dev/null
        ;;
      ordinary)
        # Crash after a file write but before record_lens; Generic evidence is
        # already saved too. Its publication must reserve the ordinary file.
        mkdir -p "$OUTPUT_DIR/security/injection"
        printf -- '---\ntitle: Ordinary saved finding\nseverity: high\ndomain: security\nlens: injection\n---\nEvidence\n' > "$OUTPUT_DIR/security/injection/001.md"
        initialize_counts
        test "$GLOBAL_ISSUES_CREATED" = 1
        optional_local_finalization
        jq -se 'length == 1 and .[0].domain == "security"' "$LOG_BASE/final/findings.jsonl" >/dev/null
        # Retrying the ordinary lens creates no new file; its zero delta must
        # not erase the recovered ordinary usage or make Generic room again.
        run_lens security/injection || exit 1
        reconcile_generic_local_counts
        test "$GLOBAL_ISSUES_CREATED" = 1
        optional_local_finalization
        jq -se 'length == 1 and .[0].domain == "security"' "$LOG_BASE/final/findings.jsonl" >/dev/null
        ;;
      partial)
        printf -- '---\ndomain: generic\nlens_id: probe\nseverity: high\n---\n' > "$raw"
        initialize_counts
        test "$GLOBAL_ISSUES_CREATED" = 0
        before="$(sha256sum "$raw")"
        if export_generic_local_findings "$OUTPUT_DIR"; then
          echo 'Incomplete draft was published' >&2; exit 1
        fi
        test "$(sha256sum "$raw")" = "$before"
        run_lens generic/probe || exit 1
        optional_local_finalization
        test "$(wc -l < "$LOG_BASE/agent-calls")" -eq 1
        jq -se 'length == 1 and (.[0].title | contains("Mock finding."))' "$LOG_BASE/final/findings.jsonl" >/dev/null
        ;;
      publication|admission)
        MAX_ISSUES=2
        cat "$raw" "$raw" > "$FIXTURE/two.md"
        mv "$FIXTURE/two.md" "$raw"
        optional_local_finalization
        MAX_ISSUES=1
        if [[ "$scenario" == admission ]]; then
          before="$(sha256sum "$SUMMARY_FILE" "$LOG_BASE/final/"{generic-delivery.json,findings.jsonl,TODO.md})"
          reconcile_summary_filing() { return 74; }
          optional_local_finalization
          test "$(sha256sum "$SUMMARY_FILE" "$LOG_BASE/final/"{generic-delivery.json,findings.jsonl,TODO.md})" = "$before"
          while IFS= read -r delivered; do test -f "$delivered"; done < <(jq -r .markdown_path "$LOG_BASE/final/findings.jsonl")
          printf 'PASS: Generic budget recovery: %s\n' "$scenario"
          exit 0
        fi
        # Inject a summary lock failure only once publication has committed.
        # Earlier admission/accounting remains available. Old code recounts
        # here and suppresses rebuilding the now-stale two-row registry.
        eval "$(declare -f reconcile_summary_filing | sed '1s/reconcile_summary_filing/real_reconcile_summary_filing/')"
        reconcile_summary_filing() {
          if [[ "$(jq length "$LOG_BASE/final/generic-delivery.json")" == 1 ]]; then return 74; fi
          real_reconcile_summary_filing "$@"
        }
        optional_local_finalization
        jq -se 'length == 1' "$LOG_BASE/final/findings.jsonl" >/dev/null
        while IFS= read -r delivered; do test -f "$delivered"; done < <(jq -r .markdown_path "$LOG_BASE/final/findings.jsonl")
        grep -Fq 'Saved finding' "$LOG_BASE/final/TODO.md"
        ;;
    esac
    printf 'PASS: Generic budget recovery: %s\n' "$scenario"
  )
done
