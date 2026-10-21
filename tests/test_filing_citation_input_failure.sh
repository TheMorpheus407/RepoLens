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

# repolens-r18-p10-1: failed outer citation input must remain retryable.
# shellcheck disable=SC2329
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/core.sh
source "$ROOT/lib/core.sh"
# shellcheck source=lib/filing.sh
source "$ROOT/lib/filing.sh"
FIXTURE="$(mktemp -d /tmp/repolens-citation-input.XXXXXX)"
trap 'rm -rf -- "$FIXTURE"' EXIT
mkdir "$FIXTURE/src"
printf 'actual source\n' > "$FIXTURE/src/a.sh"
entry="$(python3 -B - <<'PYCODE'
import json
print(json.dumps(dict(body=' '.join('src/missing%05d.sh:1' % i for i in range(6000)))))
PYCODE
)"
normal_rc=0
filing_verify_cluster_citations "$FIXTURE" "$entry" >/dev/null || normal_rc=$?
test "$normal_rc" -eq 1
saved_limit="$(ulimit -S -f)"
armed=0
# Arm EFBIG after extraction, immediately before the outer citation here-string.
# Restore the file-size limit at verifier return so later controls can use IO.
debug_boundary() {
  case "$BASH_COMMAND" in
    'local snippet_pattern context_start context_end') ulimit -S -f 0; armed=1 ;;
    'return 0'|'return 1'|'return 2') if (( armed )); then ulimit -S -f "$saved_limit"; armed=0; fi ;;
  esac
}
trap '' XFSZ
set -T
trap debug_boundary DEBUG
fault_rc=0
fault_reason="$(filing_verify_cluster_citations "$FIXTURE" "$entry")" || fault_rc=$?
trap - DEBUG
set +T
ulimit -S -f "$saved_limit"
printf 'normal_status=%s tempfile_failure_status=%s\n' "$normal_rc" "$fault_rc"
test "$fault_rc" -eq 2
test "$fault_reason" = 'could not read citations'
retry_rc=0
filing_verify_cluster_citations "$FIXTURE" "$entry" >/dev/null || retry_rc=$?
test "$retry_rc" -eq 1
filing_verify_cluster_citations "$FIXTURE" '{"body":"src/a.sh:1 `actual source`"}'
printf 'Results: failed citation input is retryable, repaired invalid and valid controls checked\n'
