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

# Issue #250 — REPOLENS_LOG_LEVEL gates log_info / log_warn / log_error
# in both the log file and the matching stdout/stderr channel. log_raw
# is intentionally exempt from the filter.

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

# run_at_level <level_value> -> sets globals: out_stdout, out_stderr, out_file
run_at_level() {
  local level="$1"
  local workdir
  workdir="$(mktemp -d)"
  (
    if [[ -n "$level" ]]; then
      export REPOLENS_LOG_LEVEL="$level"
    else
      unset REPOLENS_LOG_LEVEL
    fi
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib/logging.sh"
    init_logging "lvl" "$workdir/logs"
    log_info  "the info"
    log_warn  "the warn"
    log_error "the error"
    log_raw   "the raw"
  ) > "$workdir/out" 2> "$workdir/err"
  out_stdout="$(cat "$workdir/out")"
  out_stderr="$(cat "$workdir/err")"
  out_file="$(cat "$workdir/logs/lvl.log" 2>/dev/null || true)"
  rm -rf "$workdir"
}

count_lines_matching() {
  local pattern="$1" haystack="$2"
  local n
  n="$(printf '%s\n' "$haystack" | grep -cE "$pattern" 2>/dev/null || true)"
  printf '%s' "${n:-0}"
}

echo ""
echo "=== Test Suite: logging — REPOLENS_LOG_LEVEL filter (issue #250) ==="
echo ""

echo "Test 1: default level (unset) lets INFO + WARN + ERROR through"
run_at_level ""
assert_eq "stdout has 1 INFO line"  "1" "$(count_lines_matching '^\[INFO\] ' "$out_stdout")"
assert_eq "stderr has 1 WARN line"  "1" "$(count_lines_matching '^\[WARN\] ' "$out_stderr")"
assert_eq "stderr has 1 ERROR line" "1" "$(count_lines_matching '^\[ERROR\] ' "$out_stderr")"
assert_eq "log file has 3 timestamped lines" "3" "$(count_lines_matching '^\[(INFO|WARN|ERROR)\] ' "$out_file")"
assert_eq "log file has the raw line" "1" "$(count_lines_matching '^the raw$' "$out_file")"

echo ""
echo "Test 2: REPOLENS_LOG_LEVEL=info matches the default"
run_at_level "info"
assert_eq "stdout INFO at info level"  "1" "$(count_lines_matching '^\[INFO\] ' "$out_stdout")"
assert_eq "stderr WARN at info level"  "1" "$(count_lines_matching '^\[WARN\] ' "$out_stderr")"
assert_eq "stderr ERROR at info level" "1" "$(count_lines_matching '^\[ERROR\] ' "$out_stderr")"

echo ""
echo "Test 3: REPOLENS_LOG_LEVEL=warn drops INFO from file and stdout"
run_at_level "warn"
assert_eq "no INFO in stdout"            "0" "$(count_lines_matching '^\[INFO\] ' "$out_stdout")"
assert_eq "WARN still in stderr"         "1" "$(count_lines_matching '^\[WARN\] ' "$out_stderr")"
assert_eq "ERROR still in stderr"        "1" "$(count_lines_matching '^\[ERROR\] ' "$out_stderr")"
assert_eq "no INFO in log file"          "0" "$(count_lines_matching '^\[INFO\] ' "$out_file")"
assert_eq "WARN still in log file"       "1" "$(count_lines_matching '^\[WARN\] ' "$out_file")"
assert_eq "ERROR still in log file"      "1" "$(count_lines_matching '^\[ERROR\] ' "$out_file")"
assert_eq "log_raw still appears at warn" "1" "$(count_lines_matching '^the raw$' "$out_file")"

echo ""
echo "Test 4: REPOLENS_LOG_LEVEL=error drops both INFO and WARN"
run_at_level "error"
assert_eq "no INFO in stdout"        "0" "$(count_lines_matching '^\[INFO\] ' "$out_stdout")"
assert_eq "no WARN in stderr"        "0" "$(count_lines_matching '^\[WARN\] ' "$out_stderr")"
assert_eq "ERROR still in stderr"    "1" "$(count_lines_matching '^\[ERROR\] ' "$out_stderr")"
assert_eq "no INFO in log file"      "0" "$(count_lines_matching '^\[INFO\] ' "$out_file")"
assert_eq "no WARN in log file"      "0" "$(count_lines_matching '^\[WARN\] ' "$out_file")"
assert_eq "ERROR still in log file"  "1" "$(count_lines_matching '^\[ERROR\] ' "$out_file")"

echo ""
echo "Test 5: REPOLENS_LOG_LEVEL=silent drops everything except log_raw"
run_at_level "silent"
assert_eq "no INFO in stdout"     "0" "$(count_lines_matching '^\[INFO\] ' "$out_stdout")"
assert_eq "no WARN in stderr"     "0" "$(count_lines_matching '^\[WARN\] ' "$out_stderr")"
assert_eq "no ERROR in stderr"    "0" "$(count_lines_matching '^\[ERROR\] ' "$out_stderr")"
assert_eq "no levelled lines in log file" "0" "$(count_lines_matching '^\[(INFO|WARN|ERROR)\] ' "$out_file")"
assert_eq "log_raw still flows at silent" "1" "$(count_lines_matching '^the raw$' "$out_file")"

echo ""
echo "Test 6: invalid REPOLENS_LOG_LEVEL falls back to info"
run_at_level "bogus-value"
assert_eq "INFO present on invalid value"  "1" "$(count_lines_matching '^\[INFO\] ' "$out_stdout")"
assert_eq "WARN present on invalid value"  "1" "$(count_lines_matching '^\[WARN\] ' "$out_stderr")"
assert_eq "ERROR present on invalid value" "1" "$(count_lines_matching '^\[ERROR\] ' "$out_stderr")"

echo ""
echo "Test 7: REPOLENS_LOG_LEVEL=debug also permits INFO/WARN/ERROR"
run_at_level "debug"
assert_eq "INFO present at debug"  "1" "$(count_lines_matching '^\[INFO\] ' "$out_stdout")"
assert_eq "WARN present at debug"  "1" "$(count_lines_matching '^\[WARN\] ' "$out_stderr")"
assert_eq "ERROR present at debug" "1" "$(count_lines_matching '^\[ERROR\] ' "$out_stderr")"

echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
