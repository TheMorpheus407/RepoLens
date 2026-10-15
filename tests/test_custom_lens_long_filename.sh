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
