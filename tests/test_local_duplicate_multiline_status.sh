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

# Refuse multiline status rewrites before a managed-looking first line is removed.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
FIXTURE="$(mktemp -d)" || exit 1
trap 'rm -rf -- "$FIXTURE"' EXIT
# shellcheck source=/dev/null
source "$REPO/lib/local-dedupe.sh" || exit 1
failed=0 checks=0
# Count each assertion and report failures without ending the remaining cases.
check() {
  checks=$((checks + 1))
  if ! "$@" >/dev/null 2>&1; then
    printf 'FAIL: %s: %s\n' "$scenario" "$*"
    failed=$((failed + 1))
  fi
}
# The valid plain YAML scalar folds to "duplicate pending". Deleting only its
# first line would attach "pending" to the preceding title and lose the status.
for indent in '' '  '; do
  for padding in '' ' ' $'\t'; do
    for mode in canonical duplicate; do
      scenario="folded/$indent/$padding/$mode"
      file="$FIXTURE/folded.md"
      printf '%s\n' --- "${indent}title: Shared state" \
        "${indent}status$padding: duplicate" "${indent}  pending" \
        "${indent}severity: high" --- body > "$file" || exit 1
      cp "$file" "$FIXTURE/expected.md" || exit 1
      addition=''
      [[ "$mode" != duplicate ]] || addition=$'status: duplicate\nduplicate_of: canonical.md'
      rc=0
      _local_dedupe_mark_file "$file" "$addition" note > "$FIXTURE/rewrite.log" 2>&1 || rc=$?
      check test "$rc" -ne 0
      check grep -q 'not a single-line scalar' "$FIXTURE/rewrite.log"
      check cmp -s "$file" "$FIXTURE/expected.md"
      check test "$(find "$FIXTURE" -name '*.rldedupe.*' | wc -l)" -eq 0
    done
  done
done
# Exercise the real grouped caller in both roles, including repeated dedupe.
for role in canonical duplicate; do
  scenario="grouped/$role"
  output="$FIXTURE/$role"
  mkdir -p "$output" || exit 1
  for name in canonical duplicate; do
    severity=high
    [[ "$name" != canonical ]] || severity=critical
    {
      printf '%s\n' --- 'title: Unsafe access to shared state'
      [[ "$name" != "$role" ]] || printf '%s\n' 'status : duplicate' '  pending'
      printf '%s\n' "severity: $severity" 'domain: security' "lens: probe-$name" --- body
    } > "$output/$name.md" || exit 1
  done
  cp "$output/$role.md" "$FIXTURE/expected.md" || exit 1
  check dedupe_local_markdown "$output"
  check cmp -s "$output/$role.md" "$FIXTURE/expected.md"
  check dedupe_local_markdown "$output"
  check cmp -s "$output/$role.md" "$FIXTURE/expected.md"
done
# Quoted YAML can continue at column zero even when the next line looks like
# another root key. Mapping-shaped lines cannot establish its scalar boundary.
for value in '"duplicate' "'duplicate" '"duplicate\"' "'duplicate''"; do
  quote="${value:0:1}"
  for padding in '' ' ' $'\t'; do
    for mode in canonical duplicate; do
      scenario="quoted/$value/$padding/$mode"
      file="$FIXTURE/quoted.md"
      printf '%s\n' --- 'title: Shared state' "status$padding: $value" \
        "pending: confirmation${quote}" 'severity: high' --- body > "$file" || exit 1
      cp "$file" "$FIXTURE/expected.md" || exit 1
      addition=''
      [[ "$mode" != duplicate ]] || addition=$'status: duplicate\nduplicate_of: canonical.md'
      rc=0
      _local_dedupe_mark_file "$file" "$addition" note > "$FIXTURE/rewrite.log" 2>&1 || rc=$?
      check test "$rc" -ne 0
      check grep -q 'not a single-line scalar' "$FIXTURE/rewrite.log"
      check cmp -s "$file" "$FIXTURE/expected.md"
      check test "$(find "$FIXTURE" -name '*.rldedupe.*' | wc -l)" -eq 0
    done
  done
done
# Exercise that quoted continuation through real grouping in both roles too.
for quote in '"' "'"; do
  for role in canonical duplicate; do
    scenario="grouped-quoted/$quote/$role"
    output="$FIXTURE/quoted-group"
    mkdir -p "$output" || exit 1
    for name in canonical duplicate; do
      severity=high
      [[ "$name" != canonical ]] || severity=critical
      {
        printf '%s\n' --- 'title: Unsafe access to shared state'
        [[ "$name" != "$role" ]] || printf '%s\n' "status : ${quote}duplicate" "pending: confirmation${quote}"
        printf '%s\n' "severity: $severity" 'domain: security' "lens: probe-$name" --- body
      } > "$output/$name.md" || exit 1
    done
    cp "$output/$role.md" "$FIXTURE/expected.md" || exit 1
    check dedupe_local_markdown "$output"
    check cmp -s "$output/$role.md" "$FIXTURE/expected.md"
    check dedupe_local_markdown "$output"
    check cmp -s "$output/$role.md" "$FIXTURE/expected.md"
  done
done
# YAML node properties hide the opening quote; anchors can also be referenced
# elsewhere. Unsupported forms must never move into an opaque archive string.
for value in '&state "duplicate' '!!str "duplicate' "!local 'duplicate" \
    '!<tag:yaml.org,2002:str> "duplicate' '!!str &state "duplicate' \
    '&state !!str "duplicate'; do
  for mode in canonical duplicate; do
    scenario="prefixed-multiline/$value/$mode"
    file="$FIXTURE/prefixed.md"
    quote='"'
    [[ "$value" != "!local 'duplicate" ]] || quote="'"
    printf '%s\n' --- 'title: Shared state' "status : $value" \
      "pending: confirmation${quote}" 'severity: high' --- body > "$file" || exit 1
    cp "$file" "$FIXTURE/expected.md" || exit 1
    addition=''
    [[ "$mode" != duplicate ]] || addition=$'status: duplicate\nduplicate_of: canonical.md'
    rc=0
    _local_dedupe_mark_file "$file" "$addition" note > "$FIXTURE/rewrite.log" 2>&1 || rc=$?
    check test "$rc" -ne 0
    check grep -q 'preserving' "$FIXTURE/rewrite.log"
    check cmp -s "$file" "$FIXTURE/expected.md"
    check test "$(find "$FIXTURE" -name '*.rldedupe.*' | wc -l)" -eq 0
  done
done
# A mapping-shaped continuation at column zero must not hide an indented root
# status from validation by changing the apparent root indentation.
for value in '"duplicate' "'duplicate"; do
  for mode in canonical duplicate; do
    scenario="indented-quoted/$value/$mode"
    file="$FIXTURE/indented-quoted.md"
    quote="${value:0:1}"
    printf '%s\n' --- '  title: Shared state' "  status: $value" \
      "pending: confirmation${quote}" '  severity: high' --- body > "$file" || exit 1
    cp "$file" "$FIXTURE/expected.md" || exit 1
    addition=''
    [[ "$mode" != duplicate ]] || addition=$'status: duplicate\nduplicate_of: canonical.md'
    rc=0
    _local_dedupe_mark_file "$file" "$addition" note > "$FIXTURE/rewrite.log" 2>&1 || rc=$?
    check test "$rc" -ne 0
    check grep -q 'not a single-line scalar' "$FIXTURE/rewrite.log"
    check cmp -s "$file" "$FIXTURE/expected.md"
    check test "$(find "$FIXTURE" -name '*.rldedupe.*' | wc -l)" -eq 0
  done
done
# Anchors may be referenced by aliases elsewhere even on a single line. Tags
# and aliases also remain outside the scalar-preservation contract. Test both
# live entries and legacy archives so restoration cannot publish invalid YAML.
for value in '&state duplicate-pending' '!!str duplicate-pending' '*state' \
    '[duplicate,' '{state: duplicate,'; do
  for mode in canonical duplicate restore-only; do
    scenario="unsupported/$value/$mode"
    file="$FIXTURE/unsupported.md"
    original="status: $value"
    {
      printf '%s\n' --- 'title: Shared state'
      [[ "$value" != '*state' ]] || printf '%s\n' 'source_status: &state pending'
      if [[ "$mode" == restore-only ]]; then
        archive="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$original")" || exit 1
        printf '%s\n' "repolens_dedupe_original_status: $archive" 'status: duplicate' 'duplicate_of: canonical.md'
      else
        printf '%s\n' "$original"
      fi
      [[ "$value" != '&state duplicate-pending' ]] || printf '%s\n' 'previous_status: *state'
      [[ "$value" != '[duplicate,' ]] || printf '%s\n' 'pending: confirmation]'
      [[ "$value" != '{state: duplicate,' ]] || printf '%s\n' 'pending: confirmation}'
      printf '%s\n' 'severity: high' --- body
    } > "$file" || exit 1
    cp "$file" "$FIXTURE/expected.md" || exit 1
    addition=''
    [[ "$mode" != duplicate ]] || addition=$'status: duplicate\nduplicate_of: canonical.md'
    rc=0
    _local_dedupe_mark_file "$file" "$addition" note "$mode" > "$FIXTURE/rewrite.log" 2>&1 || rc=$?
    check test "$rc" -ne 0
    check grep -q 'preserving' "$FIXTURE/rewrite.log"
    check cmp -s "$file" "$FIXTURE/expected.md"
    check test "$(find "$FIXTURE" -name '*.rldedupe.*' | wc -l)" -eq 0
  done
done
# Exercise prefixed multiline, anchor-reference and alias preservation through
# actual grouping, repetition and the read-only registry in both rewrite roles.
for value in '&state "duplicate' '!!str "duplicate' '&state duplicate-pending' '*state'; do
  for role in canonical duplicate; do
    scenario="grouped-properties/$value/$role"
    output="$FIXTURE/property-group"
    mkdir -p "$output" || exit 1
    for name in canonical duplicate; do
      severity=high
      [[ "$name" != canonical ]] || severity=critical
      {
        printf '%s\n' --- 'title: Unsafe access to shared state'
        [[ "$value" != '*state' ]] || printf '%s\n' 'source_status: &state pending'
        if [[ "$name" == "$role" ]]; then
          printf '%s\n' "status : $value"
          [[ "$value" != *'"duplicate' ]] || printf '%s\n' 'pending: confirmation"'
          [[ "$value" != '&state duplicate-pending' ]] || printf '%s\n' 'previous_status: *state'
        fi
        printf '%s\n' "severity: $severity" 'domain: security' "lens: probe-$name" --- body
      } > "$output/$name.md" || exit 1
    done
    cp "$output/$role.md" "$FIXTURE/expected.md" || exit 1
    check dedupe_local_markdown "$output"
    check cmp -s "$output/$role.md" "$FIXTURE/expected.md"
    check dedupe_local_markdown "$output"
    check cmp -s "$output/$role.md" "$FIXTURE/expected.md"
    check build_findings_jsonl_from_local "$output" "$FIXTURE/property-registry.jsonl"
    # A rejected duplicate rewrite remains actionable; canonical preservation
    # still allows the other ordinary file to receive validated suppression.
    expected_new=1
    [[ "$role" != duplicate ]] || expected_new=2
    check jq -se --argjson n "$expected_new" \
      'length == 2 and ([.[] | select(.status == "new")] | length) == $n' "$FIXTURE/property-registry.jsonl"
  done
done
# Quoted literal indicators have no YAML property/alias semantics and remain
# supported, including exact archival and restoration of the original entry.
for value in '"!literal"' "'&literal'" '"*literal"'; do
  scenario="literal/$value"
  file="$FIXTURE/literal.md"
  printf '%s\n' --- 'title: Shared state' "status: $value" --- body > "$file" || exit 1
  cp "$file" "$FIXTURE/expected.md" || exit 1
  check _local_dedupe_mark_file "$file" $'status: duplicate\nduplicate_of: canonical.md' note
  check _local_dedupe_mark_file "$file" '' ''
  check cmp -s "$file" "$FIXTURE/expected.md"
done
# Blank lines and comments after a complete scalar do not extend its value.
scenario=single-line-with-comments
file="$FIXTURE/comments.md"
printf '%s\n' --- 'title: Shared state' 'status : duplicate # managed' \
  '' '  # status comment' 'severity: high' --- body > "$file" || exit 1
check _local_dedupe_mark_file "$file" '' ''
check test "$(grep -cE '^status[[:space:]]*:' "$file" || true)" -eq 0
check grep -qxF '  # status comment' "$file"
printf 'Local duplicate multiline status: %s checks, %s failures.\n' "$checks" "$failed"
(( failed == 0 ))
