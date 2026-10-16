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

# repolens-r7-p2-3: trailing-slash local-dedupe roots preserve relative
# duplicate links, actionable status, provenance and repeatability.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
FIXTURE="$(mktemp -d)" || exit 1
trap 'rm -rf -- "$FIXTURE"' EXIT
source "$REPO/lib/local-dedupe.sh" || exit 1
passed=0 failed=0
must() { "$@" || exit 1; }
check() {
  if "$@"; then passed=$((passed + 1));
  else failed=$((failed + 1)); printf 'FAIL: %s\n' "$*" >&2; fi
}
relative_link() {
  local target
  target="$(_ledger_frontmatter_scalar "$1" duplicate_of)" || return 1
  [[ -n "$target" && "$target" != /* && -f "${2%/}/$target" ]]
}
for variant in plain slash repeated-slash symlink-slash root; do
  case_dir="$FIXTURE/$variant"
  output_dir="$case_dir/findings"
  must mkdir -p "$output_dir/security/injection" "$output_dir/security/auth"
  for lens in injection auth; do
    must printf -- '---\ntitle: Missing authorization permits unauthorized account deletion\nseverity: high\ndomain: security\nlens: %s\n---\nEvidence: src/account.sh:10\n' "$lens" > "$output_dir/security/$lens/001.md"
  done
  dedupe_fixture_output="$output_dir"
  argument="$output_dir"
  link_root="$output_dir"
  case "$variant" in
    slash) argument="$output_dir/" ;;
    repeated-slash) argument="$output_dir///" ;;
    root)
      argument=/
      link_root=/
      # Bound every root traversal to the fixture while exercising real path
      # projection and duplicate linking relative to the filesystem root.
      # shellcheck disable=SC2329 # Called indirectly by ledger ingestion.
      find() {
        [[ "$dedupe_fixture_output" == "$FIXTURE/"* && -d "$dedupe_fixture_output" ]] || return 99
        local item
        local -a args=()
        for item in "$@"; do
          [[ ! "$item" =~ ^/+$ ]] || item="$dedupe_fixture_output"
          args+=("$item")
        done
        command find "${args[@]}"
      }
      ;;
    symlink-slash)
      must ln -s "$output_dir" "$case_dir/output-link"
      argument="$case_dir/output-link/"
      ;;
  esac
  must dedupe_local_markdown "$argument"
  must build_findings_jsonl_from_local "$argument" "$case_dir/records.jsonl"
  check jq -se 'length == 2 and ([.[]|select(.status=="duplicate")]|length)==1 and ([.[]|select(.status=="new")]|length)==1 and ([.[]|(.also_reported_by // [])[]]|length)==1' "$case_dir/records.jsonl"
  for md in "$output_dir"/security/*/001.md; do
    if [[ "$(_ledger_frontmatter_scalar "$md" status)" == duplicate ]]; then
      check relative_link "$md" "$link_root"
    fi
  done
  LOG_BASE="$case_dir/run"
  must build_finding_registry fixture "$argument"
  check jq -se 'length == 2 and ([.[]|select(.status=="duplicate")]|length)==1 and ([.[]|(.also_reported_by // [])[]]|length)==1' "$LOG_BASE/final/findings.jsonl"
  before="$(git hash-object -- "$output_dir"/security/*/001.md)" || exit 1
  must dedupe_local_markdown "$argument"
  check test "$(git hash-object -- "$output_dir"/security/*/001.md)" = "$before"
  must build_findings_jsonl_from_local "$argument" "$case_dir/repeated.jsonl"
  check cmp -s "$case_dir/records.jsonl" "$case_dir/repeated.jsonl"
  unset -f find
  printf 'Checked %s root\n' "$variant"
done
printf 'Results: %s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
