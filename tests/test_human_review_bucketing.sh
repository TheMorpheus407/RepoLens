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

# Tests for issue #333: Human Mode bucketing helper (5 noise-budget buckets).
# Pure-function tests only; NO AI models are invoked — every input is a
# handwritten JSON-Lines fixture and the helper is a model-free jq classifier.
#
# Contract under test (from the issue acceptance criteria + the owner's
# research comment, which is the authoritative spec for the open design calls):
#
#   human_review_bucketize <findings_jsonl_path>
#     Reads the finding registry (JSON Lines, schema in
#     docs/finding-registry-schema.md) and prints to stdout a SINGLE deterministic
#     JSON object that partitions EVERY finding into 5 priority-ordered buckets,
#     first-match-wins, no double-counting. It WRITES NOTHING and never invokes a
#     model. On an empty / missing / unreadable registry it prints all-empty
#     buckets and returns 0 (a DELIBERATE divergence from lib/artifacts.sh, which
#     returns 2 on missing input — see issue research §6 / D6).
#
#   BUCKET KEYS + SHAPE (the contract surface this test pins; research §5 D1):
#     {
#       "top_critical_high":              { "cap": 10,   "count": N, "items": [...] },
#       "top_medium_security":            { "cap": 25,   "count": N, "items": [...] },
#       "test_quality":                   { "cap": null, "count": N, "items": [...] },
#       "not_actionable_without_scanner": { "cap": null, "count": N, "items": [...] },
#       "remainder":                      { "cap": null, "count": N, "items": [...] }
#     }
#   - `cap` records the visible-slice size (renderer slices items[:cap]); `count`
#     and the full `items` list are NEVER truncated to the cap, so the held-back
#     accounting issue can recover the surplus (AC: "surplus ... NOT silently
#     dropped"). `items` may carry full records OR stable ids (AC: "records or
#     their stable ids") — membership/ordering assertions read each item's id via
#     `if type=="object" then .id else .` so they hold for either representation.
#
#   PRIORITY ORDER, first match wins (research §1):
#     1 top_critical_high              — any type; severity in {critical, high}.    cap 10, ranked.
#     2 top_medium_security            — severity==medium AND security-ish domain/type. cap 25, ranked.
#     3 test_quality                   — type in {test-gap, maintainability}.
#     4 not_actionable_without_scanner — type==external-dependency OR
#                                        (status==needs-validation AND a scanner-required marker).
#     5 remainder                      — everything else.
#
#   Design notes that shape these tests:
#   - We assert PUBLIC behavior: the JSON object's bucket membership, counts, caps
#     and ordering — never the internal jq filter / helper names.
#   - The security-ish domain set is data-driven from config/domains.json (research
#     §5 D3): `security` is a security domain, `code-quality` is not. We pick those
#     two so the assertion holds for any reasonable /security/i derivation (and for
#     the documented {security, llm-security} hardcoded fallback).
#   - Bucket-2 security TYPE must match BOTH the short form (`security`) and the
#     long form (`security-vulnerability`) that lib/core.sh::finding_type_normalize
#     emits (research §3 — the short/long-form trap).
#   - The scanner marker is the load-bearing phrase "needs external scanner" inside
#     validation.suggested_validation (prompts/_base/audit.md; mirrored from
#     lib/artifacts.sh P4) — single source of truth, matched case-insensitively.
#   - Ordering of buckets 1 & 2 must be deterministic; the AC sanctions the shared
#     risk ranking OR the documented fallback ([-severity_rank, -confidence(null->0.5),
#     id]). Both readings agree on the assertions below (all-critical-before-all-high
#     in bucket 1; higher-confidence-first within medium in bucket 2).

set -uo pipefail
# shellcheck disable=SC2329  # helper functions are invoked indirectly

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_LIB="$SCRIPT_DIR/lib/core.sh"
RISK_LIB="$SCRIPT_DIR/lib/risk.sh"
HUMAN_REVIEW_LIB="$SCRIPT_DIR/lib/human_review.sh"

PASS=0
FAIL=0
TOTAL=0

TMP_PARENT="$SCRIPT_DIR/logs/test-human-review-bucketing"
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
  local desc="$1" detail="${2:-}"
  FAIL=$((FAIL + 1))
  echo "  FAIL: $desc"
  if [[ -n "$detail" ]]; then
    printf '    %s\n' "$detail"
  fi
}

assert_rc_zero() {
  local desc="$1" rc="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$rc" -eq 0 ]]; then pass_with "$desc"; else fail_with "$desc" "Expected rc 0, got $rc"; fi
}

# assert_no_crash — stderr shows no bash-level explosion (set -u / syntax /
#   command-not-found). Intentional warnings are fine.
assert_no_crash() {
  local desc="$1" errfile="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$errfile" ]] && grep -qiE 'unbound variable|syntax error|command not found' "$errfile"; then
    fail_with "$desc" "stderr indicates a crash: $(head -1 "$errfile")"
  else
    pass_with "$desc"
  fi
}

# assert_valid_json — the captured stdout parses as a single JSON value.
assert_valid_json() {
  local desc="$1" file="$2"
  TOTAL=$((TOTAL + 1))
  if jq -e . "$file" >/dev/null 2>&1; then
    pass_with "$desc"
  else
    fail_with "$desc" "not valid JSON: $(head -c 200 "$file")"
  fi
}

# assert_jq_eq <desc> <file> <filter> <expected> — jq -r filter equals expected.
assert_jq_eq() {
  local desc="$1" file="$2" filter="$3" expected="$4" got
  TOTAL=$((TOTAL + 1))
  got="$(jq -r "$filter" "$file" 2>/dev/null)"
  if [[ "$got" == "$expected" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "filter [$filter] expected [$expected] got [$got]"
  fi
}

# assert_jq_true <desc> <file> <filter> — jq -r filter evaluates to boolean true.
assert_jq_true() {
  local desc="$1" file="$2" filter="$3" got
  TOTAL=$((TOTAL + 1))
  got="$(jq -r "$filter" "$file" 2>/dev/null)"
  if [[ "$got" == "true" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "filter [$filter] expected true got [$got]"
  fi
}

# assert_member / assert_not_member — <id> is / is not in <bucket>.items, reading
#   each item's id tolerantly (full record OR bare id string).
assert_member() {
  local desc="$1" bucket="$2" id="$3" got
  TOTAL=$((TOTAL + 1))
  got="$(jq -r --arg b "$bucket" --arg id "$id" \
    '([ .[$b].items[] | (if type=="object" then .id else . end) ] | index($id)) != null' \
    "$BKT_OUT" 2>/dev/null)"
  if [[ "$got" == "true" ]]; then pass_with "$desc"; else fail_with "$desc" "expected id '$id' in bucket '$bucket' (got $got)"; fi
}
assert_not_member() {
  local desc="$1" bucket="$2" id="$3" got
  TOTAL=$((TOTAL + 1))
  got="$(jq -r --arg b "$bucket" --arg id "$id" \
    '([ .[$b].items[] | (if type=="object" then .id else . end) ] | index($id)) == null' \
    "$BKT_OUT" 2>/dev/null)"
  if [[ "$got" == "true" ]]; then pass_with "$desc"; else fail_with "$desc" "expected id '$id' NOT in bucket '$bucket' (got $got)"; fi
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

# run_bucketize <jsonl-content> — write the fixture, invoke the helper, capture
#   BKT_IN / BKT_OUT (stdout) / BKT_ERR (stderr) and BKT_RC (return code).
RUN_N=0
run_bucketize() {
  local content="$1"
  RUN_N=$((RUN_N + 1))
  BKT_IN="$TMPDIR/findings-$RUN_N.jsonl"
  BKT_OUT="$TMPDIR/out-$RUN_N.json"
  BKT_ERR="$TMPDIR/err-$RUN_N.txt"
  printf '%s' "$content" >"$BKT_IN"
  human_review_bucketize "$BKT_IN" >"$BKT_OUT" 2>"$BKT_ERR"
  BKT_RC=$?
}

# run_bucketize_missing — invoke against a path that does not exist.
run_bucketize_missing() {
  RUN_N=$((RUN_N + 1))
  BKT_OUT="$TMPDIR/out-$RUN_N.json"
  BKT_ERR="$TMPDIR/err-$RUN_N.txt"
  human_review_bucketize "$TMPDIR/does-not-exist-$RUN_N.jsonl" >"$BKT_OUT" 2>"$BKT_ERR"
  BKT_RC=$?
}

# --- Source the library (core.sh + risk.sh first; the helper MAY reuse the
# shared severity/risk helpers, and sourcing them is harmless if it does not).
# Assert on the FUNCTION, not the file. -----------------------------------------
# shellcheck source=/dev/null
[[ -f "$CORE_LIB" ]] && source "$CORE_LIB"
# shellcheck source=/dev/null
[[ -f "$RISK_LIB" ]] && source "$RISK_LIB"
if [[ -f "$HUMAN_REVIEW_LIB" ]]; then
  # shellcheck source=/dev/null
  source "$HUMAN_REVIEW_LIB"
fi

TOTAL=$((TOTAL + 1))
if declare -F human_review_bucketize >/dev/null 2>&1; then
  pass_with "human_review_bucketize is defined after sourcing lib/human_review.sh"
else
  fail_with "human_review_bucketize is defined after sourcing lib/human_review.sh" \
    "not found — lib/human_review.sh must define it"
  finish
fi

# ===========================================================================
# AC (headline): partitions every finding into the 5 buckets with correct
# membership and NO finding in two buckets. One fixture covers every bucket plus
# deliberate "could match two" records that prove the first-match-wins priority.
#
#   c-crit            critical, type null              -> top_critical_high
#   c-crit-needsval   critical + needs-validation +    -> top_critical_high
#                       scanner marker (B1 beats B4)
#   h-sec             high + security domain           -> top_critical_high (NOT B2)
#   m-domsec          medium + security domain         -> top_medium_security
#   m-typesec-short   medium + type "security"         -> top_medium_security
#   m-typesec-long    medium + type "security-vulnerability" -> top_medium_security
#   m-nonsec          medium + code-quality/reliability -> remainder (NOT B2)
#   tq-testgap        type test-gap                    -> test_quality
#   tq-maint          medium + type maintainability    -> test_quality (NOT remainder)
#   ext-dep           type external-dependency         -> not_actionable_without_scanner
#   needsval-scanner  needs-validation + scanner marker -> not_actionable_without_scanner
#   needsval-noscan   needs-validation, NO marker      -> remainder (NOT B4)
#   rem-low           plain low finding                -> remainder
# (13 records; null type / null confidence / empty primary_location / {} validation
#  also exercise defensive-field handling.)
# ===========================================================================
read -r -d '' FIX_MEMBERSHIP <<'EOF' || true
{"id":"c-crit","title":"Crit any type","severity":"critical","type":null,"domain":"code-quality","lens":"l","status":"new","primary_location":"","confidence":null,"duplicate_group":null,"markdown_path":"001.md","validation":{}}
{"id":"c-crit-needsval","title":"Crit needs validation","severity":"critical","type":null,"domain":"code-quality","lens":"l","status":"needs-validation","primary_location":"a.sh:1","confidence":null,"duplicate_group":null,"markdown_path":"002.md","validation":{"suggested_validation":"this needs external scanner to confirm"}}
{"id":"h-sec","title":"High security","severity":"high","type":null,"domain":"security","lens":"l","status":"new","primary_location":"b.sh:1","confidence":null,"duplicate_group":null,"markdown_path":"003.md","validation":{}}
{"id":"m-domsec","title":"Medium security domain","severity":"medium","type":null,"domain":"security","lens":"l","status":"new","primary_location":"c.sh:1","confidence":null,"duplicate_group":null,"markdown_path":"004.md","validation":{}}
{"id":"m-typesec-short","title":"Medium security type short","severity":"medium","type":"security","domain":"code-quality","lens":"l","status":"new","primary_location":"d.sh:1","confidence":null,"duplicate_group":null,"markdown_path":"005.md","validation":{}}
{"id":"m-typesec-long","title":"Medium security type long","severity":"medium","type":"security-vulnerability","domain":"code-quality","lens":"l","status":"new","primary_location":"e.sh:1","confidence":null,"duplicate_group":null,"markdown_path":"006.md","validation":{}}
{"id":"m-nonsec","title":"Medium reliability","severity":"medium","type":"reliability","domain":"code-quality","lens":"l","status":"new","primary_location":"f.sh:1","confidence":null,"duplicate_group":null,"markdown_path":"007.md","validation":{}}
{"id":"tq-testgap","title":"Test gap","severity":"low","type":"test-gap","domain":"code-quality","lens":"l","status":"new","primary_location":"g.sh:1","confidence":null,"duplicate_group":null,"markdown_path":"008.md","validation":{}}
{"id":"tq-maint","title":"Maintainability","severity":"medium","type":"maintainability","domain":"code-quality","lens":"l","status":"new","primary_location":"h.sh:1","confidence":null,"duplicate_group":null,"markdown_path":"009.md","validation":{}}
{"id":"ext-dep","title":"External dependency","severity":"low","type":"external-dependency","domain":"code-quality","lens":"l","status":"new","primary_location":"i.sh:1","confidence":null,"duplicate_group":null,"markdown_path":"010.md","validation":{}}
{"id":"needsval-scanner","title":"Needs scanner","severity":"low","type":null,"domain":"code-quality","lens":"l","status":"needs-validation","primary_location":"j.sh:1","confidence":null,"duplicate_group":null,"markdown_path":"011.md","validation":{"suggested_validation":"requires a needs external scanner pass"}}
{"id":"needsval-noscan","title":"Needs validation no marker","severity":"low","type":null,"domain":"code-quality","lens":"l","status":"needs-validation","primary_location":"k.sh:1","confidence":null,"duplicate_group":null,"markdown_path":"012.md","validation":{}}
{"id":"rem-low","title":"Plain low","severity":"low","type":null,"domain":"code-quality","lens":"l","status":"new","primary_location":"m.sh:1","confidence":null,"duplicate_group":null,"markdown_path":"013.md","validation":{}}
EOF
run_bucketize "$FIX_MEMBERSHIP"
assert_rc_zero    "membership fixture -> rc 0" "$BKT_RC"
assert_no_crash   "membership fixture does not crash" "$BKT_ERR"
assert_valid_json "stdout is a single valid JSON object" "$BKT_OUT"

# Structure + caps contract (the bucket key names + cap metadata are the contract).
assert_jq_true "output has all 5 named buckets" "$BKT_OUT" \
  '(has("top_critical_high") and has("top_medium_security") and has("test_quality") and has("not_actionable_without_scanner") and has("remainder"))'
assert_jq_eq "top_critical_high.cap == 10"   "$BKT_OUT" '.top_critical_high.cap'   "10"
assert_jq_eq "top_medium_security.cap == 25" "$BKT_OUT" '.top_medium_security.cap' "25"
assert_jq_eq "test_quality.cap is null (uncapped)"                   "$BKT_OUT" '.test_quality.cap'                   "null"
assert_jq_eq "not_actionable_without_scanner.cap is null (uncapped)" "$BKT_OUT" '.not_actionable_without_scanner.cap' "null"
assert_jq_eq "remainder.cap is null (uncapped)"                      "$BKT_OUT" '.remainder.cap'                      "null"

# Bucket 1 — severity-only, beats every later bucket.
assert_member     "critical (any type) -> top_critical_high"                 top_critical_high c-crit
assert_member     "critical+needs-validation+marker -> top_critical_high"    top_critical_high c-crit-needsval
assert_not_member "...and NOT in scanner bucket (B1 priority beats B4)"      not_actionable_without_scanner c-crit-needsval
assert_member     "high+security -> top_critical_high"                       top_critical_high h-sec
assert_not_member "...and NOT in top_medium_security (severity precedence)"  top_medium_security h-sec

# Bucket 2 — medium + security-ish (domain OR short/long type form).
assert_member     "medium + security DOMAIN -> top_medium_security"          top_medium_security m-domsec
assert_member     "medium + type 'security' (short) -> top_medium_security"  top_medium_security m-typesec-short
assert_member     "medium + type 'security-vulnerability' (long) -> top_medium_security" top_medium_security m-typesec-long
assert_member     "medium non-security -> remainder"                         remainder m-nonsec
assert_not_member "...and NOT in top_medium_security"                        top_medium_security m-nonsec

# Bucket 3 — test/quality in its OWN section, excluded from the remainder.
assert_member     "type test-gap -> test_quality"                            test_quality tq-testgap
assert_member     "medium type maintainability -> test_quality"              test_quality tq-maint
assert_not_member "...and NOT in remainder"                                  remainder tq-maint

# Bucket 4 — scanner-required, in its OWN section.
assert_member     "type external-dependency -> not_actionable_without_scanner" not_actionable_without_scanner ext-dep
assert_member     "needs-validation + scanner marker -> not_actionable_without_scanner" not_actionable_without_scanner needsval-scanner
assert_member     "needs-validation WITHOUT marker -> remainder"             remainder needsval-noscan
assert_not_member "...and NOT in scanner bucket (marker is load-bearing)"    not_actionable_without_scanner needsval-noscan

# Bucket 5 — remainder catches the plain finding.
assert_member     "plain low finding -> remainder"                           remainder rem-low

# No double-counting + total partition: 13 placements, 13 distinct ids, all present.
assert_jq_eq "sum of bucket counts == total input lines (13)" "$BKT_OUT" \
  '[.top_critical_high,.top_medium_security,.test_quality,.not_actionable_without_scanner,.remainder] | map(.count) | add' "13"
assert_jq_eq "every input id is placed exactly once (13 items across buckets, with dups)" "$BKT_OUT" \
  '[ (.top_critical_high,.top_medium_security,.test_quality,.not_actionable_without_scanner,.remainder).items[] | (if type=="object" then .id else . end) ] | length' "13"
assert_jq_eq "no finding appears in two buckets (13 DISTINCT ids)" "$BKT_OUT" \
  '[ (.top_critical_high,.top_medium_security,.test_quality,.not_actionable_without_scanner,.remainder).items[] | (if type=="object" then .id else . end) ] | unique | length' "13"

# ===========================================================================
# AC: caps applied (10 / 25) but the FULL ordered list/count survive — surplus
# beyond the cap is NOT silently dropped (the held-back accounting issue consumes
# the full lists). 15 critical/high + 30 medium-security records.
# ===========================================================================
CAPS_FIX="$TMPDIR/caps.jsonl"
: >"$CAPS_FIX"
for i in $(seq 1 15); do
  sev="critical"; (( i % 2 == 0 )) && sev="high"
  printf '{"id":"big-ch-%02d","title":"ch %d","severity":"%s","type":null,"domain":"code-quality","lens":"l","status":"new","primary_location":"ch%d.sh:1","confidence":null,"duplicate_group":null,"markdown_path":"%02d.md","validation":{}}\n' \
    "$i" "$i" "$sev" "$i" "$i" >>"$CAPS_FIX"
done
for i in $(seq 1 30); do
  printf '{"id":"big-ms-%02d","title":"ms %d","severity":"medium","type":null,"domain":"security","lens":"l","status":"new","primary_location":"ms%d.sh:1","confidence":null,"duplicate_group":null,"markdown_path":"%02d.md","validation":{}}\n' \
    "$i" "$i" "$i" "$i" >>"$CAPS_FIX"
done
CAPS_OUT="$TMPDIR/caps-out.json"
CAPS_ERR="$TMPDIR/caps-err.txt"
human_review_bucketize "$CAPS_FIX" >"$CAPS_OUT" 2>"$CAPS_ERR"; CAPS_RC=$?
assert_rc_zero    "caps fixture -> rc 0" "$CAPS_RC"
assert_no_crash   "caps fixture does not crash" "$CAPS_ERR"
assert_jq_eq "bucket 1 cap stays 10"                       "$CAPS_OUT" '.top_critical_high.cap'            "10"
assert_jq_eq "bucket 1 count is the FULL 15 (not truncated to cap)" "$CAPS_OUT" '.top_critical_high.count' "15"
assert_jq_eq "bucket 1 items list is the FULL 15 (surplus retained)" "$CAPS_OUT" '.top_critical_high.items | length' "15"
assert_jq_eq "bucket 2 cap stays 25"                       "$CAPS_OUT" '.top_medium_security.cap'          "25"
assert_jq_eq "bucket 2 count is the FULL 30 (not truncated to cap)" "$CAPS_OUT" '.top_medium_security.count' "30"
assert_jq_eq "bucket 2 items list is the FULL 30 (surplus retained)" "$CAPS_OUT" '.top_medium_security.items | length' "30"

# ===========================================================================
# AC: ordering of buckets 1 & 2 is deterministic and uses the shared risk ranking
# (or the documented fallback). Input is scrambled. Bucket 1: every critical must
# precede every high (severity rank). Bucket 2 (all medium): higher confidence
# first. Both readings of the AC agree on these. Then assert byte-identical output
# across two runs (stable tiebreak — no run-to-run churn).
# ===========================================================================
read -r -d '' FIX_ORDER <<'EOF' || true
{"id":"o-high-1","title":"oh1","severity":"high","type":null,"domain":"code-quality","lens":"l","status":"new","primary_location":"oh1.sh:1","confidence":null,"duplicate_group":null,"markdown_path":"101.md","validation":{}}
{"id":"o-crit-1","title":"oc1","severity":"critical","type":null,"domain":"code-quality","lens":"l","status":"new","primary_location":"oc1.sh:1","confidence":null,"duplicate_group":null,"markdown_path":"102.md","validation":{}}
{"id":"o-high-2","title":"oh2","severity":"high","type":null,"domain":"code-quality","lens":"l","status":"new","primary_location":"oh2.sh:1","confidence":null,"duplicate_group":null,"markdown_path":"103.md","validation":{}}
{"id":"o-crit-2","title":"oc2","severity":"critical","type":null,"domain":"code-quality","lens":"l","status":"new","primary_location":"oc2.sh:1","confidence":null,"duplicate_group":null,"markdown_path":"104.md","validation":{}}
{"id":"o-mc-lo","title":"omclo","severity":"medium","type":null,"domain":"security","lens":"l","status":"new","primary_location":"omclo.sh:1","confidence":0.2,"duplicate_group":null,"markdown_path":"105.md","validation":{}}
{"id":"o-mc-hi","title":"omchi","severity":"medium","type":null,"domain":"security","lens":"l","status":"new","primary_location":"omchi.sh:1","confidence":0.9,"duplicate_group":null,"markdown_path":"106.md","validation":{}}
EOF
run_bucketize "$FIX_ORDER"
assert_rc_zero "ordering fixture -> rc 0" "$BKT_RC"
assert_jq_true "bucket 1: every critical precedes every high (severity rank desc)" "$BKT_OUT" \
  '[.top_critical_high.items[] | (if type=="object" then .id else . end)] as $ids
   | ([range(0;($ids|length)) | select($ids[.]|test("crit"))] | max) as $lc
   | ([range(0;($ids|length)) | select($ids[.]|test("high"))] | min) as $fh
   | ($lc != null and $fh != null and $lc < $fh)'
assert_jq_true "bucket 2: higher-confidence medium precedes lower-confidence medium" "$BKT_OUT" \
  '[.top_medium_security.items[] | (if type=="object" then .id else . end)] as $ids
   | (($ids|index("o-mc-hi")) != null and ($ids|index("o-mc-lo")) != null
      and ($ids|index("o-mc-hi")) < ($ids|index("o-mc-lo")))'
DET_A="$TMPDIR/det-a.json"
DET_B="$TMPDIR/det-b.json"
human_review_bucketize "$BKT_IN" >"$DET_A" 2>/dev/null
human_review_bucketize "$BKT_IN" >"$DET_B" 2>/dev/null
TOTAL=$((TOTAL + 1))
if cmp -s "$DET_A" "$DET_B"; then
  pass_with "deterministic: two runs on the same input are byte-identical"
else
  fail_with "deterministic: two runs on the same input are byte-identical" "outputs differ"
fi

# ===========================================================================
# AC: empty / missing / unreadable registry -> all-empty buckets, exit 0 (NOT the
# rc 2 of lib/artifacts.sh — a deliberate divergence; the helper is a total
# function). Three sub-cases: empty file, missing path, all-blank-lines file.
# ===========================================================================
# (a) empty (0-byte) file — full structural check.
run_bucketize ""
assert_rc_zero    "empty input file -> rc 0 (not an error)" "$BKT_RC"
assert_no_crash   "empty input file does not crash" "$BKT_ERR"
assert_valid_json "empty input still prints a valid JSON object" "$BKT_OUT"
assert_jq_true "empty input: all 5 buckets present, every count 0 and items []" "$BKT_OUT" \
  '([.top_critical_high,.top_medium_security,.test_quality,.not_actionable_without_scanner,.remainder]
    | all(.count == 0 and (.items|length) == 0))'

# (b) missing path — same total-function contract, rc 0.
run_bucketize_missing
assert_rc_zero    "missing input path -> rc 0 (deliberate divergence from artifacts.sh rc 2)" "$BKT_RC"
assert_no_crash   "missing input path does not crash" "$BKT_ERR"
assert_valid_json "missing input still prints a valid JSON object" "$BKT_OUT"
assert_jq_eq "missing input: total finding count is 0" "$BKT_OUT" \
  '[.top_critical_high,.top_medium_security,.test_quality,.not_actionable_without_scanner,.remainder] | map(.count) | add' "0"

# (c) all-blank-lines file — no records, same empty-bucket contract, rc 0.
run_bucketize $'\n\n  \n'
assert_rc_zero "all-blank-lines input -> rc 0" "$BKT_RC"
assert_no_crash "all-blank-lines input does not crash" "$BKT_ERR"
assert_jq_eq "all-blank-lines: total finding count is 0" "$BKT_OUT" \
  '[.top_critical_high,.top_medium_security,.test_quality,.not_actionable_without_scanner,.remainder] | map(.count) | add' "0"

# ===========================================================================
# AC / house rule: jq owns all escaping. A title with backticks, $(...) and a
# pipe must round-trip as DATA — never shell-evaluated — and the record must still
# bucketize correctly (the test_artifact_todo.sh injection fixture is the model).
# ===========================================================================
read -r -d '' FIX_INJECT <<'EOF' || true
{"id":"inj1","title":"INJ |pipe `backtick` $(echo NOTRUN) end","severity":"critical","type":null,"domain":"code-quality","lens":"l","status":"new","primary_location":"inj.sh:1","confidence":null,"duplicate_group":null,"markdown_path":"401.md","validation":{}}
EOF
run_bucketize "$FIX_INJECT"
assert_rc_zero  "special-char title -> rc 0" "$BKT_RC"
assert_no_crash "special-char title does not crash (no shell evaluation)" "$BKT_ERR"
assert_member   "messy-title finding still bucketizes (critical -> top_critical_high)" top_critical_high inj1
TOTAL=$((TOTAL + 1))
if grep -qF -- '$(echo NOTRUN)' "$BKT_OUT"; then
  pass_with "command substitution in the title is NOT evaluated (verbatim \$(...) survives in the JSON)"
else
  fail_with "command substitution in the title is NOT evaluated (verbatim \$(...) survives in the JSON)" \
    "verbatim '\$(echo NOTRUN)' not found in output"
fi

# ===========================================================================
# AC: "do not hardcode a single repo's layout" — the bucket-2 security-domain
# predicate is DATA-DRIVEN from config/domains.json (every id matching
# /security/i), not a single hardcoded domain. The earlier fixtures only use
# `domain:"security"`, which ALSO happens to be the first entry of the static
# {security, llm-security} fallback, so they don't actually prove the derivation
# picks up the rest of the security set. `llm-security` is the SECOND security
# domain in config/domains.json: a medium finding there must land in bucket 2,
# confirming the /security/i derivation (not just the fallback's lead element).
# ===========================================================================
read -r -d '' FIX_LLMSEC <<'EOF' || true
{"id":"m-llmsec","title":"Medium llm-security domain","severity":"medium","type":null,"domain":"llm-security","lens":"l","status":"new","primary_location":"n.sh:1","confidence":null,"duplicate_group":null,"markdown_path":"201.md","validation":{}}
EOF
run_bucketize "$FIX_LLMSEC"
assert_rc_zero    "llm-security domain fixture -> rc 0" "$BKT_RC"
assert_member     "medium + llm-security DOMAIN -> top_medium_security (data-driven /security/i derivation)" top_medium_security m-llmsec
assert_not_member "...and NOT in remainder (the derivation is not a single hardcoded 'security')" remainder m-llmsec

# ===========================================================================
# typenorm alias resolution (mirrors lib/core.sh::finding_type_normalize): the
# bucket predicates must canonicalize obvious synonyms, not only the literal
# taxonomy ids. The earlier fixtures use only the literal forms (external-dependency,
# test-gap, maintainability); these exercise the alias branches that are otherwise
# uncovered:
#   cve / dependency      -> external-dependency -> not_actionable_without_scanner (B4)
#   tests / testing       -> test-gap            -> test_quality (B3)
# All are low severity / non-security so they cannot reach buckets 1 or 2 — the
# placement is driven purely by the type alias, which is the point.
# ===========================================================================
read -r -d '' FIX_SYNONYMS <<'EOF' || true
{"id":"syn-cve","title":"CVE alias","severity":"low","type":"cve","domain":"code-quality","lens":"l","status":"new","primary_location":"s1.sh:1","confidence":null,"duplicate_group":null,"markdown_path":"301.md","validation":{}}
{"id":"syn-dep","title":"dependency alias","severity":"low","type":"dependency","domain":"code-quality","lens":"l","status":"new","primary_location":"s2.sh:1","confidence":null,"duplicate_group":null,"markdown_path":"302.md","validation":{}}
{"id":"syn-tests","title":"tests alias","severity":"low","type":"tests","domain":"code-quality","lens":"l","status":"new","primary_location":"s3.sh:1","confidence":null,"duplicate_group":null,"markdown_path":"303.md","validation":{}}
{"id":"syn-testing","title":"testing alias","severity":"low","type":"testing","domain":"code-quality","lens":"l","status":"new","primary_location":"s4.sh:1","confidence":null,"duplicate_group":null,"markdown_path":"304.md","validation":{}}
EOF
run_bucketize "$FIX_SYNONYMS"
assert_rc_zero    "type-synonym fixture -> rc 0" "$BKT_RC"
assert_member     "type 'cve' -> not_actionable_without_scanner (alias of external-dependency)"        not_actionable_without_scanner syn-cve
assert_not_member "...and NOT in remainder"                                                            remainder syn-cve
assert_member     "type 'dependency' -> not_actionable_without_scanner (alias of external-dependency)" not_actionable_without_scanner syn-dep
assert_member     "type 'tests' -> test_quality (alias of test-gap)"                                   test_quality syn-tests
assert_not_member "...and NOT in remainder"                                                            remainder syn-tests
assert_member     "type 'testing' -> test_quality (alias of test-gap)"                                 test_quality syn-testing

# ===========================================================================
# Defensive fallback: a registry with a MALFORMED line makes the single jq -s
# (slurp) pass fail for the whole input; the helper must still honor its contract
# — valid JSON, all-empty buckets, rc 0 — via _human_review_empty_buckets. This
# exercises the `if ! jq ...; then` error branch, which the empty/missing/blank
# cases (which flow through the main pass) never reach. One valid record is
# included alongside the broken line to show the fallback empties EVERYTHING on a
# whole-pass failure (it does not silently drop just the bad line).
# ===========================================================================
read -r -d '' FIX_MALFORMED <<'EOF' || true
{"id":"ok-crit","title":"valid record","severity":"critical","type":null,"domain":"code-quality","lens":"l","status":"new","primary_location":"ok.sh:1","confidence":null,"duplicate_group":null,"markdown_path":"501.md","validation":{}}
this line is deliberately not valid json {{{
EOF
run_bucketize "$FIX_MALFORMED"
assert_rc_zero    "malformed-line registry -> rc 0 (contract holds, never errors)" "$BKT_RC"
assert_no_crash   "malformed-line registry does not crash" "$BKT_ERR"
assert_valid_json "malformed-line registry still prints a valid JSON object (defensive fallback)" "$BKT_OUT"
assert_jq_true "malformed input: all 5 buckets present, every count 0 and items [] (fallback)" "$BKT_OUT" \
  '(has("top_critical_high") and has("top_medium_security") and has("test_quality") and has("not_actionable_without_scanner") and has("remainder"))
   and ([.top_critical_high,.top_medium_security,.test_quality,.not_actionable_without_scanner,.remainder]
        | all(.count == 0 and (.items|length) == 0))'
assert_jq_eq "malformed input: caps metadata still intact in the fallback object" "$BKT_OUT" \
  '[.top_critical_high.cap, .top_medium_security.cap]|@csv' '10,25'

# ===========================================================================
# Defensive severity handling: a severity outside the {critical,high,medium,low}
# enum normalizes to rank -1 (the `// -1` default), so it can never enter buckets
# 1 or 2 and, lacking any type/scanner match, falls through to the remainder. The
# earlier fixtures only use in-enum severities, so the unknown-severity branch is
# otherwise uncovered.
# ===========================================================================
read -r -d '' FIX_UNKSEV <<'EOF' || true
{"id":"sev-unknown","title":"out-of-enum severity","severity":"informational","type":null,"domain":"code-quality","lens":"l","status":"new","primary_location":"u.sh:1","confidence":null,"duplicate_group":null,"markdown_path":"601.md","validation":{}}
EOF
run_bucketize "$FIX_UNKSEV"
assert_rc_zero    "unknown-severity fixture -> rc 0" "$BKT_RC"
assert_member     "unknown severity (rank -1) -> remainder" remainder sev-unknown
assert_not_member "...and NOT in top_critical_high (unknown severity is not critical/high)" top_critical_high sev-unknown

finish
