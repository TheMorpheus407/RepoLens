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

# RepoLens — Human Mode bucketing helper
# Classifies the finding registry (final/findings.jsonl, schema:
# docs/finding-registry-schema.md) into the 5 noise-budget buckets that the
# --human-review digest renders. This file ONLY classifies + selects the
# ranking key; it renders no Markdown, groups no themes, and does no held-back
# accounting (those are separate issues). Sourced, never executed directly.
# Pure: function-only, no top-level side effects, no global mutation, safe under
# `set -uo pipefail`.
#
# Self-contained: the bucket predicates and risk ordering are done inside a
# single `jq -s` (slurp) pass so this file can be sourced alone, mirroring
# lib/artifacts.sh. lib/risk.sh::finding_risk_score and lib/core.sh::severity_rank
# encode the equivalent shared formula (severity_rank desc, then confidence desc
# with null treated as the 0.5 neutral midpoint, then id ascending as a stable
# tiebreak); we inline that ordering here rather than calling them per-record so
# we do not depend on them being sourced first. The bucket-2 type matching mirrors
# lib/core.sh::finding_type_normalize (short `security` and long
# `security-vulnerability` both resolve to the same canonical id).
#
# TOTAL FUNCTION: unlike the lib/artifacts.sh generators (which return 2 on a
# missing/unreadable input), human_review_bucketize ALWAYS returns 0 and ALWAYS
# prints a valid JSON object — an empty / missing / unreadable / all-blank
# registry yields all-empty buckets, never an error.
set -uo pipefail

# _human_review_security_domains
#   Prints a JSON array of the security-ish domain ids (lowercased): every domain
#   in config/domains.json whose id matches /security/i. Data-driven so the
#   bucket-2 "security domain" predicate is not tied to one repo's layout (the
#   issue forbids hardcoding a single repo's domains). Falls back to the
#   documented static set {security, llm-security} when the config is missing,
#   unreadable, or unparseable. Pure; prints one line; never errors.
_human_review_security_domains() {
  local config_file lib_dir out
  lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || lib_dir=""
  config_file="$lib_dir/../config/domains.json"

  if [[ -n "$lib_dir" && -f "$config_file" && -r "$config_file" ]]; then
    out="$(jq -c '
        [ .domains[]? | .id | select(type == "string") | ascii_downcase
          | select(test("security")) ] | unique
      ' "$config_file" 2>/dev/null)" || out=""
    if [[ -n "$out" && "$out" != "[]" && "$out" != "null" ]]; then
      printf '%s\n' "$out"
      return 0
    fi
  fi

  printf '%s\n' '["security","llm-security"]'
}

# _human_review_empty_buckets
#   Prints the canonical all-empty bucket object (the contract shape) to stdout.
#   Used only as a defensive fallback if the main jq pass itself fails; the empty
#   / missing / all-blank input cases flow through the main pass (jq slurps to []
#   and produces this same shape). Pure; never errors.
_human_review_empty_buckets() {
  jq -n '{
    "top_critical_high":              {"cap": 10,   "count": 0, "items": []},
    "top_medium_security":            {"cap": 25,   "count": 0, "items": []},
    "test_quality":                   {"cap": null, "count": 0, "items": []},
    "not_actionable_without_scanner": {"cap": null, "count": 0, "items": []},
    "remainder":                      {"cap": null, "count": 0, "items": []}
  }'
}

# human_review_bucketize <findings_jsonl_path>
#   Reads the JSON-Lines finding registry and prints a single deterministic JSON
#   object to stdout partitioning EVERY finding into 5 priority-ordered buckets,
#   first-match-wins, no double-counting. Writes nothing; invokes no model.
#
#   BUCKET SHAPE (research §5 D1 — the only shape satisfying BOTH the cap AC and
#   the "surplus not silently dropped" AC):
#     { "<bucket>": { "cap": <int|null>, "count": <N>, "items": [<full records>] } }
#   `cap` is the visible-slice size the renderer applies (items[:cap]); `count`
#   and `items` are NEVER truncated to the cap, so the held-back accounting issue
#   can recover the surplus (count - cap / items[cap:]). Items are full finding
#   records (both downstream consumers — the Markdown renderer and the html-report
#   agent — need the fields); the internal sort keys are stripped.
#
#   PRIORITY ORDER, first match wins:
#     1 top_critical_high              — any type; severity in {critical, high}.    cap 10, ranked.
#     2 top_medium_security            — severity==medium AND security-ish domain/type. cap 25, ranked.
#     3 test_quality                   — type in {test-gap, maintainability}.       own section.
#     4 not_actionable_without_scanner — type==external-dependency OR
#                                        (status==needs-validation AND scanner marker). own section.
#     5 remainder                      — everything else.
#
#   PREDICATE DETAILS:
#   - security-ish DOMAIN: .domain (lowercased) is in the data-driven security set
#     from config/domains.json (any id matching /security/i); see
#     _human_review_security_domains.
#   - security-ish TYPE: the type normalizes to "security-vulnerability" — matches
#     BOTH the short `security` and long `security-vulnerability` forms (the
#     short/long-form trap; mirrors lib/core.sh::finding_type_normalize).
#   - scanner marker: validation.suggested_validation contains "external scanner"
#     (case-insensitive) — the single load-bearing escalation phrase from
#     prompts/_base/audit.md, identical to lib/artifacts.sh P4.
#
#   ORDERING (all buckets, for determinism): severity rank desc (critical>high>
#   medium>low; unknown last), then confidence desc (null/non-numeric treated as
#   the 0.5 neutral midpoint), then id ascending as a stable tiebreak so output is
#   byte-identical across runs. This is the documented fallback, byte-identical to
#   how the sibling triage artifacts (TODO/NEEDS_REVIEW/DUPLICATES) order; it
#   coincides with the finding_risk_score product today (confidence is null for
#   every record -> 0.5 for all -> product preserves severity order).
#
#   ESCAPING: every field is emitted verbatim by jq, so a title containing
#   backticks / $(...) / pipes is data, never shell-evaluated.
#
#   EMPTY / MISSING / UNREADABLE / ALL-BLANK INPUT: all-empty buckets, rc 0
#   (a DELIBERATE divergence from the lib/artifacts.sh generators, which return 2;
#   this helper is a total function). Always returns 0.
human_review_bucketize() {
  local findings_jsonl="${1:-}" sec_domains src

  sec_domains="$(_human_review_security_domains)"

  # Total function: a missing / unreadable / absent path still emits all-empty
  # buckets — feed jq an empty stream (/dev/null slurps to []) rather than erroring.
  src="/dev/null"
  if [[ -n "$findings_jsonl" && -f "$findings_jsonl" && -r "$findings_jsonl" ]]; then
    src="$findings_jsonl"
  fi

  if ! jq -s --argjson sec_domains "$sec_domains" '
       # Mirror lib/core.sh::finding_type_normalize: canonicalize a raw type to one
       # of the six taxonomy ids (short forms + obvious synonyms), "" if unknown.
       def typenorm($v):
         ($v // "" | tostring | ascii_downcase) as $t
         | if   ($t == "security" or $t == "security-vulnerability") then "security-vulnerability"
           elif ($t == "bug" or $t == "correctness" or $t == "reliability"
                 or $t == "reliability-bug") then "reliability-bug"
           elif ($t == "perf" or $t == "performance" or $t == "performance-risk") then "performance-risk"
           elif ($t == "maintainability") then "maintainability"
           elif ($t == "test-gap" or $t == "tests" or $t == "testing") then "test-gap"
           elif ($t == "external-dependency" or $t == "cve" or $t == "dependency") then "external-dependency"
           else "" end;

       ( map(
           . as $r
           | ($r.severity // "" | tostring | ascii_downcase) as $sev
           | ({"critical": 3, "high": 2, "medium": 1, "low": 0}[$sev] // -1) as $rank
           | (if ($r.confidence | type) == "number" then $r.confidence else 0.5 end) as $conf
           | typenorm($r.type) as $tn
           | (if ($r.validation | type) == "object" then $r.validation else {} end) as $val
           | (($val.suggested_validation // "" | tostring | ascii_downcase
               | test("external scanner"))) as $marker
           | (($sec_domains | index(($r.domain // "" | tostring | ascii_downcase))) != null) as $secdom
           | (($r.status // "") | tostring) as $status
           | (
               if   ($rank == 3 or $rank == 2) then "top_critical_high"
               elif ($rank == 1 and ($secdom or $tn == "security-vulnerability")) then "top_medium_security"
               elif ($tn == "test-gap" or $tn == "maintainability") then "test_quality"
               elif ($tn == "external-dependency"
                     or ($status == "needs-validation" and $marker)) then "not_actionable_without_scanner"
               else "remainder" end
             ) as $bucket
           | $r + {"_rank": $rank, "_conf": $conf, "_bucket": $bucket}
         )
         | sort_by([(._rank * -1), (._conf * -1), (.id // "" | tostring)])
       ) as $all
       | def bk($key; $cap):
           ([ $all[] | select(._bucket == $key) | del(._rank, ._conf, ._bucket) ]) as $items
           | {"cap": $cap, "count": ($items | length), "items": $items};
         {
           "top_critical_high":              bk("top_critical_high"; 10),
           "top_medium_security":            bk("top_medium_security"; 25),
           "test_quality":                   bk("test_quality"; null),
           "not_actionable_without_scanner": bk("not_actionable_without_scanner"; null),
           "remainder":                      bk("remainder"; null)
         }
     ' "$src" 2>/dev/null; then
    # jq failed for any reason (e.g. a malformed line) — fall back to all-empty
    # buckets so the contract (valid JSON, rc 0) always holds.
    _human_review_empty_buckets
  fi

  return 0
}

# _human_review_repo_root
#   Prints the repo root (the parent of lib/). Mirrors the sibling finalize
#   helpers (_synthesize_repo_root / _verify_repo_root). Pure; prints one path.
_human_review_repo_root() {
  local source_dir
  source_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || source_dir="."
  (cd -- "$source_dir/.." 2>/dev/null && pwd) || printf '%s' "$source_dir/.."
}

# _human_review_log_base <run_id>
#   Returns the run log base directory. Honors the global LOG_BASE when set (so
#   the orchestrator and tests can redirect output) and otherwise falls back to
#   <repo_root>/logs/<run_id>. Mirrors _synthesize_log_base / _verify_log_base so
#   the finalize call and the test drive the renderer the same way. Pure; prints
#   one path.
_human_review_log_base() {
  local run_id="${1:-}"
  if [[ -n "${LOG_BASE:-}" ]]; then
    printf '%s' "$LOG_BASE"
    return 0
  fi
  printf '%s/logs/%s' "$(_human_review_repo_root)" "$run_id"
}

# render_human_review_digest <run_id>
#   Renders the human-facing curated digest at logs/<run-id>/final/HUMAN_REVIEW.md
#   from the bucketed finding registry (final/findings.jsonl). This is the
#   CONSUMER of human_review_bucketize: it slices each bucket to its visible cap
#   and emits a single prioritized Markdown page in a fixed section order —
#   header (run id + totals), Top Critical/High, Top Medium Security,
#   Test & Quality (own section), Not actionable without a scanner (own section),
#   and the themed Remainder — every leftover (bucket-5) finding grouped by
#   `domain` into collapsed <details> blocks (count desc, then domain name), each
#   listing severity + lens + title + primary_location, under the `#remainder`
#   anchor. It RENDERS only — it never builds or mutates the registry and invokes
#   no model.
#
#   PATH RESOLUTION: honors $LOG_BASE when set (the live finalize call exports it;
#   tests set it to a temp dir), else <repo_root>/logs/<run_id>. So the test drives
#   the function by just setting LOG_BASE and dropping a fixture findings.jsonl.
#
#   ATOMIC WRITE: builds the document into <out>.tmp.$$ and `mv -f`s it into place
#   on success (the promote pattern from lib/synthesize.sh / lib/triage.sh). On a
#   render/IO failure the tmp file is removed and the function returns 1, leaving
#   NO partial HUMAN_REVIEW.md behind.
#
#   DEFENSIVE RENDER: a null/empty severity/domain/lens/primary_location renders
#   as an em dash via disp(), never the literal "null"; a null/empty markdown_path
#   emits NO link (never a broken "[]()"). Every field is emitted verbatim by jq,
#   so a title containing backticks / $(...) / pipes is data, never shell-evaluated
#   and never breaks a row (bullet-list layout, not a Markdown table).
#
#   EMPTY REGISTRY: an empty / missing findings.jsonl feeds all-empty buckets
#   (human_review_bucketize is total), so the digest renders a valid "nothing to
#   review" page (header + every section header with an empty-state note) and
#   returns 0.
#
#   Returns 0 on success (file written), 1 on a render/IO failure.
render_human_review_digest() {
  local run_id="${1:-}"
  local base final_dir findings out tmp

  base="$(_human_review_log_base "$run_id")"
  final_dir="$base/final"
  findings="$final_dir/findings.jsonl"
  out="$final_dir/HUMAN_REVIEW.md"

  mkdir -p -- "$final_dir" 2>/dev/null || return 1
  tmp="$out.tmp.$$"

  # Bucketize is a total function (always rc 0, always one valid JSON object),
  # so the pipeline's exit status is determined solely by the jq renderer.
  if human_review_bucketize "$findings" \
    | jq -r --arg run_id "$run_id" --arg ph "—" '
        def disp(v): (if (v == null or v == "") then $ph else (v | tostring) end);

        # One finding -> a bullet-list block. Severity drives the heading; the
        # Where line carries domain/lens + primary_location; Details links to the
        # markdown_path only when present.
        def entry(f):
          "### [" + (((f.severity // "") | tostring | ascii_upcase)
                     | (if . == "" then $ph else . end)) + "] "
            + (f.title // "(untitled)" | tostring) + "\n"
          + "- **Where:** " + disp(f.domain) + "/" + disp(f.lens)
            + " — `" + disp(f.primary_location) + "`\n"
          + (if (f.markdown_path == null or f.markdown_path == "") then ""
             else "- **Details:** [" + (f.markdown_path | tostring)
                    + "](" + (f.markdown_path | tostring) + ")\n"
             end);

        # A capped bucket -> a "## <title>" section. The visible slice is
        # items[:cap] (cap null => all items); count and full items are not
        # truncated by the bucketizer, so an empty slice yields the empty-state.
        def section($bucket; $title):
          ($bucket.items[0:($bucket.cap // ($bucket.items | length))]) as $shown
          | "## " + $title + " (" + ($bucket.count | tostring) + ")\n\n"
            + (if ($shown | length) == 0
               then "_Nothing to review in this section._\n"
               else ([ $shown[] | entry(.) ] | join("\n"))
               end);

        # The themed remainder (bucket 5): every leftover finding, grouped by
        # `domain` (theme), each group a GitHub <details> block collapsed by
        # default so the reviewer sees coverage without scrolling hundreds of
        # lines. Groups are ordered count desc, then domain key asc for
        # determinism; a null/empty domain normalizes to a single em-dash group
        # (the grouping key is the normalized STRING, never JSON null, so it never
        # leaks into the digest nor breaks the sort). Reuses entry() so each
        # finding lists severity + lens + title + primary_location exactly like
        # the top sections. remainder.cap is null, so nothing is sliced — every
        # bucket-5 finding renders under exactly one group. Items arrive
        # pre-sorted from the bucketizer (and group_by is stable), so within-group
        # order needs no extra sort. The blank line after <summary> and before
        # </details> is required for GitHub to render the Markdown body inside the
        # collapsed block.
        def remainder_section($rem):
          "## Remainder (" + ($rem.count | tostring) + ")\n\n"
          + "<a id=\"remainder\"></a>\n\n"
          + (if ($rem.count == 0)
             then "_No further findings._\n"
             else
               ( [ $rem.items[] | . + {"_gkey": ((.domain // "") | tostring)} ]
                 | group_by(._gkey)
                 | map({domain: .[0].domain, key: .[0]._gkey, items: ., count: length})
                 | sort_by([(- .count), .key]) ) as $groups
               | "_Other findings: " + ($rem.count | tostring)
                   + " across " + ($groups | length | tostring) + " theme(s)._\n\n"
               + ( [ $groups[]
                     | "<details>\n<summary>" + disp(.domain) + " — "
                         + (.count | tostring) + " finding(s)</summary>\n\n"
                       + ([ .items[] | entry(.) ] | join("\n"))
                       + "\n</details>\n" ]
                   | join("\n") )
             end);

        ( [ .top_critical_high.count, .top_medium_security.count, .test_quality.count,
            .not_actionable_without_scanner.count, .remainder.count ] | add ) as $total
        | "# Human Review — " + $run_id + "\n\n"
          + "Curated, prioritized digest of the finding registry — "
          + ($total | tostring) + " finding(s) across 5 buckets.\n\n"
          + (if $total == 0 then "_No findings to review._\n\n" else "" end)
          + section(.top_critical_high; "Top Critical / High") + "\n"
          + section(.top_medium_security; "Top Medium Security") + "\n"
          + section(.test_quality; "Test & Quality") + "\n"
          + section(.not_actionable_without_scanner; "Not Actionable Without a Scanner") + "\n"
          + remainder_section(.remainder)
      ' >"$tmp" 2>/dev/null; then
    if mv -f -- "$tmp" "$out" 2>/dev/null; then
      return 0
    fi
  fi

  rm -f -- "$tmp"
  return 1
}
