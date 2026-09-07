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

# Tests for lib/forge.sh — detect_forge_provider (issue #57) and
# detect_forge_host (issue #62)
#
# Behavioral contract (from the issue):
#   detect_forge_provider <remote_url>
#     prints exactly one of: gh | glab | tea | fj | unknown
#   Detection rules:
#     host == github.com         -> gh
#     host == codeberg.org       -> fj
#     host matches *gitlab*      -> glab (self-hosted, case-insensitive)
#     host matches *gitea*       -> tea  (case-insensitive)
#     anything else / malformed  -> unknown
#   URL forms supported:
#     https://[user@]host[:port]/owner/repo[.git]
#     git@host:owner/repo[.git]                        (scp-like)
#     ssh://[user@]host[:port]/owner/repo[.git]
#   Exit code is always 0 — callers parse stdout.
#
# Issue #62 adds detect_forge_host <remote_url> for fj --host binding:
#   - Codeberg remotes map to codeberg.org.
#   - SSH remotes map to the bare host.
#   - HTTPS self-hosted Forgejo remotes preserve scheme, port, and base path.
#   - Plain HTTP remotes produce no binding.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/forge.sh"

PASS=0
FAIL=0
TOTAL=0

assert_detect() {
  local desc="$1" input="$2" expected="$3"
  TOTAL=$((TOTAL + 1))
  local actual
  actual="$(detect_forge_provider "$input")"
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    Input:    $input"
    echo "    Expected: $expected"
    echo "    Actual:   $actual"
  fi
}

assert_host() {
  local desc="$1" input="$2" expected="$3"
  TOTAL=$((TOTAL + 1))
  local actual rc
  actual="$(detect_forge_host "$input" 2>/dev/null)"
  rc=$?
  if [[ "$rc" -eq 0 && "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    Input:    $input"
    echo "    Expected: $expected"
    echo "    Actual:   $actual"
    echo "    rc:       $rc"
  fi
}

echo ""
echo "=== Test Suite: detect_forge_provider (issue #57) ==="
echo ""

# --- GitHub: 3 URL forms ---
echo "GitHub host (github.com) → gh"
assert_detect "github.com HTTPS"          "https://github.com/owner/repo.git"        "gh"
assert_detect "github.com SSH scp-like"   "git@github.com:owner/repo.git"            "gh"
assert_detect "github.com SSH URL form"   "ssh://git@github.com/owner/repo.git"      "gh"

echo ""
# --- Codeberg / Forgejo: 3 URL forms ---
echo "Codeberg host (codeberg.org) → fj"
assert_detect "codeberg.org HTTPS"        "https://codeberg.org/owner/repo.git"      "fj"
assert_detect "codeberg.org SSH scp-like" "git@codeberg.org:owner/repo.git"          "fj"
assert_detect "codeberg.org SSH URL form" "ssh://git@codeberg.org/owner/repo.git"    "fj"

echo ""
echo "Forgejo host binding for fj --host"
assert_host "Codeberg HTTPS maps to bare host" \
  "https://codeberg.org/owner/repo.git" "codeberg.org"
assert_host "Codeberg HTTPS maps uppercase host to bare lowercase host" \
  "https://Codeberg.Org/owner/repo.git" "codeberg.org"
assert_host "Codeberg SSH scp-like maps to bare host" \
  "git@codeberg.org:owner/repo.git" "codeberg.org"
assert_host "Codeberg SSH URL form maps to bare host" \
  "ssh://git@codeberg.org/owner/repo.git" "codeberg.org"
assert_host "self-hosted HTTPS port is preserved" \
  "https://forge.example.com:3000/owner/repo.git" "https://forge.example.com:3000"
assert_host "self-hosted HTTPS base path is preserved" \
  "https://forge.example.com/git/owner/repo.git" "https://forge.example.com/git"
assert_host "self-hosted HTTP base path has no fj host binding" \
  "http://forge.example.com/git/owner/repo.git" ""
assert_host "Codeberg HTTP has no fj host binding" \
  "http://codeberg.org/owner/repo.git" ""
assert_host "Codeberg git protocol has no fj host binding" \
  "git://codeberg.org/owner/repo.git" ""
assert_host "self-hosted HTTPS nested base path is preserved" \
  "https://forge.example.com/base/git/owner/repo.git" "https://forge.example.com/base/git"
assert_host "self-hosted HTTPS userinfo is stripped while port and base path stay" \
  "https://alice@Forge.Example.com:3000/git/owner/repo.git" "https://forge.example.com:3000/git"
assert_host "self-hosted HTTPS query string is ignored when deriving base path" \
  "https://forge.example.com/git/owner/repo.git?tab=files" "https://forge.example.com/git"
assert_host "self-hosted SSH URL with port maps to bare API host" \
  "ssh://git@forge.example.com:2222/owner/repo.git" "forge.example.com"
assert_host "empty remote has no fj host binding" "" ""
assert_host "malformed remote has no fj host binding" "not-a-url" ""

TOTAL=$((TOTAL + 1))
if actual="$(detect_forge_host 2>/dev/null)"; then
  if [[ -z "$actual" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: no-argument host call returns empty binding"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: no-argument host call returned '$actual', expected empty binding"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: no-argument host call exited non-zero (must always exit 0)"
fi

echo ""
# --- GitLab: gitlab.com exact match + *gitlab* self-hosted substring ---
echo "GitLab host (gitlab.com) → glab"
assert_detect "gitlab.com HTTPS"          "https://gitlab.com/owner/repo.git"        "glab"
assert_detect "gitlab.com SSH scp-like"   "git@gitlab.com:owner/repo.git"            "glab"
assert_detect "gitlab.com SSH URL form"   "ssh://git@gitlab.com/owner/repo.git"      "glab"

echo ""
echo "Self-hosted GitLab (*gitlab* substring) → glab"
assert_detect "gitlab subdomain HTTPS"    "https://gitlab.example.com/owner/repo.git" "glab"
assert_detect "gitlab SSH scp-like"       "git@gitlab.mycompany.io:owner/repo.git"    "glab"
assert_detect "gitlab SSH URL form"       "ssh://git@my.gitlab.net/owner/repo.git"    "glab"

echo ""
# --- Gitea: 3 URL forms (substring match) ---
echo "Gitea host (*gitea* substring) → tea"
assert_detect "gitea subdomain HTTPS"     "https://gitea.example.com/owner/repo.git" "tea"
assert_detect "gitea SSH scp-like"        "git@try.gitea.io:owner/repo.git"          "tea"
assert_detect "gitea SSH URL form"        "ssh://git@gitea.io/owner/repo.git"        "tea"

echo ""
# --- Unknown / unsupported hosts ---
echo "Unsupported / unknown hosts → unknown"
assert_detect "example.com HTTPS"         "https://example.com/owner/repo.git"       "unknown"
assert_detect "bitbucket.com SSH scp-like" "git@bitbucket.com:owner/repo.git"        "unknown"
assert_detect "bitbucket.org SSH URL"     "ssh://git@bitbucket.org/owner/repo.git"   "unknown"

echo ""
# --- Robustness: malformed / empty input must not fail, must return "unknown" ---
echo "Robustness — malformed/empty input → unknown (must never error)"
assert_detect "empty string"              ""                                         "unknown"
assert_detect "garbage non-URL"           "not-a-url"                                "unknown"
# No-argument invocation — guards against ${1:-} regression. Function must still
# print "unknown" and exit 0 rather than crashing on unbound variable.
TOTAL=$((TOTAL + 1))
if actual="$(detect_forge_provider 2>/dev/null)"; then
  if [[ "$actual" == "unknown" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: no-argument call returns 'unknown'"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: no-argument call returned '$actual', expected 'unknown'"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: no-argument call exited non-zero (must always exit 0)"
fi

echo ""
# --- Case-insensitivity (RFC 3986 §3.2.2 — hosts are case-insensitive) ---
echo "Case-insensitivity"
assert_detect "GitHub.com mixed case"     "https://GitHub.com/owner/repo.git"        "gh"
assert_detect "GITLAB.COM upper case"     "https://GITLAB.COM/owner/repo.git"        "glab"
assert_detect "CODEBERG.ORG upper case"   "https://CODEBERG.ORG/owner/repo.git"      "fj"
assert_detect "GITEA.example.com upper"   "https://GITEA.example.com/owner/repo.git" "tea"
assert_detect "GITLAB.example.com upper"  "https://GITLAB.example.com/owner/repo.git" "glab"

echo ""
# --- HTTPS authority variations (port, userinfo) ---
echo "HTTPS authority variations (userinfo / port stripped)"
assert_detect "userinfo prefix in HTTPS"  "https://user@github.com/owner/repo.git"   "gh"
assert_detect "explicit port stripped"    "https://github.com:443/owner/repo.git"    "gh"
# Combined userinfo + port on one input — exercises both ${authority#*@} and
# ${authority%%:*} parameter expansions in sequence. Individually covered
# above, but the combined form guards against a regression that breaks only
# when both strippings are required.
assert_detect "userinfo + port together" "https://user@github.com:443/owner/repo.git" "gh"

echo ""
# --- URL form edge cases (regex branches not covered by the core matrix) ---
echo "URL form edge cases"
# Bare host with no path — exercises the `$` alternative in the regex
# `([^/]+)(/|$)`. The core matrix only covers the `/` alternative.
assert_detect "bare host, no path"        "https://github.com"                       "gh"
# `git://` scheme — the implementation's contract comment in lib/forge.sh
# explicitly lists `git://` as a handled scheme even though the issue's URL
# form list only names https/scp-like/ssh. Guards the documented behavior.
assert_detect "git:// scheme"             "git://github.com/owner/repo.git"          "gh"

echo ""
# --- Issue #245: substring overreach — *gitea* glob matches "gitea" anywhere
# in the host. The tightened pattern requires "gitea" to be a full DNS label
# (delimited by dots or anchored at the start of the host), so a hyphenated
# or mid-label occurrence must NOT classify as tea.
echo "Issue #245 — substring overreach (gitea mid-label) → unknown"
assert_detect "my-gitea-instance.io (gitea is mid-label, hyphen separators)" \
  "https://my-gitea-instance.io/owner/repo.git" "unknown"
assert_detect "notgitea.example.com (gitea is a suffix of a longer label)" \
  "https://notgitea.example.com/owner/repo.git" "unknown"
assert_detect "gitea-mirror.com (gitea-mirror, hyphen not dot)" \
  "https://gitea-mirror.com/owner/repo.git" "unknown"
assert_detect "scp-like my-gitea-instance.io (gitea mid-label, SSH form)" \
  "git@my-gitea-instance.io:owner/repo.git" "unknown"

echo ""
# --- Issue #245: tightened pattern keeps canonical Gitea hosts working ---
echo "Issue #245 — canonical Gitea hosts still match → tea"
assert_detect "gitea.com (gitea as leading label)" \
  "https://gitea.com/owner/repo.git" "tea"
assert_detect "something.gitea.example.com (gitea as middle label)" \
  "https://something.gitea.example.com/owner/repo.git" "tea"

echo ""
# --- Issue #245: provider/host consistency on plain HTTP origins ---
# detect_forge_host rejects HTTP at lib/forge.sh:86-89 (returns ""), but
# detect_forge_provider used to trust the host substring and return a
# concrete provider. That asymmetry let a 'tea' run silently proceed with
# FORGE_HOST="". Provider must downgrade to 'unknown' on plain HTTP for
# every provider so the two functions agree.
echo "Issue #245 — plain HTTP origins downgrade provider → unknown"
assert_detect "HTTP github.com (insecure scheme, must downgrade)" \
  "http://github.com/owner/repo.git" "unknown"
assert_detect "HTTP codeberg.org (insecure scheme, must downgrade)" \
  "http://codeberg.org/owner/repo.git" "unknown"
assert_detect "HTTP gitea subdomain (insecure scheme, must downgrade)" \
  "http://gitea.example.com/owner/repo.git" "unknown"
assert_detect "HTTP self-hosted Gitea with port (insecure scheme)" \
  "http://my.gitea.example.com:3000/owner/repo.git" "unknown"

echo ""
# --- Issue #245: HTTP scheme guard is case-insensitive ---
# The implementation uses the regex ^[Hh][Tt][Tt][Pp]:// so uppercase or
# mixed-case schemes downgrade too. Without explicit coverage, a future
# refactor to a lowercase-only check (e.g. ^http://) would regress silently
# because callers typically lowercase the scheme before calling — but the
# function itself takes the raw URL, so the scheme guard must handle case.
echo "Issue #245 — HTTP scheme guard is case-insensitive → unknown"
assert_detect "HTTP://github.com (uppercase scheme)" \
  "HTTP://github.com/owner/repo.git" "unknown"
assert_detect "Http://gitea.example.com (mixed-case scheme)" \
  "Http://gitea.example.com/owner/repo.git" "unknown"
assert_detect "hTtP://codeberg.org (alternating-case scheme)" \
  "hTtP://codeberg.org/owner/repo.git" "unknown"

echo ""
# --- Issue #245: mixed-case HTTPS must NOT be swallowed by the HTTP guard ---
# Tightness check on the [Hh][Tt][Tt][Pp]:// regex — the trailing `://` means
# `HTTPS://` (extra `S` before the colon) must not match. If a future change
# replaces the regex with a looser prefix match (e.g. ^http), HTTPS URLs would
# wrongly downgrade. Lock the boundary in explicitly.
echo "Issue #245 — mixed-case HTTPS is NOT downgraded (regex boundary check)"
assert_detect "HTTPS://github.com (uppercase HTTPS still detects gh)" \
  "HTTPS://github.com/owner/repo.git" "gh"
assert_detect "Https://gitea.com (mixed-case HTTPS still detects tea)" \
  "Https://gitea.com/owner/repo.git" "tea"

echo ""
# --- Issue #245: ssh:// URL form of gitea substring overreach ---
# Symmetric with the scp-like coverage above (git@my-gitea-instance.io:...).
# Both URL forms feed the same case-statement, but a future refactor could
# diverge the paths — keep both forms asserted so neither regresses alone.
echo "Issue #245 — ssh:// URL form of gitea substring overreach → unknown"
assert_detect "ssh://my-gitea-instance.io (gitea mid-label, ssh URL form)" \
  "ssh://git@my-gitea-instance.io/owner/repo.git" "unknown"

echo ""
# --- Issue #245: HTTP downgrade must NOT regress non-HTTP schemes ---
echo "Issue #245 — non-HTTP schemes still detect (regression guards)"
assert_detect "git://github.com still detects gh" \
  "git://github.com/owner/repo.git" "gh"
assert_detect "ssh://git@github.com still detects gh" \
  "ssh://git@github.com/owner/repo.git" "gh"
assert_detect "https://github.com still detects gh" \
  "https://github.com/owner/repo.git" "gh"
assert_detect "https://codeberg.org still detects fj" \
  "https://codeberg.org/owner/repo.git" "fj"
assert_detect "https://gitea.com still detects tea" \
  "https://gitea.com/owner/repo.git" "tea"
assert_detect "scp-like git@gitea.example.com still detects tea" \
  "git@gitea.example.com:owner/repo.git" "tea"

echo ""
# --- Issue #245: provider/host agreement is the actual contract ---
# Lock in the invariant that the two functions agree on every URL the test
# suite exercises: if provider is non-'unknown', host must be non-empty;
# if host is empty, provider must be 'unknown'. (Exception: bare 'gh' over
# git:// or scp-like SSH today returns provider=gh but host="" because
# detect_forge_host's regex only handles scheme://… — that pre-existing
# divergence is out of scope for this issue and is NOT asserted here.)
echo "Issue #245 — provider/host agreement on HTTPS and plain HTTP"
TOTAL=$((TOTAL + 1))
provider="$(detect_forge_provider 'http://gitea.example.com/owner/repo.git')"
host="$(detect_forge_host    'http://gitea.example.com/owner/repo.git')"
if [[ "$provider" == "unknown" && -z "$host" ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: HTTP gitea — provider='unknown' AND host='' (consistent)"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: HTTP gitea — provider='$provider' host='$host' (must both be empty/unknown)"
fi

TOTAL=$((TOTAL + 1))
provider="$(detect_forge_provider 'https://gitea.example.com/owner/repo.git')"
host="$(detect_forge_host    'https://gitea.example.com/owner/repo.git')"
if [[ "$provider" == "tea" && -n "$host" ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: HTTPS gitea — provider='tea' AND host non-empty (consistent)"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: HTTPS gitea — provider='$provider' host='$host' (provider must be tea AND host non-empty)"
fi

echo ""
# --- Output contract: exactly one token, no trailing whitespace beyond newline ---
echo "Output contract — exactly one of {gh, tea, fj, unknown}"
TOTAL=$((TOTAL + 1))
out="$(detect_forge_provider "https://github.com/owner/repo.git")"
if [[ "$out" == "gh" ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: stdout is exactly 'gh' (no whitespace, no extras)"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: stdout was '$out' (expected exactly 'gh')"
fi

# Exit code is always 0 — callers compose with $(...) and check stdout.
TOTAL=$((TOTAL + 1))
detect_forge_provider "https://example.com/x.git" >/dev/null
rc=$?
if (( rc == 0 )); then
  PASS=$((PASS + 1))
  echo "  PASS: exit code is 0 even when result is 'unknown'"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: exit code was $rc for 'unknown' result (expected 0)"
fi

echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
