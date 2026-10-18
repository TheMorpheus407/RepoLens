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


# Predictable-stage symlinks must neither receive URL bytes nor become receipts.
# shellcheck disable=SC2034,SC2329 # Production callbacks consume these globals.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO/lib/polish.sh"
fixture="$(mktemp -d)" || exit 1
trap 'rm -rf -- "$fixture"' EXIT
failures=0
check() {
  if ! "$@"; then printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); fi
}
# Retain rendering; plant the old predictable path at the local/remote window.
eval "$(declare -f _polish_render_issue_body | sed '1s/_polish_render_issue_body/original_render_issue_body/')"
plant() { ln -s "$victim" "$marker.tmp.$$"; }
_polish_render_issue_body() {
  original_render_issue_body "$@" || return $?
  if [[ "$scenario" == local ]]; then plant; fi
}
# Record POSTs in the fixture; no network or model call is made.
forge_issue_create() {
  printf 'post\n' >> "$LOG_BASE/posts"
  plant || return $?
  printf 'https://github.com/fixture/repo/issues/1\n'
}
for scenario in remote local; do
  LOG_BASE="$fixture/$scenario" RUN_ID=probe FORGE_REPO_SLUG=fixture/repo
  LOCAL_MODE=false GLOBAL_ISSUES_CREATED=0 MAX_ISSUES=1 REPOLENS_FINAL_STATE=finished
  [[ "$scenario" != local ]] || LOCAL_MODE=true
  mkdir -p "$LOG_BASE/polish/filed"
  printf '[{"domain":"fluency","lens_id":"spacing-consistency","title":"Spacing","body":"Concrete suggestion","voice_fit":"strong","polish_rank_x1000":1500}]\n' > "$LOG_BASE/polish/ranked-suggestions.json"
  : > "$LOG_BASE/posts"
  marker="$LOG_BASE/polish/filed/fluency-spacing-consistency.url"
  victim="$LOG_BASE/unrelated-file"
  printf 'valuable unrelated bytes\n' > "$victim"
  victim_hash="$(sha256sum < "$victim")"
  rc=0; run_polish_issue_emission probe 3 > "$LOG_BASE/emission.log" 2>&1 || rc=$?
  printf '%s: emission=%s count=%s\n' "$scenario" "$rc" "$GLOBAL_ISSUES_CREATED"
  check test "$rc" -eq 0
  check test "$GLOBAL_ISSUES_CREATED" -eq 1
  check test "$(sha256sum < "$victim")" = "$victim_hash"
  check test -f "$marker"
  check test ! -L "$marker"
  check test -L "$marker.tmp.$$"
  expected_url="https://github.com/fixture/repo/issues/1"
  [[ "$scenario" != local ]] || expected_url="local:${marker%.url}.md"
  check test "$(cat "$marker")" = "$expected_url"
  expected_posts=1
  [[ "$scenario" != local ]] || expected_posts=0
  check test "$(wc -l < "$LOG_BASE/posts")" -eq "$expected_posts"
  GLOBAL_ISSUES_CREATED=0
  rc=0; run_polish_issue_emission probe 3 > "$LOG_BASE/retry.log" 2>&1 || rc=$?
  check test "$rc" -eq 0
  check test "$GLOBAL_ISSUES_CREATED" -eq 1
  check test "$(wc -l < "$LOG_BASE/posts")" -eq "$expected_posts"
done
# A failed exclusive allocation after POST remains an uncertain attempt. Retrying
# cannot create a duplicate; independent reconciliation recovers the saved count.
scenario=allocation LOG_BASE="$fixture/allocation" GLOBAL_ISSUES_CREATED=0 LOCAL_MODE=false
mkdir -p "$LOG_BASE/polish/filed"
cp "$fixture/remote/polish/ranked-suggestions.json" "$LOG_BASE/polish/ranked-suggestions.json"
: > "$LOG_BASE/posts"
marker="$LOG_BASE/polish/filed/fluency-spacing-consistency.url"
# Inject only allocation of this receipt, leaving all other file operations real.
mktemp() {
  if [[ "${1:-}" == "$marker.tmp.XXXXXX" ]]; then
    touch "$LOG_BASE/allocation-reached"
    return 74
  fi
  command mktemp "$@"
}
forge_issue_create() {
  printf 'post\n' >> "$LOG_BASE/posts"
  printf 'https://github.com/fixture/repo/issues/1\n'
}
rc=0; run_polish_issue_emission probe 3 > "$LOG_BASE/emission.log" 2>&1 || rc=$?
check test -f "$LOG_BASE/allocation-reached"
check test "$rc" -ne 0
check test ! -e "$marker"
check test -f "${marker%.url}.attempted"
check test "$GLOBAL_ISSUES_CREATED" -eq 0
check test -z "$(find "$LOG_BASE/polish/filed" -name '*.tmp.*' -print)"
unset -f mktemp
rc=0; run_polish_issue_emission probe 3 > "$LOG_BASE/retry.log" 2>&1 || rc=$?
check test "$rc" -ne 0
check test "$(wc -l < "$LOG_BASE/posts")" -eq 1
printf 'https://github.com/fixture/repo/issues/1\n' > "$marker"
rc=0; run_polish_issue_emission probe 3 > "$LOG_BASE/reconciled.log" 2>&1 || rc=$?
check test "$rc" -eq 0
check test "$GLOBAL_ISSUES_CREATED" -eq 1
check test "$(wc -l < "$LOG_BASE/posts")" -eq 1
# Publisher admission must also reject invalid source objects itself. Keep the
# saved destination and source names unchanged on failure, with no FIFO reads.
for kind in symlink dangling fifo directory; do
  src="$fixture/source-$kind" dest="$fixture/receipt-$kind"
  printf 'previous receipt\n' > "$dest"
  case "$kind" in
    symlink) ln -s "$victim" "$src" ;;
    dangling) ln -s "$fixture/missing" "$src" ;;
    fifo) mkfifo "$src" ;;
    directory) mkdir "$src" ;;
  esac
  rc=0; _polish_publish_receipt "$src" "$dest" || rc=$?
  check test "$rc" -ne 0
  check test -f "$dest"
  check test ! -L "$dest"
  # Do not read an invalid destination FIFO on the old implementation.
  if [[ -f "$dest" && ! -L "$dest" ]]; then
    check test "$(cat "$dest")" = 'previous receipt'
  fi
  check test -e "$src" -o -L "$src"
done
printf 'Polish receipt staging: %s failures\n' "$failures"
(( failures == 0 ))
