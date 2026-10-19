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

# Custom status metadata survives duplicate assignment and canonical promotion.
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
for indent in '' '  '; do
  for padding in '' ' ' $'\t'; do
    for value in duplicate_candidate duplicate_of '"duplicate pending"' "'needs-validation' # keep \\ and \"quotes\"" $'duplicate_pending # \u007f\u0085\u009f\u2028\u2029\ufffe\uffff'; do
      scenario="indent=${#indent} / padding=${#padding} / $value"
      original="${indent}status${padding}: $value"
      printf -- '---\n%stitle: Saved finding\n%s\n%sdetails:\n%s  status : duplicate\n---\nEvidence: src/state.sh:12\n' \
        "$indent" "$original" "$indent" "$indent" > "$FIXTURE/input.md"
      check _local_dedupe_mark_file "$FIXTURE/input.md" $'status: duplicate\nduplicate_of: canonical.md' ''
      check test "$(grep -cE "^${indent}status[[:space:]]*:" "$FIXTURE/input.md")" -eq 1
      backup="$(sed -n "s/^${indent}repolens_dedupe_original_status: //p" "$FIXTURE/input.md")"
      check test "$(jq -r . <<< "$backup")" = "$original"
      check jq -ne --arg text "$backup" '$text | explode | all(.[];
        ((. >= 127 and . <= 159) or . == 8232 or . == 8233 or . == 65534 or . == 65535) | not)'
      before="$(sha256sum "$FIXTURE/input.md")"
      check _local_dedupe_mark_file "$FIXTURE/input.md" $'status: duplicate\nduplicate_of: canonical.md' ''
      check test "$before" = "$(sha256sum "$FIXTURE/input.md")"
      check _local_dedupe_mark_file "$FIXTURE/input.md" '' ''
      check grep -qxF "$original" "$FIXTURE/input.md"
      check grep -qxF "${indent}  status : duplicate" "$FIXTURE/input.md"
      check test "$(grep -c 'repolens_dedupe_original_status' "$FIXTURE/input.md" || true)" -eq 0
    done
  done
done

# Refuse invalid/conflicting saved data in both duplicate and canonical roles.
for role in duplicate canonical; do
  additions=''
  [[ "$role" != duplicate ]] || additions=$'status: duplicate\nduplicate_of: canonical.md'
  for invalid in invalid-backup conflicting-status duplicate-backup multiple-statuses block-status multi-string-backup leading-nonstring-backup trailing-nonstring-backup; do
    scenario="$role / $invalid"
    printf -- '---\ntitle: Saved finding\nstatus: duplicate\n' > "$FIXTURE/input.md"
    case "$invalid" in
      invalid-backup) printf 'repolens_dedupe_original_status: {broken}\n' ;;
      conflicting-status) printf 'repolens_dedupe_original_status: "status : old"\nstatus : edited\n' ;;
      duplicate-backup) printf 'repolens_dedupe_original_status: "status : old"\nrepolens_dedupe_original_status: "status : other"\n' ;;
      multiple-statuses) printf 'status : first\nstatus : second\n' ;;
      block-status) printf 'status : |\n  preserve this block\n' ;;
      multi-string-backup) printf 'repolens_dedupe_original_status: "status: one" "status: two"\n' ;;
      leading-nonstring-backup) printf 'repolens_dedupe_original_status: 42 "status: old"\n' ;;
      trailing-nonstring-backup) printf 'repolens_dedupe_original_status: "status: old" null\n' ;;
    esac >> "$FIXTURE/input.md"
    printf -- '---\nEvidence: keep this\n' >> "$FIXTURE/input.md"
    cp "$FIXTURE/input.md" "$FIXTURE/expected.md"
    rc=0
    _local_dedupe_mark_file "$FIXTURE/input.md" "$additions" '' || rc=$?
    check test "$rc" -ne 0
    check cmp -s "$FIXTURE/expected.md" "$FIXTURE/input.md"
    check test ! -e "$FIXTURE/input.md.rldedupe.$$"
  done
done

# An edit after the metadata scan must not be archived as the earlier value.
scenario=concurrent-status-edit
printf -- '---\ntitle: Saved finding\nstatus : original\n---\nEvidence: keep this\n' > "$FIXTURE/input.md"
awk() {
  command awk "$@" || return $?
  if [[ "${RL_STATUS_SCAN:-0}" == 1 ]]; then
    sed -i 's/status : original/status : edited/' "$FIXTURE/input.md"
    cp "$FIXTURE/input.md" "$FIXTURE/expected.md"
  fi
}
rc=0
_local_dedupe_mark_file "$FIXTURE/input.md" $'status: duplicate\nduplicate_of: canonical.md' '' || rc=$?
unset -f awk
check test "$rc" -ne 0
check cmp -s "$FIXTURE/expected.md" "$FIXTURE/input.md"
check test ! -e "$FIXTURE/input.md.rldedupe.$$"
printf 'Local dedupe status retention: %s checks, %s failures.\n' "$checks" "$failed"
(( failed == 0 ))
