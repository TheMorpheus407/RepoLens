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

# Tests for issue #163 - forge_issue_comment wrapper.
#
# Behavioral contract:
#   - lib/forge.sh exports forge_issue_comment <repo> <issue_number> <body_file>.
#   - The gh branch invokes:
#       gh issue comment <issue_number> -R <repo> --body-file <body_file>
#     and prints the resulting comment URL on stdout.
#   - Rate-limit retry: single retry on Retry-After / API rate limit stderr.
#   - tea branch posts comments via `tea issues comment ...`; smoke covered
#     below, comprehensive cases in tests/test_forge_issue_comment_tea.sh.
#   - fj branch posts comments via `fj -H $FORGE_HOST issue comment <repo>
#     <issue_number> --body-file <body_file>`; smoke covered below,
#     comprehensive cases in tests/test_forge_issue_comment_fj.sh.
#   - Missing args / unreadable body_file / unknown provider die loudly.
#
# Forge calls are PATH-shadowed with fake stubs; sleep is mocked.

# shellcheck disable=SC2034  # REPOLENS_FAKE_* vars are exported into the runner subshell by run_comment().

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
    echo "  FAIL: $desc (expected to contain '$needle'; got '${haystack:0:300}')"
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
echo "=== Test Suite: forge_issue_comment (issue #163) ==="
echo ""

[[ -f "$SCRIPT_DIR/lib/forge.sh" ]] || { echo "FAIL: lib/forge.sh missing"; exit 1; }
[[ -f "$SCRIPT_DIR/lib/core.sh" ]]  || { echo "FAIL: lib/core.sh missing"; exit 1; }

FAKE_BIN="$TMPDIR/bin"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${REPOLENS_FAKE_GH_LOG:-/dev/null}"

# Stateful comment responses (rc|stdout|stderr per attempt).
if [[ "$1" == "issue" && "$2" == "comment" ]]; then
  if [[ -n "${REPOLENS_FAKE_GH_COMMENT_COUNTER+x}" ]]; then
    n=0
    [[ -f "$REPOLENS_FAKE_GH_COMMENT_COUNTER" ]] && n="$(cat "$REPOLENS_FAKE_GH_COMMENT_COUNTER")"
    n=$((n + 1))
    printf '%s' "$n" > "$REPOLENS_FAKE_GH_COMMENT_COUNTER"
    idx=$((n - 1))
    IFS=$'\n' read -r -d '' -a responses < <(printf '%s\0' "${REPOLENS_FAKE_GH_COMMENT_RESPONSES:-}")
    if (( idx < ${#responses[@]} )); then
      triple="${responses[$idx]}"
      rc="${triple%%|*}"; rest="${triple#*|}"
      outv="${rest%%|*}"; errv="${rest#*|}"
      [[ -n "$outv" ]] && printf '%s\n' "$outv"
      [[ -n "$errv" ]] && printf '%s\n' "$errv" >&2
      exit "${rc:-0}"
    fi
  fi
  if [[ -n "${REPOLENS_FAKE_GH_COMMENT_STDERR+x}" ]]; then
    printf '%s\n' "$REPOLENS_FAKE_GH_COMMENT_STDERR" >&2
  fi
  if [[ -n "${REPOLENS_FAKE_GH_COMMENT_STDOUT+x}" ]]; then
    printf '%s\n' "$REPOLENS_FAKE_GH_COMMENT_STDOUT"
  fi
  exit "${REPOLENS_FAKE_GH_COMMENT_RC:-0}"
fi

if [[ -n "${REPOLENS_FAKE_GH_STDERR+x}" ]]; then
  printf '%s\n' "$REPOLENS_FAKE_GH_STDERR" >&2
fi
if [[ -n "${REPOLENS_FAKE_GH_STDOUT+x}" ]]; then
  printf '%s\n' "$REPOLENS_FAKE_GH_STDOUT"
fi
exit "${REPOLENS_FAKE_GH_RC:-0}"
SH
chmod +x "$FAKE_BIN/gh"

cat > "$FAKE_BIN/sleep" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${REPOLENS_FAKE_SLEEP_LOG:-/dev/null}"
exit 0
SH
chmod +x "$FAKE_BIN/sleep"

# Fake tea — minimal stub used by the smoke test that the tea arm no
# longer dies with the #61 stub.
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

# Fake fj — minimal stub used by the smoke test that the fj arm no
# longer dies with the #62 stub.
cat > "$FAKE_BIN/fj" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${REPOLENS_FAKE_FJ_LOG:-/dev/null}"
if [[ -n "${REPOLENS_FAKE_FJ_STDERR+x}" ]]; then
  printf '%s\n' "$REPOLENS_FAKE_FJ_STDERR" >&2
fi
if [[ -n "${REPOLENS_FAKE_FJ_STDOUT+x}" ]]; then
  printf '%s\n' "$REPOLENS_FAKE_FJ_STDOUT"
fi
exit "${REPOLENS_FAKE_FJ_RC:-0}"
SH
chmod +x "$FAKE_BIN/fj"

run_comment() {
  (
    export PATH="$FAKE_BIN:/usr/bin:/bin:$PATH"
    if [[ -n "${FORGE_PROVIDER_OVERRIDE+x}" ]]; then
      export FORGE_PROVIDER="$FORGE_PROVIDER_OVERRIDE"
    else
      export FORGE_PROVIDER="gh"
    fi
    [[ -n "${FORGE_HOST+x}" ]] && export FORGE_HOST
    [[ -n "${FORGE_PROJECT_PATH+x}" ]] && export FORGE_PROJECT_PATH
    [[ -n "${FORGE_REMOTE_NAME+x}" ]] && export FORGE_REMOTE_NAME
    [[ -n "${FORGE_TEA_LOGIN+x}" ]] && export FORGE_TEA_LOGIN
    for v in REPOLENS_FAKE_GH_RC REPOLENS_FAKE_GH_LOG REPOLENS_FAKE_GH_STDOUT REPOLENS_FAKE_GH_STDERR \
             REPOLENS_FAKE_GH_COMMENT_RC REPOLENS_FAKE_GH_COMMENT_STDOUT REPOLENS_FAKE_GH_COMMENT_STDERR \
             REPOLENS_FAKE_GH_COMMENT_COUNTER REPOLENS_FAKE_GH_COMMENT_RESPONSES \
             REPOLENS_FAKE_TEA_RC REPOLENS_FAKE_TEA_LOG REPOLENS_FAKE_TEA_STDOUT REPOLENS_FAKE_TEA_STDERR \
             REPOLENS_FAKE_FJ_RC REPOLENS_FAKE_FJ_LOG REPOLENS_FAKE_FJ_STDOUT REPOLENS_FAKE_FJ_STDERR \
             REPOLENS_FAKE_SLEEP_LOG; do
      [[ -n "${!v+x}" ]] && export "${v?}"
    done
    set -uo pipefail
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib/core.sh"
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib/forge.sh"
    forge_issue_comment "$@"
  )
}

reset_env() {
  unset REPOLENS_FAKE_GH_RC REPOLENS_FAKE_GH_LOG REPOLENS_FAKE_GH_STDOUT REPOLENS_FAKE_GH_STDERR
  unset REPOLENS_FAKE_GH_COMMENT_RC REPOLENS_FAKE_GH_COMMENT_STDOUT REPOLENS_FAKE_GH_COMMENT_STDERR
  unset REPOLENS_FAKE_GH_COMMENT_COUNTER REPOLENS_FAKE_GH_COMMENT_RESPONSES
  unset REPOLENS_FAKE_TEA_RC REPOLENS_FAKE_TEA_LOG REPOLENS_FAKE_TEA_STDOUT REPOLENS_FAKE_TEA_STDERR
  unset REPOLENS_FAKE_FJ_RC REPOLENS_FAKE_FJ_LOG REPOLENS_FAKE_FJ_STDOUT REPOLENS_FAKE_FJ_STDERR
  unset FORGE_PROJECT_PATH FORGE_REMOTE_NAME FORGE_TEA_LOGIN
  unset REPOLENS_FAKE_SLEEP_LOG FORGE_PROVIDER_OVERRIDE FORGE_HOST
}

body_file="$TMPDIR/body.md"
cat > "$body_file" <<'MD'
Cross-link to sibling cluster.

See related findings in #42.
MD

# ---------------------------------------------------------------------------
# Group 1: gh success path
# ---------------------------------------------------------------------------
echo "--- Group 1: gh success path ---"
echo ""

echo "Test 1: gh comment succeeds -> wrapper prints URL and exits 0"
reset_env
REPOLENS_FAKE_GH_COMMENT_RC=0
REPOLENS_FAKE_GH_COMMENT_STDOUT='https://github.com/owner/repo/issues/42#issuecomment-12345'
out="$(run_comment owner/repo 42 "$body_file" 2>/dev/null)"
rc=$?
assert_rc_zero "comment success returns 0" "$rc"
assert_eq "stdout is the comment URL" "https://github.com/owner/repo/issues/42#issuecomment-12345" "$out"

echo ""
echo "Test 2: gh comment receives expected argv"
reset_env
gh_log="$TMPDIR/t2-gh.log"
: > "$gh_log"
REPOLENS_FAKE_GH_COMMENT_RC=0
REPOLENS_FAKE_GH_COMMENT_STDOUT='https://github.com/owner/repo/issues/42#issuecomment-1'
REPOLENS_FAKE_GH_LOG="$gh_log"
out="$(run_comment owner/repo 42 "$body_file" 2>/dev/null)"
rc=$?
logged="$(cat "$gh_log")"
assert_rc_zero "argv-contract comment succeeds" "$rc"
assert_contains "gh receives 'issue comment'" "issue comment" "$logged"
assert_contains "gh comment receives issue number positional" "issue comment 42" "$logged"
assert_contains "gh comment receives -R repo" "-R owner/repo" "$logged"
assert_contains "gh comment receives --body-file" "--body-file $body_file" "$logged"

# ---------------------------------------------------------------------------
# Group 2: rate-limit retry
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 2: rate-limit retry ---"
echo ""

echo "Test 3: rate-limit then success -> exactly 2 calls and URL returned"
reset_env
counter="$TMPDIR/t3-counter"
sleep_log="$TMPDIR/t3-sleep.log"
: > "$sleep_log"
REPOLENS_FAKE_GH_COMMENT_COUNTER="$counter"
REPOLENS_FAKE_GH_COMMENT_RESPONSES=$'1||API rate limit exceeded. Retry-After: 3\n0|https://github.com/owner/repo/issues/42#issuecomment-77|'
REPOLENS_FAKE_SLEEP_LOG="$sleep_log"
out="$(run_comment owner/repo 42 "$body_file" 2>/dev/null)"
rc=$?
n_calls=0
[[ -f "$counter" ]] && n_calls="$(cat "$counter")"
slept="$(cat "$sleep_log" 2>/dev/null || true)"
assert_rc_zero "retry success returns 0" "$rc"
assert_eq "second-attempt URL printed" "https://github.com/owner/repo/issues/42#issuecomment-77" "$out"
assert_eq "exactly 2 comment attempts" "2" "$n_calls"
TOTAL=$((TOTAL + 1))
if [[ "$slept" == "3" ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: sleep used Retry-After value (slept='$slept')"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: expected sleep=3, got '$slept'"
fi

echo ""
echo "Test 4: persistent rate-limit -> non-zero with warn, no infinite loop"
reset_env
counter="$TMPDIR/t4-counter"
sleep_log="$TMPDIR/t4-sleep.log"
: > "$sleep_log"
REPOLENS_FAKE_GH_COMMENT_COUNTER="$counter"
REPOLENS_FAKE_GH_COMMENT_RESPONSES=$'1||API rate limit exceeded. Retry-After: 1\n1||API rate limit exceeded. Retry-After: 1'
REPOLENS_FAKE_SLEEP_LOG="$sleep_log"
err_file="$TMPDIR/t4.err"
out="$(run_comment owner/repo 42 "$body_file" 2>"$err_file")"
rc=$?
n_calls=0
[[ -f "$counter" ]] && n_calls="$(cat "$counter")"
stderr_content="$(cat "$err_file")"
assert_rc_nonzero "double rate-limit returns non-zero" "$rc"
assert_eq "stdout empty on persistent rate-limit" "" "$out"
assert_eq "exactly 2 comment attempts (no infinite loop)" "2" "$n_calls"
assert_contains "warn mentions gh failed" "gh failed" "$stderr_content"
assert_contains "warn mentions repo" "owner/repo" "$stderr_content"

# ---------------------------------------------------------------------------
# Group 3: gh failure semantics (non-rate-limit)
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 3: gh failure (non-rate-limit) ---"
echo ""

echo "Test 5: gh comment exits non-zero -> wrapper returns 1 with warn"
reset_env
REPOLENS_FAKE_GH_COMMENT_RC=1
REPOLENS_FAKE_GH_COMMENT_STDERR='HTTP 404: issue not found'
err_file="$TMPDIR/t5.err"
out="$(run_comment owner/repo 999 "$body_file" 2>"$err_file")"
rc=$?
stderr_content="$(cat "$err_file")"
assert_rc_nonzero "404 returns non-zero" "$rc"
assert_eq "stdout empty on 404" "" "$out"
assert_contains "warn mentions repo" "owner/repo" "$stderr_content"
assert_contains "warn mentions gh failed" "gh failed" "$stderr_content"

# ---------------------------------------------------------------------------
# Group 4: provider dispatch + arg guards
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 4: provider dispatch + arg guards ---"
echo ""

echo "Test 6: tea provider posts a comment via 'tea issues comment'"
# Issue #240 — replaces the previous "tea die-stub" assertion. The wrapper
# must no longer die with 'not yet implemented' / '#61'; instead it routes
# the call through `tea issues comment <n>` and returns 0 on success.
reset_env
FORGE_PROVIDER_OVERRIDE=tea
FORGE_PROJECT_PATH="$TMPDIR"
FORGE_REMOTE_NAME=origin
tea_log="$TMPDIR/t6-tea.log"
: > "$tea_log"
REPOLENS_FAKE_TEA_LOG="$tea_log"
REPOLENS_FAKE_TEA_RC=0
err_file="$TMPDIR/t6.err"
out="$(run_comment owner/repo 42 "$body_file" 2>"$err_file")"
rc=$?
stderr_content="$(cat "$err_file")"
logged="$(cat "$tea_log")"
assert_rc_zero "tea dispatch succeeds (no longer dies with #61 stub)" "$rc"
TOTAL=$((TOTAL + 1))
if [[ "$stderr_content" != *"not yet implemented"* && "$stderr_content" != *"#61"* ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: tea dispatch no longer references 'not yet implemented' or '#61'"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: tea dispatch still mentions die stub (stderr='$stderr_content')"
fi
assert_contains "tea was invoked with 'issues comment'" "issues comment" "$logged"
assert_contains "tea argv includes the issue number positional" "42" "$logged"
assert_contains "tea argv includes the body file path" "$body_file" "$logged"

echo ""
echo "Test 7: fj provider posts a comment via 'fj issue comment'"
# Issue #241 — replaces the previous "fj die-stub" assertion. The wrapper
# must no longer die with 'not yet implemented' / '#62'; instead it routes
# the call through `fj -H $FORGE_HOST issue comment <repo> <n>` and
# returns 0 on success.
reset_env
FORGE_PROVIDER_OVERRIDE=fj
FORGE_HOST=codeberg.org
fj_log="$TMPDIR/t7-fj.log"
: > "$fj_log"
REPOLENS_FAKE_FJ_LOG="$fj_log"
REPOLENS_FAKE_FJ_RC=0
err_file="$TMPDIR/t7.err"
out="$(run_comment owner/repo 42 "$body_file" 2>"$err_file")"
rc=$?
stderr_content="$(cat "$err_file")"
logged="$(cat "$fj_log")"
assert_rc_zero "fj dispatch succeeds (no longer dies with #62 stub)" "$rc"
TOTAL=$((TOTAL + 1))
if [[ "$stderr_content" != *"not yet implemented"* && "$stderr_content" != *"#62"* ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: fj dispatch no longer references 'not yet implemented' or '#62'"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: fj dispatch still mentions die stub (stderr='$stderr_content')"
fi
assert_contains "fj was invoked with 'issue comment'" "issue comment" "$logged"
assert_contains "fj argv includes the issue number positional" "42" "$logged"
assert_contains "fj argv includes the body file path" "$body_file" "$logged"

echo ""
echo "Test 8: empty FORGE_PROVIDER dies with 'unknown provider'"
reset_env
FORGE_PROVIDER_OVERRIDE=""
out="$(run_comment owner/repo 1 "$body_file" 2>&1)"
rc=$?
assert_rc_nonzero "empty provider dies" "$rc"
assert_contains "empty provider reports unknown" "unknown provider" "$out"

echo ""
echo "Test 9: missing repo arg dies before any gh call"
reset_env
gh_log="$TMPDIR/t9-gh.log"
: > "$gh_log"
REPOLENS_FAKE_GH_LOG="$gh_log"
out="$(run_comment "" 1 "$body_file" 2>&1)"
rc=$?
assert_rc_nonzero "missing repo dies" "$rc"
assert_contains "missing repo reports missing argument" "missing argument" "$out"
assert_log_empty "missing repo does not call gh" "$gh_log"

echo ""
echo "Test 10: missing issue_number arg dies before any gh call"
reset_env
gh_log="$TMPDIR/t10-gh.log"
: > "$gh_log"
REPOLENS_FAKE_GH_LOG="$gh_log"
out="$(run_comment owner/repo "" "$body_file" 2>&1)"
rc=$?
assert_rc_nonzero "missing issue_number dies" "$rc"
assert_contains "missing issue_number reports missing argument" "missing argument" "$out"
assert_log_empty "missing issue_number does not call gh" "$gh_log"

echo ""
echo "Test 11: missing body_file arg dies before any gh call"
reset_env
gh_log="$TMPDIR/t11-gh.log"
: > "$gh_log"
REPOLENS_FAKE_GH_LOG="$gh_log"
out="$(run_comment owner/repo 1 "" 2>&1)"
rc=$?
assert_rc_nonzero "missing body_file dies" "$rc"
assert_contains "missing body_file reports missing argument" "missing argument" "$out"
assert_log_empty "missing body_file does not call gh" "$gh_log"

echo ""
echo "Test 12: unreadable body_file dies before any gh call"
reset_env
gh_log="$TMPDIR/t12-gh.log"
: > "$gh_log"
REPOLENS_FAKE_GH_LOG="$gh_log"
out="$(run_comment owner/repo 1 "$TMPDIR/missing.md" 2>&1)"
rc=$?
assert_rc_nonzero "unreadable body_file dies" "$rc"
assert_contains "unreadable body_file reports not readable" "not readable" "$out"
assert_log_empty "unreadable body_file does not call gh" "$gh_log"

echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
