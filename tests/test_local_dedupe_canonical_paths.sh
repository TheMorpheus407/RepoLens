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

# repolens-r10-p3-2 / repolens-r10-p5-1: duplicate links retain filename bytes.
# shellcheck disable=SC2034 # Registry generation consumes LOG_BASE.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO/lib/local-dedupe.sh"
# shellcheck source=/dev/null
source "$REPO/lib/artifacts.sh"
set -euo pipefail
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
PASS=0 FAIL=0
# Continue independent path variants while retaining every assertion failure.
check() {
  local desc="$1"; shift
  if "$@"; then PASS=$((PASS + 1))
  else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$desc"; fi
}
# Decode the producer's JSON-compatible YAML string, or a legacy plain path.
link_matches() {
  local raw decoded
  raw="$(_ledger_frontmatter_scalar "$1" duplicate_of)" || return 1
  if [[ "$raw" == \"* ]]; then
    decoded="$(jq -er 'select(type == "string")' <<< "$raw")" || return 1
  else
    decoded="$raw"
  fi
  [[ "$decoded" == "$2" ]]
}
for variant in plain quote apostrophe newline carriage backslash whitespace unicode; do
  output="$FIXTURE/$variant/findings"
  LOG_BASE="$FIXTURE/$variant/run"
  mkdir -p "$output"
  case "$variant" in
    plain) canonical=a.md ;;
    quote) canonical='"a.md' ;;
    apostrophe) canonical="'a.md" ;;
    newline) canonical=$'a\nb.md' ;;
    carriage) canonical=$'a\rb.md' ;;
    backslash) canonical='a\b.md' ;;
    whitespace) canonical=' a : b .md' ;;
    unicode) canonical=$'a\u0085b\u2028c.md' ;;
  esac
  printf -- '---\ntitle: Missing authorization permits unauthorized account deletion\nseverity: high\nlens: injection\ndomain: security\n---\nEvidence: src/account.sh:10\n' > "$output/$canonical"
  printf -- '---\ntitle: Missing authorization permits unauthorized account deletion\nseverity: low\nlens: auth\ndomain: security\n---\nEvidence: src/account.sh:10\n' > "$output/z.md"
  # Repeated trailing slashes must not alter relative path serialization.
  dedupe_local_markdown "$output///"
  check "$variant relative link preserves bytes" link_matches "$output/z.md" "$canonical"
  build_finding_registry canonical-path "$output///" false
  registry="$LOG_BASE/final/findings.jsonl"
  check "$variant one actionable and one duplicate" jq -se \
    'length == 2 and (map(select(.status == "new"))|length)==1 and (map(select(.status == "duplicate"))|length)==1' "$registry"
  check "$variant canonical/contributor paths preserved" jq -se --arg canonical "$output/$canonical" --arg duplicate "$output/z.md" \
    'any(.[]; .markdown_path==$canonical and .status=="new" and (.also_reported_by|length)==1 and .also_reported_by[0].markdown_path==$duplicate)' "$registry"
  generate_todo_md "$registry" "$LOG_BASE/final/TODO.md"
  check "$variant TODO renders the finding once" test "$(awk '/Missing authorization permits unauthorized account deletion/ {n++} END {print n+0}' "$LOG_BASE/final/TODO.md")" -eq 1
  before="$(git hash-object -- "$output/$canonical" "$output/z.md")"
  dedupe_local_markdown "$output///"
  check "$variant repeat is byte-identical" test "$(git hash-object -- "$output/$canonical" "$output/z.md")" = "$before"
  if [[ "$variant" == plain ]]; then
    # A link to an unindexed trailing-LF filename must not match a.md after
    # command substitution. Both findings must remain visible without provenance.
    for invalid in '"a.md\n"' '"a.md\n\n"'; do
      _local_dedupe_mark_file "$output/z.md" "$(printf 'status: duplicate\nduplicate_of: %s' "$invalid")" ''
      before="$(git hash-object -- "$output/$canonical" "$output/z.md")"
      build_finding_registry trailing-lf-link "$output" false
      check 'trailing LF link cannot suppress a different filename' jq -se \
        'length == 2 and all(.[]; .status == "new")' "$registry"
      check 'trailing LF link cannot invent contributor provenance' jq -se \
        'all(.[]; has("also_reported_by") | not)' "$registry"
      generate_todo_md "$registry" "$LOG_BASE/final/TODO.md"
      check 'trailing LF link leaves both findings in TODO' test "$(awk '/Missing authorization permits unauthorized account deletion/ {n++} END {print n+0}' "$LOG_BASE/final/TODO.md")" -eq 2
      check 'trailing LF recovery preserves Markdown evidence' test "$(git hash-object -- "$output/$canonical" "$output/z.md")" = "$before"
    done
  fi
  if [[ "$variant" == newline ]]; then
    # Two JSON strings must not be concatenated into a real newline filename;
    # embedded NUL is not a valid filename byte and must not be silently lost.
    for invalid in '"a" "b.md"' '"a\u0000\nb.md"'; do
      _local_dedupe_mark_file "$output/z.md" "$(printf 'status: duplicate\nduplicate_of: %s' "$invalid")" ''
      build_finding_registry invalid-link "$output" false
      check 'invalid JSON path cannot suppress a matching newline filename' jq -se \
        'length == 2 and all(.[]; .status == "new")' "$LOG_BASE/final/findings.jsonl"
    done
  fi
done
# Decoder infrastructure failure is distinct from malformed link syntax.
before_registry="$(sha256sum < "$LOG_BASE/final/findings.jsonl")"
# Fail only the quoted-link decoder; other production jq work remains real.
# shellcheck disable=SC2329 # Invoked indirectly by the sourced ledger.
jq() {
  if [[ "${1:-}" == -er || "${1:-}" == -ser || "${1:-}" == -ner ]]; then return 42; fi
  command jq "$@"
}
rc=0
build_finding_registry decoder-error "$output" false > "$FIXTURE/decoder-error.log" 2>&1 || rc=$?
unset -f jq
check 'decoder failure rejects rebuilding' test "$rc" -ne 0
check 'decoder failure preserves published registry' test "$(sha256sum < "$LOG_BASE/final/findings.jsonl")" = "$before_registry"
# Malformed links must restore eligibility rather than fail ingestion or hide
# findings. This preserves the existing invalid-link policy with JSON decoding.
_local_dedupe_mark_file "$output/z.md" $'status: duplicate\nduplicate_of: "unterminated' ''
build_finding_registry malformed-link "$output" false
check 'malformed quoted link remains actionable' jq -se \
  'length == 2 and all(.[]; .status == "new")' "$LOG_BASE/final/findings.jsonl"
printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
test "$FAIL" -eq 0
