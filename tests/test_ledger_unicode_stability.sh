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

# Frozen Unicode identity rules must not change with the Python Unicode DB.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/lib/ledger.sh"
FAIL=0
check_ids() {
  local title expected actual composed decomposed
  while IFS='|' read -r title expected; do
    actual="$(finding_id security injection "$title")" || {
      printf 'FAIL: could not generate Unicode identity for %s\n' "$title"
      return 1
    }
    if [[ "$actual" == "$expected" ]]; then
      printf 'PASS: frozen Unicode identity for %s\n' "$title"
    else
      printf 'FAIL: frozen Unicode identity for %s: expected %s, got %s\n' "$title" "$expected" "$actual"
      FAIL=$((FAIL + 1))
    fi
  done <<'CASES'
缓存泄漏|fnd-f86e364d2858
登录失败|fnd-2e59e42316f2
कल|fnd-a69a7ed0339a
कला|fnd-11d1072c680c
café|fnd-3c22695f95e6
É|fnd-0d9f21e76df5
é|fnd-c4a68b79354b
缓存。|fnd-409e5e3b1fe2
缓存|fnd-a35dea66cee8
𞓐|fnd-0d1ad8ae2b4c
𞓑|fnd-ab856c70e1a8
Ᲊ|fnd-fca92e38f618
ᲊ|fnd-9d48fb55abe3
CASES
  composed="$(finding_id security injection É)" || return 1
  decomposed="$(finding_id security injection $'E\xcc\x81')" || return 1
  if [[ "$composed" != "$decomposed" ]]; then
    printf 'FAIL: canonically equivalent Unicode identities differ\n'
    FAIL=$((FAIL + 1))
  fi
}
check_ids || { printf 'FAIL: Unicode identity check could not complete\n'; FAIL=$((FAIL + 1)); }
# Loading the synthesizer cannot change the registry identity rules.
# shellcheck source=/dev/null
source "$ROOT/lib/synthesize.sh"
check_ids || { printf 'FAIL: Unicode identity check could not complete with synthesizer\n'; FAIL=$((FAIL + 1)); }
printf 'Results: %s failed\n' "$FAIL"
(( FAIL == 0 ))
