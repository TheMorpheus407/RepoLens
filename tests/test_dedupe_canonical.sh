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

# Tests for issue #316: deterministic canonical-record selection helper for a
# duplicate group. Pure-function tests only; no AI models are invoked.
#
# Contract under test (from the issue acceptance criteria):
#   _dedupe_pick_canonical <json_array> [id_field=cluster_id]
#     Given a JSON array of finding records belonging to ONE duplicate group,
#     prints the id of the single CANONICAL record on stdout (one line).
#     Deterministic selection rule, applied in order:
#       1. highest severity   (via severity_rank / severity_normalize, lib/core.sh)
#       2. highest confidence  (numeric; missing/null/unparseable = lowest)
#       3. lexicographically smallest id  (stable tiebreak; order-independent)
#     id_field defaults to "cluster_id" (manifest.json); pass "id" for findings.jsonl.
#     Returns non-zero and prints nothing on empty/non-array/invalid input.
#     Pure: no side effects, no model.
#
# Design notes that shape these tests:
#   - We test the PUBLIC behavior (which id is returned), never the internal
#     sort-line format or helper functions. The implementer is free to choose
#     a new lib/dedupe.sh (recommended by research) OR add the function to
#     lib/synthesize.sh (AC-literal); the test sources whichever defines it.
#   - Fixtures deliberately place the WINNING record's id so it is NOT the
#     lexicographically smallest, so a passing severity/confidence test proves
#     that key dominates the id tiebreak rather than coinciding with it.
#   - The concrete non-zero return CODE for bad input is the implementer's
#     choice; we pin only "non-zero, empty stdout", never a specific value.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_LIB="$SCRIPT_DIR/lib/core.sh"
DEDUPE_LIB="$SCRIPT_DIR/lib/dedupe.sh"
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

# assert_eq <desc> <expected> <actual> — exact string equality (the returned id).
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected '$expected', got '$actual'"
  fi
}

# assert_rc_zero <desc> <rc> — the call succeeded (did not crash / error out).
assert_rc_zero() {
  local desc="$1" rc="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$rc" -eq 0 ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected rc 0, got $rc"
  fi
}

# assert_rc_nonzero <desc> <rc> — the call signalled "no canonical" via non-zero.
assert_rc_nonzero() {
  local desc="$1" rc="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$rc" -ne 0 ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected non-zero rc, got 0"
  fi
}

# assert_empty <desc> <value> — stdout was empty (no id printed on bad input).
assert_empty() {
  local desc="$1" value="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -z "$value" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected empty output, got '$value'"
  fi
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

# run_pick <json_array> [id_field] — invoke the helper, capturing stdout + rc.
#   Sets globals PICK_OUT (printed id, trailing newline stripped) and PICK_RC.
run_pick() {
  PICK_OUT="$(_dedupe_pick_canonical "$@")"
  PICK_RC=$?
}

# --- Source the library (core.sh first: the helper reuses severity_rank) -----
# The function may live in a new lib/dedupe.sh (research recommendation) or in
# lib/synthesize.sh (AC-literal). Source core.sh, then prefer dedupe.sh, and
# fall back to synthesize.sh — assert on the FUNCTION, not the file.
# shellcheck source=/dev/null
source "$CORE_LIB"

if [[ -f "$DEDUPE_LIB" ]]; then
  # shellcheck source=/dev/null
  source "$DEDUPE_LIB"
fi
if ! declare -F _dedupe_pick_canonical >/dev/null 2>&1 && [[ -f "$SYNTH_LIB" ]]; then
  # shellcheck source=/dev/null
  source "$SYNTH_LIB"
fi

TOTAL=$((TOTAL + 1))
if declare -F _dedupe_pick_canonical >/dev/null 2>&1; then
  pass_with "_dedupe_pick_canonical is defined after sourcing (dedupe.sh or synthesize.sh)"
else
  fail_with "_dedupe_pick_canonical is defined after sourcing (dedupe.sh or synthesize.sh)" \
    "not found in lib/dedupe.sh or lib/synthesize.sh"
  finish
fi

# ===========================================================================
# AC: differing severity -> highest-severity id wins.
# Winner ("zzz", critical) is the lexicographically LARGEST id, proving
# severity dominates the id tiebreak (not coincidentally smallest).
# ===========================================================================
run_pick '[
  {"cluster_id":"aaa","severity":"low"},
  {"cluster_id":"mmm","severity":"high"},
  {"cluster_id":"zzz","severity":"critical"}
]'
assert_eq "differing severity -> critical id wins (over lexicographically smaller ids)" "zzz" "$PICK_OUT"
assert_rc_zero "differing severity -> success rc" "$PICK_RC"

# medium beats low, high beats medium (full ordering critical>high>medium>low).
run_pick '[
  {"cluster_id":"zzz","severity":"medium"},
  {"cluster_id":"aaa","severity":"low"}
]'
assert_eq "medium outranks low" "zzz" "$PICK_OUT"
run_pick '[
  {"cluster_id":"zzz","severity":"high"},
  {"cluster_id":"aaa","severity":"medium"}
]'
assert_eq "high outranks medium" "zzz" "$PICK_OUT"

# ===========================================================================
# AC: severity tie broken by higher confidence.
# Higher-confidence record ("zzz", 0.9) has the lexicographically LARGER id,
# so confidence must dominate the id tiebreak.
# ===========================================================================
run_pick '[
  {"cluster_id":"aaa","severity":"high","confidence":0.4},
  {"cluster_id":"zzz","severity":"high","confidence":0.9}
]'
assert_eq "severity tie -> higher confidence wins (over lexicographically smaller id)" "zzz" "$PICK_OUT"

# ===========================================================================
# AC: severity+confidence tie broken by lexicographically smallest id, AND the
# result is stable regardless of input order (verify by shuffling/reversing).
# ===========================================================================
TIE_BASE='[
  {"cluster_id":"cluster-b","severity":"high","confidence":0.5},
  {"cluster_id":"cluster-a","severity":"high","confidence":0.5},
  {"cluster_id":"cluster-c","severity":"high","confidence":0.5}
]'
run_pick "$TIE_BASE"
assert_eq "full tie -> lexicographically smallest id" "cluster-a" "$PICK_OUT"

run_pick "$(jq 'reverse' <<<"$TIE_BASE")"
assert_eq "determinism: reversed input -> same canonical" "cluster-a" "$PICK_OUT"

# A second, hand-written reordering (c, a, b) must yield the same result.
run_pick '[
  {"cluster_id":"cluster-c","severity":"high","confidence":0.5},
  {"cluster_id":"cluster-a","severity":"high","confidence":0.5},
  {"cluster_id":"cluster-b","severity":"high","confidence":0.5}
]'
assert_eq "determinism: another ordering -> same canonical" "cluster-a" "$PICK_OUT"

# ===========================================================================
# AC: missing/absent/null/unparseable confidence treated as lowest; the helper
# must never crash. Present-but-tiny confidence (0.1) beats the missing one even
# though the present record's id sorts LATER.
# ===========================================================================
run_pick '[
  {"cluster_id":"aaa-null","severity":"high","confidence":null},
  {"cluster_id":"zzz-has","severity":"high","confidence":0.1}
]'
assert_eq "present confidence beats null confidence (at equal severity)" "zzz-has" "$PICK_OUT"
assert_rc_zero "null confidence does not crash" "$PICK_RC"

run_pick '[
  {"cluster_id":"aaa-absent","severity":"high"},
  {"cluster_id":"zzz-has","severity":"high","confidence":0.1}
]'
assert_eq "present confidence beats absent confidence key" "zzz-has" "$PICK_OUT"
assert_rc_zero "absent confidence key does not crash" "$PICK_RC"

run_pick '[
  {"cluster_id":"aaa-garbage","severity":"high","confidence":"abc"},
  {"cluster_id":"zzz-has","severity":"high","confidence":0.1}
]'
assert_eq "present confidence beats unparseable (\"abc\") confidence" "zzz-has" "$PICK_OUT"
assert_rc_zero "unparseable confidence does not crash" "$PICK_RC"

# Two missing-confidence records at equal severity fall through to the id tiebreak.
run_pick '[
  {"cluster_id":"bbb","severity":"high"},
  {"cluster_id":"aaa","severity":"high"}
]'
assert_eq "two missing-confidence records -> id tiebreak (smallest id)" "aaa" "$PICK_OUT"

# ===========================================================================
# AC: reuses severity_normalize (does not reimplement severity ranking).
# A bracketed "[CRITICAL]" and an uppercase "HIGH" only outrank their bare
# competitors if they flow through severity_normalize; their ids are the LARGER
# ones, so they cannot win by the id tiebreak.
# ===========================================================================
run_pick '[
  {"cluster_id":"zzz-bracket-crit","severity":"[CRITICAL]"},
  {"cluster_id":"aaa-high","severity":"high"}
]'
assert_eq "normalization reused: '[CRITICAL]' outranks bare 'high'" "zzz-bracket-crit" "$PICK_OUT"

run_pick '[
  {"cluster_id":"zzz-upper-high","severity":"HIGH"},
  {"cluster_id":"aaa-low","severity":"low"}
]'
assert_eq "normalization reused: uppercase 'HIGH' outranks 'low'" "zzz-upper-high" "$PICK_OUT"

# ===========================================================================
# AC: invalid/missing severity -> rank lowest (never crashes), still selectable.
# An invalid severity must lose to a real 'medium' even with higher confidence
# and a smaller id — proving invalid severity sinks to the bottom rank.
# ===========================================================================
run_pick '[
  {"cluster_id":"aaa-invalid","severity":"banana","confidence":0.9},
  {"cluster_id":"zzz-medium","severity":"medium","confidence":0.1}
]'
assert_eq "invalid severity ranks below a valid 'medium'" "zzz-medium" "$PICK_OUT"
assert_rc_zero "invalid severity does not crash" "$PICK_RC"

# When ALL severities are invalid, they tie at the bottom rank and confidence
# still orders them — never crashing.
run_pick '[
  {"cluster_id":"aaa","severity":"banana","confidence":0.2},
  {"cluster_id":"zzz","severity":"","confidence":0.9}
]'
assert_eq "all-invalid severity -> confidence still orders (rank-0 tie)" "zzz" "$PICK_OUT"
assert_rc_zero "all-invalid severity does not crash" "$PICK_RC"

# ===========================================================================
# Single-record group -> returns that record's id.
# ===========================================================================
run_pick '[{"cluster_id":"only-one","severity":"medium","confidence":0.7}]'
assert_eq "single-record group returns its id" "only-one" "$PICK_OUT"
assert_rc_zero "single-record group -> success rc" "$PICK_RC"

# ===========================================================================
# Edge: empty array / non-array / invalid JSON -> non-zero rc, empty stdout.
# ===========================================================================
run_pick '[]'
assert_rc_nonzero "empty array -> non-zero rc" "$PICK_RC"
assert_empty "empty array -> no stdout" "$PICK_OUT"

run_pick '{"cluster_id":"x","severity":"high"}'
assert_rc_nonzero "non-array (object) -> non-zero rc" "$PICK_RC"
assert_empty "non-array (object) -> no stdout" "$PICK_OUT"

run_pick 'not-valid-json'
assert_rc_nonzero "invalid JSON -> non-zero rc" "$PICK_RC"
assert_empty "invalid JSON -> no stdout" "$PICK_OUT"

# ===========================================================================
# Generality: works on real manifest.json shape (cluster_id default, no
# confidence) AND on findings.jsonl shape (id field + numeric confidence) when
# the id_field argument is passed.
# ===========================================================================
run_pick '[
  {"cluster_id":"cl-2","severity":"high","title":"X","source_finding_paths":["a"]},
  {"cluster_id":"cl-1","severity":"critical","title":"Y","source_finding_paths":["b"]}
]'
assert_eq "manifest shape (default cluster_id, no confidence) -> critical id" "cl-1" "$PICK_OUT"

run_pick '[
  {"id":"fnd-aaa","severity":"high","confidence":0.3},
  {"id":"fnd-bbb","severity":"high","confidence":0.8}
]' "id"
assert_eq "findings.jsonl shape with id_field=\"id\" -> higher-confidence id" "fnd-bbb" "$PICK_OUT"

# ===========================================================================
# Edge: empty / absent argument (distinct from empty-ARRAY "[]"). An empty or
# missing argument string short-circuits BEFORE the jq array guard — a separate
# branch from the [] / {} / invalid-JSON edges above. Contract pins only
# "non-zero rc, empty stdout"; the concrete code is the implementer's choice.
# ===========================================================================
run_pick ''
assert_rc_nonzero "empty-string argument -> non-zero rc" "$PICK_RC"
assert_empty "empty-string argument -> no stdout" "$PICK_OUT"

# Called with no positional argument at all is equally safe (never crashes).
PICK_OUT="$(_dedupe_pick_canonical)"; PICK_RC=$?
assert_rc_nonzero "no argument at all -> non-zero rc" "$PICK_RC"
assert_empty "no argument at all -> no stdout" "$PICK_OUT"

# ===========================================================================
# AC (missing=lowest), present-side: a legitimate confidence of 0 is PRESENT,
# not missing. The helper distinguishes "absent/null" from a real numeric 0, so
# a record with confidence 0 must outrank an absent-confidence sibling at equal
# severity (present tier beats missing tier). Winner's id is the LARGER one, so
# the present-tier rule — not the id tiebreak — is what decides.
# ===========================================================================
run_pick '[
  {"cluster_id":"aaa-absent","severity":"high"},
  {"cluster_id":"zzz-zero","severity":"high","confidence":0}
]'
assert_eq "present confidence 0 beats absent confidence (0 is present, not missing)" "zzz-zero" "$PICK_OUT"
assert_rc_zero "confidence 0 does not crash" "$PICK_RC"

# ...but a present 0 still loses to a higher present confidence on the numeric
# key. Winner (0.5) carries the LARGER id, so confidence — not id — must decide.
run_pick '[
  {"cluster_id":"aaa-zero","severity":"high","confidence":0},
  {"cluster_id":"zzz-half","severity":"high","confidence":0.5}
]'
assert_eq "present confidence 0 loses to higher present confidence" "zzz-half" "$PICK_OUT"

# ===========================================================================
# AC (missing=lowest), negative-magnitude case: the present/missing tiering is
# robust to magnitude — a negative confidence is still PRESENT, so it outranks
# an absent/null sibling (this is exactly why the helper uses a has-confidence
# tier rather than a numeric sentinel that a negative value could defeat).
# Winner's id is the LARGER one, proving the present tier decides.
# ===========================================================================
run_pick '[
  {"cluster_id":"aaa-null","severity":"high","confidence":null},
  {"cluster_id":"zzz-neg","severity":"high","confidence":-0.3}
]'
assert_eq "negative confidence is present -> beats null confidence" "zzz-neg" "$PICK_OUT"
assert_rc_zero "negative confidence does not crash" "$PICK_RC"

# A negative confidence still loses to a positive one on the numeric key; the
# positive winner carries the LARGER id, so confidence — not id — decides.
run_pick '[
  {"cluster_id":"aaa-neg","severity":"high","confidence":-0.3},
  {"cluster_id":"zzz-pos","severity":"high","confidence":0.2}
]'
assert_eq "positive confidence outranks negative confidence" "zzz-pos" "$PICK_OUT"

# ===========================================================================
# AC (reuses confidence parsing): a decimal authored without a leading zero
# (".5") is still recognized as a present numeric. This exercises the second
# decimal-form branch of the confidence parser, which the leading-zero fixtures
# above never reach. It must beat an absent-confidence sibling at equal
# severity; the winner's id is the LARGER one, so present-tier — not id —
# decides.
# ===========================================================================
run_pick '[
  {"cluster_id":"aaa-absent","severity":"high"},
  {"cluster_id":"zzz-dot","severity":"high","confidence":".5"}
]'
assert_eq "leading-dot decimal \".5\" parsed as present -> beats absent confidence" "zzz-dot" "$PICK_OUT"
assert_rc_zero "leading-dot decimal confidence does not crash" "$PICK_RC"

finish
