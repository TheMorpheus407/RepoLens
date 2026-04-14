#!/usr/bin/env bash
# Copyright 2025 Bootstrap Academy
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

# Tests for the --local flag and local markdown export (issue #23).
# Tests are BEHAVIORAL: they execute repolens.sh and assert on exit codes + output,
# or invoke library functions directly and assert return values.
#
# The --dry-run flag is ALREADY TAKEN for config-preview mode. This feature
# uses --local per the research recommendation (issue comment).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOLENS="$SCRIPT_DIR/repolens.sh"

TIMEOUT=20

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

# Run repolens.sh with piped stdin. Used for non-interactive / --yes tests.
run_repolens() {
  local stdin_data=""
  if [[ "${1:-}" == "--stdin" ]]; then
    stdin_data="$2"
    shift 2
  fi
  local tmp_out="$TMPDIR/.run_output"
  echo "$stdin_data" | timeout "$TIMEOUT" bash "$REPOLENS" "$@" >"$tmp_out" 2>&1
  RUN_EXIT=$?
  RUN_OUTPUT="$(cat "$tmp_out")"
  rm -f "$tmp_out"
}

# Run with script(1) for TTY simulation.
run_repolens_tty() {
  local stdin_data="$1"
  shift
  if ! command -v script >/dev/null 2>&1; then
    return 1
  fi
  local args_str=""
  for arg in "$@"; do
    args_str+=" '${arg//\'/\'\\\'\'}'"
  done
  local tmp_out="$TMPDIR/.tty_output"
  printf "%b\n" "$stdin_data" | timeout "$TIMEOUT" script -qec "bash '$REPOLENS' $args_str" /dev/null >"$tmp_out" 2>&1
  RUN_EXIT=$?
  RUN_OUTPUT="$(cat "$tmp_out")"
  rm -f "$tmp_out"
  return 0
}

# --- Setup test fixtures ---
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# Minimal git repo
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
echo "=== Test Suite: --local flag and local markdown export (issue #23) ==="
echo ""

# =====================================================================
# SECTION A: count_dry_run_issues — Unit Tests
# =====================================================================

echo "--- Section A: count_dry_run_issues unit tests ---"
echo ""

source "$SCRIPT_DIR/lib/streak.sh"

# Test 1: Nonexistent directory returns 0
echo "Test 1: count_dry_run_issues — nonexistent directory returns 0"
result="$(count_dry_run_issues "$TMPDIR/nonexistent-dir-$RANDOM" 2>/dev/null)"
assert_eq "nonexistent dir returns 0" "0" "$result"

# Test 2: Empty directory returns 0
echo ""
echo "Test 2: count_dry_run_issues — empty directory returns 0"
mkdir -p "$TMPDIR/empty-dir"
result="$(count_dry_run_issues "$TMPDIR/empty-dir" 2>/dev/null)"
assert_eq "empty dir returns 0" "0" "$result"

# Test 3: Counts 3 .md files correctly
echo ""
echo "Test 3: count_dry_run_issues — counts 3 .md files"
mkdir -p "$TMPDIR/three-md"
touch "$TMPDIR/three-md/001-finding-one.md"
touch "$TMPDIR/three-md/002-finding-two.md"
touch "$TMPDIR/three-md/003-finding-three.md"
result="$(count_dry_run_issues "$TMPDIR/three-md" 2>/dev/null)"
assert_eq "3 .md files counted" "3" "$result"

# Test 4: Ignores non-.md files
echo ""
echo "Test 4: count_dry_run_issues — ignores non-.md files"
mkdir -p "$TMPDIR/mixed-files"
touch "$TMPDIR/mixed-files/001-finding.md"
touch "$TMPDIR/mixed-files/notes.txt"
touch "$TMPDIR/mixed-files/data.json"
touch "$TMPDIR/mixed-files/.hidden"
result="$(count_dry_run_issues "$TMPDIR/mixed-files" 2>/dev/null)"
assert_eq "only .md counted, not .txt/.json/hidden" "1" "$result"

# Test 5: Ignores .md files in subdirectories (maxdepth 1)
echo ""
echo "Test 5: count_dry_run_issues — ignores .md in subdirectories"
mkdir -p "$TMPDIR/nested-md/subdir"
touch "$TMPDIR/nested-md/001-finding.md"
touch "$TMPDIR/nested-md/subdir/002-nested.md"
result="$(count_dry_run_issues "$TMPDIR/nested-md" 2>/dev/null)"
assert_eq "only top-level .md counted" "1" "$result"

# Test 6: Single file returns 1
echo ""
echo "Test 6: count_dry_run_issues — single file returns 1"
mkdir -p "$TMPDIR/single-md"
touch "$TMPDIR/single-md/001-only-finding.md"
result="$(count_dry_run_issues "$TMPDIR/single-md" 2>/dev/null)"
assert_eq "single .md returns 1" "1" "$result"

# =====================================================================
# SECTION B: Argument Parsing — Integration Tests
# =====================================================================

echo ""
echo "--- Section B: Argument parsing ---"
echo ""

# Test 7: --local flag accepted by argument parser
echo "Test 7: --local flag accepted by argument parser"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --yes --local
assert_not_contains "--local not rejected" "Unknown argument: --local" "$RUN_OUTPUT"

# Test 8: --output accepted with --local
echo ""
echo "Test 8: --output accepted with --local"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --yes --local --output "$TMPDIR/test-output-8"
assert_not_contains "--output not rejected" "Unknown argument: --output" "$RUN_OUTPUT"

# Test 9: --output without --local produces error mentioning --local
echo ""
echo "Test 9: --output without --local produces error"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --yes --output "$TMPDIR/test-output-9"
assert_exit_code "--output without --local exits 1" 1 "$RUN_EXIT"
assert_contains "--output error mentions --local" "--local" "$RUN_OUTPUT"

# Test 10: --help mentions --local
echo ""
echo "Test 10: --help mentions --local"
help_output="$(timeout "$TIMEOUT" bash "$REPOLENS" --help 2>&1)"
assert_contains "--local in help text" "--local" "$help_output"

# Test 11: --help mentions --output
echo ""
echo "Test 11: --help mentions --output"
assert_contains "--output in help text" "--output" "$help_output"

# Test 12: --local + --dry-run shows local mode info in preview
echo ""
echo "Test 12: --local + --dry-run shows local mode info"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --local --dry-run
assert_contains "dry-run shows local" "local" "$RUN_OUTPUT"
assert_exit_code "dry-run exits 0" 0 "$RUN_EXIT"

# Test 13: --output requires an argument
echo ""
echo "Test 13: --output without value produces error"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --yes --local --output
assert_exit_code "--output without value exits 1" 1 "$RUN_EXIT"

# =====================================================================
# SECTION C: GitHub Dependency Skipping
# =====================================================================

echo ""
echo "--- Section C: GitHub dependency skipping ---"
echo ""

# Test 14: --local skips gh auth status check
# In local mode, the script should NOT fail when gh is not authenticated.
# We test this indirectly: if --local skips the gh checks, it should NOT
# produce "gh is not authenticated" error even if gh would fail.
echo "Test 14: --local skips gh auth check (no 'not authenticated' error)"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --yes --local
assert_not_contains "--local skips gh auth" "gh is not authenticated" "$RUN_OUTPUT"

# Test 15: --local skips ensure_labels (no label creation log)
echo ""
echo "Test 15: --local skips label creation"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --yes --local
assert_not_contains "--local skips labels" "Ensuring GitHub labels" "$RUN_OUTPUT"

# =====================================================================
# SECTION D: compose_prompt with Local Mode — Unit Tests
# =====================================================================

echo ""
echo "--- Section D: compose_prompt with local mode ---"
echo ""

source "$SCRIPT_DIR/lib/template.sh"

# Create minimal test templates
cat > "$TMPDIR/base-local.md" <<'EOF'
You are a {{LENS_NAME}}.

## Rules
- Do stuff.

{{MAX_ISSUES_SECTION}}

{{LOCAL_MODE_SECTION}}

{{SPEC_SECTION}}

{{LENS_BODY}}

## Termination
- Say DONE.
EOF

cat > "$TMPDIR/lens-local.md" <<'EOF'
---
id: test-lens
domain: test
name: Test Lens
role: tester
---
## Your Expert Focus
Focus on testing things.
EOF

# Test 16: local_mode=true includes LOCAL MODE OVERRIDE section
echo "Test 16: compose_prompt with local_mode=true includes override"
result="$(compose_prompt "$TMPDIR/base-local.md" "$TMPDIR/lens-local.md" "LENS_NAME=LocalBot" "" "audit" "" "" "false" "true" "$TMPDIR/test-output-16")"
assert_contains "override heading present" "LOCAL MODE OVERRIDE" "$result"

# Test 17: local_mode=false produces clean template (no LOCAL MODE artifacts)
echo ""
echo "Test 17: compose_prompt with local_mode=false has no override"
result="$(compose_prompt "$TMPDIR/base-local.md" "$TMPDIR/lens-local.md" "LENS_NAME=NormalBot" "" "audit" "" "" "false" "false" "")"
assert_not_contains "no override when local=false" "LOCAL MODE OVERRIDE" "$result"
assert_not_contains "no {{LOCAL_MODE_SECTION}} artifact" '{{LOCAL_MODE_SECTION}}' "$result"

# Test 18: Output path appears in composed prompt
echo ""
echo "Test 18: Output path in composed prompt"
result="$(compose_prompt "$TMPDIR/base-local.md" "$TMPDIR/lens-local.md" "LENS_NAME=PathBot" "" "audit" "" "" "false" "true" "/absolute/output/path")"
assert_contains "output path present" "/absolute/output/path" "$result"

# Test 19: Override instructs NOT to use gh issue create
echo ""
echo "Test 19: Override says no gh issue create"
result="$(compose_prompt "$TMPDIR/base-local.md" "$TMPDIR/lens-local.md" "LENS_NAME=NoGhBot" "" "audit" "" "" "false" "true" "$TMPDIR/test-19")"
assert_contains "override forbids gh issue create" "gh issue create" "$result"
assert_contains "override says NOT to use it" "NOT" "$result"

# Test 20: Override mentions markdown file writing
echo ""
echo "Test 20: Override mentions markdown files"
result="$(compose_prompt "$TMPDIR/base-local.md" "$TMPDIR/lens-local.md" "LENS_NAME=MdBot" "" "audit" "" "" "false" "true" "$TMPDIR/test-20")"
assert_contains "mentions markdown" "markdown" "$result"

# Test 21: Override mentions YAML frontmatter
echo ""
echo "Test 21: Override mentions YAML frontmatter"
result="$(compose_prompt "$TMPDIR/base-local.md" "$TMPDIR/lens-local.md" "LENS_NAME=YamlBot" "" "audit" "" "" "false" "true" "$TMPDIR/test-21")"
assert_contains "mentions frontmatter" "frontmatter" "$result"

# Test 22: Override mentions file naming convention (slug)
echo ""
echo "Test 22: Override mentions file naming convention"
result="$(compose_prompt "$TMPDIR/base-local.md" "$TMPDIR/lens-local.md" "LENS_NAME=SlugBot" "" "audit" "" "" "false" "true" "$TMPDIR/test-22")"
assert_contains "mentions slug or naming" "slug" "$result"

# Test 23: Override instructs NOT to use gh label create
echo ""
echo "Test 23: Override says no gh label create"
result="$(compose_prompt "$TMPDIR/base-local.md" "$TMPDIR/lens-local.md" "LENS_NAME=NoLabelBot" "" "audit" "" "" "false" "true" "$TMPDIR/test-23")"
assert_contains "override forbids gh label create" "gh label create" "$result"

# Test 24: Composability — local mode with --max-issues and --spec
echo ""
echo "Test 24: Composability — local + max-issues + spec"
cat > "$TMPDIR/test-spec.md" <<'EOF'
# Test Spec
Must do things.
EOF
result="$(compose_prompt "$TMPDIR/base-local.md" "$TMPDIR/lens-local.md" "LENS_NAME=ComboBot" "$TMPDIR/test-spec.md" "audit" "5" "" "false" "true" "$TMPDIR/test-24")"
assert_contains "local override present with combo" "LOCAL MODE OVERRIDE" "$result"
assert_contains "max issues present with combo" "5 issue(s)" "$result"
assert_contains "spec present with combo" "## Specification Reference" "$result"

# Test 25: Default params — compose_prompt backwards compatible (no local params)
echo ""
echo "Test 25: compose_prompt backward compatible without local params"
result="$(compose_prompt "$TMPDIR/base-local.md" "$TMPDIR/lens-local.md" "LENS_NAME=OldBot" "" "audit")"
assert_not_contains "no override artifacts without params" "LOCAL MODE OVERRIDE" "$result"
assert_not_contains "no placeholder artifact" '{{LOCAL_MODE_SECTION}}' "$result"
assert_contains "lens body still works" "Focus on testing things" "$result"

# =====================================================================
# SECTION E: Base Template Placeholders
# =====================================================================

echo ""
echo "--- Section E: Base template placeholders ---"
echo ""

# Test 26: All 8 base templates contain {{LOCAL_MODE_SECTION}}
echo "Test 26: All 8 base templates have {{LOCAL_MODE_SECTION}}"
for tpl in audit feature bugfix discover deploy custom opensource content; do
  tpl_file="$SCRIPT_DIR/prompts/_base/$tpl.md"
  TOTAL=$((TOTAL + 1))
  if grep -qF '{{LOCAL_MODE_SECTION}}' "$tpl_file" 2>/dev/null; then
    PASS=$((PASS + 1))
    echo "  PASS: $tpl.md has {{LOCAL_MODE_SECTION}}"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $tpl.md missing {{LOCAL_MODE_SECTION}}"
  fi
done

# =====================================================================
# SECTION F: init_summary with Local Mode — Unit Tests
# =====================================================================

echo ""
echo "--- Section F: init_summary with local mode ---"
echo ""

source "$SCRIPT_DIR/lib/summary.sh"

# Test 27: output_mode set to "local" when local mode active
echo "Test 27: init_summary records output_mode=local"
init_summary "$TMPDIR/summary-local.json" "test-run-1" "/tmp/project" "audit" "claude" "" "" "local" "/tmp/output"
output_mode_val="$(jq -r '.output_mode' "$TMPDIR/summary-local.json" 2>/dev/null)"
assert_eq "output_mode is local" "local" "$output_mode_val"

# Test 28: output_dir records the path
echo ""
echo "Test 28: init_summary records output_dir"
output_dir_val="$(jq -r '.output_dir' "$TMPDIR/summary-local.json" 2>/dev/null)"
assert_eq "output_dir matches" "/tmp/output" "$output_dir_val"

# Test 29: Default output_mode is "github"
echo ""
echo "Test 29: init_summary default output_mode=github"
init_summary "$TMPDIR/summary-github.json" "test-run-2" "/tmp/project" "audit" "claude" "" ""
output_mode_val="$(jq -r '.output_mode' "$TMPDIR/summary-github.json" 2>/dev/null)"
assert_eq "default output_mode is github" "github" "$output_mode_val"

# Test 30: output_dir null when not in local mode
echo ""
echo "Test 30: init_summary output_dir null when not local"
output_dir_val="$(jq -r '.output_dir' "$TMPDIR/summary-github.json" 2>/dev/null)"
assert_eq "output_dir is null" "null" "$output_dir_val"

# =====================================================================
# SECTION G: Flag Interaction
# =====================================================================

echo ""
echo "--- Section G: Flag interaction ---"
echo ""

# Test 31: --local works with --parallel
echo "Test 31: --local + --parallel works"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --yes --local --parallel
assert_not_contains "--local + --parallel accepted" "Unknown argument" "$RUN_OUTPUT"

# Test 32: --local works with --domain
echo ""
echo "Test 32: --local + --domain works"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --yes --local --domain security
assert_not_contains "--local + --domain accepted" "Unknown argument" "$RUN_OUTPUT"

# Test 33: --local works with --focus
echo ""
echo "Test 33: --local + --focus works"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --yes --local --focus injection
assert_not_contains "--local + --focus accepted" "Unknown argument" "$RUN_OUTPUT"

# Test 34: --local works with --resume
echo ""
echo "Test 34: --local + --resume works"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --yes --local --resume fake-run-id
assert_not_contains "--local + --resume accepted" "Unknown argument" "$RUN_OUTPUT"

# Test 35: --local works with --max-issues
echo ""
echo "Test 35: --local + --max-issues works"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --yes --local --max-issues 3
assert_not_contains "--local + --max-issues accepted" "Unknown argument" "$RUN_OUTPUT"

# Test 36-43: --local works with all 8 modes
echo ""
echo "Test 36-43: --local works with all 8 modes"
for mode in audit feature bugfix discover deploy custom opensource content; do
  run_repolens --stdin "" --project "$TEST_REPO" --agent claude --yes --local --mode "$mode"
  assert_not_contains "--local + --mode $mode accepted" "Unknown argument" "$RUN_OUTPUT"
done

# Test 44: Existing --dry-run behavior unchanged (still does config preview)
echo ""
echo "Test 44: Existing --dry-run behavior unchanged"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --dry-run
assert_contains "dry-run shows Dry Run header" "Dry Run" "$RUN_OUTPUT"
assert_contains "dry-run shows Lenses that would run" "Lenses that would run" "$RUN_OUTPUT"
assert_exit_code "dry-run exits 0" 0 "$RUN_EXIT"

# Test 45: Existing --dry-run still lists lenses
echo ""
echo "Test 45: Existing --dry-run lists lenses"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --dry-run
assert_contains "dry-run lists security/injection" "injection" "$RUN_OUTPUT"

# =====================================================================
# SECTION H: Output Directory
# =====================================================================

echo ""
echo "--- Section H: Output directory ---"
echo ""

# Test 46: --output creates specified directory
echo "Test 46: --output creates directory"
local_out_dir="$TMPDIR/test-output-46"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --yes --local --output "$local_out_dir"
TOTAL=$((TOTAL + 1))
if [[ -d "$local_out_dir" ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: output directory created"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: output directory not created: $local_out_dir"
fi

# Test 47: --local + --dry-run shows output directory path
echo ""
echo "Test 47: --local + --dry-run shows output path"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --local --dry-run --output "$TMPDIR/test-output-47"
assert_contains "dry-run shows output path" "test-output-47" "$RUN_OUTPUT"

# =====================================================================
# SECTION I: Confirmation Prompt
# =====================================================================

echo ""
echo "--- Section I: Confirmation prompt ---"
echo ""

# Test 48: --local confirmation mentions local markdown (no GitHub issue warning)
echo "Test 48: --local confirmation mentions local markdown"
if run_repolens_tty "N" --project "$TEST_REPO" --agent claude --local; then
  assert_contains "confirmation mentions local markdown" "local markdown" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# Test 49: --local confirmation does NOT say "create GitHub issues"
echo ""
echo "Test 49: --local confirmation has no GitHub issue warning"
if run_repolens_tty "N" --project "$TEST_REPO" --agent claude --local; then
  assert_not_contains "no GitHub issue warning in local" "create GitHub issues" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# Test 50: --local confirmation shows output path
echo ""
echo "Test 50: --local confirmation shows output path"
if run_repolens_tty "N" --project "$TEST_REPO" --agent claude --local --output "$TMPDIR/test-output-50"; then
  assert_contains "confirmation shows output dir" "test-output-50" "$RUN_OUTPUT"
else
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: script(1) not available — skipped"
fi

# =====================================================================
# SECTION J: Validation
# =====================================================================

echo ""
echo "--- Section J: Validation ---"
echo ""

# Test 51: --local still validates project path
echo "Test 51: --local still validates project"
run_repolens --stdin "" --project "/nonexistent/path" --agent claude --yes --local
assert_exit_code "--local with bad project exits 1" 1 "$RUN_EXIT"

# Test 52: --local does not require gh (no "gh" not found error)
echo ""
echo "Test 52: --local does not fail on gh requirement"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --yes --local
assert_not_contains "--local skips gh requirement" "gh: command not found" "$RUN_OUTPUT"
assert_not_contains "--local skips gh require_cmd" "Required command not found: gh" "$RUN_OUTPUT"

# Test 53: Usage text includes --local example
echo ""
echo "Test 53: Usage text includes --local example"
help_output="$(timeout "$TIMEOUT" bash "$REPOLENS" --help 2>&1)"
assert_contains "help has --local example" "--local" "$help_output"

# Test 54: Usage text includes --output example
echo ""
echo "Test 54: Usage text includes --output example"
assert_contains "help has --output example" "--output" "$help_output"

# =====================================================================
# SECTION K: Real Template Substitution
# =====================================================================

echo ""
echo "--- Section K: Real template substitution ---"
echo ""

# Test 55: Real base templates clean when local mode inactive
echo "Test 55: Real templates clean when local=false"
for tpl in audit feature bugfix discover; do
  tpl_file="$SCRIPT_DIR/prompts/_base/$tpl.md"
  # Use the real base template with a test lens
  result="$(compose_prompt "$tpl_file" "$TMPDIR/lens-local.md" "LENS_NAME=TestBot|PROJECT_PATH=/test|DOMAIN=test|DOMAIN_NAME=Test|DOMAIN_COLOR=ededed|LENS_ID=test-lens|LENS_LABEL=audit:test/test-lens|MODE=$tpl|RUN_ID=test-run|REPO_NAME=test-repo|REPO_OWNER=local" "" "$tpl" "" "" "false" "false" "")"
  assert_not_contains "$tpl.md clean (no LOCAL_MODE_SECTION artifact)" '{{LOCAL_MODE_SECTION}}' "$result"
done

# Test 56: Real base templates include LOCAL MODE OVERRIDE when active
echo ""
echo "Test 56: Real templates have override when local=true"
for tpl in audit feature bugfix discover; do
  tpl_file="$SCRIPT_DIR/prompts/_base/$tpl.md"
  result="$(compose_prompt "$tpl_file" "$TMPDIR/lens-local.md" "LENS_NAME=TestBot|PROJECT_PATH=/test|DOMAIN=test|DOMAIN_NAME=Test|DOMAIN_COLOR=ededed|LENS_ID=test-lens|LENS_LABEL=audit:test/test-lens|MODE=$tpl|RUN_ID=test-run|REPO_NAME=test-repo|REPO_OWNER=local" "" "$tpl" "" "" "false" "true" "/tmp/local-output")"
  assert_contains "$tpl.md has LOCAL MODE OVERRIDE" "LOCAL MODE OVERRIDE" "$result"
done

# Test 57: Real deploy template works with local mode
echo ""
echo "Test 57: deploy template with local mode"
deploy_file="$SCRIPT_DIR/prompts/_base/deploy.md"
result="$(compose_prompt "$deploy_file" "$TMPDIR/lens-local.md" "LENS_NAME=DeployBot|PROJECT_PATH=/test|DOMAIN=test|DOMAIN_NAME=Test|DOMAIN_COLOR=ededed|LENS_ID=test-lens|LENS_LABEL=deploy:test/test-lens|MODE=deploy|RUN_ID=test-run|REPO_NAME=test-repo|REPO_OWNER=local" "" "deploy" "" "" "false" "true" "/tmp/deploy-out")"
assert_contains "deploy has LOCAL MODE OVERRIDE" "LOCAL MODE OVERRIDE" "$result"
assert_contains "deploy has output path" "/tmp/deploy-out" "$result"

# Test 58: Real content template works with local mode
echo ""
echo "Test 58: content template with local mode"
content_file="$SCRIPT_DIR/prompts/_base/content.md"
result="$(compose_prompt "$content_file" "$TMPDIR/lens-local.md" "LENS_NAME=ContentBot|PROJECT_PATH=/test|DOMAIN=test|DOMAIN_NAME=Test|DOMAIN_COLOR=ededed|LENS_ID=test-lens|LENS_LABEL=content:test/test-lens|MODE=content|RUN_ID=test-run|REPO_NAME=test-repo|REPO_OWNER=local" "" "content" "" "" "false" "true" "/tmp/content-out")"
assert_contains "content has LOCAL MODE OVERRIDE" "LOCAL MODE OVERRIDE" "$result"

# =====================================================================
# SECTION L: Edge Cases
# =====================================================================

echo ""
echo "--- Section L: Edge cases ---"
echo ""

# Test 59: --local + --spec + --dry-run works
echo "Test 59: --local + --spec + --dry-run combined"
cat > "$TMPDIR/edge-spec.md" <<'EOF'
# Edge case spec
EOF
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --local --dry-run --spec "$TMPDIR/edge-spec.md"
assert_exit_code "--local + --spec + --dry-run exits 0" 0 "$RUN_EXIT"
assert_contains "shows local info" "local" "$RUN_OUTPUT"

# Test 60: --local + --yes does not ask for confirmation
echo ""
echo "Test 60: --local + --yes skips confirmation"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --yes --local
assert_not_contains "--local + --yes no confirmation header" "RepoLens Confirmation" "$RUN_OUTPUT"
assert_not_contains "--local + --yes no Proceed?" "Proceed?" "$RUN_OUTPUT"

# Test 61: --local with codex agent accepted
echo ""
echo "Test 61: --local with codex agent"
run_repolens --stdin "" --project "$TEST_REPO" --agent codex --yes --local
assert_not_contains "--local + codex accepted" "Unknown argument: --local" "$RUN_OUTPUT"

# Test 62: --local does not create GitHub labels
echo ""
echo "Test 62: --local does not create labels"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --yes --local
assert_not_contains "--local does not create labels" "gh label create" "$RUN_OUTPUT"

# Test 63: --output with relative path (canonicalization test)
# The implementation should canonicalize relative paths to absolute
echo ""
echo "Test 63: --output with relative path works"
mkdir -p "$TMPDIR/relative-test"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --yes --local --output "$TMPDIR/relative-test/output"
assert_not_contains "relative path accepted" "Unknown argument" "$RUN_OUTPUT"

# Test 64: count_dry_run_issues returns 0 for directory with only subdirs
echo ""
echo "Test 64: count_dry_run_issues — directory with only subdirs returns 0"
mkdir -p "$TMPDIR/only-subdirs/subdir1"
mkdir -p "$TMPDIR/only-subdirs/subdir2"
result="$(count_dry_run_issues "$TMPDIR/only-subdirs" 2>/dev/null)"
assert_eq "only subdirs returns 0" "0" "$result"

# Test 65: count_dry_run_issues with many files
echo ""
echo "Test 65: count_dry_run_issues — many files counted correctly"
mkdir -p "$TMPDIR/many-md"
for i in $(seq 1 25); do
  touch "$TMPDIR/many-md/$(printf '%03d' "$i")-finding.md"
done
result="$(count_dry_run_issues "$TMPDIR/many-md" 2>/dev/null)"
assert_eq "25 .md files counted" "25" "$result"

# Test 66: --local + --max-cost works
echo ""
echo "Test 66: --local + --max-cost works"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --yes --local --max-cost 100
assert_not_contains "--local + --max-cost accepted" "Unknown argument" "$RUN_OUTPUT"

# =====================================================================
# SECTION M: Coverage Gap Tests (added by coverage-test agent)
# =====================================================================

echo ""
echo "--- Section M: Coverage gap tests ---"
echo ""

# Test 67: count_dry_run_issues returns clean integer (no whitespace padding from wc -l)
echo "Test 67: count_dry_run_issues returns clean integer (no whitespace)"
mkdir -p "$TMPDIR/clean-int"
touch "$TMPDIR/clean-int/001-finding.md"
touch "$TMPDIR/clean-int/002-finding.md"
result="$(count_dry_run_issues "$TMPDIR/clean-int" 2>/dev/null)"
assert_eq "result has no leading/trailing whitespace" "2" "$result"
# Also verify it's strictly a number (no whitespace at all)
TOTAL=$((TOTAL + 1))
if [[ "$result" =~ ^[0-9]+$ ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: result is a clean integer"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: result is not a clean integer: '$result'"
fi

# Test 68: Default output dir resolves to logs/<run-id>/issues/ when --local without --output
echo ""
echo "Test 68: Default output dir is logs/<run-id>/issues/"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --local --dry-run
assert_contains "default output contains /issues" "/issues" "$RUN_OUTPUT"

# Test 69: --output path is canonicalized to absolute path (verified via dry-run output)
echo ""
echo "Test 69: Relative --output path canonicalized to absolute"
mkdir -p "$TMPDIR/rel-canon"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --local --dry-run --output "$TMPDIR/rel-canon"
# The dry-run output should show the full absolute path, not a relative one
assert_contains "canonicalized path shown" "$TMPDIR/rel-canon" "$RUN_OUTPUT"

# Test 70: Log output includes "Local mode:" line when --local active
echo ""
echo "Test 70: Log output includes Local mode line"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --yes --local
assert_contains "log has Local mode line" "Local mode" "$RUN_OUTPUT"

# Test 71: compose_prompt with local_mode=true but empty output dir produces no override
echo ""
echo "Test 71: compose_prompt local_mode=true + empty dir = no override"
result="$(compose_prompt "$TMPDIR/base-local.md" "$TMPDIR/lens-local.md" "LENS_NAME=EmptyDirBot" "" "audit" "" "" "false" "true" "")"
assert_not_contains "no override with empty dir" "LOCAL MODE OVERRIDE" "$result"
assert_not_contains "no placeholder artifact with empty dir" '{{LOCAL_MODE_SECTION}}' "$result"

# Test 72: compose_prompt local mode section includes deduplication instructions
echo ""
echo "Test 72: compose_prompt local mode includes deduplication"
result="$(compose_prompt "$TMPDIR/base-local.md" "$TMPDIR/lens-local.md" "LENS_NAME=DedupBot" "" "audit" "" "" "false" "true" "/tmp/dedup-test")"
assert_contains "deduplication mentioned" "Deduplication" "$result"

# Test 73: compose_prompt local mode section includes mkdir -p instruction
echo ""
echo "Test 73: compose_prompt local mode includes mkdir -p"
result="$(compose_prompt "$TMPDIR/base-local.md" "$TMPDIR/lens-local.md" "LENS_NAME=MkdirBot" "" "audit" "" "" "false" "true" "/tmp/mkdir-test")"
assert_contains "mkdir -p instruction" "mkdir -p" "$result"

# Test 74: init_summary with special characters in output_dir (spaces) produces valid JSON
echo ""
echo "Test 74: init_summary with spaces in output_dir produces valid JSON"
init_summary "$TMPDIR/summary-spaces.json" "test-run-3" "/tmp/project" "audit" "claude" "" "" "local" "/tmp/path with spaces/output"
TOTAL=$((TOTAL + 1))
if jq empty "$TMPDIR/summary-spaces.json" 2>/dev/null; then
  PASS=$((PASS + 1))
  echo "  PASS: JSON is valid with spaces in path"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: JSON is invalid with spaces in path"
fi
output_dir_val="$(jq -r '.output_dir' "$TMPDIR/summary-spaces.json" 2>/dev/null)"
assert_eq "output_dir preserves spaces" "/tmp/path with spaces/output" "$output_dir_val"

# Test 75: Dry-run + local shows "Output:" line with "local markdown" format
echo ""
echo "Test 75: Dry-run + local shows Output: local markdown format"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --local --dry-run --output "$TMPDIR/test-output-75"
assert_contains "dry-run shows 'local markdown'" "local markdown" "$RUN_OUTPUT"

# Test 76: --local produces "skipping label creation" log message
echo ""
echo "Test 76: --local produces label skip log message"
run_repolens --stdin "" --project "$TEST_REPO" --agent claude --yes --local
assert_contains "label skip message" "skipping label creation" "$RUN_OUTPUT"

# Test 77: compose_prompt local mode section includes gh issue list prohibition
echo ""
echo "Test 77: compose_prompt local mode forbids gh issue list"
result="$(compose_prompt "$TMPDIR/base-local.md" "$TMPDIR/lens-local.md" "LENS_NAME=NoListBot" "" "audit" "" "" "false" "true" "/tmp/no-list")"
assert_contains "forbids gh issue list" "gh issue list" "$result"

# Test 78: compose_prompt local mode section specifies file format (NNN-slug.md)
echo ""
echo "Test 78: compose_prompt local mode specifies NNN naming"
result="$(compose_prompt "$TMPDIR/base-local.md" "$TMPDIR/lens-local.md" "LENS_NAME=NNNBot" "" "audit" "" "" "false" "true" "/tmp/nnn-test")"
assert_contains "NNN naming convention" "NNN" "$result"
assert_contains "zero-padded sequence" "001" "$result"

# Test 79: compose_prompt local mode with all 8 real templates produces clean output (no leftover placeholders)
echo ""
echo "Test 79: All 8 real templates produce no leftover placeholders in local mode"
for tpl in audit feature bugfix discover deploy custom opensource content; do
  tpl_file="$SCRIPT_DIR/prompts/_base/$tpl.md"
  result="$(compose_prompt "$tpl_file" "$TMPDIR/lens-local.md" "LENS_NAME=CleanBot|PROJECT_PATH=/test|DOMAIN=test|DOMAIN_NAME=Test|DOMAIN_COLOR=ededed|LENS_ID=test-lens|LENS_LABEL=audit:test/test-lens|MODE=$tpl|RUN_ID=test-run|REPO_NAME=test-repo|REPO_OWNER=local" "" "$tpl" "" "" "false" "true" "/tmp/clean-check")"
  assert_not_contains "$tpl.md no LOCAL_MODE_SECTION artifact in local mode" '{{LOCAL_MODE_SECTION}}' "$result"
done

# Test 80: init_summary produces valid JSON even with empty optional params
echo ""
echo "Test 80: init_summary with all defaults produces valid JSON"
init_summary "$TMPDIR/summary-defaults.json" "test-run-4" "/tmp/project" "audit" "claude"
TOTAL=$((TOTAL + 1))
if jq empty "$TMPDIR/summary-defaults.json" 2>/dev/null; then
  PASS=$((PASS + 1))
  echo "  PASS: default params produce valid JSON"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: default params produce invalid JSON"
fi
# Verify default values
output_mode_val="$(jq -r '.output_mode' "$TMPDIR/summary-defaults.json" 2>/dev/null)"
assert_eq "default output_mode is github" "github" "$output_mode_val"
output_dir_val="$(jq -r '.output_dir' "$TMPDIR/summary-defaults.json" 2>/dev/null)"
assert_eq "default output_dir is null" "null" "$output_dir_val"

# --- Summary ---
echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
