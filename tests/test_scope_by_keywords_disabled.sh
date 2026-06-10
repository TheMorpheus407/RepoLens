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

# Tests for issue #228: when neither `--scope-by-keywords` nor
# `REPOLENS_SCOPE_BY_KEYWORDS` is set — and no `--relevant-domains` CSV is
# provided — the default lens count MUST equal today's full mode-filtered
# fan-out byte-for-byte. This is the most important back-compat guarantee:
# adding the feature must not silently shrink default runs.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOLENS_SH="$SCRIPT_DIR/repolens.sh"
DOMAINS_FILE="$SCRIPT_DIR/config/domains.json"

PASS=0
FAIL=0
TOTAL=0

TMP_PARENT="$SCRIPT_DIR/logs/test-scope-by-keywords-disabled"
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

make_project() {
  local project="$1"
  mkdir -p "$project"
  git -C "$project" init -q
  printf '# kw-disabled test\n' > "$project/README.md"
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

extract_lens_entries() {
  local out_file="$1"
  awk '
    /^Lenses that would run:/ { in_list = 1; next }
    in_list && /^[[:space:]]*$/ { in_list = 0; next }
    in_list { gsub(/^[[:space:]]+/, "", $0); print }
  ' "$out_file"
}

# Compute the bugreport-mode lens total dynamically from domains.json using
# the same selection predicate the production resolve_lenses() catch-all
# uses. NOTE: bugreport is a "default" mode, so it includes domains whose
# mode is unset and excludes all mode-specific domains.
expected_bugreport_count="$(jq '
  [.domains[]
   | select(.mode != "discover" and .mode != "deploy"
            and .mode != "opensource" and .mode != "content"
            and .mode != "greenfield" and .mode != "polish")
   | .lenses | length] | add
' "$DOMAINS_FILE")"

BUG_FILE="$TMPDIR/bug.txt"
printf 'Symptom: foo crashes when bar runs.\n' > "$BUG_FILE"

echo ""
echo "=== Test Suite: --scope-by-keywords disabled (#228 back-compat) ==="
echo ""

echo "Test 1: no flag + no env var → full mode-filtered fan-out"
out="$TMPDIR/out-default.txt"
run_dry "$out" "default" --mode bugreport --bug-report "$BUG_FILE"
rc=$?
assert_success "default dry-run exits 0" "$rc"
actual_count="$(extract_lens_entries "$out" | sed '/^$/d' | wc -l | tr -d ' ')"
assert_eq "default lens count equals jq-derived bugreport total" \
  "$expected_bugreport_count" "$actual_count"

echo ""
echo "Test 2: explicit REPOLENS_SCOPE_BY_KEYWORDS=0 also disables the feature"
out="$TMPDIR/out-env0.txt"
project="$TMPDIR/project-env0"
make_project "$project"
env REPOLENS_SCOPE_BY_KEYWORDS=0 bash "$REPOLENS_SH" \
  --project "$project" \
  --agent claude \
  --dry-run \
  --yes \
  --local \
  --output "$TMPDIR/issues-env0" \
  --mode bugreport --bug-report "$BUG_FILE" \
  >"$out" 2>&1
rc=$?
register_run_id_from "$out"
assert_success "env=0 dry-run exits 0" "$rc"
actual_count="$(extract_lens_entries "$out" | sed '/^$/d' | wc -l | tr -d ' ')"
assert_eq "env=0 lens count equals jq-derived bugreport total" \
  "$expected_bugreport_count" "$actual_count"

echo ""
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
