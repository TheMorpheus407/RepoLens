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

# repolens-r13-p6-4: rejected proposals must survive exec argument limits.
# shellcheck disable=SC2034,SC2329 # Fixture globals/callbacks are production inputs.
set -euo pipefail
check() { "$@" || { printf 'FAIL: %s\n' "$*" >&2; exit 1; }; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/lib/core.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/synthesize.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
MODE=branch-review AGENT=stub ROUNDS=1
LOG_BASE="$TMP/run" PROJECT_PATH="$TMP/project"
mkdir -p "$LOG_BASE/rounds/round-1/lens-outputs/security" "$LOG_BASE/final" "$PROJECT_PATH"
printf '["src/changed.sh"]\n' > "$LOG_BASE/branch-scope.json"
printf 'src/changed.sh:1\n' > "$LOG_BASE/rounds/round-1/lens-outputs/security/finding.md"
python3 - "$LOG_BASE/proposal.json" <<'PYDATA'
import json, sys
finding = {
    "cluster_id": "large", "title": "Large out-of-scope finding", "severity": "high",
    "domain": "security", "lens": "injection", "root_cause_category": "validation",
    "source_finding_paths": ["finding.md"], "dedup_against_existing": [],
    "proposed_labels": [], "cross_link_actions": [], "granularity": "independent",
    "body": "x" * 160000 + "\nsrc/unchanged.sh:1\n",
}
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump([finding], stream)
PYDATA
compose_prompt() { printf 'mock prompt\n'; }
run_agent() { cat "$LOG_BASE/proposal.json"; }
handle_agent_failure_in_phase() { return 0; }
FAULT_REJECTION=0
# Simulate an interrupted rejection serialization after partial output. The
# normal large-body case below does not inject any IO/exec failure.
jq() {
  local arg
  for arg in "$@"; do
    if [[ "$FAULT_REJECTION" == 1 && "$arg" == *'{finding:'* ]]; then
      printf '{"partial":'
      return 42
    fi
  done
  command jq "$@"
}
assert_publications() {
  check jq -e 'length == 0' "$LOG_BASE/final/manifest.json"
  check jq -e --slurpfile original "$LOG_BASE/proposal.json" '
    length == 1 and .[0].finding == $original[0][0]
    and .[0].reason == "out-of-scope citation: src/unchanged.sh"
  ' "$LOG_BASE/final/manifest.json.out-of-scope.json"
}
# Feed the large candidate to the real scope filter directly: the unrelated
# Bash JSON extractor walks large agent replies character by character and
# would make this suite too slow. Exercise the synthesis caller below with a
# small proposal and the same rejection-write failure.
candidate="$LOG_BASE/final/manifest.json.tmp.large"
cp "$LOG_BASE/proposal.json" "$candidate"
check branch_scope_filter_manifest "$candidate"
check mv "$candidate" "$LOG_BASE/final/manifest.json"
assert_publications
check jq -e '.[0].finding.body | length > 160000' "$LOG_BASE/final/manifest.json.out-of-scope.json"
printf '[{"cluster_id":"saved","cross_link_actions":[]}]\n' > "$LOG_BASE/final/cross-link-actions.preserved.json"
publication_hashes() {
  sha256sum "$LOG_BASE/final/manifest.json" "$LOG_BASE/final/manifest.json.out-of-scope.json" "$LOG_BASE/final/cross-link-actions.preserved.json"
}
before="$(publication_hashes)"
cp "$LOG_BASE/proposal.json" "$candidate"
check branch_scope_filter_manifest "$candidate"
check mv "$candidate" "$LOG_BASE/final/manifest.json"
assert_publications
check test "$before" = "$(publication_hashes)"
# Pin the retryable status and candidate preservation at the filter boundary.
cp "$LOG_BASE/proposal.json" "$candidate"
FAULT_REJECTION=1
rc=0
branch_scope_filter_manifest "$candidate" || rc=$?
check test "$rc" -eq 2
check jq -e --slurpfile original "$LOG_BASE/proposal.json" '. == $original[0]' "$candidate"
check test "$before" = "$(publication_hashes)"
check test -z "$(find "$LOG_BASE/final" -name '*.scope.*' -print)"
check rm "$candidate"
# Keep the prior large rejection report while the caller handles a failed
# serialization of a fresh, small candidate with partial stdout.
jq '.[0].body = "src/unchanged.sh:1"' "$LOG_BASE/proposal.json" > "$TMP/small.json"
mv "$TMP/small.json" "$LOG_BASE/proposal.json"
FAULT_REJECTION=1
rc=0
run_synthesizer probe || rc=$?
check test "$rc" -ne 0
check test "$before" = "$(publication_hashes)"
check jq -e --slurpfile original "$LOG_BASE/proposal.json" '. == $original[0]' "$LOG_BASE/final/manifest.scope-pending.json"
check test -z "$(find "$LOG_BASE/final" -name '*.scope.*' -print)"
FAULT_REJECTION=0
check run_synthesizer probe
assert_publications
check test ! -e "$LOG_BASE/final/manifest.scope-pending.json"
check test ! -e "$LOG_BASE/final/cross-link-actions.preserved.json"
printf 'PASS: large rejected findings survive; failed serialization preserves publications and repairs on retry.\n'
