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

# Issue #262: min-severity filtering of synthesizer manifest findings must be
# observable in the run log and summary.json.
# Issue #263: local markdown min-severity filtering must provide the same
# observability for dry-run/local paths.
# Issue #264: round digest markdown findings must provide the same
# observability when filtered by min severity.
# Issue #266: final stdout must report non-zero filtered finding counts.
# shellcheck disable=SC2329

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNTHESIZE_LIB="$SCRIPT_DIR/lib/synthesize.sh"
STREAK_LIB="$SCRIPT_DIR/lib/streak.sh"
TEMPLATE_LIB="$SCRIPT_DIR/lib/template.sh"
LOGGING_LIB="$SCRIPT_DIR/lib/logging.sh"
SUMMARY_LIB="$SCRIPT_DIR/lib/summary.sh"
CORE_LIB="$SCRIPT_DIR/lib/core.sh"
ROUNDS_LIB="$SCRIPT_DIR/lib/rounds.sh"

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

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected '$expected', got '$actual'"
  fi
}

assert_file_exists() {
  local desc="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$path" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected file $path"
  fi
}

assert_dir_exists() {
  local desc="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -d "$path" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected directory $path"
  fi
}

assert_file_matches() {
  local desc="$1" path="$2" regex="$3"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$path" ]] && grep -Eq "$regex" "$path"; then
    pass_with "$desc"
  else
    local detail="Missing regex '$regex'"
    if [[ -f "$path" ]]; then
      detail+=" in $(cat "$path")"
    else
      detail+=" because $path does not exist"
    fi
    fail_with "$desc" "$detail"
  fi
}

assert_file_not_matches() {
  local desc="$1" path="$2" regex="$3"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$path" ]] && ! grep -Eq "$regex" "$path"; then
    pass_with "$desc"
  else
    local detail="Unexpected regex '$regex'"
    if [[ -f "$path" ]]; then
      detail+=" in $(cat "$path")"
    else
      detail+=" because $path does not exist"
    fi
    fail_with "$desc" "$detail"
  fi
}

exact_line_count() {
  local path="$1" expected="$2"
  awk -v expected="$expected" '$0 == expected { count++ } END { print count + 0 }' "$path"
}

line_number_for() {
  local path="$1" needle="$2"
  awk -v needle="$needle" 'index($0, needle) { print NR; exit }' "$path"
}

line_number_for_exact() {
  local path="$1" expected="$2"
  awk -v expected="$expected" '$0 == expected { print NR; exit }' "$path"
}

assert_line_order() {
  local desc="$1" earlier="$2" later="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$earlier" =~ ^[0-9]+$ && "$later" =~ ^[0-9]+$ && "$earlier" -lt "$later" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected line $earlier before line $later"
  fi
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

if [[ ! -f "$SYNTHESIZE_LIB" ]]; then
  echo "  FAIL: lib/synthesize.sh missing at $SYNTHESIZE_LIB"
  exit 1
fi
if [[ ! -f "$STREAK_LIB" ]]; then
  echo "  FAIL: lib/streak.sh missing at $STREAK_LIB"
  exit 1
fi
if [[ ! -f "$ROUNDS_LIB" ]]; then
  echo "  FAIL: lib/rounds.sh missing at $ROUNDS_LIB"
  exit 1
fi

# shellcheck disable=SC1090
source "$TEMPLATE_LIB"
# shellcheck disable=SC1090
source "$LOGGING_LIB"
# shellcheck disable=SC1090
source "$SUMMARY_LIB"
# shellcheck disable=SC1090
source "$CORE_LIB"
# shellcheck disable=SC1090
source "$ROUNDS_LIB"
# shellcheck disable=SC1090
source "$SYNTHESIZE_LIB"
# shellcheck disable=SC1090
source "$STREAK_LIB"

TMP_PARENT="$SCRIPT_DIR/tests/logs/test-min-severity-observability"
mkdir -p "$TMP_PARENT"
TMPDIR="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"
RUN_LOG_DIR=""
zero_run_log_dir=""

cleanup() {
  if [[ -n "$RUN_LOG_DIR" ]]; then
    rm -rf "$RUN_LOG_DIR"
  fi
  if [[ -n "$zero_run_log_dir" ]]; then
    rm -rf "$zero_run_log_dir"
  fi
  rm -rf "$TMPDIR"
  rmdir "$TMP_PARENT" 2>/dev/null || true
  rmdir "$SCRIPT_DIR/tests/logs" 2>/dev/null || true
}
trap cleanup EXIT

echo "=== synthesizer manifest min-severity observability ==="

run_id="run-min-severity-observability"
RUN_LOG="$TMPDIR/$run_id"
PROJECT_PATH="$TMPDIR/project"
SUMMARY_FILE="$RUN_LOG/summary.json"
COMPOSE_LOG="$TMPDIR/compose.log"
AGENT_LOG="$TMPDIR/agent.log"

mkdir -p "$PROJECT_PATH"
mkdir -p "$RUN_LOG/rounds/round-1/lens-outputs/security"
printf 'raw finding fixture\n' > "$RUN_LOG/rounds/round-1/lens-outputs/security/injection.md"

export AGENT=codex
export PROJECT_PATH
export LOG_BASE="$RUN_LOG"
export SUMMARY_FILE
export MODE=bugreport
export REPOLENS_MODE=bugreport
# repolens.sh normalizes --min-severity high into this exported value before
# invoking the synthesizer path exercised by this fixture.
export REPOLENS_MIN_SEVERITY=high

init_logging "$run_id" "$RUN_LOG"
init_summary "$SUMMARY_FILE" "$run_id" "$PROJECT_PATH" "bugreport" "$AGENT" "" "" "local" "$TMPDIR/out"

compose_prompt() {
  echo "$3" >> "$COMPOSE_LOG"
  printf 'STUBBED SYNTHESIZER PROMPT'
}

run_agent() {
  echo "fake-agent-call" >> "$AGENT_LOG"
  cat <<'JSON'
[
  {
    "cluster_id": "high::kept",
    "title": "[high] Kept high",
    "severity": "high",
    "domain": "security",
    "lens": "injection",
    "root_cause_category": "injection",
    "source_finding_paths": ["logs/run-min-severity-observability/rounds/round-1/lens-outputs/security/injection.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["security"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "body"
  },
  {
    "cluster_id": "low::dropped",
    "title": "[low] Dropped low",
    "severity": "low",
    "domain": "security",
    "lens": "injection",
    "root_cause_category": "injection",
    "source_finding_paths": ["logs/run-min-severity-observability/rounds/round-1/lens-outputs/security/injection.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["security"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "body"
  },
  {
    "cluster_id": "medium::dropped",
    "title": "[medium] Dropped medium",
    "severity": "medium",
    "domain": "docs",
    "lens": "readme-quality",
    "root_cause_category": "docs-drift",
    "source_finding_paths": ["logs/run-min-severity-observability/rounds/round-1/lens-outputs/security/injection.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["docs"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "body"
  },
  {
    "cluster_id": "missing::dropped",
    "title": "[HIGH] Missing severity",
    "domain": "code",
    "lens": "input-validation",
    "root_cause_category": "missing-validation",
    "source_finding_paths": ["logs/run-min-severity-observability/rounds/round-1/lens-outputs/security/injection.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["bug"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "body"
  },
  {
    "cluster_id": "urgent::dropped",
    "title": "[urgent] Unknown severity",
    "severity": "urgent",
    "domain": "security",
    "lens": "crypto",
    "root_cause_category": "crypto",
    "source_finding_paths": ["logs/run-min-severity-observability/rounds/round-1/lens-outputs/security/injection.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["security"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "body"
  }
]
DONE
JSON
}

: > "$COMPOSE_LOG"
: > "$AGENT_LOG"

run_synthesizer "$run_id" >"$TMPDIR/run.out" 2>"$TMPDIR/run.err"
status=$?

summary_file="$SUMMARY_FILE"
unset REPOLENS_MIN_SEVERITY REPOLENS_MODE MODE LOG_BASE SUMMARY_FILE PROJECT_PATH AGENT

log_file="$RUN_LOG/$run_id.log"
manifest="$RUN_LOG/final/manifest.json"
manifest_ids="$(jq -r 'map(.cluster_id) | join(",")' "$manifest" 2>/dev/null || true)"
filtered_count="$(jq -r '.totals.findings_filtered // "missing"' "$summary_file" 2>/dev/null || true)"
agent_calls="$(wc -l < "$AGENT_LOG" | tr -d ' ')"
compose_calls="$(wc -l < "$COMPOSE_LOG" | tr -d ' ')"

assert_success "fake-agent synthesizer run succeeds with min severity high" "$status"
assert_eq "fake agent is invoked exactly once" "1" "$agent_calls"
assert_eq "synthesizer prompt is composed exactly once" "1" "$compose_calls"
assert_file_exists "filtered manifest is promoted" "$manifest"
assert_eq "only high-or-above manifest findings remain" "high::kept" "$manifest_ids"

assert_file_matches "low drop info log has security/injection attribution" "$log_file" '\[INFO\].*\[security/injection\] Dropped finding "\[low\] Dropped low" \(severity=low < min=high\)'
assert_file_matches "medium drop info log has docs/readme-quality attribution" "$log_file" '\[INFO\].*\[docs/readme-quality\] Dropped finding "\[medium\] Dropped medium" \(severity=medium < min=high\)'
assert_file_matches "missing severity warning has code/input-validation attribution" "$log_file" '\[WARN\].*\[code/input-validation\] Finding "\[HIGH\] Missing severity" has invalid severity: "" \(expected critical, high, medium, or low\) - skipping'
assert_file_matches "unknown severity warning has security/crypto attribution" "$log_file" '\[WARN\].*\[security/crypto\] Finding "\[urgent\] Unknown severity" has invalid severity: "urgent" \(expected critical, high, medium, or low\) - skipping'

assert_eq "summary counts every filtered synthesizer finding" "4" "$filtered_count"

echo ""
echo "=== round digest min-severity observability ==="

round_run_id="run-round-digest-min-severity-observability"
round_log_dir="$TMPDIR/$round_run_id"
round_project="$TMPDIR/round-project"
round_summary="$round_log_dir/summary.json"
round_output="$TMPDIR/round-output"
round_dir="$round_log_dir/rounds/round-1"
mkdir -p "$round_project" "$round_output" \
  "$round_dir/lens-outputs/security/injection" \
  "$round_dir/lens-outputs/code-quality/naming" \
  "$round_dir/lens-outputs/code-quality/complexity" \
  "$round_dir/lens-outputs/observability/structured-logging"

cat > "$round_dir/lens-outputs/security/injection/001-kept-high.md" <<'MD'
---
title: "[HIGH] Round kept high"
severity: high
domain: security
lens: injection
root_cause_category: round-kept-high
suspect_files:
  - src/round-kept-high.sh
---

## Hypothesis
Round kept high digest hypothesis.
MD

cat > "$round_dir/lens-outputs/security/injection/002-dropped-low.md" <<'MD'
---
title: "[LOW] Round dropped low"
severity: low
domain: security
lens: injection
root_cause_category: round-dropped-low
suspect_files:
  - src/round-dropped-low.sh
---

## Hypothesis
Round dropped low digest hypothesis.
MD

cat > "$round_dir/lens-outputs/code-quality/naming/003-dropped-medium.md" <<'MD'
---
title: "[MEDIUM] Round dropped medium"
severity: medium
domain: code-quality
lens: naming
root_cause_category: round-dropped-medium
suspect_files:
  - src/round-dropped-medium.sh
---

## Hypothesis
Round dropped medium digest hypothesis.
MD

cat > "$round_dir/lens-outputs/code-quality/complexity/004-missing-severity.md" <<'MD'
---
title: "[HIGH] Round missing severity"
domain: code-quality
lens: complexity
root_cause_category: round-missing-severity
suspect_files:
  - src/round-missing-severity.sh
---

## Hypothesis
Round missing severity digest hypothesis.
MD

cat > "$round_dir/lens-outputs/observability/structured-logging/005-unknown-severity.md" <<'MD'
---
title: "[URGENT] Round unknown severity"
severity: urgent
domain: observability
lens: structured-logging
root_cause_category: round-unknown-severity
suspect_files:
  - src/round-unknown-severity.sh
---

## Hypothesis
Round unknown severity digest hypothesis.
MD

export PROJECT_PATH="$round_project"
export LOG_BASE="$round_log_dir"
export SUMMARY_FILE="$round_summary"
export AGENT=codex
export MODE=bugreport
export REPOLENS_MODE=bugreport
# repolens.sh normalizes --min-severity high into this exported value before
# invoking the round digest path exercised by this fixture.
export REPOLENS_MIN_SEVERITY=high

init_logging "$round_run_id" "$round_log_dir"
init_summary "$round_summary" "$round_run_id" "$round_project" "bugreport" "$AGENT" "" "" "local" "$round_output"

build_round_digest "$round_dir" >"$TMPDIR/round-digest.out" 2>"$TMPDIR/round-digest.err"
round_digest_status=$?

round_log_file="$round_log_dir/$round_run_id.log"
round_digest="$round_dir/digest.md"
round_filtered_count="$(jq -r '.totals.findings_filtered // "missing"' "$round_summary" 2>/dev/null || true)"

unset REPOLENS_MIN_SEVERITY REPOLENS_MODE MODE LOG_BASE SUMMARY_FILE PROJECT_PATH AGENT

assert_success "round digest build succeeds with min severity high" "$round_digest_status"
assert_file_exists "round digest markdown is written" "$round_digest"
assert_file_matches "round digest keeps the high finding" "$round_digest" 'round-kept-high'
assert_file_not_matches "round digest drops the low finding" "$round_digest" 'round-dropped-low'
assert_file_not_matches "round digest drops the medium finding" "$round_digest" 'round-dropped-medium'
assert_file_not_matches "round digest drops the missing-severity finding" "$round_digest" 'round-missing-severity'
assert_file_not_matches "round digest drops the unknown-severity finding" "$round_digest" 'round-unknown-severity'

assert_file_matches "low round digest drop info log has security/injection attribution" "$round_log_file" '\[INFO\].*\[security/injection\] Dropped finding "\[LOW\] Round dropped low" \(severity=low < min=high\)'
assert_file_matches "medium round digest drop info log has code-quality/naming attribution" "$round_log_file" '\[INFO\].*\[code-quality/naming\] Dropped finding "\[MEDIUM\] Round dropped medium" \(severity=medium < min=high\)'
assert_file_matches "missing severity round digest warning has code-quality/complexity attribution" "$round_log_file" '\[WARN\].*\[code-quality/complexity\] Finding "\[HIGH\] Round missing severity" has invalid severity: "" \(expected critical, high, medium, or low\) - skipping'
assert_file_matches "unknown severity round digest warning has observability/structured-logging attribution" "$round_log_file" '\[WARN\].*\[observability/structured-logging\] Finding "\[URGENT\] Round unknown severity" has invalid severity: "urgent" \(expected critical, high, medium, or low\) - skipping'
assert_eq "summary counts every filtered round digest finding" "4" "$round_filtered_count"

echo ""
echo "=== local markdown min-severity observability ==="

PROJECT_DIR="$TMPDIR/local-project"
FAKE_BIN="$TMPDIR/local-bin"
LOCAL_AGENT_LOG="$TMPDIR/local-agent.log"
BUG_FILE="$TMPDIR/bug-report.md"
mkdir -p "$PROJECT_DIR" "$FAKE_BIN"
git -C "$PROJECT_DIR" init -q
printf '# RepoLens local markdown observability fixture\n' > "$PROJECT_DIR/README.md"
git -C "$PROJECT_DIR" add README.md
git -C "$PROJECT_DIR" -c user.name='RepoLens Test' -c user.email='repolens@example.invalid' commit -q -m 'fixture'

cat > "$BUG_FILE" <<'EOF'
The README fixture describes an injection-shaped bug. Use the focused security
lens and write findings locally so the min-severity filter can be observed.
EOF

cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

prompt="${!#}"
output_dir="$(printf '%s\n' "$prompt" | sed -n 's/^Write all findings to: `\(.*\)`$/\1/p' | sed -n '1p')"

if [[ -n "${REPOLENS_LOCAL_OBSERVABILITY_AGENT_LOG:-}" ]]; then
  printf 'lens\n' >> "$REPOLENS_LOCAL_OBSERVABILITY_AGENT_LOG"
fi

if [[ -z "$output_dir" ]]; then
  printf 'DONE\nNo local output directory was rendered.\nDONE\n'
  exit 0
fi

mkdir -p "$output_dir"

cat > "$output_dir/001-kept-high.md" <<'MD'
---
title: "[HIGH] Kept high"
severity: high
domain: security
lens: injection
labels:
  - "bugreport:security/injection"
root_cause_category: fixture-kept
---

## Summary
High-severity local markdown finding kept by the threshold.
MD

if [[ "${REPOLENS_LOCAL_OBSERVABILITY_FIXTURE:-filtered}" == "kept-only" ]]; then
  printf 'DONE\nWrote local markdown no-filter observability fixture finding.\nDONE\n'
  exit 0
fi

cat > "$output_dir/002-dropped-low.md" <<'MD'
---
title: "[LOW] Dropped low"
severity: low
domain: security
lens: injection
labels:
  - "bugreport:security/injection"
root_cause_category: fixture-filtered
---

## Summary
Low-severity local markdown finding filtered below the high threshold.
MD

cat > "$output_dir/003-dropped-medium.md" <<'MD'
---
title: "[MEDIUM] Dropped medium"
severity: medium
domain: code-quality
lens: naming
labels:
  - "bugreport:code-quality/naming"
root_cause_category: fixture-filtered
---

## Summary
Medium-severity local markdown finding filtered below the high threshold.
MD

cat > "$output_dir/004-missing-severity.md" <<'MD'
---
title: "[HIGH] Missing severity"
domain: code-quality
lens: complexity
labels:
  - "bugreport:code-quality/complexity"
root_cause_category: fixture-invalid
---

## Summary
Local markdown finding with missing severity metadata.
MD

cat > "$output_dir/005-unknown-severity.md" <<'MD'
---
title: "[URGENT] Unknown severity"
severity: urgent
domain: security
lens: cryptography
labels:
  - "bugreport:security/cryptography"
root_cause_category: fixture-invalid
---

## Summary
Local markdown finding with unknown severity metadata.
MD

printf 'DONE\nWrote local markdown min-severity observability fixture findings.\nDONE\n'
EOF
chmod +x "$FAKE_BIN/codex"
: > "$LOCAL_AGENT_LOG"

local_run_output="$TMPDIR/local-repolens-output.txt"
PATH="$FAKE_BIN:$PATH" \
  REPOLENS_AGENT_TIMEOUT=10 \
  REPOLENS_AGENT_KILL_GRACE=1 \
  REPOLENS_LOCAL_OBSERVABILITY_AGENT_LOG="$LOCAL_AGENT_LOG" \
  bash "$SCRIPT_DIR/repolens.sh" \
    --project "$PROJECT_DIR" \
    --agent codex \
    --local \
    --mode bugreport \
    --bug-report "$BUG_FILE" \
    --focus injection \
    --rounds 1 \
    --depth 1 \
    --no-triage \
    --no-verifier \
    --yes \
    --min-severity high \
    >"$local_run_output" 2>&1
local_run_status=$?

local_run_id="$(sed -n 's/.*RepoLens run \([^ ]*\) complete.*/\1/p' "$local_run_output" | tail -1)"
if [[ -n "$local_run_id" ]]; then
  RUN_LOG_DIR="$SCRIPT_DIR/logs/$local_run_id"
fi

local_log_file="$TMPDIR/missing-local-run.log"
local_summary_file="$TMPDIR/missing-local-summary.json"
local_output_dir="$TMPDIR/missing-local-output"
if [[ -n "$RUN_LOG_DIR" ]]; then
  local_log_file="$RUN_LOG_DIR/$local_run_id.log"
  local_summary_file="$RUN_LOG_DIR/summary.json"
fi
if [[ -f "$local_summary_file" ]]; then
  local_output_dir="$(jq -r '.output_dir // empty' "$local_summary_file" 2>/dev/null || true)"
fi
[[ -n "$local_output_dir" ]] || local_output_dir="$TMPDIR/missing-local-output"

local_agent_calls="$(wc -l < "$LOCAL_AGENT_LOG" | tr -d ' ')"
local_filtered_count="$(jq -r '.totals.findings_filtered // "missing"' "$local_summary_file" 2>/dev/null || true)"
local_issues_count="$(jq -r '.totals.issues_created // "missing"' "$local_summary_file" 2>/dev/null || true)"
expected_local_filtered_count="4"
local_filtered_stdout_line="Findings filtered by --min-severity: $expected_local_filtered_count"
local_filtered_stdout_count="$(exact_line_count "$local_run_output" "$local_filtered_stdout_line")"
local_summary_finalized_line="$(line_number_for "$local_run_output" "Summary: $local_summary_file")"
local_filtered_stdout_line_number="$(line_number_for_exact "$local_run_output" "$local_filtered_stdout_line")"
local_final_json_header_line="$(line_number_for_exact "$local_run_output" "=== RepoLens Run Summary ===")"

assert_success "fake-agent local markdown run succeeds with min severity high" "$local_run_status"
assert_eq "local run id is discoverable" "set" "$([[ -n "$local_run_id" ]] && printf 'set' || printf 'missing')"
assert_eq "fake local agent is invoked exactly once" "1" "$local_agent_calls"
assert_dir_exists "local output directory is recorded in summary" "$local_output_dir"
assert_file_exists "kept high local markdown finding is written" "$local_output_dir/security/injection/001-kept-high.md"
assert_eq "local dry-run count records only the high finding as created" "1" "$local_issues_count"

assert_file_matches "low local markdown drop info log has security/injection attribution" "$local_log_file" '\[INFO\].*\[security/injection\] Dropped finding "\[LOW\] Dropped low" \(severity=low < min=high\)'
assert_file_matches "medium local markdown drop info log has code-quality/naming attribution" "$local_log_file" '\[INFO\].*\[code-quality/naming\] Dropped finding "\[MEDIUM\] Dropped medium" \(severity=medium < min=high\)'
assert_file_matches "missing severity local markdown warning has code-quality/complexity attribution" "$local_log_file" '\[WARN\].*\[code-quality/complexity\] Finding "\[HIGH\] Missing severity" has invalid severity: "" \(expected critical, high, medium, or low\) - skipping'
assert_file_matches "unknown severity local markdown warning has security/cryptography attribution" "$local_log_file" '\[WARN\].*\[security/cryptography\] Finding "\[URGENT\] Unknown severity" has invalid severity: "urgent" \(expected critical, high, medium, or low\) - skipping'
assert_eq "summary counts every filtered local markdown finding" "$expected_local_filtered_count" "$local_filtered_count"
assert_eq "final stdout reports the filtered local markdown count once" "1" "$local_filtered_stdout_count"
assert_line_order "filtered stdout appears after summary finalization output" "$local_summary_finalized_line" "$local_filtered_stdout_line_number"
assert_line_order "filtered stdout appears before final JSON dump" "$local_filtered_stdout_line_number" "$local_final_json_header_line"

echo ""
echo "=== final stdout omits zero filtered count ==="

zero_agent_log="$TMPDIR/local-zero-agent.log"
: > "$zero_agent_log"
zero_run_output="$TMPDIR/local-zero-repolens-output.txt"
PATH="$FAKE_BIN:$PATH" \
  REPOLENS_AGENT_TIMEOUT=10 \
  REPOLENS_AGENT_KILL_GRACE=1 \
  REPOLENS_LOCAL_OBSERVABILITY_AGENT_LOG="$zero_agent_log" \
  REPOLENS_LOCAL_OBSERVABILITY_FIXTURE=kept-only \
  bash "$SCRIPT_DIR/repolens.sh" \
    --project "$PROJECT_DIR" \
    --agent codex \
    --local \
    --mode bugreport \
    --bug-report "$BUG_FILE" \
    --focus injection \
    --rounds 1 \
    --depth 1 \
    --no-triage \
    --no-verifier \
    --yes \
    --min-severity high \
    >"$zero_run_output" 2>&1
zero_run_status=$?

zero_run_id="$(sed -n 's/.*RepoLens run \([^ ]*\) complete.*/\1/p' "$zero_run_output" | tail -1)"
if [[ -n "$zero_run_id" ]]; then
  zero_run_log_dir="$SCRIPT_DIR/logs/$zero_run_id"
fi

zero_summary_file="$TMPDIR/missing-zero-summary.json"
if [[ -n "$zero_run_log_dir" ]]; then
  zero_summary_file="$zero_run_log_dir/summary.json"
fi

zero_agent_calls="$(wc -l < "$zero_agent_log" | tr -d ' ')"
zero_filtered_count="$(jq -r '.totals.findings_filtered // "missing"' "$zero_summary_file" 2>/dev/null || true)"
zero_issues_count="$(jq -r '.totals.issues_created // "missing"' "$zero_summary_file" 2>/dev/null || true)"

assert_success "fake-agent kept-only local run succeeds with min severity high" "$zero_run_status"
assert_eq "kept-only local run id is discoverable" "set" "$([[ -n "$zero_run_id" ]] && printf 'set' || printf 'missing')"
assert_eq "fake kept-only local agent is invoked exactly once" "1" "$zero_agent_calls"
assert_eq "kept-only local dry-run count records the high finding" "1" "$zero_issues_count"
assert_eq "summary records zero filtered local markdown findings" "0" "$zero_filtered_count"
assert_file_not_matches "final stdout omits filtered count when no findings are filtered" "$zero_run_output" '^Findings filtered by --min-severity:'

echo ""
echo "=== local markdown filtered summary dedupe ==="

dedupe_run_id="run-local-filtered-dedupe"
dedupe_log_dir="$TMPDIR/$dedupe_run_id"
dedupe_project="$TMPDIR/dedupe-project"
dedupe_output="$TMPDIR/dedupe-output"
dedupe_summary="$dedupe_log_dir/summary.json"
mkdir -p "$dedupe_log_dir" "$dedupe_project" "$dedupe_output"

cat > "$dedupe_output/001-kept-high.md" <<'MD'
---
title: "[HIGH] Counted once"
severity: high
domain: security
lens: injection
---

## Summary
Kept finding.
MD

cat > "$dedupe_output/002-dropped-low.md" <<'MD'
---
title: "[LOW] Filtered once"
severity: low
domain: security
lens: injection
---

## Summary
Below-threshold finding.
MD

cat > "$dedupe_output/003-unknown-severity.md" <<'MD'
---
title: "[URGENT] Filtered invalid once"
severity: urgent
domain: security
lens: cryptography
---

## Summary
Invalid-severity finding.
MD

export PROJECT_PATH="$dedupe_project"
export LOG_BASE="$dedupe_log_dir"
export SUMMARY_FILE="$dedupe_summary"
export AGENT=codex
export MODE=bugreport
export REPOLENS_MODE=bugreport
export REPOLENS_MIN_SEVERITY=high

init_logging "$dedupe_run_id" "$dedupe_log_dir"
init_summary "$dedupe_summary" "$dedupe_run_id" "$dedupe_project" "bugreport" "$AGENT" "" "" "local" "$dedupe_output"

dedupe_first_count="$(count_dry_run_issues "$dedupe_output" 2>"$TMPDIR/dedupe-first.err")"
dedupe_first_status=$?
dedupe_after_first="$(jq -r '.totals.findings_filtered // "missing"' "$dedupe_summary" 2>/dev/null || true)"
dedupe_second_count="$(count_dry_run_issues "$dedupe_output" 2>"$TMPDIR/dedupe-second.err")"
dedupe_second_status=$?
dedupe_after_second="$(jq -r '.totals.findings_filtered // "missing"' "$dedupe_summary" 2>/dev/null || true)"

unset REPOLENS_MIN_SEVERITY REPOLENS_MODE MODE LOG_BASE SUMMARY_FILE PROJECT_PATH AGENT

assert_success "direct local markdown first count succeeds" "$dedupe_first_status"
assert_eq "direct local markdown first count keeps only high finding" "1" "$dedupe_first_count"
assert_eq "direct local markdown first scan records two filtered findings" "2" "$dedupe_after_first"
assert_success "direct local markdown repeated count succeeds" "$dedupe_second_status"
assert_eq "direct local markdown repeated count still keeps only high finding" "1" "$dedupe_second_count"
assert_eq "direct local markdown repeated scan does not double-count filtered findings" "2" "$dedupe_after_second"

echo ""
echo "=== round digest filtered summary dedupe ==="

round_dedupe_run_id="run-round-filtered-dedupe"
round_dedupe_log_dir="$TMPDIR/$round_dedupe_run_id"
round_dedupe_project="$TMPDIR/round-dedupe-project"
round_dedupe_output="$TMPDIR/round-dedupe-output"
round_dedupe_summary="$round_dedupe_log_dir/summary.json"
round_dedupe_dir="$round_dedupe_log_dir/rounds/round-1"
round_dedupe_lens_outputs="$round_dedupe_dir/lens-outputs"
mkdir -p "$round_dedupe_log_dir" "$round_dedupe_project" "$round_dedupe_output" "$round_dedupe_lens_outputs"

cat > "$round_dedupe_lens_outputs/001-kept-high.md" <<'MD'
---
title: "[HIGH] Shared counted high"
severity: high
domain: security
lens: injection
root_cause_category: shared-kept
suspect_files:
  - src/shared-kept.sh
---

## Summary
Kept shared finding.
MD

cat > "$round_dedupe_lens_outputs/002-dropped-low.md" <<'MD'
---
title: "[LOW] Shared filtered low"
severity: low
domain: security
lens: injection
root_cause_category: shared-low
suspect_files:
  - src/shared-low.sh
---

## Summary
Below-threshold shared finding.
MD

cat > "$round_dedupe_lens_outputs/003-unknown-severity.md" <<'MD'
---
title: "[URGENT] Shared filtered invalid"
severity: urgent
domain: security
lens: injection
root_cause_category: shared-invalid
suspect_files:
  - src/shared-invalid.sh
---

## Summary
Invalid-severity shared finding.
MD

export PROJECT_PATH="$round_dedupe_project"
export LOG_BASE="$round_dedupe_log_dir"
export SUMMARY_FILE="$round_dedupe_summary"
export AGENT=codex
export MODE=bugreport
export REPOLENS_MODE=bugreport
export REPOLENS_MIN_SEVERITY=high

init_logging "$round_dedupe_run_id" "$round_dedupe_log_dir"
init_summary "$round_dedupe_summary" "$round_dedupe_run_id" "$round_dedupe_project" "bugreport" "$AGENT" "" "" "local" "$round_dedupe_output"

round_dedupe_local_count="$(count_dry_run_issues "$round_dedupe_lens_outputs" 2>"$TMPDIR/round-dedupe-local.err")"
round_dedupe_local_status=$?
round_dedupe_after_local="$(jq -r '.totals.findings_filtered // "missing"' "$round_dedupe_summary" 2>/dev/null || true)"
build_round_digest "$round_dedupe_dir" >"$TMPDIR/round-dedupe-digest.out" 2>"$TMPDIR/round-dedupe-digest.err"
round_dedupe_digest_status=$?
round_dedupe_after_digest="$(jq -r '.totals.findings_filtered // "missing"' "$round_dedupe_summary" 2>/dev/null || true)"

unset REPOLENS_MIN_SEVERITY REPOLENS_MODE MODE LOG_BASE SUMMARY_FILE PROJECT_PATH AGENT

assert_success "shared local markdown count succeeds" "$round_dedupe_local_status"
assert_eq "shared local markdown count keeps only high finding" "1" "$round_dedupe_local_count"
assert_eq "shared local markdown scan records two filtered findings" "2" "$round_dedupe_after_local"
assert_success "shared round digest build succeeds" "$round_dedupe_digest_status"
assert_eq "shared round digest build does not double-count filtered findings" "2" "$round_dedupe_after_digest"

echo ""
echo "=== local markdown missing attribution fallback ==="

fallback_run_id="run-local-filtered-unknown-attribution"
fallback_log_dir="$TMPDIR/$fallback_run_id"
fallback_project="$TMPDIR/fallback-project"
fallback_output="$TMPDIR/fallback-output"
fallback_summary="$fallback_log_dir/summary.json"
mkdir -p "$fallback_log_dir" "$fallback_project" "$fallback_output"

cat > "$fallback_output/001-low-no-attribution.md" <<'MD'
---
title: "[LOW] Missing attribution low"
severity: low
---

## Summary
Below-threshold finding without domain or lens frontmatter.
MD

cat > "$fallback_output/002-urgent-no-attribution.md" <<'MD'
---
title: "[URGENT] Missing attribution unknown"
severity: urgent
---

## Summary
Invalid-severity finding without domain or lens frontmatter.
MD

export PROJECT_PATH="$fallback_project"
export LOG_BASE="$fallback_log_dir"
export SUMMARY_FILE="$fallback_summary"
export AGENT=codex
export MODE=bugreport
export REPOLENS_MODE=bugreport
export REPOLENS_MIN_SEVERITY=high

init_logging "$fallback_run_id" "$fallback_log_dir"
init_summary "$fallback_summary" "$fallback_run_id" "$fallback_project" "bugreport" "$AGENT" "" "" "local" "$fallback_output"

fallback_count="$(count_dry_run_issues "$fallback_output" 2>"$TMPDIR/fallback.err")"
fallback_status=$?
fallback_filtered_count="$(jq -r '.totals.findings_filtered // "missing"' "$fallback_summary" 2>/dev/null || true)"
fallback_log_file="$fallback_log_dir/$fallback_run_id.log"

unset REPOLENS_MIN_SEVERITY REPOLENS_MODE MODE LOG_BASE SUMMARY_FILE PROJECT_PATH AGENT

assert_success "missing-attribution local markdown count succeeds" "$fallback_status"
assert_eq "missing-attribution local markdown count drops both findings" "0" "$fallback_count"
assert_file_matches "missing-attribution low drop uses unknown fallback" "$fallback_log_file" '\[INFO\].*\[<unknown>/<unknown>\] Dropped finding "\[LOW\] Missing attribution low" \(severity=low < min=high\)'
assert_file_matches "missing-attribution invalid warning uses unknown fallback" "$fallback_log_file" '\[WARN\].*\[<unknown>/<unknown>\] Finding "\[URGENT\] Missing attribution unknown" has invalid severity: "urgent" \(expected critical, high, medium, or low\) - skipping'
assert_eq "missing-attribution filtered findings are counted" "2" "$fallback_filtered_count"

direct_summary="$TMPDIR/direct-summary.json"
missing_summary="$TMPDIR/missing-summary.json"
init_summary "$direct_summary" "direct-summary" "$TMPDIR/project" "bugreport" "codex" "" "" "local" "$TMPDIR/out"
initial_direct_count="$(jq -r '.totals.findings_filtered // "missing"' "$direct_summary")"
increment_findings_filtered "$direct_summary"
single_increment_status=$?
increment_findings_filtered "$direct_summary" 3
bulk_increment_status=$?
direct_count="$(jq -r '.totals.findings_filtered // "missing"' "$direct_summary")"
increment_findings_filtered "$direct_summary" "not-a-number"
invalid_increment_status=$?
direct_count_after_invalid="$(jq -r '.totals.findings_filtered // "missing"' "$direct_summary")"
increment_findings_filtered "$missing_summary" 2
missing_increment_status=$?
missing_summary_state="missing"
if [[ -e "$missing_summary" ]]; then
  missing_summary_state="present"
fi

assert_eq "summary helper initializes filtered count" "0" "$initial_direct_count"
assert_success "summary helper increments default count" "$single_increment_status"
assert_success "summary helper increments explicit count" "$bulk_increment_status"
assert_eq "summary helper accumulates filtered counts" "4" "$direct_count"
assert_success "summary helper ignores invalid counts" "$invalid_increment_status"
assert_eq "summary helper leaves count unchanged for invalid input" "4" "$direct_count_after_invalid"
assert_success "summary helper treats missing files as no-op" "$missing_increment_status"
assert_eq "summary helper does not create missing files" "missing" "$missing_summary_state"

finish
