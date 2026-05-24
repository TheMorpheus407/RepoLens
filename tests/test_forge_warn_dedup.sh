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

# Tests for issue #246 — _forge_warn dedup wrapper.
#
# Behavioral contract:
#   - _forge_warn deduplicates identical (caller, message) tuples within a
#     single shell process. The first emission reaches stderr / the run log;
#     subsequent identical emissions are silently counted in an in-memory
#     associative map (_FORGE_WARN_SEEN) keyed on "FUNCNAME[1]:$*".
#   - Distinct keys are NOT collapsed: two different messages (or the same
#     message from two callers) still produce two stderr lines.
#   - The counter accumulates across calls and survives a re-source of
#     lib/forge.sh — the array is declared with a re-source guard so test
#     and operational paths that re-source mid-run don't zero the state.
#   - The wrapper is safe under `set -uo pipefail`: the first call (where
#     the array slot is unset) must not trigger an unbound-variable crash.
#   - The stderr-only fallback path (log_warn undefined) also dedups, so
#     standalone usage outside repolens.sh gets the same benefit.
#
# All forge calls are PATH-shadowed with fake stubs. No real forge call is
# made, and no agent command is invoked.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
TOTAL=0
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (expected='$expected' actual='$actual')"
  fi
}

# shellcheck disable=SC2329
assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (expected to contain '$needle'; got '${haystack:0:200}')"
  fi
}

echo ""
echo "=== Test Suite: _forge_warn dedup (issue #246) ==="
echo ""

[[ -f "$SCRIPT_DIR/lib/forge.sh" ]] || { echo "FAIL: lib/forge.sh missing"; exit 1; }
[[ -f "$SCRIPT_DIR/lib/core.sh" ]]  || { echo "FAIL: lib/core.sh missing"; exit 1; }
[[ -f "$SCRIPT_DIR/lib/logging.sh" ]] || { echo "FAIL: lib/logging.sh missing"; exit 1; }

FAKE_BIN="$TMPDIR/bin"
FORGE_TEST_PROJECT="$TMPDIR/audited-project"
mkdir -p "$FAKE_BIN"
mkdir -p "$FORGE_TEST_PROJECT"

# Persistent gh failure stub — the exact failure mode that triggered #246
# (rate-limited / auth revoked / wrong slug all look identical from here).
cat > "$FAKE_BIN/gh" <<'SH'
#!/usr/bin/env bash
printf 'HTTP 403: API rate limit exceeded\n' >&2
exit 1
SH
chmod +x "$FAKE_BIN/gh"

# ---------------------------------------------------------------------------
# Test 1: 100 calls with persistent failure produce ONE stderr emission
# ---------------------------------------------------------------------------
echo "Test 1: 100 sequential identical failures emit the warning exactly once"
err_file="$TMPDIR/t1.err"
# shellcheck disable=SC2030,SC2031
(
  export PATH="$FAKE_BIN:/usr/bin:/bin:$PATH"
  export FORGE_PROVIDER=gh
  export FORGE_PROJECT_PATH="$FORGE_TEST_PROJECT"
  set -uo pipefail
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/core.sh"
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/logging.sh"
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/forge.sh"
  for _ in $(seq 1 100); do
    # Discard stdout (empty on failure); let stderr propagate to the outer
    # capture below so we can count the dedup'd warning lines.
    forge_issue_list_count owner/repo audit:demo >/dev/null || true
  done
) 2>"$err_file"
warning_count=$(grep -c 'forge_issue_list_count: gh failed' "$err_file" 2>/dev/null || true)
warning_count="${warning_count:-0}"
assert_eq "exactly one '[WARN] ... gh failed' line for 100 identical failures" "1" "$warning_count"

# ---------------------------------------------------------------------------
# Test 2: dedup counter map accumulates the suppressed count
# ---------------------------------------------------------------------------
echo ""
echo "Test 2: _FORGE_WARN_SEEN accumulates to 100 across the suppressed copies"
total_file="$TMPDIR/t2.total"
# shellcheck disable=SC2030,SC2031
(
  export PATH="$FAKE_BIN:/usr/bin:/bin:$PATH"
  export FORGE_PROVIDER=gh
  export FORGE_PROJECT_PATH="$FORGE_TEST_PROJECT"
  set -uo pipefail
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/core.sh"
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/logging.sh"
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/forge.sh"
  for _ in $(seq 1 100); do
    forge_issue_list_count owner/repo audit:demo >/dev/null 2>/dev/null || true
  done
  total=0
  for k in "${!_FORGE_WARN_SEEN[@]}"; do
    # shellcheck disable=SC2004
    total=$((total + _FORGE_WARN_SEEN[$k]))
  done
  printf '%s' "$total"
) > "$total_file" 2>/dev/null
total_count="$(cat "$total_file" 2>/dev/null || true)"
assert_eq "_FORGE_WARN_SEEN total equals the number of suppressed calls" "100" "$total_count"

# ---------------------------------------------------------------------------
# Test 3: distinct messages produce distinct warnings (no over-dedup)
# ---------------------------------------------------------------------------
echo ""
echo "Test 3: two distinct messages each emit exactly once"
err_file="$TMPDIR/t3.err"
(
  set -uo pipefail
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/core.sh"
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/logging.sh"
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/forge.sh"
  for _ in $(seq 1 10); do
    _forge_warn "issue246-marker-A first failure mode"
    _forge_warn "issue246-marker-B second failure mode"
  done
) 2>"$err_file"
first_count=$(grep -c 'issue246-marker-A' "$err_file" 2>/dev/null || true)
second_count=$(grep -c 'issue246-marker-B' "$err_file" 2>/dev/null || true)
first_count="${first_count:-0}"
second_count="${second_count:-0}"
assert_eq "first distinct message emitted exactly once" "1" "$first_count"
assert_eq "second distinct message emitted exactly once" "1" "$second_count"

# ---------------------------------------------------------------------------
# Test 4: re-source of lib/forge.sh does not reset the counter
# ---------------------------------------------------------------------------
echo ""
echo "Test 4: counter survives re-source of lib/forge.sh"
result_file="$TMPDIR/t4.result"
(
  set -uo pipefail
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/core.sh"
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/logging.sh"
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/forge.sh"
  _forge_warn "issue246-resourceA persistent failure"
  _forge_warn "issue246-resourceA persistent failure"
  _forge_warn "issue246-resourceA persistent failure"
  # Re-sourcing mid-run (tests do this; some operational paths might too)
  # must NOT clobber the accumulated counts.
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/forge.sh"
  _forge_warn "issue246-resourceA persistent failure"
  _forge_warn "issue246-resourceA persistent failure"
  for k in "${!_FORGE_WARN_SEEN[@]}"; do
    if [[ "$k" == *"issue246-resourceA"* ]]; then
      printf '%s' "${_FORGE_WARN_SEEN[$k]}"
    fi
  done
) > "$result_file" 2>/dev/null
final_count="$(cat "$result_file" 2>/dev/null || true)"
assert_eq "counter accumulates across re-source (3 + 2 = 5)" "5" "$final_count"

# ---------------------------------------------------------------------------
# Test 5: wrapper is safe under set -uo pipefail (first-call array slot is unset)
# ---------------------------------------------------------------------------
echo ""
echo "Test 5: first call under set -u does not crash; repeated identical calls dedup"
err_file="$TMPDIR/t5.err"
marker_file="$TMPDIR/t5.marker"
(
  set -uo pipefail
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/core.sh"
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/logging.sh"
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/forge.sh"
  _forge_warn "issue246-setu first ever call"
  _forge_warn "issue246-setu first ever call"
  _forge_warn "issue246-setu first ever call"
  printf 'survived\n' > "$marker_file"
) 2>"$err_file"
marker_content=""
[[ -f "$marker_file" ]] && marker_content="$(cat "$marker_file")"
emit_count=$(grep -c 'issue246-setu first ever call' "$err_file" 2>/dev/null || true)
emit_count="${emit_count:-0}"
assert_eq "subshell ran past three sequential calls without set -u crash" "survived" "$marker_content"
assert_eq "three identical calls emit exactly one stderr line" "1" "$emit_count"

# ---------------------------------------------------------------------------
# Test 6: stderr-only fallback path (log_warn undefined) also dedups
# ---------------------------------------------------------------------------
echo ""
echo "Test 6: standalone usage (no log_warn) still dedups via the stderr fallback"
err_file="$TMPDIR/t6.err"
sanity_file="$TMPDIR/t6.sanity"
(
  set -uo pipefail
  # Defensive: some interactive bash sessions export log_warn into the
  # environment of `bash` child processes. CI runs in a clean env do not,
  # but unsetting it here makes the test deterministic regardless.
  unset -f log_warn 2>/dev/null || true
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/core.sh"
  # Intentionally do NOT source logging.sh — log_warn must be undefined.
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/forge.sh"
  if declare -F log_warn >/dev/null 2>&1; then
    printf 'log_warn-defined\n' > "$sanity_file"
  else
    printf 'log_warn-undefined\n' > "$sanity_file"
  fi
  for _ in $(seq 1 25); do
    _forge_warn "issue246-fallback standalone path warning"
  done
) 2>"$err_file"
sanity="$(cat "$sanity_file" 2>/dev/null || true)"
emit_count=$(grep -c 'issue246-fallback' "$err_file" 2>/dev/null || true)
emit_count="${emit_count:-0}"
assert_eq "test 6 sanity: log_warn is unavailable on the fallback path" "log_warn-undefined" "$sanity"
assert_eq "stderr-only fallback emits a single [WARN] line for 25 identical calls" "1" "$emit_count"

# ---------------------------------------------------------------------------
# Test 7: distinct callers with the same message produce TWO entries
# (the dedup key is "FUNCNAME[1]:$*", not just "$*" — collapsing on message
# alone would hide the fact that two distinct call sites are failing).
# ---------------------------------------------------------------------------
echo ""
echo "Test 7: same message from two distinct callers emits twice and yields two keys"
err_file="$TMPDIR/t7.err"
result_file="$TMPDIR/t7.result"
(
  set -uo pipefail
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/core.sh"
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/logging.sh"
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/forge.sh"
  caller_alpha() { _forge_warn "issue246-shared persistent failure"; }
  caller_beta()  { _forge_warn "issue246-shared persistent failure"; }
  for _ in $(seq 1 10); do
    caller_alpha
    caller_beta
  done
  alpha_seen=0
  beta_seen=0
  total=0
  for k in "${!_FORGE_WARN_SEEN[@]}"; do
    if [[ "$k" == caller_alpha:* ]]; then
      alpha_seen="${_FORGE_WARN_SEEN[$k]}"
    elif [[ "$k" == caller_beta:* ]]; then
      beta_seen="${_FORGE_WARN_SEEN[$k]}"
    fi
    # shellcheck disable=SC2004
    total=$((total + _FORGE_WARN_SEEN[$k]))
  done
  printf '%s %s %s' "$alpha_seen" "$beta_seen" "$total" > "$result_file"
) 2>"$err_file"
read -r alpha_count beta_count grand_total < "$result_file"
emit_count=$(grep -c 'issue246-shared persistent failure' "$err_file" 2>/dev/null || true)
emit_count="${emit_count:-0}"
assert_eq "two distinct callers emit two warning lines (one per caller)" "2" "$emit_count"
assert_eq "caller_alpha counter accumulates to 10" "10" "$alpha_count"
assert_eq "caller_beta counter accumulates to 10" "10" "$beta_count"
assert_eq "grand total across both caller keys is 20" "20" "$grand_total"

# ---------------------------------------------------------------------------
# Test 8: finalize-time rollup block emits a header plus one line per key
# (issue #246 added this block to repolens.sh). The block is extracted from
# the live repolens.sh and eval'd here so we exercise the real production
# code, not a copy of it.
# ---------------------------------------------------------------------------
echo ""
echo "Test 8: rollup block emits header + sorted per-key lines with counts"
ROLLUP_SNIPPET="$TMPDIR/rollup.sh"
sed -n '/^if declare -p _FORGE_WARN_SEEN/,/^fi$/p' "$SCRIPT_DIR/repolens.sh" > "$ROLLUP_SNIPPET"
# Sanity-check the snippet was actually extracted; otherwise later asserts
# would silently degrade into "nothing emitted" without explaining why.
snippet_lines=$(wc -l < "$ROLLUP_SNIPPET" | tr -d ' ')
assert_eq "rollup snippet was extracted from repolens.sh (>= 5 lines)" "ok" \
  "$([[ "${snippet_lines:-0}" -ge 5 ]] && echo ok || echo missing)"

out_file="$TMPDIR/t8.out"
(
  set -uo pipefail
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/core.sh"
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/logging.sh"
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/forge.sh"
  # Populate three distinct keys with distinct counts so we can verify both
  # the per-key line format and the deterministic LC_ALL=C sort ordering.
  _FORGE_WARN_SEEN["alpha:msg-A"]=7
  _FORGE_WARN_SEEN["bravo:msg-B"]=3
  _FORGE_WARN_SEEN["charlie:msg-C"]=42
  # shellcheck source=/dev/null
  source "$ROLLUP_SNIPPET"
) > "$out_file" 2>/dev/null
header_count=$(grep -c 'Forge warning rollup (deduped):' "$out_file" 2>/dev/null || true)
header_count="${header_count:-0}"
alpha_line=$(grep -c 'alpha:msg-A — 7 times' "$out_file" 2>/dev/null || true)
alpha_line="${alpha_line:-0}"
bravo_line=$(grep -c 'bravo:msg-B — 3 times' "$out_file" 2>/dev/null || true)
bravo_line="${bravo_line:-0}"
charlie_line=$(grep -c 'charlie:msg-C — 42 times' "$out_file" 2>/dev/null || true)
charlie_line="${charlie_line:-0}"
assert_eq "rollup header emitted exactly once" "1" "$header_count"
assert_eq "rollup line for alpha key with count 7 present" "1" "$alpha_line"
assert_eq "rollup line for bravo key with count 3 present" "1" "$bravo_line"
assert_eq "rollup line for charlie key with count 42 present" "1" "$charlie_line"

# Verify deterministic LC_ALL=C alphabetical ordering: alpha < bravo < charlie.
# We grep only the rollup key lines and compare against an expected sort.
key_lines=$(grep -E '(alpha|bravo|charlie):msg-' "$out_file" || true)
expected_order=$(printf '%s\n' "$key_lines" | LC_ALL=C sort)
assert_eq "rollup lines are emitted in LC_ALL=C sorted order" "$expected_order" "$key_lines"

# ---------------------------------------------------------------------------
# Test 9: rollup block is silent when no forge warnings have fired
# (the `(( ${#_FORGE_WARN_SEEN[@]} > 0 ))` guard — operators shouldn't see a
# header with zero items on clean runs).
# ---------------------------------------------------------------------------
echo ""
echo "Test 9: rollup is silent when _FORGE_WARN_SEEN is empty"
out_file="$TMPDIR/t9.out"
(
  set -uo pipefail
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/core.sh"
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/logging.sh"
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/forge.sh"
  # Do NOT call _forge_warn — the map is declared empty by the re-source guard.
  # shellcheck source=/dev/null
  source "$ROLLUP_SNIPPET"
) > "$out_file" 2>/dev/null
rollup_noise=$(grep -c 'Forge warning rollup' "$out_file" 2>/dev/null || true)
rollup_noise="${rollup_noise:-0}"
any_output=$(wc -c < "$out_file" | tr -d ' ')
assert_eq "rollup header not emitted when no warnings fired" "0" "$rollup_noise"
assert_eq "rollup block produces no output at all when map is empty" "0" "$any_output"

echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
