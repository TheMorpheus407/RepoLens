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

# Tests for issue #228: invalid values to --relevant-domains must be
# rejected loudly so operator typos don't silently no-op. Validation is
# against the active mode's domain whitelist — domains that exist but
# belong to a different mode (e.g. `discovery` is a discover-mode-only
# domain) must also be rejected when used under --mode bugreport.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOLENS_SH="$SCRIPT_DIR/repolens.sh"

PASS=0
FAIL=0
TOTAL=0

TMP_PARENT="$SCRIPT_DIR/logs/test-relevant-domains-invalid"
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
assert_failure() {
  local desc="$1" actual="$2"; TOTAL=$((TOTAL + 1))
  if [[ "$actual" -ne 0 ]]; then pass_with "$desc"
  else fail_with "$desc" "Expected non-zero exit"; fi
}
assert_contains() {
  local desc="$1" needle="$2" haystack="$3"; TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then pass_with "$desc"
  else fail_with "$desc" "Expected to find '$needle'"; fi
}

make_project() {
  local project="$1"
  mkdir -p "$project"
  git -C "$project" init -q
  printf '# rd-invalid test\n' > "$project/README.md"
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

BUG_FILE="$TMPDIR/bug.txt"
printf 'Symptom: foo crashes when bar runs.\n' > "$BUG_FILE"

echo ""
echo "=== Test Suite: --relevant-domains invalid values (#228) ==="
echo ""

echo "Test 1: an unknown domain id is rejected and named in the error"
out="$TMPDIR/out-unknown.txt"
run_dry "$out" "unknown" --mode bugreport --bug-report "$BUG_FILE" \
  --relevant-domains concurrency,frobnicator
rc=$?
assert_failure "unknown id exits non-zero" "$rc"
assert_contains "error mentions the offending token 'frobnicator'" \
  "frobnicator" "$(cat "$out")"

echo ""
echo "Test 2: a wrong-mode domain id (discovery used under bugreport) is rejected"
# `discovery` is a real domain id but lives in mode=discover. Under --mode
# bugreport the mode-filtered whitelist excludes it, so it must be treated
# as invalid (issue's test plan §8.2).
out="$TMPDIR/out-wrongmode.txt"
run_dry "$out" "wrongmode" --mode bugreport --bug-report "$BUG_FILE" \
  --relevant-domains discovery
rc=$?
assert_failure "wrong-mode domain id exits non-zero" "$rc"
assert_contains "error mentions 'discovery'" "discovery" "$(cat "$out")"

echo ""
echo "Test 3: an empty-only CSV (only whitespace and commas) is rejected"
# Distinct from Test 5 of test_relevant_domains_flag.sh which mixes empty
# tokens with valid ones. A CSV containing zero valid ids must not silently
# resolve to "match everything" or "match nothing".
out="$TMPDIR/out-emptycsv.txt"
run_dry "$out" "emptycsv" --mode bugreport --bug-report "$BUG_FILE" \
  --relevant-domains "  , , ,, "
rc=$?
assert_failure "all-empty CSV exits non-zero" "$rc"

echo ""
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
