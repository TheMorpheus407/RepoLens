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
# bare citations require a path separator/extension or a conventional root file.
# URLs (including ports) and timestamps are prose, not source citations.
repolens_extract_citations() {
  local body="$1" token path
  {
    while IFS= read -r token; do
      path="${token%:*}"
      [[ "$path" == *://* || "$path" =~ ^[0-9:]+$ ]] && continue
      printf '%s\n' "$token"
    done < <(grep -oE '`[^`]+:[0-9]+(-[0-9]+)?`' <<< "$body" | sed 's/^`//; s/`$//')
    while IFS= read -r token; do
      path="${token%:*}"
      case "$path" in
        */*|*.*|Makefile|Dockerfile|Containerfile|Jenkinsfile|LICENSE|README|Gemfile|Rakefile|Procfile)
          printf '%s\n' "$token" ;;
      esac
    done < <(sed -E 's#https?://[^[:space:]<>`]+##g; s/`[^`]*`//g' <<< "$body" \
      | grep -oE '[A-Za-z_./-][A-Za-z0-9_./-]*:[0-9]+(-[0-9]+)?')
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
  citations="$(repolens_extract_citations "$body")"
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
