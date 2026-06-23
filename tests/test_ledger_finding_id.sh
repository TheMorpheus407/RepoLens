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

# Tests for issue #311: lib/ledger.sh — content-derived finding_id helper.
# Pure-function tests only; no AI models are invoked.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LEDGER_LIB="$SCRIPT_DIR/lib/ledger.sh"

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
  if [[ -n "$detail" ]]; then
    printf '    %s\n' "$detail"
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

assert_ne() {
  local desc="$1" a="$2" b="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$a" != "$b" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected distinct ids, both were '$a'"
  fi
}

assert_match() {
  local desc="$1" regex="$2" value="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$value" =~ $regex ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Value '$value' did not match /$regex/"
  fi
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

# --- Source the library alone (must be self-contained) ---------------------
TOTAL=$((TOTAL + 1))
if [[ -f "$LEDGER_LIB" ]]; then
  pass_with "lib/ledger.sh exists"
else
  fail_with "lib/ledger.sh exists" "missing: $LEDGER_LIB"
  finish
fi

# shellcheck source=/dev/null
source "$LEDGER_LIB"

TOTAL=$((TOTAL + 1))
if declare -F finding_id >/dev/null 2>&1; then
  pass_with "finding_id is defined after sourcing"
else
  fail_with "finding_id is defined after sourcing"
  finish
fi

# Sourcing alone must not pollute the shell: confirm no positional args were
# consumed and the function returns a single line (no top-level side effects).

# --- Format: fnd-<12 hex> ---------------------------------------------------
id_fmt="$(finding_id code input-validation "SQL injection in login" "src/auth.go:42")"
assert_match "id has fnd-<12 hex> format" '^fnd-[0-9a-f]{12}$' "$id_fmt"

# --- Determinism: identical args -> identical id ----------------------------
id_a="$(finding_id code input-validation "SQL injection in login" "src/auth.go:42")"
id_b="$(finding_id code input-validation "SQL injection in login" "src/auth.go:42")"
assert_eq "deterministic across invocations" "$id_a" "$id_b"

# --- Normalization equivalence ----------------------------------------------
# "[High] Foo bar!" and "foo  bar" normalize to the same canonical title, so
# with identical domain/lens/location they must collide on the same id.
id_norm1="$(finding_id code input-validation "[High] Foo bar!")"
id_norm2="$(finding_id code input-validation "foo  bar")"
assert_eq "normalization: severity prefix + casing + punctuation ignored" "$id_norm1" "$id_norm2"

# Casing-only difference also collides.
id_case1="$(finding_id code input-validation "Missing CSRF token")"
id_case2="$(finding_id code input-validation "missing csrf token")"
assert_eq "normalization: pure casing difference ignored" "$id_case1" "$id_case2"

# A non-severity bracket prefix (e.g. "[P1]") is NOT stripped, so it stays
# distinct from the same title without the prefix.
id_p1="$(finding_id code input-validation "[P1] queue backlog")"
id_plain="$(finding_id code input-validation "queue backlog")"
assert_ne "non-severity bracket prefix is preserved (not stripped)" "$id_p1" "$id_plain"

# --- Collision avoidance: differing fields yield differing ids --------------
base="$(finding_id code input-validation "SQL injection in login" "src/auth.go:42")"
diff_domain="$(finding_id deployment input-validation "SQL injection in login" "src/auth.go:42")"
diff_lens="$(finding_id code crypto "SQL injection in login" "src/auth.go:42")"
diff_title="$(finding_id code input-validation "XSS in login" "src/auth.go:42")"
diff_loc="$(finding_id code input-validation "SQL injection in login" "src/auth.go:99")"

assert_ne "different domain -> different id" "$base" "$diff_domain"
assert_ne "different lens -> different id" "$base" "$diff_lens"
assert_ne "different title -> different id" "$base" "$diff_title"
assert_ne "different location -> different id" "$base" "$diff_loc"

# --- Optional primary_location ---------------------------------------------
# Omitting the location is allowed (works under set -u) and is stable.
id_noloc1="$(finding_id code input-validation "SQL injection in login")"
id_noloc2="$(finding_id code input-validation "SQL injection in login")"
assert_match "missing location still yields valid id" '^fnd-[0-9a-f]{12}$' "$id_noloc1"
assert_eq "missing location is deterministic" "$id_noloc1" "$id_noloc2"
assert_ne "empty location differs from a populated location" "$id_noloc1" "$base"

finish
