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

# Tests for issue #163 - forge_issue_create wrapper.
#
# Behavioral contract:
#   - lib/forge.sh exports forge_issue_create <repo> <title> <body_file> [labels...]
#   - The gh branch dedups via `gh issue list --search` then creates with
#     `gh issue create -R <repo> --title <t> --body-file <bf> [--label <l> ...]`.
#   - On rate-limit stderr, retries the create exactly once.
#   - Missing args / unreadable body_file / unknown provider die loudly.
#   - tea branch creates issues via `tea issues create ...` and is exercised
#     by the smoke test below; comprehensive tea coverage lives in
#     tests/test_forge_issue_create_tea.sh.
#   - fj branch creates issues via `fj -H $FORGE_HOST issue create ...`,
#     parses the URL (or synthesizes from `#<n>`), and applies labels via
#     `fj issue edit "<repo>#<n>" labels --add <label>` (one call per label).
#     Smoke-covered below; comprehensive fj coverage lives in
#     tests/test_forge_issue_create_fj.sh.
#
# Forge calls are PATH-shadowed with fake stubs. No real forge call is made,
# and the test sleep is mocked so retry tests complete instantly.

# shellcheck disable=SC2034  # REPOLENS_FAKE_* vars are exported into the runner subshell by run_create().

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
echo "=== Test Suite: forge_issue_create (issue #163) ==="
echo ""

[[ -f "$SCRIPT_DIR/lib/forge.sh" ]] || { echo "FAIL: lib/forge.sh missing"; exit 1; }
[[ -f "$SCRIPT_DIR/lib/core.sh" ]]  || { echo "FAIL: lib/core.sh missing"; exit 1; }

FAKE_BIN="$TMPDIR/bin"
mkdir -p "$FAKE_BIN"

# Stateful fake gh: each invocation appends argv to the log, picks the
# response from REPOLENS_FAKE_GH_RESPONSES (a colon-delimited list of
# rc|stdout|stderr triples), and defaults to rc=0/empty when exhausted.
# The script-style approach also supports the simpler legacy env vars
# REPOLENS_FAKE_GH_RC / STDOUT / STDERR for non-stateful tests.
cat > "$FAKE_BIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${REPOLENS_FAKE_GH_LOG:-/dev/null}"

# Determine subcommand: "issue create", "issue list", "issue comment".
subcmd=""
if [[ "$1" == "issue" ]]; then
  subcmd="$1 ${2:-}"
fi

# Subcommand-specific responses take precedence.
case "$subcmd" in
  "issue list")
    if [[ -n "${REPOLENS_FAKE_GH_LIST_STDERR+x}" ]]; then
      printf '%s\n' "$REPOLENS_FAKE_GH_LIST_STDERR" >&2
    fi
    if [[ -n "${REPOLENS_FAKE_GH_LIST_STDOUT+x}" ]]; then
      printf '%s\n' "$REPOLENS_FAKE_GH_LIST_STDOUT"
    fi
    exit "${REPOLENS_FAKE_GH_LIST_RC:-0}"
    ;;
  "issue create")
    # Stateful: read attempt counter from a file, pick from RESPONSES list.
    if [[ -n "${REPOLENS_FAKE_GH_CREATE_COUNTER+x}" ]]; then
      n=0
      [[ -f "$REPOLENS_FAKE_GH_CREATE_COUNTER" ]] && n="$(cat "$REPOLENS_FAKE_GH_CREATE_COUNTER")"
      n=$((n + 1))
      printf '%s' "$n" > "$REPOLENS_FAKE_GH_CREATE_COUNTER"
      idx=$((n - 1))
      IFS=$'\n' read -r -d '' -a responses < <(printf '%s\0' "${REPOLENS_FAKE_GH_CREATE_RESPONSES:-}")
      if (( idx < ${#responses[@]} )); then
        triple="${responses[$idx]}"
        rc="${triple%%|*}"; rest="${triple#*|}"
        outv="${rest%%|*}"; errv="${rest#*|}"
        [[ -n "$outv" ]] && printf '%s\n' "$outv"
        [[ -n "$errv" ]] && printf '%s\n' "$errv" >&2
        exit "${rc:-0}"
      fi
    fi
    if [[ -n "${REPOLENS_FAKE_GH_CREATE_STDERR+x}" ]]; then
      printf '%s\n' "$REPOLENS_FAKE_GH_CREATE_STDERR" >&2
    fi
    if [[ -n "${REPOLENS_FAKE_GH_CREATE_STDOUT+x}" ]]; then
      printf '%s\n' "$REPOLENS_FAKE_GH_CREATE_STDOUT"
    fi
    exit "${REPOLENS_FAKE_GH_CREATE_RC:-0}"
    ;;
  "issue comment")
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
    ;;
esac

# Fallback (non-issue gh calls).
if [[ -n "${REPOLENS_FAKE_GH_STDERR+x}" ]]; then
  printf '%s\n' "$REPOLENS_FAKE_GH_STDERR" >&2
fi
if [[ -n "${REPOLENS_FAKE_GH_STDOUT+x}" ]]; then
  printf '%s\n' "$REPOLENS_FAKE_GH_STDOUT"
fi
exit "${REPOLENS_FAKE_GH_RC:-0}"
SH
chmod +x "$FAKE_BIN/gh"

# Mock sleep — record the requested duration and return immediately so
# retry tests don't actually wait.
cat > "$FAKE_BIN/sleep" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${REPOLENS_FAKE_SLEEP_LOG:-/dev/null}"
exit 0
SH
chmod +x "$FAKE_BIN/sleep"

# Fake tea — minimal stub used by the smoke test that the tea arm no
# longer dies with the #61 stub. Logs full argv and lets the caller pick
# rc / stdout / stderr via env vars.
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
# longer dies with the #62 stub. Logs full argv and lets the caller pick
# rc / stdout / stderr via env vars (mirrors the tea stub above).
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

run_create() {
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
    # Pass-through every fake-gh / fake-tea env var.
    for v in REPOLENS_FAKE_GH_RC REPOLENS_FAKE_GH_LOG REPOLENS_FAKE_GH_STDOUT REPOLENS_FAKE_GH_STDERR \
             REPOLENS_FAKE_GH_LIST_RC REPOLENS_FAKE_GH_LIST_STDOUT REPOLENS_FAKE_GH_LIST_STDERR \
             REPOLENS_FAKE_GH_CREATE_RC REPOLENS_FAKE_GH_CREATE_STDOUT REPOLENS_FAKE_GH_CREATE_STDERR \
             REPOLENS_FAKE_GH_CREATE_COUNTER REPOLENS_FAKE_GH_CREATE_RESPONSES \
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
    forge_issue_create "$@"
  )
}

reset_env() {
  unset REPOLENS_FAKE_GH_RC REPOLENS_FAKE_GH_LOG REPOLENS_FAKE_GH_STDOUT REPOLENS_FAKE_GH_STDERR
  unset REPOLENS_FAKE_GH_LIST_RC REPOLENS_FAKE_GH_LIST_STDOUT REPOLENS_FAKE_GH_LIST_STDERR
  unset REPOLENS_FAKE_GH_CREATE_RC REPOLENS_FAKE_GH_CREATE_STDOUT REPOLENS_FAKE_GH_CREATE_STDERR
  unset REPOLENS_FAKE_GH_CREATE_COUNTER REPOLENS_FAKE_GH_CREATE_RESPONSES
  unset REPOLENS_FAKE_GH_COMMENT_RC REPOLENS_FAKE_GH_COMMENT_STDOUT REPOLENS_FAKE_GH_COMMENT_STDERR
  unset REPOLENS_FAKE_GH_COMMENT_COUNTER REPOLENS_FAKE_GH_COMMENT_RESPONSES
  unset REPOLENS_FAKE_TEA_RC REPOLENS_FAKE_TEA_LOG REPOLENS_FAKE_TEA_STDOUT REPOLENS_FAKE_TEA_STDERR
  unset REPOLENS_FAKE_FJ_RC REPOLENS_FAKE_FJ_LOG REPOLENS_FAKE_FJ_STDOUT REPOLENS_FAKE_FJ_STDERR
  unset FORGE_PROJECT_PATH FORGE_REMOTE_NAME FORGE_TEA_LOGIN
  unset REPOLENS_FAKE_SLEEP_LOG FORGE_PROVIDER_OVERRIDE FORGE_HOST
}

# Make a body file with realistic markdown content.
body_file="$TMPDIR/body.md"
cat > "$body_file" <<'MD'
# Finding

```bash
echo "preserves backticks and newlines"
```

- bullet 1
- bullet 2
MD

# ---------------------------------------------------------------------------
# Group 1: gh success path
# ---------------------------------------------------------------------------
echo "--- Group 1: gh success path ---"
echo ""

echo "Test 1: gh create succeeds -> wrapper prints URL and exits 0"
reset_env
REPOLENS_FAKE_GH_LIST_RC=0
REPOLENS_FAKE_GH_LIST_STDOUT='[]'
REPOLENS_FAKE_GH_CREATE_RC=0
REPOLENS_FAKE_GH_CREATE_STDOUT='https://github.com/owner/repo/issues/42'
out="$(run_create owner/repo 'My title' "$body_file" 2>/dev/null)"
rc=$?
assert_rc_zero "create success returns 0" "$rc"
assert_eq "stdout is the issue URL" "https://github.com/owner/repo/issues/42" "$out"

echo ""
echo "Test 2: gh create receives expected argv"
reset_env
gh_log="$TMPDIR/t2-gh.log"
: > "$gh_log"
REPOLENS_FAKE_GH_LIST_RC=0
REPOLENS_FAKE_GH_LIST_STDOUT='[]'
REPOLENS_FAKE_GH_CREATE_RC=0
REPOLENS_FAKE_GH_CREATE_STDOUT='https://github.com/owner/repo/issues/1'
REPOLENS_FAKE_GH_LOG="$gh_log"
out="$(run_create owner/repo 'My title' "$body_file" 2>/dev/null)"
rc=$?
logged="$(cat "$gh_log")"
assert_rc_zero "argv-contract create succeeds" "$rc"
assert_contains "gh receives 'issue create'" "issue create" "$logged"
assert_contains "gh create receives repo selector" "-R owner/repo" "$logged"
assert_contains "gh create receives --title" "--title My title" "$logged"
assert_contains "gh create receives --body-file" "--body-file $body_file" "$logged"

echo ""
echo "Test 3: multiple labels appear as repeated --label flags in order"
reset_env
gh_log="$TMPDIR/t3-gh.log"
: > "$gh_log"
REPOLENS_FAKE_GH_LIST_RC=0
REPOLENS_FAKE_GH_LIST_STDOUT='[]'
REPOLENS_FAKE_GH_CREATE_RC=0
REPOLENS_FAKE_GH_CREATE_STDOUT='https://github.com/owner/repo/issues/2'
REPOLENS_FAKE_GH_LOG="$gh_log"
out="$(run_create owner/repo 'Title' "$body_file" 'audit:demo' 'severity:high' 2>/dev/null)"
rc=$?
logged="$(cat "$gh_log")"
assert_rc_zero "create with labels succeeds" "$rc"
assert_contains "first label flag present" "--label audit:demo" "$logged"
assert_contains "second label flag present" "--label severity:high" "$logged"

# ---------------------------------------------------------------------------
# Group 2: idempotency / dedup
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 2: idempotency / dedup ---"
echo ""

echo "Test 4: existing open issue with exact title -> wrapper returns existing URL, no create"
reset_env
gh_log="$TMPDIR/t4-gh.log"
: > "$gh_log"
REPOLENS_FAKE_GH_LIST_RC=0
REPOLENS_FAKE_GH_LIST_STDOUT='[{"title":"My title","url":"https://github.com/owner/repo/issues/99"}]'
REPOLENS_FAKE_GH_LOG="$gh_log"
# CREATE not configured: if it ever runs, it returns rc=0/empty stdout
# which we'd notice as a contract violation via the URL assertion.
out="$(run_create owner/repo 'My title' "$body_file" 2>/dev/null)"
rc=$?
logged="$(cat "$gh_log")"
assert_rc_zero "dedup hit returns 0" "$rc"
assert_eq "dedup hit prints the existing URL" "https://github.com/owner/repo/issues/99" "$out"
TOTAL=$((TOTAL + 1))
if [[ "$logged" != *"issue create"* ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: dedup hit does not invoke 'issue create'"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: dedup hit invoked 'issue create' (logged='$logged')"
fi

echo ""
echo "Test 5: list returns case/text-mismatched titles -> wrapper still creates"
reset_env
gh_log="$TMPDIR/t5-gh.log"
: > "$gh_log"
REPOLENS_FAKE_GH_LIST_RC=0
REPOLENS_FAKE_GH_LIST_STDOUT='[{"title":"my title","url":"https://github.com/owner/repo/issues/9"}]'
REPOLENS_FAKE_GH_CREATE_RC=0
REPOLENS_FAKE_GH_CREATE_STDOUT='https://github.com/owner/repo/issues/10'
REPOLENS_FAKE_GH_LOG="$gh_log"
out="$(run_create owner/repo 'My title' "$body_file" 2>/dev/null)"
rc=$?
logged="$(cat "$gh_log")"
assert_rc_zero "case-mismatch goes to create" "$rc"
assert_eq "stdout is the freshly-created URL" "https://github.com/owner/repo/issues/10" "$out"
assert_contains "create was invoked" "issue create" "$logged"

echo ""
echo "Test 6: list fails -> wrapper still proceeds to create (best-effort)"
reset_env
REPOLENS_FAKE_GH_LIST_RC=2
REPOLENS_FAKE_GH_LIST_STDERR='ENOENT'
REPOLENS_FAKE_GH_CREATE_RC=0
REPOLENS_FAKE_GH_CREATE_STDOUT='https://github.com/owner/repo/issues/11'
out="$(run_create owner/repo 'Some title' "$body_file" 2>/dev/null)"
rc=$?
assert_rc_zero "list-failure-then-create returns 0" "$rc"
assert_eq "create URL is returned" "https://github.com/owner/repo/issues/11" "$out"

# ---------------------------------------------------------------------------
# Group 3: rate-limit retry
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 3: rate-limit retry ---"
echo ""

echo "Test 7: first attempt rate-limited, retry succeeds -> 2 create calls, success"
reset_env
counter="$TMPDIR/t7-counter"
sleep_log="$TMPDIR/t7-sleep.log"
: > "$sleep_log"
REPOLENS_FAKE_GH_LIST_RC=0
REPOLENS_FAKE_GH_LIST_STDOUT='[]'
REPOLENS_FAKE_GH_CREATE_COUNTER="$counter"
REPOLENS_FAKE_GH_CREATE_RESPONSES=$'1||API rate limit exceeded. Retry-After: 2\n0|https://github.com/owner/repo/issues/77|'
REPOLENS_FAKE_SLEEP_LOG="$sleep_log"
out="$(run_create owner/repo 'Retry me' "$body_file" 2>/dev/null)"
rc=$?
n_calls=0
[[ -f "$counter" ]] && n_calls="$(cat "$counter")"
slept="$(cat "$sleep_log" 2>/dev/null || true)"
assert_rc_zero "retry success returns 0" "$rc"
assert_eq "second-attempt URL printed" "https://github.com/owner/repo/issues/77" "$out"
assert_eq "exactly 2 create attempts" "2" "$n_calls"
TOTAL=$((TOTAL + 1))
if [[ -n "$slept" ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: sleep was invoked between attempts (slept='$slept')"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: expected sleep call between attempts"
fi

echo ""
echo "Test 8: rate-limit on both attempts -> wrapper returns 1 with warn, no infinite loop"
reset_env
counter="$TMPDIR/t8-counter"
sleep_log="$TMPDIR/t8-sleep.log"
: > "$sleep_log"
REPOLENS_FAKE_GH_LIST_RC=0
REPOLENS_FAKE_GH_LIST_STDOUT='[]'
REPOLENS_FAKE_GH_CREATE_COUNTER="$counter"
REPOLENS_FAKE_GH_CREATE_RESPONSES=$'1||API rate limit exceeded. Retry-After: 1\n1||API rate limit exceeded. Retry-After: 1'
REPOLENS_FAKE_SLEEP_LOG="$sleep_log"
err_file="$TMPDIR/t8.err"
out="$(run_create owner/repo 'Retry me again' "$body_file" 2>"$err_file")"
rc=$?
n_calls=0
[[ -f "$counter" ]] && n_calls="$(cat "$counter")"
stderr_content="$(cat "$err_file")"
assert_rc_nonzero "double rate-limit returns non-zero" "$rc"
assert_eq "stdout is empty on persistent failure" "" "$out"
assert_eq "exactly 2 create attempts (no infinite loop)" "2" "$n_calls"
assert_contains "warn mentions gh failed" "gh failed" "$stderr_content"
assert_contains "warn mentions repo" "owner/repo" "$stderr_content"

echo ""
echo "Test 9: sleep duration is capped at 60s"
reset_env
counter="$TMPDIR/t9-counter"
sleep_log="$TMPDIR/t9-sleep.log"
: > "$sleep_log"
REPOLENS_FAKE_GH_LIST_RC=0
REPOLENS_FAKE_GH_LIST_STDOUT='[]'
REPOLENS_FAKE_GH_CREATE_COUNTER="$counter"
REPOLENS_FAKE_GH_CREATE_RESPONSES=$'1||API rate limit exceeded. Retry-After: 9999\n0|https://github.com/owner/repo/issues/123|'
REPOLENS_FAKE_SLEEP_LOG="$sleep_log"
out="$(run_create owner/repo 'Big retry' "$body_file" 2>/dev/null)"
rc=$?
slept="$(cat "$sleep_log" 2>/dev/null || true)"
assert_rc_zero "capped retry succeeds" "$rc"
TOTAL=$((TOTAL + 1))
if [[ "$slept" == "60" ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: sleep capped at 60 (got '$slept')"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: expected sleep=60, got '$slept'"
fi

# ---------------------------------------------------------------------------
# Group 4: gh failure semantics (non-rate-limit)
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 4: gh failure (non-rate-limit) ---"
echo ""

echo "Test 10: gh exits non-zero (auth failure) -> wrapper returns 1 with warn"
reset_env
REPOLENS_FAKE_GH_LIST_RC=0
REPOLENS_FAKE_GH_LIST_STDOUT='[]'
REPOLENS_FAKE_GH_CREATE_RC=1
REPOLENS_FAKE_GH_CREATE_STDERR='HTTP 401: not authenticated'
err_file="$TMPDIR/t10.err"
out="$(run_create owner/repo 'Auth fail' "$body_file" 2>"$err_file")"
rc=$?
stderr_content="$(cat "$err_file")"
assert_rc_nonzero "auth failure returns non-zero" "$rc"
assert_eq "stdout is empty on auth failure" "" "$out"
assert_contains "warn mentions repo" "owner/repo" "$stderr_content"
assert_contains "warn mentions gh failed" "gh failed" "$stderr_content"

# ---------------------------------------------------------------------------
# Group 5: provider dispatch + arg guards
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 5: provider dispatch + arg guards ---"
echo ""

echo "Test 11: tea provider creates an issue and prints the html_url"
# Issue #240 — replaces the previous "tea die-stub" assertion. The wrapper
# must no longer die with 'not yet implemented' / '#61'; instead it routes
# the call through `tea issues create` and prints the resulting URL.
reset_env
FORGE_PROVIDER_OVERRIDE=tea
FORGE_PROJECT_PATH="$TMPDIR"
FORGE_REMOTE_NAME=origin
tea_log="$TMPDIR/t11-tea.log"
: > "$tea_log"
REPOLENS_FAKE_TEA_LOG="$tea_log"
REPOLENS_FAKE_TEA_RC=0
REPOLENS_FAKE_TEA_STDOUT='{"html_url":"https://gitea.example.com/owner/repo/issues/7"}'
err_file="$TMPDIR/t11.err"
out="$(run_create owner/repo 'Title' "$body_file" 2>"$err_file")"
rc=$?
stderr_content="$(cat "$err_file")"
logged="$(cat "$tea_log")"
assert_rc_zero "tea dispatch succeeds (no longer dies with #61 stub)" "$rc"
assert_eq "tea wrapper prints the html_url" \
  "https://gitea.example.com/owner/repo/issues/7" "$out"
TOTAL=$((TOTAL + 1))
if [[ "$stderr_content" != *"not yet implemented"* && "$stderr_content" != *"#61"* ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: tea dispatch no longer references 'not yet implemented' or '#61'"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: tea dispatch still mentions die stub (stderr='$stderr_content')"
fi
assert_contains "tea was invoked with 'issues create'" "issues create" "$logged"
assert_contains "tea argv includes the title" "Title" "$logged"
assert_contains "tea argv includes the body file path" "$body_file" "$logged"

echo ""
echo "Test 12: fj provider creates an issue and prints the URL"
# Issue #241 — replaces the previous "fj die-stub" assertion. The wrapper
# must no longer die with 'not yet implemented' / '#62'; instead it routes
# the call through `fj -H $FORGE_HOST issue create` and prints the URL
# parsed from fj's stdout.
reset_env
FORGE_PROVIDER_OVERRIDE=fj
FORGE_HOST=codeberg.org
fj_log="$TMPDIR/t12-fj.log"
: > "$fj_log"
REPOLENS_FAKE_FJ_LOG="$fj_log"
REPOLENS_FAKE_FJ_RC=0
REPOLENS_FAKE_FJ_STDOUT='Created issue #5 at https://codeberg.org/owner/repo/issues/5'
err_file="$TMPDIR/t12.err"
out="$(run_create owner/repo 'Title' "$body_file" 2>"$err_file")"
rc=$?
stderr_content="$(cat "$err_file")"
logged="$(cat "$fj_log")"
assert_rc_zero "fj dispatch succeeds (no longer dies with #62 stub)" "$rc"
assert_eq "fj wrapper prints the parsed URL" \
  "https://codeberg.org/owner/repo/issues/5" "$out"
TOTAL=$((TOTAL + 1))
if [[ "$stderr_content" != *"not yet implemented"* && "$stderr_content" != *"#62"* ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: fj dispatch no longer references 'not yet implemented' or '#62'"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: fj dispatch still mentions die stub (stderr='$stderr_content')"
fi
assert_contains "fj was invoked with 'issue create'" "issue create" "$logged"
assert_contains "fj argv includes the title" "Title" "$logged"
assert_contains "fj argv includes the body file path" "$body_file" "$logged"

echo ""
echo "Test 13: empty FORGE_PROVIDER dies with 'unknown provider'"
reset_env
FORGE_PROVIDER_OVERRIDE=""
out="$(run_create owner/repo 'Title' "$body_file" 2>&1)"
rc=$?
assert_rc_nonzero "empty provider dies" "$rc"
assert_contains "empty provider reports unknown" "unknown provider" "$out"

echo ""
echo "Test 14: missing repo arg dies before any gh call"
reset_env
gh_log="$TMPDIR/t14-gh.log"
: > "$gh_log"
REPOLENS_FAKE_GH_LOG="$gh_log"
out="$(run_create "" 'Title' "$body_file" 2>&1)"
rc=$?
assert_rc_nonzero "missing repo dies" "$rc"
assert_contains "missing repo reports missing argument" "missing argument" "$out"
assert_log_empty "missing repo does not call gh" "$gh_log"

echo ""
echo "Test 15: missing title arg dies before any gh call"
reset_env
gh_log="$TMPDIR/t15-gh.log"
: > "$gh_log"
REPOLENS_FAKE_GH_LOG="$gh_log"
out="$(run_create owner/repo "" "$body_file" 2>&1)"
rc=$?
assert_rc_nonzero "missing title dies" "$rc"
assert_contains "missing title reports missing argument" "missing argument" "$out"
assert_log_empty "missing title does not call gh" "$gh_log"

echo ""
echo "Test 16: missing body_file arg dies before any gh call"
reset_env
gh_log="$TMPDIR/t16-gh.log"
: > "$gh_log"
REPOLENS_FAKE_GH_LOG="$gh_log"
out="$(run_create owner/repo 'Title' "" 2>&1)"
rc=$?
assert_rc_nonzero "missing body_file dies" "$rc"
assert_contains "missing body_file reports missing argument" "missing argument" "$out"
assert_log_empty "missing body_file does not call gh" "$gh_log"

echo ""
echo "Test 17: unreadable body_file dies before any gh call"
reset_env
gh_log="$TMPDIR/t17-gh.log"
: > "$gh_log"
REPOLENS_FAKE_GH_LOG="$gh_log"
out="$(run_create owner/repo 'Title' "$TMPDIR/does-not-exist.md" 2>&1)"
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
