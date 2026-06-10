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

# Tests for issue #241 — forge_issue_comment fj (Forgejo / Codeberg) backend.
#
# Behavioral contract (derived from research.md and the existing fj
# wrappers in lib/forge.sh):
#   - When FORGE_PROVIDER=fj, forge_issue_comment routes the call through:
#       fj -H "$FORGE_HOST" issue comment <repo> <issue_number>
#         --body-file <body_file>
#     (two positional args after 'issue comment': <repo> then <number>.)
#   - FORGE_HOST is required; missing -> die (mirrors other fj wrappers).
#   - fj exit 0 -> wrapper returns 0. If fj emitted any stdout, echo the
#     first line through (matches the tea arm's `… | head -n1` shape).
#   - fj non-zero exit -> wrapper returns 1 with a _forge_warn diagnostic
#     that includes the repo, issue number, rc, and first stderr line.
#
# fj is PATH-shadowed with a fake stub; no real Forgejo CLI / network /
# login / repository is required.

# shellcheck disable=SC2034  # REPOLENS_FAKE_* vars are exported into the runner subshell by run_comment_fj().

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
    echo "  FAIL: $desc (expected no fj invocation, got '$(cat "$log_file")')"
  fi
}

echo ""
echo "=== Test Suite: forge_issue_comment fj backend (issue #241) ==="
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
if [[ -n "${REPOLENS_FAKE_FJ_STDERR+x}" ]]; then
  printf '%s\n' "$REPOLENS_FAKE_FJ_STDERR" >&2
fi
if [[ -n "${REPOLENS_FAKE_FJ_STDOUT+x}" ]]; then
  printf '%s\n' "$REPOLENS_FAKE_FJ_STDOUT"
fi
exit "${REPOLENS_FAKE_FJ_RC:-0}"
SH
chmod +x "$FAKE_BIN/fj"

run_comment_fj() {
  (
    export PATH="$FAKE_BIN:/usr/bin:/bin:$PATH"
    export FORGE_PROVIDER=fj
    [[ -n "${FORGE_HOST+x}" ]] && export FORGE_HOST
    for v in REPOLENS_FAKE_FJ_RC REPOLENS_FAKE_FJ_LOG \
             REPOLENS_FAKE_FJ_ARGV_DUMP \
             REPOLENS_FAKE_FJ_STDOUT REPOLENS_FAKE_FJ_STDERR; do
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
  unset REPOLENS_FAKE_FJ_RC REPOLENS_FAKE_FJ_LOG REPOLENS_FAKE_FJ_ARGV_DUMP
  unset REPOLENS_FAKE_FJ_STDOUT REPOLENS_FAKE_FJ_STDERR
  unset FORGE_HOST
}

body_file="$TMPDIR/body.md"
cat > "$body_file" <<'MD'
Cross-link to sibling cluster.

See related findings in #42.
MD

# ---------------------------------------------------------------------------
# Group 1: fj success path
# ---------------------------------------------------------------------------
echo "--- Group 1: fj success path ---"
echo ""

echo "Test 1: fj exits 0 with empty stdout -> wrapper returns 0 (silent success)"
reset_env
FORGE_HOST=codeberg.org
REPOLENS_FAKE_FJ_RC=0
err_file="$TMPDIR/t1.err"
out="$(run_comment_fj owner/repo 42 "$body_file" 2>"$err_file")"
rc=$?
assert_rc_zero "fj silent-success returns 0" "$rc"
assert_eq "no warn on stderr for silent success" "" "$(cat "$err_file")"

echo ""
echo "Test 2: fj comment argv matches the expected CLI contract"
# Pin the full shape: -H <host> issue comment <repo> <number> --body-file <bf>.
# Two positional args after 'issue comment' (repo then number) — this is
# the exact shape research.md proposed for the wrapper.
reset_env
FORGE_HOST=codeberg.org
fj_log="$TMPDIR/t2-fj.log"
argv_dump="$TMPDIR/t2-argv.log"
: > "$fj_log"
REPOLENS_FAKE_FJ_LOG="$fj_log"
REPOLENS_FAKE_FJ_ARGV_DUMP="$argv_dump"
REPOLENS_FAKE_FJ_RC=0
out="$(run_comment_fj owner/repo 42 "$body_file" 2>/dev/null)"
rc=$?
logged="$(cat "$fj_log")"
argv_content="$(cat "$argv_dump")"
assert_rc_zero "argv-contract comment succeeds" "$rc"
assert_contains "fj argv carries -H <host>" "-H codeberg.org" "$logged"
assert_contains "fj is invoked with 'issue comment'" "issue comment" "$logged"
assert_contains "fj argv carries the repo positional verbatim" \
  "<owner/repo>" "$argv_content"
assert_contains "fj argv carries the issue-number positional verbatim" \
  "<42>" "$argv_content"
assert_contains "fj argv carries --body-file" "--body-file" "$logged"
assert_contains "fj argv carries the body file path verbatim" \
  "<$body_file>" "$argv_content"

echo ""
echo "Test 3: fj prints a comment URL -> wrapper echoes first line on stdout"
# Matches the tea-arm contract: when fj is noisy on success, forward the
# first stdout line. Callers in lib/filing.sh use rc-only, but pinning
# stdout passthrough avoids regressing the behavior.
reset_env
FORGE_HOST=codeberg.org
REPOLENS_FAKE_FJ_RC=0
REPOLENS_FAKE_FJ_STDOUT="https://codeberg.org/owner/repo/issues/42#issuecomment-1234"
out="$(run_comment_fj owner/repo 42 "$body_file" 2>/dev/null)"
rc=$?
assert_rc_zero "fj verbose-success returns 0" "$rc"
assert_eq "wrapper echoes the fj stdout first line" \
  "https://codeberg.org/owner/repo/issues/42#issuecomment-1234" "$out"

# ---------------------------------------------------------------------------
# Group 2: fj failure semantics
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 2: fj failure semantics ---"
echo ""

echo "Test 4: fj exits non-zero -> wrapper returns 1 with warn (failure path)"
# This is the bug-prevention test from the controller guidance: the stub
# returns non-zero so the wrapper's failure branch actually executes.
# A stub that always succeeds would leave the failure path untested.
reset_env
FORGE_HOST=codeberg.org
REPOLENS_FAKE_FJ_RC=9
REPOLENS_FAKE_FJ_STDERR='permission denied: cannot comment'
err_file="$TMPDIR/t4.err"
out="$(run_comment_fj owner/repo 13 "$body_file" 2>"$err_file")"
rc=$?
stderr_content="$(cat "$err_file")"
assert_rc_nonzero "fj permission failure returns non-zero" "$rc"
assert_eq "stdout is empty on fj failure" "" "$out"
assert_contains "warn mentions fj failed" "fj failed" "$stderr_content"
assert_contains "warn mentions the repo" "owner/repo" "$stderr_content"
assert_contains "warn includes the fj exit code" "rc=9" "$stderr_content"
assert_contains "warn includes the issue number" "issue=13" "$stderr_content"
assert_contains "warn surfaces the first fj stderr line" \
  "permission denied: cannot comment" "$stderr_content"

# ---------------------------------------------------------------------------
# Group 3: FORGE_HOST requirement and self-hosted shape
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 3: FORGE_HOST handling ---"
echo ""

echo "Test 5: missing FORGE_HOST dies before invoking fj"
reset_env
unset FORGE_HOST
fj_log="$TMPDIR/t5-fj.log"
: > "$fj_log"
REPOLENS_FAKE_FJ_LOG="$fj_log"
out="$(run_comment_fj owner/repo 1 "$body_file" 2>&1)"
rc=$?
assert_rc_nonzero "missing FORGE_HOST exits non-zero" "$rc"
assert_contains "die message names FORGE_HOST as the missing requirement" \
  "FORGE_HOST" "$out"
assert_log_empty "missing FORGE_HOST does not invoke fj" "$fj_log"

echo ""
echo "Test 6: self-hosted FORGE_HOST (HTTPS + port) passes through verbatim"
reset_env
FORGE_HOST="https://forge.example.com:3000"
fj_log="$TMPDIR/t6-fj.log"
: > "$fj_log"
REPOLENS_FAKE_FJ_LOG="$fj_log"
REPOLENS_FAKE_FJ_RC=0
out="$(run_comment_fj owner/repo 5 "$body_file" 2>/dev/null)"
rc=$?
logged="$(cat "$fj_log")"
assert_rc_zero "self-hosted comment succeeds" "$rc"
assert_contains "fj argv carries the self-hosted FORGE_HOST verbatim" \
  "-H https://forge.example.com:3000" "$logged"

echo ""
echo "Test 7: multi-line fj stdout is truncated to the first line"
# Some fj builds emit the comment URL followed by extra diagnostic lines
# (rate-limit notes, deprecation warnings, etc.). The wrapper pipes
# `printf '%s\n' "$fj_out" | head -n1` so callers never see the trailing
# noise (matches the tea-arm passthrough). Test 3 only exercises a single
# line, so the truncation behavior is unpinned without this case.
reset_env
FORGE_HOST=codeberg.org
REPOLENS_FAKE_FJ_RC=0
REPOLENS_FAKE_FJ_STDOUT=$'https://codeberg.org/owner/repo/issues/42#issuecomment-1234\nhint: api will deprecate v1 in 2026\nnote: 99 requests remaining'
out="$(run_comment_fj owner/repo 42 "$body_file" 2>/dev/null)"
rc=$?
assert_rc_zero "multi-line fj stdout returns 0" "$rc"
assert_eq "wrapper emits only the first stdout line, dropping trailing noise" \
  "https://codeberg.org/owner/repo/issues/42#issuecomment-1234" "$out"

echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
