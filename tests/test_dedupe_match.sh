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

# Tests for issue #322: extend near-duplicate matching to cross-domain +
# location-based. Pure-function tests only; no AI models are invoked.
#
# Contract under test (from the issue acceptance criteria):
#   _dedupe_location_key <record_json>
#     Prints a normalized location key (lowercased, path normalized, line
#     dropped). Precedence: .primary_location -> first .suspect_files[] ->
#     first .source_finding_paths[] -> empty string. Missing/invalid input
#     yields the empty key without crashing. Deterministic.
#   _dedupe_is_match <record_a_json> <record_b_json>
#     Exit-code predicate (0 = match). Matches when EITHER title Jaccard >=
#     primary threshold OR (both location keys non-empty AND equal AND title
#     Jaccard >= a lower secondary threshold). Reuses _synthesize_title_ngrams
#     + _synthesize_jaccard_x10000. Does NOT gate on .domain (cross-domain).
#
# Design notes that shape these tests:
#   - We test PUBLIC behavior (the returned key / the match exit code), never
#     internal sort/format details. The implementer may place the helpers in a
#     new lib/dedupe.sh (research recommendation) OR in lib/synthesize.sh
#     (AC-literal); the test sources whichever defines them — assert on the
#     FUNCTION, not the file (mirrors tests/test_dedupe_canonical.sh).
#   - Thresholds are pinned by exporting DEDUPE_TITLE_SIM_PRIMARY /
#     DEDUPE_TITLE_SIM_SECONDARY so the location-branch fixtures are stable
#     against future default tuning (#353), and so the env-override contract is
#     itself exercised.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_LIB="$SCRIPT_DIR/lib/core.sh"
SYNTH_LIB="$SCRIPT_DIR/lib/synthesize.sh"
DEDUPE_LIB="$SCRIPT_DIR/lib/dedupe.sh"

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

# assert_eq <desc> <expected> <actual> — exact string equality (a location key).
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected '$expected', got '$actual'"
  fi
}

# assert_match <desc> <rec_a> <rec_b> — _dedupe_is_match returns 0 (a match).
assert_match() {
  local desc="$1" a="$2" b="$3"
  TOTAL=$((TOTAL + 1))
  if _dedupe_is_match "$a" "$b"; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected match (rc 0), got rc $?"
  fi
}

# assert_no_match <desc> <rec_a> <rec_b> — _dedupe_is_match returns non-zero.
assert_no_match() {
  local desc="$1" a="$2" b="$3"
  TOTAL=$((TOTAL + 1))
  if _dedupe_is_match "$a" "$b"; then
    fail_with "$desc" "Expected NO match (non-zero rc), got rc 0"
  else
    pass_with "$desc"
  fi
}

# assert_true <desc> <rc> — generic "command exited 0".
assert_true() {
  local desc="$1" rc="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$rc" -eq 0 ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected rc 0, got $rc"
  fi
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

# --- Source the libraries (core first; the helpers reuse severity_* + title
# similarity primitives). Prefer dedupe.sh, fall back to synthesize.sh — assert
# on the FUNCTION, not the file. ----------------------------------------------
# shellcheck source=/dev/null
source "$CORE_LIB"
# shellcheck source=/dev/null
[[ -f "$SYNTH_LIB" ]] && source "$SYNTH_LIB"
if [[ -f "$DEDUPE_LIB" ]]; then
  # shellcheck source=/dev/null
  source "$DEDUPE_LIB"
fi
# If the helpers landed in synthesize.sh only, the source above already defined
# them; nothing else to do.

TOTAL=$((TOTAL + 1))
if declare -F _dedupe_location_key >/dev/null 2>&1; then
  pass_with "_dedupe_location_key is defined after sourcing (dedupe.sh or synthesize.sh)"
else
  fail_with "_dedupe_location_key is defined after sourcing (dedupe.sh or synthesize.sh)" \
    "not found in lib/dedupe.sh or lib/synthesize.sh"
  finish
fi

TOTAL=$((TOTAL + 1))
if declare -F _dedupe_is_match >/dev/null 2>&1; then
  pass_with "_dedupe_is_match is defined after sourcing (dedupe.sh or synthesize.sh)"
else
  fail_with "_dedupe_is_match is defined after sourcing (dedupe.sh or synthesize.sh)" \
    "not found in lib/dedupe.sh or lib/synthesize.sh"
  finish
fi

# Pin thresholds so the location-branch fixtures are stable AND to exercise the
# env-override contract. Primary 8500 (0.85), secondary 6000 (0.60) — the
# documented defaults.
export DEDUPE_TITLE_SIM_PRIMARY=8500
export DEDUPE_TITLE_SIM_SECONDARY=6000

# ===========================================================================
# _dedupe_location_key — precedence.
# ===========================================================================
# primary_location wins over suspect_files and source_finding_paths.
KEY="$(_dedupe_location_key '{
  "primary_location":"src/Auth.go:88",
  "suspect_files":["src/Other.go"],
  "source_finding_paths":["logs/r/lens-outputs/auth/x.md"]
}')"
assert_eq "precedence: primary_location wins (line dropped, lowercased)" "src/auth.go" "$KEY"

# suspect_files used when primary_location is absent.
KEY="$(_dedupe_location_key '{
  "suspect_files":["src/Crypto.go:42:7","src/Second.go"],
  "source_finding_paths":["logs/r/lens-outputs/crypto/y.md"]
}')"
assert_eq "precedence: first suspect_files used when primary_location absent" "src/crypto.go" "$KEY"

# source_finding_paths used when both primary_location and suspect_files absent.
KEY="$(_dedupe_location_key '{
  "source_finding_paths":["Logs/Run/Out.md","logs/run/two.md"]
}')"
assert_eq "precedence: first source_finding_paths used as last resort (lowercased)" "logs/run/out.md" "$KEY"

# ===========================================================================
# _dedupe_location_key — graceful empty key on missing/invalid input.
# ===========================================================================
KEY="$(_dedupe_location_key '{"title":"no location at all"}')"; RC=$?
assert_eq "no location field -> empty key" "" "$KEY"
assert_true "no location field -> does not crash (rc 0)" "$RC"

KEY="$(_dedupe_location_key '{"primary_location":"","suspect_files":[],"source_finding_paths":[]}')"
assert_eq "empty/blank location fields -> empty key" "" "$KEY"

KEY="$(_dedupe_location_key 'not-valid-json')"; RC=$?
assert_eq "invalid JSON -> empty key" "" "$KEY"
assert_true "invalid JSON -> does not crash (rc 0)" "$RC"

KEY="$(_dedupe_location_key '["array","not","object"]')"; RC=$?
assert_eq "non-object (array) -> empty key" "" "$KEY"
assert_true "non-object -> does not crash (rc 0)" "$RC"

KEY="$(_dedupe_location_key '')"; RC=$?
assert_eq "empty argument -> empty key" "" "$KEY"
assert_true "empty argument -> does not crash (rc 0)" "$RC"

# ===========================================================================
# _dedupe_location_key — normalization + determinism.
# Same file expressed three ways (line, line:col, no line; leading ./;
# duplicate slashes; backslashes) all key the same.
# ===========================================================================
K1="$(_dedupe_location_key '{"primary_location":"src/Auth.go:88"}')"
K2="$(_dedupe_location_key '{"primary_location":"src/Auth.go:88:12"}')"
K3="$(_dedupe_location_key '{"primary_location":"./src//Auth.go"}')"
K4="$(_dedupe_location_key '{"primary_location":"src\\Auth.go"}')"
assert_eq "normalize: line:col dropped -> same key as line-only" "$K1" "$K2"
assert_eq "normalize: leading ./ + duplicate slash stripped -> same key" "$K1" "$K3"
assert_eq "normalize: backslashes -> forward slashes -> same key" "$K1" "$K4"
assert_eq "normalize: canonical form is lowercased, line-free" "src/auth.go" "$K1"

# Determinism: same input -> same output across repeated calls.
KA="$(_dedupe_location_key '{"primary_location":"SRC/Auth.go:5"}')"
KB="$(_dedupe_location_key '{"primary_location":"SRC/Auth.go:5"}')"
assert_eq "determinism: identical input -> identical key" "$KA" "$KB"

# ===========================================================================
# AC: _dedupe_is_match — title-only primary signal, CROSS-DOMAIN.
# Identical content titles (only the [severity] prefix differs) from DIFFERENT
# domains -> Jaccard 1.0 >= primary -> match, with NO location field. Proves
# domain is never gated on.
# ===========================================================================
TITLE_ONLY_A='{
  "domain":"authorization",
  "title":"[high] SQL injection in the user login query"
}'
TITLE_ONLY_B='{
  "domain":"cryptography",
  "title":"[medium] SQL injection in the user login query"
}'
assert_match "title-only: cross-domain identical titles match (no location needed)" \
  "$TITLE_ONLY_A" "$TITLE_ONLY_B"

# ===========================================================================
# AC: location-based match catches a pair that title-only Jaccard would MISS.
# Different wording (last word differs: "name" vs "subject"), same file, two
# DIFFERENT domains. Title Jaccard ~0.666 (6666) — below primary 8500 (so
# title-only misses it) but at/above secondary 6000 once location agrees.
# This is the "Empty-CN mTLS" cross-domain duplicate.
# ===========================================================================
XDOMAIN_A='{
  "domain":"authorization",
  "primary_location":"src/mtls.go:42",
  "title":"[high] mTLS accepts certificates with empty common name"
}'
XDOMAIN_B='{
  "domain":"cryptography",
  "primary_location":"src/mtls.go:42:7",
  "title":"[critical] mTLS accepts certificates with empty common subject"
}'
# Guard: confirm the pair really would NOT match on title alone (so the test
# proves the LOCATION branch, not an accidental high title similarity).
# (save/restore the threshold rather than an env-prefix on the function call,
# which can leak into the shell and corrupt later assertions.)
DEDUPE_TITLE_SIM_SECONDARY=99999
assert_no_match \
  "control: same pair does NOT match on title alone (sim < primary, secondary off)" \
  "$XDOMAIN_A" "$XDOMAIN_B"
DEDUPE_TITLE_SIM_SECONDARY=6000
assert_match "cross-domain + same location + similar (sub-primary) title -> match" \
  "$XDOMAIN_A" "$XDOMAIN_B"

# Negative: SAME similar titles but DIFFERENT locations -> no match (location
# disagrees and title sim is below primary).
XDOMAIN_B_OTHERLOC='{
  "domain":"cryptography",
  "primary_location":"src/other.go:9",
  "title":"[critical] mTLS accepts certificates with empty common subject"
}'
assert_no_match "different location + sub-primary title similarity -> no match" \
  "$XDOMAIN_A" "$XDOMAIN_B_OTHERLOC"

# Negative: one record has a location, the other does not -> keys not both
# non-empty -> location branch cannot fire (title sim still below primary).
XDOMAIN_B_NOLOC='{
  "domain":"cryptography",
  "title":"[critical] mTLS accepts certificates with empty common subject"
}'
assert_no_match "one record location-less -> location branch cannot fire -> no match" \
  "$XDOMAIN_A" "$XDOMAIN_B_NOLOC"

# ===========================================================================
# AC / GUARD: two location-less records with low title similarity do NOT match.
# Both location keys are empty; equal-but-empty keys must NOT count as a
# location match (else every location-less manifest pair would collapse).
# ===========================================================================
EMPTY_LOC_A='{"domain":"authorization","title":"Race condition in session cache eviction"}'
EMPTY_LOC_B='{"domain":"performance","title":"N plus one query on the dashboard endpoint"}'
assert_no_match "two location-less, dissimilar titles -> no match (empty-key guard)" \
  "$EMPTY_LOC_A" "$EMPTY_LOC_B"

# ...but two location-less records with HIGH title similarity STILL match via
# the title-only primary branch (location is not required for a title match).
EMPTY_LOC_HI_A='{"domain":"authorization","title":"Missing rate limit on the password reset endpoint"}'
EMPTY_LOC_HI_B='{"domain":"api","title":"Missing rate limit on the password reset endpoint"}'
assert_match "two location-less, identical titles -> match via title-only branch" \
  "$EMPTY_LOC_HI_A" "$EMPTY_LOC_HI_B"

# ===========================================================================
# Negative: same location but UNRELATED titles (near-zero similarity) -> no
# match. Same file must NOT collapse genuinely different findings; the
# secondary branch still requires title sim >= secondary.
# ===========================================================================
SAMELOC_UNREL_A='{"domain":"authorization","primary_location":"src/app.go:10","title":"Hardcoded admin password in source"}'
SAMELOC_UNREL_B='{"domain":"cryptography","primary_location":"src/app.go:10","title":"Deprecated TLS one point zero handshake"}'
assert_no_match "same location but unrelated titles -> no match (secondary bar not met)" \
  "$SAMELOC_UNREL_A" "$SAMELOC_UNREL_B"

# Location match also works when the shared signal is suspect_files (not
# primary_location): the same sub-primary-title cross-domain pair keyed off
# suspect_files still matches.
SUSPECT_A='{
  "domain":"authorization",
  "suspect_files":["src/mtls.go:42"],
  "title":"[high] mTLS accepts certificates with empty common name"
}'
SUSPECT_B='{
  "domain":"cryptography",
  "suspect_files":["src/mtls.go"],
  "title":"[critical] mTLS accepts certificates with empty common subject"
}'
assert_match "location branch keyed off suspect_files -> cross-domain match" \
  "$SUSPECT_A" "$SUSPECT_B"

# ===========================================================================
# Env-override contract: raising the secondary threshold above the pair's title
# similarity turns the earlier location match OFF (proves the threshold is read
# from the environment, default-overridable for #353 tuning). Save/restore each
# override so it never leaks into later assertions.
# ===========================================================================
DEDUPE_TITLE_SIM_SECONDARY=8000
assert_no_match \
  "env override: secondary raised to 8000 -> location pair no longer matches" \
  "$XDOMAIN_A" "$XDOMAIN_B"
DEDUPE_TITLE_SIM_SECONDARY=6000

# Lowering the primary threshold below the pair's title similarity turns the
# pair into a title-only match even without location agreement.
DEDUPE_TITLE_SIM_PRIMARY=5000
assert_match \
  "env override: primary lowered to 5000 -> sub-default title sim now matches" \
  "$XDOMAIN_A" "$XDOMAIN_B_OTHERLOC"
DEDUPE_TITLE_SIM_PRIMARY=8500

# ===========================================================================
# Robustness: malformed records do not crash the predicate.
# ===========================================================================
TOTAL=$((TOTAL + 1))
_dedupe_is_match 'not-json' '{"title":"x"}' >/dev/null 2>&1
RC=$?
if [[ "$RC" -eq 0 || "$RC" -eq 1 ]]; then
  pass_with "malformed record -> predicate returns cleanly (no crash)"
else
  fail_with "malformed record -> predicate returns cleanly (no crash)" "got rc $RC"
fi

finish
