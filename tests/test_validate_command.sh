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

#
# TDD tests for issue #379 — Post-Audit Issue Validator (`--validate <file>`).
#
# The issue proposes a decoupled post-audit command:
#     repolens --validate ./findings.json --agent claude
# that ingests an existing findings artifact produced by a cheap "Radar" model,
# re-verifies each finding with a flagship "Filter" model, and emits a cleaned
# result containing only the verified findings (dropping the cheap model's false
# positives). See research.md §1/§6 (Approach C — cleaned-output slice first).
#
# These tests define the BEHAVIORAL CONTRACT of the `--validate` CLI flag and are
# written BEFORE any implementation exists, so they are expected to FAIL (red)
# today — `--validate` currently dies with "Unknown argument". A reasonable
# implementation of the issue's slice-1 must make them pass.
#
# What is pinned here (all grounded in the issue + research, NOT in guessed
# internals):
#   * `--validate <file>` is a recognized flag that consumes a file argument.
#   * A missing / nonexistent / malformed input is rejected LOUDLY (non-zero,
#     clear error) — never half-processed, never a silent success.
#   * An empty findings artifact is a graceful no-op (0 findings, exit 0, no
#     flagship dispatch).
#   * A flagship VERDICT of VERIFIED keeps the finding; WRONG drops it as a
#     false positive; the verified/dropped counts are REPORTED, not silently
#     truncated (mirrors the established `--min-severity` / `findings_filtered`
#     reporting ethos — research §2.5, §5 "No silent truncation").
#   * A flagship agent FAILURE is surfaced, not swallowed into "everything is a
#     false positive" (the rc=0-observability class of bug the harness warns
#     about; consistent with lib/verify.sh returning non-zero on agent trouble).
#
# What is deliberately NOT pinned (genuinely undecided per research):
#   * the STALE downrank-vs-drop policy (research §8.3),
#   * the exact cleaned-output filename/schema,
#   * whether survivors are also filed to a forge (Approach A, a later slice).
#
# NO REAL MODEL IS EVER INVOKED (CLAUDE.md::Tests): a fake `codex` on PATH is the
# only "agent"; it logs its invocations and emits a controllable verifier-style
# verdict (or a forced failure). Every run is bounded by `timeout` so a partial
# implementation can never hang the suite.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$SCRIPT_DIR/repolens.sh"

TMP_PARENT="$SCRIPT_DIR/logs/test-validate-command"
mkdir -p "$TMP_PARENT"
TMPDIR="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"

FAKE_BIN="$TMPDIR/bin"
AGENT_LOG="$TMPDIR/agent-invocations.log"
PROJECT="$TMPDIR/project"
LAST_OUT=""
LAST_RC=0

# Snapshot logs/ so any run dir a `--validate` invocation creates is removed at
# EXIT (logs/ is runtime-only + gitignored). run-all.sh runs suites serially, so
# a before/after diff attributes new dirs to this suite alone.
LOGS_DIR="$SCRIPT_DIR/logs"
LOGS_BEFORE="$TMPDIR/logs-before.txt"
# shellcheck disable=SC2012  # ls basenames here must pair with the ls in cleanup() so grep -qxF/rm match.
ls -1 "$LOGS_DIR" 2>/dev/null | sort > "$LOGS_BEFORE" || true

# shellcheck disable=SC2329  # invoked indirectly via 'trap cleanup EXIT'.
cleanup() {
  local d
  if [[ -d "$LOGS_DIR" && -f "$LOGS_BEFORE" ]]; then
    while IFS= read -r d; do
      [[ -n "$d" ]] || continue
      grep -qxF "$d" "$LOGS_BEFORE" 2>/dev/null || rm -rf "${LOGS_DIR:?}/$d"
    done < <(ls -1 "$LOGS_DIR" 2>/dev/null)
  fi
  rm -rf "$TMPDIR"
  rmdir "$TMP_PARENT" 2>/dev/null || true
}
trap cleanup EXIT

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
  [[ -n "$detail" ]] && printf '    %s\n' "$detail"
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected: '$expected' | Actual: '$actual'"
  fi
}

assert_nonzero() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -ne 0 ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected non-zero exit, got 0"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Did not find '$needle' in output:
$haystack"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Did not expect '$needle' in output:
$haystack"
  fi
}

# Case-insensitive extended-regex match against captured output. grep is
# line-oriented, so a pattern only matches within a single line — which keeps the
# count assertions below (e.g. "1 ... dropped") from spuriously matching across
# unrelated lines.
assert_matches_i() {
  local desc="$1" pattern="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if printf '%s\n' "$haystack" | grep -Eiq "$pattern"; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected output to match /$pattern/i:
$haystack"
  fi
}

# ---------------------------------------------------------------------------
# Fixtures.
# ---------------------------------------------------------------------------

# A git repo the flagship "re-reads" for context. `--validate` operates on the
# provided findings file plus the repo on disk; a real repo keeps us safe whether
# or not the command enforces the git-repo check.
mkdir -p "$PROJECT"
git -C "$PROJECT" init -q
printf 'query = "SELECT * FROM users WHERE id = " + user_input  # unsanitized\n' > "$PROJECT/src.py"
git -C "$PROJECT" add -A >/dev/null 2>&1
git -C "$PROJECT" -c user.email=t@t.t -c user.name=t commit -qm init >/dev/null 2>&1

# The stable finding id the flagship verdict references. One finding keeps the
# ingest→verdict join unambiguous regardless of whether the validator batches or
# dispatches per-finding.
FINDING_ID="aaaaaaaaaaaaaaaa"

# A valid single-record findings.jsonl (the documented ingest contract —
# docs/finding-registry-schema.md, all 12 fields populated).
FINDINGS_FILE="$TMPDIR/findings.jsonl"
cat > "$FINDINGS_FILE" <<JSON
{"id":"$FINDING_ID","title":"[HIGH] Unvalidated input concatenated into SQL query","severity":"high","type":"security-vulnerability","domain":"security","lens":"injection","status":"new","primary_location":"src.py:1","confidence":0.8,"duplicate_group":null,"markdown_path":"","validation":{}}
JSON

# An empty findings registry (zero lines) — the documented empty representation
# (schema doc: "Empty run: ... empty findings.jsonl (zero lines)").
EMPTY_FILE="$TMPDIR/empty.jsonl"
: > "$EMPTY_FILE"

# Malformed input — not parseable JSON at all.
MALFORMED_FILE="$TMPDIR/malformed.jsonl"
printf 'this is not json { [ \n' > "$MALFORMED_FILE"

# Flagship verdicts (verifier-style array — research §2.2 / §6 reuse
# verifier.md's VERIFIED/STALE/WRONG protocol). Non-empty notes are required by
# the reused validate_verification_manifest.
VERDICT_VERIFIED="$TMPDIR/verdict-verified.json"
cat > "$VERDICT_VERIFIED" <<JSON
[{"finding_id":"$FINDING_ID","status":"VERIFIED","notes":"src.py:1 concatenates user_input directly into the SQL string; the injection is real."}]
JSON

VERDICT_WRONG="$TMPDIR/verdict-wrong.json"
cat > "$VERDICT_WRONG" <<JSON
[{"finding_id":"$FINDING_ID","status":"WRONG","notes":"src.py:1 actually uses a parameterized query; no injection. This is a false positive."}]
JSON

# Fake `codex` agent: logs each invocation, optionally forces a non-zero failure
# (FAKE_AGENT_RC), otherwise emits the verdict at FAKE_VERDICT_FILE. Ignores its
# args, matching how lib/core.sh dispatches `codex exec --yolo "$prompt"`.
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
[[ -n "${FAKE_AGENT_LOG:-}" ]] && printf 'invoked\n' >> "$FAKE_AGENT_LOG"
if [[ -n "${FAKE_AGENT_RC:-}" && "${FAKE_AGENT_RC}" != "0" ]]; then
  printf 'simulated flagship agent failure (HTTP 500)\n' >&2
  exit "${FAKE_AGENT_RC}"
fi
if [[ -n "${FAKE_VERDICT_FILE:-}" && -f "${FAKE_VERDICT_FILE}" ]]; then
  cat "${FAKE_VERDICT_FILE}"
fi
printf '\nDONE\n'
EOF
chmod +x "$FAKE_BIN/codex"

# run_validate NAME [ENV=VAL ...] -- [repolens args ...]
# Resets the invocation log, injects the fake codex ahead of PATH, and runs
# `repolens.sh --validate ...` non-interactively under a hard timeout. Captures
# merged stdout+stderr into LAST_OUT and the exit code into LAST_RC.
run_validate() {
  local name="$1"; shift
  local -a env_extras=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do env_extras+=("$1"); shift; done
  [[ "${1:-}" == "--" ]] && shift

  : > "$AGENT_LOG"
  LAST_OUT="$TMPDIR/out-$name.txt"
  timeout 30 env -u REPOLENS_MIN_SEVERITY \
      PATH="$FAKE_BIN:$PATH" \
      FAKE_AGENT_LOG="$AGENT_LOG" \
      "${env_extras[@]}" \
    bash "$REPO" \
      --project "$PROJECT" \
      --agent codex \
      --yes \
      "$@" \
    </dev/null > "$LAST_OUT" 2>&1
  LAST_RC=$?
}

agent_was_invoked() { [[ -s "$AGENT_LOG" ]]; }

echo ""
echo "=== Test Suite: post-audit --validate command (issue #379) ==="
echo ""

# ---------------------------------------------------------------------------
# T1 — `--validate <file>` is a RECOGNIZED flag that consumes its file argument.
# Today it dies with "Unknown argument: --validate" (red). A correct impl parses
# it and reaches input handling instead, so "Unknown argument" must be gone.
# ---------------------------------------------------------------------------
echo "Test 1: --validate is a recognized flag (not 'Unknown argument')"
run_validate "recognized" -- --validate "$FINDINGS_FILE"
out="$(cat "$LAST_OUT")"
assert_not_contains "--validate is parsed, not rejected as an unknown argument" \
                    "Unknown argument" "$out"

# ---------------------------------------------------------------------------
# T2 — `--validate` with no following file argument is an error, mirroring every
# other value-taking flag ("Option X requires an argument").
# ---------------------------------------------------------------------------
echo ""
echo "Test 2: --validate with no argument errors out"
run_validate "missing-arg" -- --validate
out="$(cat "$LAST_OUT")"
assert_nonzero "missing --validate argument exits non-zero" "$LAST_RC"
assert_not_contains "missing-arg error is the flag-specific one, not 'Unknown argument'" \
                    "Unknown argument" "$out"
assert_matches_i "missing-arg error names --validate needing a file/argument" \
                 "validate.*(require|argument|file|path)" "$out"

# ---------------------------------------------------------------------------
# T3 — the CLI help (`--help`) documents the new flag, like every other flag.
# ---------------------------------------------------------------------------
echo ""
echo "Test 3: --help usage documents --validate"
help_out="$(timeout 15 bash "$REPO" --help 2>&1)"
assert_contains "usage/help lists the --validate flag" "--validate" "$help_out"

# ---------------------------------------------------------------------------
# T4 — a nonexistent input file is rejected LOUDLY, with no flagship dispatch.
# Silently proceeding (or treating a missing file as "0 findings") would let a
# typo'd path masquerade as a clean audit.
# ---------------------------------------------------------------------------
echo ""
echo "Test 4: a nonexistent input file is rejected, no agent dispatched"
run_validate "nonexistent" -- --validate "$TMPDIR/does-not-exist.jsonl"
out="$(cat "$LAST_OUT")"
assert_nonzero "nonexistent input file exits non-zero" "$LAST_RC"
assert_matches_i "nonexistent input error is clear (not found / no such / readable)" \
                 "not found|no such|does not exist|not readable|cannot (read|open)" "$out"
TOTAL=$((TOTAL + 1))
if agent_was_invoked; then
  fail_with "nonexistent input does not dispatch the flagship agent" \
            "agent invocation log is non-empty: $(cat "$AGENT_LOG")"
else
  pass_with "nonexistent input does not dispatch the flagship agent"
fi

# ---------------------------------------------------------------------------
# T5 — malformed JSON input is rejected with a clear error, never half-processed
# (research §7 "reject with a clear error rather than half-processing").
# ---------------------------------------------------------------------------
echo ""
echo "Test 5: malformed JSON input is rejected, not half-processed"
run_validate "malformed" -- --validate "$MALFORMED_FILE"
out="$(cat "$LAST_OUT")"
assert_nonzero "malformed input exits non-zero" "$LAST_RC"
TOTAL=$((TOTAL + 1))
if agent_was_invoked; then
  fail_with "malformed input does not dispatch the flagship agent" \
            "agent invocation log is non-empty: $(cat "$AGENT_LOG")"
else
  pass_with "malformed input does not dispatch the flagship agent"
fi

# ---------------------------------------------------------------------------
# T6 — an EMPTY findings artifact is a graceful no-op: 0 findings, exit 0, and no
# flagship dispatch (nothing to pay the expensive model for). research §8.2.
# ---------------------------------------------------------------------------
echo ""
echo "Test 6: an empty findings artifact is a graceful 0-finding no-op"
run_validate "empty" -- --validate "$EMPTY_FILE"
out="$(cat "$LAST_OUT")"
assert_eq "empty input exits 0 (graceful)" "0" "$LAST_RC"
assert_matches_i "empty input reports there is nothing to validate" \
                 "nothing to validate|no findings|0 findings|empty" "$out"
TOTAL=$((TOTAL + 1))
if agent_was_invoked; then
  fail_with "empty input does not dispatch the flagship agent" \
            "agent invocation log is non-empty: $(cat "$AGENT_LOG")"
else
  pass_with "empty input does not dispatch the flagship agent"
fi

# ---------------------------------------------------------------------------
# T7 — the core value: a flagship WRONG verdict DROPS the finding as a false
# positive. The flagship must actually run, the command completes, and the drop
# is REPORTED (1 dropped / 0 verified) — no silent truncation.
# ---------------------------------------------------------------------------
echo ""
echo "Test 7: a WRONG verdict drops the finding and reports the drop"
run_validate "drop-false-positive" FAKE_VERDICT_FILE="$VERDICT_WRONG" -- \
  --validate "$FINDINGS_FILE"
out="$(cat "$LAST_OUT")"
assert_eq "validation run completes (exit 0)" "0" "$LAST_RC"
TOTAL=$((TOTAL + 1))
if agent_was_invoked; then
  pass_with "flagship agent was dispatched for the finding"
else
  fail_with "flagship agent was dispatched for the finding" \
            "agent invocation log is empty"
fi
assert_matches_i "reports one finding dropped as a false positive" \
                 "1[^0-9]*(drop|false[ -]?positive|filter|reject|remov|discard)|(drop|false[ -]?positive|filter|reject|remov|discard)[a-z:() ,-]*1" \
                 "$out"
assert_matches_i "reports zero verified survivors" \
                 "(0|no|zero|none)[^0-9]*(verif|surviv|kept|pass|true[ -]?positive)|(verif|surviv|kept|true[ -]?positive)[a-z:() ,-]*(0|none|zero)" \
                 "$out"

# ---------------------------------------------------------------------------
# T8 — the contrast: a VERIFIED verdict KEEPS the finding (1 verified / 0
# dropped). Proves the validator is not a trivial "drop everything" filter.
# ---------------------------------------------------------------------------
echo ""
echo "Test 8: a VERIFIED verdict keeps the finding and reports the survivor"
run_validate "keep-verified" FAKE_VERDICT_FILE="$VERDICT_VERIFIED" -- \
  --validate "$FINDINGS_FILE"
out="$(cat "$LAST_OUT")"
assert_eq "validation run completes (exit 0)" "0" "$LAST_RC"
TOTAL=$((TOTAL + 1))
if agent_was_invoked; then
  pass_with "flagship agent was dispatched for the finding"
else
  fail_with "flagship agent was dispatched for the finding" \
            "agent invocation log is empty"
fi
assert_matches_i "reports one verified survivor" \
                 "1[^0-9]*(verif|surviv|kept|pass|true[ -]?positive)|(verif|surviv|kept|true[ -]?positive)[a-z:() ,-]*1" \
                 "$out"
assert_matches_i "reports zero dropped false positives" \
                 "(0|no|zero|none)[^0-9]*(drop|false[ -]?positive|filter|reject|discard)|(drop|false[ -]?positive|filter|reject|discard)[a-z:() ,-]*(0|none|zero)" \
                 "$out"

# ---------------------------------------------------------------------------
# T9 — failure path (MANDATORY): the flagship agent hard-fails (non-zero rc). The
# validator MUST surface the failure, not swallow it into a clean "everything was
# a false positive" result (the rc=0-observability class of bug). lib/verify.sh
# returns non-zero on agent trouble; the validator must do the same.
# ---------------------------------------------------------------------------
echo ""
echo "Test 9: a flagship agent failure is surfaced, not swallowed"
run_validate "agent-failure" FAKE_AGENT_RC=42 FAKE_VERDICT_FILE="$VERDICT_VERIFIED" -- \
  --validate "$FINDINGS_FILE"
out="$(cat "$LAST_OUT")"
assert_nonzero "flagship agent failure makes the validation run exit non-zero" "$LAST_RC"
# It must NOT falsely claim the finding was verified/kept off a failed run.
assert_matches_i "flagship failure is not reported as a successful validation" \
                 "fail|error|abort|could not|unable|rate.?limit" "$out"

# ---------------------------------------------------------------------------
# T10 — a STALE verdict is KEPT (not dropped) and reported as stale. STALE is the
# third verdict class (the implementation keeps STALE and only downranks it — it
# is NOT a false positive). T7/T8 only pin WRONG/VERIFIED; the STALE branch (its
# own count + its "kept, not dropped" survivorship) is otherwise unexercised.
# ---------------------------------------------------------------------------
echo ""
echo "Test 10: a STALE verdict keeps the finding (downranked, not dropped)"
VERDICT_STALE="$TMPDIR/verdict-stale.json"
cat > "$VERDICT_STALE" <<JSON
[{"finding_id":"$FINDING_ID","status":"STALE","notes":"The concatenation moved a few lines down in src.py but is still present; citation is stale, not wrong."}]
JSON
run_validate "keep-stale" FAKE_VERDICT_FILE="$VERDICT_STALE" -- \
  --validate "$FINDINGS_FILE"
out="$(cat "$LAST_OUT")"
assert_eq "validation run completes (exit 0)" "0" "$LAST_RC"
TOTAL=$((TOTAL + 1))
if agent_was_invoked; then
  pass_with "flagship agent was dispatched for the finding"
else
  fail_with "flagship agent was dispatched for the finding" \
            "agent invocation log is empty"
fi
assert_matches_i "reports one stale finding" \
                 "1[^0-9]*stale|stale[a-z:() ,-]*1" "$out"
assert_matches_i "STALE finding is KEPT, not dropped (survivor count is 1)" \
                 "1[^0-9]*kept|kept[a-z:() ,-]*1" "$out"
assert_matches_i "reports zero dropped false positives (STALE is not a drop)" \
                 "(0|no|zero|none)[^0-9]*(drop|false[ -]?positive)|(drop|false[ -]?positive)[a-z:() ,-]*(0|none|zero)" \
                 "$out"

# ---------------------------------------------------------------------------
# T11 — join correctness across a MIX of verdicts on multiple findings. With a
# single finding the ingest→verdict join is trivially right; with three findings
# a positional/mismatched join could drop the wrong one while still printing the
# right counts. This pins BOTH the reported tallies (1 verified / 1 dropped / 1
# stale, 2 kept) AND the cleaned-output file content: the WRONG finding is absent
# and the VERIFIED + STALE findings survive — proving the verdicts map back to the
# correct findings by id, not by position.
# ---------------------------------------------------------------------------
echo ""
echo "Test 11: mixed verdicts join to the correct findings by id"
MIXED_FINDINGS="$TMPDIR/findings-mixed.jsonl"
cat > "$MIXED_FINDINGS" <<'JSON'
{"id":"f-verified","title":"[HIGH] Real SQL injection","severity":"high","type":"security-vulnerability","domain":"security","lens":"injection","status":"new","primary_location":"src.py:1","confidence":0.8,"duplicate_group":null,"markdown_path":"","validation":{}}
{"id":"f-wrong","title":"[LOW] Bogus finding about a nonexistent helper","severity":"low","type":"code-smell","domain":"quality","lens":"style","status":"new","primary_location":"src.py:999","confidence":0.3,"duplicate_group":null,"markdown_path":"","validation":{}}
{"id":"f-stale","title":"[MEDIUM] Citation drifted a few lines","severity":"medium","type":"security-vulnerability","domain":"security","lens":"injection","status":"new","primary_location":"src.py:1","confidence":0.6,"duplicate_group":null,"markdown_path":"","validation":{}}
JSON
# Verdicts are DELIBERATELY out of findings order (WRONG first, though f-wrong is
# the SECOND finding). A correct by-id join still drops f-wrong; a buggy positional
# join would instead drop f-verified (findings[0]) — so the cleaned-file content
# assertions below distinguish an id join from a positional one.
VERDICT_MIXED="$TMPDIR/verdict-mixed.json"
cat > "$VERDICT_MIXED" <<'JSON'
[{"finding_id":"f-wrong","status":"WRONG","notes":"src.py has only one line; there is no line 999 and no such helper. False positive."},
 {"finding_id":"f-verified","status":"VERIFIED","notes":"src.py:1 concatenates user_input into the SQL string; the injection is real."},
 {"finding_id":"f-stale","status":"STALE","notes":"The pattern is recognizable nearby but not at the cited line."}]
JSON
run_validate "mixed-verdicts" FAKE_VERDICT_FILE="$VERDICT_MIXED" -- \
  --validate "$MIXED_FINDINGS"
out="$(cat "$LAST_OUT")"
assert_eq "validation run completes (exit 0)" "0" "$LAST_RC"
assert_matches_i "reports one verified survivor" \
                 "1[^0-9]*(verif|surviv)|(verif|surviv)[a-z:() ,-]*1" "$out"
assert_matches_i "reports one dropped false positive" \
                 "1[^0-9]*(drop|false[ -]?positive)|(drop|false[ -]?positive)[a-z:() ,-]*1" "$out"
assert_matches_i "reports one stale finding" \
                 "1[^0-9]*stale|stale[a-z:() ,-]*1" "$out"
assert_matches_i "keeps two survivors (VERIFIED + STALE, not the WRONG one)" \
                 "2[^0-9]*kept|kept[a-z:() ,-]*2" "$out"
# The cleaned output file must contain exactly the survivors, joined by id.
cleaned_path="$(grep -oE '/[^ ]*validated-findings\.jsonl' "$LAST_OUT" | head -n1)"
cleaned_content="$(cat "$cleaned_path" 2>/dev/null || true)"
assert_contains "cleaned output keeps the VERIFIED finding" '"id":"f-verified"' "$cleaned_content"
assert_contains "cleaned output keeps the STALE finding" '"id":"f-stale"' "$cleaned_content"
assert_not_contains "cleaned output drops the WRONG finding (correct id join)" \
                    '"id":"f-wrong"' "$cleaned_content"

# ---------------------------------------------------------------------------
# T12 — a whole-file JSON ARRAY (manifest.json style) is an accepted input, and
# the join key falls back to `cluster_id`. Every fixture above is JSON Lines with
# an `id`; this exercises the other ingest branch (array-typed file) AND the
# cluster_id join-key fallback that manifest.json findings actually use.
# ---------------------------------------------------------------------------
echo ""
echo "Test 12: a manifest.json array input is accepted (cluster_id join key)"
MANIFEST_FILE="$TMPDIR/manifest.json"
cat > "$MANIFEST_FILE" <<'JSON'
[{"cluster_id":"cluster-alpha","title":"[HIGH] Unvalidated input concatenated into SQL query","severity":"high","body":"src.py:1 builds a query by string concatenation of user_input."}]
JSON
VERDICT_CLUSTER="$TMPDIR/verdict-cluster.json"
cat > "$VERDICT_CLUSTER" <<'JSON'
[{"finding_id":"cluster-alpha","status":"VERIFIED","notes":"src.py:1 concatenates user_input into the SQL string; the injection is real."}]
JSON
run_validate "manifest-array" FAKE_VERDICT_FILE="$VERDICT_CLUSTER" -- \
  --validate "$MANIFEST_FILE"
out="$(cat "$LAST_OUT")"
assert_eq "manifest.json array input validates (exit 0)" "0" "$LAST_RC"
TOTAL=$((TOTAL + 1))
if agent_was_invoked; then
  pass_with "flagship agent was dispatched for the manifest finding"
else
  fail_with "flagship agent was dispatched for the manifest finding" \
            "agent invocation log is empty"
fi
assert_matches_i "manifest finding is verified/kept (cluster_id joined)" \
                 "1[^0-9]*(verif|surviv|kept)|(verif|surviv|kept)[a-z:() ,-]*1" "$out"

# ---------------------------------------------------------------------------
# T13 — the flagship SUCCEEDS (rc=0) but returns NO JSON verdict array (e.g. it
# refuses or replies in prose). This is the rc=0-observability sibling of T9: the
# validator must NOT silently treat "no verdicts" as "everything verified". With
# no FAKE_VERDICT_FILE the fake agent emits only a trailing DONE — no array — so
# the extractor finds nothing and the run must error out.
# ---------------------------------------------------------------------------
echo ""
echo "Test 13: a flagship reply with no JSON array errors (not swallowed)"
run_validate "no-verdict-array" -- --validate "$FINDINGS_FILE"
out="$(cat "$LAST_OUT")"
assert_nonzero "an unparseable flagship reply exits non-zero" "$LAST_RC"
TOTAL=$((TOTAL + 1))
if agent_was_invoked; then
  pass_with "flagship agent was dispatched (failure is post-dispatch, unlike T4/T5/T6)"
else
  fail_with "flagship agent was dispatched" "agent invocation log is empty"
fi
assert_matches_i "error names the missing/unparseable verdict array" \
                 "fail|error|did not|no .*(json|verdict|array)|unable|could not" "$out"

# ---------------------------------------------------------------------------
# T14 — the flagship succeeds (rc=0) and returns a JSON array, but the verdicts
# fail schema validation (an out-of-vocabulary status). The reused
# validate_verification_manifest must reject it and the run must error — a
# schema-invalid verdict manifest is never accepted as a clean result.
# ---------------------------------------------------------------------------
echo ""
echo "Test 14: a schema-invalid verdict manifest is rejected"
VERDICT_BADSCHEMA="$TMPDIR/verdict-badschema.json"
cat > "$VERDICT_BADSCHEMA" <<JSON
[{"finding_id":"$FINDING_ID","status":"MAYBE","notes":"an invalid, out-of-vocabulary verdict status."}]
JSON
run_validate "bad-schema" FAKE_VERDICT_FILE="$VERDICT_BADSCHEMA" -- \
  --validate "$FINDINGS_FILE"
out="$(cat "$LAST_OUT")"
assert_nonzero "a schema-invalid verdict manifest exits non-zero" "$LAST_RC"
assert_matches_i "error names the schema/verdict validation failure" \
                 "fail|error|schema|invalid|verdict" "$out"

echo ""
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
