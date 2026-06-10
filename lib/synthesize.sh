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

# RepoLens — synthesizer dispatcher and manifest validator.
#
# This module is sourceable; it defines functions only and has no top-level
# side effects beyond loading shared helpers.

if ! declare -F severity_normalize >/dev/null 2>&1; then
  _synthesize_core_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/core.sh"
  # shellcheck source=/dev/null
  [[ -f "$_synthesize_core_lib" ]] && source "$_synthesize_core_lib"
  unset _synthesize_core_lib
fi

# _synthesize_repo_root
#   Resolves the repository root from this file's location. Used to locate
#   prompts/_base/synthesize.md and to compute default LOG_BASE values when
#   the caller has not exported one.
_synthesize_repo_root() {
  local source_dir
  source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s' "$(cd "$source_dir/.." && pwd)"
}

# _synthesize_log_base <run_id>
#   Returns the run log base directory. Honors the global LOG_BASE when set
#   (so the orchestrator and tests can redirect output) and otherwise falls
#   back to <repo_root>/logs/<run_id>.
_synthesize_log_base() {
  local run_id="${1:-}"
  if [[ -n "${LOG_BASE:-}" ]]; then
    printf '%s' "$LOG_BASE"
    return 0
  fi
  printf '%s/logs/%s' "$(_synthesize_repo_root)" "$run_id"
}

# _synthesize_extract_json_array <text>
#   Reads stdin and prints the first balanced top-level JSON array found in
#   the input. Strips Markdown code fences (```json … ```), then walks the
#   string keeping track of string and escape state to find the outermost
#   '[' … ']' pair. Returns 1 if no balanced array is found.
_synthesize_extract_json_array() {
  local input="$1" stripped="" line
  while IFS= read -r line; do
    case "$line" in
      '```'*|'~~~'*) continue ;;
    esac
    stripped+="$line"$'\n'
  done <<< "$input"

  local len="${#stripped}" i=0 ch start=-1 depth=0 in_string=0 escaped=0
  for (( i = 0; i < len; i++ )); do
    ch="${stripped:i:1}"
    if (( in_string )); then
      if (( escaped )); then
        escaped=0
      elif [[ "$ch" == "\\" ]]; then
        escaped=1
      elif [[ "$ch" == '"' ]]; then
        in_string=0
      fi
      continue
    fi

    case "$ch" in
      '"') in_string=1 ;;
      '[')
        if (( depth == 0 )); then
          start=$i
        fi
        depth=$((depth + 1))
        ;;
      ']')
        depth=$((depth - 1))
        if (( depth == 0 && start >= 0 )); then
          printf '%s' "${stripped:start:i - start + 1}"
          return 0
        fi
        ;;
    esac
  done
  return 1
}

# _synthesize_normalize_title <title>
#   Lowercases the title, strips an optional leading "[severity]" prefix,
#   collapses non-alphanumeric runs to single spaces, and trims.
_synthesize_normalize_title() {
  local title="${1:-}"
  if [[ "$title" =~ ^\[([A-Za-z]+)\][[:space:]]*(.*)$ ]]; then
    if [[ -n "$(severity_normalize "${BASH_REMATCH[1]}")" ]]; then
      title="${BASH_REMATCH[2]}"
    fi
  fi
  title="${title,,}"
  local out="" ch i len="${#title}"
  for (( i = 0; i < len; i++ )); do
    ch="${title:i:1}"
    case "$ch" in
      [a-z0-9]) out+="$ch" ;;
      *) out+=' ' ;;
    esac
  done
  out="${out## }"
  out="${out%% }"
  while [[ "$out" == *"  "* ]]; do
    out="${out//  / }"
  done
  printf '%s' "$out"
}

_synthesize_normalize_manifest_severities() {
  local manifest="$1" tmp next idx severity normalized
  tmp="${manifest}.severity.$$"
  next="${tmp}.next"

  if ! jq '.' "$manifest" > "$tmp"; then
    rm -f "$tmp" "$next"
    return 1
  fi

  while IFS=$'\t' read -r idx severity; do
    normalized="$(severity_normalize "$severity")"
    [[ -n "$normalized" ]] || continue
    if ! jq --argjson idx "$idx" --arg severity "$normalized" \
        '.[$idx].severity = $severity' "$tmp" > "$next"; then
      rm -f "$tmp" "$next"
      return 1
    fi
    mv "$next" "$tmp"
  done < <(jq -r 'to_entries[] | select(.value | type == "object") | [.key, (.value.severity // "")] | @tsv' "$manifest")

  if ! mv "$tmp" "$manifest"; then
    rm -f "$tmp" "$next"
    return 1
  fi
  rm -f "$next"
}

_synthesize_content_mode_enabled() {
  local mode="${REPOLENS_MODE:-${MODE:-}}"
  [[ "$mode" == "content" ]]
}

_synthesize_log_min_severity_info() {
  local message="$1"
  if declare -F log_info >/dev/null 2>&1 && [[ -n "${_REPOLENS_LOG_FILE:-}" ]]; then
    log_info "$message"
  fi
}

_synthesize_log_min_severity_warn() {
  local message="$1"
  if declare -F log_warn >/dev/null 2>&1; then
    log_warn "$message"
  else
    printf '[WARN] %s\n' "$message" >&2
  fi
}

# _synthesize_filter_manifest_min_severity <manifest_path> <min_severity> [verification_path]
#   Filters create-issue manifest entries below the configured severity
#   threshold. Comment cross-link actions attached to valid severity-bearing
#   entries below the threshold are preserved in a sidecar consumed by
#   lib/filing.sh, but only when the original entry would pass the same
#   WRONG-source verification rule used for manifest entries.
_synthesize_filter_manifest_min_severity() {
  local manifest="${1:-}" min_severity="${2:-}" verification="${3:-}" tmp preserved preserved_tmp verification_json content_mode

  [[ -n "$manifest" && -f "$manifest" ]] || return 2
  [[ -n "$min_severity" ]] || return 0

  min_severity="$(severity_normalize "$min_severity")"
  [[ -n "$min_severity" ]] || return 2

  if ! _synthesize_normalize_manifest_severities "$manifest"; then
    return 1
  fi

  content_mode=0
  if _synthesize_content_mode_enabled; then
    content_mode=1
  fi

  tmp="${manifest}.filtered.$$"
  preserved="$(dirname "$manifest")/cross-link-actions.preserved.json"
  preserved_tmp="${preserved}.tmp.$$"
  verification_json='[]'
  if [[ -n "$verification" && -f "$verification" ]]; then
    verification_json="$(jq -c '.' "$verification")" || {
      rm -f "$tmp" "$preserved_tmp"
      return 1
    }
  fi

  local filter_decisions
  filter_decisions="$(jq -c --arg min "$min_severity" --argjson content_mode "$content_mode" '
    def is_content_priority_proposal:
      (.title // "" | test("^\\[[Pp][0-3]\\][[:space:]]*"));
    def order: ["low","medium","high","critical"];
    def rank($s): order | index($s);
    .[]
    | select(type == "object")
    | select(($content_mode == 1 and is_content_priority_proposal) | not)
    | rank(.severity) as $severity_rank
    | if $severity_rank == null then
        {
          type: "invalid",
          domain: (.domain // "<unknown>" | tostring),
          lens: (.lens // "<unknown>" | tostring),
          title: (.title // "<untitled>" | tostring),
          severity: (if has("severity") then (.severity // "" | tostring) else "" end)
        }
      elif $severity_rank < rank($min) then
        {
          type: "below",
          domain: (.domain // "<unknown>" | tostring),
          lens: (.lens // "<unknown>" | tostring),
          title: (.title // "<untitled>" | tostring),
          severity: (.severity | tostring)
        }
      else empty end
  ' "$manifest" 2>/dev/null)" || {
    rm -f "$tmp" "$preserved_tmp"
    return 1
  }

  if ! jq --arg min "$min_severity" --argjson content_mode "$content_mode" '
    def is_content_priority_proposal:
      (.title // "" | test("^\\[[Pp][0-3]\\][[:space:]]*"));
    def order: ["low","medium","high","critical"];
    def rank($s): order | index($s);
    def keep_for_min_severity:
      if $content_mode == 1 and is_content_priority_proposal then true
      elif rank(.severity) == null then false
      else rank(.severity) >= rank($min)
      end;
    [ .[] | select(keep_for_min_severity) ]
  ' "$manifest" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi

  if ! jq --arg min "$min_severity" --argjson content_mode "$content_mode" --argjson verification "$verification_json" '
    def is_content_priority_proposal:
      (.title // "" | test("^\\[[Pp][0-3]\\][[:space:]]*"));
    def order: ["low","medium","high","critical"];
    def rank($s): order | index($s);
    def preserve_as_below_threshold:
      if $content_mode == 1 and is_content_priority_proposal then false
      elif rank(.severity) == null then false
      else rank(.severity) < rank($min)
      end;
    def wrong_only_paths($v):
      ([ $v[]? | select(.status == "WRONG") | .source_finding_path // empty ] | unique) as $wrong
      | [ $v[]? | select(.status != "WRONG") | .source_finding_path // empty ] as $notwrong
      | $wrong
      | map(. as $p | select(($notwrong | index($p)) == null));
    wrong_only_paths($verification) as $wrong_only
    | [
      .[]
      | select(preserve_as_below_threshold)
      | . as $entry
      | (($entry.source_finding_paths // []) | length) as $path_count
      | ([($entry.source_finding_paths // [])[] | . as $path | select(($wrong_only | index($path)) != null)] | length) as $wrong_count
      | select(($path_count == 0) or ($wrong_count != $path_count))
      | $entry.cluster_id as $cid
      | ($entry.cross_link_actions // [])[]
      | select(.type == "comment")
      | { cluster_id: $cid, source_finding_paths: ($entry.source_finding_paths // []), type, issue_number, body }
    ]
  ' "$manifest" > "$preserved_tmp"; then
    rm -f "$tmp" "$preserved_tmp"
    return 1
  fi

  if [[ "$(jq 'length' "$preserved_tmp" 2>/dev/null || echo 0)" == "0" ]]; then
    rm -f "$preserved" "$preserved_tmp"
  else
    mv "$preserved_tmp" "$preserved" || {
      rm -f "$tmp" "$preserved_tmp"
      return 1
    }
  fi

  if ! mv "$tmp" "$manifest"; then
    rm -f "$tmp"
    return 1
  fi

  local filtered_count=0
  if [[ -n "$filter_decisions" ]]; then
    local decision decision_type domain lens title severity
    while IFS= read -r decision; do
      [[ -n "$decision" ]] || continue
      decision_type="$(jq -r '.type' <<< "$decision")"
      domain="$(jq -r '.domain' <<< "$decision")"
      lens="$(jq -r '.lens' <<< "$decision")"
      title="$(jq -r '.title' <<< "$decision")"
      severity="$(jq -r '.severity' <<< "$decision")"
      case "$decision_type" in
        below)
          _synthesize_log_min_severity_info "[$domain/$lens] Dropped finding \"$title\" (severity=$severity < min=$min_severity)"
          ;;
        invalid)
          _synthesize_log_min_severity_warn "[$domain/$lens] Finding \"$title\" has invalid severity: \"$severity\" (expected critical, high, medium, or low) - skipping"
          ;;
      esac
      filtered_count=$((filtered_count + 1))
    done <<< "$filter_decisions"
  fi

  if (( filtered_count > 0 )) && [[ -n "${SUMMARY_FILE:-}" ]] && declare -F increment_findings_filtered >/dev/null 2>&1; then
    increment_findings_filtered "$SUMMARY_FILE" "$filtered_count" || return 1
  fi
}

# _synthesize_title_ngrams <normalized_title>
#   Emits one n-gram per line. Uses trigrams when the title has at least
#   three tokens, bigrams for two tokens, and unigrams for one. Returns
#   nothing for empty input.
_synthesize_title_ngrams() {
  local normalized="${1:-}"
  [[ -n "$normalized" ]] || return 0
  local -a tokens=()
  read -ra tokens <<< "$normalized"
  local n="${#tokens[@]}" i
  if (( n >= 3 )); then
    for (( i = 0; i + 2 < n; i++ )); do
      printf '%s %s %s\n' "${tokens[i]}" "${tokens[i+1]}" "${tokens[i+2]}"
    done
  elif (( n == 2 )); then
    printf '%s %s\n' "${tokens[0]}" "${tokens[1]}"
  elif (( n == 1 )); then
    printf '%s\n' "${tokens[0]}"
  fi
}

# _synthesize_jaccard_x10000 <ngrams_a> <ngrams_b>
#   Computes Jaccard similarity scaled to 10000. The two arguments are
#   newline-separated n-gram lists. Returns 0 when both lists are empty.
_synthesize_jaccard_x10000() {
  local a="$1" b="$2"
  local -A set_a=() set_b=()
  local line union=0 intersection=0
  if [[ -n "$a" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      set_a["$line"]=1
    done <<< "$a"
  fi
  if [[ -n "$b" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      set_b["$line"]=1
    done <<< "$b"
  fi
  for line in "${!set_a[@]}"; do
    union=$((union + 1))
    if [[ -n "${set_b[$line]:-}" ]]; then
      intersection=$((intersection + 1))
    fi
  done
  for line in "${!set_b[@]}"; do
    [[ -n "${set_a[$line]:-}" ]] && continue
    union=$((union + 1))
  done
  if (( union == 0 )); then
    printf '0'
    return 0
  fi
  printf '%d' $(( intersection * 10000 / union ))
}

# validate_manifest <manifest_path>
#   Validates a synthesizer manifest. Performs:
#     1. JSON parse and top-level-array shape check.
#     2. Per-entry schema check on required S1 fields.
#     3. Pairwise Jaccard title-similarity check (> 0.85 threshold).
#     4. Cross-link gate: when CROSS_LINK_MODE=off (env), every entry's
#        cross_link_actions[] MUST be empty.
#   Reports every failure to stderr. Returns 0 on success, non-zero on any
#   failure. Extra fields are accepted (forward compatibility).
validate_manifest() {
  local manifest="${1:-}"
  if [[ -z "$manifest" ]]; then
    echo "validate_manifest: missing manifest path" >&2
    return 2
  fi
  if [[ ! -f "$manifest" ]]; then
    echo "validate_manifest: manifest not found: $manifest" >&2
    return 2
  fi

  if ! jq -e . "$manifest" >/dev/null 2>&1; then
    echo "validate_manifest: not valid JSON: $manifest" >&2
    return 1
  fi

  if ! jq -e 'type == "array"' "$manifest" >/dev/null 2>&1; then
    echo "validate_manifest: top-level value is not an array" >&2
    return 1
  fi

  local errors=0 entry_count content_mode
  content_mode=0
  if _synthesize_content_mode_enabled; then
    content_mode=1
  fi
  entry_count="$(jq 'length' "$manifest")" || return 1

  if (( entry_count == 0 )); then
    return 0
  fi

  if ! _synthesize_normalize_manifest_severities "$manifest"; then
    echo "validate_manifest: failed to normalize manifest severity values" >&2
    return 1
  fi

  local schema_errors
  schema_errors="$(jq -r --argjson content_mode "$content_mode" '
    def is_content_priority_proposal:
      (.title // "" | test("^\\[[Pp][0-3]\\][[:space:]]*"));
    def is_nonempty_string: type == "string" and length > 0;
    def severities: ["critical","high","medium","low"];
    def granularities: ["independent","cluster"];
    def cross_link_types: ["comment","reopen-suggestion"];
    def verification_statuses: ["verified","stale","wrong","unknown"];
    def severity_required($v):
      ($content_mode != 1) or (($v | is_content_priority_proposal) | not);

    to_entries[] as $e
    | $e.key as $i
    | $e.value as $v
    | (
        if ($v | type) != "object" then "entry \($i): not an object" else empty end,
        if ($v.title // "" | is_nonempty_string | not) then "entry \($i): missing or empty title" else empty end,
        if ($v.body // "" | is_nonempty_string | not) then "entry \($i): missing or empty body" else empty end,
        if ($v.cluster_id // "" | is_nonempty_string | not) then "entry \($i): missing or empty cluster_id" else empty end,
        if ($v.root_cause_category // "" | is_nonempty_string | not) then "entry \($i): missing or empty root_cause_category" else empty end,
        if ($v.domain // "" | is_nonempty_string | not) then "entry \($i): missing or empty domain" else empty end,
        if ($v.lens // "" | is_nonempty_string | not) then "entry \($i): missing or empty lens" else empty end,
        if severity_required($v) and (severities | index($v.severity // "")) == null then "entry \($i): invalid severity \($v.severity // null | tostring)" else empty end,
        if (granularities | index($v.granularity // "")) == null then "entry \($i): invalid granularity \($v.granularity // null | tostring)" else empty end,
        if ($v | has("verification_status")) and (verification_statuses | index($v.verification_status // "")) == null then "entry \($i): invalid verification_status \($v.verification_status // null | tostring)" else empty end,
        if ($v.source_finding_paths | type) != "array" then "entry \($i): source_finding_paths must be an array"
          elif ($v.source_finding_paths | length) == 0 then "entry \($i): source_finding_paths must be non-empty"
          elif ([ $v.source_finding_paths[] | is_nonempty_string ] | all | not) then "entry \($i): source_finding_paths entries must be non-empty strings"
          else empty end,
        if ($v.dedup_against_existing | type) != "array" then "entry \($i): dedup_against_existing must be an array"
          else (
            $v.dedup_against_existing | to_entries[] as $de
            | (
                if ($de.value | type) != "object" then "entry \($i).dedup_against_existing[\($de.key)]: not an object"
                  elif ($de.value.issue_number | type) != "number" then "entry \($i).dedup_against_existing[\($de.key)]: issue_number must be a number"
                  elif ($de.value.reason // "" | is_nonempty_string | not) then "entry \($i).dedup_against_existing[\($de.key)]: reason must be non-empty"
                  else empty end
              )
          ) end,
        if ($v.proposed_labels | type) != "array" then "entry \($i): proposed_labels must be an array"
          elif ([ $v.proposed_labels[]? | is_nonempty_string ] | all | not) then "entry \($i): proposed_labels entries must be non-empty strings"
          else empty end,
        if ($v.cross_link_actions | type) != "array" then "entry \($i): cross_link_actions must be an array"
          else (
            $v.cross_link_actions | to_entries[] as $ca
            | (
                if ($ca.value | type) != "object" then "entry \($i).cross_link_actions[\($ca.key)]: not an object"
                  elif (cross_link_types | index($ca.value.type // "")) == null then "entry \($i).cross_link_actions[\($ca.key)]: invalid type \($ca.value.type // null | tostring)"
                  elif ($ca.value.issue_number | type) != "number" then "entry \($i).cross_link_actions[\($ca.key)]: issue_number must be a number"
                  elif ($ca.value.body // "" | is_nonempty_string | not) then "entry \($i).cross_link_actions[\($ca.key)]: body must be non-empty"
                  else empty end
              )
          ) end
      )
  ' "$manifest" 2>/dev/null)"

  if [[ -n "$schema_errors" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      echo "validate_manifest: schema error: $line" >&2
      errors=$((errors + 1))
    done <<< "$schema_errors"
  fi

  # Cross-link gate: when CROSS_LINK_MODE=off, every entry's
  # cross_link_actions[] must be empty. The synthesizer prompt is supposed to
  # honor this, but the validator is the last line of defense against an
  # agent that ignores the gate.
  if [[ "${CROSS_LINK_MODE:-off}" == "off" ]]; then
    local off_violations
    off_violations="$(jq -r '
      to_entries[]
      | select((.value.cross_link_actions // []) | length > 0)
      | "entry \(.key): cross_link_actions must be empty when CROSS_LINK_MODE=off"
    ' "$manifest" 2>/dev/null)"
    if [[ -n "$off_violations" ]]; then
      while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        echo "validate_manifest: $line" >&2
        errors=$((errors + 1))
      done <<< "$off_violations"
    fi
  elif [[ "${CROSS_LINK_MODE:-}" == "comment" ]]; then
    # In comment mode the synthesizer must not emit reopen-suggestion.
    local comment_violations
    comment_violations="$(jq -r '
      to_entries[] as $e
      | ($e.value.cross_link_actions // [])
      | to_entries[]
      | select(.value.type == "reopen-suggestion")
      | "entry \($e.key).cross_link_actions[\(.key)]: reopen-suggestion not allowed when CROSS_LINK_MODE=comment"
    ' "$manifest" 2>/dev/null)"
    if [[ -n "$comment_violations" ]]; then
      while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        echo "validate_manifest: $line" >&2
        errors=$((errors + 1))
      done <<< "$comment_violations"
    fi
  fi

  if (( errors > 0 )); then
    return 1
  fi

  local -a titles=()
  local title
  while IFS= read -r title; do
    titles+=("$title")
  done < <(jq -r '.[].title // ""' "$manifest")

  local n="${#titles[@]}" i j sim normalized
  local -a normalized_titles=() ngram_lists=()
  for (( i = 0; i < n; i++ )); do
    normalized="$(_synthesize_normalize_title "${titles[i]}")"
    normalized_titles+=("$normalized")
    ngram_lists+=("$(_synthesize_title_ngrams "$normalized")")
  done

  for (( i = 0; i < n; i++ )); do
    for (( j = i + 1; j < n; j++ )); do
      if [[ -z "${normalized_titles[i]}" && -z "${normalized_titles[j]}" ]]; then
        continue
      fi
      sim="$(_synthesize_jaccard_x10000 "${ngram_lists[i]}" "${ngram_lists[j]}")"
      if (( sim > 8500 )); then
        echo "validate_manifest: near-duplicate titles (similarity ${sim}/10000):" >&2
        echo "  [${i}] ${titles[i]}" >&2
        echo "  [${j}] ${titles[j]}" >&2
        errors=$((errors + 1))
      fi
    done
  done

  if (( errors > 0 )); then
    return 1
  fi
  return 0
}

# validate_manifest_against_verification <manifest_path> <verification_path>
#   Enforces the B4 -> S2/S4 propagation rule from prompts/_base/synthesize.md:
#   "Do not emit a cluster whose contributing findings are all WRONG." This
#   is the deterministic counterpart of the synthesizer prompt's verification
#   gate — the prompt should obey the rule, this validator is the last line
#   of defense when an agent ignores it.
#
#   Algorithm:
#     1. Build the WRONG set: every verification entry whose status is WRONG
#        contributes its `source_finding_path` to a "WRONG-only" set, IFF no
#        non-WRONG verification entry claims the same path. A single source
#        finding path can carry several findings (separated by `---`); if at
#        least one of them is VERIFIED or STALE, the path is not WRONG-only
#        and a cluster citing it remains legitimate.
#     2. For every manifest entry, intersect its `source_finding_paths[]`
#        against the WRONG-only set. If the cluster's path list is non-empty
#        and EVERY path is WRONG-only, the cluster is leaking a WRONG finding
#        and the manifest is rejected.
#
#   Returns 0 when no WRONG-only cluster is found, 1 on the first violation.
#   Reports the offending cluster_id and the WRONG-only paths on stderr.
#   When verification.json is absent or empty, this is a no-op (return 0):
#   the verifier did not run, so there is nothing to propagate.
validate_manifest_against_verification() {
  local manifest="${1:-}"
  local verification="${2:-}"

  if [[ -z "$manifest" || ! -f "$manifest" ]]; then
    echo "validate_manifest_against_verification: manifest not found: $manifest" >&2
    return 2
  fi
  if [[ -z "$verification" || ! -f "$verification" ]]; then
    return 0
  fi

  if ! jq -e . "$verification" >/dev/null 2>&1; then
    echo "validate_manifest_against_verification: verification.json is not valid JSON" >&2
    return 1
  fi

  local wrong_only_paths
  wrong_only_paths="$(jq -r '
    [ .[] | select(.status == "WRONG") | .source_finding_path // empty ] as $wrong
    | [ .[] | select(.status != "WRONG") | .source_finding_path // empty ] as $notwrong
    | $wrong
    | unique
    | .[]
    | . as $p
    | select( ($notwrong | index($p)) == null )
  ' "$verification" 2>/dev/null)"

  if [[ -z "$wrong_only_paths" ]]; then
    return 0
  fi

  # Build a newline-separated set string for fast membership checks via grep.
  local wrong_set
  wrong_set="$wrong_only_paths"

  local violations=0 cid path_count wrong_count
  local cid_list
  cid_list="$(jq -r '.[] | .cluster_id // "<unnamed>"' "$manifest" 2>/dev/null)"
  if [[ -z "$cid_list" ]]; then
    return 0
  fi

  local i=0
  while IFS= read -r cid; do
    [[ -n "$cid" ]] || { i=$((i + 1)); continue; }
    # Read source_finding_paths for this manifest entry.
    local paths
    paths="$(jq -r --argjson i "$i" '.[$i].source_finding_paths[]?' "$manifest" 2>/dev/null)"
    path_count=0
    wrong_count=0
    local p
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      path_count=$((path_count + 1))
      if grep -Fxq -- "$p" <<<"$wrong_set"; then
        wrong_count=$((wrong_count + 1))
      fi
    done <<< "$paths"
    if (( path_count > 0 )) && (( wrong_count == path_count )); then
      echo "validate_manifest_against_verification: cluster '$cid' sources are all marked WRONG by the verifier" >&2
      while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        echo "  WRONG source: $p" >&2
      done <<< "$paths"
      violations=$((violations + 1))
    fi
    i=$((i + 1))
  done <<< "$cid_list"

  if (( violations > 0 )); then
    return 1
  fi
  return 0
}

# run_synthesizer <run_id>
#   Composes the synthesizer prompt, invokes the active agent exactly once,
#   captures the JSON manifest from stdout, validates it, and atomically
#   promotes it to logs/<run-id>/final/manifest.json. If validation fails,
#   the candidate is discarded and no consumable manifest.json remains.
#
#   Required globals: AGENT, PROJECT_PATH.
#   Optional globals: REPO_OWNER, REPO_NAME, FORGE_REPO, ROUNDS,
#                     GRANULARITY_HINT, LOG_BASE.
run_synthesizer() {
  local run_id="${1:-}"
  if [[ -z "$run_id" ]]; then
    echo "run_synthesizer: missing run_id" >&2
    return 2
  fi

  local repo_root run_log_base rounds_dir final_dir candidate prompt_text agent_output
  repo_root="$(_synthesize_repo_root)"
  run_log_base="$(_synthesize_log_base "$run_id")"
  rounds_dir="$run_log_base/rounds"
  final_dir="$run_log_base/final"

  local synthesize_template="$repo_root/prompts/_base/synthesize.md"
  if [[ ! -f "$synthesize_template" ]]; then
    echo "run_synthesizer: synthesizer template missing: $synthesize_template" >&2
    return 2
  fi

  local agent="${AGENT:-}"
  if [[ -z "$agent" ]]; then
    echo "run_synthesizer: AGENT is not set" >&2
    return 2
  fi
  local project_path="${PROJECT_PATH:-}"
  if [[ -z "$project_path" || ! -d "$project_path" ]]; then
    echo "run_synthesizer: PROJECT_PATH must be a directory: $project_path" >&2
    return 2
  fi

  mkdir -p "$final_dir" || {
    echo "run_synthesizer: cannot create final dir: $final_dir" >&2
    return 1
  }

  # Clear any stale manifest from a previous run before invoking the agent.
  # This makes the "fatal validation leaves nothing consumable" guarantee
  # hold across every failure path, not just post-validation failures.
  rm -f "$final_dir/manifest.json"
  rm -f "$final_dir/cross-link-actions.preserved.json"

  local total_findings=0
  if [[ -d "$rounds_dir" ]]; then
    total_findings=$(find "$rounds_dir" -path '*/lens-outputs/*' -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
  fi

  # Zero findings require no model work. Write the canonical empty manifest so
  # downstream consumers can distinguish a correct empty run from synthesis
  # failure.
  if (( total_findings == 0 )); then
    candidate="$final_dir/manifest.json.tmp.$$"
    if ! printf '[]\n' > "$candidate"; then
      echo "run_synthesizer: failed to write empty manifest.json" >&2
      rm -f "$candidate"
      return 1
    fi
    if ! mv "$candidate" "$final_dir/manifest.json"; then
      echo "run_synthesizer: failed to promote empty manifest.json" >&2
      rm -f "$candidate"
      return 1
    fi
    return 0
  fi

  local total_rounds="${ROUNDS:-1}"
  local granularity_hint="${GRANULARITY_HINT:-auto}"
  local repo_owner="${REPO_OWNER:-}"
  local repo_name="${REPO_NAME:-}"
  local forge_repo="${FORGE_REPO:-}"
  if [[ -z "$forge_repo" && -n "$repo_owner" && -n "$repo_name" ]]; then
    forge_repo="$repo_owner/$repo_name"
  fi

  local forge_issue_list_open=""
  if declare -F forge_prompt_issue_list >/dev/null 2>&1; then
    forge_issue_list_open="$(forge_prompt_issue_list "open" "$forge_repo" "$project_path")"
  else
    forge_issue_list_open="Use the active forge CLI to list open issues"
  fi

  local cross_link_mode="${CROSS_LINK_MODE:-off}"

  local vars
  vars="RUN_ID=$run_id"
  vars+="|PROJECT_PATH=$project_path"
  vars+="|REPO_OWNER=$repo_owner"
  vars+="|REPO_NAME=$repo_name"
  vars+="|TOTAL_ROUNDS=$total_rounds"
  vars+="|TOTAL_FINDINGS=$total_findings"
  vars+="|GRANULARITY_HINT=$granularity_hint"
  vars+="|CROSS_LINK_MODE=$cross_link_mode"
  vars+="|FORGE_ISSUE_LIST_OPEN=$forge_issue_list_open"

  if ! declare -F compose_prompt >/dev/null 2>&1; then
    echo "run_synthesizer: compose_prompt is not available (source lib/template.sh)" >&2
    return 2
  fi
  if ! declare -F run_agent >/dev/null 2>&1; then
    echo "run_synthesizer: run_agent is not available (source lib/core.sh)" >&2
    return 2
  fi

  prompt_text="$(compose_prompt "$synthesize_template" "$synthesize_template" "$vars")" || {
    echo "run_synthesizer: prompt composition failed" >&2
    return 1
  }

  local transcript_path="$final_dir/synthesizer-output.txt"
  local envelope_path="$transcript_path.envelope.json"
  local agent_rc=0
  run_agent "$agent" "$prompt_text" "$project_path" "" "" "$envelope_path" > "$transcript_path" 2>&1 || agent_rc=$?
  agent_output="$(cat "$transcript_path" 2>/dev/null || true)"
  if declare -F handle_agent_failure_in_phase >/dev/null 2>&1; then
    local phase_rc
    handle_agent_failure_in_phase "synthesizer" "$transcript_path" "$agent_rc" "$envelope_path" "run_synthesizer"
    phase_rc=$?
    if (( phase_rc != 0 )); then
      rm -f "$final_dir/manifest.json"
      rm -f "$final_dir/cross-link-actions.preserved.json"
      if (( phase_rc == 1 )); then
        return 6
      fi
      return "$phase_rc"
    fi
  elif (( agent_rc != 0 )); then
    echo "run_synthesizer: agent invocation failed" >&2
    return 6
  fi

  local extracted
  extracted="$(_synthesize_extract_json_array "$agent_output")" || {
    echo "run_synthesizer: agent output did not contain a JSON array" >&2
    return 4
  }

  candidate="$final_dir/manifest.json.tmp.$$"
  if ! printf '%s\n' "$extracted" > "$candidate"; then
    echo "run_synthesizer: failed to write candidate manifest" >&2
    rm -f "$candidate"
    return 1
  fi

  if [[ -n "${REPOLENS_MIN_SEVERITY:-}" ]]; then
    if ! _synthesize_filter_manifest_min_severity "$candidate" "$REPOLENS_MIN_SEVERITY" "$final_dir/verification.json"; then
      echo "run_synthesizer: failed to apply min-severity filter" >&2
      rm -f "$candidate"
      rm -f "$final_dir/manifest.json"
      rm -f "$final_dir/cross-link-actions.preserved.json"
      return 1
    fi
  fi

  if ! validate_manifest "$candidate"; then
    rm -f "$candidate"
    rm -f "$final_dir/manifest.json"
    rm -f "$final_dir/cross-link-actions.preserved.json"
    return 5
  fi

  # Last line of defense: even if the synthesizer prompt is bypassed or buggy,
  # reject any candidate manifest that smuggles a cluster whose contributing
  # findings were all marked WRONG by the verifier. Absent verification.json
  # is a no-op.
  if ! validate_manifest_against_verification "$candidate" "$final_dir/verification.json"; then
    rm -f "$candidate"
    rm -f "$final_dir/manifest.json"
    rm -f "$final_dir/cross-link-actions.preserved.json"
    return 5
  fi

  if ! mv "$candidate" "$final_dir/manifest.json"; then
    echo "run_synthesizer: failed to promote manifest" >&2
    rm -f "$candidate"
    return 1
  fi

  return 0
}
