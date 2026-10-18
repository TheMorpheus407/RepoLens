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


# repolens-r14-p6-1: documentation and incomplete drafts cannot spend the budget.
# shellcheck disable=SC2034,SC2329
set -euo pipefail
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# Reuse the complete mocked production driver without running its scenarios.
# shellcheck source=/dev/null
source <(awk '/^LOG_BASE=/ {exit} /^REPO=/ {next} {print}' "$REPO/tests/test_generic_explicit_output.sh")
# shellcheck source=/dev/null
source "$REPO/lib/streak.sh"
set -euo pipefail
LOG_BASE="$FIXTURE/metadata/run" OUTPUT_DIR="$FIXTURE/metadata/output" PROJECT_PATH="$FIXTURE/project"
SUMMARY_FILE="$LOG_BASE/summary.json" HEARTBEAT_DIR="$LOG_BASE/.heartbeats"
completed_lenses_file="$LOG_BASE/.completed"
OUTPUT_DIR_SET=true ROUNDS=1 STRATEGY=waves LOCAL_MODE=true PARALLEL=false
MODE=bugreport RUN_ID=probe HUMAN_REVIEW=true REPOLENS_FINAL_STATE=finished
GLOBAL_ISSUES_CREATED=0 MAX_ISSUES=1 REPOLENS_MIN_SEVERITY=''
mkdir -p "$LOG_BASE/triage" "$OUTPUT_DIR" "$PROJECT_PATH" "$HEARTBEAT_DIR"
printf 'First independent defect\n' > "$LOG_BASE/triage/investigation-seeds.txt"
: > "$completed_lenses_file"
: > "$LOG_BASE/agent-calls"
printf -- '---\ntitle: Output documentation\nlayout: default\n---\nUser README.\n' > "$OUTPUT_DIR/README.md"
printf -- '---\ndomain: security\nlens: injection\n---\nIncomplete draft.\n' > "$OUTPUT_DIR/no-severity.md"
printf -- '---\nseverity: high\nlens: injection\n---\nIncomplete draft.\n' > "$OUTPUT_DIR/no-domain.md"
printf -- '---\nseverity: high\ndomain: security\n---\nIncomplete draft.\n' > "$OUTPUT_DIR/no-lens.md"
printf -- '---\nseverity: urgent\ndomain: security\nlens: injection\n---\nInvalid draft.\n' > "$OUTPUT_DIR/invalid-severity.md"
# YAML null is absent attribution, including when only one field is null.
for null_value in null Null NULL '~'; do
  for null_field in domain lens; do
    domain=security lens=injection
    printf -v "$null_field" '%s' "$null_value"
    printf -- '---\nseverity: high\ndomain: %s\nlens: %s\n---\nIncomplete draft.\n' \
      "$domain" "$lens" > "$OUTPUT_DIR/null-$null_field-$null_value.md"
  done
done
# Comments do not give null or omitted attribution a value. Exercise spaces
# and tabs, either missing field, and all supported null spellings.
printf -- '---\nseverity: high\ndomain: null # pending\nlens: injection\n---\nDraft.\n' > "$OUTPUT_DIR/comment-domain.md"
printf -- '---\nseverity: high\ndomain: security\nlens: ~\t# pending\n---\nDraft.\n' > "$OUTPUT_DIR/comment-lens.md"
printf -- '---\nseverity: high\ndomain: Null # pending\nlens: NULL # pending\n---\nDraft.\n' > "$OUTPUT_DIR/comment-both.md"
printf -- '---\nseverity: high\ndomain: # pending\nlens: injection\n---\nDraft.\n' > "$OUTPUT_DIR/comment-empty-domain.md"
printf -- '---\nseverity: high\ndomain: security\nlens: # pending\n---\nDraft.\n' > "$OUTPUT_DIR/comment-empty-lens.md"
# Empty quoted scalars stay empty with legal comments, for either attribution.
empty_values=('""' "''" '"" # pending attribution' "'' # pending attribution" $'""\t# pending' $'\'\'\t# pending')
for index in "${!empty_values[@]}"; do
  for empty_field in domain lens; do
    domain=security lens=injection
    printf -v "$empty_field" '%s' "${empty_values[index]}"
    printf -- '---\nseverity: high\ndomain: %s\nlens: %s\n---\nDraft.\n' \
      "$domain" "$lens" > "$OUTPUT_DIR/empty-$empty_field-$index.md"
  done
done
init_summary "$SUMMARY_FILE" probe "$PROJECT_PATH" bugreport mock '' 1 local "$OUTPUT_DIR"
FAIL=0
# Record every assertion failure and return the aggregate result at the end.
check() {
  if "$@"; then printf 'PASS: %s\n' "$*"; else printf 'FAIL: %s\n' "$*"; FAIL=$((FAIL + 1)); fi
}
check reconcile_generic_local_counts
check test "$GLOBAL_ISSUES_CREATED" -eq 0
check test "$(jq '.totals.ordinary_issues_created' "$SUMMARY_FILE")" -eq 0
LENSES=(security/injection)
check run_rounds 1 LENSES
check test "$(wc -l < "$LOG_BASE/agent-calls")" -gt 0
check test "$(jq '.totals.ordinary_issues_created' "$SUMMARY_FILE")" -eq 0
# Canonical finding metadata counts even without an optional title.
printf -- '---\nseverity: high\ndomain: security\nlens: injection\n---\n## hypothesis\nReal ordinary finding.\n' > "$OUTPUT_DIR/real.md"
check reconcile_generic_local_counts
check test "$(jq '.totals.ordinary_issues_created' "$SUMMARY_FILE")" -eq 1
check test "$GLOBAL_ISSUES_CREATED" -eq 1
# Existing directory fallback and severity thresholds retain their semantics.
rm "$OUTPUT_DIR/real.md"
mkdir -p "$OUTPUT_DIR/security/injection"
printf -- '---\nseverity: high\n---\nOrdinary finding with directory attribution.\n' > "$OUTPUT_DIR/security/injection/001.md"
check reconcile_generic_local_counts
check test "$(jq '.totals.ordinary_issues_created' "$SUMMARY_FILE")" -eq 1
REPOLENS_MIN_SEVERITY=critical
check reconcile_generic_local_counts
check test "$(jq '.totals.ordinary_issues_created' "$SUMMARY_FILE")" -eq 0
# Null attribution also uses the existing directory fallback. Quoted scalars
# remain literal strings; the registry must not erase their identity.
REPOLENS_MIN_SEVERITY=''
printf -- '---\nseverity: high\ndomain: null # pending\nlens: ~\t# pending\n---\nDirectory-attributed finding.\n' > "$OUTPUT_DIR/security/injection/001.md"
check reconcile_generic_local_counts
check test "$GLOBAL_ISSUES_CREATED" -eq 1
check build_findings_jsonl_from_local "$OUTPUT_DIR" "$LOG_BASE/registry.jsonl"
check jq -se 'any(.[]; (.markdown_path | endswith("/security/injection/001.md")) and .domain == "security" and .lens == "injection")' "$LOG_BASE/registry.jsonl"
# Quoted empties with comments also use the normal directory fallback.
printf -- '---\nseverity: high\ndomain: "" # pending\nlens: '\'''\''\t# pending\n---\nDirectory-attributed finding.\n' > "$OUTPUT_DIR/security/injection/001.md"
check reconcile_generic_local_counts
check test "$GLOBAL_ISSUES_CREATED" -eq 1
check build_findings_jsonl_from_local "$OUTPUT_DIR" "$LOG_BASE/registry.jsonl"
check jq -se 'any(.[]; (.markdown_path | endswith("/security/injection/001.md")) and .domain == "security" and .lens == "injection")' "$LOG_BASE/registry.jsonl"
printf -- '---\nseverity: high\ndomain: "null"\nlens: '\''~'\''\ntitle: null\n---\nLiteral metadata.\n' > "$OUTPUT_DIR/quoted.md"
check build_findings_jsonl_from_local "$OUTPUT_DIR" "$LOG_BASE/registry.jsonl"
check jq -se 'any(.[]; (.markdown_path | endswith("/quoted.md")) and .domain == "null" and .lens == "~" and .title == "null")' "$LOG_BASE/registry.jsonl"
# A hash inside a quoted value or without separating whitespace is literal.
printf -- '---\nseverity: high\ndomain: "null # literal"\nlens: '\''~ # literal'\''\n---\nLiteral metadata.\n' > "$OUTPUT_DIR/quoted.md"
check build_findings_jsonl_from_local "$OUTPUT_DIR" "$LOG_BASE/registry.jsonl"
check jq -se 'any(.[]; (.markdown_path | endswith("/quoted.md")) and .domain == "null # literal" and .lens == "~ # literal")' "$LOG_BASE/registry.jsonl"
printf -- '---\ndomain: null#literal\nlens: ~#literal\n---\n' > "$LOG_BASE/hash.md"
check test "$(_ledger_frontmatter_value "$LOG_BASE/hash.md" domain)" = 'null#literal'
check test "$(_ledger_frontmatter_value "$LOG_BASE/hash.md" lens)" = '~#literal'
printf 'Results: %s failed\n' "$FAIL"
(( FAIL == 0 ))
