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

# Regression: repolens-r4-p2-1. Distinct dispatches own distinct reservations.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/lib/parallel.sh"
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
_REPOLENS_SEM_DIR="$FIXTURE"
first='security/injection|deeper|src/a||'
second='security/injection|deeper|src:a||'
sem_token_create "$first" 111
sem_token_create "$second" 222
test "$(find "$FIXTURE" -name '*.token' | wc -l)" -eq 2
test "$(_sem_token_path "$first")" != "$(_sem_token_path "$second")"
sem_token_remove "$first"
test -f "$(_sem_token_path "$second")"
grep -q '^pid=222$' "$(_sem_token_path "$second")"
# A literal sanitized name must not alias a transformed or digest name.
for other in 'security_injection_deeper_src_a__' "escaped+$(sha256_text "$first")"; do
  test "$(_sem_token_path "$other")" != "$(_sem_token_path "$first")"
done
sem_token_remove "$second"
test "$(find "$FIXTURE" -name '*.token' | wc -l)" -eq 0
printf 'Semaphore dispatch reservations remain independent.\n'
