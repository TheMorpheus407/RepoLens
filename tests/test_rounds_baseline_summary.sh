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

# Exercise the actual BSD regression suite's output contract for both runners.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
rc=0
output="$(bash "$REPO/tests/test_rounds_baseline_bsd_date.sh" 2>&1)" || rc=$?
# Both runners select the last Results: line from each suite's merged output.
result_line="$(printf '%s\n' "$output" | grep 'Results:' | tail -1)"
if (( rc == 0 )) && [[ "$result_line" =~ ^Results:\ [0-9]+/[0-9]+\ passed,\ 0\ failed$ ]]; then
  echo 'PASS: BSD baseline suite preserves its numeric result summary'
  echo 'Results: 1/1 passed, 0 failed'
else
  printf '%s\n' "$output"
  echo 'FAIL: BSD baseline suite must succeed with a numeric final result summary'
  echo 'Results: 0/1 passed, 1 failed'
  exit 1
fi
