#!/usr/bin/env bash
# repolens-r15-p5-1: a predictable staging symlink must never redirect output.
# shellcheck disable=SC2034 # Production functions consume LOG_BASE.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/human_review.sh"
set -euo pipefail
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
LOG_BASE="$FIXTURE/run"
mkdir -p "$LOG_BASE/final"
printf '%s\n' '{"id":"f1","title":"Current finding","severity":"high","status":"new"}' > "$LOG_BASE/final/findings.jsonl"
printf 'Unrelated original bytes\n' > "$FIXTURE/unrelated"
ln -s "$FIXTURE/unrelated" "$LOG_BASE/final/HUMAN_REVIEW.md.tmp.$$"
render_human_review_digest probe
[[ "$(cat "$FIXTURE/unrelated")" == 'Unrelated original bytes' ]]
[[ ! -L "$LOG_BASE/final/HUMAN_REVIEW.md" ]]
grep -q 'Current finding' "$LOG_BASE/final/HUMAN_REVIEW.md"
# Allocation failure preserves the saved report rather than using a fallback.
cp "$LOG_BASE/final/HUMAN_REVIEW.md" "$FIXTURE/saved"
mktemp() { return 74; }
rc=0
render_human_review_digest probe || rc=$?
unset -f mktemp
[[ "$rc" != 0 ]]
cmp "$FIXTURE/saved" "$LOG_BASE/final/HUMAN_REVIEW.md"
[[ "$(cat "$FIXTURE/unrelated")" == 'Unrelated original bytes' ]]
# Failed rendering removes only its own unique stage.
jq() { return 74; }
rc=0
render_human_review_digest probe || rc=$?
unset -f jq
[[ "$rc" != 0 ]]
cmp "$FIXTURE/saved" "$LOG_BASE/final/HUMAN_REVIEW.md"
[[ "$(find "$LOG_BASE/final" -maxdepth 1 -type f -name 'HUMAN_REVIEW.md.tmp.*' | wc -l)" -eq 0 ]]
printf 'Results: staging symlink, allocation failure and render failure passed\n'
