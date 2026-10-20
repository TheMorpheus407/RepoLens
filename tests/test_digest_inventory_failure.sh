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
# repolens-r15-p7-3: final finding sort failures must preserve it too.
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
  if [[ " $* " == *' -k3,3 '* ]]; then
    case "$fault" in
      final-sort-empty)
        builtin printf 'reached\n' > "$fixture/final-sort-fault"
        return 74
        ;;
      final-sort-after-output)
        builtin printf 'reached\n' > "$fixture/final-sort-fault"
        command sort "$@" || return $?
        return 74
        ;;
    esac
  fi
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
final_sort_failures=0
for fault in final-sort-empty final-sort-after-output; do
  rm -f "$fixture/final-sort-fault"
  rc=0
  build_round_digest "$round" > "$fixture/stdout" 2> "$fixture/stderr" || rc=$?
  builtin printf '%s: rc=%s\n' "$fault" "$rc"
  test -f "$fixture/final-sort-fault"
  if [[ "$rc" -eq 0 ]]; then
    builtin printf 'FAIL: %s must fail the digest build\n' "$fault" >&2
    final_sort_failures=$((final_sort_failures + 1))
  fi
  if ! cmp "$fixture/before" "$round/digest.md"; then
    builtin printf 'FAIL: %s must preserve the complete digest\n' "$fault" >&2
    final_sort_failures=$((final_sort_failures + 1))
  fi
  staged_files="$(command find "$round" -name 'digest.md.tmp.*' -print)" || {
    builtin printf 'FAIL: staging inspection failed\n' >&2
    exit 1
  }
  test -z "$staged_files"
  fault=none
  build_round_digest "$round"
  cmp "$fixture/before" "$round/digest.md"
done
test "$final_sort_failures" -eq 0
unset -f mktemp printf read
# The inventory delimiter must also preserve actual newline bytes in paths.
mv "$round/lens-outputs/subdir/finding.md" "$round/lens-outputs/subdir/"$'line\nbreak.md'
build_round_digest "$round"
grep -q 'Retained security evidence' "$round/digest.md"
printf 'PASS: enumeration, staged-read and final-sort errors preserve digest; repaired retry succeeds.\n'

# repolens-r16-p7-2: an existing unavailable inventory is not an empty round.
cp "$round/digest.md" "$fixture/before"
mv "$round/lens-outputs" "$round/saved-lens-outputs"
for target in missing-loop-root loop-root regular-file file-target; do
  case "$target" in
    loop-root) ln -s lens-outputs "$round/lens-outputs" ;;
    regular-file) printf 'not a directory\n' > "$round/lens-outputs" ;;
    file-target)
      printf 'not a directory\n' > "$fixture/not-directory"
      ln -s "$fixture/not-directory" "$round/lens-outputs"
      ;;
    *) ln -s "$target" "$round/lens-outputs" ;;
  esac
  rc=0
  build_round_digest "$round" || rc=$?
  test "$rc" -ne 0
  cmp "$fixture/before" "$round/digest.md"
  rm "$round/lens-outputs"
  ln -s saved-lens-outputs "$round/lens-outputs"
  build_round_digest "$round"
  cmp "$fixture/before" "$round/digest.md"
  rm "$round/lens-outputs"
done
mv "$round/saved-lens-outputs" "$round/lens-outputs"

# Deterministic outages after validation, without timing-sensitive background jobs.
# DEBUG injects at the enumeration decision; find injects immediately before or
# after traversal. A dangling command-line symlink can make find succeed empty.
take_inventory_offline() {
  if [[ "$root_kind" == directory ]]; then
    mv "$round/lens-outputs" "$fixture/offline-inventory"
  else
    mv "$fixture/stored-inventory" "$fixture/offline-inventory"
  fi
  : > "$fixture/race-reached"
}
find() {
  [[ "$race_stage" != find-before ]] || take_inventory_offline
  command find "$@" || return $?
  [[ "$race_stage" != find-after ]] || take_inventory_offline
  return 0
}
outage_at_inventory_decision() {
  if [[ "$race_stage" == decision && ${FUNCNAME[1]:-} == build_round_digest &&
    ( "$1" == '[[ -d "$lens_outputs_dir" ]]' ||
      "$1" == '[[ "$inventory_present" == true'* ) ]]; then
    trap - DEBUG
    take_inventory_offline
  fi
}
mv "$round/lens-outputs" "$fixture/stored-inventory"
race_failures=0
for root_kind in directory symlink; do
  for race_stage in decision find-before find-after; do
    # Even an empty inventory outage must retain the previously saved findings.
    mv "$fixture/stored-inventory/subdir/"$'line\nbreak.md' "$fixture/race-finding.md"
    if [[ "$root_kind" == directory ]]; then
      mv "$fixture/stored-inventory" "$round/lens-outputs"
    else
      ln -s "$fixture/stored-inventory" "$round/lens-outputs"
    fi
    (
      set -T
      trap 'outage_at_inventory_decision "$BASH_COMMAND"' DEBUG
      rc=0
      build_round_digest "$round" || rc=$?
      trap - DEBUG
      test -f "$fixture/race-reached" || exit 1
      printf '%s/%s: rc=%s\n' "$root_kind" "$race_stage" "$rc"
      case_failed=0
      test "$rc" -ne 0 || case_failed=1
      cmp "$fixture/before" "$round/digest.md" || case_failed=1
      test "$case_failed" -eq 0
    ) || race_failures=$((race_failures + 1))
    rm "$fixture/race-reached"
    rm -f "$round/lens-outputs"
    mv "$fixture/offline-inventory" "$fixture/stored-inventory"
    mv "$fixture/race-finding.md" "$fixture/stored-inventory/subdir/"$'line\nbreak.md'
    ln -s "$fixture/stored-inventory" "$round/lens-outputs"
    race_stage=none
    build_round_digest "$round"
    cmp "$fixture/before" "$round/digest.md"
    test -z "$(command find "$round" -name '.digest-files.*' -o -name 'digest.md.tmp.*')"
    rm "$round/lens-outputs"
  done
done
test "$race_failures" -eq 0
printf 'PASS: invalid roots and concurrent outages preserve digest; repaired retries succeed.\n'
