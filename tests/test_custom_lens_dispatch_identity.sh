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

# Exercise identity through real handoff certification, parsing and completion.
# shellcheck disable=SC2034,SC2329 # Production driver consumes globals/callbacks.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
# shellcheck source=/dev/null
source "$REPO/lib/rounds.sh"
log_info() { :; }
log_warn() { :; }
set_stop_reason() { :; }
record_lens() { :; }
compose_prompt() { printf 'mock prompt'; }
run_agent() {
  if [[ "$CURRENT_ROUND_INDEX" == 2 ]]; then
    if $FAIL_SECOND_META; then return 42; fi
    printf 'NO_FRESH_ANGLES\n'
  else
    cat "$META_FIXTURE"
  fi
}
run_lens() {
  local canonical role focus anchor exclude
  _rounds_meta_tuple_parse "$1" canonical role focus anchor exclude
  if ! grep -qxF "$canonical" "$completed_lenses_file" 2>/dev/null; then
    printf '%s:%s\n' "$CURRENT_ROUND_INDEX" "$1" >> "$LOG_BASE/lens-calls"
    printf '%s\n' "$canonical" >> "$completed_lenses_file"
  fi
  return 0
}
build_round_digest() { mkdir -p "$1"; printf 'mock digest\n' > "$1/digest.md"; }
LOCAL_MODE=false PARALLEL=false
RUN_ID=probe RESUME_RUN_ID=probe MODE=audit AGENT=mock
LENSES_DIR="$REPO/prompts/lenses"
LENSES=(security/injection)
PROJECT_PATH="$FIXTURE"
SUMMARY_FILE="$FIXTURE/summary.json"
META_FIXTURE="$FIXTURE/meta.txt"
passed=0 failed=0
check() {
  if "$@"; then passed=$((passed + 1));
  else failed=$((failed + 1)); printf 'FAIL: %s\n' "$*"; fi
}
# Each header attribute alone changes the prompt even with identical body text.
for category in Retry 再試行; do
case "$category" in
  Retry) first_slug=retry; changed_slug=retry-2 ;;
  *) first_slug=custom-1; changed_slug=custom-2 ;;
esac
for attribute in role focus anchor exclude body legacy; do
  LOG_BASE="$FIXTURE/$category-$attribute"
  mkdir -p "$LOG_BASE"
  completed_lenses_file="$LOG_BASE/.completed"
  FAIL_SECOND_META=true
  case "$attribute" in
    body) printf 'CUSTOM: %s\nDraft prompt:\nInspect first path.\n' "$category" ;;
    legacy) printf 'CUSTOM: %s role=deeper\nDraft prompt:\nInspect retries.\n' "$category" ;;
    *) printf 'CUSTOM: %s %s=first\nDraft prompt:\nInspect retries.\n' "$category" "$attribute" ;;
  esac > "$META_FIXTURE"
  rc=0
  run_rounds 3 LENSES || rc=$?
  check test "$rc" -eq 42
  check test "$(wc -l < "$LOG_BASE/lens-calls")" -eq 2
  # A missing proof forces production to regenerate round 1's handoff.
  rm "$LOG_BASE/rounds/round-1/meta-orchestrator-success.json"
  case "$attribute" in
    body) printf 'CUSTOM: %s\nDraft prompt:\nInspect second path.\n' "$category" > "$META_FIXTURE" ;;
    legacy)
      # Pre-upgrade attributed lenses used this exact format, without metadata.
      sed '/^dispatch_attributes:/d' "$LOG_BASE/rounds/round-1/custom-lenses/custom/r2-$first_slug.md" > "$FIXTURE/legacy.md"
      mv "$FIXTURE/legacy.md" "$LOG_BASE/rounds/round-1/custom-lenses/custom/r2-$first_slug.md"
      ;;
    *) printf 'CUSTOM: %s %s=second\nDraft prompt:\nInspect retries.\n' "$category" "$attribute" > "$META_FIXTURE" ;;
  esac
  FAIL_SECOND_META=false
  rc=0
  run_rounds 3 LENSES || rc=$?
  check test "$rc" -eq 0
  check test "$(wc -l < "$LOG_BASE/lens-calls")" -eq 3
  check grep -q "custom/r2-$changed_slug" "$LOG_BASE/lens-calls"
  run_rounds 3 LENSES || exit $?
  check test "$(wc -l < "$LOG_BASE/lens-calls")" -eq 3
  printf 'Verified regenerated handoff for %s / %s.\n' "$category" "$attribute"
done
done
# Same-category work survives production parsing at both boundary and EOF.
LOG_BASE="$FIXTURE/variants"
mkdir -p "$LOG_BASE"
completed_lenses_file="$LOG_BASE/.completed"
cat > "$META_FIXTURE" <<'EOF'
CUSTOM: Retry role=deeper focus="trace | retry" anchor=f1 exclude=f2
Draft prompt:
Inspect retries.
CUSTOM: Retry role=broader focus="trace | retry" anchor=f1 exclude=f2
Draft prompt:
Inspect retries.
CUSTOM: Retry role=broader focus="trace | retry" anchor=f1 exclude=f2
Draft prompt:
Inspect another path.
- CUSTOM: Retry exclude=f2 anchor=f1 missed_angle="trace | retry" role=broader
```prompt
Inspect another path.
```
EOF
run_rounds 2 LENSES || exit $?
check test "$(wc -l < "$LOG_BASE/lens-calls")" -eq 4
check grep -q 'custom/r2-retry-2|broader' "$LOG_BASE/lens-calls"
check grep -q 'custom/r2-retry-3|broader' "$LOG_BASE/lens-calls"
run_rounds 2 LENSES || exit $?
check test "$(wc -l < "$LOG_BASE/lens-calls")" -eq 4
# Reordered accepted variants must match their saved identities, including pipes.
rm "$LOG_BASE/rounds/round-1/meta-orchestrator-success.json"
cat > "$META_FIXTURE" <<'EOF'
CUSTOM: Retry role=broader focus="trace | retry" anchor=f1 exclude=f2
Draft prompt:
Inspect another path.
CUSTOM: Retry role=deeper focus="trace | retry" anchor=f1 exclude=f2
Draft prompt:
Inspect retries.
CUSTOM: Retry role=broader focus="trace | retry" anchor=f1 exclude=f2
Draft prompt:
Inspect retries.
EOF
run_rounds 2 LENSES || exit $?
check test "$(wc -l < "$LOG_BASE/lens-calls")" -eq 4
CURRENT_ROUND_INDEX=2
entries="$(_rounds_meta_dispatch_custom_entries "$LOG_BASE/rounds/round-1/dispatch.md" "$LOG_BASE/rounds/round-1/custom-lenses")"
check test "${entries%%|*}" = custom/r2-retry-3
# Categories without an ASCII slug must keep their identity after reordering.
# The first pass also creates the legacy custom-N file format (no attributes).
LOG_BASE="$FIXTURE/non-ascii"
mkdir -p "$LOG_BASE"
completed_lenses_file="$LOG_BASE/.completed"
cat > "$META_FIXTURE" <<'EOF'
CUSTOM: 再試行
Draft prompt:
Inspect retries.
CUSTOM: 同時実行
Draft prompt:
Inspect concurrency.
CUSTOM: !!!
Draft prompt:
Inspect punctuation-only categories.
EOF
run_rounds 2 LENSES || exit $?
check test "$(wc -l < "$LOG_BASE/lens-calls")" -eq 4
check test -f "$LOG_BASE/rounds/round-1/custom-lenses/custom/r2-custom-1.md"
check test -f "$LOG_BASE/rounds/round-1/custom-lenses/custom/r2-custom-2.md"
check test -f "$LOG_BASE/rounds/round-1/custom-lenses/custom/r2-custom-3.md"
rm "$LOG_BASE/rounds/round-1/meta-orchestrator-success.json"
cat > "$META_FIXTURE" <<'EOF'
CUSTOM: !!!
Draft prompt:
Inspect punctuation-only categories.
CUSTOM: 同時実行
Draft prompt:
Inspect concurrency.
CUSTOM: 再試行
Draft prompt:
Inspect retries.
EOF
run_rounds 2 LENSES || exit $?
check test "$(wc -l < "$LOG_BASE/lens-calls")" -eq 4
run_rounds 2 LENSES || exit $?
check test "$(wc -l < "$LOG_BASE/lens-calls")" -eq 4
check test "$(find "$LOG_BASE/rounds/round-1/custom-lenses" -name '*.md' | wc -l)" -eq 3
# A legacy suffix and a gap must not hide the remaining completed identities.
saved_dir="$LOG_BASE/rounds/round-1/custom-lenses/custom"
sed 's/r2-custom-3/r2-custom-3-2/g' "$saved_dir/r2-custom-3.md" > "$saved_dir/r2-custom-3-2.md"
rm "$saved_dir/r2-custom-1.md" "$saved_dir/r2-custom-3.md"
sed 's@custom/r2-custom-3$@custom/r2-custom-3-2@' "$LOG_BASE/.rounds/round-2.lenses.completed" > "$FIXTURE/completed"
mv "$FIXTURE/completed" "$LOG_BASE/.rounds/round-2.lenses.completed"
cat > "$META_FIXTURE" <<'EOF'
CUSTOM: !!!
Draft prompt:
Inspect punctuation-only categories.
CUSTOM: 同時実行
Draft prompt:
Inspect concurrency.
EOF
rm "$LOG_BASE/rounds/round-1/meta-orchestrator-success.json"
run_rounds 2 LENSES || exit $?
check test "$(wc -l < "$LOG_BASE/lens-calls")" -eq 4
check test "$(find "$saved_dir" -name '*.md' | wc -l)" -eq 2
# The fallback pool remains isolated to the destination round.
CURRENT_ROUND_INDEX=3
entry="$(_rounds_meta_write_custom_lens "${saved_dir%/custom}" $'CUSTOM: 同時実行\nDraft prompt:\nInspect concurrency.' 1)"
check test "$entry" = custom/r3-custom-1
printf '%s checks passed; %s failed.\n' "$passed" "$failed"
test "$failed" -eq 0
