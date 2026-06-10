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

# Tests for issue #224: role-tagged dispatch parser + GENERIC dispatch flavor.
# shellcheck disable=SC2034,SC2329

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/streak.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/summary.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/template.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/rounds.sh"

PASS=0
FAIL=0
TOTAL=0

TMP_PARENT="$SCRIPT_DIR/logs/test-rounds-meta-parse-role"
mkdir -p "$TMP_PARENT"
TMPDIR="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"

cleanup() {
  rm -rf "$TMPDIR"
  rmdir "$TMP_PARENT" 2>/dev/null || true
}
trap cleanup EXIT

pass_with() {
  local desc="$1"
  PASS=$((PASS + 1))
  echo "  PASS: $desc"
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
    fail_with "$desc" "Expected: $expected | Actual: $actual"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected to find: $needle"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Did not expect to find: $needle"
  fi
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

write_lens() {
  local domain="$1" lens="$2" dir
  dir="$TMPDIR/lenses/$domain"
  mkdir -p "$dir"
  cat > "$dir/$lens.md" <<EOF
---
id: $lens
domain: $domain
name: $lens
role: tester
---
## Your Expert Focus
Test lens.
EOF
}

log_info() { LOG_LINES+=("INFO:$*"); }
log_warn() { LOG_LINES+=("WARN:$*"); }

echo "=== role-tagged dispatch parser (issue #224) ==="

write_lens security injection
write_lens database data-integrity
LENSES_DIR="$TMPDIR/lenses"
MODE="audit"
LOG_LINES=()

echo ""
echo "Test 1: extract_kv handles token, double-quoted, single-quoted, and backtick values"
input='role=deeper focus=`lib/db.dart:142` anchor=finding-1 missed_angle="auth callback ordering" notes='\''quoted notes'\'''
val_role="$(_rounds_meta_extract_kv role "$input" || printf 'MISSING')"
val_focus="$(_rounds_meta_extract_kv focus "$input" || printf 'MISSING')"
val_anchor="$(_rounds_meta_extract_kv anchor "$input" || printf 'MISSING')"
val_missed="$(_rounds_meta_extract_kv missed_angle "$input" || printf 'MISSING')"
val_notes="$(_rounds_meta_extract_kv notes "$input" || printf 'MISSING')"
val_missing="$(_rounds_meta_extract_kv unknown "$input" || printf 'MISSING')"
assert_eq "extract_kv role from token" "deeper" "$val_role"
assert_eq "extract_kv focus from backtick" "lib/db.dart:142" "$val_focus"
assert_eq "extract_kv anchor from token" "finding-1" "$val_anchor"
assert_eq "extract_kv missed_angle from quoted" "auth callback ordering" "$val_missed"
assert_eq "extract_kv notes from single-quoted" "quoted notes" "$val_notes"
assert_eq "extract_kv returns MISSING for absent key" "MISSING" "$val_missing"

echo ""
echo "Test 2: tuple serialize round-trips fields"
tuple="$(_rounds_meta_tuple_serialize "security/injection" "deeper" "lib/db.dart:142" "finding-1" "f1,f2")"
assert_eq "tuple serialize encodes all fields" \
  "security/injection|deeper|lib/db.dart:142|finding-1|f1,f2" "$tuple"

entry=""; role=""; focus=""; anchor=""; exclude=""
_rounds_meta_tuple_parse "$tuple" entry role focus anchor exclude
assert_eq "tuple parse extracts entry" "security/injection" "$entry"
assert_eq "tuple parse extracts role" "deeper" "$role"
assert_eq "tuple parse extracts focus" "lib/db.dart:142" "$focus"
assert_eq "tuple parse extracts anchor" "finding-1" "$anchor"
assert_eq "tuple parse extracts exclude" "f1,f2" "$exclude"

bare="$(_rounds_meta_tuple_serialize "security/injection" "" "" "" "")"
assert_eq "tuple serialize emits bare entry when no meta" "security/injection" "$bare"

entry=""; role=""; focus=""; anchor=""; exclude=""
_rounds_meta_tuple_parse "security/injection" entry role focus anchor exclude
assert_eq "tuple parse handles bare entry" "security/injection" "$entry"
assert_eq "tuple parse leaves role empty for bare entry" "" "$role"

echo ""
echo "Test 3: parser preserves role/focus/anchor/exclude on LENS"
REPOLENS_META_ORCH_DISPATCH_CAP=4
cat > "$TMPDIR/meta-role.txt" <<'EOF'
## Round 2 dispatch plan
- LENS: injection role=deeper focus=`lib/db.dart:142` anchor=finding-1 - drill into a prior cluster.
- LENS: injection role=broader missed_angle="alternative auth path" exclude=f1,f2 - widen the search.
- GENERIC: role=broader missed_angle="auth callback ordering" exclude=f3 - generic broader investigator.
- CUSTOM: auth-followup role=broader missed_angle="token refresh" - `lib/auth.sh:12`; rationale.
  Draft prompt:
  Investigate token refresh path.
EOF

_rounds_meta_parse_output "$TMPDIR/meta-role.txt" "$TMPDIR/dispatch.md" "$TMPDIR/hypotheses.md" "$LENSES_DIR"
rc=$?
dispatch="$(cat "$TMPDIR/dispatch.md")"
assert_eq "role-tagged parse exits successfully" "0" "$rc"
assert_contains "dispatch keeps deeper LENS line" "LENS: injection role=deeper" "$dispatch"
assert_contains "dispatch keeps focus key on deeper LENS" "focus=lib/db.dart:142" "$dispatch"
assert_contains "dispatch keeps anchor key on deeper LENS" "anchor=finding-1" "$dispatch"
assert_contains "dispatch keeps broader LENS line" "LENS: injection role=broader" "$dispatch"
assert_contains "dispatch keeps missed_angle on broader LENS (as focus)" "focus=\"alternative auth path\"" "$dispatch"
assert_contains "dispatch keeps exclude on broader LENS" "exclude=f1,f2" "$dispatch"
assert_contains "dispatch recognizes GENERIC line" "GENERIC: role=broader" "$dispatch"
assert_contains "dispatch keeps missed_angle on GENERIC" "focus=\"auth callback ordering\"" "$dispatch"
assert_contains "dispatch keeps exclude on GENERIC" "exclude=f3" "$dispatch"
assert_contains "dispatch keeps CUSTOM directive" "CUSTOM: auth-followup" "$dispatch"
assert_contains "dispatch preserves CUSTOM draft prompt" "Investigate token refresh path" "$dispatch"
unset REPOLENS_META_ORCH_DISPATCH_CAP

echo ""
echo "Test 4: parser still accepts flat LENS (backward compatibility)"
cat > "$TMPDIR/meta-flat.txt" <<'EOF'
## Round 2 dispatch plan
LENS: injection
LENS: data-integrity
EOF
_rounds_meta_parse_output "$TMPDIR/meta-flat.txt" "$TMPDIR/dispatch-flat.md" "$TMPDIR/hypotheses-flat.md" "$LENSES_DIR"
rc=$?
flat_dispatch="$(cat "$TMPDIR/dispatch-flat.md")"
assert_eq "flat parse exits successfully" "0" "$rc"
assert_contains "flat dispatch keeps bare LENS line for injection" $'\nLENS: injection\n' $'\n'"$flat_dispatch"$'\n'
assert_contains "flat dispatch keeps bare LENS line for data-integrity" "LENS: data-integrity" "$flat_dispatch"

echo ""
echo "Test 5: parser preserves multiple same-lens dispatches with different focus"
cat > "$TMPDIR/meta-dup.txt" <<'EOF'
## Round 2 dispatch plan
- LENS: injection role=deeper focus=`lib/db.dart:142` - dispatch A.
- LENS: injection role=deeper focus=`lib/db.dart:200` - dispatch B.
EOF
_rounds_meta_parse_output "$TMPDIR/meta-dup.txt" "$TMPDIR/dispatch-dup.md" "$TMPDIR/hypotheses-dup.md" "$LENSES_DIR"
dup_dispatch="$(cat "$TMPDIR/dispatch-dup.md")"
count_a="$(grep -c 'focus=lib/db.dart:142' "$TMPDIR/dispatch-dup.md" || printf '0')"
count_b="$(grep -c 'focus=lib/db.dart:200' "$TMPDIR/dispatch-dup.md" || printf '0')"
assert_eq "dispatch keeps first focus dispatch" "1" "$count_a"
assert_eq "dispatch keeps second focus dispatch (not deduped)" "1" "$count_b"

echo ""
echo "Test 6: dispatch readers emit tuple-shaped entries"
cat > "$TMPDIR/dispatch-read.md" <<'EOF'
# Meta-Orchestrator Dispatch

LENS: injection
LENS: injection role=deeper focus=lib/db.dart:142 anchor=finding-1
GENERIC: role=broader missed_angle="auth ordering" exclude=f1,f2
EOF

lens_entries="$(_rounds_meta_dispatch_lens_entries "$TMPDIR/dispatch-read.md" "$LENSES_DIR")"
generic_entries="$(_rounds_meta_dispatch_generic_entries "$TMPDIR/dispatch-read.md")"
has_entries=0
if _rounds_meta_dispatch_has_entries "$TMPDIR/dispatch-read.md"; then has_entries=1; fi

assert_contains "lens reader emits bare entry for flat LENS" $'\nsecurity/injection\n' $'\n'"$lens_entries"$'\n'
assert_contains "lens reader emits tuple for role-tagged LENS" "security/injection|deeper|lib/db.dart:142|finding-1|" "$lens_entries"
assert_contains "generic reader emits tuple-shaped entry" "generic/broader-auth-ordering|broader|auth ordering|" "$generic_entries"
assert_eq "dispatch_has_entries detects GENERIC line" "1" "$has_entries"

echo ""
echo "Test 7: custom dispatch readers preserve role/focus on tuple"
mkdir -p "$TMPDIR/custom-out"
cat > "$TMPDIR/dispatch-custom.md" <<'EOF'
# Meta-Orchestrator Dispatch

CUSTOM: auth-followup role=broader missed_angle="token refresh" - `lib/auth.sh:1`; rationale.
  Draft prompt:
  Investigate token refresh path without rediscovering prior suspect sites.
EOF
custom_entries="$(_rounds_meta_dispatch_custom_entries "$TMPDIR/dispatch-custom.md" "$TMPDIR/custom-out")"
assert_contains "custom reader keeps role+focus on tuple" "custom/auth-followup|broader|token refresh|" "$custom_entries"

finish
