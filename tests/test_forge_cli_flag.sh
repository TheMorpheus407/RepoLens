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

# Tests for issue #58 — --forge flag + require_forge_cli presence check.
#
# Behavioral contract (from the issue):
#   - repolens.sh accepts --forge <gh|tea|fj>. If the flag is omitted, the
#     provider is resolved from detect_forge_provider on the origin remote.
#     If detection yields "unknown" and --forge is not given, repolens.sh
#     dies with a message telling the user to pass --forge explicitly.
#   - lib/forge.sh exports require_forge_cli <provider>, which runs
#     `command -v` on the matching binary (gh / tea / fj). On failure it
#     dies with a provider-specific install hint.
#   - The presence check is skipped entirely under --local, mirroring the
#     existing gh auth status skip.
#
# Tests are split into two groups:
#   Group 1 — unit tests that source lib/core.sh + lib/forge.sh and call
#             require_forge_cli directly. PATH is scrubbed so tea/fj are
#             genuinely absent while gh (a harmless fake stub) remains.
#   Group 2 — integration tests that drive repolens.sh with --dry-run,
#             a throwaway git project, and fake gh/claude binaries. No
#             real AI model is ever invoked (enforced by --dry-run and
#             PATH override).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
TOTAL=0
TMPDIR="$(mktemp -d)"
# Track log directories that integration tests may create, for cleanup.
CREATED_LOG_DIRS=()
_cleanup() {
  rm -rf "$TMPDIR"
  local d
  for d in "${CREATED_LOG_DIRS[@]:-}"; do
    [[ -n "$d" && -d "$d" ]] && rm -rf "$d"
  done
}
trap _cleanup EXIT

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
    echo "  FAIL: $desc (expected to contain: '$needle')"
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
    echo "  FAIL: $desc (unexpected needle='$needle' found)"
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

# Best-effort parse of the run_id from a repolens.sh log so we can clean
# up any logs/<run-id>/ directory the invocation created.
record_run_id() {
  local log_file="$1" run_id
  run_id="$(grep -oE 'RepoLens run [^ ]+ starting' "$log_file" 2>/dev/null | head -1 | awk '{print $3}' || true)"
  if [[ -n "${run_id:-}" ]]; then
    CREATED_LOG_DIRS+=("$SCRIPT_DIR/logs/$run_id")
  fi
}

echo ""
echo "=== Test Suite: --forge flag + require_forge_cli (issue #58) ==="
echo ""

# Sanity checks — prerequisites from #57 must be present.
[[ -f "$SCRIPT_DIR/lib/forge.sh" ]] || { echo "FAIL: lib/forge.sh missing (prerequisite from #57)"; exit 1; }
[[ -f "$SCRIPT_DIR/lib/core.sh" ]] || { echo "FAIL: lib/core.sh missing"; exit 1; }
[[ -f "$SCRIPT_DIR/repolens.sh" ]] || { echo "FAIL: repolens.sh missing"; exit 1; }

# Shared fake-bin setup: a `gh` stub whose `auth status` always succeeds
# and a minimal `claude` stub so validate_agent's require_cmd passes under
# --dry-run. The fake dir is PATH-prepended for integration scenarios;
# unit tests use it as the *entire* PATH to force tea/fj absence.
FAKE_BIN="$TMPDIR/bin"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/gh" <<'SH'
#!/usr/bin/env bash
# Fake gh: auth status always succeeds; other subcommands no-op.
exit 0
SH
chmod +x "$FAKE_BIN/gh"

cat > "$FAKE_BIN/claude" <<'SH'
#!/usr/bin/env bash
# Fake claude: never actually executed under --dry-run. Exists so
# require_cmd claude in repolens.sh succeeds.
exit 0
SH
chmod +x "$FAKE_BIN/claude"

# ---------------------------------------------------------------------------
# Group 1: Unit tests for require_forge_cli (direct function invocation)
# ---------------------------------------------------------------------------
echo "--- Group 1: require_forge_cli unit tests ---"
echo ""

# Subshell helper: PATH-scoped invocation of require_forge_cli. Uses a
# ( ... ) subshell (not `bash -c`) so we don't have to resolve the bash
# binary under a scrubbed PATH. Captures both stdout and stderr so we
# can assert on the install-hint text that die() emits to stderr.
run_require_forge_cli() {
  local path_val="$1"
  shift
  (
    export PATH="$path_val"
    set -uo pipefail
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib/core.sh"
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib/forge.sh"
    require_forge_cli "$@"
  ) 2>&1
}

# Test 1: require_forge_cli gh succeeds when gh is on PATH (fake stub).
echo "Test 1: require_forge_cli gh with gh present → rc=0"
out="$(run_require_forge_cli "$FAKE_BIN" gh)"
rc=$?
assert_rc_zero "require_forge_cli gh returns 0 when gh is present" "$rc"
assert_eq "require_forge_cli gh prints nothing on success" "" "$out"

# Test 2: require_forge_cli tea dies with install hint when tea is absent.
# Failure-path coverage (per the Worked Example in the TDD charter): the
# stub environment forces `command -v tea` to fail so the die-branch runs.
echo ""
echo "Test 2: require_forge_cli tea with tea absent → dies with install hint"
out="$(run_require_forge_cli "$FAKE_BIN" tea)"
rc=$?
assert_rc_nonzero "require_forge_cli tea exits non-zero when tea missing" "$rc"
assert_contains "die message mentions 'tea not found'" "tea not found" "$out"
assert_contains "die message includes an install hint" "install" "$out"

# Test 3: require_forge_cli fj dies with install hint when fj is absent.
# Parallel failure-path coverage for the Forgejo provider branch.
echo ""
echo "Test 3: require_forge_cli fj with fj absent → dies with install hint"
out="$(run_require_forge_cli "$FAKE_BIN" fj)"
rc=$?
assert_rc_nonzero "require_forge_cli fj exits non-zero when fj missing" "$rc"
assert_contains "die message mentions 'fj not found'" "fj not found" "$out"
assert_contains "die message includes an install hint" "install" "$out"

# Test 4: require_forge_cli with an invalid provider name dies. Guards
# against caller typos — a silent pass would mask bugs in the wiring code.
echo ""
echo "Test 4: require_forge_cli bogus → dies (invalid provider guard)"
out="$(run_require_forge_cli "$FAKE_BIN" bogus)"
rc=$?
assert_rc_nonzero "require_forge_cli bogus exits non-zero" "$rc"

# Test 4b: require_forge_cli with an empty provider also dies — a caller
# that passes "$FORGE_PROVIDER" while that var is unset/empty must not
# silently succeed.
echo ""
echo "Test 4b: require_forge_cli '' (empty) → dies (invalid provider guard)"
out="$(run_require_forge_cli "$FAKE_BIN" "")"
rc=$?
assert_rc_nonzero "require_forge_cli with empty provider exits non-zero" "$rc"
assert_contains "die message names 'require_forge_cli'" "require_forge_cli" "$out"

# Test 4c: require_forge_cli gh dies with install hint when gh is ABSENT.
# Symmetric coverage with tests 2 and 3 — the gh failure branch is just as
# important as tea/fj since the gh install hint has its own URL.
# EMPTY_BIN has no gh stub, so `command -v gh` genuinely fails.
EMPTY_BIN="$TMPDIR/empty_bin"
mkdir -p "$EMPTY_BIN"
echo ""
echo "Test 4c: require_forge_cli gh with gh absent → dies with install hint"
out="$(run_require_forge_cli "$EMPTY_BIN" gh)"
rc=$?
assert_rc_nonzero "require_forge_cli gh exits non-zero when gh missing" "$rc"
assert_contains "die message mentions 'gh not found'" "gh not found" "$out"
assert_contains "die message includes an install hint" "install" "$out"

# ---------------------------------------------------------------------------
# Group 2: Integration tests — repolens.sh with --dry-run
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 2: repolens.sh integration tests ---"
echo ""

# Minimal git project so repolens.sh's project-path validation passes.
PROJECT="$TMPDIR/project"
mkdir -p "$PROJECT"
(
  cd "$PROJECT"
  git init -q 2>/dev/null
  git config user.email test@example.com
  git config user.name Test
  echo "# test" > README.md
  git add README.md
  git commit -q -m init 2>/dev/null
) || true
# Add a gitlab origin so detect_forge_provider returns "unknown" — this
# is the most informative fixture because it exercises the
# "auto-detect yields unknown" die branch.
git -C "$PROJECT" remote add origin https://gitlab.com/owner/repo.git 2>/dev/null || true

# PATH override: fake gh + claude take precedence. Real git, jq, timeout,
# bash, etc. still resolve through the system PATH.
export PATH="$FAKE_BIN:$PATH"

# Test 5: repolens.sh source contains the --forge flag (usage text + parser).
# Mirror of test_spec_flag.sh Test 17 — a lightweight grep that fails in the
# red phase before the flag is wired.
echo "Test 5: repolens.sh mentions --forge flag"
if grep -qF -- '--forge' "$SCRIPT_DIR/repolens.sh"; then
  TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1))
  echo "  PASS: --forge appears in repolens.sh"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: --forge not found in repolens.sh"
fi

# Test 6: parser accepts --forge tea under --local + --dry-run. The
# gitlab origin would normally make auto-detect return "unknown", but the
# explicit --forge override short-circuits detection, and --local skips
# the presence check entirely — so even without a real `tea` on PATH the
# run reaches --dry-run and exits 0.
echo ""
echo "Test 6: --forge tea --local --dry-run → exits 0 (flag parsed, check skipped)"
OUT_FILE="$TMPDIR/run6.log"
set +e
bash "$SCRIPT_DIR/repolens.sh" \
  --project "$PROJECT" \
  --agent claude \
  --domain i18n \
  --forge tea \
  --local \
  --dry-run \
  --yes \
  >"$OUT_FILE" 2>&1
rc=$?
set -e
record_run_id "$OUT_FILE"
out6="$(cat "$OUT_FILE")"
assert_rc_zero "--forge tea --local --dry-run exits 0" "$rc"
assert_not_contains "--forge is not rejected as unknown argument" "Unknown argument: --forge" "$out6"
assert_not_contains "presence check skipped under --local (no 'tea not found')" "tea not found" "$out6"

# Test 7: gitlab origin + NO --forge + NO --local → die with instructional
# message telling the user to pass --forge. Exercises the
# "detection returned unknown" branch of the new wiring.
echo ""
echo "Test 7: gitlab origin without --forge / --local → die instructs user to pass --forge"
OUT_FILE="$TMPDIR/run7.log"
set +e
bash "$SCRIPT_DIR/repolens.sh" \
  --project "$PROJECT" \
  --agent claude \
  --domain i18n \
  --dry-run \
  --yes \
  >"$OUT_FILE" 2>&1
rc=$?
set -e
record_run_id "$OUT_FILE"
out7="$(cat "$OUT_FILE")"
assert_rc_nonzero "unknown-origin without --forge exits non-zero" "$rc"
assert_contains "die message instructs user to pass --forge" "--forge" "$out7"

# Test 8: --forge gh overrides an unknown-origin repo. Explicit provider
# plus a fake gh on PATH must let the run proceed past the forge-resolution
# block all the way to --dry-run (exit 0). Confirms the override path.
echo ""
echo "Test 8: --forge gh overrides gitlab origin → --dry-run exits 0"
OUT_FILE="$TMPDIR/run8.log"
set +e
bash "$SCRIPT_DIR/repolens.sh" \
  --project "$PROJECT" \
  --agent claude \
  --domain i18n \
  --forge gh \
  --dry-run \
  --yes \
  >"$OUT_FILE" 2>&1
rc=$?
set -e
record_run_id "$OUT_FILE"
out8="$(cat "$OUT_FILE")"
assert_rc_zero "--forge gh overrides unknown origin, exits 0" "$rc"
assert_not_contains "no 'detect forge provider' die when --forge is explicit" "detect forge provider" "$out8"
assert_not_contains "no 'gh not found' (fake gh stub is on PATH)" "gh not found" "$out8"

# Test 9: --forge bogus (invalid provider value) hits the validation block
# in repolens.sh (gh|tea|fj whitelist) and dies BEFORE require_forge_cli is
# called. This is a distinct code path from Test 4 (library-level guard) —
# repolens.sh has its own case-esac whitelist and its die message must
# reach the user.
echo ""
echo "Test 9: --forge bogus → die with 'Invalid --forge' (repolens-level validation)"
OUT_FILE="$TMPDIR/run9.log"
set +e
bash "$SCRIPT_DIR/repolens.sh" \
  --project "$PROJECT" \
  --agent claude \
  --domain i18n \
  --forge bogus \
  --local \
  --dry-run \
  --yes \
  >"$OUT_FILE" 2>&1
rc=$?
set -e
record_run_id "$OUT_FILE"
out9="$(cat "$OUT_FILE")"
assert_rc_nonzero "--forge bogus exits non-zero" "$rc"
assert_contains "die message mentions 'Invalid --forge'" "Invalid --forge" "$out9"

# Test 10: --forge with NO argument (last positional) dies with the
# arg-required guard. Exercises the [[ $# -ge 2 ]] check in the parser.
echo ""
echo "Test 10: --forge with no argument → die with 'requires an argument'"
OUT_FILE="$TMPDIR/run10.log"
set +e
bash "$SCRIPT_DIR/repolens.sh" \
  --project "$PROJECT" \
  --agent claude \
  --domain i18n \
  --local \
  --dry-run \
  --yes \
  --forge \
  >"$OUT_FILE" 2>&1
rc=$?
set -e
record_run_id "$OUT_FILE"
out10="$(cat "$OUT_FILE")"
assert_rc_nonzero "--forge with no argument exits non-zero" "$rc"
assert_contains "die message mentions 'requires an argument'" "requires an argument" "$out10"

# Test 11: github.com origin + NO --forge (auto-detection happy path).
# This is an explicit acceptance criterion from the issue:
# "Auto-detection picks `gh` for a `github.com` origin without --forge".
# End-to-end through repolens.sh: detect_forge_provider returns "gh",
# require_forge_cli finds the fake gh stub, fake gh auth passes, --dry-run
# short-circuits before any agent call. rc=0 is the only way the whole
# chain could have succeeded.
echo ""
echo "Test 11: github.com origin without --forge → auto-detects gh, exits 0"
PROJECT_GH="$TMPDIR/project_gh"
mkdir -p "$PROJECT_GH"
(
  cd "$PROJECT_GH"
  git init -q 2>/dev/null
  git config user.email test@example.com
  git config user.name Test
  echo "# test" > README.md
  git add README.md
  git commit -q -m init 2>/dev/null
) || true
git -C "$PROJECT_GH" remote add origin https://github.com/owner/repo.git 2>/dev/null || true

OUT_FILE="$TMPDIR/run11.log"
set +e
bash "$SCRIPT_DIR/repolens.sh" \
  --project "$PROJECT_GH" \
  --agent claude \
  --domain i18n \
  --dry-run \
  --yes \
  >"$OUT_FILE" 2>&1
rc=$?
set -e
record_run_id "$OUT_FILE"
out11="$(cat "$OUT_FILE")"
assert_rc_zero "github.com origin auto-detects gh, exits 0" "$rc"
assert_not_contains "no 'Could not detect forge provider' on github origin" "Could not detect forge provider" "$out11"
assert_not_contains "no 'Pass --forge' die on github origin" "Pass --forge" "$out11"

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
