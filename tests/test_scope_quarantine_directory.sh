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

# repolens-r13-p3-1/p4-1/p6-1: quarantine must name an exact file.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO/lib/branch-scope.sh"
# shellcheck source=/dev/null
source "$REPO/lib/ledger.sh"
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
# shellcheck disable=SC2034 # Consumed by sourced scope filter.
MODE=branch-review BRANCH_SCOPE_FILE="$FIXTURE/scope.json"
printf '["src/changed.sh"]\n' > "$BRANCH_SCOPE_FILE"
for kind in directory symlink-directory hardlink; do
  root="$FIXTURE/$kind"
  mkdir -p "$root/findings" "$root/outside"
  source_file="$root/findings/bad.md"
  cat > "$source_file" <<'FINDING'
---
title: Out of scope
severity: high
domain: security
lens: injection
---
src/unchanged.sh:1
FINDING
  cp "$source_file" "$root/original"
  case "$kind" in
    directory) mkdir "$source_file.out-of-scope" ;;
    symlink-directory) ln -s "$root/outside" "$source_file.out-of-scope" ;;
    hardlink) ln "$source_file" "$source_file.out-of-scope" ;;
  esac
  rc=0
  branch_scope_filter_directory "$root/findings" || rc=$?
  printf '%s: filter exit=%s (expected nonzero)\n' "$kind" "$rc"
  test "$rc" -ne 0
  cmp "$source_file" "$root/original"
  test ! -e "$source_file.out-of-scope/bad.md"
  test -z "$(find "$root/outside" -type f -print)"
  if [[ "$kind" == directory ]]; then
    rmdir "$source_file.out-of-scope"
  else
    if [[ "$kind" == symlink-directory ]]; then
      test -L "$source_file.out-of-scope"
    else
      test "$source_file" -ef "$source_file.out-of-scope"
    fi
    rm "$source_file.out-of-scope"
  fi
  # Once repaired, the same finding can be quarantined and cannot reappear in
  # the real recursive registry consumed by local reports.
  branch_scope_filter_directory "$root/findings"
  test ! -e "$source_file"
  cmp "$source_file.out-of-scope" "$root/original"
  grep -q 'out-of-scope citation' "$source_file.out-of-scope.reason"
  build_findings_jsonl_from_local "$root/findings" "$root/registry.jsonl"
  test ! -s "$root/registry.jsonl"
done
printf 'PASS: unsafe quarantine destinations preserve findings; repaired retries exclude them.\n'
