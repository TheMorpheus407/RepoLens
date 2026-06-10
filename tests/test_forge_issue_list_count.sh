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

# Tests for issue #60 - forge_issue_list_count wrapper.
#
# Behavioral contract:
#   - lib/forge.sh exports forge_issue_list_count <owner/repo> <label>.
#   - The gh branch counts open issues through `gh issue list ... --json number`
#     and prints the integer count on stdout.
#   - gh/jq failures and unsupported providers print nothing to stdout and
#     return non-zero so callers do not collapse "unknown" into "0".
#   - tea is implemented by issue #61 with the same count/failure contract;
#     fj is implemented by issue #62 through host-scoped `fj issue search`
#     output parsing.
#   - No direct `gh issue list` command remains in lib/streak.sh.
#
# Forge calls are PATH-shadowed with fake stubs. No real forge call is
# made, and no agent command is invoked.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
TOTAL=0
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

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
    echo "  FAIL: $desc (expected to contain '$needle'; got '${haystack:0:200}')"
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
    echo "  FAIL: $desc (did not expect to contain '$needle'; got '${haystack:0:200}')"
  fi
}

assert_rc_zero() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -eq 0 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (expected rc=0, got rc=$actual)"
  fi
}

assert_rc_nonzero() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -ne 0 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (expected non-zero rc, got 0)"
  fi
}

assert_log_empty() {
  local desc="$1" log_file="$2"
  TOTAL=$((TOTAL + 1))
  if [[ ! -s "$log_file" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (expected no gh invocation, got '$(cat "$log_file")')"
  fi
}

echo ""
echo "=== Test Suite: forge_issue_list_count (issue #60) ==="
echo ""

[[ -f "$SCRIPT_DIR/lib/forge.sh" ]] || { echo "FAIL: lib/forge.sh missing"; exit 1; }
[[ -f "$SCRIPT_DIR/lib/core.sh" ]]  || { echo "FAIL: lib/core.sh missing"; exit 1; }
[[ -f "$SCRIPT_DIR/lib/streak.sh" ]] || { echo "FAIL: lib/streak.sh missing"; exit 1; }

FAKE_BIN="$TMPDIR/bin"
FORGE_TEST_PROJECT="$TMPDIR/audited-project"
mkdir -p "$FAKE_BIN"
mkdir -p "$FORGE_TEST_PROJECT"
FORGE_PROJECT_PATH="$FORGE_TEST_PROJECT"
FORGE_REMOTE_NAME="origin"
cat > "$FAKE_BIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${REPOLENS_FAKE_GH_LOG:-/dev/null}"
if [[ -n "${REPOLENS_FAKE_GH_STDERR+x}" ]]; then
  printf '%s\n' "$REPOLENS_FAKE_GH_STDERR" >&2
fi
if [[ -n "${REPOLENS_FAKE_GH_STDOUT+x}" ]]; then
  printf '%s\n' "$REPOLENS_FAKE_GH_STDOUT"
fi
exit "${REPOLENS_FAKE_GH_RC:-0}"
SH
chmod +x "$FAKE_BIN/gh"

cat > "$FAKE_BIN/tea" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${REPOLENS_FAKE_TEA_LOG:-/dev/null}"
if [[ -n "${REPOLENS_FAKE_TEA_STDERR+x}" ]]; then
  printf '%s\n' "$REPOLENS_FAKE_TEA_STDERR" >&2
fi
if [[ -n "${REPOLENS_FAKE_TEA_STDOUT+x}" ]]; then
  printf '%s\n' "$REPOLENS_FAKE_TEA_STDOUT"
fi
exit "${REPOLENS_FAKE_TEA_RC:-0}"
SH
chmod +x "$FAKE_BIN/tea"

cat > "$FAKE_BIN/fj" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${REPOLENS_FAKE_FJ_LOG:-/dev/null}"
previous=""
for arg in "$@"; do
  if [[ "$previous" == "--style" && "$arg" == "json" ]]; then
    printf "error: invalid value 'json' for '--style <STYLE>'\n" >&2
    exit 2
  fi
  previous="$arg"
done
if [[ -n "${REPOLENS_FAKE_FJ_STDERR+x}" ]]; then
  printf '%s\n' "$REPOLENS_FAKE_FJ_STDERR" >&2
fi
if [[ -n "${REPOLENS_FAKE_FJ_STDOUT+x}" ]]; then
  printf '%s\n' "$REPOLENS_FAKE_FJ_STDOUT"
fi
exit "${REPOLENS_FAKE_FJ_RC:-0}"
SH
chmod +x "$FAKE_BIN/fj"

# Environment exports are intentionally local to wrapper subshells.
# shellcheck disable=SC2030,SC2031
run_wrapper() {
  local provider="$1"; shift
  local fn="$1"; shift
  (
    export PATH="$FAKE_BIN:/usr/bin:/bin:$PATH"
    export FORGE_PROVIDER="$provider"
    [[ -n "${FORGE_PROJECT_PATH+x}" ]] && export FORGE_PROJECT_PATH
    [[ -n "${FORGE_REMOTE_NAME+x}" ]] && export FORGE_REMOTE_NAME
    [[ -n "${FORGE_TEA_LOGIN+x}" ]] && export FORGE_TEA_LOGIN
    [[ -n "${FORGE_HOST+x}" ]] && export FORGE_HOST
    [[ -n "${REPOLENS_FAKE_GH_RC+x}" ]] && export REPOLENS_FAKE_GH_RC
    [[ -n "${REPOLENS_FAKE_GH_LOG+x}" ]] && export REPOLENS_FAKE_GH_LOG
    [[ -n "${REPOLENS_FAKE_GH_STDOUT+x}" ]] && export REPOLENS_FAKE_GH_STDOUT
    [[ -n "${REPOLENS_FAKE_GH_STDERR+x}" ]] && export REPOLENS_FAKE_GH_STDERR
    [[ -n "${REPOLENS_FAKE_TEA_RC+x}" ]] && export REPOLENS_FAKE_TEA_RC
    [[ -n "${REPOLENS_FAKE_TEA_LOG+x}" ]] && export REPOLENS_FAKE_TEA_LOG
    [[ -n "${REPOLENS_FAKE_TEA_STDOUT+x}" ]] && export REPOLENS_FAKE_TEA_STDOUT
    [[ -n "${REPOLENS_FAKE_TEA_STDERR+x}" ]] && export REPOLENS_FAKE_TEA_STDERR
    [[ -n "${REPOLENS_FAKE_FJ_RC+x}" ]] && export REPOLENS_FAKE_FJ_RC
    [[ -n "${REPOLENS_FAKE_FJ_LOG+x}" ]] && export REPOLENS_FAKE_FJ_LOG
    [[ -n "${REPOLENS_FAKE_FJ_STDOUT+x}" ]] && export REPOLENS_FAKE_FJ_STDOUT
    [[ -n "${REPOLENS_FAKE_FJ_STDERR+x}" ]] && export REPOLENS_FAKE_FJ_STDERR
    set -uo pipefail
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib/core.sh"
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib/forge.sh"
    "$fn" "$@"
  )
}

# Environment exports are intentionally local to wrapper subshells.
# shellcheck disable=SC2030,SC2031
run_wrapper_with_return_marker() {
  local provider="$1"; shift
  local fn="$1"; shift
  (
    export PATH="$FAKE_BIN:/usr/bin:/bin:$PATH"
    export FORGE_PROVIDER="$provider"
    [[ -n "${FORGE_PROJECT_PATH+x}" ]] && export FORGE_PROJECT_PATH
    [[ -n "${FORGE_REMOTE_NAME+x}" ]] && export FORGE_REMOTE_NAME
    [[ -n "${FORGE_TEA_LOGIN+x}" ]] && export FORGE_TEA_LOGIN
    [[ -n "${FORGE_HOST+x}" ]] && export FORGE_HOST
    [[ -n "${REPOLENS_FAKE_GH_LOG+x}" ]] && export REPOLENS_FAKE_GH_LOG
    [[ -n "${REPOLENS_FAKE_TEA_LOG+x}" ]] && export REPOLENS_FAKE_TEA_LOG
    [[ -n "${REPOLENS_FAKE_FJ_LOG+x}" ]] && export REPOLENS_FAKE_FJ_LOG
    set -uo pipefail
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib/core.sh"
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib/forge.sh"
    "$fn" "$@"
    local wrapper_rc=$?
    printf '__WRAPPER_RETURNED_RC=%s\n' "$wrapper_rc" >&2
    exit "$wrapper_rc"
  )
}

reset_fake_gh() {
  unset REPOLENS_FAKE_GH_RC REPOLENS_FAKE_GH_LOG
  unset REPOLENS_FAKE_GH_STDOUT REPOLENS_FAKE_GH_STDERR
}

reset_fake_tea() {
  unset REPOLENS_FAKE_TEA_RC REPOLENS_FAKE_TEA_LOG
  unset REPOLENS_FAKE_TEA_STDOUT REPOLENS_FAKE_TEA_STDERR
}

reset_fake_fj() {
  unset REPOLENS_FAKE_FJ_RC REPOLENS_FAKE_FJ_LOG
  unset REPOLENS_FAKE_FJ_STDOUT REPOLENS_FAKE_FJ_STDERR
}

# ---------------------------------------------------------------------------
# Group 1: gh success path
# ---------------------------------------------------------------------------
echo "--- Group 1: gh success path ---"
echo ""

echo "Test 1: gh returns [] -> wrapper prints 0 and exits 0"
reset_fake_gh
REPOLENS_FAKE_GH_RC=0
REPOLENS_FAKE_GH_STDOUT='[]'
err_file="$TMPDIR/t1.err"
out="$(run_wrapper gh forge_issue_list_count owner/repo audit:demo 2>"$err_file")"
rc=$?
err="$(cat "$err_file")"
assert_rc_zero "empty array is a successful count" "$rc"
assert_eq "stdout is 0 for legitimately zero open issues" "0" "$out"
assert_eq "stderr is empty on success" "" "$err"

echo ""
echo "Test 2: gh returns two issues -> wrapper prints 2 and exits 0"
reset_fake_gh
REPOLENS_FAKE_GH_RC=0
REPOLENS_FAKE_GH_STDOUT='[{"number":1},{"number":2}]'
err_file="$TMPDIR/t2.err"
out="$(run_wrapper gh forge_issue_list_count owner/repo audit:demo 2>"$err_file")"
rc=$?
assert_rc_zero "two-item array is a successful count" "$rc"
assert_eq "stdout is 2 for two open issues" "2" "$out"
assert_eq "stderr is empty on success" "" "$(cat "$err_file")"

echo ""
echo "Test 3: gh branch composes the expected issue-list argv"
reset_fake_gh
gh_log="$TMPDIR/t3-gh.log"
: > "$gh_log"
REPOLENS_FAKE_GH_RC=0
REPOLENS_FAKE_GH_STDOUT='[{"number":99}]'
REPOLENS_FAKE_GH_LOG="$gh_log"
out="$(run_wrapper gh forge_issue_list_count owner/repo audit:demo 2>/dev/null)"
rc=$?
logged="$(cat "$gh_log")"
assert_rc_zero "argv-contract call succeeds" "$rc"
assert_eq "stdout still reflects jq length" "1" "$out"
assert_contains "gh receives 'issue list'" "issue list" "$logged"
assert_contains "gh receives repo selector" "-R owner/repo" "$logged"
assert_contains "gh receives label selector" "--label audit:demo" "$logged"
assert_contains "gh limits to open issues" "--state open" "$logged"
assert_contains "gh keeps the 1000 issue limit" "--limit 1000" "$logged"
assert_contains "gh requests number JSON field" "--json number" "$logged"

# ---------------------------------------------------------------------------
# Group 2: gh failure semantics
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 2: gh failure semantics ---"
echo ""

echo "Test 4: gh exits non-zero -> wrapper returns non-zero with empty stdout and warning"
reset_fake_gh
REPOLENS_FAKE_GH_RC=1
REPOLENS_FAKE_GH_STDERR='HTTP 403: API rate limit exceeded'
err_file="$TMPDIR/t4.err"
out="$(run_wrapper gh forge_issue_list_count owner/repo audit:demo 2>"$err_file")"
rc=$?
stderr_content="$(cat "$err_file")"
assert_rc_nonzero "gh failure is observable to caller" "$rc"
assert_eq "stdout is empty on gh failure" "" "$out"
assert_contains "warning mentions the repo" "owner/repo" "$stderr_content"
assert_contains "warning mentions gh failed" "gh failed" "$stderr_content"

echo ""
echo "Test 5: gh exits 0 with non-JSON stdout -> wrapper returns non-zero with empty stdout"
reset_fake_gh
REPOLENS_FAKE_GH_RC=0
REPOLENS_FAKE_GH_STDOUT='not json'
out="$(run_wrapper gh forge_issue_list_count owner/repo audit:demo 2>/dev/null)"
rc=$?
assert_rc_nonzero "bad JSON is observable to caller" "$rc"
assert_eq "stdout is empty on jq parse failure" "" "$out"

echo ""
echo "Test 5b: jq exits 0 with non-integer output -> wrapper returns non-zero with empty stdout"
reset_fake_gh
cat > "$FAKE_BIN/jq" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' not-a-number
exit 0
SH
chmod +x "$FAKE_BIN/jq"
REPOLENS_FAKE_GH_RC=0
REPOLENS_FAKE_GH_STDOUT='[{"number":1}]'
err_file="$TMPDIR/t5b.err"
out="$(run_wrapper gh forge_issue_list_count owner/repo audit:demo 2>"$err_file")"
rc=$?
rm -f "$FAKE_BIN/jq"
assert_rc_nonzero "non-integer jq output is observable to caller" "$rc"
assert_eq "stdout is empty on unexpected jq output" "" "$out"
assert_contains "warning mentions unexpected non-integer" "unexpected non-integer" "$(cat "$err_file")"

echo ""
echo "Test 5c: mktemp failure preserves gh failure semantics"
reset_fake_gh
cat > "$FAKE_BIN/mktemp" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$FAKE_BIN/mktemp"
REPOLENS_FAKE_GH_RC=9
REPOLENS_FAKE_GH_STDERR='hidden because stderr is discarded without mktemp'
err_file="$TMPDIR/t5c.err"
out="$(run_wrapper gh forge_issue_list_count owner/repo audit:demo 2>"$err_file")"
rc=$?
rm -f "$FAKE_BIN/mktemp"
stderr_content="$(cat "$err_file")"
assert_rc_nonzero "gh failure remains observable when mktemp fails" "$rc"
assert_eq "stdout is empty when gh fails without an error tempfile" "" "$out"
assert_contains "warning still mentions gh failed" "gh failed" "$stderr_content"
assert_contains "warning records empty captured stderr" "err=<empty>" "$stderr_content"

echo ""
echo "Test 6: canonical caller pattern observes wrapper failure"
reset_fake_gh
REPOLENS_FAKE_GH_RC=2
REPOLENS_FAKE_GH_STDERR='boom'
caller_saw_failure=false
caller_var=""
if ! caller_var="$(run_wrapper gh forge_issue_list_count owner/repo audit:demo 2>/dev/null)"; then
  caller_saw_failure=true
fi
TOTAL=$((TOTAL + 1))
if $caller_saw_failure; then
  PASS=$((PASS + 1))
  echo "  PASS: caller's if-guard observed the failure"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: caller's if-guard did not observe the failure"
fi
assert_eq "caller variable stays empty on failure" "" "$caller_var"

echo ""
echo "Test 7: canonical caller pattern captures count on success"
reset_fake_gh
REPOLENS_FAKE_GH_RC=0
REPOLENS_FAKE_GH_STDOUT='[{"number":7},{"number":8},{"number":9}]'
caller_var=""
caller_rc=0
if ! caller_var="$(run_wrapper gh forge_issue_list_count owner/repo audit:demo 2>/dev/null)"; then
  caller_rc=1
fi
assert_rc_zero "caller rc remains 0 on success" "$caller_rc"
assert_eq "caller variable contains the integer count" "3" "$caller_var"

# ---------------------------------------------------------------------------
# Group 3: provider dispatch and argument guards
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 3: provider dispatch and argument guards ---"
echo ""

echo "Test 8: tea backend counts open issues with the expected issue-list argv"
reset_fake_gh
reset_fake_tea
tea_log="$TMPDIR/t8-tea.log"
: > "$tea_log"
REPOLENS_FAKE_TEA_RC=0
REPOLENS_FAKE_TEA_STDOUT='[{"number":1},{"number":2}]'
REPOLENS_FAKE_TEA_LOG="$tea_log"
out="$(run_wrapper tea forge_issue_list_count owner/repo audit:demo 2>/dev/null)"
rc=$?
logged="$(cat "$tea_log")"
assert_rc_zero "tea branch exits zero on successful JSON count" "$rc"
assert_eq "tea branch prints jq length" "2" "$out"
assert_eq "tea branch passes supported issue-list flags in order" \
  "issues list --repo $FORGE_TEST_PROJECT --remote origin --labels audit:demo --state open --limit 1000 --output json" "$logged"

echo ""
echo "Test 9: fj backend counts open issues with official minimal issue-search output"
reset_fake_gh
reset_fake_fj
fj_log="$TMPDIR/t9-fj.log"
: > "$fj_log"
FORGE_HOST=codeberg.org
REPOLENS_FAKE_FJ_RC=0
# Official forgejo-cli rejects `--style json`; the wrapper must use minimal
# output and parse the leading text count.
REPOLENS_FAKE_FJ_STDOUT='2 issues'
REPOLENS_FAKE_FJ_LOG="$fj_log"
out="$(run_wrapper fj forge_issue_list_count owner/repo audit:demo 2>/dev/null)"
rc=$?
logged="$(cat "$fj_log")"
assert_rc_zero "fj branch exits zero on successful issue-search count" "$rc"
assert_eq "fj branch prints the minimal-output count" "2" "$out"
assert_eq "fj branch passes official-compatible issue-search flags in order" \
  "-H codeberg.org --style minimal issue search --repo owner/repo --labels audit:demo --state open" "$logged"

echo ""
echo "Test 10: empty FORGE_PROVIDER returns non-zero without invoking a forge CLI"
reset_fake_gh
reset_fake_tea
reset_fake_fj
gh_log="$TMPDIR/t10-gh.log"
tea_log="$TMPDIR/t10-tea.log"
fj_log="$TMPDIR/t10-fj.log"
: > "$gh_log"
: > "$tea_log"
: > "$fj_log"
REPOLENS_FAKE_GH_LOG="$gh_log"
REPOLENS_FAKE_TEA_LOG="$tea_log"
REPOLENS_FAKE_FJ_LOG="$fj_log"
err_file="$TMPDIR/t10.err"
out="$(run_wrapper_with_return_marker "" forge_issue_list_count owner/repo audit:demo 2>"$err_file")"
rc=$?
err="$(cat "$err_file")"
assert_rc_nonzero "empty provider failure is observable to caller" "$rc"
assert_eq "stdout is empty for empty provider" "" "$out"
assert_contains "warning reports unknown provider" "unknown provider" "$err"
assert_contains "empty provider returns instead of exiting the shell" "__WRAPPER_RETURNED_RC=1" "$err"
assert_log_empty "empty provider does not call gh" "$gh_log"
assert_log_empty "empty provider does not call tea" "$tea_log"
assert_log_empty "empty provider does not call fj" "$fj_log"

echo ""
echo "Test 10b: unknown FORGE_PROVIDER returns non-zero without invoking a forge CLI"
reset_fake_gh
reset_fake_tea
reset_fake_fj
gh_log="$TMPDIR/t10b-gh.log"
tea_log="$TMPDIR/t10b-tea.log"
fj_log="$TMPDIR/t10b-fj.log"
: > "$gh_log"
: > "$tea_log"
: > "$fj_log"
REPOLENS_FAKE_GH_LOG="$gh_log"
REPOLENS_FAKE_TEA_LOG="$tea_log"
REPOLENS_FAKE_FJ_LOG="$fj_log"
err_file="$TMPDIR/t10b.err"
out="$(run_wrapper_with_return_marker unknown forge_issue_list_count owner/repo audit:demo 2>"$err_file")"
rc=$?
err="$(cat "$err_file")"
assert_rc_nonzero "unknown provider failure is observable to caller" "$rc"
assert_eq "stdout is empty for unknown provider" "" "$out"
assert_contains "warning includes provider value" "unknown provider 'unknown'" "$err"
assert_contains "unknown provider returns instead of exiting the shell" "__WRAPPER_RETURNED_RC=1" "$err"
assert_log_empty "unknown provider does not call gh" "$gh_log"
assert_log_empty "unknown provider does not call tea" "$tea_log"
assert_log_empty "unknown provider does not call fj" "$fj_log"

echo ""
echo "Test 11: missing repo argument dies before invoking gh"
reset_fake_gh
gh_log="$TMPDIR/t11-gh.log"
: > "$gh_log"
REPOLENS_FAKE_GH_LOG="$gh_log"
out="$(run_wrapper gh forge_issue_list_count "" audit:demo 2>&1)"
rc=$?
assert_rc_nonzero "missing repo exits non-zero" "$rc"
assert_contains "missing repo reports missing argument" "missing argument" "$out"
assert_log_empty "missing repo does not call gh" "$gh_log"

echo ""
echo "Test 12: missing label argument dies before invoking gh"
reset_fake_gh
gh_log="$TMPDIR/t12-gh.log"
: > "$gh_log"
REPOLENS_FAKE_GH_LOG="$gh_log"
out="$(run_wrapper gh forge_issue_list_count owner/repo "" 2>&1)"
rc=$?
assert_rc_nonzero "missing label exits non-zero" "$rc"
assert_contains "missing label reports missing argument" "missing argument" "$out"
assert_log_empty "missing label does not call gh" "$gh_log"

# ---------------------------------------------------------------------------
# Group 4: open issue backlog snapshot for greenfield planning
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 4: open issue backlog snapshot for greenfield planning ---"
echo ""

echo "Test 12a: gh open backlog snapshot lists all open issues without label filtering"
reset_fake_gh
gh_log="$TMPDIR/t12a-gh.log"
err_file="$TMPDIR/t12a.err"
: > "$gh_log"
REPOLENS_FAKE_GH_RC=0
REPOLENS_FAKE_GH_LOG="$gh_log"
REPOLENS_FAKE_GH_STDOUT='[
  {"number":2,"title":"Second backlog","body":"Second body","labels":[{"name":"beta"}],"url":"https://github.com/owner/repo/issues/2"},
  {"number":1,"title":"First backlog","body":"First body\nwith whitespace","labels":[{"name":"alpha"},{"name":"greenfield"}],"url":"https://github.com/owner/repo/issues/1"}
]'
out="$(run_wrapper gh forge_open_issue_backlog_snapshot owner/repo 2>"$err_file")"
rc=$?
logged="$(cat "$gh_log")"
assert_rc_zero "gh open backlog snapshot succeeds" "$rc"
assert_eq "stderr is empty on gh backlog success" "" "$(cat "$err_file")"
assert_contains "gh backlog snapshot includes first issue title" "### Open issue #1: First backlog" "$out"
assert_contains "gh backlog snapshot includes normalized body excerpt" "First body with whitespace" "$out"
assert_contains "gh backlog snapshot includes label names" "- Labels: alpha, greenfield" "$out"
assert_contains "gh backlog snapshot includes URL" "- URL: https://github.com/owner/repo/issues/1" "$out"
assert_contains "gh backlog lists open issues" "--state open" "$logged"
assert_contains "gh backlog uses the 1000 issue limit" "--limit 1000" "$logged"
assert_contains "gh backlog requests planning fields" "--json number,title,body,labels,url" "$logged"
assert_not_contains "gh open backlog snapshot is not lens-label filtered" "--label" "$logged"

echo ""
echo "Test 12b: tea open backlog snapshot uses provider target binding and body fields"
reset_fake_tea
tea_log="$TMPDIR/t12b-tea.log"
err_file="$TMPDIR/t12b.err"
: > "$tea_log"
REPOLENS_FAKE_TEA_RC=0
REPOLENS_FAKE_TEA_LOG="$tea_log"
REPOLENS_FAKE_TEA_STDOUT='{"issues":[{"index":7,"title":"Tea backlog","description":"Tea body","labels":["product","planning"],"html_url":"https://gitea.example/owner/repo/issues/7"}]}'
out="$(run_wrapper tea forge_open_issue_backlog_snapshot owner/repo 2>"$err_file")"
rc=$?
logged="$(cat "$tea_log")"
assert_rc_zero "tea open backlog snapshot succeeds" "$rc"
assert_eq "stderr is empty on tea backlog success" "" "$(cat "$err_file")"
assert_contains "tea backlog snapshot uses index as issue number" "### Open issue #7: Tea backlog" "$out"
assert_contains "tea backlog snapshot includes description body" "- Body excerpt: Tea body" "$out"
assert_contains "tea backlog snapshot includes string labels" "- Labels: product, planning" "$out"
assert_eq "tea backlog passes supported issue-list flags without labels" \
  "issues list --repo $FORGE_TEST_PROJECT --remote origin --state open --limit 1000 --output json" "$logged"

echo ""
echo "Test 12c: fj open backlog snapshot does not pass invalid JSON style to official fj"
reset_fake_fj
fj_log="$TMPDIR/t12c-fj.log"
err_file="$TMPDIR/t12c.err"
: > "$fj_log"
FORGE_HOST=codeberg.org
REPOLENS_FAKE_FJ_RC=0
REPOLENS_FAKE_FJ_LOG="$fj_log"
REPOLENS_FAKE_FJ_STDOUT=$'1 issue\n#9 FJ backlog'
out="$(run_wrapper fj forge_open_issue_backlog_snapshot owner/repo 2>"$err_file")"
rc=$?
logged="$(cat "$fj_log")"
assert_rc_nonzero "official fj backlog snapshot fails cleanly when JSON output is unavailable" "$rc"
assert_eq "stdout is empty when official fj backlog output is not machine-parseable" "" "$out"
assert_contains "warning identifies the backlog snapshot function" \
  "forge_open_issue_backlog_snapshot" "$(cat "$err_file")"
assert_eq "fj backlog snapshot uses official minimal issue search" \
  "-H codeberg.org --style minimal issue search --repo owner/repo --state open" "$logged"
assert_not_contains "fj backlog snapshot never asks official fj for invalid JSON style" \
  "--style json" "$logged"

echo ""
echo "Test 12d: malformed open backlog JSON fails without a misleading empty snapshot"
reset_fake_gh
err_file="$TMPDIR/t12d.err"
REPOLENS_FAKE_GH_RC=0
REPOLENS_FAKE_GH_STDOUT='not json'
out="$(run_wrapper gh forge_open_issue_backlog_snapshot owner/repo 2>"$err_file")"
rc=$?
assert_rc_nonzero "malformed backlog JSON is observable to caller" "$rc"
assert_eq "stdout is empty on malformed backlog JSON" "" "$out"
assert_contains "warning reports backlog JSON parse failure" "jq failed to parse issue list" "$(cat "$err_file")"

# ---------------------------------------------------------------------------
# Group 5: acceptance regression guard
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 5: acceptance regression guard ---"
echo ""

echo "Test 13: lib/streak.sh contains no direct 'gh issue list' call"
TOTAL=$((TOTAL + 1))
if grep -nE '\bgh issue list\b' "$SCRIPT_DIR/lib/streak.sh" >/dev/null 2>&1; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: direct 'gh issue list' call still present in lib/streak.sh"
  grep -nE '\bgh issue list\b' "$SCRIPT_DIR/lib/streak.sh" | sed 's/^/    /'
else
  PASS=$((PASS + 1))
  echo "  PASS: no direct 'gh issue list' call remains in lib/streak.sh"
fi

echo ""
echo "Test 14: repolens.sh uses forge_issue_list_count at the issue-count call sites"
legacy_refs="$(grep -nF 'count_repo_issues' "$SCRIPT_DIR/repolens.sh" 2>/dev/null || true)"
forge_call_count="$(grep -cF 'forge_issue_list_count "$FORGE_REPO_SLUG" "$lens_label"' "$SCRIPT_DIR/repolens.sh" 2>/dev/null || true)"
forge_context_count="$(grep -cF 'FORGE_PROJECT_PATH="$PROJECT_PATH"' "$SCRIPT_DIR/repolens.sh" 2>/dev/null || true)"
TOTAL=$((TOTAL + 1))
if [[ -z "$legacy_refs" && "$forge_call_count" -eq 2 && "$forge_context_count" -ge 1 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: runtime issue-count call sites use forge_issue_list_count with project context available"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: expected two forge_issue_list_count call sites, project context, and no count_repo_issues references"
  [[ -n "$legacy_refs" ]] && printf '%s\n' "$legacy_refs" | sed 's/^/    legacy: /'
  echo "    forge_issue_list_count call count: $forge_call_count"
  echo "    FORGE_PROJECT_PATH assignment count: $forge_context_count"
fi

echo ""
echo "Test 15: repolens.sh label bootstrap uses the canonical forge repo slug"
label_bootstrap_count="$(grep -cF 'forge_label_bootstrap "$FORGE_REPO_SLUG" "$label_set_file"' "$SCRIPT_DIR/repolens.sh" 2>/dev/null || true)"
legacy_label_bootstrap_count="$(grep -cF 'forge_label_bootstrap "$REPO_OWNER/$REPO_NAME" "$label_set_file"' "$SCRIPT_DIR/repolens.sh" 2>/dev/null || true)"
TOTAL=$((TOTAL + 1))
if [[ "$label_bootstrap_count" -eq 1 && "$legacy_label_bootstrap_count" -eq 0 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: label bootstrap uses FORGE_REPO_SLUG"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: expected label bootstrap to use FORGE_REPO_SLUG exactly once and never REPO_OWNER/REPO_NAME"
  echo "    FORGE_REPO_SLUG bootstrap count: $label_bootstrap_count"
  echo "    legacy bootstrap count: $legacy_label_bootstrap_count"
fi

echo ""
echo "Test 16: repolens.sh derives metadata from origin slug for renamed checkouts"
metadata_project="$TMPDIR/local-dir-metadata"
mkdir -p "$metadata_project"
git -C "$metadata_project" init -q
git -C "$metadata_project" remote add origin "https://github.com/acme/origin-repo.git"
metadata_block="$(
  awk '
    /^# --- Derive repo metadata ---$/ { in_repo_block = 1 }
    /^# --- Validate agent and dependencies ---$/ { in_repo_block = 0 }
    in_repo_block { print }
  ' "$SCRIPT_DIR/repolens.sh"
)"
metadata_result="$(
  bash -c '
    set -uo pipefail
    source "$1"
    PROJECT_PATH="$2"
    eval "$3"
    printf "REPO_OWNER=%s\nREPO_NAME=%s\nREPO_OWNER_NAME=%s/%s\nFORGE_REPO_SLUG=%s\n" \
      "$REPO_OWNER" "$REPO_NAME" "$REPO_OWNER" "$REPO_NAME" "$FORGE_REPO_SLUG"
  ' bash "$SCRIPT_DIR/lib/forge.sh" "$metadata_project" "$metadata_block" 2>"$TMPDIR/t16.err"
)"
metadata_rc=$?
assert_rc_zero "metadata block completes for renamed checkout" "$metadata_rc"
assert_contains "metadata derives REPO_OWNER from origin slug" "REPO_OWNER=acme" "$metadata_result"
assert_contains "metadata derives REPO_NAME from origin slug" "REPO_NAME=origin-repo" "$metadata_result"
assert_contains "metadata composed owner/name equals FORGE_REPO_SLUG" $'REPO_OWNER_NAME=acme/origin-repo\nFORGE_REPO_SLUG=acme/origin-repo' "$metadata_result"

echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
