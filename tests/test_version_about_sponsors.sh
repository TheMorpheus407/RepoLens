#!/usr/bin/env bash
# Tests for --version, --about, and config/sponsors.json (issue #11)
# Tests are BEHAVIORAL: they execute repolens.sh and assert on exit codes + output,
# never on source code patterns.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOLENS="$SCRIPT_DIR/repolens.sh"

TIMEOUT=15

PASS=0
FAIL=0
TOTAL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    Expected: $(echo "$expected" | head -3)"
    echo "    Actual:   $(echo "$actual" | head -3)"
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
    echo "  FAIL: $desc"
    echo "    Expected to contain: $needle"
    echo "    In output (first 300 chars): ${haystack:0:300}"
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
    echo "  FAIL: $desc"
    echo "    Expected NOT to contain: $needle"
  fi
}

assert_exit_code() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" -eq "$actual" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    Expected exit code: $expected, got: $actual"
  fi
}

# Helper: run repolens.sh with timeout and capture output + exit code.
# Usage: run_repolens [args...]
# Sets: RUN_OUTPUT (combined stdout+stderr), RUN_EXIT (exit code)
run_repolens() {
  local tmp_out
  tmp_out="$(mktemp)"
  timeout "$TIMEOUT" bash "$REPOLENS" "$@" >"$tmp_out" 2>&1
  RUN_EXIT=$?
  RUN_OUTPUT="$(cat "$tmp_out")"
  rm -f "$tmp_out"
}

# --- Setup test fixtures ---
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

setup_test_repo() {
  local repo_dir="$TMPDIR/test-repo"
  mkdir -p "$repo_dir"
  git -C "$repo_dir" init -q
  git -C "$repo_dir" config user.email "test@test.com"
  git -C "$repo_dir" config user.name "Test"
  echo "test" > "$repo_dir/README.md"
  git -C "$repo_dir" add .
  git -C "$repo_dir" commit -q -m "init"
  echo "$repo_dir"
}

TEST_REPO="$(setup_test_repo)"

echo ""
echo "=== Test Suite: --version, --about, and sponsors.json (issue #11) ==="
echo ""

# =====================================================================
# SECTION A: --version Flag Tests
# =====================================================================

# =====================================================================
# Test 1: --version flag is accepted by argument parser
# =====================================================================
# When --version is passed, the script should NOT fail with "Unknown argument".

echo "Test 1: --version flag accepted by argument parser"
run_repolens --version
assert_not_contains "--version not rejected as unknown" "Unknown argument: --version" "$RUN_OUTPUT"

# =====================================================================
# Test 2: --version exits with code 0
# =====================================================================
# --version should be an informational flag that exits cleanly.

echo ""
echo "Test 2: --version exits with code 0"
run_repolens --version
assert_exit_code "--version exit code is 0" 0 "$RUN_EXIT"

# =====================================================================
# Test 3: --version does not require --project or --agent
# =====================================================================
# --version must exit before required-arg validation.

echo ""
echo "Test 3: --version does not require --project or --agent"
run_repolens --version
assert_not_contains "no Missing required argument" "Missing required argument" "$RUN_OUTPUT"

# =====================================================================
# Test 4: --version output contains tool name "RepoLens"
# =====================================================================

echo ""
echo "Test 4: --version output contains RepoLens"
run_repolens --version
assert_contains "--version shows RepoLens" "RepoLens" "$RUN_OUTPUT"

# =====================================================================
# Test 5: --version output contains a version number
# =====================================================================
# The output should include a semver-like version string (e.g., 0.1.0).

echo ""
echo "Test 5: --version output contains version number"
run_repolens --version
TOTAL=$((TOTAL + 1))
if echo "$RUN_OUTPUT" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+'; then
  PASS=$((PASS + 1))
  echo "  PASS: --version contains semver-like version number"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: --version should contain a version number (e.g., 0.1.0)"
  echo "    Output (first 200 chars): ${RUN_OUTPUT:0:200}"
fi

# =====================================================================
# Test 6: --version output contains sponsor information
# =====================================================================
# Per issue #11, sponsor info must appear in --version output.
# This means at least one sponsor URL or the word "sponsor" must appear.

echo ""
echo "Test 6: --version output contains sponsor information"
run_repolens --version
TOTAL=$((TOTAL + 1))
if echo "$RUN_OUTPUT" | grep -qiE 'sponsor|patreon|github.com/sponsors'; then
  PASS=$((PASS + 1))
  echo "  PASS: --version contains sponsor information"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: --version should contain sponsor information"
  echo "    Output (first 300 chars): ${RUN_OUTPUT:0:300}"
fi

# =====================================================================
# SECTION B: --about Flag Tests
# =====================================================================

# =====================================================================
# Test 7: --about flag is accepted by argument parser
# =====================================================================

echo ""
echo "Test 7: --about flag accepted by argument parser"
run_repolens --about
assert_not_contains "--about not rejected as unknown" "Unknown argument: --about" "$RUN_OUTPUT"

# =====================================================================
# Test 8: --about exits with code 0
# =====================================================================

echo ""
echo "Test 8: --about exits with code 0"
run_repolens --about
assert_exit_code "--about exit code is 0" 0 "$RUN_EXIT"

# =====================================================================
# Test 9: --about does not require --project or --agent
# =====================================================================
# --about must exit before required-arg validation.

echo ""
echo "Test 9: --about does not require --project or --agent"
run_repolens --about
assert_not_contains "no Missing required argument for --about" "Missing required argument" "$RUN_OUTPUT"

# =====================================================================
# Test 10: --about output contains tool name "RepoLens"
# =====================================================================

echo ""
echo "Test 10: --about output contains RepoLens"
run_repolens --about
assert_contains "--about shows RepoLens" "RepoLens" "$RUN_OUTPUT"

# =====================================================================
# Test 11: --about output contains a description of the tool
# =====================================================================
# --about should describe what RepoLens does (audit, analysis, lenses, etc.)

echo ""
echo "Test 11: --about output contains tool description"
run_repolens --about
TOTAL=$((TOTAL + 1))
if echo "$RUN_OUTPUT" | grep -qiE 'audit|analysis|lens'; then
  PASS=$((PASS + 1))
  echo "  PASS: --about contains tool description"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: --about should contain a description (audit, analysis, or lens)"
  echo "    Output (first 300 chars): ${RUN_OUTPUT:0:300}"
fi

# =====================================================================
# Test 12: --about output contains sponsor information
# =====================================================================
# Per issue #11, sponsor info must appear in --about output.

echo ""
echo "Test 12: --about output contains sponsor information"
run_repolens --about
TOTAL=$((TOTAL + 1))
if echo "$RUN_OUTPUT" | grep -qiE 'sponsor|patreon|github.com/sponsors'; then
  PASS=$((PASS + 1))
  echo "  PASS: --about contains sponsor information"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: --about should contain sponsor information"
  echo "    Output (first 300 chars): ${RUN_OUTPUT:0:300}"
fi

# =====================================================================
# SECTION C: --help Text Tests
# =====================================================================

# =====================================================================
# Test 13: --help output includes --version documentation
# =====================================================================

echo ""
echo "Test 13: --help mentions --version flag"
help_output="$(timeout "$TIMEOUT" bash "$REPOLENS" --help 2>&1)"
assert_contains "--version in help text" "--version" "$help_output"

# =====================================================================
# Test 14: --help output includes --about documentation
# =====================================================================

echo ""
echo "Test 14: --help mentions --about flag"
assert_contains "--about in help text" "--about" "$help_output"

# =====================================================================
# SECTION D: config/sponsors.json Tests
# =====================================================================

# =====================================================================
# Test 15: config/sponsors.json exists
# =====================================================================

echo ""
echo "Test 15: config/sponsors.json exists"
TOTAL=$((TOTAL + 1))
if [[ -f "$SCRIPT_DIR/config/sponsors.json" ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: config/sponsors.json exists"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: config/sponsors.json does not exist"
fi

# =====================================================================
# Test 16: config/sponsors.json is valid JSON
# =====================================================================

echo ""
echo "Test 16: config/sponsors.json is valid JSON"
TOTAL=$((TOTAL + 1))
if [[ -f "$SCRIPT_DIR/config/sponsors.json" ]] && jq empty "$SCRIPT_DIR/config/sponsors.json" 2>/dev/null; then
  PASS=$((PASS + 1))
  echo "  PASS: config/sponsors.json is valid JSON"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: config/sponsors.json is not valid JSON or does not exist"
fi

# =====================================================================
# Test 17: config/sponsors.json has a "sponsors" array
# =====================================================================

echo ""
echo "Test 17: config/sponsors.json has sponsors array"
TOTAL=$((TOTAL + 1))
if [[ -f "$SCRIPT_DIR/config/sponsors.json" ]] && jq -e '.sponsors | type == "array"' "$SCRIPT_DIR/config/sponsors.json" >/dev/null 2>&1; then
  PASS=$((PASS + 1))
  echo "  PASS: sponsors field is an array"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: config/sponsors.json should have a 'sponsors' array"
fi

# =====================================================================
# Test 18: Each sponsor entry has required fields (name, url, type)
# =====================================================================

echo ""
echo "Test 18: Sponsor entries have name, url, and type fields"
TOTAL=$((TOTAL + 1))
if [[ -f "$SCRIPT_DIR/config/sponsors.json" ]] && \
   jq -e '.sponsors | length > 0 and all(has("name") and has("url") and has("type"))' \
   "$SCRIPT_DIR/config/sponsors.json" >/dev/null 2>&1; then
  PASS=$((PASS + 1))
  echo "  PASS: all sponsor entries have name, url, type"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: sponsor entries should each have name, url, and type fields"
fi

# =====================================================================
# SECTION E: No Sponsor Output in Normal Run
# =====================================================================

# =====================================================================
# Test 19: --dry-run output does NOT contain sponsor URLs
# =====================================================================
# Sponsor info must NOT bleed into normal run output (the core issue).

echo ""
echo "Test 19: --dry-run output does NOT contain sponsor URLs"
run_repolens --project "$TEST_REPO" --agent claude --dry-run
assert_not_contains "no github sponsors URL in dry-run" "github.com/sponsors" "$RUN_OUTPUT"
assert_not_contains "no patreon URL in dry-run" "patreon.com" "$RUN_OUTPUT"

# =====================================================================
# Test 20: --dry-run output does NOT contain sponsor/funding text
# =====================================================================

echo ""
echo "Test 20: --dry-run output does NOT contain sponsor/funding banner"
run_repolens --project "$TEST_REPO" --agent claude --dry-run
assert_not_contains "no sponsor banner in dry-run" "Sponsored by" "$RUN_OUTPUT"
assert_not_contains "no funding banner in dry-run" "Support this project" "$RUN_OUTPUT"

# =====================================================================
# SECTION F: Early Exit / No Side Effects
# =====================================================================

# =====================================================================
# Test 21: --version does not start any lens execution
# =====================================================================
# --version must exit immediately — no lens discovery or execution.

echo ""
echo "Test 21: --version does not trigger lens execution"
run_repolens --version
assert_not_contains "no lens discovery with --version" "Ensuring GitHub labels" "$RUN_OUTPUT"
assert_not_contains "no run summary with --version" "Run Summary" "$RUN_OUTPUT"

# =====================================================================
# Test 22: --about does not start any lens execution
# =====================================================================

echo ""
echo "Test 22: --about does not trigger lens execution"
run_repolens --about
assert_not_contains "no lens discovery with --about" "Ensuring GitHub labels" "$RUN_OUTPUT"
assert_not_contains "no run summary with --about" "Run Summary" "$RUN_OUTPUT"

# =====================================================================
# Test 23: --version combined with other flags still exits early
# =====================================================================
# Even if --project and --agent are given, --version should win.

echo ""
echo "Test 23: --version with other flags still exits early"
run_repolens --version --project "$TEST_REPO" --agent claude
assert_exit_code "--version with other flags exits 0" 0 "$RUN_EXIT"
assert_contains "--version still shows version" "RepoLens" "$RUN_OUTPUT"
assert_not_contains "no lens execution" "Ensuring GitHub labels" "$RUN_OUTPUT"

# =====================================================================
# Test 24: --about combined with other flags still exits early
# =====================================================================

echo ""
echo "Test 24: --about with other flags still exits early"
run_repolens --about --project "$TEST_REPO" --agent claude
assert_exit_code "--about with other flags exits 0" 0 "$RUN_EXIT"
assert_contains "--about still shows about" "RepoLens" "$RUN_OUTPUT"
assert_not_contains "no lens execution" "Ensuring GitHub labels" "$RUN_OUTPUT"

# =====================================================================
# SECTION G: Graceful Degradation (missing sponsors.json)
# =====================================================================

# =====================================================================
# Test 25: --version works when sponsors.json is missing
# =====================================================================
# show_version() should still print version info without sponsors.

echo ""
echo "Test 25: --version works when sponsors.json is missing"
SPONSORS_BACKUP="$(mktemp)"
cp "$SCRIPT_DIR/config/sponsors.json" "$SPONSORS_BACKUP"
mv "$SCRIPT_DIR/config/sponsors.json" "$SCRIPT_DIR/config/sponsors.json.bak"
run_repolens --version
mv "$SCRIPT_DIR/config/sponsors.json.bak" "$SCRIPT_DIR/config/sponsors.json"
assert_exit_code "--version exits 0 without sponsors.json" 0 "$RUN_EXIT"
assert_contains "--version still shows RepoLens" "RepoLens" "$RUN_OUTPUT"
rm -f "$SPONSORS_BACKUP"

# =====================================================================
# Test 26: --about works when sponsors.json is missing
# =====================================================================

echo ""
echo "Test 26: --about works when sponsors.json is missing"
mv "$SCRIPT_DIR/config/sponsors.json" "$SCRIPT_DIR/config/sponsors.json.bak"
run_repolens --about
mv "$SCRIPT_DIR/config/sponsors.json.bak" "$SCRIPT_DIR/config/sponsors.json"
assert_exit_code "--about exits 0 without sponsors.json" 0 "$RUN_EXIT"
assert_contains "--about still shows RepoLens" "RepoLens" "$RUN_OUTPUT"

# =====================================================================
# SECTION H: Actual Sponsor Data Rendering
# =====================================================================

# =====================================================================
# Test 27: --version output contains actual sponsor URLs from JSON
# =====================================================================
# Verify the jq rendering actually emits the URLs from the config file.

echo ""
echo "Test 27: --version output contains actual sponsor URLs"
run_repolens --version
assert_contains "--version shows GitHub Sponsors URL" "github.com/sponsors" "$RUN_OUTPUT"
assert_contains "--version shows Patreon URL" "patreon.com" "$RUN_OUTPUT"

# =====================================================================
# Test 28: --about output contains actual sponsor URLs from JSON
# =====================================================================

echo ""
echo "Test 28: --about output contains actual sponsor URLs"
run_repolens --about
assert_contains "--about shows GitHub Sponsors URL" "github.com/sponsors" "$RUN_OUTPUT"
assert_contains "--about shows Patreon URL" "patreon.com" "$RUN_OUTPUT"

# =====================================================================
# SECTION I: VERSION Consistency
# =====================================================================

# =====================================================================
# Test 29: --version and --about show the same version string
# =====================================================================

echo ""
echo "Test 29: --version and --about show the same version string"
run_repolens --version
VERSION_LINE="$(echo "$RUN_OUTPUT" | head -1)"
run_repolens --about
ABOUT_LINE="$(echo "$RUN_OUTPUT" | head -1)"
assert_eq "--version and --about first line match" "$VERSION_LINE" "$ABOUT_LINE"

# =====================================================================
# Test 30: --version output uses "v" prefix format (RepoLens vX.Y.Z)
# =====================================================================

echo ""
echo "Test 30: --version uses 'RepoLens vX.Y.Z' format"
run_repolens --version
TOTAL=$((TOTAL + 1))
if echo "$RUN_OUTPUT" | grep -qE '^RepoLens v[0-9]+\.[0-9]+\.[0-9]+$'; then
  PASS=$((PASS + 1))
  echo "  PASS: --version uses correct format"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: first line should match 'RepoLens vX.Y.Z'"
  echo "    First line: $(echo "$RUN_OUTPUT" | head -1)"
fi

# =====================================================================
# SECTION J: Empty Sponsors Array
# =====================================================================

# =====================================================================
# Test 31: --version handles empty sponsors array without error
# =====================================================================

echo ""
echo "Test 31: --version handles empty sponsors array"
mv "$SCRIPT_DIR/config/sponsors.json" "$SCRIPT_DIR/config/sponsors.json.bak"
echo '{"sponsors": []}' > "$SCRIPT_DIR/config/sponsors.json"
run_repolens --version
mv "$SCRIPT_DIR/config/sponsors.json.bak" "$SCRIPT_DIR/config/sponsors.json"
assert_exit_code "--version exits 0 with empty sponsors" 0 "$RUN_EXIT"
assert_contains "--version still shows RepoLens" "RepoLens" "$RUN_OUTPUT"

# =====================================================================
# Test 32: --about handles empty sponsors array without error
# =====================================================================

echo ""
echo "Test 32: --about handles empty sponsors array"
mv "$SCRIPT_DIR/config/sponsors.json" "$SCRIPT_DIR/config/sponsors.json.bak"
echo '{"sponsors": []}' > "$SCRIPT_DIR/config/sponsors.json"
run_repolens --about
mv "$SCRIPT_DIR/config/sponsors.json.bak" "$SCRIPT_DIR/config/sponsors.json"
assert_exit_code "--about exits 0 with empty sponsors" 0 "$RUN_EXIT"
assert_contains "--about still shows description" "audit" "$RUN_OUTPUT"

# --- Summary ---
echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
