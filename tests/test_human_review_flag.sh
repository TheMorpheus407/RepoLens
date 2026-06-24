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

# Tests for issue #325: --human-review flag (noise-budget mode) + usage/help
# + REPOLENS_HUMAN_REVIEW env fallback.
#
# This is a pure CLI-plumbing flag mirroring the REPOLENS_NO_VERIFIER /
# REPOLENS_SCOPE_BY_KEYWORDS boolean-with-env-fallback pattern. No downstream
# renderer behavior is wired yet — the flag only resolves + exports a boolean.
#
# Observability contract: because no control flow reads HUMAN_REVIEW yet, the
# only no-agent surface on which the resolved boolean is observable is the
# --dry-run banner. These tests therefore require the implementer to surface
# the resolved value in the dry-run banner (research §7 "observability gap",
# recommended option), mirroring how `Strategy:` is printed (repolens.sh
# ~L2767). The asserted line carries the resolved boolean as the literal
# string `true`/`false`, matching the established `export HUMAN_REVIEW`
# string convention. The label-matching is case/spacing-tolerant so the
# implementer keeps wording latitude; only the boolean value is pinned.
#
# Covers (each maps to an acceptance criterion):
#   1. --help advertises --human-review, an example using it, and the
#      REPOLENS_HUMAN_REVIEW Environment entry.            (criterion 4)
#   2. --human-review parses (no "Unknown argument", exit 0). (criterion 1)
#   3. --human-review resolves the boolean to true.          (criterion 1)
#   4. Default (no flag, no env) leaves it off (false).      (criteria 2/5)
#   5. REPOLENS_HUMAN_REVIEW grammar resolves to the documented boolean for
#      every accepted spelling (case-folded).               (criterion 2)
#   6. CLI flag wins over the env var.                       (criterion 3)
#   7. A bogus env value dies, mentioning REPOLENS_HUMAN_REVIEW. (criterion 2)
#
# No real models are invoked — every repolens.sh run uses --dry-run (which
# exits before any agent call) or --help.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOLENS_SH="$SCRIPT_DIR/repolens.sh"

PASS=0
FAIL=0
TOTAL=0

TMP_PARENT="$SCRIPT_DIR/logs/test-human-review-flag"
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

pass_with() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

fail_with() {
  local desc="$1" detail="${2:-}"
  FAIL=$((FAIL + 1))
  echo "  FAIL: $desc"
  if [[ -n "$detail" ]]; then
    printf '    %s\n' "$detail"
  fi
}

assert_success() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -eq 0 ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected exit 0, got $actual"
  fi
}

assert_failure() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -ne 0 ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected non-zero exit"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected to find '$needle'"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Did not expect to find '$needle'"
  fi
}

make_project() {
  local project="$1"
  mkdir -p "$project"
  git -C "$project" init -q
  printf '# human-review test\n' > "$project/README.md"
  git -C "$project" -c user.email=t@t -c user.name=t add README.md >/dev/null 2>&1 || true
  git -C "$project" -c user.email=t@t -c user.name=t commit -q -m init >/dev/null 2>&1 || true
}

register_run_id_from() {
  local out_file="$1" run_id
  run_id="$(grep -oE 'RepoLens run [^ ]+ starting' "$out_file" 2>/dev/null | head -1 | awk '{print $3}')"
  if [[ -n "$run_id" ]]; then
    CREATED_RUN_IDS+=("$run_id")
  fi
}

# Drive a dry-run invocation with extra flags. --local + --output bypasses the
# forge-detection gate so a freshly-init'd no-origin repo still reaches the
# dry-run print section. Captured output goes to the given file path.
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

# As run_dry, but with a single VAR=value prepended to the environment.
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

# Extract the dry-run banner line that reports the resolved --human-review
# state. Case-insensitive and tolerant of the exact label spelling/spacing;
# anchored so it cannot collide with a listed lens path. Returns '' if absent.
hr_banner_line() {
  grep -iE '^[[:space:]]*human[ _-]?review' "$1" 2>/dev/null | head -1
}

echo ""
echo "=== Test Suite: --human-review flag ==="
echo ""

echo "Test 1: --help advertises --human-review, an example, and the env entry"
help_out="$(bash "$REPOLENS_SH" --help 2>&1)"
help_rc=$?
assert_success "--help exits 0" "$help_rc"
assert_contains "help text mentions --human-review" "--human-review" "$help_out"
assert_contains "help text documents REPOLENS_HUMAN_REVIEW env fallback" \
  "REPOLENS_HUMAN_REVIEW" "$help_out"
# An Examples line is a `repolens.sh ...` invocation that uses the flag —
# distinguishes the example from the Options/Environment doc lines.
example_count=$(grep -cE '^[[:space:]]*repolens\.sh .*--human-review' <<< "$help_out")
TOTAL=$((TOTAL + 1))
if (( example_count >= 1 )); then
  pass_with "help block includes an example invocation using --human-review"
else
  fail_with "help block includes an example invocation using --human-review" \
    "Got $example_count example lines"
fi

echo ""
echo "Test 2: --human-review parses (no Unknown argument, exit 0)"
out="$TMPDIR/out-parse.txt"
run_dry "$out" "parse" --human-review
rc=$?
assert_success "--human-review dry-run exits 0" "$rc"
assert_not_contains "no Unknown argument error" "Unknown argument" "$(cat "$out")"

echo ""
echo "Test 3: --human-review resolves the boolean to true"
out="$TMPDIR/out-flag-true.txt"
run_dry "$out" "flag-true" --human-review
rc=$?
assert_success "--human-review run exits 0" "$rc"
assert_contains "dry-run banner reports a human-review line" \
  "review" "$(hr_banner_line "$out")"
assert_contains "--human-review resolves to true" \
  "true" "$(hr_banner_line "$out")"

echo ""
echo "Test 4: default (no flag, no env) leaves human-review off"
out="$TMPDIR/out-default.txt"
run_dry "$out" "default"
rc=$?
assert_success "default dry-run exits 0" "$rc"
assert_contains "default human-review resolves to false" \
  "false" "$(hr_banner_line "$out")"

echo ""
echo "Test 5: REPOLENS_HUMAN_REVIEW grammar resolves to the documented boolean"
# Truthy spellings (case-folded) must resolve true; falsy spellings false.
# Each value is exercised via the env fallback with the CLI flag absent.
for val in 1 true yes on TRUE On YeS; do
  out="$TMPDIR/out-env-true-$val.txt"
  run_dry_env "$out" "env-true-$val" "REPOLENS_HUMAN_REVIEW=$val"
  rc=$?
  assert_success "REPOLENS_HUMAN_REVIEW=$val exits 0" "$rc"
  assert_contains "REPOLENS_HUMAN_REVIEW=$val resolves to true" \
    "true" "$(hr_banner_line "$out")"
done
for val in 0 false no off FALSE Off; do
  out="$TMPDIR/out-env-false-$val.txt"
  run_dry_env "$out" "env-false-$val" "REPOLENS_HUMAN_REVIEW=$val"
  rc=$?
  assert_success "REPOLENS_HUMAN_REVIEW=$val exits 0" "$rc"
  assert_contains "REPOLENS_HUMAN_REVIEW=$val resolves to false" \
    "false" "$(hr_banner_line "$out")"
done

echo ""
echo "Test 6: CLI --human-review wins over REPOLENS_HUMAN_REVIEW=0"
out="$TMPDIR/out-cli-wins.txt"
run_dry_env "$out" "cli-wins" "REPOLENS_HUMAN_REVIEW=0" --human-review
rc=$?
assert_success "CLI override exits 0" "$rc"
assert_contains "CLI --human-review wins over env 0 (resolves true)" \
  "true" "$(hr_banner_line "$out")"

echo ""
echo "Test 7: bogus REPOLENS_HUMAN_REVIEW value is rejected"
out="$TMPDIR/out-env-bogus.txt"
run_dry_env "$out" "env-bogus" "REPOLENS_HUMAN_REVIEW=bogus"
rc=$?
assert_failure "REPOLENS_HUMAN_REVIEW=bogus exits non-zero" "$rc"
assert_contains "error mentions REPOLENS_HUMAN_REVIEW" \
  "REPOLENS_HUMAN_REVIEW" "$(cat "$out")"

echo ""
echo "Test 8: empty REPOLENS_HUMAN_REVIEW leaves human-review off"
# Criterion 2 names "empty" alongside 0/false/no/off as a value that leaves the
# flag off. Test 5's falsy set omits it because empty is a *distinct* path: the
# `elif [[ -n "${REPOLENS_HUMAN_REVIEW:-}" ]]` guard short-circuits before the
# `case` ever runs (the `""` case arm is dead code), so empty must NOT die and
# must fall through to the default `false`. `env VAR= cmd` sets VAR to "".
out="$TMPDIR/out-env-empty.txt"
run_dry_env "$out" "env-empty" "REPOLENS_HUMAN_REVIEW="
rc=$?
assert_success "REPOLENS_HUMAN_REVIEW= (empty) exits 0" "$rc"
assert_not_contains "empty env value does not die" "REPOLENS_HUMAN_REVIEW must be" "$(cat "$out")"
assert_contains "empty REPOLENS_HUMAN_REVIEW resolves to false" \
  "false" "$(hr_banner_line "$out")"

echo ""
echo "Test 9: CLI --human-review wins over a bogus env value (no die)"
# The precedence guard ($HUMAN_REVIEW_SET, criterion 3) is checked BEFORE the
# env var is parsed. So when the CLI flag is present, an otherwise-fatal bogus
# env value must never be consulted: no die, resolves to true. This is the
# sharpest edge of the guard ordering — Test 6 only covers CLI-vs-valid-0 and
# Test 7 only covers bogus-without-the-flag.
out="$TMPDIR/out-cli-over-bogus.txt"
run_dry_env "$out" "cli-over-bogus" "REPOLENS_HUMAN_REVIEW=bogus" --human-review
rc=$?
assert_success "CLI flag + bogus env exits 0 (env never parsed)" "$rc"
assert_not_contains "bogus env does not die when CLI flag wins" \
  "REPOLENS_HUMAN_REVIEW must be" "$(cat "$out")"
assert_contains "CLI --human-review wins over bogus env (resolves true)" \
  "true" "$(hr_banner_line "$out")"

echo ""
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
