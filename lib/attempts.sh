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

# RepoLens — per-invocation attempt record (issue #371).
#
# A run lives at `logs/<run-id>/` and survives `--resume` by reusing the SAME
# dir. Completion state persists in append-only root or per-round lens receipts,
# but nothing records the SEPARATE invocations ("attempts") that touched the
# run: when each pass started/stopped, why it stopped, or how many lenses it
# completed. This module writes that audit trail to
# `logs/<run-id>/attempts.json` — a JSON array, one entry appended per
# invocation (fresh start OR `--resume`).
#
# Two functions:
#   attempts_begin <log_base>                       — called once near run-id
#       resolution; records started_at + a baseline lens-receipt count to a
#       transient `.attempt-start` marker.
#   attempts_finalize <log_base> <status> <why> <exit_code>
#       — appends one attempt entry atomically (temp file + mv).
#
# Each attempt entry (issue #375 enriched the #371 base for triage):
#   attempt_id                    monotonic 1-based int (= array length + 1)
#   started_at                    UTC +%Y-%m-%dT%H:%M:%SZ (.attempt-start marker)
#   finished_at                   UTC +%Y-%m-%dT%H:%M:%SZ (at finalize)
#   status                        REPOLENS_FINAL_STATE: finished / finished-empty
#                                 / failed / interrupted / rate-limit-pending
#   why_stopped                   the stopped_reason from summary.json, or a
#                                 sentinel fallback (rate-limit / agent-no-progress
#                                 / systemic-failure / interrupted-<signal>), or ""
#   lenses_completed_this_attempt lenses completed during THIS attempt (delta =
#                                 current lens-receipt count - baseline at
#                                 attempts_begin), clamped at >= 0. Answers "what
#                                 did THIS pass complete", which a cumulative
#                                 snapshot cannot.
#   lenses_completed_total        cumulative lens-receipt count at finalize —
#                                 "how far is the WHOLE run", across all attempts.
#   exit_code                     the process exit code this attempt is about to
#                                 exit with, as a JSON number; null when no exit
#                                 code is passed (e.g. a finalize that predates
#                                 the exit-code resolution).
#
# The write is additive and strictly non-fatal: every failure path logs a
# warning and returns 0 so an attempts-write failure never changes the run's
# exit code. Guarded by `command -v jq`. A corrupt/unparseable attempts.json is
# NEVER reset to [] (that would silently drop prior attempts) — we warn and
# skip the append instead. Pattern mirrors lib/result_pointer.sh (#308).

# _attempts_completed_count <log_base> — count lens receipts across the run.
# Single-round work uses .completed; multi-round work uses one
# .rounds/round-N.lenses.completed file per round. The same lens in two rounds
# is two investigations. Round barrier markers are not lens receipts.
# Absent/unreadable files contribute 0; always prints a non-negative integer.
_attempts_completed_count() {
  local log_base="$1" completed_file count receipt_fd total=0
  for completed_file in "$log_base/.completed" "$log_base"/.rounds/round-*.lenses.completed; do
    [[ -f "$completed_file" ]] || continue
    # Count only terminated receipts, under the writer's inode lock. A repaired
    # tail is new completed work, not part of a resumed attempt's baseline.
    count="$(
      exec {receipt_fd}<"$completed_file" || exit 1
      flock -s "$receipt_fd" || exit 1
      wc -l < "$completed_file"
    )" 2>/dev/null || count=0
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    total=$(( total + count ))
  done
  printf '%s' "$total"
}

# attempts_begin <log_base> — record the start of this invocation. Writes a
# transient `.attempt-start` marker (key=value lines, like the .rate-limit-*
# markers) capturing started_at and the baseline lens-receipt count so
# attempts_finalize can compute the per-attempt lenses-completed delta. On a
# fresh run no receipt files exist yet (they are created later), so the baseline
# is correctly 0; on a resume it reflects work done by earlier attempts.
#
# Side effects: creates/overwrites <log_base>/.attempt-start. Strictly
# non-fatal — returns 0 on every path.
attempts_begin() {
  local log_base="${1:-}"
  [[ -n "$log_base" ]] || return 0

  local started_at baseline marker tmp
  started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '')"
  baseline="$(_attempts_completed_count "$log_base")"
  marker="$log_base/.attempt-start"
  tmp="${marker}.tmp.${BASHPID}"

  mkdir -p "$log_base" 2>/dev/null || true

  if {
    printf 'started_at=%s\n' "$started_at"
    printf 'baseline_completed=%s\n' "$baseline"
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$marker" 2>/dev/null; then
    return 0
  fi

  rm -f "$tmp" 2>/dev/null
  log_warn "attempts: cannot write start marker in $log_base; lenses_completed may be inaccurate"
  return 0
}

# attempts_finalize <log_base> <status> <why_stopped> <exit_code> — append one
# attempt entry to <log_base>/attempts.json atomically (temp file in <log_base>
# + mv). An optional 5th argument selects the current invocation's fixed
# attempt_id: append that slot or reconcile the last entry in place. The caller
# retains .attempt-start until reconciliation finishes, then removes it.
#
# Reads started_at + baseline_completed from the .attempt-start marker written
# by attempts_begin (fallbacks: started_at="", baseline 0 if absent). attempt_id
# is the current array length + 1; lenses_completed_this_attempt is the
# per-attempt delta, lenses_completed_total is the cumulative lens-receipt count.
# exit_code is recorded as a JSON number when numeric, else null (the 4th arg is
# optional so a caller that does not know the exit code records null).
#
# Side effects: creates/extends <log_base>/attempts.json; removes the
# .attempt-start marker on success. Never aborts the caller — returns 0 on every
# path; warnings go to log_warn.
attempts_finalize() {
  local log_base="${1:-}" status="${2:-finished}" why_stopped="${3:-}" exit_code="${4:-}"

  if [[ -z "$log_base" ]]; then
    log_warn "attempts: no log_base provided; skipping attempt record"
    return 0
  fi

  if ! command -v jq >/dev/null 2>&1; then
    log_warn "attempts: jq not available; skipping attempt record"
    return 0
  fi

  # Read the start marker (started_at + baseline). Tolerate a missing marker so
  # a finalize that somehow skipped attempts_begin still records an entry.
  local marker started_at="" baseline=0 key value
  marker="$log_base/.attempt-start"
  if [[ -f "$marker" ]]; then
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
      case "$key" in
        started_at) started_at="$value" ;;
        baseline_completed) baseline="$value" ;;
      esac
    done < "$marker"
  fi
  [[ "$baseline" =~ ^[0-9]+$ ]] || baseline=0

  local finished_at
  finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '')"

  # Existing array: read it ONLY if attempts.json exists AND parses. If it
  # exists but is invalid JSON, warn and bail WITHOUT clobbering (do not reset
  # to [] — that would silently drop prior attempts).
  local dest existing="[]"
  dest="$log_base/attempts.json"
  if [[ -f "$dest" ]]; then
    if ! existing="$(jq -e 'if type == "array" then . else error("not an array") end' "$dest" 2>/dev/null)"; then
      log_warn "attempts: $dest is not a valid JSON array; skipping append to avoid data loss"
      return 0
    fi
  fi

  local attempt_id current_id="${5:-}"
  attempt_id="$(printf '%s' "$existing" | jq 'length + 1' 2>/dev/null || printf '')"
  if [[ ! "$attempt_id" =~ ^[1-9][0-9]*$ ]]; then
    log_warn "attempts: cannot determine the next attempt id; skipping record"
    return 0
  fi
  if [[ -n "$current_id" ]]; then
    # Only the new slot or the last slot may be written. Earlier history
    # is immutable; main reserves this invocation's slot before the first write.
    if [[ ! "$current_id" =~ ^[1-9][0-9]*$ ]] \
        || (( current_id != attempt_id && current_id != attempt_id - 1 )); then
      log_warn "attempts: current attempt slot changed; skipping record to avoid data loss"
      return 0
    fi
    attempt_id="$current_id"
  fi

  # lenses_completed_this_attempt = work done during THIS attempt (current -
  # baseline), clamped at >= 0 defensively. lenses_completed_total = the same
  # cumulative current_completed count, recorded so consumers don't have to read
  # receipt files separately.
  local current_completed lenses_completed
  current_completed="$(_attempts_completed_count "$log_base")"
  lenses_completed=$(( current_completed - baseline ))
  (( lenses_completed < 0 )) && lenses_completed=0

  # exit_code -> JSON number when numeric, else JSON null (the field is always
  # present so consumers can rely on its shape).
  local exit_code_json='null'
  [[ "$exit_code" =~ ^[0-9]+$ ]] && exit_code_json="$exit_code"

  # Atomic write: temp file inside log_base (same filesystem) + mv. A
  # non-writable log_base makes mktemp fail and we bail non-fatally.
  local tmp
  tmp="$(mktemp "$log_base/.attempts.json.tmp.XXXXXX" 2>/dev/null)" || {
    log_warn "attempts: cannot create temp file in $log_base; skipping attempt record"
    return 0
  }

  if ! printf '%s' "$existing" | jq \
      --argjson attempt_id "$attempt_id" \
      --arg started_at "$started_at" \
      --arg finished_at "$finished_at" \
      --arg status "$status" \
      --arg why_stopped "$why_stopped" \
      --argjson lenses_completed_this_attempt "$lenses_completed" \
      --argjson lenses_completed_total "$current_completed" \
      --argjson exit_code "$exit_code_json" \
      '.[($attempt_id - 1)] = {
        attempt_id: $attempt_id,
        started_at: $started_at,
        finished_at: $finished_at,
        status: $status,
        why_stopped: $why_stopped,
        lenses_completed_this_attempt: $lenses_completed_this_attempt,
        lenses_completed_total: $lenses_completed_total,
        exit_code: $exit_code
      }' > "$tmp" 2>/dev/null; then
    log_warn "attempts: failed to build JSON; skipping attempt record"
    rm -f "$tmp" 2>/dev/null
    return 0
  fi

  if ! mv -f "$tmp" "$dest" 2>/dev/null; then
    log_warn "attempts: failed to write $dest; skipping attempt record"
    rm -f "$tmp" 2>/dev/null
    return 0
  fi

  # Tidy the transient marker; the next attempts_begin overwrites it anyway.
  if [[ -z "$current_id" ]]; then rm -f "$marker" 2>/dev/null; fi

  return 0
}
