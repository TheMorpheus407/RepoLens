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

# Duplicate exclusions must preserve review capacity and honest accounting.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO/lib/human_review.sh"
FIXTURE="$(mktemp -d)" || exit 1
trap 'rm -rf -- "$FIXTURE"' EXIT
export LOG_BASE="$FIXTURE/run"
mkdir -p "$LOG_BASE/final"
findings="$LOG_BASE/final/findings.jsonl"
digest="$LOG_BASE/final/HUMAN_REVIEW.md"
failed=0 checks=0
check() {
  checks=$((checks + 1))
  if ! "$@" >/dev/null 2>&1; then
    printf 'FAIL: %s\n' "$*"
    failed=$((failed + 1))
  fi
}
lacks() { ! grep -qE "$@"; }
# Exercise every bucket with eligible records and higher-ranking duplicates.
# Duplicates would displace eligible records at both caps without the filter.
jq -nc '
  [range(0;12) | {id:("high-"+tostring),severity:"high",type:"reliability-bug"}]
  + [range(0;27) | {id:("medium-"+tostring),severity:"medium",type:"security-vulnerability"}]
  + [{id:"quality",severity:"low",type:"test-gap"},
     {id:"scanner",severity:"low",type:"external-dependency"},
     {id:"remainder",severity:"low",type:"reliability-bug"}]
  | .[] | . + {title:.id,domain:"code",lens:"probe",status:"new",confidence:0.5,validation:{}}
' > "$FIXTURE/eligible.jsonl"
jq -c '. + {id:("duplicate-"+.id),title:("DUPLICATE "+.title),status:"duplicate",confidence:1}' \
  "$FIXTURE/eligible.jsonl" > "$FIXTURE/duplicates.jsonl"
cat "$FIXTURE/eligible.jsonl" "$FIXTURE/duplicates.jsonl" > "$findings"
before="$(sha256sum "$findings")"
human_review_bucketize "$findings" > "$FIXTURE/buckets.json"
check jq -e '.registry_count == 84 and .excluded_duplicates == 42
  and .top_critical_high.count == 12 and .top_medium_security.count == 27
  and .test_quality.count == 1 and .not_actionable_without_scanner.count == 1 and .remainder.count == 1
  and ([ (.top_critical_high,.top_medium_security,.test_quality,.not_actionable_without_scanner,.remainder).items[] ]
       | length == 42 and all(.status == "new"))' "$FIXTURE/buckets.json"
render_human_review_digest probe
check test "$(grep -cE '^### ' "$digest")" -eq 38
check lacks '^### .*DUPLICATE' "$digest"
check grep -qE '12 total, showing 10, 2 more' "$digest"
check grep -qE '27 total, showing 25, 2 more' "$digest"
check grep -qE '84 registry findings: 42 eligible, 42 duplicates excluded' "$digest"
check grep -Fq '[findings.jsonl](findings.jsonl)' "$digest"
# A provenance link must only appear when the report actually exists.
check lacks '\[DUPLICATES.md\]' "$digest"
summary="$(human_review_heldback_summary probe)"
check test "$summary" = 'Human review: 42 findings, 37 surfaced, 5 held back (critical/high +2, medium-security +2, remainder collapsed across 1 theme(s)); 84 registry findings, 42 duplicates excluded'
: > "$LOG_BASE/final/DUPLICATES.md"
render_human_review_digest probe
check grep -Fq '[DUPLICATES.md](DUPLICATES.md)' "$digest"
check test "$(sha256sum "$findings")" = "$before"

# A duplicate-only registry has zero eligible/held-back entries, with provenance.
cat "$FIXTURE/duplicates.jsonl" > "$findings"
human_review_bucketize "$findings" > "$FIXTURE/buckets.json"
check jq -e '.registry_count == 42 and .excluded_duplicates == 42
  and ([.top_critical_high,.top_medium_security,.test_quality,.not_actionable_without_scanner,.remainder] | all(.count == 0))' "$FIXTURE/buckets.json"
render_human_review_digest probe
check grep -qE '42 registry findings: 0 eligible, 42 duplicates excluded' "$digest"
check grep -qE 'No findings to review' "$digest"
check lacks '^### ' "$digest"
check test "$(human_review_heldback_summary probe)" = 'Human review: 0 findings, 0 surfaced, 0 held back (critical/high +0, medium-security +0, no remainder); 42 registry findings, 42 duplicates excluded'

# Without duplicates, retain the established digest/header and log strings.
cat "$FIXTURE/eligible.jsonl" > "$findings"
render_human_review_digest probe
check grep -Fq '42 finding(s) across 5 buckets' "$digest"
check lacks 'duplicates excluded' "$digest"
check test "$(human_review_heldback_summary probe)" = 'Human review: 42 findings, 37 surfaced, 5 held back (critical/high +2, medium-security +2, remainder collapsed across 1 theme(s))'
: > "$findings"
render_human_review_digest probe
check test "$(human_review_heldback_summary probe)" = 'Human review: 0 findings, 0 surfaced, 0 held back (critical/high +0, medium-security +0, no remainder)'
printf 'Human review duplicate exclusions: %s checks, %s failures.\n' "$checks" "$failed"
(( failed == 0 ))
