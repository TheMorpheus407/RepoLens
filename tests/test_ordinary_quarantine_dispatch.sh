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

# Failed ordinary receipt quarantine stops admission before callbacks/comments.
# shellcheck disable=SC2034,SC2329 # Sourced callbacks consume fixture globals.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO/lib/filing.sh"
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT

case_dispatch() (
  destination="$1" PARALLEL="$2"
  LOG_BASE="$FIXTURE/$destination-$PARALLEL" PROJECT_PATH="$FIXTURE/project"
  FORGE_REPO=acme/probe CROSS_LINK_MODE=comment REPOLENS_FINAL_STATE=finished
  filed_dir="$LOG_BASE/final/filed" prefix="$LOG_BASE/final/filed/c1"
  mkdir -p "$filed_dir" "$PROJECT_PATH/src" "$LOG_BASE/outside"
  printf 'code\n' > "$PROJECT_PATH/src/a.sh"
  printf 'external bytes\n' > "$LOG_BASE/outside/target"
  entry='{"cluster_id":"c1","title":"Finding","body":"src/a.sh:1","proposed_labels":[],"dedup_against_existing":[],"cross_link_actions":[{"type":"comment","issue_number":9,"body":"Related finding."}]}'
  # Sequential admission collects a fresh reservation before the bad receipt.
  # Parallel mode has only the receipt, so no process scopes are needed.
  jq -n --argjson entry "$entry" --arg parallel "$PARALLEL" '
    if $parallel == "true" then [$entry]
    else [($entry | .cluster_id="c0" | .title="Fresh" | .cross_link_actions=[]), $entry] end
  ' > "$LOG_BASE/final/manifest.json"
  printf '%s\n' "$entry" > "$prefix.request.json"
  printf 'https://example.invalid/acme/probe/issues/17\n' > "$prefix.url"
  case "$destination" in
    directory) mkdir "$prefix.unverified-url" ;;
    symlink-directory) ln -s "$LOG_BASE/outside" "$prefix.unverified-url" ;;
    symlink-file) ln -s "$LOG_BASE/outside/target" "$prefix.unverified-url" ;;
    symlink-dangling) ln -s "$LOG_BASE/outside/missing" "$prefix.unverified-url" ;;
    *) exit 2 ;;
  esac
  read_ok=false
  forge_filing_capable() { return 0; }
  forge_issue_number_from_url() { printf '%s\n' "${2##*/}"; }
  forge_issue_read_json() {
    printf '%s\n' "$2" >> "$LOG_BASE/reads"
    if [[ "$2" == 9 ]]; then printf '{"state":"open"}\n'; return 0; fi
    $read_ok || return 1
    title=Finding
    [[ "$2" != 18 ]] || title=Fresh
    jq -cn --argjson number "$2" --arg title "$title" '{number:$number,url:("https://example.invalid/acme/probe/issues/"+($number|tostring)),title:$title,body:"src/a.sh:1",state:"open",labels:[]}'
  }
  forge_issue_list_json() { printf '[]\n'; }
  forge_issue_create_once() {
    printf 'issue\n' >> "$LOG_BASE/posts"
    printf 'https://example.invalid/acme/probe/issues/18\n'
  }
  forge_issue_comment_once() {
    printf 'comment\n' >> "$LOG_BASE/posts"
    printf 'https://example.invalid/acme/probe/issues/9#comment-42\n'
  }
  forge_issue_comment_read_json() {
    jq -cn --rawfile body "$filed_dir/cross-link/comment-9.body.md" --arg url "$3" '{body:$body,url:$url}'
  }

  rc=0
  dispatch_filing_batch probe > "$LOG_BASE/output" 2> "$LOG_BASE/errors" || rc=$?
  printf '%s/parallel=%s: blocked quarantine dispatch=%s posts=%s\n' \
    "$destination" "$PARALLEL" "$rc" "$(test ! -e "$LOG_BASE/posts" || cat "$LOG_BASE/posts")"
  [[ "$rc" == 1 && ! -e "$LOG_BASE/posts" ]]
  cmp -s <(printf 'https://example.invalid/acme/probe/issues/17\n') "$prefix.url"
  [[ -f "$prefix.attempted" && ! -e "$prefix.failed" && ! -e "$prefix.governor" ]]
  [[ ! -e "$filed_dir/c0.lock" && ! -e "$filed_dir/c0.attempted" ]]
  [[ ! -e "$filed_dir/cross-link/comment-9.attempted" ]]
  cmp -s <(printf 'external bytes\n') "$LOG_BASE/outside/target"
  [[ ! -e "$LOG_BASE/outside/c1.url" && ! -e "$LOG_BASE/outside/missing" ]]
  if [[ "$destination" == directory ]]; then rmdir "$prefix.unverified-url";
  else test -L "$prefix.unverified-url"; rm "$prefix.unverified-url"; fi

  # Resume reattests the historical issue, then publishes only pending work.
  read_ok=true PARALLEL=false
  dispatch_filing_batch probe > "$LOG_BASE/resumed-output" 2> "$LOG_BASE/resumed-errors"
  [[ -f "$prefix.readback.json" && -f "$prefix.url" && ! -e "$prefix.failed" ]]
  [[ ! -e "$prefix.governor" && -f "$filed_dir/cross-link/comment-9.done" ]]
  expected=comment
  [[ "$2" != false ]] || expected=$'issue\ncomment'
  [[ "$(cat "$LOG_BASE/posts")" == "$expected" ]]
  dispatch_filing_batch probe > "$LOG_BASE/repeated-output" 2> "$LOG_BASE/repeated-errors"
  [[ "$(cat "$LOG_BASE/posts")" == "$expected" ]]
  printf 'PASS: %s/parallel=%s repair resumes without repeating completed POSTs.\n' "$destination" "$2"
)

if (( $# )); then
  case_dispatch "$1" "$2"
else
  for destination in directory symlink-directory symlink-file symlink-dangling; do
    for parallel in false true; do case_dispatch "$destination" "$parallel"; done
  done
fi
