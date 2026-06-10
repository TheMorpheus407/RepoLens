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

# Regression coverage for issue #276: rate-limit aborts that occur in a
# parallel run_lens child must be visible to the parent after wait_all.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORIGINAL_PATH="$PATH"

PASS=0
FAIL=0
TOTAL=0
TMPDIR="$(mktemp -d)"
RUN_IDS=()

# shellcheck disable=SC2329 # Invoked by the EXIT trap below.
cleanup() {
  local run_id
  rm -rf "$TMPDIR"
  for run_id in "${RUN_IDS[@]:-}"; do
    [[ -n "$run_id" ]] && rm -rf "$SCRIPT_DIR/logs/$run_id"
  done
}
trap cleanup EXIT

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

assert_file_exists() {
  local desc="$1" file="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$file" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Missing file: $file"
  fi
}

assert_file_contains() {
  local desc="$1" file="$2" needle="$3"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$file" ]] && grep -qF "$needle" "$file"; then
    pass_with "$desc"
  else
    fail_with "$desc" "file=$file needle=$needle"
  fi
}

assert_file_missing() {
  local desc="$1" file="$2"
  TOTAL=$((TOTAL + 1))
  if [[ ! -e "$file" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Unexpected path: $file"
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

assert_next_action_delta_between_updated_at() {
  local desc="$1" file="$2" min_delta="$3" max_delta="$4"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$file" ]] && jq -e \
    --argjson min_delta "$min_delta" \
    --argjson max_delta "$max_delta" \
    '.state == "rate-limit-pending"
     and (.next_action.earliest_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
     and (((.next_action.earliest_at | fromdateiso8601) - (.updated_at | fromdateiso8601)) as $delta
          | ($delta >= $min_delta and $delta <= $max_delta))' \
    "$file" >/dev/null 2>&1; then
    pass_with "$desc"
  else
    fail_with "$desc" "file=$file expected delta ${min_delta}..${max_delta}s"
  fi
}

assert_numeric_at_least() {
  local desc="$1" actual="$2" minimum="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" =~ ^[0-9]+$ && "$actual" -ge "$minimum" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected >= $minimum | Actual: ${actual:-<empty>}"
  fi
}

setup_project() {
  local project="$1"
  mkdir -p "$project"
  (
    cd "$project" || exit 1
    git init -q 2>/dev/null
    git config user.email test@example.com
    git config user.name Test
    printf '# test project\n' > README.md
    git add README.md
    git commit -q -m init 2>/dev/null
  ) || true
}

parse_run_id() {
  local output_file="$1"
  grep -oE 'RepoLens run [^ ]+ starting' "$output_file" 2>/dev/null | head -1 | awk '{print $3}'
}

count_rate_limit_sleep_calls() {
  local file="$1"
  if [[ -f "$file" ]]; then
    awk '$1 ~ /^[0-9]+$/ && $1 >= 60 { count++ } END { print count + 0 }' "$file"
  else
    printf '0\n'
  fi
}

install_fake_sleep() {
  local fake_bin="$1"
  cat > "$fake_bin/sleep" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${REPOLENS_TEST_SLEEP_LOG:?}"
exit "${REPOLENS_TEST_SLEEP_RC:?}"
SH
  chmod +x "$fake_bin/sleep"
}

install_retry_rate_limit_agent() {
  local fake_bin="$1"
  cat > "$fake_bin/codex" <<'SH'
#!/usr/bin/env bash
count=0
if [[ -f "${REPOLENS_TEST_STATE:?}" ]]; then
  count="$(cat "$REPOLENS_TEST_STATE")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$REPOLENS_TEST_STATE"
echo "ERROR: You've hit your usage limit. Please try again in 1 seconds."
exit 1
SH
  chmod +x "$fake_bin/codex"
}

install_terminal_rate_limit_agent() {
  local fake_bin="$1"
  cat > "$fake_bin/codex" <<'SH'
#!/usr/bin/env bash
count=0
if [[ -f "${REPOLENS_TEST_STATE:?}" ]]; then
  count="$(cat "$REPOLENS_TEST_STATE")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$REPOLENS_TEST_STATE"
echo "ERROR: You've hit your usage limit. Please try again later."
exit 1
SH
  chmod +x "$fake_bin/codex"
}

install_success_agent() {
  local fake_bin="$1"
  cat > "$fake_bin/codex" <<'SH'
#!/usr/bin/env bash
mkdir -p "${REPOLENS_TEST_STATE:?}"
count=0
if [[ -f "$REPOLENS_TEST_STATE/calls" ]]; then
  count="$(cat "$REPOLENS_TEST_STATE/calls")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$REPOLENS_TEST_STATE/calls"
echo "Analysis complete."
echo "DONE"
exit 0
SH
  chmod +x "$fake_bin/codex"
}

register_case_run() {
  CASE_RUN_ID="$(parse_run_id "$CASE_OUT_FILE")"
  if [[ -n "${CASE_RUN_ID:-}" ]]; then
    RUN_IDS+=("$CASE_RUN_ID")
  fi
  CASE_LOG_BASE="$SCRIPT_DIR/logs/$CASE_RUN_ID"
  CASE_SUMMARY_FILE="$CASE_LOG_BASE/summary.json"
  CASE_STATUS_FILE="$CASE_LOG_BASE/status.json"
}

run_parallel_sleep_case() {
  local name="$1" sleep_rc="$2"
  CASE_DIR="$TMPDIR/$name"
  CASE_PROJECT="$CASE_DIR/project"
  CASE_FAKE_BIN="$CASE_DIR/bin"
  CASE_STATE="$CASE_DIR/codex-count"
  CASE_SLEEP_LOG="$CASE_DIR/sleep.log"
  CASE_OUT_FILE="$CASE_DIR/run.log"
  mkdir -p "$CASE_FAKE_BIN"
  setup_project "$CASE_PROJECT"
  install_retry_rate_limit_agent "$CASE_FAKE_BIN"
  install_fake_sleep "$CASE_FAKE_BIN"

  set +e
  env \
    PATH="$CASE_FAKE_BIN:$ORIGINAL_PATH" \
    REPOLENS_TEST_STATE="$CASE_STATE" \
    REPOLENS_TEST_SLEEP_LOG="$CASE_SLEEP_LOG" \
    REPOLENS_TEST_SLEEP_RC="$sleep_rc" \
    REPOLENS_RATE_LIMIT_MAX_SLEEP=120 \
    REPOLENS_AGENT_TIMEOUT=10 \
    REPOLENS_STATUS_INTERVAL=1 \
    bash "$SCRIPT_DIR/repolens.sh" \
      --project "$CASE_PROJECT" \
      --agent codex \
      --focus i18n-strings \
      --mode audit \
      --local \
      --parallel \
      --max-parallel 1 \
      --yes \
      >"$CASE_OUT_FILE" 2>&1
  CASE_EXIT_CODE=$?
  set -u

  register_case_run
}

run_parallel_terminal_case() {
  local name="$1"
  CASE_DIR="$TMPDIR/$name"
  CASE_PROJECT="$CASE_DIR/project"
  CASE_FAKE_BIN="$CASE_DIR/bin"
  CASE_STATE="$CASE_DIR/codex-count"
  CASE_SLEEP_LOG="$CASE_DIR/sleep.log"
  CASE_OUT_FILE="$CASE_DIR/run.log"
  mkdir -p "$CASE_FAKE_BIN"
  setup_project "$CASE_PROJECT"
  install_terminal_rate_limit_agent "$CASE_FAKE_BIN"
  install_fake_sleep "$CASE_FAKE_BIN"

  set +e
  env \
    PATH="$CASE_FAKE_BIN:$ORIGINAL_PATH" \
    REPOLENS_TEST_STATE="$CASE_STATE" \
    REPOLENS_TEST_SLEEP_LOG="$CASE_SLEEP_LOG" \
    REPOLENS_TEST_SLEEP_RC=0 \
    REPOLENS_RATE_LIMIT_MAX_SLEEP=120 \
    REPOLENS_AGENT_TIMEOUT=10 \
    REPOLENS_STATUS_INTERVAL=1 \
    bash "$SCRIPT_DIR/repolens.sh" \
      --project "$CASE_PROJECT" \
      --agent codex \
      --domain i18n \
      --mode audit \
      --local \
      --parallel \
      --max-parallel 1 \
      --yes \
      >"$CASE_OUT_FILE" 2>&1
  CASE_EXIT_CODE=$?
  set -u

  register_case_run
}

run_resume_cleanup_case() {
  local name="$1"
  CASE_DIR="$TMPDIR/$name"
  CASE_PROJECT="$CASE_DIR/project"
  CASE_FAKE_BIN="$CASE_DIR/bin"
  CASE_STATE="$CASE_DIR/state"
  CASE_OUT_FILE="$CASE_DIR/run.log"
  CASE_RUN_ID="test-rate-limit-sleep-resume-$RANDOM"
  CASE_LOG_BASE="$SCRIPT_DIR/logs/$CASE_RUN_ID"
  CASE_SUMMARY_FILE="$CASE_LOG_BASE/summary.json"
  CASE_STATUS_FILE="$CASE_LOG_BASE/status.json"
  mkdir -p "$CASE_FAKE_BIN" "$CASE_LOG_BASE/rounds/round-1" "$CASE_LOG_BASE/output/i18n/i18n-strings"
  RUN_IDS+=("$CASE_RUN_ID")
  setup_project "$CASE_PROJECT"
  install_success_agent "$CASE_FAKE_BIN"

  printf '%s\n' "i18n/i18n-formatting" > "$CASE_LOG_BASE/.completed"
  printf '{"run_id":"%s","rounds_total":1,"total_lenses":2,"lens_list":["i18n/i18n-strings","i18n/i18n-formatting"]}\n' \
    "$CASE_RUN_ID" > "$CASE_LOG_BASE/rounds/round-1/metadata.json"
  printf '{"run_id":"%s","project_path":"","mode":"audit","agent":"codex","started_at":"2026-05-14T00:00:00Z","completed_at":null,"stopped_reason":"interrupted-sigint","lenses":[{"domain":"i18n","lens":"i18n-strings","iterations":1,"status":"rate-limited","issues_created":0,"rate_limit_sleep_seconds":61}],"totals":{"lenses_run":1,"iterations_total":1,"issues_created":0}}\n' \
    "$CASE_RUN_ID" > "$CASE_SUMMARY_FILE"
  : > "$CASE_LOG_BASE/.rate-limit-abort"
  {
    printf 'exit_code=130\n'
    printf 'signal=SIGINT\n'
    printf 'stopped_reason=interrupted-sigint\n'
    printf 'source=rate-limit-sleep\n'
  } > "$CASE_LOG_BASE/.rate-limit-sleep-interrupt"
  : > "$CASE_LOG_BASE/.rate-limit-abort.tmp.123"
  : > "$CASE_LOG_BASE/.rate-limit-sleep-interrupt.tmp.123"

  set +e
  env \
    PATH="$CASE_FAKE_BIN:$ORIGINAL_PATH" \
    REPOLENS_TEST_STATE="$CASE_STATE" \
    REPOLENS_AGENT_TIMEOUT=10 \
    REPOLENS_STATUS_INTERVAL=1 \
    bash "$SCRIPT_DIR/repolens.sh" \
      --project "$CASE_PROJECT" \
      --agent codex \
      --domain i18n \
      --mode audit \
      --depth 1 \
      --resume "$CASE_RUN_ID" \
      --local \
      --parallel \
      --max-parallel 1 \
      --yes \
      >"$CASE_OUT_FILE" 2>&1
  CASE_EXIT_CODE=$?
  set -u
}

assert_signal_sleep_case() {
  local label="$1" sleep_rc="$2" stopped_reason="$3"
  local expected_signal

  echo ""
  echo "Test: parallel rate-limit sleep propagates $label"
  run_parallel_sleep_case "sleep-$label" "$sleep_rc"
  case "$sleep_rc" in
    129) expected_signal="SIGHUP" ;;
    130) expected_signal="SIGINT" ;;
    143) expected_signal="SIGTERM" ;;
    *) expected_signal="UNKNOWN" ;;
  esac

  assert_eq "$label run id parsed" "1" "$([[ -n "${CASE_RUN_ID:-}" ]] && printf 1 || printf 0)"
  assert_eq "$label exits with signal-specific code" "$sleep_rc" "$CASE_EXIT_CODE"
  assert_eq "$label fake agent invoked once" "1" "$(cat "$CASE_STATE" 2>/dev/null || printf 0)"
  assert_numeric_at_least "$label rate-limit retry sleep was requested" \
                          "$(count_rate_limit_sleep_calls "$CASE_SLEEP_LOG")" "1"
  assert_file_exists "$label writes parent-visible rate-limit marker" "$CASE_LOG_BASE/.rate-limit-abort"
  assert_file_exists "$label writes parent-visible sleep interrupt marker" "$CASE_LOG_BASE/.rate-limit-sleep-interrupt"
  assert_file_contains "$label interrupt marker records exit code" "$CASE_LOG_BASE/.rate-limit-sleep-interrupt" "exit_code=$sleep_rc"
  assert_file_contains "$label interrupt marker records signal" "$CASE_LOG_BASE/.rate-limit-sleep-interrupt" "signal=$expected_signal"
  assert_file_contains "$label interrupt marker records stopped reason" "$CASE_LOG_BASE/.rate-limit-sleep-interrupt" "stopped_reason=$stopped_reason"
  assert_file_contains "$label interrupt marker records source" "$CASE_LOG_BASE/.rate-limit-sleep-interrupt" "source=rate-limit-sleep"
  assert_jq "$label status.json final state is interrupted" "$CASE_STATUS_FILE" '.state == "interrupted"'
  assert_jq "$label interrupted status omits next_action retry metadata" "$CASE_STATUS_FILE" \
            'has("next_action") | not'
  assert_jq "$label summary records signal-specific stopped_reason" "$CASE_SUMMARY_FILE" \
            ".stopped_reason == \"$stopped_reason\""
  assert_jq "$label does not finalize as finished" "$CASE_STATUS_FILE" \
            '.state != "finished" and .state != "finished-empty"'
}

echo "=== Parallel rate-limit abort propagation (issue #276) ==="

assert_signal_sleep_case "sighup" "129" "interrupted-sighup"
assert_signal_sleep_case "sigint" "130" "interrupted-sigint"
assert_signal_sleep_case "sigterm" "143" "interrupted-sigterm"

echo ""
echo "Test: parallel rate-limit sleep generic failure becomes rate-limit pending"
run_parallel_sleep_case "sleep-generic-failure" "42"
assert_eq "generic sleep failure run id parsed" "1" "$([[ -n "${CASE_RUN_ID:-}" ]] && printf 1 || printf 0)"
assert_eq "generic sleep failure exits with rate-limit pending code" "3" "$CASE_EXIT_CODE"
assert_eq "generic sleep failure fake agent invoked once" "1" "$(cat "$CASE_STATE" 2>/dev/null || printf 0)"
assert_numeric_at_least "generic sleep failure rate-limit retry sleep was requested" \
                        "$(count_rate_limit_sleep_calls "$CASE_SLEEP_LOG")" "1"
assert_file_exists "generic sleep failure writes parent-visible rate-limit marker" "$CASE_LOG_BASE/.rate-limit-abort"
assert_file_missing "generic sleep failure does not write sleep interrupt marker" "$CASE_LOG_BASE/.rate-limit-sleep-interrupt"
assert_jq "generic sleep failure status is rate-limit-pending" "$CASE_STATUS_FILE" \
          '.state == "rate-limit-pending"'
assert_next_action_delta_between_updated_at \
  "generic sleep failure status persists the parsed short retry time" \
  "$CASE_STATUS_FILE" -15 15
assert_jq "generic sleep failure stopped_reason stays rate-limit related" "$CASE_SUMMARY_FILE" \
          '(.stopped_reason // "") | startswith("rate-limited")'
assert_jq "generic sleep failure is not classified as interrupted" "$CASE_SUMMARY_FILE" \
          '(.stopped_reason // "") | startswith("interrupted") | not'
generic_rate_limited_count="$(jq '[.lenses[]? | select(.status == "rate-limited")] | length' "$CASE_SUMMARY_FILE" 2>/dev/null || printf 0)"
assert_eq "generic sleep failure records aborted lens as rate-limited" "1" "$generic_rate_limited_count"

echo ""
echo "Test: parallel terminal rate-limit marker stops later spawns"
run_parallel_terminal_case "terminal-rate-limit"
assert_eq "terminal rate-limit run id parsed" "1" "$([[ -n "${CASE_RUN_ID:-}" ]] && printf 1 || printf 0)"
assert_eq "terminal rate-limit exits with rate-limit pending code" "3" "$CASE_EXIT_CODE"
assert_eq "terminal rate-limit invokes fake agent once before skipping sibling" "1" "$(cat "$CASE_STATE" 2>/dev/null || printf 0)"
assert_eq "terminal rate-limit does not enter retry sleep" "0" "$(count_rate_limit_sleep_calls "$CASE_SLEEP_LOG")"
assert_file_exists "terminal rate-limit writes parent-visible marker" "$CASE_LOG_BASE/.rate-limit-abort"
assert_jq "terminal rate-limit status is rate-limit-pending" "$CASE_STATUS_FILE" \
          '.state == "rate-limit-pending"'
assert_jq "terminal rate-limit without a retry time omits next_action" "$CASE_STATUS_FILE" \
          'has("next_action") | not'
assert_jq "terminal rate-limit stopped_reason is rate-limit related" "$CASE_SUMMARY_FILE" \
          '(.stopped_reason // "") | startswith("rate-limited")'
rate_limited_count="$(jq '[.lenses[]? | select(.status == "rate-limited")] | length' "$CASE_SUMMARY_FILE" 2>/dev/null || printf 0)"
skipped_count="$(jq '[.lenses[]? | select(.status == "skipped")] | length' "$CASE_SUMMARY_FILE" 2>/dev/null || printf 0)"
assert_eq "terminal rate-limit records one aborted lens" "1" "$rate_limited_count"
assert_numeric_at_least "terminal rate-limit records unspawned sibling as skipped" "$skipped_count" "1"

echo ""
echo "Test: resume clears stale rate-limit sleep interrupt state"
run_resume_cleanup_case "resume-clears-sleep-interrupt"
assert_eq "resume cleanup exits successfully" "0" "$CASE_EXIT_CODE"
assert_file_missing "resume cleanup removes stale rate-limit marker" "$CASE_LOG_BASE/.rate-limit-abort"
assert_file_missing "resume cleanup removes stale rate-limit temp marker" "$CASE_LOG_BASE/.rate-limit-abort.tmp.123"
assert_file_missing "resume cleanup removes stale sleep interrupt marker" "$CASE_LOG_BASE/.rate-limit-sleep-interrupt"
assert_file_missing "resume cleanup removes stale sleep interrupt temp marker" "$CASE_LOG_BASE/.rate-limit-sleep-interrupt.tmp.123"
assert_jq "resume cleanup clears stale stopped_reason" "$CASE_SUMMARY_FILE" '.stopped_reason == null'
assert_jq "resume cleanup does not finalize as interrupted" "$CASE_STATUS_FILE" '.state != "interrupted"'
assert_jq "resume cleanup does not finalize as rate-limit-pending" "$CASE_STATUS_FILE" '.state != "rate-limit-pending"'
assert_jq "resume cleanup omits stale next_action retry metadata" "$CASE_STATUS_FILE" \
          'has("next_action") | not'
assert_file_contains "resume cleanup marks pending lens completed" "$CASE_LOG_BASE/.completed" "i18n/i18n-strings"
assert_eq "resume cleanup invokes fake agent once" "1" "$(cat "$CASE_STATE/calls" 2>/dev/null || printf 0)"

echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
exit "$FAIL"
