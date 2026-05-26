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

# Tests for issue #249 — agent-pricing.json freshness:
#   1. updated_at field exists and is a valid YYYY-MM-DD date
#   2. updated_at is within 90 days of now (CI freshness gate)
#   3. All models referenced by agent_default_model exist in models{}
#   4. confirm_run / dry-run emits a warning when pricing data is > 60 days old
#   5. confirm_run / dry-run does NOT warn when pricing data is recent
#   6. Default model for claude agent is claude-sonnet-4-6 (not stale 4-5)
#
# All cases use --dry-run plus a fake-codex agent. No real models are invoked.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRICING_FILE="$SCRIPT_DIR/config/agent-pricing.json"

TMP_PARENT="$SCRIPT_DIR/logs/test-pricing-freshness"
mkdir -p "$TMP_PARENT"
TMPDIR="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"
CREATED_RUN_IDS=()
BUG_FILE="$TMPDIR/bug-report.md"
printf 'Pricing freshness fixture bug report — placeholder text.\n' > "$BUG_FILE"

cleanup() {
  local run_id
  rm -rf "$TMPDIR"
  for run_id in "${CREATED_RUN_IDS[@]:-}"; do
    [[ -n "$run_id" ]] && rm -rf "$SCRIPT_DIR/logs/$run_id"
  done
  rmdir "$TMP_PARENT" 2>/dev/null || true
}
trap cleanup EXIT

PASS=0
FAIL=0
TOTAL=0
FAKE_BIN="$TMPDIR/bin"
LAST_OUTPUT_FILE=""
LAST_RC=0

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

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected: $expected | Actual: $actual"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected output to contain: $needle"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Did not expect output to contain: $needle"
  fi
}

make_fake_codex() {
  mkdir -p "$FAKE_BIN"
  cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
printf 'DONE\n'
EOF
  chmod +x "$FAKE_BIN/codex"
}

make_project() {
  local project="$1"
  mkdir -p "$project"
  git -C "$project" init -q
  for i in $(seq 1 20); do
    printf 'line %d of seed source — keep the repo above the 1k-token threshold\n' "$i" \
      >> "$project/src.txt"
  done
  printf '# pricing freshness fixture\n' > "$project/README.md"
}

last_output() {
  cat "$LAST_OUTPUT_FILE"
}

register_created_run_id() {
  local run_id
  run_id="$(grep -oE 'RepoLens run [^ ]+ starting' "$LAST_OUTPUT_FILE" 2>/dev/null | head -1 | awk '{print $3}')"
  if [[ -n "$run_id" ]]; then
    CREATED_RUN_IDS+=("$run_id")
  fi
}

# Run repolens with an isolated env and a custom pricing file.
# First arg = case name; second arg = pricing file override path;
# remaining args are forwarded to repolens.sh.
run_repolens_with_pricing() {
  local name="$1" pricing_override="$2"
  shift 2

  local project="$TMPDIR/proj-$name"
  make_project "$project"

  LAST_OUTPUT_FILE="$TMPDIR/out-$name.txt"

  # Copy the override pricing file into the project's config dir so
  # repolens.sh picks it up from $SCRIPT_DIR/config/agent-pricing.json.
  # We create a temporary SCRIPT_DIR overlay via symlinks.
  local overlay="$TMPDIR/overlay-$name"
  mkdir -p "$overlay/config"
  cp "$pricing_override" "$overlay/config/agent-pricing.json"
  # Symlink everything else from real SCRIPT_DIR
  for item in "$SCRIPT_DIR"/*; do
    local base
    base="$(basename "$item")"
    [[ "$base" == "config" ]] && continue
    [[ "$base" == "logs" ]] && continue
    ln -sf "$item" "$overlay/$base" 2>/dev/null || true
  done
  # Symlink non-pricing config files
  for item in "$SCRIPT_DIR/config"/*; do
    local base
    base="$(basename "$item")"
    [[ "$base" == "agent-pricing.json" ]] && continue
    ln -sf "$item" "$overlay/config/$base" 2>/dev/null || true
  done
  mkdir -p "$overlay/logs"

  env -u REPOLENS_ROUNDS -u REPOLENS_MAX_ROUNDS -u DONE_STREAK_REQUIRED \
    PATH="$FAKE_BIN:$PATH" \
    bash "$overlay/repolens.sh" \
      --project "$project" \
      --agent codex \
      --mode bugreport \
      --bug-report "$BUG_FILE" \
      --local \
      --output "$TMPDIR/issues-$name" \
      "$@" </dev/null >"$LAST_OUTPUT_FILE" 2>&1
  LAST_RC=$?
  register_created_run_id
}

echo ""
echo "=== Test Suite: pricing freshness (issue #249) ==="
echo ""

make_fake_codex

# -----------------------------------------------------------------------
# Test 1: updated_at field exists in agent-pricing.json
# -----------------------------------------------------------------------
echo "Test 1: agent-pricing.json has an updated_at field"
updated_at="$(jq -r '.updated_at // empty' "$PRICING_FILE" 2>/dev/null)"
TOTAL=$((TOTAL + 1))
if [[ -n "$updated_at" ]]; then
  pass_with "updated_at field exists: $updated_at"
else
  fail_with "updated_at field missing from $PRICING_FILE"
fi

# -----------------------------------------------------------------------
# Test 2: updated_at is a valid YYYY-MM-DD date
# -----------------------------------------------------------------------
echo ""
echo "Test 2: updated_at is a valid YYYY-MM-DD date"
TOTAL=$((TOTAL + 1))
if [[ "$updated_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  # Verify it's a real date (not 2026-13-45)
  if date -d "$updated_at" +%s >/dev/null 2>&1; then
    pass_with "updated_at is a valid date: $updated_at"
  else
    fail_with "updated_at matches YYYY-MM-DD pattern but is not a valid date: $updated_at"
  fi
else
  fail_with "updated_at does not match YYYY-MM-DD: '$updated_at'"
fi

# -----------------------------------------------------------------------
# Test 3: updated_at is within 90 days of now (CI freshness gate)
# -----------------------------------------------------------------------
echo ""
echo "Test 3: pricing data is not stale (updated_at within 90 days)"
TOTAL=$((TOTAL + 1))
if [[ -n "$updated_at" ]]; then
  now_epoch="$(date +%s)"
  updated_epoch="$(date -d "$updated_at" +%s 2>/dev/null || echo 0)"
  days_old=$(( (now_epoch - updated_epoch) / 86400 ))
  if [[ "$days_old" -le 90 ]]; then
    pass_with "pricing data is $days_old days old (<=90)"
  else
    fail_with "pricing data is $days_old days old (>90 — needs refresh)"
  fi
else
  fail_with "cannot check freshness: updated_at field is missing"
fi

# -----------------------------------------------------------------------
# Test 4: All models referenced in agent_default_model exist in models{}
# -----------------------------------------------------------------------
echo ""
echo "Test 4: agent_default_model references only models that exist in models{}"
default_model_refs="$(jq -r '.agent_default_model | values[]' "$PRICING_FILE" 2>/dev/null)"
while IFS= read -r model_ref; do
  [[ -z "$model_ref" ]] && continue
  TOTAL=$((TOTAL + 1))
  model_exists="$(jq -r --arg m "$model_ref" '.models[$m] // empty' "$PRICING_FILE" 2>/dev/null)"
  if [[ -n "$model_exists" ]]; then
    pass_with "agent_default_model reference '$model_ref' exists in models{}"
  else
    fail_with "agent_default_model references '$model_ref' but it is not in models{}"
  fi
done <<< "$default_model_refs"

# -----------------------------------------------------------------------
# Test 5: Default claude model is claude-sonnet-4-6 (not stale 4-5)
# -----------------------------------------------------------------------
echo ""
echo "Test 5: default claude model is claude-sonnet-4-6"
claude_default="$(jq -r '.agent_default_model.claude // empty' "$PRICING_FILE" 2>/dev/null)"
assert_eq "claude default model is claude-sonnet-4-6" "claude-sonnet-4-6" "$claude_default"

# -----------------------------------------------------------------------
# Test 6: Dry-run with stale pricing (100 days old) emits freshness warning
# -----------------------------------------------------------------------
echo ""
echo "Test 6: dry-run with stale pricing (100 days old) emits freshness warning"
stale_date="$(date -d '100 days ago' +%Y-%m-%d)"
stale_pricing="$TMPDIR/stale-pricing.json"
jq --arg d "$stale_date" '. + {"updated_at": $d}' "$PRICING_FILE" > "$stale_pricing"
run_repolens_with_pricing "stale-warn" "$stale_pricing" --rounds 1 --yes --dry-run
out_stale="$(last_output)"
assert_eq "stale pricing dry-run exits 0" "0" "$LAST_RC"
assert_contains "stale pricing emits 'days old' warning" "days old" "$out_stale"

# -----------------------------------------------------------------------
# Test 7: Dry-run with fresh pricing (today) does NOT emit freshness warning
# -----------------------------------------------------------------------
echo ""
echo "Test 7: dry-run with fresh pricing (today) does NOT emit freshness warning"
today_date="$(date +%Y-%m-%d)"
fresh_pricing="$TMPDIR/fresh-pricing.json"
jq --arg d "$today_date" '. + {"updated_at": $d}' "$PRICING_FILE" > "$fresh_pricing"
run_repolens_with_pricing "fresh-no-warn" "$fresh_pricing" --rounds 1 --yes --dry-run
out_fresh="$(last_output)"
assert_eq "fresh pricing dry-run exits 0" "0" "$LAST_RC"
assert_not_contains "fresh pricing does NOT emit 'days old' warning" "days old" "$out_fresh"

# -----------------------------------------------------------------------
# Test 8: claude-opus-4-6 pricing is $5/$25, not the stale $15/$75
# -----------------------------------------------------------------------
echo ""
echo "Test 8: claude-opus-4-6 priced at \$5/\$25 (not stale \$15/\$75)"
opus46_in="$(jq -r '.models["claude-opus-4-6"].input_per_mtok // empty' "$PRICING_FILE" 2>/dev/null)"
opus46_out="$(jq -r '.models["claude-opus-4-6"].output_per_mtok // empty' "$PRICING_FILE" 2>/dev/null)"
TOTAL=$((TOTAL + 1))
if awk -v a="$opus46_in" 'BEGIN { exit (a == 5 || a == 5.0 || a == 5.00) ? 0 : 1 }'; then
  pass_with "claude-opus-4-6 input price is \$${opus46_in}/MTok"
else
  fail_with "claude-opus-4-6 input price is \$${opus46_in}/MTok (expected 5.00)"
fi
TOTAL=$((TOTAL + 1))
if awk -v a="$opus46_out" 'BEGIN { exit (a == 25 || a == 25.0 || a == 25.00) ? 0 : 1 }'; then
  pass_with "claude-opus-4-6 output price is \$${opus46_out}/MTok"
else
  fail_with "claude-opus-4-6 output price is \$${opus46_out}/MTok (expected 25.00)"
fi

# -----------------------------------------------------------------------
# Test 9: claude-opus-4-7 and claude-sonnet-4-6 models exist in pricing
# -----------------------------------------------------------------------
echo ""
echo "Test 9: newer Claude models exist in pricing data"
for model_id in "claude-opus-4-7" "claude-sonnet-4-6"; do
  TOTAL=$((TOTAL + 1))
  model_data="$(jq -r --arg m "$model_id" '.models[$m].label // empty' "$PRICING_FILE" 2>/dev/null)"
  if [[ -n "$model_data" ]]; then
    pass_with "$model_id exists in models{} (label: $model_data)"
  else
    fail_with "$model_id missing from models{}"
  fi
done

# -----------------------------------------------------------------------
# Test 10: claude-opus-4-7 pricing values are correct ($5/$25)
# -----------------------------------------------------------------------
echo ""
echo "Test 10: claude-opus-4-7 priced at \$5/\$25"
opus47_in="$(jq -r '.models["claude-opus-4-7"].input_per_mtok // empty' "$PRICING_FILE" 2>/dev/null)"
opus47_out="$(jq -r '.models["claude-opus-4-7"].output_per_mtok // empty' "$PRICING_FILE" 2>/dev/null)"
TOTAL=$((TOTAL + 1))
if awk -v a="$opus47_in" 'BEGIN { exit (a == 5 || a == 5.0 || a == 5.00) ? 0 : 1 }'; then
  pass_with "claude-opus-4-7 input price is \$${opus47_in}/MTok"
else
  fail_with "claude-opus-4-7 input price is \$${opus47_in}/MTok (expected 5.00)"
fi
TOTAL=$((TOTAL + 1))
if awk -v a="$opus47_out" 'BEGIN { exit (a == 25 || a == 25.0 || a == 25.00) ? 0 : 1 }'; then
  pass_with "claude-opus-4-7 output price is \$${opus47_out}/MTok"
else
  fail_with "claude-opus-4-7 output price is \$${opus47_out}/MTok (expected 25.00)"
fi

# -----------------------------------------------------------------------
# Test 11: claude-sonnet-4-6 pricing values are correct ($3/$15)
# -----------------------------------------------------------------------
echo ""
echo "Test 11: claude-sonnet-4-6 priced at \$3/\$15"
sonnet46_in="$(jq -r '.models["claude-sonnet-4-6"].input_per_mtok // empty' "$PRICING_FILE" 2>/dev/null)"
sonnet46_out="$(jq -r '.models["claude-sonnet-4-6"].output_per_mtok // empty' "$PRICING_FILE" 2>/dev/null)"
TOTAL=$((TOTAL + 1))
if awk -v a="$sonnet46_in" 'BEGIN { exit (a == 3 || a == 3.0 || a == 3.00) ? 0 : 1 }'; then
  pass_with "claude-sonnet-4-6 input price is \$${sonnet46_in}/MTok"
else
  fail_with "claude-sonnet-4-6 input price is \$${sonnet46_in}/MTok (expected 3.00)"
fi
TOTAL=$((TOTAL + 1))
if awk -v a="$sonnet46_out" 'BEGIN { exit (a == 15 || a == 15.0 || a == 15.00) ? 0 : 1 }'; then
  pass_with "claude-sonnet-4-6 output price is \$${sonnet46_out}/MTok"
else
  fail_with "claude-sonnet-4-6 output price is \$${sonnet46_out}/MTok (expected 15.00)"
fi

# -----------------------------------------------------------------------
# Test 12: Missing updated_at field does NOT cause error or warning
# -----------------------------------------------------------------------
echo ""
echo "Test 12: missing updated_at field — no error, no warning"
no_date_pricing="$TMPDIR/no-date-pricing.json"
jq 'del(.updated_at)' "$PRICING_FILE" > "$no_date_pricing"
run_repolens_with_pricing "no-date" "$no_date_pricing" --rounds 1 --yes --dry-run
out_no_date="$(last_output)"
assert_eq "missing updated_at dry-run exits 0" "0" "$LAST_RC"
assert_not_contains "missing updated_at does NOT emit 'days old' warning" "days old" "$out_no_date"

# -----------------------------------------------------------------------
# Test 13: Invalid date string in updated_at does NOT cause error or warning
# -----------------------------------------------------------------------
echo ""
echo "Test 13: invalid date in updated_at — no error, no warning"
bad_date_pricing="$TMPDIR/bad-date-pricing.json"
jq '. + {"updated_at": "not-a-date"}' "$PRICING_FILE" > "$bad_date_pricing"
run_repolens_with_pricing "bad-date" "$bad_date_pricing" --rounds 1 --yes --dry-run
out_bad_date="$(last_output)"
assert_eq "invalid updated_at dry-run exits 0" "0" "$LAST_RC"
assert_not_contains "invalid updated_at does NOT emit 'days old' warning" "days old" "$out_bad_date"

# -----------------------------------------------------------------------
# Test 14: Boundary — exactly 60 days old does NOT warn (threshold is > 60)
# -----------------------------------------------------------------------
echo ""
echo "Test 14: exactly 60 days old — no warning (threshold is strictly > 60)"
boundary_date="$(date -d '60 days ago' +%Y-%m-%d)"
boundary_pricing="$TMPDIR/boundary-pricing.json"
jq --arg d "$boundary_date" '. + {"updated_at": $d}' "$PRICING_FILE" > "$boundary_pricing"
run_repolens_with_pricing "boundary-60" "$boundary_pricing" --rounds 1 --yes --dry-run
out_boundary="$(last_output)"
assert_eq "boundary 60-day dry-run exits 0" "0" "$LAST_RC"
assert_not_contains "exactly 60 days does NOT emit 'days old' warning" "days old" "$out_boundary"

# -----------------------------------------------------------------------
# Test 15: 61 days old DOES warn (just over the threshold)
# -----------------------------------------------------------------------
echo ""
echo "Test 15: 61 days old — emits warning (just over threshold)"
over_date="$(date -d '61 days ago' +%Y-%m-%d)"
over_pricing="$TMPDIR/over-pricing.json"
jq --arg d "$over_date" '. + {"updated_at": $d}' "$PRICING_FILE" > "$over_pricing"
run_repolens_with_pricing "over-61" "$over_pricing" --rounds 1 --yes --dry-run
out_over="$(last_output)"
assert_eq "61-day dry-run exits 0" "0" "$LAST_RC"
assert_contains "61 days old emits 'days old' warning" "days old" "$out_over"

echo ""
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
