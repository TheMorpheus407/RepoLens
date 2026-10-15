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

# Atomic staging must accept every canonical basename that fits NAME_MAX.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
# shellcheck source=/dev/null
source "$REPO/lib/rounds.sh"
# shellcheck disable=SC2034 # The sourced writer reads the round index.
CURRENT_ROUND_INDEX=2
category="$(printf '%0240d' 0 | tr '0' a)"
payload="$(printf 'CUSTOM: %s\nDraft prompt:\nInspect retries.\n' "$category")"
entry="$(_rounds_meta_write_custom_lens "$FIXTURE" "$payload" 1)"
test "$entry" = "custom/r2-$category"
test -f "$FIXTURE/$entry.md"
test "$(_rounds_meta_write_custom_lens "$FIXTURE" "$payload" 1)" = "$entry"
test "$(find "$FIXTURE" -type f | wc -l)" -eq 1
printf 'PASS: long valid canonical names support atomic creation and reuse.\n'

# A canonical name can fit exactly while its collision suffix exceeds NAME_MAX.
# Exercise the production parser too, then reorder the saved investigations.
for length in 249 250 400; do
  category="$(printf '%0*d' "$length" 0 | tr '0' a)"
  destination="$FIXTURE/length-$length"
  mkdir -p "$destination"
  for variant in first second; do
    printf 'CUSTOM: %s\nDraft prompt:\nInspect %s path.\n' "$category" "$variant"
  done > "$destination/output.md"
  _rounds_meta_parse_output "$destination/output.md" "$destination/dispatch.md" "$destination/hypotheses.md"
  entries="$(_rounds_meta_dispatch_custom_entries "$destination/dispatch.md" "$destination/lenses")"
  mapfile -t ids <<< "$entries"
  test "${#ids[@]}" -eq 2
  test "${ids[0]}" != "${ids[1]}"
  if [[ "$length" == 249 ]]; then
    test "${ids[0]}" = "custom/r2-$category"
  fi
  for index in 0 1; do
    file="$destination/lenses/${ids[$index]}.md"
    test -f "$file"
    basename="${file##*/}"
    test "${#basename}" -le 255
  done
  grep -qF 'Inspect first path.' "$destination/lenses/${ids[0]}.md"
  grep -qF 'Inspect second path.' "$destination/lenses/${ids[1]}.md"
  for variant in second first; do
    printf 'CUSTOM: %s\nDraft prompt:\nInspect %s path.\n' "$category" "$variant"
  done > "$destination/output.md"
  _rounds_meta_parse_output "$destination/output.md" "$destination/dispatch.md" "$destination/hypotheses.md"
  reordered="$(_rounds_meta_dispatch_custom_entries "$destination/dispatch.md" "$destination/lenses")"
  test "$reordered" = "$(printf '%s\n%s' "${ids[1]}" "${ids[0]}")"
  test "$(find "$destination/lenses" -type f | wc -l)" -eq 2
done
printf 'PASS: near-limit collisions and overlong categories keep distinct stable IDs.\n'

# Different long categories with the same retained prefix must remain distinct,
# and a two-digit collision counter must still fit and resume without new files.
category="$(printf '%0400d' 0 | tr '0' a)"
first="$(_rounds_meta_write_custom_lens "$FIXTURE/hash-tail" "$(printf 'CUSTOM: %sb\nDraft prompt:\nInspect retries.\n' "$category")" 1)"
second="$(_rounds_meta_write_custom_lens "$FIXTURE/hash-tail" "$(printf 'CUSTOM: %sc\nDraft prompt:\nInspect retries.\n' "$category")" 2)"
test "$first" != "$second"
test -f "$FIXTURE/hash-tail/$first.md"
test -f "$FIXTURE/hash-tail/$second.md"
saved=()
for variant in {1..12}; do
  payload="$(printf 'CUSTOM: %s\nDraft prompt:\nInspect path %s.\n' "$category" "$variant")"
  saved+=("$(_rounds_meta_write_custom_lens "$FIXTURE/many" "$payload" "$variant")")
done
for variant in {12..1}; do
  payload="$(printf 'CUSTOM: %s\nDraft prompt:\nInspect path %s.\n' "$category" "$variant")"
  test "$(_rounds_meta_write_custom_lens "$FIXTURE/many" "$payload" "$variant")" = "${saved[$((variant - 1))]}"
done
test "$(find "$FIXTURE/many" -type f | wc -l)" -eq 12
printf 'PASS: truncated category tails and two-digit collisions remain stable.\n'
