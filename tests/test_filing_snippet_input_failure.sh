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
saved_limit="$(ulimit -S -f)"
armed=0
# Arm RLIMIT_FSIZE after extraction at the selected loop input, then restore it
# before the verifier returns so assertions and repaired retries run normally.
debug_boundary() {
  case "$BASH_COMMAND" in
    '[[ -n "$snippets" ]]')
      if [[ "$boundary" == snippets ]]; then ulimit -S -f 0; armed=1; fi ;;
    'local snippet_pattern context_start context_end')
      if [[ "$boundary" == citations ]]; then ulimit -S -f 0; armed=1; fi ;;
    'return 0'|'return 1'|'return 2') if (( armed )); then ulimit -S -f "$saved_limit"; armed=0; fi ;;
  esac
}
trap '' XFSZ
for boundary in snippets citations; do
  # Force each here-string beyond Bash's pipe buffer without source evidence.
  entry="$(python3 -B - "$boundary" <<'PY'
import json
import sys
body = ('src/a.sh:1 `' + 'invalid_evidence_' * 6000 + '`'
        if sys.argv[1] == 'snippets' else
        ' '.join('src/missing%05d.sh:1' % i for i in range(6000)))
print(json.dumps(dict(body=body)))
PY
)"
  baseline_rc=0
  filing_verify_cluster_citations "$FIXTURE" "$entry" >/dev/null || baseline_rc=$?
  test "$baseline_rc" -eq 1
  set -T
  trap debug_boundary DEBUG
  fault_rc=0
  fault_reason="$(filing_verify_cluster_citations "$FIXTURE" "$entry")" || fault_rc=$?
  trap - DEBUG
  set +T
  ulimit -S -f "$saved_limit"
  printf 'boundary=%s normal_status=%s tempfile_failure_status=%s\n' "$boundary" "$baseline_rc" "$fault_rc"
  test "$fault_rc" -eq 2
  if [[ "$boundary" == snippets ]]; then
    test "$fault_reason" = 'src/a.sh:1 could not read citation snippets'
  else
    test "$fault_reason" = 'could not read citations'
  fi
  retry_rc=0
  filing_verify_cluster_citations "$FIXTURE" "$entry" >/dev/null || retry_rc=$?
  test "$retry_rc" -eq 1
done
valid_rc=0
filing_verify_cluster_citations "$FIXTURE" '{"body":"src/a.sh:1 `actual source`"}' || valid_rc=$?
test "$valid_rc" -eq 0
printf 'Results: invalid evidence rejected, both input failures retryable, repaired retries and valid evidence checked\n'
