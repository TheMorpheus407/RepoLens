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

# Race at the actual rename boundary; both old mv and exact-path implementations
# use the same hook. Real returning signals, no forge or model calls.
# shellcheck disable=SC2034,SC2329
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/filing.sh
source "$REPO/lib/filing.sh"
eval "$(declare -f _branch_scope_replace_file | sed '1s/_branch_scope_replace_file/real_replace/')"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
case_race() (
  kind="$1" phase="$2" object="$3" signal="$4"
  saved="$fixture/$kind-$phase-$object-$signal"
  mkdir -p "$saved/outside" "$saved/c1.governor"
  if [[ "$kind" == ordinary ]]; then
    original="$saved/c1.url" quarantine="$saved/c1.unverified-url"
  else
    original="$saved/c1.done" quarantine="$saved/c1.unverified-done"
  fi
  printf 'saved-success\n' > "$original"
  REPOLENS_FINAL_STATE=finished injected=0 boundaries=0
  trap 'REPOLENS_FINAL_STATE=interrupted' HUP INT TERM
  obstruct() {
    local target="$1"
    if [[ "$object" == directory ]]; then
      mkdir "$target"
      printf 'unrelated state\n' > "$target/sentinel"
    else
      printf 'unrelated state\n' > "$saved/outside/sentinel"
      ln -s "$saved/outside" "$target"
    fi
  }
  before_move() {
    if [[ "$1" == "$original" && "$2" == "$quarantine" ]]; then
      boundaries=$((boundaries + 1))
      if [[ "$phase" == forward && "$injected" == 0 ]]; then
        obstruct "$quarantine"
        injected=1
      fi
    elif [[ "$phase" == rollback && "$1" == "$quarantine" && "$2" == "$original" && "$injected" == 0 ]]; then
      obstruct "$original"
      injected=1
    fi
  }
  after_move() {
    if [[ "$1" == "$original" && "$2" == "$quarantine" ]]; then
      if [[ "$signal" != none ]]; then kill -s "$signal" "$BASHPID"; fi
    fi
  }
  mv() {
    local args=("$@") rc=0
    local src="${args[${#args[@]}-2]}" dest="${args[${#args[@]}-1]}"
    before_move "$src" "$dest"
    command mv "$@" || rc=$?
    after_move "$src" "$dest"
    return "$rc"
  }
  _branch_scope_replace_file() {
    local rc=0
    before_move "$1" "$2"
    real_replace "$@" || rc=$?
    after_move "$1" "$2"
    return "$rc"
  }
  rc=0
  if [[ "$kind" == ordinary ]]; then
    _filing_fail "$saved" c1 invalid || rc=$?
  else
    _filing_cross_link_fail "$original" "$saved/c1.failed" invalid || rc=$?
  fi
  [[ "$rc" != 0 && "$boundaries" == 1 && -f "$saved/c1.attempted" && ! -e "$saved/c1.failed" ]] || return 1
  if [[ "$kind" == ordinary ]]; then
    [[ ! -e "$saved/c1.governor" ]] || return 1
  fi
  if [[ "$signal" == none ]]; then
    [[ "$REPOLENS_FINAL_STATE" == finished ]] || return 1
  else
    [[ "$REPOLENS_FINAL_STATE" == interrupted ]] || return 1
  fi
  if [[ "$phase" == forward ]]; then
    [[ -f "$original" && ! -L "$original" ]] || return 1
    cmp -s <(printf 'saved-success\n') "$original" || return 1
    collision="$quarantine"
    [[ ! -e "$quarantine/${original##*/}" ]] || return 1
  else
    [[ -f "$quarantine" && ! -L "$quarantine" ]] || return 1
    cmp -s <(printf 'saved-success\n') "$quarantine" || return 1
    collision="$original"
    [[ ! -e "$original/${quarantine##*/}" ]] || return 1
  fi
  if [[ "$object" == directory ]]; then
    [[ -d "$collision" && ! -L "$collision" ]] || return 1
    cmp -s <(printf 'unrelated state\n') "$collision/sentinel" || return 1
  else
    [[ -L "$collision" ]] || return 1
    cmp -s <(printf 'unrelated state\n') "$saved/outside/sentinel" || return 1
  fi
  printf 'PASS: %s/%s/%s/%s preserves receipt and obstruction\n' "$kind" "$phase" "$object" "$signal"
)
failures=0
for kind in ordinary cross-link; do
  for phase in forward rollback; do
    for object in directory symlink-directory; do
      for signal in HUP INT TERM; do
        if ! case_race "$kind" "$phase" "$object" "$signal"; then
          printf 'FAIL: %s/%s/%s/%s\n' "$kind" "$phase" "$object" "$signal"
          failures=$((failures + 1))
        fi
      done
      if [[ "$phase" == forward ]] && ! case_race "$kind" "$phase" "$object" none; then
        failures=$((failures + 1))
      fi
    done
  done
done
printf 'Quarantine race: %s failures\n' "$failures"
(( failures == 0 ))
