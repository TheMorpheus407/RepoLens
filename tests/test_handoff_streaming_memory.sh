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

# Regression for PR #461 D3: repeated restoration must not buffer an entire
# accepted response. The fixture limit reproduces the verified allocation bug;
# it does not add any production response limit. No model/forge calls.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
FIXTURE="$(mktemp -d)" || exit 1
trap 'rm -rf -- "$FIXTURE"' EXIT
source "$ROOT/lib/rounds.sh" || exit 1
passed=0 failed=0
for kind in saturated dispatch; do
  saved="$FIXTURE/$kind"
  mkdir "$saved" || exit 1
  # Keep the Bash parsing case small enough to complete in seconds while its
  # tighter fixture limit still rejects response-sized allocations.
  memory_kib=131072
  [[ "$kind" == saturated ]] || memory_kib=32768
  # Ignored lines plus a small result: 64 MiB saturated, 8 MiB dispatch.
  # Without the marker, restoration must also stream through both Bash parsers.
  python3 - "$saved/meta-orchestrator-output.txt" "$kind" <<'DATA' || exit 1
import sys
with open(sys.argv[1], 'wb') as output:
    if sys.argv[2] == 'dispatch':
        output.write(b'HYPOTHESES_TO_VERIFY:\nKeep this accepted hypothesis\n')
        output.write(b'GENERIC: role=investigator\n')
    line = b'x' * (256 * 1024 - 1) + b'\n'
    for _ in range(256 if sys.argv[2] == 'saturated' else 32):
        output.write(line)
    if sys.argv[2] == 'saturated':
        output.write(b'NO_FRESH_ANGLES\n')
DATA
  if [[ "$kind" == saturated ]]; then
    printf '# Meta-Orchestrator Dispatch\n\nNO_FRESH_ANGLES\n' > "$saved/expected-dispatch" || exit 1
    : > "$saved/expected-hypotheses" || exit 1
  else
    printf '# Meta-Orchestrator Dispatch\n\nGENERIC: role=investigator\n' > "$saved/expected-dispatch" || exit 1
    printf 'Keep this accepted hypothesis\n' > "$saved/expected-hypotheses" || exit 1
  fi
  _rounds_meta_certify_success "$saved" || exit 1
  # Keep the bound within a child so a regression cannot kill the suite runner.
  for attempt in 1 2; do
    if (
      ulimit -v "$memory_kib" || exit 1
      _rounds_meta_restore_success "$saved" || exit 1
      if [[ "$kind" == saturated ]]; then
        [[ "$META_ORCH_SATURATED" == 1 ]] || exit 1
      else
        [[ "$META_ORCH_SATURATED" == 0 ]] || exit 1
      fi
      cmp -s "$saved/expected-dispatch" "$saved/dispatch.md" || exit 1
      cmp -s "$saved/expected-hypotheses" "$saved/hypotheses.md" || exit 1
    ); then passed=$((passed + 1));
    else failed=$((failed + 1)); printf 'FAIL: bounded-memory %s restore %s\n' "$kind" "$attempt" >&2; fi
  done
done
printf 'Results: %s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
