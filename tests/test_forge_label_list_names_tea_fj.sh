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

# Tests for issue #242 — forge_label_list_names tea + fj backends.
#
# Behavioral contract (mirrors the gh arm at lib/forge.sh:474-499 and the
# sibling forge_issue_list_count tea/fj arms):
#
#   - forge_label_list_names <owner/repo> with FORGE_PROVIDER=tea:
#       * Requires either FORGE_PROJECT_PATH (+ FORGE_REMOTE_NAME) OR
#         FORGE_TEA_LOGIN for target binding; missing both dies before
#         invoking tea.
#       * On success: returns 0, prints one label name per line on stdout,
#         no stderr noise.
#       * On tea failure: returns 1, empty stdout, emits a _forge_warn line
#         to stderr that includes `tea failed`, `repo=<slug>`, `rc=<exit>`,
#         and the first stderr line as `err=...`.
#       * On JSON parse failure: returns 1, empty stdout, warn mentions
#         `jq failed to parse tea output`.
#
#   - forge_label_list_names <owner/repo> with FORGE_PROVIDER=fj:
#       * Requires FORGE_HOST; missing host dies before invoking fj.
#       * On success: returns 0, prints one label name per line on stdout.
#         The official path parses minimal/CSV-like output without passing
#         the unsupported `--style json` flag, while still accepting
#         structured JSON if a compatible CLI emits it.
#       * On fj failure: returns 1, empty stdout, warn includes
#         `fj failed`, `repo=<slug>`, `rc=<exit>`, and the first stderr
#         line as `err=...`.
#
# Fallback contract preserved from issue #186:
#   non-zero rc with empty stdout instructs _forge_label_bootstrap_unlocked
#   to take the best-effort create-all path.
#
# All tea / fj calls are PATH-shadowed with fake stubs. No real CLIs are
# invoked and no network or repository is required.

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
    echo "  FAIL: $desc (unexpectedly contained '$needle'; got '${haystack:0:200}')"
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
    echo "  FAIL: $desc (expected no invocation, got '$(cat "$log_file")')"
  fi
}

echo ""
echo "=== Test Suite: forge_label_list_names tea + fj (issue #242) ==="
echo ""

[[ -f "$SCRIPT_DIR/lib/forge.sh" ]] || { echo "FAIL: lib/forge.sh missing"; exit 1; }
[[ -f "$SCRIPT_DIR/lib/core.sh" ]]  || { echo "FAIL: lib/core.sh missing"; exit 1; }

FAKE_BIN="$TMPDIR/bin"
FORGE_TEST_PROJECT="$TMPDIR/audited project"
mkdir -p "$FAKE_BIN"
mkdir -p "$FORGE_TEST_PROJECT"

# Fake tea — logs argv, optionally dumps argv vector, emits configured
# stdout/stderr/rc. Identical fixture shape to tests/test_forge_tea.sh.
cat > "$FAKE_BIN/tea" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${REPOLENS_FAKE_TEA_LOG:-/dev/null}"
if [[ -n "${REPOLENS_FAKE_TEA_ARGV_DUMP+x}" ]]; then
  {
    printf '%s\n' "$#"
    for arg in "$@"; do
      printf '<%s>\n' "$arg"
    done
  } > "$REPOLENS_FAKE_TEA_ARGV_DUMP"
fi
if [[ -n "${REPOLENS_FAKE_TEA_STDERR+x}" ]]; then
  printf '%s\n' "$REPOLENS_FAKE_TEA_STDERR" >&2
fi
if [[ -n "${REPOLENS_FAKE_TEA_STDOUT+x}" ]]; then
  printf '%s\n' "$REPOLENS_FAKE_TEA_STDOUT"
fi
exit "${REPOLENS_FAKE_TEA_RC:-0}"
SH
chmod +x "$FAKE_BIN/tea"

# Fake fj — same shape, but models the official forgejo-cli parser: global
# `--style json` is invalid. When REPOLENS_FAKE_FJ_LABELS_NAMES is set
# (space-separated), the stub emits official minimal label output: one label
# name per line.
# When unset, it falls back to whatever REPOLENS_FAKE_FJ_STDOUT was configured
# to.
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
if [[ -n "${REPOLENS_FAKE_FJ_LABELS_NAMES+x}" ]]; then
  for name in $REPOLENS_FAKE_FJ_LABELS_NAMES; do
    printf '%s\n' "$name"
  done
elif [[ -n "${REPOLENS_FAKE_FJ_STDOUT+x}" ]]; then
  printf '%s\n' "$REPOLENS_FAKE_FJ_STDOUT"
fi
exit "${REPOLENS_FAKE_FJ_RC:-0}"
SH
chmod +x "$FAKE_BIN/fj"

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
    [[ -n "${REPOLENS_FAKE_TEA_RC+x}" ]] && export REPOLENS_FAKE_TEA_RC
    [[ -n "${REPOLENS_FAKE_TEA_LOG+x}" ]] && export REPOLENS_FAKE_TEA_LOG
    [[ -n "${REPOLENS_FAKE_TEA_ARGV_DUMP+x}" ]] && export REPOLENS_FAKE_TEA_ARGV_DUMP
    [[ -n "${REPOLENS_FAKE_TEA_STDOUT+x}" ]] && export REPOLENS_FAKE_TEA_STDOUT
    [[ -n "${REPOLENS_FAKE_TEA_STDERR+x}" ]] && export REPOLENS_FAKE_TEA_STDERR
    [[ -n "${REPOLENS_FAKE_FJ_RC+x}" ]] && export REPOLENS_FAKE_FJ_RC
    [[ -n "${REPOLENS_FAKE_FJ_LOG+x}" ]] && export REPOLENS_FAKE_FJ_LOG
    [[ -n "${REPOLENS_FAKE_FJ_ARGV_DUMP+x}" ]] && export REPOLENS_FAKE_FJ_ARGV_DUMP
    [[ -n "${REPOLENS_FAKE_FJ_STDOUT+x}" ]] && export REPOLENS_FAKE_FJ_STDOUT
    [[ -n "${REPOLENS_FAKE_FJ_STDERR+x}" ]] && export REPOLENS_FAKE_FJ_STDERR
    [[ -n "${REPOLENS_FAKE_FJ_LABELS_NAMES+x}" ]] && export REPOLENS_FAKE_FJ_LABELS_NAMES
    set -uo pipefail
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib/core.sh"
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib/forge.sh"
    "$fn" "$@"
  )
}

reset_fake_tea() {
  unset REPOLENS_FAKE_TEA_RC REPOLENS_FAKE_TEA_LOG
  unset REPOLENS_FAKE_TEA_ARGV_DUMP
  unset REPOLENS_FAKE_TEA_STDOUT REPOLENS_FAKE_TEA_STDERR
}

reset_fake_fj() {
  unset REPOLENS_FAKE_FJ_RC REPOLENS_FAKE_FJ_LOG
  unset REPOLENS_FAKE_FJ_ARGV_DUMP
  unset REPOLENS_FAKE_FJ_STDOUT REPOLENS_FAKE_FJ_STDERR
  unset REPOLENS_FAKE_FJ_LABELS_NAMES
}

# ---------------------------------------------------------------------------
# Group 1: tea — happy path, output parsing, target binding
# ---------------------------------------------------------------------------
echo "--- Group 1: tea ---"
echo ""

echo "Test 1: tea labels list succeeds and prints one name per line"
reset_fake_tea
FORGE_PROJECT_PATH="$FORGE_TEST_PROJECT"
FORGE_REMOTE_NAME="origin"
unset FORGE_TEA_LOGIN
tea_log="$TMPDIR/t1-tea.log"
argv_dump="$TMPDIR/t1-argv.log"
: > "$tea_log"
REPOLENS_FAKE_TEA_RC=0
REPOLENS_FAKE_TEA_STDOUT='[{"name":"audit:foo"},{"name":"enhancement"}]'
REPOLENS_FAKE_TEA_LOG="$tea_log"
REPOLENS_FAKE_TEA_ARGV_DUMP="$argv_dump"
err_file="$TMPDIR/t1.err"
out="$(run_wrapper tea forge_label_list_names owner/repo 2>"$err_file")"
rc=$?
logged="$(cat "$tea_log")"
argv_content="$(cat "$argv_dump" 2>/dev/null || true)"
assert_rc_zero "tea label list succeeds when tea returns a JSON array" "$rc"
assert_eq "tea label list prints names one per line in argv order" \
  $'audit:foo\nenhancement' "$out"
assert_eq "tea label list is silent on stderr" "" "$(cat "$err_file")"
assert_contains "tea label list argv invokes 'labels list'" "labels list" "$logged"
assert_contains "tea label list argv requests JSON output" "--output json" "$logged"
assert_contains "tea label list argv targets FORGE_PROJECT_PATH" "--repo $FORGE_TEST_PROJECT" "$logged"
assert_contains "tea label list argv passes the configured remote" "--remote origin" "$logged"
assert_contains "tea label list argv keeps the spaced project path as one argument" \
  "<$FORGE_TEST_PROJECT>" "$argv_content"
assert_not_contains "tea label list argv does not pass owner/repo slug as repo selector" \
  "--repo owner/repo" "$logged"

echo ""
echo "Test 2: tea labels list failure returns non-zero with empty stdout and a diagnostic warn"
reset_fake_tea
tea_log="$TMPDIR/t2-tea.log"
: > "$tea_log"
REPOLENS_FAKE_TEA_RC=7
REPOLENS_FAKE_TEA_STDERR='Gitea API unavailable'
REPOLENS_FAKE_TEA_LOG="$tea_log"
err_file="$TMPDIR/t2.err"
out="$(run_wrapper tea forge_label_list_names owner/repo 2>"$err_file")"
rc=$?
stderr_content="$(cat "$err_file")"
assert_rc_nonzero "tea label-list failure is observable to callers" "$rc"
assert_eq "tea label-list failure produces empty stdout" "" "$out"
assert_contains "warning mentions tea failed" "tea failed" "$stderr_content"
assert_contains "warning includes the tea exit code" "rc=7" "$stderr_content"
assert_contains "warning includes the target repo" "repo=owner/repo" "$stderr_content"
assert_contains "warning includes the first tea stderr line" "Gitea API unavailable" "$stderr_content"

echo ""
echo "Test 3: tea labels list returning malformed JSON returns non-zero with empty stdout"
reset_fake_tea
REPOLENS_FAKE_TEA_RC=0
REPOLENS_FAKE_TEA_STDOUT='not json'
err_file="$TMPDIR/t3.err"
out="$(run_wrapper tea forge_label_list_names owner/repo 2>"$err_file")"
rc=$?
assert_rc_nonzero "malformed tea JSON is observable to callers" "$rc"
assert_eq "malformed tea JSON produces empty stdout" "" "$out"
assert_contains "warning mentions jq parse failure for tea" \
  "jq failed to parse tea output" "$(cat "$err_file")"

echo ""
echo "Test 4: tea labels list requires explicit target binding"
reset_fake_tea
tea_log="$TMPDIR/t4-tea.log"
: > "$tea_log"
unset FORGE_PROJECT_PATH FORGE_TEA_LOGIN
REPOLENS_FAKE_TEA_LOG="$tea_log"
out="$(run_wrapper tea forge_label_list_names owner/repo 2>&1)"
rc=$?
FORGE_PROJECT_PATH="$FORGE_TEST_PROJECT"
assert_rc_nonzero "missing tea label-list target binding exits non-zero" "$rc"
assert_contains "missing tea label-list target binding explains target binding" \
  "target binding" "$out"
assert_log_empty "missing tea label-list target binding does not call tea" "$tea_log"

echo ""
echo "Test 5: tea labels list uses FORGE_TEA_LOGIN when FORGE_PROJECT_PATH is unavailable"
reset_fake_tea
tea_log="$TMPDIR/t5-tea.log"
: > "$tea_log"
unset FORGE_PROJECT_PATH
FORGE_TEA_LOGIN="work-login"
REPOLENS_FAKE_TEA_RC=0
REPOLENS_FAKE_TEA_STDOUT='[{"name":"audit:foo"}]'
REPOLENS_FAKE_TEA_LOG="$tea_log"
out="$(run_wrapper tea forge_label_list_names owner/repo 2>/dev/null)"
rc=$?
FORGE_PROJECT_PATH="$FORGE_TEST_PROJECT"
unset FORGE_TEA_LOGIN
logged="$(cat "$tea_log")"
assert_rc_zero "FORGE_TEA_LOGIN label-list fallback exits zero" "$rc"
assert_eq "FORGE_TEA_LOGIN label-list fallback prints the parsed name" "audit:foo" "$out"
assert_contains "FORGE_TEA_LOGIN label-list fallback targets owner/repo with login" \
  "--repo owner/repo --login work-login" "$logged"
assert_not_contains "FORGE_TEA_LOGIN label-list fallback does not pass a remote selector" \
  "--remote" "$logged"

# ---------------------------------------------------------------------------
# Group 2: fj — happy path, output parsing, host requirement
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 2: fj ---"
echo ""

echo "Test 6: fj labels list succeeds and prints one name per line"
reset_fake_fj
FORGE_HOST="codeberg.org"
fj_log="$TMPDIR/t6-fj.log"
argv_dump="$TMPDIR/t6-argv.log"
: > "$fj_log"
REPOLENS_FAKE_FJ_RC=0
REPOLENS_FAKE_FJ_LABELS_NAMES="audit:foo enhancement"
REPOLENS_FAKE_FJ_LOG="$fj_log"
REPOLENS_FAKE_FJ_ARGV_DUMP="$argv_dump"
err_file="$TMPDIR/t6.err"
out="$(run_wrapper fj forge_label_list_names owner/repo 2>"$err_file")"
rc=$?
logged="$(cat "$fj_log")"
argv_content="$(cat "$argv_dump" 2>/dev/null || true)"
assert_rc_zero "fj label list succeeds when fj returns a label set" "$rc"
assert_eq "fj label list prints names one per line in argv order" \
  $'audit:foo\nenhancement' "$out"
assert_eq "fj label list is silent on stderr" "" "$(cat "$err_file")"
assert_contains "fj label list argv passes the explicit FORGE_HOST" \
  "-H codeberg.org" "$logged"
assert_contains "fj label list argv targets the owner/repo slug" "owner/repo" "$logged"
assert_contains "fj label list argv invokes the labels-list subcommand" \
  "labels" "$logged"
assert_not_contains "fj label list argv does not request invalid JSON style" \
  "--style json" "$logged"
assert_contains "fj label list argv keeps owner/repo as one argument" "<owner/repo>" "$argv_content"

echo ""
echo "Test 6b: fj labels list preserves structured JSON compatibility without invalid style"
reset_fake_fj
FORGE_HOST="codeberg.org"
fj_log="$TMPDIR/t6b-fj.log"
: > "$fj_log"
REPOLENS_FAKE_FJ_RC=0
REPOLENS_FAKE_FJ_STDOUT='{"data":[{"name":"audit:foo"},{"name":"enhancement"}]}'
REPOLENS_FAKE_FJ_LOG="$fj_log"
err_file="$TMPDIR/t6b.err"
out="$(run_wrapper fj forge_label_list_names owner/repo 2>"$err_file")"
rc=$?
assert_rc_zero "fj JSON-compatible label output exits zero" "$rc"
assert_eq "fj JSON-compatible label output prints names one per line" \
  $'audit:foo\nenhancement' "$out"
assert_eq "fj JSON-compatible label output is silent on stderr" "" "$(cat "$err_file")"
assert_not_contains "fj JSON-compatible path still avoids invalid style" \
  "--style json" "$(cat "$fj_log")"

echo ""
echo "Test 6c: fj labels list preserves CSV/header parsing without invalid style"
reset_fake_fj
FORGE_HOST="codeberg.org"
fj_log="$TMPDIR/t6c-fj.log"
: > "$fj_log"
REPOLENS_FAKE_FJ_RC=0
REPOLENS_FAKE_FJ_STDOUT=$'id,color,name,description\n1,#aabbcc,audit:foo,\n2,#ddeeff,enhancement,'
REPOLENS_FAKE_FJ_LOG="$fj_log"
err_file="$TMPDIR/t6c.err"
out="$(run_wrapper fj forge_label_list_names owner/repo 2>"$err_file")"
rc=$?
assert_rc_zero "fj CSV-compatible label output exits zero" "$rc"
assert_eq "fj CSV-compatible label output prints names one per line" \
  $'audit:foo\nenhancement' "$out"
assert_eq "fj CSV-compatible label output is silent on stderr" "" "$(cat "$err_file")"
assert_not_contains "fj CSV-compatible path still avoids invalid style" \
  "--style json" "$(cat "$fj_log")"

echo ""
echo "Test 6d: fj labels list accepts top-level JSON arrays without invalid style"
reset_fake_fj
FORGE_HOST="codeberg.org"
fj_log="$TMPDIR/t6d-fj.log"
: > "$fj_log"
REPOLENS_FAKE_FJ_RC=0
REPOLENS_FAKE_FJ_STDOUT='[{"name":"audit:foo"},{"name":"enhancement"}]'
REPOLENS_FAKE_FJ_LOG="$fj_log"
err_file="$TMPDIR/t6d.err"
out="$(run_wrapper fj forge_label_list_names owner/repo 2>"$err_file")"
rc=$?
assert_rc_zero "fj top-level JSON array label output exits zero" "$rc"
assert_eq "fj top-level JSON array output prints names one per line" \
  $'audit:foo\nenhancement' "$out"
assert_eq "fj top-level JSON array output is silent on stderr" "" "$(cat "$err_file")"
assert_not_contains "fj top-level JSON array path still avoids invalid style" \
  "--style json" "$(cat "$fj_log")"

echo ""
echo "Test 6e: fj labels list accepts labels-keyed JSON objects without invalid style"
reset_fake_fj
FORGE_HOST="codeberg.org"
fj_log="$TMPDIR/t6e-fj.log"
: > "$fj_log"
REPOLENS_FAKE_FJ_RC=0
REPOLENS_FAKE_FJ_STDOUT='{"labels":[{"name":"audit:foo"},{"name":"enhancement"}]}'
REPOLENS_FAKE_FJ_LOG="$fj_log"
err_file="$TMPDIR/t6e.err"
out="$(run_wrapper fj forge_label_list_names owner/repo 2>"$err_file")"
rc=$?
assert_rc_zero "fj labels-keyed JSON object output exits zero" "$rc"
assert_eq "fj labels-keyed JSON object output prints names one per line" \
  $'audit:foo\nenhancement' "$out"
assert_eq "fj labels-keyed JSON object output is silent on stderr" "" "$(cat "$err_file")"
assert_not_contains "fj labels-keyed JSON object path still avoids invalid style" \
  "--style json" "$(cat "$fj_log")"

echo ""
echo "Test 7: fj labels list works against an HTTPS self-hosted host"
reset_fake_fj
FORGE_HOST="https://forge.example.com:3000"
fj_log="$TMPDIR/t7-fj.log"
: > "$fj_log"
REPOLENS_FAKE_FJ_RC=0
REPOLENS_FAKE_FJ_LABELS_NAMES="audit:foo"
REPOLENS_FAKE_FJ_LOG="$fj_log"
out="$(run_wrapper fj forge_label_list_names owner/repo 2>/dev/null)"
rc=$?
FORGE_HOST="codeberg.org"
assert_rc_zero "self-hosted fj label list exits zero" "$rc"
assert_eq "self-hosted fj label list prints the parsed name" "audit:foo" "$out"
assert_contains "self-hosted fj label list preserves the HTTPS host" \
  "-H https://forge.example.com:3000" "$(cat "$fj_log")"

echo ""
echo "Test 8: fj labels list failure returns non-zero with empty stdout and a diagnostic warn"
reset_fake_fj
FORGE_HOST="codeberg.org"
REPOLENS_FAKE_FJ_RC=9
REPOLENS_FAKE_FJ_STDERR='Forgejo API unavailable'
err_file="$TMPDIR/t8.err"
out="$(run_wrapper fj forge_label_list_names owner/repo 2>"$err_file")"
rc=$?
stderr_content="$(cat "$err_file")"
assert_rc_nonzero "fj label-list failure is observable to callers" "$rc"
assert_eq "fj label-list failure produces empty stdout" "" "$out"
assert_contains "warning mentions fj failed" "fj failed" "$stderr_content"
assert_contains "warning includes the fj exit code" "rc=9" "$stderr_content"
assert_contains "warning includes the target repo" "repo=owner/repo" "$stderr_content"
assert_contains "warning includes the first fj stderr line" \
  "Forgejo API unavailable" "$stderr_content"

echo ""
echo "Test 9: fj labels list requires FORGE_HOST before invoking fj"
reset_fake_fj
fj_log="$TMPDIR/t9-fj.log"
: > "$fj_log"
unset FORGE_HOST
REPOLENS_FAKE_FJ_LOG="$fj_log"
out="$(run_wrapper fj forge_label_list_names owner/repo 2>&1)"
rc=$?
FORGE_HOST="codeberg.org"
assert_rc_nonzero "fj label list without FORGE_HOST exits non-zero" "$rc"
assert_contains "missing label-list FORGE_HOST reports the required host binding" \
  "FORGE_HOST" "$out"
assert_log_empty "missing label-list FORGE_HOST does not call fj" "$fj_log"

echo ""
echo "Test 9b: fj labels list returning unparseable CSV output returns non-zero with empty stdout"
# Symmetric coverage for the tea malformed-output case (Test 3). Official
# minimal output is plain names, so the non-JSON failure sample must be a
# structured listing that cannot identify a name column.
reset_fake_fj
FORGE_HOST="codeberg.org"
REPOLENS_FAKE_FJ_RC=0
REPOLENS_FAKE_FJ_STDOUT=$'id,title,color\n1,audit:foo,#aabbcc'
err_file="$TMPDIR/t9b.err"
out="$(run_wrapper fj forge_label_list_names owner/repo 2>"$err_file")"
rc=$?
assert_rc_nonzero "unparseable fj label output is observable to callers" "$rc"
assert_eq "unparseable fj label output produces empty stdout" "" "$out"
assert_contains "warning identifies forge_label_list_names for fj parse failure" \
  "forge_label_list_names" "$(cat "$err_file")"

echo ""
echo "Test 9c: fj labels list returning malformed JSON returns non-zero with empty stdout"
reset_fake_fj
FORGE_HOST="codeberg.org"
REPOLENS_FAKE_FJ_RC=0
REPOLENS_FAKE_FJ_STDOUT='{"data":'
err_file="$TMPDIR/t9c.err"
out="$(run_wrapper fj forge_label_list_names owner/repo 2>"$err_file")"
rc=$?
assert_rc_nonzero "malformed fj JSON label output is observable to callers" "$rc"
assert_eq "malformed fj JSON label output produces empty stdout" "" "$out"
assert_contains "warning mentions jq parse failure for fj" \
  "jq failed to parse fj output" "$(cat "$err_file")"

# ---------------------------------------------------------------------------
# Group 2b: empty label-set carve-out — rc=0 with empty stdout
# ---------------------------------------------------------------------------
# Empty successful label output must return success with empty stdout so the
# bootstrap creates all desired labels via the diff path, rather than
# incorrectly falling through to the create-all fallback. tea reports this as
# JSON []; official fj minimal output is empty.
echo ""
echo "--- Group 2b: empty label set returns rc=0 ---"
echo ""

echo "Test 9d: tea returning [] is success with empty stdout (not a parse failure)"
reset_fake_tea
FORGE_PROJECT_PATH="$FORGE_TEST_PROJECT"
FORGE_REMOTE_NAME="origin"
unset FORGE_TEA_LOGIN
REPOLENS_FAKE_TEA_RC=0
REPOLENS_FAKE_TEA_STDOUT='[]'
err_file="$TMPDIR/t9c.err"
out="$(run_wrapper tea forge_label_list_names owner/repo 2>"$err_file")"
rc=$?
assert_rc_zero "empty tea label set exits zero (not parse-fail)" "$rc"
assert_eq "empty tea label set produces empty stdout" "" "$out"
assert_eq "empty tea label set emits no warning" "" "$(cat "$err_file")"

echo ""
echo "Test 9e: fj returning an empty official label listing is success with empty stdout"
reset_fake_fj
FORGE_HOST="codeberg.org"
REPOLENS_FAKE_FJ_RC=0
REPOLENS_FAKE_FJ_STDOUT=''
err_file="$TMPDIR/t9d.err"
out="$(run_wrapper fj forge_label_list_names owner/repo 2>"$err_file")"
rc=$?
assert_rc_zero "empty fj label set exits zero (not parse-fail)" "$rc"
assert_eq "empty fj label set produces empty stdout" "" "$out"
assert_eq "empty fj label set emits no warning" "" "$(cat "$err_file")"

echo ""
echo "Test 9f: tea defaults FORGE_REMOTE_NAME to 'origin' when only FORGE_PROJECT_PATH is set"
# Test 1 sets FORGE_REMOTE_NAME explicitly. Locks the default at
# lib/forge.sh:509 (`--remote "${FORGE_REMOTE_NAME:-origin}"`) so the
# cascade does not regress to passing an empty --remote flag, which would
# bind to the wrong target in environments without an explicit override.
reset_fake_tea
FORGE_PROJECT_PATH="$FORGE_TEST_PROJECT"
unset FORGE_REMOTE_NAME FORGE_TEA_LOGIN
tea_log="$TMPDIR/t9e-tea.log"
: > "$tea_log"
REPOLENS_FAKE_TEA_RC=0
REPOLENS_FAKE_TEA_STDOUT='[{"name":"audit:foo"}]'
REPOLENS_FAKE_TEA_LOG="$tea_log"
out="$(run_wrapper tea forge_label_list_names owner/repo 2>/dev/null)"
rc=$?
FORGE_REMOTE_NAME="origin"
logged="$(cat "$tea_log")"
assert_rc_zero "tea label list defaults remote without FORGE_REMOTE_NAME" "$rc"
assert_eq "tea label list still prints names with default remote" "audit:foo" "$out"
assert_contains "tea label list defaults --remote to origin" "--remote origin" "$logged"

# ---------------------------------------------------------------------------
# Group 3: end-to-end diff path — the whole point of the issue
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 3: end-to-end through forge_label_bootstrap ---"
echo ""

echo "Test 10: tea bootstrap creates only labels missing from the forge"
reset_fake_tea
tea_log="$TMPDIR/t10-tea.log"
: > "$tea_log"
export REPOLENS_LABEL_CACHE_DIR="$TMPDIR/cache-tea-t10"
rm -rf "$REPOLENS_LABEL_CACHE_DIR"
mkdir -p "$REPOLENS_LABEL_CACHE_DIR"
export REPOLENS_LABEL_CACHE_TTL=600
FORGE_PROJECT_PATH="$FORGE_TEST_PROJECT"
FORGE_REMOTE_NAME="origin"
unset FORGE_TEA_LOGIN
# tea label list returns one of the three desired labels; the other two
# must be created.
REPOLENS_FAKE_TEA_RC=0
REPOLENS_FAKE_TEA_STDOUT='[{"name":"audit:security/injection"}]'
REPOLENS_FAKE_TEA_LOG="$tea_log"
desired_file="$TMPDIR/t10-desired.txt"
cat > "$desired_file" <<'EOF'
audit:security/injection=ff5555
audit:code-quality/naming=ededed
spec:payments-flow=c9b1ff
EOF
out="$(run_wrapper tea forge_label_bootstrap owner/repo "$desired_file" 2>/dev/null)"
rc=$?
unset REPOLENS_LABEL_CACHE_DIR REPOLENS_LABEL_CACHE_TTL
list_count="$(grep -c 'labels list' "$tea_log" 2>/dev/null || true)"
create_count="$(grep -c 'labels create' "$tea_log" 2>/dev/null || true)"
assert_rc_zero "tea bootstrap succeeds" "$rc"
assert_eq "tea bootstrap emits no stdout" "" "$out"
assert_eq "tea bootstrap performs exactly one labels-list call" "1" "$list_count"
assert_eq "tea bootstrap creates only the two missing labels" "2" "$create_count"

echo ""
echo "Test 11: fj bootstrap creates only labels missing from the forge"
reset_fake_fj
fj_log="$TMPDIR/t11-fj.log"
: > "$fj_log"
export REPOLENS_LABEL_CACHE_DIR="$TMPDIR/cache-fj-t11"
rm -rf "$REPOLENS_LABEL_CACHE_DIR"
mkdir -p "$REPOLENS_LABEL_CACHE_DIR"
export REPOLENS_LABEL_CACHE_TTL=600
FORGE_HOST="codeberg.org"
REPOLENS_FAKE_FJ_RC=0
REPOLENS_FAKE_FJ_LABELS_NAMES="audit:security/injection"
REPOLENS_FAKE_FJ_LOG="$fj_log"
desired_file="$TMPDIR/t11-desired.txt"
cat > "$desired_file" <<'EOF'
audit:security/injection=ff5555
audit:code-quality/naming=ededed
spec:payments-flow=c9b1ff
EOF
out="$(run_wrapper fj forge_label_bootstrap owner/repo "$desired_file" 2>/dev/null)"
rc=$?
unset REPOLENS_LABEL_CACHE_DIR REPOLENS_LABEL_CACHE_TTL
# The observable contract is one official-compatible list call, then create
# only the missing labels. We grep on "labels" plus " list" to avoid coupling
# this test to unrelated flag ordering.
list_count="$(grep -c 'repo labels .* list' "$fj_log" 2>/dev/null || true)"
create_count="$(grep -c 'repo labels .* create' "$fj_log" 2>/dev/null || true)"
assert_rc_zero "fj bootstrap succeeds" "$rc"
assert_eq "fj bootstrap emits no stdout" "" "$out"
assert_eq "fj bootstrap performs exactly one labels-list call" "1" "$list_count"
assert_eq "fj bootstrap creates only the two missing labels" "2" "$create_count"

echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
