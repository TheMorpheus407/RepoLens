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

# repolens-r13-p6-3: replacing provenance must consume indentless sequences.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO/lib/core.sh"
# shellcheck source=/dev/null
source "$REPO/lib/ledger.sh"
# shellcheck source=/dev/null
source "$REPO/lib/local-dedupe.sh"
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
for width in 0 2 4; do
  dir="$FIXTURE/$width"
  mkdir "$dir"
  prefix="$(printf '%*s' "$width" '')"
  {
    printf -- '---\n'
    sed "s/^/$prefix/" <<'FRONTMATTER'
title: Authentication accepts expired session tokens
severity: high
domain: security
lens: injection
also_reported_by:
# Keep this contributor note
- lens: old
  domain: testing
  markdown_path: old.md
complexity: 5
context:
  also_reported_by:
  - lens: nested
    domain: keep
FRONTMATTER
    printf -- '---\nBody preserved\n'
  } > "$dir/canonical.md"
  printf -- '---\ntitle: Authentication accepts expired session tokens\nseverity: low\ndomain: security\nlens: auth\n---\nOther evidence\n' > "$dir/duplicate.md"
  # The library handles its own errors; expected statuses are checked explicitly.
  dedupe_local_markdown "$dir" || exit 1
  if grep -Fq 'lens: old' "$dir/canonical.md"; then
    printf 'FAIL: root indentation %s left an orphan old contributor\n' "$width" >&2
    exit 1
  fi
  grep -Fxq "$prefix# Keep this contributor note" "$dir/canonical.md"
  grep -Fq 'lens: nested' "$dir/canonical.md"
  grep -Fxq 'Body preserved' "$dir/canonical.md"
  grep -q '^status: duplicate' "$dir/duplicate.md"
  build_findings_jsonl_from_local "$dir" "$FIXTURE/registry-$width.jsonl" || exit 1
  jq -se 'length==2 and ([.[] | select(.status=="new" and .severity=="high" and .complexity==5)] | length)==1 and ([.[] | select(.status=="duplicate")] | length)==1' "$FIXTURE/registry-$width.jsonl" >/dev/null
  cp "$dir/canonical.md" "$FIXTURE/canonical-$width.before"
  cp "$dir/duplicate.md" "$FIXTURE/duplicate-$width.before"
  dedupe_local_markdown "$dir" || exit 1
  cmp "$dir/canonical.md" "$FIXTURE/canonical-$width.before"
  cmp "$dir/duplicate.md" "$FIXTURE/duplicate-$width.before"
  printf 'PASS: indent=%s, root list replaced, nested fields retained, retry byte-identical\n' "$width"
done
