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

# repolens-r13-p3-2: quarantine containers must not replace saved receipts.
# shellcheck disable=SC2034,SC2329 # Sourced functions consume globals/callbacks.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO/lib/filing.sh"
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
for kind in ordinary cross-link; do
  for destination in directory symlink-directory; do
    (
      LOG_BASE="$FIXTURE/$kind-$destination"
      filed_dir="$LOG_BASE/final/filed"
      mkdir -p "$filed_dir" "$LOG_BASE/outside"
      prefix="$filed_dir/c1"
      if [[ "$kind" == ordinary ]]; then
        receipt="$prefix.url" quarantine="$prefix.unverified-url"
      else
        receipt="$prefix.done" quarantine="$prefix.unverified-done"
      fi
      printf 'https://example.invalid/acme/repo/issues/17\n' > "$receipt"
      cp "$receipt" "$LOG_BASE/original"
      if [[ "$destination" == directory ]]; then
        mkdir "$quarantine"
      else
        ln -s "$LOG_BASE/outside" "$quarantine"
      fi
      REPOLENS_FINAL_STATE=finished
      trap 'REPOLENS_FINAL_STATE=interrupted' TERM
      mv() {
        local target="${!#}"
        command mv "$@" || return 1
        # Real signal at the same rename boundary as the original failure.
        [[ "$target" != "$quarantine" ]] || kill -TERM "$BASHPID"
      }
      rc=0
      if [[ "$kind" == ordinary ]]; then
        mkdir "$prefix.governor"
        _filing_fail "$filed_dir" c1 'readback failed' || rc=$?
      else
        _filing_cross_link_fail "$receipt" "$prefix.failed" 'readback failed' || rc=$?
      fi
      printf '%s/%s: exit=%s, receipt_regular=%s\n' "$kind" "$destination" "$rc" "$(test -f "$receipt" && echo yes || echo no)"
      test "$rc" -ne 0
      test -f "$receipt"
      cmp "$receipt" "$LOG_BASE/original"
      test -d "$quarantine"
      test ! -e "$quarantine/${receipt##*/}"
      test ! -e "$prefix.failed"
      test -f "$prefix.attempted"
      if [[ "$destination" == symlink-directory ]]; then test -L "$quarantine"; fi
      test -z "$(find "$LOG_BASE/outside" -type f -print)"
      if [[ "$kind" == ordinary ]]; then
        test ! -e "$prefix.governor"
        unset -f mv
        REPOLENS_FINAL_STATE=finished FORGE_REPO=acme/repo
        printf '{"title":"Finding","body":"Evidence","proposed_labels":[]}\n' > "$prefix.request.json"
        forge_issue_number_from_url() { printf '17\n'; }
        forge_issue_read_json() {
          printf 'read\n' >> "$LOG_BASE/forge-reads"
          printf '{"url":"https://example.invalid/acme/repo/issues/17","number":17,"title":"Finding","body":"Evidence","state":"open","labels":[]}\n'
        }
        filing_verified_issue_count probe > "$LOG_BASE/count"
        test "$(cat "$LOG_BASE/count")" = 1
        test "$(wc -l < "$LOG_BASE/forge-reads")" -eq 1
        test -f "$receipt"
        test ! -e "$prefix.failed"
      fi
    )
  done
done
printf 'PASS: unsafe quarantine targets preserve saved receipts and ordinary resume reattests them.\n'
