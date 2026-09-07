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

# RepoLens — deterministic filing governor and batch dispatcher.
#
# Consumes the validated synthesizer manifest at
# logs/<run-id>/final/manifest.json and fans out one governed publisher per cluster
# in parallel, with atomic per-cluster reservations and permanent POST-attempt
# markers. Resume reattests successful results and dispatches unattempted gaps.
#
# This module is sourceable; it defines functions only and has no top-level
# side effects beyond loading shared helpers. It expects lib/parallel.sh,
# lib/core.sh, lib/forge.sh, and lib/logging.sh to be sourced
# by the caller.
#
# Concurrency contract:
#   The .lock file guards crash-resume re-entry of a SINGLE dispatcher
#   process across runs. It is not a flock — its mtime is the freshness
#   signal, and a stale lock (mtime older than STALE_LOCK_TIMEOUT, default
#   3600s) is eligible for dispatcher recovery. The governor reservation and
#   .attempted marker independently prevent repeating a POST. Two concurrent
#   dispatch_filing_batch invocations on the same run_id may race; the
#   intended invariant is "one dispatcher per run".

# shellcheck source=lib/branch-scope.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/branch-scope.sh"

# _filing_repo_root
#   Resolves the repository root from this file's location. Used to locate
#   prompts/_base/file-issue.md.
_filing_repo_root() {
  local source_dir
  source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s' "$(cd "$source_dir/.." && pwd)"
}

# _filing_log_base <run_id>
#   Returns the run log base directory. Honors LOG_BASE when set so callers
#   and tests can redirect output, otherwise falls back to
#   <repo_root>/logs/<run_id>.
_filing_log_base() {
  local run_id="${1:-}"
  if [[ -n "${LOG_BASE:-}" ]]; then
    printf '%s' "$LOG_BASE"
    return 0
  fi
  printf '%s/logs/%s' "$(_filing_repo_root)" "$run_id"
}

# _filing_lock_age <lock_path>
#   Prints the age in seconds of the lock file, or a very large number if
#   the lock file does not exist or its mtime cannot be read. Uses GNU
#   `stat -c %Y` with a BSD `stat -f %m` fallback.
_filing_lock_age() {
  local lock_path="$1"
  local mtime now
  if [[ ! -e "$lock_path" ]]; then
    printf '%s' '999999999'
    return 0
  fi
  mtime="$(stat -c %Y "$lock_path" 2>/dev/null || stat -f %m "$lock_path" 2>/dev/null || printf '0')"
  now="$(date +%s)"
  if [[ ! "$mtime" =~ ^[0-9]+$ ]]; then
    printf '%s' '999999999'
    return 0
  fi
  printf '%d' $((now - mtime))
}

# filing_verify_cluster_citations <project_path> <manifest_entry_json>
#   Deterministic re-verification of every `path:LINE` (or `path:LSTART-LEND`)
#   citation embedded in a synthesizer manifest entry's `body` field. This is
#   the mandatory shell-level guard before a cluster can reach
#   a forge mutation. The production governor invokes it unconditionally
#   before provider calls and before trusting persisted success markers.
#
#   Citation grammar (extracted from the manifest entry's `body` string):
#     - `path:LINE`               (single-line citation)
#     - `path:LSTART-LEND`        (line-range citation; LSTART <= LEND)
#     - Optionally followed by a backtick-fenced snippet on the same logical
#       line, e.g. `src/auth.sh:42 — \`return $LOGIN_DENIED\`` — when present,
#       the snippet text must appear within +/-20 lines of the cited line.
#
#   For each citation:
#     1. The cited file must exist under <project_path>.
#     2. The cited line (or LSTART..LEND range) must lie within the file's
#        line count. LSTART > line_count -> MISMATCH "line exceeds file
#        length".
#     3. If a backtick snippet is attached, the snippet text must be findable
#        (substring match) within +/-20 lines of the cited line. Snippet not
#        found -> MISMATCH "snippet not found near cited line".
#
#   On success: returns 0. Prints nothing.
#   On failure: returns 1. Prints exactly one concise reason line on stdout
#               of the form `<path>:<line> <description>` so callers can
#               embed it verbatim after `VERIFICATION_FAILED: `.
#
#   If the body contains zero parseable citations the helper treats that as a
#   verification failure ("no citations to verify"), matching the prompt rule
#   that an issue must be backed by at least one verified citation.
filing_verify_cluster_citations() {
  local project_path="${1:-}"
  local entry_json="${2:-}"
  if [[ -z "$project_path" || ! -d "$project_path" ]]; then
    printf 'project path missing or not a directory: %s\n' "$project_path"
    return 1
  fi
  if [[ -z "$entry_json" ]]; then
    printf 'manifest entry json is empty\n'
    return 1
  fi

  local body
  body="$(jq -r '.body // empty' <<<"$entry_json" 2>/dev/null)"
  if [[ -z "$body" ]]; then
    printf 'manifest entry has no body to verify citations against\n'
    return 1
  fi

  # Extract citations of the form `path:N` or `path:N-M`. The path component
  # accepts letters/digits/_/-/./ slash, must contain at least one '/' or
  # '.' to avoid trapping things like `step:1`, and the line number must be
  # numeric. Use a temporary while loop with grep -oE so each match is
  # processed independently.
  local citations
  citations="$(repolens_extract_citations "$body")"

  if [[ -z "$citations" ]]; then
    printf 'no citations found in body\n'
    return 1
  fi

  local citation path line_spec lstart lend file_path line_count snippet
  local snippet_pattern context_start context_end
  while IFS= read -r citation; do
    [[ -n "$citation" ]] || continue
    path="${citation%:*}"
    line_spec="${citation##*:}"
    if [[ "$line_spec" == *-* ]]; then
      lstart="${line_spec%-*}"
      lend="${line_spec#*-}"
    else
      lstart="$line_spec"
      lend="$line_spec"
    fi
    if ! [[ "$lstart" =~ ^[0-9]+$ ]] || ! [[ "$lend" =~ ^[0-9]+$ ]]; then
      printf '%s invalid line spec\n' "$citation"
      return 1
    fi
    if (( ${#lstart} > 9 || ${#lend} > 9 )); then
      printf '%s line number too large\n' "$citation"
      return 1
    fi
    lstart=$((10#$lstart))
    lend=$((10#$lend))
    if (( lstart < 1 )) || (( lend < lstart )); then
      printf '%s invalid line range\n' "$citation"
      return 1
    fi

    if [[ "$path" == /* || "$path" == .. || "$path" == ../* || "$path" == */../* || "$path" == */.. ]]; then
      printf '%s path escapes project\n' "$citation"
      return 1
    fi
    # Reject symlink components so a repo-controlled citation cannot read
    # credentials or unrelated source outside the checked project.
    local component candidate="$project_path" remainder="$path"
    while [[ -n "$remainder" ]]; do
      component="${remainder%%/*}"
      candidate="$candidate/$component"
      if [[ -L "$candidate" ]]; then
        printf '%s symlink citation is not allowed\n' "$citation"
        return 1
      fi
      [[ "$remainder" == */* ]] || break
      remainder="${remainder#*/}"
    done
    file_path="$project_path/$path"
    if [[ ! -f "$file_path" ]]; then
      printf '%s file not found\n' "$citation"
      return 1
    fi
    line_count="$(wc -l <"$file_path" | tr -d ' ')"
    # Treat a final line without a trailing newline as a real line.
    if [[ -s "$file_path" ]] && [[ "$(tail -c 1 "$file_path" | od -An -c | tr -d ' ')" != '\n' ]]; then
      line_count=$((line_count + 1))
    fi
    if (( lstart > line_count )) || (( lend > line_count )); then
      printf '%s line exceeds file length (%d lines)\n' "$citation" "$line_count"
      return 1
    fi

    # Optional snippet check: look for a backtick-quoted snippet attached to
    # this citation on the same logical body line. Use grep on the body so
    # multi-line bodies are searched line-by-line.
    snippet="$(grep -F -- "$citation" <<<"$body" \
      | grep -oE "\`[^\`]+\`" \
      | sed -e 's/^`//' -e 's/`$//' \
      | grep -vE '^.+:[0-9]+(-[0-9]+)?$' \
      | head -1)"
    if [[ -n "$snippet" ]]; then
      context_start=$(( lstart - 20 ))
      (( context_start < 1 )) && context_start=1
      context_end=$(( lend + 20 ))
      (( context_end > line_count )) && context_end=$line_count
      snippet_pattern="$(sed -n "${context_start},${context_end}p" "$file_path")"
      if [[ "$snippet_pattern" != *"$snippet"* ]]; then
        printf '%s snippet not found near cited line\n' "$citation"
        return 1
      fi
    fi
  done <<< "$citations"

  return 0
}

# _filing_real_agent <run_id> <cluster_id>
# Kept as the dispatcher callback name for compatibility. Filing is now a
# deterministic governor: no model, prompt, shell evaluation, or model-owned
# sentinels participate in this credential-bearing phase.
_filing_real_agent() {
  local run_id="$1" cluster_id="$2" log_base entry reason repo title body_file
  local open_issues duplicate created_url number readback label
  log_base="$(_filing_log_base "$run_id")"
  local filed_dir="$log_base/final/filed"
  [[ "$cluster_id" =~ ^[A-Za-z0-9_][A-Za-z0-9_.:-]*$ ]] || return 1
  mkdir -p "$filed_dir" || return 1
  # An atomic per-cluster directory protects direct callers and dispatchers
  # racing on an expired legacy .lock marker. A crash leaves this reservation
  # for operator reconciliation, never an automatic repeat of a possible POST.
  mkdir "$filed_dir/$cluster_id.governor" 2>/dev/null || return 1
  if [[ ! -e "$filed_dir/$cluster_id.url" ]] && [[ -e "$filed_dir/$cluster_id.failed" || -e "$filed_dir/$cluster_id.attempted" ]]; then
    rmdir "$filed_dir/$cluster_id.governor"
    return 0
  fi

  entry="$(jq -ce --arg cid "$cluster_id" '
    [.[] | select(.cluster_id == $cid)] | select(length == 1) | .[0]
    | select((.title | type == "string" and length > 0 and (test("[[:cntrl:]]") | not))
      and (.body | type == "string" and length > 0 and (contains("\u0000") | not))
      and (.proposed_labels | type == "array")
      and all(.proposed_labels[]; type == "string" and length > 0 and (test("[[:cntrl:]]") | not))
      and (.dedup_against_existing | type == "array")
      and all(.dedup_against_existing[]; (.issue_number | type == "number" and . > 0 and . == floor)))
  ' "$log_base/final/manifest.json" 2>/dev/null)" || {
    _filing_fail "$filed_dir" "$cluster_id" 'invalid or ambiguous manifest entry'
    return 1
  }
  if ! reason="$(filing_verify_cluster_citations "${PROJECT_PATH:-}" "$entry")"; then
    _filing_fail "$filed_dir" "$cluster_id" "$reason"
    return 1
  fi
  if ! reason="$(branch_scope_verify_body "$(jq -r '.body' <<< "$entry")")"; then
    _filing_fail "$filed_dir" "$cluster_id" "$reason"
    return 1
  fi
  repo="${FORGE_REPO:-${REPO_OWNER:-}/${REPO_NAME:-}}"
  if [[ ! "$repo" =~ ^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)+$ ]] \
      || ! forge_filing_capable create; then
    _filing_fail "$filed_dir" "$cluster_id" 'forge target or structured filing adapter unavailable'
    return 1
  fi
  if [[ -e "$filed_dir/$cluster_id.url" ]]; then
    created_url="$(cat "$filed_dir/$cluster_id.url")"
    if [[ -L "$filed_dir/$cluster_id.url" || -L "$filed_dir/$cluster_id.request.json" ]] \
        || ! jq -e --argjson entry "$entry" '. == $entry' "$filed_dir/$cluster_id.request.json" >/dev/null 2>&1 \
        || ! number="$(forge_issue_number_from_url "$repo" "$created_url")" \
        || ! readback="$(forge_issue_read_json "$repo" "$number")" \
        || ! _filing_readback_matches "$entry" "$created_url" "$number" "$readback"; then
      _filing_fail "$filed_dir" "$cluster_id" 'unattested or stale success marker; reconcile remote state before retry'
      return 1
    fi
    printf '%s\n' "$readback" > "$filed_dir/$cluster_id.readback.json"
    rmdir "$filed_dir/$cluster_id.governor"
    return 0
  fi
  title="$(jq -r '.title' <<< "$entry")"
  if ! open_issues="$(forge_issue_list_json "$repo" open)"; then
    _filing_fail "$filed_dir" "$cluster_id" 'fresh dedup query failed'
    return 1
  fi
  duplicate="$(jq -r --arg title "$title" --argjson entry "$entry" '
    [.[] | select(.state == "open") | select(.title == $title or (.number as $n | any($entry.dedup_against_existing[]; .issue_number == $n)))]
    | .[0].number // empty' <<< "$open_issues")"
  if [[ -n "$duplicate" ]]; then
    printf 'DEDUP_HIT: #%s\n' "$duplicate" > "$filed_dir/$cluster_id.failed"
    rm -f "$filed_dir/$cluster_id.lock"
    rmdir "$filed_dir/$cluster_id.governor"
    return 0
  fi
  body_file="$filed_dir/$cluster_id.governor/body.md"
  # The exact checked body is the exact payload. There is no rewriting agent
  # between verification and POST. Save the request and response for recovery.
  printf '%s\n' "$entry" > "$filed_dir/$cluster_id.request.json" || return 1
  jq -jr '.body' <<< "$entry" > "$body_file" || return 1
  local -a labels=()
  while IFS= read -r label; do labels+=("$label"); done < <(jq -r '.proposed_labels[]' <<< "$entry")
  for label in "${labels[@]}"; do
    if [[ "${FORGE_PROVIDER:-}" == gh ]]; then
      GH_HOST="$(_forge_gh_filing_host)" forge_label_create "$label" ededed "$repo" >> "$filed_dir/$cluster_id.log" 2>&1 || true
    else
      forge_label_create "$label" ededed "$repo" >> "$filed_dir/$cluster_id.log" 2>&1 || true
    fi
  done
  # Mark the attempt BEFORE the call; ambiguous transport failures are terminal.
  : > "$filed_dir/$cluster_id.attempted" || return 1
  if ! created_url="$(forge_issue_create_once "$repo" "$title" "$body_file" "${labels[@]}" 2>> "$filed_dir/$cluster_id.log")"; then
    _filing_fail "$filed_dir" "$cluster_id" 'forge create failed; reconcile remote state before retry'
    return 1
  fi
  printf '%s\n' "$created_url" > "$filed_dir/$cluster_id.created-response"
  if ! number="$(forge_issue_number_from_url "$repo" "$created_url")" \
      || ! readback="$(forge_issue_read_json "$repo" "$number")"; then
    _filing_fail "$filed_dir" "$cluster_id" 'forge readback failed; reconcile created-response before retry'
    return 1
  fi
  printf '%s\n' "$readback" > "$filed_dir/$cluster_id.readback.json"
  if ! _filing_readback_matches "$entry" "$created_url" "$number" "$readback"; then
    _filing_fail "$filed_dir" "$cluster_id" 'forge readback does not match approved request'
    return 1
  fi
  printf '%s\n' "$created_url" > "$filed_dir/$cluster_id.url" || return 1
  rm -f "$filed_dir/$cluster_id.lock" "$body_file"
  rmdir "$filed_dir/$cluster_id.governor"
}

_filing_readback_matches() {
  jq -e --argjson entry "$1" --arg url "$2" --argjson number "$3" '
    .url == $url and .number == $number and .title == $entry.title
    and .body == $entry.body and .state == "open"
    and (($entry.proposed_labels - .labels) | length == 0)
  ' <<< "$4" >/dev/null
}

_filing_fail() {
  local filed_dir="$1" cluster_id="$2" reason="$3"
  if [[ -e "$filed_dir/$cluster_id.url" || -L "$filed_dir/$cluster_id.url" ]]; then
    mv -f "$filed_dir/$cluster_id.url" "$filed_dir/$cluster_id.unverified-url"
    : > "$filed_dir/$cluster_id.attempted"
  fi
  printf 'VERIFICATION_FAILED: %s\n' "$reason" > "$filed_dir/$cluster_id.failed"
  rm -f "$filed_dir/$cluster_id.lock" "$filed_dir/$cluster_id.governor/body.md"
  rmdir "$filed_dir/$cluster_id.governor" 2>/dev/null || true
}

# _filing_cross_link_enact <run_id>
#   Iterate every manifest entry's cross_link_actions[] and enact them via
#   the forge layer. Idempotent: each (type, issue_number) pair is keyed by
#   a content-hash sentinel under final/filed/cross-link/, so re-running the
#   dispatcher does not re-enact already-completed actions.
#
#   Per-action state machine for each cross-link entry:
#     1. <key>.done present     -> SKIP
#     2. <key>.failed present   -> SKIP (operator must rm to retry)
#     3. otherwise              -> attempt; on success write .done; on
#                                  failure write .failed (non-fatal)
#
#   Failures NEVER fail the overall run — cross-link actions are best-effort.
#   They are logged to stderr and counted in the run's diagnostics only.
#
#   Required globals: AGENT, FORGE_REPO (or REPO_OWNER+REPO_NAME).
#   Optional globals: REPOLENS_REOPEN_LABEL (defaults "repolens:reopen-candidate").
#
#   Cross-link actions on a cluster whose own filing failed
#   (<cid>.failed present, no <cid>.url) are skipped to avoid posting a
#   cross-link comment that references a non-existent new issue.
_filing_cross_link_enact() {
  local run_id="${1:-}"
  local log_base manifest preserved_actions verification filed_dir cross_dir
  log_base="$(_filing_log_base "$run_id")"
  manifest="$log_base/final/manifest.json"
  preserved_actions="$log_base/final/cross-link-actions.preserved.json"
  verification="$log_base/final/verification.json"
  filed_dir="$log_base/final/filed"
  cross_dir="$filed_dir/cross-link"

  if [[ ! -f "$manifest" && ! -f "$preserved_actions" ]]; then
    return 0
  fi

  local repo_owner="${REPO_OWNER:-}"
  local repo_name="${REPO_NAME:-}"
  local forge_repo="${FORGE_REPO:-}"
  if [[ -z "$forge_repo" && -n "$repo_owner" && -n "$repo_name" ]]; then
    forge_repo="$repo_owner/$repo_name"
  fi
  local reopen_label="${REPOLENS_REOPEN_LABEL:-repolens:reopen-candidate}"

  # Build a flat list of (cluster_id, idx, type, issue_number, body) tuples.
  local tuples manifest_tuples preserved_tuples verification_json
  manifest_tuples=""
  preserved_tuples=""
  verification_json='[]'
  if [[ -f "$manifest" ]]; then
    manifest_tuples="$(jq -r '
      to_entries[]
      | .key as $i
      | .value.cluster_id as $cid
      | (.value.cross_link_actions // [])
      | to_entries[]
      | [$cid, .key, .value.type, (.value.issue_number | tostring), (.value.body | tojson | @base64)]
      | @tsv
    ' "$manifest" 2>/dev/null)" || manifest_tuples=""
  fi
  if [[ -f "$verification" ]]; then
    verification_json="$(jq -c '.' "$verification" 2>/dev/null)" || verification_json='[]'
  fi
  if [[ -f "$preserved_actions" ]]; then
    preserved_tuples="$(jq -r --argjson verification "$verification_json" '
      def wrong_only_paths($v):
        ([ $v[]? | select(.status == "WRONG") | .source_finding_path // empty ] | unique) as $wrong
        | [ $v[]? | select(.status != "WRONG") | .source_finding_path // empty ] as $notwrong
        | $wrong
        | map(. as $p | select(($notwrong | index($p)) == null));
      wrong_only_paths($verification) as $wrong_only
      | to_entries[]
      | .value as $action
      | (($action.source_finding_paths // []) | length) as $path_count
      | ([($action.source_finding_paths // [])[] | . as $path | select(($wrong_only | index($path)) != null)] | length) as $wrong_count
      | select(($path_count == 0) or ($wrong_count != $path_count))
      | [.value.cluster_id, .key, .value.type, (.value.issue_number | tostring), (.value.body | tojson | @base64)]
      | @tsv
    ' "$preserved_actions" 2>/dev/null)" || preserved_tuples=""
  fi
  tuples="$manifest_tuples"
  if [[ -n "$preserved_tuples" ]]; then
    tuples="${tuples:+$tuples$'\n'}$preserved_tuples"
  fi

  if [[ -z "$tuples" ]]; then
    return 0
  fi

  mkdir -p "$cross_dir" || {
    echo "_filing_cross_link_enact: cannot create cross-link dir: $cross_dir" >&2
    return 0
  }

  # De-duplicate (type, issue_number) across clusters so a comment is posted
  # at most once even when multiple clusters flag the same existing issue.
  local -A seen=()

  local cluster_id action_type issue_number body key sentinel_done sentinel_failed body_file rc
  local evidence reason target response readback title new_number reconcile_done body_json
  while IFS=$'\t' read -r cluster_id _ action_type issue_number body; do
    [[ "$issue_number" =~ ^[1-9][0-9]*$ ]] || continue
    [[ "$cluster_id" =~ ^[A-Za-z0-9_][A-Za-z0-9_.:-]*$ ]] || continue
    case "${CROSS_LINK_MODE:-off}:$action_type" in
      comment:comment|suggest-reopen:comment|suggest-reopen:reopen-suggestion) ;;
      *) continue ;;
    esac

    # Transport the body as base64-encoded JSON so TSV cannot reinterpret
    # backslashes, tabs, CR, or trailing newlines. Decode to a JSON string;
    # only the citation scan uses Bash text, while the payload stays exact.
    if ! body_json="$(jq -en --arg encoded "$body" '$encoded | @base64d | fromjson | select(type == "string" and length > 0 and (contains("\u0000") | not))')"; then
      printf 'VERIFICATION_FAILED: invalid cross-link body\n' > "$cross_dir/$action_type-$issue_number.failed"
      if [[ -e "$cross_dir/$action_type-$issue_number.done" ]]; then
        mv "$cross_dir/$action_type-$issue_number.done" "$cross_dir/$action_type-$issue_number.unverified-done"
        : > "$cross_dir/$action_type-$issue_number.attempted"
      fi
      continue
    fi
    body="$(jq -r . <<< "$body_json")"

    key="${action_type}-${issue_number}"
    if [[ -n "${seen[$key]:-}" ]]; then
      continue
    fi
    seen["$key"]=1

    sentinel_done="$cross_dir/$key.done"
    sentinel_failed="$cross_dir/$key.failed"
    reconcile_done=0
    if [[ -e "$sentinel_done" ]]; then
      mv "$sentinel_done" "$cross_dir/$key.unverified-done" || continue
      : > "$cross_dir/$key.attempted"
      reconcile_done=1
    elif [[ -e "$sentinel_failed" || -e "$cross_dir/$key.attempted" ]]; then
      continue
    fi

    # If the parent cluster failed and has no .url, skip — a comment that
    # references a non-existent new issue is worse than no comment.
    if [[ -n "$cluster_id" && -e "$filed_dir/$cluster_id.failed" && ! -e "$filed_dir/$cluster_id.url" ]]; then
      printf 'cross_link_skipped_parent_failed: cluster=%s key=%s\n' \
        "$cluster_id" "$key" > "$sentinel_failed"
      continue
    fi

    # Comments and reopen suggestions are governed actions too. Require live
    # parent evidence (or self-contained preserved-action citations), a valid
    # target state, and a backend with structured result readback.
    evidence="$(jq -c --arg cid "$cluster_id" '[.[] | select(.cluster_id == $cid)] | .[0] // empty' "$manifest" 2>/dev/null)"
    if [[ -z "$evidence" && -f "$preserved_actions" ]]; then
      evidence="$(jq -c --arg cid "$cluster_id" '[.[] | select(.cluster_id == $cid and (.evidence_body | type == "string"))] | .[0] | select(. != null) | {body:.evidence_body}' "$preserved_actions" 2>/dev/null)"
    fi
    [[ -n "$evidence" ]] || evidence="$(jq -cn --arg body "$body" '{body:$body}')"
    reason=""
    if ! reason="$(filing_verify_cluster_citations "${PROJECT_PATH:-}" "$evidence")" \
        || ! reason="$(branch_scope_verify_body "$(jq -r '.body' <<< "$evidence")")"; then
      printf 'VERIFICATION_FAILED: %s\n' "$reason" > "$sentinel_failed"
      continue
    fi
    if [[ ! "$forge_repo" =~ ^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)+$ ]] \
        || ! forge_filing_capable "$([[ "$action_type" == comment ]] && printf comment || printf create)" \
        || ! target="$(forge_issue_read_json "$forge_repo" "$issue_number")" \
        || ! jq -e --arg type "$action_type" 'if $type == "comment" then .state == "open" else .state == "closed" end' <<< "$target" >/dev/null; then
      printf 'VERIFICATION_FAILED: cross-link target or adapter unavailable\n' > "$sentinel_failed"
      continue
    fi
    # Newly introduced citations in the action itself must also verify.
    if [[ -n "$(repolens_extract_citations "$body")" ]]; then
      if ! reason="$(filing_verify_cluster_citations "${PROJECT_PATH:-}" "$(jq -cn --arg body "$body" '{body:$body}')")" \
          || ! reason="$(branch_scope_verify_body "$body")"; then
        printf 'VERIFICATION_FAILED: %s\n' "$reason" > "$sentinel_failed"
        continue
      fi
    fi
    # Atomic permanent reservation: failures/crashes require reconciliation.
    if (( ! reconcile_done )); then
      ( set -o noclobber; : > "$cross_dir/$key.attempted" ) 2>/dev/null || continue
    fi

    body_file="$cross_dir/$key.body.md"
    jq -jr . <<< "$body_json" > "$body_file" || {
      echo "_filing_cross_link_enact: cannot write body file for $key" >&2
      continue
    }

    rc=0
    case "$action_type" in
      comment)
        if [[ -z "$forge_repo" ]]; then
          echo "_filing_cross_link_enact: FORGE_REPO unset; skipping comment on #$issue_number" >&2
          rc=1
        elif declare -F forge_issue_comment_once >/dev/null 2>&1; then
          if (( reconcile_done )); then
            response="$(cat "$cross_dir/$key.created-response" 2>/dev/null)" || rc=1
          else
            response="$(forge_issue_comment_once "$forge_repo" "$issue_number" "$body_file" 2>>"$cross_dir/$key.log")" || rc=$?
            printf '%s\n' "$response" > "$cross_dir/$key.created-response"
          fi
          if (( rc == 0 )); then
            readback="$(forge_issue_comment_read_json "$forge_repo" "$issue_number" "$response")" || rc=$?
            jq -e --rawfile body "$body_file" --arg url "$response" '.body == $body and .url == $url' <<< "$readback" >/dev/null || rc=1
          fi
        else
          echo "_filing_cross_link_enact: forge_issue_comment unavailable" >&2
          rc=1
        fi
        ;;
      reopen-suggestion)
        if [[ -z "$forge_repo" ]]; then
          echo "_filing_cross_link_enact: FORGE_REPO unset; skipping reopen-suggestion for #$issue_number" >&2
          rc=1
        elif declare -F forge_issue_create_once >/dev/null 2>&1; then
          title="[reopen-candidate] consider re-opening #$issue_number"
          # Prepend a banner so reviewers can see this is a RepoLens-emitted
          # reopen suggestion with the source closed issue called out
          # explicitly in the body.
          local banner_file="$cross_dir/$key.body.banner.md"
          {
            printf '> Generated by RepoLens run %s\n' "${run_id}"
            printf '> Source: closed issue #%s\n\n' "$issue_number"
            cat "$body_file"
            printf '\n\nLabel suggestion: `%s`\n' "$reopen_label"
          } > "$banner_file"
          if (( reconcile_done )); then
            response="$(cat "$cross_dir/$key.created-response" 2>/dev/null)" || rc=1
          else
            response="$(forge_issue_create_once "$forge_repo" "$title" "$banner_file" 2>>"$cross_dir/$key.log")" || rc=$?
            printf '%s\n' "$response" > "$cross_dir/$key.created-response"
          fi
          if (( rc == 0 )); then
            new_number="$(forge_issue_number_from_url "$forge_repo" "$response")" || rc=$?
            readback="$(forge_issue_read_json "$forge_repo" "$new_number")" || rc=$?
            jq -e --arg title "$title" --rawfile body "$banner_file" --arg url "$response" \
              '.title == $title and .body == $body and .url == $url and .state == "open"' <<< "$readback" >/dev/null || rc=1
          fi
        else
          echo "_filing_cross_link_enact: forge_issue_create unavailable" >&2
          rc=1
        fi
        ;;
      *)
        echo "_filing_cross_link_enact: unknown action type '$action_type' for #$issue_number" >&2
        rc=1
        ;;
    esac

    if (( rc == 0 )); then
      rm -f "$cross_dir/$key.unverified-done"
      : > "$sentinel_done"
    else
      printf 'rc=%d action=%s issue=%s\n' "$rc" "$action_type" "$issue_number" \
        > "$sentinel_failed"
      echo "_filing_cross_link_enact: $action_type on #$issue_number failed (rc=$rc), continuing" >&2
    fi
  done <<< "$tuples"

  return 0
}

# dispatch_filing_batch <run_id>
#   Consumes logs/<run-id>/final/manifest.json and fans out one filing
#   governor per cluster, in parallel. The deterministic governor owns .url/.failed transitions;
#   .attempted and atomic reservations prevent repeating ambiguous POSTs.
#
#   Per-cluster state machine for each manifest entry:
#     1. .url present                            -> SKIP (Skipped-existing)
#     2. .failed present                         -> terminal, do not retry
#     3. .lock present, mtime <= STALE_LOCK_TIMEOUT -> SKIP (in flight)
#     4. otherwise                               -> take/refresh .lock and
#                                                   spawn callback
#
#   Returns:
#     0  on completion (whether or not individual callbacks succeeded;
#        callback failures are reflected in the absence of .url/.failed
#        markers and counted in the aggregate output).
#     1  on infrastructure failure: invalid manifest, failed process-scope
#        initialization/launch/cleanup, or a missing callback outcome.
#
#   Aggregate output on stdout:
#     Filed: X, Verification-failed: Y, Skipped-existing: Z
#       Filed             = clusters that ended this run with .url and
#                           did not have .url at start.
#       Verification-failed = clusters whose final state is .failed.
#       Skipped-existing  = clusters with pre-existing .url at start.
#
#   Environment overrides:
#     STALE_LOCK_TIMEOUT  Seconds before a .lock is treated as crashed.
#                         Default 3600.
#     PARALLEL            Concurrent filing only when true. Default false;
#                         also honors an explicit pre-run sequential fallback.
#     MAX_PARALLEL        Max concurrent filing callbacks when parallel. Default 8.
#     LOG_BASE            Override the run log base directory.
#     _FILING_AGENT_CALLBACK
#                         Function name invoked per cluster. Defaults to
#                         _filing_real_agent. Tests inject a stub.
dispatch_filing_batch() {
  local run_id="${1:-}"
  if [[ -z "$run_id" ]]; then
    echo "dispatch_filing_batch: missing run_id" >&2
    return 1
  fi

  local log_base manifest final_dir filed_dir stale_lock_timeout
  log_base="$(_filing_log_base "$run_id")"
  manifest="$log_base/final/manifest.json"
  final_dir="$log_base/final"
  filed_dir="$final_dir/filed"
  stale_lock_timeout="${STALE_LOCK_TIMEOUT:-3600}"
  if [[ ! "$stale_lock_timeout" =~ ^[0-9]+$ ]]; then
    stale_lock_timeout=3600
  fi

  if [[ ! -f "$manifest" ]]; then
    echo "dispatch_filing_batch: manifest missing: $manifest" >&2
    return 1
  fi
  if [[ ! -s "$manifest" ]]; then
    echo "dispatch_filing_batch: manifest empty: $manifest" >&2
    return 1
  fi
  if ! jq -e . "$manifest" >/dev/null 2>&1; then
    echo "dispatch_filing_batch: manifest is not valid JSON: $manifest" >&2
    return 1
  fi
  if ! jq -e 'type == "array"' "$manifest" >/dev/null 2>&1; then
    echo "dispatch_filing_batch: manifest top-level is not an array: $manifest" >&2
    return 1
  fi

  if ! jq -e 'all(.[]; (.cluster_id | type == "string" and test("^[A-Za-z0-9_][A-Za-z0-9_.:-]*$")))
    and (([.[].cluster_id] | unique | length) == length)' "$manifest" >/dev/null 2>&1; then
    echo "dispatch_filing_batch: invalid or duplicate cluster ids" >&2
    return 1
  fi

  local entry_count
  entry_count="$(jq 'length' "$manifest")"
  if (( entry_count == 0 )); then
    mkdir -p "$filed_dir" || {
      echo "dispatch_filing_batch: cannot create filed dir: $filed_dir" >&2
      return 1
    }
    if [[ "${CROSS_LINK_MODE:-off}" != "off" ]]; then
      _filing_cross_link_enact "$run_id" || true
    fi
    printf 'Filed: 0, Verification-failed: 0, Skipped-existing: 0\n'
    return 0
  fi

  mkdir -p "$filed_dir" || {
    echo "dispatch_filing_batch: cannot create filed dir: $filed_dir" >&2
    return 1
  }

  local -a cluster_ids=()
  local cid
  while IFS= read -r cid; do
    [[ -n "$cid" ]] || continue
    cluster_ids+=("$cid")
  done < <(jq -r '.[].cluster_id' "$manifest")

  local -A pre_existing_url=()
  local -a to_dispatch=()
  local skipped_existing=0
  local age

  for cid in "${cluster_ids[@]}"; do
    if [[ -e "$filed_dir/$cid.url" && "${_FILING_AGENT_CALLBACK:-_filing_real_agent}" == _filing_real_agent ]]; then
      _filing_real_agent "$run_id" "$cid" >/dev/null 2>&1 || {
        _filing_fail "$filed_dir" "$cid" 'success marker could not be reconciled'
      }
    fi
    if [[ -e "$filed_dir/$cid.url" ]]; then
      pre_existing_url["$cid"]=1
      skipped_existing=$((skipped_existing + 1))
      continue
    fi
    if [[ -e "$filed_dir/$cid.failed" || -e "$filed_dir/$cid.attempted" ]]; then
      # Terminal failure state. Do not retry within this dispatcher
      # invocation; operator must rm the .failed marker to retry.
      continue
    fi
    if [[ -e "$filed_dir/$cid.lock" ]]; then
      age="$(_filing_lock_age "$filed_dir/$cid.lock")"
      if (( age <= stale_lock_timeout )); then
        # Owned by another in-flight worker; skip this cluster.
        continue
      fi
      # Stale lock: fall through and retake.
    fi
    : > "$filed_dir/$cid.lock" || {
      echo "dispatch_filing_batch: failed to take lock for $cid" >&2
      continue
    }
    to_dispatch+=("$cid")
  done

  local dispatch_rc=0 wait_rc=0 recorded_failure=0 dispatched_count=0 pending
  local callback="${_FILING_AGENT_CALLBACK:-_filing_real_agent}"
  if (( ${#to_dispatch[@]} > 0 )); then
    if ${PARALLEL:-false}; then
      if ! declare -F init_parallel >/dev/null 2>&1 \
        || ! declare -F spawn_lens >/dev/null 2>&1 \
        || ! declare -F wait_all >/dev/null 2>&1; then
        echo "dispatch_filing_batch: parallel lifecycle unavailable (source lib/parallel.sh)" >&2
        dispatch_rc=1
      elif ! init_parallel "$log_base/.semaphore" "${MAX_PARALLEL:-8}"; then
        echo "dispatch_filing_batch: parallel initialization failed" >&2
        dispatch_rc=1
      else
        for cid in "${to_dispatch[@]}"; do
          if ! spawn_lens "$cid" "$callback" "$run_id" "$cid"; then
            echo "dispatch_filing_batch: parallel launch failed for $cid" >&2
            dispatch_rc=1
            if declare -F _cleanup_children >/dev/null 2>&1; then
              _cleanup_children || true
            fi
            break
          fi
          dispatched_count=$((dispatched_count + 1))
        done
        wait_all || wait_rc=$?
        if [[ "${_REPOLENS_SCOPE_FAILED:-0}" == 1 ]]; then
          # The caller captures dispatcher output in a subshell, so globals do
          # not propagate; this exit status must preserve terminal scope failure.
          echo "dispatch_filing_batch: terminal process-scope cleanup failure" >&2
          dispatch_rc=1
          if declare -F _cleanup_children >/dev/null 2>&1; then
            _cleanup_children || true
          fi
        elif (( wait_rc != 0 )); then
          # A governed per-cluster rejection is a recorded result. Every other
          # wait failure is infrastructure failure, including one after .url.
          for cid in "${to_dispatch[@]:0:$dispatched_count}"; do
            if [[ -e "$filed_dir/$cid.failed" ]]; then recorded_failure=1;
            elif [[ ! -e "$filed_dir/$cid.url" ]]; then dispatch_rc=1; fi
          done
          (( recorded_failure == 1 )) || dispatch_rc=1
        fi
      fi
    else
      # Sequential defaults and pre-run fallback never probe or launch scopes.
      for cid in "${to_dispatch[@]}"; do
        dispatched_count=$((dispatched_count + 1))
        if ! "$callback" "$run_id" "$cid"; then
          if [[ ! -e "$filed_dir/$cid.failed" ]]; then
            echo "dispatch_filing_batch: callback failed without a recorded outcome for $cid" >&2
            dispatch_rc=1
            break
          fi
        fi
      done
    fi
    # Only undispatched reservations are released; live/failed scopes retain
    # their own diagnostics and locks until their lifecycle is reconciled.
    for pending in "${to_dispatch[@]:$dispatched_count}"; do
      rm -f "$filed_dir/$pending.lock"
    done
  fi

  local filed=0 vfailed=0
  for cid in "${cluster_ids[@]}"; do
    if [[ -n "${pre_existing_url[$cid]:-}" ]]; then
      continue
    fi
    if [[ -e "$filed_dir/$cid.url" ]]; then
      filed=$((filed + 1))
    elif [[ -e "$filed_dir/$cid.failed" ]]; then
      vfailed=$((vfailed + 1))
    fi
  done

  # Cross-links run only after lifecycle infrastructure settled successfully.
  if (( dispatch_rc == 0 )) && [[ "${CROSS_LINK_MODE:-off}" != "off" ]]; then
    _filing_cross_link_enact "$run_id" || true
  fi

  printf 'Filed: %d, Verification-failed: %d, Skipped-existing: %d\n' \
    "$filed" "$vfailed" "$skipped_existing"
  return "$dispatch_rc"
}
