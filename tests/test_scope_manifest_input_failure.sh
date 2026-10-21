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

# repolens-r18-p4-3 / p10-2: a failed entry input cannot publish an empty batch.
# shellcheck disable=SC2034,SC2329
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/lib/branch-scope.sh"
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
MODE=branch-review BRANCH_SCOPE_FILE="$FIXTURE/scope.json"
printf '["src/probe.sh"]\n' > "$BRANCH_SCOPE_FILE"
printf '[{"saved":"previous rejection report"}]\n' > "$FIXTURE/report.json"
saved_limit="$(ulimit -S -f)"
# Normal aggregation recovers write availability after the input failure. This
# leaves jq and publication real and catches erroneous empty-success fallback.
jq() {
  if [[ "${1:-}" == -s && "${2:-}" == . ]]; then
    ulimit -S -f "$saved_limit"
  fi
  command jq "$@"
}
jq -n '[{title:"Finding",severity:"high",body:(("x" * 100000) + " src/probe.sh:1")}]' > "$FIXTURE/original.json"
for pipefail_mode in on off; do
  cp "$FIXTURE/original.json" "$FIXTURE/manifest.json"
  cp "$FIXTURE/report.json" "$FIXTURE/manifest.json.out-of-scope.json"
  fault_rc=0
  # Capture diagnostics through a pipe: the limit must not block the test log.
  diagnostics="$( {
    trap '' XFSZ
    [[ "$pipefail_mode" != off ]] || set +o pipefail
    ulimit -S -f 0
    branch_scope_filter_manifest "$FIXTURE/manifest.json"
  } 2>&1)" || fault_rc=$?
  printf 'pipefail=%s input_failure_status=%s\n%s\n' "$pipefail_mode" "$fault_rc" "$diagnostics"
  [[ "$diagnostics" == *'cannot create temp file for here-document'* ]]
  test "$fault_rc" -eq 2
  cmp "$FIXTURE/original.json" "$FIXTURE/manifest.json"
  cmp "$FIXTURE/report.json" "$FIXTURE/manifest.json.out-of-scope.json"
  test -z "$(find "$FIXTURE" -name 'manifest.json.scope.*' -print)"
  # The complete original candidate remains eligible for a repaired retry.
  branch_scope_filter_manifest "$FIXTURE/manifest.json"
  command jq -e 'length == 1 and .[0].title == "[REGRESSION][HIGH] Finding" and (.[0].body | endswith(" src/probe.sh:1"))' "$FIXTURE/manifest.json" >/dev/null
  command jq -e 'length == 0' "$FIXTURE/manifest.json.out-of-scope.json" >/dev/null
  test -z "$(find "$FIXTURE" -name 'manifest.json.scope.*' -print)"
done
printf 'Results: scope input failure preserves both publications and retries\n'
