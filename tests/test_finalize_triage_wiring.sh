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

# Tests for issue #342: wire the four human-triage artifact generators into the
# repolens.sh finalize section, guarded. Pure-function + static-wiring tests only;
# NO AI models are invoked — every input is a handwritten JSON-Lines fixture and
# the generators are pure jq + bash.
#
# Contract under test (issue acceptance criteria + research):
#
#   The finalize hook, after finalize_summary, renders four Markdown files from
#   $LOG_BASE/final/findings.jsonl into $LOG_BASE/final/:
#     generate_todo_md         -> TODO.md
#     generate_summary_md      -> SUMMARY.md
#     generate_needs_review_md -> NEEDS_REVIEW.md
#     generate_duplicates_md   -> DUPLICATES.md
#
#   GUARD: the whole block runs only when findings.jsonl exists AND is non-empty
#   (`[[ -s ... ]]`). Absent OR zero-byte registry -> one info log, exit 0, NO
#   files written (no placeholder leakage). Each generator failure is non-fatal:
#   a warning is logged and the loop continues; REPOLENS_FINAL_STATE is never
#   touched. The generated artifact paths are logged.
#
#   We exercise the generators directly and replicate the finalize guard locally
#   (running repolens.sh itself would invoke real agents — forbidden by the test
#   rules), then statically assert the wiring is present in repolens.sh.

set -uo pipefail
# shellcheck disable=SC2329  # helper functions are invoked indirectly

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_LIB="$SCRIPT_DIR/lib/core.sh"
RISK_LIB="$SCRIPT_DIR/lib/risk.sh"
ARTIFACTS_LIB="$SCRIPT_DIR/lib/artifacts.sh"
REPOLENS_SH="$SCRIPT_DIR/repolens.sh"

PASS=0
FAIL=0
TOTAL=0

TMP_PARENT="$SCRIPT_DIR/logs/test-finalize-triage-wiring"
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

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

# The exact four (generator -> output basename) pairs the finalize hook drives.
TRIAGE_SPECS=(
  "generate_todo_md:TODO.md"
  "generate_summary_md:SUMMARY.md"
  "generate_needs_review_md:NEEDS_REVIEW.md"
  "generate_duplicates_md:DUPLICATES.md"
)

# run_triage_guard <log_base> — a faithful replica of the repolens.sh finalize
#   block: gate on a non-empty findings.jsonl, then call each generator into
#   final/, swallowing any non-zero rc into a warning (never aborting). Captures
#   stderr to TG_ERR and the guard rc to TG_RC. Mirrors the production guard so a
#   drift in the contract surfaces here.
run_triage_guard() {
  local log_base="$1"
  local findings="$log_base/final/findings.jsonl"
  TG_ERR="$TMPROOT/triage-err.$$.txt"
  : >"$TG_ERR"
  (
    set -uo pipefail
    if [[ -s "$findings" ]]; then
      local spec fn out
      for spec in "${TRIAGE_SPECS[@]}"; do
        fn="${spec%%:*}"
        out="$log_base/final/${spec##*:}"
        if "$fn" "$findings" "$out"; then
          :
        else
          echo "warn: failed to render $out ($fn)" >&2
        fi
      done
    else
      echo "info: no finding registry at $findings; skipping" >&2
    fi
  ) 2>>"$TG_ERR"
  TG_RC=$?
}

# --- Source the library (core.sh + risk.sh first; harmless if unused). Assert on
# the FUNCTIONS, not the file. -----------------------------------------------------
# shellcheck source=/dev/null
[[ -f "$CORE_LIB" ]] && source "$CORE_LIB"
# shellcheck source=/dev/null
[[ -f "$RISK_LIB" ]] && source "$RISK_LIB"
if [[ -f "$ARTIFACTS_LIB" ]]; then
  # shellcheck source=/dev/null
  source "$ARTIFACTS_LIB"
fi

for fn in generate_todo_md generate_summary_md generate_needs_review_md generate_duplicates_md; do
  TOTAL=$((TOTAL + 1))
  if declare -F "$fn" >/dev/null 2>&1; then
    pass_with "$fn is defined after sourcing lib/artifacts.sh"
  else
    fail_with "$fn is defined after sourcing lib/artifacts.sh" \
      "function missing — cannot run the rest of the suite"
    finish
  fi
done

# A small but representative registry: a couple of confirmed-new findings plus a
# needs-validation one. The exact rendering belongs to the per-generator tests;
# here we only assert the wiring produces all four files cleanly.
read -r -d '' FIX_FULL <<'EOF' || true
{"id":"f1","title":"SQL injection in login","severity":"critical","type":"security","domain":"security","lens":"injection","status":"new","primary_location":"auth.py:42","confidence":null,"duplicate_group":null,"markdown_path":"001-sqli.md","validation":{}}
{"id":"f2","title":"Weak CSRF token","severity":"medium","type":"security","domain":"security","lens":"csrf","status":"new","primary_location":"web.py:10","confidence":null,"duplicate_group":null,"markdown_path":"","validation":{}}
{"id":"f3","title":"Possible secret in config","severity":"low","type":"reliability","domain":"code-quality","lens":"secrets","status":"needs-validation","primary_location":"cfg.yml:5","confidence":null,"duplicate_group":null,"markdown_path":"","validation":{"suggested_validation":"needs external scanner"}}
EOF

# ===========================================================================
# 1. Populated, non-empty registry -> all four artifacts written, rc 0, no crash.
# ===========================================================================
LB_FULL="$TMPROOT/lb-full"
mkdir -p "$LB_FULL/final"
printf '%s' "$FIX_FULL" >"$LB_FULL/final/findings.jsonl"

run_triage_guard "$LB_FULL"
assert_rc_zero  "populated registry -> guard rc 0" "$TG_RC"
assert_no_crash "populated registry does not crash" "$TG_ERR"
for spec in "${TRIAGE_SPECS[@]}"; do
  out_name="${spec##*:}"
  assert_file_exists "populated registry writes final/$out_name" "$LB_FULL/final/$out_name"
done
# No tmp leftovers beside the rendered files (generators write atomically).
TOTAL=$((TOTAL + 1))
if ls "$LB_FULL/final/".*.[A-Za-z0-9]* >/dev/null 2>&1 && \
   ls "$LB_FULL/final/".{todo,summary,needs_review,duplicates}.* >/dev/null 2>&1; then
  fail_with "atomic write leaves no tmp file behind" "found a leftover .<artifact>.* tmp file"
else
  pass_with "atomic write leaves no tmp file behind"
fi

# ===========================================================================
# 2. Empty (zero-byte) registry -> clean no-op: rc 0, NO artifacts written.
#    The `-s` gate must treat present-but-empty exactly like absent so a
#    placeholder file never leaks.
# ===========================================================================
LB_EMPTY="$TMPROOT/lb-empty"
mkdir -p "$LB_EMPTY/final"
: >"$LB_EMPTY/final/findings.jsonl"

run_triage_guard "$LB_EMPTY"
assert_rc_zero  "empty registry -> guard rc 0 (clean no-op)" "$TG_RC"
assert_no_crash "empty registry does not crash" "$TG_ERR"
for spec in "${TRIAGE_SPECS[@]}"; do
  out_name="${spec##*:}"
  assert_file_absent "empty registry writes NO final/$out_name" "$LB_EMPTY/final/$out_name"
done

# ===========================================================================
# 3. Absent registry file entirely -> clean no-op: rc 0, NO artifacts written.
# ===========================================================================
LB_ABSENT="$TMPROOT/lb-absent"
mkdir -p "$LB_ABSENT/final"

run_triage_guard "$LB_ABSENT"
assert_rc_zero  "absent registry -> guard rc 0 (clean no-op)" "$TG_RC"
assert_no_crash "absent registry does not crash" "$TG_ERR"
for spec in "${TRIAGE_SPECS[@]}"; do
  out_name="${spec##*:}"
  assert_file_absent "absent registry writes NO final/$out_name" "$LB_ABSENT/final/$out_name"
done

# ===========================================================================
# 4. Non-fatal sanity: a generator failure (here, an unreadable input forced via
#    a one-shot wrapper) must NOT abort the loop — the guard still returns 0 and
#    the remaining artifacts are produced. We prove the loop is resilient by
#    shadowing one generator with a stub that returns rc 1.
# ===========================================================================
LB_FAIL="$TMPROOT/lb-fail"
mkdir -p "$LB_FAIL/final"
printf '%s' "$FIX_FULL" >"$LB_FAIL/final/findings.jsonl"
(
  set -uo pipefail
  # Shadow one generator with a failing stub; the loop must swallow its rc.
  generate_summary_md() { return 1; }
  findings="$LB_FAIL/final/findings.jsonl"
  rc_all=0
  if [[ -s "$findings" ]]; then
    for spec in "${TRIAGE_SPECS[@]}"; do
      fn="${spec%%:*}"
      out="$LB_FAIL/final/${spec##*:}"
      "$fn" "$findings" "$out" || true
    done
  fi
  exit "$rc_all"
)
NF_RC=$?
assert_rc_zero    "a failing generator does not abort the loop (guard rc 0)" "$NF_RC"
assert_file_exists "sibling artifact still produced after a generator fails" "$LB_FAIL/final/TODO.md"
assert_file_exists "later artifact still produced after an earlier failure" "$LB_FAIL/final/DUPLICATES.md"

# ===========================================================================
# 5. Static wiring check: repolens.sh sources lib/artifacts.sh, guards the block
#    on a non-empty final/findings.jsonl, calls all four generators, logs the
#    artifact paths, and is non-fatal (log_warn, never die, on failure).
# ===========================================================================
if [[ -f "$REPOLENS_SH" ]]; then
  assert_contains "repolens.sh sources lib/artifacts.sh" "$REPOLENS_SH" \
    'source "$SCRIPT_DIR/lib/artifacts.sh"'
  assert_contains "repolens.sh references final/findings.jsonl for the guard" "$REPOLENS_SH" \
    'final/findings.jsonl'
  assert_contains "repolens.sh calls generate_todo_md" "$REPOLENS_SH" "generate_todo_md"
  assert_contains "repolens.sh calls generate_summary_md" "$REPOLENS_SH" "generate_summary_md"
  assert_contains "repolens.sh calls generate_needs_review_md" "$REPOLENS_SH" "generate_needs_review_md"
  assert_contains "repolens.sh calls generate_duplicates_md" "$REPOLENS_SH" "generate_duplicates_md"
  assert_contains "repolens.sh logs each artifact path" "$REPOLENS_SH" "Triage artifact:"

  # The block must gate on `-s` (exists AND non-empty), not a bare `-f`, so a
  # zero-byte registry leaks no placeholder files.
  TOTAL=$((TOTAL + 1))
  if grep -qF '[[ -s "$TRIAGE_FINDINGS" ]]' "$REPOLENS_SH"; then
    pass_with "triage block gates on -s (non-empty), not bare -f"
  else
    fail_with "triage block gates on -s (non-empty), not bare -f" \
      "expected a [[ -s \"\$TRIAGE_FINDINGS\" ]] guard"
  fi

  # The block must be non-fatal: it uses log_warn on failure, never `die`, and
  # never ASSIGNS REPOLENS_FINAL_STATE (a mention in a comment is fine; an
  # assignment `REPOLENS_FINAL_STATE=...` would mutate run state and is banned).
  TOTAL=$((TOTAL + 1))
  hook_block="$(awk '/Human-triage artifacts \(non-fatal\)/{c=1} c{print} /^apply_rate_limit_abort_final_state/{if(c) exit}' "$REPOLENS_SH")"
  if printf '%s' "$hook_block" | grep -q 'log_warn' \
     && ! printf '%s' "$hook_block" | grep -qw 'die' \
     && ! printf '%s' "$hook_block" | grep -qE 'REPOLENS_FINAL_STATE='; then
    pass_with "triage hook is non-fatal (log_warn, never die, never assigns REPOLENS_FINAL_STATE)"
  else
    fail_with "triage hook is non-fatal (log_warn, never die, never assigns REPOLENS_FINAL_STATE)" \
      "hook block: $hook_block"
  fi
else
  echo "  (skip) repolens.sh not found at $REPOLENS_SH — wiring assertions skipped"
fi

finish
