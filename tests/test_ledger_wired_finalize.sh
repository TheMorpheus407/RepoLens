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

# Tests for issue #348: wire build_finding_registry into the non-local finalize
# path in repolens.sh. The orchestrator (lib/ledger.sh::build_finding_registry)
# already ships, fully unit-tested (tests/test_ledger_build_registry.sh) — but
# nothing in repolens.sh sources it or calls it, so on every non-local run the
# downstream human-review digest and triage artifacts (which both read
# final/findings.jsonl) are dead no-ops. This issue is the missing producer glue:
# source lib/ledger.sh, then call build_finding_registry "$RUN_ID" (NON-FATAL) in
# the finalize flow BEFORE those consumers run.
#
# Contract under test (issue acceptance criteria + research):
#   1. lib/ledger.sh is sourced in repolens.sh.
#   2. On a non-local run that produced final/manifest.json, build_finding_registry
#      is invoked and findings.jsonl + findings.csv appear in final/.
#   3. A registry-build failure is NON-FATAL: it logs a warning and does NOT flip
#      run state (no RUN_ROUNDS_RC / REPOLENS_FINAL_STATE mutation in the block).
#   4. The success path logs an info line naming the artifacts.
#   5. The call is wired BEFORE the human-review / triage consumers so they have a
#      registry to render.
#
# repolens.sh cannot be driven end-to-end here: --dry-run exits before finalize,
# and a real run invokes live agents (forbidden by the test rules). So we exercise
# a faithful REPLICA of the finalize guard against the REAL build_finding_registry
# (pure jq/bash file-assembly, no models) using handwritten manifest fixtures, then
# statically assert repolens.sh actually carries the wiring. This is the same
# strategy as tests/test_finalize_triage_wiring.sh.

set -uo pipefail
# shellcheck disable=SC2329  # helper / replica functions are invoked indirectly

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_LIB="$SCRIPT_DIR/lib/core.sh"
LOGGING_LIB="$SCRIPT_DIR/lib/logging.sh"
SYNTHESIZE_LIB="$SCRIPT_DIR/lib/synthesize.sh"
LEDGER_LIB="$SCRIPT_DIR/lib/ledger.sh"
REPOLENS_SH="$SCRIPT_DIR/repolens.sh"

# The exact success info line the issue mandates (asserted verbatim in repolens.sh).
SUCCESS_LINE='Finding registry: findings.jsonl + findings.csv written'

PASS=0
FAIL=0
TOTAL=0

TMP_PARENT="$SCRIPT_DIR/logs/test-ledger-wired-finalize"
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

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then pass_with "$desc"; else fail_with "$desc" "Expected '$expected', got '$actual'"; fi
}

assert_rc_zero() {
  local desc="$1" rc="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$rc" -eq 0 ]]; then pass_with "$desc"; else fail_with "$desc" "Expected rc 0, got $rc"; fi
}

assert_success() {
  local desc="$1" rc="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$rc" -eq 0 ]]; then pass_with "$desc"; else fail_with "$desc" "Expected exit 0, got $rc"; fi
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

# assert_lt <desc> <a> <b> — passes when a < b (both numeric, non-empty).
assert_lt() {
  local desc="$1" a="$2" b="$3"
  TOTAL=$((TOTAL + 1))
  if [[ -n "$a" && -n "$b" && "$a" -lt "$b" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "expected $a < $b"
  fi
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

# write_manifest <path> — a representative 2-cluster synthesizer manifest (the
#   only source the non-local path feeds the builder; OUTPUT_DIR is empty off the
#   --local path). Mirrors the fixture shape build_findings_jsonl_from_manifest
#   is unit-tested against, so a successful ingest yields exactly 2 records.
write_manifest() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'JSON'
[
  {
    "cluster_id": "missing-validation::upload-handler",
    "title": "[high] Validate upload filenames before writing files",
    "severity": "High",
    "domain": "code",
    "lens": "input-validation",
    "root_cause_category": "missing-validation",
    "source_finding_paths": [
      "logs/run-1/rounds/round-1/lens-outputs/code/input-validation.md"
    ],
    "granularity": "independent",
    "verification_status": "verified",
    "body": "## Summary\nUploads are not sanitized."
  },
  {
    "cluster_id": "weak-crypto::tls-config",
    "title": "Weak TLS ciphers enabled on the edge",
    "severity": "critical",
    "domain": "deployment",
    "lens": "tls",
    "root_cause_category": "weak-crypto",
    "source_finding_paths": [
      "logs/run-1/rounds/round-1/lens-outputs/deployment/tls.md"
    ],
    "granularity": "independent",
    "verification_status": "wrong",
    "body": "## Summary\nLegacy ciphers."
  }
]
JSON
}

# run_registry_guard <log_base> <local_mode> — a faithful replica of the
#   recommended repolens.sh finalize guard: on the NON-LOCAL path, when a
#   synthesizer manifest exists, call the REAL build_finding_registry and swallow
#   its rc into a log line (info on success, warn on failure) — never aborting.
#   Captures the guard's overall rc in RG_RC and stderr in RG_ERR. Mirrors the
#   production block so a drift in the wired contract surfaces here.
run_registry_guard() {
  local log_base="$1" local_mode="$2"
  RG_ERR="$TMPROOT/registry-err.txt"
  : >"$RG_ERR"
  (
    set -uo pipefail
    local LOCAL_MODE="$local_mode"
    local LOG_BASE="$log_base"
    local RUN_ID="run-wired"
    if ! $LOCAL_MODE && [[ -f "$LOG_BASE/final/manifest.json" ]]; then
      if build_finding_registry "$RUN_ID"; then
        echo "info: $SUCCESS_LINE" >&2
      else
        echo "warn: registry build failed" >&2
      fi
    fi
  ) 2>>"$RG_ERR"
  RG_RC=$?
}

# --- Source the libraries in the SAME order the wiring uses (synthesize before
# ledger, so _ledger_log_base prefers _synthesize_log_base and the registry lands
# beside the manifest in $LOG_BASE/final). Assert on the FUNCTIONS, not files. ---
# shellcheck source=/dev/null
[[ -f "$CORE_LIB" ]] && source "$CORE_LIB"
# shellcheck source=/dev/null
[[ -f "$LOGGING_LIB" ]] && source "$LOGGING_LIB"
# shellcheck source=/dev/null
[[ -f "$SYNTHESIZE_LIB" ]] && source "$SYNTHESIZE_LIB"
# shellcheck source=/dev/null
[[ -f "$LEDGER_LIB" ]] && source "$LEDGER_LIB"

TOTAL=$((TOTAL + 1))
if declare -F build_finding_registry >/dev/null 2>&1; then
  pass_with "build_finding_registry is defined after sourcing synthesize + ledger"
else
  fail_with "build_finding_registry is defined after sourcing synthesize + ledger" \
    "function missing — cannot run the functional cases"
  finish
fi

# ===========================================================================
# 1. Non-local happy path: manifest present -> the guard invokes the real
#    builder, which promotes findings.jsonl + findings.csv into final/ (exactly
#    where the human-review/triage consumers read them), one line per cluster,
#    and the registry validates. This is the AC the wiring must satisfy.
# ===========================================================================
LB_OK="$TMPROOT/lb-ok"
write_manifest "$LB_OK/final/manifest.json"

run_registry_guard "$LB_OK" "false"
assert_rc_zero  "non-local + manifest -> guard rc 0" "$RG_RC"
assert_no_crash "non-local + manifest does not crash" "$RG_ERR"
assert_file_exists "non-local + manifest -> final/findings.jsonl promoted" "$LB_OK/final/findings.jsonl"
assert_file_exists "non-local + manifest -> final/findings.csv promoted" "$LB_OK/final/findings.csv"

jsonl_ok="$LB_OK/final/findings.jsonl"
lines_ok="$(wc -l < "$jsonl_ok" | tr -d ' ')"
assert_eq "non-local + manifest -> 2 clusters become 2 jsonl lines" "2" "$lines_ok"

# The promoted registry validates against the schema (so the consumers can read it).
validate_findings_jsonl "$jsonl_ok" >/dev/null 2>&1
assert_success "non-local + manifest -> promoted registry passes validate_findings_jsonl" "$?"

# AC 4 ("Success path logs an info line") proven at RUNTIME, not just statically:
# when the REAL builder succeeds the guard must take the INFO branch, never the
# warn branch. RG_ERR still holds case 1's guard output (next run_registry_guard
# call is case 3) — the success replica echoes the verbatim success line there.
assert_contains "non-local + manifest -> success branch logs the info line" "$RG_ERR" "$SUCCESS_LINE"
TOTAL=$((TOTAL + 1))
if [[ -f "$RG_ERR" ]] && grep -qF 'warn: registry build failed' "$RG_ERR"; then
  fail_with "non-local + manifest -> warn branch NOT taken when build succeeds" \
    "warn line present though the real builder returned 0"
else
  pass_with "non-local + manifest -> warn branch NOT taken when build succeeds"
fi

# ===========================================================================
# 2. Build failure is NON-FATAL: with the builder shadowed to fail, the guard
#    still returns 0, run state is left UNTOUCHED, and no findings.jsonl appears.
#    A failing stub (not a passing one) forces the `|| log_warn` branch — the
#    exact path the AC says must not flip run state.
# ===========================================================================
LB_FAIL="$TMPROOT/lb-fail"
write_manifest "$LB_FAIL/final/manifest.json"
nf_err="$TMPROOT/nf-err.txt"
: > "$nf_err"
nf_out="$(
  set -uo pipefail
  build_finding_registry() { echo "stub: forced failure" >&2; return 1; }  # force the failure branch
  LOCAL_MODE=false
  LOG_BASE="$LB_FAIL"
  RUN_ID="run-fail"
  RUN_ROUNDS_RC=0
  REPOLENS_FINAL_STATE="ok"
  if ! $LOCAL_MODE && [[ -f "$LOG_BASE/final/manifest.json" ]]; then
    if build_finding_registry "$RUN_ID"; then
      :
    else
      # NON-FATAL: warn only, never mutate run state. Marker captured to the
      # branch-trace file so the test can assert the WARN branch fired (a trailing
      # 2>file on the assignment would miss it — the substitution expands before
      # that redirect applies).
      echo "warn: registry build failed" >>"$nf_err"
    fi
  fi
  printf 'RC=%s STATE=%s' "$RUN_ROUNDS_RC" "$REPOLENS_FINAL_STATE"
)"
nf_rc=$?
assert_rc_zero "build failure -> guard still returns rc 0 (non-fatal)" "$nf_rc"
assert_eq "build failure -> run state untouched (no RUN_ROUNDS_RC / REPOLENS_FINAL_STATE flip)" \
  "RC=0 STATE=ok" "$nf_out"
assert_file_absent "build failure -> no findings.jsonl promoted" "$LB_FAIL/final/findings.jsonl"
# The failure path must positively take the WARN branch (and NOT the success
# info line). The files/rc/state assertions above wouldn't catch a wiring bug
# that swapped the two log branches (e.g. an inverted `if`); this pins it.
assert_contains "build failure -> warn branch fired (failure path logs a warning)" \
  "$nf_err" "warn: registry build failed"
TOTAL=$((TOTAL + 1))
if [[ -f "$nf_err" ]] && grep -qF "$SUCCESS_LINE" "$nf_err"; then
  fail_with "build failure -> success info line NOT logged" \
    "success line present though the build failed"
else
  pass_with "build failure -> success info line NOT logged"
fi

# ===========================================================================
# 3. No manifest -> the recommended guard skips entirely: rc 0, NO findings.jsonl.
#    (If the implementer instead chooses the unconditional `! $LOCAL_MODE` variant,
#    the orchestrator self-no-ops to a canonical-empty registry — also AC-valid;
#    this case pins the research-recommended manifest-gated behavior.)
# ===========================================================================
LB_NOMAN="$TMPROOT/lb-noman"
mkdir -p "$LB_NOMAN/final"   # final/ exists but holds no manifest

run_registry_guard "$LB_NOMAN" "false"
assert_rc_zero  "no manifest -> guard rc 0 (clean skip)" "$RG_RC"
assert_no_crash "no manifest does not crash" "$RG_ERR"
assert_file_absent "no manifest -> no findings.jsonl written" "$LB_NOMAN/final/findings.jsonl"

# ===========================================================================
# 4. Local mode is OUT OF SCOPE: even with a manifest present, the `! $LOCAL_MODE`
#    guard skips the call on the --local path (that wiring is a sibling issue).
# ===========================================================================
LB_LOCAL="$TMPROOT/lb-local"
write_manifest "$LB_LOCAL/final/manifest.json"

run_registry_guard "$LB_LOCAL" "true"
assert_rc_zero  "local mode -> guard rc 0" "$RG_RC"
assert_file_absent "local mode -> registry not built on the non-local hook" "$LB_LOCAL/final/findings.jsonl"

# ===========================================================================
# 4b. Manifest present but EMPTY ([] clusters) — e.g. the synthesizer ran but
#    clustered nothing. The wiring gate is `-f` (file exists), NOT `-s`, so an
#    empty-array manifest STILL triggers the call: the real builder succeeds with
#    a canonical-empty registry, so the SUCCESS/info branch fires and the
#    human-review/triage consumers get a valid (empty) findings.jsonl rather than
#    a missing file. Guards against anyone tightening the gate to `-s`, which
#    would skip empty manifests and re-break the consumers. Distinct from case 3
#    (no manifest file at all) — here the file exists, just with [].
# ===========================================================================
LB_EMPTY="$TMPROOT/lb-empty"
mkdir -p "$LB_EMPTY/final"
printf '[]\n' > "$LB_EMPTY/final/manifest.json"

run_registry_guard "$LB_EMPTY" "false"
assert_rc_zero  "empty [] manifest -> guard rc 0 (success branch)" "$RG_RC"
assert_no_crash "empty [] manifest does not crash" "$RG_ERR"
assert_contains "empty [] manifest -> success branch logs the info line" "$RG_ERR" "$SUCCESS_LINE"
assert_file_exists "empty [] manifest -> findings.jsonl still produced for the consumers" \
  "$LB_EMPTY/final/findings.jsonl"

# ===========================================================================
# 5. Static wiring checks against repolens.sh (the genuinely-new surface this
#    issue adds — --dry-run cannot reach finalize, so we assert the source line,
#    the call, the success log, non-fatality, and ordering directly in the file).
# ===========================================================================
if [[ -f "$REPOLENS_SH" ]]; then
  assert_contains "repolens.sh sources lib/ledger.sh" "$REPOLENS_SH" \
    'source "$SCRIPT_DIR/lib/ledger.sh"'
  assert_contains "repolens.sh calls build_finding_registry \"\$RUN_ID\"" "$REPOLENS_SH" \
    'build_finding_registry "$RUN_ID"'
  assert_contains "repolens.sh logs the exact success info line" "$REPOLENS_SH" \
    "$SUCCESS_LINE"

  # Locate the call so we can window-check non-fatality and ordering.
  call_ln="$(grep -nF 'build_finding_registry "$RUN_ID"' "$REPOLENS_SH" | head -n1 | cut -d: -f1)"

  # The wired block must be non-fatal AND non-local-gated: a window around the
  # call must contain log_warn and the `! $LOCAL_MODE` guard, and must NOT `die`
  # or assign RUN_ROUNDS_RC / REPOLENS_FINAL_STATE (which would flip run state).
  TOTAL=$((TOTAL + 1))
  if [[ -n "$call_ln" ]]; then
    win_start=$(( call_ln > 3 ? call_ln - 3 : 1 ))
    win_end=$(( call_ln + 6 ))
    block="$(sed -n "${win_start},${win_end}p" "$REPOLENS_SH")"
    if printf '%s' "$block" | grep -q 'log_warn' \
       && printf '%s' "$block" | grep -qF '! $LOCAL_MODE' \
       && ! printf '%s' "$block" | grep -qw 'die' \
       && ! printf '%s' "$block" | grep -qE 'RUN_ROUNDS_RC=' \
       && ! printf '%s' "$block" | grep -qE 'REPOLENS_FINAL_STATE='; then
      pass_with "registry block is non-fatal + non-local-gated (log_warn, ! \$LOCAL_MODE, never die/flips state)"
    else
      fail_with "registry block is non-fatal + non-local-gated (log_warn, ! \$LOCAL_MODE, never die/flips state)" \
        "block window: $block"
    fi
  else
    fail_with "registry block is non-fatal + non-local-gated (log_warn, ! \$LOCAL_MODE, never die/flips state)" \
      "build_finding_registry \"\$RUN_ID\" call not found — wiring absent"
  fi

  # Ordering: the registry must be produced BEFORE the human-review digest and the
  # triage block consume final/findings.jsonl, or those consumers stay dead.
  hr_ln="$(grep -nF 'render_human_review_digest "$RUN_ID"' "$REPOLENS_SH" | head -n1 | cut -d: -f1)"
  tr_ln="$(grep -nF 'TRIAGE_FINDINGS=' "$REPOLENS_SH" | head -n1 | cut -d: -f1)"
  assert_lt "registry call is ordered before the human-review consumer" "$call_ln" "$hr_ln"
  assert_lt "registry call is ordered before the triage consumer" "$call_ln" "$tr_ln"
else
  echo "  (skip) repolens.sh not found at $REPOLENS_SH — wiring assertions skipped"
fi

finish
