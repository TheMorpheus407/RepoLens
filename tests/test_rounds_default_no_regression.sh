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

# Tests for issue #177: --rounds default preserves today's single-pass behavior.
#
# Goal: lock in the backward-compat guarantee of the multi-round feature.
# Invoking repolens.sh WITHOUT --rounds (or with --rounds 1) must produce
# byte-identical output to today's single-pass run, after normalization of
# inherently nondeterministic fields (timestamps, run IDs, absolute paths).
#
# Mechanism: capture --dry-run output for each of the 8 default-rounds modes
# (audit, feature, bugfix, custom, discover, deploy, opensource, content),
# normalize, and diff against committed baselines in tests/baselines/<mode>.txt.
#
# bugreport is intentionally excluded: its default ROUNDS is 3, not 1, so it
# falls outside the single-pass backward-compat contract.
#
# Update workflow: when an intentional UX change shifts dry-run output, run
#   bash tests/test_rounds_default_no_regression.sh --update-baseline
# to regenerate tests/baselines/*.txt. Reviewers must opt-in to baseline
# changes via PR review.
#
# Normalization function strips:
#   - ISO-8601 timestamps:        2026-05-12T06:40:10Z       -> <TIMESTAMP>
#   - Run IDs:                    20260512T064010Z-919eab16  -> <RUN_ID>
#   - mktemp project paths:       /tmp/tmp.A1b2C3d4E5        -> <PROJECT>
#   - tmp.XXX local-mode tags:    local/tmp.A1b2C3d4E5       -> local/<PROJECT_TAIL>
#
# Defense in depth: in addition to the baseline diff, every mode is asserted
# to have NONE of the multi-round markers (ROUND_INDEX=, ROUND_TOTAL=,
# PRIOR_ROUND_DIGEST, HYPOTHESES_TO_VERIFY, [round 2/, [round 3/,
# "Using meta-orchestrator dispatch") and MUST contain literal "rounds=1" in
# the cost line.

set -uo pipefail

# Prevent CI-injected env from poisoning the default-rounds-1 path under test.
unset REPOLENS_ROUNDS REPOLENS_MAX_ROUNDS

# Pin the detected core count so the committed baselines stay byte-stable on
# ANY host (issue #367). The dry-run wall-clock line embeds the resolved
# --max-parallel value; once the default becomes nproc-aware
# (clamp(nproc, 8, 32)), an unpinned 16- or 32-core box would render
# "--max-parallel 16/32" and break the byte-for-byte baseline diff. Pinning
# REPOLENS_NPROC=8 forces clamp(8, 8, 32)=8, matching the committed baselines'
# "--max-parallel 8" on every host — no baseline regeneration required.
export REPOLENS_NPROC=8

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASELINES_DIR="$SCRIPT_DIR/tests/baselines"
TMP_PARENT="$SCRIPT_DIR/logs/test-rounds-default-no-regression"
mkdir -p "$TMP_PARENT"
TMPDIR_RUN="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"
CREATED_RUN_IDS=()

FAKE_BIN="$TMPDIR_RUN/fake-bin"
mkdir -p "$FAKE_BIN"
for _agent in claude codex opencode agy; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/$_agent"
  chmod +x "$FAKE_BIN/$_agent"
done
# Pin the pricing-age clock to the checked-in pricing date. Otherwise the
# freshness warning appears after 60 days and breaks all eight baselines.
# Keep real date parsing and formatted timestamps; freshness behavior has its
# own boundary tests in test_pricing_freshness.sh.
BASELINE_REAL_DATE="$(command -v date)"
BASELINE_UPDATED_AT="$(jq -er '.updated_at' "$SCRIPT_DIR/config/agent-pricing.json")" || exit 1
if ! BASELINE_NOW_EPOCH="$("$BASELINE_REAL_DATE" -d "$BASELINE_UPDATED_AT" +%s 2>/dev/null)"; then
  # BSD date retains unspecified time fields; specify midnight to match GNU.
  BASELINE_NOW_EPOCH="$("$BASELINE_REAL_DATE" -j -f '%Y-%m-%d %H:%M:%S' "$BASELINE_UPDATED_AT 00:00:00" +%s 2>/dev/null)" || exit 1
fi
export BASELINE_REAL_DATE BASELINE_NOW_EPOCH
cat > "$FAKE_BIN/date" <<'DATE'
#!/usr/bin/env bash
set -uo pipefail
if [[ "$#" -eq 1 && "$1" == +%s ]]; then
  printf '%s\n' "$BASELINE_NOW_EPOCH"
else
  exec "$BASELINE_REAL_DATE" "$@"
fi
DATE
chmod +x "$FAKE_BIN/date"
export PATH="$FAKE_BIN:$PATH"

UPDATE_BASELINE=false
if [[ "${1:-}" == "--update-baseline" ]]; then
  UPDATE_BASELINE=true
  mkdir -p "$BASELINES_DIR"
fi

cleanup() {
  local run_id
  rm -rf "$TMPDIR_RUN"
  for run_id in "${CREATED_RUN_IDS[@]:-}"; do
    [[ -n "$run_id" ]] && rm -rf "$SCRIPT_DIR/logs/$run_id"
  done
  rmdir "$TMP_PARENT" 2>/dev/null || true
}
trap cleanup EXIT

PASS=0
FAIL=0
TOTAL=0

pass_with() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

fail_with() {
  local desc="$1" detail="${2:-}"
  FAIL=$((FAIL + 1))
  echo "  FAIL: $desc"
  if [[ -n "$detail" ]]; then
    printf '    %s\n' "$detail" | head -50
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

# Per-mode --focus map. The literal `injection` lens lives in `security/`,
# which is part of every non-exclusive mode. For exclusive modes
# (discover/deploy/opensource/content) we pick the canonical first lens of
# that mode's first domain.
focus_for_mode() {
  case "$1" in
    audit|feature|bugfix|custom) echo "injection" ;;
    discover) echo "product-gaps" ;;
    deploy) echo "service-health" ;;
    opensource) echo "secret-leaks" ;;
    content) echo "content-inventory" ;;
    *) echo "" ;;
  esac
}

# Extra CLI args required by some modes (e.g. custom requires --change).
extra_args_for_mode() {
  case "$1" in
    custom) printf '%s\0%s\0' "--change" "regression-test sentinel" ;;
    *) : ;;
  esac
}

# Make a deterministic empty project. The test asserts on dry-run output only,
# so no real source is needed — the cost-banner token estimate is dominated by
# the fixed agent-pricing constants.
make_project() {
  local project="$1"
  mkdir -p "$project"
  git -C "$project" init -q
  printf '# rounds-default-no-regression\n' > "$project/README.md"
}

# Strip every known nondeterministic field. After normalize() two independent
# runs of the same `mode` configuration MUST be byte-identical.
normalize() {
  local project="$1"
  local project_tail="${project##*/}"
  # GNU sed regex; tab kept verbatim.
  sed -E \
    -e "s@${TMPDIR_RUN}@<TMP_RUN_DIR>@g" \
    -e "s@${project}@<PROJECT>@g" \
    -e "s@${project_tail}@<PROJECT_TAIL>@g" \
    -e 's@[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z@<TIMESTAMP>@g' \
    -e 's@[0-9]{8}T[0-9]{6}Z-[a-f0-9]{8}@<RUN_ID>@g'
}

# Capture dry-run output for one mode and emit the normalized form on stdout.
# Side effects: creates a temp project, captures the run-ID for cleanup.
capture_mode() {
  local mode="$1"
  local project="$TMPDIR_RUN/project-$mode"
  local out_dir="$TMPDIR_RUN/issues-$mode"
  make_project "$project"

  local focus
  focus="$(focus_for_mode "$mode")"

  # Build argv. Read mode-specific extras from NUL-delimited stream so
  # `--change "two words"` survives intact.
  local -a argv=(
    --project "$project"
    --agent codex
    --mode "$mode"
    --focus "$focus"
    --local
    --output "$out_dir"
    --dry-run
    --yes
  )
  local extra
  while IFS= read -r -d '' extra; do
    [[ -n "$extra" ]] && argv+=("$extra")
  done < <(extra_args_for_mode "$mode")

  local raw_output
  raw_output="$(bash "$SCRIPT_DIR/repolens.sh" "${argv[@]}" 2>&1)" || true

  # Harvest the run-id so we can clean up logs/<run-id>/.
  local rid
  rid="$(printf '%s\n' "$raw_output" | grep -oE 'RepoLens run [^ ]+ starting' \
        | head -1 | awk '{print $3}')"
  if [[ -n "$rid" ]]; then
    CREATED_RUN_IDS+=("$rid")
  fi

  printf '%s\n' "$raw_output" | normalize "$project"
}

echo ""
echo "=== Test Suite: rounds default no regression (issue #177) ==="
echo ""

MODES=(audit feature bugfix custom discover deploy opensource content)

for mode in "${MODES[@]}"; do
  echo "Test: capture --mode $mode --dry-run"
  baseline="$BASELINES_DIR/$mode.txt"
  actual_file="$TMPDIR_RUN/actual-$mode.txt"

  capture_mode "$mode" > "$actual_file"

  if $UPDATE_BASELINE; then
    mkdir -p "$BASELINES_DIR"
    cp "$actual_file" "$baseline"
    TOTAL=$((TOTAL + 1))
    pass_with "baseline written for mode '$mode'"
    continue
  fi

  # ---- baseline diff ----
  TOTAL=$((TOTAL + 1))
  if [[ ! -f "$baseline" ]]; then
    fail_with "baseline missing for mode '$mode'" \
      "expected: $baseline (run with --update-baseline to create)"
  elif diff -u "$baseline" "$actual_file" > "$TMPDIR_RUN/$mode.diff" 2>&1; then
    pass_with "mode '$mode' matches baseline"
  else
    fail_with "mode '$mode' diverges from baseline" \
      "$(cat "$TMPDIR_RUN/$mode.diff")"
  fi

  # ---- structural assertions (defense in depth — run even on baseline match) ----
  actual_content="$(cat "$actual_file")"

  # Round-template vars must NEVER leak into the rendered output.
  assert_not_contains "[$mode] no ROUND_INDEX leak"      "ROUND_INDEX="          "$actual_content"
  assert_not_contains "[$mode] no ROUND_TOTAL leak"      "ROUND_TOTAL="          "$actual_content"
  assert_not_contains "[$mode] no PRIOR_ROUND_DIGEST leak" "PRIOR_ROUND_DIGEST"  "$actual_content"
  assert_not_contains "[$mode] no HYPOTHESES_TO_VERIFY leak" "HYPOTHESES_TO_VERIFY" "$actual_content"

  # Multi-round banner must NOT appear for single-pass default.
  assert_not_contains "[$mode] no [round 2/ banner" "[round 2/" "$actual_content"
  assert_not_contains "[$mode] no [round 3/ banner" "[round 3/" "$actual_content"

  # Meta-orchestrator / synthesizer / verifier must NOT dispatch for rounds_total==1.
  assert_not_contains "[$mode] no meta-orchestrator dispatch" \
    "Using meta-orchestrator dispatch" "$actual_content"

  # Positive assertion: the default IS rounds=1 (catches a default-flip regression).
  assert_contains "[$mode] cost line shows rounds=1" "rounds=1" "$actual_content"
done

# =====================================================================
# audit-mode filesystem invariant: dry-run still calls init_run_layout
# and creates rounds/round-1/. Verify that rounds/round-2/ is NEVER created.
# =====================================================================
echo ""
echo "Test: audit-mode dry-run creates round-1 but never round-2"
audit_project="$TMPDIR_RUN/fs-audit-project"
make_project "$audit_project"
audit_out="$TMPDIR_RUN/fs-audit.out"
bash "$SCRIPT_DIR/repolens.sh" \
  --project "$audit_project" \
  --agent codex \
  --mode audit \
  --focus injection \
  --local \
  --output "$TMPDIR_RUN/fs-audit-issues" \
  --dry-run \
  --yes >"$audit_out" 2>&1 || true

audit_rid="$(grep -oE 'RepoLens run [^ ]+ starting' "$audit_out" \
            | head -1 | awk '{print $3}')"
if [[ -n "$audit_rid" ]]; then
  CREATED_RUN_IDS+=("$audit_rid")
fi

TOTAL=$((TOTAL + 1))
if [[ -n "$audit_rid" && -d "$SCRIPT_DIR/logs/$audit_rid/rounds/round-1" ]]; then
  pass_with "rounds/round-1/ exists (single-round layout created)"
else
  fail_with "rounds/round-1/ missing" "run-id: $audit_rid"
fi

TOTAL=$((TOTAL + 1))
if [[ -n "$audit_rid" && ! -e "$SCRIPT_DIR/logs/$audit_rid/rounds/round-2" ]]; then
  pass_with "rounds/round-2/ absent (default --rounds 1 stays single-pass)"
else
  fail_with "rounds/round-2/ unexpectedly present" \
    "$SCRIPT_DIR/logs/$audit_rid/rounds/round-2"
fi

# Verify metadata.json reports rounds_total=1.
audit_metadata="$SCRIPT_DIR/logs/$audit_rid/rounds/round-1/metadata.json"
TOTAL=$((TOTAL + 1))
if [[ -f "$audit_metadata" ]]; then
  rt="$(jq -r '.rounds_total // empty' "$audit_metadata" 2>/dev/null || echo "")"
  if [[ "$rt" == "1" ]]; then
    pass_with "round-1/metadata.json reports rounds_total=1"
  else
    fail_with "round-1/metadata.json rounds_total mismatch" "got: $rt"
  fi
else
  fail_with "round-1/metadata.json missing" "$audit_metadata"
fi

echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

[[ "$FAIL" -eq 0 ]] || exit 1
