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

# repolens-r14-p5-1: incomplete enumeration must preserve the last digest.
# shellcheck disable=SC2317,SC2329
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/lib/core.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/rounds.sh"
fixture="$(mktemp -d)"
trap 'chmod -R u+rwX "$fixture"; rm -rf -- "$fixture"' EXIT
round="$fixture/round-1"
mkdir -p "$round/lens-outputs/subdir"
printf -- '---\ntitle: retained finding\nseverity: high\ndomain: security\nlens: injection\n---\n## hypothesis\nRetained security evidence\n' > "$round/lens-outputs/subdir/finding.md"
build_round_digest "$round"
cp "$round/digest.md" "$fixture/before"
fault=none
find() {
  if [[ "$fault" == find ]]; then return 74; fi
  command find "$@" || return $?
  [[ "$fault" != partial-find ]]
}
sort() {
  command sort "$@" || return $?
  [[ "$fault" != sort ]]
}
for fault in find partial-find sort permission; do
  if [[ "$fault" == permission ]]; then
    chmod 000 "$round/lens-outputs/subdir"
    # Root cannot produce EACCES; retain the failed-producer contract there.
    if [[ -r "$round/lens-outputs/subdir" ]]; then fault="find"; fi
  fi
  rc=0
  build_round_digest "$round" > "$fixture/stdout" 2> "$fixture/stderr" || rc=$?
  printf '%s: rc=%s\n' "$fault" "$rc"
  test "$rc" -ne 0
  cmp "$fixture/before" "$round/digest.md"
  chmod 700 "$round/lens-outputs/subdir"
  fault=none
  build_round_digest "$round"
  cmp "$fixture/before" "$round/digest.md"
done
# The inventory delimiter must also preserve actual newline bytes in paths.
mv "$round/lens-outputs/subdir/finding.md" "$round/lens-outputs/subdir/"$'line\nbreak.md'
build_round_digest "$round"
grep -q 'Retained security evidence' "$round/digest.md"
printf 'PASS: enumeration errors preserve digest; repaired retry succeeds.\n'
