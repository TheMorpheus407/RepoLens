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

# Behavioral coverage for issue #308 — write logs/latest-result.json at finalize.
#
# At the end of a completed run, RepoLens must emit a single canonical pointer
# file at the TOP of the logs tree ($SCRIPT_DIR/logs/latest-result.json)
# describing the run that just finished. This suite has two harnesses:
#
#   Part A — full mock-agent run (audit mode, single lens) inside an isolated
#            symlink-farm logs tree. Proves the pointer is actually produced at
#            finalize with the core fields, that findings/manifest are ABSOLUTE
#            paths under the finished run's final/, and discarded_runs == [].
#            This part is signature-independent: it exercises observable
#            end-to-end behavior, not the internal helper.
#
#   Part B — unit test of the lib function write_latest_result_pointer against a
#            hand-built summary.json + manifest.json. Pins the `counts` grouping
#            by NORMALIZED severity (the only non-trivial logic) and the
#            MANDATORY non-fatal failure path: an unwritable logs dir must NOT
#            change the caller's exit code and must log a warning.
#
#            The function contract (from the issue + planner) is:
#              write_latest_result_pointer <logs_dir> <run_id> <mode> <agent> \
#                  <summary_file> <status> <final_dir>
#            writing <logs_dir>/latest-result.json, mapping summary
#            started_at/completed_at -> started_at/finished_at, and deriving
#            findings/manifest paths from <final_dir>.
#
# CLAUDE.md hard rule: NO real models. Part A drives tests/mock-agent.sh through
# a fake `codex` on PATH; Part B calls the lib function directly.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
TOTAL=0
KEEP_ARTIFACTS=0
TMP_ROOT=""

# shellcheck disable=SC2329  # cleanup is invoked indirectly via 'trap cleanup EXIT' below.
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
  if [[ "$expected" == "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected: $expected | Actual: $actual"
  fi
}

assert_file_exists() {
  local desc="$1" file="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$file" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected file at $file"
  fi
}

# assert_jq_true <desc> <file> <filter> — filter must evaluate truthy under jq -e.
assert_jq_true() {
  local desc="$1" file="$2" filter="$3"
  TOTAL=$((TOTAL + 1))
  if jq -e "$filter" "$file" >/dev/null 2>&1; then
    pass_with "$desc"
  else
    fail_with "$desc" "jq filter not truthy: $filter (file: $file)"
  fi
}

# assert_jq_eq <desc> <file> <filter> <expected>
assert_jq_eq() {
  local desc="$1" file="$2" filter="$3" expected="$4" actual
  TOTAL=$((TOTAL + 1))
  actual="$(jq -r "$filter" "$file" 2>/dev/null || printf '__jq_error__')"
  if [[ "$expected" == "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected: $expected | Actual: $actual | Filter: $filter"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "needle '$needle' not found"
  fi
}

finish() {
  echo ""
  echo "Results: $PASS/$TOTAL passed, $FAIL failed"
  [[ "$FAIL" -gt 0 ]] && exit 1
  exit 0
}

parse_run_id() {
  sed -n 's/.*RepoLens run \([^ ]*\) starting.*/\1/p' "$1" | head -1
}

TMP_ROOT="$(mktemp -d)"

# ---------------------------------------------------------------------------
# Part A — end-to-end: a completed run writes logs/latest-result.json
# ---------------------------------------------------------------------------
echo "=== latest-result.json written at finalize (issue #308) ==="

# Symlink farm: isolate $SCRIPT_DIR/logs so the pointer (and the run dir) land
# in the farm, never the real logs tree. repolens derives its logs base from its
# own location, so symlinking the entry point + libs gives a fully isolated run.
FARM="$TMP_ROOT/farm"
mkdir -p "$FARM/logs"
for item in repolens.sh lib config prompts; do
  ln -s "$SCRIPT_DIR/$item" "$FARM/$item"
done

# Throwaway git repo to audit.
PROJECT_DIR="$TMP_ROOT/project"
mkdir -p "$PROJECT_DIR"
git -C "$PROJECT_DIR" init -q
printf '# RepoLens issue 308 fixture\n' > "$PROJECT_DIR/README.md"
git -C "$PROJECT_DIR" add README.md
git -C "$PROJECT_DIR" -c user.name='RepoLens Test' -c user.email='repolens@example.invalid' \
  commit -q -m 'fixture'

# Fake `codex` that defers to the deterministic mock agent.
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

assert_eq "completed audit run exits successfully" "0" "$run_rc"

RUN_ID="$(parse_run_id "$run_output")"
assert_eq "run id is discoverable from output" "set" \
  "$([[ -n "$RUN_ID" ]] && printf 'set' || printf 'missing')"

POINTER="$FARM/logs/latest-result.json"

# Acceptance: pointer exists and is valid JSON.
assert_file_exists "latest-result.json exists at top of logs tree" "$POINTER"
assert_jq_true "latest-result.json is valid JSON" "$POINTER" '.'

# Acceptance: run_id matches the finished run, plus all core fields present.
assert_jq_eq "pointer run_id equals the finished run" "$POINTER" '.run_id' "$RUN_ID"
for field in run_id mode agent started_at finished_at status findings manifest counts discarded_runs; do
  assert_jq_true "pointer has '$field'" "$POINTER" "has(\"$field\")"
done

assert_jq_eq "pointer mode is audit" "$POINTER" '.mode' "audit"
assert_jq_eq "pointer agent is codex" "$POINTER" '.agent' "codex"
assert_jq_true "pointer status is a non-empty string" "$POINTER" '(.status | type == "string") and (.status | length > 0)'
assert_jq_true "pointer started_at is non-empty" "$POINTER" '(.started_at | type == "string") and (.started_at | length > 0)'
assert_jq_true "pointer finished_at is non-empty" "$POINTER" '(.finished_at | type == "string") and (.finished_at | length > 0)'

# Acceptance: findings/manifest are ABSOLUTE paths under the finished run's final/.
assert_jq_true "findings path is absolute" "$POINTER" '.findings | startswith("/")'
assert_jq_true "manifest path is absolute" "$POINTER" '.manifest | startswith("/")'
assert_jq_true "findings path points under <run-id>/final/findings.jsonl" "$POINTER" \
  "(.findings | endswith(\"/$RUN_ID/final/findings.jsonl\"))"
assert_jq_true "manifest path points under <run-id>/final/manifest.json" "$POINTER" \
  "(.manifest | endswith(\"/$RUN_ID/final/manifest.json\"))"

# Acceptance: discarded_runs placeholder, counts is an object (no manifest in a
# local audit run -> {} is the correct "else" branch).
assert_jq_true "discarded_runs is an empty array" "$POINTER" '(.discarded_runs | type == "array") and (.discarded_runs | length == 0)'
assert_jq_true "counts is an object" "$POINTER" '.counts | type == "object"'

# ---------------------------------------------------------------------------
# Part B — unit: counts grouping by normalized severity + non-fatal failure
# ---------------------------------------------------------------------------
echo ""
echo "=== write_latest_result_pointer unit behavior ==="

RP_LIB="$SCRIPT_DIR/lib/result_pointer.sh"
CORE_LIB="$SCRIPT_DIR/lib/core.sh"
LOG_LIB="$SCRIPT_DIR/lib/logging.sh"

# run_pointer <logs_dir> <summary_file> <status> <final_dir>  (stderr -> $UNIT_ERR)
# Calls the lib function in an isolated shell with the documented signature.
UNIT_ERR=""
run_pointer() {
  local logs_dir="$1" summary_file="$2" status="$3" final_dir="$4"
  UNIT_ERR="$(mktemp "$TMP_ROOT/unit-err.XXXXXX")"
  bash -c '
    set -uo pipefail
    source "$1"   # core.sh   (severity_normalize)
    source "$2"   # logging.sh (log_warn)
    source "$3"   # result_pointer.sh (function under test)
    write_latest_result_pointer "$4" "unit-run-id" "audit" "codex" "$5" "$6" "$7"
  ' _ "$CORE_LIB" "$LOG_LIB" "$RP_LIB" "$logs_dir" "$summary_file" "$status" "$final_dir" \
    2>"$UNIT_ERR"
  return $?
}

if [[ ! -f "$RP_LIB" ]]; then
  # Red phase before implementation: record the dependency explicitly so the
  # failure is legible, then fall through (the calls below also fail cleanly).
  fail_with "lib/result_pointer.sh exists" "Missing $RP_LIB"
fi

# --- B1: happy path with a manifest carrying mixed/dirty severities ---
UNIT_LOGS="$TMP_ROOT/unit-logs"
UNIT_FINAL="$TMP_ROOT/unit-final"
mkdir -p "$UNIT_LOGS" "$UNIT_FINAL"

cat > "$TMP_ROOT/unit-summary.json" <<'JSON'
{
  "run_id": "unit-run-id",
  "mode": "audit",
  "agent": "codex",
  "started_at": "2026-06-01T00:00:00Z",
  "completed_at": "2026-06-01T01:00:00Z",
  "stopped_reason": null
}
JSON

# Mixed casing + bracketed display form + an invalid severity + a non-finding
# object (no severity). severity_normalize must canonicalize and skip the rest.
cat > "$UNIT_FINAL/manifest.json" <<'JSON'
[
  {"severity": "critical", "title": "c1"},
  {"severity": "high",     "title": "h1"},
  {"severity": "HIGH",     "title": "h2"},
  {"severity": "[Medium]", "title": "m1"},
  {"severity": "low",      "title": "l1"},
  {"severity": "info",     "title": "invalid-should-be-skipped"},
  {"title": "cross-link action with no severity"}
]
JSON

run_pointer "$UNIT_LOGS" "$TMP_ROOT/unit-summary.json" "finished" "$UNIT_FINAL"
unit_rc=$?
UNIT_POINTER="$UNIT_LOGS/latest-result.json"

assert_eq "unit happy-path returns 0" "0" "$unit_rc"
assert_file_exists "unit run writes latest-result.json" "$UNIT_POINTER"
assert_jq_true "unit pointer is valid JSON" "$UNIT_POINTER" '.'

# started_at/completed_at -> started_at/finished_at mapping.
assert_jq_eq "started_at copied from summary" "$UNIT_POINTER" '.started_at' "2026-06-01T00:00:00Z"
assert_jq_eq "finished_at mapped from summary completed_at" "$UNIT_POINTER" '.finished_at' "2026-06-01T01:00:00Z"
assert_jq_eq "status reflects the passed value" "$UNIT_POINTER" '.status' "finished"

# findings/manifest derived from final_dir.
assert_jq_eq "findings path under final_dir" "$UNIT_POINTER" '.findings' "$UNIT_FINAL/findings.jsonl"
assert_jq_eq "manifest path under final_dir" "$UNIT_POINTER" '.manifest' "$UNIT_FINAL/manifest.json"

# counts grouped by NORMALIZED severity; invalid + no-severity entries skipped.
assert_jq_eq "counts.critical == 1" "$UNIT_POINTER" '.counts.critical' "1"
assert_jq_eq "counts.high == 2 (high + HIGH)" "$UNIT_POINTER" '.counts.high' "2"
assert_jq_eq "counts.medium == 1 ([Medium] normalized)" "$UNIT_POINTER" '.counts.medium' "1"
assert_jq_eq "counts.low == 1" "$UNIT_POINTER" '.counts.low' "1"
assert_jq_true "invalid severity is not counted" "$UNIT_POINTER" '(.counts | has("info")) | not'
assert_jq_true "discarded_runs is []" "$UNIT_POINTER" '(.discarded_runs | type == "array") and (.discarded_runs | length == 0)'

# --- B2: no manifest -> counts is {} ---
UNIT_LOGS2="$TMP_ROOT/unit-logs2"
UNIT_FINAL2="$TMP_ROOT/unit-final2"
mkdir -p "$UNIT_LOGS2" "$UNIT_FINAL2"   # final2 has no manifest.json

run_pointer "$UNIT_LOGS2" "$TMP_ROOT/unit-summary.json" "finished-empty" "$UNIT_FINAL2"
assert_eq "unit no-manifest returns 0" "0" "$?"
assert_jq_true "counts is {} when no manifest present" "$UNIT_LOGS2/latest-result.json" '.counts == {}'

# --- B3: non-fatal failure path (unwritable logs target) ---
# logs_dir is a regular FILE, so the pointer can never be created regardless of
# the atomic-write technique. The function must swallow the error: return 0 and
# log a warning. This is the failure-path coverage required for '|| log_warn'.
BAD_LOGS="$TMP_ROOT/not-a-dir"
: > "$BAD_LOGS"   # create as a regular file

run_pointer "$BAD_LOGS" "$TMP_ROOT/unit-summary.json" "finished" "$UNIT_FINAL"
fail_rc=$?
assert_eq "unwritable logs dir does not change exit code (returns 0)" "0" "$fail_rc"
assert_contains "a warning is logged on pointer-write failure" "[WARN]" "$(cat "$UNIT_ERR" 2>/dev/null || true)"

# ---------------------------------------------------------------------------
# Part C — additional branch coverage (coverage-test stage, issue #308)
#
# Exercises write_latest_result_pointer branches the test-dev suite (Parts A/B)
# did not reach: the manifest-present-but-no-valid-severities path (distinct
# from B2's no-manifest case), malformed/non-array and corrupt manifests, and
# the missing-summary defensive branch. Each pins the documented field values
# AND the non-fatal contract (rc 0 + a complete, valid pointer) — a finalize
# helper must never abort the run on a degenerate or absent input.
# ---------------------------------------------------------------------------
echo ""
echo "=== write_latest_result_pointer branch coverage ==="

# --- C1: manifest present but ZERO findings ([]) -> counts == {} ---------------
# Distinct from B2 (no manifest FILE). run_synthesizer writes an empty array for
# a zero-findings run, so final/manifest.json can exist yet hold no severities;
# the `(( ${#_sev_counts[@]} > 0 ))` guard must leave counts as {} (not error,
# not absent).
UNIT_FINAL_EMPTY="$TMP_ROOT/unit-final-empty"
UNIT_LOGS_EMPTY="$TMP_ROOT/unit-logs-empty"
mkdir -p "$UNIT_FINAL_EMPTY" "$UNIT_LOGS_EMPTY"
printf '[]\n' > "$UNIT_FINAL_EMPTY/manifest.json"
run_pointer "$UNIT_LOGS_EMPTY" "$TMP_ROOT/unit-summary.json" "finished-empty" "$UNIT_FINAL_EMPTY"
assert_eq "empty-array manifest returns 0" "0" "$?"
assert_file_exists "empty-array manifest still writes pointer" "$UNIT_LOGS_EMPTY/latest-result.json"
assert_jq_true "counts is {} for an empty-array manifest" "$UNIT_LOGS_EMPTY/latest-result.json" '.counts == {}'

# --- C2: manifest present with only invalid / no-severity entries -> counts {} -
# The while-loop iterates every entry but severity_normalize skips all of them
# (info, empty string, and a no-severity cross-link object), so _sev_counts
# stays empty and counts must collapse to {} rather than a partial object.
UNIT_FINAL_SKIP="$TMP_ROOT/unit-final-skip"
UNIT_LOGS_SKIP="$TMP_ROOT/unit-logs-skip"
mkdir -p "$UNIT_FINAL_SKIP" "$UNIT_LOGS_SKIP"
cat > "$UNIT_FINAL_SKIP/manifest.json" <<'JSON'
[
  {"severity": "info", "title": "not-a-real-severity"},
  {"severity": "",     "title": "empty-severity"},
  {"title": "cross-link action with no severity field"}
]
JSON
run_pointer "$UNIT_LOGS_SKIP" "$TMP_ROOT/unit-summary.json" "finished" "$UNIT_FINAL_SKIP"
assert_eq "all-skipped manifest returns 0" "0" "$?"
assert_jq_true "counts is {} when every manifest entry is skipped" "$UNIT_LOGS_SKIP/latest-result.json" '.counts == {}'

# --- C3: malformed manifest (JSON object, not array) -> counts {}, rc 0 --------
# The `if type=="array" then .[] else empty end` guard must treat a non-array
# manifest as zero findings instead of crashing finalize.
UNIT_FINAL_OBJ="$TMP_ROOT/unit-final-obj"
UNIT_LOGS_OBJ="$TMP_ROOT/unit-logs-obj"
mkdir -p "$UNIT_FINAL_OBJ" "$UNIT_LOGS_OBJ"
printf '{"not":"an array"}\n' > "$UNIT_FINAL_OBJ/manifest.json"
run_pointer "$UNIT_LOGS_OBJ" "$TMP_ROOT/unit-summary.json" "finished" "$UNIT_FINAL_OBJ"
assert_eq "non-array manifest returns 0" "0" "$?"
assert_jq_true "non-array manifest still yields a valid pointer" "$UNIT_LOGS_OBJ/latest-result.json" '.'
assert_jq_true "counts is {} for a non-array manifest" "$UNIT_LOGS_OBJ/latest-result.json" '.counts == {}'

# --- C4: corrupt (non-JSON) manifest -> counts {}, rc 0 ------------------------
# The manifest read is `jq ... 2>/dev/null` inside a process substitution; a
# corrupt file must be swallowed (no output) and not abort the pointer write.
UNIT_FINAL_GARBAGE="$TMP_ROOT/unit-final-garbage"
UNIT_LOGS_GARBAGE="$TMP_ROOT/unit-logs-garbage"
mkdir -p "$UNIT_FINAL_GARBAGE" "$UNIT_LOGS_GARBAGE"
printf 'this is not json at all <<<\n' > "$UNIT_FINAL_GARBAGE/manifest.json"
run_pointer "$UNIT_LOGS_GARBAGE" "$TMP_ROOT/unit-summary.json" "finished" "$UNIT_FINAL_GARBAGE"
assert_eq "corrupt manifest returns 0" "0" "$?"
assert_jq_true "corrupt manifest still yields a valid pointer" "$UNIT_LOGS_GARBAGE/latest-result.json" '.'
assert_jq_true "counts is {} for a corrupt manifest" "$UNIT_LOGS_GARBAGE/latest-result.json" '.counts == {}'

# --- C5: missing summary file -> empty timestamps, rc 0, pointer still written -
# finalize writes summary.json before calling the helper, but the function
# guards `[[ -f "$summary_file" ]]`; the false branch must leave started_at /
# finished_at empty and STILL emit a complete, valid pointer (status + all core
# fields), never aborting the run.
UNIT_LOGS_NOSUM="$TMP_ROOT/unit-logs-nosum"
mkdir -p "$UNIT_LOGS_NOSUM"
run_pointer "$UNIT_LOGS_NOSUM" "$TMP_ROOT/does-not-exist-summary.json" "failed" "$UNIT_FINAL2"
assert_eq "missing summary returns 0" "0" "$?"
assert_file_exists "missing summary still writes pointer" "$UNIT_LOGS_NOSUM/latest-result.json"
assert_jq_true "missing-summary pointer is valid JSON" "$UNIT_LOGS_NOSUM/latest-result.json" '.'
assert_jq_eq "started_at is empty when summary absent" "$UNIT_LOGS_NOSUM/latest-result.json" '.started_at' ""
assert_jq_eq "finished_at is empty when summary absent" "$UNIT_LOGS_NOSUM/latest-result.json" '.finished_at' ""
assert_jq_eq "status still passed through with summary absent" "$UNIT_LOGS_NOSUM/latest-result.json" '.status' "failed"
for field in run_id mode agent started_at finished_at status findings manifest counts discarded_runs; do
  assert_jq_true "pointer still has '$field' with summary absent" "$UNIT_LOGS_NOSUM/latest-result.json" "has(\"$field\")"
done

finish
