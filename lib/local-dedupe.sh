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

# RepoLens — deterministic, model-free dedupe over the --local markdown output.
#
# In --local mode every lens agent writes standalone NNN-<slug>.md finding files
# under <output_dir>/<domain>/<lens>/. Because lenses run independently and in
# parallel, the only existing dedupe (a soft "skip a similar title" prompt
# instruction) misses cross-lens/cross-domain repeats: the same finding lands
# twice under two lenses. This module adds the deterministic post-pass the issue
# (#343) asks for — it runs ONCE after all lenses finish and reconciles the md
# tree, building ON the helpers already written for the manifest path rather than
# reinventing the matching / canonical-selection logic.
#
# Reuses (never reimplements):
#   - build_findings_jsonl_from_local  (lib/ledger.sh)   parse md tree -> records
#   - _synthesize_compute_duplicate_groups (lib/synthesize.sh) union-find grouping
#       which lazy-loads _dedupe_is_match / _dedupe_pick_canonical (lib/dedupe.sh)
#
# MARKING DECISION (least-surprising, documented per the issue): files are marked
# IN PLACE and NEVER deleted or moved. Paths stay stable so markdown_path links
# (and any future build_finding_registry run) don't break and a re-run's recursive
# find never double-counts a relocated file. For each duplicate group of size >= 2:
#   - each NON-canonical file gains `status: duplicate` + a `duplicate_of:` link
#     (canonical path, relative to <output_dir>) in its YAML frontmatter, plus a
#     short body note;
#   - the CANONICAL file gains a sorted `also_reported_by:` frontmatter list
#     ({lens,domain,markdown_path} per contributor) plus a short body note; it is
#     NOT itself marked a duplicate (absence is the safe distinguisher, mirroring
#     lib/synthesize.sh::_synthesize_mark_duplicates).
# Singletons and files without a valid frontmatter block are left byte-identical.
#
# IDEMPOTENT: the pass OWNS the fields/notes it writes. On every run it strips the
# pass-owned frontmatter keys (status:duplicate, duplicate_of, also_reported_by)
# and the sentinel-wrapped body note FIRST, then recomputes them. Grouping keys
# only off title/severity/domain/lens (build_findings_jsonl_from_local derives
# records purely from those frontmatter fields), never off the pass-owned marks,
# so a re-run over an already-deduped tree is byte-identical.
#
# Sourced, never executed directly. No model is invoked anywhere in this file
# (project hard rule + issue AC6): the pass is pure bash + jq + awk.
set -uo pipefail

# _local_dedupe_lib_dir
#   Absolute directory of this file (for the on-demand source of sibling libs).
#   Runs in a subshell so the caller's CWD is never changed.
_local_dedupe_lib_dir() {
  ( cd "$(dirname "${BASH_SOURCE[0]}")" && pwd )
}

# _local_dedupe_mark_file <file> <fm_add> <note>
#   Idempotent in-place YAML-frontmatter + body surgery on one finding file.
#   Single awk pass that STRIPS the pass-owned content first, then re-adds it:
#     - frontmatter: drops a pass-owned `status: duplicate`, any `duplicate_of:`,
#       and the whole `also_reported_by:` block (key + its indented children),
#       then inserts <fm_add> immediately before the closing `---`;
#     - body: drops everything from the `<!-- repolens-dedupe:begin -->` sentinel
#       to EOF and trims trailing blank lines, then appends a fresh, blank-line-
#       separated, sentinel-wrapped note carrying <note>.
#   Because strip removes exactly what add inserts and never perturbs any other
#   line, re-applying the transform is a fixed point (byte-identical).
#
#   <fm_add> may be multi-line (e.g. an also_reported_by: YAML list); both
#   arguments are passed via the environment (literal, no awk escape handling).
#   Caller guarantees <file> has a valid leading frontmatter block (only group
#   members reach here, and those come from build_findings_jsonl_from_local which
#   requires one). Writes atomically (tmp + mv). No model invoked.
_local_dedupe_mark_file() {
  local file="$1" fm_add="$2" note="$3"
  local tmp="${file}.rldedupe.$$"

  RL_FM_ADD="$fm_add" RL_NOTE="$note" awk '
    BEGIN {
      fm_add = ENVIRON["RL_FM_ADD"]
      note   = ENVIRON["RL_NOTE"]
      state  = "pre"     # pre -> fm -> body
      skip_arb = 0       # inside an also_reported_by: block we are dropping
      seen_sentinel = 0  # past the body note sentinel (drop to EOF)
      nb = 0
    }
    {
      if (state == "pre") {
        # First line is the opening "---" (guaranteed valid frontmatter).
        print $0
        state = "fm"
        next
      }
      if (state == "fm") {
        if ($0 == "---") {
          if (length(fm_add) > 0) print fm_add
          print "---"
          state = "body"
          next
        }
        if (skip_arb == 1) {
          if ($0 ~ /^[[:space:]]/) { next }   # indented continuation -> drop
          skip_arb = 0                         # de-indented -> process normally
        }
        if ($0 ~ /^also_reported_by:/)               { skip_arb = 1; next }
        if ($0 ~ /^status:[[:space:]]*["'\'']?duplicate/) { next }
        if ($0 ~ /^duplicate_of:/)                   { next }
        print $0
        next
      }
      # state == body: buffer up to the sentinel, drop the sentinel block + after.
      if (seen_sentinel == 1) { next }
      if ($0 == "<!-- repolens-dedupe:begin -->") { seen_sentinel = 1; next }
      nb++
      body[nb] = $0
      next
    }
    END {
      while (nb > 0 && body[nb] == "") nb--   # trim trailing blank lines
      for (k = 1; k <= nb; k++) print body[k]
      if (length(note) > 0) {
        print ""
        print "<!-- repolens-dedupe:begin -->"
        print note
        print "<!-- repolens-dedupe:end -->"
      }
    }
  ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }

  mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
}

# dedupe_local_markdown <output_dir>
#   Public entry point. Walks the --local md tree under <output_dir>, groups
#   near-duplicate findings with the shared match + canonical-selection helpers,
#   and marks the files in place (see module header). Deterministic + idempotent.
#
#   Returns 0 on success AND on every no-op (missing/empty dir, a single file, or
#   no duplicate groups): callers treat it as best-effort. Returns non-zero only
#   when a required helper is unavailable or a parse/group step fails — the
#   repolens.sh finalize hook is non-fatal and merely warns in that case. No model
#   is ever invoked.
dedupe_local_markdown() {
  local output_dir="${1:-}"
  [[ "${REPOLENS_FINAL_STATE:-finished}" != interrupted ]] || return "${REPOLENS_INTERRUPT_EXIT_CODE:-130}"

  if [[ -z "$output_dir" ]]; then
    echo "dedupe_local_markdown: no output dir given; skipping" >&2
    return 0
  fi
  if [[ ! -d "$output_dir" ]]; then
    echo "dedupe_local_markdown: output dir not found ($output_dir); nothing to dedupe" >&2
    return 0
  fi

  # On-demand source of the reused helpers. repolens.sh sources synthesize.sh but
  # not ledger.sh/dedupe.sh; standalone callers/tests may already have them.
  # Mirrors lib/dedupe.sh's lazy-source-on-demand pattern (cheap no-op when set).
  local _lib_dir
  _lib_dir="$(_local_dedupe_lib_dir)"
  if ! declare -F build_findings_jsonl_from_local >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    [[ -f "$_lib_dir/ledger.sh" ]] && source "$_lib_dir/ledger.sh"
  fi
  if ! declare -F _synthesize_compute_duplicate_groups >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    [[ -f "$_lib_dir/synthesize.sh" ]] && source "$_lib_dir/synthesize.sh"
  fi
  if ! declare -F build_findings_jsonl_from_local >/dev/null 2>&1 \
     || ! declare -F _synthesize_compute_duplicate_groups >/dev/null 2>&1; then
    echo "dedupe_local_markdown: required helpers unavailable; skipping" >&2
    return 1
  fi

  # Scratch dir OUTSIDE output_dir (so it never pollutes the tree being walked /
  # hashed). build_findings_jsonl_from_local writes its own tmp+mv inside here.
  local tmpdir
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/rl-local-dedupe.XXXXXX")" || {
    echo "dedupe_local_markdown: failed to create scratch dir" >&2
    return 1
  }
  local jsonl="$tmpdir/records.jsonl"
  local manifest="$tmpdir/records.json"

  # 1. Parse the md tree into comparable JSON records (reuse — populates
  #    markdown_path, normalized severity, frontmatter domain/lens). Files
  #    without a valid frontmatter block are skipped by the parser, so they
  #    never group and stay byte-identical.
  if ! build_findings_jsonl_from_local "$output_dir" "$jsonl"; then
    echo "dedupe_local_markdown: failed to parse local markdown findings" >&2
    rm -rf "$tmpdir"
    return 1
  fi
  if [[ "${REPOLENS_FINAL_STATE:-finished}" == interrupted ]]; then
    rm -rf "$tmpdir"
    return "${REPOLENS_INTERRUPT_EXIT_CODE:-130}"
  fi

  # 2. Slurp the JSONL into the JSON array the grouping helper expects. Array
  #    index i <-> i-th file in sorted find order (deterministic).
  if ! jq -s '.' "$jsonl" > "$manifest"; then
    echo "dedupe_local_markdown: failed to assemble record array" >&2
    rm -rf "$tmpdir"
    return 1
  fi

  # 3. Group near-duplicates (union-find over _dedupe_is_match) + pick canonical
  #    (_dedupe_pick_canonical). Empty output for < 2 records or no matches.
  local groups_jsonl
  if ! groups_jsonl="$(_synthesize_compute_duplicate_groups "$manifest")"; then
    echo "dedupe_local_markdown: duplicate grouping failed" >&2
    rm -rf "$tmpdir"
    return 1
  fi
  if [[ "${REPOLENS_FINAL_STATE:-finished}" == interrupted ]]; then
    rm -rf "$tmpdir"
    return "${REPOLENS_INTERRUPT_EXIT_CODE:-130}"
  fi

  if [[ -z "$groups_jsonl" ]]; then
    echo "dedupe_local_markdown: no duplicate findings under $output_dir" >&2
    rm -rf "$tmpdir"
    return 0
  fi

  # 4. Mark each duplicate group in place.
  local group canon_idx canon_md canon_rel contrib_idx_json m dup_md
  local arb tsv clens cdomain cmd crel groups_marked=0
  while IFS= read -r group; do
    if [[ "${REPOLENS_FINAL_STATE:-finished}" == interrupted ]]; then
      rm -rf "$tmpdir"
      return "${REPOLENS_INTERRUPT_EXIT_CODE:-130}"
    fi
    [[ -n "$group" ]] || continue
    canon_idx="$(jq -r '.canonical_idx' <<<"$group")" || continue
    canon_md="$(jq -r --argjson k "$canon_idx" '.[$k].markdown_path // ""' "$manifest")"
    [[ -n "$canon_md" && -f "$canon_md" ]] || continue
    canon_rel="${canon_md#"$output_dir"/}"

    # Non-canonical contributor indices (every member except the canonical).
    contrib_idx_json="$(jq -c --argjson c "$canon_idx" \
      '[ .member_indices[] | select(. != $c) ]' <<<"$group")" || continue
    [[ "$(jq 'length' <<<"$contrib_idx_json")" -ge 1 ]] || continue

    # 4a. Mark each non-canonical file: status: duplicate + duplicate_of link.
    while IFS= read -r m; do
      [[ "${REPOLENS_FINAL_STATE:-finished}" != interrupted ]] || break
      [[ -n "$m" ]] || continue
      dup_md="$(jq -r --argjson k "$m" '.[$k].markdown_path // ""' "$manifest")"
      [[ -n "$dup_md" && -f "$dup_md" ]] || continue
      if ! _local_dedupe_mark_file "$dup_md" \
        "$(printf 'status: duplicate\nduplicate_of: %s' "$canon_rel")" \
        "> Duplicate of \`$canon_rel\` — see the canonical finding for the full details."; then
        echo "dedupe_local_markdown: failed to mark duplicate $dup_md" >&2
      fi
    done < <(jq -r '.[]' <<<"$contrib_idx_json")

    if [[ "${REPOLENS_FINAL_STATE:-finished}" == interrupted ]]; then
      rm -rf "$tmpdir"
      return "${REPOLENS_INTERRUPT_EXIT_CODE:-130}"
    fi

    # 4b. Build the sorted also_reported_by: YAML list + annotate the canonical.
    arb='also_reported_by:'
    tsv="$(jq -r --argjson idx "$contrib_idx_json" '
      [ $idx[] as $k
        | { lens: (.[$k].lens // ""), domain: (.[$k].domain // ""), md: (.[$k].markdown_path // "") } ]
      | sort_by(.domain, .lens, .md)
      | .[] | [.lens, .domain, .md] | @tsv
    ' "$manifest")" || tsv=""
    while IFS=$'\t' read -r clens cdomain cmd; do
      [[ -n "${clens}${cdomain}${cmd}" ]] || continue
      crel="${cmd#"$output_dir"/}"
      arb+=$'\n'"  - lens: ${clens}"
      arb+=$'\n'"    domain: ${cdomain}"
      arb+=$'\n'"    markdown_path: ${crel}"
    done <<< "$tsv"

    if ! _local_dedupe_mark_file "$canon_md" "$arb" \
      "> Also reported by other lenses; see \`also_reported_by\` in the frontmatter above."; then
      echo "dedupe_local_markdown: failed to annotate canonical $canon_md" >&2
    fi

    groups_marked=$((groups_marked + 1))
  done <<< "$groups_jsonl"

  rm -rf "$tmpdir"
  echo "dedupe_local_markdown: reconciled $groups_marked duplicate group(s) under $output_dir" >&2
  return 0
}
