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

# RepoLens — Human-facing triage artifact generators
# Renders the post-run Markdown artifacts under logs/<run-id>/final/ from the
# finding registry final/findings.jsonl (schema: docs/finding-registry-schema.md).
# This file only RENDERS; it never builds or mutates the registry. Sourced,
# never executed directly. Pure: function-only, no top-level side effects, no
# global mutation, safe under `set -uo pipefail`.
#
# Self-contained: the inclusion predicate and risk ordering are done inside jq
# so this file can be sourced alone. lib/risk.sh::finding_risk_score and
# lib/core.sh::severity_rank encode the equivalent shared formula; we do not
# depend on them landing first (matches the defensive discipline in ledger.sh /
# dedupe.sh). Wiring into repolens.sh finalize is a separate issue.
set -uo pipefail

# generate_todo_md <findings_jsonl> <out_file>
#   Renders the "act on these now" list to <out_file> as Markdown, one entry per
#   actionable finding showing severity, type, primary_location and (when present)
#   a link to its markdown_path. Reads the JSON-Lines registry with `jq -s`
#   (slurp) so the ordering spans every record.
#
#   INCLUSION PREDICATE (research "Reading B" — the recommended/owner design):
#     include  <=>  status == "new"
#                   AND NOT (confidence is a number strictly below THRESHOLD)
#     - THRESHOLD = 0.5 (the lib/risk.sh neutral midpoint), comparison inclusive:
#       confidence >= 0.5 is kept; an explicit number below 0.5 is excluded. To
#       tighten (e.g. drop "medium" too) a reviewer bumps this single constant.
#     - status == "new" IS the proof gate. The validation classifier (#334) and
#       dedupe (#335) demote weak / negative / duplicate findings OUT of "new",
#       so a record still "new" is confirmed and validation-not-negative. We
#       therefore honor the issue's "positive validation" half THROUGH status and
#       deliberately do NOT crack open the opaque `validation` object (its schema
#       ownership lives with the validation-hints agent).
#     - an UNSCORED confidence (null / absent / non-numeric) is KEPT (neutral),
#       mirroring lib/risk.sh's 0.5 default: unscored findings must not be buried.
#       This is load-bearing today, when `confidence` is null for every record.
#     - the status match is EXACT ("newish" and other unknown statuses do not
#       pass); this also excludes needs-validation / likely-false-positive /
#       duplicate.
#
#   ORDERING: severity rank desc (critical>high>medium>low; unknown last), then
#   confidence desc (null treated as the 0.5 neutral midpoint), then id ascending
#   as a stable tiebreak so output is byte-identical across runs (no timestamps).
#
#   RENDERING is defensive (every field below is null/empty for records emitted
#   today): null/empty type or primary_location renders as an em dash, never the
#   literal "null"; a null/empty markdown_path emits NO link (never a broken
#   "[...]()"). Fields are emitted verbatim by jq, so a title containing
#   backticks / $() / pipes is data, never shell-evaluated.
#
#   EMPTY / MISSING INPUT: a missing or unreadable input path returns 2 and
#   writes nothing (no crash). A present-but-empty or all-excluded registry
#   writes a valid file with a "no actionable findings" note and returns 0.
#
#   Pure apart from the documented write of <out_file> (atomic tmp+mv). Returns
#   0 on success, 2 on bad/unreadable input, 1 on a render/IO failure.
generate_todo_md() {
  local findings_jsonl="${1:-}" out_file="${2:-}"

  # Bad args or an unreadable/missing input -> rc 2, nothing written, no crash.
  [[ -n "$findings_jsonl" && -n "$out_file" ]] || return 2
  [[ -f "$findings_jsonl" && -r "$findings_jsonl" ]] || return 2

  local out_dir
  out_dir="$(dirname -- "$out_file")"
  mkdir -p -- "$out_dir" 2>/dev/null || return 1

  local tmp
  tmp="$(mktemp "$out_dir/.todo.XXXXXX")" || return 1

  if jq -rs --arg ph "—" '
       def rank: {critical:3, high:2, medium:1, low:0}[(.severity // "")] // -1;
       def conf: (if (.confidence | type) == "number" then .confidence else 0.5 end);
       def disp(v): (if (v == null or v == "") then $ph else (v | tostring) end);
       def kept:
         (.status == "new")
         and ((.confidence | type) != "number" or .confidence >= 0.5);

       ( map(select(kept))
         | map(. + {_rank: rank, _conf: conf})
         | sort_by([(._rank * -1), (._conf * -1), (.id // "")])
         | map(
             "## [" + ((.severity // "") | ascii_upcase) + "] "
               + (.title // "(untitled)") + "\n"
             + "- **Severity:** " + disp(.severity) + "\n"
             + "- **Type:** " + disp(.type) + "\n"
             + "- **Location:** " + disp(.primary_location) + "\n"
             + (if (.markdown_path == null or .markdown_path == "")
                then ""
                else "- **Details:** [" + (.markdown_path | tostring)
                       + "](" + (.markdown_path | tostring) + ")\n"
                end)
           )
       ) as $entries
       | "# TODO — Actionable Findings\n\n"
         + "Confirmed, ready-to-act findings (status `new`, not low-confidence), "
         + "ordered by severity then confidence.\n\n"
         + (if ($entries | length) == 0
            then "_No actionable findings._\n"
            else ($entries | join("\n"))
            end)
     ' "$findings_jsonl" >"$tmp" 2>/dev/null; then
    mv -f -- "$tmp" "$out_file"
    return 0
  fi

  rm -f -- "$tmp"
  return 1
}
