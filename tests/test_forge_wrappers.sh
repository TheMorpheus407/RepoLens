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

# Tests for issue #59 — forge_auth_status / forge_label_create wrappers.
#
# Behavioural contract (from the issue body + research.md):
#   - lib/forge.sh exports forge_auth_status and
#     forge_label_create <label> <color> <owner/repo>.
#   - Both case-dispatch on $FORGE_PROVIDER. The gh branch is implemented
#     today; tea/fj branches die "not yet implemented" (pointing at the
#     follow-up issues #61/#62).
#   - forge_auth_status dies on gh auth-status failure (exact message
#     preserved for README troubleshooting table: "gh is not authenticated.
#     Run 'gh auth login'.").
#   - forge_label_create's gh branch must SWALLOW non-zero exits (|| true)
#     — labels are best-effort, matching the pre-refactor inline call.
#   - Acceptance regression guard: `grep -rnE '\bgh (auth|label) '
#     repolens.sh` returns no lines (no stray direct calls remain).
#
# All cases are library-level: source lib/core.sh + lib/forge.sh in a
# subshell with a PATH-scoped fake-gh stub. No repolens.sh invocation,
# no real AI model, no real gh binary.

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
    echo "  FAIL: $desc (expected to contain: '$needle'; got: '$haystack')"
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
    echo "  FAIL: $desc (expected non-zero, got 0)"
  fi
}

echo ""
echo "=== Test Suite: forge_auth_status + forge_label_create (issue #59) ==="
echo ""

# Prerequisites.
[[ -f "$SCRIPT_DIR/lib/forge.sh" ]] || { echo "FAIL: lib/forge.sh missing"; exit 1; }
[[ -f "$SCRIPT_DIR/lib/core.sh" ]]  || { echo "FAIL: lib/core.sh missing"; exit 1; }
[[ -f "$SCRIPT_DIR/repolens.sh" ]]  || { echo "FAIL: repolens.sh missing"; exit 1; }

# Fake `gh` stub. Reads REPOLENS_FAKE_GH_RC to decide its exit code
# (default 0) and appends its argv to $TMPDIR/gh.log so tests can
# assert on the exact CLI surface. stderr is intentionally quiet so
# the 2>/dev/null in the real caller is exercised identically here.
FAKE_BIN="$TMPDIR/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/gh" <<'SH'
#!/usr/bin/env bash
# Log the exact argv the wrapper passed us.
printf '%s\n' "$*" >> "${REPOLENS_FAKE_GH_LOG:-/dev/null}"
exit "${REPOLENS_FAKE_GH_RC:-0}"
SH
chmod +x "$FAKE_BIN/gh"

# Subshell helper: sources libs under a PATH that contains only the fake
# gh stub, sets FORGE_PROVIDER, invokes the wrapper, captures merged
# stdout+stderr. The caller asserts on rc via $?.
#
# Args: <provider> <fn> [fn-args...]
run_wrapper() {
  local provider="$1"; shift
  local fn="$1"; shift
  (
    # Fake gh at highest priority so wrappers hit the stub; inherited PATH
    # tail lets the stub's `#!/usr/bin/env bash` shebang resolve on hosts
    # where bash lives outside /usr/bin:/bin (e.g. NixOS).
    export PATH="$FAKE_BIN:/usr/bin:/bin:$PATH"
    export FORGE_PROVIDER="$provider"
    # Forward per-case stub dials into the fake gh's process env. The
    # callers set REPOLENS_FAKE_GH_{RC,LOG} as shell vars via prefix
    # assignment, which are visible in this subshell but not exported —
    # re-export them here so the external stub process actually sees them.
    [[ -n "${REPOLENS_FAKE_GH_RC+x}" ]]  && export REPOLENS_FAKE_GH_RC
    [[ -n "${REPOLENS_FAKE_GH_LOG+x}" ]] && export REPOLENS_FAKE_GH_LOG
    set -uo pipefail
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib/core.sh"
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib/forge.sh"
    "$fn" "$@"
  ) 2>&1
}

# ---------------------------------------------------------------------------
# Group 1: forge_auth_status dispatch
# ---------------------------------------------------------------------------
echo "--- Group 1: forge_auth_status ---"
echo ""

# Test 1: happy path — gh stub exits 0 → wrapper rc=0, no output.
echo "Test 1: forge_auth_status gh (stub rc=0) → rc=0, silent"
REPOLENS_FAKE_GH_RC=0 \
  out="$(run_wrapper gh forge_auth_status)"
rc=$?
assert_rc_zero "forge_auth_status rc=0 when gh auth status succeeds" "$rc"
assert_eq "forge_auth_status prints nothing on success" "" "$out"

# Test 2: failure-path — gh stub exits non-zero → wrapper dies with the
# README-quoted troubleshooting message. This is the load-bearing die
# string the research calls out; do not paraphrase.
echo ""
echo "Test 2: forge_auth_status gh (stub rc=1) → dies with README message"
REPOLENS_FAKE_GH_RC=1 \
  out="$(run_wrapper gh forge_auth_status)"
rc=$?
assert_rc_nonzero "forge_auth_status exits non-zero when gh auth fails" "$rc"
assert_contains "die message preserves 'gh is not authenticated'" \
  "gh is not authenticated" "$out"
assert_contains "die message preserves \"Run 'gh auth login'\" hint" \
  "gh auth login" "$out"

# Test 3: tea branch not yet implemented → dies, mentions #61.
echo ""
echo "Test 3: forge_auth_status tea → dies with 'not yet implemented' + #61"
out="$(run_wrapper tea forge_auth_status)"
rc=$?
assert_rc_nonzero "forge_auth_status tea exits non-zero" "$rc"
assert_contains "die message mentions 'not yet implemented'" \
  "not yet implemented" "$out"
assert_contains "die message references follow-up issue #61" "#61" "$out"

# Test 4: fj branch not yet implemented → dies, mentions #62.
echo ""
echo "Test 4: forge_auth_status fj → dies with 'not yet implemented' + #62"
out="$(run_wrapper fj forge_auth_status)"
rc=$?
assert_rc_nonzero "forge_auth_status fj exits non-zero" "$rc"
assert_contains "die message mentions 'not yet implemented'" \
  "not yet implemented" "$out"
assert_contains "die message references follow-up issue #62" "#62" "$out"

# Test 5: empty FORGE_PROVIDER → default case dies with a clear message.
# Guards against a caller sourcing the module before the provider is set.
echo ""
echo "Test 5: forge_auth_status with empty FORGE_PROVIDER → dies"
out="$(run_wrapper "" forge_auth_status)"
rc=$?
assert_rc_nonzero "forge_auth_status with empty provider exits non-zero" "$rc"

# ---------------------------------------------------------------------------
# Group 2: forge_label_create dispatch + argv contract
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 2: forge_label_create ---"
echo ""

# Test 6: happy path. Stub logs its argv; assert the exact CLI the
# wrapper composes (matches the pre-refactor inline call).
echo "Test 6: forge_label_create gh — stub logs 'label create <label> --color <color> --force -R <owner/repo>'"
GH_LOG="$TMPDIR/gh_test6.log"
: > "$GH_LOG"
REPOLENS_FAKE_GH_RC=0 REPOLENS_FAKE_GH_LOG="$GH_LOG" \
  out="$(run_wrapper gh forge_label_create my-label abcdef owner/repo)"
rc=$?
logged="$(cat "$GH_LOG")"
assert_rc_zero "forge_label_create happy path rc=0" "$rc"
assert_contains "gh stub received the label name"  "label create my-label" "$logged"
assert_contains "gh stub received --color abcdef"  "--color abcdef"        "$logged"
assert_contains "gh stub received --force flag"    "--force"               "$logged"
assert_contains "gh stub received -R owner/repo"   "-R owner/repo"         "$logged"

# Test 7: failure-path swallow. Stub returns non-zero; wrapper must
# still exit 0 because the pre-refactor call ended in `|| true`. If the
# wrapper accidentally dropped the swallow, every label-permission
# error would turn into a hard failure — this is the specific
# behavioural guard called out in research.md:case 7.
echo ""
echo "Test 7: forge_label_create gh (stub rc=1) → wrapper rc=0 (|| true preserved)"
REPOLENS_FAKE_GH_RC=1 REPOLENS_FAKE_GH_LOG=/dev/null \
  out="$(run_wrapper gh forge_label_create my-label abcdef owner/repo)"
rc=$?
assert_rc_zero "forge_label_create swallows non-zero gh exit" "$rc"

# Test 8: tea branch not yet implemented → dies, mentions #61.
echo ""
echo "Test 8: forge_label_create tea → dies with 'not yet implemented' + #61"
out="$(run_wrapper tea forge_label_create my-label abcdef owner/repo)"
rc=$?
assert_rc_nonzero "forge_label_create tea exits non-zero" "$rc"
assert_contains "die message mentions 'not yet implemented'" \
  "not yet implemented" "$out"
assert_contains "die message references follow-up issue #61" "#61" "$out"

# Test 9: fj branch not yet implemented → dies, mentions #62.
echo ""
echo "Test 9: forge_label_create fj → dies with 'not yet implemented' + #62"
out="$(run_wrapper fj forge_label_create my-label abcdef owner/repo)"
rc=$?
assert_rc_nonzero "forge_label_create fj exits non-zero" "$rc"
assert_contains "die message mentions 'not yet implemented'" \
  "not yet implemented" "$out"
assert_contains "die message references follow-up issue #62" "#62" "$out"

# Test 10: argument guard — missing any of the three required args
# must die, not silently pass garbage to gh.
echo ""
echo "Test 10: forge_label_create with empty color → dies on missing-arg guard"
out="$(run_wrapper gh forge_label_create my-label "" owner/repo)"
rc=$?
assert_rc_nonzero "forge_label_create with empty color exits non-zero" "$rc"

# ---------------------------------------------------------------------------
# Group 3: acceptance regression guard
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 3: acceptance regression guard ---"
echo ""

# Test 11: direct acceptance criterion from the issue —
# `grep -rnE '\bgh (auth|label) ' repolens.sh` returns no lines.
# Encoded as a test so a future patch that re-inlines `gh auth status`
# or `gh label create ...` fails loudly in CI.
echo "Test 11: 'gh auth' and 'gh label' no longer appear in repolens.sh"
TOTAL=$((TOTAL + 1))
if grep -rnE '\bgh (auth|label) ' "$SCRIPT_DIR/repolens.sh" >/dev/null 2>&1; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: direct 'gh auth' / 'gh label' calls still present in repolens.sh"
  grep -rnE '\bgh (auth|label) ' "$SCRIPT_DIR/repolens.sh" | sed 's/^/    /'
else
  PASS=$((PASS + 1))
  echo "  PASS: no direct 'gh auth' / 'gh label' calls in repolens.sh"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
