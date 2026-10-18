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
# shellcheck source=lib/locking.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/locking.sh"

# Sourceable callers may use the filing governor without the parallel library.
_filing_cancelled() {
  [[ "${REPOLENS_FINAL_STATE:-finished}" == interrupted ]]
}

# Reserve a possible creation under a shared run lock, immediately before POST.
# Attempts survive ambiguous failures and cap changes. Comments never enter this
# budget. Return 2 for deferral, 1 for an accounting/reservation failure.
_filing_reserve_issue_attempt() {
  local filed_dir="$1" marker="$2"
  with_file_lock "$filed_dir/.issue-budget.lock" "${REPOLENS_SUMMARY_LOCK_TIMEOUT:-30}" \
    _filing_reserve_issue_attempt_locked "$filed_dir" "$marker"
}

_filing_reserve_issue_attempt_locked() {
  local filed_dir="$1" marker="$2" path key
  local cap="${MAX_ISSUES:-}" used="${GLOBAL_ISSUES_CREATED:-0}"
  local -A reservations=()
  # Count each operation once, including old/quarantined successes whose
  # permanent attempt marker may predate the governor.
  for path in "$filed_dir"/*.attempted "$filed_dir"/*.url "$filed_dir"/*.unverified-url \
      "$filed_dir"/cross-link/reopen-suggestion-*.attempted \
      "$filed_dir"/cross-link/reopen-suggestion-*.done \
      "$filed_dir"/cross-link/reopen-suggestion-*.unverified-done; do
    [[ -e "$path" || -L "$path" ]] || continue
    key="${path%.*}"
    reservations["$key"]=1
  done
  [[ "$used" =~ ^[0-9]+$ ]] || return 1
  used=$((used + ${#reservations[@]}))
  if [[ -n "$cap" ]]; then
    [[ "$cap" =~ ^[1-9][0-9]*$ ]] || return 1
    (( used < cap )) || return 2
  fi
  ( set -o noclobber; : > "$marker" ) 2>/dev/null
}

# Count only matching successful receipts, including reopen-suggestion issues.
# Reattest even historical receipts omitted from a regenerated manifest;
# quarantined markers retain their budget reservation but drop out of totals.
# Unique URLs describe actual creations even if two records reference one URL.
# Call in the signal-receiving parent to support cancellation. Cancellation
# returns the signal code with no count and never quarantines an in-flight read.
filing_verified_issue_count() {
  local run_id="$1" filed_dir marker prefix url entry number readback
  local verified_urls="" rc=0
  filed_dir="$(_filing_log_base "$run_id")/final/filed"
  local repo="${FORGE_REPO:-${REPO_OWNER:-}/${REPO_NAME:-}}"
  for marker in "$filed_dir"/*.url; do
    _filing_cancelled && return "${REPOLENS_INTERRUPT_EXIT_CODE:-130}"
    [[ -e "$marker" || -L "$marker" ]] || continue
    prefix="${marker%.url}"
    if [[ ! -f "$marker" || -L "$marker" \
        || ! -f "$prefix.request.json" || -L "$prefix.request.json" \
        || -L "$prefix.readback.json" ]] \
        || ! url="$(cat "$marker")" \
        || ! entry="$(cat "$prefix.request.json")" \
        || ! number="$(forge_issue_number_from_url "$repo" "$url")" \
        || _filing_cancelled \
        || ! readback="$(forge_issue_read_json "$repo" "$number")" \
        || ! _filing_readback_matches "$entry" "$url" "$number" "$readback"; then
      _filing_cancelled && return "${REPOLENS_INTERRUPT_EXIT_CODE:-130}"
      _filing_fail "$filed_dir" "${prefix##*/}" 'saved creation receipt could not be reconciled'
      rc=1
      continue
    fi
    _filing_cancelled && return "${REPOLENS_INTERRUPT_EXIT_CODE:-130}"
    printf '%s\n' "$readback" > "$prefix.readback.json" || rc=1
    verified_urls+="$url"$'\n'
  done
  for marker in "$filed_dir"/cross-link/reopen-suggestion-*.done; do
    _filing_cancelled && return "${REPOLENS_INTERRUPT_EXIT_CODE:-130}"
    [[ -e "$marker" || -L "$marker" ]] || continue
    prefix="${marker%.done}"
    if [[ ! -f "$marker" || -L "$marker" \
        || -L "$prefix.readback.json" \
        || ! -f "$prefix.created-response" || -L "$prefix.created-response" \
        || ! -f "$prefix.body.banner.md" || -L "$prefix.body.banner.md" ]] \
        || ! url="$(cat "$prefix.created-response")" \
        || ! number="$(forge_issue_number_from_url "$repo" "$url")" \
        || _filing_cancelled \
        || ! readback="$(forge_issue_read_json "$repo" "$number")" \
        || ! jq -e --arg url "$url" --argjson number "$number" \
          --arg title "[reopen-candidate] consider re-opening #${prefix##*/reopen-suggestion-}" \
          --rawfile body "$prefix.body.banner.md" \
          '.url == $url and .number == $number and .title == $title and .body == $body and .state == "open"' \
          <<< "$readback" >/dev/null; then
      _filing_cancelled && return "${REPOLENS_INTERRUPT_EXIT_CODE:-130}"
      if ! _filing_cross_link_fail "$marker" "$prefix.failed" \
          'VERIFICATION_FAILED: saved creation receipt could not be reconciled'; then
        _filing_cancelled && return "${REPOLENS_INTERRUPT_EXIT_CODE:-130}"
        return 1
      fi
      rc=1
      continue
    fi
    _filing_cancelled && return "${REPOLENS_INTERRUPT_EXIT_CODE:-130}"
    printf '%s\n' "$readback" > "$prefix.readback.json" || rc=1
    verified_urls+="$url"$'\n'
  done
  _filing_cancelled && return "${REPOLENS_INTERRUPT_EXIT_CODE:-130}"
  printf '%s' "$verified_urls" | LC_ALL=C sort -u | wc -l | tr -d '[:space:]'
  return "$rc"
}

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

  # The shared extractor preserves complete paths and formatted citations.
  # A malformed list is a body-level failure, even with another valid anchor.
  local citations
  if ! citations="$(repolens_extract_citations "$body")"; then
    printf 'malformed citation list in body\n'
    return 1
  fi

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
    if ! line_count="$(wc -l <"$file_path" | tr -d ' ')"; then
      printf '%s could not read source line count\n' "$citation"
      return 1
    fi
    # Treat a final line without a trailing newline as a real line, but never
    # interpret missing/partial output from a failed read as source evidence.
    # Numeric bytes distinguish a literal space from an empty file.
    local last_byte
    if ! last_byte="$(tail -c 1 "$file_path" | od -An -tu1 | tr -d '[:space:]')"; then
      printf '%s could not read source final byte\n' "$citation"
      return 1
    fi
    if [[ -n "$last_byte" && "$last_byte" != 10 ]]; then
      line_count=$((line_count + 1))
    fi
    if (( lstart > line_count )) || (( lend > line_count )); then
      printf '%s line exceeds file length (%d lines)\n' "$citation" "$line_count"
      return 1
    fi

    # Verify the snippet attached to every occurrence of this citation.
    local snippets
    if ! snippets="$(repolens_citation_snippets "$body" "$citation")"; then
      printf 'could not bind citation snippets\n'
      return 1
    fi
    if [[ -n "$snippets" ]]; then
      context_start=$(( lstart - 20 ))
      (( context_start < 1 )) && context_start=1
      context_end=$(( lend + 20 ))
      (( context_end > line_count )) && context_end=$line_count
      if ! snippet_pattern="$(sed -n "${context_start},${context_end}p" "$file_path")"; then
        printf '%s could not read source snippet\n' "$citation"
        return 1
      fi
      while IFS= read -r snippet; do
        if [[ "$snippet_pattern" != *"$snippet"* ]]; then
          printf '%s snippet not found near cited line\n' "$citation"
          return 1
        fi
      done <<< "$snippets"
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
  local open_issues duplicate created_url number readback label reserve_rc scope_rc
  _filing_cancelled && return 1
  log_base="$(_filing_log_base "$run_id")"
  local filed_dir="$log_base/final/filed"
  [[ "$cluster_id" =~ ^[A-Za-z0-9_][A-Za-z0-9_.:-]*$ ]] || return 1
  mkdir -p "$filed_dir" || return 1
  # An atomic per-cluster directory protects direct callers and dispatchers
  # racing on an expired legacy .lock marker. A crash leaves this reservation
  # for operator reconciliation, never an automatic repeat of a possible POST.
  mkdir "$filed_dir/$cluster_id.governor" 2>/dev/null || return 1
  rm -f "$filed_dir/$cluster_id.deferred"
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
  if reason="$(branch_scope_verify_body "$(jq -r '.body' <<< "$entry")")"; then
    :
  else
    scope_rc=$?
    if (( scope_rc != 1 )); then
      # No POST has been admitted. Keep saved receipts and pending work retryable.
      rm -f "$filed_dir/$cluster_id.lock"
      rmdir "$filed_dir/$cluster_id.governor"
      printf 'filing: %s; retry after scope repair\n' "$reason" >&2
      return 2
    fi
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
    local receipt_valid=1
    created_url="$(cat "$filed_dir/$cluster_id.url")"
    if [[ -L "$filed_dir/$cluster_id.url" || -L "$filed_dir/$cluster_id.request.json" ]] \
        || ! jq -e --argjson entry "$entry" '. == $entry' "$filed_dir/$cluster_id.request.json" >/dev/null 2>&1 \
        || ! number="$(forge_issue_number_from_url "$repo" "$created_url")" \
        || _filing_cancelled \
        || ! readback="$(forge_issue_read_json "$repo" "$number")" \
        || ! _filing_readback_matches "$entry" "$created_url" "$number" "$readback"; then
      receipt_valid=0
    fi
    # Cancellation is not evidence that a previously verified receipt is bad.
    # Release only this invocation's governor so a normal resume can retry.
    if _filing_cancelled; then
      rmdir "$filed_dir/$cluster_id.governor"
      return 1
    fi
    if (( receipt_valid == 0 )); then
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
  # Validated duplicates and invalid drafts never reserve creation capacity.
  # This marker also guards uncapped runs against repeating ambiguous POSTs.
  reserve_rc=0
  _filing_reserve_issue_attempt "$filed_dir" "$filed_dir/$cluster_id.attempted" || reserve_rc=$?
  if (( reserve_rc == 2 )); then
    printf 'BUDGET_DEFERRED: new-issue limit %s reached\n' "$MAX_ISSUES" > "$filed_dir/$cluster_id.deferred"
    rm -f "$filed_dir/$cluster_id.lock" "$body_file"
    rmdir "$filed_dir/$cluster_id.governor"
    return 0
  elif (( reserve_rc != 0 )); then
    _filing_fail "$filed_dir" "$cluster_id" 'unable to reserve new-issue budget'
    return 1
  fi
  for label in "${labels[@]}"; do
    if [[ "${FORGE_PROVIDER:-}" == gh ]]; then
      GH_HOST="$(_forge_gh_filing_host)" forge_label_create "$label" ededed "$repo" >> "$filed_dir/$cluster_id.log" 2>&1 || true
    else
      forge_label_create "$label" ededed "$repo" >> "$filed_dir/$cluster_id.log" 2>&1 || true
    fi
  done
  # The attempt is already reserved; ambiguous transport failures are terminal.
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

# Quarantine an invalid ordinary receipt and record its failure. Cancellation
# restores saved success; a permanent attempt guard protects failed rollback.
# Release read-only governors on storage failure so retained receipts can resume.
_filing_fail() {
  local filed_dir="$1" cluster_id="$2" reason="$3" move_rc=0
  # Interrupted preflight helpers cannot invalidate a saved success receipt.
  # This governor belongs to read-only reconciliation, so release it for resume.
  if _filing_cancelled && [[ -e "$filed_dir/$cluster_id.url" || -L "$filed_dir/$cluster_id.url" ]]; then
    rmdir "$filed_dir/$cluster_id.governor" 2>/dev/null || true
    return 1
  fi
  if [[ -e "$filed_dir/$cluster_id.url" || -L "$filed_dir/$cluster_id.url" ]]; then
    # Historical successes may predate attempt markers. Reserve the completed
    # POST before quarantine so a failed rollback can never admit another one.
    if ! : > "$filed_dir/$cluster_id.attempted"; then
      rmdir "$filed_dir/$cluster_id.governor" 2>/dev/null || true
      return 1
    fi
    if _filing_cancelled; then
      rmdir "$filed_dir/$cluster_id.governor" 2>/dev/null || true
      return 1
    fi
    # A quarantine marker is an exact file, never a container for the receipt.
    # Exact-path replacement also refuses a directory created after this guard.
    if [[ -d "$filed_dir/$cluster_id.unverified-url" || -L "$filed_dir/$cluster_id.unverified-url" ]]; then
      rmdir "$filed_dir/$cluster_id.governor" 2>/dev/null || true
      return 1
    fi
    _branch_scope_replace_file "$filed_dir/$cluster_id.url" "$filed_dir/$cluster_id.unverified-url" || move_rc=$?
    # The returning parent handler may accept cancellation while mv waits.
    # Restore a completed rename before leaving this receipt for resume.
    if _filing_cancelled; then
      if [[ ! -e "$filed_dir/$cluster_id.url" && ! -L "$filed_dir/$cluster_id.url" ]] \
          && [[ -e "$filed_dir/$cluster_id.unverified-url" || -L "$filed_dir/$cluster_id.unverified-url" ]]; then
        _branch_scope_replace_file "$filed_dir/$cluster_id.unverified-url" "$filed_dir/$cluster_id.url" || return 1
      fi
      rmdir "$filed_dir/$cluster_id.governor" 2>/dev/null || true
      return 1
    fi
    if (( move_rc != 0 )); then
      # No POST runs during saved-receipt verification. Let resume reattest a
      # receipt whose rename failed instead of stranding its read-only governor.
      rmdir "$filed_dir/$cluster_id.governor" 2>/dev/null || true
      return 1
    fi
  fi
  printf 'VERIFICATION_FAILED: %s\n' "$reason" > "$filed_dir/$cluster_id.failed"
  rm -f "$filed_dir/$cluster_id.lock" "$filed_dir/$cluster_id.governor/body.md"
  rmdir "$filed_dir/$cluster_id.governor" 2>/dev/null || true
}

# Invalidate a saved cross-link receipt only after a completed failure.
# A cancellation leaves the original receipt and its payload available for resume.
_filing_cross_link_fail() {
  local done_file="$1" result_file="$2" reason="$3" move_rc=0
  _filing_cancelled && return 1
  if [[ -e "$done_file" || -L "$done_file" ]]; then
    # Reserve the already completed POST before any marker move, including crashes.
    : > "${done_file%.done}.attempted" || return 1
    _filing_cancelled && return 1
    if [[ -d "${done_file%.done}.unverified-done" || -L "${done_file%.done}.unverified-done" ]]; then
      return 1
    fi
    _branch_scope_replace_file "$done_file" "${done_file%.done}.unverified-done" || move_rc=$?
    # A returning handler may run while mv waits for its child. Even a failed
    # command can have completed the rename before reporting interruption.
    if _filing_cancelled; then
      if [[ ! -e "$done_file" && ! -L "$done_file" ]] \
          && [[ -e "${done_file%.done}.unverified-done" || -L "${done_file%.done}.unverified-done" ]]; then
        _branch_scope_replace_file "${done_file%.done}.unverified-done" "$done_file" || return 1
      fi
      return 1
    fi
    (( move_rc == 0 )) || return 1
  fi
  printf '%s\n' "$reason" > "$result_file"
}

# Promote verified saved payloads together, retaining originals until both
# renames complete without cancellation. Restore even an absent historical raw
# body on failure. If rollback itself fails, keep its backup for reconciliation.
_filing_cross_link_promote_payload() {
  local prefix="$1" body_candidate="$2" banner_candidate="$3"
  local backup i rc=0 restore_rc=0
  local -a candidates=() targets=()
  if [[ -n "$banner_candidate" ]]; then
    candidates+=("$banner_candidate")
    targets+=("$prefix.body.banner.md")
  fi
  candidates+=("$body_candidate")
  targets+=("$prefix.body.md")
  backup="$(mktemp -d "$prefix.body.md.reconcile.XXXXXX")" || return 1
  mkdir "$backup/originals" || { rmdir "$backup"; return 1; }
  for i in "${!targets[@]}"; do
    if [[ -e "${targets[$i]}" || -L "${targets[$i]}" ]]; then
      cp -pP "${targets[$i]}" "$backup/originals/$i" || {
        rm -rf -- "$backup"
        return 1
      }
    fi
  done
  if _filing_cancelled; then
    rm -rf -- "$backup"
    return 1
  fi
  for i in "${!targets[@]}"; do
    mv "${candidates[$i]}" "${targets[$i]}" || rc=1
    if (( rc != 0 )) || _filing_cancelled; then
      rc=1
      break
    fi
  done
  if (( rc != 0 )); then
    for i in "${!targets[@]}"; do
      if [[ -e "$backup/originals/$i" || -L "$backup/originals/$i" ]]; then
        mv "$backup/originals/$i" "${targets[$i]}" || restore_rc=1
      else
        rm -f "${targets[$i]}" || restore_rc=1
      fi
    done
  fi
  if (( restore_rc != 0 )); then
    echo "_filing_cross_link_promote_payload: restore failed; originals retained under $backup" >&2
    return 1
  fi
  rm -rf -- "$backup"
  return "$rc"
}

# Emit complete whitespace tokens carrying bare file/line-shaped references.
# This is only a classifier: the shared extractor decides supported grammar.
_filing_action_reference_candidates() {
  awk '
    # Mask equal-length backtick runs, allowing shorter runs inside a span.
    # Excluded snippets must neither expose references nor join path bytes.
    function mask_spans(value, result, start, width, tail, offset, run, content, path) {
      result = ""
      while (match(value, /`+/)) {
        start = RSTART
        width = RLENGTH
        result = result substr(value, 1, start - 1)
        tail = substr(value, start + width)
        offset = 0
        while (match(tail, /`+/)) {
          run = RLENGTH
          offset += RSTART + run - 1
          tail = substr(tail, RSTART + run)
          if (run == width) break
        }
        if (run != width) return result substr(value, start)
        content = substr(value, start + width, offset - width)
        path = content
        sub(/:[0-9]+(-[0-9]+)?$/, "", path)
        # Keep recognized quoted members opaque and valid for list parsing.
        # This placeholder is only classified, never used as live evidence.
        if (content ~ /^[^`]+:[0-9]+(-[0-9]+)?$/ &&
            path !~ /:\/\// && path !~ /^[0-9:]+$/)
          result = result "`quoted:1`"
        else result = result "@"
        value = substr(value, start + width + offset)
        run = 0
      }
      return result value
    }
    # Match delimiters across the complete body so multiline excluded spans
    # cannot expose their inner text as independent action references.
    { body = body $0 "\n" }
    END {
      value = mask_spans(body)
      gsub(/[[:alpha:]][[:alnum:]+.-]*:\/\/[^[:space:]<>`]+/, "@", value)
      count = split(value, tokens, /[[:space:]]+/)
      for (i = 1; i <= count; i++) {
        members = split(tokens[i], parts, /[,;]/)
        found = 0
        for (j = 1; j <= members; j++) {
          token = parts[j]
          gsub(/^[([{\042\047*_<>]+|[])}.\042\047:!?*_<>]+$/, "", token)
          if (token ~ /^[0-9][0-9:\/.TtZz+-]*$/ ||
              tolower(token) ~ /^[0-9][0-9]?\/(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)\/[0-9][0-9][0-9][0-9]:[0-9:.z+-]+$/) continue
          if (token ~ /[\/.][^[:space:]]*:[0-9]+(-[0-9]+)?/ ||
              token ~ /(^|[^A-Za-z0-9_.\/-])(Makefile|Dockerfile|Containerfile|Jenkinsfile|LICENSE|README|Gemfile|Rakefile|Procfile):[0-9]+/)
            found = 1
        }
        if (found) print tokens[i]
      }
    }
  ' <<< "$1"
}

# _filing_cross_link_enact <run_id>
#   Iterate every manifest entry's cross_link_actions[] and enact them via
#   the forge layer. Idempotent: each (type, issue_number) pair is keyed by
#   type-issue_number sentinel under final/filed/cross-link/, so re-running
#   the dispatcher does not repeat a POST.
#
#   Per-action state machine for each cross-link entry:
#     1. <key>.done present     -> preserve receipt and payload while re-attesting;
#                                quarantine only a completed validation failure
#     2. .failed or .attempted  -> SKIP (requires operator reconciliation)
#     3. otherwise             -> verify evidence, adapter, target and body;
#                                dedup new reopen suggestions against one
#                                fresh open-issue snapshot per enact pass;
#                                reserve and attempt unmatched actions
#   Lookup failures are cached for the pass and fail closed. Dedup precedes
#   budget reservation. Verified readback writes .done; failure writes .failed.
#
#   Ordinary action failures are best-effort and logged to stderr. Parent
#   cancellation stops admission and makes the enclosing dispatch fail. A failed
#   saved-receipt quarantine also fails the dispatch.
#
#   Required globals: FORGE_REPO (or REPO_OWNER+REPO_NAME).
#   Optional globals: REPOLENS_REOPEN_LABEL (defaults "repolens:reopen-candidate").
#
#   Cross-link actions on a cluster whose own filing failed
#   (<cid>.failed present, no <cid>.url) are skipped; deferred parents without
#   a .url defer their actions, avoiding references to a non-existent issue.
_filing_cross_link_enact() {
  _filing_cancelled && return 1
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

  local cluster_id action_type issue_number body key sentinel_done sentinel_failed body_file rc scope_rc
  local evidence reason target response readback title new_number reconcile_done body_json reserve_rc action_citations
  local open_issues duplicate open_issues_status=unfetched
  while IFS=$'\t' read -r cluster_id _ action_type issue_number body; do
    _filing_cancelled && return 1
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
      _filing_cross_link_fail "$cross_dir/$action_type-$issue_number.done" \
        "$cross_dir/$action_type-$issue_number.failed" 'VERIFICATION_FAILED: invalid cross-link body' || return 1
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
    rm -f "$cross_dir/$key.deferred"
    reconcile_done=0
    if [[ -e "$sentinel_done" ]]; then
      # Keep the saved success during read-only reattestation. Its permanent
      # attempt marker prevents a repeated POST if later invalidation is interrupted.
      : > "$cross_dir/$key.attempted" || return 1
      reconcile_done=1
    elif [[ -e "$sentinel_failed" || -e "$cross_dir/$key.attempted" ]]; then
      continue
    fi

    # If the parent cluster failed and has no .url, skip — a comment that
    # references a non-existent new issue is worse than no comment.
    if [[ -e "$filed_dir/$cluster_id.deferred" && ! -e "$filed_dir/$cluster_id.url" ]]; then
      _filing_cross_link_fail "$sentinel_done" "$cross_dir/$key.deferred" \
        "BUDGET_DEFERRED: parent cluster $cluster_id deferred" || return 1
      continue
    fi
    if [[ -n "$cluster_id" && -e "$filed_dir/$cluster_id.failed" && ! -e "$filed_dir/$cluster_id.url" ]]; then
      _filing_cross_link_fail "$sentinel_done" "$sentinel_failed" \
        "cross_link_skipped_parent_failed: cluster=$cluster_id key=$key" || return 1
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
    if ! reason="$(filing_verify_cluster_citations "${PROJECT_PATH:-}" "$evidence")"; then
      _filing_cross_link_fail "$sentinel_done" "$sentinel_failed" "VERIFICATION_FAILED: $reason" || return 1
      continue
    fi
    scope_rc=0
    reason="$(branch_scope_verify_body "$(jq -r '.body' <<< "$evidence")")" || scope_rc=$?
    (( scope_rc <= 1 )) || return 2
    if (( scope_rc == 1 )); then
      _filing_cross_link_fail "$sentinel_done" "$sentinel_failed" "VERIFICATION_FAILED: $reason" || return 1
      continue
    fi
    if [[ ! "$forge_repo" =~ ^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)+$ ]] \
        || ! forge_filing_capable "$([[ "$action_type" == comment ]] && printf comment || printf create)" \
        || _filing_cancelled \
        || ! target="$(forge_issue_read_json "$forge_repo" "$issue_number")" \
        || ! jq -e --arg type "$action_type" 'if $type == "comment" then .state == "open" else .state == "closed" end' <<< "$target" >/dev/null; then
      _filing_cross_link_fail "$sentinel_done" "$sentinel_failed" 'VERIFICATION_FAILED: cross-link target or adapter unavailable' || return 1
      continue
    fi
    # Newly introduced citations in the action itself must also verify.
    if ! action_citations="$(repolens_extract_citations "$body")"; then
      _filing_cross_link_fail "$sentinel_done" "$sentinel_failed" 'VERIFICATION_FAILED: malformed citation list in body' || return 1
      continue
    fi
    # Classification covers every action, including mixed valid/unsupported
    # references. Candidates never replace the original validation body.
    local action_reference_candidates action_reference candidate_citations
    if ! action_reference_candidates="$(_filing_action_reference_candidates "$body")"; then
      _filing_cross_link_fail "$sentinel_done" "$sentinel_failed" 'VERIFICATION_FAILED: action citation classification failed' || return 1
      continue
    fi
    local unsupported_reference=0
    while IFS= read -r action_reference; do
      [[ -n "$action_reference" ]] || continue
      if ! candidate_citations="$(repolens_extract_citations "$action_reference" | sed '/^quoted:1$/d')"; then
        _filing_cross_link_fail "$sentinel_done" "$sentinel_failed" 'VERIFICATION_FAILED: action citation classification failed' || return 1
        unsupported_reference=1
        break
      fi
      if [[ -z "$candidate_citations" ]]; then
        _filing_cross_link_fail "$sentinel_done" "$sentinel_failed" 'VERIFICATION_FAILED: unsupported action citation; quote the complete path' || return 1
        unsupported_reference=1
        break
      fi
    done <<< "$action_reference_candidates"
    (( unsupported_reference )) && continue
    if [[ -n "$action_citations" ]]; then
      if ! reason="$(filing_verify_cluster_citations "${PROJECT_PATH:-}" "$(jq -cn --arg body "$body" '{body:$body}')")"; then
        _filing_cross_link_fail "$sentinel_done" "$sentinel_failed" "VERIFICATION_FAILED: $reason" || return 1
        continue
      fi
      scope_rc=0
      reason="$(branch_scope_verify_body "$body")" || scope_rc=$?
      (( scope_rc <= 1 )) || return 2
      if (( scope_rc == 1 )); then
        _filing_cross_link_fail "$sentinel_done" "$sentinel_failed" "VERIFICATION_FAILED: $reason" || return 1
        continue
      fi
    fi
    if [[ "$action_type" == reopen-suggestion ]]; then
      title="[reopen-candidate] consider re-opening #$issue_number"
    fi
    # A reopen suggestion files a new issue with a deterministic title. Fetch
    # a fresh open-issue snapshot at the first eligible new reopen action,
    # independent of the parent governor's lookup, and reuse it for this pass.
    # Exact-title matching suppresses candidates present in that snapshot;
    # local sentinels cannot deduplicate across runs. Another writer's candidate
    # created after the snapshot can be missed by a later action in this pass.
    # This check/create path does not guarantee repository-wide uniqueness.
    # Lookup failures are also cached. The adapter fails closed
    # (an error or truncated result never becomes an empty list), and the check
    # runs before budget reservation so a suppressed action never charges
    # MAX_ISSUES. A reconciled .done keeps its saved created-response instead:
    # an ambiguous POST is never retried.
    if [[ "$action_type" == reopen-suggestion ]] && (( ! reconcile_done )); then
      if [[ "$open_issues_status" == unfetched ]]; then
        if open_issues="$(forge_issue_list_json "$forge_repo" open)"; then
          open_issues_status=ready
        else
          open_issues_status=failed
        fi
      fi
      if [[ "$open_issues_status" == failed ]]; then
        _filing_cross_link_fail "$sentinel_done" "$sentinel_failed" 'VERIFICATION_FAILED: fresh reopen-candidate dedup query failed' || return 1
        continue
      fi
      duplicate="$(jq -r --arg title "$title" '
        [.[] | select(.state == "open") | select(.title == $title)]
        | .[0].number // empty' <<< "$open_issues")"
      if [[ -n "$duplicate" ]]; then
        _filing_cross_link_fail "$sentinel_done" "$sentinel_failed" "DEDUP_HIT: #$duplicate" || return 1
        continue
      fi
    fi
    _filing_cancelled && return 1
    # Atomic permanent reservation: failures/crashes require reconciliation.
    if (( ! reconcile_done )); then
      if [[ "$action_type" == reopen-suggestion ]]; then
        reserve_rc=0
        _filing_reserve_issue_attempt "$filed_dir" "$cross_dir/$key.attempted" || reserve_rc=$?
        if (( reserve_rc == 2 )); then
          _filing_cross_link_fail "$sentinel_done" "$cross_dir/$key.deferred" "BUDGET_DEFERRED: new-issue limit $MAX_ISSUES reached" || return 1
          continue
        elif (( reserve_rc != 0 )); then
          _filing_cross_link_fail "$sentinel_done" "$sentinel_failed" 'VERIFICATION_FAILED: unable to reserve new-issue budget' || return 1
          continue
        fi
      else
        ( set -o noclobber; : > "$cross_dir/$key.attempted" ) 2>/dev/null || continue
      fi
    fi

    body_file="$cross_dir/$key.body.md"
    local reconcile_body_file="" reconcile_banner_file=""
    if (( reconcile_done )); then
      reconcile_body_file="$(mktemp "$body_file.reconcile.XXXXXX")" || return 1
      body_file="$reconcile_body_file"
    fi
    jq -jr . <<< "$body_json" > "$body_file" || {
      echo "_filing_cross_link_enact: cannot write body file for $key" >&2
      [[ -z "$reconcile_body_file" ]] || rm -f "$reconcile_body_file"
      if _filing_cancelled; then
        # No POST was attempted by this pass. Preserve older receipts that
        # still require reconciliation, but release a fresh unsent action.
        if (( ! reconcile_done )); then
          rm -f "$cross_dir/$key.attempted" "$body_file"
        fi
        return 1
      fi
      _filing_cross_link_fail "$sentinel_done" "$sentinel_failed" 'VERIFICATION_FAILED: unable to write cross-link body' || return 1
      continue
    }

    if (( reconcile_done )) && _filing_cancelled; then
      rm -f "$reconcile_body_file"
      return 1
    fi
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
            if _filing_cancelled; then
              # This reservation belongs to an action that never reached POST.
              rm -f "$cross_dir/$key.attempted" "$body_file"
              return 1
            fi
            response="$(forge_issue_comment_once "$forge_repo" "$issue_number" "$body_file" 2>>"$cross_dir/$key.log")" || rc=$?
            printf '%s\n' "$response" > "$cross_dir/$key.created-response"
          fi
          if (( rc == 0 )); then
            # Reading a saved response can deliver a pending parent signal.
            if _filing_cancelled; then
              [[ -z "$reconcile_body_file" ]] || rm -f "$reconcile_body_file"
              return 1
            fi
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
          # Prepend a banner so reviewers can see this is a RepoLens-emitted
          # reopen suggestion with the source closed issue called out
          # explicitly in the body.
          local banner_file="$cross_dir/$key.body.banner.md"
          if (( reconcile_done )); then
            reconcile_banner_file="$(mktemp "$banner_file.reconcile.XXXXXX")" || {
              rm -f "$reconcile_body_file"
              return 1
            }
            banner_file="$reconcile_banner_file"
          fi
          {
            printf '> Generated by RepoLens run %s\n' "${run_id}" &&
            printf '> Source: closed issue #%s\n\n' "$issue_number" &&
            cat "$body_file" &&
            printf '\n\nLabel suggestion: %s\n' "\`$reopen_label\`"
          } > "$banner_file" || rc=1
          if _filing_cancelled; then
            if (( reconcile_done )); then
              rm -f "$reconcile_body_file" "$reconcile_banner_file"
            else
              # Banner generation may have failed before the pre-POST check.
              rm -f "$cross_dir/$key.attempted" "$body_file" "$banner_file"
            fi
            return 1
          fi
          if (( rc == 0 )); then
            if (( reconcile_done )); then
              response="$(cat "$cross_dir/$key.created-response" 2>/dev/null)" || rc=1
            else
              if _filing_cancelled; then
                rm -f "$cross_dir/$key.attempted" "$body_file" "$banner_file"
                return 1
              fi
              response="$(forge_issue_create_once "$forge_repo" "$title" "$banner_file" 2>>"$cross_dir/$key.log")" || rc=$?
              printf '%s\n' "$response" > "$cross_dir/$key.created-response"
            fi
            if (( rc == 0 )); then
              if _filing_cancelled; then
                [[ -z "$reconcile_body_file" ]] || rm -f "$reconcile_body_file" "$reconcile_banner_file"
                return 1
              fi
              new_number="$(forge_issue_number_from_url "$forge_repo" "$response")" || rc=$?
              # URL parsing is another command-substitution signal boundary.
              if _filing_cancelled; then
                [[ -z "$reconcile_body_file" ]] || rm -f "$reconcile_body_file" "$reconcile_banner_file"
                return 1
              fi
              if (( rc == 0 )); then
                readback="$(forge_issue_read_json "$forge_repo" "$new_number")" || rc=$?
                jq -e --arg title "$title" --rawfile body "$banner_file" --arg url "$response" \
                  '.title == $title and .body == $body and .url == $url and .state == "open"' <<< "$readback" >/dev/null || rc=1
              fi
            fi
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

    if (( reconcile_done )); then
      if _filing_cancelled; then
        rm -f "$reconcile_body_file" ${reconcile_banner_file:+"$reconcile_banner_file"}
        return 1
      fi
      if (( rc == 0 )); then
        _filing_cross_link_promote_payload "$cross_dir/$key" "$reconcile_body_file" "$reconcile_banner_file" || rc=1
      fi
      rm -f "$reconcile_body_file" ${reconcile_banner_file:+"$reconcile_banner_file"}
      _filing_cancelled && return 1
    fi
    if (( rc == 0 )); then
      printf '%s\n' "$readback" > "$cross_dir/$key.readback.json" || continue
      rm -f "$cross_dir/$key.unverified-done"
      : > "$sentinel_done"
    else
      _filing_cross_link_fail "$sentinel_done" "$sentinel_failed" "rc=$rc action=$action_type issue=$issue_number" || return 1
      echo "_filing_cross_link_enact: $action_type on #$issue_number failed (rc=$rc), continuing" >&2
    fi
  done <<< "$tuples"

  _filing_cancelled && return 1
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
#     1  on parent cancellation or infrastructure failure: invalid manifest,
#        failed process-scope initialization/launch/cleanup, or a missing
#        callback outcome, or failed saved-receipt quarantine.
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
  _filing_cancelled && return 1
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

  # Deferrals describe this dispatch's selected work. Removed/disabled actions
  # must not carry a stale budget-stop status into a resumed run. Permanent
  # attempts and creation receipts remain intact for budget reconciliation.
  rm -f -- "$filed_dir"/cross-link/*.deferred || return 1

  local entry_count
  entry_count="$(jq 'length' "$manifest")"
  if (( entry_count == 0 )); then
    mkdir -p "$filed_dir" || {
      echo "dispatch_filing_batch: cannot create filed dir: $filed_dir" >&2
      return 1
    }
    if ! _filing_cancelled && [[ "${CROSS_LINK_MODE:-off}" != "off" ]]; then
      local cross_link_rc=0
      _filing_cross_link_enact "$run_id" || cross_link_rc=$?
      if (( cross_link_rc != 0 )); then
        echo "dispatch_filing_batch: cross-link enactment failed (rc=$cross_link_rc)" >&2
        return 1
      fi
    fi
    _filing_cancelled && return 1
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

  # The sequential CLI signal handlers return during this read-only phase so
  # cancellation can release the current governor and undispatched locks.
  # Bash dynamic scope restores the flag on every return from this function.
  local _REPOLENS_FILING_RECONCILING=1 admission_rc=0
  for cid in "${cluster_ids[@]}"; do
    _filing_cancelled && break
    if [[ -e "$filed_dir/$cid.url" && "${_FILING_AGENT_CALLBACK:-_filing_real_agent}" == _filing_real_agent ]]; then
      local reconcile_rc=0
      _filing_real_agent "$run_id" "$cid" >/dev/null 2>&1 || reconcile_rc=$?
      if (( reconcile_rc == 2 )); then admission_rc=1; break; fi
      if (( reconcile_rc != 0 )); then
        _filing_cancelled && break
        if ! _filing_fail "$filed_dir" "$cid" 'success marker could not be reconciled'; then
          # A retained receipt is pending reconciliation, not verified success.
          # Stop before callbacks/cross-links and release queued reservations.
          echo "dispatch_filing_batch: saved receipt quarantine failed for $cid" >&2
          admission_rc=1
          break
        fi
      fi
    fi
    _filing_cancelled && break
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
  if (( admission_rc != 0 )) || _filing_cancelled; then
    for pending in "${to_dispatch[@]}"; do
      rm -f "$filed_dir/$pending.lock"
    done
    return 1
  fi
  _REPOLENS_FILING_RECONCILING=0
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
          # Preserve terminal scope failure in the dispatcher result.
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
        if _filing_cancelled; then dispatch_rc=1; break; fi
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
    _filing_cancelled && dispatch_rc=1
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
  if (( dispatch_rc == 0 )) && ! _filing_cancelled && [[ "${CROSS_LINK_MODE:-off}" != "off" ]]; then
    local cross_link_rc=0
    _filing_cross_link_enact "$run_id" || cross_link_rc=$?
    if (( cross_link_rc != 0 )); then
      echo "dispatch_filing_batch: cross-link enactment failed (rc=$cross_link_rc)" >&2
      dispatch_rc=1
    fi
  fi
  _filing_cancelled && dispatch_rc=1

  printf 'Filed: %d, Verification-failed: %d, Skipped-existing: %d\n' \
    "$filed" "$vfailed" "$skipped_existing"
  return "$dispatch_rc"
}
