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

# Tests for issue #341: render final/HUMAN_REVIEW.md from the bucketed findings
# at finalize time. Pure-function tests only; NO AI models are invoked — every
# input is a handwritten JSON-Lines fixture and the renderer is pure jq + bash.
#
# Contract under test (from the issue acceptance criteria + research):
#
#   render_human_review_digest <run_id>
#     Reads logs/<run-id>/final/findings.jsonl via human_review_bucketize and
#     writes logs/<run-id>/final/HUMAN_REVIEW.md atomically (exclusive mktemp
#     stage, then exact-path replacement).
#     Honors $LOG_BASE for path resolution (so the test drives it by setting
#     LOG_BASE and dropping a fixture findings.jsonl). It RENDERS only — never
#     builds/mutates the registry, never invokes a model.
#
#   SECTIONS (fixed order): a short header (run id + totals), Top Critical/High,
#   Top Medium Security, Test & Quality (own section), Not actionable without a
#   scanner (own section), and a placeholder/anchor for the themed remainder.
#
#   Each finding line uses registry fields: severity, domain/lens, a title, and
#   primary_location; links to markdown_path when present.
#
#   DEFENSIVE: a null/empty field renders as an em dash, never the literal
#   "null"; a null/empty markdown_path emits NO link (never a broken "[]()").
#   Fields are emitted verbatim by jq, so a title with backticks / $(...) / pipes
#   is data, never shell-evaluated.
#
#   EMPTY / MISSING registry -> valid "nothing to review" digest, rc 0.
#
#   GATE (repolens.sh finalize hook): the digest is written only when
#   HUMAN_REVIEW == true AND findings.jsonl exists; the call is non-fatal and
#   never flips REPOLENS_FINAL_STATE / RUN_ROUNDS_RC. We assert the renderer's
#   public behavior directly and the finalize gate by replicating the guard plus
#   a static check of the wiring in repolens.sh (running repolens.sh itself would
#   invoke real agents — forbidden by the test rules).

# shellcheck disable=SC2030,SC2031 # Subshell-local test state is intentional.
set -uo pipefail
# shellcheck disable=SC2329  # helper functions are invoked indirectly

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_LIB="$SCRIPT_DIR/lib/core.sh"
RISK_LIB="$SCRIPT_DIR/lib/risk.sh"
HUMAN_REVIEW_LIB="$SCRIPT_DIR/lib/human_review.sh"
REPOLENS_SH="$SCRIPT_DIR/repolens.sh"

PASS=0
FAIL=0
TOTAL=0

TMP_PARENT="$SCRIPT_DIR/logs/test-human-review-render"
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

assert_rc_nonzero() {
  local desc="$1" rc="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$rc" -ne 0 ]]; then pass_with "$desc"; else fail_with "$desc" "Expected nonzero rc, got 0"; fi
}

assert_file_exists() {
  local desc="$1" f="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$f" ]]; then pass_with "$desc"; else fail_with "$desc" "expected file to exist: $f"; fi
}

assert_file_absent() {
  local desc="$1" f="$2"
  TOTAL=$((TOTAL + 1))
  if [[ ! -e "$f" ]]; then pass_with "$desc"; else fail_with "$desc" "expected file to be absent: $f"; fi
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

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

# render_in <run_id> <jsonl-content> — set up a fresh LOG_BASE, drop the fixture
#   registry, invoke the renderer, and capture RR_OUT (the rendered file path),
#   RR_ERR (stderr) and RR_RC.
RUN_N=0
render_in() {
  local run_id="$1" content="$2"
  RUN_N=$((RUN_N + 1))
  RR_BASE="$TMPROOT/lb-$RUN_N"
  mkdir -p "$RR_BASE/final"
  printf '%s' "$content" >"$RR_BASE/final/findings.jsonl"
  RR_OUT="$RR_BASE/final/HUMAN_REVIEW.md"
  RR_ERR="$TMPROOT/err-$RUN_N.txt"
  ( export LOG_BASE="$RR_BASE"; render_human_review_digest "$run_id" ) 2>"$RR_ERR"
  RR_RC=$?
}

# render_no_registry <run_id> — invoke against a LOG_BASE with NO findings.jsonl.
render_no_registry() {
  local run_id="$1"
  RUN_N=$((RUN_N + 1))
  RR_BASE="$TMPROOT/lb-$RUN_N"
  RR_OUT="$RR_BASE/final/HUMAN_REVIEW.md"
  RR_ERR="$TMPROOT/err-$RUN_N.txt"
  ( export LOG_BASE="$RR_BASE"; render_human_review_digest "$run_id" ) 2>"$RR_ERR"
  RR_RC=$?
}

# --- Source the library (core.sh + risk.sh first; harmless if unused). Assert on
# the FUNCTION, not the file. -----------------------------------------------------
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
# 1. Populated registry -> digest written with every section, links, em dashes.
#    Buckets exercised: critical+high (bucket 1), medium security (bucket 2),
#    test-gap (bucket 3), external-dependency would be bucket 4 but high severity
#    wins it into bucket 1 (first-match), so a needs-validation+scanner finding
#    covers bucket 4; a low/perf finding covers the remainder. The remainder
#    title is deliberately hostile (pipe, backtick, $()) to prove escape-safety.
# ===========================================================================
read -r -d '' FIX_FULL <<'EOF' || true
{"id":"a-crit","title":"SQL injection in login","severity":"critical","type":"security","domain":"security","lens":"injection","status":"new","primary_location":"auth.py:42","confidence":null,"duplicate_group":null,"markdown_path":"001-sqli.md","validation":{}}
{"id":"b-med-sec","title":"Weak CSRF token","severity":"medium","type":"security","domain":"security","lens":"csrf","status":"new","primary_location":"web.py:10","confidence":null,"duplicate_group":null,"markdown_path":"","validation":{}}
{"id":"c-test","title":"No tests for parser | pipe `tick` $(cmd)","severity":"low","type":"test-gap","domain":"code-quality","lens":"tests","status":"new","primary_location":"","confidence":null,"duplicate_group":null,"markdown_path":"003-tests.md","validation":{}}
{"id":"d-scan","title":"Possible secret in config","severity":"low","type":"reliability","domain":"code-quality","lens":"secrets","status":"needs-validation","primary_location":"cfg.yml:5","confidence":null,"duplicate_group":null,"markdown_path":"","validation":{"suggested_validation":"needs external scanner to confirm"}}
{"id":"e-rem","title":"Refactor opportunity | with pipe `tick` $(cmd)","severity":"low","type":"performance","domain":"perf","lens":"hot","status":"new","primary_location":"x.py:1","confidence":null,"duplicate_group":null,"markdown_path":"","validation":{}}
EOF

render_in "full-run" "$FIX_FULL"
assert_rc_zero    "populated registry -> rc 0" "$RR_RC"
assert_no_crash   "populated registry does not crash" "$RR_ERR"
assert_file_exists "populated registry writes final/HUMAN_REVIEW.md" "$RR_OUT"
assert_contains "header carries the run id" "$RR_OUT" "# Human Review — full-run"
assert_contains "section: Top Critical / High present" "$RR_OUT" "## Top Critical / High"
assert_contains "section: Top Medium Security present" "$RR_OUT" "## Top Medium Security"
assert_contains "section: Test & Quality present (own section)" "$RR_OUT" "## Test & Quality"
assert_contains "section: Not Actionable Without a Scanner present (own section)" "$RR_OUT" "## Not Actionable Without a Scanner"
assert_contains "remainder placeholder/anchor present" "$RR_OUT" "## Remainder"
assert_contains "remainder anchor id present" "$RR_OUT" 'id="remainder"'
# Field rendering: severity heading + domain/lens + primary_location.
assert_contains "critical finding rendered with severity heading" "$RR_OUT" "### [CRITICAL] SQL injection in login"
assert_contains "domain/lens + primary_location rendered" "$RR_OUT" "security/injection"
assert_contains "primary_location value rendered" "$RR_OUT" "auth.py:42"
# markdown_path: link emitted when present.
assert_contains "markdown_path rendered as a link when present" "$RR_OUT" "[001-sqli.md](001-sqli.md)"
# Defensive: null/empty markdown_path -> NO broken link; empty field -> em dash,
# never the literal "null".
assert_not_contains "no broken empty link from null markdown_path" "$RR_OUT" "]()"
assert_not_contains "no literal 'null' leaks into the digest" "$RR_OUT" "null"
assert_contains "empty primary_location renders an em dash" "$RR_OUT" "code-quality/tests — \`—\`"
# Escape-safety: a hostile title in a RENDERED section (Test & Quality) survives
# verbatim — the pipe / backtick / $() are data, never shell-evaluated, and the
# bullet-list layout means a literal pipe can't break a row.
assert_contains "hostile title rendered verbatim (pipe/backtick/\$() are data)" "$RR_OUT" \
  'No tests for parser | pipe `tick` $(cmd)'
# Atomic write: no *.tmp.* leftover beside the final file.
TOTAL=$((TOTAL + 1))
if ls "$RR_BASE/final/"HUMAN_REVIEW.md.tmp.* >/dev/null 2>&1; then
  fail_with "atomic write leaves no tmp file behind" "found a leftover HUMAN_REVIEW.md.tmp.* file"
else
  pass_with "atomic write leaves no tmp file behind"
fi

# Determinism: rendering the same registry twice is byte-identical.
RENDER_A="$RR_BASE/final/HUMAN_REVIEW.md"
cp "$RENDER_A" "$TMPROOT/first.md"
( export LOG_BASE="$RR_BASE"; render_human_review_digest "full-run" ) 2>/dev/null
TOTAL=$((TOTAL + 1))
if cmp -s "$TMPROOT/first.md" "$RENDER_A"; then
  pass_with "render is deterministic (byte-identical across runs)"
else
  fail_with "render is deterministic (byte-identical across runs)" "second render differs"
fi

# ===========================================================================
# 2. Empty (zero-line) registry -> valid "nothing to review" digest, rc 0.
# ===========================================================================
render_in "empty-run" ""
assert_rc_zero    "empty registry -> rc 0" "$RR_RC"
assert_no_crash   "empty registry does not crash" "$RR_ERR"
assert_file_exists "empty registry still writes a digest" "$RR_OUT"
assert_contains "empty digest keeps the header" "$RR_OUT" "# Human Review — empty-run"
assert_contains "empty digest keeps Top Critical / High section" "$RR_OUT" "## Top Critical / High"
assert_contains "empty digest keeps Top Medium Security section" "$RR_OUT" "## Top Medium Security"
assert_contains "empty digest keeps Test & Quality section" "$RR_OUT" "## Test & Quality"
assert_contains "empty digest keeps Not Actionable Without a Scanner section" "$RR_OUT" "## Not Actionable Without a Scanner"
# A valid "nothing to review" state (either the top-level note or per-section).
TOTAL=$((TOTAL + 1))
if grep -qiE 'No findings to review|Nothing to review' "$RR_OUT"; then
  pass_with "empty digest shows a nothing-to-review note"
else
  fail_with "empty digest shows a nothing-to-review note" "no empty-state note found"
fi

# ===========================================================================
# 3. Missing registry file entirely -> renderer is total: valid digest, rc 0.
# ===========================================================================
render_no_registry "no-file-run"
assert_rc_zero     "missing findings.jsonl -> rc 0 (renderer is total)" "$RR_RC"
assert_no_crash    "missing findings.jsonl does not crash" "$RR_ERR"
assert_file_exists "missing findings.jsonl still writes a digest" "$RR_OUT"
assert_contains    "missing-registry digest keeps the header" "$RR_OUT" "# Human Review — no-file-run"

# ===========================================================================
# 4. Finalize gate (replicated): write ONLY when HUMAN_REVIEW == true AND a
#    findings.jsonl exists. This mirrors the non-fatal hook in repolens.sh.
# ===========================================================================
GATE_BASE="$TMPROOT/gate"
mkdir -p "$GATE_BASE/final"
printf '%s' "$FIX_FULL" >"$GATE_BASE/final/findings.jsonl"
GATE_OUT="$GATE_BASE/final/HUMAN_REVIEW.md"

# guard helper mirroring repolens.sh: only renders when enabled and registry present.
gate_render() {
  local enabled="$1" run_id="$2"
  if [[ "$enabled" == "true" && -f "$GATE_BASE/final/findings.jsonl" ]]; then
    ( export LOG_BASE="$GATE_BASE"; render_human_review_digest "$run_id" )
  fi
}

# Disabled -> no file written.
rm -f "$GATE_OUT"
gate_render "false" "gate-off"
assert_file_absent "HUMAN_REVIEW=false -> no HUMAN_REVIEW.md written" "$GATE_OUT"

# Enabled + registry present -> file written.
gate_render "true" "gate-on"
assert_file_exists "HUMAN_REVIEW=true + findings.jsonl -> HUMAN_REVIEW.md written" "$GATE_OUT"

# ===========================================================================
# 5. Static wiring check: repolens.sh finalize hook is present, guarded on
#    HUMAN_REVIEW, calls the renderer, logs the exact success string, and is
#    non-fatal (log_warn, not die, on failure).
# ===========================================================================
if [[ -f "$REPOLENS_SH" ]]; then
  assert_contains "repolens.sh calls render_human_review_digest" "$REPOLENS_SH" "render_human_review_digest"
  assert_contains "repolens.sh guards the hook on HUMAN_REVIEW" "$REPOLENS_SH" 'HUMAN_REVIEW:-false'
  assert_contains "repolens.sh logs the exact success string" "$REPOLENS_SH" 'Human review: HUMAN_REVIEW.md written'
  # The hook must not flip the run state inside the human-review block: assert the
  # warn-branch uses log_warn (non-fatal), not die.
  TOTAL=$((TOTAL + 1))
  hook_block="$(awk '/Human review digest \(non-fatal\)/{c=1} c{print} /^apply_rate_limit_abort_final_state/{if(c) exit}' "$REPOLENS_SH")"
  if printf '%s' "$hook_block" | grep -q 'log_warn' && ! printf '%s' "$hook_block" | grep -qw 'die'; then
    pass_with "human-review hook is non-fatal (log_warn, never die)"
  else
    fail_with "human-review hook is non-fatal (log_warn, never die)" "hook block: $hook_block"
  fi
else
  echo "  (skip) repolens.sh not found at $REPOLENS_SH — wiring assertions skipped"
fi

finish
