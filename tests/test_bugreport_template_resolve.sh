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

# Tests for issue #167: BUG_REPORT must use the file-backed @path form when
# rendered through compose_prompt, the same way PRIOR_ROUND_DIGEST and
# HYPOTHESES_TO_VERIFY do. Without the allow-list entry the @/path string is
# emitted verbatim instead of being expanded to the bug-report body.

# shellcheck disable=SC1091 # Source paths are resolved from the repository root at runtime.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/template.sh
source "$SCRIPT_DIR/lib/template.sh"

PASS=0
FAIL=0
TOTAL=0

TMP_PARENT="$SCRIPT_DIR/logs/test-bugreport-template-resolve"
mkdir -p "$TMP_PARENT"
TMPDIR="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"

cleanup() {
  rm -rf "$TMPDIR"
  rmdir "$TMP_PARENT" 2>/dev/null || true
}
trap cleanup EXIT

pass_with() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

fail_with() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
  if [[ -n "${2:-}" ]]; then
    printf '    %s\n' "$2"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected to find: $needle"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Did not expect to find: $needle"
  fi
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

echo "=== bugreport BUG_REPORT @path resolution (issue #167) ==="

cat > "$TMPDIR/bug-report.txt" <<'EOF'
Symptom: requests randomly time out under load.
Trace: client | server | proxy boundary.
Backtick `code` fragment, ampersand & marker, backslash \ marker, <angle> markers.
Literal placeholder must stay literal: {{SPEC_SECTION}}.
EOF

cat > "$TMPDIR/lens.md" <<'EOF'
---
id: test-lens
domain: test
name: Test Lens
role: tester
---
## Your Expert Focus
Focus on the bug report symptom evidence.
EOF

echo ""
echo "Test 1: _template_resolve_file_backed_value resolves BUG_REPORT @path"
resolved="$(_template_resolve_file_backed_value "BUG_REPORT" "@${TMPDIR}/bug-report.txt")"
assert_contains "BUG_REPORT @path expands to bug-report body" \
                "Symptom: requests randomly time out under load." \
                "$resolved"
assert_contains "BUG_REPORT @path preserves pipe characters" \
                "client | server | proxy boundary." \
                "$resolved"
assert_not_contains "BUG_REPORT @path does not retain leading @-marker" \
                    "@${TMPDIR}/bug-report.txt" \
                    "$resolved"

echo ""
echo "Test 2: existing PRIOR_ROUND_DIGEST / HYPOTHESES_TO_VERIFY still resolve"
echo 'digest body' > "$TMPDIR/digest.md"
echo 'hypotheses body' > "$TMPDIR/hypotheses.md"
digest_resolved="$(_template_resolve_file_backed_value "PRIOR_ROUND_DIGEST" "@${TMPDIR}/digest.md")"
hyp_resolved="$(_template_resolve_file_backed_value "HYPOTHESES_TO_VERIFY" "@${TMPDIR}/hypotheses.md")"
assert_contains "PRIOR_ROUND_DIGEST still expands" "digest body" "$digest_resolved"
assert_contains "HYPOTHESES_TO_VERIFY still expands" "hypotheses body" "$hyp_resolved"

echo ""
echo "Test 2b: TRIAGE_CONTEXT_PACK @path is file-backed and pipe-safe (issue #171)"
cat > "$TMPDIR/pack.md" <<'EOF'
# Triage context pack

## Mentioned files
- lib/foo.sh | also lib/bar.sh
EOF
pack_resolved="$(_template_resolve_file_backed_value "TRIAGE_CONTEXT_PACK" "@${TMPDIR}/pack.md")"
assert_contains "TRIAGE_CONTEXT_PACK @path expands to pack body" \
                "# Triage context pack" \
                "$pack_resolved"
assert_contains "TRIAGE_CONTEXT_PACK @path preserves pipe characters" \
                "lib/foo.sh | also lib/bar.sh" \
                "$pack_resolved"
assert_not_contains "TRIAGE_CONTEXT_PACK @path does not retain leading @-marker" \
                    "@${TMPDIR}/pack.md" \
                    "$pack_resolved"

echo ""
echo "Test 3: unrelated keys still pass through unchanged"
unrelated="$(_template_resolve_file_backed_value "LENS_NAME" "@${TMPDIR}/bug-report.txt")"
assert_contains "unrelated key keeps raw @path" \
                "@${TMPDIR}/bug-report.txt" \
                "$unrelated"
assert_not_contains "unrelated key is not file-expanded" \
                    "Symptom: requests randomly time out" \
                    "$unrelated"

echo ""
echo "Test 4: compose_prompt against bugreport.md substitutes the file body"
base_vars="LENS_NAME=BugBot|DOMAIN_NAME=Bugfix|REPO_OWNER=owner|REPO_NAME=repo|PROJECT_PATH=/tmp/project|LENS_LABEL=bugreport:test/lens|DOMAIN_COLOR=ededed|DOMAIN=test|LENS_ID=test-lens|MODE=bugreport|RUN_ID=test-run|ROUND_INDEX=1|ROUND_TOTAL=1"
rendered="$(compose_prompt "$SCRIPT_DIR/prompts/_base/bugreport.md" "$TMPDIR/lens.md" "${base_vars}|BUG_REPORT=@${TMPDIR}/bug-report.txt" "" "bugreport")"

assert_contains "rendered prompt contains bug-report symptom text" \
                "Symptom: requests randomly time out under load." \
                "$rendered"
assert_contains "rendered prompt preserves pipe-bearing trace line" \
                "client | server | proxy boundary." \
                "$rendered"
assert_not_contains "rendered prompt does not leave @path token in place" \
                    "@${TMPDIR}/bug-report.txt" \
                    "$rendered"
assert_not_contains "rendered prompt consumes the {{BUG_REPORT}} placeholder" \
                    "{{BUG_REPORT}}" \
                    "$rendered"

echo ""
echo "Test 5: TRIAGE_CONTEXT_PACK slot is substituted in bugreport.md (issue #171)"
rendered_with_pack="$(compose_prompt "$SCRIPT_DIR/prompts/_base/bugreport.md" "$TMPDIR/lens.md" "${base_vars}|BUG_REPORT=@${TMPDIR}/bug-report.txt|TRIAGE_CONTEXT_PACK=@${TMPDIR}/pack.md" "" "bugreport")"
assert_contains "rendered bugreport prompt includes triage pack body" \
                "# Triage context pack" \
                "$rendered_with_pack"
assert_not_contains "rendered prompt consumes the {{TRIAGE_CONTEXT_PACK}} placeholder" \
                    "{{TRIAGE_CONTEXT_PACK}}" \
                    "$rendered_with_pack"

echo ""
echo "Test 6: missing TRIAGE_CONTEXT_PACK still consumes the placeholder (empty fallback)"
rendered_no_pack="$(compose_prompt "$SCRIPT_DIR/prompts/_base/bugreport.md" "$TMPDIR/lens.md" "${base_vars}|BUG_REPORT=@${TMPDIR}/bug-report.txt" "" "bugreport")"
assert_not_contains "rendered prompt without pack consumes the {{TRIAGE_CONTEXT_PACK}} placeholder" \
                    "{{TRIAGE_CONTEXT_PACK}}" \
                    "$rendered_no_pack"

echo ""
echo "Test 7: bug-report text is opaque to later template substitutions"
cat > "$TMPDIR/literal-report.txt" <<'EOF'
The template removes {{SPEC_SECTION}} and {{MAX_ISSUES_SECTION}} from the response.
Keep {{REPO_NAME}}, {{VOICE_PROFILE}}, {{TRIAGE_CONTEXT_PACK}}, and {{LOCAL_MODE_SECTION}} literal.
EOF
literal_report="$(cat "$TMPDIR/literal-report.txt")"
for report_value in "@$TMPDIR/literal-report.txt" "$literal_report"; do
  literal_prompt="$(compose_prompt "$SCRIPT_DIR/prompts/_base/bugreport.md" "$TMPDIR/lens.md" "${base_vars}|BUG_REPORT=${report_value}|VOICE_PROFILE=voice replacement|TRIAGE_CONTEXT_PACK=pack replacement" "" "bugreport")"
  assert_contains "complete bug-report input survives in the actual prompt" "$literal_report" "$literal_prompt"
  assert_contains "the actual repository slots still expand" "**owner/repo**" "$literal_prompt"
  assert_contains "the actual triage slot still expands" "pack replacement" "$literal_prompt"
done

echo ""
echo "Test 8: specification text is opaque to final context-slot replacements"
cat > "$TMPDIR/literal-spec.md" <<'EOF'
Specification expression: {{VOICE_PROFILE}} and {{TRIAGE_CONTEXT_PACK}}.
Keep {{SPEC_SECTION}} and {{BUG_REPORT}} literal too.
EOF
literal_spec="$(cat "$TMPDIR/literal-spec.md")"
spec_prompt="$(compose_prompt "$SCRIPT_DIR/prompts/_base/audit.md" "$TMPDIR/lens.md" "${base_vars}|VOICE_PROFILE=voice replacement|TRIAGE_CONTEXT_PACK=pack replacement" "$TMPDIR/literal-spec.md" "audit")"
assert_contains "complete specification survives in the actual audit prompt" "$literal_spec" "$spec_prompt"
assert_contains "specification reference wrapper is still rendered" "## Specification Reference" "$spec_prompt"

finish
