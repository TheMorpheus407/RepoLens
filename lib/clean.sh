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

# RepoLens — run-directory retention (`repolens clean`) and per-lens
# iteration-file gzip.
#
# Two independent concerns live here:
#   1. compress_lens_iterations — called from the run loop after a lens
#      finishes, to gzip old forensic iteration-*.txt captures.
#   2. clean_command / maybe_auto_clean — the `repolens clean` subcommand and
#      the opt-in startup auto-retention prune.
#
# Safety is the whole point of this module. `clean` DELETES directories, so the
# selector is strictly positive: it only ever touches a direct child of logs/
# whose name is a genuine run id AND that carries summary.json or status.json.
# AutoDev state (logs/issues/, logs/auto-develop/) and partial dirs are
# excluded by construction. Resume candidates and live runs are skipped.

# A RepoLens run id: UTC timestamp + random suffix, e.g. 20260528T073531Z-3815430a.
# The timestamp prefix is the real discriminator (it excludes AutoDev dirs like
# logs/issues and logs/auto-develop); the suffix is matched loosely as
# alphanumeric so the selector is not tied to the exact random-token encoding.
_CLEAN_RUN_ID_REGEX='^[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9]+$'

# clean_usage — print `repolens.sh clean` help. Side effects: writes stdout.
clean_usage() {
  cat <<'EOF'
Usage: repolens.sh clean [OPTIONS]

Remove old RepoLens run directories under logs/. Only genuine run dirs (a
run-id-named child of logs/ carrying summary.json or status.json) are ever
considered — AutoDev state and partial directories are never touched. Runs
that are resume candidates (incomplete) or currently live are kept.

Options:
  --older-than <dur>   Remove runs older than this age. Suffix d/h/m for
                       days/hours/minutes, or a bare number of seconds.
                       (default: 30d)
  --keep-last <n>      Always protect the N most recent runs, regardless of
                       age. (default: 50)
  --keep-incomplete    Keep resume-candidate runs (running/interrupted/failed,
                       a non-null stopped_reason, or an abort sentinel). This
                       is ON by default; the flag is accepted for clarity.
  --remove-incomplete  Opposite of --keep-incomplete: also remove resume
                       candidates that are otherwise eligible.
  --dry-run            Print the run ids that would be removed; delete nothing.
  --force              Skip the confirmation prompt.
  -h, --help           Show this help.
EOF
}

# _clean_parse_duration <spec> — echo the duration in seconds, or empty on a
# malformed spec. Accepts Nd / Nh / Nm suffixes or a bare integer (seconds).
_clean_parse_duration() {
  local spec="$1" num unit
  [[ -n "$spec" ]] || return 0
  if [[ "$spec" =~ ^([0-9]+)([dhms]?)$ ]]; then
    num="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
    case "$unit" in
      d) printf '%s' "$(( num * 86400 ))" ;;
      h) printf '%s' "$(( num * 3600 ))" ;;
      m) printf '%s' "$(( num * 60 ))" ;;
      s|"") printf '%s' "$num" ;;
    esac
  fi
}

# _clean_dir_mtime <dir> — echo the directory mtime in epoch seconds (0 on
# failure). Used as the age basis for retention.
_clean_dir_mtime() {
  local dir="$1" mtime
  mtime="$(stat -c %Y "$dir" 2>/dev/null || stat -f %m "$dir" 2>/dev/null || printf '0')"
  [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
  printf '%s' "$mtime"
}

# _clean_json_string_value_without_jq <file> <key> — best-effort extractor for
# compact RepoLens JSON when jq is unavailable. It is intentionally narrow: the
# fallback below only uses it for status.json.state and stopped_reason.
_clean_json_string_value_without_jq() {
  local file="$1" key="$2" line value
  [[ -f "$file" ]] || return 1
  line="$(tr '\n' ' ' < "$file" 2>/dev/null || true)"
  if [[ "$line" =~ \"$key\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then
    value="${BASH_REMATCH[1]}"
    printf '%s' "$value"
    return 0
  fi
  return 1
}

# _clean_json_key_is_null_without_jq <file> <key> — return 0 when a compact JSON
# key is explicitly null. Used only as a no-jq safety fallback.
_clean_json_key_is_null_without_jq() {
  local file="$1" key="$2" line
  [[ -f "$file" ]] || return 1
  line="$(tr '\n' ' ' < "$file" 2>/dev/null || true)"
  [[ "$line" =~ \"$key\"[[:space:]]*:[[:space:]]*null([^A-Za-z0-9_]|$) ]]
}

# _clean_is_run_dir <dir> — return 0 iff <dir> is a genuine RepoLens run dir:
# a run-id-shaped name with summary.json or status.json present.
_clean_is_run_dir() {
  local dir="$1" name
  [[ -d "$dir" ]] || return 1
  name="${dir##*/}"
  [[ "$name" =~ $_CLEAN_RUN_ID_REGEX ]] || return 1
  [[ -f "$dir/summary.json" || -f "$dir/status.json" ]] || return 1
  return 0
}

# _clean_is_incomplete <dir> — return 0 iff the run is a resume candidate that
# --keep-incomplete should protect: status.json.state in
# {running,interrupted,failed}, a non-null summary.json.stopped_reason, or an
# abort sentinel file.
_clean_is_incomplete() {
  local dir="$1" state stopped

  if [[ -e "$dir/.rate-limit-abort" || -e "$dir/.systemic-failure-abort" \
        || -e "$dir/.agent-no-progress-abort" ]]; then
    return 0
  fi

  if command -v jq >/dev/null 2>&1; then
    if [[ -f "$dir/status.json" ]]; then
      state="$(jq -r '.state // empty' "$dir/status.json" 2>/dev/null)"
      case "$state" in
        running|interrupted|failed) return 0 ;;
      esac
    fi
    if [[ -f "$dir/summary.json" ]]; then
      stopped="$(jq -r '.stopped_reason // empty' "$dir/summary.json" 2>/dev/null)"
      [[ -n "$stopped" ]] && return 0
    fi
  else
    if [[ -f "$dir/status.json" ]]; then
      state="$(_clean_json_string_value_without_jq "$dir/status.json" "state")"
      case "$state" in
        running|interrupted|failed) return 0 ;;
        finished|finished-empty) ;;
        *) return 0 ;;
      esac
    fi
    if [[ -f "$dir/summary.json" ]]; then
      stopped="$(_clean_json_string_value_without_jq "$dir/summary.json" "stopped_reason")"
      [[ -n "$stopped" ]] && return 0
      if ! _clean_json_key_is_null_without_jq "$dir/summary.json" "stopped_reason"; then
        return 0
      fi
    fi
  fi

  return 1
}

# _clean_is_locked <dir> — return 0 iff a live process currently holds the
# run's .repolens.flock. Age and state cannot detect a long-running active run
# whose mtime is old, so we probe the lock directly.
_clean_is_locked() {
  local dir="$1"
  local lock_file="$dir/.repolens.flock" fd
  command -v flock >/dev/null 2>&1 || return 1
  [[ -e "$lock_file" ]] || return 1
  [[ ! -L "$lock_file" && -f "$lock_file" ]] || return 1
  if ! exec {fd}<>"$lock_file" 2>/dev/null; then
    return 1
  fi
  if flock -n "$fd"; then
    flock -u "$fd" 2>/dev/null || true
    exec {fd}>&- 2>/dev/null || true
    return 1
  fi
  exec {fd}>&- 2>/dev/null || true
  return 0
}

# clean_command [OPTIONS] — the `repolens clean` subcommand. Removes eligible
# old run dirs. Side effects: deletes directories under logs/ (unless
# --dry-run), writes stdout. Returns 0 on success, non-zero on usage/removal
# failure.
clean_command() {
  local older_than="30d" keep_last="50" keep_incomplete="true"
  local dry_run="false" force="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --older-than)
        older_than="${2:-}"; shift 2 2>/dev/null || shift ;;
      --older-than=*)
        older_than="${1#*=}"; shift ;;
      --keep-last)
        keep_last="${2:-}"; shift 2 2>/dev/null || shift ;;
      --keep-last=*)
        keep_last="${1#*=}"; shift ;;
      --keep-incomplete)
        keep_incomplete="true"; shift ;;
      --remove-incomplete)
        keep_incomplete="false"; shift ;;
      --dry-run)
        dry_run="true"; shift ;;
      --force|-f|-y)
        force="true"; shift ;;
      -h|--help)
        clean_usage; return 0 ;;
      *)
        echo "clean: unknown option: $1" >&2
        clean_usage >&2
        return 1 ;;
    esac
  done

  local cutoff_seconds
  cutoff_seconds="$(_clean_parse_duration "$older_than")"
  if [[ -z "$cutoff_seconds" ]]; then
    echo "clean: invalid --older-than value: $older_than" >&2
    return 1
  fi
  if [[ ! "$keep_last" =~ ^[0-9]+$ ]]; then
    echo "clean: invalid --keep-last value: $keep_last" >&2
    return 1
  fi

  local logs_dir="${SCRIPT_DIR:-.}/logs"
  if [[ ! -d "$logs_dir" ]]; then
    echo "clean: no logs directory at $logs_dir — nothing to do."
    return 0
  fi

  local now cutoff
  now="$(date -u +%s)"
  cutoff=$(( now - cutoff_seconds ))

  # Gather genuine run dirs paired with their mtime, newest first.
  local dir mtime
  local -a runs=()
  for dir in "$logs_dir"/*; do
    _clean_is_run_dir "$dir" || continue
    mtime="$(_clean_dir_mtime "$dir")"
    runs+=("$mtime"$'\t'"$dir")
  done

  if (( ${#runs[@]} == 0 )); then
    echo "clean: no run directories to remove."
    return 0
  fi

  local sorted
  sorted="$(printf '%s\n' "${runs[@]}" | sort -t$'\t' -k1,1nr)"

  # Decide what to remove: protect the N newest (--keep-last), keep recent runs
  # (age guard), keep resume candidates (--keep-incomplete), keep live runs.
  local -a to_remove=()
  local idx=0 run_mtime run_dir name
  while IFS=$'\t' read -r run_mtime run_dir; do
    [[ -n "$run_dir" ]] || continue
    idx=$(( idx + 1 ))
    name="${run_dir##*/}"

    # --keep-last: the first `keep_last` entries are the newest; protect them.
    if (( idx <= keep_last )); then
      continue
    fi
    # Age guard: keep runs that are not older than the cutoff.
    if (( run_mtime >= cutoff )); then
      continue
    fi
    # Resume candidates.
    if [[ "$keep_incomplete" == "true" ]] && _clean_is_incomplete "$run_dir"; then
      continue
    fi
    # Live runs.
    if _clean_is_locked "$run_dir"; then
      continue
    fi
    to_remove+=("$run_dir")
  done <<< "$sorted"

  if (( ${#to_remove[@]} == 0 )); then
    echo "clean: nothing to remove (no run older than ${older_than}, beyond --keep-last ${keep_last})."
    return 0
  fi

  if [[ "$dry_run" == "true" ]]; then
    echo "clean: ${#to_remove[@]} run(s) would be removed (dry-run):"
    for run_dir in "${to_remove[@]}"; do
      echo "  would remove: ${run_dir##*/}"
    done
    return 0
  fi

  # Confirm before deleting, unless --force or a non-interactive stdin.
  if [[ "$force" != "true" && -t 0 ]]; then
    echo "clean: about to remove ${#to_remove[@]} run director(ies):"
    for run_dir in "${to_remove[@]}"; do
      echo "  ${run_dir##*/}"
    done
    local reply
    read -r -p "Proceed? [y/N] " reply
    case "$reply" in
      y|Y|yes|YES) ;;
      *) echo "clean: aborted."; return 0 ;;
    esac
  fi

  local removed=0 failed=0
  for run_dir in "${to_remove[@]}"; do
    if rm -rf -- "$run_dir"; then
      echo "  removed: ${run_dir##*/}"
      removed=$(( removed + 1 ))
    else
      echo "  failed to remove: ${run_dir##*/}" >&2
      failed=$(( failed + 1 ))
    fi
  done
  echo "clean: removed ${removed} run director(ies)."
  if (( failed > 0 )); then
    echo "clean: failed to remove ${failed} run director(ies)." >&2
    return 1
  fi
  return 0
}

# maybe_auto_clean — opt-in startup retention prune, gated on
# REPOLENS_AUTO_CLEAN=true. Runs clean_command in the background with --force so
# a live run is never blocked. Retention is configurable via
# REPOLENS_RETENTION_DAYS (default 30) and REPOLENS_KEEP_LAST (default 50).
# Side effects: may spawn a background prune; never fatal.
maybe_auto_clean() {
  [[ "${REPOLENS_AUTO_CLEAN:-false}" == "true" ]] || return 0

  local retention_days="${REPOLENS_RETENTION_DAYS:-30}"
  local keep_last="${REPOLENS_KEEP_LAST:-50}"
  [[ "$retention_days" =~ ^[0-9]+$ ]] || retention_days=30
  [[ "$keep_last" =~ ^[0-9]+$ ]] || keep_last=50

  if declare -F log_info >/dev/null 2>&1; then
    log_info "Startup auto-clean enabled: pruning logs older than ${retention_days}d (keep-last ${keep_last})"
  fi

  (
    clean_command --older-than "${retention_days}d" --keep-last "$keep_last" --force \
      >/dev/null 2>&1
  ) </dev/null &
  return 0
}

# compress_lens_iterations <lens_log_dir> [keep=3] — gzip the forensic
# iteration-*.txt captures in a finished lens dir, keeping the `keep`
# highest-iteration-number files uncompressed. Older ones become
# iteration-*.txt.gz (the plain .txt is removed). Touches nothing else:
# lens-outputs/*.md (read by synth/verify/--resume) and the .envelope.json
# sidecars are left alone. No-op (non-fatal) when gzip is unavailable.
compress_lens_iterations() {
  local lens_dir="$1" keep="${2:-3}"
  [[ -d "$lens_dir" ]] || return 0
  command -v gzip >/dev/null 2>&1 || return 0
  [[ "$keep" =~ ^[0-9]+$ ]] || keep=3

  # Pair each iteration-*.txt with its numeric iteration so we can keep the
  # highest N (a lexical sort would wrongly rank "10" below "2").
  local -a entries=()
  local f base num
  for f in "$lens_dir"/iteration-*.txt; do
    [[ -f "$f" ]] || continue
    base="${f##*/}"
    num="${base#iteration-}"
    num="${num%%-*}"
    [[ "$num" =~ ^[0-9]+$ ]] || continue
    entries+=("$num"$'\t'"$f")
  done

  (( ${#entries[@]} > keep )) || return 0

  local sorted idx=0 ent_path
  sorted="$(printf '%s\n' "${entries[@]}" | sort -t$'\t' -k1,1nr)"
  while IFS=$'\t' read -r _ ent_path; do
    [[ -n "$ent_path" ]] || continue
    idx=$(( idx + 1 ))
    (( idx <= keep )) && continue
    gzip -f -- "$ent_path" 2>/dev/null || true
  done <<< "$sorted"

  return 0
}
