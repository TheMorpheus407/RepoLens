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

# repolens-r4-p2-3/4: synthesized verdicts and empty resumes govern reports.
# shellcheck disable=SC2034,SC2329 # Production functions consume fixture globals.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
for lib in core rounds ledger synthesize verify local-dedupe human_review artifacts branch-scope; do
  # shellcheck source=/dev/null
  source "$REPO/lib/$lib.sh"
done
log_info() { :; }
log_warn() { printf '%s\n' "$*" >&2; }
optional_local_finalization() {
  # Execute the current main's actual dedupe, registry and report orchestration.
  # shellcheck source=/dev/null
  source <(sed -n '/^# --- Local-mode deterministic dedupe/,/^unset _local_registry_ready _duplicate_report_ready/p' "$REPO/repolens.sh")
}

case_local_verification() (
  LOG_BASE="$FIXTURE/multiround"
  SUMMARY_FILE="$LOG_BASE/summary.json"
  RUN_ID=probe MODE=bugreport ROUNDS=2 AGENT=mock LOCAL_MODE=true OUTPUT_DIR_SET=false
  PARALLEL=false HUMAN_REVIEW=true REPOLENS_FINAL_STATE=finished
  PROJECT_PATH="$FIXTURE"
  LENSES_DIR="$REPO/prompts/lenses"
  mkdir -p "$LOG_BASE"
  completed_lenses_file="$LOG_BASE/.completed"
  OUTPUT_DIR="$(round_lens_outputs_dir "$RUN_ID" 1)"
  LENSES=(security/injection)
  validate_rounds "$MODE" "$ROUNDS" --rounds
  compose_prompt() { printf 'mock model prompt'; }
  run_agent() { printf 'LENS: injection\n'; }
  build_round_digest() { mkdir -p "$1"; printf 'mock digest\n' > "$1/digest.md"; }
  run_lens() {
    local title='SQL injection in query construction'
    [[ "$CURRENT_ROUND_INDEX" == 1 ]] || title='Missing authorization on account deletion'
    mkdir -p "$CURRENT_ROUND_OUTPUT_DIR/security/injection"
    printf -- '---\ntitle: %s\nseverity: high\ndomain: security\nlens: injection\n---\nEvidence: src/probe.sh:1\n' "$title" \
      > "$CURRENT_ROUND_OUTPUT_DIR/security/injection/001-finding.md"
    printf '%s\n' "$1" >> "$completed_lenses_file"
  }
  run_rounds 2 LENSES
  # Both findings were determined to be false positives. Drive the real
  # verifier and synthesizer with schema-valid model responses, then the main's
  # actual local finalization. No provider calls take place.
  verifier_response() {
    find "$LOG_BASE/rounds" -name '001-finding.md' -print | sort | \
      jq -Rn '[inputs | {finding_id:.,source_finding_path:.,status:"WRONG",notes:"The cited operation already checks authorization and parameterizes input."}]'
  }
  _VERIFIER_AGENT_CALLBACK=verifier_response
  run_verifier "$RUN_ID"
  run_agent() { printf '[]\n'; }
  run_synthesizer "$RUN_ID"
  optional_local_finalization
  printf 'LOCAL_VERIFICATION wrong_verdicts=%s manifest_clusters=%s registry=%s rejected_round1_in_TODO=%s\n' \
    "$(jq 'map(select(.status == "WRONG")) | length' "$LOG_BASE/final/verification.json")" \
    "$(jq length "$LOG_BASE/final/manifest.json")" \
    "$(wc -l < "$LOG_BASE/final/findings.jsonl")" \
    "$(grep -c 'SQL injection' "$LOG_BASE/final/TODO.md" 2>/dev/null || true)"
  test "$(find "$LOG_BASE/rounds" -name '001-finding.md' | wc -l)" -eq 2
  test "$(jq length "$LOG_BASE/final/manifest.json")" -eq 0
  test ! -s "$LOG_BASE/final/findings.jsonl"
  test "$(wc -l < "$LOG_BASE/final/findings.csv")" -eq 1
  test ! -e "$LOG_BASE/final/TODO.md"
  grep -q '_No findings to review._' "$LOG_BASE/final/HUMAN_REVIEW.md"
  # An accepted manifest must also stay authoritative over rejected raw files.
  printf -- '---\ntitle: Approved manifest finding\nseverity: high\ndomain: security\nlens: injection\n---\nEvidence: src/probe.sh:1\n' > "$LOG_BASE/approved-source.md"
  jq -n --arg source "$LOG_BASE/approved-source.md" '[{cluster_id:"accepted",title:"Approved manifest finding",severity:"high",domain:"security",lens:"injection",root_cause_category:"missing-validation",source_finding_paths:[$source],cross_link_actions:[],granularity:"independent",verification_status:"verified",body:"Evidence: src/probe.sh:1",proposed_labels:[],dedup_against_existing:[]}]' > "$LOG_BASE/final/manifest.json"
  validate_manifest "$LOG_BASE/final/manifest.json"
  optional_local_finalization
  jq -se 'length == 1 and .[0].title == "Approved manifest finding"' "$LOG_BASE/final/findings.jsonl" >/dev/null
  grep -q 'Approved manifest finding' "$LOG_BASE/final/TODO.md"
  if grep -q 'SQL injection\|Missing authorization' "$LOG_BASE/final/TODO.md"; then exit 1; fi
)

case_empty_resume() (
  LOG_BASE="$FIXTURE/empty-resume"
  OUTPUT_DIR="$LOG_BASE/output"
  RUN_ID=probe MODE=audit ROUNDS=1 LOCAL_MODE=true HUMAN_REVIEW=true REPOLENS_FINAL_STATE=finished
  mkdir -p "$OUTPUT_DIR/security/injection"
  printf -- '---\ntitle: Removed obsolete finding\nseverity: high\ndomain: security\nlens: injection\n---\nEvidence\n' \
    > "$OUTPUT_DIR/security/injection/001-finding.md"
  optional_local_finalization
  test -s "$LOG_BASE/final/TODO.md"
  rm -- "$OUTPUT_DIR/security/injection/001-finding.md"
  optional_local_finalization
  printf 'EMPTY_RESUME registry=%s old_TODO_entries=%s digest_empty=%s\n' \
    "$(wc -l < "$LOG_BASE/final/findings.jsonl")" \
    "$(grep -c 'Removed obsolete finding' "$LOG_BASE/final/TODO.md" 2>/dev/null || true)" \
    "$(grep -c '_No findings to review._' "$LOG_BASE/final/HUMAN_REVIEW.md" || true)"
  test ! -s "$LOG_BASE/final/findings.jsonl"
  for artifact in TODO SUMMARY NEEDS_REVIEW DUPLICATES; do
    test ! -e "$LOG_BASE/final/$artifact.md"
  done
  grep -q '_No findings to review._' "$LOG_BASE/final/HUMAN_REVIEW.md"
)

case "${1:-all}" in
  verification) case_local_verification ;;
  empty-resume) case_empty_resume ;;
  all) case_local_verification; case_empty_resume ;;
  *) exit 2 ;;
esac
printf 'Local report reconciliation regression passed: %s\n' "${1:-all}"
