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

# Tests for issue #241 — forge_issue_create fj (Forgejo / Codeberg) backend.
#
# Behavioral contract (derived from research.md + the existing fj wrappers
# in lib/forge.sh — auth_status, label_create, issue_list_count — which
# all require FORGE_HOST and route through `fj -H "$FORGE_HOST" …`):
#   - When FORGE_PROVIDER=fj, forge_issue_create routes the call through:
#       fj -H "$FORGE_HOST" issue create --repo <repo> --title <t>
#         --body-file <bf> --no-template
#   - FORGE_HOST is required; missing -> die (mirrors fj auth/label/count).
#   - URL parsing: prefer a full `https?://.../issues/<n>` line; fall back
#     to `#<n>` and synthesize "<FORGE_HOST>/<repo>/issues/<n>". If both
#     fail, the wrapper returns 1 with a warn naming the URL parse failure
#     (the dispatch_filing_batch contract requires that rc=0 means a URL
#     was actually filed — see research.md §Constraints).
#   - Labels: applied post-create with one `fj issue edit "<repo>#<n>"
#     labels --add <label>` per label. Per-label call fan-out is intentional
#     (lowest-common-denominator across fj versions; see research.md).
#   - Label-edit failures are best-effort: the issue create has already
#     succeeded, so a label-add failure does NOT roll the wrapper rc to 1.
#     Mirrors the swallow shape used by forge_label_create's fj arm.
#   - fj non-zero exit on create -> wrapper returns 1 with a _forge_warn
#     diagnostic that includes the repo, fj exit code, and first stderr
#     line (mirrors the tea-arm warn shape).
#
# fj is PATH-shadowed with a fake stub; no real Forgejo CLI / network /
# login / repository is required.

# shellcheck disable=SC2034  # REPOLENS_FAKE_* vars are exported into the runner subshell by run_create_fj().

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

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (unexpectedly contained '$needle'; got '${haystack:0:300}')"
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
echo "=== Test Suite: forge_issue_create fj backend (issue #241) ==="
echo ""

[[ -f "$SCRIPT_DIR/lib/forge.sh" ]] || { echo "FAIL: lib/forge.sh missing"; exit 1; }
[[ -f "$SCRIPT_DIR/lib/core.sh" ]]  || { echo "FAIL: lib/core.sh missing"; exit 1; }

FAKE_BIN="$TMPDIR/bin"
mkdir -p "$FAKE_BIN"

# Stateful fake fj. Logs full argv (one invocation per line). For tests
# that need to assert on argument boundaries, the most-recent invocation's
# argv is dumped argv-by-argv to REPOLENS_FAKE_FJ_ARGV_DUMP.
#
# Per-subcommand responses (rc / stdout / stderr) are picked from
# REPOLENS_FAKE_FJ_CREATE_* and REPOLENS_FAKE_FJ_EDIT_*. The "subcommand"
# is determined by scanning argv for the first non-flag token after the
# leading -H<host>; "create" / "edit" are the two we care about here.
# Anything else falls back to the legacy REPOLENS_FAKE_FJ_* env vars.
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

# Detect the verb: look for 'create' or 'edit' anywhere in argv.
verb=""
for arg in "$@"; do
  case "$arg" in
    create) verb="create"; break ;;
    edit)   verb="edit"; break ;;
  esac
done

case "$verb" in
  create)
    if [[ -n "${REPOLENS_FAKE_FJ_CREATE_STDERR+x}" ]]; then
      printf '%s\n' "$REPOLENS_FAKE_FJ_CREATE_STDERR" >&2
    fi
    if [[ -n "${REPOLENS_FAKE_FJ_CREATE_STDOUT+x}" ]]; then
      printf '%s\n' "$REPOLENS_FAKE_FJ_CREATE_STDOUT"
    fi
    exit "${REPOLENS_FAKE_FJ_CREATE_RC:-0}"
    ;;
  edit)
    # Stateful per-call edit responses (newline-separated rc values).
    # When REPOLENS_FAKE_FJ_EDIT_COUNTER is set, pick the Nth value from
    # REPOLENS_FAKE_FJ_EDIT_RCS; otherwise fall back to a flat _RC.
    if [[ -n "${REPOLENS_FAKE_FJ_EDIT_COUNTER+x}" ]]; then
      n=0
      [[ -f "$REPOLENS_FAKE_FJ_EDIT_COUNTER" ]] && n="$(cat "$REPOLENS_FAKE_FJ_EDIT_COUNTER")"
      n=$((n + 1))
      printf '%s' "$n" > "$REPOLENS_FAKE_FJ_EDIT_COUNTER"
      idx=$((n - 1))
      IFS=$'\n' read -r -d '' -a edit_rcs < <(printf '%s\0' "${REPOLENS_FAKE_FJ_EDIT_RCS:-}")
      if (( idx < ${#edit_rcs[@]} )); then
        if [[ -n "${REPOLENS_FAKE_FJ_EDIT_STDERR+x}" ]]; then
          printf '%s\n' "$REPOLENS_FAKE_FJ_EDIT_STDERR" >&2
        fi
        exit "${edit_rcs[$idx]:-0}"
      fi
    fi
    if [[ -n "${REPOLENS_FAKE_FJ_EDIT_STDERR+x}" ]]; then
      printf '%s\n' "$REPOLENS_FAKE_FJ_EDIT_STDERR" >&2
    fi
    exit "${REPOLENS_FAKE_FJ_EDIT_RC:-0}"
    ;;
esac

# Fallback for any non-create/non-edit invocation.
if [[ -n "${REPOLENS_FAKE_FJ_STDERR+x}" ]]; then
  printf '%s\n' "$REPOLENS_FAKE_FJ_STDERR" >&2
fi
if [[ -n "${REPOLENS_FAKE_FJ_STDOUT+x}" ]]; then
  printf '%s\n' "$REPOLENS_FAKE_FJ_STDOUT"
fi
exit "${REPOLENS_FAKE_FJ_RC:-0}"
SH
chmod +x "$FAKE_BIN/fj"

run_create_fj() {
  (
    export PATH="$FAKE_BIN:/usr/bin:/bin:$PATH"
    export FORGE_PROVIDER=fj
    [[ -n "${FORGE_HOST+x}" ]] && export FORGE_HOST
    for v in REPOLENS_FAKE_FJ_LOG REPOLENS_FAKE_FJ_ARGV_DUMP \
             REPOLENS_FAKE_FJ_RC REPOLENS_FAKE_FJ_STDOUT REPOLENS_FAKE_FJ_STDERR \
             REPOLENS_FAKE_FJ_CREATE_RC REPOLENS_FAKE_FJ_CREATE_STDOUT REPOLENS_FAKE_FJ_CREATE_STDERR \
             REPOLENS_FAKE_FJ_EDIT_RC REPOLENS_FAKE_FJ_EDIT_STDERR \
             REPOLENS_FAKE_FJ_EDIT_COUNTER REPOLENS_FAKE_FJ_EDIT_RCS; do
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
  unset REPOLENS_FAKE_FJ_LOG REPOLENS_FAKE_FJ_ARGV_DUMP
  unset REPOLENS_FAKE_FJ_RC REPOLENS_FAKE_FJ_STDOUT REPOLENS_FAKE_FJ_STDERR
  unset REPOLENS_FAKE_FJ_CREATE_RC REPOLENS_FAKE_FJ_CREATE_STDOUT REPOLENS_FAKE_FJ_CREATE_STDERR
  unset REPOLENS_FAKE_FJ_EDIT_RC REPOLENS_FAKE_FJ_EDIT_STDERR
  unset REPOLENS_FAKE_FJ_EDIT_COUNTER REPOLENS_FAKE_FJ_EDIT_RCS
  unset FORGE_HOST
}

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
# Group 1: fj success path — URL parsing
# ---------------------------------------------------------------------------
echo "--- Group 1: fj success path ---"
echo ""

echo "Test 1: fj prints a full URL line -> wrapper parses it and exits 0"
reset_env
FORGE_HOST=codeberg.org
fj_log="$TMPDIR/t1-fj.log"
argv_dump="$TMPDIR/t1-argv.log"
: > "$fj_log"
REPOLENS_FAKE_FJ_LOG="$fj_log"
REPOLENS_FAKE_FJ_ARGV_DUMP="$argv_dump"
REPOLENS_FAKE_FJ_CREATE_RC=0
REPOLENS_FAKE_FJ_CREATE_STDOUT='Created issue #5 at https://codeberg.org/owner/repo/issues/5'
out="$(run_create_fj owner/repo 'My title' "$body_file" 2>/dev/null)"
rc=$?
logged="$(cat "$fj_log")"
argv_content="$(cat "$argv_dump")"
assert_rc_zero "fj URL-form success returns 0" "$rc"
assert_eq "stdout is the URL extracted from fj output" \
  "https://codeberg.org/owner/repo/issues/5" "$out"
assert_contains "fj is invoked with 'issue create'" "issue create" "$logged"
assert_contains "fj argv carries -H <host>" "-H codeberg.org" "$logged"
assert_contains "fj argv carries --repo <repo>" "--repo owner/repo" "$logged"
assert_contains "fj argv carries --title <t>" "--title" "$logged"
assert_contains "fj argv carries the title value verbatim" \
  "<My title>" "$argv_content"
assert_contains "fj argv carries --body-file <bf>" "--body-file" "$logged"
assert_contains "fj argv carries the body file path verbatim" \
  "<$body_file>" "$argv_content"
assert_contains "fj argv carries --no-template" "--no-template" "$logged"

echo ""
echo "Test 2: fj prints short '<repo>#<n>' -> wrapper synthesizes URL from FORGE_HOST"
# When fj only echoes the short identity ('owner/repo#7') and no URL, the
# wrapper must synthesize 'https://<host>/<repo>/issues/<n>'. For a bare
# 'codeberg.org' FORGE_HOST without a scheme, the wrapper prepends https://.
reset_env
FORGE_HOST=codeberg.org
REPOLENS_FAKE_FJ_CREATE_RC=0
REPOLENS_FAKE_FJ_CREATE_STDOUT='owner/repo#7'
out="$(run_create_fj owner/repo 'Short form' "$body_file" 2>/dev/null)"
rc=$?
assert_rc_zero "fj short-form success returns 0" "$rc"
assert_eq "stdout is the synthesized URL" \
  "https://codeberg.org/owner/repo/issues/7" "$out"

# ---------------------------------------------------------------------------
# Group 2: label fan-out
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 2: per-label edit fan-out ---"
echo ""

echo "Test 3: two labels trigger exactly two 'issue edit' calls in order"
# fj does not accept --label on create. The wrapper applies each label
# with a separate 'fj issue edit "<repo>#<n>" labels --add <label>' call.
reset_env
FORGE_HOST=codeberg.org
fj_log="$TMPDIR/t3-fj.log"
: > "$fj_log"
REPOLENS_FAKE_FJ_LOG="$fj_log"
REPOLENS_FAKE_FJ_CREATE_RC=0
REPOLENS_FAKE_FJ_CREATE_STDOUT='Created issue #5 at https://codeberg.org/owner/repo/issues/5'
REPOLENS_FAKE_FJ_EDIT_RC=0
out="$(run_create_fj owner/repo 'Labeled' "$body_file" 'audit:demo' 'severity:high' 2>/dev/null)"
rc=$?
logged="$(cat "$fj_log")"
assert_rc_zero "create with labels succeeds" "$rc"
assert_eq "stdout is the parsed URL" \
  "https://codeberg.org/owner/repo/issues/5" "$out"
# 3 calls total: 1 create + 2 edits.
n_lines="$(grep -c . "$fj_log" || true)"
assert_eq "fj log shows exactly 3 invocations (1 create + 2 edits)" "3" "$n_lines"
assert_contains "fj log shows the create call" "issue create" "$logged"
assert_contains "fj log shows the first label add" \
  "issue edit owner/repo#5 labels --add audit:demo" "$logged"
assert_contains "fj log shows the second label add" \
  "issue edit owner/repo#5 labels --add severity:high" "$logged"
# Per-label fan-out: must NOT collapse into a single comma-joined --add.
assert_not_contains "labels must not be comma-joined in a single --add" \
  "audit:demo,severity:high" "$logged"

echo ""
echo "Test 4: label-edit failures are best-effort (wrapper still returns 0)"
# The issue is already created; a label-edit fault must not roll wrapper rc.
reset_env
FORGE_HOST=codeberg.org
edit_counter="$TMPDIR/t4-counter"
REPOLENS_FAKE_FJ_CREATE_RC=0
REPOLENS_FAKE_FJ_CREATE_STDOUT='Created issue #9 at https://codeberg.org/owner/repo/issues/9'
REPOLENS_FAKE_FJ_EDIT_COUNTER="$edit_counter"
# First edit fails (label already exists / transient), second succeeds.
REPOLENS_FAKE_FJ_EDIT_RCS=$'9\n0'
REPOLENS_FAKE_FJ_EDIT_STDERR='label already exists'
err_file="$TMPDIR/t4.err"
out="$(run_create_fj owner/repo 'Best effort' "$body_file" 'audit:demo' 'severity:high' 2>"$err_file")"
rc=$?
assert_rc_zero "label-edit failure is swallowed; wrapper still 0" "$rc"
assert_eq "stdout is the issue URL even when a label edit failed" \
  "https://codeberg.org/owner/repo/issues/9" "$out"

# ---------------------------------------------------------------------------
# Group 3: failure semantics
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 3: failure semantics ---"
echo ""

echo "Test 5: fj create exits non-zero -> wrapper returns 1 with warn"
# Mirrors the tea-arm failure warn shape: includes repo, rc, and first
# stderr line. Operators need all three to root-cause cross-link failures.
reset_env
FORGE_HOST=codeberg.org
REPOLENS_FAKE_FJ_CREATE_RC=4
REPOLENS_FAKE_FJ_CREATE_STDERR='auth required'
err_file="$TMPDIR/t5.err"
out="$(run_create_fj owner/repo 'Auth fail' "$body_file" 2>"$err_file")"
rc=$?
stderr_content="$(cat "$err_file")"
assert_rc_nonzero "fj create failure returns non-zero" "$rc"
assert_eq "stdout is empty on fj create failure" "" "$out"
assert_contains "warn mentions fj failed" "fj failed" "$stderr_content"
assert_contains "warn mentions the repo" "owner/repo" "$stderr_content"
assert_contains "warn includes the fj exit code" "rc=4" "$stderr_content"
assert_contains "warn surfaces the first fj stderr line" \
  "auth required" "$stderr_content"

echo ""
echo "Test 6: fj create rc=0 but unparsable stdout -> wrapper returns 1"
# Per dispatch_filing_batch contract: rc=0 must mean a URL was actually
# filed. If we can't extract one, surface the failure rather than letting
# callers believe a non-existent URL went out.
reset_env
FORGE_HOST=codeberg.org
REPOLENS_FAKE_FJ_CREATE_RC=0
REPOLENS_FAKE_FJ_CREATE_STDOUT='something unexpected'
err_file="$TMPDIR/t6.err"
out="$(run_create_fj owner/repo 'No URL' "$body_file" 2>"$err_file")"
rc=$?
stderr_content="$(cat "$err_file")"
assert_rc_nonzero "URL parse failure is observable to callers" "$rc"
assert_eq "stdout is empty when no URL could be parsed" "" "$out"
assert_contains "warn mentions parse failure" "parse" "$stderr_content"

# ---------------------------------------------------------------------------
# Group 4: FORGE_HOST requirement and self-hosted shape
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 4: FORGE_HOST handling ---"
echo ""

echo "Test 7: missing FORGE_HOST dies before invoking fj"
# Mirror the existing fj wrappers (forge_auth_status, forge_label_create,
# forge_issue_list_count): all three require FORGE_HOST. The new arm
# inherits the same guard.
reset_env
unset FORGE_HOST
fj_log="$TMPDIR/t7-fj.log"
: > "$fj_log"
REPOLENS_FAKE_FJ_LOG="$fj_log"
out="$(run_create_fj owner/repo 'No host' "$body_file" 2>&1)"
rc=$?
assert_rc_nonzero "missing FORGE_HOST exits non-zero" "$rc"
assert_contains "die message names FORGE_HOST as the missing requirement" \
  "FORGE_HOST" "$out"
assert_log_empty "missing FORGE_HOST does not invoke fj" "$fj_log"

echo ""
echo "Test 8: self-hosted FORGE_HOST (HTTPS + port) passes through verbatim"
# When the operator runs against a self-hosted Forgejo on
# https://forge.example.com:3000, the wrapper must forward the host
# string as-is (matches the self-hosted assertion in tests/test_forge_fj.sh
# Test 10).
reset_env
FORGE_HOST="https://forge.example.com:3000"
fj_log="$TMPDIR/t8-fj.log"
: > "$fj_log"
REPOLENS_FAKE_FJ_LOG="$fj_log"
REPOLENS_FAKE_FJ_CREATE_RC=0
REPOLENS_FAKE_FJ_CREATE_STDOUT='Created issue #1 at https://forge.example.com:3000/owner/repo/issues/1'
out="$(run_create_fj owner/repo 'Self-hosted' "$body_file" 2>/dev/null)"
rc=$?
logged="$(cat "$fj_log")"
assert_rc_zero "self-hosted create succeeds" "$rc"
assert_contains "fj argv carries the self-hosted FORGE_HOST verbatim" \
  "-H https://forge.example.com:3000" "$logged"

echo ""
echo "Test 9: short-form output + FORGE_HOST already has https:// scheme -> no double-prepend"
# Branch coverage for the URL-synthesis fallback (lines ~953-955 in lib/forge.sh).
# When fj returns the short '<repo>#<n>' form AND FORGE_HOST already carries
# a scheme (self-hosted Forgejo deployment), the wrapper must use $FORGE_HOST
# verbatim instead of naively prepending https://, which would produce a
# broken 'https://https://...' URL. Test 2 covers the bare-host branch;
# Test 8 covers the verbose-URL parse path with a self-hosted host. Neither
# exercises the short-form + already-has-scheme branch.
reset_env
FORGE_HOST="https://forge.example.com:3000"
REPOLENS_FAKE_FJ_CREATE_RC=0
REPOLENS_FAKE_FJ_CREATE_STDOUT='owner/repo#11'
out="$(run_create_fj owner/repo 'Self-hosted short form' "$body_file" 2>/dev/null)"
rc=$?
assert_rc_zero "short-form + scheme'd host succeeds" "$rc"
assert_eq "synthesized URL preserves the existing scheme (no double https://)" \
  "https://forge.example.com:3000/owner/repo/issues/11" "$out"

echo ""
echo "Test 10: short-form output + FORGE_HOST with http:// scheme -> preserves http"
# Sibling branch to Test 9: when the operator deliberately uses http://
# (e.g. local dev Forgejo on http://localhost:3000), the wrapper must not
# silently upgrade the scheme to https://. The condition at
# `if [[ "$host_url" != http://* && "$host_url" != https://* ]]` makes this
# explicit; pin it so a future "always-https" refactor cannot regress
# plaintext-host operators.
reset_env
FORGE_HOST="http://localhost:3000"
REPOLENS_FAKE_FJ_CREATE_RC=0
REPOLENS_FAKE_FJ_CREATE_STDOUT='owner/repo#3'
out="$(run_create_fj owner/repo 'Local dev short form' "$body_file" 2>/dev/null)"
rc=$?
assert_rc_zero "short-form + http://-host succeeds" "$rc"
assert_eq "synthesized URL preserves the http:// scheme verbatim" \
  "http://localhost:3000/owner/repo/issues/3" "$out"

echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
