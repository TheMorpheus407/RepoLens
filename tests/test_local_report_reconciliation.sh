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
for lib in core summary rounds ledger synthesize verify local-dedupe human_review artifacts branch-scope; do
  # shellcheck source=/dev/null
  source "$REPO/lib/$lib.sh"
done
log_info() { :; }
log_warn() { printf '%s\n' "$*" >&2; }
optional_local_finalization() {
  # Execute the current main's actual dedupe, registry and report orchestration.
  # The non-local hook initializes readiness before this local-only slice.
  _registry_ready=false
  # shellcheck source=/dev/null
  source <(sed -n '/^# --- Local-mode deterministic dedupe/,/^unset _registry_ready _duplicate_report_ready/p' "$REPO/repolens.sh")
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

# A failed required synthesis must not publish raw, rejected findings or
# erase the previous successful registry/reports during a retry.
case_failed_synthesis() (
  local response artifact before
  for response in malformed agent-failure; do
    for prior in fresh retained; do
      (
        LOG_BASE="$FIXTURE/failed-$response-$prior"
        SUMMARY_FILE="$LOG_BASE/summary.json"
        RUN_ID=probe MODE=bugreport ROUNDS=2 AGENT=mock LOCAL_MODE=true OUTPUT_DIR_SET=false
        HUMAN_REVIEW=true REPOLENS_FINAL_STATE=finished RUN_ROUNDS_RC=0
        PROJECT_PATH="$FIXTURE"
        OUTPUT_DIR="$LOG_BASE/rounds/round-1/lens-outputs"
        mkdir -p "$OUTPUT_DIR/security/injection" "$LOG_BASE/final"
        printf '{}\n' > "$SUMMARY_FILE"
        printf -- '---\ntitle: Rejected raw finding\nseverity: high\ndomain: security\nlens: injection\n---\nEvidence: src/probe.sh:1\n' \
          > "$OUTPUT_DIR/security/injection/001-finding.md"
        compose_prompt() { printf 'mock model prompt'; }
        verifier_response() {
          jq -cn --arg path "$OUTPUT_DIR/security/injection/001-finding.md" \
            '[{finding_id:"rejected",source_finding_path:$path,status:"WRONG",notes:"Already checked."}]'
        }
        _VERIFIER_AGENT_CALLBACK=verifier_response
        run_verifier "$RUN_ID"
        if [[ "$prior" == retained ]]; then
          for artifact in findings.jsonl findings.csv TODO.md SUMMARY.md NEEDS_REVIEW.md DUPLICATES.md HUMAN_REVIEW.md; do
            printf 'Previous successful %s\n' "$artifact" > "$LOG_BASE/final/$artifact"
          done
          before="$(sha256sum "$LOG_BASE/final/"*.md "$LOG_BASE/final/findings."*)"
        fi
        run_agent() {
          [[ "$response" != agent-failure ]] || return 1
          printf 'Malformed response without an array\n'
        }
        # shellcheck source=/dev/null
        source <(sed -n '/^# --- Synthesizer (post-rounds, post-verifier)/,/^# --- Finalize ---/p' "$REPO/repolens.sh")
        test "$REPOLENS_FINAL_STATE" = failed
        test "$RUN_ROUNDS_RC" -ne 0
        test ! -e "$LOG_BASE/final/manifest.json"
        jq -e '.[0].status == "WRONG"' "$LOG_BASE/final/verification.json" >/dev/null
        optional_local_finalization
        if [[ "$prior" == retained ]]; then
          test "$(sha256sum "$LOG_BASE/final/"*.md "$LOG_BASE/final/findings."*)" = "$before"
        else
          test ! -e "$LOG_BASE/final/findings.jsonl"
          test ! -e "$LOG_BASE/final/TODO.md"
          test ! -e "$LOG_BASE/final/HUMAN_REVIEW.md"
        fi
        printf 'Failed synthesis preserves reports: %s %s\n' "$response" "$prior"
      )
    done
  done
)

# Failed preparation may retain a valid old manifest. Neither an empty nor a
# nonempty saved manifest authorizes replacing reports during a failed retry.
case_retained_manifest_failure() (
  local failure saved artifact before
  for failure in synthesis-inventory verifier-preparation rounds; do
    for saved in empty nonempty; do
      (
        LOG_BASE="$FIXTURE/retained-$failure-$saved"
        SUMMARY_FILE="$LOG_BASE/summary.json"
        RUN_ID=probe MODE=bugreport ROUNDS=2 AGENT=mock LOCAL_MODE=true OUTPUT_DIR_SET=false
        HUMAN_REVIEW=true NO_VERIFIER=false REPOLENS_FINAL_STATE=finished RUN_ROUNDS_RC=0
        PROJECT_PATH="$FIXTURE"
        OUTPUT_DIR="$LOG_BASE/rounds/round-1/lens-outputs"
        mkdir -p "$OUTPUT_DIR/security/injection" "$LOG_BASE/final"
        printf '{}\n' > "$SUMMARY_FILE"
        printf -- '---\ntitle: Current raw evidence\nseverity: high\ndomain: security\nlens: injection\n---\nEvidence: src/probe.sh:1\n' \
          > "$OUTPUT_DIR/security/injection/001-finding.md"
        jq -n --arg source "$OUTPUT_DIR/security/injection/001-finding.md" \
          '[{cluster_id:"saved",title:"Saved publication",severity:"high",domain:"security",lens:"injection",root_cause_category:"validation",source_finding_paths:[$source],cross_link_actions:[],granularity:"independent",verification_status:"verified",body:"Evidence: src/probe.sh:1",proposed_labels:[],dedup_against_existing:[]}]' \
          > "$LOG_BASE/final/manifest.json"
        optional_local_finalization
        # An empty synthesis may have been saved before an earlier registry
        # write failed, leaving the last successful reports in place.
        if [[ "$saved" == empty ]]; then printf '[]\n' > "$LOG_BASE/final/manifest.json"; fi
        if [[ "$failure" == verifier-preparation ]]; then printf '[]\n' > "$LOG_BASE/final/verification.json"; fi
        for artifact in findings.jsonl findings.csv TODO.md SUMMARY.md NEEDS_REVIEW.md DUPLICATES.md HUMAN_REVIEW.md; do
          test -f "$LOG_BASE/final/$artifact"
        done
        before="$(sha256sum "$LOG_BASE/final/"*.json "$LOG_BASE/final/"*.md "$LOG_BASE/final/findings."*)"
        compose_prompt() { printf 'mock model prompt'; }
        run_agent() { touch "$LOG_BASE/unexpected-model-call"; return 99; }
        verifier_response() { printf '[]\n'; }
        _VERIFIER_AGENT_CALLBACK=verifier_response
        case "$failure" in
          synthesis-inventory)
            NO_VERIFIER=true
            find() {
              local inventory_root="${1:-}"
              [[ "$inventory_root" != -H ]] || inventory_root="${2:-}"
              if [[ "$inventory_root" == "$LOG_BASE/rounds" ]]; then
                printf 'Injected synthesis inventory failure\n' >&2
                return 42
              fi
              command find "$@"
            }
            ;;
          verifier-preparation) AGENT='' ;;
          rounds) RUN_ROUNDS_RC=1 REPOLENS_FINAL_STATE=failed ;;
        esac
        # shellcheck source=/dev/null
        source <(sed -n '/^# --- Verifier (post-rounds/,/^# --- Finalize ---/p' "$REPO/repolens.sh")
        test "$RUN_ROUNDS_RC" -ne 0
        test "$REPOLENS_FINAL_STATE" = failed
        test ! -e "$LOG_BASE/unexpected-model-call"
        if [[ "$failure" == verifier-preparation ]]; then
          test "$(jq -r .stopped_reason "$SUMMARY_FILE")" = verifier-preparation-failed
        fi
        test -f "$LOG_BASE/final/manifest.json"
        optional_local_finalization
        if [[ "$(sha256sum "$LOG_BASE/final/"*.json "$LOG_BASE/final/"*.md "$LOG_BASE/final/findings."*)" != "$before" ]]; then
          printf 'FAIL: %s retry with retained %s manifest changed previous reports\n' "$failure" "$saved" >&2
          exit 1
        fi
        printf 'Retained %s manifest and reports after %s\n' "$saved" "$failure"
      )
    done
  done
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


# Exercise explicit output routing through real rounds and empty synthesis.
case_custom_output() (
  LOG_BASE="$FIXTURE/custom-output"
  SUMMARY_FILE="$LOG_BASE/summary.json"
  RUN_ID=probe MODE=bugreport ROUNDS=2 AGENT=mock LOCAL_MODE=true OUTPUT_DIR_SET=true
  PARALLEL=false HUMAN_REVIEW=true REPOLENS_FINAL_STATE=finished
  PROJECT_PATH="$FIXTURE" LENSES_DIR="$REPO/prompts/lenses"
  OUTPUT_DIR="$FIXTURE/custom findings"
  mkdir -p "$LOG_BASE" "$OUTPUT_DIR"
  init_summary "$SUMMARY_FILE" probe "$PROJECT_PATH" bugreport mock '' '' local "$OUTPUT_DIR"
  completed_lenses_file="$LOG_BASE/.completed"
  LENSES=(security/injection)
  validate_rounds "$MODE" "$ROUNDS" --rounds
  compose_prompt() { printf 'mock model prompt'; }
  run_agent() { printf 'LENS: injection\n'; }
  build_round_digest() { mkdir -p "$1"; printf 'mock digest\n' > "$1/digest.md"; }
  run_lens() {
    mkdir -p "$CURRENT_ROUND_OUTPUT_DIR/security/injection"
    printf -- '---\ntitle: Custom output finding round %s\nseverity: high\ndomain: security\nlens: injection\n---\nEvidence: src/probe.sh:1\n' "$CURRENT_ROUND_INDEX" \
      > "$CURRENT_ROUND_OUTPUT_DIR/security/injection/00$CURRENT_ROUND_INDEX-finding.md"
    printf '%s\n' "$1" >> "$completed_lenses_file"
  }
  run_rounds 2 LENSES
  # Custom output is outside the round-only verifier/synthesizer inventory.
  # An unexpected model call must fail the fixture, never use a provider.
  run_agent() { return 99; }
  run_verifier "$RUN_ID"
  run_synthesizer "$RUN_ID"
  test "$(jq length "$LOG_BASE/final/manifest.json")" -eq 0
  for attempt in fresh resume; do
    optional_local_finalization
    printf 'CUSTOM_OUTPUT %s registry=%s\n' "$attempt" "$(wc -l < "$LOG_BASE/final/findings.jsonl")"
    jq -se 'length == 2 and all(.status == "new")' "$LOG_BASE/final/findings.jsonl" >/dev/null
    grep -q 'Custom output finding round 1' "$LOG_BASE/final/TODO.md"
    grep -q 'Custom output finding round 2' "$LOG_BASE/final/HUMAN_REVIEW.md"
    test -s "$LOG_BASE/final/DUPLICATES.md"
  done
)

# Synthesis computes a location-based duplicate group. Registry/report
# consumers must keep its contributor provenance, links and duplicate marks.
case_manifest_metadata() (
  local field="$1"
  LOG_BASE="$FIXTURE/manifest-$field"
  OUTPUT_DIR="$LOG_BASE/rounds/round-1/lens-outputs"
  RUN_ID=probe MODE=bugreport ROUNDS=2 AGENT=mock LOCAL_MODE=true OUTPUT_DIR_SET=false
  HUMAN_REVIEW=true REPOLENS_FINAL_STATE=finished PROJECT_PATH="$FIXTURE"
  mkdir -p "$OUTPUT_DIR/security/probe" "$LOG_BASE/final"
  printf -- '---\ntitle: Rejected unrelated raw finding\nseverity: high\ndomain: security\nlens: probe\n---\nEvidence\n' \
    > "$OUTPUT_DIR/security/probe/001-rejected.md"
  local canonical="$LOG_BASE/canonical.md" contributor="$LOG_BASE/contributor.md"
  printf 'Accepted canonical evidence\n' > "$canonical"
  printf 'Accepted contributor evidence\n' > "$contributor"
  jq -n --arg canonical "$canonical" --arg contributor "$contributor" '[
    {cluster_id:"canonical",title:"missing mtls client certificate cn validation in handshake",severity:"critical",domain:"security",lens:"mtls-auth",primary_location:"src/mtls.go:88",source_finding_paths:[$canonical]},
    {cluster_id:"contributor",title:"missing mtls client certificate cn validation in startup",severity:"high",domain:"networking",lens:"tls-config",primary_location:"src/mtls.go:90",source_finding_paths:[$contributor]}
  ] | map(. + {root_cause_category:"validation",cross_link_actions:[],granularity:"independent",verification_status:"verified",body:"Evidence: src/mtls.go:88",proposed_labels:[],dedup_against_existing:[]})' \
    > "$LOG_BASE/model-response.json"
  if [[ "$field" == links-relative || "$field" == links-project ]]; then
    jq '.[0].source_finding_paths = ["canonical.md"] | .[1].source_finding_paths = ["contributor.md"]' \
      "$LOG_BASE/model-response.json" > "$LOG_BASE/relative-response.json"
    mv "$LOG_BASE/relative-response.json" "$LOG_BASE/model-response.json"
    PROJECT_PATH="$LOG_BASE"
    if [[ "$field" == links-project ]]; then
      # The provider runs inside --project, while finalization stays in the
      # caller's directory. Same-named caller files must never win resolution.
      cd "$FIXTURE"
      printf 'Unrelated caller file\n' > canonical.md
      printf 'Unrelated caller file\n' > contributor.md
    else
      cd "$PROJECT_PATH"
    fi
  fi
  compose_prompt() { printf 'mock model prompt'; }
  run_agent() ( cd "$3"; cat "$LOG_BASE/model-response.json"; )
  run_synthesizer "$RUN_ID"
  jq -e '.[0].also_reported_by | length == 1' "$LOG_BASE/final/manifest.json" >/dev/null
  jq -e '.[1].status == "duplicate"' "$LOG_BASE/final/manifest.json" >/dev/null
  optional_local_finalization
  local registry="$LOG_BASE/final/findings.jsonl"
  case "$field" in
    contributors)
      jq -se --arg path "$contributor" '.[0].also_reported_by == [{domain:"networking",lens:"tls-config",markdown_path:$path}]' "$registry" >/dev/null
      grep -q 'networking/tls-config' "$LOG_BASE/final/DUPLICATES.md"
      ;;
    links|links-relative|links-project)
      jq -se --arg path "$canonical" '.[0].markdown_path == $path' "$registry" >/dev/null
      grep -Fq "[$canonical]($canonical)" "$LOG_BASE/final/TODO.md"
      grep -Fq "[$canonical]($canonical)" "$LOG_BASE/final/HUMAN_REVIEW.md"
      if [[ "$field" == links-relative || "$field" == links-project ]]; then
        jq -se '.[0].source_finding_paths == ["canonical.md"]' "$registry" >/dev/null
        jq -se --arg path "$contributor" '.[0].also_reported_by == [{domain:"networking",lens:"tls-config",markdown_path:$path}]' "$registry" >/dev/null
        grep -Fq "[$contributor]($contributor)" "$LOG_BASE/final/DUPLICATES.md"
        # Link normalization belongs to the derived registry; keep synthesis
        # provenance as originally recorded.
        jq -e '.[0].also_reported_by[0].markdown_path == "contributor.md" and .[1].source_finding_paths == ["contributor.md"]' "$LOG_BASE/final/manifest.json" >/dev/null
      fi
      ;;
    duplicates)
      jq -se 'length == 2 and .[1].status == "duplicate"' "$registry" >/dev/null
      test "$(grep -c '^## \[' "$LOG_BASE/final/TODO.md")" -eq 1
      grep -q '1 duplicates excluded' "$LOG_BASE/final/HUMAN_REVIEW.md"
      ;;
    *) exit 2 ;;
  esac
  if grep -q 'Rejected unrelated' "$LOG_BASE/final/TODO.md"; then exit 1; fi
  printf 'Manifest metadata regression passed: %s\n' "$field"
)

# A retained empty index is insufficient to authorize report cleanup.
case_empty_preservation() (
  local scenario artifact before
  for scenario in interrupted build-failure missing-output; do
    (
      LOG_BASE="$FIXTURE/preserve-$scenario"
      OUTPUT_DIR="$LOG_BASE/output"
      RUN_ID=probe MODE=audit LOCAL_MODE=true OUTPUT_DIR_SET=false HUMAN_REVIEW=true
      REPOLENS_FINAL_STATE=finished
      mkdir -p "$LOG_BASE/final" "$OUTPUT_DIR"
      : > "$LOG_BASE/final/findings.jsonl"
      printf 'Raw evidence\n' > "$OUTPUT_DIR/evidence.txt"
      for artifact in TODO SUMMARY NEEDS_REVIEW DUPLICATES HUMAN_REVIEW; do
        printf 'Retained %s report\n' "$artifact" > "$LOG_BASE/final/$artifact.md"
      done
      before="$(sha256sum "$LOG_BASE/final/"*.md "$OUTPUT_DIR/evidence.txt")"
      case "$scenario" in
        interrupted) REPOLENS_FINAL_STATE=interrupted ;;
        build-failure) build_finding_registry() { return 1; } ;;
        missing-output) OUTPUT_DIR="$LOG_BASE/missing" ;;
      esac
      optional_local_finalization
      test "$(sha256sum "$LOG_BASE/final/"*.md "$LOG_BASE/output/evidence.txt")" = "$before"
      printf 'Retained reports after %s\n' "$scenario"
    )
  done
)

case "${1:-all}" in
  retained-manifest-failure) case_retained_manifest_failure ;;
  failed-synthesis) case_failed_synthesis ;;
  verification) case_local_verification ;;
  empty-resume) case_empty_resume ;;
  custom-output) case_custom_output ;;
  empty-preservation) case_empty_preservation ;;
  manifest-contributors) case_manifest_metadata contributors ;;
  manifest-links) case_manifest_metadata links ;;
  manifest-links-relative) case_manifest_metadata links-relative ;;
  manifest-links-project) case_manifest_metadata links-project ;;
  manifest-duplicates) case_manifest_metadata duplicates ;;
  all)
    case_retained_manifest_failure
    case_failed_synthesis
    case_local_verification
    case_empty_resume
    case_custom_output
    case_empty_preservation
    for field in contributors links links-relative links-project duplicates; do case_manifest_metadata "$field"; done
    ;;
  *) exit 2 ;;
esac
printf 'Local report reconciliation regression passed: %s\n' "${1:-all}"
