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

# Tests for issue #319: lib/ledger.sh — build_findings_jsonl_from_local.
# Ingests --local NNN-*.md YAML frontmatter (title/severity/domain/lens) into
# the canonical finding registry (findings.jsonl, schema in
# docs/finding-registry-schema.md). Pure filesystem-to-JSON transformation;
# NO AI models are invoked. Sibling of build_findings_jsonl_from_manifest
# (#314) — same null-slot conventions, but markdown_path is POPULATED with the
# .md file's path (the whole point of the issue) and no source_finding_paths.
# shellcheck disable=SC2329

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LEDGER_LIB="$SCRIPT_DIR/lib/ledger.sh"

PASS=0
FAIL=0
TOTAL=0

TMP_PARENT="$SCRIPT_DIR/logs/test-ledger-from-local"
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

assert_nonempty() {
  local desc="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -s "$path" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected non-empty file $path"
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

# --- Source lib/ledger.sh ALONE (must stay self-contained) -----------------
# The module deliberately takes no hard dependency on lib/core.sh / logging.sh
# / rounds.sh, so the local builder must work with ledger sourced on its own
# (the frontmatter parser and severity normalization must be inline replicas,
# not pulled in from rounds.sh). Sourcing alone here proves that contract.
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
if declare -F build_findings_jsonl_from_local >/dev/null 2>&1; then
  pass_with "build_findings_jsonl_from_local is defined after sourcing ledger alone"
else
  fail_with "build_findings_jsonl_from_local is defined after sourcing ledger alone" \
    "function not found — implementation pending (TDD red phase)"
  finish
fi

# ---------------------------------------------------------------------------
# Fixture tree under a single --local output dir. Mirrors the real layout:
#   <output_dir>/<domain>/<lens>/NNN-<slug>.md   (nested) AND
#   <output_dir>/NNN-<slug>.md                   (flat)
#
#   001 nested, full frontmatter, dir names DELIBERATELY DIFFER from the
#       frontmatter domain/lens (proves frontmatter wins over the path), title
#       is YAML-quoted with a [severity] prefix (proves de-quote + id stability),
#       and a `domain:`-looking line in the BODY proves the parser reads only
#       the leading frontmatter block, not the prose.
#   002 flat, full frontmatter, mixed-case severity (proves normalization).
#   003 nested, frontmatter OMITS domain/lens (proves directory fallback).
#   004 no frontmatter at all (first line is not `---`) -> skipped + warned.
#   006 nested, metacharacter/unicode title, UNQUOTED (proves jq owns escaping
#       and there is no shell injection / the value round-trips intact).
#   notes.txt a non-.md file with frontmatter-looking content -> must be ignored.
#
#   -> 4 valid .md files (001/002/003/006) => 4 JSONL lines; 004 skipped.
# ---------------------------------------------------------------------------
local_dir="$TMPDIR/output"
mkdir -p "$local_dir/misc/general" \
         "$local_dir/deployment/secrets" \
         "$local_dir/code/input-validation" \
         "$local_dir/code/misc"

# 001 — nested under misc/general but frontmatter says code/input-validation.
cat > "$local_dir/misc/general/001-validate-uploads.md" <<'EOF'
---
title: "[high] Validate uploads"
severity: high
domain: code
lens: input-validation
labels:
  - "input-validation"
---

## Summary
Uploads are not validated. domain: SHOULD_NOT_WIN
title: SHOULD_NOT_WIN
EOF

# 002 — flat file, mixed-case severity in frontmatter.
cat > "$local_dir/002-weak-tls.md" <<'EOF'
---
title: "[critical] Weak TLS ciphers enabled"
severity: Critical
domain: deployment
lens: tls
---

## Summary
Legacy ciphers.
EOF

# 003 — nested, frontmatter omits domain/lens -> derive from deployment/secrets.
cat > "$local_dir/deployment/secrets/003-leaked-key.md" <<'EOF'
---
title: "[medium] Leaked deploy key in history"
severity: medium
---

## Summary
A deploy key was committed to history.
EOF

# 004 — no frontmatter (first line is prose) -> skipped, warned, not fatal.
cat > "$local_dir/004-garbage.md" <<'EOF'
This file has no YAML frontmatter at all.
title: should never be parsed
domain: should never be parsed
EOF

# 006 — metacharacter + unicode title, UNQUOTED so de-quoting is a no-op and the
# expected value is unambiguous. jq must own escaping; no shell execution.
cat > "$local_dir/code/misc/006-meta.md" <<'EOF'
---
title: Bad "q" and $(rm -rf /) and `backtick` and ünïcödé — 危険
severity: high
domain: code
lens: misc
---

## Summary
meta.
EOF

# notes.txt — frontmatter-looking, but NOT a .md file. Must be ignored.
cat > "$local_dir/code/input-validation/notes.txt" <<'EOF'
---
title: "[high] I am not markdown"
severity: high
domain: code
lens: input-validation
---
EOF

# Expected, de-quoted titles (what the builder must store and hash).
title1='[high] Validate uploads'
title2='[critical] Weak TLS ciphers enabled'
title3='[medium] Leaked deploy key in history'
title6='Bad "q" and $(rm -rf /) and `backtick` and ünïcödé — 危険'

# Expected ids, computed with the REAL finding_id (de-quoted titles).
id1="$(finding_id code input-validation "$title1")"
id1_bare="$(finding_id code input-validation 'Validate uploads')"
id2="$(finding_id deployment tls "$title2")"
id3="$(finding_id deployment secrets "$title3")"
id6="$(finding_id code misc "$title6")"

echo "=== build_findings_jsonl_from_local: mixed fixture tree ==="

out_main="$TMPDIR/findings.jsonl"
stderr_main="$TMPDIR/stderr-main.txt"
build_findings_jsonl_from_local "$local_dir" "$out_main" 2>"$stderr_main"
rc_main=$?
assert_success "valid output dir returns exit 0" "$rc_main"
assert_file_exists "findings.jsonl is created" "$out_main"

# Acceptance: one line per .md with parseable frontmatter (004 skipped; the
# non-.md notes.txt ignored) -> 4 lines.
line_count="$(wc -l < "$out_main" | tr -d ' ')"
assert_eq "one JSONL line per valid-frontmatter .md (malformed skipped)" "4" "$line_count"

# Acceptance: malformed file is skipped with a warning (not fatal) -> stderr
# carries a message while the exit code stays 0 above.
assert_nonempty "a warning is emitted for the skipped malformed file" "$stderr_main"

# Acceptance: every physical line is independently parseable JSON.
all_lines_parse=0
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  if ! jq -e . <<<"$line" >/dev/null 2>&1; then
    all_lines_parse=1
    break
  fi
done < "$out_main"
assert_success "every line independently parses as JSON" "$all_lines_parse"

# Acceptance: every line carries all 12 registry schema keys (present-but-null
# counts via has()). NOTE: source_finding_paths is intentionally NOT required
# for the --local builder (there are no upstream cluster source paths).
keys_present=0
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  if ! jq -e '
      has("id") and has("title") and has("severity") and has("type")
      and has("domain") and has("lens") and has("status")
      and has("primary_location") and has("confidence")
      and has("duplicate_group") and has("markdown_path")
      and has("validation")
    ' <<<"$line" >/dev/null 2>&1; then
    keys_present=1
    break
  fi
done < "$out_main"
assert_success "every line has all 12 registry schema keys" "$keys_present"

# Slurp into an array for field-by-field assertions, selected by id.
records="$(jq -s '.' "$out_main")"

# Acceptance: markdown_path is POPULATED (non-null, non-empty) on every line —
# this is the whole point of the issue and the key difference from the manifest
# builder (which leaves markdown_path null).
assert_jq "markdown_path is populated (non-null) on every line" \
  'all(.[]; .markdown_path != null and .markdown_path != "")' "$records" stdin

# Acceptance: every markdown_path actually locates the file it indexes. Accept
# either the path as found (absolute / relative to cwd) or relative to the
# output dir, so the test does not over-constrain that representation choice.
md_resolves=0
while IFS= read -r mp; do
  [[ -n "$mp" ]] || { md_resolves=1; break; }
  [[ -f "$mp" || -f "$local_dir/$mp" ]] || { md_resolves=1; break; }
done < <(jq -r '.[].markdown_path' <<<"$records")
assert_success "every markdown_path resolves to an existing file" "$md_resolves"

echo "=== fixture 001: de-quote + id stability + frontmatter precedence ==="

rec1="$(jq -c --arg id "$id1" 'map(select(.id == $id)) | (.[0] // null)' <<<"$records")"

# id is content-derived via finding_id from the DE-QUOTED title.
assert_eq "fixture 001 id matches finding_id over the de-quoted title" \
  "$id1" "$(jq -r '.id // ""' <<<"$rec1")"
# The de-quote is load-bearing: a "[high] X" frontmatter title must earn the
# SAME id as a bare "X" (finding_id strips the [severity] prefix internally).
# A builder that forgot to strip the surrounding YAML quotes would hash
# '"[high] Validate uploads"' instead and diverge — this pins that fix.
assert_eq "fixture 001 id equals the bare-title id (quotes stripped before hashing)" \
  "$id1_bare" "$(jq -r '.id // ""' <<<"$rec1")"
# The stored title is the de-quoted form, not the raw '"..."' frontmatter value.
assert_eq "fixture 001 stored title is de-quoted" \
  "$title1" "$(jq -r '.title // ""' <<<"$rec1")"
# Frontmatter domain/lens win over the (deliberately different) directory names.
assert_eq "fixture 001 domain from frontmatter wins over directory" \
  "code" "$(jq -r '.domain // ""' <<<"$rec1")"
assert_eq "fixture 001 lens from frontmatter wins over directory" \
  "input-validation" "$(jq -r '.lens // ""' <<<"$rec1")"
assert_eq "fixture 001 severity copied" "high" "$(jq -r '.severity // ""' <<<"$rec1")"
# markdown_path points at the right file.
mp1="$(jq -r '.markdown_path // ""' <<<"$rec1")"
assert_eq "fixture 001 markdown_path names the source file" \
  "001-validate-uploads.md" "$(basename "$mp1")"

echo "=== fixture 002: severity normalization (flat file) ==="

rec2="$(jq -c --arg id "$id2" 'map(select(.id == $id)) | (.[0] // null)' <<<"$records")"
assert_eq "fixture 002 id matches finding_id" "$id2" "$(jq -r '.id // ""' <<<"$rec2")"
# severity_normalize: frontmatter "Critical" -> "critical".
assert_eq "fixture 002 mixed-case severity normalized: Critical -> critical" \
  "critical" "$(jq -r '.severity // ""' <<<"$rec2")"
assert_eq "fixture 002 domain from frontmatter" "deployment" "$(jq -r '.domain // ""' <<<"$rec2")"
assert_eq "fixture 002 lens from frontmatter" "tls" "$(jq -r '.lens // ""' <<<"$rec2")"

echo "=== fixture 003: directory fallback for domain/lens ==="

rec3="$(jq -c --arg id "$id3" 'map(select(.id == $id)) | (.[0] // null)' <<<"$records")"
assert_eq "fixture 003 id matches finding_id (fallback domain/lens)" \
  "$id3" "$(jq -r '.id // ""' <<<"$rec3")"
# Frontmatter omitted domain/lens -> derived from <output_dir>/deployment/secrets/.
assert_eq "fixture 003 domain falls back to directory component" \
  "deployment" "$(jq -r '.domain // ""' <<<"$rec3")"
assert_eq "fixture 003 lens falls back to directory component" \
  "secrets" "$(jq -r '.lens // ""' <<<"$rec3")"

echo "=== static / builder-owned fields (every line) ==="

# Local findings have no verification_status and no clusters, so the registry
# slots stay at their conservative defaults on every record.
# Issue #344: type is now resolved (frontmatter type: -> domain fallback), never
# null. None of these fixtures carry an explicit type: and their domains
# (code/deployment) are unmapped, so each resolves to the maintainability
# back-compat default.
assert_jq "type resolves to maintainability on every line (unmapped domain, no explicit type:)" \
  'all(.[]; .type == "maintainability")' "$records" stdin
assert_jq "confidence is null on every line" 'all(.[]; .confidence == null)' "$records" stdin
assert_jq "duplicate_group is null on every line" \
  'all(.[]; .duplicate_group == null)' "$records" stdin
assert_jq "primary_location is empty string on every line" \
  'all(.[]; .primary_location == "")' "$records" stdin
assert_jq "validation is an empty object on every line" \
  'all(.[]; .validation == {})' "$records" stdin
assert_jq "status is new on every line" 'all(.[]; .status == "new")' "$records" stdin

echo "=== fixture 006: jq owns escaping (metacharacter + unicode title) ==="

rec6="$(jq -c 'map(select(.domain == "code" and .lens == "misc")) | (.[0] // null)' <<<"$records")"
# A title with quotes, $(...), backticks, em-dash and CJK must round-trip byte
# for byte — proving the builder hands the value to jq via --arg and never
# string-interpolates (no shell execution of $(rm -rf /)).
assert_eq "fixture 006 metacharacter/unicode title round-trips exactly" \
  "$title6" "$(jq -r '.title // ""' <<<"$rec6")"
assert_eq "fixture 006 id matches finding_id over the metacharacter title" \
  "$id6" "$(jq -r '.id // ""' <<<"$rec6")"

echo "=== determinism ==="

# id is deterministic and find output is sorted -> two builds byte-identical.
out_main2="$TMPDIR/findings2.jsonl"
build_findings_jsonl_from_local "$local_dir" "$out_main2" >/dev/null 2>&1
TOTAL=$((TOTAL + 1))
if diff -q "$out_main" "$out_main2" >/dev/null 2>&1; then
  pass_with "two builds of the same dir are byte-identical"
else
  fail_with "two builds of the same dir are byte-identical" "output differs between runs"
fi

echo "=== empty dir / no-.md dir -> empty output, exit 0 ==="

empty_dir="$TMPDIR/empty"
mkdir -p "$empty_dir"
out_empty="$TMPDIR/findings-empty.jsonl"
build_findings_jsonl_from_local "$empty_dir" "$out_empty"
rc_empty=$?
assert_success "empty dir returns exit 0" "$rc_empty"
assert_file_exists "empty dir still produces an output file" "$out_empty"
empty_lines="$(wc -l < "$out_empty" | tr -d ' ')"
assert_eq "empty dir yields 0 output lines" "0" "$empty_lines"

# A dir containing only non-.md files behaves the same (only *.md are ingested).
nomd_dir="$TMPDIR/nomd"
mkdir -p "$nomd_dir"
cat > "$nomd_dir/readme.txt" <<'EOF'
---
title: "[high] not markdown"
severity: high
---
EOF
out_nomd="$TMPDIR/findings-nomd.jsonl"
build_findings_jsonl_from_local "$nomd_dir" "$out_nomd"
rc_nomd=$?
assert_success "no-.md dir returns exit 0" "$rc_nomd"
nomd_lines="$(wc -l < "$out_nomd" | tr -d ' ')"
assert_eq "no-.md dir yields 0 output lines" "0" "$nomd_lines"

echo "=== malformed-only dir: skipped + warned + not fatal (failure path) ==="

# Forces the no-valid-frontmatter branch in isolation: the dir's single .md has
# no frontmatter, so it is skipped. The builder must still exit 0 (not fatal),
# emit a warning to stderr, and write an empty registry.
bad_dir="$TMPDIR/badonly"
mkdir -p "$bad_dir"
cat > "$bad_dir/bad.md" <<'EOF'
no frontmatter here, just prose.
EOF
out_bad="$TMPDIR/findings-bad.jsonl"
stderr_bad="$TMPDIR/stderr-bad.txt"
build_findings_jsonl_from_local "$bad_dir" "$out_bad" 2>"$stderr_bad"
rc_bad=$?
assert_success "malformed-only dir is not fatal (exit 0)" "$rc_bad"
bad_lines="$(wc -l < "$out_bad" | tr -d ' ')"
assert_eq "malformed file is skipped (0 output lines)" "0" "$bad_lines"
assert_nonempty "malformed file triggers a stderr warning" "$stderr_bad"

echo "=== error handling (failure paths) ==="

# Missing arguments -> non-zero.
build_findings_jsonl_from_local >/dev/null 2>&1
assert_failure "missing both arguments returns non-zero" "$?"

build_findings_jsonl_from_local "$local_dir" >/dev/null 2>&1
assert_failure "missing out-path argument returns non-zero" "$?"

# Nonexistent output dir -> non-zero (parity with the manifest builder's
# missing-manifest guard; a typo'd path must not silently yield empty output).
out_nodir_src="$TMPDIR/findings-nodir-src.jsonl"
build_findings_jsonl_from_local "$TMPDIR/does-not-exist" "$out_nodir_src" >/dev/null 2>&1
assert_failure "nonexistent output dir returns non-zero" "$?"
assert_file_missing "no output written when the input dir is missing" "$out_nodir_src"

# Output path's parent dir missing -> the atomic tmp write fails -> non-zero,
# no output (parity with the manifest builder).
out_noparent="$TMPDIR/missing-subdir/findings.jsonl"
build_findings_jsonl_from_local "$local_dir" "$out_noparent" >/dev/null 2>&1
assert_failure "nonexistent output parent dir returns non-zero" "$?"
assert_file_missing "no output written when the output parent dir is missing" "$out_noparent"

echo "=== atomic write leaves no temp scaffolding behind ==="

# The builder writes to "${out}.tmp.$$" then mv's it into place. After every
# build above, no .tmp.<pid> file may linger in the sandbox.
leftover_tmp="$(find "$TMPDIR" -name '*.tmp.*' -type f 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "no .tmp.<pid> scaffolding survives a successful build" "0" "$leftover_tmp"

echo "=== malformed frontmatter: opening '---' with NO closing '---' ==="

# Distinct from fixture 004 (first line is prose, caught by the NR==1 guard).
# Here line 1 IS `---` but the closing delimiter never arrives, so validity
# hinges on the awk END-guard (`END { if (!found) exit 1 }`) — the exact branch
# the implementation summary flags as load-bearing for the line-count contract.
# Assert the helper rejects it directly, then prove the builder skips + warns +
# stays non-fatal (the integrated path).
dangle_file="$TMPDIR/dangle-probe.md"
cat > "$dangle_file" <<'EOF'
---
title: dangling
severity: high
domain: code
lens: x
EOF
_ledger_has_frontmatter "$dangle_file"
assert_failure "_ledger_has_frontmatter rejects an unterminated frontmatter block" "$?"

dangle_dir="$TMPDIR/dangleonly"
mkdir -p "$dangle_dir"
cp "$dangle_file" "$dangle_dir/050-dangle.md"
out_dangle="$TMPDIR/findings-dangle.jsonl"
stderr_dangle="$TMPDIR/stderr-dangle.txt"
build_findings_jsonl_from_local "$dangle_dir" "$out_dangle" 2>"$stderr_dangle"
assert_success "unterminated-frontmatter dir is not fatal (exit 0)" "$?"
assert_eq "unterminated-frontmatter file is skipped (0 output lines)" \
  "0" "$(wc -l < "$out_dangle" | tr -d ' ')"
assert_nonempty "unterminated-frontmatter file triggers a stderr warning" "$stderr_dangle"

echo "=== single-quoted YAML value de-quoting + whitespace trim ==="

# Fixture 001 covered DOUBLE quotes; the single-quote strip branch
# (v="${v#\'}"; v="${v%\'}") and the leading/trailing whitespace trim are their
# own code paths. Assert the helper directly...
assert_eq "_ledger_trim_yaml_value strips a single-quoted pair" \
  "sq val" "$(_ledger_trim_yaml_value "'sq val'")"
assert_eq "_ledger_trim_yaml_value trims whitespace, then strips quotes" \
  "padded" "$(_ledger_trim_yaml_value '   "padded"   ')"
assert_eq "_ledger_trim_yaml_value leaves an unquoted (trimmed) value intact" \
  "bare" "$(_ledger_trim_yaml_value '   bare   ')"

# ...then end-to-end: a single-quoted '[high] ...' title must de-quote so it
# earns the SAME id as its bare form — the same id-stability contract fixture
# 001 pins for double quotes, here for the single-quote branch.
sq_dir="$TMPDIR/sqout"
mkdir -p "$sq_dir/code/auth"
cat > "$sq_dir/code/auth/060-single-quoted.md" <<'EOF'
---
title: '[high] Single quoted finding'
severity: high
domain: code
lens: auth
---

## Summary
single quotes.
EOF
out_sq="$TMPDIR/findings-sq.jsonl"
build_findings_jsonl_from_local "$sq_dir" "$out_sq" 2>/dev/null
assert_eq "single-quoted file yields exactly one line" "1" "$(wc -l < "$out_sq" | tr -d ' ')"
sq_title='[high] Single quoted finding'
sq_id="$(finding_id code auth "$sq_title")"
sq_id_bare="$(finding_id code auth 'Single quoted finding')"
assert_eq "single-quoted title is stored de-quoted" \
  "$sq_title" "$(jq -r '.title' "$out_sq")"
assert_eq "single-quoted title earns the bare-title id (quotes stripped before hashing)" \
  "$sq_id_bare" "$(jq -r '.id' "$out_sq")"
assert_eq "single-quoted title id matches finding_id over the de-quoted title" \
  "$sq_id" "$(jq -r '.id' "$out_sq")"

echo "=== partial directory fallback (only ONE of domain/lens omitted) ==="

# Fixture 003 omits BOTH domain and lens (both fall back). The builder applies
# the two fallbacks INDEPENDENTLY, so the mixed cases — one from frontmatter,
# one from the path — are their own branches, untested above.
#
# (a) domain in frontmatter, lens omitted -> lens from dir, domain kept.
mixa_dir="$TMPDIR/mixa"
mkdir -p "$mixa_dir/ignoreddir/realauth"
cat > "$mixa_dir/ignoreddir/realauth/070-mixa.md" <<'EOF'
---
title: "[low] domain wins, lens from dir"
severity: low
domain: customdomain
---
body
EOF
out_mixa="$TMPDIR/findings-mixa.jsonl"
build_findings_jsonl_from_local "$mixa_dir" "$out_mixa" 2>/dev/null
assert_eq "partial fallback (a): domain kept from frontmatter" \
  "customdomain" "$(jq -r '.domain' "$out_mixa")"
assert_eq "partial fallback (a): lens derived from directory" \
  "realauth" "$(jq -r '.lens' "$out_mixa")"

# (b) lens in frontmatter, domain omitted -> domain from dir, lens kept.
mixb_dir="$TMPDIR/mixb"
mkdir -p "$mixb_dir/realdomain/ignoredlens"
cat > "$mixb_dir/realdomain/ignoredlens/080-mixb.md" <<'EOF'
---
title: "[low] lens wins, domain from dir"
severity: low
lens: customlens
---
body
EOF
out_mixb="$TMPDIR/findings-mixb.jsonl"
build_findings_jsonl_from_local "$mixb_dir" "$out_mixb" 2>/dev/null
assert_eq "partial fallback (b): domain derived from directory" \
  "realdomain" "$(jq -r '.domain' "$out_mixb")"
assert_eq "partial fallback (b): lens kept from frontmatter" \
  "customlens" "$(jq -r '.lens' "$out_mixb")"

echo "=== flat file omitting domain/lens stays empty (no bogus dir-name leak) ==="

# The directory fallback is GUARDED by `rel == */*/*`, so a flat
# <output_dir>/NNN-x.md that omits domain/lens must NOT inherit <output_dir>'s
# own basename as a bogus domain/lens — they stay "" (impl design §4.3). This
# pins the guard that fixture 002 (flat but WITH frontmatter domain/lens) and
# fixture 003 (nested) never exercise.
flatdl_dir="$TMPDIR/flatnodl"
mkdir -p "$flatdl_dir"
cat > "$flatdl_dir/090-flat-no-dl.md" <<'EOF'
---
title: "[low] flat, no domain or lens"
severity: low
---
body
EOF
out_flatdl="$TMPDIR/findings-flatdl.jsonl"
build_findings_jsonl_from_local "$flatdl_dir" "$out_flatdl" 2>/dev/null
assert_eq "flat file omitting domain/lens yields exactly one line" \
  "1" "$(wc -l < "$out_flatdl" | tr -d ' ')"
assert_eq "flat file omitting domain leaves domain empty (no dir-name leak)" \
  "" "$(jq -r '.domain' "$out_flatdl")"
assert_eq "flat file omitting lens leaves lens empty (no dir-name leak)" \
  "" "$(jq -r '.lens' "$out_flatdl")"
# id stays deterministic over empty domain/lens + the de-quoted title.
flatdl_id="$(finding_id "" "" '[low] flat, no domain or lens')"
assert_eq "flat file id is finding_id over empty domain/lens" \
  "$flatdl_id" "$(jq -r '.id' "$out_flatdl")"

echo "=== trailing slashes preserve canonical metadata and finding IDs ==="

slash_dir="$TMPDIR/reports [local]"
mkdir -p "$slash_dir/security/injection/dispatch-example"
for finding in security/injection/001-plain.md security/injection/dispatch-example/002-nested.md 003-flat.md; do
  cat > "$slash_dir/$finding" <<EOF
---
title: $finding
severity: low
---
body
EOF
done
plain_id="$(finding_id security injection security/injection/001-plain.md)"
nested_id="$(finding_id security injection security/injection/dispatch-example/002-nested.md)"
flat_id="$(finding_id '' '' 003-flat.md)"
expected_metadata="$(jq -cn --arg plain "$plain_id" --arg nested "$nested_id" --arg flat "$flat_id" '
  [["003-flat.md", "", "", "maintainability", $flat],
   ["security/injection/001-plain.md", "security", "injection", "security-vulnerability", $plain],
   ["security/injection/dispatch-example/002-nested.md", "security", "injection", "security-vulnerability", $nested]]')"
for suffix in '' / ///; do
  slash_out="$TMPDIR/trailing-findings.jsonl"
  build_findings_jsonl_from_local "$slash_dir$suffix" "$slash_out"
  assert_success "local ingestion succeeds with suffix '$suffix'" "$?"
  assert_eq "local metadata, inferred type and IDs survive suffix '$suffix'" \
    "$expected_metadata" "$(jq -cs 'map([.title, .domain, .lens, .type, .id]) | sort' "$slash_out")"
  while IFS= read -r markdown; do
    assert_file_exists "source link resolves with suffix '$suffix'" "$markdown"
  done < <(jq -r '.markdown_path' "$slash_out")

  # The public registry caller forwards the root without CLI canonicalization.
  LOG_BASE="$TMPDIR/trailing-registry" build_finding_registry trailing "$slash_dir$suffix"
  assert_success "registry ingestion succeeds with suffix '$suffix'" "$?"
  assert_eq "registry preserves metadata and IDs with suffix '$suffix'" \
    "$expected_metadata" "$(jq -cs 'map([.title, .domain, .lens, .type, .id]) | sort' "$TMPDIR/trailing-registry/final/findings.jsonl")"
done

echo "=== symlinked output root preserves findings without following child links ==="

linked_root="$TMPDIR/reports link [root]"
ln -s "$slash_dir" "$linked_root"
# Only the explicitly supplied root may be followed. Child links must not add
# outside findings or duplicate existing files (as find -L would do).
outside_dir="$TMPDIR/outside"
mkdir -p "$outside_dir"
cat > "$outside_dir/004-outside.md" <<'EOF'
---
title: Outside finding
severity: high
---
body
EOF
ln -s "$outside_dir" "$slash_dir/linked-directory"
ln -s "$outside_dir/004-outside.md" "$slash_dir/linked-file.md"
for suffix in '' / ///; do
  link_out="$TMPDIR/linked-findings.jsonl"
  build_findings_jsonl_from_local "$linked_root$suffix" "$link_out"
  assert_success "symlink-root ingestion succeeds with suffix '$suffix'" "$?"
  assert_eq "symlink-root metadata, types and IDs match without child links, suffix '$suffix'" \
    "$expected_metadata" "$(jq -cs 'map([.title, .domain, .lens, .type, .id]) | sort' "$link_out")"
  while IFS= read -r markdown; do
    assert_file_exists "symlink-root source link resolves with suffix '$suffix'" "$markdown"
  done < <(jq -r '.markdown_path' "$link_out")

  LOG_BASE="$TMPDIR/linked-registry" build_finding_registry linked "$linked_root$suffix"
  assert_success "symlink-root registry succeeds with suffix '$suffix'" "$?"
  assert_eq "symlink-root registry retains all findings and excludes child links, suffix '$suffix'" \
    "$expected_metadata" "$(jq -cs 'map([.title, .domain, .lens, .type, .id]) | sort' "$TMPDIR/linked-registry/final/findings.jsonl")"
done

echo "=== exact-path publication rejects directory destinations ==="
destination_input="$TMPDIR/destination-input"
mkdir -p "$destination_input/security/injection"
cat > "$destination_input/security/injection/finding.md" <<'EOF'
---
title: Destination regression
severity: high
---
body
EOF
for destination_kind in directory directory-link; do
  destination_target="$TMPDIR/target-$destination_kind"
  destination_out="$TMPDIR/registry-$destination_kind.jsonl"
  mkdir -p "$destination_target"
  printf 'preserve me\n' > "$destination_target/sentinel"
  if [[ "$destination_kind" == directory ]]; then
    destination_out="$destination_target"
  else
    ln -s "$destination_target" "$destination_out"
  fi
  build_findings_jsonl_from_local "$destination_input" "$destination_out"
  destination_rc=$?
  assert_failure "$destination_kind returns a publication error" "$destination_rc"
  assert_eq "$destination_kind preserves sentinel bytes" 'preserve me' "$(cat "$destination_target/sentinel")"
  assert_eq "$destination_kind adds no file inside the directory" 'sentinel' \
    "$(find "$destination_target" -mindepth 1 -maxdepth 1 -exec basename {} \;)"
  assert_eq "$destination_kind leaves no staging files beside the target" '' \
    "$(find "$TMPDIR" -maxdepth 1 -name "${destination_out##*/}.tmp.*" -print)"
  if [[ "$destination_kind" == directory-link ]]; then
    assert_eq 'directory symlink is unchanged' "$destination_target" "$(readlink "$destination_out")"
    rm "$destination_out"
  else
    # Keep the original nonempty destination intact; retry at a file path.
    destination_out="$TMPDIR/retry-registry.jsonl"
  fi
  printf 'previous registry\n' > "$destination_out"
  build_findings_jsonl_from_local "$destination_input" "$destination_out"
  assert_success "$destination_kind retries successfully at an exact file path" "$?"
  assert_eq "$destination_kind publishes one valid finding after retry" 'Destination regression' \
    "$(jq -r '.title' "$destination_out")"
done

finish
