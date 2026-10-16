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
# side effects. Nearly every function works purely from its arguments — so it
# is safe to source alone under `set -uo pipefail`. The sole exception is the
# `build_finding_registry` orchestrator, which reads the optional `LOG_BASE`
# and `OUTPUT_DIR` globals (both `${VAR:-}`-guarded) to resolve where the
# registry lands and where to find a local `--local` md tree.
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

# _ledger_complexity_normalize <value>
#   Canonicalizes a task-complexity estimate (issue #385) to an INTEGER 1..5
#   (printed as a bare digit) or "" for anything else — absent, out-of-range
#   (0, 6, 7, ...), non-integer (2.5), or non-numeric. Trims surrounding
#   whitespace and strips one surrounding pair of matching quotes first, so a
#   YAML-quoted "5" normalizes exactly like a bare 5. Complexity is an
#   orthogonal, OPTIONAL routing tier AUTHORED by the audit model; bash only
#   parses and range-checks it — it never scores or infers it (no LLM logic in
#   the tool, per CLAUDE.md). Out-of-range is REJECTED to "" rather than clamped
#   so a miscalibrated model surfaces as null, not a false-legal tier. Pure;
#   set -u safe with a missing/empty arg.
_ledger_complexity_normalize() {
  local value="${1:-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  value="${value#\"}"; value="${value%\"}"
  value="${value#\'}"; value="${value%\'}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  case "$value" in
    1|2|3|4|5) printf '%s' "$value" ;;
    *) printf '' ;;
  esac
}

# _ledger_finding_type_normalize <value>
#   Canonicalizes a raw finding-TYPE string to one of the six closed taxonomy
#   ids (or "" for unknown). Prefers the shared finding_type_normalize
#   (lib/core.sh) when it is already sourced; otherwise falls back to a
#   self-contained replica so lib/ledger.sh keeps resolving types when sourced on
#   its own (the same defensive pattern as _ledger_severity_normalize above).
_ledger_finding_type_normalize() {
  if declare -F finding_type_normalize >/dev/null 2>&1; then
    finding_type_normalize "${1:-}"
    return
  fi

  # Self-contained replica of lib/core.sh::finding_type_normalize.
  local value="${1:-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  if [[ "$value" == \[*\] ]]; then
    value="${value#\[}"; value="${value%\]}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
  fi
  value="${value,,}"
  case "$value" in
    security-vulnerability) printf '%s\n' 'security-vulnerability' ;;
    reliability-bug)        printf '%s\n' 'reliability-bug' ;;
    performance-risk)       printf '%s\n' 'performance-risk' ;;
    maintainability)        printf '%s\n' 'maintainability' ;;
    test-gap)               printf '%s\n' 'test-gap' ;;
    external-dependency)    printf '%s\n' 'external-dependency' ;;
    security)               printf '%s\n' 'security-vulnerability' ;;
    bug|correctness|reliability)
                            printf '%s\n' 'reliability-bug' ;;
    perf|performance)       printf '%s\n' 'performance-risk' ;;
    tests|testing)          printf '%s\n' 'test-gap' ;;
    cve|dependency)         printf '%s\n' 'external-dependency' ;;
    *) printf '' ;;
  esac
}

# _ledger_domain_default_finding_type <domain>
#   Back-compat fallback: maps a finding's domain to a default canonical type.
#   Prefers the shared domain_default_finding_type (lib/core.sh) when sourced;
#   otherwise a self-contained replica so the builders resolve a domain default
#   even when lib/ledger.sh is sourced alone. Always prints a canonical id
#   (unknown/empty -> maintainability, the safe non-security default).
_ledger_domain_default_finding_type() {
  if declare -F domain_default_finding_type >/dev/null 2>&1; then
    domain_default_finding_type "${1:-}"
    return
  fi

  # Self-contained replica of lib/core.sh::domain_default_finding_type.
  local domain="${1:-}"
  domain="${domain#"${domain%%[![:space:]]*}"}"
  domain="${domain%"${domain##*[![:space:]]}"}"
  domain="${domain,,}"
  case "$domain" in
    security|llm-security) printf '%s\n' 'security-vulnerability' ;;
    testing)              printf '%s\n' 'test-gap' ;;
    performance)          printf '%s\n' 'performance-risk' ;;
    error-handling|concurrency|database)
                          printf '%s\n' 'reliability-bug' ;;
    *)                    printf '%s\n' 'maintainability' ;;
  esac
}

# _ledger_resolve_finding_type <raw_type> <domain>
#   Canonical finding type for a registry record: a valid raw type wins (repaired
#   via _ledger_finding_type_normalize); otherwise fall back to the domain
#   default. Always prints exactly one of the six canonical ids — never empty (so
#   registry records are always typed). Value-based: callers pass already-read
#   frontmatter so the builders do not re-read the file (mirrors
#   lib/core.sh::finding_resolve_type, which is the file-reading entry point).
#   Pure; set -u safe with missing/empty args.
_ledger_resolve_finding_type() {
  local norm
  norm="$(_ledger_finding_type_normalize "${1:-}")"
  [[ -n "$norm" ]] || norm="$(_ledger_domain_default_finding_type "${2:-}")"
  printf '%s\n' "$norm"
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
#   - synthesized status="duplicate" remains duplicate for report exclusion.
#   - markdown_path is the absolute path of the first existing source finding
#     file, else null (so links work from reports under final/).
#     Relative paths use PROJECT_PATH, the synthesizer's working directory,
#     falling back to the caller's directory for standalone library use.
#     Source files are only checked for existence, never read.
#   - also_reported_by passes through when it is a non-empty array, with
#     relative Markdown links made absolute for reports under final/.
#   - confidence is null, primary_location is "", validation is {}.
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

  local count i entry domain lens title raw_sev sev vstatus status id raw_type ftype cx md source_path source_base
  source_base="${PROJECT_PATH:-$PWD}"
  [[ "$source_base" == /* ]] || source_base="$PWD/$source_base"
  count="$(jq 'length' "$manifest")" || { rm -f "$tmp"; return 1; }
  for (( i = 0; i < count; i++ )); do
    entry="$(jq -c --argjson i "$i" '.[$i]' "$manifest")" || { rm -f "$tmp"; return 1; }
    domain="$(jq -r '.domain // ""'  <<<"$entry")"
    lens="$(jq -r   '.lens // ""'    <<<"$entry")"
    title="$(jq -r  '.title // ""'   <<<"$entry")"
    raw_sev="$(jq -r '.severity // ""' <<<"$entry")"
    vstatus="$(jq -r '.verification_status // ""' <<<"$entry")"
    # Manifest clusters carry no finding taxonomy `type:` today, so this is
    # normally "" and the type resolves purely from the cluster's domain — the
    # read is defensive/future-proof in case a manifest ever adds one (#344).
    raw_type="$(jq -r '.type // ""' <<<"$entry")"
    # Complexity (#385): optional 1..5 routing tier authored by the synthesizer.
    # Absent/out-of-range normalizes to "" -> stored as null (parity with the
    # nullable confidence slot). tostring so a JSON number reaches the normalizer
    # as its bare digits.
    cx="$(_ledger_complexity_normalize "$(jq -r '.complexity // "" | tostring' <<<"$entry")")"

    id="$(finding_id "$domain" "$lens" "$title")"
    sev="$(_ledger_severity_normalize "$raw_sev")"
    ftype="$(_ledger_resolve_finding_type "$raw_type" "$domain")"
    status="new"
    case "$vstatus" in
      wrong) status="likely-false-positive" ;;
      stale) status="needs-validation" ;;
    esac

    if [[ "$(jq -r '.status // ""' <<<"$entry")" == duplicate ]]; then
      status=duplicate
    fi
    md=""
    while IFS= read -r -d '' source_path; do
      [[ "$source_path" == /* ]] || source_path="$source_base/$source_path"
      if [[ -f "$source_path" ]]; then
        md="$source_path"
        break
      fi
    done < <(jq -j '.source_finding_paths[]? | ., "\u0000"' <<<"$entry")

    jq -cn \
      --argjson entry "$entry" \
      --arg id "$id" --arg severity "$sev" --arg status "$status" --arg ftype "$ftype" \
      --arg md "$md" --arg complexity "$cx" --arg source_base "$source_base" '
      {
        id: $id,
        title: ($entry.title // ""),
        severity: $severity,
        type: $ftype,
        domain: ($entry.domain // ""),
        lens: ($entry.lens // ""),
        status: $status,
        primary_location: "",
        confidence: null,
        duplicate_group: ($entry.cluster_id // null),
        markdown_path: (if $md == "" then null else $md end),
        validation: {},
        complexity: (if $complexity == "" then null else ($complexity | tonumber) end),
        source_finding_paths: ($entry.source_finding_paths // [])
      }
      + (if ($entry.also_reported_by | type) == "array" and ($entry.also_reported_by | length) > 0
         then {also_reported_by: ($entry.also_reported_by | map(
           if (.markdown_path | type) == "string" and .markdown_path != ""
              and (.markdown_path | startswith("/") | not)
           then .markdown_path = ($source_base + "/" + .markdown_path)
           else . end))} else {} end)' >> "$tmp" || { rm -f "$tmp"; return 1; }
  done

  mv "$tmp" "$out" || { rm -f "$tmp"; return 1; }
}

# _ledger_trim_yaml_value <raw>
#   Trims surrounding whitespace, then strips one surrounding pair of matching
#   double or single quotes. A frontmatter `title: "[high] X"` must de-quote to
#   the bare `[high] X` so it earns the SAME finding_id as the manifest path
#   (the surrounding quotes otherwise prevent the [severity] prefix from being
#   stripped during normalization — an id-divergence bug). Self-contained
#   replica of lib/rounds.sh::_round_digest_trim_yaml_value (no dependency, to
#   keep lib/ledger.sh sourceable on its own).
_ledger_trim_yaml_value() {
  local v="$*"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  v="${v#\"}"; v="${v%\"}"
  v="${v#\'}"; v="${v%\'}"
  printf '%s' "$v"
}

# _ledger_has_frontmatter <file>
#   Returns 0 iff the file's first line is exactly `---` AND a closing `---`
#   line exists below it. This is the validity gate used to skip malformed /
#   frontmatter-less files. The closing-delimiter flag guards the END exit so a
#   well-formed block reports success even though the rule already returned.
_ledger_has_frontmatter() {
  awk '
    NR==1 && $0!="---" { exit 1 }
    NR==1 { next }
    $0=="---" { found=1; exit 0 }
    END { if (!found) exit 1 }
  ' "$1"
}

# _ledger_frontmatter_scalar <file> <key>
#   Prints the raw (still-quoted) value of a scalar key found inside the leading
#   `---` frontmatter block, or nothing when the key is absent. Reads ONLY the
#   block (stops at the closing `---`), so a `key:`-looking line in the markdown
#   body cannot be misparsed. Validity is checked separately by
#   _ledger_has_frontmatter; this reader has no END block so its rule exits are
#   authoritative (printing the value never gets clobbered by a guard).
_ledger_frontmatter_scalar() {
  local file="$1" key="$2"
  awk -v key="$key" '
    NR==1 && $0!="---" { exit 0 }
    NR==1 { next }
    $0=="---" { exit 0 }
    $0 ~ "^[[:space:]]*" key "[[:space:]]*:" {
      sub("^[[:space:]]*" key "[[:space:]]*:[[:space:]]*", "")
      print
      exit 0
    }
  ' "$file"
}

# build_findings_jsonl_from_local <output_dir> <out_jsonl_path> [generic_raw_root]
#   Optional physical rounds root excludes private raw Generic files during
#   explicit delivery; standalone/default callers keep their source selection.
#   Ingests the markdown findings written by `--local` mode into the canonical
#   finding registry as JSON Lines. Recursively finds every `*.md` under
#   <output_dir>, parses each file's leading YAML frontmatter
#   (title/severity/domain/lens) and emits one registry record per file that
#   carries a valid frontmatter block, mapped onto the 12-field schema in
#   docs/finding-registry-schema.md.
#
#   Sibling of build_findings_jsonl_from_manifest (#314): same null-slot
#   conventions and the same atomic-write + jq-owns-escaping discipline, with
#   two deliberate differences —
#   - markdown_path is POPULATED with the .md file's path (the point of #319:
#     link the registry row back to the human-readable file). The path is
#     emitted exactly as `find` yields it (i.e. relative to / prefixed by
#     <output_dir>), so it opens directly from where the registry lives.
#   - duplicate_group is null and source_finding_paths is OMITTED: local runs
#     have no synthesizer clusters, so there is nothing to seed or pass through.
#
#   Field sourcing:
#   - title/severity/domain/lens come from the frontmatter (YAML-dequoted).
#   - domain/lens fall back to directory components
#     (<output_dir>/<domain>/<lens>/NNN-x.md) ONLY when the frontmatter omits
#     them AND the nesting depth exists; a flat <output_dir>/NNN-x.md without
#     frontmatter domain/lens leaves them "" (no bogus value from the dir name).
#   - id is content-derived via finding_id over the DE-QUOTED title (no
#     primary_location), so the same finding earns the same id whether it
#     arrived via a manifest cluster or a local .md file.
#   - severity is run through _ledger_severity_normalize ("Critical"->"critical").
#   - confidence is null, primary_location is "", validation is {}.
#   - status preserves a "duplicate" mark only with a direct duplicate_of link
#     to a different, parsed non-duplicate in the same current deterministic
#     group; otherwise it is "new", so stale marks cannot suppress review.
#     Valid links reconstruct also_reported_by on canonical records.
#
#   jq owns all quoting/escaping: title/domain/lens/markdown_path are passed as
#   --arg and the object is built inside jq, so titles with quotes, `$()`,
#   backticks, or unicode round-trip intact and are never shell-evaluated.
#
#   A file without a valid frontmatter block is skipped with a stderr warning
#   (not fatal — the function still returns 0). An empty / no-`.md` dir yields an
#   empty output file (0 lines), exit 0. find output is sorted so rebuilds are
#   byte-identical. Output is written atomically (tmp + mv). Returns non-zero on
#   missing args or a missing <output_dir>, and on a missing out-path parent dir
#   (the atomic write fails). Failed enumeration (find or sort) returns non-zero,
#   cleans staging files and preserves any previously published output. A failed
#   staged-list open/read or source-file read has the same failure semantics.
#   The list's completion sentinel must be consumed even for an empty tree;
#   malformed readable source files continue to be skipped.
build_findings_jsonl_from_local() {
  local dir="${1:-}" out="${2:-}" generic_raw_root="${3:-}"
  [[ -n "$dir" ]] || { echo "build_findings_jsonl_from_local: missing output_dir" >&2; return 2; }
  [[ -n "$out" ]] || { echo "build_findings_jsonl_from_local: missing out path" >&2; return 2; }
  [[ -d "$dir" ]] || { echo "build_findings_jsonl_from_local: output_dir not found: $dir" >&2; return 2; }

  # Keep the traversal and relative-path prefix consistent for library callers.
  while [[ "$dir" == */ && "$dir" != / ]]; do dir="${dir%/}"; done

  local tmp="${out}.tmp.$$"
  : > "$tmp" || return 1

  local file rel lens_rel title severity domain lens id sev type_raw ftype cx status duplicate_of generic_source_id
  # Finish enumeration before ingestion: process substitution hides find's
  # failure and could otherwise promote an empty or partial registry.
  # Follow only an explicitly supplied symlink root.
  # An empty filename is impossible: consume this completion sentinel before
  # publishing, so list-open/read failures cannot look like an empty tree.
  if ! { (set -o pipefail; find -H "$dir" -type f -name '*.md' -print0 | LC_ALL=C sort -z) && printf '\0'; } > "$tmp.files"; then
    rm -f "$tmp" "$tmp.files"
    return 1
  fi
  # Unlike the projected metadata, this file holds the complete private body.
  # mktemp creates it exclusively with owner-only permissions, regardless of umask.
  local ingest_failed=0 list_complete=0 snapshot
  if ! snapshot="$(mktemp "$tmp.source.XXXXXX")"; then
    rm -f "$tmp" "$tmp.files"
    return 1
  fi
  while IFS= read -r -d '' file; do
    if [[ -z "$file" ]]; then
      list_complete=1
      break
    fi
    # Parse one fully read snapshot. IO failure is not malformed frontmatter:
    # never publish a partial tree or mix scalar reads from different versions.
    if ! cat -- "$file" > "$snapshot"; then
      echo "build_findings_jsonl_from_local: cannot read finding: $file" >&2
      ingest_failed=1
      break
    fi
    # Skip + warn (not fatal) when there is no valid leading frontmatter block.
    if ! _ledger_has_frontmatter "$snapshot"; then
      echo "build_findings_jsonl_from_local: no valid frontmatter, skipping: $file" >&2
      continue
    fi

    title="$(_ledger_trim_yaml_value "$(_ledger_frontmatter_scalar "$snapshot" title)")"
    severity="$(_ledger_trim_yaml_value "$(_ledger_frontmatter_scalar "$snapshot" severity)")"
    domain="$(_ledger_trim_yaml_value "$(_ledger_frontmatter_scalar "$snapshot" domain)")"
    lens="$(_ledger_trim_yaml_value "$(_ledger_frontmatter_scalar "$snapshot" lens)")"
    type_raw="$(_ledger_trim_yaml_value "$(_ledger_frontmatter_scalar "$snapshot" type)")"
    status="$(_ledger_trim_yaml_value "$(_ledger_frontmatter_scalar "$snapshot" status)")"
    [[ "$status" == duplicate ]] || status=new
    duplicate_of=""
    if [[ "$status" == duplicate ]]; then
      duplicate_of="$(_ledger_trim_yaml_value "$(_ledger_frontmatter_scalar "$snapshot" duplicate_of)")"
    fi
    # Complexity (#385): optional 1..5 routing tier from the finding frontmatter.
    # The normalizer trims/de-quotes and range-checks; absent or out-of-range
    # yields "" -> stored as null (parity with the nullable confidence slot).
    cx="$(_ledger_complexity_normalize "$(_ledger_frontmatter_scalar "$snapshot" complexity)")"

    # Directory fallback only when the <domain>/<lens> nesting actually exists.
    # Findings may be nested further in a dispatch-specific directory.
    # rel like <domain>/<lens>/NNN-x.md has 3+ path components; a flat file does
    # not, so we never derive a bogus domain/lens from <output_dir>'s own name.
    rel="${file#"${dir%/}"/}"
    if [[ -z "$domain" || -z "$lens" ]] && [[ "$rel" == */*/* ]]; then
      lens_rel="${rel#*/}"
      [[ -z "$lens"   ]] && lens="${lens_rel%%/*}"
      [[ -z "$domain" ]] && domain="${rel%%/*}"
    fi

    generic_source_id="$(_ledger_trim_yaml_value "$(_ledger_frontmatter_scalar "$snapshot" generic_source_id)")"
    # Explicit Generic delivery indexes projections once, even when the user
    # chose a destination containing the private multi-segment inventory.
    if [[ -n "$generic_raw_root" && "$domain" == generic && -z "$generic_source_id" ]] \
        && [[ "$(realpath -- "$file")" == "$generic_raw_root"/round-*/lens-outputs/* ]]; then
      continue
    fi
    if [[ "$domain" == generic && "$generic_source_id" =~ ^[a-f0-9]{64}$ ]]; then
      # Projected blocks may share title/lens while owning separate evidence.
      title="$(jq -r . <<< "$(_ledger_frontmatter_scalar "$snapshot" title)")" || { ingest_failed=1; break; }
      id="$(finding_id "$domain" "$lens" "$title" "generic:$generic_source_id")"
    else
      id="$(finding_id "$domain" "$lens" "$title")"
    fi
    sev="$(_ledger_severity_normalize "$severity")"
    # Resolve from the POST directory-fallback $domain (not a fresh file read) so
    # a type:-less file under <domain>/<lens>/NNN.md still gets the right default.
    ftype="$(_ledger_resolve_finding_type "$type_raw" "$domain")"

    jq -cn \
      --arg id "$id" --arg title "$title" --arg severity "$sev" \
      --arg domain "$domain" --arg lens "$lens" --arg md "$file" --arg ftype "$ftype" \
      --arg complexity "$cx" --arg status "$status" --arg duplicate_of "$duplicate_of" '
      {
        id: $id,
        title: $title,
        severity: $severity,
        type: $ftype,
        domain: $domain,
        lens: $lens,
        status: $status,
        __local_duplicate_of: $duplicate_of,
        primary_location: "",
        confidence: null,
        duplicate_group: null,
        markdown_path: $md,
        validation: {},
        complexity: (if $complexity == "" then null else ($complexity | tonumber) end)
      }' >> "$tmp" || { ingest_failed=1; break; }
  done < "$tmp.files" || ingest_failed=1
  rm -f "$tmp.files" "$snapshot"
  if (( ingest_failed || ! list_complete )); then
    if (( ! ingest_failed )); then
      echo "build_findings_jsonl_from_local: cannot read complete findings list" >&2
    fi
    rm -f "$tmp"
    return 1
  fi

  # Reuse current connected components, including transitive matches and the
  # operator's thresholds. A live old link alone cannot justify suppression
  # after a title edit. Unmarked trees need no grouping during ingestion.
  local components="$tmp.components" manifest="$tmp.manifest"
  : > "$components" || { rm -f "$tmp"; return 1; }
  if jq -se 'any(.[]; .status == "duplicate")' "$tmp" >/dev/null; then
    if ! declare -F _synthesize_compute_duplicate_groups >/dev/null 2>&1; then
      # shellcheck source=/dev/null
      source "$(_ledger_repo_root)/lib/synthesize.sh"
    fi
    if [[ "${REPOLENS_FINAL_STATE:-finished}" == interrupted ]]; then
      rm -f "$tmp" "$components"
      return "${REPOLENS_INTERRUPT_EXIT_CODE:-130}"
    fi
    if ! jq -s '.' "$tmp" > "$manifest"; then
      rm -f "$tmp" "$components" "$manifest"
      return 1
    fi
    # Assembly can accept a returning parent signal. Do not start the expensive
    # grouping pass once cancellation has been observed at this boundary.
    if [[ "${REPOLENS_FINAL_STATE:-finished}" == interrupted ]]; then
      rm -f "$tmp" "$components" "$manifest"
      return "${REPOLENS_INTERRUPT_EXIT_CODE:-130}"
    fi
    if ! _synthesize_compute_duplicate_groups "$manifest" > "$components"; then
      rm -f "$tmp" "$components" "$manifest"
      return 1
    fi
    rm -f "$manifest"
    if [[ "${REPOLENS_FINAL_STATE:-finished}" == interrupted ]]; then
      rm -f "$tmp" "$components"
      return "${REPOLENS_INTERRUPT_EXIT_CODE:-130}"
    fi
  fi

  # The local dedupe pass stores canonical paths relative to output_dir. Resolve
  # only against records in this same tree; no referenced file is opened. Check
  # RAW statuses before normalization so self-links, chains and cycles cannot
  # validate one another. Missing/filtered/invalid or now-unrelated canonicals
  # restore eligibility without modifying evidence. Only valid links contribute.
  if ! jq -cs --arg dir "${dir%/}" --slurpfile groups "$components" '
      . as $records
      | (reduce $groups[] as $g ({};
          reduce $g.member_indices[] as $i (.;
            .[$records[$i].markdown_path] = $g.canonical_idx))) as $membership
      | (map({key: .markdown_path, value: .status}) | from_entries) as $raw_status
      | map(
          ($dir + "/" + .__local_duplicate_of) as $target
          | if .status == "duplicate" and .__local_duplicate_of != ""
              and $target != .markdown_path and $raw_status[$target] == "new"
              and $membership[.markdown_path] != null
              and $membership[.markdown_path] == $membership[$target] then .
            else .status = "new" | .__local_duplicate_of = "" end)
      | (reduce .[] as $r ({};
        if $r.__local_duplicate_of == "" then .
        else .[$dir + "/" + $r.__local_duplicate_of] +=
          [{lens: $r.lens, domain: $r.domain, markdown_path: $r.markdown_path}]
        end)) as $contributors
      | .[]
      | if ($contributors[.markdown_path] // [] | length) > 0 then
          . + {also_reported_by: ($contributors[.markdown_path] | sort_by(.domain, .lens, .markdown_path))}
        else . end
      | del(.__local_duplicate_of)
    ' "$tmp" > "$tmp.groups"; then
    rm -f "$tmp" "$tmp.groups" "$components"
    return 1
  fi
  rm -f "$tmp" "$components"
  mv "$tmp.groups" "$out" || { rm -f "$tmp.groups"; return 1; }
}

# build_findings_csv <findings_jsonl_path> <out_csv_path>
#   Projects the canonical finding registry (findings.jsonl, schema in
#   docs/finding-registry-schema.md) onto a flat CSV: a fixed 12-column header
#   row, then one row per JSONL line, preserving JSONL line order
#   (deterministic). Spreadsheet/grep users get a flat view without a second
#   source of truth — findings.jsonl stays the full-fidelity registry.
#
#   Columns (exactly, in this order):
#     id,title,severity,type,domain,lens,status,primary_location,confidence,
#     duplicate_group,markdown_path,complexity
#   The nested `validation` object and the `source_finding_paths` array are
#   OMITTED — they don't flatten to a single cell. Keep this column list in
#   lockstep with the jq array below; the header string and the array are two
#   parallel lists (tests/test_ledger_csv.sh asserts the header byte-for-byte).
#
#   jq -r @csv owns all CSV quoting/escaping (RFC-4180): a field containing a
#   comma, a double quote, or a newline is correctly quoted and inner quotes are
#   doubled. A JSON null (or an absent key) renders as a bare empty cell.
#   Numbers (e.g. confidence) render unquoted. Fields are read inside jq, so
#   titles with shell metacharacters or unicode are never shell-evaluated.
#
#   Sibling of build_findings_jsonl_from_{manifest,local}: same atomic-write
#   (tmp + mv) + jq-owns-escaping discipline. Pure: reads the JSONL, writes the
#   CSV. An empty findings.jsonl yields a header-only CSV (matching the empty,
#   zero-line registry), exit 0. Returns non-zero on missing args or a missing
#   input file (no output written), and on a jq/IO failure (tmp cleaned up).
build_findings_csv() {
  local in="${1:-}" out="${2:-}"
  [[ -n "$in" ]]  || { echo "build_findings_csv: missing findings.jsonl path" >&2; return 2; }
  [[ -n "$out" ]] || { echo "build_findings_csv: missing out path" >&2; return 2; }
  [[ -f "$in" ]]  || { echo "build_findings_csv: input not found: $in" >&2; return 2; }

  local tmp="${out}.tmp.$$"
  # Header first. Keep this list in lockstep with the jq array below. `complexity`
  # (#385) is appended at the END so every pre-existing column index stays stable
  # for downstream consumers that read the CSV positionally.
  printf '%s\n' \
    'id,title,severity,type,domain,lens,status,primary_location,confidence,duplicate_group,markdown_path,complexity' \
    > "$tmp" || return 1

  # One CSV row per JSONL value (jq streams values in input order). Raw field
  # access (no `// ""`) so a JSON null becomes a bare empty cell, not the
  # literal "null". An empty input yields zero rows -> header-only CSV, exit 0.
  jq -r '
    [ .id, .title, .severity, .type, .domain, .lens, .status,
      .primary_location, .confidence, .duplicate_group, .markdown_path,
      .complexity ]
    | @csv
  ' "$in" >> "$tmp" || { rm -f "$tmp"; return 1; }

  mv "$tmp" "$out" || { rm -f "$tmp"; return 1; }
}

# validate_findings_jsonl <findings_jsonl_path>
#   Validates the JSON-Lines finding registry (schema:
#   docs/finding-registry-schema.md) PER LINE. This is the last line of defense
#   so siblings (dedupe/validation/triage/html/csv) can trust the structure even
#   if a builder regresses or a future producer writes the file. It mirrors
#   validate_manifest's reporting discipline (every message to stderr, prefixed
#   "validate_findings_jsonl: ...", accumulate-then-return), but iterates line by
#   line because JSONL is one independent JSON object per line: a single jq pass
#   would abort on the first malformed line, skip every line after it, and could
#   not attribute a violation to a line number.
#
#   Per non-empty line it asserts: the line parses as a JSON object; the 12
#   required keys are present (id, title, severity, type, domain, lens, status,
#   primary_location, confidence, duplicate_group, markdown_path, validation); id
#   is a non-empty string; severity in {critical,high,medium,low}; status in
#   {new,duplicate,needs-validation,likely-false-positive}; a non-null, non-empty
#   type in {security,reliability,performance,maintainability,test-gap,
#   external-dependency} (null/empty type accepted — owned by finding-types);
#   validation is an object (internals NOT checked — owned by validation-hints).
#   Extra/forward-compatible keys (e.g. source_finding_paths) are tolerated.
#
#   Empty file -> 0. Returns 0 when every line is valid, 1 on any violation,
#   2 on missing arg / missing file. Pure: reads only, no writes, no model.
validate_findings_jsonl() {
  local findings="${1:-}"
  if [[ -z "$findings" ]]; then
    echo "validate_findings_jsonl: missing findings.jsonl path" >&2
    return 2
  fi
  if [[ ! -f "$findings" ]]; then
    echo "validate_findings_jsonl: findings.jsonl not found: $findings" >&2
    return 2
  fi

  local errors=0 lineno=0 line out rc violation
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    # Skip genuinely blank lines (e.g. a trailing newline). lineno is still
    # incremented above so reported numbers match what an editor shows.
    [[ -n "${line//[[:space:]]/}" ]] || continue

    # One jq pass per line emits one violation string per problem. The
    # `if type != "object"` guard is load-bearing: has(...) on a non-object
    # raises a jq error, so we branch on object-ness first. A valid-but-non-object
    # line (e.g. a bare array/scalar) parses with rc=0 and falls into the
    # "not a JSON object" arm; an unparseable line makes jq exit non-zero and is
    # caught by the rc != 0 arm below. Enum checks are guarded by has(...) so a
    # MISSING key reports only "missing required key: ..." without duplicate noise.
    out="$(jq -r '
      def is_nonempty_string: type == "string" and length > 0;
      def severities: ["critical","high","medium","low"];
      def statuses:   ["new","duplicate","needs-validation","likely-false-positive"];
      # Accept BOTH the legacy short forms and the canonical long-form ids that
      # finding_resolve_type / finding_type_normalize emit (#344). Additive so
      # existing short-form fixtures stay valid while resolver output validates.
      def types:      ["security","reliability","performance","maintainability","test-gap","external-dependency","security-vulnerability","reliability-bug","performance-risk"];
      if type != "object" then "not a JSON object"
      else
        . as $v
        | (
            (["id","title","severity","type","domain","lens","status","primary_location","confidence","duplicate_group","markdown_path","validation"][] as $k
              | select(($v | has($k)) | not)
              | "missing required key: \($k)"),
            (if ($v | has("id")) and ($v.id | is_nonempty_string | not)
               then "id must be a non-empty string" else empty end),
            (if ($v | has("severity")) and ((severities | index($v.severity)) == null)
               then "invalid severity: \($v.severity | tostring)" else empty end),
            (if ($v | has("status")) and ((statuses | index($v.status)) == null)
               then "invalid status: \($v.status | tostring)" else empty end),
            (if ($v.type != null and $v.type != "") and ((types | index($v.type)) == null)
               then "invalid type: \($v.type | tostring)" else empty end),
            (if ($v | has("validation")) and (($v.validation | type) != "object")
               then "validation must be an object" else empty end),
            # complexity (#385) is OPTIONAL + nullable (mirrors confidence): an
            # absent key or an explicit null is fine. When present and non-null it
            # must be an INTEGER 1..5 — a non-number, out-of-range (0, 6, ...), or
            # fractional (2.5) value is a violation. NOT added to the required-keys
            # list above so pre-existing / hand-authored records stay valid.
            (if ($v | has("complexity")) and ($v.complexity != null)
                and (($v.complexity | type) != "number"
                     or $v.complexity < 1 or $v.complexity > 5
                     or $v.complexity != ($v.complexity | floor))
               then "invalid complexity: \($v.complexity | tostring)" else empty end)
          )
      end
    ' <<<"$line" 2>/dev/null)"
    rc=$?

    if (( rc != 0 )); then
      # jq could not parse the line -> not valid JSON (and so not an object).
      echo "validate_findings_jsonl: line $lineno: not a JSON object" >&2
      errors=$((errors + 1))
      continue
    fi

    while IFS= read -r violation; do
      [[ -n "$violation" ]] || continue
      echo "validate_findings_jsonl: line $lineno: $violation" >&2
      errors=$((errors + 1))
    done <<< "$out"
  done < "$findings"

  (( errors == 0 )) || return 1
  return 0
}

# _ledger_repo_root
#   Prints the repository root (the parent of this file's lib/ directory).
#   Self-contained replica of lib/synthesize.sh::_synthesize_repo_root so the
#   log-base resolver works when lib/ledger.sh is sourced on its own. Both
#   files live in lib/, so `dirname/..` yields the same root.
_ledger_repo_root() {
  local source_dir
  source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s' "$(cd "$source_dir/.." && pwd)"
}

# _ledger_log_base <run_id>
#   Resolves the run's log base: honors the optional `LOG_BASE` global (so the
#   orchestrator and tests can redirect output) and otherwise falls back to
#   <repo_root>/logs/<run_id>. Prefers the shared _synthesize_log_base
#   (lib/synthesize.sh) when it is already sourced, so the registry lands beside
#   the synthesizer's manifest.json; otherwise uses a self-contained replica so
#   lib/ledger.sh keeps working when sourced alone (the same defensive pattern
#   as _ledger_normalize_title / _ledger_severity_normalize above).
_ledger_log_base() {
  local run_id="${1:-}"
  if declare -F _synthesize_log_base >/dev/null 2>&1; then
    _synthesize_log_base "$run_id"
    return
  fi
  if [[ -n "${LOG_BASE:-}" ]]; then
    printf '%s' "$LOG_BASE"
    return 0
  fi
  printf '%s/logs/%s' "$(_ledger_repo_root)" "$run_id"
}

# build_finding_registry <run_id> [local_dir] [include_manifest=true] [generic_raw_root]
#   Orchestrates the four source-specific builders above into the canonical
#   finding registry under `<log_base>/final/`: findings.jsonl (full fidelity)
#   plus findings.csv (flat projection). This is the single producer of
#   final/findings.jsonl — consumed by result_pointer.sh / human_review.sh /
#   triage. It is GLUE ONLY; no new parsing logic lives here.
#
#   Source selection (both may run, results are concatenated). The optional
#   third argument false selects only the supplied local tree, as required for
#   user-selected explicit output, including overlap with private inventory.
#   - if `<log_base>/final/manifest.json` exists, ingest it via
#     build_findings_jsonl_from_manifest.
#   - if a local output dir is supplied (2nd arg, else the OUTPUT_DIR global;
#     an explicit empty 2nd arg disables local ingestion)
#     and is a directory, ingest its `*.md` tree via
#     build_findings_jsonl_from_local.
#   The concatenation is then collapsed so each `id` appears once, keeping the
#   first NON-DUPLICATE occurrence, or the first duplicate if none is canonical.
#   Ties retain input order (manifest-first — the manifest record carries the
#   richer cross-run provenance: source_finding_paths passthrough and a
#   cluster-seeded duplicate_group. Either order satisfies the AC, which mandates
#   only that identical-id duplicates collapse). Colliding non-duplicate records
#   merge their also_reported_by contributors, preserving all other winner fields.
#   jq -s + reduce is single-pass
#   and order-preserving (unique_by would sort and lose "keep first").
#
#   Atomicity mirrors run_synthesizer's tmp+mv discipline: the registry is
#   assembled in a `.tmp.$$` candidate, validated via validate_findings_jsonl,
#   and only `mv`-ed into place on success. A validation (or builder) failure
#   discards every intermediate and promotes NOTHING — a partial/failed build
#   never leaves a consumable findings.jsonl. The CSV is derived from the
#   PROMOTED jsonl, so no orphan CSV survives a discarded candidate.
#
#   No sources -> a canonical-empty registry: a 0-line findings.jsonl and a
#   header-only findings.csv, exit 0 (parity with the synthesizer's empty case).
#
#   Reads the optional LOG_BASE and OUTPUT_DIR globals (both `${VAR:-}`-guarded).
#   Returns 2 on a missing run_id, 1 on a builder/jq/IO/validation failure.
build_finding_registry() {
  local run_id="${1:-}"
  local local_dir="${2-${OUTPUT_DIR:-}}"
  local include_manifest="${3:-true}" generic_raw_root="${4:-}"
  if [[ -z "$run_id" ]]; then
    echo "build_finding_registry: missing run_id" >&2
    return 2
  fi

  local final_dir
  final_dir="$(_ledger_log_base "$run_id")/final"
  if ! mkdir -p "$final_dir"; then
    echo "build_finding_registry: cannot create $final_dir" >&2
    return 1
  fi

  local jsonl="$final_dir/findings.jsonl"
  local csv="$final_dir/findings.csv"
  local candidate="$jsonl.tmp.$$"
  local deduped="$candidate.dedup"
  local m_tmp="$final_dir/.fr-manifest.$$"
  local l_tmp="$final_dir/.fr-local.$$"

  # Start from an empty candidate so the no-source path falls out naturally.
  if ! : > "$candidate"; then
    echo "build_finding_registry: cannot write candidate $candidate" >&2
    return 1
  fi

  # Source 1: synthesizer manifest, when present.
  local manifest="$final_dir/manifest.json"
  if [[ "$include_manifest" == true && -f "$manifest" ]]; then
    if build_findings_jsonl_from_manifest "$manifest" "$m_tmp"; then
      cat "$m_tmp" >> "$candidate"
    else
      echo "build_finding_registry: manifest ingest failed" >&2
      rm -f "$candidate" "$m_tmp" "$l_tmp"
      return 1
    fi
    rm -f "$m_tmp"
  fi

  # Source 2: --local markdown tree, when a directory is supplied. A
  # provided-but-missing dir is treated as "no local source" (forgiving).
  if [[ -n "$local_dir" && -d "$local_dir" ]]; then
    if build_findings_jsonl_from_local "$local_dir" "$l_tmp" "$generic_raw_root"; then
      cat "$l_tmp" >> "$candidate"
    else
      echo "build_finding_registry: local ingest failed" >&2
      rm -f "$candidate" "$m_tmp" "$l_tmp"
      return 1
    fi
    rm -f "$l_tmp"
  fi

  # A later canonical local record must replace an earlier marked duplicate
  # sharing its id, or actionable reports lose the finding entirely. Preserve
  # the first id's position and manifest-first precedence among equal statuses.
  # Empty candidate -> empty output (0 lines).
  if ! jq -c -s '
        reduce .[] as $r ({seen: {}, out: []};
          (.seen[$r.id] // null) as $pos
          | if $pos == null then
              .seen[$r.id] = (.out | length) | .out += [$r]
            elif .out[$pos].status == "duplicate" and $r.status != "duplicate" then
              .out[$pos] = $r
            elif .out[$pos].status != "duplicate" and $r.status != "duplicate"
                and (((.out[$pos].also_reported_by // []) + ($r.also_reported_by // [])) | length) > 0 then
              .out[$pos].also_reported_by =
                ((.out[$pos].also_reported_by // []) + ($r.also_reported_by // [])
                  | unique_by([.domain, .lens, .markdown_path]))
            else . end)
        | .out[]' "$candidate" > "$deduped" 2>/dev/null; then
    echo "build_finding_registry: dedup pass failed" >&2
    rm -f "$candidate" "$deduped"
    return 1
  fi
  if ! mv "$deduped" "$candidate"; then
    rm -f "$candidate" "$deduped"
    return 1
  fi

  # Validate BEFORE promoting. A failure discards the candidate and promotes
  # nothing (no jsonl, no derived csv).
  if ! validate_findings_jsonl "$candidate"; then
    echo "build_finding_registry: registry failed validation, not promoting" >&2
    rm -f "$candidate"
    return 1
  fi

  # Atomic promote, then derive the CSV from the promoted jsonl.
  if ! mv "$candidate" "$jsonl"; then
    rm -f "$candidate"
    return 1
  fi
  if ! build_findings_csv "$jsonl" "$csv"; then
    echo "build_finding_registry: csv projection failed" >&2
    return 1
  fi

  return 0
}
