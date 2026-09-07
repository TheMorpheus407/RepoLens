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

# Behavioral contract for issue #389: greenfield and spec-change accept a
# deterministic bundle of specification documents through the public CLI.
# No real model is invoked; invocations use dry-run or a no-op fake agent.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/spec.sh
# shellcheck disable=SC1091 # SCRIPT_DIR is resolved dynamically.
source "$SCRIPT_DIR/lib/spec.sh"

PASS=0
FAIL=0
TOTAL=0
CREATED_RUN_IDS=()
LAST_RUN_ID=""

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    Expected: $expected"
    echo "    Actual:   $actual"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    Expected to contain: $needle"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    Expected NOT to contain: $needle"
  fi
}

assert_file_exists() {
  local desc="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$path" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    Missing file: $path"
  fi
}

assert_pattern_valid() {
  local desc="$1" pattern="$2" normalized="${3:-$2}" status
  if spec_normalize_pattern "$pattern" "--spec-glob"; then
    status=0
  else
    status=$?
  fi
  assert_eq "$desc" "0:$normalized" "$status:$SPEC_NORMALIZED_VALUE"
}

assert_pattern_invalid() {
  local desc="$1" pattern="$2" expected_error="$3" status
  if spec_normalize_pattern "$pattern" "--spec-glob"; then
    status=0
  else
    status=$?
  fi
  assert_eq "$desc exits non-zero" "1" "$status"
  assert_contains "$desc explains the syntax error" "$expected_error" "$SPEC_BUNDLE_ERROR"
}

assert_pattern_match() {
  local desc="$1" path="$2" pattern="$3" status
  if LC_ALL=C spec_pattern_matches "$path" "$pattern"; then
    status=0
  else
    status=$?
  fi
  assert_eq "$desc" "0" "$status"
}

assert_pattern_no_match() {
  local desc="$1" path="$2" pattern="$3" status
  if LC_ALL=C spec_pattern_matches "$path" "$pattern"; then
    status=0
  else
    status=$?
  fi
  assert_eq "$desc" "1" "$status"
}

artifact_sha256() {
  spec_sha256_file "$1" || return 1
  printf '%s' "$SPEC_SHA256_VALUE"
}

tamper_same_length() {
  local file="$1" from="$2" to="$3" before_bytes after_bytes temp_file
  [[ ${#from} -eq ${#to} ]] || return 1
  before_bytes="$(wc -c < "$file")" || return 1
  temp_file="$(mktemp "$TMPDIR/tamper.XXXXXX")" || return 1
  if ! awk -v from="$from" -v to="$to" '
    {
      if (!changed) {
        position = index($0, from)
        if (position > 0) {
          $0 = substr($0, 1, position - 1) to substr($0, position + length(from))
          changed = 1
        }
      }
      print
    }
    END { if (!changed) exit 3 }
  ' "$file" > "$temp_file"; then
    rm -f "$temp_file"
    return 1
  fi
  after_bytes="$(wc -c < "$temp_file")" || {
    rm -f "$temp_file"
    return 1
  }
  if [[ "$before_bytes" != "$after_bytes" ]] || cmp -s "$file" "$temp_file"; then
    rm -f "$temp_file"
    return 1
  fi
  mv "$temp_file" "$file"
}

TMP_PARENT="$SCRIPT_DIR/logs/test-multi-file-spec"
mkdir -p "$TMP_PARENT"
TMPDIR="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"

cleanup() {
  local run_id
  rm -rf "$TMPDIR"
  for run_id in "${CREATED_RUN_IDS[@]:-}"; do
    [[ -n "$run_id" ]] && rm -rf "$SCRIPT_DIR/logs/$run_id"
  done
  rmdir "$TMP_PARENT" 2>/dev/null || true
}
trap cleanup EXIT

PROJECT_DIR="$TMPDIR/project"
SPEC_DIR="$PROJECT_DIR/specs"
FAKE_BIN="$TMPDIR/bin"
mkdir -p "$SPEC_DIR/domain" "$FAKE_BIN"

cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
printf 'DONE\n'
EOF
cat > "$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${REPOLENS_TEST_FORGE_CALL_LOG:-}" ]]; then
  printf '%s\n' "$*" >> "$REPOLENS_TEST_FORGE_CALL_LOG"
fi
case "${1:-} ${2:-}" in
  "auth status"|"label create")
    exit 0
    ;;
  "label list"|"issue list")
    printf '[]\n'
    exit 0
    ;;
esac
exit 0
EOF
chmod +x "$FAKE_BIN/codex" "$FAKE_BIN/gh"

cat > "$SPEC_DIR/index.md" <<'EOF'
# Product
The entry document introduces the product.
EOF
cat > "$SPEC_DIR/domain/auth.md" <<'EOF'
# Authentication
Users sign in with passwords.
EOF
cat > "$SPEC_DIR/domain/workflows.md" <<'EOF'
# Workflows
Operators approve each request.
EOF
cat > "$SPEC_DIR/log.md" <<'EOF'
# Editing log
This document is not part of the normative specification.
EOF
printf '# Fixture project\n' > "$PROJECT_DIR/README.md"

git -C "$PROJECT_DIR" init -q
git -C "$PROJECT_DIR" config user.name "RepoLens Test"
git -C "$PROJECT_DIR" config user.email "repolens@example.invalid"
git -C "$PROJECT_DIR" config commit.gpgsign false
git -C "$PROJECT_DIR" add README.md specs
git -C "$PROJECT_DIR" commit -q -m "fixture"
git -C "$PROJECT_DIR" remote add origin https://github.com/owner/repo.git

register_created_run_id() {
  local output_file="$1" run_id
  run_id="$(grep -oE 'RepoLens run [^ ]+ starting' "$output_file" 2>/dev/null | head -1 | awk '{print $3}')"
  LAST_RUN_ID="$run_id"
  [[ -n "$run_id" ]] && CREATED_RUN_IDS+=("$run_id")
}

run_repolens() {
  local name="$1"
  shift
  local out_file="$TMPDIR/$name.out" before_runs run_path run_id
  before_runs="$(mktemp "$TMPDIR/before-runs.XXXXXX")"
  {
    for run_path in "$SCRIPT_DIR"/logs/20*; do
      [[ -d "$run_path" ]] && printf '%s\n' "${run_path##*/}"
    done
  } | LC_ALL=C sort > "$before_runs"
  LAST_RUN_ID=""
  env -u REPOLENS_ROUNDS -u DONE_STREAK_REQUIRED \
    PATH="$FAKE_BIN:$PATH" \
    REPOLENS_TEST_FORGE_CALL_LOG="$FORGE_CALL_LOG" \
    REPOLENS_AGENT_TIMEOUT=10 \
    REPOLENS_LENS_MAX_WALL=60 \
    bash "$SCRIPT_DIR/repolens.sh" \
      --project "$PROJECT_DIR" \
      --agent codex \
      "$@" \
      >"$out_file" 2>&1
  printf '%s\n' "$?" > "$TMPDIR/$name.rc"
  for run_path in "$SCRIPT_DIR"/logs/20*; do
    [[ -d "$run_path" ]] || continue
    run_id="${run_path##*/}"
    grep -qxF "$run_id" "$before_runs" || CREATED_RUN_IDS+=("$run_id")
  done
  rm -f "$before_runs"
  register_created_run_id "$out_file"
}

FORGE_CALL_LOG="$TMPDIR/forge-calls.log"

echo ""
echo "=== Test Suite: multi-file specs (issue #389) ==="

echo ""
echo "Test 1: greenfield resolves, orders, excludes, and persists a spec bundle"
run_repolens "greenfield-bundle" \
  --mode greenfield \
  --spec-dir "$SPEC_DIR" \
  --spec-glob "**/*.md" \
  --spec-entry "index.md" \
  --spec-exclude "log.md" \
  --local \
  --yes \
  --dry-run \
  --output "$TMPDIR/greenfield-issues"
bundle_out="$(cat "$TMPDIR/greenfield-bundle.out")"
assert_eq "valid bundle dry-run exits successfully" "0" "$(cat "$TMPDIR/greenfield-bundle.rc")"
assert_contains "dry-run identifies the canonical spec root" "$SPEC_DIR" "$bundle_out"
assert_contains "dry-run reports the entry document" "index.md" "$bundle_out"
assert_contains "root-level files match the default recursive glob" "index.md" "$bundle_out"
assert_contains "dry-run reports a nested document" "domain/auth.md" "$bundle_out"
assert_contains "dry-run reports the matched file count" "3" "$bundle_out"

bundle_run_id="$LAST_RUN_ID"
bundle_log_dir="$SCRIPT_DIR/logs/$bundle_run_id"
assert_file_exists "resolved manifest is persisted" "$bundle_log_dir/spec-files.json"
assert_file_exists "combined current specification is persisted" "$bundle_log_dir/combined-spec.md"
if [[ -f "$bundle_log_dir/spec-files.json" ]]; then
  assert_eq "manifest preserves deterministic entry-first order" \
    '["index.md","domain/auth.md","domain/workflows.md"]' \
    "$(jq -c '[.files[].path]' "$bundle_log_dir/spec-files.json")"
  assert_eq "manifest records three selected files" "3" \
    "$(jq -r '.files | length' "$bundle_log_dir/spec-files.json")"
  assert_eq "manifest records the effective include patterns" '["**/*.md"]' \
    "$(jq -c '.includes' "$bundle_log_dir/spec-files.json")"
  assert_eq "manifest records the effective exclude patterns" '["log.md"]' \
    "$(jq -c '.excludes' "$bundle_log_dir/spec-files.json")"
  assert_eq "manifest byte count matches the composed artifact" \
    "$(wc -c < "$bundle_log_dir/combined-spec.md")" \
    "$(jq -r '.combined_bytes' "$bundle_log_dir/spec-files.json")"
  assert_eq "manifest uses the SHA-256 integrity schema" "3:sha256" \
    "$(jq -r '[.schema_version, .artifact_integrity.algorithm] | join(":")' \
      "$bundle_log_dir/spec-files.json")"
  assert_eq "manifest SHA-256 matches the frozen combined artifact" \
    "$(artifact_sha256 "$bundle_log_dir/combined-spec.md")" \
    "$(jq -r '.artifact_integrity.combined_spec.sha256' \
      "$bundle_log_dir/spec-files.json")"
fi
if [[ -f "$bundle_log_dir/combined-spec.md" ]]; then
  combined="$(cat "$bundle_log_dir/combined-spec.md")"
  assert_contains "combined spec carries entry-file provenance" 'path="index.md"' "$combined"
  assert_contains "combined spec carries nested-file provenance" 'path="domain/auth.md"' "$combined"
  assert_contains "combined spec contains entry content" "introduces the product" "$combined"
  assert_contains "combined spec contains nested content" "Users sign in with passwords" "$combined"
  assert_not_contains "combined spec omits excluded content" "not part of the normative specification" "$combined"
  index_prefix="${combined%%path=\"index.md\"*}"
  auth_prefix="${combined%%path=\"domain/auth.md\"*}"
  workflows_prefix="${combined%%path=\"domain/workflows.md\"*}"
  assert_eq "entry marker appears before the sorted remaining files" "true" \
    "$([[ ${#index_prefix} -lt ${#auth_prefix} && ${#auth_prefix} -lt ${#workflows_prefix} ]] && echo true || echo false)"
fi
run_repolens "bundle-summary" \
  --mode greenfield \
  --spec-dir "$SPEC_DIR" \
  --spec-entry "index.md" \
  --spec-exclude "log.md" \
  --depth 1 \
  --rounds 1 \
  --local --yes --output "$TMPDIR/bundle-summary-issues"
summary_log_dir="$SCRIPT_DIR/logs/$LAST_RUN_ID"
assert_file_exists "bundle run persists summary metadata" "$summary_log_dir/summary.json"
if [[ -f "$summary_log_dir/summary.json" ]]; then
  assert_eq "bundle summary keeps the legacy scalar spec field null" "null" \
    "$(jq -r '.spec | type' "$summary_log_dir/summary.json")"
  assert_eq "bundle summary identifies a directory spec set" "directory" \
    "$(jq -r '.spec_set.kind' "$summary_log_dir/summary.json")"
  assert_eq "bundle summary records the selected file count" "3" \
    "$(jq -r '.spec_set.file_count' "$summary_log_dir/summary.json")"
  assert_eq "bundle summary points at the persisted manifest" "$summary_log_dir/spec-files.json" \
    "$(jq -r '.spec_set.manifest' "$summary_log_dir/summary.json")"
  assert_eq "bundle summary carries the manifest SHA-256 metadata" \
    "$(jq -c '.artifact_integrity' "$summary_log_dir/spec-files.json")" \
    "$(jq -c '.spec_set.artifact_integrity' "$summary_log_dir/summary.json")"
fi

echo ""
echo "Test 1b: default and combined filter forms select each file exactly once"
run_repolens "default-glob" \
  --mode greenfield \
  --spec-dir "$SPEC_DIR" \
  --local --yes --dry-run --output "$TMPDIR/default-glob-issues"
assert_eq "omitting --spec-glob uses the recursive Markdown default" "0" \
  "$(cat "$TMPDIR/default-glob.rc")"
default_log_dir="$SCRIPT_DIR/logs/$LAST_RUN_ID"
assert_eq "default recursive glob includes root and nested Markdown files" \
  '["domain/auth.md","domain/workflows.md","index.md","log.md"]' \
  "$(jq -c '[.files[].path]' "$default_log_dir/spec-files.json")"

run_repolens "combined-filters" \
  --mode greenfield \
  --spec-dir "$SPEC_DIR" \
  --spec-glob "**/*.md,index.md" \
  --spec-glob "domain/*.md" \
  --spec-entry "index.md" \
  --spec-exclude "log.md,domain/workflows.md" \
  --local --yes --dry-run --output "$TMPDIR/combined-filters-issues"
assert_eq "comma-separated and repeated filters are accepted" "0" \
  "$(cat "$TMPDIR/combined-filters.rc")"
combined_filter_log_dir="$SCRIPT_DIR/logs/$LAST_RUN_ID"
assert_eq "overlapping includes are deduplicated and excludes win" \
  '["index.md","domain/auth.md"]' \
  "$(jq -c '[.files[].path]' "$combined_filter_log_dir/spec-files.json")"

run_repolens "single-segment-glob" \
  --mode greenfield \
  --spec-dir "$SPEC_DIR" \
  --spec-glob "*.md" \
  --spec-exclude "log.md" \
  --local --yes --dry-run --output "$TMPDIR/single-segment-glob-issues"
assert_eq "a single star does not cross directory boundaries" "0" \
  "$(cat "$TMPDIR/single-segment-glob.rc")"
single_segment_log_dir="$SCRIPT_DIR/logs/$LAST_RUN_ID"
assert_eq "single-segment glob selects only root-level Markdown" \
  '["index.md"]' \
  "$(jq -c '[.files[].path]' "$single_segment_log_dir/spec-files.json")"

echo ""
echo "Test 1c: POSIX bracket atoms validate and preserve segment-aware matching"
assert_pattern_valid "POSIX character classes are accepted" \
  "chapter[[:digit:]].md"
assert_pattern_valid "POSIX classes compose with literal bracket members" \
  "file[[:alnum:]_-].md"
assert_pattern_valid "POSIX equivalence classes are accepted" \
  "[[=a=]].md"
assert_pattern_valid "POSIX collating symbols are accepted" \
  "[[.a.]].md"
assert_pattern_valid "ordinary bracket expressions remain accepted" \
  "[=a=].md"
assert_pattern_valid "ordinary dotted bracket expressions remain accepted" \
  "[.a.].md"
assert_pattern_valid "literal opening brackets use the portable [[] form" \
  "spec[[]old].md"

assert_pattern_match "a POSIX class matches within one filename segment" \
  "chapters/chapter7.md" "chapters/chapter[[:digit:]].md"
assert_pattern_no_match "a single-segment POSIX class pattern does not cross directories" \
  "chapters/archive/chapter7.md" "chapters/chapter[[:digit:]].md"
assert_pattern_match "globstar recurses before a POSIX class segment" \
  "chapters/archive/chapter7.md" "**/chapter[[:digit:]].md"
assert_pattern_match "globstar still permits zero directories before a POSIX class segment" \
  "chapter7.md" "**/chapter[[:digit:]].md"
assert_pattern_no_match "POSIX digit classes reject alphabetic filename members" \
  "chapters/chapterx.md" "chapters/chapter[[:digit:]].md"
assert_pattern_match "equivalence classes retain Bash matching semantics" \
  "a.md" "[[=a=]].md"
assert_pattern_match "collating symbols retain Bash matching semantics" \
  "a.md" "[[.a.]].md"
assert_pattern_match "literal opening bracket expressions match filenames" \
  "spec[old].md" "spec[[]old].md"

assert_pattern_invalid "unknown POSIX character class" \
  "[[:bogus:]].md" "unknown POSIX character class"
assert_pattern_invalid "unterminated outer POSIX bracket expression" \
  "[[:digit:].md" "unmatched '['"
assert_pattern_invalid "raw nested bracket expression" \
  "[a[b].md" "nested '['"
assert_pattern_invalid "slash inside a POSIX bracket atom" \
  "[[.a/b.]].md" "'/' inside a POSIX bracket atom"
assert_pattern_invalid "control character inside a bracket expression" \
  $'chapter[a\x01].md' "must not contain control characters"

LITERAL_BRACKET_SPEC_DIR="$TMPDIR/literal-bracket-specs"
mkdir -p "$LITERAL_BRACKET_SPEC_DIR"
printf '# Legacy spec\n' > "$LITERAL_BRACKET_SPEC_DIR/spec[old].md"
run_repolens "literal-bracket-glob" \
  --mode greenfield \
  --spec-dir "$LITERAL_BRACKET_SPEC_DIR" \
  --spec-glob "spec[[]old].md" \
  --local --yes --dry-run --output "$TMPDIR/literal-bracket-output"
assert_eq "literal-bracket glob succeeds end to end" "0" \
  "$(cat "$TMPDIR/literal-bracket-glob.rc")"
literal_bracket_log_dir="$SCRIPT_DIR/logs/$LAST_RUN_ID"
assert_eq "literal-bracket glob selects the intended file" '["spec[old].md"]' \
  "$(jq -c '[.files[].path]' "$literal_bracket_log_dir/spec-files.json")"

echo ""
echo "Test 2: incompatible and dependent options fail with actionable errors"
run_repolens "mutually-exclusive" \
  --mode greenfield \
  --spec "$SPEC_DIR/index.md" \
  --spec-dir "$SPEC_DIR" \
  --local --yes --dry-run --output "$TMPDIR/mutually-exclusive-issues"
assert_eq "--spec and --spec-dir together exit non-zero" "1" "$(cat "$TMPDIR/mutually-exclusive.rc")"
mutual_out="$(cat "$TMPDIR/mutually-exclusive.out")"
assert_contains "mutual-exclusion error explains the conflict" "mutually exclusive" "$mutual_out"

run_repolens "glob-without-dir" \
  --mode greenfield \
  --spec "$SPEC_DIR/index.md" \
  --spec-glob "**/*.md" \
  --local --yes --dry-run --output "$TMPDIR/glob-without-dir-issues"
assert_eq "--spec-glob without --spec-dir exits non-zero" "1" "$(cat "$TMPDIR/glob-without-dir.rc")"
assert_contains "dependent-option error explains the requirement" \
  "--spec-glob requires --spec-dir" "$(cat "$TMPDIR/glob-without-dir.out")"

run_repolens "excluded-entry" \
  --mode greenfield \
  --spec-dir "$SPEC_DIR" \
  --spec-entry "index.md" \
  --spec-exclude "index.md" \
  --local --yes --dry-run --output "$TMPDIR/excluded-entry-issues"
assert_eq "an entry removed by effective filters exits non-zero" "1" \
  "$(cat "$TMPDIR/excluded-entry.rc")"
assert_contains "excluded-entry error identifies the invalid entry" \
  "--spec-entry 'index.md' is not included" "$(cat "$TMPDIR/excluded-entry.out")"

run_repolens "empty-glob" \
  --mode greenfield \
  --spec-dir "$SPEC_DIR" \
  --spec-glob "" \
  --local --yes --dry-run --output "$TMPDIR/empty-glob-issues"
assert_eq "an empty include pattern exits non-zero" "1" \
  "$(cat "$TMPDIR/empty-glob.rc")"
assert_contains "empty-pattern error is actionable" \
  "--spec-glob must not be empty" "$(cat "$TMPDIR/empty-glob.out")"

run_repolens "traversal-glob" \
  --mode greenfield \
  --spec-dir "$SPEC_DIR" \
  --spec-glob "../*.md" \
  --local --yes --dry-run --output "$TMPDIR/traversal-glob-issues"
assert_eq "a parent-traversal pattern exits non-zero" "1" \
  "$(cat "$TMPDIR/traversal-glob.rc")"
assert_contains "traversal-pattern error identifies the invalid segment" \
  "invalid path segment" "$(cat "$TMPDIR/traversal-glob.out")"

echo ""
echo "Test 3: an empty selection fails fast and explains what matched"
run_repolens "zero-match" \
  --mode greenfield \
  --spec-dir "$SPEC_DIR" \
  --spec-glob "**/*.rst" \
  --local --yes --dry-run --output "$TMPDIR/zero-match-issues"
assert_eq "zero matches exit non-zero" "1" "$(cat "$TMPDIR/zero-match.rc")"
zero_out="$(cat "$TMPDIR/zero-match.out")"
assert_contains "zero-match error names the spec directory" "$SPEC_DIR" "$zero_out"
assert_contains "zero-match error includes the effective pattern" "**/*.rst" "$zero_out"

echo ""
echo "Test 4: the 100KB safety cap applies to the complete composed bundle"
mkdir -p "$TMPDIR/large-specs"
dd if=/dev/zero bs=1024 count=60 2>/dev/null | tr '\0' 'A' > "$TMPDIR/large-specs/a.md"
dd if=/dev/zero bs=1024 count=60 2>/dev/null | tr '\0' 'B' > "$TMPDIR/large-specs/b.md"
run_repolens "aggregate-too-large" \
  --mode greenfield \
  --spec-dir "$TMPDIR/large-specs" \
  --local --yes --dry-run --output "$TMPDIR/aggregate-too-large-issues"
assert_eq "aggregate over 100KB exits non-zero" "1" "$(cat "$TMPDIR/aggregate-too-large.rc")"
large_out="$(cat "$TMPDIR/aggregate-too-large.out")"
assert_contains "aggregate-size error reports the size limit" "100KB" "$large_out"

echo ""
echo "Test 5: a binary member is rejected before prompting"
mkdir -p "$TMPDIR/binary-specs"
printf '# Text prefix\nbinary\0payload\n' > "$TMPDIR/binary-specs/input.md"
run_repolens "binary-member" \
  --mode greenfield \
  --spec-dir "$TMPDIR/binary-specs" \
  --local --yes --dry-run --output "$TMPDIR/binary-member-issues"
assert_eq "binary bundle member exits non-zero" "1" "$(cat "$TMPDIR/binary-member.rc")"
assert_contains "binary-member error names the rejected file" \
  "Spec file appears to be binary: $TMPDIR/binary-specs/input.md" \
  "$(cat "$TMPDIR/binary-member.out")"

echo ""
echo "Test 5a: selected file and directory symlinks are rejected explicitly"
SYMLINK_TARGET_DIR="$TMPDIR/symlink-target"
SYMLINK_SPEC_DIR="$TMPDIR/symlink-specs"
mkdir -p "$SYMLINK_TARGET_DIR/nested" "$SYMLINK_SPEC_DIR"
printf '# External file\n' > "$SYMLINK_TARGET_DIR/external.md"
printf '# External nested file\n' > "$SYMLINK_TARGET_DIR/nested/hidden.md"
ln -s "$SYMLINK_TARGET_DIR/external.md" "$SYMLINK_SPEC_DIR/linked.md"
run_repolens "selected-file-symlink" \
  --mode greenfield \
  --spec-dir "$SYMLINK_SPEC_DIR" \
  --local --yes --dry-run --output "$TMPDIR/selected-file-symlink-output"
assert_eq "a selected spec-file symlink exits non-zero" "1" \
  "$(cat "$TMPDIR/selected-file-symlink.rc")"
assert_contains "selected file symlink rejection is explicit" \
  "Selected spec bundle member must not be a symlink" \
  "$(cat "$TMPDIR/selected-file-symlink.out")"

rm "$SYMLINK_SPEC_DIR/linked.md"
printf '# Local file\n' > "$SYMLINK_SPEC_DIR/local.md"
ln -s "$SYMLINK_TARGET_DIR/nested" "$SYMLINK_SPEC_DIR/linked-dir"
run_repolens "selected-directory-symlink" \
  --mode greenfield \
  --spec-dir "$SYMLINK_SPEC_DIR" \
  --local --yes --dry-run --output "$TMPDIR/selected-directory-symlink-output"
assert_eq "a spec-tree directory symlink exits non-zero" "1" \
  "$(cat "$TMPDIR/selected-directory-symlink.rc")"
assert_contains "directory symlink rejection is explicit" \
  "symlink directory that could hide selected files" \
  "$(cat "$TMPDIR/selected-directory-symlink.out")"

ln -s "$SYMLINK_SPEC_DIR" "$TMPDIR/spec-root-link"
run_repolens "spec-root-symlink" \
  --mode greenfield \
  --spec-dir "$TMPDIR/spec-root-link" \
  --local --yes --dry-run --output "$TMPDIR/spec-root-symlink-output"
assert_eq "a symlink --spec-dir exits non-zero" "1" \
  "$(cat "$TMPDIR/spec-root-symlink.rc")"
assert_contains "spec-root symlink rejection is explicit" \
  "Spec directory must not be a symlink" \
  "$(cat "$TMPDIR/spec-root-symlink.out")"

echo ""
echo "Test 5b: safe filenames retain valid, unambiguous provenance markers"
SAFE_SPEC_DIR="$TMPDIR/spec files"
mkdir -p "$SAFE_SPEC_DIR"
odd_spec_name='odd"-->name.md'
printf '# Odd filename\nStill valid specification text.\n' > "$SAFE_SPEC_DIR/$odd_spec_name"
run_repolens "safe-marker-path" \
  --mode greenfield \
  --spec-dir "$SAFE_SPEC_DIR" \
  --local --yes --dry-run --output "$TMPDIR/safe-marker-path-issues"
assert_eq "spaces and marker metacharacters in filenames are supported" "0" \
  "$(cat "$TMPDIR/safe-marker-path.rc")"
safe_marker_log_dir="$SCRIPT_DIR/logs/$LAST_RUN_ID"
safe_marker_combined="$(cat "$safe_marker_log_dir/combined-spec.md")"
assert_contains "marker attributes escape quotes and comment terminators" \
  'path="odd&quot;--&gt;name.md"' "$safe_marker_combined"
assert_not_contains "unsafe raw marker attribute is absent" \
  'path="odd"-->name.md"' "$safe_marker_combined"

echo ""
echo "Test 6: planner prompts preserve bundled provenance and expose conflicts"
greenfield_prompt="$(cat "$SCRIPT_DIR/prompts/_base/greenfield.md")"
spec_change_prompt="$(cat "$SCRIPT_DIR/prompts/_base/spec-change.md")"
greenfield_lens="$(cat "$SCRIPT_DIR/prompts/lenses/greenfield/backlog-planning.md")"
spec_change_lens="$(cat "$SCRIPT_DIR/prompts/lenses/spec-change/spec-change-planning.md")"
assert_contains "greenfield output requires relative-file spec references" \
  "originating relative file path" "$greenfield_prompt"
assert_contains "greenfield prompt rejects ordering as precedence" \
  "does not establish precedence" "$greenfield_prompt"
assert_contains "greenfield planner must expose conflicting documents" \
  "documents conflict, expose the conflict" "$greenfield_lens"
assert_contains "spec-change context requires relative-file provenance" \
  "originating relative file path" "$spec_change_prompt"
assert_contains "spec-change lens preserves bundle paths" \
  "Preserve bundled file-boundary paths" "$spec_change_lens"

echo ""
echo "Test 6b: resume reuses the frozen bundle and rejects option drift"
bundle_hash_before="$(git hash-object "$bundle_log_dir/combined-spec.md")"
snapshot_probe_dir="$TMPDIR/verified-snapshot-probe"
mkdir -p "$snapshot_probe_dir"
spec_manifest_snapshot_artifact \
  "$bundle_log_dir/spec-files.json" "combined_spec" \
  "$bundle_log_dir/combined-spec.md" "combined-spec.md" \
  "$snapshot_probe_dir/combined-spec.md" "combined specification bundle"
snapshot_probe_hash="$(artifact_sha256 "$snapshot_probe_dir/combined-spec.md")"
snapshot_source_backup="$TMPDIR/snapshot-source.backup.md"
cp "$bundle_log_dir/combined-spec.md" "$snapshot_source_backup"
tamper_same_length \
  "$bundle_log_dir/combined-spec.md" "passwords" "passwards" \
  || {
    echo "  FAIL: test fixture could not tamper snapshot source without changing its length"
    exit 1
  }
assert_eq "verified resume snapshot is immutable after source replacement" \
  "$snapshot_probe_hash" \
  "$(artifact_sha256 "$snapshot_probe_dir/combined-spec.md")"
assert_not_contains "verified resume snapshot never re-reads the replaced source" \
  "passwards" "$(cat "$snapshot_probe_dir/combined-spec.md")"
cp "$snapshot_source_backup" "$bundle_log_dir/combined-spec.md"

cat > "$SPEC_DIR/domain/auth.md" <<'EOF'
# Authentication
This source changed after the original run.
EOF
run_repolens "bundle-resume" \
  --mode greenfield \
  --spec-dir "$SPEC_DIR" \
  --spec-glob "**/*.md" \
  --spec-entry "index.md" \
  --spec-exclude "log.md" \
  --resume "$bundle_run_id" \
  --local --yes --dry-run --output "$TMPDIR/greenfield-issues"
assert_eq "bundle resume succeeds with matching selection options" "0" \
  "$(cat "$TMPDIR/bundle-resume.rc")"
assert_eq "resume preserves the original combined specification bytes" \
  "$bundle_hash_before" "$(git hash-object "$bundle_log_dir/combined-spec.md")"
assert_not_contains "resume does not import post-start source changes" \
  "This source changed after the original run." \
  "$(cat "$bundle_log_dir/combined-spec.md")"

combined_backup="$TMPDIR/combined-spec.backup.md"
cp "$bundle_log_dir/combined-spec.md" "$combined_backup"
tamper_same_length \
  "$bundle_log_dir/combined-spec.md" "passwords" "passwards" \
  || {
    echo "  FAIL: test fixture could not tamper combined-spec.md without changing its length"
    exit 1
  }
run_repolens "bundle-resume-corrupt-current" \
  --mode greenfield \
  --spec-dir "$SPEC_DIR" \
  --spec-glob "**/*.md" \
  --spec-entry "index.md" \
  --spec-exclude "log.md" \
  --resume "$bundle_run_id" \
  --local --yes --dry-run --output "$TMPDIR/greenfield-issues"
assert_eq "resume rejects same-length corruption of the current combined bundle" "1" \
  "$(cat "$TMPDIR/bundle-resume-corrupt-current.rc")"
assert_contains "current-bundle corruption reports a SHA-256 mismatch" \
  "combined specification bundle is corrupt: SHA-256 mismatch" \
  "$(cat "$TMPDIR/bundle-resume-corrupt-current.out")"
cp "$combined_backup" "$bundle_log_dir/combined-spec.md"

run_repolens "bundle-resume-mismatch" \
  --mode greenfield \
  --spec-dir "$SPEC_DIR" \
  --spec-glob "**/*.md" \
  --spec-entry "index.md" \
  --spec-exclude "log.md,domain/auth.md" \
  --resume "$bundle_run_id" \
  --local --yes --dry-run --output "$TMPDIR/greenfield-issues"
assert_eq "resume rejects selection options that differ from the manifest" "1" \
  "$(cat "$TMPDIR/bundle-resume-mismatch.rc")"
assert_contains "resume mismatch names the conflicting option family" \
  "Resume --spec-exclude values do not match" \
  "$(cat "$TMPDIR/bundle-resume-mismatch.out")"

manifest_backup="$TMPDIR/spec-files.backup.json"
cp "$bundle_log_dir/spec-files.json" "$manifest_backup"
jq 'del(.schema_version, .artifact_integrity)' \
  "$manifest_backup" > "$bundle_log_dir/spec-files.json"
run_repolens "bundle-resume-legacy-manifest" \
  --mode greenfield \
  --spec-dir "$SPEC_DIR" \
  --spec-glob "**/*.md" \
  --spec-entry "index.md" \
  --spec-exclude "log.md" \
  --resume "$bundle_run_id" \
  --local --yes --dry-run --output "$TMPDIR/greenfield-issues"
assert_eq "resume rejects a legacy byte-count-only manifest" "1" \
  "$(cat "$TMPDIR/bundle-resume-legacy-manifest.rc")"
assert_contains "legacy-manifest rejection explains the safe recovery" \
  "predates SHA-256 artifact integrity metadata and cannot be resumed safely" \
  "$(cat "$TMPDIR/bundle-resume-legacy-manifest.out")"
assert_contains "legacy-manifest rejection tells the operator to start a new run" \
  "Start a new run" "$(cat "$TMPDIR/bundle-resume-legacy-manifest.out")"
cp "$manifest_backup" "$bundle_log_dir/spec-files.json"

cat > "$SPEC_DIR/domain/auth.md" <<'EOF'
# Authentication
Users sign in with passwords.
EOF

echo ""
echo "Test 6c: bundle resume restores selection but requires current execution intent"
minimal_resume_output="$TMPDIR/minimal-resume-local-output"
run_repolens "minimal-resume-seed" \
  --mode greenfield \
  --spec-dir "$SPEC_DIR" \
  --spec-glob "**/*.md" \
  --spec-entry "index.md" \
  --spec-exclude "log.md" \
  --local --output "$minimal_resume_output" \
  --yes --dry-run
minimal_resume_run_id="$LAST_RUN_ID"
minimal_resume_log_dir="$SCRIPT_DIR/logs/$minimal_resume_run_id"
assert_file_exists "bundle run persists minimal-resume metadata" \
  "$minimal_resume_log_dir/resume-metadata.json"
assert_eq "resume metadata uses the selection-only schema" "3" \
  "$(jq -r '.schema_version' "$minimal_resume_log_dir/resume-metadata.json")"
assert_eq "resume metadata preserves the original mode" "greenfield" \
  "$(jq -r '.mode' "$minimal_resume_log_dir/resume-metadata.json")"
assert_eq "resume metadata preserves the exact include selection" '["**/*.md"]' \
  "$(jq -c '.specification.includes' "$minimal_resume_log_dir/resume-metadata.json")"
assert_eq "resume metadata carries no execution authorization or routing" "false:false" \
  "$(jq -r '[has("auto_yes"), has("execution")] | join(":")' \
    "$minimal_resume_log_dir/resume-metadata.json")"
assert_eq "manifest identity is limited to mode and data base" \
  '["mode","spec_base"]' \
  "$(jq -c '.resume_identity | keys | sort' "$minimal_resume_log_dir/spec-files.json")"
assert_eq "manifest records the exact selection metadata bytes" \
  "$(artifact_sha256 "$minimal_resume_log_dir/resume-metadata.json")" \
  "$(jq -r '.artifact_integrity.resume_metadata.sha256' \
    "$minimal_resume_log_dir/spec-files.json")"
minimal_bundle_hash="$(git hash-object "$minimal_resume_log_dir/combined-spec.md")"

# Resume hints repeat current execution authority because artifacts never do.
resume_hint="$(
  RUN_ID="$minimal_resume_run_id" \
  PROJECT_PATH="$PROJECT_DIR" \
  AGENT=codex \
  MODE=greenfield \
  LOCAL_MODE=true \
  OUTPUT_DIR="$minimal_resume_output" \
  AUTO_YES=true \
    bash -c 'source "$1/lib/logging.sh"; print_resume_hint' _ "$SCRIPT_DIR" 2>&1
)"
assert_contains "resume hint repeats the current mode" \
  "--mode greenfield" "$resume_hint"
assert_contains "resume hint repeats the local boundary" \
  "--local" "$resume_hint"
assert_contains "resume hint repeats the current output path" \
  "--output $minimal_resume_output" "$resume_hint"
assert_contains "resume hint repeats explicit non-interactive authorization" \
  "--yes" "$resume_hint"
forge_resume_hint="$(
  RUN_ID="$minimal_resume_run_id" \
  PROJECT_PATH="$PROJECT_DIR" \
  AGENT=codex \
  MODE=greenfield \
  LOCAL_MODE=false \
  FORGE_PROVIDER=gh \
  AUTO_YES=true \
    bash -c 'source "$1/lib/logging.sh"; print_resume_hint' _ "$SCRIPT_DIR" 2>&1
)"
assert_contains "resume hint repeats the current forge boundary" \
  "--forge gh" "$forge_resume_hint"

run_repolens "minimal-resume-no-boundary" \
  --mode greenfield --resume "$minimal_resume_run_id" --dry-run
assert_eq "bundle resume without a current execution boundary fails closed" "1" \
  "$(cat "$TMPDIR/minimal-resume-no-boundary.rc")"
assert_contains "missing-boundary rejection names both explicit choices" \
  "pass --local (optionally --output <path>) or --forge <gh|glab|tea|fj>" \
  "$(cat "$TMPDIR/minimal-resume-no-boundary.out")"

run_repolens "minimal-resume-no-mode" \
  --local --output "$minimal_resume_output" \
  --resume "$minimal_resume_run_id" --yes --dry-run
assert_eq "bundle resume without current mode intent fails closed" "1" \
  "$(cat "$TMPDIR/minimal-resume-no-mode.rc")"
assert_contains "missing-mode rejection names the required mode" \
  "pass --mode greenfield" "$(cat "$TMPDIR/minimal-resume-no-mode.out")"

# Move the live source tree away to prove a fully explicit continuation consumes
# the frozen bundle rather than re-resolving the worktree.
mv "$SPEC_DIR" "$SPEC_DIR.moved"
: > "$FORGE_CALL_LOG"
run_repolens "explicit-resume-command" \
  --mode greenfield \
  --local --output "$minimal_resume_output" \
  --yes --resume "$minimal_resume_run_id"
mv "$SPEC_DIR.moved" "$SPEC_DIR"
assert_eq "fully explicit resume command exits successfully" "0" \
  "$(cat "$TMPDIR/explicit-resume-command.rc")"
minimal_resume_out="$(cat "$TMPDIR/explicit-resume-command.out")"
assert_contains "explicit resume keeps greenfield mode" \
  "Mode: greenfield" "$minimal_resume_out"
assert_contains "explicit resume restores the persisted three-file selection" \
  "Spec bundle: 3 files" "$minimal_resume_out"
assert_contains "explicit resume uses current local-only output intent" \
  "Output:       local markdown ($minimal_resume_output)" "$minimal_resume_out"
assert_eq "explicit local resume performs no forge CLI calls" "0" \
  "$(wc -l < "$FORGE_CALL_LOG" | tr -d ' ')"
assert_eq "explicit local resume keeps the canonical output directory" "true" \
  "$([[ -d "$minimal_resume_output" ]] && echo true || echo false)"
assert_eq "explicit resume preserves the frozen combined bundle bytes" \
  "$minimal_bundle_hash" "$(git hash-object "$minimal_resume_log_dir/combined-spec.md")"

run_repolens "minimal-resume-wrong-mode" \
  --mode audit --local --output "$minimal_resume_output" \
  --resume "$minimal_resume_run_id" --dry-run
assert_eq "an explicit wrong-mode resume is rejected" "1" \
  "$(cat "$TMPDIR/minimal-resume-wrong-mode.rc")"
assert_contains "wrong-mode rejection names original and requested modes" \
  "originally executed with --mode greenfield, cannot resume with --mode audit" \
  "$(cat "$TMPDIR/minimal-resume-wrong-mode.out")"

different_resume_output="$TMPDIR/different-resume-output"
run_repolens "minimal-resume-current-output" \
  --mode greenfield \
  --local --output "$TMPDIR/different-resume-output" \
  --yes --resume "$minimal_resume_run_id" --dry-run
assert_eq "current explicit output replaces any historical routing" "0" \
  "$(cat "$TMPDIR/minimal-resume-current-output.rc")"
assert_contains "dry-run reports the current output path" \
  "Output:       local markdown ($different_resume_output)" \
  "$(cat "$TMPDIR/minimal-resume-current-output.out")"

run_repolens "forge-boundary-seed" \
  --mode greenfield \
  --spec-dir "$SPEC_DIR" \
  --spec-glob "**/*.md" \
  --spec-entry "index.md" \
  --spec-exclude "log.md" \
  --forge gh --yes --dry-run
forge_boundary_run_id="$LAST_RUN_ID"
: > "$FORGE_CALL_LOG"
run_repolens "forge-resume-no-boundary" \
  --mode greenfield --resume "$forge_boundary_run_id" --yes --dry-run
assert_eq "forge bundle resume without current boundary intent fails closed" "1" \
  "$(cat "$TMPDIR/forge-resume-no-boundary.rc")"
assert_contains "forge resume does not infer its prior boundary from artifacts" \
  "requires an explicit execution boundary" \
  "$(cat "$TMPDIR/forge-resume-no-boundary.out")"

run_repolens "forge-to-current-local" \
  --mode greenfield \
  --local --output "$TMPDIR/forge-to-local-output" \
  --yes --resume "$forge_boundary_run_id" --dry-run
assert_eq "current explicit local boundary is authoritative" "0" \
  "$(cat "$TMPDIR/forge-to-current-local.rc")"
assert_eq "current local boundary makes no forge CLI call" "0" \
  "$(wc -l < "$FORGE_CALL_LOG" | tr -d ' ')"

run_repolens "ambiguous-current-boundary" \
  --mode greenfield --local --forge gh \
  --resume "$minimal_resume_run_id" --yes --dry-run
assert_eq "simultaneous local and forge resume intent is rejected" "1" \
  "$(cat "$TMPDIR/ambiguous-current-boundary.rc")"
assert_contains "ambiguous boundary rejection asks for one choice" \
  "choose --local (optionally --output) or --forge" \
  "$(cat "$TMPDIR/ambiguous-current-boundary.out")"

metadata_backup="$TMPDIR/resume-metadata.backup.json"
manifest_routing_backup="$TMPDIR/spec-files-routing.backup.json"
summary_backup="$TMPDIR/summary-resume.backup.json"
cp "$minimal_resume_log_dir/resume-metadata.json" "$metadata_backup"
cp "$minimal_resume_log_dir/spec-files.json" "$manifest_routing_backup"
cp "$minimal_resume_log_dir/summary.json" "$summary_backup"

tamper_same_length \
  "$minimal_resume_log_dir/resume-metadata.json" \
  "**/*.md" "**/*.mD"
run_repolens "resume-metadata-same-length-tamper" \
  --mode greenfield --local --output "$minimal_resume_output" \
  --resume "$minimal_resume_run_id" --dry-run
assert_eq "same-length resume metadata tampering is rejected" "1" \
  "$(cat "$TMPDIR/resume-metadata-same-length-tamper.rc")"
assert_contains "metadata tampering fails SHA-256 verification" \
  "SHA-256 mismatch" "$(cat "$TMPDIR/resume-metadata-same-length-tamper.out")"
cp "$metadata_backup" "$minimal_resume_log_dir/resume-metadata.json"

jq '.resume_identity.spec_base = "HEAD~1"' \
  "$manifest_routing_backup" > "$minimal_resume_log_dir/spec-files.json"
run_repolens "resume-manifest-selection-tamper" \
  --mode greenfield --local --output "$minimal_resume_output" \
  --resume "$minimal_resume_run_id" --dry-run
assert_eq "manifest selection-identity tampering is rejected" "1" \
  "$(cat "$TMPDIR/resume-manifest-selection-tamper.rc")"
assert_contains "selection tampering fails the duplicate identity check" \
  "selection identity does not match" \
  "$(cat "$TMPDIR/resume-manifest-selection-tamper.out")"
cp "$manifest_routing_backup" "$minimal_resume_log_dir/spec-files.json"

jq '.output_mode = "forge" | .output_dir = null' "$summary_backup" \
  > "$minimal_resume_log_dir/summary.json"
run_repolens "resume-summary-routing-tamper" \
  --mode greenfield --local --output "$minimal_resume_output" \
  --yes --resume "$minimal_resume_run_id" --dry-run
assert_eq "historical summary routing cannot override current intent" "0" \
  "$(cat "$TMPDIR/resume-summary-routing-tamper.rc")"
assert_contains "current local route survives historical summary tampering" \
  "Output:       local markdown ($minimal_resume_output)" \
  "$(cat "$TMPDIR/resume-summary-routing-tamper.out")"
cp "$summary_backup" "$minimal_resume_log_dir/summary.json"

jq '.artifact_integrity.base_combined_spec = .artifact_integrity.combined_spec' \
  "$manifest_routing_backup" > "$minimal_resume_log_dir/spec-files.json"
run_repolens "resume-artifact-shape-tamper" \
  --mode greenfield --local --output "$minimal_resume_output" \
  --resume "$minimal_resume_run_id" --dry-run
assert_eq "mode-incompatible artifact shape is rejected" "1" \
  "$(cat "$TMPDIR/resume-artifact-shape-tamper.rc")"
assert_contains "artifact-shape drift names the resumed mode mismatch" \
  "artifacts do not match the resumed mode" \
  "$(cat "$TMPDIR/resume-artifact-shape-tamper.out")"
cp "$manifest_routing_backup" "$minimal_resume_log_dir/spec-files.json"

mv "$minimal_resume_log_dir/resume-metadata.json" \
  "$minimal_resume_log_dir/resume-metadata.real.json"
ln -s "resume-metadata.real.json" \
  "$minimal_resume_log_dir/resume-metadata.json"
run_repolens "resume-metadata-symlink" \
  --mode greenfield --local --output "$minimal_resume_output" \
  --resume "$minimal_resume_run_id" --dry-run
assert_eq "symlink resume metadata is rejected" "1" \
  "$(cat "$TMPDIR/resume-metadata-symlink.rc")"
assert_contains "metadata symlink rejection is explicit" \
  "resume metadata must not be a symlink" \
  "$(cat "$TMPDIR/resume-metadata-symlink.out")"
rm "$minimal_resume_log_dir/resume-metadata.json"
mv "$minimal_resume_log_dir/resume-metadata.real.json" \
  "$minimal_resume_log_dir/resume-metadata.json"

mv "$minimal_resume_log_dir/spec-files.json" \
  "$minimal_resume_log_dir/spec-files.real.json"
ln -s "spec-files.real.json" "$minimal_resume_log_dir/spec-files.json"
run_repolens "resume-manifest-symlink" \
  --mode greenfield --local --output "$minimal_resume_output" \
  --resume "$minimal_resume_run_id" --dry-run
assert_eq "symlink specification manifest is rejected" "1" \
  "$(cat "$TMPDIR/resume-manifest-symlink.rc")"
assert_contains "manifest symlink rejection is explicit" \
  "specification manifest must not be a symlink" \
  "$(cat "$TMPDIR/resume-manifest-symlink.out")"
rm "$minimal_resume_log_dir/spec-files.json"
mv "$minimal_resume_log_dir/spec-files.real.json" \
  "$minimal_resume_log_dir/spec-files.json"

# Even a coherent edit of metadata and its manifest digest cannot reintroduce
# execution authority into the selection-only schema.
coherent_metadata="$TMPDIR/coherent-resume-metadata.json"
jq '.auto_yes = true
  | .execution = {
      boundary:"forge",
      output_dir:null,
      output_dir_explicit:false
    }' "$metadata_backup" > "$coherent_metadata"
coherent_metadata_bytes="$(wc -c < "$coherent_metadata")"
coherent_metadata_sha="$(artifact_sha256 "$coherent_metadata")"
cp "$coherent_metadata" "$minimal_resume_log_dir/resume-metadata.json"
jq \
  --argjson bytes "$coherent_metadata_bytes" \
  --arg sha "$coherent_metadata_sha" \
  '.resume_identity.auto_yes = true
    | .resume_identity.execution = {
        boundary:"forge",
        output_dir:null,
        output_dir_explicit:false
      }
    | .artifact_integrity.resume_metadata.bytes = $bytes
    | .artifact_integrity.resume_metadata.sha256 = $sha' \
  "$manifest_routing_backup" > "$minimal_resume_log_dir/spec-files.json"
run_repolens "resume-coherent-execution-tamper" \
  --mode greenfield --local --output "$minimal_resume_output" \
  --yes --resume "$minimal_resume_run_id" --dry-run
assert_eq "coherent dual-artifact execution tampering is rejected" "1" \
  "$(cat "$TMPDIR/resume-coherent-execution-tamper.rc")"
assert_contains "selection-only metadata rejects injected execution fields" \
  "resume metadata is invalid" \
  "$(cat "$TMPDIR/resume-coherent-execution-tamper.out")"
cp "$metadata_backup" "$minimal_resume_log_dir/resume-metadata.json"
cp "$manifest_routing_backup" "$minimal_resume_log_dir/spec-files.json"

# A symlink run directory is a parent-path escape for every artifact below it
# and must be rejected before any leaf artifact is opened.
escaped_run_dir="$TMPDIR/escaped-resume-run"
mv "$minimal_resume_log_dir" "$escaped_run_dir"
ln -s "$escaped_run_dir" "$minimal_resume_log_dir"
run_repolens "resume-run-directory-symlink" \
  --mode greenfield --local --output "$minimal_resume_output" \
  --yes --resume "$minimal_resume_run_id" --dry-run
assert_eq "symlink resume run directory is rejected" "1" \
  "$(cat "$TMPDIR/resume-run-directory-symlink.rc")"
assert_contains "run-directory symlink rejection happens at the parent boundary" \
  "Resume run directory is missing or is a symlink" \
  "$(cat "$TMPDIR/resume-run-directory-symlink.out")"
rm "$minimal_resume_log_dir"
mv "$escaped_run_dir" "$minimal_resume_log_dir"

# Schema-1/2 runs remain selection-compatible, but their standalone auto_yes
# value is never trusted. A non-interactive resume therefore fails at the
# confirmation gate instead of silently authorizing work.
jq '.schema_version = 1 | .auto_yes = true' \
  "$metadata_backup" > "$minimal_resume_log_dir/resume-metadata.json"
jq '.schema_version = 2 | del(.resume_identity)
  | .artifact_integrity.resume_metadata = null' \
  "$manifest_routing_backup" > "$minimal_resume_log_dir/spec-files.json"
run_repolens "legacy-resume-does-not-restore-yes" \
  --mode greenfield \
  --local --output "$minimal_resume_output" \
  --resume "$minimal_resume_run_id"
assert_eq "legacy resume without explicit --yes fails closed" "1" \
  "$(cat "$TMPDIR/legacy-resume-does-not-restore-yes.rc")"
assert_contains "legacy resume reaches the non-interactive confirmation gate" \
  "Running non-interactively without --yes flag" \
  "$(cat "$TMPDIR/legacy-resume-does-not-restore-yes.out")"
cp "$metadata_backup" "$minimal_resume_log_dir/resume-metadata.json"
cp "$manifest_routing_backup" "$minimal_resume_log_dir/spec-files.json"

echo ""
echo "Test 7: spec-change diffs composed base and current document sets"
cat > "$SPEC_DIR/domain/auth.md" <<'EOF'
# Authentication
Users sign in with passkeys.
EOF
rm "$SPEC_DIR/domain/workflows.md"
run_repolens "spec-change-bundle" \
  --mode spec-change \
  --spec-dir "$SPEC_DIR" \
  --spec-glob "**/*.md" \
  --spec-entry "index.md" \
  --spec-exclude "log.md" \
  --spec-base HEAD \
  --local \
  --yes \
  --dry-run \
  --output "$TMPDIR/spec-change-issues"
assert_eq "spec-change bundle dry-run exits successfully" "0" "$(cat "$TMPDIR/spec-change-bundle.rc")"
change_run_id="$LAST_RUN_ID"
change_log_dir="$SCRIPT_DIR/logs/$change_run_id"
assert_file_exists "base combined snapshot is persisted" "$change_log_dir/combined-spec.base.md"
assert_file_exists "combined bundle diff is persisted" "$change_log_dir/spec-diff.txt"
if [[ -f "$change_log_dir/spec-diff.txt" ]]; then
  bundle_diff="$(cat "$change_log_dir/spec-diff.txt")"
  assert_contains "diff attributes the changed nested document" "domain/auth.md" "$bundle_diff"
  assert_contains "diff contains the new requirement" "Users sign in with passkeys" "$bundle_diff"
  assert_contains "diff contains the removed requirement" "Users sign in with passwords" "$bundle_diff"
  assert_contains "diff retains a document deleted from the working tree" "domain/workflows.md" "$bundle_diff"
  assert_contains "diff contains content removed with the deleted document" "Operators approve each request" "$bundle_diff"
  assert_contains "diff uses a stable base snapshot label" "a/combined-spec.base.md" "$bundle_diff"
  assert_contains "diff uses a stable current snapshot label" "b/combined-spec.md" "$bundle_diff"
  assert_not_contains "diff does not expose the run-directory path" "$change_log_dir" "$bundle_diff"
fi
if [[ -f "$change_log_dir/spec-files.json" ]]; then
  assert_eq "spec-change manifest records the base bundle SHA-256" \
    "$(artifact_sha256 "$change_log_dir/combined-spec.base.md")" \
    "$(jq -r '.artifact_integrity.base_combined_spec.sha256' \
      "$change_log_dir/spec-files.json")"
  assert_eq "spec-change manifest records the diff SHA-256" \
    "$(artifact_sha256 "$change_log_dir/spec-diff.txt")" \
    "$(jq -r '.artifact_integrity.spec_diff.sha256' \
      "$change_log_dir/spec-files.json")"
fi

base_backup="$TMPDIR/combined-spec.base.backup.md"
cp "$change_log_dir/combined-spec.base.md" "$base_backup"
tamper_same_length \
  "$change_log_dir/combined-spec.base.md" "passwords" "passwards" \
  || {
    echo "  FAIL: test fixture could not tamper combined-spec.base.md without changing its length"
    exit 1
  }
run_repolens "spec-change-resume-corrupt-base" \
  --mode spec-change \
  --spec-dir "$SPEC_DIR" \
  --spec-glob "**/*.md" \
  --spec-entry "index.md" \
  --spec-exclude "log.md" \
  --spec-base HEAD \
  --resume "$change_run_id" \
  --local --yes --dry-run --output "$TMPDIR/spec-change-issues"
assert_eq "resume rejects same-length corruption of the base bundle" "1" \
  "$(cat "$TMPDIR/spec-change-resume-corrupt-base.rc")"
assert_contains "base-bundle corruption reports a SHA-256 mismatch" \
  "base combined specification bundle is corrupt: SHA-256 mismatch" \
  "$(cat "$TMPDIR/spec-change-resume-corrupt-base.out")"
cp "$base_backup" "$change_log_dir/combined-spec.base.md"

diff_backup="$TMPDIR/spec-diff.backup.txt"
cp "$change_log_dir/spec-diff.txt" "$diff_backup"
tamper_same_length \
  "$change_log_dir/spec-diff.txt" "passkeys" "passkEys" \
  || {
    echo "  FAIL: test fixture could not tamper spec-diff.txt without changing its length"
    exit 1
  }
run_repolens "spec-change-resume-corrupt-diff" \
  --mode spec-change \
  --spec-dir "$SPEC_DIR" \
  --spec-glob "**/*.md" \
  --spec-entry "index.md" \
  --spec-exclude "log.md" \
  --spec-base HEAD \
  --resume "$change_run_id" \
  --local --yes --dry-run --output "$TMPDIR/spec-change-issues"
assert_eq "resume rejects same-length corruption of the combined spec diff" "1" \
  "$(cat "$TMPDIR/spec-change-resume-corrupt-diff.rc")"
assert_contains "spec-diff corruption reports a SHA-256 mismatch" \
  "combined specification diff is corrupt: SHA-256 mismatch" \
  "$(cat "$TMPDIR/spec-change-resume-corrupt-diff.out")"
cp "$diff_backup" "$change_log_dir/spec-diff.txt"

run_repolens "spec-change-bundle-resume" \
  --mode spec-change \
  --spec-dir "$SPEC_DIR" \
  --spec-glob "**/*.md" \
  --spec-entry "index.md" \
  --spec-exclude "log.md" \
  --spec-base HEAD \
  --resume "$change_run_id" \
  --local --yes --dry-run --output "$TMPDIR/spec-change-issues"
assert_eq "spec-change resume succeeds after all frozen artifacts verify" "0" \
  "$(cat "$TMPDIR/spec-change-bundle-resume.rc")"

entry_backup="$TMPDIR/deleted-entry.backup.md"
cp "$SPEC_DIR/index.md" "$entry_backup"
rm "$SPEC_DIR/index.md"
run_repolens "spec-change-deleted-entry" \
  --mode spec-change \
  --spec-dir "$SPEC_DIR" \
  --spec-glob "**/*.md" \
  --spec-entry "index.md" \
  --spec-exclude "log.md" \
  --spec-base HEAD \
  --local --yes --dry-run --output "$TMPDIR/spec-change-deleted-entry-output"
assert_eq "spec-change accepts a configured entry deleted from the worktree" "0" \
  "$(cat "$TMPDIR/spec-change-deleted-entry.rc")"
deleted_entry_log_dir="$SCRIPT_DIR/logs/$LAST_RUN_ID"
assert_contains "deleted entry remains attributable in the combined diff" \
  'REPOLENS_SPEC_FILE_BEGIN path="index.md"' \
  "$(cat "$deleted_entry_log_dir/spec-diff.txt")"
assert_contains "deleted entry content remains visible in the combined diff" \
  "The entry document introduces the product." \
  "$(cat "$deleted_entry_log_dir/spec-diff.txt")"
cp "$entry_backup" "$SPEC_DIR/index.md"

run_repolens "spec-change-missing-entry-union" \
  --mode spec-change \
  --spec-dir "$SPEC_DIR" \
  --spec-glob "**/*.md" \
  --spec-entry "missing.md" \
  --spec-exclude "log.md" \
  --spec-base HEAD \
  --local --yes --dry-run --output "$TMPDIR/spec-change-missing-entry-output"
assert_eq "spec-change rejects an entry absent from both base and current" "1" \
  "$(cat "$TMPDIR/spec-change-missing-entry-union.rc")"
assert_contains "missing-entry rejection names the base/current union" \
  "not included by the effective base/current specification union" \
  "$(cat "$TMPDIR/spec-change-missing-entry-union.out")"

echo ""
echo "Test 7b: project-root bundles work and untracked current specs are rejected"
run_repolens "project-root-bundle" \
  --mode spec-change \
  --spec-dir "$PROJECT_DIR" \
  --spec-glob "specs/*.md" \
  --spec-entry "specs/index.md" \
  --spec-exclude "specs/log.md" \
  --spec-base HEAD \
  --local --yes --dry-run --output "$TMPDIR/project-root-bundle-issues"
assert_eq "the project root is a valid specification directory" "0" \
  "$(cat "$TMPDIR/project-root-bundle.rc")"

printf '# New untracked requirement\n' > "$SPEC_DIR/domain/untracked.md"
run_repolens "untracked-spec-change" \
  --mode spec-change \
  --spec-dir "$SPEC_DIR" \
  --spec-glob "**/*.md" \
  --spec-exclude "log.md" \
  --spec-base HEAD \
  --local --yes --dry-run --output "$TMPDIR/untracked-spec-change-issues"
assert_eq "spec-change rejects an untracked selected document" "1" \
  "$(cat "$TMPDIR/untracked-spec-change.rc")"
assert_contains "untracked-file error names the tracking requirement" \
  "requires every selected spec file to be tracked by git" \
  "$(cat "$TMPDIR/untracked-spec-change.out")"
rm "$SPEC_DIR/domain/untracked.md"

echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
