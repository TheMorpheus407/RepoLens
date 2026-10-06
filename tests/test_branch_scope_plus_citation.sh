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

# Tests for issue #410: bare citations containing '+' must retain the complete
# filename. The unanchored bare-citation regex in
# repolens_extract_citations used to drop the path prefix up to '+', so
# 'src/routes/+page.svelte:1' was extracted as the unrelated root citation
# 'page.svelte:1'. Both consumers then validated the wrong file:
# branch_scope_verify_body accepted the truncated path when the root twin is
# allowlisted, and filing_verify_cluster_citations stats the root twin instead
# of the cited route file.
#
# Behavioral contract pinned here:
#   1. Bare citations preserve the complete supported filename, including
#      'src/routes/+page.svelte'; the truncated twin suffix is never emitted.
#   2. Branch scope rejects the route citation when only the root twin file is
#      allowlisted, even though that root file exists.
#   3. When the full route is allowlisted and the cited line exists in the
#      route file, both checks pass — and neither check can be satisfied by
#      the wrong-file twin (asserted in both line-count directions).
#   4. Tokens with unsupported characters (e.g. '@') are rejected whole; they
#      cannot yield a valid suffix citation for either consumer.
#   5. Existing supported forms are preserved: backtick-quoted paths (with
#      spaces and with '+'), conventional root filenames, line ranges, and
#      the exclusion of URLs and timestamps.
#   6. A bare token starting with '+' (e.g. +page.svelte:1) is rejected whole:
#      the suffix after '+' never becomes a root-file citation for either
#      consumer, even when that root twin exists and is allowlisted.
#   7. Punctuation-delimited citations (comma-adjacent lists, parenthesized
#      line ranges, start of a later line in multi-line bodies) keep their
#      exact paths; the boundary delimiter is stripped, never part of the
#      citation.
#   8. A citation to a '+' route that is absent on disk fails verification
#      even when a longer root twin exists — the verifier stats only the
#      named file, and its failure reason names the complete '+' path.
#   9. '~' home-path tokens are rejected whole like other unsupported
#      characters: nothing is extracted, so both consumers fail closed even
#      when the suffix path exists and is allowlisted.
#
# No real agent, forge, or network call is performed; fixtures are plain
# files under a temporary directory.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/filing.sh"

PASS=0
FAIL=0
TOTAL=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass_with() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

fail_with() {
  local desc="$1" detail="${2:-}"
  FAIL=$((FAIL + 1))
  echo "  FAIL: $desc"
  if [[ -n "$detail" ]]; then
    printf '    %s\n' "$detail"
  fi
}

assert_success() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -eq 0 ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected exit 0, got $actual"
  fi
}

assert_failure() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -ne 0 ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected non-zero exit"
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected '$expected', got '$actual'"
  fi
}

# Exact whole-line membership assertions for multi-line extractor output, so a
# truncated suffix can never hide inside a longer path line.
assert_has_line() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if printf '%s\n' "$actual" | grep -qxF -- "$expected"; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected line '$expected' in: ${actual:0:300}"
  fi
}

assert_lacks_line() {
  local desc="$1" unwanted="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if printf '%s\n' "$actual" | grep -qxF -- "$unwanted"; then
    fail_with "$desc" "Unexpected line '$unwanted' in: ${actual:0:300}"
  else
    pass_with "$desc"
  fi
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

# shellcheck disable=SC2034 # Read by branch_scope_verify_body in sourced lib/branch-scope.sh.
MODE=branch-review
unset REPOLENS_MODE
SCOPE_FILE="$TMP/scope.json"
# shellcheck disable=SC2034 # Read by branch_scope_verify_body in sourced lib/branch-scope.sh.
BRANCH_SCOPE_FILE="$SCOPE_FILE"

# Project A: the cited route file is DEEPER than the unrelated root twin, so a
# citation to the route's own line 2 can only verify against the real route.
PROJECT_A="$TMP/project-a"
mkdir -p "$PROJECT_A/src/routes" "$PROJECT_A/scope"
printf 'actual unchanged source\nsecond route line\n' > "$PROJECT_A/src/routes/+page.svelte"
printf 'unrelated changed source\n' > "$PROJECT_A/page.svelte"
printf 'export const x = 1\n' > "$PROJECT_A/scope/file.sh"

# Project B: the root twin is DEEPER than the cited route file, so accepting
# the truncated twin would wrongly validate a citation the route cannot back.
PROJECT_B="$TMP/project-b"
mkdir -p "$PROJECT_B/src/routes"
printf 'actual unchanged source\n' > "$PROJECT_B/src/routes/+page.svelte"
printf 'unrelated changed source\ntwin line two\ntwin line three\n' > "$PROJECT_B/page.svelte"

echo ""
echo "=== Case 1: extractor preserves the complete '+' path ==="

body='The regression is at src/routes/+page.svelte:1'
extracted="$(repolens_extract_citations "$body")"
assert_has_line "bare citation keeps the full src/routes/+page.svelte path" \
  'src/routes/+page.svelte:1' "$extracted"
assert_lacks_line "extractor never emits the truncated page.svelte twin" \
  'page.svelte:1' "$extracted"

echo ""
echo "=== Case 2: issue fixture — root twin allowlisted, route must be rejected ==="

printf '["page.svelte"]\n' > "$SCOPE_FILE"
branch_scope_verify_body "$body" >/dev/null 2>&1
assert_failure "branch scope rejects the route citation when only the root twin is allowlisted" "$?"

echo ""
echo "=== Case 3: citation verifier targets the named file, never the root twin ==="

entry_line2="$(jq -n --arg body 'The regression is at src/routes/+page.svelte:2' '{body:$body}')"
filing_verify_cluster_citations "$PROJECT_A" "$entry_line2" >/dev/null 2>&1
assert_success "route's own second line verifies when the root twin is shorter" "$?"
filing_verify_cluster_citations "$PROJECT_B" "$entry_line2" >/dev/null 2>&1
assert_failure "citation beyond the route's length fails even when the root twin is longer" "$?"

echo ""
echo "=== Case 4: full route allowlisted — both checks accept the real file ==="

printf '["src/routes/+page.svelte"]\n' > "$SCOPE_FILE"
branch_scope_verify_body "$body" >/dev/null 2>&1
assert_success "branch scope accepts the allowlisted route citation" "$?"
entry_range="$(jq -n --arg body 'The regression spans src/routes/+page.svelte:1-2' '{body:$body}')"
filing_verify_cluster_citations "$PROJECT_A" "$entry_range" >/dev/null 2>&1
assert_success "line-range citation against the route file verifies" "$?"

echo ""
echo "=== Case 5: unsupported characters cannot yield a valid suffix citation ==="

at_body='Importer lives at src/@scope/file.sh:1'
at_extracted="$(repolens_extract_citations "$at_body")"
assert_lacks_line "unsupported '@' token never yields the suffix citation" \
  'scope/file.sh:1' "$at_extracted"
printf '["scope/file.sh"]\n' > "$SCOPE_FILE"
branch_scope_verify_body "$at_body" >/dev/null 2>&1
assert_failure "scope check rejects a body whose only citation uses an unsupported character" "$?"
at_entry="$(jq -n --arg body "$at_body" '{body:$body}')"
filing_verify_cluster_citations "$PROJECT_A" "$at_entry" >/dev/null 2>&1
assert_failure "citation check rejects a body whose only citation uses an unsupported character" "$?"

echo ""
echo "=== Case 6: previously supported citation forms are preserved ==="

quoted="$(repolens_extract_citations 'See `src/with spaces.sh:1` for context')"
assert_has_line "backtick-quoted path with spaces still extracts" \
  'src/with spaces.sh:1' "$quoted"
quoted_plus="$(repolens_extract_citations 'See `src/routes/+page.svelte:1`')"
assert_has_line "backtick-quoted '+' path still extracts" \
  'src/routes/+page.svelte:1' "$quoted_plus"
root_file="$(repolens_extract_citations 'Makefile:2 needs a fix')"
assert_has_line "conventional root filename still extracts" 'Makefile:2' "$root_file"
range="$(repolens_extract_citations 'src/changed.sh:2-4 is wrong')"
assert_has_line "line-range citations still extract" 'src/changed.sh:2-4' "$range"
url="$(repolens_extract_citations 'browse https://example.com/src/a.sh:10 later')"
assert_eq "URLs are not source citations" "" "$url"
timestamp="$(repolens_extract_citations 'failed at 12:34:56 yesterday')"
assert_eq "timestamps are not source citations" "" "$timestamp"

echo ""
echo "=== Case 7: bare '+'-leading token is rejected whole, never a root-file citation ==="

plus_leading_body='The bug is in +page.svelte:1 today'
plus_leading="$(repolens_extract_citations "$plus_leading_body")"
assert_eq "bare '+'-leading token yields no citation at all" "" "$plus_leading"
printf '["page.svelte"]\n' > "$SCOPE_FILE"
branch_scope_verify_body "$plus_leading_body" >/dev/null 2>&1
assert_failure "scope rejects '+'-leading citation even when the root twin is allowlisted" "$?"
plus_leading_entry="$(jq -n --arg body "$plus_leading_body" '{body:$body}')"
filing_verify_cluster_citations "$PROJECT_A" "$plus_leading_entry" >/dev/null 2>&1
assert_failure "citation check rejects '+'-leading citation even when the root twin exists" "$?"

echo ""
echo "=== Case 8: punctuation-delimited citations keep their exact paths ==="

adjacent="$(repolens_extract_citations 'fix src/a.sh:1,src/b.sh:2 now')"
assert_has_line "first comma-adjacent citation extracts" 'src/a.sh:1' "$adjacent"
assert_has_line "second comma-adjacent citation extracts" 'src/b.sh:2' "$adjacent"
assert_lacks_line "boundary delimiter is stripped from the citation" \
  ',src/b.sh:2' "$adjacent"
paren="$(repolens_extract_citations 'see (src/foo.sh:10-12) here')"
assert_has_line "parenthesized line-range citation extracts without the delimiter" \
  'src/foo.sh:10-12' "$paren"
multiline="$(repolens_extract_citations "$(printf 'first line\nsrc/late.sh:5 trailing')")"
assert_has_line "citation at the start of a later line extracts" \
  'src/late.sh:5' "$multiline"

echo ""
echo "=== Case 9: missing '+' route on disk — verifier never falls back to the root twin ==="

# Project C: only the unrelated root twin exists, with enough lines to satisfy
# the citation if the truncated twin were stat'ed instead of the named route.
PROJECT_C="$TMP/project-c"
mkdir -p "$PROJECT_C"
printf 'twin line one\ntwin line two\ntwin line three\n' > "$PROJECT_C/page.svelte"
missing_entry="$(jq -n --arg body 'The regression is at src/routes/+page.svelte:2' '{body:$body}')"
missing_reason="$(filing_verify_cluster_citations "$PROJECT_C" "$missing_entry" 2>/dev/null)"
missing_rc=$?
assert_failure "citation to a missing '+' route fails even when a longer root twin exists" "$missing_rc"
assert_eq "failure reason names the complete '+' path, never the twin" \
  'src/routes/+page.svelte:2 file not found' "$missing_reason"

echo ""
echo "=== Case 10: '~' home-path tokens are rejected whole, never a suffix citation ==="

# The suffix path exists on disk and is allowlisted, so only whole-token
# rejection of the unsupported '~' character keeps both consumers closed.
mkdir -p "$PROJECT_C/src"
printf 'echo hi\n' > "$PROJECT_C/src/a.sh"
printf '["src/a.sh"]\n' > "$SCOPE_FILE"
tilde_body='Try ~/src/a.sh:1 for the fix'
tilde_extracted="$(repolens_extract_citations "$tilde_body")"
assert_eq "'~' token yields no citation at all" "" "$tilde_extracted"
branch_scope_verify_body "$tilde_body" >/dev/null 2>&1
assert_failure "scope rejects '~' citation even when the suffix path is allowlisted" "$?"
tilde_entry="$(jq -n --arg body "$tilde_body" '{body:$body}')"
filing_verify_cluster_citations "$PROJECT_C" "$tilde_entry" >/dev/null 2>&1
assert_failure "citation check rejects '~' citation even when the suffix file exists" "$?"

finish
