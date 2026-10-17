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

# repolens-r12-p4-2: nested provenance cannot override root finding metadata.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/core.sh"
source "$ROOT/lib/rounds.sh"
source "$ROOT/lib/summary.sh"
source "$ROOT/lib/ledger.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
PASS=0 FAIL=0
check() { if "$@"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$*" >&2; fi; }
# Capture failure explicitly so all behavioural assertions reach the summary.
scalar_is() {
  local value rc=0
  value="$(printf '%s\n' "$FM" | _round_digest_frontmatter_scalar "$1")" || rc=$?
  check test "$rc" -eq 0
  check test "$value" = "$2"
}
values_are() {
  local value rc=0
  value="$(printf '%s\n' "$FM" | _round_digest_frontmatter_values "$1")" || rc=$?
  check test "$rc" -eq 0
  check test "$value" = "$2"
}
canonical='title: Actual high finding
domain: generic
lens_id: probe
severity: high
root_cause_category:
  - race
  - retry
suspect_files:
  - src/right.sh:1'
provenance='provenance:
  generic_source_id: nested-provenance-marker
  title: Antecedent low finding
  domain: custom
  lens_id: decoy
  severity: low
  root_cause_category:
    - wrong
  suspect_files:
    - src/decoy.sh:99'
for placement in before after; do
  for indent in 0 2 4; do
    prefix="$(printf '%*s' "$indent" '')"
    if [[ "$placement" == before ]]; then FM="$provenance"$'\n'"$canonical"
    else FM="$canonical"$'\n'"$provenance"; fi
    FM="$(printf '%s\n' "$FM" | sed "s/^/$prefix/")"
    scalar_is title 'Actual high finding'
    scalar_is domain generic
    scalar_is lens_id probe
    scalar_is severity high
    values_are root_cause_category $'race\nretry'
    values_are suspect_files src/right.sh:1
  done
done
# Nested-only metadata cannot fill absent canonical fields.
FM="$provenance"
scalar_is title ''
scalar_is domain ''
scalar_is lens_id ''
scalar_is severity ''
scalar_is generic_source_id ''
# Valid indentless lists still belong to their root keys.
FM='provenance:
  suspect_files:
    - src/decoy.sh:99
suspect_files:
- src/right.sh:1
root_cause_category:
- race
- retry'
values_are suspect_files src/right.sh:1
values_are root_cause_category $'race\nretry'
# Delivery/resume integration: retain an existing high finding when only nested
# metadata is added. This uses a zero-indented root; projection indentation is
# a distinct regression tracked as repolens-r12-p4-1/p6-1.
LOG_BASE="$TMP/run" OUTPUT_DIR="$TMP/output" RUN_ID=probe
MODE=bugreport LOCAL_MODE=true ROUNDS=1 REPOLENS_MIN_SEVERITY=high
SUMMARY_FILE="$LOG_BASE/summary.json"
mkdir -p "$LOG_BASE/rounds/round-1/lens-outputs" "$OUTPUT_DIR"
printf '%s\n' '{"lens_ids":["generic/probe"]}' > "$LOG_BASE/rounds/round-1/metadata.json"
source_path="$LOG_BASE/rounds/round-1/lens-outputs/probe.md"
printf -- '---\n%s\n---\n## hypothesis\nActual high finding\n## evidence\nsrc/right.sh:1\n' "$canonical" > "$source_path"
check init_summary "$SUMMARY_FILE" probe "$TMP" bugreport mock '' '' local "$OUTPUT_DIR"
check export_generic_local_findings "$OUTPUT_DIR"
check build_findings_jsonl_from_local "$OUTPUT_DIR" "$TMP/before.jsonl"
check jq -se 'length==1 and .[0].severity=="high"' "$TMP/before.jsonl"
printf -- '---\n%s\n%s\n---\n## hypothesis\nActual high finding\n## evidence\nsrc/right.sh:1\n' "$provenance" "$canonical" > "$source_path"
check export_generic_local_findings "$OUTPUT_DIR"
check build_findings_jsonl_from_local "$OUTPUT_DIR" "$TMP/after.jsonl"
check jq -se 'length==1 and .[0].title=="Actual high finding" and .[0].severity=="high" and .[0].domain=="generic" and .[0].lens=="probe"' "$TMP/after.jsonl"
check jq -se --slurpfile old "$TMP/before.jsonl" 'length==1 and .[0].id==$old[0].id and .[0].markdown_path==$old[0].markdown_path' "$TMP/after.jsonl"
check test "$(find "$OUTPUT_DIR" -type f -name '*.md' | wc -l)" -eq 1
check export_generic_local_findings "$OUTPUT_DIR"
printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
