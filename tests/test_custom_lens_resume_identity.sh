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
  printf 'meta\n' >> "$LOG_BASE/meta-calls"
  if [[ "$CURRENT_ROUND_INDEX" == 2 ]]; then
    if $FAIL_SECOND_META; then return 42; fi
    printf 'NO_FRESH_ANGLES\n'
  else
    printf 'CUSTOM: Payment retry race\nDraft prompt:\nCheck payment retry races.\n'
  fi
}
run_lens() {
  local canonical role focus anchor exclude
  _rounds_meta_tuple_parse "$1" canonical role focus anchor exclude
  if ! grep -qxF "$canonical" "$completed_lenses_file" 2>/dev/null; then
    printf '%s:%s\n' "$CURRENT_ROUND_INDEX" "$canonical" >> "$LOG_BASE/lens-calls"
    printf '%s\n' "$canonical" >> "$completed_lenses_file"
  fi
  return 0
}
build_round_digest() { mkdir -p "$1"; printf 'mock digest\n' > "$1/digest.md"; }
LOCAL_MODE=false PARALLEL=false
RUN_ID=probe MODE=audit AGENT=mock
LENSES_DIR="$REPO/prompts/lenses"
LENSES=(security/injection)
LOG_BASE="$FIXTURE/run"
PROJECT_PATH="$FIXTURE"
SUMMARY_FILE="$FIXTURE/summary.json"
mkdir -p "$LOG_BASE"
completed_lenses_file="$LOG_BASE/.completed"
FAIL_SECOND_META=true
first_rc=0
run_rounds 3 LENSES || first_rc=$?
test "$first_rc" -eq 42
first="$(wc -l < "$LOG_BASE/lens-calls")"
test ! -f "$LOG_BASE/rounds/round-2/.completed"
RESUME_RUN_ID=probe
FAIL_SECOND_META=false
run_rounds 3 LENSES || exit $?
second="$(wc -l < "$LOG_BASE/lens-calls")"
printf 'master=%s\nlens calls before resume=%s; after resume=%s\n' "$(git -C "$REPO" rev-parse HEAD)" "$first" "$second"
cat "$LOG_BASE/lens-calls"
printf 'meta calls=%s\n' "$(wc -l < "$LOG_BASE/meta-calls")"
test "$first" -eq 2
test "$second" -eq 2
run_rounds 3 LENSES || exit $?
test "$(wc -l < "$LOG_BASE/lens-calls")" -eq 2
test "$(find "$LOG_BASE" -name 'r2-payment-retry-race*.md' | wc -l)" -eq 1
printf 'PASS: custom completion identity survives repeated resume.\n'
# Distinct entries, including identical categories/focus with different tuple
# roles, retain their collision-separated identities on every materialization.
cat > "$FIXTURE/collisions.md" <<'EOF'
CUSTOM: Payment retry race role=deeper
Draft prompt:
Check payment retry races.
CUSTOM: Payment retry race role=broader
Draft prompt:
Check payment retry races.
CUSTOM: payment-retry race!
Draft prompt:
Inspect another retry path.
EOF
CURRENT_ROUND_INDEX=2
entries_first="$(_rounds_meta_dispatch_custom_entries "$FIXTURE/collisions.md" "$FIXTURE/collisions")"
entries_again="$(_rounds_meta_dispatch_custom_entries "$FIXTURE/collisions.md" "$FIXTURE/collisions")"
test "$entries_first" = "$entries_again"
test "$(find "$FIXTURE/collisions" -name '*.md' | wc -l)" -eq 3
grep -q 'custom/r2-payment-retry-race-2|broader' <<< "$entries_first"
grep -q 'custom/r2-payment-retry-race-3' <<< "$entries_first"
printf 'PASS: same-round collisions stay distinct and stable on retry.\n'
