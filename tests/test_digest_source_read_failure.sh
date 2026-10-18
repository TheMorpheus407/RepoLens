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

# repolens-r14-p5-2: source IO errors cannot become malformed/empty findings.
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
mkdir -p "$round/lens-outputs"
finding="$round/lens-outputs/finding.md"
printf -- '---\ntitle: retained finding\nseverity: high\ndomain: security\nlens: injection\n---\n## hypothesis\nRetained security evidence\n' > "$finding"
build_round_digest "$round" || exit 1
cp "$round/digest.md" "$fixture/before" || exit 1
FAIL=0
check() {
  if "$@"; then printf 'PASS: %s\n' "$*"; else printf 'FAIL: %s\n' "$*"; FAIL=$((FAIL + 1)); fi
}
fault=none
awk() {
  if [[ "${1:-}" == -v && "${2:-}" == content_mode=* ]]; then
    case "$fault" in
      partial-read) command awk "$@" || return $?; return 74 ;;
      parser-io) return 74 ;;
      parser-io-one) return 1 ;;
    esac
  fi
  command awk "$@"
}
for fault in permission partial-read parser-io parser-io-one; do
  if [[ "$fault" == permission ]]; then
    chmod 000 "$finding"
    if [[ -r "$finding" ]]; then
      printf 'SKIP: real EACCES unavailable; inject partial source read instead.\n'
      fault=partial-read
    fi
  fi
  rc=0
  build_round_digest "$round" > "$fixture/stdout" 2> "$fixture/stderr" || rc=$?
  check test "$rc" -ne 0
  check cmp "$fixture/before" "$round/digest.md"
  chmod 600 "$finding"
  cp "$fixture/before" "$round/digest.md"
  fault=none
  check build_round_digest "$round"
  check cmp "$fixture/before" "$round/digest.md"
done
# The parser must discard emitted segments when its final status is failure.
for fault in partial-read parser-io parser-io-one; do
  rc=0
  _round_digest_finding_segments "$finding" > "$fixture/segments" 2> "$fixture/stderr" || rc=$?
  check test "$rc" -eq 2
  check test ! -s "$fixture/segments"
done
fault=none
# Readable empty and malformed drafts return format status, remain skippable,
# and cannot alter the valid finding's digest.
: > "$round/lens-outputs/empty.md"
printf -- '---\nseverity: high\ndomain: security\nlens: injection\n' > "$round/lens-outputs/unterminated.md"
printf 'ordinary notes without frontmatter\n' > "$round/lens-outputs/notes.md"
for draft in empty unterminated notes; do
  rc=0
  _round_digest_finding_segments "$round/lens-outputs/$draft.md" > "$fixture/segments" || rc=$?
  check test "$rc" -eq 1
  check test ! -s "$fixture/segments"
done
check build_round_digest "$round"
check cmp "$fixture/before" "$round/digest.md"
printf 'Results: %s failed\n' "$FAIL"
(( FAIL == 0 ))
