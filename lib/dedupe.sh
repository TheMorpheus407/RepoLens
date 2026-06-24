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

# RepoLens — Duplicate-group dedupe helpers
# Foundation of the dedupe-agent family (#316 canonical selection -> #322
# matching -> #335 marking -> #353 thresholds -> #343 --local -> #328
# also_reported_by[]). This file SELECTS the canonical record for a group (#316)
# and provides the near-duplicate MATCH predicates (#322); it never mutates
# records, builds the registry, or renders artifacts. Sourced, never executed
# directly. Pure: function-only, no global mutation, safe under
# `set -uo pipefail`.
#
# DEPENDENCY: reuses severity_rank / severity_normalize from lib/core.sh — do
# NOT reimplement severity handling. Callers must `source lib/core.sh` before
# this file. The #322 match predicate additionally reuses the title-similarity
# primitives (_synthesize_normalize_title / _synthesize_title_ngrams /
# _synthesize_jaccard_x10000) from lib/synthesize.sh — do NOT reimplement them.
set -uo pipefail

# _dedupe_is_match reuses the title-similarity primitives from lib/synthesize.sh.
# Source it on demand so this file works standalone (and from its test); when
# repolens.sh has already sourced synthesize.sh the guard is a cheap no-op.
# synthesize.sh transitively sources core.sh, so this also satisfies the
# severity_* dependency above. No top-level side effect beyond loading helpers.
if ! declare -F _synthesize_jaccard_x10000 >/dev/null 2>&1; then
  _dedupe_synth_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/synthesize.sh"
  # shellcheck source=/dev/null
  [[ -f "$_dedupe_synth_lib" ]] && source "$_dedupe_synth_lib"
  unset _dedupe_synth_lib
fi

# _dedupe_pick_canonical <json_array> [id_field=cluster_id]
#   Given a JSON array of finding records belonging to ONE duplicate group,
#   prints the id of the single CANONICAL record on stdout (one line).
#   Deterministic selection rule, applied in order:
#     1. highest severity   (severity_rank, lib/core.sh — NOT reimplemented)
#     2. highest confidence  (numeric; missing/null/unparseable = lowest)
#     3. lexicographically smallest id  (stable tiebreak; order-independent)
#
#   id_field defaults to "cluster_id" so it works on final/manifest.json today;
#   pass "id" for final/findings.jsonl records. Because id is unique within a
#   group, the id tiebreak makes the ordering total -> output is independent of
#   input array order (jq / parallel-collection order is not guaranteed stable).
#
#   Returns non-zero and prints nothing on empty / non-array / invalid input.
#   Pure: no side effects, no globals, no model. Never mutates the input.
#
#   NOTE: this deliberately does NOT use the 0.5 missing-confidence default from
#   _risk_confidence_normalize (lib/risk.sh). That default is a neutral midpoint
#   for *risk scoring* (so unscored findings aren't buried); here the contract is
#   the OPPOSITE — missing/unparseable confidence must rank LOWEST for tiebreak
#   ordering. A `has_conf` tier (present > missing) enforces that regardless of
#   numeric magnitude, including legitimately negative confidence values.
_dedupe_pick_canonical() {
  local array="${1:-}" id_field="${2:-cluster_id}"

  [[ -n "$array" ]] || return 2
  jq -e 'type == "array" and length > 0' >/dev/null 2>&1 <<<"$array" || return 1

  local count i rec sev id conf rank has_conf lines=()
  count="$(jq 'length' <<<"$array")" || return 1

  for (( i = 0; i < count; i++ )); do
    rec="$(jq -c --argjson i "$i" '.[$i]' <<<"$array")" || return 1
    sev="$(jq -r '.severity // ""' <<<"$rec")"
    id="$(jq -r --arg f "$id_field" '.[$f] // ""' <<<"$rec")"
    # Distinguish "absent or null" from a legitimate numeric (including 0).
    conf="$(jq -r 'if has("confidence") and (.confidence != null)
                   then (.confidence | tostring) else "" end' <<<"$rec")"

    rank="$(severity_rank "$sev")" || rank=0

    # Plain decimals only (mirrors lib/risk.sh). Anything else -> missing tier.
    if [[ "$conf" =~ ^-?[0-9]+(\.[0-9]+)?$ || "$conf" =~ ^-?\.[0-9]+$ ]]; then
      has_conf=1
    else
      has_conf=0
      conf=0
    fi

    lines+=("$(printf '%s\t%s\t%s\t%s' "$rank" "$has_conf" "$conf" "$id")")
  done

  # One total, locale-stable sort: severity desc -> present-confidence desc ->
  # confidence desc -> id ascending. Capture-then-slice (NOT `| head -1`) so a
  # closed pipe never SIGPIPE-flakes `sort` under `set -uo pipefail`.
  local sorted first
  sorted="$(printf '%s\n' "${lines[@]}" \
    | LC_ALL=C sort -t$'\t' -k1,1nr -k2,2nr -k3,3nr -k4,4)"
  first="${sorted%%$'\n'*}"
  printf '%s\n' "${first##*$'\t'}"
}

# _dedupe_location_key <record_json>
#   Derives a normalized, comparable location string from whatever location
#   signal a finding record exposes, and prints it on stdout (one line, no
#   trailing newline). Used as the location signal for _dedupe_is_match.
#
#   SOURCE PRECEDENCE (first non-empty wins; documented contract):
#     1. .primary_location          (forward-looking findings.jsonl field; a
#                                     "path:line" string when present)
#     2. first non-empty .suspect_files[]        (cluster-rule field; may be
#                                                  present on some records)
#     3. first non-empty .source_finding_paths[] (always present on valid
#                                                  manifest records, but a WEAK
#                                                  cross-domain signal — lens
#                                                  output paths differ per lens)
#     4. else the empty string                   (no crash; deterministic)
#
#   NORMALIZATION applied to the chosen raw value (so the same file keys equal
#   regardless of surface form):
#     - trim surrounding whitespace
#     - lowercase
#     - backslashes -> forward slashes
#     - collapse duplicate slashes
#     - strip a leading "./"
#     - drop a trailing ":<line>" (and optional ":<col>") suffix — same file,
#       different line, keys the same ("drop the line", not bucket)
#
#   Deterministic and total: missing/null location fields, a non-object record,
#   or invalid JSON all yield the empty key. NEVER errors the pipeline (always
#   returns 0). Pure: no side effects, no globals, no model. Never mutates input.
_dedupe_location_key() {
  local record="${1:-}"
  [[ -n "$record" ]] || { printf ''; return 0; }

  local key
  key="$(jq -rj '
    def firststr($arr):
      ([ ($arr // [])[]? | select(type == "string") | select(length > 0) ]
       | (.[0] // ""));
    def normalize_loc($s):
      ( $s
        | sub("^\\s+"; "") | sub("\\s+$"; "")
        | ascii_downcase
        | gsub("\\\\"; "/")
        | gsub("/+"; "/")
        | sub("^(\\./)+"; "")
        | sub(":[0-9]+(:[0-9]+)?$"; "") );
    if type != "object" then ""
    else
      ( if ((.primary_location | type) == "string")
           and ((.primary_location | length) > 0)
        then .primary_location
        else
          ( firststr(.suspect_files) as $sf
            | if ($sf | length) > 0 then $sf
              else firststr(.source_finding_paths)
              end )
        end ) as $raw
      | normalize_loc($raw)
    end
  ' <<<"$record" 2>/dev/null)" || { printf ''; return 0; }

  printf '%s' "$key"
}

# _dedupe_is_match <record_a_json> <record_b_json>
#   Exit-code predicate (idiomatic bash): returns 0 when the two finding
#   records are near-duplicates, non-zero otherwise. Use as:
#       if _dedupe_is_match "$a" "$b"; then ... ; fi
#
#   Two records MATCH when EITHER:
#     (1) title Jaccard similarity >= DEDUPE_TITLE_SIM_PRIMARY   (title alone)
#     (2) both location keys are non-empty AND equal, AND title Jaccard
#         similarity >= DEDUPE_TITLE_SIM_SECONDARY               (same file +
#                                                                  lower bar)
#
#   The match is CROSS-DOMAIN by design: .domain is never compared. Two records
#   from different lenses/domains that point at the same file with similar
#   wording therefore match (the "Empty-CN mTLS" case).
#
#   Title similarity reuses the existing primitives from lib/synthesize.sh
#   (_synthesize_normalize_title -> _synthesize_title_ngrams ->
#   _synthesize_jaccard_x10000); location uses _dedupe_location_key above.
#
#   Thresholds are module-level defaults, env-overridable (so #353 tuning and
#   tests can pin them without code changes), expressed as Jaccard x10000:
#     DEDUPE_TITLE_SIM_PRIMARY    default 8500 (0.85) — aligns with the existing
#                                 validate_manifest title bar.
#     DEDUPE_TITLE_SIM_SECONDARY  default 6000 (0.60) — lower bar that only
#                                 applies once location agrees.
#   Comparison is inclusive (>=), per the issue.
#
#   GUARD: two empty location keys are NOT a location match — equality of keys
#   only counts when BOTH are non-empty. Without this, every location-less pair
#   would collapse at the lower threshold. Pure: no side effects, no model.
_dedupe_is_match() {
  local rec_a="${1:-}" rec_b="${2:-}"
  local primary="${DEDUPE_TITLE_SIM_PRIMARY:-8500}"
  local secondary="${DEDUPE_TITLE_SIM_SECONDARY:-6000}"

  local title_a title_b
  title_a="$(jq -r 'if type == "object" then (.title // "") else "" end' \
    <<<"$rec_a" 2>/dev/null)" || title_a=""
  title_b="$(jq -r 'if type == "object" then (.title // "") else "" end' \
    <<<"$rec_b" 2>/dev/null)" || title_b=""

  local na nb ga gb sim
  na="$(_synthesize_normalize_title "$title_a")"
  nb="$(_synthesize_normalize_title "$title_b")"
  ga="$(_synthesize_title_ngrams "$na")"
  gb="$(_synthesize_title_ngrams "$nb")"
  sim="$(_synthesize_jaccard_x10000 "$ga" "$gb")"

  # Primary signal: title similarity alone is enough.
  if (( ${sim:-0} >= primary )); then
    return 0
  fi

  # Secondary signal: same (non-empty) location + a lower title bar.
  local ka kb
  ka="$(_dedupe_location_key "$rec_a")"
  kb="$(_dedupe_location_key "$rec_b")"
  if [[ -n "$ka" && -n "$kb" && "$ka" == "$kb" ]] \
     && (( ${sim:-0} >= secondary )); then
    return 0
  fi

  return 1
}
