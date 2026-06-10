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

# Regression tests for issue #220: a run with zero findings and a degenerate
# max-iterations distribution must be observable as broken, not as a clean run.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
TOTAL=0
TMPDIR="$(mktemp -d)"
CREATED_RUNS=()
trap 'rm -rf "$TMPDIR"; for run_id in "${CREATED_RUNS[@]:-}"; do rm -rf "$SCRIPT_DIR/logs/$run_id"; done' EXIT

pass_with() {
  local desc="$1"
  PASS=$((PASS + 1))
  echo "  PASS: $desc"
}

fail_with() {
  local desc="$1" detail="${2:-}"
  FAIL=$((FAIL + 1))
  echo "  FAIL: $desc"
  if [[ -n "$detail" ]]; then
    printf '    %s\n' "$detail"
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
  local desc="$1" needle="$2" file="$3"
  TOTAL=$((TOTAL + 1))
  if grep -qF "$needle" "$file" 2>/dev/null; then
    pass_with "$desc"
  else
    fail_with "$desc" "Missing: $needle"
  fi
}

assert_file_exists() {
  local desc="$1" file="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$file" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Missing file: $file"
  fi
}

assert_jq() {
  local desc="$1" file="$2" filter="$3"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$file" ]] && jq -e "$filter" "$file" >/dev/null 2>&1; then
    pass_with "$desc"
  else
    fail_with "$desc" "file=$file filter=$filter"
  fi
}

require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "  SKIP: jq not available"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
    exit 0
  fi
}

create_project() {
  local project="$1"
  mkdir -p "$project"
  (
    cd "$project" || exit 1
    git init -q 2>/dev/null
    git config user.email test@example.com
    git config user.name Test
    printf '# fixture\n' > README.md
    git add README.md
    git commit -q -m init 2>/dev/null
  ) || true
}

install_health_gate_codex() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/codex" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
mode="${HEALTH_AGENT_MODE:-clean}"
state_dir="${HEALTH_AGENT_STATE_DIR:?state dir required}"
mkdir -p "$state_dir"
count_file="$state_dir/calls"
count=0
[[ -f "$count_file" ]] && count="$(cat "$count_file")"
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"

case "$mode" in
  max)
    printf 'Iteration %s produced meaningful investigation notes without a terminal marker. ' "$count"
    printf 'This output is intentionally substantial and unique so the no-progress circuit breaker does not fire. %.0s' {1..12}
    printf '\n'
    ;;
  clean)
    printf 'Analysis complete. No findings.\n'
    printf 'DONE\n'
    ;;
  *)
    printf 'unknown HEALTH_AGENT_MODE=%s\n' "$mode" >&2
    exit 2
    ;;
esac
exit 0
SH
  chmod +x "$bin_dir/codex"
}

extract_run_id() {
  local output_file="$1"
  grep -oE 'RepoLens run [^ ]+ starting' "$output_file" | head -1 | awk '{print $3}'
}

write_summary_fixture() {
  local file="$1" issues="$2" max_iterations="$3" completed="$4" skipped="${5:-0}"
  jq -n \
    --argjson issues "$issues" \
    --argjson max_iterations "$max_iterations" \
    --argjson completed "$completed" \
    --argjson skipped "$skipped" \
    '
      def lens($status; $i):
        {domain: "test", lens: ("lens-" + ($i | tostring)), iterations: 1, status: $status, issues_created: 0, rate_limit_sleep_seconds: 0};
      {
        run_id: "fixture",
        started_at: "2026-05-14T00:00:00Z",
        completed_at: null,
        stopped_reason: null,
        totals: {lenses_run: ($max_iterations + $completed), iterations_total: ($max_iterations + $completed), issues_created: $issues},
        lenses:
          ([range(0; $max_iterations) | lens("max-iterations"; .)]
           + [range(0; $completed) | lens("completed"; .)]
           + [range(0; $skipped) | lens("skipped"; .)])
      }
    ' > "$file"
}

classify_fixture() {
  local file="$1" threshold="${2:-90}"
  (
    cd "$SCRIPT_DIR" || exit 1
    source ./lib/summary.sh
    classify_summary_health "$file" "$threshold"
  )
}

persist_health_fixture() {
  local file="$1" threshold="${2:-90}"
  (
    cd "$SCRIPT_DIR" || exit 1
    source ./lib/summary.sh
    set_summary_health "$file" "$threshold"
  )
}

run_repolens_case() {
  local case_name="$1" agent_mode="$2" allow_degenerate="${3:-false}"
  local case_dir="$TMPDIR/$case_name"
  local project="$case_dir/project"
  local bin_dir="$case_dir/bin"
  local out_file="$case_dir/run.log"
  mkdir -p "$case_dir"
  create_project "$project"
  install_health_gate_codex "$bin_dir"

  set +e
  env \
    PATH="$bin_dir:$PATH" \
    HEALTH_AGENT_MODE="$agent_mode" \
    HEALTH_AGENT_STATE_DIR="$case_dir/state" \
    REPOLENS_ALLOW_DEGENERATE="$allow_degenerate" \
    REPOLENS_NO_PROGRESS_MIN_BYTES=0 \
    REPOLENS_STATUS_INTERVAL=1 \
    REPOLENS_AGENT_TIMEOUT=15 \
    bash "$SCRIPT_DIR/repolens.sh" \
      --project "$project" \
      --agent codex \
      --focus i18n-strings \
      --change "health gate regression" \
      --local \
      --yes \
      >"$out_file" 2>&1
  local rc=$?
  set -e

  local run_id
  run_id="$(extract_run_id "$out_file")"
  if [[ -n "$run_id" ]]; then
    CREATED_RUNS+=("$run_id")
  fi
  printf '%s|%s|%s\n' "$rc" "$run_id" "$out_file"
}

echo "=== Health gate for degenerate max-iterations runs (issue #220) ==="
require_jq

echo "Test 1: summary classifier identifies the reported 485/494 regression"
fixture_485="$TMPDIR/summary-485.json"
write_summary_fixture "$fixture_485" 0 485 9 0
health_485="$(classify_fixture "$fixture_485" 90 2>/dev/null || printf 'missing')"
assert_eq "485/494 max-iterations with zero findings is broken" "broken" "$health_485"

echo "Test 2: skipped lenses do not dilute the max-iterations denominator"
fixture_skipped="$TMPDIR/summary-skipped.json"
write_summary_fixture "$fixture_skipped" 0 9 1 90
health_skipped="$(classify_fixture "$fixture_skipped" 90 2>/dev/null || printf 'missing')"
assert_eq "9/10 run lenses at max-iterations remains broken despite skipped records" "broken" "$health_skipped"

echo "Test 3: mixed zero-finding run is classified as no-findings"
fixture_mixed="$TMPDIR/summary-mixed.json"
write_summary_fixture "$fixture_mixed" 0 4 6 0
health_mixed="$(classify_fixture "$fixture_mixed" 90 2>/dev/null || printf 'missing')"
assert_eq "40 percent max-iterations with zero findings is no-findings" "no-findings" "$health_mixed"

echo "Test 4: findings make health ok even with a high max-iterations ratio"
fixture_ok="$TMPDIR/summary-ok.json"
write_summary_fixture "$fixture_ok" 1 9 1 0
health_ok="$(classify_fixture "$fixture_ok" 90 2>/dev/null || printf 'missing')"
assert_eq "at least one finding classifies the run as ok" "ok" "$health_ok"

echo "Test 5: empty finalized summary is classified distinctly"
fixture_empty="$TMPDIR/summary-empty.json"
write_summary_fixture "$fixture_empty" 0 0 0 0
health_empty="$(classify_fixture "$fixture_empty" 90 2>/dev/null || printf 'missing')"
assert_eq "zero run lenses with zero findings is empty" "empty" "$health_empty"

echo "Test 6: invalid classifier thresholds fail closed"
fixture_invalid="$TMPDIR/summary-invalid-threshold.json"
write_summary_fixture "$fixture_invalid" 0 1 0 0
set +e
classify_fixture "$fixture_invalid" 0 >/dev/null 2>&1
invalid_low_rc=$?
classify_fixture "$fixture_invalid" 101 >/dev/null 2>&1
invalid_high_rc=$?
classify_fixture "$fixture_invalid" abc >/dev/null 2>&1
invalid_text_rc=$?
set -e
assert_eq "threshold 0 is rejected" "2" "$invalid_low_rc"
assert_eq "threshold over 100 is rejected" "2" "$invalid_high_rc"
assert_eq "non-numeric threshold is rejected" "2" "$invalid_text_rc"

echo "Test 7: persisted broken health keeps an existing stop reason"
fixture_existing_reason="$TMPDIR/summary-existing-reason.json"
write_summary_fixture "$fixture_existing_reason" 0 9 1 0
jq '.stopped_reason = "operator-stop"' "$fixture_existing_reason" > "$fixture_existing_reason.tmp"
mv "$fixture_existing_reason.tmp" "$fixture_existing_reason"
persist_health_fixture "$fixture_existing_reason" 90
assert_jq "set_summary_health records broken health" "$fixture_existing_reason" '.health == "broken"'
assert_jq "set_summary_health preserves existing stopped reason" "$fixture_existing_reason" '.stopped_reason == "operator-stop"'

echo "Test 8: public CLI exits 2 and marks broken when the only lens hits max-iterations"
broken_result="$(run_repolens_case "broken" "max" "false")"
IFS='|' read -r broken_rc broken_run_id broken_log <<< "$broken_result"
broken_summary="$SCRIPT_DIR/logs/$broken_run_id/summary.json"
broken_status="$SCRIPT_DIR/logs/$broken_run_id/status.json"
assert_eq "degenerate run exits with policy code 2" "2" "$broken_rc"
assert_file_exists "degenerate run writes summary" "$broken_summary"
assert_jq "degenerate summary records broken health" "$broken_summary" '.health == "broken"'
assert_jq "degenerate summary records stopped reason" "$broken_summary" '.stopped_reason == "degenerate-no-findings"'
assert_jq "degenerate lens records max-iterations" "$broken_summary" '.lenses | any(.domain == "i18n" and .lens == "i18n-strings" and .status == "max-iterations" and .iterations == 20)'
assert_contains "degenerate run prints visible broken banner" "Run health: BROKEN" "$broken_log"
assert_jq "degenerate final status is failed with health" "$broken_status" '.state == "failed" and .health == "broken"'

echo "Test 9: allow override keeps broken health but permits a zero exit"
allowed_result="$(run_repolens_case "allowed" "max" "true")"
IFS='|' read -r allowed_rc allowed_run_id _allowed_log <<< "$allowed_result"
allowed_summary="$SCRIPT_DIR/logs/$allowed_run_id/summary.json"
allowed_status="$SCRIPT_DIR/logs/$allowed_run_id/status.json"
assert_eq "allow-degenerate override exits zero" "0" "$allowed_rc"
assert_jq "allow-degenerate preserves broken summary health" "$allowed_summary" '.health == "broken" and .stopped_reason == "degenerate-no-findings"'
assert_jq "allow-degenerate preserves failed final state for pollers" "$allowed_status" '.state == "failed" and .health == "broken"'

echo "Test 10: clean zero-finding run exits zero as finished-empty"
clean_result="$(run_repolens_case "clean" "clean" "false")"
IFS='|' read -r clean_rc clean_run_id _clean_log <<< "$clean_result"
clean_summary="$SCRIPT_DIR/logs/$clean_run_id/summary.json"
clean_status="$SCRIPT_DIR/logs/$clean_run_id/status.json"
assert_eq "clean no-finding run exits zero" "0" "$clean_rc"
assert_jq "clean summary records no-findings health" "$clean_summary" '.health == "no-findings" and .stopped_reason == null'
assert_jq "clean final status is finished-empty with health" "$clean_status" '.state == "finished-empty" and .health == "no-findings"'

echo ""
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
