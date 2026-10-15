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

# Sequential custom materialization and heartbeat keys must not require Python.
# shellcheck disable=SC2034,SC2329 # Sourced functions and mocked PATH consume globals.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
# shellcheck source=/dev/null
source "$REPO/lib/rounds.sh"
# shellcheck source=/dev/null
source "$REPO/lib/parallel.sh"
eval "$(awk '/^(sanitize_heartbeat_component|lens_heartbeat_key|lens_heartbeat_path|lens_heartbeat_iteration_path)\(\)/,/^}/' "$REPO/repolens.sh")"
CURRENT_ROUND_INDEX=2
HEARTBEAT_DIR="$FIXTURE/heartbeat"
_REPOLENS_SEM_DIR="$FIXTURE/semaphore"
mkdir -p "$HEARTBEAT_DIR" "$_REPOLENS_SEM_DIR"
# Reject even a direct Python invocation; other commands retain their real PATH.
python3() { printf 'Unexpected Python call\n' >> "$FIXTURE/python-calls"; return 127; }
category="$(printf '%0400d' 0 | tr '0' a)"
payload="$(printf 'CUSTOM: %s\nDraft prompt:\nInspect retries.\n' "$category")"
expected_slug="r2-$category"
digest="$(printf '%s' "$expected_slug" | sha256sum)"
expected_slug="${expected_slug:0:219}-${digest:0:32}"
entry="$(_rounds_meta_write_custom_lens "$FIXTURE/lenses" "$payload" 1)" || {
  printf 'FAIL: long custom materialization requires Python.\n' >&2
  exit 1
}
test "$entry" = "custom/$expected_slug"
test -f "$FIXTURE/lenses/$entry.md"
test "$(_rounds_meta_write_custom_lens "$FIXTURE/lenses" "$payload" 1)" = "$entry"
heartbeat="$(lens_heartbeat_path custom "${entry#*/}")"
iteration="$(lens_heartbeat_iteration_path custom "${entry#*/}")"
digest="$(printf '%s' "custom__${entry#*/}" | sha256sum)"
test "$heartbeat" = "$HEARTBEAT_DIR/long-${digest:0:64}.json"
test "$iteration" = "$HEARTBEAT_DIR/.long-${digest:0:64}.iteration"
sem_token_create "$entry" 123
test -f "$(_sem_token_path "$entry")"
test ! -e "$FIXTURE/python-calls"
printf 'PASS: long materialization, stable IDs and bookkeeping without Python.\n'

# Exercise the SHA fallback cascade using the same real materialization path.
# Fallback shims validate arguments and formats without requiring those tools.
backend=sha256sum
command() {
  if [[ "${1:-}" == -v && "${2:-}" =~ ^(sha256sum|shasum|openssl)$ ]]; then
    [[ "$2" == "$backend" ]]
  else
    builtin command "$@"
  fi
}
shasum() {
  test "$*" = '-a 256' || return 1
  sha256sum
}
openssl() {
  test "$*" = 'dgst -sha256 -r' || return 1
  local output
  output="$(sha256sum)" || return 1
  printf '%s *stdin\n' "${output:0:64}"
}
for backend in shasum openssl; do
  test "$(_rounds_meta_write_custom_lens "$FIXTURE/lenses" "$payload" 1)" = "$entry"
  test "$(lens_heartbeat_path custom "${entry#*/}")" = "$heartbeat"
  test -f "$(_sem_token_path "$entry")"
done
# Missing, failing and malformed tools must not produce an ID for different work.
backend=none
rc=0
_rounds_meta_write_custom_lens "$FIXTURE/unavailable" "$payload" 1 > "$FIXTURE/output" 2>/dev/null || rc=$?
test "$rc" -ne 0
test ! -s "$FIXTURE/output"
backend=sha256sum
sha256sum() { return 71; }
rc=0
lens_heartbeat_path custom "${entry#*/}" > "$FIXTURE/output" 2>/dev/null || rc=$?
test "$rc" -ne 0
test ! -s "$FIXTURE/output"
sha256sum() { printf 'bad digest\n'; }
rc=0
_sem_token_path "$entry" > "$FIXTURE/output" 2>/dev/null || rc=$?
test "$rc" -ne 0
test ! -s "$FIXTURE/output"
printf 'PASS: hash fallbacks retain IDs and propagate tool failures.\n'
