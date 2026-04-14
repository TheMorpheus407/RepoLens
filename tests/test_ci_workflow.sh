#!/usr/bin/env bash
# Tests for issue #24: Add GitHub Actions CI workflow with ShellCheck and test execution
#
# Behavioral contract:
# 1. .github/workflows/ci.yml must exist and be valid YAML
# 2. Workflow must trigger on push to master and on pull requests
# 3. Workflow must have a ShellCheck linting job
# 4. Workflow must have a test execution job
# 5. ShellCheck job must lint source and test scripts
# 6. Test job must install jq and run the test suite
# 7. Both jobs must use ubuntu-latest and actions/checkout@v4
# 8. README must have a CI status badge linking to the workflow
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

assert_matches() {
  local desc="$1" pattern="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  # Use here-string to avoid SIGPIPE with pipefail when grep -q exits early on large input
  if grep -qP -- "$pattern" <<< "$haystack"; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    Expected to match pattern: $pattern"
  fi
}

assert_file_exists() {
  local desc="$1" filepath="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$filepath" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    File not found: $filepath"
  fi
}

assert_file_not_empty() {
  local desc="$1" filepath="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -s "$filepath" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    File is empty or missing: $filepath"
  fi
}

echo ""
echo "=== Test Suite: GitHub Actions CI Workflow (issue #24) ==="
echo ""

CI_WORKFLOW="$SCRIPT_DIR/.github/workflows/ci.yml"

# =====================================================================
# Section 1: Workflow file existence and validity
# =====================================================================

echo "--- Section 1: Workflow file existence and validity ---"
echo ""

echo "Test 1: .github/workflows/ci.yml exists"
assert_file_exists "ci.yml exists at .github/workflows/" "$CI_WORKFLOW"

echo ""
echo "Test 2: ci.yml is not empty"
assert_file_not_empty "ci.yml has content" "$CI_WORKFLOW"

# Load workflow content for subsequent tests (gracefully handle missing file)
ci_content=""
if [[ -f "$CI_WORKFLOW" ]]; then
  ci_content="$(cat "$CI_WORKFLOW")"
fi

echo ""
echo "Test 3: ci.yml is parseable YAML"
TOTAL=$((TOTAL + 1))
if [[ -f "$CI_WORKFLOW" ]]; then
  # Use python3 with yaml module to validate YAML if available; fall back to basic structure check
  if command -v python3 &>/dev/null && python3 -c "import yaml" 2>/dev/null; then
    if python3 -c "import yaml; yaml.safe_load(open('$CI_WORKFLOW'))" 2>/dev/null; then
      PASS=$((PASS + 1))
      echo "  PASS: ci.yml is valid YAML (python3 yaml.safe_load)"
    else
      FAIL=$((FAIL + 1))
      echo "  FAIL: ci.yml is not valid YAML"
    fi
  else
    # Fallback: check for basic YAML structure markers
    if echo "$ci_content" | grep -qP '^name:' && echo "$ci_content" | grep -qP '^on:' && echo "$ci_content" | grep -qP '^jobs:'; then
      PASS=$((PASS + 1))
      echo "  PASS: ci.yml has basic YAML structure (name/on/jobs)"
    else
      FAIL=$((FAIL + 1))
      echo "  FAIL: ci.yml missing basic YAML structure (name/on/jobs)"
    fi
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: ci.yml not found, cannot validate YAML"
fi

echo ""
echo "Test 4: Workflow has a 'name' field"
assert_matches "workflow has name field" "^name:" "$ci_content"

# =====================================================================
# Section 2: Trigger configuration
# =====================================================================

echo ""
echo "--- Section 2: Trigger configuration ---"
echo ""

echo "Test 5: Workflow triggers on push"
assert_matches "triggers on push" "^\s*push:" "$ci_content"

echo ""
echo "Test 6: Push trigger includes master branch"
assert_matches "push trigger includes master" "branches:.*master" "$ci_content"

echo ""
echo "Test 7: Workflow triggers on pull_request"
assert_matches "triggers on pull_request" "^\s*pull_request:" "$ci_content"

# =====================================================================
# Section 3: ShellCheck job
# =====================================================================

echo ""
echo "--- Section 3: ShellCheck job ---"
echo ""

echo "Test 8: Workflow has a shellcheck job"
assert_matches "has shellcheck job" "(?i)shellcheck:" "$ci_content"

echo ""
echo "Test 9: ShellCheck job uses ubuntu-latest"
# The shellcheck job section should reference ubuntu-latest
TOTAL=$((TOTAL + 1))
if [[ -f "$CI_WORKFLOW" ]]; then
  # Extract the shellcheck job block and check for ubuntu-latest
  # Use a multi-line approach: find the shellcheck job and look for runs-on
  shellcheck_block="$(echo "$ci_content" | sed -n '/shellcheck:/,/^  [a-zA-Z_-]*:/p' | head -20)"
  # If shellcheck is the last job, sed won't capture — use alternate extraction
  if [[ -z "$shellcheck_block" ]]; then
    shellcheck_block="$(echo "$ci_content" | sed -n '/shellcheck:/,$ p' | head -20)"
  fi
  if echo "$shellcheck_block" | grep -q 'ubuntu-latest'; then
    PASS=$((PASS + 1))
    echo "  PASS: ShellCheck job uses ubuntu-latest"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: ShellCheck job does not reference ubuntu-latest"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: ci.yml not found"
fi

echo ""
echo "Test 10: ShellCheck job uses actions/checkout"
assert_matches "shellcheck uses actions/checkout" "actions/checkout@v[0-9]" "$ci_content"

echo ""
echo "Test 11: ShellCheck job installs or uses shellcheck"
assert_matches "shellcheck is installed or used" "(?i)(install.*shellcheck|shellcheck|action-shellcheck)" "$ci_content"

echo ""
echo "Test 12: ShellCheck job lints repolens.sh"
assert_contains "shellcheck lints repolens.sh" "repolens.sh" "$ci_content"

echo ""
echo "Test 13: ShellCheck job lints lib/*.sh"
assert_contains "shellcheck lints lib/*.sh" "lib/" "$ci_content"

echo ""
echo "Test 14: ShellCheck job lints tests/*.sh"
assert_contains "shellcheck lints tests/*.sh" "tests/" "$ci_content"

# =====================================================================
# Section 4: Test job
# =====================================================================

echo ""
echo "--- Section 4: Test job ---"
echo ""

echo "Test 15: Workflow has a test job"
assert_matches "has test job" "(?i)^\s+test:" "$ci_content"

echo ""
echo "Test 16: Test job uses ubuntu-latest"
TOTAL=$((TOTAL + 1))
if [[ -f "$CI_WORKFLOW" ]]; then
  # Check that runs-on: ubuntu-latest appears in the test job context
  test_block="$(echo "$ci_content" | sed -n '/^\s\s*test:/,/^  [a-zA-Z_-]*:/p' | head -30)"
  # If test is the last job, sed won't capture — use alternate extraction
  if [[ -z "$test_block" ]]; then
    test_block="$(echo "$ci_content" | sed -n '/^\s\s*test:/,$ p' | head -30)"
  fi
  if echo "$test_block" | grep -q 'ubuntu-latest'; then
    PASS=$((PASS + 1))
    echo "  PASS: test job uses ubuntu-latest"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: test job does not reference ubuntu-latest"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: ci.yml not found"
fi

echo ""
echo "Test 17: Test job uses actions/checkout"
# Check there are at least 2 checkout references (one per job)
TOTAL=$((TOTAL + 1))
if [[ -f "$CI_WORKFLOW" ]]; then
  checkout_count="$(echo "$ci_content" | grep -c 'actions/checkout')"
  if [[ "$checkout_count" -ge 2 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: at least 2 actions/checkout references ($checkout_count found)"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: expected at least 2 actions/checkout references (for both jobs), found $checkout_count"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: ci.yml not found"
fi

echo ""
echo "Test 18: Test job installs jq"
assert_matches "test job installs jq" "(?i)(install.*jq|apt.*jq)" "$ci_content"

echo ""
echo "Test 19: Test job runs the test suite"
# Must either call 'make check' or iterate over tests/test_*.sh
TOTAL=$((TOTAL + 1))
if [[ -f "$CI_WORKFLOW" ]]; then
  if echo "$ci_content" | grep -qP 'make check|tests/test_\*\.sh|test_\*\.sh'; then
    PASS=$((PASS + 1))
    echo "  PASS: test job runs the test suite (make check or test glob)"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: test job does not appear to run 'make check' or iterate test_*.sh"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: ci.yml not found"
fi

# =====================================================================
# Section 5: Jobs are separate (parallelism)
# =====================================================================

echo ""
echo "--- Section 5: Job structure ---"
echo ""

echo "Test 20: ShellCheck and test are separate jobs (not combined steps)"
TOTAL=$((TOTAL + 1))
if [[ -f "$CI_WORKFLOW" ]]; then
  # Count top-level job keys under jobs: — there should be at least 2
  # Jobs are indented at 2 spaces under 'jobs:'
  job_count="$(echo "$ci_content" | grep -cP '^\s{2}[a-zA-Z_-]+:\s*$')"
  if [[ "$job_count" -ge 2 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: at least 2 separate jobs defined ($job_count found)"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: expected at least 2 separate jobs under 'jobs:', found $job_count"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: ci.yml not found"
fi

echo ""
echo "Test 21: Workflow does not have needs/depends between shellcheck and test"
# Both jobs should be independent — no 'needs: shellcheck' or 'needs: test'
TOTAL=$((TOTAL + 1))
if [[ -f "$CI_WORKFLOW" ]]; then
  if echo "$ci_content" | grep -qP '^\s+needs:'; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: workflow has 'needs:' dependency between jobs (should run in parallel)"
  else
    PASS=$((PASS + 1))
    echo "  PASS: no inter-job dependencies (jobs run in parallel)"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: ci.yml not found"
fi

# =====================================================================
# Section 6: README CI badge
# =====================================================================

echo ""
echo "--- Section 6: README CI badge ---"
echo ""

readme_content=""
if [[ -f "$SCRIPT_DIR/README.md" ]]; then
  readme_content="$(cat "$SCRIPT_DIR/README.md")"
fi

echo "Test 22: README has a CI badge"
# Use word boundary to avoid matching 'social' or other words containing 'ci'
assert_matches "README has CI badge" "\[!\[CI\b" "$readme_content"

echo ""
echo "Test 23: CI badge references GitHub Actions workflow"
assert_matches "CI badge references actions workflow" "github\.com/TheMorpheus407/RepoLens/actions" "$readme_content"

echo ""
echo "Test 24: CI badge references ci.yml"
assert_contains "CI badge references ci.yml" "ci.yml" "$readme_content"

echo ""
echo "Test 25: CI badge includes badge.svg image"
assert_contains "CI badge has badge.svg" "badge.svg" "$readme_content"

echo ""
echo "Test 26: CI badge appears in the first 10 lines of README"
TOTAL=$((TOTAL + 1))
if [[ -f "$SCRIPT_DIR/README.md" ]]; then
  ci_badge_in_header="$(head -10 "$SCRIPT_DIR/README.md" | grep -ciP 'CI.*badge\.svg|actions/workflows/ci\.yml')"
  if [[ "$ci_badge_in_header" -ge 1 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: CI badge found in first 10 lines"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: CI badge not found in first 10 lines of README"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: README.md not found"
fi

echo ""
echo "Test 27: Existing badges are preserved (license badge regression check)"
assert_matches "license badge still present" "\[!\[.*License.*Apache.*2\.0.*\]\(https://img\.shields\.io" "$readme_content"

echo ""
echo "Test 28: Existing badges are preserved (version badge regression check)"
assert_matches "version badge still present" "\[!\[.*[Vv]ersion.*\]\(https://img\.shields\.io" "$readme_content"

echo ""
echo "Test 29: Existing badges are preserved (stars badge regression check)"
assert_matches "stars badge still present" "\[!\[.*[Ss]tars.*\]\(https://img\.shields\.io/github/stars" "$readme_content"

# =====================================================================
# Section 7: Workflow content quality
# =====================================================================

echo ""
echo "--- Section 7: Workflow content quality ---"
echo ""

echo "Test 30: Workflow file has at least 15 lines (substantive, not a stub)"
TOTAL=$((TOTAL + 1))
if [[ -f "$CI_WORKFLOW" ]]; then
  ci_lines="$(wc -l < "$CI_WORKFLOW")"
  if [[ "$ci_lines" -ge 15 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: ci.yml has $ci_lines lines (>= 15)"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: ci.yml has only $ci_lines lines (expected >= 15)"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: ci.yml not found"
fi

echo ""
echo "Test 31: Workflow has named steps (not bare run commands)"
assert_matches "has named steps" "- name:" "$ci_content"

echo ""
echo "Test 32: Workflow does not contain TODO or placeholder markers"
assert_not_contains "no TODO markers" "TODO" "$ci_content"

echo ""
echo "Test 33: Workflow does not contain FIXME markers"
assert_not_contains "no FIXME markers" "FIXME" "$ci_content"

# =====================================================================
# Section 8: CONTRIBUTING.md CI reference
# =====================================================================

echo ""
echo "--- Section 8: CONTRIBUTING.md CI reference ---"
echo ""

contrib_content=""
if [[ -f "$SCRIPT_DIR/CONTRIBUTING.md" ]]; then
  contrib_content="$(cat "$SCRIPT_DIR/CONTRIBUTING.md")"
fi

echo "Test 34: CONTRIBUTING.md mentions CI running on pull requests"
TOTAL=$((TOTAL + 1))
if [[ -f "$SCRIPT_DIR/CONTRIBUTING.md" ]]; then
  # The implementation added a sentence about CI running on PRs with status checks
  if echo "$contrib_content" | grep -qiP 'CI.*pull.request|pull.request.*CI|automated.*pull.request'; then
    PASS=$((PASS + 1))
    echo "  PASS: CONTRIBUTING.md mentions CI on pull requests"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: CONTRIBUTING.md should mention CI running on pull requests"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: CONTRIBUTING.md not found"
fi

echo ""
echo "Test 35: CONTRIBUTING.md mentions ShellCheck or automated linting"
TOTAL=$((TOTAL + 1))
if [[ -f "$SCRIPT_DIR/CONTRIBUTING.md" ]]; then
  if echo "$contrib_content" | grep -qiP 'ShellCheck|linting|lint'; then
    PASS=$((PASS + 1))
    echo "  PASS: CONTRIBUTING.md mentions ShellCheck/linting"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: CONTRIBUTING.md should mention ShellCheck or linting"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: CONTRIBUTING.md not found"
fi

# =====================================================================
# Section 9: CI reliability — apt-get update before install
# =====================================================================

echo ""
echo "--- Section 9: CI reliability ---"
echo ""

echo "Test 36: Both jobs run apt-get update before installing packages"
TOTAL=$((TOTAL + 1))
if [[ -f "$CI_WORKFLOW" ]]; then
  # Count lines that contain 'apt-get update' — should be at least 2 (one per job)
  apt_update_count="$(echo "$ci_content" | grep -c 'apt-get update')"
  if [[ "$apt_update_count" -ge 2 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: apt-get update appears in both jobs ($apt_update_count occurrences)"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: expected apt-get update in both jobs, found $apt_update_count occurrence(s)"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: ci.yml not found"
fi

# =====================================================================
# Summary
# =====================================================================

echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
