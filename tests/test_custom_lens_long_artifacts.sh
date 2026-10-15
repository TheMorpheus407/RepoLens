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

# Long canonical IDs must remain usable by heartbeat and parallel bookkeeping.
# shellcheck disable=SC2034 # Production functions consume these globals.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
# shellcheck source=/dev/null
source "$REPO/lib/parallel.sh"
# Extract only these production definitions; do not execute the CLI or agents.
eval "$(awk '/^(sanitize_heartbeat_component|lens_heartbeat_key|lens_heartbeat_path|lens_heartbeat_iteration_path|write_lens_heartbeat_iteration|write_lens_heartbeat)\(\)/,/^}/' "$REPO/repolens.sh")"
_REPOLENS_SEM_DIR="$FIXTURE/semaphore"
HEARTBEAT_DIR="$FIXTURE/heartbeat"
mkdir -p "$_REPOLENS_SEM_DIR" "$HEARTBEAT_DIR"
passed=0 failed=0
check() {
  if "$@"; then passed=$((passed + 1));
  else failed=$((failed + 1)); printf 'FAIL: %s\n' "$*"; fi
}
# Transformed names use a collision-resistant namespace; heartbeats keep theirs.
check test "$(_sem_token_path custom/r2-retry)" = "$_REPOLENS_SEM_DIR/escaped+$(sha256_text custom/r2-retry).token"
check test "$(lens_heartbeat_path custom r2-retry)" = "$HEARTBEAT_DIR/custom__r2-retry.json"
for tail in a b; do
  lens_id="r2-$(printf '%0248d' 0 | tr '0' a)$tail"
  check sem_token_create "custom/$lens_id" 123
  token="$(_sem_token_path "custom/$lens_id")"
  check test -f "$token"
  check grep -q '^pid=123$' "$token"
  heartbeat="$(lens_heartbeat_path custom "$lens_id")"
  iteration="$(lens_heartbeat_iteration_path custom "$lens_id")"
  check write_lens_heartbeat_iteration "$iteration" 1
  check write_lens_heartbeat "$heartbeat" probe custom "$lens_id" 123 1 2026-10-15T00:00:00Z
  check jq -e --arg id "$lens_id" '.lens_id == $id and .iteration == 1' "$heartbeat"
done
check test "$(find "$_REPOLENS_SEM_DIR" -type f | wc -l)" -eq 2
check test "$(find "$HEARTBEAT_DIR" -type f | wc -l)" -eq 4
check sem_token_remove "custom/$lens_id"
check test ! -e "$token"
# A short caller-supplied ID must not alias the reserved long-ID namespace.
long_id="$(printf '%0201d' 0 | tr '0' x)"
short_id="long-$(sha256_text "$long_id")"
long_token="$(_sem_token_path "$long_id")"
short_token="$(_sem_token_path "$short_id")"
check test "$long_token" != "$short_token"
check sem_token_create "$long_id" 111
check sem_token_create "$short_id" 222
check grep -q '^pid=111$' "$long_token"
check grep -q '^pid=222$' "$short_token"
check sem_token_remove "$short_id"
check test -f "$long_token"
check sem_token_remove "$long_id"
# Sanitization cannot turn a literal reserved delimiter into a hashed key.
check test "$(_sem_token_path "long+$(sha256_text "$long_id")")" != "$long_token"
# Production dispatch tuples contain free-text attributes. Under a UTF-8
# locale the sanitizer preserves Japanese letters, but NAME_MAX counts bytes.
# shellcheck source=/dev/null
source "$REPO/lib/rounds.sh"
export LC_ALL=C.UTF-8
focus="$(printf '%090d' 0 | tr '0' x)"
focus="${focus//x/試}"
check test "${#focus}" -eq 90
printf 'CUSTOM: retry role=broader focus="%s"\nDraft prompt:\nInspect retries.\n' "$focus" > "$FIXTURE/unicode.md"
_rounds_meta_parse_output "$FIXTURE/unicode.md" "$FIXTURE/unicode-dispatch.md" "$FIXTURE/unicode-hypotheses.md" "$REPO/prompts/lenses"
CURRENT_ROUND_INDEX=2
tuple="$(_rounds_meta_dispatch_custom_entries "$FIXTURE/unicode-dispatch.md" "$FIXTURE/unicode-lenses")"
check test "${#tuple}" -lt 200
unicode_token="$(_sem_token_path "$tuple")"
check sem_token_create "$tuple" 333
check test -f "$unicode_token"
check grep -q '^pid=333$' "$unicode_token"
check test "$(_sem_token_path "$tuple")" = "$unicode_token"
# A different focus must retain independent bookkeeping and removal.
other_tuple="$(_rounds_meta_tuple_serialize custom/r2-retry broader "${focus}別" "" "")"
other_token="$(_sem_token_path "$other_tuple")"
check test "$other_token" != "$unicode_token"
check sem_token_create "$other_tuple" 444
check grep -q '^pid=444$' "$other_token"
check sem_token_remove "$other_tuple"
check test -f "$unicode_token"
check sem_token_remove "$tuple"
check test ! -e "$unicode_token"
# Short multibyte dispatch IDs are also hashed; the helper's byte counting
# locale must not leak into its caller.
check test "$(_sem_token_path custom/試)" = "$_REPOLENS_SEM_DIR/escaped+$(sha256_text custom/試).token"
check test "$LC_ALL" = C.UTF-8
LC_ALL=C sem_token_create "$tuple" 555
check sem_token_remove "$tuple"
printf '%s checks passed; %s failed.\n' "$passed" "$failed"
test "$failed" -eq 0
