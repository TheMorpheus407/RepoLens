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

# Source after lib/parallel.sh. Required cgroup CI must fail, never skip.
set -uo pipefail
require_process_scopes() {
  if ! python3 "$_REPOLENS_SCOPE_HELPER" probe 2>/dev/null; then
    if [[ "${REPOLENS_TEST_PROCESS_SCOPES_REQUIRED:-0}" == 1 ]]; then
      echo "FAIL: this job requires real delegated cgroup v2 process scopes" >&2
      exit 1
    fi
    echo "SKIP: delegated cgroup v2/Python pidfds unavailable; required process-scope CI exercises containment"
    exit 0
  fi
}
