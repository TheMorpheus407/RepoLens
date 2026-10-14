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
  local body="$1" token path quoted_marker='quoted'
  # Use a letter sequence absent from the input. Masking excluded spans with
  # '@' cannot fabricate that sequence or impersonate a quoted list member.
  while [[ "$body" == *"$quoted_marker"* ]]; do quoted_marker+='q'; done
  quoted_marker="@$quoted_marker@"
  {
    while IFS= read -r token; do
      path="${token%:*}"
      [[ "$path" == *://* || "$path" =~ ^[0-9:]+$ ]] && continue
      printf '%s\n' "$token"
    done < <(grep -oE '`[^`]+:[0-9]+(-[0-9]+)?`' <<< "$body" | sed 's/^`//; s/`$//')
    # Keep recognized quoted citations as opaque list members, while masking
    # excluded spans. Neither replacement can join text into a bare path.
    sed -E -e 's#https?://[^[:space:]<>`]+#@#g' \
      -e 's#`[^`]*://[^`]*`#@#g' \
      -e 's/`[0-9:]+:[0-9]+(-[0-9]+)?`/@/g' \
      -e "s/\`[^\`]+:[0-9]+(-[0-9]+)?\`/$quoted_marker/g" \
      -e 's/`[^`]*`/@/g' <<< "$body" \
      | awk -v quoted_marker="$quoted_marker" '
        function normalize(value, previous, first, last) {
          do {
            previous = value
            sub(/^[([{]+/, "", value)
            sub(/[])}.:!?]+$/, "", value)
            first = substr(value, 1, 1)
            last = substr(value, length(value), 1)
            if (length(value) > 4 && substr(value, 1, 2) == "~~" &&
                substr(value, length(value) - 1) == "~~") {
              value = substr(value, 3, length(value) - 4)
            } else if (length(value) > 2 &&
                ((first == last && index("*_\042\047", first)) ||
                 (first == "<" && last == ">"))) {
              value = substr(value, 2, length(value) - 2)
            }
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
          token_count = split($0, tokens, /[[:space:]]+/)
          for (token_index = 1; token_index <= token_count; token_index++) {
            result = citation_list(tokens[token_index])
            # Formatting may enclose the entire list rather than each member.
            if (!list_valid) result = citation_list(normalize(tokens[token_index]))
            if (malformed_list) extraction_failed = 1
            printf "%s", result
          }
        }
        END { exit extraction_failed ? 1 : 0 }
      '
  } | sort -u
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
# local registries, round digests, verifier, and synthesizer.
branch_scope_filter_directory() {
  [[ "${MODE:-${REPOLENS_MODE:-}}" == "branch-review" ]] || return 0
  local dir="$1" file reason
  [[ -d "$dir" ]] || return 0
  while IFS= read -r -d '' file; do
    if ! reason="$(branch_scope_verify_body "$(cat "$file")")"; then
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
