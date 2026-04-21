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

# Integration test for issue #128 — rate-limit detection must NOT fire on
# user-code keyword false positives.
#
# The detector's signatures (`usage limit`, `rate[- ]?limit(ed|ing|s)?`,
# `try again (at|in)`, `401 unauthorized`, `403 forbidden`) are generic
# English and occur naturally inside the repositories RepoLens scans.
# When the agent succeeds (exit code 0) and quotes those phrases as part
# of a finding, the orchestrator used to misread it as an upstream
# rate-limit and wrote `.rate-limit-abort`, skipping every remaining lens.
#
# Contract (derived from the issue):
#   On a successful agent iteration (rc == 0) whose output echoes user
#   code containing bare rate-limit keywords (Laravel `usage_limit`
#   column, `// rate limit` comment, `Please try again in 30s.` error
#   string, `RateLimiter` class reference, `401 Unauthorized` in a
#   security finding), the orchestrator MUST:
#     * complete the run with exit code 0
#     * NOT emit `[ERROR] ... rate-limited / quota exceeded`
#     * NOT create the `.rate-limit-abort` sentinel file
#     * NOT mark any lens as `status: rate-limited`
#     * NOT set `summary.stopped_reason` to `rate-limited`
#
# The abort path for real rate-limits (rc != 0 + signature) stays covered
# by the existing tests/test_rate_limit_abort.sh suite.
#
# Strategy: stub a fake `codex` on PATH that prints a multi-line snippet
# mirroring the exact example from the issue body (Laravel migration with
# `$table->integer('usage_limit')` and a `// Overall usage limit of the
# voucher` comment), followed by DONE, and exits 0. Run repolens.sh in
# --local mode so no GitHub access is required. No real AI model is ever
# invoked (enforced by PATH override).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
TOTAL=0
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (expected='$expected' actual='$actual')"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (unexpected needle='$needle' found)"
  fi
}

echo "=== Orchestrator rate-limit false positive (issue #128) — integration ==="

# Minimal git project so repolens.sh passes its project-path validation.
PROJECT="$TMPDIR/project"
mkdir -p "$PROJECT"
(
  cd "$PROJECT"
  git init -q 2>/dev/null
  git config user.email test@example.com
  git config user.name Test
  echo "# test" > README.md
  git add README.md
  git commit -q -m init 2>/dev/null
) || true

# Fake agent: emits user-code snippets that hit bare rate-limit signatures
# (`usage limit`, `rate limit`, `try again in`, `401 Unauthorized`) and
# also emits DONE as the last word so the DONE-streak mechanism terminates
# the lens after the required number of iterations. Exits 0 to simulate a
# successful analysis — NOT an API error.
FAKE_BIN="$TMPDIR/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/codex" <<'SH'
#!/usr/bin/env bash
# Deliberately prints phrases that match _REPOLENS_RATE_LIMIT_PATTERNS
# verbatim, as a successful agent iteration would when quoting user code.
cat <<'MSG'
Analysis of database/migrations/2024_03_create_vouchers_table.php:

    $table->integer('usage_limit')->default(1); // Overall usage limit of the voucher

This column caps redemptions. The throttling logic enforces a
// rate limit on the vouchers API via Illuminate\Cache\RateLimiter.
The user-facing error message is "Please try again in 30s." which is
appropriate. 401 Unauthorized responses are correctly handled by the
auth middleware.

No critical issues found.

DONE
MSG
exit 0
SH
chmod +x "$FAKE_BIN/codex"

# PATH override: fake codex takes precedence. No real model runs.
export PATH="$FAKE_BIN:$PATH"

# Sanity-check: the PATH override points at the fake.
which_codex="$(command -v codex 2>/dev/null || true)"
assert_eq "Fake codex is first on PATH" "$FAKE_BIN/codex" "$which_codex"

# Run repolens.sh on a small 2-lens domain in --local mode. A false
# positive would abort after lens 1 and skip lens 2.
OUT_FILE="$TMPDIR/run.log"
set +e
bash "$SCRIPT_DIR/repolens.sh" \
  --project "$PROJECT" \
  --agent codex \
  --domain i18n \
  --mode audit \
  --local \
  --yes \
  >"$OUT_FILE" 2>&1
exit_code=$?
set -e

# Parse run_id so we can inspect the summary + sentinel directory.
run_id="$(grep -oE 'RepoLens run [^ ]+ starting' "$OUT_FILE" | head -1 | awk '{print $3}')"
if [[ -z "${run_id:-}" ]]; then
  echo "FAIL: could not parse run_id from repolens.sh output" >&2
  echo "---- run.log ----"
  cat "$OUT_FILE"
  echo "-----------------"
  exit 1
fi
summary_file="$SCRIPT_DIR/logs/$run_id/summary.json"
sentinel_file="$SCRIPT_DIR/logs/$run_id/.rate-limit-abort"

# Best-effort cleanup of the test run log directory on exit.
trap 'rm -rf "$TMPDIR" "$SCRIPT_DIR/logs/$run_id"' EXIT

# ----------------------------------------------------------------------
# Assertion 1: orchestrator exits 0 — the run completed successfully.
# A rate-limit false positive would exit non-zero (stopped_reason path).
# ----------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
if [[ "$exit_code" -eq 0 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: Orchestrator exits 0 on agent rc=0 + user-code keyword match"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: Expected exit 0, got $exit_code"
  echo "---- run.log ----"
  cat "$OUT_FILE"
  echo "-----------------"
fi

# ----------------------------------------------------------------------
# Assertion 2: no [ERROR] rate-limit line was logged.
# ----------------------------------------------------------------------
log_contents="$(cat "$OUT_FILE")"
assert_not_contains "Log does NOT report 'rate-limited / quota exceeded'" \
  "rate-limited / quota exceeded" "$log_contents"
assert_not_contains "Log does NOT report 'Aborting run'" \
  "Aborting run" "$log_contents"

# ----------------------------------------------------------------------
# Assertion 3: summary.json exists and is not marked rate-limited.
# ----------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
if [[ -f "$summary_file" ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: summary.json was created at $summary_file"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: summary.json missing (expected $summary_file)"
  echo "---- run.log ----"
  cat "$OUT_FILE"
  echo "-----------------"
  echo ""
  echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
  exit "$FAIL"
fi

stopped_reason="$(jq -r '.stopped_reason' "$summary_file")"
TOTAL=$((TOTAL + 1))
if [[ "$stopped_reason" != "rate-limited" ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: summary.stopped_reason != 'rate-limited' (got '$stopped_reason')"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: summary.stopped_reason is 'rate-limited' — false positive fired"
fi

rate_limited_count="$(jq '[.lenses[] | select(.status == "rate-limited")] | length' "$summary_file")"
assert_eq "No lens has status=rate-limited" "0" "$rate_limited_count"

skipped_count="$(jq '[.lenses[] | select(.status == "skipped")] | length' "$summary_file")"
assert_eq "No lens has status=skipped (sibling lenses still ran)" "0" "$skipped_count"

# ----------------------------------------------------------------------
# Assertion 4: `.rate-limit-abort` sentinel was NOT created.
# Its presence would also poison future --resume invocations.
# ----------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
if [[ ! -f "$sentinel_file" ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: .rate-limit-abort sentinel NOT created"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: .rate-limit-abort sentinel was incorrectly created at $sentinel_file"
fi

echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
exit "$FAIL"
