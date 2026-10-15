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

# A successful grep -q can SIGPIPE a large upstream echo under pipefail.
# Exercise the unchanged assertions with a larger, semantically identical input.
# shellcheck disable=SC2329 # cat is exported to the child test shell.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cat() {
  command cat "$@"
  if [[ "${1:-}" == */CHANGELOG.md ]]; then
    printf '%262144s\n' ''
  fi
}
export -f cat
bash "$SCRIPT_DIR/tests/test_changelog.sh"
