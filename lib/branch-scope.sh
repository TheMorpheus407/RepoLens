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

# RepoLens — deterministic branch-review scope checks.
# These checks deliberately accept only citations to changed files. Findings
# with an unverifiable/missing scope are quarantined, never silently approved.

# Shared citation grammar: backticks support spaces and extensionless paths;
# bare citations allow '+' mid-path (e.g. src/routes/+page.svelte) and require
# a path separator/extension or a conventional root file. A bare token carrying
# unsupported characters is rejected whole after trimming prose delimiters;
# punctuation inside a token cannot make its suffix a citation. Adjacent
# comma/semicolon lists are accepted only if every nonempty member is valid;
# paired Markdown emphasis and outer prose punctuation are supported.
# A malformed list containing a recognized citation returns nonzero; callers
# must reject the body even if other citations were emitted.
# The complete remaining token must match the bare path grammar to become
# a citation. URLs (including ports) and timestamps are prose, not source
# citations.
repolens_extract_citations() {
  _repolens_scan_citations "$1" | sort -u
}

# Emit the first complete noncitation code span attached to each occurrence of
# the requested citation. Share parsing and positions with extraction so prose,
# URLs and citation-like text within snippets cannot become source boundaries.
repolens_citation_snippets() {
  _repolens_scan_citations "$1" "$2"
}

# Scan once per request, retaining occurrence and complete code-span positions.
# With a second argument emit its snippets; otherwise emit all source citations.
_repolens_scan_citations() {
  local body="$1" snippet_citation="${2:-}" quoted_marker='quoted'
  # Use a letter sequence absent from the input. Masking excluded spans with
  # '@' cannot fabricate that sequence or impersonate a quoted list member.
  while [[ "$body" == *"$quoted_marker"* ]]; do quoted_marker+='q'; done
  quoted_marker="@$quoted_marker@"
  REPOLENS_SNIPPET_CITATION="$snippet_citation" awk -v quoted_marker="$quoted_marker" '
        # Map masked characters to their original line positions. Placeholders
        # may change length; later bare references must keep their real offsets.
        function append_mask(text, origin, i, base) {
          base = length(masked)
          for (i = 1; i <= length(text); i++) original[base + i] = origin + i - 1
          masked = masked text
        }
        function remember_reference(text, start, end) {
          reference[start] = text
          reference_end[start] = end
        }
        function emit_snippets(line_length, pos, next_pos, first, i, snippet) {
          first = 1
          for (pos = 1; pos <= line_length; pos++) {
            if (!(pos in reference)) continue
            next_pos = pos + 1
            while (next_pos <= line_length && !(next_pos in reference)) next_pos++
            snippet = ""
            for (i = 1; i <= span_count; i++) {
              if (span_start[i] > reference_end[pos] && span_end[i] < next_pos) {
                snippet = span_text[i]
                break
              }
            }
            # Only the first actual citation may use preceding evidence.
            if (snippet == "" && first) {
              for (i = 1; i <= span_count; i++) {
                if (span_end[i] < pos) { snippet = span_text[i]; break }
              }
            }
            if (reference[pos] == ENVIRON["REPOLENS_SNIPPET_CITATION"] && snippet != "") print snippet
            first = 0
          }
        }
        # Consume complete, equal-length tick runs from left to right. Shorter
        # runs inside a span are literal and cannot manufacture a citation.
        # Scan each line independently so multiline fences leave their source
        # references available to the existing bare/quoted citation grammar.
        function mask_spans(value, start, width, tail, offset, run, content, path, consumed) {
          masked = ""
          consumed = 0
          while (match(value, /`+/)) {
            start = RSTART
            width = RLENGTH
            append_mask(substr(value, 1, start - 1), consumed + 1)
            tail = substr(value, start + width)
            offset = run = 0
            while (match(tail, /`+/)) {
              run = RLENGTH
              offset += RSTART + run - 1
              tail = substr(tail, RSTART + run)
              if (run == width) break
            }
            if (run != width) {
              # An unmatched run is literal. Later complete spans can still
              # supply independent evidence, but cannot reuse its ticks.
              append_mask(substr(value, start, width), consumed + start)
              consumed += start + width - 1
              value = substr(value, start + width)
              continue
            }
            content = substr(value, start + width, offset - width)
            path = content
            sub(/:[0-9]+(-[0-9]+)?$/, "", path)
            if (content ~ /^[^`]+:[0-9]+(-[0-9]+)?$/ &&
                path !~ /:\/\// && path !~ /^[0-9:]+$/) {
              if (ENVIRON["REPOLENS_SNIPPET_CITATION"] == "") print content
              remember_reference(content, consumed + start, consumed + start + width + offset - 1)
              append_mask(quoted_marker, consumed + start)
            } else {
              # Preserve the legacy exclusion of location-shaped spans,
              # including quoted URL ports and timestamps, from snippets.
              if (content !~ /^.+:[0-9]+(-[0-9]+)?$/) {
                span_count++
                span_start[span_count] = consumed + start
                span_end[span_count] = consumed + start + width + offset - 1
                span_text[span_count] = content
              }
              append_mask("@", consumed + start)
            }
            consumed += start + width + offset - 1
            value = substr(value, start + width + offset)
          }
          append_mask(value, consumed + 1)
          return masked
        }
        function unwrap(value, first, last) {
          first = substr(value, 1, 1)
          last = substr(value, length(value), 1)
          # Peel one layer so a list is retried before member formatting can
          # be mistaken for another wrapper around the entire list.
          if (length(value) && index("([{", first))
            return substr(value, 2)
          if (length(value) && index("])}.:!?", last))
            return substr(value, 1, length(value) - 1)
          if (length(value) > 4 && substr(value, 1, 2) == "~~" &&
              substr(value, length(value) - 1) == "~~")
            return substr(value, 3, length(value) - 4)
          if (length(value) > 2 &&
              ((first == last && index("*_\042\047", first)) ||
               (first == "<" && last == ">")))
            return substr(value, 2, length(value) - 2)
          return value
        }
        function normalize(value, previous) {
          do {
            previous = value
            value = unwrap(value)
          } while (value != previous)
          return value
        }
        function citation(value, path) {
          if (value !~ /^[A-Za-z_./-][A-Za-z0-9_+./-]*:[0-9]+(-[0-9]+)?$/)
            return 0
          path = value
          sub(/:[0-9]+(-[0-9]+)?$/, "", path)
          return path ~ /[\/.]/ ||
            path ~ /^(Makefile|Dockerfile|Containerfile|Jenkinsfile|LICENSE|README|Gemfile|Rakefile|Procfile)$/
        }
        function citation_list(value, members, count, i, member, result, invalid, recognized) {
          count = split(value, members, /[,;]/)
          result = ""
          invalid = recognized = 0
          for (i = 1; i <= count; i++) {
            if (members[i] == "") continue
            member = normalize(members[i])
            # Already emitted by the quoted branch. Only a whole member
            # qualifies; embedded markers still invalidate the bare token.
            if (member == quoted_marker || citation(member)) {
              recognized = 1
              if (member != quoted_marker) result = result member "\n"
            } else invalid = 1
          }
          list_valid = !invalid
          malformed_list = count > 1 && recognized && invalid
          return invalid ? "" : result
        }
        {
          delete reference
          delete reference_end
          span_count = 0
          value = mask_spans($0)
          # Keep masked offsets stable when hiding URLs as well.
          while (match(value, /[[:alpha:]][[:alnum:]+.-]*:\/\/[^[:space:]<>`]+/)) {
            replacement = substr(value, RSTART, RLENGTH)
            gsub(/./, "@", replacement)
            value = substr(value, 1, RSTART - 1) replacement substr(value, RSTART + RLENGTH)
          }
          token_count = split(value, tokens, /[[:space:]]+/)
          token_cursor = 1
          for (token_index = 1; token_index <= token_count; token_index++) {
            token_start = token_cursor + index(substr(value, token_cursor), tokens[token_index]) - 1
            token_cursor = token_start + length(tokens[token_index])
            token_value = tokens[token_index]
            # The normalization loop mutates value, so retain the masked line.
            masked_line = value
            value = token_value
            token_malformed = 0
            do {
              result = citation_list(value)
              if (list_valid) break
              if (malformed_list) token_malformed = 1
              previous = value
              value = unwrap(value)
            } while (value != previous)
            # A complete interpretation wins; unsuccessful interpretations
            # retain every recognized malformed-list error across layers.
            if (!list_valid && token_malformed) extraction_failed = 1
            if (ENVIRON["REPOLENS_SNIPPET_CITATION"] == "") printf "%s", result
            count = split(result, found, /\n/)
            member_cursor = 1
            for (i = 1; i <= count; i++) {
              if (found[i] == "") continue
              member_start = member_cursor + index(substr(token_value, member_cursor), found[i]) - 1
              member_cursor = member_start + length(found[i])
              start = original[token_start + member_start - 1]
              remember_reference(found[i], start, start + length(found[i]) - 1)
            }
            value = masked_line
          }
          if (ENVIRON["REPOLENS_SNIPPET_CITATION"] != "") emit_snippets(length($0))
        }
        END { exit extraction_failed ? 1 : 0 }
      ' <<< "$body"
}

# Read trusted configuration separately from finding validation. Missing,
# invalid or unreadable scope evidence must leave findings eligible for retry.
_branch_scope_read_paths() {
  local scope="${BRANCH_SCOPE_FILE:-${LOG_BASE:-}/branch-scope.json}"
  [[ -f "$scope" && ! -L "$scope" ]] || return 1
  jq -ce 'select(type == "array" and all(.[]; type == "string"))' "$scope" 2>/dev/null
}

# Returns 0 for an accepted body, 1 for a rejected body, 2 if scope evidence is
# unavailable. Callers must not record an operational failure as a rejection.
branch_scope_verify_body() {
  [[ "${MODE:-${REPOLENS_MODE:-}}" == "branch-review" ]] || return 0
  local body="${1:-}" paths citations path
  if ! paths="$(_branch_scope_read_paths)"; then
    printf 'branch scope missing or invalid\n'
    return 2
  fi
  if ! citations="$(repolens_extract_citations "$body")"; then
    printf 'malformed citation list in body\n'
    return 1
  fi
  [[ -n "$citations" ]] || { printf 'branch finding has no file:line citation\n'; return 1; }
  while IFS= read -r path; do
    path="${path%:*}"
    path="${path#./}"
    if ! jq -e --arg path "$path" 'index($path) != null' <<< "$paths" >/dev/null; then
      printf 'out-of-scope citation: %s\n' "$path"
      return 1
    fi
  done <<< "$citations"
}

# Replace an exact quarantine or diagnostic path on GNU and BSD/macOS. Recheck
# unsafe destinations after staging. os.replace never follows a final symlink
# or moves the staged file inside a destination directory; callers clean up
# the staged file on failure.
_branch_scope_replace_file() {
  python3 -c '
import os
import sys
try:
    if os.path.islink(sys.argv[2]) or os.path.isdir(sys.argv[2]):
        sys.exit(1)
    # rename/replace succeeds without removing either name for hard links to
    # the same inode. That would leave rejected Markdown eligible for ingestion.
    if os.path.exists(sys.argv[2]) and os.path.samefile(sys.argv[1], sys.argv[2]):
        sys.exit(1)
    os.replace(sys.argv[1], sys.argv[2])
except OSError as exc:
    print(f"branch_scope_filter_directory: cannot replace finding file: {exc}", file=sys.stderr)
    sys.exit(1)
' "$1" "$2"
}

# Side effect: preserve rejected findings as <name>.md.out-of-scope with a
# companion reason, so all downstream *.md consumers exclude them, including
# local registries, round digests, verifier, and synthesizer. Read failures
# abort filtering without quarantining the unreadable source. Unavailable scope
# evidence aborts filtering and preserves every pending finding.
branch_scope_filter_directory() {
  [[ "${MODE:-${REPOLENS_MODE:-}}" == "branch-review" ]] || return 0
  local dir="$1" file reason body files files_fd verification_rc filter_rc=0 list_complete=false
  local -a finding_files=() rejected_files=() rejection_reasons=()
  [[ -d "$dir" ]] || return 0
  if ! _branch_scope_read_paths >/dev/null; then
    printf 'branch_scope_filter_directory: branch scope unavailable; retry after repair\n' >&2
    return 1
  fi
  # Complete enumeration before filtering. A failed producer can emit a valid
  # prefix, but that prefix cannot authorize publication of the whole tree.
  files="$(mktemp "$dir/.branch-scope-files.XXXXXX")" || return 1
  # An empty record cannot be a filename. It proves the reader consumed the
  # successful producer's entire list, rather than stopping on an I/O error.
  # Match registry ingestion: follow an explicitly supplied symlink root while
  # leaving nested directory/file symlinks unvisited.
  if ! { find -H "$dir" -type f -name '*.md' -print0 && printf '\0'; } > "$files"; then
    printf 'branch_scope_filter_directory: cannot enumerate findings: %s\n' "$dir" >&2
    rm -f -- "$files"
    return 1
  fi
  if ! exec {files_fd}< "$files"; then
    printf 'branch_scope_filter_directory: cannot open findings list: %s\n' "$files" >&2
    rm -f -- "$files"
    return 1
  fi
  while IFS= read -r -d '' file; do
    if [[ -z "$file" ]]; then
      list_complete=true
      break
    fi
    finding_files+=("$file")
  done <&"$files_fd"
  exec {files_fd}<&- || filter_rc=1
  rm -f -- "$files" || return 1
  if ! $list_complete; then
    printf 'branch_scope_filter_directory: cannot read complete findings list: %s\n' "$files" >&2
    return 1
  fi
  (( filter_rc == 0 )) || return 1
  # No finding is checked or quarantined until the whole list is available.
  for file in "${finding_files[@]}"; do
    if ! body="$(cat -- "$file")"; then
      printf 'branch_scope_filter_directory: cannot read finding: %s\n' "$file" >&2
      filter_rc=1
      break
    fi
    if reason="$(branch_scope_verify_body "$body")"; then
      continue
    else
      verification_rc=$?
      if (( verification_rc != 1 )); then
        printf 'branch_scope_filter_directory: %s; leaving finding pending\n' "$reason" >&2
        filter_rc=1
        break
      fi
      rejected_files+=("$file")
      rejection_reasons+=("$reason")
    fi
  done
  (( filter_rc == 0 )) || return "$filter_rc"
  # A later scope/read failure must not quarantine an earlier finding.
  # Finish verification before committing any rejections.
  local rejection_index reason_tmp
  for rejection_index in "${!rejected_files[@]}"; do
    file="${rejected_files[$rejection_index]}"
    reason="${rejection_reasons[$rejection_index]}"
    # Keep the source eligible for retry until its diagnostic is saved.
    if [[ -L "$file.out-of-scope.reason" || -d "$file.out-of-scope.reason" ]]; then
      printf 'branch_scope_filter_directory: unsafe diagnostic destination: %s\n' "$file.out-of-scope.reason" >&2
      filter_rc=1
      break
    fi
    # Stage beside the finding so exact-path replacement stays on its
    # filesystem even when a nested directory is a separate mount.
    reason_tmp="$(mktemp "${file%/*}/.branch-scope-reason.XXXXXX")" || return 1
    if ! printf '%s\n' "$reason" > "$reason_tmp" ||
        ! _branch_scope_replace_file "$reason_tmp" "$file.out-of-scope.reason"; then
      rm -f -- "$reason_tmp"
      filter_rc=1
      break
    fi
    if ! _branch_scope_replace_file "$file" "$file.out-of-scope"; then
      rm -f -- "$file.out-of-scope.reason"
      filter_rc=1
      break
    fi
  done
  return "$filter_rc"
}

# Side effects: filter a synthesized candidate before promotion, preserve
# rejected proposals, and retain the branch title convention mechanically.
# Returns 2 on unavailable scope evidence, an incomplete candidate read, or
# staging/serialization/publication failure, preserving publications through
# the synthesis caller; 1 on an invalid candidate.
branch_scope_filter_manifest() {
  [[ "${MODE:-${REPOLENS_MODE:-}}" == "branch-review" ]] || return 0
  local manifest="$1" entry reason kept rejected verification_rc entries report_tmp accepted
  jq -e 'type == "array"' "$manifest" >/dev/null 2>&1 || return 1
  _branch_scope_read_paths >/dev/null || return 2
  kept="$(mktemp "${manifest}.scope.XXXXXX")" || return 2
  # Capture and check the whole stream before filtering or publishing a prefix.
  entries="$(jq -c '.[]' "$manifest")" || { rm -f "$kept"; return 2; }
  # Exclusively create derived stages rather than opening predictable siblings.
  rejected="$(mktemp "${kept}.rejected.XXXXXX")" || { rm -f "$kept"; return 2; }
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    if reason="$(branch_scope_verify_body "$(jq -r '.body' <<< "$entry")")"; then
      jq -c '
        .title = ("[REGRESSION][" + (.severity | ascii_upcase) + "] " +
          (.title | sub("^\\[REGRESSION\\][[:space:]]*"; "")
            | sub("^\\[(?i:critical|high|medium|low)\\][[:space:]]*"; "")))
      ' <<< "$entry" >> "$kept" || { rm -f "$kept" "$rejected"; return 2; }
    else
      verification_rc=$?
      if (( verification_rc != 1 )); then
        rm -f "$kept" "$rejected"
        return 2
      fi
      # Findings can exceed exec argument limits. Stream the entry and check
      # serialization before publishing either the manifest or rejection report.
      jq -c --arg reason "$reason" '{finding:.,reason:$reason}' <<< "$entry" >> "$rejected" || {
        rm -f "$kept" "$rejected"
        return 2
      }
    fi
  done <<< "$entries"
  # Aggregate both streams before publishing either result. Accepted-entry
  # IO must preserve the candidate and the previous report for the caller.
  accepted="$(mktemp "${kept}.accepted.XXXXXX")" || {
    rm -f -- "$kept" "$rejected"
    return 2
  }
  if ! jq -s '.' "$kept" > "$accepted"; then
    rm -f -- "$kept" "$rejected" "$accepted"
    return 2
  fi
  report_tmp="$(mktemp "${kept}.report.XXXXXX")" || {
    rm -f -- "$kept" "$rejected" "$accepted"
    return 2
  }
  if ! jq -s '.' "$rejected" > "$report_tmp" ||
      ! _branch_scope_replace_file "$report_tmp" "${manifest%.tmp.*}.out-of-scope.json" ||
      ! _branch_scope_replace_file "$accepted" "$manifest"; then
    rm -f -- "$kept" "$rejected" "$report_tmp" "$accepted"
    return 2
  fi
  rm -f -- "$kept" "$rejected" || return 2
}
