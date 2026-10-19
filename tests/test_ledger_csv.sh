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

# Tests for issue #324: lib/ledger.sh — build_findings_csv.
# Projects the canonical finding registry (findings.jsonl, schema in
# docs/finding-registry-schema.md) onto a flat CSV: a fixed 12-column header
# row, then one row per JSONL line, preserving JSONL line order. The nested
# `validation` object and the `source_finding_paths` array are OMITTED — they
# don't flatten to a single cell — and findings.jsonl stays the full-fidelity
# source of truth. Pure JSONL->CSV transform; NO AI models are invoked. Sibling
# of build_findings_jsonl_from_{manifest,local} — same atomic-write + jq-owns-
# escaping discipline.
# shellcheck disable=SC2329

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LEDGER_LIB="$SCRIPT_DIR/lib/ledger.sh"

# The exact 12-column contract. Header drift is the one real maintenance hazard
# for build_findings_csv (the header string and the jq array are two parallel
# lists), so this is asserted byte-for-byte below. Issue #385 appended
# `complexity` at the END so every pre-existing column index stays stable for
# downstream consumers that read the CSV positionally.
EXPECTED_HEADER='id,title,severity,type,domain,lens,status,primary_location,confidence,duplicate_group,markdown_path,complexity'

PASS=0
FAIL=0
TOTAL=0

TMP_PARENT="$SCRIPT_DIR/logs/test-ledger-csv"
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

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected '$expected', got '$actual'"
  fi
}

assert_success() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -eq 0 ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected exit 0, got $actual"
  fi
}

assert_failure() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -ne 0 ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected non-zero exit, got 0"
  fi
}

assert_file_exists() {
  local desc="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$path" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected file $path"
  fi
}

assert_file_missing() {
  local desc="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [[ ! -e "$path" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Did not expect file $path"
  fi
}

# assert_grep <desc> <-q|-qv> <fixed-string> <file>
#   -q : pass when the fixed string IS present.
#   -qv: pass when the fixed string is ABSENT.
assert_grep() {
  local desc="$1" mode="$2" needle="$3" file="$4"
  TOTAL=$((TOTAL + 1))
  if grep -qF -- "$needle" "$file"; then
    if [[ "$mode" == "-q" ]]; then pass_with "$desc"; else
      fail_with "$desc" "did not expect to find: $needle"; fi
  else
    if [[ "$mode" == "-qv" ]]; then pass_with "$desc"; else
      fail_with "$desc" "expected to find: $needle"; fi
  fi
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

# --- Source lib/ledger.sh ALONE (must stay self-contained) -----------------
# build_findings_csv uses jq + coreutils + Python 3, and ledger must source on
# its own (no hard dep on lib/core.sh / logging.sh). Sourcing alone here proves
# that contract and doubles as the TDD red-phase guard: before the function
# exists, we fail with a single clear message instead of a cascade.
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
if declare -F build_findings_csv >/dev/null 2>&1; then
  pass_with "build_findings_csv is defined after sourcing ledger alone"
else
  fail_with "build_findings_csv is defined after sourcing ledger alone" \
    "function not found — implementation pending (TDD red phase)"
  finish
fi

# ---------------------------------------------------------------------------
# Fixture JSONL — one small file covering every acceptance criterion.
#
#   fnd-1: title carries BOTH a comma and a double quote (the RFC-4180 stress
#          case), confidence is a number, and it carries a `validation` object
#          plus a distinctively-named `source_finding_paths` entry — both of
#          which must be DROPPED from the CSV.
#   fnd-2: severity / type / confidence / markdown_path are JSON null (must
#          render as empty cells), primary_location is an empty string, and
#          duplicate_group is populated.
# ---------------------------------------------------------------------------
in_jsonl="$TMPDIR/findings.jsonl"
cat > "$in_jsonl" <<'EOF'
{"id":"fnd-1","title":"Fix bug, now \"urgent\"","severity":"high","type":"security","domain":"code","lens":"input-validation","status":"new","primary_location":"a.go:10","confidence":0.9,"duplicate_group":null,"markdown_path":"001-x.md","validation":{},"source_finding_paths":["SRCPATH-ONLY.md"]}
{"id":"fnd-2","title":"Plain title","severity":null,"type":null,"domain":"code","lens":"y","status":"new","primary_location":"","confidence":null,"duplicate_group":"grp-1","markdown_path":null,"validation":{}}
EOF

jsonl_lines="$(wc -l < "$in_jsonl" | tr -d ' ')"

echo "=== build_findings_csv: happy path over the mixed fixture ==="

out_csv="$TMPDIR/findings.csv"
build_findings_csv "$in_jsonl" "$out_csv"
rc=$?
assert_success "valid JSONL returns exit 0" "$rc"
assert_file_exists "findings.csv is created" "$out_csv"

# AC: header row exactly the 12 named columns, in order (first line, byte-exact).
got_header=""
IFS= read -r got_header < "$out_csv"
assert_eq "header is exactly the 12 named columns, in order" \
  "$EXPECTED_HEADER" "$got_header"

# AC: header row then one row per JSONL line (header + N data lines).
total_lines="$(wc -l < "$out_csv" | tr -d ' ')"
assert_eq "output is header + one row per JSONL line" \
  "$((jsonl_lines + 1))" "$total_lines"
data_rows="$((total_lines - 1))"
assert_eq "data-row count equals the JSONL line count" "$jsonl_lines" "$data_rows"

# Omission: the nested validation object never reaches a cell. NOTE we cannot
# grep for the bare word "validation" — the legit lens value "input-validation"
# contains it — so we assert the serialized empty object {} is absent instead.
assert_grep "validation object is omitted (no serialized {} in any cell)" \
  -qv '{}' "$out_csv"
# Omission: source_finding_paths is dropped (its distinctively-named entry is
# nowhere in the projection).
assert_grep "source_finding_paths is omitted (its path token is absent)" \
  -qv 'SRCPATH-ONLY' "$out_csv"

echo "=== RFC-4180 quoting/escaping (comma + quote in the title) ==="

# AC: a title with a comma and a double quote is correctly quoted, with the
# inner quote doubled per RFC-4180. jq-free, byte-exact — always runs.
assert_grep "comma+quote title is RFC-4180 quoted (inner quote doubled)" \
  -q '"Fix bug, now ""urgent"""' "$out_csv"

# A JSON number renders as a bare (unquoted) cell — valid CSV, round-trips as
# the number. Proven jq-free by the quoted-location-then-unquoted-number seam.
assert_grep "numeric confidence renders unquoted" -q '"a.go:10",0.9,' "$out_csv"

echo "=== real CSV-parser round-trip (python3 csv module) ==="

# The authoritative round-trip: parse the CSV with a real RFC-4180 reader and
# assert the tricky title decodes byte-for-byte, null JSONL fields decode to
# empty cells, and the omitted fields are not columns. Python 3 is also required
# by the production exact-path CSV promoter.
if command -v python3 >/dev/null 2>&1; then
  py_rc=0
  python3 - "$out_csv" <<'PYEOF' || py_rc=$?
import csv, sys

path = sys.argv[1]
expected_header = ['id', 'title', 'severity', 'type', 'domain', 'lens',
                   'status', 'primary_location', 'confidence',
                   'duplicate_group', 'markdown_path', 'complexity']

with open(path, newline='') as f:
    reader = csv.DictReader(f)
    fieldnames = reader.fieldnames
    rows = list(reader)

if fieldnames != expected_header:
    sys.stderr.write('header mismatch: %r\n' % (fieldnames,))
    sys.exit(1)
for bad in ('validation', 'source_finding_paths'):
    if bad in (fieldnames or []):
        sys.stderr.write('unexpected column present: %s\n' % bad)
        sys.exit(1)
if len(rows) != 2:
    sys.stderr.write('expected 2 data rows, got %d\n' % len(rows))
    sys.exit(1)

# AC: the comma+quote title round-trips exactly through a real parser.
if rows[0]['title'] != 'Fix bug, now "urgent"':
    sys.stderr.write('title round-trip failed: %r\n' % rows[0]['title'])
    sys.exit(1)
# A JSON number stays its numeric text.
if rows[0]['confidence'] != '0.9':
    sys.stderr.write('confidence round-trip failed: %r\n' % rows[0]['confidence'])
    sys.exit(1)
# AC: null JSONL fields render as empty cells (row 2 severity/type/confidence/
# markdown_path are JSON null).
for col in ('severity', 'type', 'confidence', 'markdown_path'):
    if rows[1][col] != '':
        sys.stderr.write('row1 %s should be empty, got %r\n' % (col, rows[1][col]))
        sys.exit(1)
# A null in any column (row 0 duplicate_group) also empties.
if rows[0]['duplicate_group'] != '':
    sys.stderr.write('row0 duplicate_group should be empty, got %r\n'
                     % rows[0]['duplicate_group'])
    sys.exit(1)

sys.exit(0)
PYEOF
  assert_success "python3 csv round-trip: title, null->empty, omitted columns" "$py_rc"
else
  echo "  NOTE: python3 not found — skipping the csv-parser round-trip check" \
       "(quoting/omission ACs still covered by the jq-free greps above)"
fi

echo "=== RFC-4180: a newline embedded in a title (multi-line cell) ==="

# The doc comment promises a field containing a *newline* is quoted just like a
# comma/quote — but the mixed fixture above only stresses comma+quote. A newline
# in a title is the trickiest RFC-4180 case: the cell is quoted and spans
# multiple PHYSICAL lines while remaining ONE logical record. A consumer that
# splits on '\n' would mis-count rows; a real CSV reader must not. This is the
# case most likely to break a naive downstream parser, so cover it directly.
nl_in="$TMPDIR/newline.jsonl"
printf '%s\n' '{"id":"nl-1","title":"line one\nline two","severity":"low","type":"x","domain":"code","lens":"y","status":"new","primary_location":"a.go:1","confidence":0.1,"duplicate_group":null,"markdown_path":"m.md"}' > "$nl_in"
nl_out="$TMPDIR/newline.csv"
build_findings_csv "$nl_in" "$nl_out"
assert_success "newline-in-title JSONL returns exit 0" "$?"
assert_file_exists "newline-in-title produces a CSV file" "$nl_out"

# jq-free, always runs: the quoted cell genuinely spans multiple physical lines.
# Header (1) + a 2-physical-line quoted cell = 3 physical lines, even though it
# is only ONE logical data row. That contrast is the whole point of the case —
# a naive `wc -l`-style row count would over-count by one here.
nl_phys_lines="$(wc -l < "$nl_out" | tr -d ' ')"
assert_eq "multi-line cell spans extra physical lines (header + 2 = 3)" \
  "3" "$nl_phys_lines"

# Real-parser round-trip (guarded, same pattern as above): exactly ONE logical
# row, and the title decodes with its embedded newline intact.
if command -v python3 >/dev/null 2>&1; then
  nl_py_rc=0
  python3 - "$nl_out" <<'PYEOF' || nl_py_rc=$?
import csv, sys

rows = list(csv.DictReader(open(sys.argv[1], newline='')))
if len(rows) != 1:
    sys.stderr.write('expected 1 logical row, got %d\n' % len(rows))
    sys.exit(1)
if rows[0]['title'] != 'line one\nline two':
    sys.stderr.write('newline title round-trip failed: %r\n' % rows[0]['title'])
    sys.exit(1)
sys.exit(0)
PYEOF
  assert_success "python3 csv round-trip: multi-line cell is 1 row, newline intact" \
    "$nl_py_rc"
else
  echo "  NOTE: python3 not found — skipping the newline round-trip check" \
       "(physical-line-count assertion above still covers the multi-line cell)"
fi

echo "=== empty findings.jsonl -> header-only CSV, exit 0 ==="

# AC: an empty registry yields a header-only CSV (matching the empty,
# zero-line findings.jsonl) and still exits 0.
empty_in="$TMPDIR/empty.jsonl"
: > "$empty_in"
empty_out="$TMPDIR/empty.csv"
build_findings_csv "$empty_in" "$empty_out"
rc_empty=$?
assert_success "empty findings.jsonl returns exit 0" "$rc_empty"
assert_file_exists "empty input still produces a CSV file" "$empty_out"
empty_lines="$(wc -l < "$empty_out" | tr -d ' ')"
assert_eq "empty input yields a header-only CSV (1 line)" "1" "$empty_lines"
got_empty_header=""
IFS= read -r got_empty_header < "$empty_out"
assert_eq "empty-input CSV's single line is exactly the header" \
  "$EXPECTED_HEADER" "$got_empty_header"

echo "=== determinism (line order preserved, rebuilds byte-identical) ==="

out_csv2="$TMPDIR/findings2.csv"
build_findings_csv "$in_jsonl" "$out_csv2" >/dev/null 2>&1
TOTAL=$((TOTAL + 1))
if diff -q "$out_csv" "$out_csv2" >/dev/null 2>&1; then
  pass_with "two builds of the same JSONL are byte-identical"
else
  fail_with "two builds of the same JSONL are byte-identical" "output differs between runs"
fi

echo "=== error handling (failure paths, parity with sibling builders) ==="

# Missing arguments -> non-zero.
build_findings_csv >/dev/null 2>&1
assert_failure "missing both arguments returns non-zero" "$?"

build_findings_csv "$in_jsonl" >/dev/null 2>&1
assert_failure "missing out-path argument returns non-zero" "$?"

# Missing input file -> non-zero, and no output written (a typo'd path must not
# silently yield an empty/header-only CSV).
out_noinput="$TMPDIR/noinput.csv"
build_findings_csv "$TMPDIR/does-not-exist.jsonl" "$out_noinput" >/dev/null 2>&1
assert_failure "missing input file returns non-zero" "$?"
assert_file_missing "no output written when the input file is missing" "$out_noinput"

# Output path's parent dir missing -> the atomic tmp write fails -> non-zero,
# no output (parity with the JSONL builders).
out_noparent="$TMPDIR/missing-subdir/findings.csv"
build_findings_csv "$in_jsonl" "$out_noparent" >/dev/null 2>&1
assert_failure "nonexistent output parent dir returns non-zero" "$?"
assert_file_missing "no output written when the output parent dir is missing" "$out_noparent"

# A non-scalar value (array/object) in one of the 11 projected columns is not
# valid in a CSV row: jq @csv exits non-zero. The builder must FAIL LOUD —
# return non-zero, write NO output, leave no partial CSV — rather than silently
# coercing or truncating. This exercises the jq-failure cleanup branch
# (`jq ... || { rm -f "$tmp"; return 1; }`), distinct from the failure paths
# above: the missing-input / missing-out-parent cases never reach jq at all.
nonscalar_in="$TMPDIR/nonscalar.jsonl"
printf '%s\n' '{"id":"bad-1","title":["not","a","scalar"],"severity":"low","type":"x","domain":"code","lens":"y","status":"new","primary_location":"a.go:1","confidence":0.1,"duplicate_group":null,"markdown_path":"m.md"}' > "$nonscalar_in"
nonscalar_out="$TMPDIR/nonscalar.csv"
build_findings_csv "$nonscalar_in" "$nonscalar_out" >/dev/null 2>&1
assert_failure "non-scalar field in a projected column returns non-zero (jq fail-loud)" "$?"
assert_file_missing "no output written when jq rejects a non-scalar field" "$nonscalar_out"

# All-or-nothing on a corrupted registry: a VALID line followed by a malformed
# (non-JSON) line must abort the whole build — no CSV is emitted from the lines
# that parsed before the bad one. Guards against silently shipping a truncated
# projection of a partially-corrupt findings.jsonl.
partial_in="$TMPDIR/partial.jsonl"
{
  printf '%s\n' '{"id":"ok-1","title":"Good row","severity":"low","type":"x","domain":"code","lens":"y","status":"new","primary_location":"a.go:1","confidence":0.1,"duplicate_group":null,"markdown_path":"m.md"}'
  printf '%s\n' 'this is not valid json'
} > "$partial_in"
partial_out="$TMPDIR/partial.csv"
build_findings_csv "$partial_in" "$partial_out" >/dev/null 2>&1
assert_failure "a malformed line after a valid one returns non-zero" "$?"
assert_file_missing "no partial CSV written when a later JSONL line is malformed" "$partial_out"

echo "=== atomic write leaves no temp scaffolding behind ==="

# The builder writes to a temp file then mv's it into place. After every build
# above, no .tmp.<pid> file may linger in the sandbox.
leftover_tmp="$(find "$TMPDIR" -name '*.tmp.*' -type f 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "no .tmp.<pid> scaffolding survives a successful build" "0" "$leftover_tmp"

finish
