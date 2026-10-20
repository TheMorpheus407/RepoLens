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

# Owned receipts end at their closing sentinel; surrounding evidence is user data.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO/lib/local-dedupe.sh"
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
failed=0 checks=0
check() {
  local description="$1"; shift
  checks=$((checks + 1))
  if ! "$@"; then
    printf 'FAIL: %s: %s\n' "$scenario" "$description"
    failed=$((failed + 1))
  fi
}
for scenario in typed legacy canonical incomplete; do
  path="$FIXTURE/$scenario.md"
  prefix=$'---\ntitle: Shared state access\nseverity: high\nstatus: reviewed\n---\nEvidence before receipt.\n\n\n'
  suffix=$'\n## Follow-up\nKeep user evidence, tabs\tand spaces.  \n\n'
  if [[ "$scenario" == typed ]]; then suffix="${suffix%$'\n\n'}"; fi
  note='> Duplicate of `canonical.md` — see the canonical finding for the full details.'
  case "$scenario" in
    typed|incomplete) note=$'<!-- repolens-dedupe:duplicate -->\n'"$note" ;;
    canonical) note='> Also reported by other lenses.' ;;
  esac
  {
    printf '%s<!-- repolens-dedupe:begin -->\n%s\n' "$prefix" "$note"
    if [[ "$scenario" != incomplete ]]; then printf '<!-- repolens-dedupe:end -->\n'; fi
    printf '%s' "$suffix"
  } > "$path"
  if [[ "$scenario" == incomplete ]]; then
    cp "$path" "$FIXTURE/before.md"
    rc=0
    _local_dedupe_mark_file "$path" '' 'Replacement' || rc=$?
    check 'incomplete receipt fails safely' test "$rc" -ne 0
    check 'incomplete receipt leaves original unchanged' cmp -s "$path" "$FIXTURE/before.md"
    continue
  fi
  replacement=$'<!-- repolens-dedupe:duplicate -->\n> Updated duplicate note.'
  printf '%s<!-- repolens-dedupe:begin -->\n%s\n<!-- repolens-dedupe:end -->\n%s' \
    "$prefix" "$replacement" "$suffix" > "$FIXTURE/expected.md"
  check 'bounded replacement succeeds' _local_dedupe_mark_file "$path" '' "$replacement"
  check 'surrounding evidence and whitespace remain byte-identical' cmp -s "$path" "$FIXTURE/expected.md"
  check 'rerun succeeds' _local_dedupe_mark_file "$path" '' "$replacement"
  check 'rerun remains byte-identical' cmp -s "$path" "$FIXTURE/expected.md"
  replacement='> Canonical finding after promotion.'
  printf '%s<!-- repolens-dedupe:begin -->\n%s\n<!-- repolens-dedupe:end -->\n%s' \
    "$prefix" "$replacement" "$suffix" > "$FIXTURE/expected.md"
  check 'promotion succeeds' _local_dedupe_mark_file "$path" '' "$replacement"
  check 'promotion preserves surrounding evidence' cmp -s "$path" "$FIXTURE/expected.md"
done
printf 'Receipt replacement: %s checks, %s failures.\n' "$checks" "$failed"
test "$failed" -eq 0
