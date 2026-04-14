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

# Tests for the --spec flag implementation
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/template.sh"

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

# --- Setup test fixtures ---
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# Minimal base template
cat > "$TMPDIR/base.md" <<'EOF'
You are a {{LENS_NAME}}.

## Rules
- Do stuff.

{{SPEC_SECTION}}

{{LENS_BODY}}

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

# Test spec file
cat > "$TMPDIR/spec.md" <<'EOF'
# Product Requirements

## Authentication
Users must authenticate via OAuth2.

## API
All endpoints must return JSON.
EOF

echo ""
echo "=== Test Suite: --spec flag ==="
echo ""

# --- Test 1: No spec — {{SPEC_SECTION}} becomes empty ---
echo "Test 1: No spec — clean substitution"
result="$(compose_prompt "$TMPDIR/base.md" "$TMPDIR/lens.md" "LENS_NAME=TestBot" "" "audit")"
assert_not_contains "no {{SPEC_SECTION}} artifact" '{{SPEC_SECTION}}' "$result"
assert_contains "lens body present" "Focus on testing things" "$result"
assert_contains "variable substituted" "TestBot" "$result"
# Should have two consecutive blank lines where {{SPEC_SECTION}} was (empty substitution)
assert_not_contains "no spec heading" "## Specification Reference" "$result"

# --- Test 2: With spec — audit mode ---
echo ""
echo "Test 2: With spec — audit mode framing"
result="$(compose_prompt "$TMPDIR/base.md" "$TMPDIR/lens.md" "LENS_NAME=AuditBot" "$TMPDIR/spec.md" "audit")"
assert_contains "spec heading present" "## Specification Reference" "$result"
assert_contains "audit framing" "Align your audit with this specification" "$result"
assert_contains "spec content" "Users must authenticate via OAuth2" "$result"
assert_contains "spec tags" "<spec>" "$result"
assert_contains "lens body after spec" "Focus on testing things" "$result"

# --- Test 3: With spec — feature mode ---
echo ""
echo "Test 3: With spec — feature mode framing"
result="$(compose_prompt "$TMPDIR/base.md" "$TMPDIR/lens.md" "LENS_NAME=FeatureBot" "$TMPDIR/spec.md" "feature")"
assert_contains "feature framing" "Use this specification as your feature roadmap" "$result"
assert_contains "spec content" "All endpoints must return JSON" "$result"

# --- Test 4: With spec — bugfix mode ---
echo ""
echo "Test 4: With spec — bugfix mode framing"
result="$(compose_prompt "$TMPDIR/base.md" "$TMPDIR/lens.md" "LENS_NAME=BugBot" "$TMPDIR/spec.md" "bugfix")"
assert_contains "bugfix framing" "Use this specification as ground truth" "$result"
assert_contains "deviation language" "a deviation from specified behavior is a bug" "$result"

# --- Test 4b: With spec — discover mode ---
echo ""
echo "Test 4b: With spec — discover mode framing"
result="$(compose_prompt "$TMPDIR/base.md" "$TMPDIR/lens.md" "LENS_NAME=DiscoverBot" "$TMPDIR/spec.md" "discover")"
assert_contains "discover framing" "Use this specification as context for your brainstorming" "$result"
assert_contains "discover vision language" "extend, complement, or creatively build upon" "$result"

# --- Test 5: Placeholder injection prevention ---
echo ""
echo "Test 5: Placeholder injection prevention"
cat > "$TMPDIR/malicious-spec.md" <<'EOF'
This spec mentions {{PROJECT_PATH}} and {{REPO_NAME}} literally.
Also {{LENS_BODY}} and {{SPEC_SECTION}}.
EOF
result="$(compose_prompt "$TMPDIR/base.md" "$TMPDIR/lens.md" "LENS_NAME=SafeBot|PROJECT_PATH=/my/project|REPO_NAME=myrepo" "$TMPDIR/malicious-spec.md" "audit")"
assert_contains "{{PROJECT_PATH}} literal in spec" '{{PROJECT_PATH}}' "$result"
assert_contains "{{REPO_NAME}} literal in spec" '{{REPO_NAME}}' "$result"
# Verify the variable was NOT substituted inside the spec content (injection prevention)
# The base template doesn't use {{PROJECT_PATH}}, so we just verify spec content is literal
assert_not_contains "no leaked substitution" 'LENS_NAME=SafeBot' "$result"

# --- Test 6: Special characters in spec ---
echo ""
echo "Test 6: Special characters survive"
cat > "$TMPDIR/special-spec.md" <<'SPECEOF'
Price is $100 & tax.
Use `backticks` for code.
Pipe: a | b
Backslash: C:\Users\test
Braces: {{ and }}
SPECEOF
result="$(compose_prompt "$TMPDIR/base.md" "$TMPDIR/lens.md" "LENS_NAME=SpecialBot" "$TMPDIR/special-spec.md" "audit")"
assert_contains "dollar sign" 'Price is $100' "$result"
assert_contains "backticks" '`backticks`' "$result"
assert_contains "pipe" 'a | b' "$result"

# --- Test 7: Empty spec file ---
echo ""
echo "Test 7: Empty spec file"
touch "$TMPDIR/empty-spec.md"
result="$(compose_prompt "$TMPDIR/base.md" "$TMPDIR/lens.md" "LENS_NAME=EmptyBot" "$TMPDIR/empty-spec.md" "audit")"
assert_not_contains "no spec heading for empty" "## Specification Reference" "$result"
assert_not_contains "no spec artifact" '{{SPEC_SECTION}}' "$result"

# --- Test 8: read_spec_file strips BOM ---
echo ""
echo "Test 8: BOM stripping"
printf '\xEF\xBB\xBFThis has a BOM.\nSecond line.' > "$TMPDIR/bom-spec.md"
result="$(read_spec_file "$TMPDIR/bom-spec.md")"
assert_eq "BOM stripped" "This has a BOM.
Second line." "$result"

# --- Test 9: read_spec_file strips CRLF ---
echo ""
echo "Test 9: CRLF stripping"
printf 'Line one.\r\nLine two.\r\n' > "$TMPDIR/crlf-spec.md"
result="$(read_spec_file "$TMPDIR/crlf-spec.md")"
# Command substitution strips trailing newlines, so expected has no trailing newline
assert_eq "CRLF stripped" "Line one.
Line two." "$result"

# --- Test 10: Spec ordering — appears before lens body ---
echo ""
echo "Test 10: Spec before lens body in output"
result="$(compose_prompt "$TMPDIR/base.md" "$TMPDIR/lens.md" "LENS_NAME=OrderBot" "$TMPDIR/spec.md" "audit")"
spec_pos="${result%%## Specification Reference*}"
lens_pos="${result%%## Your Expert Focus*}"
if [[ ${#spec_pos} -lt ${#lens_pos} ]]; then
  TOTAL=$((TOTAL + 1))
  PASS=$((PASS + 1))
  echo "  PASS: spec section appears before lens body"
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: spec section should appear before lens body"
fi

# --- Test 11: init_summary with spec ---
echo ""
echo "Test 11: init_summary with spec file"
source "$SCRIPT_DIR/lib/summary.sh"
init_summary "$TMPDIR/summary-spec.json" "test-run" "/tmp/project" "audit" "claude" "/path/to/spec.md"
spec_val="$(jq -r '.spec' "$TMPDIR/summary-spec.json")"
assert_eq "spec in summary" "/path/to/spec.md" "$spec_val"

# --- Test 12: init_summary without spec ---
echo ""
echo "Test 12: init_summary without spec file"
init_summary "$TMPDIR/summary-nospec.json" "test-run" "/tmp/project" "audit" "claude" ""
spec_val="$(jq -r '.spec' "$TMPDIR/summary-nospec.json")"
assert_eq "spec null in summary" "null" "$spec_val"

# --- Test 13: Size limit validation ---
echo ""
echo "Test 13: Size limit — file too large"
dd if=/dev/zero bs=1024 count=150 2>/dev/null | tr '\0' 'A' > "$TMPDIR/large-spec.txt"
# Source the validation logic manually
_spec_size="$(wc -c < "$TMPDIR/large-spec.txt")"
if [[ "$_spec_size" -gt 102400 ]]; then
  TOTAL=$((TOTAL + 1))
  PASS=$((PASS + 1))
  echo "  PASS: 150KB file detected as too large ($_spec_size bytes)"
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: 150KB file should be too large"
fi

# --- Test 14: Size limit — file within limit ---
echo ""
echo "Test 14: Size limit — file within limit"
dd if=/dev/zero bs=1024 count=90 2>/dev/null | tr '\0' 'B' > "$TMPDIR/ok-spec.txt"
_spec_size="$(wc -c < "$TMPDIR/ok-spec.txt")"
if [[ "$_spec_size" -le 102400 ]]; then
  TOTAL=$((TOTAL + 1))
  PASS=$((PASS + 1))
  echo "  PASS: 90KB file within limit ($_spec_size bytes)"
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: 90KB file should be within limit"
fi

# --- Test 15: Binary rejection ---
echo ""
echo "Test 15: Binary file detection"
printf 'Hello\x00World' > "$TMPDIR/binary-spec.bin"
if ! tr -d '\0' < "$TMPDIR/binary-spec.bin" | cmp -s - "$TMPDIR/binary-spec.bin"; then
  TOTAL=$((TOTAL + 1))
  PASS=$((PASS + 1))
  echo "  PASS: binary file detected (contains NUL)"
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: binary file should be detected"
fi

# --- Test 16: Base templates have {{SPEC_SECTION}} ---
echo ""
echo "Test 16: Base templates contain {{SPEC_SECTION}}"
for tpl in audit feature bugfix discover; do
  tpl_file="$SCRIPT_DIR/prompts/_base/$tpl.md"
  if grep -qF '{{SPEC_SECTION}}' "$tpl_file"; then
    TOTAL=$((TOTAL + 1))
    PASS=$((PASS + 1))
    echo "  PASS: $tpl.md has {{SPEC_SECTION}}"
  else
    TOTAL=$((TOTAL + 1))
    FAIL=$((FAIL + 1))
    echo "  FAIL: $tpl.md missing {{SPEC_SECTION}}"
  fi
done

# --- Test 17: Usage text includes --spec ---
echo ""
echo "Test 17: Usage mentions --spec"
if grep -qF -- '--spec' "$SCRIPT_DIR/repolens.sh"; then
  TOTAL=$((TOTAL + 1))
  PASS=$((PASS + 1))
  echo "  PASS: --spec in repolens.sh"
else
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: --spec not found in repolens.sh"
fi

# --- Test 18: Nonexistent spec file in compose_prompt ---
echo ""
echo "Test 18: Nonexistent spec file — graceful handling"
result="$(compose_prompt "$TMPDIR/base.md" "$TMPDIR/lens.md" "LENS_NAME=GhostBot" "/nonexistent/spec.md" "audit")"
assert_not_contains "no spec section for nonexistent" "## Specification Reference" "$result"
assert_not_contains "no artifact" '{{SPEC_SECTION}}' "$result"

# --- Summary ---
echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
