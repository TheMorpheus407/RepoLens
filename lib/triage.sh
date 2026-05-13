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

  # Idempotence: --resume re-enters with the same run id. If a non-empty pack
  # already exists, keep it; do not pay the agent cost again.
  if [[ -s "$pack_file" ]]; then
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

  local vars
  vars="RUN_ID=$run_id"
  vars+="|MODE=$mode"
  vars+="|PROJECT_PATH=$project_path"
  vars+="|REPO_OWNER=$repo_owner"
  vars+="|REPO_NAME=$repo_name"
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
    agent_output="$(run_agent "$agent" "$prompt_text" "$project_path" "${AGENT_TIMEOUT_SECS:-}" "${AGENT_KILL_GRACE_SECS:-30}")" || {
      echo "run_triage: agent invocation failed" >&2
      return 1
    }
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
