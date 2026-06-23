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

# RepoLens — canonical "latest result" pointer (issue #308).
#
# `logs/` accumulates one `<run-id>/` dir per run with no stable "this is THE
# result" marker; `status_latest_file` only guesses newest-by-mtime. At finalize
# we write a single canonical pointer at the TOP of the logs tree
# (`logs/latest-result.json`) describing the run that just completed, derived
# from its finalized `summary.json` (and `final/manifest.json` if present).
#
# The write is additive and strictly non-fatal: every failure path logs a
# warning and returns 0 so a pointer-write failure never changes the run's exit
# code. Guarded by `command -v jq`.

# _collect_discarded_runs <logs_dir> <run_id> — print a JSON array of the OTHER
# genuine run dirs under <logs_dir> (everything except <run_id>), each as
# {run_id, reason}, where `reason` is derived from the clean.sh predicates:
#
#   _clean_is_locked     -> skip (a live run is not "discarded")
#   _clean_is_incomplete -> "aborted-or-incomplete"
#   no final/manifest.json AND .totals.issues_created == 0 -> "empty"
#   otherwise (a prior complete run)                       -> "superseded"
#
# Cheap by design: stat-level checks plus a single jq read of summary.json per
# run dir, no model calls. Always prints a valid JSON array ([] if there is
# nothing to list, the logs tree is missing/odd, or the _clean_* predicates are
# not sourced) so the caller can feed it straight into --argjson. Guarded by
# `declare -F _clean_is_run_dir` so the unit harness that sources only
# core/logging/result_pointer (not clean.sh) degrades to [] silently.
_collect_discarded_runs() {
  local logs_dir="$1" run_id="$2"

  if ! declare -F _clean_is_run_dir >/dev/null 2>&1 || [[ ! -d "$logs_dir" ]]; then
    printf '[]'
    return 0
  fi

  local _lines="" _d _name _reason _issues
  for _d in "$logs_dir"/*; do
    _clean_is_run_dir "$_d" || continue
    _name="${_d##*/}"
    [[ "$_name" == "$run_id" ]] && continue

    if _clean_is_locked "$_d"; then
      continue                       # live — not a discarded run
    elif _clean_is_incomplete "$_d"; then
      _reason="aborted-or-incomplete"
    else
      _issues=0
      if [[ -f "$_d/summary.json" ]]; then
        _issues="$(jq -r '.totals.issues_created // 0' "$_d/summary.json" 2>/dev/null || printf '0')"
        [[ "$_issues" =~ ^[0-9]+$ ]] || _issues=0
      fi
      if [[ ! -f "$_d/final/manifest.json" && "$_issues" -eq 0 ]]; then
        _reason="empty"
      else
        _reason="superseded"
      fi
    fi

    _lines+="$_name"$'\t'"$_reason"$'\n'
  done

  if [[ -z "$_lines" ]]; then
    printf '[]'
    return 0
  fi

  local _json
  _json="$(printf '%s' "$_lines" \
    | jq -R -n '[inputs | select(length>0) | split("\t") | {run_id: .[0], reason: .[1]}]' 2>/dev/null)"
  [[ -n "$_json" ]] || _json='[]'
  printf '%s' "$_json"
}

# update_latest_symlink <logs_dir> <run_id> — (re)point <logs_dir>/LATEST at
# <run_id> as an ergonomic companion to latest-result.json (issue #313). The
# target is RELATIVE (the run-id only) so the logs tree stays relocatable, and
# the swap is ATOMIC where the platform supports it: build the link under a
# temp name (<logs_dir>/.LATEST.tmp) then `mv -T` it over LATEST (a GNU rename
# over the existing name). On platforms without `mv -T` (BSD/macOS) it falls
# back to `ln -sfn`. A CLOBBER GUARD refuses to touch LATEST if it is a real
# (non-symlink) file or directory — `-e` follows symlinks, so a valid OR
# dangling symlink is repointable, only a genuine file/dir is left alone.
#
# Side effects: creates/replaces <logs_dir>/LATEST; removes any stray
# <logs_dir>/.LATEST.tmp. Strictly non-fatal: every failure path logs a warning
# and returns 0 so a symlink failure never changes the run's exit code.
update_latest_symlink() {
  local logs_dir="$1" run_id="$2"
  local link="$logs_dir/LATEST"
  local tmp="$logs_dir/.LATEST.tmp"

  # Refuse to destroy a real file/dir that happens to sit at logs/LATEST.
  # `-e` follows symlinks, so a valid OR dangling symlink is NOT caught here
  # (dangling => -e false); only a genuine regular file or directory is.
  if [[ -e "$link" && ! -L "$link" ]]; then
    log_warn "LATEST: $link exists as a real file/dir; leaving it untouched"
    return 0
  fi

  # Build the new link under a temp name first (relative target = run-id only).
  rm -f "$tmp" 2>/dev/null
  if ! ln -s "$run_id" "$tmp" 2>/dev/null; then
    log_warn "LATEST: cannot create symlink in $logs_dir (filesystem may not support symlinks); skipping"
    rm -f "$tmp" 2>/dev/null
    return 0
  fi

  # Atomic swap: rename the temp link over LATEST. Prefer GNU `mv -T`, which
  # treats LATEST as a plain name and rename(2)s over it (including an existing
  # symlink-to-dir); plain `mv` would move the temp link *into* such a dir.
  if mv -T "$tmp" "$link" 2>/dev/null; then
    return 0
  fi

  # `mv -T` unavailable (BSD/macOS) or failed: fall back to `ln -sfn`, then make
  # sure no stray temp link is left behind.
  if ln -sfn "$run_id" "$link" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    return 0
  fi

  log_warn "LATEST: failed to point $link at $run_id; leaving previous state"
  rm -f "$tmp" 2>/dev/null
  return 0
}

# write_latest_result_pointer <logs_dir> <run_id> <mode> <agent> \
#     <summary_file> <status> <final_dir>
#
# Writes <logs_dir>/latest-result.json atomically (temp file in <logs_dir> + mv).
# Fields:
#   run_id, mode, agent      — passed through verbatim
#   started_at, finished_at  — summary .started_at / .completed_at (renamed)
#   status                   — passed through (finished/finished-empty/failed/…)
#   findings, manifest       — ABSOLUTE paths under <final_dir> (not created here)
#   counts                   — headline counts by NORMALIZED severity from
#                              <final_dir>/manifest.json if present, else {}
#   discarded_runs           — [{run_id, reason}] for every OTHER genuine run
#                              dir under <logs_dir> (issue #310; see
#                              _collect_discarded_runs)
#
# Side effects: creates/replaces <logs_dir>/latest-result.json. Never aborts the
# caller — returns 0 on every path; warnings go to log_warn.
write_latest_result_pointer() {
  local logs_dir="$1" run_id="$2" mode="$3" agent="$4" summary_file="$5" status="$6" final_dir="$7"

  if ! command -v jq >/dev/null 2>&1; then
    log_warn "latest-result pointer: jq not available; skipping pointer write"
    return 0
  fi

  local started_at="" finished_at=""
  if [[ -f "$summary_file" ]]; then
    started_at="$(jq -r '.started_at // ""' "$summary_file" 2>/dev/null || printf '')"
    finished_at="$(jq -r '.completed_at // ""' "$summary_file" 2>/dev/null || printf '')"
  fi

  local findings_path="$final_dir/findings.jsonl"
  local manifest_path="$final_dir/manifest.json"

  # Headline counts by normalized severity. The manifest is a flat array of
  # finding objects; entries with an unrecognized severity (severity_normalize
  # returns empty) and non-finding objects (no .severity) are skipped.
  local counts_json='{}'
  if [[ -f "$manifest_path" ]]; then
    declare -A _sev_counts=()
    local _sev _norm
    while IFS= read -r _sev; do
      _norm="$(severity_normalize "$_sev")"
      [[ -n "$_norm" ]] || continue
      _sev_counts["$_norm"]=$(( ${_sev_counts["$_norm"]:-0} + 1 ))
    done < <(jq -r 'if type=="array" then .[] else empty end | objects | .severity // empty' "$manifest_path" 2>/dev/null)

    if (( ${#_sev_counts[@]} > 0 )); then
      local _k
      counts_json="$(
        for _k in "${!_sev_counts[@]}"; do
          printf '%s\t%s\n' "$_k" "${_sev_counts[$_k]}"
        done | jq -R -n '[inputs | split("\t") | {(.[0]): (.[1] | tonumber)}] | add // {}' 2>/dev/null
      )"
      [[ -n "$counts_json" ]] || counts_json='{}'
    fi
  fi

  # Sibling run dirs that are not the authoritative result, each classified via
  # clean.sh (issue #310). Always a valid JSON array; [] when nothing to list.
  local discarded_json
  discarded_json="$(_collect_discarded_runs "$logs_dir" "$run_id")"
  [[ -n "$discarded_json" ]] || discarded_json='[]'

  # Atomic write: temp file inside logs_dir (same filesystem) + mv. If logs_dir
  # is not a writable directory the mktemp fails and we bail non-fatally.
  local tmp
  tmp="$(mktemp "$logs_dir/.latest-result.json.tmp.XXXXXX" 2>/dev/null)" || {
    log_warn "latest-result pointer: cannot create temp file in $logs_dir; skipping pointer write"
    return 0
  }

  if ! jq -n \
      --arg run_id "$run_id" \
      --arg mode "$mode" \
      --arg agent "$agent" \
      --arg started_at "$started_at" \
      --arg finished_at "$finished_at" \
      --arg status "$status" \
      --arg findings "$findings_path" \
      --arg manifest "$manifest_path" \
      --argjson counts "$counts_json" \
      --argjson discarded "$discarded_json" \
      '{
        run_id: $run_id,
        mode: $mode,
        agent: $agent,
        started_at: $started_at,
        finished_at: $finished_at,
        status: $status,
        findings: $findings,
        manifest: $manifest,
        counts: $counts,
        discarded_runs: $discarded
      }' > "$tmp" 2>/dev/null; then
    log_warn "latest-result pointer: failed to build JSON; skipping pointer write"
    rm -f "$tmp" 2>/dev/null
    return 0
  fi

  if ! mv -f "$tmp" "$logs_dir/latest-result.json" 2>/dev/null; then
    log_warn "latest-result pointer: failed to write $logs_dir/latest-result.json; skipping pointer write"
    rm -f "$tmp" 2>/dev/null
    return 0
  fi

  # Ergonomic companion to latest-result.json: a relative, atomic LATEST symlink
  # to this run dir (issue #313). Strictly non-fatal — never changes our rc.
  update_latest_symlink "$logs_dir" "$run_id"

  return 0
}
