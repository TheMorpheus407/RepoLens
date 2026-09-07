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
set -uo pipefail
export REPOLENS_TEST_PROCESS_SCOPES_REQUIRED=1
bash --version | head -1
for suite in test_process_scopes test_process_scope_rpc test_parallel_wait_timeout test_parallel_sem_trap test_parallel_stale_token_gc test_parallel_heartbeat test_parallel_cleanup_bounded; do
  bash "tests/$suite.sh" || exit 1
done
# The full CLI currently uses existing Bash 4.2+ constructs outside this backend.
# Bash 4.0 still executes the real run_agent topology and 124/137 parity above.
if (( BASH_VERSINFO[0] > 4 || BASH_VERSINFO[1] >= 2 )); then
  bash tests/test_agent_timeout_kill_grace.sh || exit 1
  bash tests/test_parallel_remote_clone_cleanup.sh || exit 1
fi
