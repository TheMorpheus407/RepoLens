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

# RepoLens — triage dispatcher and context-pack writer.
#
# Implements the pre-rounds round-0 context pack from issue #171. Composes the
# triage prompt from prompts/_base/triage.md, dispatches the active agent
# exactly once, captures its markdown stdout, truncates the pack to the 2 KB
# budget, and atomically promotes it to
# logs/<run-id>/triage/context-pack.md. The full agent transcript is preserved
# at logs/<run-id>/triage/transcript.txt for forensic recovery.
#
# Triage runs ONCE before run_rounds; on every failure path the dispatcher
# returns non-zero but the orchestrator should treat that as non-fatal: a
# missing context-pack.md means round-1 lenses do their own initial scan.
#
# This module is sourceable; it defines functions only and has no top-level
# side effects beyond loading shared helpers.

# Maximum byte size of the consumable context pack. Anything beyond this is
# truncated by _triage_truncate_pack with a deterministic marker so downstream
# tooling can detect that truncation happened.
TRIAGE_PACK_MAX_BYTES=2048

_triage_repo_root() {
  local source_dir
  source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s' "$(cd "$source_dir/.." && pwd)"
}

_triage_log_base() {
  local run_id="${1:-}"
  if [[ -n "${LOG_BASE:-}" ]]; then
    printf '%s' "$LOG_BASE"
    return 0
  fi
  printf '%s/logs/%s' "$(_triage_repo_root)" "$run_id"
}

# _triage_extract_investigation_seeds <src_path> <dst_path>
#   Parses the `## Investigation seeds` markdown section from <src_path> and
#   writes one cleaned seed per line to <dst_path>. The section is captured
#   from the first `## Investigation seeds` heading (with or without the
#   parenthetical suffix) until the next `## ` heading or EOF.
#
#   Each captured line is sanitized:
#     - leading list markers (`1.`, `2)`, `-`, `*`, `+`) are stripped
#     - surrounding whitespace is trimmed
#     - blank lines, `DONE` markers, and `(none)` placeholders are dropped
#     - duplicate seeds are removed (case-sensitive, first occurrence wins)
#     - embedded control characters (newline, CR, tab) and pipes are
#       collapsed to a single space so they cannot break dispatch parsers
#       downstream
#   The destination file is always created (possibly empty) when the source
#   exists. Returns 0 on success even when no seeds are found.
_triage_extract_investigation_seeds() {
  local src="$1" dst="$2"
  local tmp_dst
  tmp_dst="${dst}.tmp.$$"

  : > "$tmp_dst" || return 1

  if [[ ! -f "$src" ]]; then
    mv "$tmp_dst" "$dst" 2>/dev/null || rm -f "$tmp_dst"
    return 1
  fi

  awk '
    BEGIN { in_seeds = 0 }
    /^##[[:space:]]+Investigation seeds/ {
      in_seeds = 1
      next
    }
    in_seeds && /^##[[:space:]]+/ {
      in_seeds = 0
    }
    in_seeds { print }
  ' "$src" > "$tmp_dst.raw" || {
    rm -f "$tmp_dst" "$tmp_dst.raw"
    return 1
  }

  local -A seen=()
  local raw_line seed
  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    seed="$raw_line"
    seed="${seed//$'\r'/}"
    seed="${seed//$'\t'/ }"
    seed="${seed//|/ }"
    # Trim leading whitespace
    seed="${seed#"${seed%%[![:space:]]*}"}"
    # Strip leading list marker: digits with `.` or `)`, or `-`, `*`, `+`
    if [[ "$seed" =~ ^([0-9]+[\.\)]|[-*+])[[:space:]]+(.*)$ ]]; then
      seed="${BASH_REMATCH[2]}"
    fi
    # Collapse internal whitespace runs to a single space
    seed="$(printf '%s' "$seed" | tr -s '[:space:]' ' ')"
    # Trim leading/trailing whitespace
    seed="${seed#"${seed%%[![:space:]]*}"}"
    seed="${seed%"${seed##*[![:space:]]}"}"

    [[ -z "$seed" ]] && continue
    [[ "$seed" == "DONE" ]] && continue
    [[ "$seed" == "(none)" ]] && continue
    [[ "$seed" == '`' ]] && continue
    if [[ -n "${seen[$seed]:-}" ]]; then
      continue
    fi
    seen["$seed"]=1
    printf '%s\n' "$seed" >> "$tmp_dst"
  done < "$tmp_dst.raw"
  rm -f "$tmp_dst.raw"

  if ! mv "$tmp_dst" "$dst"; then
    rm -f "$tmp_dst"
    return 1
  fi
  return 0
}

# _triage_default_mode_domain_ids <domains_file>
#   Emits, one per line, the IDs of every domain in <domains_file> whose mode
#   is unset or "default" (i.e. the default-mode domains that bugreport runs
#   would otherwise fan out across). Used both to build the {{AVAILABLE_DOMAINS}}
#   prompt menu and to whitelist the agent's relevant-domains output so unknown
#   ids cannot accidentally widen or zero-out the lens list.
_triage_default_mode_domain_ids() {
  local domains_file="$1"
  if [[ ! -f "$domains_file" ]]; then
    return 0
  fi
  jq -r '
    .domains
    | sort_by(.order // 0)
    | map(select(.mode != "discover" and .mode != "deploy" and .mode != "opensource" and .mode != "content" and .mode != "greenfield" and .mode != "polish"))
    | .[].id
  ' "$domains_file" 2>/dev/null || true
}

# _triage_extract_relevant_domains <src_path> <dst_path> <domains_file>
#   Parses the `## Relevant domains` markdown section from <src_path> and writes
#   one cleaned domain id per line to <dst_path>. The section is captured from
#   the first `## Relevant domains` heading (with or without trailing
#   parenthetical suffix) until the next `## ` heading or EOF.
#
#   Each captured line is sanitized:
#     - leading list markers (`1.`, `2)`, `-`, `*`, `+`) are stripped
#     - trailing parenthetical notes (`security (auth angle)`) are stripped
#     - surrounding whitespace is trimmed
#     - blank lines, `DONE` markers, and `(none)` placeholders are dropped
#     - duplicate entries are removed (first occurrence wins)
#     - any id NOT in the default-mode domain whitelist derived from
#       <domains_file> is silently dropped — protects the dispatcher from
#       hallucinated or stale domain ids
#   The destination file is always created (possibly empty) when the source
#   exists. Returns 0 on success even when no domains are found.
_triage_extract_relevant_domains() {
  local src="$1" dst="$2" domains_file="$3"
  local tmp_dst
  tmp_dst="${dst}.tmp.$$"

  : > "$tmp_dst" || return 1

  if [[ ! -f "$src" ]]; then
    mv "$tmp_dst" "$dst" 2>/dev/null || rm -f "$tmp_dst"
    return 1
  fi

  awk '
    BEGIN { in_section = 0 }
    /^##[[:space:]]+Relevant domains/ {
      in_section = 1
      next
    }
    in_section && /^##[[:space:]]+/ {
      in_section = 0
    }
    in_section { print }
  ' "$src" > "$tmp_dst.raw" || {
    rm -f "$tmp_dst" "$tmp_dst.raw"
    return 1
  }

  local -A allowed=()
  if [[ -n "$domains_file" ]]; then
    local known
    while IFS= read -r known; do
      [[ -z "$known" ]] && continue
      allowed["$known"]=1
    done < <(_triage_default_mode_domain_ids "$domains_file")
  fi

  local -A seen=()
  local raw_line entry
  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    entry="$raw_line"
    entry="${entry//$'\r'/}"
    entry="${entry//$'\t'/ }"
    entry="${entry//|/ }"
    # Trim leading whitespace
    entry="${entry#"${entry%%[![:space:]]*}"}"
    # Strip leading list marker: digits with `.` or `)`, or `-`, `*`, `+`
    if [[ "$entry" =~ ^([0-9]+[\.\)]|[-*+])[[:space:]]+(.*)$ ]]; then
      entry="${BASH_REMATCH[2]}"
    fi
    # Strip backticks / code-fence markers around the id
    entry="${entry//\`/}"
    # Drop a trailing parenthetical "id (note)" or "id - note" or "id: note"
    # so the artifact stays a clean id list. Match the FIRST id-shaped token.
    if [[ "$entry" =~ ^([A-Za-z0-9][A-Za-z0-9_-]*) ]]; then
      entry="${BASH_REMATCH[1]}"
    fi
    # Collapse internal whitespace runs to a single space
    entry="$(printf '%s' "$entry" | tr -s '[:space:]' ' ')"
    # Trim leading/trailing whitespace
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"

    [[ -z "$entry" ]] && continue
    [[ "$entry" == "DONE" ]] && continue
    [[ "$entry" == "(none)" ]] && continue
    [[ "$entry" == "none" ]] && continue
    if [[ -n "${seen[$entry]:-}" ]]; then
      continue
    fi
    if (( ${#allowed[@]} > 0 )) && [[ -z "${allowed[$entry]:-}" ]]; then
      continue
    fi
    seen["$entry"]=1
    printf '%s\n' "$entry" >> "$tmp_dst"
  done < "$tmp_dst.raw"
  rm -f "$tmp_dst.raw"

  if ! mv "$tmp_dst" "$dst"; then
    rm -f "$tmp_dst"
    return 1
  fi
  return 0
}

# _triage_truncate_pack <src_path> <dst_path>
#   Copies up to TRIAGE_PACK_MAX_BYTES from <src_path> into <dst_path>. If the
#   source exceeds the cap, the destination is truncated and a deterministic
#   marker line is appended so downstream readers can detect truncation. The
#   truncation budget is enforced byte-wise on the consumable pack only; the
#   full original transcript is preserved separately by run_triage.
_triage_truncate_pack() {
  local src="$1" dst="$2"
  local size
  size="$(wc -c < "$src" 2>/dev/null | tr -d ' ')"
  if [[ -z "$size" || ! "$size" =~ ^[0-9]+$ ]]; then
    size=0
  fi
  if (( size <= TRIAGE_PACK_MAX_BYTES )); then
    cp "$src" "$dst"
    return 0
  fi

  local marker=$'\n[... truncated, see logs/<run-id>/triage/transcript.txt ...]\n'
  local marker_len="${#marker}"
  local head_budget=$((TRIAGE_PACK_MAX_BYTES - marker_len))
  if (( head_budget < 0 )); then
    head_budget=0
  fi
  {
    head -c "$head_budget" "$src"
    printf '%s' "$marker"
  } > "$dst"
}

# run_triage <run_id>
#   Composes the triage prompt, invokes the active agent exactly once, captures
#   stdout, truncates it to TRIAGE_PACK_MAX_BYTES, and atomically promotes it
#   to logs/<run-id>/triage/context-pack.md. The full transcript is also
#   written to logs/<run-id>/triage/transcript.txt.
#
#   Idempotent on resume: if context-pack.md already exists for this run id
#   the function returns 0 without re-invoking the agent.
#
#   Required globals: AGENT, PROJECT_PATH.
#   Optional globals: REPO_OWNER, REPO_NAME, MODE, LOG_BASE, BUG_REPORT_FILE,
#                     AGENT_TIMEOUT_SECS, AGENT_KILL_GRACE_SECS.
#
#   Returns 0 on success, non-zero on any dispatch / composition failure. The
#   orchestrator must treat non-zero as non-fatal — bugreport mode continues
#   with an absent context pack (which the template engine substitutes as
#   empty into the round-1 lens prompts).
run_triage() {
  local run_id="${1:-}"
  if [[ -z "$run_id" ]]; then
    echo "run_triage: missing run_id" >&2
    return 2
  fi

  local repo_root run_log_base triage_dir pack_file transcript_file
  repo_root="$(_triage_repo_root)"
  run_log_base="$(_triage_log_base "$run_id")"
  triage_dir="$run_log_base/triage"
  pack_file="$triage_dir/context-pack.md"
  transcript_file="$triage_dir/transcript.txt"

  local triage_template="$repo_root/prompts/_base/triage.md"
  if [[ ! -f "$triage_template" ]]; then
    echo "run_triage: triage template missing: $triage_template" >&2
    return 2
  fi

  local agent="${AGENT:-}"
  if [[ -z "$agent" ]]; then
    echo "run_triage: AGENT is not set" >&2
    return 2
  fi
  local project_path="${PROJECT_PATH:-}"
  if [[ -z "$project_path" || ! -d "$project_path" ]]; then
    echo "run_triage: PROJECT_PATH must be a directory: $project_path" >&2
    return 2
  fi

  mkdir -p "$triage_dir" || {
    echo "run_triage: cannot create triage dir: $triage_dir" >&2
    return 1
  }

  local domains_file="${DOMAINS_FILE:-$repo_root/config/domains.json}"

  # Idempotence: --resume re-enters with the same run id. If a non-empty pack
  # already exists, keep it; do not pay the agent cost again.
  if [[ -s "$pack_file" ]]; then
    # Backfill the seeds artifact for older runs that predate it. Best-effort:
    # if extraction fails we still consider the cached pack canonical.
    if [[ ! -f "$triage_dir/investigation-seeds.txt" ]]; then
      _triage_extract_investigation_seeds "$pack_file" "$triage_dir/investigation-seeds.txt" || true
    fi
    # Backfill the relevant-domains artifact the same way. Prefer the raw
    # transcript when present (it survives the 2 KB cap); fall back to the pack.
    if [[ ! -f "$triage_dir/relevant-domains.txt" ]]; then
      local backfill_src="$pack_file"
      if [[ -s "$transcript_file" ]]; then
        backfill_src="$transcript_file"
      fi
      _triage_extract_relevant_domains "$backfill_src" "$triage_dir/relevant-domains.txt" "$domains_file" || true
    fi
    return 0
  fi

  if ! declare -F compose_prompt >/dev/null 2>&1; then
    echo "run_triage: compose_prompt is not available (source lib/template.sh)" >&2
    return 2
  fi
  if ! declare -F run_agent >/dev/null 2>&1; then
    echo "run_triage: run_agent is not available (source lib/core.sh)" >&2
    return 2
  fi

  local mode="${MODE:-bugreport}"
  local repo_owner="${REPO_OWNER:-}"
  local repo_name="${REPO_NAME:-}"
  local bug_report_file="${BUG_REPORT_FILE:-}"

  # Build the default-mode domain menu the triage agent picks from. Indented as
  # a markdown bullet list so it slots cleanly under the step-7 prose. Empty
  # when DOMAINS_FILE is unreadable — the prompt then degrades to "no menu
  # available" and the dispatcher whitelist will drop every emitted id, which
  # falls through to full fanout (the safe path).
  local available_domains=""
  local _dom
  while IFS= read -r _dom; do
    [[ -z "$_dom" ]] && continue
    available_domains+="   - ${_dom}"$'\n'
  done < <(_triage_default_mode_domain_ids "$domains_file")
  available_domains="${available_domains%$'\n'}"

  local vars
  vars="RUN_ID=$run_id"
  vars+="|MODE=$mode"
  vars+="|PROJECT_PATH=$project_path"
  vars+="|REPO_OWNER=$repo_owner"
  vars+="|REPO_NAME=$repo_name"
  vars+="|AVAILABLE_DOMAINS=$available_domains"
  if [[ -n "$bug_report_file" && -f "$bug_report_file" ]]; then
    vars+="|BUG_REPORT=@${bug_report_file}"
  fi

  local prompt_text
  prompt_text="$(compose_prompt "$triage_template" "$triage_template" "$vars")" || {
    echo "run_triage: prompt composition failed" >&2
    return 1
  }

  local agent_output
  if [[ -n "${_TRIAGE_AGENT_CALLBACK:-}" ]] && declare -F "${_TRIAGE_AGENT_CALLBACK}" >/dev/null 2>&1; then
    agent_output="$("${_TRIAGE_AGENT_CALLBACK}" "$run_id" "$prompt_text")" || {
      echo "run_triage: triage callback failed" >&2
      return 1
    }
  else
    local agent_rc=0
    local envelope_file="$transcript_file.envelope.json"
    run_agent "$agent" "$prompt_text" "$project_path" "${AGENT_TIMEOUT_SECS:-}" "${AGENT_KILL_GRACE_SECS:-30}" "$envelope_file" > "$transcript_file" 2>&1 || agent_rc=$?
    agent_output="$(cat "$transcript_file" 2>/dev/null || true)"
    if declare -F handle_agent_failure_in_phase >/dev/null 2>&1; then
      local phase_rc
      handle_agent_failure_in_phase "triage" "$transcript_file" "$agent_rc" "$envelope_file" "run_triage"
      phase_rc=$?
      if (( phase_rc != 0 )); then
        return "$phase_rc"
      fi
    elif (( agent_rc != 0 )); then
      echo "run_triage: agent invocation failed" >&2
      return 1
    fi
  fi

  printf '%s\n' "$agent_output" > "$transcript_file" 2>/dev/null || true

  if [[ -z "$agent_output" ]]; then
    echo "run_triage: agent emitted no output" >&2
    return 1
  fi

  local raw_pack
  raw_pack="$triage_dir/context-pack.raw.$$"
  if ! printf '%s\n' "$agent_output" > "$raw_pack"; then
    echo "run_triage: failed to stage raw pack" >&2
    rm -f "$raw_pack"
    return 1
  fi

  # Extract investigation seeds from the FULL raw output before truncation, so
  # the auditable seeds file survives the 2 KB pack cap. Failure is non-fatal:
  # bugreport wave-1 selection falls back to full fanout when seeds are missing.
  local seeds_file="$triage_dir/investigation-seeds.txt"
  _triage_extract_investigation_seeds "$raw_pack" "$seeds_file" || true

  # Extract the relevant-domains list from the same pre-truncation transcript.
  # The dispatcher intersects this with the full default-mode lens list to
  # prune round-1 fanout. Failure is non-fatal: missing or empty file means
  # the dispatcher falls through to full fanout.
  local relevant_domains_file="$triage_dir/relevant-domains.txt"
  _triage_extract_relevant_domains "$raw_pack" "$relevant_domains_file" "$domains_file" || true

  local candidate
  candidate="$triage_dir/context-pack.md.tmp.$$"
  _triage_truncate_pack "$raw_pack" "$candidate" || {
    echo "run_triage: truncation failed" >&2
    rm -f "$raw_pack" "$candidate"
    return 1
  }
  rm -f "$raw_pack"

  if ! mv "$candidate" "$pack_file"; then
    echo "run_triage: failed to promote context-pack.md" >&2
    rm -f "$candidate"
    return 1
  fi

  return 0
}
