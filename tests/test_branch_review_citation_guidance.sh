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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/core.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/template.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/filing.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0 FAIL=0
check() {
  local description="$1"; shift
  if "$@"; then PASS=$((PASS + 1)); printf '  PASS: %s\n' "$description"
  else FAIL=$((FAIL + 1)); printf '  FAIL: %s\n' "$description"; fi
}

# Actual before/after source, with different historical and live snippets.
# No model or forge is invoked: this exercises the production citation gate.
mkdir -p "$TMP/project/src"
git -C "$TMP/project" init -q
git -C "$TMP/project" config user.name 'Fixture Author'
git -C "$TMP/project" config user.email 'fixture@example.invalid'
printf 'check() {\n  return 0\n}\n' > "$TMP/project/src/check.sh"
git -C "$TMP/project" add src/check.sh
git -C "$TMP/project" -c commit.gpgsign=false commit -qm 'base'
base_sha="$(git -C "$TMP/project" rev-parse HEAD)"
printf 'check() {\n  return 1\n}\n' > "$TMP/project/src/check.sh"
git -C "$TMP/project" -c commit.gpgsign=false commit -qam 'regress return value'
head_sha="$(git -C "$TMP/project" rev-parse HEAD)"

{
  cat <<'BODY'
## Summary
The successful check now reports failure.

## Introduced By
BODY
  printf 'Commit %s changes the return value.\n\n' "$head_sha"
  cat <<'BODY'
## Before / After
Before: the merge-base check succeeds.
BODY
  printf '\n```bash\ngit show %s:src/check.sh\n```\n\n' "$base_sha"
  printf '```bash\n'
  git -C "$TMP/project" show "$base_sha:src/check.sh"
  printf '```\n\n'
  cat <<'BODY'
After: the head check always fails.
src/check.sh:2

```bash
  return 1
```

## Impact
Callers stop processing otherwise valid input.

## Complexity
- **Complexity:** 2 (Easy)

## Recommended Fix
Restore the success result.

## References
src/check.sh:2

## Validation
- attacker_source: n/a
- missing_guard: n/a
- sink_effect: n/a
- preconditions: call check with valid input
- proof_anchors:
src/check.sh:2
Merge-base command and output appear in Before / After above.
- suggested_validation: bash -c 'source src/check.sh; check'
BODY
} > "$TMP/body.md"
entry="$(jq -cn --rawfile body "$TMP/body.md" '{body:$body}')"
check 'real Before/After evidence with separate historical output passes live gate' \
  filing_verify_cluster_citations "$TMP/project" "$entry"
check 'fixture historical snippet differs from live source' \
  test "$(git -C "$TMP/project" show "$base_sha:src/check.sh")" != "$(cat "$TMP/project/src/check.sh")"
bad_entry="$(jq -cn --arg body 'src/check.sh:2 — `return 0`' '{body:$body}')"
rejects_historical_quote() {
  local reason result
  reason="$(filing_verify_cluster_citations "$TMP/project" "$bad_entry")"
  result=$?
  [[ "$result" -eq 1 && "$reason" == *'snippet not found near cited line'* ]]
}
check 'historical snippet presented as live evidence is rejected' \
  rejects_historical_quote

printf 'Lens evidence fixture.\n' > "$TMP/lens.md"
prompt="$(compose_prompt "$SCRIPT_DIR/prompts/_base/branch-review.md" "$TMP/lens.md" \
  'LENS_NAME=Fixture|DOMAIN_NAME=Correctness|REPO_OWNER=example|REPO_NAME=project' \
  '' branch-review '' '' false true "$TMP/findings")"
check 'shipped rendered branch prompt requires separate live anchors' \
  grep -Fq 'Put each live-head' <<< "$prompt"
check 'shipped local override keeps the resolved base/head evidence contract' \
  grep -Fq 'Record base-side evidence separately as git show <resolved-merge-base-sha>' <<< "$prompt"
check 'shipped guidance keeps the Before / After requirement' \
  grep -Fq '## Before / After' <<< "$prompt"
check 'shipped guidance explains deleted-file-only quarantine' \
  grep -Fq 'deleted-file-only findings without a surviving changed-file head anchor' <<< "$prompt"

printf 'Results: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
