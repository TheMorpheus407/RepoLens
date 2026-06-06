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

# Tests for issue #302: polish mode emits one grouped issue per lens.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/core.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/template.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/summary.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/polish.sh"

PASS=0
FAIL=0
TOTAL=0

TMP_PARENT="$SCRIPT_DIR/logs/test-polish-issue-emission"
mkdir -p "$TMP_PARENT"
TMPDIR="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"
unset LOG_BASE RUN_ID OUTPUT_DIR CURRENT_ROUND_OUTPUT_DIR SUMMARY_FILE MAX_ISSUES GLOBAL_ISSUES_CREATED

cleanup() {
  rm -rf "$TMPDIR"
  rmdir "$TMP_PARENT" 2>/dev/null || true
}
trap cleanup EXIT

pass_with() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

fail_with() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
  if [[ -n "${2:-}" ]]; then
    printf '    %s\n' "$2"
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected: $expected | Actual: ${actual:-<empty>}"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected to contain: $needle"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Did not expect to contain: $needle"
  fi
}

assert_jq() {
  local desc="$1" file="$2" filter="$3"
  TOTAL=$((TOTAL + 1))
  if jq -e "$filter" "$file" >/dev/null 2>&1; then
    pass_with "$desc"
  else
    fail_with "$desc" "jq filter failed: $filter"
  fi
}

assert_function_exists() {
  local desc="$1" name="$2"
  TOTAL=$((TOTAL + 1))
  if declare -F "$name" >/dev/null 2>&1; then
    pass_with "$desc"
    return 0
  fi
  fail_with "$desc" "Missing shell function: $name"
  return 1
}

assert_ordered() {
  local desc="$1" haystack="$2"
  shift 2
  local rest="$haystack" needle
  TOTAL=$((TOTAL + 1))
  for needle in "$@"; do
    if [[ "$rest" != *"$needle"* ]]; then
      fail_with "$desc" "Missing or out of order: $needle"
      return
    fi
    rest="${rest#*"$needle"}"
  done
  pass_with "$desc"
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

reset_emission_run() {
  RUN_ID="$1"
  LOG_BASE="$TMPDIR/logs/$RUN_ID"
  SUMMARY_FILE="$LOG_BASE/summary.json"
  FORGE_CALL_LOG="$TMPDIR/$RUN_ID-forge-calls.tsv"
  BODY_CAPTURE_DIR="$TMPDIR/$RUN_ID-bodies"
  FORGE_REPO_SLUG="owner/repo"
  FORGE_PROVIDER="gh"
  LOCAL_MODE=false
  GLOBAL_ISSUES_CREATED=0
  unset MAX_ISSUES REPOLENS_FAKE_FORGE_FAIL
  export RUN_ID LOG_BASE SUMMARY_FILE FORGE_REPO_SLUG FORGE_PROVIDER LOCAL_MODE GLOBAL_ISSUES_CREATED
  export FORGE_CALL_LOG BODY_CAPTURE_DIR

  mkdir -p "$LOG_BASE/polish" "$BODY_CAPTURE_DIR"
  : > "$FORGE_CALL_LOG"
  init_summary "$SUMMARY_FILE" "$RUN_ID" "$SCRIPT_DIR" "polish" "codex" "" "${MAX_ISSUES:-}" "github" "" "" ""
}

write_ranked_fixture() {
  local file="$1"
  cat > "$file" <<'JSON'
[
  {
    "title": "[POLISH] Spacing polish 1",
    "domain": "fluency",
    "lens_id": "spacing-consistency",
    "source_path": "app/ui.css",
    "polish_family": "fluency",
    "voice_fit": "strong",
    "voice_fit_justification": "Matches RepoLens's restrained audit voice.",
    "location_expectedness": "forgotten-corner",
    "polish_rank_x1000": 1500,
    "body": "## Polish Summary\nTune the most visible spacing rhythm."
  },
  {
    "title": "[POLISH] Loading polish 1",
    "domain": "effort-signal",
    "lens_id": "loading-transparency",
    "source_path": "src/loading.ts",
    "polish_family": "effort-signal",
    "voice_fit": "strong",
    "voice_fit_justification": "Keeps the CLI's direct handoff tone intact.",
    "location_expectedness": "no-benchmark",
    "polish_rank_x1000": 1350,
    "body": "## Polish Summary\nClarify the long-running loading handoff."
  },
  {
    "title": "[POLISH] Spacing polish 2",
    "domain": "fluency",
    "lens_id": "spacing-consistency",
    "source_path": "app/ui.css",
    "polish_family": "fluency",
    "voice_fit": "medium",
    "voice_fit_justification": "Supports the existing compact reporting rhythm.",
    "location_expectedness": "expected",
    "polish_rank_x1000": 1000,
    "body": "## Polish Summary\nAlign secondary spacing tokens."
  },
  {
    "title": "[POLISH] Loading polish 2",
    "domain": "effort-signal",
    "lens_id": "loading-transparency",
    "source_path": "src/loading.ts",
    "polish_family": "effort-signal",
    "voice_fit": "medium",
    "voice_fit_justification": "Fits the current concise progress language.",
    "location_expectedness": "expected",
    "polish_rank_x1000": 900,
    "body": "## Polish Summary\nTighten a secondary loading transition."
  },
  {
    "title": "[POLISH] Spacing polish 3",
    "domain": "fluency",
    "lens_id": "spacing-consistency",
    "source_path": "app/panel.css",
    "polish_family": "fluency",
    "voice_fit": "medium",
    "voice_fit_justification": "Uses the same low-noise audit presentation.",
    "location_expectedness": "expected",
    "polish_rank_x1000": 800,
    "body": "## Polish Summary\nNormalize panel spacing."
  },
  {
    "title": "[POLISH] Spacing polish 4",
    "domain": "fluency",
    "lens_id": "spacing-consistency",
    "source_path": "app/rare.css",
    "polish_family": "fluency",
    "voice_fit": "medium",
    "voice_fit_justification": "Still fits, but ranks below stronger spacing polish.",
    "location_expectedness": "expected",
    "polish_rank_x1000": 700,
    "body": "## Polish Summary\nThis fourth item must stay out of the top three."
  }
]
JSON
}

forge_issue_create() {
  local repo="$1" title="$2" body_file="$3"
  shift 3
  local idx capture

  idx="$(wc -l < "$FORGE_CALL_LOG" | tr -d '[:space:]')"
  idx=$((idx + 1))
  capture="$BODY_CAPTURE_DIR/body-$idx.md"
  cp "$body_file" "$capture"
  printf '%s\t%s\t%s\t%s\n' "$repo" "$title" "$capture" "$*" >> "$FORGE_CALL_LOG"

  if [[ "${REPOLENS_FAKE_FORGE_FAIL:-false}" == "true" ]]; then
    return 42
  fi

  printf 'https://github.com/%s/issues/%d\n' "$repo" "$idx"
  return 0
}

find_body_containing() {
  local needle="$1"
  grep -rlF -- "$needle" "$BODY_CAPTURE_DIR" 2>/dev/null | head -n 1
}

echo ""
echo "=== Test Suite: polish issue emission (issue #302) ==="
echo ""

echo "Test 1: polish prompt requires one-line voice-fit justification"
cat > "$TMPDIR/lens.md" <<'EOF'
---
id: emission-test
domain: fluency
name: Emission Test
role: tester
---
## Your Expert Focus
Check polish issue emission.
EOF

base_vars="LENS_NAME=Emission Test|DOMAIN_NAME=Fluency|REPO_OWNER=owner|REPO_NAME=repo|PROJECT_PATH=/tmp/project|LENS_LABEL=polish:fluency/emission-test|DOMAIN_COLOR=14b8a6|DOMAIN=fluency|LENS_ID=emission-test|MODE=polish|RUN_ID=test-run|VOICE_PROFILE=Mock polish voice profile."
rendered_prompt="$(compose_prompt "$SCRIPT_DIR/prompts/_base/polish.md" "$TMPDIR/lens.md" "$base_vars" "" "polish" "" "" "false" "true" "$TMPDIR/local-output")"

assert_contains "polish prompt requires structured voice-fit justification" "voice_fit_justification:" "$rendered_prompt"
assert_contains "polish local JSON schema includes voice-fit justification" '"voice_fit_justification"' "$rendered_prompt"
assert_ordered "repolens emits polish issues after ranking" "$(cat "$SCRIPT_DIR/repolens.sh")" \
  'run_polish_ranking "$RUN_ID"' 'run_polish_issue_emission "$RUN_ID"'

echo ""
echo "Test 2: run_polish_issue_emission groups ranked top-N polish suggestions by lens"
if ! assert_function_exists "run_polish_issue_emission is available" "run_polish_issue_emission"; then
  finish
fi

reset_emission_run "remote-grouping-run"
write_ranked_fixture "$LOG_BASE/polish/ranked-suggestions.json"

emission_rc=0
run_polish_issue_emission "$RUN_ID" 3 >/dev/null 2>&1 || emission_rc=$?
assert_eq "grouped polish emission exits successfully" "0" "$emission_rc"
assert_eq "one forge issue is emitted per lens" "2" "$(wc -l < "$FORGE_CALL_LOG" | tr -d '[:space:]')"

forge_calls="$(cat "$FORGE_CALL_LOG")"
assert_contains "forge calls use the target repository" "owner/repo" "$forge_calls"
assert_contains "spacing lens label is passed to forge" "polish:fluency/spacing-consistency" "$forge_calls"
assert_contains "loading lens label is passed to forge" "polish:effort-signal/loading-transparency" "$forge_calls"
assert_contains "enhancement label is passed to forge" "enhancement" "$forge_calls"
assert_contains "forge issue titles are polish-scoped" "[POLISH]" "$forge_calls"

spacing_body_file="$(find_body_containing "[POLISH] Spacing polish 1")"
loading_body_file="$(find_body_containing "[POLISH] Loading polish 1")"
spacing_body="$([[ -n "$spacing_body_file" ]] && cat "$spacing_body_file" || true)"
loading_body="$([[ -n "$loading_body_file" ]] && cat "$loading_body_file" || true)"

assert_contains "spacing body was captured" "[POLISH] Spacing polish 1" "$spacing_body"
assert_ordered "spacing body keeps ranked top-three order" "$spacing_body" \
  "[POLISH] Spacing polish 1" "[POLISH] Spacing polish 2" "[POLISH] Spacing polish 3"
assert_not_contains "spacing body omits the fourth ranked item" "[POLISH] Spacing polish 4" "$spacing_body"
assert_eq "spacing body has one voice-fit justification per listed item" \
  "3" "$(grep -c 'Voice-fit justification:' <<< "$spacing_body" || true)"
assert_contains "loading body includes its voice-fit justification" \
  "Voice-fit justification: Keeps the CLI's direct handoff tone intact." "$loading_body"
assert_jq "summary counts grouped polish issues" "$SUMMARY_FILE" '.totals.issues_created == 2'

emission_rc=0
run_polish_issue_emission "$RUN_ID" 3 >/dev/null 2>&1 || emission_rc=$?
assert_eq "same-run polish emission reuses filed sentinels successfully" "0" "$emission_rc"
assert_eq "same-run polish emission does not duplicate forge issues" "2" "$(wc -l < "$FORGE_CALL_LOG" | tr -d '[:space:]')"
assert_jq "same-run polish emission does not double-count summary issues" "$SUMMARY_FILE" '.totals.issues_created == 2'

echo ""
echo "Test 3: local polish emission writes grouped markdown drafts without forge calls"
reset_emission_run "local-draft-run"
LOCAL_MODE=true
export LOCAL_MODE
write_ranked_fixture "$LOG_BASE/polish/ranked-suggestions.json"

emission_rc=0
run_polish_issue_emission "$RUN_ID" 3 >/dev/null 2>&1 || emission_rc=$?
assert_eq "local polish emission exits successfully" "0" "$emission_rc"
assert_eq "local polish emission does not call forge" "0" "$(wc -l < "$FORGE_CALL_LOG" | tr -d '[:space:]')"

local_spacing_body_file="$LOG_BASE/polish/filed/fluency-spacing-consistency.md"
local_spacing_body="$(cat "$local_spacing_body_file" 2>/dev/null || true)"
local_spacing_sentinel="$(cat "$LOG_BASE/polish/filed/fluency-spacing-consistency.url" 2>/dev/null || true)"
assert_contains "local polish draft is written for the spacing lens" "[POLISH] Spacing polish 1" "$local_spacing_body"
assert_contains "local polish draft sentinel points at the markdown draft" "local:$local_spacing_body_file" "$local_spacing_sentinel"
assert_jq "local polish emission still updates summary counts" "$SUMMARY_FILE" '.totals.issues_created == 2'

echo ""
echo "Test 4: polish emission filters unusable suggestions and falls back to body voice fit"
reset_emission_run "filter-fallback-run"
cat > "$LOG_BASE/polish/ranked-suggestions.json" <<'JSON'
[
  {
    "title": "[POLISH] Body fallback polish",
    "domain": "fluency",
    "lens_id": "alignment-symmetry",
    "source_path": "ui/card.css",
    "polish_family": "fluency",
    "voice_fit": "medium",
    "location_expectedness": "expected",
    "polish_rank_x1000": 650,
    "body": "## Polish Summary\nAlign the card rhythm.\n\n## Voice Profile Fit\nMatches the existing concise reviewer tone.\n"
  },
  {
    "title": "[POLISH] Off-brand polish",
    "domain": "fluency",
    "lens_id": "alignment-symmetry",
    "source_path": "ui/card.css",
    "polish_family": "fluency",
    "voice_fit": "off-brand",
    "voice_fit_justification": "This should never be filed.",
    "location_expectedness": "forgotten-corner",
    "polish_rank_x1000": 1500,
    "body": "## Polish Summary\nThis off-brand item should be filtered."
  },
  {
    "title": "[POLISH] Zero-rank polish",
    "domain": "fluency",
    "lens_id": "alignment-symmetry",
    "source_path": "ui/card.css",
    "polish_family": "fluency",
    "voice_fit": "weak",
    "voice_fit_justification": "This zero-rank item should never be filed.",
    "location_expectedness": "expected",
    "polish_rank_x1000": 0,
    "body": "## Polish Summary\nThis zero-rank item should be filtered."
  },
  {
    "title": "[POLISH] Missing body polish",
    "domain": "fluency",
    "lens_id": "alignment-symmetry",
    "source_path": "ui/card.css",
    "polish_family": "fluency",
    "voice_fit": "strong",
    "voice_fit_justification": "This missing-body item should never be filed.",
    "location_expectedness": "expected",
    "polish_rank_x1000": 1000
  }
]
JSON

emission_rc=0
run_polish_issue_emission "$RUN_ID" 3 >/dev/null 2>&1 || emission_rc=$?
assert_eq "filtered polish emission exits successfully" "0" "$emission_rc"
assert_eq "only the usable polish suggestion is emitted" "1" "$(wc -l < "$FORGE_CALL_LOG" | tr -d '[:space:]')"
fallback_body="$(cat "$BODY_CAPTURE_DIR"/body-1.md 2>/dev/null || true)"
assert_contains "body voice-fit fallback becomes the issue justification" \
  "Voice-fit justification: Matches the existing concise reviewer tone." "$fallback_body"
assert_not_contains "off-brand polish suggestion is filtered" "[POLISH] Off-brand polish" "$fallback_body"
assert_not_contains "zero-rank polish suggestion is filtered" "[POLISH] Zero-rank polish" "$fallback_body"
assert_not_contains "missing-body polish suggestion is filtered" "[POLISH] Missing body polish" "$fallback_body"
assert_jq "filtered polish emission counts only the filed issue" "$SUMMARY_FILE" '.totals.issues_created == 1'

echo ""
echo "Test 5: polish emission respects the remaining --max-issues budget"
reset_emission_run "max-issues-run"
write_ranked_fixture "$LOG_BASE/polish/ranked-suggestions.json"
MAX_ISSUES=1
GLOBAL_ISSUES_CREATED=0
export MAX_ISSUES GLOBAL_ISSUES_CREATED

emission_rc=0
run_polish_issue_emission "$RUN_ID" 3 >/dev/null 2>&1 || emission_rc=$?
assert_eq "max-issues polish emission exits successfully" "0" "$emission_rc"
assert_eq "max-issues allows only one lens issue" "1" "$(wc -l < "$FORGE_CALL_LOG" | tr -d '[:space:]')"
only_body="$(cat "$BODY_CAPTURE_DIR"/body-1.md 2>/dev/null || true)"
assert_contains "max-issues keeps the highest-ranked lens issue" "[POLISH] Spacing polish 1" "$only_body"
assert_not_contains "max-issues does not emit the lower-ranked lens issue" "[POLISH] Loading polish 1" "$only_body"
assert_eq "global issue counter tracks emitted polish issues" "1" "${GLOBAL_ISSUES_CREATED:-0}"
assert_jq "summary counts only the emitted budgeted polish issue" "$SUMMARY_FILE" '.totals.issues_created == 1'

echo ""
echo "Test 6: forge failure propagates without recording a created polish issue"
reset_emission_run "forge-failure-run"
cat > "$LOG_BASE/polish/ranked-suggestions.json" <<'JSON'
[
  {
    "title": "[POLISH] Failure path polish",
    "domain": "fluency",
    "lens_id": "spacing-consistency",
    "source_path": "app/ui.css",
    "polish_family": "fluency",
    "voice_fit": "strong",
    "voice_fit_justification": "Keeps the polish issue grounded in the repo voice.",
    "location_expectedness": "expected",
    "polish_rank_x1000": 1000,
    "body": "## Polish Summary\nThis item exercises forge failure propagation."
  }
]
JSON
REPOLENS_FAKE_FORGE_FAIL=true
export REPOLENS_FAKE_FORGE_FAIL

emission_rc=0
run_polish_issue_emission "$RUN_ID" 3 >/dev/null 2>&1 || emission_rc=$?
assert_eq "forge failure returns the real non-zero status" "42" "$emission_rc"
assert_eq "failed forge call is attempted once" "1" "$(wc -l < "$FORGE_CALL_LOG" | tr -d '[:space:]')"
assert_jq "failed forge emission does not increment summary issues" "$SUMMARY_FILE" '.totals.issues_created == 0'
assert_eq "failed forge emission does not increment global issue counter" "0" "${GLOBAL_ISSUES_CREATED:-0}"

echo ""
echo "Test 7: empty, missing, and malformed ranked artifacts are handled without forge side effects"
reset_emission_run "empty-ranked-run"
printf '[]\n' > "$LOG_BASE/polish/ranked-suggestions.json"

emission_rc=0
run_polish_issue_emission "$RUN_ID" 3 >/dev/null 2>&1 || emission_rc=$?
assert_eq "empty ranked polish artifact exits successfully" "0" "$emission_rc"
assert_eq "empty ranked polish artifact emits no forge issues" "0" "$(wc -l < "$FORGE_CALL_LOG" | tr -d '[:space:]')"
assert_jq "empty ranked polish artifact leaves summary issue count unchanged" "$SUMMARY_FILE" '.totals.issues_created == 0'

reset_emission_run "missing-ranked-run"
emission_rc=0
run_polish_issue_emission "$RUN_ID" 3 >/dev/null 2>&1 || emission_rc=$?
assert_eq "missing ranked polish artifact fails clearly" "1" "$emission_rc"
assert_eq "missing ranked polish artifact emits no forge issues" "0" "$(wc -l < "$FORGE_CALL_LOG" | tr -d '[:space:]')"
assert_jq "missing ranked polish artifact leaves summary issue count unchanged" "$SUMMARY_FILE" '.totals.issues_created == 0'

reset_emission_run "malformed-ranked-run"
printf '{not valid json\n' > "$LOG_BASE/polish/ranked-suggestions.json"

emission_rc=0
run_polish_issue_emission "$RUN_ID" 3 >/dev/null 2>&1 || emission_rc=$?
assert_eq "malformed ranked polish artifact fails clearly" "1" "$emission_rc"
assert_eq "malformed ranked polish artifact emits no forge issues" "0" "$(wc -l < "$FORGE_CALL_LOG" | tr -d '[:space:]')"
assert_jq "malformed ranked polish artifact leaves summary issue count unchanged" "$SUMMARY_FILE" '.totals.issues_created == 0'

finish
