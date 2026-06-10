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

# Tests for issue #62 - Forgejo fj backend for forge_* wrappers.
#
# Behavioral contract:
#   - forge_auth_status with FORGE_PROVIDER=fj checks `fj -H <host> whoami`.
#   - forge_label_create <label> <color> <owner/repo> calls
#     `fj -H <host> repo labels <owner/repo> create <label> <color>`
#     and keeps label creation best-effort by swallowing fj failures.
#   - forge_issue_list_count <owner/repo> <label> works with the official
#     forgejo-cli contract: `--style` only accepts `fancy|minimal`, so the
#     wrapper must not pass `--style json`. It uses host-scoped issue search,
#     parses the leading minimal-style `N issue(s)` line, and preserves the
#     same success/failure contract as the gh/tea branches.
#   - fj never relies on current-directory repository inference; every call
#     gets an explicit FORGE_HOST-derived `-H` argument.
#
# All fj calls are PATH-shadowed with a fake fj stub. No real Forgejo CLI,
# network, login, or repository is required.

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
    echo "  FAIL: $desc (expected no fj invocation, got '$(cat "$log_file")')"
  fi
}

echo ""
echo "=== Test Suite: forge fj backend (issue #62) ==="
echo ""

[[ -f "$SCRIPT_DIR/lib/forge.sh" ]] || { echo "FAIL: lib/forge.sh missing"; exit 1; }
[[ -f "$SCRIPT_DIR/lib/core.sh" ]]  || { echo "FAIL: lib/core.sh missing"; exit 1; }

FAKE_BIN="$TMPDIR/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/fj" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${REPOLENS_FAKE_FJ_LOG:-/dev/null}"
if [[ -n "${REPOLENS_FAKE_FJ_ARGV_DUMP+x}" ]]; then
  {
    printf '%s\n' "$#"
    for arg in "$@"; do
      printf '<%s>\n' "$arg"
    done
  } > "$REPOLENS_FAKE_FJ_ARGV_DUMP"
fi
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

run_wrapper() {
  local fn="$1"; shift
  (
    export PATH="$FAKE_BIN:/usr/bin:/bin:$PATH"
    export FORGE_PROVIDER=fj
    [[ -n "${FORGE_HOST+x}" ]] && export FORGE_HOST
    [[ -n "${REPOLENS_FAKE_FJ_RC+x}" ]] && export REPOLENS_FAKE_FJ_RC
    [[ -n "${REPOLENS_FAKE_FJ_LOG+x}" ]] && export REPOLENS_FAKE_FJ_LOG
    [[ -n "${REPOLENS_FAKE_FJ_ARGV_DUMP+x}" ]] && export REPOLENS_FAKE_FJ_ARGV_DUMP
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

reset_fake_fj() {
  unset REPOLENS_FAKE_FJ_RC REPOLENS_FAKE_FJ_LOG
  unset REPOLENS_FAKE_FJ_ARGV_DUMP
  unset REPOLENS_FAKE_FJ_STDOUT REPOLENS_FAKE_FJ_STDERR
}

# ---------------------------------------------------------------------------
# Group 1: forge_auth_status
# ---------------------------------------------------------------------------
echo "--- Group 1: forge_auth_status ---"
echo ""

echo "Test 1: fj auth success calls host-scoped whoami and stays silent"
reset_fake_fj
fj_log="$TMPDIR/t1-fj.log"
: > "$fj_log"
FORGE_HOST=codeberg.org
REPOLENS_FAKE_FJ_RC=0
REPOLENS_FAKE_FJ_LOG="$fj_log"
err_file="$TMPDIR/t1.err"
out="$(run_wrapper forge_auth_status 2>"$err_file")"
rc=$?
assert_rc_zero "forge_auth_status fj returns 0 when fj whoami succeeds" "$rc"
assert_eq "forge_auth_status fj prints nothing on stdout" "" "$out"
assert_eq "forge_auth_status fj prints nothing on stderr" "" "$(cat "$err_file")"
assert_eq "fj auth argv uses explicit host and whoami" "-H codeberg.org whoami" "$(cat "$fj_log")"

echo ""
echo "Test 2: fj auth failure dies with a host-specific login hint"
reset_fake_fj
fj_log="$TMPDIR/t2-fj.log"
: > "$fj_log"
FORGE_HOST=codeberg.org
REPOLENS_FAKE_FJ_RC=4
REPOLENS_FAKE_FJ_LOG="$fj_log"
out="$(run_wrapper forge_auth_status 2>&1)"
rc=$?
assert_rc_nonzero "forge_auth_status fj returns non-zero when fj whoami fails" "$rc"
assert_contains "die message mentions fj authentication" "fj is not authenticated" "$out"
assert_contains "die message tells the user how to log in for the host" "fj -H codeberg.org auth login" "$out"
assert_eq "fj auth failure still uses host-scoped whoami" "-H codeberg.org whoami" "$(cat "$fj_log")"

echo ""
echo "Test 3: fj auth requires FORGE_HOST before invoking fj"
reset_fake_fj
fj_log="$TMPDIR/t3-fj.log"
: > "$fj_log"
unset FORGE_HOST
REPOLENS_FAKE_FJ_LOG="$fj_log"
out="$(run_wrapper forge_auth_status 2>&1)"
rc=$?
assert_rc_nonzero "missing FORGE_HOST exits non-zero" "$rc"
assert_contains "missing FORGE_HOST reports the required host binding" "FORGE_HOST" "$out"
assert_log_empty "missing FORGE_HOST does not call fj" "$fj_log"

# ---------------------------------------------------------------------------
# Group 2: forge_label_create
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 2: forge_label_create ---"
echo ""

echo "Test 4: fj label create uses repo labels with explicit host"
reset_fake_fj
fj_log="$TMPDIR/t4-fj.log"
argv_dump="$TMPDIR/t4-argv.log"
: > "$fj_log"
FORGE_HOST=codeberg.org
REPOLENS_FAKE_FJ_RC=0
REPOLENS_FAKE_FJ_LOG="$fj_log"
REPOLENS_FAKE_FJ_ARGV_DUMP="$argv_dump"
out="$(run_wrapper forge_label_create audit:demo abcdef owner/repo 2>&1)"
rc=$?
logged="$(cat "$fj_log")"
argv_content="$(cat "$argv_dump" 2>/dev/null || true)"
assert_rc_zero "forge_label_create fj succeeds when fj repo labels succeeds" "$rc"
assert_eq "forge_label_create fj is silent on success" "" "$out"
assert_eq "fj label argv matches the supported CLI surface (with #RRGGBB)" \
  "-H codeberg.org repo labels owner/repo create audit:demo #abcdef" "$logged"
assert_eq "fj label argv has one owner/repo argument" "8" "$(sed -n '1p' "$argv_dump" 2>/dev/null || true)"
assert_contains "fj label argv includes owner/repo as one argument" "<owner/repo>" "$argv_content"

echo ""
echo "Test 5: fj label create failures remain best-effort"
reset_fake_fj
fj_log="$TMPDIR/t5-fj.log"
: > "$fj_log"
FORGE_HOST=codeberg.org
REPOLENS_FAKE_FJ_RC=9
REPOLENS_FAKE_FJ_STDERR='label already exists'
REPOLENS_FAKE_FJ_LOG="$fj_log"
out="$(run_wrapper forge_label_create audit:demo abcdef owner/repo 2>&1)"
rc=$?
assert_rc_zero "forge_label_create fj swallows non-zero fj exit" "$rc"
assert_eq "forge_label_create fj suppresses failed label stderr" "" "$out"
assert_eq "best-effort label failure still calls fj repo labels create (with #RRGGBB)" \
  "-H codeberg.org repo labels owner/repo create audit:demo #abcdef" "$(cat "$fj_log")"

echo ""
echo "Test 6: fj label create requires FORGE_HOST before invoking fj"
reset_fake_fj
fj_log="$TMPDIR/t6-fj.log"
: > "$fj_log"
unset FORGE_HOST
REPOLENS_FAKE_FJ_LOG="$fj_log"
out="$(run_wrapper forge_label_create audit:demo abcdef owner/repo 2>&1)"
rc=$?
assert_rc_nonzero "forge_label_create fj without FORGE_HOST exits non-zero" "$rc"
assert_contains "missing label-create FORGE_HOST reports the required host binding" "FORGE_HOST" "$out"
assert_log_empty "missing label-create FORGE_HOST does not call fj" "$fj_log"

# ---------------------------------------------------------------------------
# Group 3: forge_issue_list_count
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 3: forge_issue_list_count ---"
echo ""

echo "Test 7: fj issue search returning '0 issues' prints 0"
reset_fake_fj
fj_log="$TMPDIR/t7-fj.log"
argv_dump="$TMPDIR/t7-argv.log"
: > "$fj_log"
FORGE_HOST=codeberg.org
REPOLENS_FAKE_FJ_RC=0
REPOLENS_FAKE_FJ_STDOUT='0 issues'
REPOLENS_FAKE_FJ_LOG="$fj_log"
REPOLENS_FAKE_FJ_ARGV_DUMP="$argv_dump"
err_file="$TMPDIR/t7.err"
out="$(run_wrapper forge_issue_list_count owner/repo audit:demo 2>"$err_file")"
rc=$?
logged="$(cat "$fj_log")"
argv_content="$(cat "$argv_dump" 2>/dev/null || true)"
assert_rc_zero "zero fj issues is a successful count" "$rc"
assert_eq "stdout is 0 for legitimately zero matching open Forgejo issues" "0" "$out"
assert_eq "stderr is empty on successful fj count" "" "$(cat "$err_file")"
assert_eq "fj issue-search argv uses official minimal style and accepted flags" \
  "-H codeberg.org --style minimal issue search --repo owner/repo --labels audit:demo --state open" "$logged"
assert_eq "fj issue-search argv has the expected argument count" "12" "$(sed -n '1p' "$argv_dump" 2>/dev/null || true)"
assert_contains "fj issue-search argv includes owner/repo as one argument" "<owner/repo>" "$argv_content"

echo ""
echo "Test 8: fj issue search returning singular '1 issue' prints 1"
reset_fake_fj
FORGE_HOST=codeberg.org
REPOLENS_FAKE_FJ_RC=0
REPOLENS_FAKE_FJ_STDOUT='1 issue'
out="$(run_wrapper forge_issue_list_count owner/repo audit:demo 2>/dev/null)"
rc=$?
assert_rc_zero "singular fj issue count exits zero" "$rc"
assert_eq "stdout is 1 for one matching open Forgejo issue" "1" "$out"

echo ""
echo "Test 9: fj issue search parses the leading count from multiline output"
reset_fake_fj
FORGE_HOST=codeberg.org
REPOLENS_FAKE_FJ_RC=0
REPOLENS_FAKE_FJ_STDOUT=$'2 issues\n#1 existing issue\n#2 another issue'
out="$(run_wrapper forge_issue_list_count owner/repo audit:demo 2>/dev/null)"
rc=$?
assert_rc_zero "multiline fj issue output exits zero" "$rc"
assert_eq "stdout is 2 when fj also prints issue rows after the count" "2" "$out"

echo ""
echo "Test 10: fj issue search works with an HTTPS self-hosted Forgejo host"
reset_fake_fj
fj_log="$TMPDIR/t10-fj.log"
: > "$fj_log"
FORGE_HOST="https://forge.example.com:3000"
REPOLENS_FAKE_FJ_RC=0
REPOLENS_FAKE_FJ_STDOUT='2 issues'
REPOLENS_FAKE_FJ_LOG="$fj_log"
out="$(run_wrapper forge_issue_list_count owner/repo audit:demo 2>/dev/null)"
rc=$?
assert_rc_zero "self-hosted fj issue count exits zero" "$rc"
assert_eq "stdout is 2 for two matching open Forgejo issues" "2" "$out"
assert_eq "self-hosted fj issue-search argv preserves the HTTPS host with minimal style" \
  "-H https://forge.example.com:3000 --style minimal issue search --repo owner/repo --labels audit:demo --state open" "$(cat "$fj_log")"

echo ""
echo "Test 11: fj issue search failure returns non-zero, empty stdout, and warning"
reset_fake_fj
FORGE_HOST=codeberg.org
REPOLENS_FAKE_FJ_RC=7
REPOLENS_FAKE_FJ_STDERR='Forgejo API unavailable'
err_file="$TMPDIR/t11.err"
out="$(run_wrapper forge_issue_list_count owner/repo audit:demo 2>"$err_file")"
rc=$?
stderr_content="$(cat "$err_file")"
assert_rc_nonzero "fj issue-search failure is observable to callers" "$rc"
assert_eq "stdout is empty when fj issue search fails" "" "$out"
assert_contains "warning mentions fj failed" "fj failed" "$stderr_content"
assert_contains "warning includes the fj exit code" "rc=7" "$stderr_content"
assert_contains "warning includes the target repo" "repo=owner/repo" "$stderr_content"
assert_contains "warning includes the target label" "label=audit:demo" "$stderr_content"
assert_contains "warning includes the first fj stderr line" "Forgejo API unavailable" "$stderr_content"

echo ""
echo "Test 12: fj issue search unparsable output returns non-zero with empty stdout"
reset_fake_fj
FORGE_HOST=codeberg.org
REPOLENS_FAKE_FJ_RC=0
REPOLENS_FAKE_FJ_STDOUT='open issues: two'
err_file="$TMPDIR/t12.err"
out="$(run_wrapper forge_issue_list_count owner/repo audit:demo 2>"$err_file")"
rc=$?
assert_rc_nonzero "unparsable fj output is observable to callers" "$rc"
assert_eq "stdout is empty on fj output parse failure" "" "$out"
stderr_content="$(cat "$err_file")"
assert_contains "warning identifies the function" "forge_issue_list_count" "$stderr_content"
assert_contains "warning records the target repo" "repo=owner/repo" "$stderr_content"
assert_contains "warning records the target label" "label=audit:demo" "$stderr_content"

echo ""
echo "Test 13: fj issue count requires FORGE_HOST before invoking fj"
reset_fake_fj
fj_log="$TMPDIR/t13-fj.log"
: > "$fj_log"
unset FORGE_HOST
REPOLENS_FAKE_FJ_LOG="$fj_log"
out="$(run_wrapper forge_issue_list_count owner/repo audit:demo 2>&1)"
rc=$?
assert_rc_nonzero "forge_issue_list_count fj without FORGE_HOST exits non-zero" "$rc"
assert_contains "missing issue-count FORGE_HOST reports the required host binding" "FORGE_HOST" "$out"
assert_log_empty "missing issue-count FORGE_HOST does not call fj" "$fj_log"

echo ""
echo "Test 14: missing issue label dies before invoking fj"
reset_fake_fj
fj_log="$TMPDIR/t14-fj.log"
: > "$fj_log"
FORGE_HOST=codeberg.org
REPOLENS_FAKE_FJ_LOG="$fj_log"
out="$(run_wrapper forge_issue_list_count owner/repo "" 2>&1)"
rc=$?
assert_rc_nonzero "missing issue label exits non-zero" "$rc"
assert_contains "missing issue label reports missing argument" "missing argument" "$out"
assert_log_empty "missing issue label does not call fj" "$fj_log"

echo ""
echo "Test 15: official fj rejects --style json but minimal output still counts"
reset_fake_fj
fj_log="$TMPDIR/t15-fj.log"
: > "$fj_log"
FORGE_HOST=codeberg.org
REPOLENS_FAKE_FJ_RC=0
REPOLENS_FAKE_FJ_STDOUT='3 issues'
REPOLENS_FAKE_FJ_LOG="$fj_log"
err_file="$TMPDIR/t15.err"
out="$(run_wrapper forge_issue_list_count owner/repo audit:demo 2>"$err_file")"
rc=$?
assert_rc_zero "official-minimal fj output is a successful count" "$rc"
assert_eq "stdout is the parsed minimal count" "3" "$out"
assert_eq "stderr is empty when minimal output parses cleanly" "" "$(cat "$err_file")"
assert_eq "fj is invoked with official minimal style, not invalid JSON style" \
  "-H codeberg.org --style minimal issue search --repo owner/repo --labels audit:demo --state open" "$(cat "$fj_log")"

echo ""
echo "Test 16: minimal-style output with capitalized 'Issues' still parses via case-insensitive fallback (issue #244)"
reset_fake_fj
FORGE_HOST=codeberg.org
REPOLENS_FAKE_FJ_RC=0
# Official fj emits a minimal leading-count line; the title-cased 'Issues'
# form was the original regression that motivated #244.
REPOLENS_FAKE_FJ_STDOUT='2 Issues'
err_file="$TMPDIR/t16.err"
out="$(run_wrapper forge_issue_list_count owner/repo audit:demo 2>"$err_file")"
rc=$?
assert_rc_zero "capitalized 'Issues' fallback exits zero" "$rc"
assert_eq "stdout is 2 for '2 Issues' minimal-style output" "2" "$out"

echo ""
echo "Test 17: fj returns rc=0 with empty stdout -> single warn, non-zero rc (issue #244)"
reset_fake_fj
fj_log="$TMPDIR/t17-fj.log"
: > "$fj_log"
FORGE_HOST=codeberg.org
REPOLENS_FAKE_FJ_RC=0
# Explicitly clear stdout: fj succeeds with empty output.
REPOLENS_FAKE_FJ_STDOUT=''
REPOLENS_FAKE_FJ_LOG="$fj_log"
err_file="$TMPDIR/t17.err"
out="$(run_wrapper forge_issue_list_count owner/repo audit:demo 2>"$err_file")"
rc=$?
stderr_content="$(cat "$err_file")"
assert_rc_nonzero "empty fj stdout is observable to caller" "$rc"
assert_eq "stdout is empty when fj produces no output" "" "$out"
assert_contains "warning identifies the function on empty stdout" "forge_issue_list_count" "$stderr_content"
assert_contains "warning records the target repo on empty stdout" "repo=owner/repo" "$stderr_content"
assert_contains "warning records the target label on empty stdout" "label=audit:demo" "$stderr_content"
warn_lines=$(printf '%s\n' "$stderr_content" | grep -c 'forge_issue_list_count' || true)
TOTAL=$((TOTAL + 1))
if [[ "$warn_lines" -le 1 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: empty fj stdout emits at most one warning line (no double-warn from JSON probe + fallback)"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: empty fj stdout emitted $warn_lines warnings (expected at most 1)"
fi

echo ""
echo "Test 18: minimal output with whitespace around zero still prints 0"
reset_fake_fj
fj_log="$TMPDIR/t18-fj.log"
: > "$fj_log"
FORGE_HOST=codeberg.org
REPOLENS_FAKE_FJ_RC=0
REPOLENS_FAKE_FJ_STDOUT='  0 Issues  '
REPOLENS_FAKE_FJ_LOG="$fj_log"
err_file="$TMPDIR/t18.err"
out="$(run_wrapper forge_issue_list_count owner/repo audit:demo 2>"$err_file")"
rc=$?
assert_rc_zero "whitespace-padded minimal zero-count exits zero" "$rc"
assert_eq "stdout is 0 for a whitespace-padded minimal zero count" "0" "$out"
assert_eq "stderr is empty on minimal zero-count" "" "$(cat "$err_file")"
assert_eq "zero-count fj call uses official minimal style" \
  "-H codeberg.org --style minimal issue search --repo owner/repo --labels audit:demo --state open" "$(cat "$fj_log")"

echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
