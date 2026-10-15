#!/usr/bin/env bash
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
