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

# Tests for issue #321: generate final/TODO.md from findings.jsonl
# (the "act on these now" list). Pure-function tests only; NO AI models are
# invoked — all input is handwritten JSON-Lines fixtures.
#
# Contract under test (from the issue acceptance criteria + the owner's
# research comment, which is the authoritative spec for the open design calls):
#
#   generate_todo_md <findings_jsonl> <out_file>
#     Reads the finding registry (JSON Lines, schema in
#     docs/finding-registry-schema.md), selects the actionable subset, and
#     writes a Markdown file at <out_file>. One entry per finding showing
#     severity, type, primary_location and a link to its markdown_path.
#
#   INCLUSION PREDICATE (research "Reading B" — the recommended/owner design):
#     include  <=>  status == "new"  AND  NOT (confidence is a number below the
#     documented threshold).
#       - status == "new" is the proof gate: the validation classifier (#334)
#         and dedupe (#335) demote weak/duplicate findings OUT of "new", so a
#         surviving "new" is confirmed and validation-not-negative.
#       - an UNSCORED confidence (null / absent) is KEPT (neutral), mirroring
#         lib/risk.sh's 0.5 default — unscored findings must not be buried. This
#         is the load-bearing difference from the rejected "Reading A" (require
#         explicit high confidence), which would make TODO.md empty for every
#         real run today (confidence is null for every record currently emitted).
#       - the opaque `validation` object is intentionally NOT inspected.
#
# Design notes that shape these tests:
#   - We test PUBLIC behavior: the contents of the written file and the return
#     code, never the internal jq filter / helper names / exact layout.
#   - The function may live in a new lib/artifacts.sh (research recommendation)
#     or alongside lib/summary.sh (AC-literal alternative). We source whichever
#     defines generate_todo_md — assert on the FUNCTION, not the file.
#   - Threshold VALUE is the implementer's documented choice (research suggests
#     0.5 inclusive, notes a reviewer may bump to 0.66). So confidence fixtures
#     use values that are unambiguous for any reasonable threshold in
#     [0.33, 0.7]: 0.9 (clearly kept), 0.2 (clearly dropped). The exact boundary
#     is deliberately NOT pinned.
#   - The empty-PRESENT-file return code (rc 0 + empty-state vs rc !=0 + nothing)
#     is explicitly sanctioned both ways by the research, so it is NOT pinned;
#     only "no spurious entries, no crash" is asserted. The MISSING-input rc IS
#     pinned non-zero — both the issue scope ("returns nonzero ... no crash")
#     and the research ("return 2, nothing written") agree on that.

set -uo pipefail
# shellcheck disable=SC2329  # helper functions are invoked indirectly

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_LIB="$SCRIPT_DIR/lib/core.sh"
RISK_LIB="$SCRIPT_DIR/lib/risk.sh"
ARTIFACTS_LIB="$SCRIPT_DIR/lib/artifacts.sh"
SUMMARY_LIB="$SCRIPT_DIR/lib/summary.sh"

PASS=0
FAIL=0
TOTAL=0

TMP_PARENT="$SCRIPT_DIR/logs/test-artifact-todo"
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

# assert_rc_zero / assert_rc_nonzero — the call's return code.
assert_rc_zero() {
  local desc="$1" rc="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$rc" -eq 0 ]]; then pass_with "$desc"; else fail_with "$desc" "Expected rc 0, got $rc"; fi
}
assert_rc_nonzero() {
  local desc="$1" rc="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$rc" -ne 0 ]]; then pass_with "$desc"; else fail_with "$desc" "Expected non-zero rc, got 0"; fi
}

assert_file_exists() {
  local desc="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$path" ]]; then pass_with "$desc"; else fail_with "$desc" "Expected file $path"; fi
}
assert_nonempty() {
  local desc="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -s "$path" ]]; then pass_with "$desc"; else fail_with "$desc" "Expected non-empty file $path"; fi
}

# assert_contains / assert_contains_ci — output file holds the literal needle.
assert_contains() {
  local desc="$1" needle="$2" path="$3"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$path" ]] && grep -qF -- "$needle" "$path"; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected to find '$needle' in $path"
  fi
}
assert_contains_ci() {
  local desc="$1" needle="$2" path="$3"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$path" ]] && grep -qiF -- "$needle" "$path"; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected to find (ci) '$needle' in $path"
  fi
}

# assert_not_contains — needle absent (also passes if the file was not written).
assert_not_contains() {
  local desc="$1" needle="$2" path="$3"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$path" ]] && grep -qF -- "$needle" "$path"; then
    fail_with "$desc" "Did not expect '$needle' in $path"
  else
    pass_with "$desc"
  fi
}

# assert_before — <earlier> appears on an earlier line than <later> (ordering).
assert_before() {
  local desc="$1" earlier="$2" later="$3" path="$4"
  TOTAL=$((TOTAL + 1))
  local la lb
  la="$(grep -nF -- "$earlier" "$path" 2>/dev/null | head -1 | cut -d: -f1)"
  lb="$(grep -nF -- "$later" "$path" 2>/dev/null | head -1 | cut -d: -f1)"
  if [[ -n "$la" && -n "$lb" && "$la" -lt "$lb" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected '$earlier' (line ${la:-none}) before '$later' (line ${lb:-none})"
  fi
}

# assert_no_crash — stderr shows no bash-level explosion (set -u / syntax).
#   Intentional warnings are fine; an unbound-variable / syntax crash is not.
assert_no_crash() {
  local desc="$1" errfile="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$errfile" ]] && grep -qiE 'unbound variable|syntax error|command not found' "$errfile"; then
    fail_with "$desc" "stderr indicates a crash: $(head -1 "$errfile")"
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

# run_gen <jsonl-content> — write the fixture, invoke the generator, capture
#   GEN_IN / GEN_OUT / GEN_ERR (paths) and GEN_RC (return code).
GEN_N=0
run_gen() {
  local content="$1"
  GEN_N=$((GEN_N + 1))
  GEN_IN="$TMPDIR/findings-$GEN_N.jsonl"
  GEN_OUT="$TMPDIR/todo-$GEN_N.md"
  GEN_ERR="$TMPDIR/err-$GEN_N.txt"
  printf '%s' "$content" >"$GEN_IN"
  generate_todo_md "$GEN_IN" "$GEN_OUT" 2>"$GEN_ERR"
  GEN_RC=$?
}

# run_gen_missing — invoke the generator against an input path that does not
#   exist (the "missing input" edge). Captures GEN_OUT / GEN_ERR / GEN_RC.
run_gen_missing() {
  GEN_N=$((GEN_N + 1))
  GEN_OUT="$TMPDIR/todo-$GEN_N.md"
  GEN_ERR="$TMPDIR/err-$GEN_N.txt"
  generate_todo_md "$TMPDIR/does-not-exist-$GEN_N.jsonl" "$GEN_OUT" 2>"$GEN_ERR"
  GEN_RC=$?
}

# --- Source the library (core.sh + risk.sh first; the generator MAY reuse the
# shared severity/risk helpers, and sourcing them is harmless if it does not).
# Prefer lib/artifacts.sh (research recommendation); fall back to lib/summary.sh
# (AC-literal). Assert on the FUNCTION, not the file. ----------------------------
# shellcheck source=/dev/null
[[ -f "$CORE_LIB" ]] && source "$CORE_LIB"
# shellcheck source=/dev/null
[[ -f "$RISK_LIB" ]] && source "$RISK_LIB"
if [[ -f "$ARTIFACTS_LIB" ]]; then
  # shellcheck source=/dev/null
  source "$ARTIFACTS_LIB"
fi
if ! declare -F generate_todo_md >/dev/null 2>&1 && [[ -f "$SUMMARY_LIB" ]]; then
  # shellcheck source=/dev/null
  source "$SUMMARY_LIB"
fi

TOTAL=$((TOTAL + 1))
if declare -F generate_todo_md >/dev/null 2>&1; then
  pass_with "generate_todo_md is defined after sourcing (artifacts.sh or summary.sh)"
else
  fail_with "generate_todo_md is defined after sourcing (artifacts.sh or summary.sh)" \
    "not found in lib/artifacts.sh or lib/summary.sh"
  finish
fi

# ===========================================================================
# AC: reads findings.jsonl, writes a Markdown file; inclusion predicate selects
# only confirmed/actionable findings (status=new + good proof). Mixed fixture:
# two should appear, five should be excluded.
#   - INCL-NEW-NULLCONF : status=new, confidence=null  -> KEPT (unscored neutral)
#   - INCL-NEW-HIGHCONF : status=new, confidence=0.9   -> KEPT
#   - EXCL-NEW-LOWCONF  : status=new, confidence=0.2   -> dropped (explicit low)
#   - EXCL-NEEDSVAL     : status=needs-validation      -> dropped
#   - EXCL-FALSEPOS     : status=likely-false-positive -> dropped
#   - EXCL-DUP          : status=duplicate             -> dropped
#   - EXCL-UNKNOWN      : status="newish"              -> dropped (exact match)
# ===========================================================================
read -r -d '' FIX_PREDICATE <<'EOF' || true
{"id":"f1","title":"INCL-NEW-NULLCONF","severity":"high","type":"security","domain":"d","lens":"l","status":"new","primary_location":"a.sh:10","confidence":null,"duplicate_group":null,"markdown_path":"001-a.md","validation":{}}
{"id":"f2","title":"INCL-NEW-HIGHCONF","severity":"critical","type":"reliability","domain":"d","lens":"l","status":"new","primary_location":"b.sh:20","confidence":0.9,"duplicate_group":null,"markdown_path":"002-b.md","validation":{}}
{"id":"f3","title":"EXCL-NEW-LOWCONF","severity":"high","type":"security","domain":"d","lens":"l","status":"new","primary_location":"c.sh:30","confidence":0.2,"duplicate_group":null,"markdown_path":"003-c.md","validation":{}}
{"id":"f4","title":"EXCL-NEEDSVAL","severity":"high","type":"security","domain":"d","lens":"l","status":"needs-validation","primary_location":"d.sh:40","confidence":0.9,"duplicate_group":null,"markdown_path":"004-d.md","validation":{}}
{"id":"f5","title":"EXCL-FALSEPOS","severity":"high","type":"security","domain":"d","lens":"l","status":"likely-false-positive","primary_location":"e.sh:50","confidence":0.9,"duplicate_group":null,"markdown_path":"005-e.md","validation":{}}
{"id":"f6","title":"EXCL-DUP","severity":"high","type":"security","domain":"d","lens":"l","status":"duplicate","primary_location":"f.sh:60","confidence":0.9,"duplicate_group":"g1","markdown_path":"006-f.md","validation":{}}
{"id":"f7","title":"EXCL-UNKNOWN","severity":"high","type":"security","domain":"d","lens":"l","status":"newish","primary_location":"g.sh:70","confidence":0.9,"duplicate_group":null,"markdown_path":"007-g.md","validation":{}}
EOF
run_gen "$FIX_PREDICATE"
assert_rc_zero       "predicate fixture -> success rc" "$GEN_RC"
assert_file_exists   "writes a Markdown file at out_file" "$GEN_OUT"
assert_nonempty      "written TODO.md is non-empty when there are actionable findings" "$GEN_OUT"
assert_contains      "status=new + null confidence is KEPT (unscored neutral, Reading B)" "INCL-NEW-NULLCONF" "$GEN_OUT"
assert_contains      "status=new + high confidence is KEPT" "INCL-NEW-HIGHCONF" "$GEN_OUT"
assert_not_contains  "status=new + explicit low confidence is EXCLUDED" "EXCL-NEW-LOWCONF" "$GEN_OUT"
assert_not_contains  "status=needs-validation is EXCLUDED" "EXCL-NEEDSVAL" "$GEN_OUT"
assert_not_contains  "status=likely-false-positive is EXCLUDED" "EXCL-FALSEPOS" "$GEN_OUT"
assert_not_contains  "status=duplicate is EXCLUDED" "EXCL-DUP" "$GEN_OUT"
assert_not_contains  "unknown status (not exactly \"new\") is EXCLUDED" "EXCL-UNKNOWN" "$GEN_OUT"

# ===========================================================================
# AC: each entry shows severity, type, primary_location, and links to
# markdown_path. One fully-populated actionable finding.
# ===========================================================================
read -r -d '' FIX_RENDER <<'EOF' || true
{"id":"r1","title":"RENDER-FULL","severity":"critical","type":"security","domain":"d","lens":"l","status":"new","primary_location":"src/app.sh:42","confidence":0.9,"duplicate_group":null,"markdown_path":"012-render-full.md","validation":{}}
EOF
run_gen "$FIX_RENDER"
assert_rc_zero      "render fixture -> success rc" "$GEN_RC"
assert_contains     "entry shows the finding title" "RENDER-FULL" "$GEN_OUT"
assert_contains_ci  "entry shows the severity"      "critical" "$GEN_OUT"
assert_contains     "entry shows the type"          "security" "$GEN_OUT"
assert_contains     "entry shows the primary_location" "src/app.sh:42" "$GEN_OUT"
assert_contains     "entry links to markdown_path (Markdown link target)" "](012-render-full.md)" "$GEN_OUT"

# ===========================================================================
# AC: defensive rendering. null type, empty primary_location, and null
# markdown_path must not leak the literal "null" and must not emit a broken
# empty link "[...]()"; the finding itself still appears.
# ===========================================================================
read -r -d '' FIX_DEFENSIVE <<'EOF' || true
{"id":"d1","title":"DEFENSIVE-ENTRY","severity":"high","type":null,"domain":"d","lens":"l","status":"new","primary_location":"","confidence":0.9,"duplicate_group":null,"markdown_path":null,"validation":{}}
EOF
run_gen "$FIX_DEFENSIVE"
assert_rc_zero      "defensive fixture -> success rc" "$GEN_RC"
assert_contains     "actionable finding with sparse fields still appears" "DEFENSIVE-ENTRY" "$GEN_OUT"
assert_not_contains "null fields do not leak the literal \"null\" into the Markdown" "null" "$GEN_OUT"
assert_not_contains "null markdown_path does not emit a broken empty link \"[...]()\"" "]()" "$GEN_OUT"

# ===========================================================================
# AC: order entries sensibly by severity (critical > high > medium > low).
# All status=new, all clearly-kept confidence; input order is scrambled so a
# pass proves the generator sorts (not just echoes input order).
# ===========================================================================
read -r -d '' FIX_ORDER <<'EOF' || true
{"id":"o1","title":"ORD-LOW","severity":"low","type":"security","domain":"d","lens":"l","status":"new","primary_location":"l.sh:1","confidence":0.9,"duplicate_group":null,"markdown_path":"101-low.md","validation":{}}
{"id":"o2","title":"ORD-CRIT","severity":"critical","type":"security","domain":"d","lens":"l","status":"new","primary_location":"c.sh:1","confidence":0.9,"duplicate_group":null,"markdown_path":"102-crit.md","validation":{}}
{"id":"o3","title":"ORD-MED","severity":"medium","type":"security","domain":"d","lens":"l","status":"new","primary_location":"m.sh:1","confidence":0.9,"duplicate_group":null,"markdown_path":"103-med.md","validation":{}}
{"id":"o4","title":"ORD-HIGH","severity":"high","type":"security","domain":"d","lens":"l","status":"new","primary_location":"h.sh:1","confidence":0.9,"duplicate_group":null,"markdown_path":"104-high.md","validation":{}}
EOF
run_gen "$FIX_ORDER"
assert_before "ordering: critical entry precedes high entry" "ORD-CRIT" "ORD-HIGH" "$GEN_OUT"
assert_before "ordering: high entry precedes medium entry"   "ORD-HIGH" "ORD-MED"  "$GEN_OUT"
assert_before "ordering: medium entry precedes low entry"    "ORD-MED"  "ORD-LOW"  "$GEN_OUT"

# ===========================================================================
# AC (research §3/§9): equal severity is ordered by descending confidence.
# Both above any reasonable threshold so both are kept; 0.95 must precede 0.70.
# ===========================================================================
read -r -d '' FIX_TIE <<'EOF' || true
{"id":"t1","title":"TIE-LOWER","severity":"high","type":"security","domain":"d","lens":"l","status":"new","primary_location":"x.sh:1","confidence":0.70,"duplicate_group":null,"markdown_path":"201-lo.md","validation":{}}
{"id":"t2","title":"TIE-HIGHER","severity":"high","type":"security","domain":"d","lens":"l","status":"new","primary_location":"y.sh:1","confidence":0.95,"duplicate_group":null,"markdown_path":"202-hi.md","validation":{}}
EOF
run_gen "$FIX_TIE"
assert_before "equal severity: higher confidence entry comes first" "TIE-HIGHER" "TIE-LOWER" "$GEN_OUT"

# ===========================================================================
# Determinism: same input rendered twice produces byte-identical output (a
# stable sort tiebreak — required so finalize output does not churn run-to-run).
# ===========================================================================
DET_OUT_A="$TMPDIR/det-a.md"
DET_OUT_B="$TMPDIR/det-b.md"
generate_todo_md "$GEN_IN" "$DET_OUT_A" 2>/dev/null
generate_todo_md "$GEN_IN" "$DET_OUT_B" 2>/dev/null
TOTAL=$((TOTAL + 1))
if cmp -s "$DET_OUT_A" "$DET_OUT_B"; then
  pass_with "deterministic: two runs on the same input are byte-identical"
else
  fail_with "deterministic: two runs on the same input are byte-identical" "outputs differ"
fi

# ===========================================================================
# AC: all-excluded input (records exist, NONE qualify) produces NO spurious
# entries and does not crash. The empty-PRESENT-file return code is the
# implementer's documented choice (research sanctions rc 0 + empty-state OR
# rc !=0 + nothing), so it is NOT pinned here.
# ===========================================================================
read -r -d '' FIX_ALLEXCL <<'EOF' || true
{"id":"x1","title":"AX-NEEDSVAL","severity":"critical","type":"security","domain":"d","lens":"l","status":"needs-validation","primary_location":"a.sh:1","confidence":0.9,"duplicate_group":null,"markdown_path":"301-a.md","validation":{}}
{"id":"x2","title":"AX-DUP","severity":"critical","type":"security","domain":"d","lens":"l","status":"duplicate","primary_location":"b.sh:1","confidence":0.9,"duplicate_group":"g","markdown_path":"302-b.md","validation":{}}
{"id":"x3","title":"AX-LOWCONF","severity":"critical","type":"security","domain":"d","lens":"l","status":"new","primary_location":"c.sh:1","confidence":0.1,"duplicate_group":null,"markdown_path":"303-c.md","validation":{}}
EOF
run_gen "$FIX_ALLEXCL"
assert_no_crash     "all-excluded input does not crash the caller" "$GEN_ERR"
assert_not_contains "all-excluded: needs-validation finding not rendered" "AX-NEEDSVAL" "$GEN_OUT"
assert_not_contains "all-excluded: duplicate finding not rendered"        "AX-DUP"      "$GEN_OUT"
assert_not_contains "all-excluded: low-confidence finding not rendered"   "AX-LOWCONF"  "$GEN_OUT"

# ===========================================================================
# AC: empty input file (0 lines) produces no spurious entries and does not
# error the caller (no set -u explosion). rc not pinned (see above).
# ===========================================================================
run_gen ""
assert_no_crash "empty input file does not crash the caller" "$GEN_ERR"

# ===========================================================================
# AC + research: MISSING / unreadable input -> non-zero rc, no crash, nothing
# meaningful written. Both the issue scope and the research agree the rc is
# non-zero here (research recommends 2).
# ===========================================================================
run_gen_missing
assert_rc_nonzero "missing input file -> non-zero rc" "$GEN_RC"
assert_no_crash   "missing input file does not crash the caller (clean return)" "$GEN_ERR"

# ===========================================================================
# COVERAGE (issue #321 impl, lib/artifacts.sh): the function header asserts field
# values are "emitted verbatim by jq ... a title containing backticks / $() /
# pipes is data, never shell-evaluated", and the list layout (not a Markdown
# table) is chosen precisely so a literal "|" in a title cannot break the row.
# Neither claim was exercised by the test-dev stage. This fixture feeds a title
# packed with shell- and Markdown-significant characters and proves: no command
# substitution runs (the verbatim "$(...)" survives), the pipe survives, and the
# surrounding entry still renders its structured fields.
# ===========================================================================
read -r -d '' FIX_INJECT <<'EOF' || true
{"id":"inj1","title":"INJ-MARK |pipe `backtick` $(echo NOTRUN) ]rbracket","severity":"high","type":"security","domain":"d","lens":"l","status":"new","primary_location":"inj.sh:1","confidence":0.9,"duplicate_group":null,"markdown_path":"401-inj.md","validation":{}}
EOF
run_gen "$FIX_INJECT"
assert_rc_zero  "special-char title -> success rc" "$GEN_RC"
assert_no_crash "special-char title does not crash the caller" "$GEN_ERR"
assert_contains "special-char title is rendered (entry present)" "INJ-MARK" "$GEN_OUT"
assert_contains "command substitution in the title is NOT evaluated (verbatim \$(...) survives)" "\$(echo NOTRUN)" "$GEN_OUT"
assert_contains "a literal pipe in the title survives (list layout, no table breakage)" "|pipe" "$GEN_OUT"
assert_contains "the entry's structured fields still render alongside the messy title" "inj.sh:1" "$GEN_OUT"

# ===========================================================================
# COVERAGE: the impl documents that an all-excluded OR empty registry writes a
# WELL-FORMED empty-state file ("_No actionable findings._") and returns 0. The
# test-dev stage deliberately left the empty-case rc + file FREE (open implementer
# choice) and only checked "no spurious entries / no crash". Now that the code has
# chosen, pin the positive half: the artifact IS written, rc is 0, and the
# empty-state note is present — so a regression to "write nothing / error out"
# is caught.
# ===========================================================================
read -r -d '' FIX_EMPTYSTATE <<'EOF' || true
{"id":"es1","title":"ES-DUP","severity":"critical","type":"security","domain":"d","lens":"l","status":"duplicate","primary_location":"a.sh:1","confidence":0.9,"duplicate_group":"g","markdown_path":"501-a.md","validation":{}}
EOF
run_gen "$FIX_EMPTYSTATE"
assert_rc_zero     "all-excluded registry returns 0 (well-formed empty-state, not an error)" "$GEN_RC"
assert_file_exists "all-excluded registry still writes a TODO.md artifact" "$GEN_OUT"
assert_contains    "all-excluded TODO.md carries the empty-state note" "No actionable findings" "$GEN_OUT"
# Empty (0-line) input -> same empty-state contract.
run_gen ""
assert_rc_zero     "empty input file returns 0 (empty-state artifact)" "$GEN_RC"
assert_file_exists "empty input file still writes a TODO.md artifact" "$GEN_OUT"
assert_contains    "empty input TODO.md carries the empty-state note" "No actionable findings" "$GEN_OUT"

# ===========================================================================
# COVERAGE: the impl pins a documented inclusion threshold — confidence >= 0.5 is
# KEPT, an explicit number below 0.5 is dropped (THRESHOLD=0.5, inclusive). The
# test-dev stage left the boundary unpinned (it used 0.9/0.2, unambiguous for any
# threshold). Now that the code chose 0.5-inclusive, lock the boundary so a
# regression that flips the comparison (>= vs >) or silently moves the constant
# is caught. NOTE: if a reviewer intentionally bumps THRESHOLD (the header invites
# 0.66), update these two assertions to match the new documented constant.
# ===========================================================================
read -r -d '' FIX_BOUNDARY <<'EOF' || true
{"id":"b1","title":"BND-AT-THRESHOLD","severity":"high","type":"security","domain":"d","lens":"l","status":"new","primary_location":"a.sh:1","confidence":0.5,"duplicate_group":null,"markdown_path":"601-a.md","validation":{}}
{"id":"b2","title":"BND-BELOW-THRESHOLD","severity":"high","type":"security","domain":"d","lens":"l","status":"new","primary_location":"b.sh:1","confidence":0.49,"duplicate_group":null,"markdown_path":"602-b.md","validation":{}}
EOF
run_gen "$FIX_BOUNDARY"
assert_rc_zero      "threshold-boundary fixture -> success rc" "$GEN_RC"
assert_contains     "confidence == 0.5 is KEPT (documented threshold is inclusive)" "BND-AT-THRESHOLD" "$GEN_OUT"
assert_not_contains "confidence just below 0.5 (0.49) is EXCLUDED" "BND-BELOW-THRESHOLD" "$GEN_OUT"

# ===========================================================================
# COVERAGE: a status=new finding with an UNMAPPABLE ("info") or EMPTY ("")
# severity still passes the proof gate, so it must appear, render its severity
# defensively (em dash for ""), never leak the literal "null", and sort LAST via
# the `// -1` rank fallback. None of this severity-edge path was exercised by the
# test-dev stage (its ordering fixture used only the four mapped severities).
# ===========================================================================
read -r -d '' FIX_SEV <<'EOF' || true
{"id":"sv1","title":"SEV-CRIT","severity":"critical","type":"security","domain":"d","lens":"l","status":"new","primary_location":"c.sh:1","confidence":0.9,"duplicate_group":null,"markdown_path":"701-c.md","validation":{}}
{"id":"sv2","title":"SEV-EMPTY","severity":"","type":"security","domain":"d","lens":"l","status":"new","primary_location":"e.sh:1","confidence":0.9,"duplicate_group":null,"markdown_path":"702-e.md","validation":{}}
{"id":"sv3","title":"SEV-UNMAPPED","severity":"info","type":"security","domain":"d","lens":"l","status":"new","primary_location":"i.sh:1","confidence":0.9,"duplicate_group":null,"markdown_path":"703-i.md","validation":{}}
EOF
run_gen "$FIX_SEV"
assert_rc_zero      "odd-severity fixture -> success rc" "$GEN_RC"
assert_contains     "empty-severity status=new finding still appears (proof gate passed)" "SEV-EMPTY" "$GEN_OUT"
assert_contains     "unmapped-severity status=new finding still appears" "SEV-UNMAPPED" "$GEN_OUT"
assert_not_contains "empty/odd severity does not leak the literal \"null\"" "null" "$GEN_OUT"
assert_before       "ordering: mapped critical precedes an empty-severity finding (rank -1 sorts last)" "SEV-CRIT" "SEV-EMPTY" "$GEN_OUT"
assert_before       "ordering: mapped critical precedes an unmapped-severity finding (rank -1 sorts last)" "SEV-CRIT" "SEV-UNMAPPED" "$GEN_OUT"

# ===========================================================================
# COVERAGE: real/partial registry records may OMIT keys entirely (not just set
# them to null). A record with NO confidence key is unscored -> KEPT (jq sees the
# missing key as null, type != "number"); a record with NO type key renders
# defensively (em dash, not "null"). The test-dev fixtures always wrote every key.
# ===========================================================================
read -r -d '' FIX_ABSENT <<'EOF' || true
{"id":"ab1","title":"ABSENT-KEYS-KEPT","severity":"high","status":"new","primary_location":"z.sh:1","markdown_path":"801-z.md"}
EOF
run_gen "$FIX_ABSENT"
assert_rc_zero      "absent-keys fixture -> success rc" "$GEN_RC"
assert_contains     "record OMITTING the confidence key is KEPT (unscored = neutral)" "ABSENT-KEYS-KEPT" "$GEN_OUT"
assert_not_contains "absent type key does not leak the literal \"null\"" "null" "$GEN_OUT"

# ===========================================================================
# COVERAGE: the impl documents rc 2 SPECIFICALLY for bad/unreadable input, and
# guards missing ARGS (empty findings path OR empty out path) with that same rc 2
# `|| return 2` branch — which the test-dev "missing input" case never reaches (it
# passes BOTH args and asserts nonzero only). Pin the documented usage code (==2)
# and the no-write / no-crash guarantee for each bad-argument shape.
# ===========================================================================
# (a) missing input file -> the documented rc 2, nothing written.
run_gen_missing
TOTAL=$((TOTAL + 1))
if [[ "$GEN_RC" -eq 2 ]]; then pass_with "missing input file returns the documented rc 2"
else fail_with "missing input file returns the documented rc 2" "Expected rc 2, got $GEN_RC"; fi
TOTAL=$((TOTAL + 1))
if [[ ! -e "$GEN_OUT" ]]; then pass_with "missing input writes no output file"
else fail_with "missing input writes no output file" "Unexpected file $GEN_OUT"; fi

# (b) empty findings-path argument -> rc 2, no crash, nothing written.
BADARG_OUT="$TMPDIR/badarg-out.md"
BADARG_ERR="$TMPDIR/badarg.err"
generate_todo_md "" "$BADARG_OUT" 2>"$BADARG_ERR"; BADARG_RC=$?
TOTAL=$((TOTAL + 1))
if [[ "$BADARG_RC" -eq 2 ]]; then pass_with "empty findings-path arg returns rc 2"
else fail_with "empty findings-path arg returns rc 2" "Expected rc 2, got $BADARG_RC"; fi
assert_no_crash "empty findings-path arg does not crash the caller" "$BADARG_ERR"
TOTAL=$((TOTAL + 1))
if [[ ! -e "$BADARG_OUT" ]]; then pass_with "empty findings-path arg writes no output file"
else fail_with "empty findings-path arg writes no output file" "Unexpected file $BADARG_OUT"; fi

# (c) empty out-file argument (valid input present) -> rc 2, no crash.
BADARG2_IN="$TMPDIR/badarg2-in.jsonl"
BADARG2_ERR="$TMPDIR/badarg2.err"
printf '%s' '{"id":"q1","title":"Q","severity":"high","status":"new"}' >"$BADARG2_IN"
generate_todo_md "$BADARG2_IN" "" 2>"$BADARG2_ERR"; BADARG2_RC=$?
TOTAL=$((TOTAL + 1))
if [[ "$BADARG2_RC" -eq 2 ]]; then pass_with "empty out-file arg returns rc 2"
else fail_with "empty out-file arg returns rc 2" "Expected rc 2, got $BADARG2_RC"; fi
assert_no_crash "empty out-file arg does not crash the caller" "$BADARG2_ERR"

finish
