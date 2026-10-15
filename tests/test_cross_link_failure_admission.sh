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

# Inject returning cancellation between the failure helper's entry and marker move.
# shellcheck disable=SC2034 # Production callback consumes cancellation state.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO/lib/filing.sh"
FIXTURE="$(mktemp -d)" || exit 1
trap 'rm -rf -- "$FIXTURE"' EXIT
for signal in HUP INT TERM; do
  if (
    done_file="$FIXTURE/$signal.done"
    : > "$done_file"
    REPOLENS_FINAL_STATE=finished
    trap 'REPOLENS_FINAL_STATE=interrupted' HUP INT TERM
    # DEBUG runs just before the marker write, after the entry cancellation check.
    set -T
    trap 'if [[ "$BASH_COMMAND" == *done_file%.done*attempted* ]]; then trap - DEBUG; kill -s "$signal" "$BASHPID"; fi' DEBUG
    rc=0
    _filing_cross_link_fail "$done_file" "$FIXTURE/$signal.failed" invalid || rc=$?
    trap - DEBUG
    [[ "$rc" == 1 && -e "$done_file" && -e "$FIXTURE/$signal.attempted" && ! -e "$FIXTURE/$signal.unverified-done" && ! -e "$FIXTURE/$signal.failed" ]]
  ); then printf 'PASS: %s failure admission\n' "$signal"
  else printf 'FAIL: %s failure admission\n' "$signal"; exit 1; fi
done

# A returning signal inside mv must roll quarantine back before writing a result.
for signal in HUP INT TERM; do
  for move_status in 0 1; do
    if (
      prefix="$FIXTURE/move-$signal-$move_status"
      printf 'saved receipt\n' > "$prefix.done"
      REPOLENS_FINAL_STATE=finished
      trap 'REPOLENS_FINAL_STATE=interrupted' HUP INT TERM
      mv() {
        command mv "$@" || return 1
        if [[ "$1" == "$prefix.done" ]]; then
          kill -s "$signal" "$BASHPID"
          return "$move_status"
        fi
      }
      rc=0
      _filing_cross_link_fail "$prefix.done" "$prefix.failed" invalid || rc=$?
      [[ "$rc" == 1 && -e "$prefix.done" && -e "$prefix.attempted" && ! -e "$prefix.unverified-done" && ! -e "$prefix.failed" ]] || exit 1
      cmp -s <(printf 'saved receipt\n') "$prefix.done"
    ); then printf 'PASS: %s quarantine move status %s\n' "$signal" "$move_status"
    else printf 'FAIL: %s quarantine move status %s\n' "$signal" "$move_status"; exit 1; fi
  done
done

# The final reopen recount must use the same reversible quarantine transition.
for signal in HUP INT TERM; do
  if (
    LOG_BASE="$FIXTURE/recount-$signal"
    prefix="$LOG_BASE/final/filed/cross-link/reopen-suggestion-9"
    mkdir -p "${prefix%/*}"
    : > "$prefix.done"
    printf 'https://example.invalid/issues/17\n' > "$prefix.created-response"
    printf 'saved banner\n' > "$prefix.body.banner.md"
    REPOLENS_FINAL_STATE=finished FORGE_REPO=acme/repo
    REPOLENS_INTERRUPT_EXIT_CODE=130
    case "$signal" in HUP) REPOLENS_INTERRUPT_EXIT_CODE=129;; TERM) REPOLENS_INTERRUPT_EXIT_CODE=143;; esac
    trap 'REPOLENS_FINAL_STATE=interrupted' HUP INT TERM
    forge_issue_number_from_url() { printf '17\n'; }
    forge_issue_read_json() { printf '{}\n'; }
    mv() {
      command mv "$@" || return 1
      if [[ "$1" == "$prefix.done" ]]; then kill -s "$signal" "$BASHPID"; fi
    }
    rc=0
    filing_verified_issue_count probe > "$LOG_BASE/count" || rc=$?
    [[ "$rc" == "$REPOLENS_INTERRUPT_EXIT_CODE" && -e "$prefix.done" && -e "$prefix.attempted" && ! -e "$prefix.unverified-done" && ! -e "$prefix.failed" && ! -s "$LOG_BASE/count" ]]
  ); then printf 'PASS: %s recount quarantine rollback\n' "$signal"
  else printf 'FAIL: %s recount quarantine rollback\n' "$signal"; exit 1; fi
done
