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

# Regression: repolens-r9-p2-2. Exercise the standalone public renderer;
# no models, forge calls, or writes outside this disposable fixture.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/human_review.sh
source "$ROOT/lib/human_review.sh"
TMPROOT="$(mktemp -d)"
trap 'rm -rf -- "$TMPROOT"' EXIT
PASS=0 FAIL=0
# check <label> <command> [args...]: count and print one assertion result.
check() {
  local label="$1"
  shift
  if "$@"; then
    PASS=$((PASS + 1)); printf 'PASS: %s\n' "$label"
  else
    FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$label"
  fi
}
# Succeed only when the renderer has removed all staged Markdown files.
no_staging() {
  [[ -z "$(find "$LOG_BASE/final" -name 'HUMAN_REVIEW.md.tmp.*' -print)" ]]
}
for kind in directory directory-link; do
  LOG_BASE="$TMPROOT/$kind"
  mkdir -p "$LOG_BASE/final" "$TMPROOT/$kind-target"
  printf 'keep\n' > "$TMPROOT/$kind-target/sentinel"
  if [[ "$kind" == directory ]]; then
    mkdir "$LOG_BASE/final/HUMAN_REVIEW.md"
    printf 'keep\n' > "$LOG_BASE/final/HUMAN_REVIEW.md/sentinel"
    target="$LOG_BASE/final/HUMAN_REVIEW.md"
  else
    ln -s "$TMPROOT/$kind-target" "$LOG_BASE/final/HUMAN_REVIEW.md"
    target="$TMPROOT/$kind-target"
  fi
  printf '%s\n' '{"id":"current","title":"Current finding","severity":"high","status":"new"}' > "$LOG_BASE/final/findings.jsonl"
  before="$(cksum < "$LOG_BASE/final/findings.jsonl")"
  for attempt in 1 2; do
    rc=0
    render_human_review_digest destination || rc=$?
    check "$kind attempt $attempt reports IO failure" test "$rc" -eq 1
    check "$kind attempt $attempt preserves target type" test -d "$LOG_BASE/final/HUMAN_REVIEW.md"
    check "$kind attempt $attempt creates no nested report" test "$(find "$target" -type f | wc -l)" -eq 1
    check "$kind attempt $attempt preserves sentinel" grep -qx keep "$target/sentinel"
    check "$kind attempt $attempt removes staging" no_staging
    check "$kind attempt $attempt leaves registry unchanged" test "$before" = "$(cksum < "$LOG_BASE/final/findings.jsonl")"
  done
  if [[ "$kind" == directory-link ]]; then
    check 'directory symlink remains unchanged' test "$(readlink "$LOG_BASE/final/HUMAN_REVIEW.md")" = "$target"
    rm "$LOG_BASE/final/HUMAN_REVIEW.md"
  else
    rm "$target/sentinel"
    # The old implementation leaves nested reports; remove only this fixture.
    rm -rf -- "$target"
  fi
  rc=0
  render_human_review_digest destination || rc=$?
  check "$kind repaired target succeeds" test "$rc" -eq 0
  check "$kind repaired target has canonical file" test -f "$LOG_BASE/final/HUMAN_REVIEW.md"
  check "$kind repaired target contains current finding" grep -q 'Current finding' "$LOG_BASE/final/HUMAN_REVIEW.md"
  check "$kind repaired target has no staging" no_staging
  printf 'old report\n' > "$LOG_BASE/final/HUMAN_REVIEW.md"
  rc=0
  render_human_review_digest replacement || rc=$?
  check "$kind existing regular report replaces successfully" test "$rc" -eq 0
  check "$kind replacement contains new run" grep -q 'Human Review — replacement' "$LOG_BASE/final/HUMAN_REVIEW.md"
done
# A file symlink must be replaced at the exact output path, leaving its target.
rm "$LOG_BASE/final/HUMAN_REVIEW.md"
printf 'outside report\n' > "$TMPROOT/outside.md"
ln -s "$TMPROOT/outside.md" "$LOG_BASE/final/HUMAN_REVIEW.md"
rc=0
render_human_review_digest file-link || rc=$?
check 'file symlink promotion succeeds' test "$rc" -eq 0
check 'file symlink target remains untouched' grep -qx 'outside report' "$TMPROOT/outside.md"
check 'file symlink becomes canonical regular file' test ! -L "$LOG_BASE/final/HUMAN_REVIEW.md"
check 'file symlink replacement contains current finding' grep -q 'Current finding' "$LOG_BASE/final/HUMAN_REVIEW.md"
check 'successful promotion removes staging' no_staging
# Source relatively in a fresh shell, then leave the repository before rendering.
# Existing caller helpers and shell state must survive the lazy artifact import.
rc=0
bash -euo pipefail -s -- "$ROOT" "$TMPROOT/relative source" <<'BASH' || rc=$?
cd "$1"
source lib/human_review.sh
LOG_BASE="$2"
mkdir -p "$LOG_BASE/final"
printf '%s\n' '{"id":"relative","title":"Relative source finding","severity":"high","status":"new"}' > "$LOG_BASE/final/findings.jsonl"
cd "$LOG_BASE"
_artifacts_replace_report() { return 93; }
tmp='caller temporary value'
caller_options="$(set +o)"
render_human_review_digest relative-source
[[ "$tmp" == 'caller temporary value' && "$(set +o)" == "$caller_options" ]]
helper_rc=0
_artifacts_replace_report || helper_rc=$?
[[ "$helper_rc" -eq 93 ]]
BASH
check 'relative source renders after changing directory and preserves caller state' test "$rc" -eq 0
check 'relative source report contains the current finding' grep -q 'Relative source finding' "$TMPROOT/relative source/final/HUMAN_REVIEW.md"
check 'relative source leaves no staging' test -z "$(find "$TMPROOT/relative source/final" -name 'HUMAN_REVIEW.md.tmp.*' -print)"
# A disposable module copy lets configuration differ from the static fallback
# without changing the repository registry. A different cwd must not change
# bucket membership, the digest, or surfaced/held-back accounting.
config_root="$TMPROOT/config source"
mkdir -p "$config_root/lib" "$config_root/config"
cp "$ROOT/lib/human_review.sh" "$ROOT/lib/artifacts.sh" "$config_root/lib/"
printf '%s\n' '{"domains":[{"id":"application-security"}]}' > "$config_root/config/domains.json"
for kind in missing-config foreign-config; do
  rc=0
  bash -euo pipefail -s -- "$config_root" "$TMPROOT/$kind" "$kind" <<'BASH' || rc=$?
cd "$1"
source lib/human_review.sh
LOG_BASE="$2/logs"
mkdir -p "$LOG_BASE/final" "$2/cwd"
printf '%s\n' '{"id":"configured","title":"Configured security finding","severity":"medium","domain":"application-security","status":"new"}' > "$LOG_BASE/final/findings.jsonl"
human_review_bucketize "$LOG_BASE/final/findings.jsonl" > "$2/before.json"
jq -e '.top_medium_security.items[0].id == "configured" and .remainder.count == 0' "$2/before.json" > /dev/null
render_human_review_digest configured
cp "$LOG_BASE/final/HUMAN_REVIEW.md" "$2/before.md"
human_review_heldback_summary configured > "$2/before-summary.txt"
if [[ "$3" == foreign-config ]]; then
  mkdir -p "$2/cwd/lib" "$2/cwd/config"
  printf '%s\n' '{"domains":[{"id":"foreign-security"}]}' > "$2/cwd/config/domains.json"
fi
cd "$2/cwd"
human_review_bucketize "$LOG_BASE/final/findings.jsonl" > "$2/after.json"
render_human_review_digest configured
human_review_heldback_summary configured > "$2/after-summary.txt"
BASH
  check "$kind renders after directory change" test "$rc" -eq 0
  check "$kind preserves configured security bucket" cmp -s "$TMPROOT/$kind/before.json" "$TMPROOT/$kind/after.json"
  check "$kind preserves digest sections" cmp -s "$TMPROOT/$kind/before.md" "$TMPROOT/$kind/logs/final/HUMAN_REVIEW.md"
  check "$kind preserves surfaced accounting" cmp -s "$TMPROOT/$kind/before-summary.txt" "$TMPROOT/$kind/after-summary.txt"
done
printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
