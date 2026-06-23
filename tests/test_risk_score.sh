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

# Tests for issue #315: lib/risk.sh — shared risk-ranking helper
# (finding_risk_score = severity_rank x confidence).
# Pure-function tests only; no AI models are invoked.
#
# Contract under test (from the issue acceptance criteria):
#   - A sourced shell function computes risk = severity_rank(severity) x confidence.
#   - Invalid/missing severity and invalid/missing confidence are handled
#     deterministically (documented default) and never crash the caller.
#   - The helper is pure and reuses severity_rank/severity_normalize (lib/core.sh).
#
# Design notes that shape these tests:
#   - Scores are compared NUMERICALLY, not as exact strings. The AC pins the
#     *ordering* and the *formula*, not the print precision; comparing numbers
#     keeps the contract robust to the implementer's chosen numeric format.
#   - severity_rank is 0-based (low=0), so risk(low, c) == 0 for every c. This
#     multiplication-by-zero property is asserted explicitly so downstream
#     triage authors don't expect confidence to order findings within `low`.
#   - The numeric VALUE of the missing/invalid-confidence default (e.g. 0.0 vs
#     0.5) is deliberately left to the implementer (the research sanctions
#     either), so it is tested as an invariant — deterministic, never-crashing,
#     and identical across the missing/empty/invalid inputs — not pinned.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_LIB="$SCRIPT_DIR/lib/core.sh"
RISK_LIB="$SCRIPT_DIR/lib/risk.sh"

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

assert_match() {
  local desc="$1" regex="$2" value="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$value" =~ $regex ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Value '$value' did not match /$regex/"
  fi
}

# assert_num_eq <desc> <a> <b>
#   Numeric equality within a tiny epsilon (format-agnostic: "2" == "2.0000").
assert_num_eq() {
  local desc="$1" a="$2" b="$3"
  TOTAL=$((TOTAL + 1))
  if awk -v a="$a" -v b="$b" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d < 1e-9) }'; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected numeric '$a' == '$b'"
  fi
}

# assert_num_gt <desc> <a> <b>
#   Strict numeric greater-than (the ordering / tie-break acceptance criteria).
assert_num_gt() {
  local desc="$1" a="$2" b="$3"
  TOTAL=$((TOTAL + 1))
  if awk -v a="$a" -v b="$b" 'BEGIN { exit !(a > b) }'; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected numeric '$a' > '$b'"
  fi
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

# --- Source the library (core.sh first: risk.sh reuses severity_rank) -------
TOTAL=$((TOTAL + 1))
if [[ -f "$RISK_LIB" ]]; then
  pass_with "lib/risk.sh exists"
else
  fail_with "lib/risk.sh exists" "missing: $RISK_LIB"
  finish
fi

# shellcheck source=/dev/null
source "$CORE_LIB"
# shellcheck source=/dev/null
source "$RISK_LIB"

TOTAL=$((TOTAL + 1))
if declare -F finding_risk_score >/dev/null 2>&1; then
  pass_with "finding_risk_score is defined after sourcing"
else
  fail_with "finding_risk_score is defined after sourcing"
  finish
fi

# --- Formula: risk == severity_rank x confidence ----------------------------
# Pins the multiplicative formula across all four severity ranks (3/2/1/0)
# with distinct confidences, independent of the printed precision.
assert_num_eq "critical(rank 3) x 1.0 == 3"    "$(finding_risk_score critical 1.0)" "3"
assert_num_eq "high(rank 2) x 0.5 == 1.0"      "$(finding_risk_score high 0.5)"     "1.0"
assert_num_eq "medium(rank 1) x 0.4 == 0.4"    "$(finding_risk_score medium 0.4)"   "0.4"
assert_num_eq "low(rank 0) x 0.9 == 0"         "$(finding_risk_score low 0.9)"      "0"

# --- AC: severity ordering at equal confidence (critical>high>medium>low) ---
c=1.0
s_crit="$(finding_risk_score critical "$c")"
s_high="$(finding_risk_score high "$c")"
s_med="$(finding_risk_score medium "$c")"
s_low="$(finding_risk_score low "$c")"
assert_num_gt "ordering: critical > high (equal confidence)" "$s_crit" "$s_high"
assert_num_gt "ordering: high > medium (equal confidence)"   "$s_high" "$s_med"
assert_num_gt "ordering: medium > low (equal confidence)"    "$s_med"  "$s_low"

# --- AC: higher confidence breaks ties at equal (non-low) severity ----------
# Must use a non-low severity: at `low` every score is 0, so confidence cannot
# differentiate (see the low-always-0 property below).
assert_num_gt "tie-break: high@0.9 > high@0.5" \
  "$(finding_risk_score high 0.9)" "$(finding_risk_score high 0.5)"

# --- Property: low severity is 0 for ANY confidence -------------------------
# Documents that confidence never orders findings within the `low` band.
assert_num_eq "low x 0.1 == 0 (multiply by rank 0)" "$(finding_risk_score low 0.1)" "0"

# --- AC #3: severity normalization is reused (severity_normalize) -----------
# A bracketed, padded, upper-cased severity must score identically to the bare
# canonical form — only possible if it flows through severity_normalize.
assert_num_eq "normalization reused: '[CRITICAL] ' == 'critical'" \
  "$(finding_risk_score "[CRITICAL] " 1.0)" "$(finding_risk_score critical 1.0)"

# --- AC #2: invalid/missing severity -> rank 0 -> 0, never crashes -----------
assert_num_eq "empty severity -> 0"   "$(finding_risk_score "" 0.9)"     "0"
inv_out="$(finding_risk_score banana 0.9)"; inv_rc=$?
assert_num_eq "unknown severity 'banana' -> 0" "$inv_out" "0"
assert_eq "invalid severity returns success (rc 0, no crash)" "0" "$inv_rc"

# --- AC: confidence clamped to its documented range -------------------------
# An out-of-range confidence (>1) is clamped, so high@1.5 == high@1.0.
assert_num_eq "confidence > 1 is clamped: high@1.5 == high@1.0" \
  "$(finding_risk_score high 1.5)" "$(finding_risk_score high 1.0)"

# --- AC: default-on-missing/invalid confidence is deterministic --------------
# The numeric default value is the implementer's documented choice; here we pin
# only its *invariants*: missing == empty == invalid, stable across calls, and
# the call always succeeds under `set -u` (omitted 2nd arg must not crash).
miss_out="$(finding_risk_score critical)"; miss_rc=$?
assert_eq "missing confidence returns success under set -u (rc 0)" "0" "$miss_rc"
assert_num_eq "missing confidence == empty confidence (same default)" \
  "$miss_out" "$(finding_risk_score critical "")"
assert_num_eq "default is deterministic across calls" \
  "$miss_out" "$(finding_risk_score critical)"
assert_num_eq "invalid confidence 'abc' uses the same default as missing" \
  "$(finding_risk_score critical abc)" "$(finding_risk_score critical "")"

# --- Output is a sort-friendly number ---------------------------------------
assert_match "score prints as a plain number (sort-friendly)" \
  '^[0-9]+(\.[0-9]+)?$' "$(finding_risk_score high 0.5)"

# ===========================================================================
# Coverage-stage additions (issue #315). Each block exercises an implemented
# code path in lib/risk.sh that the contract-defining tests above leave
# unverified. Expected values were confirmed against the real implementation.
# ===========================================================================

# --- Confidence authoring aliases low|medium|high -> 0.33|0.66|1.0 -----------
# The whole _risk_confidence_normalize alias `case` (the low/medium/high arms)
# is otherwise unexercised. The registry schema assigns this alias->numeric
# mapping to #315, so the concrete weights are part of this helper's contract.
assert_num_eq "alias 'high'   -> 1.0  (critical x 1.0  = 3.00)" "$(finding_risk_score critical high)"   "3"
assert_num_eq "alias 'medium' -> 0.66 (critical x 0.66 = 1.98)" "$(finding_risk_score critical medium)" "1.98"
assert_num_eq "alias 'low'    -> 0.33 (critical x 0.33 = 0.99)" "$(finding_risk_score critical low)"    "0.99"
# Aliases are matched case-insensitively (the normalizer lowercases first).
assert_num_eq "alias is case-insensitive: 'HIGH' == 'high'" \
  "$(finding_risk_score critical HIGH)" "$(finding_risk_score critical high)"
# And they preserve the intended ordering at a fixed (non-low) severity.
assert_num_gt "alias ordering: high@'high' > high@'medium'" \
  "$(finding_risk_score high high)" "$(finding_risk_score high medium)"
assert_num_gt "alias ordering: high@'medium' > high@'low'" \
  "$(finding_risk_score high medium)" "$(finding_risk_score high low)"

# --- Confidence < 0 is clamped to 0 (distinct branch from the >1 clamp) ------
# Above only the upper clamp (>1) is exercised; the lower clamp is its own awk
# arm (`if (c < 0) c = 0`). A negative confidence must floor to 0, not stay
# negative (which would invert ordering).
assert_num_eq "confidence < 0 is clamped to 0: high@-0.3 == 0" "$(finding_risk_score high -0.3)" "0"
assert_num_eq "lower-clamp matches an explicit 0: high@-0.3 == high@0" \
  "$(finding_risk_score high -0.3)" "$(finding_risk_score high 0)"

# --- Leading-dot decimals are accepted (the ^-?\.[0-9]+$ regex alternative) --
# `.5` (no integer part) is a separate, otherwise-untested validation branch;
# it must parse as 0.5, not fall through to the default.
assert_num_eq "leading-dot confidence '.5' parses as 0.5: high@.5 == high@0.5" \
  "$(finding_risk_score high .5)" "$(finding_risk_score high 0.5)"

# --- Numeric-looking junk is rejected -> documented default -----------------
# Scientific notation is deliberately NOT parsed; `1e-3` must take the default
# (0.5), the same as a missing value — proving the helper validates the numeric
# form rather than handing `1e-3` to awk (which would read it as ~0.001).
assert_num_eq "scientific notation '1e-3' falls back to the default" \
  "$(finding_risk_score critical 1e-3)" "$(finding_risk_score critical "")"

# --- Confidence is whitespace-trimmed before validation ---------------------
# The severity trim is covered above via '[CRITICAL] '; the confidence trim
# (same leading/trailing strip) is not. A padded numeric must parse, not default.
assert_num_eq "padded confidence ' 0.5 ' is trimmed then parsed: == high@0.5" \
  "$(finding_risk_score high " 0.5 ")" "$(finding_risk_score high 0.5)"

# --- Load-bearing default VALUE (0.5) pinned as a regression guard -----------
# The tests above pin the default's *invariants*; the implementation made a
# deliberate, documented choice of 0.5 (neutral midpoint) because `confidence`
# is `null` for every registry record today. Pin the concrete value: a critical
# finding with no confidence must land at 1.5 — strictly between high-certain
# (2.0) and medium-certain (1.0) — so unscored criticals are not buried.
assert_num_eq "default confidence is 0.5: critical@missing == 1.5" \
  "$(finding_risk_score critical "")" "1.5"
assert_num_gt "high-certain (2.0) outranks an unscored critical (1.5)" \
  "$(finding_risk_score high 1.0)" "$(finding_risk_score critical "")"
assert_num_gt "an unscored critical (1.5) outranks medium-certain (1.0)" \
  "$(finding_risk_score critical "")" "$(finding_risk_score medium 1.0)"

# --- End-to-end: scores rank correctly under `LC_ALL=C sort -rn` -------------
# The helper's entire purpose is ordering the human-triage artifacts (SUMMARY
# Top-N etc.). Feed a scrambled set through the exact numeric sort consumers
# use and assert the result is correctly ranked, format-agnostically.
sorted_scores="$(
  {
    finding_risk_score medium 1.0     # 1.0
    finding_risk_score critical 1.0   # 3.0
    finding_risk_score low 0.9        # 0.0
    finding_risk_score critical ""    # 1.5 (default)
    finding_risk_score high 1.0       # 2.0
  } | LC_ALL=C sort -rn
)"
mapfile -t sorted_arr <<< "$sorted_scores"
assert_num_eq "sort -rn: top is critical@1.0 (== 3)"          "${sorted_arr[0]}" "3"
assert_num_eq "sort -rn: critical-unscored sits 3rd (== 1.5)" "${sorted_arr[2]}" "1.5"
assert_num_eq "sort -rn: bottom is low (== 0)"                "${sorted_arr[4]}" "0"
assert_num_gt "sort -rn: rank is descending at [0] > [1]" "${sorted_arr[0]}" "${sorted_arr[1]}"
assert_num_gt "sort -rn: rank is descending at [3] > [4]" "${sorted_arr[3]}" "${sorted_arr[4]}"

# --- Coverage: zero-argument call (AC #2 combined edge) ----------------------
# AC #2 requires invalid/missing severity AND invalid/missing confidence to be
# handled deterministically and never crash. The suite covers each alone
# (`finding_risk_score "" 0.9`, `finding_risk_score critical`) but never both at
# once. A no-argument call must stay safe under `set -u` (both ${1:-}/${2:-}
# default), score rank-0 x default-confidence = 0, and return success.
zero_out="$(finding_risk_score)"; zero_rc=$?
assert_eq "zero-arg call returns success under set -u (rc 0)" "0" "$zero_rc"
assert_num_eq "zero-arg call (no severity, no confidence) -> 0" "$zero_out" "0"
assert_num_eq "zero-arg call == explicit empty severity + empty confidence" \
  "$zero_out" "$(finding_risk_score "" "")"

# --- Coverage: negative leading-dot decimal (regex alt 2 + lower clamp) ------
# `.5` (positive leading-dot) and `-0.3` (negative, with integer part) are
# covered, but a NEGATIVE leading-dot value `-.5` matches the OTHER regex
# alternative (^-?\.[0-9]+$) while carrying the sign; it must still floor to 0
# via the lower clamp, not fall through to the default or stay negative (which
# would invert ordering).
assert_num_eq "negative leading-dot '-.5' is clamped to 0: high@-.5 == 0" \
  "$(finding_risk_score high -.5)" "0"
assert_num_eq "negative leading-dot '-.5' == explicit lower bound high@0" \
  "$(finding_risk_score high -.5)" "$(finding_risk_score high 0)"

# --- Coverage: whitespace-only confidence trims to empty -> default ----------
# A confidence of only spaces trims to "" and must take the documented default
# (identical to a missing value), not match an alias or the numeric regex. This
# is a realistic input: the registry's confidence is null/blank today, so jq may
# hand the helper a whitespace-only string.
assert_num_eq "whitespace-only confidence '   ' uses the default (== empty)" \
  "$(finding_risk_score critical "   ")" "$(finding_risk_score critical "")"

finish
