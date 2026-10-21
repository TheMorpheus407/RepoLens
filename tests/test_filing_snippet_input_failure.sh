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

# Regression for repolens-r18-p4-1: live snippet input must fail closed.
# shellcheck disable=SC2329
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/core.sh
source "$ROOT/lib/core.sh"

# shellcheck source=lib/filing.sh
source "$ROOT/lib/filing.sh"
FIXTURE="$(mktemp -d /tmp/repolens-snippet-input.XXXXXX)"
trap 'rm -rf -- "$FIXTURE"' EXIT
mkdir "$FIXTURE/src"
printf 'actual source\n' > "$FIXTURE/src/a.sh"
# One optional snippet far larger than Bash's pipe buffer, absent from source.
entry="$(python3 -B - <<'PY'
import json
print(json.dumps(dict(body='src/a.sh:1 `' + 'invalid_evidence_' * 6000 + '`')))
PY
)"
baseline_rc=0
filing_verify_cluster_citations "$FIXTURE" "$entry" || baseline_rc=$?
test "$baseline_rc" -eq 1
saved_limit="$(ulimit -S -f)"
armed=0
debug_boundary() {
  case "$BASH_COMMAND" in
    '[[ -n "$snippets" ]]') ulimit -S -f 0; armed=1 ;;
    'return 0'|'return 1'|'return 2') if (( armed )); then ulimit -S -f "$saved_limit"; armed=0; fi ;;
  esac
}
trap '' XFSZ
set -T
trap debug_boundary DEBUG
fault_rc=0
filing_verify_cluster_citations "$FIXTURE" "$entry" || fault_rc=$?
trap - DEBUG
set +T
ulimit -S -f "$saved_limit"
printf 'normal_status=%s tempfile_failure_status=%s\n' "$baseline_rc" "$fault_rc"
test "$fault_rc" -eq 2
retry_rc=0
filing_verify_cluster_citations "$FIXTURE" "$entry" >/dev/null || retry_rc=$?
test "$retry_rc" -eq 1
valid_rc=0
filing_verify_cluster_citations "$FIXTURE" '{"body":"src/a.sh:1 `actual source`"}' || valid_rc=$?
test "$valid_rc" -eq 0
printf 'Results: invalid snippets rejected, input failure retryable, repaired retry and valid evidence checked\n'
