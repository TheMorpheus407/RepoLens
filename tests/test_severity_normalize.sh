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

echo "=== severity normalization ==="

assert_eq "uppercase HIGH normalizes" "high" "$(severity_normalize "HIGH")"
assert_eq "lowercase high remains canonical" "high" "$(severity_normalize "high")"
assert_eq "bracketed uppercase normalizes" "high" "$(severity_normalize "[HIGH]")"
assert_eq "leading and trailing spaces trim" "medium" "$(severity_normalize " Medium ")"
assert_eq "inner bracket spaces trim" "medium" "$(severity_normalize "[ medium ]")"
assert_eq "INFO is not a structured severity" "" "$(severity_normalize "INFO")"
assert_eq "unknown severity is rejected" "" "$(severity_normalize "urgent")"
assert_eq "empty input is rejected" "" "$(severity_normalize "")"

finish
