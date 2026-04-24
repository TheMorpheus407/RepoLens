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

# Tests for lib/forge.sh — detect_forge_provider (issue #57)
#
# Behavioral contract (from the issue):
#   detect_forge_provider <remote_url>
#     prints exactly one of: gh | tea | fj | unknown
#   Detection rules:
#     host == github.com         -> gh
#     host == codeberg.org       -> fj
#     host matches *gitea*       -> tea  (case-insensitive)
#     anything else / malformed  -> unknown
#   URL forms supported:
#     https://[user@]host[:port]/owner/repo[.git]
#     git@host:owner/repo[.git]                        (scp-like)
#     ssh://[user@]host[:port]/owner/repo[.git]
#   Exit code is always 0 — callers parse stdout.
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
# --- Gitea: 3 URL forms (substring match) ---
echo "Gitea host (*gitea* substring) → tea"
assert_detect "gitea subdomain HTTPS"     "https://gitea.example.com/owner/repo.git" "tea"
assert_detect "gitea SSH scp-like"        "git@try.gitea.io:owner/repo.git"          "tea"
assert_detect "gitea SSH URL form"        "ssh://git@gitea.io/owner/repo.git"        "tea"

echo ""
# --- Unknown / unsupported hosts ---
echo "Unsupported / unknown hosts → unknown"
assert_detect "example.com HTTPS"         "https://example.com/owner/repo.git"       "unknown"
assert_detect "gitlab.com SSH scp-like"   "git@gitlab.com:owner/repo.git"            "unknown"
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
assert_detect "CODEBERG.ORG upper case"   "https://CODEBERG.ORG/owner/repo.git"      "fj"
assert_detect "GITEA.example.com upper"   "https://GITEA.example.com/owner/repo.git" "tea"

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
