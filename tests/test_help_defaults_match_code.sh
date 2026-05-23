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

# Issue #239 — keep --help in sync with the real per-mode defaults.
#
# Two facts have drifted before:
#   1. --no-verifier help text described the polarity backwards relative to
#      the case branch that resolves NO_VERIFIER in repolens.sh.
#   2. --rounds help text claimed "default: 1" even though
#      MODE_DEFAULT_ROUNDS[bugreport]=3 in lib/core.sh.
#
# This suite parses --help output and the source of repolens.sh, then asserts
# the wording matches the actual defaults. A future change to either default
# (in lib/core.sh or in the repolens.sh case branch) must also update --help
# or this suite fails.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
# shellcheck source=../lib/core.sh
source "$SCRIPT_DIR/lib/core.sh"

PASS=0
FAIL=0
TOTAL=0

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

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected: $expected | Actual: $actual"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected output to contain: $needle"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Did not expect output to contain: $needle"
  fi
}

echo "=== help text reflects real per-mode defaults ==="

USAGE_OUTPUT="$(env -u REPOLENS_ROUNDS -u REPOLENS_NO_VERIFIER \
  bash "$SCRIPT_DIR/repolens.sh" --help 2>&1)"

# Tripwire 1 — MODE_DEFAULT_ROUNDS[bugreport] is the value we claim in help.
bugreport_default="${MODE_DEFAULT_ROUNDS[bugreport]:-}"
assert_eq "MODE_DEFAULT_ROUNDS[bugreport] is 3" "3" "$bugreport_default"

# Extract the --rounds help paragraph (its line plus following indented
# continuation lines until the next "  --" option line).
rounds_paragraph="$(printf '%s\n' "$USAGE_OUTPUT" |
  awk '
    /^  --rounds </ { capture=1; print; next }
    capture && /^  --/ { exit }
    capture { print }
  ')"

assert_contains "rounds help mentions bugreport" \
  "bugreport" "$rounds_paragraph"
assert_contains "rounds help mentions the real bugreport default" \
  "$bugreport_default" "$rounds_paragraph"
assert_contains "rounds help preserves the multi-round phrasing" \
  "only --mode bugreport" "$rounds_paragraph"

# Extract the --no-verifier help paragraph the same way.
verifier_paragraph="$(printf '%s\n' "$USAGE_OUTPUT" |
  awk '
    /^  --no-verifier / { capture=1; print; next }
    capture && /^  --/ { exit }
    capture { print }
  ')"

assert_contains "verifier help mentions bugreport" \
  "bugreport" "$verifier_paragraph"
assert_contains "verifier help says the verifier RUNS by default for bugreport" \
  "runs by default" "$verifier_paragraph"

# Polarity guard — the inverted construction ("Defaults: ON for ... bugreport")
# is exactly the wording the bug previously used. Make sure it never returns.
assert_not_contains "verifier help avoids inverted 'Defaults: ON for ... bugreport'" \
  "Defaults: ON for" "$verifier_paragraph"

# Source-level tripwire — the case branch in repolens.sh must still set
# NO_VERIFIER=false for bugreport. If a future refactor flips that branch,
# this assertion fires and forces the help text to be updated in lockstep.
verifier_case_line="$(grep -E '^[[:space:]]*bugreport\)[[:space:]]+NO_VERIFIER=' \
  "$SCRIPT_DIR/repolens.sh" | head -1)"
assert_contains "repolens.sh still resolves NO_VERIFIER=false for bugreport" \
  "NO_VERIFIER=false" "$verifier_case_line"

echo ""
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
