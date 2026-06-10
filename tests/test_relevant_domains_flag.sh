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

# Tests for issue #228: `--relevant-domains <csv>` CLI flag — the "missing
# middle" between `--focus` (1 lens) and full fan-out. Operator-supplied
# allowlist of domain ids; intersects with the mode-filtered lens list at
# the same chokepoint as the #227 triage-side filter.
#
# All runs use `--dry-run` so no real models are invoked (CLAUDE.md::Tests).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOLENS_SH="$SCRIPT_DIR/repolens.sh"
DOMAINS_FILE="$SCRIPT_DIR/config/domains.json"

PASS=0
FAIL=0
TOTAL=0

TMP_PARENT="$SCRIPT_DIR/logs/test-relevant-domains-flag"
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
assert_eq() {
  local desc="$1" expected="$2" actual="$3"; TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then pass_with "$desc"
  else fail_with "$desc" "Expected: '$expected' | Actual: '$actual'"; fi
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
  printf '# rd-flag test\n' > "$project/README.md"
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

# Extract the list of "domain/lens" entries that the dry-run prints under
# the "Lenses that would run:" header.
extract_lens_entries() {
  local out_file="$1"
  awk '
    /^Lenses that would run:/ { in_list = 1; next }
    in_list && /^[[:space:]]*$/ { in_list = 0; next }
    in_list { gsub(/^[[:space:]]+/, "", $0); print }
  ' "$out_file"
}

# Extract the set of unique domain prefixes from the lens list.
extract_lens_domains() {
  local out_file="$1"
  extract_lens_entries "$out_file" | awk -F/ '{print $1}' | sort -u
}

BUG_FILE="$TMPDIR/bug.txt"
printf 'Symptom: deadlock between lock acquisitions; database query hangs.\n' > "$BUG_FILE"

echo ""
echo "=== Test Suite: --relevant-domains <csv> flag (#228) ==="
echo ""

echo "Test 1: --relevant-domains concurrency,database keeps only those domains"
out="$TMPDIR/out-csv.txt"
run_dry "$out" "csv" --mode bugreport --bug-report "$BUG_FILE" \
  --relevant-domains concurrency,database
rc=$?
assert_success "CSV invocation exits 0" "$rc"
domains="$(extract_lens_domains "$out")"
assert_contains "lens list includes concurrency domain" "concurrency" "$domains"
assert_contains "lens list includes database domain" "database" "$domains"
assert_not_contains "lens list excludes security domain" "security" "$domains"
assert_not_contains "lens list excludes performance domain" "performance" "$domains"
assert_not_contains "lens list excludes architecture domain" "architecture" "$domains"

echo ""
echo "Test 2: --relevant-domains lens count equals union of the two domains"
expected_count="$(jq '[.domains[] | select(.id == "concurrency" or .id == "database") | .lenses | length] | add' "$DOMAINS_FILE")"
actual_count="$(extract_lens_entries "$out" | wc -l | tr -d ' ')"
assert_eq "kept lens count matches sum of concurrency+database" "$expected_count" "$actual_count"

echo ""
echo "Test 3: whitespace and empty tokens in CSV are tolerated"
out="$TMPDIR/out-csv-ws.txt"
run_dry "$out" "csv-ws" --mode bugreport --bug-report "$BUG_FILE" \
  --relevant-domains "  ,, , database  , ,concurrency ,"
rc=$?
assert_success "whitespace-tolerant CSV invocation exits 0" "$rc"
domains="$(extract_lens_domains "$out")"
assert_contains "ws-CSV keeps concurrency" "concurrency" "$domains"
assert_contains "ws-CSV keeps database" "database" "$domains"
assert_not_contains "ws-CSV excludes security" "security" "$domains"

echo ""
echo "Test 4: --relevant-domains without an argument is rejected"
out="$TMPDIR/out-no-arg.txt"
run_dry "$out" "no-arg" --mode bugreport --bug-report "$BUG_FILE" \
  --relevant-domains
rc=$?
TOTAL=$((TOTAL + 1))
if [[ "$rc" -ne 0 ]]; then pass_with "--relevant-domains with no value exits non-zero"
else fail_with "--relevant-domains with no value exits non-zero" "got rc=0"; fi

echo ""
echo "Test 5: --focus short-circuits and bypasses --relevant-domains"
# --focus already selects exactly one lens; the CSV must not zero out or
# expand that single-lens selection. Behaviour: focus wins, CSV ignored.
out="$TMPDIR/out-focus.txt"
run_dry "$out" "focus" --mode bugreport --bug-report "$BUG_FILE" \
  --focus injection --relevant-domains kubernetes
rc=$?
assert_success "--focus + --relevant-domains exits 0" "$rc"
entries="$(extract_lens_entries "$out")"
entry_count="$(printf '%s\n' "$entries" | sed '/^$/d' | wc -l | tr -d ' ')"
assert_eq "focus mode resolves to exactly 1 lens (CSV ignored)" "1" "$entry_count"
assert_contains "focus lens is injection" "injection" "$entries"

echo ""
echo "Test 6: --help text documents --relevant-domains"
help_out="$(bash "$REPOLENS_SH" --help 2>&1)"
help_rc=$?
assert_success "--help exits 0" "$help_rc"
assert_contains "help text mentions --relevant-domains" "--relevant-domains" "$help_out"

echo ""
echo "Test 7: --domain (singular) short-circuits and bypasses --relevant-domains"
# --domain runs in its own branch of resolve_lenses() — the catch-all branch
# (where the CSV filter lives) never executes. So passing a --relevant-domains
# CSV alongside --domain must yield exactly the --domain selection, even if the
# CSV would otherwise restrict to a disjoint set. This is the parallel of Test 5
# (which covers --focus) for the singular-domain override.
out="$TMPDIR/out-domain-override.txt"
run_dry "$out" "domain-override" --mode bugreport --bug-report "$BUG_FILE" \
  --domain security --relevant-domains concurrency,database
rc=$?
assert_success "--domain + --relevant-domains exits 0" "$rc"
domains="$(extract_lens_domains "$out")"
assert_contains "--domain wins: security lenses present" "security" "$domains"
assert_not_contains "--domain wins: concurrency NOT introduced from CSV" \
  "concurrency" "$domains"
assert_not_contains "--domain wins: database NOT introduced from CSV" \
  "database" "$domains"
expected_dom_count="$(jq '[.domains[] | select(.id == "security") | .lenses | length] | add' "$DOMAINS_FILE")"
actual_dom_count="$(extract_lens_entries "$out" | sed '/^$/d' | wc -l | tr -d ' ')"
assert_eq "--domain alone determines lens count (CSV ignored)" \
  "$expected_dom_count" "$actual_dom_count"

echo ""
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
