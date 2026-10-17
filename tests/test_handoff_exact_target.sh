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

# repolens-r12-p3-2: promotion must never treat a raced directory as a container.
# shellcheck disable=SC2034,SC2329 # Fixture callbacks/globals are consumed by rounds.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/rounds.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
PASS=0 FAIL=0
check() { if "$@"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$*" >&2; fi; }
MODE=bugreport LENSES_DIR="$ROOT/prompts/lenses"
# Inject only the filesystem interleaving; perform the real promotion command.
insert_directory() {
  if [[ "${RACE:-false}" == true && "$1" == "$TARGET" && ! -e "$TARGET" ]]; then
    if [[ "$VARIANT" == symlink ]]; then ln -s "$EXTERNAL" "$TARGET"; else mkdir "$TARGET"; fi
    printf 'keep\n' > "$TARGET/sentinel"
  fi
}
mv() { insert_directory "${!#}"; command mv "$@"; }
python3() { insert_directory "${!#}"; command python3 "$@"; }
for operation in restore parse; do
  for name in dispatch.md hypotheses.md; do
    for VARIANT in directory symlink; do
      dir="$TMP/$operation-$name-$VARIANT"
      mkdir -p "$dir" "$dir/external"
      EXTERNAL="$dir/external" TARGET="$dir/$name" RACE=false
      printf 'GENERIC: role=deeper focus="accepted investigation"\nHYPOTHESES_TO_VERIFY:\naccepted hypothesis\n' > "$dir/meta-orchestrator-output.txt"
      check _rounds_meta_certify_success "$dir"
      promote() {
        if [[ "$operation" == restore ]]; then _rounds_meta_restore_success "$dir"
        else _rounds_meta_parse_output "$dir/meta-orchestrator-output.txt" "$dir/dispatch.md" "$dir/hypotheses.md"; fi
      }
      RACE=true rc=0
      promote || rc=$?
      check test "$rc" -ne 0
      check test -d "$TARGET"
      check grep -Fxq keep "$TARGET/sentinel"
      check test "$(command find -H "$TARGET" -type f -name "$name" | wc -l)" -eq 0
      check test -f "$dir/meta-orchestrator-success.json"
      if [[ "$VARIANT" == symlink ]]; then check test -L "$TARGET"; fi
      rm -rf -- "$TARGET"
      RACE=false
      check promote
      check test -f "$dir/dispatch.md"
      check test -f "$dir/hypotheses.md"
      entries="$(_rounds_meta_dispatch_generic_entries "$dir/dispatch.md")"
      check test "$entries" = 'generic/deeper-accepted-investigation|deeper|accepted investigation||'
      check test "$(command find "$dir" -maxdepth 1 -type d -name '.meta-*' | wc -l)" -eq 0
    done
  done
done
# Caller-level regression: a failed handoff cannot start a fallback round 2.
log_info() { :; }
log_warn() { :; }
set_stop_reason() { :; }
record_lens() { :; }
compose_prompt() { printf 'mock prompt\n'; }
run_agent() { printf 'GENERIC: role=deeper focus="accepted investigation"\n'; }
run_lens() { printf '%s:%s\n' "$CURRENT_ROUND_INDEX" "$1" >> "$LOG_BASE/calls"; printf '%s\n' "$1" >> "$completed_lenses_file"; }
build_round_digest() { mkdir -p "$1"; printf 'digest\n' > "$1/digest.md"; }
LOCAL_MODE=false PARALLEL=false RUN_ID=probe RESUME_RUN_ID='' AGENT=mock
LOG_BASE="$TMP/run" SUMMARY_FILE="$TMP/run/summary.json" completed_lenses_file="$TMP/run/.completed"
TARGET="$LOG_BASE/rounds/round-1/dispatch.md" VARIANT=directory RACE=true
LENSES=(security/injection)
rc=0
run_rounds 2 LENSES || rc=$?
check test "$rc" -ne 0
check test "$(wc -l < "$LOG_BASE/calls")" -eq 1
check test ! -e "$LOG_BASE/rounds/round-2/.completed"
check grep -Fxq keep "$TARGET/sentinel"
printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
