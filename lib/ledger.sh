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

# RepoLens — evidence-ledger / finding-registry helpers.
#
# This module is sourceable; it defines functions only and has no top-level
# side effects. It depends on no globals — every function works purely from
# its arguments — so it is safe to source alone under `set -uo pipefail`.
#
# The finding registry (`logs/<run-id>/final/findings.jsonl`, schema in
# docs/finding-registry-schema.md) needs a STABLE `id` so the same finding
# earns the same id across runs and across both source paths (manifest
# clusters and `--local` markdown frontmatter). This module owns that id.
#
# NOTE: this is a DIFFERENT identity from the verifier's per-run
# `_round_digest_finding_id` (lib/rounds.sh): that one is SHA-1 over
# lens/domain/round/suspect-files for matching verification.json entries.
# The registry id below is title-derived (content-stable, not suspect-file
# derived) and carries an `fnd-` prefix to keep the two visually distinct.

# _ledger_normalize_title <title>
#   Normalizes a finding title for stable hashing: lowercases, strips an
#   optional leading "[severity]" prefix (only when the bracketed word is a
#   real severity), collapses non-alphanumeric runs to single spaces, trims.
#
#   Prefers the shared `_synthesize_normalize_title` (lib/synthesize.sh) when
#   it is already sourced, so the two stay in lockstep; otherwise falls back to
#   a self-contained replica so lib/ledger.sh works when sourced on its own.
_ledger_normalize_title() {
  if declare -F _synthesize_normalize_title >/dev/null 2>&1; then
    _synthesize_normalize_title "$1"
    return
  fi

  # Self-contained replica of lib/synthesize.sh::_synthesize_normalize_title.
  # The severity word set (critical|high|medium|low) is inlined to match
  # lib/core.sh::severity_normalize without taking a hard dependency on it.
  local title="${1:-}"
  if [[ "$title" =~ ^\[([A-Za-z]+)\][[:space:]]*(.*)$ ]]; then
    case "${BASH_REMATCH[1],,}" in
      critical|high|medium|low) title="${BASH_REMATCH[2]}" ;;
    esac
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

# _ledger_sha256_hex
#   Reads stdin and prints its lowercase SHA-256 as 64 hex chars. Mirrors the
#   repo's hash cascade (lib/forge.sh::_forge_label_set_hash): sha256sum, then
#   shasum -a 256. No cksum fallback here — the finding id must be a real,
#   collision-resistant content hash, and both tools are present on this host.
_ledger_sha256_hex() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

# finding_id <domain> <lens> <title> [primary_location]
#   Prints a stable, content-derived finding id of the form `fnd-<12 hex>`.
#
#   The title argument is normalized internally (see _ledger_normalize_title),
#   so casing, a leading "[severity]" prefix, and punctuation differences do
#   not change the id. The canonical pre-image is the four fields joined by the
#   ASCII Unit Separator (US, 0x1F), SHA-256 hashed, truncated to 12 hex chars.
#
#   `primary_location` is optional; when omitted it hashes as an empty trailing
#   field (stable). Deterministic: identical args always yield the same id.
finding_id() {
  local domain="${1:-}" lens="${2:-}" title="${3:-}" location="${4:-}"
  local sep=$'\037' norm hex

  norm="$(_ledger_normalize_title "$title")"
  hex="$(printf '%s' "${domain}${sep}${lens}${sep}${norm}${sep}${location}" \
    | _ledger_sha256_hex)"

  printf 'fnd-%s\n' "${hex:0:12}"
}

# _ledger_severity_normalize <value>
#   Canonicalizes a severity to critical|high|medium|low (or "" for anything
#   else). Prefers the shared severity_normalize (lib/core.sh) when it is
#   already sourced; otherwise falls back to a self-contained replica so
#   lib/ledger.sh keeps working when sourced on its own (the same defensive
#   pattern used by _ledger_normalize_title above).
_ledger_severity_normalize() {
  if declare -F severity_normalize >/dev/null 2>&1; then
    severity_normalize "$1"
    return
  fi

  # Self-contained replica of lib/core.sh::severity_normalize.
  local value="${1:-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  if [[ "$value" == \[*\] ]]; then
    value="${value#\[}"
    value="${value%\]}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
  fi
  value="${value,,}"
  case "$value" in
    critical|high|medium|low) printf '%s' "$value" ;;
    *) printf '' ;;
  esac
}

# build_findings_jsonl_from_manifest <manifest_path> <out_jsonl_path>
#   Reads a validated synthesizer manifest (logs/<run-id>/final/manifest.json:
#   a JSON array of cluster objects) and writes the canonical finding registry
#   as JSON Lines — one record per cluster, mapped onto the 12-field schema in
#   docs/finding-registry-schema.md plus a source_finding_paths passthrough.
#
#   Pure: reads the manifest, writes the out file. No required globals;
#   severity_normalize (lib/core.sh) is used when present, else an inline
#   replica (see _ledger_severity_normalize) keeps this sourceable alone.
#
#   Field mapping (notable points):
#   - id        is content-derived via finding_id with an EMPTY primary_location
#               (the manifest carries no file:line); stable across runs.
#   - severity  is run through _ledger_severity_normalize (e.g. "High"->"high").
#   - status    defaults to "new"; verification_status "wrong" ->
#               "likely-false-positive", "stale" -> "needs-validation";
#               everything else (verified/unknown/absent) -> "new"
#               (conservative — "verified" is still "new" to the registry).
#   - duplicate_group is SEEDED from cluster_id; the final dedup grouping is
#               owned by the dedupe agent (#316/#322/#335). cluster_id is a
#               per-run, non-stable handle and must not be confused with id.
#   - type/confidence/markdown_path are null and primary_location is "";
#     validation is an empty object {}. These are owned by sibling agents.
#   - source_finding_paths is passed through verbatim so siblings can trace
#     the underlying evidence.
#
#   jq owns all quoting/escaping: the whole entry is handed to jq via
#   --argjson and fields are read inside jq, so titles/paths with quotes,
#   newlines, shell metacharacters, or unicode survive intact. Only the three
#   computed scalars (id, severity, status) are passed as --arg.
#
#   Empty manifest ([]) -> empty out file (0 lines), exit 0. Output is written
#   atomically (tmp + mv) so a mid-loop failure leaves no partial registry.
#   Returns non-zero on missing args, a missing manifest, or non-array JSON
#   (no output is written in those cases).
build_findings_jsonl_from_manifest() {
  local manifest="${1:-}" out="${2:-}"
  [[ -n "$manifest" ]] || { echo "build_findings_jsonl_from_manifest: missing manifest path" >&2; return 2; }
  [[ -n "$out" ]]      || { echo "build_findings_jsonl_from_manifest: missing out path" >&2; return 2; }
  [[ -f "$manifest" ]] || { echo "build_findings_jsonl_from_manifest: manifest not found: $manifest" >&2; return 2; }
  jq -e 'type == "array"' "$manifest" >/dev/null 2>&1 \
    || { echo "build_findings_jsonl_from_manifest: not a JSON array: $manifest" >&2; return 1; }

  local tmp="${out}.tmp.$$"
  : > "$tmp" || return 1

  local count i entry domain lens title raw_sev sev vstatus status id
  count="$(jq 'length' "$manifest")" || { rm -f "$tmp"; return 1; }
  for (( i = 0; i < count; i++ )); do
    entry="$(jq -c --argjson i "$i" '.[$i]' "$manifest")" || { rm -f "$tmp"; return 1; }
    domain="$(jq -r '.domain // ""'  <<<"$entry")"
    lens="$(jq -r   '.lens // ""'    <<<"$entry")"
    title="$(jq -r  '.title // ""'   <<<"$entry")"
    raw_sev="$(jq -r '.severity // ""' <<<"$entry")"
    vstatus="$(jq -r '.verification_status // ""' <<<"$entry")"

    id="$(finding_id "$domain" "$lens" "$title")"
    sev="$(_ledger_severity_normalize "$raw_sev")"
    status="new"
    case "$vstatus" in
      wrong) status="likely-false-positive" ;;
      stale) status="needs-validation" ;;
    esac

    jq -cn \
      --argjson entry "$entry" \
      --arg id "$id" --arg severity "$sev" --arg status "$status" '
      {
        id: $id,
        title: ($entry.title // ""),
        severity: $severity,
        type: null,
        domain: ($entry.domain // ""),
        lens: ($entry.lens // ""),
        status: $status,
        primary_location: "",
        confidence: null,
        duplicate_group: ($entry.cluster_id // null),
        markdown_path: null,
        validation: {},
        source_finding_paths: ($entry.source_finding_paths // [])
      }' >> "$tmp" || { rm -f "$tmp"; return 1; }
  done

  mv "$tmp" "$out" || { rm -f "$tmp"; return 1; }
}
