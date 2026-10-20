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
  test "$(finding_id security injection café)" = "$(finding_id security injection $'cafe\xcc\x81')"
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
titles='["缓存泄漏", "登录失败", "𞓐", "𞓑", "Ᲊ", "ᲊ"]'
jq -n --argjson titles "$titles" '$titles | to_entries | map({
  cluster_id:("independent-" + (.key|tostring)),title:.value,
  severity:"high",domain:"security",lens:"injection",root_cause_category:"validation",
  body:"Independent cause",source_finding_paths:[("finding-" + (.key|tostring) + ".md")],dedup_against_existing:[],
  proposed_labels:[],cross_link_actions:[],granularity:"independent"
})' > "$LOG_BASE/final/manifest.json"
validate_manifest "$LOG_BASE/final/manifest.json"
build_finding_registry probe ''
jq -se --argjson titles "$titles" 'length == ($titles | length)
  and ([.[].id] | unique | length == ($titles | length))
  and ([.[].title] | sort == ($titles | sort))' "$LOG_BASE/final/findings.jsonl"
jq -s 'map({id,title}) | sort_by(.id)' "$LOG_BASE/final/findings.jsonl" > "$fixture/manifest-identities.json"
python3 - "$LOG_BASE/final/findings.csv" "$titles" <<'PY'
import csv
import json
import sys
with open(sys.argv[1], encoding="utf-8", newline="") as stream:
    rows = list(csv.DictReader(stream))
assert sorted(row["title"] for row in rows) == sorted(json.loads(sys.argv[2]))
assert len({row["id"] for row in rows}) == len(rows)
PY

# Exercise the separate local-frontmatter ingestion path with the same titles.
local_dir="$fixture/local"
mkdir -p "$local_dir"
index=0
while IFS= read -r title; do
  index=$((index + 1))
  printf -- '---\ntitle: %s\nseverity: high\ndomain: security\nlens: injection\n---\nIndependent cause.\n' "$title" > "$local_dir/$index.md"
done < <(jq -r '.[]' <<< "$titles")
LOG_BASE="$fixture/local-run"
build_finding_registry probe "$local_dir"
jq -s 'map({id,title}) | sort_by(.id)' "$LOG_BASE/final/findings.jsonl" > "$fixture/local-identities.json"
cmp "$fixture/manifest-identities.json" "$fixture/local-identities.json"
test "$(wc -l < "$LOG_BASE/final/findings.csv")" -eq 7
printf 'PASS: Independent Unicode findings retain identical JSONL/CSV identities through manifest and local ingestion.\n'
