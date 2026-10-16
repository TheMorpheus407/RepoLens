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

# Full finding bodies must never acquire public permissions while staged.
set -euo pipefail
check() { "$@" || { printf 'FAIL: %s\n' "$*" >&2; exit 1; }; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/ledger.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
check mkdir -m 700 "$TMP/private"
check mkdir -m 755 "$TMP/public"
private_file="$TMP/private/001.md"
check printf -- '---\ntitle: Private finding\nseverity: high\n---\nPrivate body\n' > "$private_file"
check chmod 600 "$private_file"
OUT="$TMP/public/findings.jsonl"
# Observe the actual destination descriptor BEFORE any source bytes are copied.
# The registry is allowed to contain metadata; the complete body is private.
cat() {
  local arg
  for arg in "$@"; do
    if [[ "$arg" == "$private_file" ]]; then
      python3 -c 'import os, stat, sys
mode = stat.S_IMODE(os.fstat(1).st_mode)
if mode & 0o077:
    sys.exit("unsafe snapshot permissions before copy: %04o" % mode)
' || return 1
      printf 'checked\n' >> "$TMP/observed"
    fi
  done
  command cat "$@"
}
umask 000
check build_findings_jsonl_from_local "$TMP/private" "$OUT"
check test -s "$TMP/observed"
check jq -se 'length == 1 and .[0].title == "Private finding"' "$OUT"
check test "$(find "$TMP/public" -type f | wc -l)" -eq 1
printf 'PASS: full-body snapshot is private before copy and removed after ingestion\n'
# Snapshot allocation failure must preserve the previous projection and clean
# the already-created registry candidate and enumeration list.
expected="$(command cat "$OUT")"
mktemp() { return 1; }
rc=0
build_findings_jsonl_from_local "$TMP/private" "$OUT" || rc=$?
check test "$rc" -ne 0
check test "$(command cat "$OUT")" = "$expected"
check test "$(find "$TMP/public" -type f | wc -l)" -eq 1
printf 'PASS: snapshot allocation failure preserves registry and cleans staging\n'
printf 'Results: snapshot privacy checks passed\n'
