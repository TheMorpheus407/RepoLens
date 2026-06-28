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

# Integration test for issue #356: the cross-domain "Empty-CN mTLS" dedupe case.
#
# Real user pain this guards: the "Empty-CN mTLS" finding surfaced under BOTH the
# Authorization and Cryptography lenses as two equal TODOs. The dedupe passes must
# collapse that to ONE canonical finding (with an also_reported_by[] sub-list) and
# ONE duplicate-marked record, while leaving an unrelated control finding alone.
#
# Unlike the per-pass unit tests (tests/test_synthesize_also_reported_by.sh and
# tests/test_synthesize_mark_duplicates.sh, which each exercise ONE pass in
# isolation), this test runs BOTH passes together on a SINGLE shared, story-
# accurate manifest in the same order as run_synthesizer
# (_synthesize_attach_also_reported_by then _synthesize_mark_duplicates), proving
# they compose into the user-visible end state. Pure jq/bash, NO AI model.
#
# Design traps that shape this fixture (get these wrong and it groups for the
# wrong reason, or trips validate_manifest unrelated to the assertion):
#   - The A/B pair groups via the LOCATION branch of _dedupe_is_match: same
#     normalized primary_location + title Jaccard in the [0.60, 0.85) secondary
#     band. The measured Jaccard of the A/B titles is 6363/10000 — comfortably
#     above the 6000 secondary floor and below the 8500 bar, so it both groups
#     AND keeps the augmented manifest under validate_manifest's near-duplicate-
#     title gate (> 8500 is rejected). If you re-word a title, keep that band.
#   - Same location is delivered via primary_location (highest-precedence source
#     in _dedupe_location_key), NOT source_finding_paths — the per-lens markdown
#     paths differ by design and would yield DIFFERENT location keys.
#   - Thresholds are pinned (DEDUPE_TITLE_SIM_PRIMARY/_SECONDARY) so the location
#     branch is stable against future default tuning (#353), and CROSS_LINK_MODE
#     is off so validate_manifest's empty-cross_link_actions[] gate passes for
#     the right reason.
#   - A is critical, B is high, so _dedupe_pick_canonical deterministically picks
#     A (the authz framing) as canonical regardless of array order.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_LIB="$SCRIPT_DIR/lib/core.sh"
SYNTH_LIB="$SCRIPT_DIR/lib/synthesize.sh"

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

# assert_eq <desc> <expected> <actual> — exact string equality.
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected '$expected', got '$actual'"
  fi
}

# assert_rc <desc> <expected_rc> <actual_rc>
assert_rc() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" -eq "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected rc $expected, got $actual"
  fi
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

# --- Source libraries. core first; synthesize defines both passes under test and
# the title-similarity primitives. dedupe.sh is lazy-loaded BY the passes, so we
# deliberately do NOT pre-source it — this exercises the lazy-source wiring. -----
# shellcheck source=/dev/null
source "$CORE_LIB"
# shellcheck source=/dev/null
source "$SYNTH_LIB"

TOTAL=$((TOTAL + 1))
if declare -F _synthesize_attach_also_reported_by >/dev/null 2>&1 \
  && declare -F _synthesize_mark_duplicates >/dev/null 2>&1; then
  pass_with "both dedupe passes are defined after sourcing synthesize.sh"
else
  fail_with "both dedupe passes are defined after sourcing synthesize.sh" \
    "_synthesize_attach_also_reported_by / _synthesize_mark_duplicates not found"
  finish
fi

# Pin thresholds (also asserts the dedupe helpers are reachable via lazy source)
# and the cross-link gate so validate_manifest passes for the right reason.
export DEDUPE_TITLE_SIM_PRIMARY=8500
export DEDUPE_TITLE_SIM_SECONDARY=6000
export CROSS_LINK_MODE=off

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# A complete, schema-valid manifest record. Helper keeps fixtures terse while
# satisfying every validate_manifest required field.
make_record() {
  # $1 cluster_id  $2 domain  $3 lens  $4 severity  $5 title
  # $6 primary_location  $7 source_finding_paths (JSON array literal)
  local cid="$1" domain="$2" lens="$3" sev="$4" title="$5" loc="$6" paths="$7"
  jq -nc \
    --arg cid "$cid" --arg domain "$domain" --arg lens "$lens" \
    --arg sev "$sev" --arg title "$title" --arg loc "$loc" \
    --argjson paths "$paths" '
    {
      title: $title, body: ("body for " + $cid), cluster_id: $cid,
      root_cause_category: "rc", domain: $domain, lens: $lens,
      severity: $sev, granularity: "independent",
      source_finding_paths: $paths, primary_location: $loc,
      dedup_against_existing: [], proposed_labels: [], cross_link_actions: []
    }'
}

# ===========================================================================
# The mTLS fixture (verified end-to-end against the real libs, model-free):
#   A (idx 0, a1): authorization / authz-mtls, CRITICAL — the canonical framing.
#   B (idx 1, b1): cryptography  / crypto-tls, HIGH     — the cross-domain twin.
#   C (idx 2, c1): performance   / db-pool,    MEDIUM   — unrelated control.
#
# A and B share primary_location src/server/mtls.go (line numbers differ but
# normalize equal) and their titles score Jaccard 6363/10000 — in the secondary
# band — so they group via the location branch. C shares neither title nor
# location with anything, so it stays a singleton.
# ===========================================================================
A="$(make_record a1 authorization authz-mtls critical \
  "empty cn in mtls client cert bypasses authentication and authorization checks" \
  "src/server/mtls.go:88" '["logs/r/lens-outputs/authorization/authz-mtls.md"]')"
B="$(make_record b1 cryptography crypto-tls high \
  "empty cn in mtls client cert bypasses authentication and certificate validation" \
  "src/server/mtls.go:90" '["logs/r/lens-outputs/cryptography/crypto-tls.md"]')"
C="$(make_record c1 performance db-pool medium \
  "database connection pool exhausted under sustained load" \
  "src/db/pool.go:12" '["logs/r/lens-outputs/performance/db-pool.md"]')"

MANIFEST="$WORKDIR/manifest.json"
jq -nc --argjson a "$A" --argjson b "$B" --argjson c "$C" '[$a,$b,$c]' > "$MANIFEST"

# Run BOTH passes in production order (run_synthesizer: attach_also_reported_by
# at synthesize.sh:1214, then mark_duplicates at :1227).
_synthesize_attach_also_reported_by "$MANIFEST"; RC_ARB=$?
assert_rc "_synthesize_attach_also_reported_by returns 0 on the mTLS fixture" 0 "$RC_ARB"
_synthesize_mark_duplicates "$MANIFEST"; RC_MDUP=$?
assert_rc "_synthesize_mark_duplicates returns 0 on the mTLS fixture" 0 "$RC_MDUP"

# --- AC: exactly one canonical and one duplicate for the cross-domain A/B pair. -
# The canonical (A) is status-UNSET; the duplicate (B) carries status=duplicate;
# the control (C) is untouched. The whole status map is the cleanest expression.
STATUS_MAP="$(jq -c '[.[] | has("status")]' "$MANIFEST")"
assert_eq "exactly one record (the duplicate) carries a status; canonical+control do not" \
  '[false,true,false]' "$STATUS_MAP"
DUP_COUNT="$(jq -c '[.[] | select(.status == "duplicate")] | length' "$MANIFEST")"
assert_eq "exactly one record has status=duplicate" "1" "$DUP_COUNT"

# --- AC: the duplicate (B) links to the canonical (A) cluster_id. --------------
B_STATUS="$(jq -r '.[1].status // "<unset>"' "$MANIFEST")"
B_DOF="$(jq -r '.[1].duplicate_of // "<unset>"' "$MANIFEST")"
A_ID="$(jq -r '.[0].cluster_id' "$MANIFEST")"
assert_eq "the cryptography record is marked status=duplicate" "duplicate" "$B_STATUS"
assert_eq "the duplicate's duplicate_of points at the authorization canonical id (a1)" \
  "a1" "$B_DOF"
assert_eq "duplicate_of matches the canonical record's actual cluster_id" "$A_ID" "$B_DOF"

# --- AC: duplicate_of equals the id chosen by _dedupe_pick_canonical. -----------
# The passes lazy-source dedupe.sh inside a command-substitution subshell, so the
# helpers are not visible here; source it explicitly for this direct-call check
# (the passes' own lazy-source wiring was already exercised by the calls above).
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/dedupe.sh"
AB_SUBARR="$(jq -c '[ (.[0] + {__rl_idx:0}), (.[1] + {__rl_idx:1}) ]' "$MANIFEST")"
CANON_IDX="$(_dedupe_pick_canonical "$AB_SUBARR" __rl_idx)"
CANON_ID="$(jq -r --argjson k "$CANON_IDX" '.[$k].cluster_id' "$MANIFEST")"
assert_eq "_dedupe_pick_canonical selects the critical authorization record (a1)" \
  "a1" "$CANON_ID"
assert_eq "duplicate_of equals the _dedupe_pick_canonical-selected canonical id" \
  "$CANON_ID" "$B_DOF"

# --- AC: the canonical record is left status-UNSET and gains no duplicate_of. ---
assert_eq "canonical record has no status (absence is the canonical distinguisher)" \
  "false" "$(jq -c '.[0] | has("status")' "$MANIFEST")"
assert_eq "canonical record has no duplicate_of" \
  "false" "$(jq -c '.[0] | has("duplicate_of")' "$MANIFEST")"

# --- AC: also_reported_by[] on the canonical names the OTHER lens/domain/path. --
# One entry for the single non-canonical contributor (the cryptography lens), with
# markdown_path = that contributor's first source_finding_paths[].
ARB="$(jq -c '.[0].also_reported_by' "$MANIFEST")"
EXPECTED_ARB='[{"lens":"crypto-tls","domain":"cryptography","markdown_path":"logs/r/lens-outputs/cryptography/crypto-tls.md"}]'
assert_eq "canonical also_reported_by names the cryptography lens/domain/markdown_path" \
  "$EXPECTED_ARB" "$ARB"
assert_eq "also_reported_by has exactly one contributor entry" \
  "1" "$(jq -c '.[0].also_reported_by | length' "$MANIFEST")"

# --- AC: the duplicate does NOT get also_reported_by (only the canonical does). -
assert_eq "the duplicate record has no also_reported_by" \
  "false" "$(jq -c '.[1] | has("also_reported_by")' "$MANIFEST")"

# --- AC: the unique control record C is completely untouched. -------------------
assert_eq "control record has no status" \
  "false" "$(jq -c '.[2] | has("status")' "$MANIFEST")"
assert_eq "control record has no duplicate_of" \
  "false" "$(jq -c '.[2] | has("duplicate_of")' "$MANIFEST")"
assert_eq "control record has no also_reported_by (it merged with nothing)" \
  "false" "$(jq -c '.[2] | has("also_reported_by")' "$MANIFEST")"

# --- Sanity: the augmented manifest still validates (proves the fixture sat below
# the near-duplicate-title gate for the right reason). --------------------------
validate_manifest "$MANIFEST" 2>/dev/null; RC=$?
assert_rc "validate_manifest passes on the deduped mTLS manifest" 0 "$RC"

# --- Integration is idempotent: re-running BOTH passes is byte-identical. -------
BEFORE="$(jq -S . "$MANIFEST")"
_synthesize_attach_also_reported_by "$MANIFEST"; RC1=$?
_synthesize_mark_duplicates "$MANIFEST"; RC2=$?
assert_rc "re-run of attach_also_reported_by returns 0" 0 "$RC1"
assert_rc "re-run of mark_duplicates returns 0" 0 "$RC2"
AFTER="$(jq -S . "$MANIFEST")"
TOTAL=$((TOTAL + 1))
if [[ "$BEFORE" == "$AFTER" ]]; then
  pass_with "running both passes a second time is byte-identical (idempotent)"
else
  fail_with "running both passes a second time is byte-identical (idempotent)" \
    "manifest changed on the second run"
fi

finish
