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
