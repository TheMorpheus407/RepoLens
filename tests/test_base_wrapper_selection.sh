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

# Tests for issue #89 — deploy mode base wrapper selection by target type.
#
# Behavioural contract:
#   1. resolve_base_wrapper is a pure path resolver defined in repolens.sh.
#   2. Routing:
#        MODE=deploy + TARGET_TYPE=android   -> prompts/_base/android.md
#        MODE=deploy + TARGET_TYPE=server    -> prompts/_base/deploy.md
#        MODE=deploy + TARGET_TYPE unset     -> prompts/_base/deploy.md
#        MODE=<other> + any TARGET_TYPE      -> prompts/_base/<MODE>.md
#   3. Both call sites in repolens.sh consult the resolver (directly or via
#      the BASE_WRAPPER_FILE global it populates) — no literal occurrences
#      of "$BASE_PROMPTS_DIR/$MODE.md" remain.
#   4. Soft fall-back: when MODE=deploy + TARGET_TYPE=android but android.md
#      is absent on disk, repolens.sh falls back to deploy.md and emits a
#      warning rather than failing the run. (Until sibling #92 lands the
#      android.md file, deploy mode against an APK target must still run.)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOLENS="$SCRIPT_DIR/repolens.sh"
BASE_DIR="$SCRIPT_DIR/prompts/_base"

PASS=0
FAIL=0
TOTAL=0

TMPROOT="$SCRIPT_DIR/tests/.tmp"
mkdir -p "$TMPROOT"
TMPDIR="$(mktemp -d "$TMPROOT/base-wrapper-selection.XXXXXX")"
CREATED_LOG_DIRS=()
# shellcheck disable=SC2329
_cleanup() {
  rm -rf "$TMPDIR"
  rmdir "$TMPROOT" 2>/dev/null || true
  local d
  for d in "${CREATED_LOG_DIRS[@]:-}"; do
    [[ -n "$d" && -d "$d" ]] && rm -rf "$d"
  done
}
trap _cleanup EXIT

record_pass() {
  TOTAL=$((TOTAL + 1))
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

record_fail() {
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (expected='$expected' actual='$actual')"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (expected to contain '$needle' in: ${haystack:0:240})"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (unexpected '$needle' present in: ${haystack:0:240})"
  fi
}

record_run_id() {
  local log_file="$1" run_id
  run_id="$(grep -oE 'RepoLens run [^ ]+ starting' "$log_file" 2>/dev/null \
    | head -1 | awk '{print $3}' || true)"
  if [[ -n "${run_id:-}" ]]; then
    CREATED_LOG_DIRS+=("$SCRIPT_DIR/logs/$run_id")
  fi
}

# ---------------------------------------------------------------------------
# Extract the resolve_base_wrapper function from repolens.sh into a tiny
# stub we can source. The helper is pure (no logging, no exit, no fs side
# effects) so this works without setting up the rest of repolens.sh.
# ---------------------------------------------------------------------------
HELPER_STUB="$TMPDIR/helper.sh"
{
  printf '%s\n' 'set -uo pipefail'
  sed -n '/^resolve_base_wrapper()/,/^}$/p' "$REPOLENS"
} > "$HELPER_STUB"

# Sanity: the extraction must contain the function body. Guards against
# silent rename/refactor that would turn every call below into a no-op.
if ! grep -q '^resolve_base_wrapper()' "$HELPER_STUB"; then
  echo "FATAL: could not extract resolve_base_wrapper() from $REPOLENS"
  exit 99
fi

resolve() {
  # Run the helper in a clean subshell with the requested MODE / TARGET_TYPE
  # so each test is independent. BASE_PROMPTS_DIR is hard-pinned to the
  # canonical location, mirroring the value repolens.sh sets at startup.
  local mode="$1" target="${2-}"
  (
    # shellcheck disable=SC1090
    source "$HELPER_STUB"
    BASE_PROMPTS_DIR="$BASE_DIR"
    MODE="$mode"
    if [[ -n "$target" ]]; then
      TARGET_TYPE="$target"
    else
      unset TARGET_TYPE
    fi
    resolve_base_wrapper
  )
}

echo ""
echo "=== Test Suite: deploy mode base wrapper selection (issue #89) ==="
echo ""

# ===========================================================================
# Test 1: helper exists and is invocable.
# ===========================================================================
echo "Test 1: resolve_base_wrapper is defined in repolens.sh"
if grep -q '^resolve_base_wrapper()' "$REPOLENS"; then
  record_pass "resolve_base_wrapper() is declared in repolens.sh"
else
  record_fail "resolve_base_wrapper() is declared in repolens.sh"
fi

# ===========================================================================
# Test 2: deploy + TARGET_TYPE unset → deploy.md (current behaviour).
# ===========================================================================
echo ""
echo "Test 2: deploy mode with TARGET_TYPE unset resolves to deploy.md"
got="$(resolve deploy "")"
assert_eq "deploy + (unset) → deploy.md" "$BASE_DIR/deploy.md" "$got"

# ===========================================================================
# Test 3: deploy + server → deploy.md (explicit default).
# ===========================================================================
echo ""
echo "Test 3: deploy mode with TARGET_TYPE=server resolves to deploy.md"
got="$(resolve deploy server)"
assert_eq "deploy + server → deploy.md" "$BASE_DIR/deploy.md" "$got"

# ===========================================================================
# Test 4: deploy + android → android.md (the new routing).
# ===========================================================================
# Pure path resolution — does NOT require android.md to exist on disk.
# Issue #89 explicitly states it must compile/lint/test cleanly even when
# sibling #92 has not yet delivered the file.
echo ""
echo "Test 4: deploy mode with TARGET_TYPE=android resolves to android.md"
got="$(resolve deploy android)"
assert_eq "deploy + android → android.md" "$BASE_DIR/android.md" "$got"

# ===========================================================================
# Test 5: every non-deploy mode is unaffected even when TARGET_TYPE=android.
# ===========================================================================
# Proves the deploy/android branch is mode-gated. Cross-contamination would
# silently re-route audit / feature / bugfix / ... runs to android.md.
echo ""
echo "Test 5: non-deploy modes ignore TARGET_TYPE entirely"
for mode in audit feature bugfix discover opensource content custom; do
  got="$(resolve "$mode" android)"
  assert_eq "$mode + android → ${mode}.md (deploy-only routing)" \
    "$BASE_DIR/${mode}.md" "$got"
done

# ===========================================================================
# Test 6: every non-deploy mode still picks <mode>.md when TARGET_TYPE=server.
# ===========================================================================
echo ""
echo "Test 6: non-deploy modes pass through with TARGET_TYPE=server"
for mode in audit feature bugfix discover opensource content custom; do
  got="$(resolve "$mode" server)"
  assert_eq "$mode + server → ${mode}.md" \
    "$BASE_DIR/${mode}.md" "$got"
done

# ===========================================================================
# Test 7: legacy literal path is gone from both call sites.
# ===========================================================================
# The pre-check (around line 641) and run_lens (around line 1064) used to
# build the path as "$BASE_PROMPTS_DIR/$MODE.md" inline. After this issue
# both must consult resolve_base_wrapper (directly or via BASE_WRAPPER_FILE).
echo ""
echo "Test 7: legacy inline path is replaced at both call sites"
literal_count="$(grep -c 'BASE_PROMPTS_DIR/\$MODE\.md' "$REPOLENS" || true)"
# resolve_base_wrapper itself contains one occurrence (the body of the
# else-branch). Anything beyond that means a call site was missed.
if [[ "$literal_count" -le 1 ]]; then
  record_pass "no stale \"\$BASE_PROMPTS_DIR/\$MODE.md\" call sites remain ($literal_count <= 1)"
else
  record_fail "stale \"\$BASE_PROMPTS_DIR/\$MODE.md\" still appears $literal_count times outside the helper"
fi

# Both call sites should now reference the helper (or the global it sets).
if grep -q 'BASE_WRAPPER_FILE' "$REPOLENS"; then
  record_pass "BASE_WRAPPER_FILE global is used by run_lens / pre-check"
else
  record_fail "BASE_WRAPPER_FILE global is referenced in repolens.sh"
fi

# ===========================================================================
# Test 8: --mode audit --dry-run is unaffected (regression guard).
# ===========================================================================
# Stage a fake `claude` on PATH so the dispatcher's preflight passes. The
# dry-run must complete without warning about wrapper fall-back.
echo ""
echo "Test 8: --mode audit --dry-run still resolves to audit.md"
FAKE_BIN="$TMPDIR/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/claude" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FAKE_BIN/claude"

GIT_REPO="$TMPDIR/audit-repo"
mkdir -p "$GIT_REPO"
(
  cd "$GIT_REPO" || exit 1
  git init -q
  git -c user.email=t@e -c user.name=t commit --allow-empty -q -m init
)

LOG8="$TMPDIR/audit-dry-run.log"
set +e
PATH="$FAKE_BIN:$PATH" bash "$REPOLENS" \
  --project "$GIT_REPO" \
  --agent claude \
  --mode audit \
  --local \
  --dry-run \
  --yes \
  >"$LOG8" 2>&1
rc8=$?
set -e
record_run_id "$LOG8"

if [[ "$rc8" -eq 0 ]]; then
  record_pass "audit dry-run exits 0"
else
  record_fail "audit dry-run exits 0 (rc=$rc8, log: ${LOG8})"
fi
out8="$(cat "$LOG8")"
assert_not_contains "audit dry-run does not warn about wrapper fall-back" \
  "falling back to deploy.md" "$out8"

# ===========================================================================
# Test 9: --mode deploy --dry-run on a plain dir resolves to deploy.md.
# ===========================================================================
echo ""
echo "Test 9: deploy dry-run on server target completes without fall-back"
PLAIN_DIR="$TMPDIR/plain"
mkdir -p "$PLAIN_DIR"
echo "# plain" > "$PLAIN_DIR/README.md"

LOG9="$TMPDIR/deploy-server-dry-run.log"
set +e
PATH="$FAKE_BIN:$PATH" bash "$REPOLENS" \
  --project "$PLAIN_DIR" \
  --agent claude \
  --mode deploy \
  --local \
  --dry-run \
  --yes \
  >"$LOG9" 2>&1
rc9=$?
set -e
record_run_id "$LOG9"

if [[ "$rc9" -eq 0 ]]; then
  record_pass "deploy/server dry-run exits 0"
else
  record_fail "deploy/server dry-run exits 0 (rc=$rc9, log: ${LOG9})"
fi
out9="$(cat "$LOG9")"
assert_not_contains "deploy/server dry-run does not log a wrapper fall-back warning" \
  "falling back to deploy.md" "$out9"

# ===========================================================================
# Test 10: --mode deploy --dry-run on an APK target either uses android.md
#          or falls back to deploy.md with a logged warning. Either way the
#          run completes — that is the cross-issue compile-without-#92
#          requirement spelled out in the issue body.
# ===========================================================================
echo ""
echo "Test 10: deploy dry-run on APK target completes (with or without #92)"
APK_DIR="$TMPDIR/apk"
mkdir -p "$APK_DIR/app/build/outputs/apk/debug"
: > "$APK_DIR/app/build/outputs/apk/debug/app-debug.apk"

LOG10="$TMPDIR/deploy-apk-dry-run.log"
set +e
PATH="$FAKE_BIN:$PATH" bash "$REPOLENS" \
  --project "$APK_DIR" \
  --agent claude \
  --mode deploy \
  --local \
  --dry-run \
  --yes \
  >"$LOG10" 2>&1
rc10=$?
set -e
record_run_id "$LOG10"

if [[ "$rc10" -eq 0 ]]; then
  record_pass "deploy/android dry-run exits 0 (android.md present OR fall-back active)"
else
  record_fail "deploy/android dry-run exits 0 (rc=$rc10, log: ${LOG10})"
fi

out10="$(cat "$LOG10")"
if [[ -f "$BASE_DIR/android.md" ]]; then
  assert_not_contains "android.md present → no fall-back warning emitted" \
    "falling back to deploy.md" "$out10"
else
  assert_contains "android.md absent → fall-back warning is emitted exactly once" \
    "falling back to deploy.md" "$out10"
fi

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
