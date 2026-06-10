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

# Tests for issue #228: domain-level `keywords` metadata + opt-in
# `--scope-by-keywords` / `REPOLENS_SCOPE_BY_KEYWORDS=1`. When enabled,
# the dispatcher substring-matches the bug-report text (case-insensitive)
# against each domain's keyword list:
#   - match >= 1 keyword  → keep the domain
#   - match 0 keywords    → drop the domain
#   - keywords missing/empty → always keep (conservative back-compat)
#   - feature disabled    → behaviour identical to today

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOLENS_SH="$SCRIPT_DIR/repolens.sh"
DOMAINS_FILE="$SCRIPT_DIR/config/domains.json"

PASS=0
FAIL=0
TOTAL=0

TMP_PARENT="$SCRIPT_DIR/logs/test-scope-by-keywords"
mkdir -p "$TMP_PARENT"
TMPDIR="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"
CREATED_RUN_IDS=()

cleanup() {
  local run_id
  rm -rf "$TMPDIR"
  for run_id in "${CREATED_RUN_IDS[@]:-}"; do
    [[ -n "$run_id" ]] && rm -rf "$SCRIPT_DIR/logs/$run_id"
  done
  rmdir "$TMP_PARENT" 2>/dev/null || true
}
trap cleanup EXIT

pass_with() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail_with() {
  local desc="$1" detail="${2:-}"
  FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
  [[ -n "$detail" ]] && printf '    %s\n' "$detail"
}
assert_success() {
  local desc="$1" actual="$2"; TOTAL=$((TOTAL + 1))
  if [[ "$actual" -eq 0 ]]; then pass_with "$desc"
  else fail_with "$desc" "Expected exit 0, got $actual"; fi
}
assert_contains() {
  local desc="$1" needle="$2" haystack="$3"; TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then pass_with "$desc"
  else fail_with "$desc" "Expected to find '$needle'"; fi
}
assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"; TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then pass_with "$desc"
  else fail_with "$desc" "Did NOT expect to find '$needle'"; fi
}

make_project() {
  local project="$1"
  mkdir -p "$project"
  git -C "$project" init -q
  printf '# kw test\n' > "$project/README.md"
  git -C "$project" -c user.email=t@t -c user.name=t add README.md >/dev/null 2>&1 || true
  git -C "$project" -c user.email=t@t -c user.name=t commit -q -m init >/dev/null 2>&1 || true
}

register_run_id_from() {
  local out_file="$1" run_id
  run_id="$(grep -oE 'RepoLens run [^ ]+ starting' "$out_file" 2>/dev/null | head -1 | awk '{print $3}')"
  [[ -n "$run_id" ]] && CREATED_RUN_IDS+=("$run_id")
}

run_dry() {
  local out_file="$1" name="$2"
  shift 2
  local project="$TMPDIR/project-$name"
  make_project "$project"
  bash "$REPOLENS_SH" \
    --project "$project" \
    --agent claude \
    --dry-run \
    --yes \
    --local \
    --output "$TMPDIR/issues-$name" \
    "$@" \
    >"$out_file" 2>&1
  local rc=$?
  register_run_id_from "$out_file"
  return "$rc"
}

run_dry_env() {
  local out_file="$1" name="$2" env_var="$3"
  shift 3
  local project="$TMPDIR/project-$name"
  make_project "$project"
  # shellcheck disable=SC2086
  env $env_var bash "$REPOLENS_SH" \
    --project "$project" \
    --agent claude \
    --dry-run \
    --yes \
    --local \
    --output "$TMPDIR/issues-$name" \
    "$@" \
    >"$out_file" 2>&1
  local rc=$?
  register_run_id_from "$out_file"
  return "$rc"
}

extract_lens_entries() {
  local out_file="$1"
  awk '
    /^Lenses that would run:/ { in_list = 1; next }
    in_list && /^[[:space:]]*$/ { in_list = 0; next }
    in_list { gsub(/^[[:space:]]+/, "", $0); print }
  ' "$out_file"
}

extract_lens_domains() {
  local out_file="$1"
  extract_lens_entries "$out_file" | awk -F/ '{print $1}' | sort -u
}

# Choose a default-mode domain that the issue's initial keyword manifest
# explicitly leaves WITHOUT keywords. The issue ships keywords for exactly
# five domains (security, concurrency, error-handling, performance,
# database). `code-quality` is a default-mode domain outside that set, so
# it exercises the "missing/empty keywords → always keep" back-compat path.
BACKCOMPAT_DOMAIN="code-quality"

echo ""
echo "=== Test Suite: --scope-by-keywords (#228) ==="
echo ""

DB_BUG_FILE="$TMPDIR/db-bug.txt"
printf 'Symptom: sqflite NOTNULL constraint failed when inserting row.\n' > "$DB_BUG_FILE"

echo "Test 1: bug report matching database keywords keeps database, drops security"
out="$TMPDIR/out-db.txt"
run_dry "$out" "db" --mode bugreport --bug-report "$DB_BUG_FILE" --scope-by-keywords
rc=$?
assert_success "--scope-by-keywords exits 0 on database-ish bug" "$rc"
domains="$(extract_lens_domains "$out")"
assert_contains "database domain kept (sqflite matched)" "database" "$domains"
assert_not_contains "security domain dropped (no auth/login/token keywords in bug)" \
  "security" "$domains"

echo ""
echo "Test 2: domain without keywords field is always present (back-compat)"
# code-quality has no `keywords` in the initial PR scope. The bug-report
# above contains nothing matching the security/concurrency/etc. keyword
# lists, so the only reason code-quality should survive is the missing-
# keywords short-circuit.
assert_contains "code-quality kept (no keywords field → always include)" \
  "$BACKCOMPAT_DOMAIN" "$domains"

echo ""
echo "Test 3: bug report matching security keywords keeps security, drops database"
SEC_BUG_FILE="$TMPDIR/sec-bug.txt"
printf 'Symptom: user session token leak via auth login redirect.\n' > "$SEC_BUG_FILE"
out="$TMPDIR/out-sec.txt"
run_dry "$out" "sec" --mode bugreport --bug-report "$SEC_BUG_FILE" --scope-by-keywords
rc=$?
assert_success "--scope-by-keywords exits 0 on security-ish bug" "$rc"
domains="$(extract_lens_domains "$out")"
assert_contains "security domain kept (auth/login/session/token matched)" \
  "security" "$domains"
assert_not_contains "database domain dropped (no sql/sqlite/sqflite/etc. matched)" \
  "database" "$domains"

echo ""
echo "Test 4: case-insensitive matching"
# Spec: "case-insensitive substring." `SQFLITE` (uppercase) must match the
# lowercase `sqflite` keyword.
CI_BUG_FILE="$TMPDIR/ci-bug.txt"
printf 'CRASH REPORT: SQFLITE failure on production build.\n' > "$CI_BUG_FILE"
out="$TMPDIR/out-ci.txt"
run_dry "$out" "ci" --mode bugreport --bug-report "$CI_BUG_FILE" --scope-by-keywords
rc=$?
assert_success "case-insensitive run exits 0" "$rc"
domains="$(extract_lens_domains "$out")"
assert_contains "database matched on UPPERCASE SQFLITE" "database" "$domains"

echo ""
echo "Test 5: REPOLENS_SCOPE_BY_KEYWORDS=1 env-var fallback works"
out="$TMPDIR/out-env.txt"
run_dry_env "$out" "env" "REPOLENS_SCOPE_BY_KEYWORDS=1" \
  --mode bugreport --bug-report "$DB_BUG_FILE"
rc=$?
assert_success "env-var path exits 0" "$rc"
domains="$(extract_lens_domains "$out")"
assert_contains "env-var: database kept" "database" "$domains"
assert_not_contains "env-var: security dropped" "security" "$domains"

echo ""
echo "Test 6: --relevant-domains + --scope-by-keywords compose with AND semantics"
# Both filters intersect: CSV narrows to {concurrency, database, security};
# the sqflite bug only matches database keywords, so database is the only
# survivor among the CSV-restricted set. Concurrency keywords (race, lock,
# mutex, ...) and security keywords (auth, login, token, ...) do not match
# the bug text. Compose result: just database/*.
out="$TMPDIR/out-compose.txt"
run_dry "$out" "compose" --mode bugreport --bug-report "$DB_BUG_FILE" \
  --relevant-domains concurrency,database,security \
  --scope-by-keywords
rc=$?
assert_success "compose CSV+keywords exits 0" "$rc"
domains="$(extract_lens_domains "$out")"
assert_contains "compose: database kept (CSV ∧ keyword match)" "database" "$domains"
assert_not_contains "compose: concurrency dropped (in CSV but no keyword match)" \
  "concurrency" "$domains"
assert_not_contains "compose: security dropped (in CSV but no keyword match)" \
  "security" "$domains"
# Code-quality has no keywords (back-compat: always in keyword-keep set),
# but it is NOT in the CSV, so it must still be excluded. This verifies
# the CSV filter is the outer envelope and the keyword filter doesn't
# re-introduce CSV-excluded domains.
assert_not_contains "compose: code-quality dropped (not in CSV, despite no keywords)" \
  "code-quality" "$domains"

echo ""
echo "Test 7: --scope-by-keywords is a no-op outside bugreport mode"
# The keyword matcher is gated on MODE==bugreport (only mode with a
# bug-report text corpus). In audit mode the flag must be silently
# inert — full audit lens fan-out, untouched by keyword logic.
expected_audit_count="$(jq '
  [.domains[]
   | select(.mode != "discover" and .mode != "deploy"
            and .mode != "opensource" and .mode != "content"
            and .mode != "greenfield" and .mode != "polish")
   | .lenses | length] | add
' "$DOMAINS_FILE")"
out="$TMPDIR/out-audit.txt"
run_dry "$out" "audit" --mode audit --scope-by-keywords
rc=$?
assert_success "--scope-by-keywords in audit mode exits 0" "$rc"
actual_audit_count="$(extract_lens_entries "$out" | sed '/^$/d' | wc -l | tr -d ' ')"
TOTAL=$((TOTAL + 1))
if [[ "$expected_audit_count" == "$actual_audit_count" ]]; then
  pass_with "audit mode lens count untouched by --scope-by-keywords"
else
  fail_with "audit mode lens count untouched by --scope-by-keywords" \
    "Expected: $expected_audit_count | Actual: $actual_audit_count"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
