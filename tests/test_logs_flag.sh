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

# Tests for issue #129/#130/#139/#141/#144/#146/#148/#150/#151/#153: --logs path plumbing and logs domain lens registration.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/template.sh"

PASS=0
FAIL=0
TOTAL=0

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    Expected to contain: $needle"
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
    echo "  FAIL: $desc"
    echo "    Expected NOT to contain: $needle"
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    Expected: $expected"
    echo "    Actual:   $actual"
  fi
}

assert_exit_code() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" -eq "$actual" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    Expected exit code: $expected, got: $actual"
  fi
}

TMP_ROOT="$SCRIPT_DIR/logs/test-logs-flag.$$"
RUN_PREFIX="test-logs-flag-$$"
trap 'rm -rf "$TMP_ROOT" "$SCRIPT_DIR/logs/${RUN_PREFIX}"*' EXIT

FAKE_BIN="$TMP_ROOT/bin"
PROJECT_DIR="$TMP_ROOT/project"
LOG_DIR="$TMP_ROOT/runtime-logs"
LOG_FILE="$LOG_DIR/app.log"
mkdir -p "$FAKE_BIN" "$PROJECT_DIR" "$LOG_DIR"

cat > "$FAKE_BIN/claude" <<'EOF'
#!/usr/bin/env bash
echo "DONE"
EOF
chmod +x "$FAKE_BIN/claude"

git init -q "$PROJECT_DIR"
printf 'started\n' > "$LOG_FILE"

run_repolens() {
  local run_id="$1"
  shift
  PATH="$FAKE_BIN:$PATH" bash "$SCRIPT_DIR/repolens.sh" \
    --project "$PROJECT_DIR" \
    --agent claude \
    --local \
    --yes \
    --resume "$run_id" \
    "$@" 2>&1
}

echo ""
echo "=== Test Suite: --logs flag ==="
echo ""

echo "Test 1: Help documents --logs flag and example"
help_output="$(bash "$SCRIPT_DIR/repolens.sh" --help 2>&1)"
assert_contains "help includes --logs option" "--logs <path>" "$help_output"
assert_contains "help includes logs domain example" "--domain logs" "$help_output"

echo ""
echo "Test 2: Missing --logs argument fails with specific message"
missing_arg_output="$(PATH="$FAKE_BIN:$PATH" bash "$SCRIPT_DIR/repolens.sh" \
  --project "$PROJECT_DIR" \
  --agent claude \
  --local \
  --yes \
  --resume "${RUN_PREFIX}-missing-arg" \
  --logs 2>&1)"
missing_arg_rc=$?
assert_exit_code "missing argument exits nonzero" 1 "$missing_arg_rc"
assert_contains "missing argument message" "Option --logs requires a file or directory path argument." "$missing_arg_output"

echo ""
echo "Test 3: Missing logs path fails with specific message"
missing_path_output="$(run_repolens "${RUN_PREFIX}-missing-path" --logs "$TMP_ROOT/nope" --dry-run)"
missing_path_rc=$?
assert_exit_code "missing path exits nonzero" 1 "$missing_path_rc"
assert_contains "missing path message" "Logs path not found: $TMP_ROOT/nope" "$missing_path_output"

echo ""
echo "Test 4: Logs file path is accepted and logged as absolute"
file_output="$(run_repolens "${RUN_PREFIX}-file" --logs "$LOG_FILE" --domain i18n --dry-run)"
file_rc=$?
assert_exit_code "logs file dry-run exits zero" 0 "$file_rc"
assert_contains "logs file absolute path logged" "Logs: $LOG_FILE" "$file_output"
assert_contains "dry-run lists selected lenses" "i18n/i18n-strings" "$file_output"

echo ""
echo "Test 5: Logs directory path is accepted and logged as absolute"
dir_output="$(run_repolens "${RUN_PREFIX}-dir" --logs "$LOG_DIR" --domain i18n --dry-run)"
dir_rc=$?
assert_exit_code "logs directory dry-run exits zero" 0 "$dir_rc"
assert_contains "logs directory absolute path logged" "Logs: $LOG_DIR" "$dir_output"

echo ""
echo "Test 6: Logs domain dry-run includes registered logs lenses"
logs_dry_output="$(run_repolens "${RUN_PREFIX}-logs-dry" --domain logs --dry-run)"
logs_dry_rc=$?
assert_exit_code "logs domain dry-run exits zero" 0 "$logs_dry_rc"
assert_contains "logs dry-run shows fifteen lenses" "Lenses:       15" "$logs_dry_output"
assert_contains "logs dry-run lists error-storms" "logs/error-storms" "$logs_dry_output"
assert_contains "logs dry-run lists error-cascades" "logs/error-cascades" "$logs_dry_output"
assert_contains "logs dry-run lists retry-loops" "logs/retry-loops" "$logs_dry_output"
assert_contains "logs dry-run lists recursive-growth" "logs/recursive-growth" "$logs_dry_output"
assert_contains "logs dry-run lists resource-leaks" "logs/resource-leaks" "$logs_dry_output"
assert_contains "logs dry-run lists resource-exhaustion" "logs/resource-exhaustion" "$logs_dry_output"
assert_contains "logs dry-run lists log-gaps" "logs/log-gaps" "$logs_dry_output"
assert_contains "logs dry-run lists missing-heartbeats" "logs/missing-heartbeats" "$logs_dry_output"
assert_contains "logs dry-run lists silent-failures" "logs/silent-failures" "$logs_dry_output"
assert_contains "logs dry-run lists state-machine-violations" "logs/state-machine-violations" "$logs_dry_output"
assert_contains "logs dry-run lists lifecycle-violations" "logs/lifecycle-violations" "$logs_dry_output"
assert_contains "logs dry-run lists process-orphans" "logs/process-orphans" "$logs_dry_output"
assert_contains "logs dry-run lists latency-degradation" "logs/latency-degradation" "$logs_dry_output"
assert_contains "logs dry-run lists clock-skew" "logs/clock-skew" "$logs_dry_output"
assert_contains "logs dry-run lists timeout-clusters" "logs/timeout-clusters" "$logs_dry_output"
assert_contains "logs dry-run completes" "Dry run complete" "$logs_dry_output"

echo ""
echo "Test 7: Logs domain non-dry run executes registered lens"
logs_run_output="$(run_repolens "${RUN_PREFIX}-logs-run" --domain logs)"
logs_run_rc=$?
assert_exit_code "logs domain run exits zero" 0 "$logs_run_rc"
assert_not_contains "logs run is not treated as empty" "No lenses to run for domain 'logs'." "$logs_run_output"
assert_contains "logs run completes error-storms" "[logs/error-storms] DONE x3" "$logs_run_output"
assert_contains "logs run completes error-cascades" "[logs/error-cascades] DONE x3" "$logs_run_output"
assert_contains "logs run completes retry-loops" "[logs/retry-loops] DONE x3" "$logs_run_output"
assert_contains "logs run completes recursive-growth" "[logs/recursive-growth] DONE x3" "$logs_run_output"
assert_contains "logs run completes resource-leaks" "[logs/resource-leaks] DONE x3" "$logs_run_output"
assert_contains "logs run completes resource-exhaustion" "[logs/resource-exhaustion] DONE x3" "$logs_run_output"
assert_contains "logs run completes log-gaps" "[logs/log-gaps] DONE x3" "$logs_run_output"
assert_contains "logs run completes missing-heartbeats" "[logs/missing-heartbeats] DONE x3" "$logs_run_output"
assert_contains "logs run completes silent-failures" "[logs/silent-failures] DONE x3" "$logs_run_output"
assert_contains "logs run completes state-machine-violations" "[logs/state-machine-violations] DONE x3" "$logs_run_output"
assert_contains "logs run completes lifecycle-violations" "[logs/lifecycle-violations] DONE x3" "$logs_run_output"
assert_contains "logs run completes process-orphans" "[logs/process-orphans] DONE x3" "$logs_run_output"
assert_contains "logs run completes latency-degradation" "[logs/latency-degradation] DONE x3" "$logs_run_output"
assert_contains "logs run completes clock-skew" "[logs/clock-skew] DONE x3" "$logs_run_output"
assert_contains "logs run completes timeout-clusters" "[logs/timeout-clusters] DONE x3" "$logs_run_output"

echo ""
echo "Test 8: Invalid domain still fails"
invalid_domain_output="$(run_repolens "${RUN_PREFIX}-invalid-domain" --domain logz --dry-run)"
invalid_domain_rc=$?
assert_exit_code "invalid domain exits nonzero" 1 "$invalid_domain_rc"
assert_contains "invalid domain message" "Domain 'logz' not found in domains.json (mode: audit)" "$invalid_domain_output"

echo ""
echo "Test 9: Mode-hidden domain still fails"
hidden_domain_output="$(run_repolens "${RUN_PREFIX}-hidden-domain" --mode audit --domain discovery --dry-run)"
hidden_domain_rc=$?
assert_exit_code "mode-hidden domain exits nonzero" 1 "$hidden_domain_rc"
assert_contains "mode-hidden domain message" "Domain 'discovery' not found in domains.json (mode: audit)" "$hidden_domain_output"

echo ""
echo "Test 10: logs domain registry entry is valid"
logs_order="$(jq -r '.domains[] | select(.id == "logs") | .order' "$SCRIPT_DIR/config/domains.json")"
logs_lens_count="$(jq -r '.domains[] | select(.id == "logs") | .lenses | length' "$SCRIPT_DIR/config/domains.json")"
logs_mode="$(jq -r '.domains[] | select(.id == "logs") | .mode // "null"' "$SCRIPT_DIR/config/domains.json")"
duplicate_orders="$(jq -r '.domains[].order' "$SCRIPT_DIR/config/domains.json" | sort -n | uniq -d)"
assert_eq "logs domain order is 28" "28" "$logs_order"
assert_eq "logs domain has fifteen lenses" "15" "$logs_lens_count"
logs_lens_ids="$(jq -r '.domains[] | select(.id == "logs") | .lenses | join(",")' "$SCRIPT_DIR/config/domains.json")"
assert_eq "logs domain registers expected lenses" "error-storms,error-cascades,retry-loops,recursive-growth,resource-leaks,resource-exhaustion,log-gaps,missing-heartbeats,silent-failures,state-machine-violations,lifecycle-violations,process-orphans,latency-degradation,clock-skew,timeout-clusters" "$logs_lens_ids"
assert_eq "logs domain has no mode field" "null" "$logs_mode"
assert_eq "domain order values are unique" "" "$duplicate_orders"

echo ""
echo "Test 11: LOGS_PATH template variable substitutes only when supplied"
cat > "$TMP_ROOT/base.md" <<'EOF'
{{LENS_BODY}}
EOF
cat > "$TMP_ROOT/lens.md" <<'EOF'
---
id: logs-smoke
domain: logs
name: Logs Smoke
role: tester
---
## Your Expert Focus
LOGS={{LOGS_PATH}}
EOF
rendered_with_logs="$(compose_prompt "$TMP_ROOT/base.md" "$TMP_ROOT/lens.md" "LOGS_PATH=$LOG_FILE" "" "audit")"
rendered_without_logs="$(compose_prompt "$TMP_ROOT/base.md" "$TMP_ROOT/lens.md" "" "" "audit")"
assert_contains "LOGS_PATH is substituted when supplied" "LOGS=$LOG_FILE" "$rendered_with_logs"
assert_contains "LOGS_PATH remains literal when omitted" 'LOGS={{LOGS_PATH}}' "$rendered_without_logs"

echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
