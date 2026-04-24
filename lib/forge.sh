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

# RepoLens — Forge provider detection
#
# Foundation of the multi-forge roadmap (issues #57 → #64). This module is
# intentionally narrow: a single pure function that classifies a git remote
# URL by forge provider. No CLI wiring, no auth/side-effectful wrappers —
# those land in later tickets.

set -uo pipefail

# detect_forge_provider <remote_url>
#   Prints exactly one of: gh | tea | fj | unknown
#
#   Detection rules:
#     host == github.com         -> gh
#     host == codeberg.org       -> fj
#     host matches *gitea*       -> tea   (case-insensitive substring)
#     anything else / malformed  -> unknown
#
#   Supported URL forms:
#     https://[user@]host[:port]/owner/repo[.git]
#     git@host:owner/repo[.git]                         (scp-like SSH)
#     ssh://[user@]host[:port]/owner/repo[.git]
#
#   Exit code is always 0 — callers parse stdout.
detect_forge_provider() {
  local url="${1:-}"
  if [[ -z "$url" ]]; then
    printf 'unknown\n'
    return 0
  fi

  local host=""

  # Form 1: scp-like SSH — user@host:path (no scheme, colon separates host from path).
  # Must be checked before the URL-with-scheme form because it has no "://".
  if [[ "$url" =~ ^[^@/:]+@([^:/]+): ]]; then
    host="${BASH_REMATCH[1]}"
  # Form 2: URL with scheme — scheme://[user@]host[:port]/path
  elif [[ "$url" =~ ^[a-zA-Z][a-zA-Z0-9+.-]*://([^/]+)(/|$) ]]; then
    local authority="${BASH_REMATCH[1]}"
    # Strip optional userinfo prefix
    authority="${authority#*@}"
    # Strip optional :port suffix
    host="${authority%%:*}"
  fi

  if [[ -z "$host" ]]; then
    printf 'unknown\n'
    return 0
  fi

  # Hosts are case-insensitive per RFC 3986 §3.2.2.
  local host_lower="${host,,}"

  # Exact-match rules come first so a host like "gitea.github.com" (hypothetical)
  # would not incorrectly classify as tea.
  case "$host_lower" in
    github.com)    printf 'gh\n' ;;
    codeberg.org)  printf 'fj\n' ;;
    *gitea*)       printf 'tea\n' ;;
    *)             printf 'unknown\n' ;;
  esac
  return 0
}
