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

# Tests for issue #349: ensure --local runs produce findings.jsonl + findings.csv.
#
# --local mode bypasses the synthesizer/manifest path entirely (the
# synthesizer/filing block is gated on bugreport && rounds>1, and the non-local
# finding-registry hook is `! $LOCAL_MODE`-gated — sibling issue #348). So today a
# --local run dumps NNN-<slug>.md files into $OUTPUT_DIR with NO machine-readable
# index. This issue adds the missing producer glue: a $LOCAL_MODE-gated, NON-FATAL
# call to build_finding_registry "$RUN_ID" "$OUTPUT_DIR" in the finalize region,
# plus an end-of-run summary line naming the index — so a --local run also emits
# logs/<run-id>/final/findings.jsonl + findings.csv indexing the md tree.
#
# The orchestrator (lib/ledger.sh::build_finding_registry + its local-md ingestion
# path) already ships and is fully unit-tested (tests/test_ledger_build_registry.sh,
# tests/test_ledger_from_local.sh). The NEW surface this issue adds is purely the
# wiring in repolens.sh, so that is what these tests pin.
#
# Acceptance criteria (issue #349):
#   1. After a --local run, final/findings.jsonl + findings.csv exist and index the
#      md files (each record's markdown_path points at a real md file).
#   2. The registry lands under final/, leaving $OUTPUT_DIR holding only md files.
#   3. A build failure is NON-FATAL (warn, run still succeeds).
#   4. The end-of-run local-mode summary mentions the registry index path.
#
# Strategy (CLAUDE.md hard rule: NO real models — mock-agent / sourced replica only):
#   Part A — full mock-agent --local run inside an isolated symlink-farm logs tree.
#            Proves the wiring actually fires in the real finalize path: the
#            registry is produced under final/, every markdown_path resolves to a
#            real md file, $OUTPUT_DIR stays md-only, and the run surfaces the index
#            path. This is the genuine red-phase driver (no findings.jsonl today).
#   Part B — sourced replica of the new $LOCAL_MODE guard with build_finding_registry
#            shadowed to FAIL, pinning the MANDATORY non-fatal contract (rc 0, run
#            state untouched, warn branch fired). A passing stub would never exercise
#            the `|| log_warn` branch this AC is about.
#   Part C — static wiring assertions: repolens.sh carries a $LOCAL_MODE-gated,
#            OUTPUT_DIR-aware, non-fatal build_finding_registry call distinct from
#            the existing `! $LOCAL_MODE` block.

set -uo pipefail
# shellcheck disable=SC2329  # helper / replica functions are invoked indirectly

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_LIB="$SCRIPT_DIR/lib/core.sh"
LOGGING_LIB="$SCRIPT_DIR/lib/logging.sh"
SYNTHESIZE_LIB="$SCRIPT_DIR/lib/synthesize.sh"
LEDGER_LIB="$SCRIPT_DIR/lib/ledger.sh"
REPOLENS_SH="$SCRIPT_DIR/repolens.sh"

# The flat 11-column CSV header contract (lib/ledger.sh build_findings_csv).
CSV_HEADER='id,title,severity,type,domain,lens,status,primary_location,confidence,duplicate_group,markdown_path'

PASS=0
FAIL=0
TOTAL=0
KEEP_ARTIFACTS=0
TMP_ROOT=""

# shellcheck disable=SC2329  # cleanup is invoked indirectly via 'trap cleanup EXIT'.
cleanup() {
  if (( KEEP_ARTIFACTS == 0 )); then
    [[ -n "$TMP_ROOT" && -d "$TMP_ROOT" ]] && rm -rf "$TMP_ROOT"
  else
    printf 'Preserved test artifacts: %s\n' "$TMP_ROOT"
  fi
}
trap cleanup EXIT

pass_with() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

fail_with() {
  local desc="$1" detail="${2:-}"
  FAIL=$((FAIL + 1))
  KEEP_ARTIFACTS=1
  echo "  FAIL: $desc"
  [[ -n "$detail" ]] && printf '    %s\n' "$detail"
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

# assert_nonempty <desc> <value>
assert_nonempty() {
  local desc="$1" v="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -n "$v" ]]; then pass_with "$desc"; else fail_with "$desc" "expected a non-empty value"; fi
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  [[ "$FAIL" -gt 0 ]] && exit 1
  exit 0
}

parse_run_id() {
  sed -n 's/.*RepoLens run \([^ ]*\) starting.*/\1/p' "$1" | head -1
}

TMP_ROOT="$(mktemp -d)"

# ===========================================================================
# Part A — end-to-end: a completed --local run produces the finding registry
#          under final/ and surfaces its path. Proves the new wiring fires in
#          the REAL finalize flow (the replica in Part B cannot).
# ===========================================================================
echo "=== --local run produces final/findings.jsonl + findings.csv (issue #349) ==="

# Symlink farm: isolate $SCRIPT_DIR/logs so the run dir + registry land in the
# farm, never the real logs tree. repolens derives its logs base from its own
# location, so symlinking the entry point + libs gives a fully isolated run.
FARM="$TMP_ROOT/farm"
mkdir -p "$FARM/logs"
for item in repolens.sh lib config prompts; do
  ln -s "$SCRIPT_DIR/$item" "$FARM/$item"
done

# Throwaway git repo to audit.
PROJECT_DIR="$TMP_ROOT/project"
mkdir -p "$PROJECT_DIR"
git -C "$PROJECT_DIR" init -q
printf '# RepoLens issue 349 fixture\n' > "$PROJECT_DIR/README.md"
git -C "$PROJECT_DIR" add README.md
git -C "$PROJECT_DIR" -c user.name='RepoLens Test' -c user.email='repolens@example.invalid' \
  commit -q -m 'fixture'

# Fake `codex` that defers to the deterministic mock agent (writes NNN-*.md
# findings with valid frontmatter into the rendered $OUTPUT_DIR).
FAKE_BIN="$TMP_ROOT/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
exec bash "$REPOLENS_TEST_SCRIPT_DIR/tests/mock-agent.sh" "$@"
EOF
chmod +x "$FAKE_BIN/codex"

run_output="$TMP_ROOT/run-output.txt"
PATH="$FAKE_BIN:$PATH" \
  REPOLENS_AGENT_TIMEOUT=10 \
  REPOLENS_AGENT_KILL_GRACE=1 \
  REPOLENS_TEST_SCRIPT_DIR="$SCRIPT_DIR" \
  bash "$FARM/repolens.sh" \
    --project "$PROJECT_DIR" \
    --agent codex \
    --local \
    --focus injection \
    --depth 1 \
    --yes \
    >"$run_output" 2>&1
run_rc=$?

# AC #3 (the run still succeeds) is proven on the happy path here too.
assert_rc_zero "completed --local run exits successfully" "$run_rc"

RUN_ID="$(parse_run_id "$run_output")"
assert_nonempty "run id is discoverable from output" "$RUN_ID"

FINAL_DIR="$FARM/logs/$RUN_ID/final"
JSONL="$FINAL_DIR/findings.jsonl"
CSV="$FINAL_DIR/findings.csv"
# Default --local OUTPUT_DIR (repolens resolves it to round-1 lens-outputs).
OUT_DIR="$FARM/logs/$RUN_ID/rounds/round-1/lens-outputs"

# AC #1: the registry pair exists under final/ and indexes the md files.
assert_file_exists "--local run writes final/findings.jsonl" "$JSONL"
assert_file_exists "--local run writes final/findings.csv" "$CSV"

# Non-empty registry: the mock wrote at least one finding, so the index must
# carry at least one record (a 0-line jsonl would mean the md tree wasn't ingested).
records="$(grep -c '' "$JSONL" 2>/dev/null || printf '0')"
TOTAL=$((TOTAL + 1))
if [[ "$records" -ge 1 ]]; then
  pass_with "findings.jsonl has at least one record ($records)"
else
  fail_with "findings.jsonl has at least one record" "got $records lines"
fi

# Every line is valid JSON and carries a markdown_path that resolves to a real md
# file (AC #1: "each record's markdown_path points at a real md file"). Starts
# unsatisfied and is only satisfied after at least one record passes every check,
# so a missing / empty registry fails here rather than passing vacuously.
TOTAL=$((TOTAL + 1))
md_ok=0
md_checked=0
md_detail="registry missing or empty — no markdown_path validated"
if [[ -f "$JSONL" ]]; then
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if ! printf '%s' "$line" | jq -e . >/dev/null 2>&1; then
      md_ok=0; md_detail="invalid JSON line: $line"; break
    fi
    mp="$(printf '%s' "$line" | jq -r '.markdown_path // ""')"
    if [[ -z "$mp" ]]; then
      md_ok=0; md_detail="empty markdown_path in: $line"; break
    fi
    if [[ "$mp" != *.md ]]; then
      md_ok=0; md_detail="markdown_path is not a .md file: $mp"; break
    fi
    if [[ ! -f "$mp" ]]; then
      md_ok=0; md_detail="markdown_path does not resolve to a file: $mp"; break
    fi
    # AC #2 corollary: the indexed md lives in the output tree, NOT inside final/.
    if [[ "$mp" == "$FINAL_DIR/"* ]]; then
      md_ok=0; md_detail="markdown_path points inside final/: $mp"; break
    fi
    md_checked=$((md_checked + 1))
    md_ok=1
  done < "$JSONL"
fi
if [[ "$md_ok" -eq 1 && "$md_checked" -ge 1 ]]; then
  pass_with "every markdown_path resolves to a real .md file outside final/"
else
  fail_with "every markdown_path resolves to a real .md file outside final/" "$md_detail"
fi

# The promoted registry validates against the schema (so downstream consumers can
# read it). Source the libs in a subshell to call the real validator model-free.
TOTAL=$((TOTAL + 1))
if bash -c '
  set -uo pipefail
  source "$1"; source "$2"; source "$3"; source "$4"
  validate_findings_jsonl "$5"
' _ "$CORE_LIB" "$LOGGING_LIB" "$SYNTHESIZE_LIB" "$LEDGER_LIB" "$JSONL" >/dev/null 2>&1; then
  pass_with "produced findings.jsonl passes validate_findings_jsonl"
else
  fail_with "produced findings.jsonl passes validate_findings_jsonl" "validation failed for $JSONL"
fi

# CSV is the flat 11-column projection (header byte-for-byte).
csv_header="$(head -n1 "$CSV" 2>/dev/null || true)"
assert_eq "findings.csv carries the canonical 11-column header" "$CSV_HEADER" "$csv_header"

# AC #2: the registry is under final/; $OUTPUT_DIR stays md-only and final/ holds
# no md (the deliverable was not copied into the index dir).
TOTAL=$((TOTAL + 1))
non_md_in_out="$(find "$OUT_DIR" -type f ! -name '*.md' 2>/dev/null)"
if [[ -z "$non_md_in_out" ]]; then
  pass_with "\$OUTPUT_DIR (lens-outputs) contains only md files"
else
  fail_with "\$OUTPUT_DIR (lens-outputs) contains only md files" "non-md present: $non_md_in_out"
fi
TOTAL=$((TOTAL + 1))
md_in_final="$(find "$FINAL_DIR" -type f -name '*.md' 2>/dev/null)"
if [[ -z "$md_in_final" ]]; then
  pass_with "final/ holds the registry, not copied md deliverables"
else
  fail_with "final/ holds the registry, not copied md deliverables" "md leaked into final/: $md_in_final"
fi

# AC #4: the end-of-run output mentions the registry index path. Accept either the
# success log_info or the summary echo, wording-agnostic: a positive "finding
# registry|index" line that names <run-id>/final and is NOT the triage skip line
# ("...no finding registry at .../findings.jsonl; skipping", which runs before the
# local build under the recommended placement and must not satisfy this AC).
TOTAL=$((TOTAL + 1))
index_mention="$(grep -iE 'finding (registry|index)' "$run_output" 2>/dev/null \
  | grep -viF 'skipping' | grep -F "$RUN_ID/final" || true)"
if [[ -n "$index_mention" ]]; then
  pass_with "end-of-run output surfaces the registry index path"
else
  fail_with "end-of-run output surfaces the registry index path" \
    "no positive 'finding registry/index' line naming $RUN_ID/final in run output"
fi

# AC #4 (sharper) — pin the SUMMARY ECHO itself, not just "some line". The check
# above is wording-agnostic and is already satisfied by the success `log_info`
# ("Finding registry: ... -> <run>/final/ ..."), so deleting the end-of-run summary
# block would NOT fail it — yet the issue names the *summary* as the surface that
# must mention the index. The summary block emits two strings found nowhere else on
# the real --local path: an "Output: local markdown (...)" deliverable pointer
# (the dry-run twin at repolens.sh:2820 is gated behind `if $DRY_RUN`, untaken here)
# and a distinct "Finding index:" label (the log_info uses "Finding registry:").
assert_contains "summary block surfaces the md deliverable pointer (Output: local markdown)" \
  "$run_output" "local markdown ("
assert_contains "summary block surfaces the registry via its distinct 'Finding index:' label" \
  "$run_output" "Finding index:"

# ===========================================================================
# Part B — build failure is NON-FATAL (AC #3). With build_finding_registry
#          shadowed to fail, a faithful replica of the new $LOCAL_MODE guard must
#          still return 0, leave run state UNTOUCHED, log a warning, and promote
#          no findings.jsonl. A failing stub (not a passing one) is what forces the
#          `|| log_warn` branch the AC is about.
# ===========================================================================
echo ""
echo "=== --local registry build failure is non-fatal ==="

LB_FAIL="$TMP_ROOT/lb-fail"
OUT_FAIL="$LB_FAIL/issues"
mkdir -p "$OUT_FAIL"
cat > "$OUT_FAIL/001-fixture.md" <<'MD'
---
title: "[low] fixture finding"
severity: low
domain: security
lens: injection
---
## Summary
fixture
MD

nf_err="$TMP_ROOT/nf-err.txt"
: > "$nf_err"
nf_out="$(
  set -uo pipefail
  # Shadow the orchestrator to force the failure branch.
  build_finding_registry() { echo "stub: forced failure" >&2; return 1; }
  log_info() { :; }
  log_warn() { echo "warn: $*" >>"$nf_err"; }
  LOCAL_MODE=true
  OUTPUT_DIR="$OUT_FAIL"
  RUN_ID="run-fail"
  RUN_ROUNDS_RC=0
  REPOLENS_FINAL_STATE="ok"
  if $LOCAL_MODE && [[ -n "$OUTPUT_DIR" && -d "$OUTPUT_DIR" ]]; then
    if build_finding_registry "$RUN_ID" "$OUTPUT_DIR"; then
      log_info "Finding registry: findings.jsonl + findings.csv written"
    else
      # NON-FATAL: warn only, never mutate run state or abort.
      log_warn "Finding registry: build failed (findings index not produced)"
    fi
  fi
  printf 'RC=%s STATE=%s' "$RUN_ROUNDS_RC" "$REPOLENS_FINAL_STATE"
)"
nf_rc=$?

assert_rc_zero "build failure -> guard still returns rc 0 (non-fatal)" "$nf_rc"
assert_eq "build failure -> run state untouched (no RUN_ROUNDS_RC / REPOLENS_FINAL_STATE flip)" \
  "RC=0 STATE=ok" "$nf_out"
assert_contains "build failure -> warn branch fired" "$nf_err" "warn:"
# The forced-failure replica wrote no registry (the stub never produced one).
assert_file_absent "build failure -> no findings.jsonl under the staged OUTPUT_DIR" \
  "$OUT_FAIL/findings.jsonl"

# ===========================================================================
# Part D — end-of-run summary echo, the registry-ABSENT branch (BEHAVIORAL).
#          Part A pins the present branch (both pointers printed) and Part C
#          pins the guard SOURCE TEXT, but neither RUNS the false branch: when
#          no findings.jsonl exists (the Part B non-fatal build-failure shape),
#          the summary must still print the md deliverable pointer yet stay
#          SILENT on "Finding index:" — no dangling path to a registry that was
#          never produced. The companion present-case replica proves that
#          omission is the file guard firing, not a vacuously-silent block.
# ===========================================================================
echo ""
echo "=== --local summary echo gates the index pointer on the registry existing ==="

# Faithful replica of repolens.sh's end-of-run $LOCAL_MODE summary echo block.
summary_echo_replica() {
  local LOCAL_MODE="$1" OUTPUT_DIR="$2" LOG_BASE="$3"
  if $LOCAL_MODE; then
    echo ""
    echo "Output:       local markdown ($OUTPUT_DIR)"
    if [[ -f "$LOG_BASE/final/findings.jsonl" ]]; then
      echo "Finding index: $LOG_BASE/final/findings.jsonl (+ findings.csv)"
    fi
  fi
}

# Absent case: final/ exists but holds NO findings.jsonl (the Part B failure shape).
SUM_BASE="$TMP_ROOT/summary"
mkdir -p "$SUM_BASE/absent/final" "$SUM_BASE/absent/out"
absent_out="$(summary_echo_replica true "$SUM_BASE/absent/out" "$SUM_BASE/absent")"

# The md deliverable pointer is unconditional in local mode...
TOTAL=$((TOTAL + 1))
if printf '%s\n' "$absent_out" | grep -qF 'local markdown ('; then
  pass_with "summary still prints the md deliverable pointer when no registry exists"
else
  fail_with "summary still prints the md deliverable pointer when no registry exists" \
    "output was: $absent_out"
fi
# ...but the index pointer must be SILENT — no dangling path to a missing registry.
TOTAL=$((TOTAL + 1))
if printf '%s\n' "$absent_out" | grep -qF 'Finding index:'; then
  fail_with "summary omits 'Finding index:' when findings.jsonl is absent" \
    "printed a dangling index path: $absent_out"
else
  pass_with "summary omits 'Finding index:' when findings.jsonl is absent"
fi

# Present case: the SAME replica DOES surface the index when findings.jsonl exists,
# proving the omission above is the file guard firing — not a vacuously-silent block.
mkdir -p "$SUM_BASE/present/final" "$SUM_BASE/present/out"
: > "$SUM_BASE/present/final/findings.jsonl"
present_out="$(summary_echo_replica true "$SUM_BASE/present/out" "$SUM_BASE/present")"
TOTAL=$((TOTAL + 1))
if printf '%s\n' "$present_out" | grep -qF 'Finding index:'; then
  pass_with "summary surfaces 'Finding index:' when findings.jsonl exists (guard is live)"
else
  fail_with "summary surfaces 'Finding index:' when findings.jsonl exists (guard is live)" \
    "expected an index pointer; output was: $present_out"
fi

# ===========================================================================
# Part C — static wiring assertions against repolens.sh. --dry-run exits before
#          finalize, so the genuinely-new source surface (the $LOCAL_MODE block)
#          is asserted directly in the file: it must exist, be OUTPUT_DIR-aware,
#          non-fatal, and distinct from the existing `! $LOCAL_MODE` non-local hook.
# ===========================================================================
echo ""
echo "=== repolens.sh carries the --local registry wiring ==="

if [[ ! -f "$REPOLENS_SH" ]]; then
  echo "  (skip) repolens.sh not found at $REPOLENS_SH — wiring assertions skipped"
  finish
fi

# Locate the LOCAL-gated build_finding_registry call: among all call sites, the
# one whose preceding window opens with a positive `if $LOCAL_MODE` guard (NOT the
# negated `! $LOCAL_MODE` non-local block). Implementation may pass OUTPUT_DIR as
# the 2nd arg or rely on the OUTPUT_DIR global default — both are accepted, so we
# key on the guard, not the exact arg list.
local_call_ln=""
while IFS=: read -r ln _; do
  [[ -n "$ln" ]] || continue
  win_start=$(( ln > 6 ? ln - 6 : 1 ))
  guard_block="$(sed -n "${win_start},${ln}p" "$REPOLENS_SH")"
  if printf '%s' "$guard_block" | grep -qE 'if[[:space:]]+\$LOCAL_MODE' \
     && ! printf '%s' "$guard_block" | grep -qF '! $LOCAL_MODE'; then
    local_call_ln="$ln"
    break
  fi
done < <(grep -nF 'build_finding_registry "$RUN_ID"' "$REPOLENS_SH")

TOTAL=$((TOTAL + 1))
if [[ -n "$local_call_ln" ]]; then
  pass_with "repolens.sh has a \$LOCAL_MODE-gated build_finding_registry call"
else
  fail_with "repolens.sh has a \$LOCAL_MODE-gated build_finding_registry call" \
    "no build_finding_registry call found under a positive 'if \$LOCAL_MODE' guard"
fi

# The local block must be OUTPUT_DIR-aware (guards on / passes $OUTPUT_DIR so the
# local-md ingestion path runs) and NON-FATAL (warns, never die / flips run state).
TOTAL=$((TOTAL + 1))
if [[ -n "$local_call_ln" ]]; then
  blk_start=$(( local_call_ln > 6 ? local_call_ln - 6 : 1 ))
  blk_end=$(( local_call_ln + 6 ))
  block="$(sed -n "${blk_start},${blk_end}p" "$REPOLENS_SH")"
  if printf '%s' "$block" | grep -qF 'OUTPUT_DIR' \
     && printf '%s' "$block" | grep -q 'log_warn' \
     && ! printf '%s' "$block" | grep -qw 'die' \
     && ! printf '%s' "$block" | grep -qE 'RUN_ROUNDS_RC=' \
     && ! printf '%s' "$block" | grep -qE 'REPOLENS_FINAL_STATE='; then
    pass_with "local registry block is OUTPUT_DIR-aware + non-fatal (log_warn, no die/state-flip)"
  else
    fail_with "local registry block is OUTPUT_DIR-aware + non-fatal (log_warn, no die/state-flip)" \
      "block window: $block"
  fi
else
  fail_with "local registry block is OUTPUT_DIR-aware + non-fatal (log_warn, no die/state-flip)" \
    "local build_finding_registry call not found — wiring absent"
fi

# The end-of-run summary's "Finding index:" pointer must be gated on the registry
# actually existing — else a run whose build failed (Part B) would print a dangling
# path to a nonexistent findings.jsonl. e2e (Part A) only exercises the present
# branch; pin the guard statically so the absent branch can't regress into a lie.
TOTAL=$((TOTAL + 1))
idx_ln="$(grep -nF 'Finding index' "$REPOLENS_SH" | head -1 | cut -d: -f1)"
if [[ -n "$idx_ln" ]]; then
  win_start=$(( idx_ln > 5 ? idx_ln - 5 : 1 ))
  idx_win="$(sed -n "${win_start},${idx_ln}p" "$REPOLENS_SH")"
  if printf '%s' "$idx_win" | grep -qE '\[\[[[:space:]]+-f.*findings\.jsonl'; then
    pass_with "summary 'Finding index' pointer is gated on findings.jsonl existing (no dangling path)"
  else
    fail_with "summary 'Finding index' pointer is gated on findings.jsonl existing (no dangling path)" \
      "no '[[ -f ... findings.jsonl ]]' guard in the 5 lines above the 'Finding index' echo"
  fi
else
  fail_with "summary 'Finding index' pointer is gated on findings.jsonl existing (no dangling path)" \
    "no 'Finding index' echo found in repolens.sh — summary pointer wiring absent"
fi

finish
