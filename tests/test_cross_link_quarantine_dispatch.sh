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

# A failed saved-comment quarantine must fail both dispatcher entry paths.
# shellcheck disable=SC2034,SC2329 # Sourced callbacks consume fixture globals.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO/lib/filing.sh"
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT

case_dispatch() (
  local_manifest="$1" destination="$2"
  LOG_BASE="$FIXTURE/$local_manifest-$destination" PROJECT_PATH="$FIXTURE/project"
  FORGE_REPO=acme/probe CROSS_LINK_MODE=comment PARALLEL=false
  REPOLENS_FINAL_STATE=finished
  filed_dir="$LOG_BASE/final/filed" cross="$LOG_BASE/final/filed/cross-link/comment-9"
  mkdir -p "$filed_dir/cross-link" "$PROJECT_PATH/src" "$LOG_BASE/outside"
  printf 'code\n' > "$PROJECT_PATH/src/a.sh"
  entry='{"cluster_id":"c1","title":"Finding","body":"src/a.sh:1","proposed_labels":[],"dedup_against_existing":[],"cross_link_actions":[{"type":"comment","issue_number":9,"body":"Saved comment."},{"type":"comment","issue_number":10,"body":"Later comment."}]}'
  if [[ "$local_manifest" == nonempty ]]; then
    printf '[%s]\n' "$entry" > "$LOG_BASE/final/manifest.json"
    printf '%s\n' "$entry" > "$filed_dir/c1.request.json"
    printf 'https://example.invalid/acme/probe/issues/17\n' > "$filed_dir/c1.url"
  else
    printf '[]\n' > "$LOG_BASE/final/manifest.json"
    jq '[.cross_link_actions[] | . + {cluster_id:"c1",evidence_body:"src/a.sh:1"}]' <<< "$entry" > "$LOG_BASE/final/cross-link-actions.preserved.json"
  fi
  printf 'saved receipt\n' > "$cross.done"
  printf 'Saved comment.' > "$cross.body.md"
  printf 'https://example.invalid/acme/probe/issues/9#comment-42\n' > "$cross.created-response"
  if [[ "$destination" == directory ]]; then
    mkdir "$cross.unverified-done"
  else
    ln -s "$LOG_BASE/outside" "$cross.unverified-done"
  fi
  target_open=false
  forge_filing_capable() { return 0; }
  forge_issue_number_from_url() { printf '17\n'; }
  forge_issue_read_json() {
    printf '%s\n' "$2" >> "$LOG_BASE/reads"
    if [[ "$2" == 17 ]]; then
      printf '{"number":17,"url":"https://example.invalid/acme/probe/issues/17","title":"Finding","body":"src/a.sh:1","state":"open","labels":[]}\n'
    elif [[ "$2" == 9 ]] && ! $target_open; then
      printf '{"state":"closed"}\n'
    else
      printf '{"state":"open"}\n'
    fi
  }
  forge_issue_comment_once() {
    printf '%s\n' "$2" >> "$LOG_BASE/posts"
    printf 'https://example.invalid/acme/probe/issues/%s#comment-42\n' "$2"
  }
  forge_issue_comment_read_json() {
    jq -cn --rawfile body "$filed_dir/cross-link/comment-$2.body.md" --arg url "$3" '{body:$body,url:$url}'
  }

  rc=0
  dispatch_filing_batch probe > "$LOG_BASE/output" 2> "$LOG_BASE/errors" || rc=$?
  printf '%s/%s: blocked quarantine dispatch=%s\n' "$local_manifest" "$destination" "$rc"
  [[ "$rc" == 1 ]]
  cmp -s <(printf 'saved receipt\n') "$cross.done"
  cmp -s <(printf 'Saved comment.') "$cross.body.md"
  [[ -f "$cross.attempted" && ! -e "$cross.failed" && ! -e "$LOG_BASE/posts" ]]
  [[ ! -e "$filed_dir/cross-link/comment-10.attempted" ]]
  [[ -z "$(find "$LOG_BASE/outside" -type f -print)" ]]

  # Repair storage and remote target state. Resume reattests the saved comment
  # without reposting it, then admits the later action exactly once.
  if [[ "$destination" == directory ]]; then rmdir "$cross.unverified-done";
  else rm "$cross.unverified-done"; fi
  target_open=true
  dispatch_filing_batch probe > "$LOG_BASE/resumed-output" 2> "$LOG_BASE/resumed-errors"
  [[ "$(cat "$LOG_BASE/posts")" == 10 ]]
  [[ -f "$cross.done" && -f "$cross.readback.json" && ! -e "$cross.failed" ]]
  [[ -f "$filed_dir/cross-link/comment-10.done" ]]
  dispatch_filing_batch probe > "$LOG_BASE/repeated-output" 2> "$LOG_BASE/repeated-errors"
  [[ "$(cat "$LOG_BASE/posts")" == 10 ]]
  printf 'PASS: %s/%s repair resumes saved and later comments without duplicate POSTs.\n' "$local_manifest" "$destination"
)

if (( $# )); then
  case_dispatch "$1" "$2"
else
  for local_manifest in empty nonempty; do
    for destination in directory symlink-directory; do
      case_dispatch "$local_manifest" "$destination"
    done
  done
fi
