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

# repolens-r16-p7-3: Unicode titles must not disappear behind equal IDs.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/lib/ledger.sh"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
check_ids() {
  test "$(finding_id security injection 缓存泄漏)" != "$(finding_id security injection 登录失败)"
  test "$(finding_id security injection 'Cache 缓存泄漏')" != "$(finding_id security injection 'Cache 登录失败')"
  test "$(finding_id security injection '[High] 缓存泄漏!')" = "$(finding_id security injection 缓存泄漏)"
  test "$(finding_id security injection कल)" != "$(finding_id security injection कला)"
  test "$(finding_id security injection café)" = "$(finding_id security injection $'cafe\u0301')"
  test "$(LC_ALL=C finding_id security injection 缓存泄漏)" = "$(finding_id security injection 缓存泄漏)"
  # Preserve the existing ASCII content identities.
  test "$(finding_id security injection 'Missing CSRF token')" = fnd-c85e3de3f641
}
check_ids
# CLI ingestion has the synthesizer loaded; it must retain the same identities.
# shellcheck source=/dev/null
source "$ROOT/lib/synthesize.sh"
check_ids
LOG_BASE="$fixture/run"
mkdir -p "$LOG_BASE/final"
jq -n '["缓存泄漏", "登录失败"] | to_entries | map({
  cluster_id:("independent-" + (.key|tostring)),title:.value,
  severity:"high",domain:"security",lens:"injection",root_cause_category:"validation",
  body:"Independent cause",source_finding_paths:[("finding-" + (.key|tostring) + ".md")],dedup_against_existing:[],
  proposed_labels:[],cross_link_actions:[],granularity:"independent"
})' > "$LOG_BASE/final/manifest.json"
validate_manifest "$LOG_BASE/final/manifest.json"
build_finding_registry probe ''
jq -se 'length == 2 and ([.[].id] | unique | length == 2)
  and ([.[].title] | sort == (["缓存泄漏", "登录失败"] | sort))' "$LOG_BASE/final/findings.jsonl"
test "$(wc -l < "$LOG_BASE/final/findings.csv")" -eq 3
printf 'PASS: Unicode identities preserve both independent findings and ASCII compatibility.\n'
