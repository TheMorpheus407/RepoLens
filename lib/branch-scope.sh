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
  local body="$1" quoted_marker='quoted'
  # Use a letter sequence absent from the input. Masking excluded spans with
  # '@' cannot fabricate that sequence or impersonate a quoted list member.
  while [[ "$body" == *"$quoted_marker"* ]]; do quoted_marker+='q'; done
  quoted_marker="@$quoted_marker@"
  awk -v quoted_marker="$quoted_marker" '
        # Consume complete, equal-length tick runs from left to right. Shorter
        # runs inside a span are literal and cannot manufacture a citation.
        # Scan each line independently so multiline fences leave their source
        # references available to the existing bare/quoted citation grammar.
        function mask_spans(value, result, start, width, tail, offset, run, content, path) {
          result = ""
          while (match(value, /`+/)) {
            start = RSTART
            width = RLENGTH
            result = result substr(value, 1, start - 1)
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
              result = result substr(value, start, width)
              value = substr(value, start + width)
              continue
            }
            content = substr(value, start + width, offset - width)
            path = content
            sub(/:[0-9]+(-[0-9]+)?$/, "", path)
            if (content ~ /^[^`]+:[0-9]+(-[0-9]+)?$/ &&
                path !~ /:\/\// && path !~ /^[0-9:]+$/) {
              print content
              result = result quoted_marker
            } else result = result "@"
            value = substr(value, start + width + offset)
          }
          return result value
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
          value = mask_spans($0)
          gsub(/https?:\/\/[^[:space:]<>`]+/, "@", value)
          token_count = split(value, tokens, /[[:space:]]+/)
          for (token_index = 1; token_index <= token_count; token_index++) {
            value = tokens[token_index]
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
            printf "%s", result
          }
        }
        END { exit extraction_failed ? 1 : 0 }
      ' <<< "$body" | sort -u
}

branch_scope_verify_body() {
  [[ "${MODE:-${REPOLENS_MODE:-}}" == "branch-review" ]] || return 0
  local body="${1:-}" scope="${BRANCH_SCOPE_FILE:-${LOG_BASE:-}/branch-scope.json}" paths citations path
  if [[ ! -f "$scope" || -L "$scope" ]] \
      || ! paths="$(jq -ce 'select(type == "array" and all(.[]; type == "string"))' "$scope" 2>/dev/null)"; then
    printf 'branch scope missing or invalid\n'
    return 1
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

# Side effect: preserve rejected findings as <name>.md.out-of-scope with a
# companion reason, so all downstream *.md consumers exclude them, including
# local registries, round digests, verifier, and synthesizer. Read failures
# abort filtering without quarantining the unreadable source.
branch_scope_filter_directory() {
  [[ "${MODE:-${REPOLENS_MODE:-}}" == "branch-review" ]] || return 0
  local dir="$1" file reason body
  [[ -d "$dir" ]] || return 0
  while IFS= read -r -d '' file; do
    if ! body="$(cat -- "$file")"; then
      printf 'branch_scope_filter_directory: cannot read finding: %s\n' "$file" >&2
      return 1
    fi
    if ! reason="$(branch_scope_verify_body "$body")"; then
      mv -- "$file" "$file.out-of-scope" || return 1
      printf '%s\n' "$reason" > "$file.out-of-scope.reason"
    fi
  done < <(find "$dir" -type f -name '*.md' -print0)
}

# Side effects: filter a synthesized candidate before promotion, preserve
# rejected proposals, and retain the branch title convention mechanically.
branch_scope_filter_manifest() {
  [[ "${MODE:-${REPOLENS_MODE:-}}" == "branch-review" ]] || return 0
  local manifest="$1" entry reason kept rejected
  jq -e 'type == "array"' "$manifest" >/dev/null 2>&1 || return 1
  kept="$(mktemp "${manifest}.scope.XXXXXX")" || return 1
  rejected="${kept}.rejected"
  : > "$rejected"
  while IFS= read -r entry; do
    if reason="$(branch_scope_verify_body "$(jq -r '.body' <<< "$entry")")"; then
      jq -c '
        .title = ("[REGRESSION][" + (.severity | ascii_upcase) + "] " +
          (.title | sub("^\\[REGRESSION\\][[:space:]]*"; "")
            | sub("^\\[(?i:critical|high|medium|low)\\][[:space:]]*"; "")))
      ' <<< "$entry" >> "$kept" || { rm -f "$kept" "$rejected"; return 1; }
    else
      jq -cn --argjson finding "$entry" --arg reason "$reason" '{finding:$finding,reason:$reason}' >> "$rejected"
    fi
  done < <(jq -c '.[]' "$manifest")
  jq -s '.' "$rejected" > "${manifest%.tmp.*}.out-of-scope.json" || return 1
  jq -s '.' "$kept" > "$manifest" || return 1
  rm -f "$kept" "$rejected"
}
