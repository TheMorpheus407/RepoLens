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

# Issue #250 — log_info / log_warn / log_error must not fork date(1).
#
# Approach: shadow the `date` command with a counter stub via a PATH-first
# directory. After N log calls, the stub must have been invoked zero times.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
TOTAL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    expected: $expected"
    echo "    actual:   $actual"
  fi
}

assert_matches() {
  local desc="$1" pattern="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if grep -qE "$pattern" <<< "$haystack"; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    expected pattern: $pattern"
    echo "    actual:           $haystack"
  fi
}

echo ""
echo "=== Test Suite: logging — no date(1) fork (issue #250) ==="
echo ""

# Build an isolated workspace with a `date` stub that tallies invocations.
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

stubdir="$workdir/stub"
mkdir -p "$stubdir"
counter_file="$workdir/date.count"
: > "$counter_file"

cat > "$stubdir/date" <<EOF
#!/usr/bin/env bash
# date(1) stub: append a line to "$counter_file" per call, then forward
# to the real binary so callers that genuinely need a timestamp still work.
printf 'called\n' >> "$counter_file"
for real in /usr/bin/date /bin/date; do
  if [[ -x "\$real" ]]; then exec "\$real" "\$@"; fi
done
exec date "\$@"
EOF
chmod +x "$stubdir/date"

# Run the log calls in a subshell so PATH manipulation doesn't leak.
(
  PATH="$stubdir:$PATH"
  export PATH
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/logging.sh"
  init_logging "test-run" "$workdir/logs"
  for ((i = 0; i < 100; i++)); do
    log_info "hello $i"
    log_warn "warning $i"
    log_error "error $i"
  done
) > "$workdir/stdout.txt" 2> "$workdir/stderr.txt"

call_count=$(wc -l < "$counter_file" | tr -d ' ')

echo "Test 1: log_info / log_warn / log_error perform zero date(1) forks"
assert_eq "date(1) fork count after 300 log calls" "0" "$call_count"

echo ""
echo "Test 2: log file received all 300 entries"
log_file="$workdir/logs/test-run.log"
TOTAL=$((TOTAL + 1))
if [[ -f "$log_file" ]]; then
  entries=$(wc -l < "$log_file" | tr -d ' ')
  if [[ "$entries" == "300" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: log file has 300 entries"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: log file has $entries entries (expected 300)"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: log file $log_file missing"
fi

echo ""
echo "Test 3: timestamps are ISO-8601 UTC (Z suffix)"
# Sample one log line and confirm the timestamp format
sample="$(head -1 "$log_file" 2>/dev/null || true)"
assert_matches "first log line carries [INFO] tag" "^\[INFO\] " "$sample"
assert_matches "timestamp matches YYYY-MM-DDTHH:MM:SSZ" \
  "\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\]" "$sample"

echo ""
echo "Test 4: _log_ts_var writes a UTC ISO-8601 timestamp to its target var"
ts_var_output="$(
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/logging.sh"
  ts=""
  _log_ts_var ts
  printf '%s' "$ts"
)"
assert_matches "_log_ts_var output format" \
  "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$" "$ts_var_output"

echo ""
echo "Test 5: _log_ts_var output equals current UTC (within 5s)"
expected_now="$(TZ=UTC0 date +%Y-%m-%dT%H:%M:%SZ)"
expected_epoch=$(date -u -d "$expected_now" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$expected_now" +%s 2>/dev/null)
actual_epoch=$(date -u -d "$ts_var_output" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts_var_output" +%s 2>/dev/null)
TOTAL=$((TOTAL + 1))
if [[ -n "$expected_epoch" && -n "$actual_epoch" ]]; then
  delta=$(( expected_epoch > actual_epoch ? expected_epoch - actual_epoch : actual_epoch - expected_epoch ))
  if (( delta <= 5 )); then
    PASS=$((PASS + 1))
    echo "  PASS: timestamp matches UTC now (delta=${delta}s)"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: timestamp drift too large (delta=${delta}s, expected=$expected_now actual=$ts_var_output)"
  fi
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: could not parse one of the epochs (expected=$expected_now actual=$ts_var_output)"
fi

echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
