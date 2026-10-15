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
    if mv -f -- "$tmp" "$out_file"; then
      return 0
    fi
  fi

  rm -f -- "$tmp"
  return 1
}

# generate_summary_md <findings_jsonl> <out_file>
#   Renders the executive "Top 20 findings by risk" view to <out_file> as
#   Markdown, one ranked entry per finding showing severity, type,
#   primary_location and (when present) a link to its markdown_path. Reads the
#   JSON-Lines registry with `jq -rs` (slurp) so the ranking spans every record.
#   Sibling of generate_todo_md / generate_needs_review_md / generate_duplicates_md;
#   it only RENDERS — it never builds or mutates the registry.
#
#   RISK (issue #336 AC #1) — risk = severity rank x confidence, ranked
#   descending, mirroring lib/risk.sh::finding_risk_score / lib/core.sh::
#   severity_rank exactly (the formula is kept INLINE in jq so this file stays
#   self-sourceable and avoids one subprocess per finding; AC #4 sanctions this
#   inline mirror as the documented fallback). Severity rank: critical=3, high=2,
#   medium=1, low=0. Confidence: the numeric value if present, else the 0.5
#   neutral default (mirrors lib/risk.sh's _risk_confidence_normalize, so an
#   unscored finding is not buried). Two distinct ranks are used: `// 0` for the
#   SCORE (matches finding_risk_score, which clamps an invalid rank to 0 — never
#   a negative risk) and `// -1` for the tiebreak (so an unknown-severity finding
#   sorts LAST). Note: `low` always scores 0 (rank 0), so confidence cannot order
#   findings within the low band — by design, not a bug.
#
#   POPULATION (research §3.2 — the recommended/owner design): rank EVERY record
#   EXCEPT status == "duplicate". Unlike generate_todo_md there is NO status ==
#   "new" gate — SUMMARY is the executive risk view, so a high-risk
#   needs-validation (or even likely-false-positive) finding still surfaces; the
#   risk formula de-weights low-confidence items naturally. The ONLY status that
#   must be filtered is `duplicate`: a non-canonical copy carries the same
#   severity/confidence as its canonical and would double-count a single real
#   issue, wasting a slot in the Top-20. This matches every sibling's treatment
#   of `status == "duplicate"`.
#
#   ORDERING / CAP: risk desc, then severity rank desc (so a high@0.5=1.0 beats a
#   medium@1.0=1.0 — severity wins on a tie), then confidence desc, then id
#   ascending as a stable tiebreak so output is byte-identical across runs (no
#   timestamps). Take the top 20 (`.[0:20]`); fewer than 20 eligible findings
#   emit exactly that many.
#
#   RENDERING is defensive (mirrors the siblings): null/empty type or
#   primary_location renders as an em dash, never the literal "null"; a
#   null/empty markdown_path emits NO link (never a broken "[...]()"). Fields are
#   emitted verbatim by jq, so a title containing backticks / $() / pipes is
#   data, never shell-evaluated; the list layout (not a Markdown table) means a
#   literal "|" cannot break a row.
#
#   EMPTY / MISSING INPUT: a missing or unreadable input path returns 2 and
#   writes nothing (no crash). A present-but-empty or all-excluded registry
#   writes a valid file with a "no findings" note and returns 0.
#
#   Pure apart from the documented write of <out_file> (atomic tmp+mv). Returns
#   0 on success, 2 on bad/unreadable input, 1 on a render/IO failure.
generate_summary_md() {
  local findings_jsonl="${1:-}" out_file="${2:-}"

  # Bad args or an unreadable/missing input -> rc 2, nothing written, no crash.
  [[ -n "$findings_jsonl" && -n "$out_file" ]] || return 2
  [[ -f "$findings_jsonl" && -r "$findings_jsonl" ]] || return 2

  local out_dir
  out_dir="$(dirname -- "$out_file")"
  mkdir -p -- "$out_dir" 2>/dev/null || return 1

  local tmp
  tmp="$(mktemp "$out_dir/.summary.XXXXXX")" || return 1

  if jq -rs --arg ph "—" '
       # Score rank clamps invalid severity to 0 (mirrors finding_risk_score,
       # never negative); tiebreak rank uses -1 so unknown severity sorts last.
       def rank0: {critical:3, high:2, medium:1, low:0}[(.severity // "")] // 0;
       def rankt: {critical:3, high:2, medium:1, low:0}[(.severity // "")] // -1;
       def conf: (if (.confidence | type) == "number" then .confidence else 0.5 end);
       def disp(v): (if (v == null or v == "") then $ph else (v | tostring) end);

       ( map(select(.status != "duplicate"))
         | map(. + {_risk: (rank0 * conf), _rankt: rankt, _conf: conf})
         | sort_by([(._risk * -1), (._rankt * -1), (._conf * -1), (.id // "")])
         | .[0:20]
         | to_entries
         | map(
             "## " + ((.key + 1) | tostring) + ". ["
               + ((.value.severity // "") | ascii_upcase) + "] "
               + (.value.title // "(untitled)") + "\n"
             + "- **Severity:** " + disp(.value.severity) + "\n"
             + "- **Type:** " + disp(.value.type) + "\n"
             + "- **Location:** " + disp(.value.primary_location) + "\n"
             + (if (.value.markdown_path == null or .value.markdown_path == "")
                then ""
                else "- **Details:** [" + (.value.markdown_path | tostring)
                       + "](" + (.value.markdown_path | tostring) + ")\n"
                end)
           )
       ) as $entries
       | "# SUMMARY — Top 20 Findings by Risk\n\n"
         + "Executive view: the highest-risk findings across this run, ranked by "
         + "risk = severity rank x confidence (descending; critical=3, high=2, "
         + "medium=1, low=0). Duplicate findings are excluded so a canonical is "
         + "never double-counted. Most-risky first.\n\n"
         + (if ($entries | length) == 0
            then "_No findings to summarize._\n"
            else ($entries | join("\n"))
            end)
     ' "$findings_jsonl" >"$tmp" 2>/dev/null; then
    if mv -f -- "$tmp" "$out_file"; then
      return 0
    fi
  fi

  rm -f -- "$tmp"
  return 1
}

# generate_needs_review_md <findings_jsonl> <out_file>
#   Renders the "a human (or an external scanner) must look at this" list to
#   <out_file> as Markdown, one entry per UNCERTAIN finding showing severity,
#   type, primary_location, (when present) a link to its markdown_path, and a
#   named review REASON. Reads the JSON-Lines registry with `jq -s` (slurp) so
#   the ordering spans every record. Sibling of generate_todo_md; the two lists
#   together must lose no non-duplicate finding through the cracks.
#
#   INCLUSION PREDICATE — the complement of generate_todo_md's actionable set
#   over NON-DUPLICATE findings, unioned with two validation-derived reasons.
#   A finding is included iff status != "duplicate" AND any of:
#     P1  status == "needs-validation"          -> reason "needs validation"
#           (the validation classifier #334 flagged it for confirmation)
#     P2  status == "likely-false-positive"     -> reason "likely false positive"
#           DESIGN CALL: INCLUDED. TODO requires status == "new", so a
#           non-duplicate likely-false-positive is NOT actionable and IS in the
#           complement — a human confirms the probable-FP call rather than it
#           silently vanishing. (Excluding it would leave a gap between the two
#           lists; we keep them an exact complement.)
#     P3  confidence is a number strictly below THRESHOLD -> reason "low
#           confidence (<value>)". THRESHOLD = 0.5 and the (confidence|type) ==
#           "number" guard are IDENTICAL to generate_todo_md's: TODO keeps
#           unscored (neutral) + >= 0.5; NEEDS_REVIEW takes the explicit-low
#           leftovers. Keeping this constant in lockstep is the single highest-
#           risk correctness property — drift creates a coverage gap or overlap.
#     P4  validation.suggested_validation names an external scanner -> reason
#           "needs external scanner". Keys off the load-bearing escalation phrase
#           "needs external scanner" (prompts/_base/audit.md), matched
#           case-insensitively. This can surface an OTHERWISE-actionable finding
#           (status new, high confidence) that simply cannot be confirmed locally.
#     P5  validation.contradictory == true -> reason "contradictory validation".
#
#   P4/P5 inspect the opaque `validation` object (owned by the validation-hints
#   agent, #317/#332/#334/#345) via FORWARD-COMPATIBLE, DEFENSIVE heuristics:
#   they degrade to no-match on today's empty `{}` / a missing or non-object
#   value, and this function does NOT define the validation schema. The
#   duplicate guard is top-level so it wins over P3 (a low-confidence duplicate
#   belongs to the DUPLICATES artifact, a separate issue), and `status` being
#   single-valued means it cleanly removes duplicates from every predicate.
#
#   REASONS: each matched predicate's label is collected (a finding may match
#   several) from the SAME predicates that gate inclusion — single source of
#   truth, so the printed reason never drifts from why the entry was kept.
#
#   ORDERING: severity rank desc (critical>high>medium>low; unknown last), then
#   confidence desc (null treated as the 0.5 neutral midpoint), then id ascending
#   as a stable tiebreak so output is byte-identical across runs (no timestamps).
#
#   RENDERING is defensive (mirrors generate_todo_md): null/empty type or
#   primary_location renders as an em dash, never the literal "null"; a
#   null/empty markdown_path emits NO link (never a broken "[...]()"). Fields are
#   emitted verbatim by jq, so a title containing backticks / $() / pipes is
#   data, never shell-evaluated.
#
#   EMPTY / MISSING INPUT: a missing or unreadable input path returns 2 and
#   writes nothing (no crash). A present-but-empty or all-excluded registry
#   writes a valid file with a "nothing needs review" note and returns 0.
#
#   Pure apart from the documented write of <out_file> (atomic tmp+mv). Returns
#   0 on success, 2 on bad/unreadable input, 1 on a render/IO failure.
generate_needs_review_md() {
  local findings_jsonl="${1:-}" out_file="${2:-}"

  # Bad args or an unreadable/missing input -> rc 2, nothing written, no crash.
  [[ -n "$findings_jsonl" && -n "$out_file" ]] || return 2
  [[ -f "$findings_jsonl" && -r "$findings_jsonl" ]] || return 2

  local out_dir
  out_dir="$(dirname -- "$out_file")"
  mkdir -p -- "$out_dir" 2>/dev/null || return 1

  local tmp
  tmp="$(mktemp "$out_dir/.needs-review.XXXXXX")" || return 1

  if jq -rs --arg ph "—" '
       def rank: {critical:3, high:2, medium:1, low:0}[(.severity // "")] // -1;
       def conf: (if (.confidence | type) == "number" then .confidence else 0.5 end);
       def disp(v): (if (v == null or v == "") then $ph else (v | tostring) end);
       def vobj: (if (.validation | type) == "object" then .validation else {} end);
       # Collect every matched review reason (a finding may match several).
       # P3 mirrors generate_todo_md exactly: THRESHOLD 0.5, number-typed guard.
       def reasons:
         ( (if .status == "needs-validation"
              then ["needs validation (classifier flagged it)"] else [] end)
         + (if .status == "likely-false-positive"
              then ["likely false positive — confirm"] else [] end)
         + (if ((.confidence | type) == "number" and .confidence < 0.5)
              then ["low confidence (" + (.confidence | tostring) + ")"] else [] end)
         + (if ((vobj | (.suggested_validation // "") | ascii_downcase) | test("external scanner"))
              then ["needs external scanner"] else [] end)
         + (if (vobj | (.contradictory == true))
              then ["contradictory validation"] else [] end)
         );
       def kept: (.status != "duplicate") and ((reasons | length) > 0);

       ( map(select(kept))
         | map(. + {_rank: rank, _conf: conf, _reasons: reasons})
         | sort_by([(._rank * -1), (._conf * -1), (.id // "")])
         | map(
             "## [" + ((.severity // "") | ascii_upcase) + "] "
               + (.title // "(untitled)") + "\n"
             + "- **Severity:** " + disp(.severity) + "\n"
             + "- **Type:** " + disp(.type) + "\n"
             + "- **Location:** " + disp(.primary_location) + "\n"
             + "- **Needs review:** " + (._reasons | join("; ")) + "\n"
             + (if (.markdown_path == null or .markdown_path == "")
                then ""
                else "- **Details:** [" + (.markdown_path | tostring)
                       + "](" + (.markdown_path | tostring) + ")\n"
                end)
           )
       ) as $entries
       | "# NEEDS_REVIEW — Findings Requiring Human Review\n\n"
         + "Uncertain findings a person (or an external scanner) should confirm "
         + "before acting — the complement of TODO.md over non-duplicate "
         + "findings, ordered by severity then confidence.\n\n"
         + (if ($entries | length) == 0
            then "_Nothing needs review._\n"
            else ($entries | join("\n"))
            end)
     ' "$findings_jsonl" >"$tmp" 2>/dev/null; then
    if mv -f -- "$tmp" "$out_file"; then
      return 0
    fi
  fi

  rm -f -- "$tmp"
  return 1
}

# generate_duplicates_md <findings_jsonl> <out_file>
#   Renders the "N lenses converged on the same finding" list to <out_file> as
#   Markdown, one section per MERGED GROUP: the canonical finding (severity, type,
#   primary_location and, when present, a link to its markdown_path) followed by
#   the OTHER lenses that also reported it (its `also_reported_by` list). Reads the
#   JSON-Lines registry with `jq -rs` (slurp) so ordering spans every record.
#   Sibling of generate_todo_md / generate_needs_review_md; renders only — it never
#   builds or mutates the registry.
#
#   MERGED-GROUP PREDICATE (research "Reading A" — the recommended/owner design):
#     include  <=>  `also_reported_by` is a NON-EMPTY array.
#     - That record IS the canonical (the synthesize step attaches
#       `also_reported_by` only to the canonical of a group), and its array already
#       enumerates every OTHER reporter. The reporter count is therefore
#       1 + (also_reported_by | length).
#     - `duplicate_group` is the section's group identity (shown as a "Group:" line
#       when present), but grouping NEVER depends on its value — so a null / missing
#       / non-string `duplicate_group` cannot crash the generator and the literal
#       "null" never leaks (it is rendered through the same defensive path).
#     - This is robust to today's data: `also_reported_by` is not yet carried into
#       findings.jsonl (the manifest->registry build drops it), so today every
#       record degrades to a singleton, yielding ZERO groups and the clean
#       empty-state path. The renderer lights up automatically once the
#       carry-through lands — no code change here. This mirrors how
#       generate_needs_review_md treats the opaque `validation` object: a
#       missing / null / wrong-typed value degrades to no-match, never a crash.
#
#   SINGLETONS — EXCLUDED (the documented rule). DUPLICATES.md is ABOUT
#   convergence; a singleton has nothing to merge and already appears in TODO.md /
#   NEEDS_REVIEW.md. A record with no / empty / non-array `also_reported_by` is a
#   singleton and is excluded by definition (never rendered, never an empty link).
#
#   Each `also_reported_by[]` element is { "lens": <id>, "domain": <id>,
#   "markdown_path": <path> } (one per non-canonical contributor; markdown_path may
#   be ""). Rendered "<domain>/<lens>" with an optional link when markdown_path is
#   non-empty.
#
#   ORDERING: severity rank desc (critical>high>medium>low; unknown last), then
#   confidence desc (null treated as the 0.5 neutral midpoint), then duplicate_group
#   then id ascending as a stable tiebreak so output is byte-identical across runs
#   (no timestamps).
#
#   RENDERING is defensive (mirrors the siblings): null/empty severity/type/
#   primary_location/domain/lens render as an em dash, never the literal "null"; a
#   null/empty markdown_path (canonical OR contributor) emits NO link (never a
#   broken "[...]()"). Fields are emitted verbatim by jq, so a title containing
#   backticks / $() / pipes is data, never shell-evaluated.
#
#   EMPTY / MISSING INPUT: a missing or unreadable input path returns 2 and writes
#   nothing (no crash). A present-but-empty or all-singleton registry writes a valid
#   file with a "no duplicate groups" note and returns 0.
#
#   Pure apart from the documented write of <out_file> (atomic tmp+mv). Returns 0 on
#   success, 2 on bad/unreadable input, 1 on a render/IO failure.
generate_duplicates_md() {
  local findings_jsonl="${1:-}" out_file="${2:-}"

  # Bad args or an unreadable/missing input -> rc 2, nothing written, no crash.
  [[ -n "$findings_jsonl" && -n "$out_file" ]] || return 2
  [[ -f "$findings_jsonl" && -r "$findings_jsonl" ]] || return 2

  local out_dir
  out_dir="$(dirname -- "$out_file")"
  mkdir -p -- "$out_dir" 2>/dev/null || return 1

  local tmp
  tmp="$(mktemp "$out_dir/.duplicates.XXXXXX")" || return 1

  if jq -rs --arg ph "—" '
       def rank: {critical:3, high:2, medium:1, low:0}[(.severity // "")] // -1;
       def conf: (if (.confidence | type) == "number" then .confidence else 0.5 end);
       def disp(v): (if (v == null or v == "") then $ph else (v | tostring) end);
       # Reading A: a merged group is a record whose also_reported_by is a NON-EMPTY
       # array. A missing / null / non-array value degrades to [] (a singleton).
       def arb: (if (.also_reported_by | type) == "array" then .also_reported_by else [] end);

       ( map(select((arb | length) > 0))
         | map(. + {_rank: rank, _conf: conf, _arb: arb})
         | sort_by([(._rank * -1), (._conf * -1), (.duplicate_group // ""), (.id // "")])
         | map(
             "## [" + ((.severity // "") | ascii_upcase) + "] "
               + (.title // "(untitled)") + "\n"
             + "- **Severity:** " + disp(.severity) + "\n"
             + "- **Type:** " + disp(.type) + "\n"
             + "- **Location:** " + disp(.primary_location) + "\n"
             + (if (.duplicate_group == null or .duplicate_group == "")
                then ""
                else "- **Group:** " + (.duplicate_group | tostring) + "\n"
                end)
             + "- **Also reported by:** " + ((._arb | length) | tostring)
               + " other lens(es):\n"
             + ( ._arb
                 | map(
                     "  - " + disp(.domain) + "/" + disp(.lens)
                     + (if (.markdown_path == null or .markdown_path == "")
                        then ""
                        else " ([" + (.markdown_path | tostring)
                               + "](" + (.markdown_path | tostring) + "))"
                        end)
                   )
                 | join("\n")
               ) + "\n"
             + (if (.markdown_path == null or .markdown_path == "")
                then ""
                else "- **Details:** [" + (.markdown_path | tostring)
                       + "](" + (.markdown_path | tostring) + ")\n"
                end)
           )
       ) as $entries
       | "# DUPLICATES — Merged Finding Groups\n\n"
         + "Groups where two or more lenses converged on the same finding (a "
         + "confidence signal). Each entry shows the canonical finding plus the "
         + "other lenses that also reported it. Singleton findings are excluded — "
         + "they appear in TODO.md / NEEDS_REVIEW.md. Ordered by severity then "
         + "confidence.\n\n"
         + (if ($entries | length) == 0
            then "_No duplicate groups — no two lenses converged on the same finding._\n"
            else ($entries | join("\n"))
            end)
     ' "$findings_jsonl" >"$tmp" 2>/dev/null; then
    if mv -f -- "$tmp" "$out_file"; then
      return 0
    fi
  fi

  rm -f -- "$tmp"
  return 1
}
