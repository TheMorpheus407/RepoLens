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

# Regression: repolens-r6-p2-1. No real model or forge calls.
# shellcheck disable=SC2329
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/ledger.sh"
TMP="$(mktemp -d)"
cleanup() { chmod -R u+rwx "$TMP"; rm -rf "$TMP"; }
trap cleanup EXIT
mkdir -p "$TMP/output/security/injection"
printf -- '---\ntitle: Unsafe query\nseverity: high\n---\nEvidence\n' > "$TMP/output/security/injection/001.md"
OUT="$TMP/findings.jsonl"
build_findings_jsonl_from_local "$TMP/output" "$OUT"
expected="$(cat "$OUT")"
[[ -n "$expected" ]]
# An enumeration can emit a valid partial list before failing. It must never
# replace the old complete registry, even when the downstream sort succeeds.
find() { command find "$@"; return 1; }
rc=0
build_findings_jsonl_from_local "$TMP/output" "$OUT" || rc=$?
unset -f find
[[ "$rc" != 0 && "$(cat "$OUT")" == "$expected" ]]
# Exercise a real permission failure as a normal user as well.
chmod 000 "$TMP/output/security"
if [[ ! -r "$TMP/output/security" ]]; then
  rc=0
  build_findings_jsonl_from_local "$TMP/output" "$OUT" || rc=$?
  [[ "$rc" != 0 && "$(cat "$OUT")" == "$expected" ]]
fi
chmod 700 "$TMP/output/security"
[[ "$(command find "$TMP" -name '*.tmp.*' | wc -l)" -eq 0 ]]
build_findings_jsonl_from_local "$TMP/output" "$OUT"
[[ "$(cat "$OUT")" == "$expected" ]]
echo 'Results: registry preserved after partial and failed traversal'
