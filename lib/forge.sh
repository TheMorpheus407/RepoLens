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

# RepoLens — Forge provider detection and wrapper dispatch

set -uo pipefail

# detect_forge_provider <remote_url>
#   Prints exactly one of: gh | glab | tea | fj | unknown
#
#   Detection rules:
#     host == github.com                  -> gh
#     host == codeberg.org                -> fj
#     host matches gitlab.* or *.gitlab.* -> glab  (self-hosted GitLab, case-insensitive)
#     host matches gitea.* or *.gitea.*   -> tea  (gitea must be a full DNS
#                                                  label, not a substring)
#     scheme == http                      -> unknown  (mirrors detect_forge_host's
#                                                      plain-HTTP rejection so the
#                                                      two functions stay consistent)
#     anything else / malformed           -> unknown
#
#   Supported URL forms:
#     https://[user@]host[:port]/owner/repo[.git]
#     git@host:owner/repo[.git]                         (scp-like SSH)
#     ssh://[user@]host[:port]/owner/repo[.git]
#
#   Exit code is always 0 — callers parse stdout.
detect_forge_provider() {
  local url="${1:-}"
  local host
  host="$(_forge_remote_host "$url")"

  if [[ -z "$host" ]]; then
    printf 'unknown\n'
    return 0
  fi

  # Plain HTTP origins are rejected to mirror detect_forge_host's HTTP guard
  # (lib/forge.sh:86-89). Without this, an `http://gitea.example.com/...`
  # would yield provider='tea' while host='', leaving FORGE_HOST silently empty.
  if [[ "$url" =~ ^[Hh][Tt][Tt][Pp]:// ]]; then
    printf 'unknown\n'
    return 0
  fi

  # Hosts are case-insensitive per RFC 3986 §3.2.2.
  local host_lower="${host,,}"

  # Exact-match rules come first so a host like "gitea.github.com" (hypothetical)
  # would not incorrectly classify as tea. The gitea pattern requires "gitea"
  # to be a full DNS label (delimited by dots) so substrings like
  # "gitlab.gitea-mirror.com" or "my-gitea-instance.io" do not false-match.
  case "$host_lower" in
    github.com)               printf 'gh\n' ;;
    codeberg.org)             printf 'fj\n' ;;
    gitlab.*|*.gitlab.*)      printf 'glab\n' ;;
    gitea.*|*.gitea.*)        printf 'tea\n' ;;
    *)                        printf 'unknown\n' ;;
  esac
  return 0
}

# detect_forge_host <remote_url>
#   Prints the host/base URL to pass to `fj -H`.
#
#   Codeberg and SSH remotes use the bare host. HTTPS self-hosted Forgejo
#   remotes preserve scheme, port, and any base path before owner/repo.
#   Plain HTTP remotes are rejected by returning an empty binding so callers do
#   not pass authenticated fj traffic over an insecure transport.
#   Exit code is always 0; malformed or empty input prints an empty string.
detect_forge_host() {
  local url="${1:-}"
  if [[ -z "$url" ]]; then
    printf '\n'
    return 0
  fi

  local host
  host="$(_forge_remote_host "$url")"
  if [[ -z "$host" ]]; then
    printf '\n'
    return 0
  fi

  if [[ "$url" =~ ^([a-zA-Z][a-zA-Z0-9+.-]*)://([^/]+)(/.*)?$ ]]; then
    local scheme="${BASH_REMATCH[1],,}"
    local authority="${BASH_REMATCH[2]}"
    local path="${BASH_REMATCH[3]:-}"

    if [[ "$scheme" == "http" ]]; then
      printf '\n'
      return 0
    fi

    if [[ "$scheme" == "https" ]]; then
      if [[ "$host" == "codeberg.org" ]]; then
        printf 'codeberg.org\n'
        return 0
      fi

      authority="${authority##*@}"
      local host_part="${authority%%:*}"
      local port_part=""
      if [[ "$authority" == *:* ]]; then
        port_part=":${authority#*:}"
      fi

      local base_path
      base_path="$(_forge_http_base_path "$path")"
      printf '%s://%s%s%s\n' "$scheme" "${host_part,,}" "$port_part" "$base_path"
      return 0
    fi

    if [[ "$scheme" == "ssh" ]]; then
      printf '%s\n' "$host"
      return 0
    fi

    printf '\n'
    return 0
  fi

  printf '%s\n' "$host"
  return 0
}

# forge_remote_repo_slug <remote_url>
#   Prints the owner/repo slug from a supported forge remote URL.
#   Supported URL forms mirror detect_forge_provider:
#     https://[user@]host[:port][/base]/owner/repo[.git]
#     git@host:owner/repo[.git]
#     ssh://[user@]host[:port]/owner/repo[.git]
#   Malformed or too-short paths print an empty string and return 0.
forge_remote_repo_slug() {
  local url="${1:-}" path
  path="$(_forge_remote_path "$url")"
  path="${path#/}"
  path="${path%.git}"

  if [[ -z "$path" ]]; then
    printf '\n'
    return 0
  fi

  local -a parts=()
  IFS='/' read -r -a parts <<< "$path"
  if (( ${#parts[@]} < 2 )); then
    printf '\n'
    return 0
  fi

  printf '%s\n' "$path"
  return 0
}

_forge_remote_host() {
  local url="${1:-}"
  local host=""

  if [[ -z "$url" ]]; then
    printf '\n'
    return 0
  fi

  # Form 1: scp-like SSH — user@host:path (no scheme, colon separates host from path).
  if [[ "$url" =~ ^[^@/:]+@([^:/]+): ]]; then
    host="${BASH_REMATCH[1]}"
  # Form 2: URL with scheme — scheme://[user@]host[:port]/path
  elif [[ "$url" =~ ^[a-zA-Z][a-zA-Z0-9+.-]*://([^/]+)(/|$) ]]; then
    local authority="${BASH_REMATCH[1]}"
    authority="${authority##*@}"
    host="${authority%%:*}"
  fi

  printf '%s\n' "${host,,}"
  return 0
}

_forge_remote_path() {
  local url="${1:-}" path=""

  if [[ -z "$url" ]]; then
    printf '\n'
    return 0
  fi

  # Form 1: scp-like SSH — user@host:path (no scheme, colon separates host from path).
  if [[ "$url" =~ ^[^@/:]+@[^:/]+:(.+)$ ]]; then
    path="${BASH_REMATCH[1]}"
  # Form 2: URL with scheme — scheme://[user@]host[:port]/path
  elif [[ "$url" =~ ^[a-zA-Z][a-zA-Z0-9+.-]*://[^/]+/(.*)$ ]]; then
    path="${BASH_REMATCH[1]}"
  fi

  path="${path%%\?*}"
  path="${path%%#*}"
  while [[ "$path" == */ ]]; do
    path="${path%/}"
  done
  path="${path%.git}"

  printf '%s\n' "$path"
  return 0
}

_forge_http_base_path() {
  local path="${1:-}"
  path="${path%%\?*}"
  path="${path%%#*}"
  while [[ "$path" == */ ]]; do
    path="${path%/}"
  done
  path="${path#/}"

  if [[ -z "$path" ]]; then
    printf ''
    return 0
  fi

  local -a parts=()
  IFS='/' read -r -a parts <<< "$path"
  local count="${#parts[@]}"
  if (( count <= 2 )); then
    printf ''
    return 0
  fi

  local base="" i
  for ((i = 0; i < count - 2; i++)); do
    [[ -n "${parts[$i]}" ]] || continue
    base+="/${parts[$i]}"
  done
  printf '%s' "$base"
  return 0
}

# require_forge_cli <provider>
#   Verifies the forge CLI binary for <provider> is on PATH.
#   On success: returns 0 silently.
#   On failure: calls die() with a provider-specific install hint (exit 1).
#
#   Valid providers: gh | glab | tea | fj
#   Any other value dies with an "unknown provider" message to guard against
#   caller typos.
#
#   Depends on die() from lib/core.sh — sourcing forge.sh without core.sh
#   means callers must define die themselves (the companion
#   detect_forge_provider has no such dependency).
require_forge_cli() {
  local provider="${1:-}"
  case "$provider" in
    gh)
      command -v gh >/dev/null 2>&1 \
        || die "gh not found — install from https://cli.github.com"
      ;;
    glab)
      command -v glab >/dev/null 2>&1 \
        || die "glab not found — install from https://gitlab.com/gitlab-org/cli"
      ;;
    tea)
      command -v tea >/dev/null 2>&1 \
        || die "tea not found — install from https://gitea.com/gitea/tea"
      ;;
    fj)
      command -v fj >/dev/null 2>&1 \
        || die "fj not found — install from https://codeberg.org/forgejo-contrib/forgejo-cli"
      ;;
    *)
      die "require_forge_cli: unknown provider '$provider' (expected gh|glab|tea|fj)"
      ;;
  esac
}

# forge_prompt_issue_create <label> <owner/repo> <project_path>
#   Prints provider-specific issue creation syntax for rendered agent prompts.
#   The command intentionally includes literal "$title", "$body", and
#   "$body_file" operands so agents can substitute concrete finding values.
forge_prompt_issue_create() {
  local label="${1:-}" repo="${2:-}" project_path="${3:-}"
  [[ -n "$label" ]] || label="<lens-label>"
  [[ -n "$repo" ]] || repo="<owner/repo>"

  case "${FORGE_PROVIDER:-}" in
    gh)
      printf 'gh issue create -R %s --title "$title" --body-file "$body_file" --label %s\n' \
        "$repo" "$label"
      ;;
    glab)
      local glab_host_prefix=""
      local _gh="${FORGE_HOST:-}"
      if [[ "$_gh" =~ ^https?://([^/:]+) ]]; then _gh="${BASH_REMATCH[1]}"; fi
      [[ -n "$_gh" && "$_gh" != "gitlab.com" ]] && glab_host_prefix="GITLAB_HOST=$_gh "
      printf '%sglab issue create -R %s --title "$title" --description "$body" --label %s\n' \
        "$glab_host_prefix" "$repo" "$label"
      ;;
    tea)
      printf 'tea issues create %s --title "$title" --description "$body" --labels %s\n' \
        "$(_forge_prompt_tea_target "$repo" "$project_path")" "$label"
      ;;
    fj)
      local host="${FORGE_HOST:-<forge-host>}"
      printf 'issue_output="$(fj -H %s issue create --repo %s "$title" --body "$body" --no-template)" && issue_number="${issue_output##*issues/}" && issue_number="${issue_number%%[^0-9]*}" && issue_number="${issue_number:-${issue_output##*#}}" && issue_number="${issue_number%%[^0-9]*}" && [[ -n "$issue_number" ]] && fj -H %s issue edit "%s#$issue_number" labels --add %s\n' \
        "$host" "$repo" "$host" "$repo" "$label"
      ;;
    *)
      printf 'Use the active forge CLI to create the issue with title, body, repo %s, and label %s\n' \
        "$repo" "$label"
      ;;
  esac
}

# forge_prompt_label_create <label> <color> <owner/repo> <project_path>
#   Prints provider-specific label creation syntax for rendered prompts.
forge_prompt_label_create() {
  local label="${1:-}" color="${2:-}" repo="${3:-}" project_path="${4:-}"
  [[ -n "$label" ]] || label="<label>"
  [[ -n "$color" ]] || color="ededed"
  [[ -n "$repo" ]] || repo="<owner/repo>"

  case "${FORGE_PROVIDER:-}" in
    gh)
      printf 'gh label create %s --color %s --force -R %s\n' "$label" "$color" "$repo"
      ;;
    glab)
      local glab_host_prefix=""
      local _gh="${FORGE_HOST:-}"
      if [[ "$_gh" =~ ^https?://([^/:]+) ]]; then _gh="${BASH_REMATCH[1]}"; fi
      [[ -n "$_gh" && "$_gh" != "gitlab.com" ]] && glab_host_prefix="GITLAB_HOST=$_gh "
      printf '%sglab label create -R %s --name %s --color "#%s"\n' \
        "$glab_host_prefix" "$repo" "$label" "${color#\#}"
      ;;
    tea)
      printf 'tea labels create --name %s --color %s %s\n' \
        "$label" "$color" "$(_forge_prompt_tea_target "$repo" "$project_path")"
      ;;
    fj)
      local host="${FORGE_HOST:-<forge-host>}"
      local fj_color="$color"
      [[ "$fj_color" == \#* ]] || fj_color="#$fj_color"
      printf 'fj -H %s repo labels %s create %s %s\n' "$host" "$repo" "$label" "$fj_color"
      ;;
    *)
      printf 'Use the active forge CLI to create label %s with color %s on %s\n' \
        "$label" "$color" "$repo"
      ;;
  esac
}

# forge_prompt_issue_list <state> <owner/repo> <project_path>
#   Prints provider-specific issue listing syntax for duplicate checks.
forge_prompt_issue_list() {
  local state="${1:-open}" repo="${2:-}" project_path="${3:-}"
  [[ -n "$repo" ]] || repo="<owner/repo>"

  case "${FORGE_PROVIDER:-}" in
    gh)
      printf 'gh issue list -R %s --state %s --limit 100\n' "$repo" "$state"
      ;;
    glab)
      local glab_host_prefix=""
      local _gh="${FORGE_HOST:-}"
      if [[ "$_gh" =~ ^https?://([^/:]+) ]]; then _gh="${BASH_REMATCH[1]}"; fi
      [[ -n "$_gh" && "$_gh" != "gitlab.com" ]] && glab_host_prefix="GITLAB_HOST=$_gh "
      # GitLab uses "opened" not "open"
      local gl_state="$state"
      [[ "$gl_state" == "open" ]] && gl_state="opened"
      printf '%sglab issue list -R %s --state %s --per-page 100\n' "$glab_host_prefix" "$repo" "$gl_state"
      ;;
    tea)
      printf 'tea issues list %s --state %s --limit 100\n' \
        "$(_forge_prompt_tea_target "$repo" "$project_path")" "$state"
      ;;
    fj)
      local host="${FORGE_HOST:-<forge-host>}"
      printf 'fj -H %s --style minimal issue search --repo %s --state %s\n' \
        "$host" "$repo" "$state"
      ;;
    *)
      printf 'Use the active forge CLI to list %s issues on %s\n' "$state" "$repo"
      ;;
  esac
}

_forge_prompt_tea_target() {
  local repo="${1:-<owner/repo>}" project_path="${2:-}"
  local remote="${FORGE_REMOTE_NAME:-origin}"

  if [[ -n "$project_path" ]]; then
    printf -- '--repo %s --remote %s' "$(_forge_prompt_shell_quote "$project_path")" "$remote"
  elif [[ -n "${FORGE_PROJECT_PATH:-}" ]]; then
    printf -- '--repo %s --remote %s' "$(_forge_prompt_shell_quote "$FORGE_PROJECT_PATH")" "$remote"
  elif [[ -n "${FORGE_TEA_LOGIN:-}" ]]; then
    printf -- '--repo %s --login %s' "$repo" "$FORGE_TEA_LOGIN"
  else
    printf -- '--repo %s --remote %s' "$repo" "$remote"
  fi
}

_forge_prompt_shell_quote() {
  local value="${1:-}"
  value="$(printf '%s' "$value" | sed "s/'/'\\\\''/g")"
  printf "'%s'" "$value"
}

# forge_auth_status
#   Verify the user is authenticated against the current forge. Prints
#   nothing on success; dies on failure. Provider dispatch reads
#   $FORGE_PROVIDER (resolved by repolens.sh before any forge call).
#
#   gh  → `gh auth status` — exit 0 ok, non-zero triggers die with the
#         exact README-troubleshooting message.
#   tea → `tea login list` — exit 0 ok, non-zero triggers die with a
#         Gitea-specific setup hint.
#   fj  → `fj -H <host> whoami` — exit 0 ok, non-zero triggers die with
#         a Forgejo-specific setup hint.
#
#   Callers in repolens.sh keep their outer `if ! $LOCAL_MODE` gate —
#   this wrapper is provider-aware but not mode-aware.
#
#   Depends on die() from lib/core.sh.
forge_auth_status() {
  case "${FORGE_PROVIDER:-}" in
    gh)
      gh auth status >/dev/null 2>&1 \
        || die "gh is not authenticated. Run 'gh auth login'."
      ;;
    glab)
      local _glab_host=""
      if [[ -n "${FORGE_HOST:-}" ]]; then
        _glab_host="${FORGE_HOST}"
        if [[ "$_glab_host" =~ ^https?://([^/:]+) ]]; then _glab_host="${BASH_REMATCH[1]}"; fi
      fi
      GITLAB_HOST="$_glab_host" glab auth status >/dev/null 2>&1 \
        || die "glab is not authenticated. Run 'glab auth login'."
      ;;
    tea)
      tea login list >/dev/null 2>&1 \
        || die "tea is not authenticated. Run 'tea login add'."
      ;;
    fj)
      [[ -n "${FORGE_HOST:-}" ]] \
        || die "forge_auth_status: fj backend requires FORGE_HOST"
      fj -H "$FORGE_HOST" whoami >/dev/null 2>&1 \
        || die "fj is not authenticated. Run 'fj -H $FORGE_HOST auth login' or 'fj -H $FORGE_HOST auth add-key <user>'."
      ;;
    *)
      die "forge_auth_status: unknown provider '${FORGE_PROVIDER:-}' (expected gh|glab|tea|fj)"
      ;;
  esac
}

# forge_label_create <label> <color> <owner/repo>
#   Create or update (upsert) a label on the target repository.
#   Best-effort by design: non-zero exit from the underlying CLI is
#   swallowed (matches the pre-refactor inline `|| true`) so a labels
#   permission error never halts a run.
#
#   gh  → `gh label create <label> --color <color> --force -R <owner/repo>`
#         with stderr suppressed and exit ignored.
#   tea → `tea labels create --name <label> --color <color> ...`
#         bound to $FORGE_PROJECT_PATH/$FORGE_REMOTE_NAME or $FORGE_TEA_LOGIN.
#   fj  → `fj -H <host> repo labels <owner/repo> create <label> <color>`
#         with stderr suppressed and exit ignored.
#
#   All three args are required; any missing arg is a caller bug and
#   dies loudly rather than pass garbage to the forge CLI. Unknown
#   providers are treated like other best-effort failures: warn and no-op.
#
#   Depends on die() from lib/core.sh.
forge_label_create() {
  local label="${1:-}" color="${2:-}" repo="${3:-}"
  [[ -n "$label" && -n "$color" && -n "$repo" ]] \
    || die "forge_label_create: missing argument (label='$label' color='$color' repo='$repo')"

  case "${FORGE_PROVIDER:-}" in
    gh)
      gh label create "$label" --color "$color" --force -R "$repo" 2>/dev/null || true
      ;;
    glab)
      local _glab_host=""
      if [[ -n "${FORGE_HOST:-}" ]]; then
        _glab_host="${FORGE_HOST}"
        if [[ "$_glab_host" =~ ^https?://([^/:]+) ]]; then _glab_host="${BASH_REMATCH[1]}"; fi
        [[ "$_glab_host" == "gitlab.com" ]] && _glab_host=""
      fi
      # GitLab requires # prefix on hex color codes
      GITLAB_HOST="$_glab_host" glab label create -R "$repo" \
        --name "$label" --color "#${color#\#}" 2>/dev/null || true
      ;;
    tea)
      local -a tea_target_flags=()
      if [[ -n "${FORGE_PROJECT_PATH:-}" ]]; then
        tea_target_flags=(--repo "$FORGE_PROJECT_PATH" --remote "${FORGE_REMOTE_NAME:-origin}")
      elif [[ -n "${FORGE_TEA_LOGIN:-}" ]]; then
        tea_target_flags=(--repo "$repo" --login "$FORGE_TEA_LOGIN")
      else
        die "forge_label_create: tea backend requires FORGE_PROJECT_PATH or FORGE_TEA_LOGIN for target binding"
      fi
      tea labels create --name "$label" --color "$color" "${tea_target_flags[@]}" 2>/dev/null || true
      ;;
    fj)
      [[ -n "${FORGE_HOST:-}" ]] \
        || die "forge_label_create: fj backend requires FORGE_HOST"
      local fj_color="$color"
      [[ "$fj_color" == \#* ]] || fj_color="#$fj_color"
      fj -H "$FORGE_HOST" repo labels "$repo" create "$label" "$fj_color" 2>/dev/null || true
      ;;
    *)
      _forge_warn "forge_label_create: unknown provider '${FORGE_PROVIDER:-}' (expected gh|glab|tea|fj)"
      return 0
      ;;
  esac
}

# forge_label_list_names <owner/repo>
#   Prints existing label names one per line and returns 0 on success.
#   On provider/parse failure, prints nothing and returns non-zero so callers
#   can fall back to best-effort create-all behavior.
#
#   gh  → `gh label list -R <owner/repo> --limit 1000 --json name`, parsed via jq.
#   tea → `tea labels list ... --output json`, bound to
#         $FORGE_PROJECT_PATH/$FORGE_REMOTE_NAME or $FORGE_TEA_LOGIN, parsed via jq.
#   fj  → `fj -H <host> repo labels <owner/repo> list`, parsed from official
#         minimal/CSV-like output.
forge_label_list_names() {
  local repo="${1:-}"
  [[ -n "$repo" ]] \
    || die "forge_label_list_names: missing argument (repo='$repo')"

  case "${FORGE_PROVIDER:-}" in
    gh)
      local gh_err gh_out gh_rc
      gh_err="$(mktemp 2>/dev/null)" || gh_err=""
      if [[ -n "$gh_err" ]]; then
        gh_out="$(gh label list -R "$repo" --limit 1000 --json name 2>"$gh_err")"
        gh_rc=$?
      else
        gh_out="$(gh label list -R "$repo" --limit 1000 --json name 2>/dev/null)"
        gh_rc=$?
      fi
      if [[ "$gh_rc" -ne 0 ]]; then
        local first_err=""
        if [[ -n "$gh_err" && -s "$gh_err" ]]; then
          first_err="$(head -n1 "$gh_err" 2>/dev/null || true)"
        fi
        [[ -n "$gh_err" ]] && rm -f "$gh_err"
        _forge_warn "forge_label_list_names: gh failed for repo=$repo rc=$gh_rc err=${first_err:-<empty>}"
        return 1
      fi
      [[ -n "$gh_err" ]] && rm -f "$gh_err"

      if ! printf '%s' "$gh_out" | jq -r '.[].name // empty' 2>/dev/null; then
        _forge_warn "forge_label_list_names: jq failed to parse gh output for repo=$repo"
        return 1
      fi
      return 0
      ;;

    tea)
      local -a tea_target_flags=()
      if [[ -n "${FORGE_PROJECT_PATH:-}" ]]; then
        tea_target_flags=(--repo "$FORGE_PROJECT_PATH" --remote "${FORGE_REMOTE_NAME:-origin}")
      elif [[ -n "${FORGE_TEA_LOGIN:-}" ]]; then
        tea_target_flags=(--repo "$repo" --login "$FORGE_TEA_LOGIN")
      else
        die "forge_label_list_names: tea backend requires FORGE_PROJECT_PATH or FORGE_TEA_LOGIN for target binding"
      fi

      local tea_err tea_out tea_rc
      tea_err="$(mktemp 2>/dev/null)" || tea_err=""
      if [[ -n "$tea_err" ]]; then
        tea_out="$(tea labels list "${tea_target_flags[@]}" --output json 2>"$tea_err")"
        tea_rc=$?
      else
        tea_out="$(tea labels list "${tea_target_flags[@]}" --output json 2>/dev/null)"
        tea_rc=$?
      fi
      if [[ "$tea_rc" -ne 0 ]]; then
        local first_err=""
        if [[ -n "$tea_err" && -s "$tea_err" ]]; then
          first_err="$(head -n1 "$tea_err" 2>/dev/null || true)"
        fi
        [[ -n "$tea_err" ]] && rm -f "$tea_err"
        _forge_warn "forge_label_list_names: tea failed for repo=$repo rc=$tea_rc err=${first_err:-<empty>}"
        return 1
      fi
      [[ -n "$tea_err" ]] && rm -f "$tea_err"

      local parsed
      if ! parsed="$(printf '%s' "$tea_out" | jq -r '.[].name // empty' 2>/dev/null)"; then
        _forge_warn "forge_label_list_names: jq failed to parse tea output for repo=$repo"
        return 1
      fi
      if [[ -z "$parsed" && -n "$tea_out" && "$tea_out" != "[]" ]]; then
        _forge_warn "forge_label_list_names: jq failed to parse tea output for repo=$repo"
        return 1
      fi
      [[ -n "$parsed" ]] && printf '%s\n' "$parsed"
      return 0
      ;;
    fj)
      [[ -n "${FORGE_HOST:-}" ]] \
        || die "forge_label_list_names: fj backend requires FORGE_HOST"

      local fj_err fj_out fj_rc
      fj_err="$(mktemp 2>/dev/null)" || fj_err=""
      if [[ -n "$fj_err" ]]; then
        fj_out="$(fj -H "$FORGE_HOST" repo labels "$repo" list 2>"$fj_err")"
        fj_rc=$?
      else
        fj_out="$(fj -H "$FORGE_HOST" repo labels "$repo" list 2>/dev/null)"
        fj_rc=$?
      fi
      if [[ "$fj_rc" -ne 0 ]]; then
        local first_err=""
        if [[ -n "$fj_err" && -s "$fj_err" ]]; then
          first_err="$(head -n1 "$fj_err" 2>/dev/null || true)"
        fi
        [[ -n "$fj_err" ]] && rm -f "$fj_err"
        _forge_warn "forge_label_list_names: fj failed for repo=$repo rc=$fj_rc err=${first_err:-<empty>}"
        return 1
      fi
      [[ -n "$fj_err" ]] && rm -f "$fj_err"

      local parsed
      if [[ -z "$fj_out" ]]; then
        return 0
      elif [[ "$fj_out" =~ ^[[:space:]]*[\[\{] ]]; then
        if ! parsed="$(printf '%s' "$fj_out" | jq -r '
          def items:
            if type == "array" then .
            elif (.labels? | type) == "array" then .labels
            elif (.data? | type) == "array" then .data
            else []
            end;
          items[]?.name // empty
        ' 2>/dev/null)"; then
          _forge_warn "forge_label_list_names: jq failed to parse fj output for repo=$repo"
          return 1
        fi
      else
        if ! parsed="$(printf '%s\n' "$fj_out" | awk '
          function trim(s) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
            return s
          }
          BEGIN { FS = ","; name_col = 0; mode = "" }
          /^[[:space:]]*$/ { next }
          mode == "" {
            first = trim($0)
            if (index(first, ",") > 0) {
              for (i = 1; i <= NF; i++) {
                field = tolower(trim($i))
                if (field == "name") {
                  name_col = i
                }
              }
              if (name_col == 0) {
                exit 2
              }
              mode = "csv"
              next
            }
            mode = "minimal"
          }
          mode == "csv" {
            if (NF < name_col) {
              exit 2
            }
            name = trim($name_col)
            if (name != "") {
              print name
            }
            next
          }
          mode == "minimal" {
            name = trim($0)
            if (name != "") {
              print name
            }
          }
        ' 2>/dev/null)"; then
          _forge_warn "forge_label_list_names: failed to parse fj output for repo=$repo"
          return 1
        fi
      fi
      [[ -n "$parsed" ]] && printf '%s\n' "$parsed"
      return 0
      ;;
    glab)
      local _glab_host=""
      if [[ -n "${FORGE_HOST:-}" ]]; then
        _glab_host="${FORGE_HOST}"
        if [[ "$_glab_host" =~ ^https?://([^/:]+) ]]; then _glab_host="${BASH_REMATCH[1]}"; fi
        [[ "$_glab_host" == "gitlab.com" ]] && _glab_host=""
      fi
      local glab_err glab_out glab_rc
      glab_err="$(mktemp 2>/dev/null)" || glab_err=""
      if [[ -n "$glab_err" ]]; then
        glab_out="$(GITLAB_HOST="$_glab_host" glab label list -R "$repo" --output json 2>"$glab_err")"
        glab_rc=$?
      else
        glab_out="$(GITLAB_HOST="$_glab_host" glab label list -R "$repo" --output json 2>/dev/null)"
        glab_rc=$?
      fi
      if [[ "$glab_rc" -ne 0 ]]; then
        local first_err=""
        if [[ -n "$glab_err" && -s "$glab_err" ]]; then
          first_err="$(head -n1 "$glab_err" 2>/dev/null || true)"
        fi
        [[ -n "$glab_err" ]] && rm -f "$glab_err"
        _forge_warn "forge_label_list_names: glab failed for repo=$repo rc=$glab_rc err=${first_err:-<empty>}"
        return 1
      fi
      [[ -n "$glab_err" ]] && rm -f "$glab_err"
      if ! printf '%s' "$glab_out" | jq -r '.[].name // empty' 2>/dev/null; then
        _forge_warn "forge_label_list_names: jq failed to parse glab output for repo=$repo"
        return 1
      fi
      return 0
      ;;
    *)
      _forge_warn "forge_label_list_names: unsupported provider '${FORGE_PROVIDER:-}'"
      return 1
      ;;
  esac
}

_forge_label_cache_base_dir() {
  if [[ -n "${REPOLENS_LABEL_CACHE_DIR:-}" ]]; then
    printf '%s\n' "$REPOLENS_LABEL_CACHE_DIR"
  elif [[ -n "${XDG_CACHE_HOME:-}" ]]; then
    printf '%s\n' "$XDG_CACHE_HOME/repolens/labels"
  else
    printf '%s\n' "${HOME:-.}/.cache/repolens/labels"
  fi
}

_forge_label_set_hash() {
  local label_set_file="${1:-}"
  if command -v sha256sum >/dev/null 2>&1; then
    LC_ALL=C sort "$label_set_file" | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    LC_ALL=C sort "$label_set_file" | shasum -a 256 | awk '{print $1}'
  else
    LC_ALL=C sort "$label_set_file" | cksum | awk '{print $1 "-" $2}'
  fi
}

_forge_label_cache_repo_key() {
  local repo="${1:-}"
  local provider="${FORGE_PROVIDER:-unknown}"
  printf '%s/%s\n' "$provider" "$(printf '%s' "$repo" | sed 's#[^A-Za-z0-9._-]#_#g')"
}

_forge_label_sentinel_is_fresh() {
  local sentinel="${1:-}" ttl="${REPOLENS_LABEL_CACHE_TTL:-600}"
  [[ -n "$sentinel" && -f "$sentinel" ]] || return 1
  [[ "$ttl" =~ ^[0-9]+$ ]] || ttl=600
  [[ "$ttl" -gt 0 ]] || return 1

  local now modified age
  now="$(date +%s 2>/dev/null || printf '0')"
  modified="$(stat -c %Y "$sentinel" 2>/dev/null || printf '0')"
  [[ "$now" =~ ^[0-9]+$ && "$modified" =~ ^[0-9]+$ ]] || return 1
  age=$((now - modified))
  [[ "$age" -ge 0 && "$age" -lt "$ttl" ]]
}

_forge_label_create_all_from_file() {
  local repo="${1:-}" label_set_file="${2:-}"
  local line label color
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    [[ "$line" == *=* ]] || continue
    label="${line%%=*}"
    color="${line#*=}"
    [[ -n "$label" && -n "$color" ]] || continue
    forge_label_create "$label" "$color" "$repo"
  done < "$label_set_file"
}

_forge_label_bootstrap_unlocked() {
  local repo="${1:-}" label_set_file="${2:-}"
  local existing_out
  if ! existing_out="$(forge_label_list_names "$repo")"; then
    _forge_label_create_all_from_file "$repo" "$label_set_file"
    return 0
  fi

  local -A existing=()
  local existing_label
  while IFS= read -r existing_label || [[ -n "$existing_label" ]]; do
    [[ -n "$existing_label" ]] || continue
    existing["$existing_label"]=1
  done <<< "$existing_out"

  local line label color
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    [[ "$line" == *=* ]] || continue
    label="${line%%=*}"
    color="${line#*=}"
    [[ -n "$label" && -n "$color" ]] || continue
    if [[ -z "${existing[$label]:-}" ]]; then
      forge_label_create "$label" "$color" "$repo"
    fi
  done < "$label_set_file"
}

# forge_label_bootstrap <owner/repo> <label-set-file>
#   Coordinates repository label seeding across concurrent RepoLens processes.
#   The label-set file is newline-delimited label=color pairs. The helper lists
#   existing labels once, creates only missing labels, and falls back to the
#   existing best-effort create-all loop when listing is unavailable.
forge_label_bootstrap() {
  local repo="${1:-}" label_set_file="${2:-}"
  [[ -n "$repo" && -n "$label_set_file" ]] \
    || die "forge_label_bootstrap: missing argument (repo='$repo' label_set_file='$label_set_file')"
  [[ -r "$label_set_file" ]] \
    || die "forge_label_bootstrap: label_set_file '$label_set_file' not readable"

  local cache_base repo_key cache_dir label_hash lock_file sentinel
  cache_base="$(_forge_label_cache_base_dir)"
  repo_key="$(_forge_label_cache_repo_key "$repo")"
  cache_dir="$cache_base/$repo_key"
  label_hash="$(_forge_label_set_hash "$label_set_file")"
  lock_file="$cache_dir/bootstrap.lock"
  sentinel="$cache_dir/$label_hash.seeded"

  mkdir -p "$cache_dir" 2>/dev/null || {
    _forge_label_bootstrap_unlocked "$repo" "$label_set_file" >/dev/null
    return 0
  }

  if ! command -v flock >/dev/null 2>&1; then
    if ! _forge_label_sentinel_is_fresh "$sentinel"; then
      _forge_label_bootstrap_unlocked "$repo" "$label_set_file" >/dev/null
      : > "$sentinel" 2>/dev/null || true
    fi
    return 0
  fi

  local lock_fd
  exec {lock_fd}>"$lock_file" || {
    _forge_label_bootstrap_unlocked "$repo" "$label_set_file" >/dev/null
    return 0
  }

  if flock "$lock_fd"; then
    if ! _forge_label_sentinel_is_fresh "$sentinel"; then
      _forge_label_bootstrap_unlocked "$repo" "$label_set_file" >/dev/null
      : > "$sentinel" 2>/dev/null || true
    fi
    flock -u "$lock_fd" 2>/dev/null || true
  else
    _forge_label_bootstrap_unlocked "$repo" "$label_set_file" >/dev/null
  fi
  exec {lock_fd}>&-
  return 0
}

_forge_backlog_inline_text() {
  local value="${1:-}" max_len="${2:-3000}"
  value="${value//$'\r'/ }"
  value="${value//$'\n'/ }"
  value="${value//$'\t'/ }"
  while [[ "$value" == *"  "* ]]; do
    value="${value//  / }"
  done
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  if [[ "$max_len" =~ ^[0-9]+$ && "$max_len" -gt 0 && "${#value}" -gt "$max_len" ]]; then
    value="${value:0:max_len}..."
  fi
  printf '%s' "$value"
}

_forge_format_open_backlog_json() {
  local repo="$1" json="$2" rows number title body labels url count=0

  if ! rows="$(printf '%s' "$json" | jq -r '
    def items:
      if type == "array" then .
      elif (.issues? | type) == "array" then .issues
      elif (.data? | type) == "array" then .data
      else []
      end;
    def issue_number: .number // .index // .id // "";
    def clean:
      if . == null then ""
      else tostring | gsub("[\t\r\n]+"; " ") | gsub("  +"; " ")
      end;
    def label_name:
      if type == "object" then (.name // .title // .Name // .Title // empty)
      else tostring
      end;
    items
    | sort_by((issue_number | tostring | tonumber?) // 0)
    | .[]
    | [
        (issue_number | tostring),
        (.title | clean),
        ((.body // .description // .content // "") | clean),
        ([ (.labels // [])[]? | label_name ] | join(", ") | clean),
        ((.url // .html_url // .web_url // .HTMLURL // "") | clean)
      ]
    | @tsv
  ' 2>/dev/null)"; then
    _forge_warn "forge_open_issue_backlog_snapshot: jq failed to parse issue list for repo=$repo"
    return 1
  fi

  while IFS=$'\t' read -r number title body labels url; do
    [[ -n "$number$title$body$labels$url" ]] || continue
    count=$((count + 1))
    number="$(_forge_backlog_inline_text "$number" 80)"
    title="$(_forge_backlog_inline_text "$title" 500)"
    body="$(_forge_backlog_inline_text "$body" 3000)"
    labels="$(_forge_backlog_inline_text "$labels" 500)"
    url="$(_forge_backlog_inline_text "$url" 500)"

    [[ -n "$number" ]] || number="?"
    [[ -n "$title" ]] || title="<untitled>"
    [[ -n "$labels" ]] || labels="<none>"

    printf '### Open issue #%s: %s\n' "$number" "$title"
    printf -- '- URL: %s\n' "${url:-<unknown>}"
    printf -- '- Labels: %s\n' "$labels"
    if [[ -n "$body" ]]; then
      printf -- '- Body excerpt: %s\n' "$body"
    else
      printf -- '- Body excerpt: <empty>\n'
    fi
    printf '\n'
  done <<< "$rows"

  if (( count == 0 )); then
    printf 'No current open forge issues were found for %s.\n' "$repo"
  fi
}

# forge_open_issue_backlog_snapshot <owner/repo>
#   Emits a bounded markdown snapshot of all currently open issues on the
#   target repo. This is planning context for greenfield deduplication, not the
#   label-scoped accounting path used by forge_issue_list_count.
forge_open_issue_backlog_snapshot() {
  local repo="${1:-}"
  [[ -n "$repo" ]] || die "forge_open_issue_backlog_snapshot: missing repo"

  case "${FORGE_PROVIDER:-}" in
    gh)
      local gh_err gh_out gh_rc
      gh_err="$(mktemp 2>/dev/null)" || gh_err=""
      if [[ -n "$gh_err" ]]; then
        gh_out="$(gh issue list -R "$repo" --state open --limit 1000 \
          --json number,title,body,labels,url 2>"$gh_err")"
        gh_rc=$?
      else
        gh_out="$(gh issue list -R "$repo" --state open --limit 1000 \
          --json number,title,body,labels,url 2>/dev/null)"
        gh_rc=$?
      fi
      if [[ "$gh_rc" -ne 0 ]]; then
        local first_err=""
        if [[ -n "$gh_err" && -s "$gh_err" ]]; then
          first_err="$(head -n1 "$gh_err" 2>/dev/null || true)"
        fi
        [[ -n "$gh_err" ]] && rm -f "$gh_err"
        _forge_warn "forge_open_issue_backlog_snapshot: gh failed for repo=$repo rc=$gh_rc err=${first_err:-<empty>}"
        return 1
      fi
      [[ -n "$gh_err" ]] && rm -f "$gh_err"
      _forge_format_open_backlog_json "$repo" "$gh_out"
      return $?
      ;;
    tea)
      local -a tea_target_flags=()
      if [[ -n "${FORGE_PROJECT_PATH:-}" ]]; then
        tea_target_flags=(--repo "$FORGE_PROJECT_PATH" --remote "${FORGE_REMOTE_NAME:-origin}")
      elif [[ -n "${FORGE_TEA_LOGIN:-}" ]]; then
        tea_target_flags=(--repo "$repo" --login "$FORGE_TEA_LOGIN")
      else
        die "forge_open_issue_backlog_snapshot: tea backend requires FORGE_PROJECT_PATH or FORGE_TEA_LOGIN for target binding"
      fi

      local tea_err tea_out tea_rc
      tea_err="$(mktemp 2>/dev/null)" || tea_err=""
      if [[ -n "$tea_err" ]]; then
        tea_out="$(tea issues list "${tea_target_flags[@]}" --state open \
          --limit 1000 --output json 2>"$tea_err")"
        tea_rc=$?
      else
        tea_out="$(tea issues list "${tea_target_flags[@]}" --state open \
          --limit 1000 --output json 2>/dev/null)"
        tea_rc=$?
      fi
      if [[ "$tea_rc" -ne 0 ]]; then
        local first_err=""
        if [[ -n "$tea_err" && -s "$tea_err" ]]; then
          first_err="$(head -n1 "$tea_err" 2>/dev/null || true)"
        fi
        [[ -n "$tea_err" ]] && rm -f "$tea_err"
        _forge_warn "forge_open_issue_backlog_snapshot: tea failed for repo=$repo rc=$tea_rc err=${first_err:-<empty>}"
        return 1
      fi
      [[ -n "$tea_err" ]] && rm -f "$tea_err"
      _forge_format_open_backlog_json "$repo" "$tea_out"
      return $?
      ;;
    fj)
      [[ -n "${FORGE_HOST:-}" ]] \
        || die "forge_open_issue_backlog_snapshot: fj backend requires FORGE_HOST"

      local fj_err fj_out fj_rc
      fj_err="$(mktemp 2>/dev/null)" || fj_err=""
      if [[ -n "$fj_err" ]]; then
        fj_out="$(fj -H "$FORGE_HOST" --style minimal issue search \
          --repo "$repo" --state open 2>"$fj_err")"
        fj_rc=$?
      else
        fj_out="$(fj -H "$FORGE_HOST" --style minimal issue search \
          --repo "$repo" --state open 2>/dev/null)"
        fj_rc=$?
      fi
      if [[ "$fj_rc" -ne 0 ]]; then
        local first_err=""
        if [[ -n "$fj_err" && -s "$fj_err" ]]; then
          first_err="$(head -n1 "$fj_err" 2>/dev/null || true)"
        fi
        [[ -n "$fj_err" ]] && rm -f "$fj_err"
        _forge_warn "forge_open_issue_backlog_snapshot: fj failed for repo=$repo rc=$fj_rc err=${first_err:-<empty>}"
        return 1
      fi
      [[ -n "$fj_err" ]] && rm -f "$fj_err"
      _forge_format_open_backlog_json "$repo" "$fj_out"
      return $?
      ;;
    *)
      _forge_warn "forge_open_issue_backlog_snapshot: unknown provider '${FORGE_PROVIDER:-}' (expected gh|tea|fj)"
      return 1
      ;;
  esac
}

# forge_issue_list_count <owner/repo> <label>
#   Counts open issues carrying <label> on the target repository.
#   Prints the integer count on stdout and returns 0 on success.
#   On forge CLI or JSON parsing failure, prints nothing to stdout, emits
#   a warning diagnostic, and returns 1 so callers can distinguish "unknown"
#   from "legitimately zero".
#
#   gh  -> `gh issue list -R <owner/repo> --label <label> --state open
#          --limit 1000 --json number`, counted via jq.
#   tea -> `tea issues list ... --labels <label> --state open --limit 1000
#          --output json`, bound to $FORGE_PROJECT_PATH/$FORGE_REMOTE_NAME or
#          $FORGE_TEA_LOGIN, counted via jq.
#   fj  -> `fj -H <host> --style minimal issue search --repo <owner/repo>
#          --labels <label> --state open`, parsed from the leading count line.
#
#   Both args are required; missing args are caller bugs and die loudly.
#
#   Depends on die() from lib/core.sh and jq being available on PATH.
forge_issue_list_count() {
  local repo="${1:-}" label="${2:-}"
  [[ -n "$repo" && -n "$label" ]] \
    || die "forge_issue_list_count: missing argument (repo='$repo' label='$label')"

  case "${FORGE_PROVIDER:-}" in
    gh)
      local gh_err gh_out gh_rc
      gh_err="$(mktemp 2>/dev/null)" || gh_err=""
      if [[ -n "$gh_err" ]]; then
        gh_out="$(gh issue list -R "$repo" --label "$label" --state open \
          --limit 1000 --json number 2>"$gh_err")"
        gh_rc=$?
      else
        gh_out="$(gh issue list -R "$repo" --label "$label" --state open \
          --limit 1000 --json number 2>/dev/null)"
        gh_rc=$?
      fi
      if [[ "$gh_rc" -ne 0 ]]; then
        local first_err=""
        if [[ -n "$gh_err" && -s "$gh_err" ]]; then
          first_err="$(head -n1 "$gh_err" 2>/dev/null || true)"
        fi
        [[ -n "$gh_err" ]] && rm -f "$gh_err"
        _forge_warn "forge_issue_list_count: gh failed for repo=$repo label=$label rc=$gh_rc err=${first_err:-<empty>}"
        return 1
      fi
      [[ -n "$gh_err" ]] && rm -f "$gh_err"

      local n
      if ! n="$(printf '%s' "$gh_out" | jq 'length' 2>/dev/null)"; then
        _forge_warn "forge_issue_list_count: jq failed to parse gh output for repo=$repo label=$label"
        return 1
      fi
      if ! [[ "$n" =~ ^[0-9]+$ ]]; then
        _forge_warn "forge_issue_list_count: unexpected non-integer from jq for repo=$repo label=$label: '$n'"
        return 1
      fi
      printf '%s\n' "$n"
      return 0
      ;;
    tea)
      local -a tea_target_flags=()
      if [[ -n "${FORGE_PROJECT_PATH:-}" ]]; then
        tea_target_flags=(--repo "$FORGE_PROJECT_PATH" --remote "${FORGE_REMOTE_NAME:-origin}")
      elif [[ -n "${FORGE_TEA_LOGIN:-}" ]]; then
        tea_target_flags=(--repo "$repo" --login "$FORGE_TEA_LOGIN")
      else
        die "forge_issue_list_count: tea backend requires FORGE_PROJECT_PATH or FORGE_TEA_LOGIN for target binding"
      fi

      local tea_err tea_out tea_rc
      tea_err="$(mktemp 2>/dev/null)" || tea_err=""
      if [[ -n "$tea_err" ]]; then
        tea_out="$(tea issues list "${tea_target_flags[@]}" --labels "$label" --state open \
          --limit 1000 --output json 2>"$tea_err")"
        tea_rc=$?
      else
        tea_out="$(tea issues list "${tea_target_flags[@]}" --labels "$label" --state open \
          --limit 1000 --output json 2>/dev/null)"
        tea_rc=$?
      fi
      if [[ "$tea_rc" -ne 0 ]]; then
        local first_err=""
        if [[ -n "$tea_err" && -s "$tea_err" ]]; then
          first_err="$(head -n1 "$tea_err" 2>/dev/null || true)"
        fi
        [[ -n "$tea_err" ]] && rm -f "$tea_err"
        _forge_warn "forge_issue_list_count: tea failed for repo=$repo label=$label rc=$tea_rc err=${first_err:-<empty>}"
        return 1
      fi
      [[ -n "$tea_err" ]] && rm -f "$tea_err"

      local n
      if ! n="$(printf '%s' "$tea_out" | jq 'length' 2>/dev/null)"; then
        _forge_warn "forge_issue_list_count: jq failed to parse tea output for repo=$repo label=$label"
        return 1
      fi
      if ! [[ "$n" =~ ^[0-9]+$ ]]; then
        _forge_warn "forge_issue_list_count: unexpected non-integer from jq for repo=$repo label=$label: '$n'"
        return 1
      fi
      printf '%s\n' "$n"
      return 0
      ;;
    glab)
      local _glab_host=""
      if [[ -n "${FORGE_HOST:-}" ]]; then
        _glab_host="${FORGE_HOST}"
        if [[ "$_glab_host" =~ ^https?://([^/:]+) ]]; then _glab_host="${BASH_REMATCH[1]}"; fi
        [[ "$_glab_host" == "gitlab.com" ]] && _glab_host=""
      fi
      local glab_err glab_out glab_rc
      glab_err="$(mktemp 2>/dev/null)" || glab_err=""
      if [[ -n "$glab_err" ]]; then
        glab_out="$(GITLAB_HOST="$_glab_host" glab issue list -R "$repo" --label "$label" \
          --per-page 100 --output json 2>"$glab_err")"
        glab_rc=$?
      else
        glab_out="$(GITLAB_HOST="$_glab_host" glab issue list -R "$repo" --label "$label" \
          --per-page 100 --output json 2>/dev/null)"
        glab_rc=$?
      fi
      if [[ "$glab_rc" -ne 0 ]]; then
        local first_err=""
        if [[ -n "$glab_err" && -s "$glab_err" ]]; then
          first_err="$(head -n1 "$glab_err" 2>/dev/null || true)"
        fi
        [[ -n "$glab_err" ]] && rm -f "$glab_err"
        _forge_warn "forge_issue_list_count: glab failed for repo=$repo label=$label rc=$glab_rc err=${first_err:-<empty>}"
        return 1
      fi
      [[ -n "$glab_err" ]] && rm -f "$glab_err"
      local n
      if ! n="$(printf '%s' "$glab_out" | jq 'length' 2>/dev/null)"; then
        _forge_warn "forge_issue_list_count: jq failed to parse glab output for repo=$repo label=$label"
        return 1
      fi
      if ! [[ "$n" =~ ^[0-9]+$ ]]; then
        _forge_warn "forge_issue_list_count: unexpected non-integer from jq for repo=$repo label=$label: '$n'"
        return 1
      fi
      printf '%s\n' "$n"
      return 0
      ;;
    fj)
      [[ -n "${FORGE_HOST:-}" ]] \
        || die "forge_issue_list_count: fj backend requires FORGE_HOST"

      local fj_err fj_out fj_rc
      fj_err="$(mktemp 2>/dev/null)" || fj_err=""
      if [[ -n "$fj_err" ]]; then
        fj_out="$(fj -H "$FORGE_HOST" --style minimal issue search \
          --repo "$repo" --labels "$label" --state open 2>"$fj_err")"
        fj_rc=$?
      else
        fj_out="$(fj -H "$FORGE_HOST" --style minimal issue search \
          --repo "$repo" --labels "$label" --state open 2>/dev/null)"
        fj_rc=$?
      fi
      if [[ "$fj_rc" -ne 0 ]]; then
        local first_err=""
        if [[ -n "$fj_err" && -s "$fj_err" ]]; then
          first_err="$(head -n1 "$fj_err" 2>/dev/null || true)"
        fi
        [[ -n "$fj_err" ]] && rm -f "$fj_err"
        _forge_warn "forge_issue_list_count: fj failed for repo=$repo label=$label rc=$fj_rc err=${first_err:-<empty>}"
        return 1
      fi
      [[ -n "$fj_err" ]] && rm -f "$fj_err"

      # Official fj emits the minimal-style "N issue(s)" leading line.
      # Lowercase to tolerate case drift ("2 Issues") that broke the
      # original strict regex.
      local first_line
      first_line="$(printf '%s\n' "$fj_out" | sed -n '1p')"
      if [[ "${first_line,,}" =~ ^[[:space:]]*([0-9]+)[[:space:]]+issues?[[:space:]]*$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
      fi

      _forge_warn "forge_issue_list_count: fj output unrecognized for repo=$repo label=$label first_line='${first_line:-<empty>}'"
      return 1
      ;;
    *)
      _forge_warn "forge_issue_list_count: unknown provider '${FORGE_PROVIDER:-}' (expected gh|glab|tea|fj)"
      return 1
      ;;
  esac
}

# forge_issue_create <repo> <title> <body_file> [labels...]
#   Create a GitHub issue with the given title, body content read from
#   <body_file>, and any number of labels. Body is passed by file path so
#   newlines, backticks, and markdown survive intact (a shell-quoted body
#   string would mangle these).
#
#   Best-effort idempotency: before creating, the helper queries
#   `gh issue list --search "in:title \"$title\"" --json title,url` and
#   post-filters for an exact title match. On hit, it prints the existing
#   URL and returns 0 without creating a duplicate. On any failure of the
#   dedup search, the helper proceeds to creation. Race-free guarantees
#   between parallel invocations are explicitly out of scope.
#
#   Rate-limit retry: if `gh` exits non-zero with a stderr matching
#   "Retry-After:" or "API rate limit", the helper sleeps for the
#   advertised duration (capped at 60s, default 30s when unparseable) and
#   retries the create exactly once. A second failure returns 1 with a
#   `_forge_warn` diagnostic — no infinite loops.
#
#   gh  -> see above
#   tea -> `tea issues create --repo $repo --remote $remote --title $title
#          --body-file $body_file [--labels csv] --output json`,
#          parses `.html_url` from the JSON response.
#   fj  -> `fj -H $FORGE_HOST issue create --repo $repo --title $title
#          --body-file $body_file --no-template`. Parses the issue URL from
#          stdout (full `https?://.../issues/<n>` preferred; falls back to
#          extracting `#<n>` and synthesizing the URL from $FORGE_HOST).
#          Each label is applied post-create with one
#          `fj -H $FORGE_HOST issue edit "$repo#<n>" labels --add <label>`
#          call; label-edit failures are swallowed (best-effort) so the
#          successful create is not lost on a transient label fault.
#          Requires $FORGE_HOST.
#
#   Required args (repo, title, body_file) missing -> die loudly per the
#   caller-bug tripwire convention. Unreadable body_file -> die.
#
#   Output: created (or existing) issue URL on stdout, single line.
#           Diagnostics on stderr via _forge_warn.
#   Exit:   0 on success, 1 on creation failure.
#
#   Depends on die() from lib/core.sh and jq being available on PATH for
#   the dedup search.
forge_issue_create() {
  local repo="${1:-}" title="${2:-}" body_file="${3:-}"
  [[ -n "$repo" && -n "$title" && -n "$body_file" ]] \
    || die "forge_issue_create: missing argument (repo='$repo' title='$title' body_file='$body_file')"
  shift 3
  local -a labels=("$@")

  [[ -r "$body_file" ]] \
    || die "forge_issue_create: body_file '$body_file' not readable"

  case "${FORGE_PROVIDER:-}" in
    gh)
      local existing_url
      existing_url="$(_forge_gh_find_open_issue_by_title "$repo" "$title" 2>/dev/null || true)"
      if [[ -n "$existing_url" ]]; then
        printf '%s\n' "$existing_url"
        return 0
      fi

      local -a argv=(issue create -R "$repo" --title "$title" --body-file "$body_file")
      local lbl
      for lbl in "${labels[@]}"; do
        [[ -n "$lbl" ]] || continue
        argv+=(--label "$lbl")
      done

      _forge_gh_with_rate_limit_retry "forge_issue_create" "$repo" "${argv[@]}"
      return $?
      ;;
    glab)
      local existing_url
      existing_url="$(_forge_glab_find_open_issue_by_title "$repo" "$title" 2>/dev/null || true)"
      if [[ -n "$existing_url" ]]; then
        printf '%s\n' "$existing_url"
        return 0
      fi

      local _glab_host=""
      if [[ -n "${FORGE_HOST:-}" ]]; then
        _glab_host="${FORGE_HOST}"
        if [[ "$_glab_host" =~ ^https?://([^/:]+) ]]; then _glab_host="${BASH_REMATCH[1]}"; fi
        [[ "$_glab_host" == "gitlab.com" ]] && _glab_host=""
      fi

      local description
      description="$(cat "$body_file")"

      local -a argv=(issue create -R "$repo" \
        --title "$title" --description "$description")
      local lbl
      for lbl in "${labels[@]}"; do
        [[ -n "$lbl" ]] || continue
        argv+=(--label "$lbl")
      done

      _forge_glab_with_rate_limit_retry "forge_issue_create" "$repo" "$_glab_host" "${argv[@]}"
      return $?
      ;;
    tea)
      local -a tea_target_flags=()
      if [[ -n "${FORGE_PROJECT_PATH:-}" ]]; then
        tea_target_flags=(--repo "$FORGE_PROJECT_PATH" --remote "${FORGE_REMOTE_NAME:-origin}")
      elif [[ -n "${FORGE_TEA_LOGIN:-}" ]]; then
        tea_target_flags=(--repo "$repo" --login "$FORGE_TEA_LOGIN")
      else
        die "forge_issue_create: tea backend requires FORGE_PROJECT_PATH or FORGE_TEA_LOGIN for target binding"
      fi

      local -a tea_label_flags=()
      if (( ${#labels[@]} > 0 )); then
        local labels_csv="" lbl
        for lbl in "${labels[@]}"; do
          [[ -n "$lbl" ]] || continue
          if [[ -z "$labels_csv" ]]; then
            labels_csv="$lbl"
          else
            labels_csv="$labels_csv,$lbl"
          fi
        done
        if [[ -n "$labels_csv" ]]; then
          tea_label_flags=(--labels "$labels_csv")
        fi
      fi

      local tea_err tea_out tea_rc
      tea_err="$(mktemp 2>/dev/null)" || tea_err=""
      if [[ -n "$tea_err" ]]; then
        tea_out="$(tea issues create "${tea_target_flags[@]}" \
          --title "$title" --body-file "$body_file" \
          "${tea_label_flags[@]}" --output json 2>"$tea_err")"
        tea_rc=$?
      else
        tea_out="$(tea issues create "${tea_target_flags[@]}" \
          --title "$title" --body-file "$body_file" \
          "${tea_label_flags[@]}" --output json 2>/dev/null)"
        tea_rc=$?
      fi
      if [[ "$tea_rc" -ne 0 ]]; then
        local first_err=""
        if [[ -n "$tea_err" && -s "$tea_err" ]]; then
          first_err="$(head -n1 "$tea_err" 2>/dev/null || true)"
        fi
        [[ -n "$tea_err" ]] && rm -f "$tea_err"
        _forge_warn "forge_issue_create: tea failed for repo=$repo rc=$tea_rc err=${first_err:-<empty>}"
        return 1
      fi
      [[ -n "$tea_err" ]] && rm -f "$tea_err"

      local html_url=""
      if command -v jq >/dev/null 2>&1; then
        html_url="$(printf '%s' "$tea_out" | jq -r '.html_url // empty' 2>/dev/null || true)"
      fi
      if [[ -z "$html_url" ]]; then
        _forge_warn "forge_issue_create: tea response missing html_url for repo=$repo"
        return 1
      fi
      printf '%s\n' "$html_url"
      return 0
      ;;
    fj)
      [[ -n "${FORGE_HOST:-}" ]] \
        || die "forge_issue_create: fj backend requires FORGE_HOST"

      local fj_err fj_out fj_rc
      fj_err="$(mktemp 2>/dev/null)" || fj_err=""
      if [[ -n "$fj_err" ]]; then
        fj_out="$(fj -H "$FORGE_HOST" issue create --repo "$repo" \
          --title "$title" --body-file "$body_file" --no-template 2>"$fj_err")"
        fj_rc=$?
      else
        fj_out="$(fj -H "$FORGE_HOST" issue create --repo "$repo" \
          --title "$title" --body-file "$body_file" --no-template 2>/dev/null)"
        fj_rc=$?
      fi
      if [[ "$fj_rc" -ne 0 ]]; then
        local first_err=""
        if [[ -n "$fj_err" && -s "$fj_err" ]]; then
          first_err="$(head -n1 "$fj_err" 2>/dev/null || true)"
        fi
        [[ -n "$fj_err" ]] && rm -f "$fj_err"
        _forge_warn "forge_issue_create: fj failed for repo=$repo rc=$fj_rc err=${first_err:-<empty>}"
        return 1
      fi
      [[ -n "$fj_err" ]] && rm -f "$fj_err"

      local html_url="" issue_n=""
      if [[ "$fj_out" =~ (https?://[^[:space:]]+/issues/([0-9]+)) ]]; then
        html_url="${BASH_REMATCH[1]}"
        issue_n="${BASH_REMATCH[2]}"
      elif [[ "$fj_out" =~ \#([0-9]+) ]]; then
        issue_n="${BASH_REMATCH[1]}"
        local host_url="$FORGE_HOST"
        if [[ "$host_url" != http://* && "$host_url" != https://* ]]; then
          host_url="https://$host_url"
        fi
        html_url="${host_url}/${repo}/issues/${issue_n}"
      fi

      if [[ -z "$html_url" || -z "$issue_n" ]]; then
        _forge_warn "forge_issue_create: fj succeeded but URL parse failed for repo=$repo (stdout='${fj_out:0:200}')"
        return 1
      fi

      local lbl
      for lbl in "${labels[@]}"; do
        [[ -n "$lbl" ]] || continue
        fj -H "$FORGE_HOST" issue edit "$repo#$issue_n" labels --add "$lbl" 2>/dev/null || true
      done

      printf '%s\n' "$html_url"
      return 0
      ;;
    *)
      die "forge_issue_create: unknown provider '${FORGE_PROVIDER:-}' (expected gh|glab|tea|fj)"
      ;;
  esac
}

# forge_issue_comment <repo> <issue_number> <body_file>
#   Post a comment on an existing issue. Body is passed by file path so
#   markdown formatting survives intact. Rate-limit retry policy mirrors
#   forge_issue_create (single retry on Retry-After / API rate limit).
#
#   gh  -> `gh issue comment <issue_number> -R <repo> --body-file <body_file>`
#   tea -> `tea issues comment <issue_number> --body-file <body_file>
#          --repo $FORGE_PROJECT_PATH --remote $FORGE_REMOTE_NAME`
#          (or --login $FORGE_TEA_LOGIN fallback).
#   fj  -> `fj -H $FORGE_HOST issue comment <repo> <issue_number>
#          --body-file <body_file>`. On success, echoes any fj stdout
#          first line (matches the tea-arm passthrough). Requires
#          $FORGE_HOST.
#
#   Output: comment URL on stdout (gh prints it natively).
#   Exit:   0 on success, 1 on failure.
forge_issue_comment() {
  local repo="${1:-}" issue_number="${2:-}" body_file="${3:-}"
  [[ -n "$repo" && -n "$issue_number" && -n "$body_file" ]] \
    || die "forge_issue_comment: missing argument (repo='$repo' issue_number='$issue_number' body_file='$body_file')"

  [[ -r "$body_file" ]] \
    || die "forge_issue_comment: body_file '$body_file' not readable"

  case "${FORGE_PROVIDER:-}" in
    gh)
      _forge_gh_with_rate_limit_retry "forge_issue_comment" "$repo" \
        issue comment "$issue_number" -R "$repo" --body-file "$body_file"
      return $?
      ;;
    glab)
      local _glab_host=""
      if [[ -n "${FORGE_HOST:-}" ]]; then
        _glab_host="${FORGE_HOST}"
        if [[ "$_glab_host" =~ ^https?://([^/:]+) ]]; then _glab_host="${BASH_REMATCH[1]}"; fi
        [[ "$_glab_host" == "gitlab.com" ]] && _glab_host=""
      fi

      local message
      message="$(cat "$body_file")"

      _forge_glab_with_rate_limit_retry "forge_issue_comment" "$repo" "$_glab_host" \
        issue note "$issue_number" -R "$repo" --message "$message"
      return $?
      ;;
    tea)
      local -a tea_target_flags=()
      if [[ -n "${FORGE_PROJECT_PATH:-}" ]]; then
        tea_target_flags=(--repo "$FORGE_PROJECT_PATH" --remote "${FORGE_REMOTE_NAME:-origin}")
      elif [[ -n "${FORGE_TEA_LOGIN:-}" ]]; then
        tea_target_flags=(--repo "$repo" --login "$FORGE_TEA_LOGIN")
      else
        die "forge_issue_comment: tea backend requires FORGE_PROJECT_PATH or FORGE_TEA_LOGIN for target binding"
      fi

      local tea_err tea_out tea_rc
      tea_err="$(mktemp 2>/dev/null)" || tea_err=""
      if [[ -n "$tea_err" ]]; then
        tea_out="$(tea issues comment "$issue_number" \
          --body-file "$body_file" "${tea_target_flags[@]}" 2>"$tea_err")"
        tea_rc=$?
      else
        tea_out="$(tea issues comment "$issue_number" \
          --body-file "$body_file" "${tea_target_flags[@]}" 2>/dev/null)"
        tea_rc=$?
      fi
      if [[ "$tea_rc" -ne 0 ]]; then
        local first_err=""
        if [[ -n "$tea_err" && -s "$tea_err" ]]; then
          first_err="$(head -n1 "$tea_err" 2>/dev/null || true)"
        fi
        [[ -n "$tea_err" ]] && rm -f "$tea_err"
        _forge_warn "forge_issue_comment: tea failed for repo=$repo issue=$issue_number rc=$tea_rc err=${first_err:-<empty>}"
        return 1
      fi
      [[ -n "$tea_err" ]] && rm -f "$tea_err"

      if [[ -n "$tea_out" ]]; then
        printf '%s\n' "$tea_out" | head -n1
      fi
      return 0
      ;;
    fj)
      [[ -n "${FORGE_HOST:-}" ]] \
        || die "forge_issue_comment: fj backend requires FORGE_HOST"

      local fj_err fj_out fj_rc
      fj_err="$(mktemp 2>/dev/null)" || fj_err=""
      if [[ -n "$fj_err" ]]; then
        fj_out="$(fj -H "$FORGE_HOST" issue comment "$repo" "$issue_number" \
          --body-file "$body_file" 2>"$fj_err")"
        fj_rc=$?
      else
        fj_out="$(fj -H "$FORGE_HOST" issue comment "$repo" "$issue_number" \
          --body-file "$body_file" 2>/dev/null)"
        fj_rc=$?
      fi
      if [[ "$fj_rc" -ne 0 ]]; then
        local first_err=""
        if [[ -n "$fj_err" && -s "$fj_err" ]]; then
          first_err="$(head -n1 "$fj_err" 2>/dev/null || true)"
        fi
        [[ -n "$fj_err" ]] && rm -f "$fj_err"
        _forge_warn "forge_issue_comment: fj failed for repo=$repo issue=$issue_number rc=$fj_rc err=${first_err:-<empty>}"
        return 1
      fi
      [[ -n "$fj_err" ]] && rm -f "$fj_err"

      if [[ -n "$fj_out" ]]; then
        printf '%s\n' "$fj_out" | head -n1
      fi
      return 0
      ;;
    *)
      die "forge_issue_comment: unknown provider '${FORGE_PROVIDER:-}' (expected gh|glab|tea|fj)"
      ;;
  esac
}

# Internal: best-effort exact-title lookup for GitLab open issues.
# Prints web_url on hit, empty on miss or any failure. Always returns 0.
_forge_glab_find_open_issue_by_title() {
  local repo="$1" title="$2"
  command -v jq >/dev/null 2>&1 || return 0

  local _glab_host=""
  if [[ -n "${FORGE_HOST:-}" ]]; then
    _glab_host="${FORGE_HOST}"
    if [[ "$_glab_host" =~ ^https?://([^/:]+) ]]; then _glab_host="${BASH_REMATCH[1]}"; fi
    [[ "$_glab_host" == "gitlab.com" ]] && _glab_host=""
  fi

  local search_out
  search_out="$(GITLAB_HOST="$_glab_host" glab issue list -R "$repo" --state opened \
    --search "$title" --output json --per-page 50 2>/dev/null)" || return 0
  [[ -n "$search_out" ]] || return 0

  local url
  url="$(printf '%s' "$search_out" \
    | jq -r --arg t "$title" '.[] | select(.title == $t) | .web_url' 2>/dev/null \
    | head -n1)" || return 0
  [[ -n "$url" ]] || return 0
  printf '%s\n' "$url"
}

# Internal: invoke `glab <argv...>` with single retry on rate-limit failure.
# Mirrors _forge_gh_with_rate_limit_retry; see that function for full docs.
# Args: <fn_name> <repo> <gitlab_host> <glab-argv...>
#   gitlab_host: hostname to set via GITLAB_HOST env var; empty string uses glab default.
_forge_glab_with_rate_limit_retry() {
  local fn_name="$1" repo="$2" gitlab_host="${3:-}"
  shift 3

  local attempt=0
  local max_attempts=2
  local out err rc
  while (( attempt < max_attempts )); do
    attempt=$((attempt + 1))
    err="$(mktemp 2>/dev/null)" || err=""
    if [[ -n "$err" ]]; then
      out="$(GITLAB_HOST="$gitlab_host" glab "$@" 2>"$err")"
      rc=$?
    else
      out="$(GITLAB_HOST="$gitlab_host" glab "$@" 2>/dev/null)"
      rc=$?
    fi

    if [[ "$rc" -eq 0 ]]; then
      [[ -n "$err" ]] && rm -f "$err"
      printf '%s\n' "$out"
      return 0
    fi

    local err_content=""
    if [[ -n "$err" && -s "$err" ]]; then
      err_content="$(cat "$err" 2>/dev/null || true)"
    fi
    [[ -n "$err" ]] && rm -f "$err"

    if (( attempt < max_attempts )) && _forge_is_rate_limit_error "$err_content"; then
      local sleep_secs
      sleep_secs="$(_forge_rate_limit_sleep_secs "$err_content")"
      sleep "$sleep_secs"
      continue
    fi

    local first_err=""
    if [[ -n "$err_content" ]]; then
      first_err="$(printf '%s\n' "$err_content" | head -n1)"
    fi
    _forge_warn "$fn_name: glab failed for repo=$repo rc=$rc err=${first_err:-<empty>}"
    return 1
  done

  return 1
}

# Internal: best-effort exact-title lookup against open issues on $repo.
# Prints URL on hit, empty on miss or any failure. Always returns 0 so
# callers can use `result="$(_forge_gh_find_open_issue_by_title ...)"`
# without short-circuiting through `set -e` semantics.
_forge_gh_find_open_issue_by_title() {
  local repo="$1" title="$2"

  command -v jq >/dev/null 2>&1 || return 0

  local search_out
  search_out="$(gh issue list -R "$repo" --state open \
    --search "in:title \"$title\"" --json title,url --limit 50 2>/dev/null)" || return 0
  [[ -n "$search_out" ]] || return 0

  local url
  url="$(printf '%s' "$search_out" \
    | jq -r --arg t "$title" '.[] | select(.title == $t) | .url' 2>/dev/null \
    | head -n1)" || return 0
  [[ -n "$url" ]] || return 0

  printf '%s\n' "$url"
}

# Internal: invoke `gh <argv...>` with single retry on rate-limit failure.
# Prints captured stdout (typically the issue/comment URL) on success.
# On non-rate-limit failure or persistent rate-limit failure, emits a
# `_forge_warn` diagnostic and returns 1.
#
# Args: <fn_name> <repo> <gh-argv...>
#   fn_name: name of the public helper, used in warn messages.
#   repo:    repo slug, included in warn messages for context.
_forge_gh_with_rate_limit_retry() {
  local fn_name="$1" repo="$2"
  shift 2

  local attempt=0
  local max_attempts=2
  local out err rc
  while (( attempt < max_attempts )); do
    attempt=$((attempt + 1))
    err="$(mktemp 2>/dev/null)" || err=""
    if [[ -n "$err" ]]; then
      out="$(gh "$@" 2>"$err")"
      rc=$?
    else
      out="$(gh "$@" 2>/dev/null)"
      rc=$?
    fi

    if [[ "$rc" -eq 0 ]]; then
      [[ -n "$err" ]] && rm -f "$err"
      printf '%s\n' "$out"
      return 0
    fi

    local err_content=""
    if [[ -n "$err" && -s "$err" ]]; then
      err_content="$(cat "$err" 2>/dev/null || true)"
    fi
    [[ -n "$err" ]] && rm -f "$err"

    if (( attempt < max_attempts )) && _forge_is_rate_limit_error "$err_content"; then
      local sleep_secs
      sleep_secs="$(_forge_rate_limit_sleep_secs "$err_content")"
      sleep "$sleep_secs"
      continue
    fi

    local first_err=""
    if [[ -n "$err_content" ]]; then
      first_err="$(printf '%s\n' "$err_content" | head -n1)"
    fi
    _forge_warn "$fn_name: gh failed for repo=$repo rc=$rc err=${first_err:-<empty>}"
    return 1
  done

  return 1
}

# Internal: returns 0 if stderr text indicates a rate-limit failure.
_forge_is_rate_limit_error() {
  local txt="${1:-}"
  [[ -n "$txt" ]] || return 1
  if [[ "$txt" == *"Retry-After"* ]] || [[ "$txt" == *"API rate limit"* ]] \
     || [[ "$txt" == *"rate limit exceeded"* ]] || [[ "$txt" == *"secondary rate limit"* ]]; then
    return 0
  fi
  return 1
}

# Internal: extract Retry-After seconds from stderr, capped at 60.
# Falls back to 30 when no parseable number is present but the text
# carries a rate-limit marker.
_forge_rate_limit_sleep_secs() {
  local txt="${1:-}"
  local secs=""

  if [[ "$txt" =~ Retry-After[[:space:]]*:?[[:space:]]*([0-9]+) ]]; then
    secs="${BASH_REMATCH[1]}"
  elif [[ "$txt" =~ retry[[:space:]]+after[[:space:]]+([0-9]+) ]]; then
    secs="${BASH_REMATCH[1]}"
  elif [[ "$txt" =~ reset[[:space:]]+in[[:space:]]+([0-9]+) ]]; then
    secs="${BASH_REMATCH[1]}"
  fi

  if [[ -z "$secs" ]] || ! [[ "$secs" =~ ^[0-9]+$ ]]; then
    secs=30
  fi
  if (( secs > 60 )); then
    secs=60
  fi
  if (( secs < 1 )); then
    secs=1
  fi
  printf '%s' "$secs"
}

# Per-(caller, message) suppression map for _forge_warn. Persistent forge
# failures (auth revoked, wrong slug, rate-limited) repeat identically per
# lens iteration; without dedup a single root cause spawned ~10k warning
# lines per run (issue #246), drowning real findings. The re-source guard
# preserves accumulated counts when lib/forge.sh is re-sourced mid-run.
# Parallel workers each track their own map (bash arrays don't cross fork
# boundaries) — that still collapses ~1000× under typical fan-out.
declare -p _FORGE_WARN_SEEN >/dev/null 2>&1 || declare -gA _FORGE_WARN_SEEN=()

# Internal: delegates to RepoLens log_warn when logging.sh is sourced,
# otherwise falls back to stderr so wrappers remain usable in standalone tests.
# Identical (caller, message) tuples are emitted once and silently counted
# in _FORGE_WARN_SEEN; the rollup at finalize time names the suppressed total.
_forge_warn() {
  local key="${FUNCNAME[1]:-_}:$*"
  local prev="${_FORGE_WARN_SEEN[$key]:-0}"
  _FORGE_WARN_SEEN[$key]=$((prev + 1))
  if (( prev > 0 )); then
    return 0
  fi
  if declare -F log_warn >/dev/null 2>&1 && [[ -n "${_REPOLENS_LOG_FILE+x}" ]]; then
    log_warn "$*"
  else
    printf '[WARN] %s\n' "$*" >&2
  fi
}
