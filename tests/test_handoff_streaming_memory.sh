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
# 64 MiB spread across lines: none contributes a dispatch or hypothesis.
python3 - "$FIXTURE/meta-orchestrator-output.txt" <<'DATA' || exit 1
import sys
with open(sys.argv[1], 'wb') as output:
    line = b'x' * (256 * 1024 - 1) + b'\n'
    for _ in range(256):
        output.write(line)
    output.write(b'NO_FRESH_ANGLES\n')
DATA
source "$ROOT/lib/rounds.sh" || exit 1
_rounds_meta_certify_success "$FIXTURE" || exit 1
# Keep the bound within a child so a regression cannot kill the suite runner.
passed=0 failed=0
for attempt in 1 2; do
  if (
    ulimit -v 131072 || exit 1
    _rounds_meta_restore_success "$FIXTURE" || exit 1
    [[ "$META_ORCH_SATURATED" == 1 ]] || exit 1
    grep -qx 'NO_FRESH_ANGLES' "$FIXTURE/dispatch.md" || exit 1
  ); then passed=$((passed + 1));
  else failed=$((failed + 1)); printf 'FAIL: bounded-memory restore %s\n' "$attempt" >&2; fi
done
printf 'Results: %s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
