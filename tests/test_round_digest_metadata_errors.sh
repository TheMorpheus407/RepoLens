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

# Failed metadata reads must preserve the last complete digest at every key.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/core.sh"
source "$ROOT/lib/rounds.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
PASS=0 FAIL=0
check() { if "$@"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s/%s: %s\n' "$metadata_key" "$fault" "$*" >&2; fi; }
round_dir="$TMP/round-1"
mkdir -p "$round_dir/lens-outputs"
# Use the legacy alias so both the absent lens_id and fallback lens are read.
cat > "$round_dir/lens-outputs/probe.md" <<'FINDING'
---
domain: generic
lens: probe
title: Saved finding
severity: high
confidence: high
round: 1
root_cause_category:
  - retry
suspect_files:
  - src/probe.sh:1
---
## hypothesis
Saved finding
## evidence
Original evidence.
FINDING
build_round_digest "$round_dir" generic/probe
cp "$round_dir/digest.md" "$TMP/saved-digest.md"
for metadata_key in generic_source_id title severity domain lens_id lens confidence round root_cause_category suspect_files; do
  for fault in empty partial; do
    # Fault only this key, including readers reached late in digest assembly.
    awk() {
      if [[ "${FUNCNAME[1]:-}" == _round_digest_frontmatter_values && "${2:-}" == "key=$metadata_key" ]]; then
        : > "$TMP/fault-hit"
        [[ "$fault" != partial ]] || command awk "$@"
        return 74
      fi
      command awk "$@"
    }
    rc=0
    build_round_digest "$round_dir" generic/probe || rc=$?
    check test -f "$TMP/fault-hit"
    check test "$rc" -ne 0
    check cmp -s "$TMP/saved-digest.md" "$round_dir/digest.md"
    unset -f awk
    rm -f "$TMP/fault-hit"
    check build_round_digest "$round_dir" generic/probe
    check cmp -s "$TMP/saved-digest.md" "$round_dir/digest.md"
  done
done
printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
