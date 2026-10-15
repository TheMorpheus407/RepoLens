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

# Record containment CI's actual invocations without running the full gate.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
(
  unset REPOLENS_TEST_PROCESS_SCOPES_REQUIRED
  bash() {
    if [[ "$1" == --version ]]; then printf 'mock Bash\n'; return 0; fi
    printf '%s %s\n' "${REPOLENS_TEST_PROCESS_SCOPES_REQUIRED:-0}" "$1" >> "$FIXTURE/calls"
  }
  source "$REPO/ci/check-process-scopes.sh"
)
for suite in test_parallel_setup_cancellation test_filing_parent_cancellation; do
  if ! grep -Fx "1 tests/$suite.sh" "$FIXTURE/calls" >/dev/null; then
    printf 'FAIL: containment CI must require %s\n' "$suite"
    exit 1
  fi
  printf 'PASS: containment CI requires %s\n' "$suite"
done
