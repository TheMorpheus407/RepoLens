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

# Issue #250 — size-based log rotation governed by REPOLENS_LOG_MAX_BYTES
# and REPOLENS_LOG_KEEP. Only the init_logging owner PID rotates.

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

assert_true() {
  local desc="$1" cond="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$cond" == "1" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
  fi
}

filesize() {
  stat -c %s "$1" 2>/dev/null || stat -f %z "$1" 2>/dev/null || printf '0'
}

echo ""
echo "=== Test Suite: logging — size-based rotation (issue #250) ==="
echo ""

# ---------------------------------------------------------------------------
# Test 1: log file rotates when it exceeds REPOLENS_LOG_MAX_BYTES.
# ---------------------------------------------------------------------------

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

(
  export REPOLENS_LOG_MAX_BYTES=512
  export REPOLENS_LOG_KEEP=5
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/logging.sh"
  init_logging "rot" "$workdir/logs"
  # Each log_info line is ~50 bytes. 50 calls => ~2500 bytes; far above 512.
  for ((i = 0; i < 50; i++)); do
    log_info "rotation-marker-line-$i"
  done
) > /dev/null 2>&1

log_file="$workdir/logs/rot.log"

echo "Test 1: current log exists after rotation pressure"
TOTAL=$((TOTAL + 1))
if [[ -f "$log_file" ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: current log file exists"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: current log file missing"
fi

echo ""
echo "Test 2: at least one rotated file (.log.1) exists"
TOTAL=$((TOTAL + 1))
if [[ -f "${log_file}.1" ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: ${log_file}.1 exists"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: ${log_file}.1 missing — rotation never fired"
fi

echo ""
echo "Test 3: total emitted lines are preserved across rotated + current"
total_lines=0
for f in "$log_file" "${log_file}".*; do
  [[ -f "$f" ]] || continue
  n=$(grep -c 'rotation-marker-line-' "$f" || true)
  total_lines=$(( total_lines + n ))
done
assert_eq "all 50 marker lines accounted for across rotated logs" "50" "$total_lines"

# ---------------------------------------------------------------------------
# Test 4: REPOLENS_LOG_KEEP caps the number of rotated backups.
# ---------------------------------------------------------------------------

workdir2="$(mktemp -d)"
(
  export REPOLENS_LOG_MAX_BYTES=256
  export REPOLENS_LOG_KEEP=2
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/logging.sh"
  init_logging "rotcap" "$workdir2/logs"
  for ((i = 0; i < 200; i++)); do
    log_info "cap-line-$i"
  done
) > /dev/null 2>&1

echo ""
echo "Test 4: REPOLENS_LOG_KEEP=2 — .log.3 must not exist"
log_file2="$workdir2/logs/rotcap.log"
TOTAL=$((TOTAL + 1))
if [[ ! -e "${log_file2}.3" ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: ${log_file2}.3 absent (cap respected)"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: ${log_file2}.3 exists (cap violated)"
fi

echo ""
echo "Test 5: REPOLENS_LOG_KEEP=2 — .log.1 and .log.2 should exist after enough writes"
exist1=0; exist2=0
[[ -f "${log_file2}.1" ]] && exist1=1
[[ -f "${log_file2}.2" ]] && exist2=1
assert_true ".log.1 present" "$exist1"
assert_true ".log.2 present" "$exist2"

rm -rf "$workdir2"

# ---------------------------------------------------------------------------
# Test 6: rotation disabled when REPOLENS_LOG_MAX_BYTES=0.
# ---------------------------------------------------------------------------

workdir3="$(mktemp -d)"
(
  export REPOLENS_LOG_MAX_BYTES=0
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/logging.sh"
  init_logging "norot" "$workdir3/logs"
  for ((i = 0; i < 100; i++)); do
    log_info "norot-line-$i"
  done
) > /dev/null 2>&1

echo ""
echo "Test 6: REPOLENS_LOG_MAX_BYTES=0 disables rotation"
log_file3="$workdir3/logs/norot.log"
TOTAL=$((TOTAL + 1))
if [[ -f "$log_file3" && ! -e "${log_file3}.1" ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: no rotated file when max bytes is 0"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: rotation fired despite REPOLENS_LOG_MAX_BYTES=0"
fi

rm -rf "$workdir3"

# ---------------------------------------------------------------------------
# Test 7: parallel children must NOT rotate even if they trigger a write that
# would otherwise cross the threshold. Only the init_logging owner rotates.
# ---------------------------------------------------------------------------

workdir4="$(mktemp -d)"
(
  # Pretend a child process inherited the env without ever calling
  # init_logging itself. _REPOLENS_LOG_PID points at a PID that is not us,
  # so _log_maybe_rotate must be a no-op.
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/logging.sh"
  init_logging "child" "$workdir4/logs"
  # Force the owner-pid sentinel to something that is NOT this shell.
  _REPOLENS_LOG_PID=1
  export REPOLENS_LOG_MAX_BYTES=32
  for ((i = 0; i < 50; i++)); do
    log_info "child-line-$i"
  done
) > /dev/null 2>&1

echo ""
echo "Test 7: non-owner PID does not rotate"
log_file4="$workdir4/logs/child.log"
TOTAL=$((TOTAL + 1))
if [[ -f "$log_file4" && ! -e "${log_file4}.1" ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: non-owner skipped rotation"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: non-owner attempted rotation (${log_file4}.1 present=$([[ -e "${log_file4}.1" ]] && echo 1 || echo 0))"
fi

rm -rf "$workdir4"

echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
