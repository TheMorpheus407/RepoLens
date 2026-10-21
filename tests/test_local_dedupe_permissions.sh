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

# Regression: repolens-r17-p6-3. Dedupe must preserve private file modes.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/lib/local-dedupe.sh"
set -euo pipefail
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
umask 022
for mode in 600 640 644; do
  file="$fixture/finding-$mode.md"
  printf -- '---\ntitle: Finding\nseverity: high\n---\nEvidence\n' > "$file"
  chmod "$mode" "$file"
  _local_dedupe_mark_file "$file" 'status: duplicate' 'Duplicate finding'
  actual="$(stat -c %a "$file")"
  if [[ "$actual" != "$mode" ]]; then
    printf 'FAIL: expected mode %s, got %s\n' "$mode" "$actual" >&2
    exit 1
  fi
done
printf 'Results: file permissions preserved\n'
