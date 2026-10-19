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

# Each Txx scenario implements one row in docs/local-dedupe-status-transitions.md.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/local-dedupe.sh
source "$REPO/lib/local-dedupe.sh"
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
checks=0 failed=0
check() {
  checks=$((checks + 1))
  if ! "$@" >/dev/null 2>&1; then
    printf 'FAIL: %s: %s\n' "$scenario" "$*" >&2
    failed=$((failed + 1))
  fi
}
# Reset the finding with arbitrary status metadata and stable surrounding data.
fixture() {
  printf -- '---\ntitle: Saved finding\nseverity: high\ndetails:\n  retained: yes\n%s---\nEvidence: keep this\n' "$1" > "$FIXTURE/input.md"
}
mark() {
  local additions=''
  [[ "$1" != D ]] || additions=$'status: duplicate\nduplicate_of: canonical.md'
  _local_dedupe_mark_file "$FIXTURE/input.md" "$additions" ''
}
# Rejected operations must preserve the entire document and remove temporary output.
refuse() {
  local role="$1" rc=0
  cp "$FIXTURE/input.md" "$FIXTURE/refused.md"
  mark "$role" || rc=$?
  check test "$rc" -ne 0
  check cmp -s "$FIXTURE/refused.md" "$FIXTURE/input.md"
  check test ! -e "$FIXTURE/input.md.rldedupe.$$"
}
original=$'status : needs-validation # retain\n'
for scenario in T01 T02 T03 T04 T05 T06 T07 T08 T09 T10 T11 T12 T13 T14 T15 T16 T17 T18; do
  fixture "$original"
  cp "$FIXTURE/input.md" "$FIXTURE/original.md"
  case "$scenario" in
    T01)
      check mark C
      check mark C
      check cmp -s "$FIXTURE/original.md" "$FIXTURE/input.md"
      ;;
    T02)
      check mark C
      check mark D
      check test "$(grep -c '^status' "$FIXTURE/input.md")" -eq 1
      check grep -qxF 'status: duplicate' "$FIXTURE/input.md"
      check grep -qxF 'repolens_dedupe_original_status: "status : needs-validation # retain"' "$FIXTURE/input.md"
      ;;
    T03)
      check mark D
      cp "$FIXTURE/input.md" "$FIXTURE/duplicate.md"
      check mark D
      check cmp -s "$FIXTURE/duplicate.md" "$FIXTURE/input.md"
      ;;
    T04)
      check mark D
      check mark C
      check cmp -s "$FIXTURE/original.md" "$FIXTURE/input.md"
      ;;
    T05)
      for role in D C D D C C; do check mark "$role"; done
      check cmp -s "$FIXTURE/original.md" "$FIXTURE/input.md"
      ;;
    T06)
      fixture ''
      cp "$FIXTURE/input.md" "$FIXTURE/original.md"
      for role in C D D C; do check mark "$role"; done
      check cmp -s "$FIXTURE/original.md" "$FIXTURE/input.md"
      ;;
    T07)
      for role in C D; do
        fixture $'status\t: "duplicate" # old\n'
        check mark "$role"
        check test "$(grep -c '^status' "$FIXTURE/input.md" || true)" -eq "$([[ "$role" == D ]] && echo 1 || echo 0)"
        check test "$(grep -c '^repolens_dedupe_original_status:' "$FIXTURE/input.md" || true)" -eq 0
      done
      ;;
    T08|T09)
      check mark D
      if [[ "$scenario" == T08 ]]; then value='edited'; else value='needs-validation # retain'; fi
      sed -i "s/^status:.*/status : $value/" "$FIXTURE/input.md"
      if [[ "$scenario" == T08 ]]; then
        refuse D
        refuse C
      else
        check mark D
        check mark C
        check cmp -s "$FIXTURE/original.md" "$FIXTURE/input.md"
      fi
      ;;
    T10|T11)
      check mark D
      sed -i '2,/^---$/ { /^---$/! s/^/  /; }' "$FIXTURE/input.md"
      check mark D
      refuse C
      if [[ "$scenario" == T11 ]]; then
        sed -i '2,/^---$/ { /^---$/! s/^  //; }' "$FIXTURE/input.md"
        check mark C
        check cmp -s "$FIXTURE/original.md" "$FIXTURE/input.md"
      fi
      ;;
    T12)
      for value in '&workflow pending' '[&workflow pending]' '{phase: &workflow pending}' '{? &workflow phase: pending}'; do
        fixture "status: $value"$'\nstate: *workflow\n'
        cp "$FIXTURE/input.md" "$FIXTURE/original.md"
        check mark C
        refuse D
        refuse D
        check mark C
        check cmp -s "$FIXTURE/original.md" "$FIXTURE/input.md"
      done
      ;;
    T13)
      for value in $'"needs\nvalidation"' $'|\n  # retained' $'[needs,\nvalidation]'; do
        fixture "status: $value"$'\n'
        refuse D
        refuse C
      done
      ;;
    T14)
      for backup in '"status: one" "status: two"' '"status: old\rstatus: duplicate"' '"status: duplicate"' '"status: [&workflow pending]"'; do
        fixture $'status: duplicate\n'"repolens_dedupe_original_status: $backup"$'\n'
        refuse D
        refuse C
      done
      ;;
    T15)
      for role in C D; do
        fixture $'status: needs-validation\r\n'
        cp "$FIXTURE/input.md" "$FIXTURE/original.md"
        if [[ "$role" == D ]]; then refuse D; else check mark C; fi
        check cmp -s "$FIXTURE/original.md" "$FIXTURE/input.md"
      done
      ;;
    T16)
      # Simulate a status edit precisely between the two reads.
      awk() {
        command awk "$@" || return $?
        if [[ "${RL_STATUS_SCAN:-0}" == 1 ]]; then
          sed -i 's/needs-validation/edited/' "$FIXTURE/input.md"
          cp "$FIXTURE/input.md" "$FIXTURE/edited.md"
        fi
      }
      rc=0
      mark D || rc=$?
      unset -f awk
      check test "$rc" -ne 0
      check cmp -s "$FIXTURE/edited.md" "$FIXTURE/input.md"
      check test ! -e "$FIXTURE/input.md.rldedupe.$$"
      ;;
    T17)
      # A failed publication cannot consume a saved status; a retry restores it.
      check mark D
      mv() { return 77; }
      refuse C
      unset -f mv
      check mark C
      check cmp -s "$FIXTURE/original.md" "$FIXTURE/input.md"
      ;;
    T18)
      # Singleton/stale-link eligibility is handled by the actual grouping/reader.
      output="$FIXTURE/output"
      mkdir -p "$output"
      cp "$FIXTURE/input.md" "$output/a.md"
      printf -- '---\ntitle: Saved finding\nseverity: critical\n---\nEvidence: keep this\n' > "$output/b.md"
      check dedupe_local_markdown "$output"
      check grep -qxF 'status: duplicate' "$output/a.md"
      sed -i 's/title: Saved finding/title: Unrelated memory corruption/' "$output/b.md"
      before="$(sha256sum "$output/"*.md)"
      check dedupe_local_markdown "$output"
      check test "$before" = "$(sha256sum "$output/"*.md)"
      check build_findings_jsonl_from_local "$output" "$FIXTURE/records.jsonl"
      check jq -se 'length == 2 and all(.[]; .status == "new")' "$FIXTURE/records.jsonl"
      ;;
  esac
done
printf 'Local dedupe status transitions: %s checks, %s failures.\n' "$checks" "$failed"
(( failed == 0 ))
