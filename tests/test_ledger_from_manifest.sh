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

# Tests for issue #314: lib/ledger.sh — build_findings_jsonl_from_manifest.
# Maps validated synthesizer manifest clusters onto the canonical finding
# registry (findings.jsonl, schema in docs/finding-registry-schema.md).
# Pure JSON-to-JSON transformation; NO AI models are invoked.
# shellcheck disable=SC2329

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LEDGER_LIB="$SCRIPT_DIR/lib/ledger.sh"

PASS=0
FAIL=0
TOTAL=0

TMP_PARENT="$SCRIPT_DIR/logs/test-ledger-from-manifest"
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

# assert_jq <desc> <jq-filter> <file-or-line> [via_stdin]
#   Passes when `jq -e <filter>` exits 0. When the 4th arg is "stdin" the third
#   arg is treated as a JSON string fed on stdin; otherwise it is a file path.
assert_jq() {
  local desc="$1" filter="$2" subject="$3" mode="${4:-file}"
  TOTAL=$((TOTAL + 1))
  local rc
  if [[ "$mode" == "stdin" ]]; then
    jq -e "$filter" <<<"$subject" >/dev/null 2>&1
    rc=$?
  else
    jq -e "$filter" "$subject" >/dev/null 2>&1
    rc=$?
  fi
  if [[ "$rc" -eq 0 ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "jq filter failed (rc=$rc): $filter"
  fi
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

# --- Source lib/ledger.sh ALONE (must be self-contained) -------------------
# The module deliberately takes no hard dependency on lib/core.sh, so the
# builder must work with ledger sourced on its own (severity normalization
# falls back to an inline replica). Sourcing alone here proves that contract.
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
if declare -F build_findings_jsonl_from_manifest >/dev/null 2>&1; then
  pass_with "build_findings_jsonl_from_manifest is defined after sourcing ledger alone"
else
  fail_with "build_findings_jsonl_from_manifest is defined after sourcing ledger alone" \
    "function not found — implementation pending (TDD red phase)"
  finish
fi

# ---------------------------------------------------------------------------
# Fixture A: a small, valid manifest exercising every status branch and a
# mixed-case severity. Four entries -> four registry lines.
#   entry 0: verification_status "verified" -> status "new"
#   entry 1: verification_status "wrong"    -> status "likely-false-positive"
#   entry 2: verification_status "stale"    -> status "needs-validation"
#   entry 3: no verification_status         -> status "new"
# ---------------------------------------------------------------------------
manifest_a="$TMPDIR/manifest-a.json"
cat > "$manifest_a" <<'JSON'
[
  {
    "cluster_id": "missing-validation::upload-handler",
    "title": "[high] Validate upload filenames before writing files",
    "severity": "High",
    "domain": "code",
    "lens": "input-validation",
    "root_cause_category": "missing-validation",
    "source_finding_paths": [
      "logs/run-1/rounds/round-1/lens-outputs/code/input-validation.md",
      "logs/run-1/rounds/round-2/lens-outputs/code/input-validation.md"
    ],
    "proposed_labels": ["bug", "input-validation"],
    "dedup_against_existing": [],
    "cross_link_actions": [],
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
    "proposed_labels": ["security"],
    "dedup_against_existing": [],
    "cross_link_actions": [],
    "granularity": "independent",
    "verification_status": "wrong",
    "body": "## Summary\nLegacy ciphers."
  },
  {
    "cluster_id": "hardcoded-secret::config",
    "title": "Hardcoded API secret in committed config",
    "severity": "medium",
    "domain": "code",
    "lens": "secrets",
    "root_cause_category": "hardcoded-secret",
    "source_finding_paths": [
      "logs/run-1/rounds/round-1/lens-outputs/code/secrets.md"
    ],
    "proposed_labels": ["security"],
    "dedup_against_existing": [],
    "cross_link_actions": [],
    "granularity": "cluster",
    "verification_status": "stale",
    "body": "## Summary\nSecret in repo."
  },
  {
    "cluster_id": "missing-index::orders-query",
    "title": "Slow orders query missing composite index",
    "severity": "low",
    "domain": "code",
    "lens": "performance",
    "root_cause_category": "missing-index",
    "source_finding_paths": [
      "logs/run-1/rounds/round-1/lens-outputs/code/performance.md"
    ],
    "proposed_labels": ["performance"],
    "dedup_against_existing": [],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "## Summary\nFull scan."
  }
]
JSON

echo "=== build_findings_jsonl_from_manifest: valid manifest ==="

out_a="$TMPDIR/findings-a.jsonl"
build_findings_jsonl_from_manifest "$manifest_a" "$out_a"
rc_a=$?
assert_success "valid manifest returns exit 0" "$rc_a"
assert_file_exists "findings.jsonl is created" "$out_a"

# Acceptance: one line per manifest entry (4 entries -> 4 lines).
line_count="$(wc -l < "$out_a" | tr -d ' ')"
assert_eq "one JSONL line per manifest entry" "4" "$line_count"

# Acceptance: each physical line is independently parseable by `jq -e .`.
all_lines_parse=0
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  if ! jq -e . <<<"$line" >/dev/null 2>&1; then
    all_lines_parse=1
    break
  fi
done < "$out_a"
assert_success "every line independently parses as JSON" "$all_lines_parse"

# Acceptance: each line carries all 12 schema keys plus source_finding_paths,
# even when the value is null (has() is true for present-but-null keys).
keys_present=0
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  if ! jq -e '
      has("id") and has("title") and has("severity") and has("type")
      and has("domain") and has("lens") and has("status")
      and has("primary_location") and has("confidence")
      and has("duplicate_group") and has("markdown_path")
      and has("validation") and has("source_finding_paths")
    ' <<<"$line" >/dev/null 2>&1; then
    keys_present=1
    break
  fi
done < "$out_a"
assert_success "every line has all 12 schema keys + source_finding_paths" "$keys_present"

echo "=== field mapping ==="

# Slurp into an array so we can index entries by manifest order.
records="$(jq -s '.' "$out_a")"

# Acceptance: id matches finding_id for the same domain/lens/title (no location).
expected_id0="$(finding_id "code" "input-validation" "[high] Validate upload filenames before writing files")"
actual_id0="$(jq -r '.[0].id' <<<"$records")"
assert_eq "id matches finding_id for entry 0" "$expected_id0" "$actual_id0"
assert_jq "id has fnd-<12 hex> shape" '.[0].id | test("^fnd-[0-9a-f]{12}$")' "$records" stdin

# Acceptance: severity is normalized (manifest "High" -> "high").
assert_eq "severity normalized: High -> high" \
  "high" "$(jq -r '.[0].severity' <<<"$records")"

# Acceptance: duplicate_group equals the source cluster_id (seed value).
assert_eq "duplicate_group seeded from cluster_id (entry 0)" \
  "missing-validation::upload-handler" "$(jq -r '.[0].duplicate_group' <<<"$records")"
assert_eq "duplicate_group seeded from cluster_id (entry 1)" \
  "weak-crypto::tls-config" "$(jq -r '.[1].duplicate_group' <<<"$records")"

# title / domain / lens copied verbatim.
assert_eq "title copied verbatim" \
  "Weak TLS ciphers enabled on the edge" "$(jq -r '.[1].title' <<<"$records")"
assert_eq "domain copied verbatim" "deployment" "$(jq -r '.[1].domain' <<<"$records")"
assert_eq "lens copied verbatim" "tls" "$(jq -r '.[1].lens' <<<"$records")"

# Acceptance: id matches finding_id for EVERY entry, derived from that entry's
# own domain/lens/title (above only entry 0 is checked). Pins that the per-entry
# id computation reads the current loop entry, not entry 0 or a stale variable —
# a misindexed id would otherwise slip through with only entry 0 asserted.
assert_eq "id matches finding_id for entry 1" \
  "$(finding_id "deployment" "tls" "Weak TLS ciphers enabled on the edge")" \
  "$(jq -r '.[1].id' <<<"$records")"
assert_eq "id matches finding_id for entry 2" \
  "$(finding_id "code" "secrets" "Hardcoded API secret in committed config")" \
  "$(jq -r '.[2].id' <<<"$records")"
assert_eq "id matches finding_id for entry 3" \
  "$(finding_id "code" "performance" "Slow orders query missing composite index")" \
  "$(jq -r '.[3].id' <<<"$records")"

# Distinct domain/lens/title across entries -> distinct ids. Guards against a
# builder that emitted a constant or last-entry id for every line.
assert_jq "ids are unique across all four entries" \
  '([.[].id] | length) == ([.[].id] | unique | length)' "$records" stdin

echo "=== status mapping (conservative) ==="

# verified -> new ; wrong -> likely-false-positive ; stale -> needs-validation ;
# absent -> new.
assert_eq "verification_status verified -> status new" \
  "new" "$(jq -r '.[0].status' <<<"$records")"
assert_eq "verification_status wrong -> status likely-false-positive" \
  "likely-false-positive" "$(jq -r '.[1].status' <<<"$records")"
assert_eq "verification_status stale -> status needs-validation" \
  "needs-validation" "$(jq -r '.[2].status' <<<"$records")"
assert_eq "absent verification_status -> status new" \
  "new" "$(jq -r '.[3].status' <<<"$records")"

echo "=== static / builder-owned fields ==="

# type/confidence/markdown_path are null; primary_location is ""; validation {}.
assert_jq "type is null on every line" 'all(.[]; .type == null)' "$records" stdin
assert_jq "confidence is null on every line" 'all(.[]; .confidence == null)' "$records" stdin
assert_jq "markdown_path is null on every line" 'all(.[]; .markdown_path == null)' "$records" stdin
assert_jq "primary_location is empty string on every line" \
  'all(.[]; .primary_location == "")' "$records" stdin
assert_jq "validation is an empty object on every line" \
  'all(.[]; .validation == {})' "$records" stdin

# source_finding_paths passthrough: entry 0 keeps both of its source paths.
assert_jq "source_finding_paths passthrough preserves the manifest array" \
  '.[0].source_finding_paths == [
     "logs/run-1/rounds/round-1/lens-outputs/code/input-validation.md",
     "logs/run-1/rounds/round-2/lens-outputs/code/input-validation.md"
   ]' "$records" stdin

echo "=== determinism ==="

# Acceptance: id is deterministic across runs -> two builds are byte-identical.
out_a2="$TMPDIR/findings-a2.jsonl"
build_findings_jsonl_from_manifest "$manifest_a" "$out_a2" >/dev/null 2>&1
TOTAL=$((TOTAL + 1))
if diff -q "$out_a" "$out_a2" >/dev/null 2>&1; then
  pass_with "two builds of the same manifest are byte-identical"
else
  fail_with "two builds of the same manifest are byte-identical" \
    "output differs between runs"
fi

echo "=== empty manifest ==="

# Acceptance: empty manifest ([]) -> empty output (0 lines), exit 0.
manifest_empty="$TMPDIR/manifest-empty.json"
printf '[]\n' > "$manifest_empty"
out_empty="$TMPDIR/findings-empty.jsonl"
build_findings_jsonl_from_manifest "$manifest_empty" "$out_empty"
rc_empty=$?
assert_success "empty manifest returns exit 0" "$rc_empty"
assert_file_exists "empty manifest still produces an output file" "$out_empty"
empty_lines="$(wc -l < "$out_empty" | tr -d ' ')"
assert_eq "empty manifest yields 0 output lines" "0" "$empty_lines"

echo "=== metacharacter title (jq owns escaping) ==="

# A title with quotes, shell metacharacters, and unicode must survive intact:
# the builder passes the entry through jq, never string-interpolating the title.
manifest_meta="$TMPDIR/manifest-meta.json"
cat > "$manifest_meta" <<'JSON'
[
  {
    "cluster_id": "meta::edge",
    "title": "Bad \"quote\" and $(rm -rf /) and `backtick` and ünïcödé — 危険",
    "severity": "high",
    "domain": "code",
    "lens": "input-validation",
    "root_cause_category": "edge",
    "source_finding_paths": ["logs/run-1/rounds/round-1/lens-outputs/code/input-validation.md"],
    "proposed_labels": [],
    "dedup_against_existing": [],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "## Summary\nedge."
  }
]
JSON
out_meta="$TMPDIR/findings-meta.jsonl"
build_findings_jsonl_from_manifest "$manifest_meta" "$out_meta"
rc_meta=$?
assert_success "metacharacter manifest returns exit 0" "$rc_meta"

meta_line="$(head -n1 "$out_meta")"
assert_jq "metacharacter line is valid JSON" '.' "$meta_line" stdin
expected_title="$(jq -r '.[0].title' "$manifest_meta")"
actual_title="$(jq -r '.title' <<<"$meta_line")"
assert_eq "metacharacter title round-trips exactly" "$expected_title" "$actual_title"

echo "=== error handling (failure paths) ==="

# Missing arguments -> non-zero, no output written.
build_findings_jsonl_from_manifest >/dev/null 2>&1
assert_failure "missing both arguments returns non-zero" "$?"

build_findings_jsonl_from_manifest "$manifest_a" >/dev/null 2>&1
assert_failure "missing out-path argument returns non-zero" "$?"

# Missing manifest file -> non-zero, no output written.
out_missing="$TMPDIR/findings-missing.jsonl"
build_findings_jsonl_from_manifest "$TMPDIR/does-not-exist.json" "$out_missing" >/dev/null 2>&1
assert_failure "missing manifest file returns non-zero" "$?"
assert_file_missing "no output written when manifest is missing" "$out_missing"

# Manifest that is valid JSON but not an array -> non-zero, no output written.
manifest_obj="$TMPDIR/manifest-obj.json"
printf '{"not":"an array"}\n' > "$manifest_obj"
out_obj="$TMPDIR/findings-obj.jsonl"
build_findings_jsonl_from_manifest "$manifest_obj" "$out_obj" >/dev/null 2>&1
assert_failure "non-array manifest JSON returns non-zero" "$?"
assert_file_missing "no output written when manifest is not an array" "$out_obj"

echo "=== severity_normalize delegated path (lib/core.sh sourced) ==="

# Every assertion above ran with lib/ledger.sh sourced ALONE, so they only
# exercise the inline-replica fallback inside _ledger_severity_normalize. In
# production (repolens.sh sources lib/core.sh too) the helper takes its OTHER
# branch: `declare -F severity_normalize` is true and it delegates to the shared
# severity_normalize. These subshell checks cover that branch without polluting
# the main shell (which must keep ledger sourced alone for the asserts below).
CORE_LIB="$SCRIPT_DIR/lib/core.sh"

# (a) Real delegation end-to-end: source core.sh alongside the already-loaded
#     ledger functions, rebuild, and confirm severity is still normalized.
out_core="$TMPDIR/findings-core.jsonl"
core_sev="$(
  # shellcheck source=/dev/null
  source "$CORE_LIB" 2>/dev/null
  build_findings_jsonl_from_manifest "$manifest_a" "$out_core" >/dev/null 2>&1 \
    && jq -s -r '.[0].severity' "$out_core" 2>/dev/null
)"
assert_eq "severity normalized via shared severity_normalize (core.sh sourced): High -> high" \
  "high" "$core_sev"

# (b) Branch proof: with a severity_normalize stub in scope the helper must
#     delegate to it rather than fall through to the replica. This pins that the
#     declare -F branch is the one taken when severity_normalize exists.
delegated="$(
  severity_normalize() { printf 'DELEGATED-%s' "$1"; }
  _ledger_severity_normalize "high"
)"
assert_eq "_ledger_severity_normalize delegates to severity_normalize when it is defined" \
  "DELEGATED-high" "$delegated"

echo "=== _ledger_severity_normalize replica branches (ledger sourced alone) ==="

# Direct unit coverage of the inline replica's branches. The builder above only
# ever fed "High", so the bracket-stripping branch ([sev] -> sev) and the
# out-of-enum -> "" branch were never exercised. Guard first that the main shell
# really is on the replica path (severity_normalize undefined), otherwise these
# would silently cover the wrong branch.
TOTAL=$((TOTAL + 1))
if declare -F severity_normalize >/dev/null 2>&1; then
  fail_with "severity_normalize is undefined in the main shell (replica path)" \
    "unexpected: lib/core.sh leaked into the main shell"
else
  pass_with "severity_normalize is undefined in the main shell (replica path)"
fi

assert_eq "replica strips [..] wrapper: [high] -> high" \
  "high" "$(_ledger_severity_normalize '[high]')"
assert_eq "replica strips wrapper + inner spaces: [ low ] -> low" \
  "low" "$(_ledger_severity_normalize '[ low ]')"
assert_eq "replica trims whitespace then lowercases: '  Critical  ' -> critical" \
  "critical" "$(_ledger_severity_normalize '  Critical  ')"
assert_eq "replica lowercases all-caps: MEDIUM -> medium" \
  "medium" "$(_ledger_severity_normalize 'MEDIUM')"
assert_eq "replica maps an out-of-enum value to empty string" \
  "" "$(_ledger_severity_normalize 'bogus')"
assert_eq "replica maps empty input to empty string" \
  "" "$(_ledger_severity_normalize '')"

echo "=== builder: out-of-enum severity + unknown verification_status ==="

# Two builder-level defensive paths the Fixture-A run never hit:
#   - a severity outside the enum normalizes to "" and must NOT crash the
#     builder; the line stays valid JSON with severity:"".
#   - verification_status "unknown" is a real enum value (the enum is
#     verified|stale|wrong|unknown); the status map must treat it like an absent
#     status -> "new", not fall into a non-new bucket.
manifest_defensive="$TMPDIR/manifest-defensive.json"
cat > "$manifest_defensive" <<'JSON'
[
  {
    "cluster_id": "weird::sev",
    "title": "Entry with an out-of-enum severity",
    "severity": "Catastrophic",
    "domain": "code",
    "lens": "misc",
    "root_cause_category": "edge",
    "source_finding_paths": ["logs/run-1/rounds/round-1/lens-outputs/code/misc.md"],
    "granularity": "independent",
    "verification_status": "unknown",
    "body": "## Summary\nweird."
  }
]
JSON
out_defensive="$TMPDIR/findings-defensive.jsonl"
build_findings_jsonl_from_manifest "$manifest_defensive" "$out_defensive"
rc_defensive=$?
assert_success "builder tolerates an out-of-enum severity (exit 0)" "$rc_defensive"
def_line="$(head -n1 "$out_defensive")"
assert_jq "out-of-enum-severity line is still valid JSON" '.' "$def_line" stdin
assert_eq "out-of-enum severity normalizes to empty string" \
  "" "$(jq -r '.severity' <<<"$def_line")"
assert_eq "verification_status unknown -> status new" \
  "new" "$(jq -r '.status' <<<"$def_line")"

echo "=== error handling: missing output directory ==="

# A failure path distinct from the missing-args / missing-manifest / non-array
# cases: the manifest is valid, but the output's parent directory does not
# exist, so the atomic tmp write (: > "${out}.tmp.$$") fails. The builder must
# return non-zero and leave no output behind.
out_nodir="$TMPDIR/missing-subdir/findings.jsonl"
build_findings_jsonl_from_manifest "$manifest_a" "$out_nodir" >/dev/null 2>&1
assert_failure "nonexistent output directory returns non-zero" "$?"
assert_file_missing "no output written when the output directory is missing" "$out_nodir"

echo "=== sparse entry: absent cluster_id + source_finding_paths (jq defaults) ==="

# Every Fixture-A/meta/defensive entry supplies BOTH cluster_id and
# source_finding_paths, so the jq default branches `cluster_id // null` and
# `source_finding_paths // []` were never exercised. A deliberately sparse
# entry (only the four fields finding_id needs) pins those defaults: an absent
# cluster_id must seed duplicate_group as null (not "" or the literal "null"),
# and an absent source_finding_paths must passthrough as an empty array — while
# the line still carries every schema key and a well-formed id.
manifest_sparse="$TMPDIR/manifest-sparse.json"
cat > "$manifest_sparse" <<'JSON'
[
  {
    "title": "Sparse entry with no cluster_id and no source paths",
    "severity": "high",
    "domain": "code",
    "lens": "misc"
  }
]
JSON
out_sparse="$TMPDIR/findings-sparse.jsonl"
build_findings_jsonl_from_manifest "$manifest_sparse" "$out_sparse"
rc_sparse=$?
assert_success "sparse manifest entry returns exit 0" "$rc_sparse"
sparse_line="$(head -n1 "$out_sparse")"
assert_jq "sparse line is valid JSON" '.' "$sparse_line" stdin
# Absent cluster_id -> duplicate_group null (jq `// null` default branch).
assert_jq "absent cluster_id -> duplicate_group is JSON null" \
  '.duplicate_group == null' "$sparse_line" stdin
# Absent source_finding_paths -> [] (jq `// []` default branch), not null.
assert_jq "absent source_finding_paths -> empty array (not null)" \
  '.source_finding_paths == []' "$sparse_line" stdin
# All 12 schema keys + passthrough survive on a sparse entry.
assert_jq "sparse line still carries all 12 schema keys + source_finding_paths" '
    has("id") and has("title") and has("severity") and has("type")
    and has("domain") and has("lens") and has("status")
    and has("primary_location") and has("confidence")
    and has("duplicate_group") and has("markdown_path")
    and has("validation") and has("source_finding_paths")
  ' "$sparse_line" stdin
# id stays content-derived from the present fields.
assert_eq "sparse entry id matches finding_id for its fields" \
  "$(finding_id "code" "misc" "Sparse entry with no cluster_id and no source paths")" \
  "$(jq -r '.id' <<<"$sparse_line")"

echo "=== rebuild over an existing populated output file (overwrite, not append) ==="

# The builder writes atomically (tmp + mv), so re-running it against a path that
# already holds a previous (and here, deliberately garbage) findings.jsonl must
# REPLACE the file wholesale — never append to it and never leave stale lines
# behind. findings.jsonl is a stable, re-derivable artifact, so an
# append-instead-of-overwrite bug would silently double the registry on a rerun.
out_overwrite="$TMPDIR/findings-overwrite.jsonl"
printf 'STALE GARBAGE LINE 1\nSTALE GARBAGE LINE 2\nSTALE GARBAGE LINE 3\n' > "$out_overwrite"
build_findings_jsonl_from_manifest "$manifest_a" "$out_overwrite"
rc_overwrite=$?
assert_success "rebuild over an existing populated file returns exit 0" "$rc_overwrite"
# 4 entries -> exactly 4 lines; the 3 stale lines must be gone, not 7 total.
ow_lines="$(wc -l < "$out_overwrite" | tr -d ' ')"
assert_eq "rebuild overwrites rather than appends: exactly 4 lines remain" "4" "$ow_lines"
# No surviving trace of the prior file content.
TOTAL=$((TOTAL + 1))
if grep -q 'STALE GARBAGE' "$out_overwrite"; then
  fail_with "rebuild leaves no trace of the prior file content" \
    "stale content survived the overwrite"
else
  pass_with "rebuild leaves no trace of the prior file content"
fi
# And the rebuilt file is byte-identical to a clean build of the same manifest.
TOTAL=$((TOTAL + 1))
if diff -q "$out_a" "$out_overwrite" >/dev/null 2>&1; then
  pass_with "rebuild over existing file matches a clean build byte-for-byte"
else
  fail_with "rebuild over existing file matches a clean build byte-for-byte" \
    "rebuilt output differs from a clean build"
fi

echo "=== atomic write leaves no temp scaffolding behind ==="

# The builder writes to "${out}.tmp.$$" and mv's it into place for atomicity.
# After a SUCCESSFUL build, no temp file may linger beside the registry — a
# regression that wrote $out directly (non-atomic) or skipped the mv would
# either leak a .tmp.<pid> file into final/ or break the all-or-nothing write.
# Every other assertion checks final content; none checks the scaffolding is
# gone. By this point every build in the run has either mv'd its temp away or
# returned before creating one, so the sandbox must hold zero .tmp.<pid> files.
leftover_tmp="$(find "$TMPDIR" -maxdepth 1 -name '*.tmp.*' -type f 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "no .tmp.<pid> scaffolding survives a successful build" "0" "$leftover_tmp"

finish
