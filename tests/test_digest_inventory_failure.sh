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
fault=none
# A successful sentinel write can be lost before the inventory is opened;
# deleting the pathname leaves the producer's already-open descriptor valid.
printf() {
  if [[ "${1:-}" == '\0' ]]; then
    case "$fault" in
      missing-sentinel) return 0 ;;
      open) command rm -- "$(cat "$fixture/inventory-path")" ;;
    esac
  fi
  # shellcheck disable=SC2059 # Forward the caller's format and arguments.
  builtin printf "$@"
}
fixture="$(command mktemp -d)"
trap 'chmod -R u+rwX "$fixture"; rm -rf -- "$fixture"' EXIT
round="$fixture/round-1"
mkdir -p "$round/lens-outputs/subdir"
builtin printf -- '---\ntitle: retained finding\nseverity: high\ndomain: security\nlens: injection\n---\n## hypothesis\nRetained security evidence\n' > "$round/lens-outputs/subdir/finding.md"
build_round_digest "$round"
cp "$round/digest.md" "$fixture/before"
fault=none
# Fail before output or after a real inventory has been produced.
find() {
  if [[ "$fault" == find ]]; then return 74; fi
  command find "$@" || return $?
  [[ "$fault" != partial-find ]]
}
# Preserve the real sorter output before reporting an injected producer failure.
sort() {
  command sort "$@" || return $?
  [[ "$fault" != sort ]]
}
for fault in find partial-find sort permission; do
  if [[ "$fault" == permission ]]; then
    chmod 000 "$round/lens-outputs/subdir"
    # Root cannot produce EACCES; retain the failed-producer contract there.
    if [[ -r "$round/lens-outputs/subdir" ]]; then
      builtin printf 'SKIP: real directory EACCES unavailable; injecting find failure instead.\n'
      fault="find"
    fi
  fi
  rc=0
  build_round_digest "$round" > "$fixture/stdout" 2> "$fixture/stderr" || rc=$?
  builtin printf '%s: rc=%s\n' "$fault" "$rc"
  test "$rc" -ne 0
  cmp "$fixture/before" "$round/digest.md"
  chmod 700 "$round/lens-outputs/subdir"
  fault=none
  build_round_digest "$round"
  cmp "$fixture/before" "$round/digest.md"
done
# Exercise the staged-list consumer separately from producer failures. Capture
# its private path, then inject failures without changing unrelated readers.
mktemp() {
  local path
  path="$(command mktemp "$@")" || return $?
  if [[ "${1:-}" == "$round/.digest-files.XXXXXX" ]]; then
    builtin printf '%s' "$path" > "$fixture/inventory-path"
  fi
  builtin printf '%s\n' "$path"
}
# Interrupt only the NUL-framed inventory reader, before or after a real path.
read() {
  if [[ $# == 4 && "$1" == -r && "$2" == -d && -z "$3" && "$4" == file ]]; then
    case "$fault" in
      read-empty) return 74 ;;
      read-partial)
        if (( inventory_reads > 0 )); then return 74; fi
        inventory_reads=$((inventory_reads + 1))
        ;;
    esac
  fi
  # shellcheck disable=SC2162 # Forward the caller's options, including -r.
  builtin read "$@"
}
for fault in open read-empty read-partial missing-sentinel; do
  inventory_reads=0
  rc=0
  build_round_digest "$round" > "$fixture/stdout" 2> "$fixture/stderr" || rc=$?
  printf '%s: rc=%s\n' "$fault" "$rc"
  test "$rc" -ne 0
  grep -q 'Unable to read complete findings inventory' "$fixture/stderr"
  cmp "$fixture/before" "$round/digest.md"
  test -z "$(command find "$round" -name '.digest-files.*' -print)"
  fault=none
  build_round_digest "$round"
  cmp "$fixture/before" "$round/digest.md"
done
unset -f mktemp printf read
# The inventory delimiter must also preserve actual newline bytes in paths.
mv "$round/lens-outputs/subdir/finding.md" "$round/lens-outputs/subdir/"$'line\nbreak.md'
build_round_digest "$round"
grep -q 'Retained security evidence' "$round/digest.md"
printf 'PASS: enumeration and staged-read errors preserve digest; repaired retry succeeds.\n'
