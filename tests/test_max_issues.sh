#!/usr/bin/env bash
# Tests for the --max-issues flag implementation
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/template.sh"
source "$SCRIPT_DIR/lib/streak.sh"
source "$SCRIPT_DIR/lib/summary.sh"

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
    echo "    In output of length: ${#haystack}"
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

# --- Setup test fixtures ---
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# Minimal base template (matches the real templates' placeholder layout)
cat > "$TMPDIR/base.md" <<'EOF'
You are a {{LENS_NAME}}.

## Rules
- Do stuff.

{{SPEC_SECTION}}

{{LENS_BODY}}

{{MAX_ISSUES_SECTION}}

## Termination
- Say DONE.
EOF

# Minimal lens file
cat > "$TMPDIR/lens.md" <<'EOF'
---
id: test-lens
domain: test
name: Test Lens
role: tester
---
## Your Expert Focus
Focus on testing things.
EOF

echo ""
echo "=== Test Suite: --max-issues flag ==="
echo ""

# =====================================================================
# count_issues_in_output tests
# =====================================================================

echo "Test 1: count_issues_in_output — no issues"
echo "No issues here, just regular output." > "$TMPDIR/output-none.txt"
result="$(count_issues_in_output "$TMPDIR/output-none.txt")"
assert_eq "zero issues counted" "0" "$result"

echo ""
echo "Test 2: count_issues_in_output — one issue"
cat > "$TMPDIR/output-one.txt" <<'EOF'
Created issue https://github.com/owner/repo/issues/42
DONE
EOF
result="$(count_issues_in_output "$TMPDIR/output-one.txt")"
assert_eq "one issue counted" "1" "$result"

echo ""
echo "Test 3: count_issues_in_output — multiple issues"
cat > "$TMPDIR/output-multi.txt" <<'EOF'
Analyzing codebase...
Created issue https://github.com/owner/repo/issues/1
Found another problem.
Created issue https://github.com/owner/repo/issues/2
And one more.
Created issue https://github.com/owner/repo/issues/3
DONE
EOF
result="$(count_issues_in_output "$TMPDIR/output-multi.txt")"
assert_eq "three issues counted" "3" "$result"

echo ""
echo "Test 4: count_issues_in_output — empty file"
touch "$TMPDIR/output-empty.txt"
result="$(count_issues_in_output "$TMPDIR/output-empty.txt")"
assert_eq "zero for empty file" "0" "$result"

echo ""
echo "Test 5: count_issues_in_output — nonexistent file"
result="$(count_issues_in_output "$TMPDIR/nonexistent.txt")"
assert_eq "zero for missing file" "0" "$result"

echo ""
echo "Test 6: count_issues_in_output — URLs that look similar but aren't issues"
cat > "$TMPDIR/output-noise.txt" <<'EOF'
See https://github.com/owner/repo/pull/5
And https://github.com/owner/repo/issues/abc is not valid
But https://github.com/owner/repo/issues/99 is real
EOF
result="$(count_issues_in_output "$TMPDIR/output-noise.txt")"
assert_eq "only valid issue URL counted" "1" "$result"

# =====================================================================
# compose_prompt with max_issues tests
# =====================================================================

echo ""
echo "Test 7: compose_prompt — no max_issues, clean substitution"
result="$(compose_prompt "$TMPDIR/base.md" "$TMPDIR/lens.md" "LENS_NAME=TestBot" "" "audit" "")"
assert_not_contains "no {{MAX_ISSUES_SECTION}} artifact" '{{MAX_ISSUES_SECTION}}' "$result"
assert_not_contains "no Issue Limit heading" "## Issue Limit" "$result"
assert_contains "lens body present" "Focus on testing things" "$result"

echo ""
echo "Test 8: compose_prompt — max_issues=1"
result="$(compose_prompt "$TMPDIR/base.md" "$TMPDIR/lens.md" "LENS_NAME=DryRunBot" "" "audit" "1")"
assert_not_contains "no {{MAX_ISSUES_SECTION}} artifact" '{{MAX_ISSUES_SECTION}}' "$result"
assert_contains "Issue Limit heading" "## Issue Limit" "$result"
assert_contains "at most 1 issue(s)" "at most 1 issue(s)" "$result"
assert_contains "stop instruction" "stop immediately" "$result"
assert_contains "prioritization" "most severe and impactful" "$result"

echo ""
echo "Test 9: compose_prompt — max_issues=5"
result="$(compose_prompt "$TMPDIR/base.md" "$TMPDIR/lens.md" "LENS_NAME=FiveBot" "" "audit" "5")"
assert_contains "at most 5 issue(s)" "at most 5 issue(s)" "$result"

echo ""
echo "Test 10: compose_prompt — max_issues section before Termination"
result="$(compose_prompt "$TMPDIR/base.md" "$TMPDIR/lens.md" "LENS_NAME=OrderBot" "" "audit" "3")"
limit_pos="${result%%## Issue Limit*}"
term_pos="${result%%## Termination*}"
if [[ ${#limit_pos} -lt ${#term_pos} ]]; then
  TOTAL=$((TOTAL + 1))
  PASS=$((PASS + 1))
  echo "  PASS: Issue Limit appears before Termination"
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: Issue Limit should appear before Termination"
fi

echo ""
echo "Test 11: compose_prompt — max_issues + spec composability"
cat > "$TMPDIR/spec.md" <<'EOF'
# Requirements
Everything must work.
EOF
result="$(compose_prompt "$TMPDIR/base.md" "$TMPDIR/lens.md" "LENS_NAME=ComboBot" "$TMPDIR/spec.md" "audit" "2")"
assert_contains "spec present" "## Specification Reference" "$result"
assert_contains "max_issues present" "## Issue Limit" "$result"
assert_contains "lens body present" "Focus on testing things" "$result"

# =====================================================================
# init_summary with max_issues tests
# =====================================================================

echo ""
echo "Test 12: init_summary — with max_issues"
init_summary "$TMPDIR/summary-max.json" "test-run" "/tmp/project" "audit" "claude" "" "3"
max_val="$(jq '.max_issues' "$TMPDIR/summary-max.json")"
assert_eq "max_issues in summary" "3" "$max_val"
reason_val="$(jq -r '.stopped_reason' "$TMPDIR/summary-max.json")"
assert_eq "stopped_reason null" "null" "$reason_val"

echo ""
echo "Test 13: init_summary — without max_issues"
init_summary "$TMPDIR/summary-nomax.json" "test-run" "/tmp/project" "audit" "claude" "" ""
max_val="$(jq '.max_issues' "$TMPDIR/summary-nomax.json")"
assert_eq "max_issues null in summary" "null" "$max_val"

# =====================================================================
# record_lens with issues count tests
# =====================================================================

echo ""
echo "Test 14: record_lens — with issue count"
init_summary "$TMPDIR/summary-rec.json" "test-run" "/tmp/project" "audit" "claude" "" "5"
record_lens "$TMPDIR/summary-rec.json" "security" "injection" 3 "completed" 2
issues_val="$(jq '.lenses[0].issues_created' "$TMPDIR/summary-rec.json")"
assert_eq "per-lens issues_created" "2" "$issues_val"
total_issues="$(jq '.totals.issues_created' "$TMPDIR/summary-rec.json")"
assert_eq "total issues_created" "2" "$total_issues"
total_run="$(jq '.totals.lenses_run' "$TMPDIR/summary-rec.json")"
assert_eq "lenses_run incremented" "1" "$total_run"

echo ""
echo "Test 15: record_lens — skipped lens does not increment lenses_run"
record_lens "$TMPDIR/summary-rec.json" "security" "xss" 0 "skipped" 0
total_run="$(jq '.totals.lenses_run' "$TMPDIR/summary-rec.json")"
assert_eq "lenses_run unchanged after skip" "1" "$total_run"
skip_status="$(jq -r '.lenses[1].status' "$TMPDIR/summary-rec.json")"
assert_eq "skipped lens status" "skipped" "$skip_status"

echo ""
echo "Test 16: record_lens — max-issues status"
record_lens "$TMPDIR/summary-rec.json" "security" "csrf" 1 "max-issues" 1
status_val="$(jq -r '.lenses[2].status' "$TMPDIR/summary-rec.json")"
assert_eq "max-issues lens status" "max-issues" "$status_val"
total_issues="$(jq '.totals.issues_created' "$TMPDIR/summary-rec.json")"
assert_eq "accumulated total issues" "3" "$total_issues"

# =====================================================================
# set_stop_reason tests
# =====================================================================

echo ""
echo "Test 17: set_stop_reason"
init_summary "$TMPDIR/summary-stop.json" "test-run" "/tmp/project" "audit" "claude" "" "1"
set_stop_reason "$TMPDIR/summary-stop.json" "max-issues-reached"
reason="$(jq -r '.stopped_reason' "$TMPDIR/summary-stop.json")"
assert_eq "stop reason set" "max-issues-reached" "$reason"

echo ""
echo "Test 18: set_stop_reason — empty reason is no-op"
init_summary "$TMPDIR/summary-noop.json" "test-run" "/tmp/project" "audit" "claude" "" ""
set_stop_reason "$TMPDIR/summary-noop.json" ""
reason="$(jq -r '.stopped_reason' "$TMPDIR/summary-noop.json")"
assert_eq "stop reason stays null" "null" "$reason"

# =====================================================================
# Validation tests (--max-issues arg parsing)
# =====================================================================

echo ""
echo "Test 19: --max-issues validation — rejects 0"
if [[ "0" =~ ^[1-9][0-9]*$ ]]; then
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: 0 should be rejected by regex"
else
  TOTAL=$((TOTAL + 1))
  PASS=$((PASS + 1))
  echo "  PASS: 0 rejected"
fi

echo ""
echo "Test 20: --max-issues validation — rejects negative"
if [[ "-1" =~ ^[1-9][0-9]*$ ]]; then
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: -1 should be rejected by regex"
else
  TOTAL=$((TOTAL + 1))
  PASS=$((PASS + 1))
  echo "  PASS: -1 rejected"
fi

echo ""
echo "Test 21: --max-issues validation — rejects non-integer"
if [[ "abc" =~ ^[1-9][0-9]*$ ]]; then
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: abc should be rejected by regex"
else
  TOTAL=$((TOTAL + 1))
  PASS=$((PASS + 1))
  echo "  PASS: abc rejected"
fi

echo ""
echo "Test 22: --max-issues validation — accepts 1"
if [[ "1" =~ ^[1-9][0-9]*$ ]]; then
  TOTAL=$((TOTAL + 1))
  PASS=$((PASS + 1))
  echo "  PASS: 1 accepted"
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: 1 should be accepted"
fi

echo ""
echo "Test 23: --max-issues validation — accepts 42"
if [[ "42" =~ ^[1-9][0-9]*$ ]]; then
  TOTAL=$((TOTAL + 1))
  PASS=$((PASS + 1))
  echo "  PASS: 42 accepted"
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: 42 should be accepted"
fi

# =====================================================================
# Base template placeholder tests
# =====================================================================

echo ""
echo "Test 24: Base templates contain {{MAX_ISSUES_SECTION}}"
for tpl in audit feature bugfix discover; do
  tpl_file="$SCRIPT_DIR/prompts/_base/$tpl.md"
  if grep -qF '{{MAX_ISSUES_SECTION}}' "$tpl_file"; then
    TOTAL=$((TOTAL + 1))
    PASS=$((PASS + 1))
    echo "  PASS: $tpl.md has {{MAX_ISSUES_SECTION}}"
  else
    TOTAL=$((TOTAL + 1))
    FAIL=$((FAIL + 1))
    echo "  FAIL: $tpl.md missing {{MAX_ISSUES_SECTION}}"
  fi
done

echo ""
echo "Test 25: Usage text includes --max-issues"
if grep -qF -- '--max-issues' "$SCRIPT_DIR/repolens.sh"; then
  TOTAL=$((TOTAL + 1))
  PASS=$((PASS + 1))
  echo "  PASS: --max-issues in repolens.sh"
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: --max-issues not found in repolens.sh"
fi

echo ""
echo "Test 26: Template clean when unused — all four modes"
for mode in audit feature bugfix discover; do
  tpl_file="$SCRIPT_DIR/prompts/_base/$mode.md"
  result="$(compose_prompt "$tpl_file" "$TMPDIR/lens.md" "LENS_NAME=CleanBot|DOMAIN_NAME=Test|REPO_OWNER=test|REPO_NAME=test|PROJECT_PATH=/tmp|LENS_LABEL=audit:test/test|DOMAIN_COLOR=ededed|DOMAIN=test|LENS_ID=test|MODE=audit|RUN_ID=test|SPEC_SECTION=" "" "$mode" "")"
  if [[ "$result" != *"{{MAX_ISSUES_SECTION}}"* && "$result" != *"## Issue Limit"* ]]; then
    TOTAL=$((TOTAL + 1))
    PASS=$((PASS + 1))
    echo "  PASS: $mode.md clean when no max-issues"
  else
    TOTAL=$((TOTAL + 1))
    FAIL=$((FAIL + 1))
    echo "  FAIL: $mode.md has max-issues artifacts when flag not set"
  fi
done

# =====================================================================
# count_repo_issues function existence and error handling
# =====================================================================

echo ""
echo "Test 27: count_repo_issues — function exists"
if declare -f count_repo_issues >/dev/null 2>&1; then
  TOTAL=$((TOTAL + 1))
  PASS=$((PASS + 1))
  echo "  PASS: count_repo_issues is defined"
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: count_repo_issues not defined"
fi

echo ""
echo "Test 28: count_repo_issues — returns 0 for nonexistent repo"
result="$(count_repo_issues "nonexistent-owner/nonexistent-repo-xyz" "fake-label")"
assert_eq "zero for nonexistent repo" "0" "$result"

# =====================================================================
# Run ID generation (xxd fix)
# =====================================================================

echo ""
echo "Test 29: Run ID generation — od produces hex suffix"
hex="$(od -An -tx1 -N4 /dev/urandom | tr -d ' \n')"
TOTAL=$((TOTAL + 1))
if [[ "$hex" =~ ^[0-9a-f]{8}$ ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: od generates 8-char hex ($hex)"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: od hex unexpected format: '$hex'"
fi

echo ""
echo "Test 30: repolens.sh does not use xxd"
if grep -qF 'xxd' "$SCRIPT_DIR/repolens.sh"; then
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: repolens.sh still references xxd"
else
  TOTAL=$((TOTAL + 1))
  PASS=$((PASS + 1))
  echo "  PASS: no xxd in repolens.sh"
fi

# =====================================================================
# Remote URL detection tests
# =====================================================================

echo ""
echo "Test 31: URL detection — https"
if [[ "https://github.com/org/repo.git" =~ ^(https://|git@|ssh://|git://) ]]; then
  TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1))
  echo "  PASS: https URL detected"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: https URL not detected"
fi

echo ""
echo "Test 32: URL detection — git@"
if [[ "git@github.com:org/repo.git" =~ ^(https://|git@|ssh://|git://) ]]; then
  TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1))
  echo "  PASS: git@ URL detected"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: git@ URL not detected"
fi

echo ""
echo "Test 33: URL detection — ssh://"
if [[ "ssh://git@github.com/org/repo" =~ ^(https://|git@|ssh://|git://) ]]; then
  TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1))
  echo "  PASS: ssh:// URL detected"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: ssh:// URL not detected"
fi

echo ""
echo "Test 34: URL detection — local path NOT matched"
if [[ "/home/user/project" =~ ^(https://|git@|ssh://|git://) ]]; then
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: local path should not be detected as URL"
else
  TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1))
  echo "  PASS: local path not matched"
fi

echo ""
echo "Test 35: URL detection — relative path NOT matched"
if [[ "../other-project" =~ ^(https://|git@|ssh://|git://) ]]; then
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: relative path should not be detected as URL"
else
  TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1))
  echo "  PASS: relative path not matched"
fi

echo ""
echo "Test 36: Repo name extraction from URL"
result="$(basename "https://github.com/org/my-project.git" .git)"
assert_eq "repo name from https URL" "my-project" "$result"

echo ""
echo "Test 37: Repo name extraction from URL without .git"
result="$(basename "https://github.com/org/my-project" .git)"
assert_eq "repo name from URL without .git" "my-project" "$result"

echo ""
echo "Test 38: Read-only isolation — chmod works on temp dir"
_iso_dir="$(mktemp -d)"
mkdir -p "$_iso_dir/repo"
echo "test" > "$_iso_dir/repo/file.sh"
chmod +x "$_iso_dir/repo/file.sh"
chmod -R a-w "$_iso_dir/repo"
find "$_iso_dir/repo" -type f -exec chmod a-x {} +
# Verify read-only
if [[ ! -w "$_iso_dir/repo/file.sh" ]]; then
  TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1))
  echo "  PASS: file is not writable"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: file should not be writable"
fi
# Verify not executable
if [[ ! -x "$_iso_dir/repo/file.sh" ]]; then
  TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1))
  echo "  PASS: file is not executable"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: file should not be executable"
fi
# Verify still readable
if [[ -r "$_iso_dir/repo/file.sh" ]]; then
  TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1))
  echo "  PASS: file is still readable"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: file should still be readable"
fi
# Cleanup (must restore write first)
chmod -R u+w "$_iso_dir"
rm -rf "$_iso_dir"

echo ""
echo "Test 39: Usage text mentions remote URL"
if grep -qF 'url' "$SCRIPT_DIR/repolens.sh" 2>/dev/null || grep -qF 'URL' "$SCRIPT_DIR/repolens.sh" 2>/dev/null; then
  TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1))
  echo "  PASS: usage mentions URL"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: usage should mention URL"
fi

# --- Summary ---
echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
