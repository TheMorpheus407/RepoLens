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

# Behavioral contract for finding_type_normalize (issue #327).
#
# Mirrors tests/test_severity_normalize.sh: source lib/core.sh, then drive a
# table of assert_eq cases through the pure helper. No real model is ever
# invoked — the function only reads $1 and writes to stdout.
#
# Contract under test:
#   - Trim leading/trailing whitespace; strip an optional surrounding [...].
#   - Lowercase, then map to one of the six canonical finding-type ids.
#   - Each canonical id round-trips to itself.
#   - The documented aliases from the issue repair to the right canonical id.
#   - Unknown/empty/no-arg input prints empty string and does not error
#     under `set -u` (same empty-on-unknown contract as severity_normalize).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_LIB="$SCRIPT_DIR/lib/core.sh"

PASS=0
FAIL=0
TOTAL=0

pass_with() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

fail_with() {
  local desc="$1" detail="${2:-}"
  FAIL=$((FAIL + 1))
  echo "  FAIL: $desc"
  [[ -n "$detail" ]] && printf '    %s\n' "$detail"
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

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

if [[ ! -f "$CORE_LIB" ]]; then
  fail_with "lib/core.sh exists" "Missing $CORE_LIB"
  finish
fi

# shellcheck disable=SC1090
source "$CORE_LIB"

echo "=== finding-type normalization ==="

# --- the six canonical ids round-trip to themselves ---
assert_eq "security-vulnerability round-trips" "security-vulnerability" "$(finding_type_normalize "security-vulnerability")"
assert_eq "reliability-bug round-trips" "reliability-bug" "$(finding_type_normalize "reliability-bug")"
assert_eq "performance-risk round-trips" "performance-risk" "$(finding_type_normalize "performance-risk")"
assert_eq "maintainability round-trips" "maintainability" "$(finding_type_normalize "maintainability")"
assert_eq "test-gap round-trips" "test-gap" "$(finding_type_normalize "test-gap")"
assert_eq "external-dependency round-trips" "external-dependency" "$(finding_type_normalize "external-dependency")"

# --- case folding ---
assert_eq "uppercase canonical folds" "security-vulnerability" "$(finding_type_normalize "SECURITY-VULNERABILITY")"
assert_eq "mixed-case canonical folds" "test-gap" "$(finding_type_normalize "Test-Gap")"

# --- whitespace trimming ---
assert_eq "leading and trailing spaces trim" "maintainability" "$(finding_type_normalize "  maintainability  ")"
# tabs (not just literal spaces) trim too: the helper uses the [:space:] class,
# so a naive space-only strip would leave the tabs and wrongly reject the value.
assert_eq "leading and trailing tabs trim" "reliability-bug" "$(finding_type_normalize "$(printf '\treliability-bug\t')")"

# --- optional [...] wrapper stripping ---
assert_eq "bracketed value strips" "performance-risk" "$(finding_type_normalize "[performance-risk]")"
assert_eq "bracketed + inner spaces + case fold" "test-gap" "$(finding_type_normalize "[ TEST-GAP ]")"

# --- documented aliases (verbatim from the issue body) repair to canonical ---
assert_eq "alias: security" "security-vulnerability" "$(finding_type_normalize "security")"
assert_eq "alias: bug" "reliability-bug" "$(finding_type_normalize "bug")"
assert_eq "alias: correctness" "reliability-bug" "$(finding_type_normalize "correctness")"
assert_eq "alias: reliability" "reliability-bug" "$(finding_type_normalize "reliability")"
assert_eq "alias: perf" "performance-risk" "$(finding_type_normalize "perf")"
assert_eq "alias: performance" "performance-risk" "$(finding_type_normalize "performance")"
assert_eq "alias: tests" "test-gap" "$(finding_type_normalize "tests")"
assert_eq "alias: testing" "test-gap" "$(finding_type_normalize "testing")"
assert_eq "alias: cve" "external-dependency" "$(finding_type_normalize "cve")"
assert_eq "alias: dependency" "external-dependency" "$(finding_type_normalize "dependency")"

# --- alias combined with decoration (bracket + case + space) ---
assert_eq "decorated alias normalizes" "performance-risk" "$(finding_type_normalize "[ Perf ]")"

# --- unknown / empty / no-arg → empty string, no error under set -u ---
assert_eq "unknown word is rejected" "" "$(finding_type_normalize "foo")"
assert_eq "empty input is rejected" "" "$(finding_type_normalize "")"
# whitespace-only collapses to empty after the trim, then rejects (the boundary
# of the empty contract: blank-but-nonzero input must behave like "" not error).
assert_eq "whitespace-only input is rejected" "" "$(finding_type_normalize "   ")"
assert_eq "space instead of hyphen is rejected" "" "$(finding_type_normalize "security vuln")"
assert_eq "no argument is safe and empty" "" "$(finding_type_normalize)"
# partial bracket must NOT strip (guard requires a full [...] wrapper); a broken
# guard would leave a valid id and wrongly normalize instead of returning empty.
assert_eq "unclosed leading bracket is not stripped" "" "$(finding_type_normalize "[security-vulnerability")"
# symmetric to the above: a trailing ] with no leading [ must NOT strip either.
# This pins that the guard requires BOTH brackets — a guard checking only the
# trailing `]` (e.g. == *\]) would wrongly peel it and normalize the bare id.
assert_eq "trailing bracket without opener is not stripped" "" "$(finding_type_normalize "security-vulnerability]")"

finish
