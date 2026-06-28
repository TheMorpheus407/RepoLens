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

# Tests for issue #350: group the themed Remainder (bucket 5) by domain into
# collapsed <details> sections with per-group counts in HUMAN_REVIEW.md.
# Pure-function tests only; NO AI models are invoked — every input is a
# handwritten JSON-Lines fixture and the renderer is pure jq + bash.
#
# Contract under test (issue acceptance criteria + research):
#
#   render_human_review_digest <run_id> renders the Remainder section so that
#   every bucket-5 finding appears under exactly one `domain` (theme) group,
#   each group a GitHub <details><summary>domain — N finding(s)</summary>…</details>
#   block collapsed by default. Groups are ordered by finding count descending,
#   then domain name ascending, for byte-identical determinism. A section total
#   line ("Other findings: N across M theme(s)") is shown. A null/empty domain
#   renders via an em dash (never the literal "null"). A zero remainder renders
#   cleanly with NO <details> blocks. Findings from buckets 1–4 never leak into
#   the remainder (membership is owned by the out-of-scope bucketizer).

set -uo pipefail
# shellcheck disable=SC2329  # helper functions are invoked indirectly

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_LIB="$SCRIPT_DIR/lib/core.sh"
RISK_LIB="$SCRIPT_DIR/lib/risk.sh"
HUMAN_REVIEW_LIB="$SCRIPT_DIR/lib/human_review.sh"

PASS=0
FAIL=0
TOTAL=0

TMP_PARENT="$SCRIPT_DIR/logs/test-human-review-grouping"
mkdir -p "$TMP_PARENT"
TMPROOT="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"

cleanup() {
  rm -rf "$TMPROOT"
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

# assert_contains <desc> <file> <fixed-string>
assert_contains() {
  local desc="$1" f="$2" needle="$3"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$f" ]] && grep -qF -- "$needle" "$f"; then
    pass_with "$desc"
  else
    fail_with "$desc" "expected to find: $needle"
  fi
}

# assert_not_contains <desc> <file> <fixed-string>
assert_not_contains() {
  local desc="$1" f="$2" needle="$3"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$f" ]] && grep -qF -- "$needle" "$f"; then
    fail_with "$desc" "did not expect to find: $needle"
  else
    pass_with "$desc"
  fi
}

# assert_eq <desc> <expected> <actual>
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "expected [$expected], got [$actual]"
  fi
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

# render_in <run_id> <jsonl-content> — set up a fresh LOG_BASE, drop the fixture
#   registry, invoke the renderer, and capture RR_OUT / RR_RC / RR_REM (the
#   remainder section sliced from "## Remainder" to EOF).
RUN_N=0
render_in() {
  local run_id="$1" content="$2"
  RUN_N=$((RUN_N + 1))
  RR_BASE="$TMPROOT/lb-$RUN_N"
  mkdir -p "$RR_BASE/final"
  printf '%s' "$content" >"$RR_BASE/final/findings.jsonl"
  RR_OUT="$RR_BASE/final/HUMAN_REVIEW.md"
  ( export LOG_BASE="$RR_BASE"; render_human_review_digest "$run_id" ) 2>/dev/null
  RR_RC=$?
  RR_REM="$RR_BASE/final/remainder-only.md"
  if [[ -f "$RR_OUT" ]]; then
    awk '/^## Remainder/{p=1} p' "$RR_OUT" >"$RR_REM"
  else
    : >"$RR_REM"
  fi
}

# ordered_domains <remainder-file> — emit the <summary> domain names in render
#   order, one per line. Used to assert the count-desc, then name-asc ordering.
ordered_domains() {
  grep -F '<summary>' "$1" \
    | sed -E 's#^<summary>(.*) — [0-9]+ finding\(s\)</summary>$#\1#'
}

# --- Source the library (core.sh + risk.sh first; harmless if unused). ----------
# shellcheck source=/dev/null
[[ -f "$CORE_LIB" ]] && source "$CORE_LIB"
# shellcheck source=/dev/null
[[ -f "$RISK_LIB" ]] && source "$RISK_LIB"
if [[ -f "$HUMAN_REVIEW_LIB" ]]; then
  # shellcheck source=/dev/null
  source "$HUMAN_REVIEW_LIB"
fi

TOTAL=$((TOTAL + 1))
if declare -F render_human_review_digest >/dev/null 2>&1; then
  pass_with "render_human_review_digest is defined after sourcing lib/human_review.sh"
else
  fail_with "render_human_review_digest is defined after sourcing lib/human_review.sh" \
    "function missing — cannot run the rest of the suite"
  finish
fi

# ===========================================================================
# 1. Remainder spanning several domains incl. one large group. A bucket-1
#    (critical) and a bucket-3 (test-gap) finding are mixed in to prove they
#    never leak into the remainder. Layout: perf x3, docs x2, arch x1, zebra x1
#    (7 remainder findings across 4 themes). Tie groups arch/zebra exercise the
#    name-asc tiebreak (arch before zebra).
# ===========================================================================
read -r -d '' FIX_MULTI <<'EOF' || true
{"id":"k1","title":"BUCKET1 critical leak","severity":"critical","type":"security","domain":"security","lens":"injection","status":"new","primary_location":"a.py:1","confidence":null,"markdown_path":"","validation":{}}
{"id":"k3","title":"BUCKET3 testgap leak","severity":"low","type":"test-gap","domain":"code-quality","lens":"tests","status":"new","primary_location":"t.py:1","confidence":null,"markdown_path":"","validation":{}}
{"id":"p1","title":"Perf one","severity":"low","type":"performance","domain":"perf","lens":"hot","status":"new","primary_location":"p1.py:1","confidence":null,"markdown_path":"perf1.md","validation":{}}
{"id":"p2","title":"Perf two","severity":"low","type":"performance","domain":"perf","lens":"cold","status":"new","primary_location":"p2.py:2","confidence":null,"markdown_path":"","validation":{}}
{"id":"p3","title":"Perf three","severity":"low","type":"performance","domain":"perf","lens":"warm","status":"new","primary_location":"p3.py:3","confidence":null,"markdown_path":"","validation":{}}
{"id":"d1","title":"Docs one","severity":"low","type":"performance","domain":"docs","lens":"readme","status":"new","primary_location":"d1.md:1","confidence":null,"markdown_path":"","validation":{}}
{"id":"d2","title":"Docs two","severity":"low","type":"performance","domain":"docs","lens":"api","status":"new","primary_location":"d2.md:2","confidence":null,"markdown_path":"","validation":{}}
{"id":"a1","title":"Arch one","severity":"low","type":"performance","domain":"arch","lens":"layering","status":"new","primary_location":"a1.py:1","confidence":null,"markdown_path":"","validation":{}}
{"id":"z1","title":"Zebra one","severity":"low","type":"performance","domain":"zebra","lens":"misc","status":"new","primary_location":"z1.py:1","confidence":null,"markdown_path":"","validation":{}}
EOF

render_in "multi-run" "$FIX_MULTI"
assert_rc_zero "multi-domain remainder -> rc 0" "$RR_RC"

# Heading + anchor kept.
assert_contains "remainder heading kept with total count" "$RR_REM" "## Remainder (7)"
assert_contains "remainder anchor id kept" "$RR_REM" 'id="remainder"'

# Section total line.
assert_contains "section total: Other findings across themes" "$RR_REM" \
  "Other findings: 7 across 4 theme(s)."

# Collapsed-by-default markers present (open + close).
assert_contains "collapsed block: <details> open marker present" "$RR_REM" "<details>"
assert_contains "collapsed block: </details> close marker present" "$RR_REM" "</details>"
assert_contains "collapsed block: <summary> marker present" "$RR_REM" "<summary>"

# Per-group summary headers with domain + count.
assert_contains "group header: perf with count 3" "$RR_REM" "<summary>perf — 3 finding(s)</summary>"
assert_contains "group header: docs with count 2" "$RR_REM" "<summary>docs — 2 finding(s)</summary>"
assert_contains "group header: arch with count 1" "$RR_REM" "<summary>arch — 1 finding(s)</summary>"
assert_contains "group header: zebra with count 1" "$RR_REM" "<summary>zebra — 1 finding(s)</summary>"

# Every remainder finding present (none dropped).
assert_contains "remainder finding present: Perf one" "$RR_REM" "Perf one"
assert_contains "remainder finding present: Perf two" "$RR_REM" "Perf two"
assert_contains "remainder finding present: Perf three" "$RR_REM" "Perf three"
assert_contains "remainder finding present: Docs one" "$RR_REM" "Docs one"
assert_contains "remainder finding present: Docs two" "$RR_REM" "Docs two"
assert_contains "remainder finding present: Arch one" "$RR_REM" "Arch one"
assert_contains "remainder finding present: Zebra one" "$RR_REM" "Zebra one"

# Findings carry severity + lens + primary_location like the top sections.
assert_contains "finding renders severity heading" "$RR_REM" "### [LOW] Perf one"
assert_contains "finding renders domain/lens + primary_location" "$RR_REM" "perf/hot — \`p1.py:1\`"

# Deterministic ordering: count desc, then domain name asc.
ACT_ORDER="$(ordered_domains "$RR_REM")"
EXP_ORDER=$'perf\ndocs\narch\nzebra'
assert_eq "groups ordered count desc, then name asc" "$EXP_ORDER" "$ACT_ORDER"

# No bucket 1–4 finding leaks into the remainder.
assert_not_contains "bucket-1 (critical) finding does not leak into remainder" "$RR_REM" \
  "BUCKET1 critical leak"
assert_not_contains "bucket-3 (test-gap) finding does not leak into remainder" "$RR_REM" \
  "BUCKET3 testgap leak"

# No literal "null" leaks anywhere in the digest.
assert_not_contains "no literal 'null' leaks into the digest" "$RR_OUT" "null"

# Determinism: rendering the same registry twice is byte-identical.
cp "$RR_OUT" "$TMPROOT/first-multi.md"
( export LOG_BASE="$RR_BASE"; render_human_review_digest "multi-run" ) 2>/dev/null
TOTAL=$((TOTAL + 1))
if cmp -s "$TMPROOT/first-multi.md" "$RR_OUT"; then
  pass_with "themed remainder render is deterministic (byte-identical across runs)"
else
  fail_with "themed remainder render is deterministic (byte-identical across runs)" "second render differs"
fi

# ===========================================================================
# 2. A null domain and an empty-string domain collapse into ONE em-dash group
#    (the grouping key is the normalized string, never JSON null), rendered via
#    the em dash, never the literal "null".
# ===========================================================================
read -r -d '' FIX_NULLDOM <<'EOF' || true
{"id":"n1","title":"Anon domain one","severity":"low","type":"performance","domain":null,"lens":"x","status":"new","primary_location":"n1.py:1","confidence":null,"markdown_path":"","validation":{}}
{"id":"n2","title":"Anon domain two","severity":"low","type":"performance","domain":"","lens":"y","status":"new","primary_location":"n2.py:2","confidence":null,"markdown_path":"","validation":{}}
EOF

render_in "anondom-run" "$FIX_NULLDOM"
assert_rc_zero "null/empty-domain remainder -> rc 0" "$RR_RC"
assert_contains "null + empty domain collapse into one em-dash group of 2" "$RR_REM" \
  "<summary>— — 2 finding(s)</summary>"
assert_contains "section total counts the single em-dash theme" "$RR_REM" \
  "Other findings: 2 across 1 theme(s)."
assert_not_contains "null domain never renders the literal 'null'" "$RR_OUT" "null"

# ===========================================================================
# 3. A zero remainder renders cleanly: the empty-state note and NO <details>.
#    (The lone critical finding lands in bucket 1, leaving the remainder empty.)
# ===========================================================================
read -r -d '' FIX_NOREM <<'EOF' || true
{"id":"c1","title":"Only critical","severity":"critical","type":"security","domain":"security","lens":"injection","status":"new","primary_location":"c.py:1","confidence":null,"markdown_path":"","validation":{}}
EOF

render_in "norem-run" "$FIX_NOREM"
assert_rc_zero "empty remainder -> rc 0" "$RR_RC"
assert_contains "empty remainder shows count 0 heading" "$RR_REM" "## Remainder (0)"
assert_contains "empty remainder shows a clean empty-state note" "$RR_REM" "_No further findings._"
assert_not_contains "empty remainder emits NO <details> block" "$RR_REM" "<details>"
assert_not_contains "empty remainder emits NO section total line" "$RR_REM" "Other findings:"

finish
