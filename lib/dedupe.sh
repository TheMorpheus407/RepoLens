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
# also_reported_by[]). This file only SELECTS the canonical record for a group;
# it never mutates records, builds the registry, or renders artifacts. Sourced,
# never executed directly. Pure: function-only, no top-level side effects, no
# global mutation, safe under `set -uo pipefail`.
#
# DEPENDENCY: reuses severity_rank / severity_normalize from lib/core.sh — do
# NOT reimplement severity handling. Callers must `source lib/core.sh` before
# this file.
set -uo pipefail

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
