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
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
# shellcheck source=/dev/null
source "$ROOT/lib/local-dedupe.sh" || exit 1
fixture="$(mktemp -d)" || exit 1
trap 'rm -rf -- "$fixture"' EXIT
umask 022

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
file_mode() {
  python3 - "$1" <<'PYMODE'
import os, stat, sys
print(format(stat.S_IMODE(os.stat(sys.argv[1]).st_mode), "o"))
PYMODE
}

# Simulate native BSD utilities without relying on GNU stat in assertions.
# shellcheck disable=SC2329
stat() {
  [[ "$platform" != stat_error ]] || return 1
  if [[ "$platform" == bsd ]]; then
    [[ "$#" == 3 && "$1" == -f ]] || return 1
    python3 - "$2" "$3" <<'PYBSD'
import os, stat, sys
mode = stat.S_IMODE(os.stat(sys.argv[2]).st_mode)
if sys.argv[1] == "%Lp":
    # Native BSD's low field excludes setuid, setgid and sticky bits.
    print(format(mode & 0o777, "o"))
elif sys.argv[1] == "%Mp%03Lp":
    print(format(mode >> 9, "o") + format(mode & 0o777, "03o"))
else:
    sys.exit(1)
PYBSD
  else
    command stat "$@"
  fi
}
# shellcheck disable=SC2329
chmod() {
  [[ "$platform" != chmod_error ]] || return 1
  if [[ "$platform" == bsd && "${1:-}" == --* ]]; then
    printf 'chmod: unsupported GNU option %s\n' "$1" >&2
    return 1
  fi
  command chmod "$@"
}

for platform in native bsd; do
  for mode in 400 600 640 644 1600 2600 4600 7644; do
    file="$fixture/$platform-finding-$mode.md"
    printf -- '---\ntitle: Finding\nseverity: high\n---\nEvidence\n' > "$file" || exit 1
    command chmod "$mode" "$file" || exit 1
    _local_dedupe_mark_file "$file" 'status: duplicate' 'Duplicate finding' || fail "$platform duplicate rewrite"
    actual="$(file_mode "$file")" || exit 1
    [[ "$actual" == "$mode" ]] || fail "$platform expected mode $mode, got $actual"
    grep -q '^status: duplicate$' "$file" || fail "$platform duplicate metadata missing"
    grep -q '^Duplicate finding$' "$file" || fail "$platform receipt missing"

    # Canonical promotion uses the same helper and must preserve permissions too.
    _local_dedupe_mark_file "$file" 'also_reported_by: []' 'Canonical finding' || fail "$platform canonical rewrite"
    actual="$(file_mode "$file")" || exit 1
    [[ "$actual" == "$mode" ]] || fail "$platform canonical expected mode $mode, got $actual"
    grep -q '^also_reported_by: \[\]$' "$file" || fail "$platform canonical metadata missing"
    grep -q '^Canonical finding$' "$file" || fail "$platform canonical receipt missing"
  done
  printf 'PASS: %s permissions, metadata and receipts preserved\n' "$platform"
done

for platform in stat_error chmod_error; do
  file="$fixture/$platform.md"
  printf -- '---\ntitle: Finding\nseverity: high\n---\nEvidence\n' > "$file" || exit 1
  command chmod 600 "$file" || exit 1
  cp "$file" "$fixture/before.md" || exit 1
  if _local_dedupe_mark_file "$file" 'status: duplicate' 'Duplicate finding'; then
    fail "$platform unexpectedly published a rewrite"
  fi
  cmp -s "$fixture/before.md" "$file" || fail "$platform changed original content"
  [[ "$(file_mode "$file")" == 600 ]] || fail "$platform changed original permissions"
  [[ ! -e "$file.rldedupe.$$" ]] || fail "$platform left staged output"
  printf 'PASS: %s preserves original and cleans staged output\n' "$platform"
done

# Inspect the staged file while a controlled slow writer still has it open.
platform=native
file="$fixture/private-during-write.md"
started="$fixture/private-during-write.started"
release="$fixture/private-during-write.release"
printf -- '---\ntitle: Finding\nseverity: high\n---\nEvidence\n' > "$file" || exit 1
command chmod 400 "$file" || exit 1
tmp="$file.rldedupe.$$"

# shellcheck disable=SC2329
awk() {
  local input="$2" line
  local first=1 attempt
  while IFS= read -r line || [[ -n "$line" ]]; do
    printf '%s\n' "$line"
    if [[ "$first" == 1 ]]; then
      : > "$started" || return 1
      for ((attempt = 0; attempt < 500; attempt++)); do
        [[ ! -e "$release" ]] || break
        sleep 0.01
      done
      [[ -e "$release" ]] || return 1
      first=0
    fi
  done < "$input"
}

_local_dedupe_mark_file "$file" 'status: duplicate' 'Duplicate finding' &
rewrite_pid=$!
for ((attempt = 0; attempt < 500; attempt++)); do
  [[ ! -e "$started" ]] || break
  sleep 0.01
done
if [[ ! -e "$started" ]]; then
  : > "$release"
  wait "$rewrite_pid" || true
  fail "slow writer did not start"
fi
if [[ ! -e "$tmp" ]]; then
  : > "$release"
  wait "$rewrite_pid" || true
  fail "staged output missing during write"
fi
during_mode="$(file_mode "$tmp")"
: > "$release" || exit 1
wait "$rewrite_pid" || fail "private rewrite failed"
[[ "$during_mode" == 600 ]] || fail "staged output mode under umask 022 was $during_mode, expected 600"
[[ "$(file_mode "$file")" == 400 ]] || fail "private rewrite changed final permissions"
unset -f awk
printf 'PASS: staged output is private throughout the write\n'
printf 'Results: file permissions preserved\n'
