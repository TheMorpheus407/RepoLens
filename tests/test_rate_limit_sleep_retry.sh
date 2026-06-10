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

# Integration tests for issue #115 rate-limit resume handling.
#
# The tests run repolens.sh in --local mode with fake codex and fake sleep
# commands on PATH. No real agent is invoked, and sleeps are recorded instead
# of waiting in wall-clock time.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
TOTAL=0
TMPDIR="$(mktemp -d)"
RUN_IDS=()

# shellcheck disable=SC2329
cleanup() {
  local run_id
  rm -rf "$TMPDIR"
  for run_id in "${RUN_IDS[@]:-}"; do
    rm -rf "$SCRIPT_DIR/logs/$run_id"
  done
}
trap cleanup EXIT

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (expected='$expected' actual='$actual')"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (needle='$needle' not found)"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (unexpected needle='$needle' found)"
  fi
}

assert_jq() {
  local desc="$1" file="$2" filter="$3"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$file" ]] && jq -e "$filter" "$file" >/dev/null 2>&1; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (file='$file' filter='$filter')"
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
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (file='$file' expected delta ${min_delta}..${max_delta}s)"
  fi
}

assert_numeric_between() {
  local desc="$1" actual="$2" min="$3" max="$4"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" =~ ^[0-9]+$ && "$actual" -ge "$min" && "$actual" -le "$max" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (expected ${min}..${max}, actual='${actual:-<empty>}')"
  fi
}

setup_project() {
  local project="$1"
  mkdir -p "$project"
  git -C "$project" init -q 2>/dev/null || true
  printf '# test project\n' > "$project/README.md"
}

install_fake_sleep() {
  local fake_bin="$1"
  cat > "$fake_bin/sleep" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${REPOLENS_TEST_SLEEP_LOG:?}"
exit 0
SH
  chmod +x "$fake_bin/sleep"
}

parse_run_id() {
  local output_file="$1"
  grep -oE 'RepoLens run [^ ]+ starting' "$output_file" | head -1 | awk '{print $3}'
}

count_lines_or_zero() {
  local file="$1"
  if [[ -f "$file" ]]; then
    wc -l < "$file"
  else
    echo 0
  fi
}

run_repolens_focus() {
  local project="$1" out_file="$2"
  set +e
  env \
    PATH="$PATH" \
    REPOLENS_TEST_STATE="${REPOLENS_TEST_STATE:-}" \
    REPOLENS_TEST_SLEEP_LOG="${REPOLENS_TEST_SLEEP_LOG:-}" \
    REPOLENS_RATE_LIMIT_MAX_SLEEP="${REPOLENS_RATE_LIMIT_MAX_SLEEP:-}" \
    REPOLENS_AGENT_TIMEOUT=10 \
    bash "$SCRIPT_DIR/repolens.sh" \
      --project "$project" \
      --agent codex \
      --focus i18n-strings \
      --mode audit \
      --local \
      --max-issues 99 \
      --yes \
      >"$out_file" 2>&1
  local rc=$?
  return "$rc"
}

echo "=== Rate-limit sleep and retry succeeds once ==="

CASE_DIR="$TMPDIR/retry-success"
PROJECT="$CASE_DIR/project"
FAKE_BIN="$CASE_DIR/bin"
STATE="$CASE_DIR/codex-count"
SLEEP_LOG="$CASE_DIR/sleep.log"
OUT_FILE="$CASE_DIR/run.log"
mkdir -p "$FAKE_BIN"
setup_project "$PROJECT"
install_fake_sleep "$FAKE_BIN"
cat > "$FAKE_BIN/codex" <<'SH'
#!/usr/bin/env bash
count=0
if [[ -f "${REPOLENS_TEST_STATE:?}" ]]; then
  count="$(cat "$REPOLENS_TEST_STATE")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$REPOLENS_TEST_STATE"

if [[ "$count" -eq 1 ]]; then
  echo "ERROR: You've hit your usage limit. Please try again in 1 seconds."
  exit 1
fi

echo "Analysis complete."
echo "DONE"
exit 0
SH
chmod +x "$FAKE_BIN/codex"

export PATH="$FAKE_BIN:$PATH"
export REPOLENS_TEST_STATE="$STATE"
export REPOLENS_TEST_SLEEP_LOG="$SLEEP_LOG"
export REPOLENS_RATE_LIMIT_MAX_SLEEP=120

run_repolens_focus "$PROJECT" "$OUT_FILE"
exit_code=$?
run_id="$(parse_run_id "$OUT_FILE")"
[[ -n "${run_id:-}" ]] && RUN_IDS+=("$run_id")
summary_file="$SCRIPT_DIR/logs/$run_id/summary.json"
status_file="$SCRIPT_DIR/logs/$run_id/status.json"
log_contents="$(cat "$OUT_FILE")"

assert_eq "Run exits 0 after sleeping and retrying" "0" "$exit_code"
assert_eq "Fake codex invoked twice" "2" "$(cat "$STATE" 2>/dev/null || echo 0)"
assert_contains "Log announces rate-limit sleep" "Agent rate-limited. Resume at" "$log_contents"
assert_contains "Log announces sleeping" "Sleeping." "$log_contents"
assert_not_contains "Run does not use terminal rate-limit abort log" "rate-limited / quota exceeded" "$log_contents"

sleep_calls="$(count_lines_or_zero "$SLEEP_LOG")"
assert_eq "Exactly one sleep was requested" "1" "$sleep_calls"
sleep_seconds=""
[[ -f "$SLEEP_LOG" ]] && sleep_seconds="$(tail -1 "$SLEEP_LOG")"
assert_numeric_between "Sleep includes the retry buffer" "$sleep_seconds" 60 65

if [[ -f "$summary_file" ]]; then
  stopped_reason="$(jq -r '.stopped_reason' "$summary_file")"
  assert_eq "summary.stopped_reason remains null" "null" "$stopped_reason"
  iterations="$(jq '[.lenses[] | select(.lens == "i18n-strings") | .iterations] | .[0]' "$summary_file")"
  assert_eq "Retry uses the existing lens loop and records two iterations" "2" "$iterations"
  rl_count="$(jq '[.lenses[] | select(.status == "rate-limited")] | length' "$summary_file")"
  assert_eq "No lens is marked rate-limited after successful retry" "0" "$rl_count"
  summary_sleep="$(jq '[.lenses[] | select(.lens == "i18n-strings") | .rate_limit_sleep_seconds] | .[0]' "$summary_file")"
  assert_eq "Summary records rate_limit_sleep_seconds" "$sleep_seconds" "$summary_sleep"
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: summary.json missing for retry-success run"
fi

echo ""
echo "=== Parseable wait beyond default cap aborts without sleeping ==="

CASE_DIR="$TMPDIR/cap-abort"
PROJECT="$CASE_DIR/project"
FAKE_BIN="$CASE_DIR/bin"
STATE="$CASE_DIR/codex-count"
SLEEP_LOG="$CASE_DIR/sleep.log"
OUT_FILE="$CASE_DIR/run.log"
mkdir -p "$FAKE_BIN"
setup_project "$PROJECT"
install_fake_sleep "$FAKE_BIN"
cat > "$FAKE_BIN/codex" <<'SH'
#!/usr/bin/env bash
count=0
if [[ -f "${REPOLENS_TEST_STATE:?}" ]]; then
  count="$(cat "$REPOLENS_TEST_STATE")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$REPOLENS_TEST_STATE"
echo "ERROR: You've hit your usage limit. Please try again in 7 hours."
exit 1
SH
chmod +x "$FAKE_BIN/codex"

export PATH="$FAKE_BIN:$PATH"
export REPOLENS_TEST_STATE="$STATE"
export REPOLENS_TEST_SLEEP_LOG="$SLEEP_LOG"
unset REPOLENS_RATE_LIMIT_MAX_SLEEP

run_repolens_focus "$PROJECT" "$OUT_FILE"
exit_code=$?
run_id="$(parse_run_id "$OUT_FILE")"
[[ -n "${run_id:-}" ]] && RUN_IDS+=("$run_id")
summary_file="$SCRIPT_DIR/logs/$run_id/summary.json"
status_file="$SCRIPT_DIR/logs/$run_id/status.json"
log_contents="$(cat "$OUT_FILE")"

TOTAL=$((TOTAL + 1))
if [[ "$exit_code" -ne 0 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: Run exits non-zero when parsed wait exceeds the default cap"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: Expected non-zero exit when parsed wait exceeds default cap"
fi
assert_eq "Cap abort invokes codex only once" "1" "$(cat "$STATE" 2>/dev/null || echo 0)"
assert_eq "Cap abort does not sleep" "0" "$(count_lines_or_zero "$SLEEP_LOG")"
assert_contains "Cap abort falls back to existing abort path" "rate-limited / quota exceeded" "$log_contents"
assert_next_action_delta_between_updated_at \
  "Cap abort status persists the parsed seven-hour retry time" \
  "$status_file" 25080 25260

echo ""
echo "=== Stale parsed resume time aborts without sleeping ==="

CASE_DIR="$TMPDIR/stale-abort"
PROJECT="$CASE_DIR/project"
FAKE_BIN="$CASE_DIR/bin"
STATE="$CASE_DIR/codex-count"
SLEEP_LOG="$CASE_DIR/sleep.log"
OUT_FILE="$CASE_DIR/run.log"
mkdir -p "$FAKE_BIN"
setup_project "$PROJECT"
install_fake_sleep "$FAKE_BIN"
cat > "$FAKE_BIN/codex" <<'SH'
#!/usr/bin/env bash
count=0
if [[ -f "${REPOLENS_TEST_STATE:?}" ]]; then
  count="$(cat "$REPOLENS_TEST_STATE")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$REPOLENS_TEST_STATE"
echo "ERROR: You've hit your usage limit. Please try again at Jan 1st, 2000 12:00 AM UTC."
exit 1
SH
chmod +x "$FAKE_BIN/codex"

export PATH="$FAKE_BIN:$PATH"
export REPOLENS_TEST_STATE="$STATE"
export REPOLENS_TEST_SLEEP_LOG="$SLEEP_LOG"
export REPOLENS_RATE_LIMIT_MAX_SLEEP=120

run_repolens_focus "$PROJECT" "$OUT_FILE"
exit_code=$?
run_id="$(parse_run_id "$OUT_FILE")"
[[ -n "${run_id:-}" ]] && RUN_IDS+=("$run_id")
summary_file="$SCRIPT_DIR/logs/$run_id/summary.json"
status_file="$SCRIPT_DIR/logs/$run_id/status.json"
log_contents="$(cat "$OUT_FILE")"

TOTAL=$((TOTAL + 1))
if [[ "$exit_code" -ne 0 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: Run exits non-zero for stale parsed resume time"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: Expected non-zero exit for stale parsed resume time"
fi
assert_eq "Stale resume abort invokes codex only once" "1" "$(cat "$STATE" 2>/dev/null || echo 0)"
assert_eq "Stale resume abort does not sleep" "0" "$(count_lines_or_zero "$SLEEP_LOG")"
assert_not_contains "Stale resume abort does not enter sleep/retry path" "Agent rate-limited. Resume at" "$log_contents"
assert_contains "Stale resume abort falls back to existing abort path" "rate-limited / quota exceeded" "$log_contents"
assert_jq "Stale resume status omits next_action retry metadata" "$status_file" \
  '.state == "rate-limit-pending" and (has("next_action") | not)'
if [[ -f "$summary_file" ]]; then
  summary_sleep="$(jq '[.lenses[] | select(.status == "rate-limited") | .rate_limit_sleep_seconds] | .[0]' "$summary_file")"
  assert_eq "Stale resume summary records zero sleep" "0" "$summary_sleep"
fi

echo ""
echo "=== Unparseable rate-limit resume aborts without sleeping ==="

CASE_DIR="$TMPDIR/unparseable-abort"
PROJECT="$CASE_DIR/project"
FAKE_BIN="$CASE_DIR/bin"
STATE="$CASE_DIR/codex-count"
SLEEP_LOG="$CASE_DIR/sleep.log"
OUT_FILE="$CASE_DIR/run.log"
mkdir -p "$FAKE_BIN"
setup_project "$PROJECT"
install_fake_sleep "$FAKE_BIN"
cat > "$FAKE_BIN/codex" <<'SH'
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
chmod +x "$FAKE_BIN/codex"

export PATH="$FAKE_BIN:$PATH"
export REPOLENS_TEST_STATE="$STATE"
export REPOLENS_TEST_SLEEP_LOG="$SLEEP_LOG"
export REPOLENS_RATE_LIMIT_MAX_SLEEP=120

run_repolens_focus "$PROJECT" "$OUT_FILE"
exit_code=$?
run_id="$(parse_run_id "$OUT_FILE")"
[[ -n "${run_id:-}" ]] && RUN_IDS+=("$run_id")
summary_file="$SCRIPT_DIR/logs/$run_id/summary.json"
status_file="$SCRIPT_DIR/logs/$run_id/status.json"
log_contents="$(cat "$OUT_FILE")"

TOTAL=$((TOTAL + 1))
if [[ "$exit_code" -ne 0 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: Run exits non-zero for unparseable rate-limit resume"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: Expected non-zero exit for unparseable rate-limit resume"
fi
assert_eq "Unparseable resume abort invokes codex only once" "1" "$(cat "$STATE" 2>/dev/null || echo 0)"
assert_eq "Unparseable resume abort does not sleep" "0" "$(count_lines_or_zero "$SLEEP_LOG")"
assert_not_contains "Unparseable resume abort does not enter sleep/retry path" "Agent rate-limited. Resume at" "$log_contents"
assert_contains "Unparseable resume abort falls back to existing abort path" "rate-limited / quota exceeded" "$log_contents"
assert_jq "Unparseable resume status omits next_action retry metadata" "$status_file" \
  '.state == "rate-limit-pending" and (has("next_action") | not)'
if [[ -f "$summary_file" ]]; then
  summary_sleep="$(jq '[.lenses[] | select(.status == "rate-limited") | .rate_limit_sleep_seconds] | .[0]' "$summary_file")"
  assert_eq "Unparseable resume summary records zero sleep" "0" "$summary_sleep"
fi

echo ""
echo "=== Invalid rate-limit sleep cap is rejected before agent invocation ==="

CASE_DIR="$TMPDIR/invalid-cap"
PROJECT="$CASE_DIR/project"
FAKE_BIN="$CASE_DIR/bin"
STATE="$CASE_DIR/codex-count"
SLEEP_LOG="$CASE_DIR/sleep.log"
OUT_FILE="$CASE_DIR/run.log"
mkdir -p "$FAKE_BIN"
setup_project "$PROJECT"
install_fake_sleep "$FAKE_BIN"
cat > "$FAKE_BIN/codex" <<'SH'
#!/usr/bin/env bash
printf 'called\n' >> "${REPOLENS_TEST_STATE:?}"
echo "DONE"
exit 0
SH
chmod +x "$FAKE_BIN/codex"

export PATH="$FAKE_BIN:$PATH"
export REPOLENS_TEST_STATE="$STATE"
export REPOLENS_TEST_SLEEP_LOG="$SLEEP_LOG"
export REPOLENS_RATE_LIMIT_MAX_SLEEP=-1

run_repolens_focus "$PROJECT" "$OUT_FILE"
exit_code=$?
log_contents="$(cat "$OUT_FILE")"

TOTAL=$((TOTAL + 1))
if [[ "$exit_code" -ne 0 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: Invalid cap exits non-zero"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: Invalid cap unexpectedly exited 0"
fi
assert_eq "Invalid cap does not invoke codex" "0" "$(count_lines_or_zero "$STATE")"
assert_eq "Invalid cap does not sleep" "0" "$(count_lines_or_zero "$SLEEP_LOG")"
assert_contains "Invalid cap reports validation error" "REPOLENS_RATE_LIMIT_MAX_SLEEP must be a non-negative integer" "$log_contents"

echo ""
echo "=== Second rate-limit after retry aborts ==="

CASE_DIR="$TMPDIR/second-hit"
PROJECT="$CASE_DIR/project"
FAKE_BIN="$CASE_DIR/bin"
STATE="$CASE_DIR/codex-count"
SLEEP_LOG="$CASE_DIR/sleep.log"
OUT_FILE="$CASE_DIR/run.log"
mkdir -p "$FAKE_BIN"
setup_project "$PROJECT"
install_fake_sleep "$FAKE_BIN"
cat > "$FAKE_BIN/codex" <<'SH'
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
chmod +x "$FAKE_BIN/codex"

export PATH="$FAKE_BIN:$PATH"
export REPOLENS_TEST_STATE="$STATE"
export REPOLENS_TEST_SLEEP_LOG="$SLEEP_LOG"
export REPOLENS_RATE_LIMIT_MAX_SLEEP=120

run_repolens_focus "$PROJECT" "$OUT_FILE"
exit_code=$?
run_id="$(parse_run_id "$OUT_FILE")"
[[ -n "${run_id:-}" ]] && RUN_IDS+=("$run_id")
summary_file="$SCRIPT_DIR/logs/$run_id/summary.json"
status_file="$SCRIPT_DIR/logs/$run_id/status.json"
log_contents="$(cat "$OUT_FILE")"

TOTAL=$((TOTAL + 1))
if [[ "$exit_code" -ne 0 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: Run exits non-zero after second rate-limit hit"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: Expected non-zero exit after second rate-limit hit"
fi
assert_eq "Second-hit run invokes codex twice" "2" "$(cat "$STATE" 2>/dev/null || echo 0)"
assert_eq "Second-hit run sleeps only once" "1" "$(count_lines_or_zero "$SLEEP_LOG")"
assert_contains "Second-hit run eventually logs terminal abort" "rate-limited / quota exceeded" "$log_contents"
assert_next_action_delta_between_updated_at \
  "Second-hit status persists the parsed short retry time" \
  "$status_file" -15 15
if [[ -f "$summary_file" ]]; then
  iterations="$(jq '[.lenses[] | select(.status == "rate-limited") | .iterations] | .[0]' "$summary_file")"
  assert_eq "Second-hit abort records two iterations" "2" "$iterations"
  summary_sleep="$(jq '[.lenses[] | select(.status == "rate-limited") | .rate_limit_sleep_seconds] | .[0]' "$summary_file")"
  assert_numeric_between "Second-hit summary records the one sleep" "$summary_sleep" 60 65
fi

echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
exit "$FAIL"
