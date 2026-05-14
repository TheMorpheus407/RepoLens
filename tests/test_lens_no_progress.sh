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

# Integration tests for issue #212: persistent agent failures must trip a
# no-progress circuit breaker before the per-lens safety cap is exhausted.

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
    fail_with "$desc" "Expected: $expected | Actual: $actual"
  fi
}

assert_nonzero() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -ne 0 ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected non-zero exit status"
  fi
}

assert_zero() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -eq 0 ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected exit status 0, got $actual"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" file="$3"
  TOTAL=$((TOTAL + 1))
  if grep -qF "$needle" "$file"; then
    pass_with "$desc"
  else
    fail_with "$desc" "Missing: $needle"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" file="$3"
  TOTAL=$((TOTAL + 1))
  if grep -qF "$needle" "$file"; then
    fail_with "$desc" "Unexpected: $needle"
  else
    pass_with "$desc"
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

assert_file_missing() {
  local desc="$1" file="$2"
  TOTAL=$((TOTAL + 1))
  if [[ ! -f "$file" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Unexpected file: $file"
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

install_fake_codex() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/codex" <<'SH'
#!/usr/bin/env bash
set -uo pipefail

state_dir="${FAKE_AGENT_STATE_DIR:?}"
mkdir -p "$state_dir"
counter_file="$state_dir/calls"
count=0
if [[ -f "$counter_file" ]]; then
  count="$(cat "$counter_file")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$counter_file"

case "${FAKE_AGENT_MODE:?}" in
  fail-short)
    printf 'upstream error\n'
    exit 1
    ;;
  empty-success)
    printf 'ok\n'
    exit 0
    ;;
  reset-then-done)
    case "$count" in
      1)
        printf 'transient upstream error\n'
        exit 1
        ;;
      2)
        printf 'meaningful progress '
        printf 'analysis %.0s' {1..90}
        printf '\n'
        exit 0
        ;;
      3|4)
        printf 'transient upstream error\n'
        exit 1
        ;;
      *)
        printf 'DONE\n'
        exit 0
        ;;
    esac
    ;;
  issue-url-then-done)
    if [[ "$count" -le 3 ]]; then
      printf 'Created finding https://github.com/example/repo/issues/%s\n' "$count"
      exit 1
    fi
    printf 'DONE\n'
    exit 0
    ;;
  local-finding-then-done)
    if [[ "$count" -le 3 ]]; then
      prompt="${*: -1}"
      output_dir="$(printf '%s\n' "$prompt" | sed -n 's/^Write all findings to: `\(.*\)`$/\1/p' | sed -n '1p')"
      if [[ -n "$output_dir" ]]; then
        mkdir -p "$output_dir"
        printf '# Local finding %s\n' "$count" > "$output_dir/local-finding-$count.md"
      fi
      printf 'wrote local finding\n'
      exit 1
    fi
    printf 'DONE\n'
    exit 0
    ;;
  done)
    printf 'DONE\n'
    exit 0
    ;;
  *)
    printf 'unknown fake mode: %s\n' "${FAKE_AGENT_MODE:?}" >&2
    exit 2
    ;;
esac
SH
  chmod +x "$bin_dir/codex"
}

extract_run_id() {
  local output_file="$1"
  grep -oE 'RepoLens run [^ ]+ starting' "$output_file" | head -1 | awk '{print $3}'
}

run_focus_case() {
  local name="$1" mode="$2" output_var="$3" rc_var="$4" run_id_var="$5"
  local case_dir="$TMPDIR/$name"
  local project="$case_dir/project"
  local bin_dir="$case_dir/bin"
  local output_file="$case_dir/run.log"
  local run_id rc

  mkdir -p "$case_dir"
  create_project "$project"
  install_fake_codex "$bin_dir"

  FAKE_AGENT_MODE="$mode" \
  FAKE_AGENT_STATE_DIR="$case_dir/state" \
  PATH="$bin_dir:$PATH" \
  REPOLENS_NO_PROGRESS_LIMIT=3 \
  bash "$SCRIPT_DIR/repolens.sh" \
    --project "$project" \
    --agent codex \
    --domain i18n \
    --focus i18n-strings \
    --mode audit \
    --depth 1 \
    --local \
    --yes \
    >"$output_file" 2>&1
  rc=$?

  run_id="$(extract_run_id "$output_file")"
  if [[ -n "$run_id" ]]; then
    CREATED_RUNS+=("$run_id")
  fi

  printf -v "$output_var" '%s' "$output_file"
  printf -v "$rc_var" '%s' "$rc"
  printf -v "$run_id_var" '%s' "$run_id"
}

echo "=== No-progress circuit breaker (issue #212) ==="

fail_log=
fail_rc=
fail_run_id=
empty_log=
empty_rc=
empty_run_id=
reset_rc=
reset_run_id=
url_rc=
url_run_id=
local_rc=
local_run_id=

echo ""
echo "Test 1: repeated non-zero short output aborts before safety cap"
run_focus_case "fail-short" "fail-short" fail_log fail_rc fail_run_id
fail_summary="$SCRIPT_DIR/logs/$fail_run_id/summary.json"
assert_nonzero "non-zero short output exits non-zero" "$fail_rc"
assert_not_contains "non-zero short output does not hit safety cap" "Hit safety cap" "$fail_log"
assert_not_contains "non-zero short output does not run iteration 20" "Iteration 20" "$fail_log"
assert_file_exists "non-zero short output writes no-progress sentinel" "$SCRIPT_DIR/logs/$fail_run_id/.agent-no-progress-abort"
assert_eq "non-zero short output stopped_reason" "agent-no-progress" "$(jq -r '.stopped_reason' "$fail_summary" 2>/dev/null || printf missing)"
assert_eq "non-zero short output records agent-no-progress lens" "1" "$(jq '[.lenses[] | select(.status == "agent-no-progress")] | length' "$fail_summary" 2>/dev/null || printf 0)"
assert_eq "non-zero short output aborts after configured limit" "3" "$(jq '[.lenses[] | select(.status == "agent-no-progress") | .iterations] | .[0]' "$fail_summary" 2>/dev/null || printf null)"
failed_lens="$(jq -r '[.lenses[] | select(.status == "agent-no-progress")] | .[0] | "\(.domain)/\(.lens)"' "$fail_summary" 2>/dev/null || true)"
if [[ -n "$failed_lens" && "$failed_lens" != "null/null" ]]; then
  if grep -qxF "$failed_lens" "$SCRIPT_DIR/logs/$fail_run_id/.completed" 2>/dev/null; then
    TOTAL=$((TOTAL + 1))
    fail_with "no-progress lens is resumable" "$failed_lens was marked completed"
  else
    TOTAL=$((TOTAL + 1))
    pass_with "no-progress lens is resumable"
  fi
else
  TOTAL=$((TOTAL + 1))
  fail_with "no-progress lens is resumable" "No agent-no-progress lens recorded"
fi

echo ""
echo "Test 2: repeated rc=0 near-empty output also aborts"
run_focus_case "empty-success" "empty-success" empty_log empty_rc empty_run_id
empty_summary="$SCRIPT_DIR/logs/$empty_run_id/summary.json"
assert_nonzero "near-empty success output exits non-zero" "$empty_rc"
assert_not_contains "near-empty success output does not hit safety cap" "Hit safety cap" "$empty_log"
assert_file_exists "near-empty success output writes no-progress sentinel" "$SCRIPT_DIR/logs/$empty_run_id/.agent-no-progress-abort"
assert_eq "near-empty success output stopped_reason" "agent-no-progress" "$(jq -r '.stopped_reason' "$empty_summary" 2>/dev/null || printf missing)"
assert_eq "near-empty success output records configured iterations" "3" "$(jq '[.lenses[] | select(.status == "agent-no-progress") | .iterations] | .[0]' "$empty_summary" 2>/dev/null || printf null)"

echo ""
echo "Test 3: meaningful progress resets the degraded streak"
run_focus_case "reset-then-done" "reset-then-done" reset_log reset_rc reset_run_id
reset_summary="$SCRIPT_DIR/logs/$reset_run_id/summary.json"
assert_zero "progress reset run completes" "$reset_rc"
assert_file_missing "progress reset does not write no-progress sentinel" "$SCRIPT_DIR/logs/$reset_run_id/.agent-no-progress-abort"
assert_eq "progress reset stopped_reason remains null" "null" "$(jq -r '.stopped_reason' "$reset_summary" 2>/dev/null || printf missing)"
assert_eq "progress reset records no agent-no-progress lenses" "0" "$(jq '[.lenses[] | select(.status == "agent-no-progress")] | length' "$reset_summary" 2>/dev/null || printf 0)"

echo ""
echo "Test 4: issue URLs count as progress even when the agent exits non-zero"
run_focus_case "issue-url" "issue-url-then-done" url_log url_rc url_run_id
url_summary="$SCRIPT_DIR/logs/$url_run_id/summary.json"
assert_zero "issue URL run completes" "$url_rc"
assert_file_missing "issue URL progress does not write no-progress sentinel" "$SCRIPT_DIR/logs/$url_run_id/.agent-no-progress-abort"
assert_eq "issue URL progress stopped_reason remains null" "null" "$(jq -r '.stopped_reason' "$url_summary" 2>/dev/null || printf missing)"
assert_eq "issue URL progress records no agent-no-progress lenses" "0" "$(jq '[.lenses[] | select(.status == "agent-no-progress")] | length' "$url_summary" 2>/dev/null || printf 0)"

echo ""
echo "Test 5: local finding files count as progress even when output is short"
run_focus_case "local-finding" "local-finding-then-done" local_log local_rc local_run_id
local_summary="$SCRIPT_DIR/logs/$local_run_id/summary.json"
assert_zero "local finding progress run completes" "$local_rc"
assert_file_missing "local finding progress does not write no-progress sentinel" "$SCRIPT_DIR/logs/$local_run_id/.agent-no-progress-abort"
assert_eq "local finding progress stopped_reason remains null" "null" "$(jq -r '.stopped_reason' "$local_summary" 2>/dev/null || printf missing)"
assert_eq "local finding progress records no agent-no-progress lenses" "0" "$(jq '[.lenses[] | select(.status == "agent-no-progress")] | length' "$local_summary" 2>/dev/null || printf 0)"
assert_eq "local finding progress records created findings" "3" "$(jq '[.lenses[] | select(.domain == "i18n" and .lens == "i18n-strings" and .status == "completed") | .issues_created] | .[0]' "$local_summary" 2>/dev/null || printf null)"

echo ""
echo "Test 6: resume clears stale no-progress run state and retries the failed lens"
resume_run_id="test-no-progress-resume-$RANDOM"
resume_dir="$SCRIPT_DIR/logs/$resume_run_id"
CREATED_RUNS+=("$resume_run_id")
mkdir -p "$resume_dir/rounds/round-1" "$resume_dir/output/i18n/i18n-strings"
printf 'i18n/i18n-formatting\n' > "$resume_dir/.completed"
printf '{"run_id":"%s","rounds_total":1,"total_lenses":2,"lens_list":["i18n/i18n-strings","i18n/i18n-formatting"]}\n' "$resume_run_id" > "$resume_dir/rounds/round-1/metadata.json"
printf '{"run_id":"%s","project_path":"","mode":"audit","agent":"codex","started_at":"2026-05-14T00:00:00Z","completed_at":null,"stopped_reason":"agent-no-progress","lenses":[{"domain":"i18n","lens":"i18n-strings","iterations":3,"status":"agent-no-progress","issues_created":0,"rate_limit_sleep_seconds":0}],"totals":{"lenses_run":1,"iterations_total":3,"issues_created":0}}\n' "$resume_run_id" > "$resume_dir/summary.json"
: > "$resume_dir/.agent-no-progress-abort"
resume_case="$TMPDIR/resume"
mkdir -p "$resume_case"
create_project "$resume_case/project"
install_fake_codex "$resume_case/bin"
resume_log="$resume_case/run.log"
FAKE_AGENT_MODE="done" \
FAKE_AGENT_STATE_DIR="$resume_case/state" \
PATH="$resume_case/bin:$PATH" \
bash "$SCRIPT_DIR/repolens.sh" \
  --project "$resume_case/project" \
  --agent codex \
  --domain i18n \
  --mode audit \
  --depth 1 \
  --resume "$resume_run_id" \
  --local \
  --yes \
  >"$resume_log" 2>&1
resume_rc=$?
assert_zero "resume after no-progress succeeds" "$resume_rc"
assert_file_missing "resume removes stale no-progress sentinel" "$resume_dir/.agent-no-progress-abort"
assert_eq "resume clears stale stopped_reason" "null" "$(jq -r '.stopped_reason' "$resume_dir/summary.json" 2>/dev/null || printf missing)"
assert_contains "resume marks retried lens completed" "i18n/i18n-strings" "$resume_dir/.completed"
assert_eq "resume appends completed retry result" "1" "$(jq '[.lenses[] | select(.domain == "i18n" and .lens == "i18n-strings" and .status == "completed")] | length' "$resume_dir/summary.json" 2>/dev/null || printf 0)"

echo ""
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
