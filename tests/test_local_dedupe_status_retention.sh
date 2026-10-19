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
values=(
  '"&workflow needs-validation"'
  "'&workflow needs-validation'"
  'needs-validation # &workflow'
  'needs-validation &workflow'
  duplicate_candidate
  duplicate_of
  '"duplicate pending"'
  "'needs-validation' # keep \\ and \"quotes\""
  $'duplicate_pending # \u007f\u0085\u009f\u2028\u2029\ufffe\uffff'
  '"needs \"validation\"" # workflow'
  "'needs ''validation''' # workflow"
  '!!str "needs-validation"'
  '"|"'
  "'>'"
  '[needs, "validation"]'
  '{needs: "validation"}'
  '[[needs], {validation: pending}] # workflow'
)
for indent in '' '  '; do
  for padding in '' ' ' $'\t'; do
    for value in "${values[@]}"; do
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
  for invalid in invalid-backup conflicting-status duplicate-backup multiple-statuses block-status multi-string-backup leading-nonstring-backup trailing-nonstring-backup cr-backup crlf-backup trailing-cr-backup open-double-backup open-single-backup block-header-backup open-flow-backup; do
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
      cr-backup) printf '%s\n' 'repolens_dedupe_original_status: "status: needs-validation\rstatus: duplicate"' ;;
      crlf-backup) printf '%s\n' 'repolens_dedupe_original_status: "status: needs-validation\r\nstatus: duplicate"' ;;
      trailing-cr-backup) printf '%s\n' 'repolens_dedupe_original_status: "status: needs-validation\r"' ;;
      open-double-backup) printf '%s\n' 'repolens_dedupe_original_status: "status: \"needs"' ;;
      open-single-backup) printf '%s\n' "repolens_dedupe_original_status: \"status: 'needs\"" ;;
      block-header-backup) printf '%s\n' 'repolens_dedupe_original_status: "status: |"' ;;
      open-flow-backup) printf '%s\n' 'repolens_dedupe_original_status: "status: [needs,"' ;;
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

# Moving an anchor into a quoted backup removes definitions used by aliases;
# restoring it at the end would put the definition after those aliases.
for indent in '' '  '; do
  for value in '&workflow needs-validation' '! &workflow needs-validation' $'!\t&workflow needs-validation' '!!str &workflow needs-validation' '!<tag:yaml.org,2002:str> &workflow needs-validation'; do
    original="${indent}status : $value"
    for role in duplicate canonical; do
      scenario="anchored status / indent=${#indent} / $value / $role"
      printf -- '---\n%stitle: Anchored finding\n%s\n%sdetails:\n%s  status: *workflow\n---\nEvidence: keep this\n' \
        "$indent" "$original" "$indent" "$indent" > "$FIXTURE/input.md"
      cp "$FIXTURE/input.md" "$FIXTURE/expected.md"
      rc=0
      if [[ "$role" == duplicate ]]; then
        _local_dedupe_mark_file "$FIXTURE/input.md" $'status: duplicate\nduplicate_of: canonical.md' '' || rc=$?
        check test "$rc" -ne 0
      else
        # Canonical custom statuses stay in place, so their anchors are safe.
        _local_dedupe_mark_file "$FIXTURE/input.md" '' '' || rc=$?
        check test "$rc" -eq 0
      fi
      check cmp -s "$FIXTURE/expected.md" "$FIXTURE/input.md"
      check test ! -e "$FIXTURE/input.md.rldedupe.$$"

      # Refuse pre-existing anchored backups in either role as well.
      scenario="anchored backup / indent=${#indent} / $value / $role"
      backup="$(jq -nc --arg line "$original" '$line')"
      printf -- '---\n%stitle: Anchored finding\n%sstatus: duplicate\n%srepolens_dedupe_original_status: %s\n%sdetails:\n%s  status: *workflow\n---\nEvidence: keep this\n' \
        "$indent" "$indent" "$indent" "$backup" "$indent" "$indent" > "$FIXTURE/input.md"
      cp "$FIXTURE/input.md" "$FIXTURE/expected.md"
      additions=''
      [[ "$role" != duplicate ]] || additions=$'status: duplicate\nduplicate_of: canonical.md'
      rc=0
      _local_dedupe_mark_file "$FIXTURE/input.md" "$additions" '' || rc=$?
      check test "$rc" -ne 0
      check cmp -s "$FIXTURE/expected.md" "$FIXTURE/input.md"
      check test ! -e "$FIXTURE/input.md.rldedupe.$$"
    done
  done
done

# A CRLF status among LF-delimited frontmatter must not create a backup that
# the next duplicate pass or canonical promotion would reject as invalid.
for indent in '' '  '; do
  for padding in '' ' ' $'\t'; do
    for role in duplicate canonical; do
      printf -- '---\n%stitle: Saved finding\n%sstatus%s: needs-validation\r\n---\nEvidence: keep this\n' \
        "$indent" "$indent" "$padding" > "$FIXTURE/input.md"
      cp "$FIXTURE/input.md" "$FIXTURE/expected.md"
      additions=''
      [[ "$role" != duplicate ]] || additions=$'status: duplicate\nduplicate_of: canonical.md'
      for attempt in first rerun; do
        scenario="CR-bearing original / indent=${#indent} / padding=${#padding} / $role / $attempt"
        rc=0
        _local_dedupe_mark_file "$FIXTURE/input.md" "$additions" '' || rc=$?
        if [[ "$role" == duplicate ]]; then
          check test "$rc" -ne 0
        else
          check test "$rc" -eq 0
        fi
        check cmp -s "$FIXTURE/expected.md" "$FIXTURE/input.md"
        check test ! -e "$FIXTURE/input.md.rldedupe.$$"
      done
      # Refused duplicate assignment leaves the original usable on promotion.
      check _local_dedupe_mark_file "$FIXTURE/input.md" '' ''
      check cmp -s "$FIXTURE/expected.md" "$FIXTURE/input.md"
    done
  done
done

# Quoted scalars can continue at the root indentation, and indented comments
# are scalar content in literal/folded blocks. Never archive just their header.
for indent in '' '  '; do
  for form in double-quoted single-quoted tagged-quoted escaped-quote literal-comment folded-comment chomp-comment empty-block flow-sequence flow-mapping plain-managed-prefix; do
    case "$form" in
      double-quoted) status=$'"needs\nvalidation"' ;;
      single-quoted) status=$'\'needs\nvalidation\'' ;;
      tagged-quoted) status=$'!!str "needs\nvalidation: pending"' ;;
      escaped-quote) status=$'"needs \\"\nvalidation"' ;;
      literal-comment) status=$'|\n  # needs-validation' ;;
      folded-comment) status=$'>\n  # needs-validation' ;;
      chomp-comment) status=$'|- # workflow\n  # needs-validation' ;;
      empty-block) status='|' ;;
      flow-sequence) status=$'[needs,\nvalidation]' ;;
      flow-mapping) status=$'{needs:\nvalidation}' ;;
      plain-managed-prefix) status=$'duplicate\n  pending' ;;
    esac
    for role in duplicate canonical; do
      scenario="multiline status / indent=${#indent} / $form / $role"
      printf -- '---\n%stitle: Multiline status\n' "$indent" > "$FIXTURE/input.md"
      printf 'status : %s\n' "$status" | sed "s/^/$indent/" >> "$FIXTURE/input.md"
      printf -- '%sseverity: high\n---\nEvidence: keep this\n' "$indent" >> "$FIXTURE/input.md"
      cp "$FIXTURE/input.md" "$FIXTURE/expected.md"
      additions=''
      [[ "$role" != duplicate ]] || additions=$'status: duplicate\nduplicate_of: canonical.md'
      for attempt in first rerun; do
        rc=0
        _local_dedupe_mark_file "$FIXTURE/input.md" "$additions" '' || rc=$?
        check test "$rc" -ne 0
        check cmp -s "$FIXTURE/expected.md" "$FIXTURE/input.md"
        check test ! -e "$FIXTURE/input.md.rldedupe.$$"
      done
    done
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
