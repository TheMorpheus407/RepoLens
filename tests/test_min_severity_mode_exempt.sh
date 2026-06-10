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

# Issue #268: --min-severity is accepted in discover mode, but discover
# findings are effort-sized ideas rather than severity-ranked findings.
# Issue #269: feature mode follows the same no-effect contract.
# Issue #270: custom mode follows the same no-effect contract.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
TOTAL=0

pass_with() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

fail_with() {
  local desc="$1" detail="${2:-}"
  FAIL=$((FAIL + 1))
  echo "  FAIL: $desc"
  if [[ -n "$detail" ]]; then
    printf '    %s\n' "$detail"
  fi
}

assert_success() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -eq 0 ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected exit 0, got $actual"
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected '$expected', got '$actual'"
  fi
}

assert_file_exists() {
  local desc="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$path" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected file $path"
  fi
}

assert_dir_exists() {
  local desc="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -d "$path" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected directory $path"
  fi
}

assert_file_contains() {
  local desc="$1" path="$2" needle="$3"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$path" ]] && grep -Fq -- "$needle" "$path"; then
    pass_with "$desc"
  else
    local detail="Missing: $needle"
    [[ -f "$path" ]] || detail="Expected file $path"
    fail_with "$desc" "$detail"
  fi
}

assert_file_not_contains() {
  local desc="$1" path="$2" needle="$3"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$path" ]] && ! grep -Fq -- "$needle" "$path"; then
    pass_with "$desc"
  else
    local detail="Unexpected content: $needle"
    [[ -f "$path" ]] || detail="Expected file $path"
    fail_with "$desc" "$detail"
  fi
}

line_count_contains() {
  local path="$1" needle="$2"
  awk -v needle="$needle" 'index($0, needle) { count++ } END { print count + 0 }' "$path"
}

line_number_for() {
  local path="$1" needle="$2"
  awk -v needle="$needle" 'index($0, needle) { print NR; exit }' "$path"
}

assert_line_order() {
  local desc="$1" earlier="$2" later="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$earlier" =~ ^[0-9]+$ && "$later" =~ ^[0-9]+$ && "$earlier" -lt "$later" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected line $earlier before line $later"
  fi
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

echo "=== min-severity mode exemptions ==="

mkdir -p "$SCRIPT_DIR/logs"
TMPDIR="$(mktemp -d "$SCRIPT_DIR/logs/test-min-severity-mode-exempt.XXXXXX")"
RUN_LOG_DIR=""
ENV_RUN_LOG_DIR=""
FEATURE_RUN_LOG_DIR=""
FEATURE_ENV_RUN_LOG_DIR=""
CUSTOM_RUN_LOG_DIR=""
CUSTOM_ENV_RUN_LOG_DIR=""

cleanup() {
  if [[ -n "$RUN_LOG_DIR" ]]; then
    rm -rf "$RUN_LOG_DIR"
  fi
  if [[ -n "$ENV_RUN_LOG_DIR" ]]; then
    rm -rf "$ENV_RUN_LOG_DIR"
  fi
  if [[ -n "$FEATURE_RUN_LOG_DIR" ]]; then
    rm -rf "$FEATURE_RUN_LOG_DIR"
  fi
  if [[ -n "$FEATURE_ENV_RUN_LOG_DIR" ]]; then
    rm -rf "$FEATURE_ENV_RUN_LOG_DIR"
  fi
  if [[ -n "$CUSTOM_RUN_LOG_DIR" ]]; then
    rm -rf "$CUSTOM_RUN_LOG_DIR"
  fi
  if [[ -n "$CUSTOM_ENV_RUN_LOG_DIR" ]]; then
    rm -rf "$CUSTOM_ENV_RUN_LOG_DIR"
  fi
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

PROJECT_DIR="$TMPDIR/project"
FAKE_BIN="$TMPDIR/bin"
AGENT_LOG="$TMPDIR/agent.log"
FEATURE_AGENT_LOG="$TMPDIR/feature-agent.log"
CUSTOM_AGENT_LOG="$TMPDIR/custom-agent.log"
RUN_OUTPUT="$TMPDIR/repolens-output.txt"
ENV_RUN_OUTPUT="$TMPDIR/repolens-env-output.txt"
FEATURE_RUN_OUTPUT="$TMPDIR/repolens-feature-output.txt"
FEATURE_ENV_RUN_OUTPUT="$TMPDIR/repolens-feature-env-output.txt"
CUSTOM_RUN_OUTPUT="$TMPDIR/repolens-custom-output.txt"
CUSTOM_ENV_RUN_OUTPUT="$TMPDIR/repolens-custom-env-output.txt"
mkdir -p "$PROJECT_DIR" "$FAKE_BIN"

git -C "$PROJECT_DIR" init -q
printf '# RepoLens discover mode exemption fixture\n' > "$PROJECT_DIR/README.md"
git -C "$PROJECT_DIR" add README.md
git -C "$PROJECT_DIR" -c user.name='RepoLens Test' -c user.email='repolens@example.invalid' commit -q -m 'fixture'

ln -s "$SCRIPT_DIR/tests/mock-agent.sh" "$FAKE_BIN/codex"
: > "$AGENT_LOG"
: > "$FEATURE_AGENT_LOG"
: > "$CUSTOM_AGENT_LOG"

PATH="$FAKE_BIN:$PATH" \
  REPOLENS_AGENT_TIMEOUT=10 \
  REPOLENS_AGENT_KILL_GRACE=1 \
  REPOLENS_MOCK_AGENT_LOG="$AGENT_LOG" \
  REPOLENS_MOCK_AGENT_FINDINGS=2 \
  bash "$SCRIPT_DIR/repolens.sh" \
    --project "$PROJECT_DIR" \
    --agent codex \
    --local \
    --mode discover \
    --focus product-gaps \
    --depth 1 \
    --yes \
    --min-severity high \
    >"$RUN_OUTPUT" 2>&1
run_status=$?

run_id="$(sed -n 's/.*RepoLens run \([^ ]*\) complete.*/\1/p' "$RUN_OUTPUT" | tail -1)"
if [[ -n "$run_id" ]]; then
  RUN_LOG_DIR="$SCRIPT_DIR/logs/$run_id"
fi

PATH="$FAKE_BIN:$PATH" \
  REPOLENS_AGENT_TIMEOUT=10 \
  REPOLENS_AGENT_KILL_GRACE=1 \
  REPOLENS_MIN_SEVERITY=HIGH \
  bash "$SCRIPT_DIR/repolens.sh" \
    --project "$PROJECT_DIR" \
    --agent codex \
    --local \
    --dry-run \
    --mode discover \
    --focus product-gaps \
    --depth 1 \
    --yes \
    >"$ENV_RUN_OUTPUT" 2>&1
env_run_status=$?

env_run_id="$(sed -n 's/.*RepoLens run \([^ ]*\) starting.*/\1/p' "$ENV_RUN_OUTPUT" | tail -1)"
if [[ -n "$env_run_id" ]]; then
  ENV_RUN_LOG_DIR="$SCRIPT_DIR/logs/$env_run_id"
fi

PATH="$FAKE_BIN:$PATH" \
  REPOLENS_AGENT_TIMEOUT=10 \
  REPOLENS_AGENT_KILL_GRACE=1 \
  REPOLENS_MOCK_AGENT_LOG="$FEATURE_AGENT_LOG" \
  REPOLENS_MOCK_AGENT_FINDINGS=2 \
  bash "$SCRIPT_DIR/repolens.sh" \
    --project "$PROJECT_DIR" \
    --agent codex \
    --local \
    --mode feature \
    --focus injection \
    --depth 1 \
    --yes \
    --min-severity high \
    >"$FEATURE_RUN_OUTPUT" 2>&1
feature_run_status=$?

feature_run_id="$(sed -n 's/.*RepoLens run \([^ ]*\) complete.*/\1/p' "$FEATURE_RUN_OUTPUT" | tail -1)"
if [[ -n "$feature_run_id" ]]; then
  FEATURE_RUN_LOG_DIR="$SCRIPT_DIR/logs/$feature_run_id"
fi

PATH="$FAKE_BIN:$PATH" \
  REPOLENS_AGENT_TIMEOUT=10 \
  REPOLENS_AGENT_KILL_GRACE=1 \
  REPOLENS_MIN_SEVERITY=HIGH \
  bash "$SCRIPT_DIR/repolens.sh" \
    --project "$PROJECT_DIR" \
    --agent codex \
    --local \
    --dry-run \
    --mode feature \
    --focus injection \
    --depth 1 \
    --yes \
    >"$FEATURE_ENV_RUN_OUTPUT" 2>&1
feature_env_run_status=$?

feature_env_run_id="$(sed -n 's/.*RepoLens run \([^ ]*\) starting.*/\1/p' "$FEATURE_ENV_RUN_OUTPUT" | tail -1)"
if [[ -n "$feature_env_run_id" ]]; then
  FEATURE_ENV_RUN_LOG_DIR="$SCRIPT_DIR/logs/$feature_env_run_id"
fi

PATH="$FAKE_BIN:$PATH" \
  REPOLENS_AGENT_TIMEOUT=10 \
  REPOLENS_AGENT_KILL_GRACE=1 \
  REPOLENS_MOCK_AGENT_LOG="$CUSTOM_AGENT_LOG" \
  REPOLENS_MOCK_AGENT_FINDINGS=2 \
  bash "$SCRIPT_DIR/repolens.sh" \
    --project "$PROJECT_DIR" \
    --agent codex \
    --local \
    --mode custom \
    --change "custom min-severity exemption fixture" \
    --focus injection \
    --depth 1 \
    --yes \
    --min-severity high \
    >"$CUSTOM_RUN_OUTPUT" 2>&1
custom_run_status=$?

custom_run_id="$(sed -n 's/.*RepoLens run \([^ ]*\) complete.*/\1/p' "$CUSTOM_RUN_OUTPUT" | tail -1)"
if [[ -n "$custom_run_id" ]]; then
  CUSTOM_RUN_LOG_DIR="$SCRIPT_DIR/logs/$custom_run_id"
fi

PATH="$FAKE_BIN:$PATH" \
  REPOLENS_AGENT_TIMEOUT=10 \
  REPOLENS_AGENT_KILL_GRACE=1 \
  REPOLENS_MIN_SEVERITY=HIGH \
  bash "$SCRIPT_DIR/repolens.sh" \
    --project "$PROJECT_DIR" \
    --agent codex \
    --local \
    --dry-run \
    --mode custom \
    --change "custom min-severity exemption fixture" \
    --focus injection \
    --depth 1 \
    --yes \
    >"$CUSTOM_ENV_RUN_OUTPUT" 2>&1
custom_env_run_status=$?

custom_env_run_id="$(sed -n 's/.*RepoLens run \([^ ]*\) starting.*/\1/p' "$CUSTOM_ENV_RUN_OUTPUT" | tail -1)"
if [[ -n "$custom_env_run_id" ]]; then
  CUSTOM_ENV_RUN_LOG_DIR="$SCRIPT_DIR/logs/$custom_env_run_id"
fi

summary_file="$TMPDIR/missing-summary.json"
if [[ -n "$RUN_LOG_DIR" ]]; then
  summary_file="$RUN_LOG_DIR/summary.json"
fi

local_output_dir=""
if [[ -f "$summary_file" ]]; then
  local_output_dir="$(jq -r '.output_dir // empty' "$summary_file" 2>/dev/null || true)"
fi
[[ -n "$local_output_dir" ]] || local_output_dir="$TMPDIR/missing-output"

warning_text="--min-severity has no effect in discover mode (this mode does not use severity)"
warning_count="$(line_count_contains "$RUN_OUTPUT" "$warning_text")"
env_warning_count="$(line_count_contains "$ENV_RUN_OUTPUT" "$warning_text")"
warning_line="$(line_number_for "$RUN_OUTPUT" "$warning_text")"
lens_start_line="$(line_number_for "$RUN_OUTPUT" "[discovery/product-gaps] Starting lens")"
agent_calls="$(wc -l < "$AGENT_LOG" | tr -d ' ')"
findings_filtered="$(jq -r '.totals.findings_filtered // "missing"' "$summary_file" 2>/dev/null || true)"
issues_created="$(jq -r '.totals.issues_created // "missing"' "$summary_file" 2>/dev/null || true)"

first_finding="$local_output_dir/discovery/product-gaps/001-mock-finding-product-gaps-r1-1.md"
second_finding="$local_output_dir/discovery/product-gaps/002-mock-finding-product-gaps-r1-2.md"

feature_summary_file="$TMPDIR/missing-feature-summary.json"
if [[ -n "$FEATURE_RUN_LOG_DIR" ]]; then
  feature_summary_file="$FEATURE_RUN_LOG_DIR/summary.json"
fi

feature_local_output_dir=""
if [[ -f "$feature_summary_file" ]]; then
  feature_local_output_dir="$(jq -r '.output_dir // empty' "$feature_summary_file" 2>/dev/null || true)"
fi
[[ -n "$feature_local_output_dir" ]] || feature_local_output_dir="$TMPDIR/missing-feature-output"

feature_warning_text="--min-severity has no effect in feature mode (this mode does not use severity)"
feature_warning_count="$(line_count_contains "$FEATURE_RUN_OUTPUT" "$feature_warning_text")"
feature_env_warning_count="$(line_count_contains "$FEATURE_ENV_RUN_OUTPUT" "$feature_warning_text")"
feature_warning_line="$(line_number_for "$FEATURE_RUN_OUTPUT" "$feature_warning_text")"
feature_lens_start_line="$(line_number_for "$FEATURE_RUN_OUTPUT" "[security/injection] Starting lens")"
feature_agent_calls="$(wc -l < "$FEATURE_AGENT_LOG" | tr -d ' ')"
feature_findings_filtered="$(jq -r '.totals.findings_filtered // "missing"' "$feature_summary_file" 2>/dev/null || true)"
feature_issues_created="$(jq -r '.totals.issues_created // "missing"' "$feature_summary_file" 2>/dev/null || true)"

feature_first_finding="$feature_local_output_dir/security/injection/001-mock-finding-injection-r1-1.md"
feature_second_finding="$feature_local_output_dir/security/injection/002-mock-finding-injection-r1-2.md"
feature_prompt_file="$(dirname "$feature_local_output_dir")/captured-prompts/security__injection.prompt.md"

custom_summary_file="$TMPDIR/missing-custom-summary.json"
if [[ -n "$CUSTOM_RUN_LOG_DIR" ]]; then
  custom_summary_file="$CUSTOM_RUN_LOG_DIR/summary.json"
fi

custom_local_output_dir=""
if [[ -f "$custom_summary_file" ]]; then
  custom_local_output_dir="$(jq -r '.output_dir // empty' "$custom_summary_file" 2>/dev/null || true)"
fi
[[ -n "$custom_local_output_dir" ]] || custom_local_output_dir="$TMPDIR/missing-custom-output"

custom_warning_text="--min-severity has no effect in custom mode (this mode does not use severity)"
custom_warning_count="$(line_count_contains "$CUSTOM_RUN_OUTPUT" "$custom_warning_text")"
custom_env_warning_count="$(line_count_contains "$CUSTOM_ENV_RUN_OUTPUT" "$custom_warning_text")"
custom_warning_line="$(line_number_for "$CUSTOM_RUN_OUTPUT" "$custom_warning_text")"
custom_lens_start_line="$(line_number_for "$CUSTOM_RUN_OUTPUT" "[security/injection] Starting lens")"
custom_agent_calls="$(wc -l < "$CUSTOM_AGENT_LOG" | tr -d ' ')"
custom_findings_filtered="$(jq -r '.totals.findings_filtered // "missing"' "$custom_summary_file" 2>/dev/null || true)"
custom_issues_created="$(jq -r '.totals.issues_created // "missing"' "$custom_summary_file" 2>/dev/null || true)"

custom_first_finding="$custom_local_output_dir/security/injection/001-mock-finding-injection-r1-1.md"
custom_second_finding="$custom_local_output_dir/security/injection/002-mock-finding-injection-r1-2.md"

assert_success "fake-agent discover run succeeds with min severity high" "$run_status"
assert_eq "discover run id is discoverable" "set" "$([[ -n "$run_id" ]] && printf 'set' || printf 'missing')"
assert_eq "fake discover agent is invoked exactly once" "1" "$agent_calls"
assert_eq "discover mode logs the min-severity no-effect warning exactly once" "1" "$warning_count"
assert_line_order "min-severity warning is emitted before lens execution" "$warning_line" "$lens_start_line"
assert_file_not_contains "discover startup does not advertise an active min-severity filter" "$RUN_OUTPUT" "Min severity: high"
assert_file_not_contains "discover output does not log dropped findings" "$RUN_OUTPUT" "Dropped finding"
assert_file_not_contains "discover output does not report filtered stdout" "$RUN_OUTPUT" "Findings filtered by --min-severity:"
assert_file_exists "summary.json is written" "$summary_file"
assert_dir_exists "local output directory is recorded in summary" "$local_output_dir"
assert_file_exists "first low-severity discover fixture finding is preserved" "$first_finding"
assert_file_exists "second low-severity discover fixture finding is preserved" "$second_finding"
assert_file_contains "fixture finding is below the high threshold" "$first_finding" "severity: low"
assert_eq "summary preserves both emitted discover findings" "2" "$issues_created"
assert_eq "summary records zero min-severity filtered discover findings" "0" "$findings_filtered"
assert_success "env fallback discover dry-run succeeds" "$env_run_status"
assert_eq "env fallback discover logs the no-effect warning exactly once" "1" "$env_warning_count"
assert_file_not_contains "env fallback discover does not advertise an active min-severity filter" "$ENV_RUN_OUTPUT" "Min severity: high"

assert_success "fake-agent feature run succeeds with min severity high" "$feature_run_status"
assert_eq "feature run id is discoverable" "set" "$([[ -n "$feature_run_id" ]] && printf 'set' || printf 'missing')"
assert_eq "fake feature agent is invoked exactly once" "1" "$feature_agent_calls"
assert_eq "feature mode logs the min-severity no-effect warning exactly once" "1" "$feature_warning_count"
assert_line_order "feature min-severity warning is emitted before lens execution" "$feature_warning_line" "$feature_lens_start_line"
assert_file_not_contains "feature startup does not advertise an active min-severity filter" "$FEATURE_RUN_OUTPUT" "Min severity: high"
assert_file_not_contains "feature output does not log dropped findings" "$FEATURE_RUN_OUTPUT" "Dropped finding"
assert_file_not_contains "feature output does not report filtered stdout" "$FEATURE_RUN_OUTPUT" "Findings filtered by --min-severity:"
assert_file_exists "feature summary.json is written" "$feature_summary_file"
assert_dir_exists "feature local output directory is recorded in summary" "$feature_local_output_dir"
assert_file_exists "first low-severity feature fixture finding is preserved" "$feature_first_finding"
assert_file_exists "second low-severity feature fixture finding is preserved" "$feature_second_finding"
assert_file_contains "feature fixture finding is below the high threshold" "$feature_first_finding" "severity: low"
assert_file_exists "feature rendered prompt is captured" "$feature_prompt_file"
assert_file_not_contains "feature rendered prompt omits min-severity instructions" "$feature_prompt_file" "## Minimum Severity"
assert_eq "summary preserves both emitted feature findings" "2" "$feature_issues_created"
assert_eq "summary records zero min-severity filtered feature findings" "0" "$feature_findings_filtered"
assert_success "env fallback feature dry-run succeeds" "$feature_env_run_status"
assert_eq "env fallback feature logs the no-effect warning exactly once" "1" "$feature_env_warning_count"
assert_file_not_contains "env fallback feature does not advertise an active min-severity filter" "$FEATURE_ENV_RUN_OUTPUT" "Min severity: high"

assert_success "fake-agent custom run succeeds with min severity high" "$custom_run_status"
assert_eq "custom run id is discoverable" "set" "$([[ -n "$custom_run_id" ]] && printf 'set' || printf 'missing')"
assert_eq "fake custom agent is invoked exactly once" "1" "$custom_agent_calls"
assert_eq "custom mode logs the min-severity no-effect warning exactly once" "1" "$custom_warning_count"
assert_line_order "custom min-severity warning is emitted before lens execution" "$custom_warning_line" "$custom_lens_start_line"
assert_file_not_contains "custom startup does not advertise an active min-severity filter" "$CUSTOM_RUN_OUTPUT" "Min severity: high"
assert_file_not_contains "custom output does not log dropped findings" "$CUSTOM_RUN_OUTPUT" "Dropped finding"
assert_file_not_contains "custom output does not report filtered stdout" "$CUSTOM_RUN_OUTPUT" "Findings filtered by --min-severity:"
assert_file_exists "custom summary.json is written" "$custom_summary_file"
assert_dir_exists "custom local output directory is recorded in summary" "$custom_local_output_dir"
assert_file_exists "first low-severity custom fixture finding is preserved" "$custom_first_finding"
assert_file_exists "second low-severity custom fixture finding is preserved" "$custom_second_finding"
assert_file_contains "custom fixture finding is below the high threshold" "$custom_first_finding" "severity: low"
assert_eq "summary preserves both emitted custom findings" "2" "$custom_issues_created"
assert_eq "summary records zero min-severity filtered custom findings" "0" "$custom_findings_filtered"
assert_success "env fallback custom dry-run succeeds" "$custom_env_run_status"
assert_eq "env fallback custom logs the no-effect warning exactly once" "1" "$custom_env_warning_count"
assert_file_not_contains "env fallback custom does not advertise an active min-severity filter" "$CUSTOM_ENV_RUN_OUTPUT" "Min severity: high"

finish
