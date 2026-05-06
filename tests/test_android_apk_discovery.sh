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

# Tests for issue #86 — Android APK discovery for deploy mode.
#
# Behavioural contract:
#   - lib/android.sh exports discover_android_apk <project_path>.
#   - The function searches standard Gradle APK output first:
#     <project>/app/build/outputs/apk/**/*.apk.
#   - If that scope has no APKs, it falls back to a recursive project-wide
#     *.apk search.
#   - Multiple APKs in the active scope select the newest by mtime.
#   - Success returns rc=0, prints the resolved APK path, and calls log_info.
#   - Misses return non-zero quietly so a later build-fallback step can run.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_LIB="$SCRIPT_DIR/lib/android.sh"

PASS=0
FAIL=0
TOTAL=0

TMPROOT="$SCRIPT_DIR/tests/.tmp"
mkdir -p "$TMPROOT"
TMPDIR="$(mktemp -d "$TMPROOT/android-apk-discovery.XXXXXX")"
trap 'rm -rf "$TMPDIR"; rmdir "$TMPROOT" 2>/dev/null || true' EXIT

LOG_INFO_FILE="$TMPDIR/log-info.txt"
LOG_WARN_FILE="$TMPDIR/log-warn.txt"
LOG_ERROR_FILE="$TMPDIR/log-error.txt"
DISCOVER_STDOUT_FILE="$TMPDIR/discover-stdout.txt"
DISCOVER_STDERR_FILE="$TMPDIR/discover-stderr.txt"

DISCOVER_RC=0
DISCOVER_OUTPUT=""
DISCOVER_ERR=""
LOG_INFO_MESSAGES=""
LOG_WARN_MESSAGES=""
LOG_ERROR_MESSAGES=""

record_pass() {
  TOTAL=$((TOTAL + 1))
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

record_fail() {
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (expected='$expected' actual='$actual')"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (expected to contain '$needle', got '${haystack:0:240}')"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (expected not to contain '$needle', got '${haystack:0:240}')"
  fi
}

assert_rc_zero() {
  local desc="$1" rc="$2"
  if [[ "$rc" -eq 0 ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (expected rc=0, got rc=$rc)"
  fi
}

assert_rc_nonzero() {
  local desc="$1" rc="$2"
  if [[ "$rc" -ne 0 ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (expected non-zero rc, got rc=0)"
  fi
}

# shellcheck disable=SC2329  # Indirectly invoked by sourced Android helpers.
log_info() {
  printf '%s\n' "$*" >> "$LOG_INFO_FILE"
}

# shellcheck disable=SC2329  # Indirectly invoked by sourced Android helpers.
log_warn() {
  printf '%s\n' "$*" >> "$LOG_WARN_FILE"
}

# shellcheck disable=SC2329  # Indirectly invoked by sourced Android helpers.
log_error() {
  printf '%s\n' "$*" >> "$LOG_ERROR_FILE"
}

if [[ -f "$ANDROID_LIB" ]]; then
  # shellcheck source=/dev/null
  source "$ANDROID_LIB"
fi

require_discover_android_apk() {
  local desc="$1"
  if declare -F discover_android_apk >/dev/null 2>&1; then
    return 0
  fi
  record_fail "$desc (discover_android_apk is not defined)"
  return 1
}

create_apk() {
  local path="$1" timestamp="$2"
  mkdir -p "$(dirname "$path")"
  : > "$path"
  touch -t "$timestamp" "$path"
}

run_discover() {
  local project_arg="$1" cwd="${2:-$SCRIPT_DIR}"

  : > "$LOG_INFO_FILE"
  : > "$LOG_WARN_FILE"
  : > "$LOG_ERROR_FILE"
  : > "$DISCOVER_STDOUT_FILE"
  : > "$DISCOVER_STDERR_FILE"

  (
    cd "$cwd" || exit 99
    discover_android_apk "$project_arg"
  ) >"$DISCOVER_STDOUT_FILE" 2>"$DISCOVER_STDERR_FILE"
  DISCOVER_RC=$?
  DISCOVER_OUTPUT="$(cat "$DISCOVER_STDOUT_FILE")"
  DISCOVER_ERR="$(cat "$DISCOVER_STDERR_FILE")"
  LOG_INFO_MESSAGES="$(cat "$LOG_INFO_FILE")"
  LOG_WARN_MESSAGES="$(cat "$LOG_WARN_FILE")"
  LOG_ERROR_MESSAGES="$(cat "$LOG_ERROR_FILE")"
}

run_discover_without_log_info() {
  local project_arg="$1" cwd="${2:-$SCRIPT_DIR}"

  : > "$LOG_INFO_FILE"
  : > "$LOG_WARN_FILE"
  : > "$LOG_ERROR_FILE"
  : > "$DISCOVER_STDOUT_FILE"
  : > "$DISCOVER_STDERR_FILE"

  (
    unset -f log_info log_warn log_error
    cd "$cwd" || exit 99
    discover_android_apk "$project_arg"
  ) >"$DISCOVER_STDOUT_FILE" 2>"$DISCOVER_STDERR_FILE"
  DISCOVER_RC=$?
  DISCOVER_OUTPUT="$(cat "$DISCOVER_STDOUT_FILE")"
  DISCOVER_ERR="$(cat "$DISCOVER_STDERR_FILE")"
  LOG_INFO_MESSAGES="$(cat "$LOG_INFO_FILE")"
  LOG_WARN_MESSAGES="$(cat "$LOG_WARN_FILE")"
  LOG_ERROR_MESSAGES="$(cat "$LOG_ERROR_FILE")"
}

echo ""
echo "=== Test Suite: Android APK discovery (issue #86) ==="
echo ""

echo "Test 1: repolens.sh sources lib/android.sh in the library block"
source_block="$(sed -n '/# --- Source libraries ---/,/^VERSION=/p' "$SCRIPT_DIR/repolens.sh")"
assert_contains "source block includes lib/android.sh" \
  'source "$SCRIPT_DIR/lib/android.sh"' "$source_block"

echo ""
echo "Test 2: lib/android.sh exports discover_android_apk"
if [[ -f "$ANDROID_LIB" ]]; then
  record_pass "lib/android.sh exists"
else
  record_fail "lib/android.sh exists"
fi
if declare -F discover_android_apk >/dev/null 2>&1; then
  record_pass "discover_android_apk is defined"
else
  record_fail "discover_android_apk is defined"
fi

echo ""
echo "Test 3: one standard Gradle APK returns rc=0, resolved path, and info log"
if require_discover_android_apk "one standard APK can be discovered"; then
  project="$TMPDIR/Project With Spaces"
  expected="$project/app/build/outputs/apk/debug/app-debug.apk"
  create_apk "$expected" "202601010101.01"

  run_discover "Project With Spaces" "$TMPDIR"
  assert_rc_zero "single standard APK returns rc=0" "$DISCOVER_RC"
  assert_eq "single standard APK prints only the resolved APK path" "$expected" "$DISCOVER_OUTPUT"
  assert_eq "single standard APK does not write stderr" "" "$DISCOVER_ERR"
  assert_contains "single standard APK logs selected path" "$expected" "$LOG_INFO_MESSAGES"
  assert_eq "single standard APK does not warn" "" "$LOG_WARN_MESSAGES"
  assert_eq "single standard APK does not error" "" "$LOG_ERROR_MESSAGES"
fi

echo ""
echo "Test 4: newest standard Gradle APK wins when multiple standard APKs exist"
if require_discover_android_apk "newest standard APK can be selected"; then
  project="$TMPDIR/standard-newest"
  old_apk="$project/app/build/outputs/apk/debug/app-debug.apk"
  new_apk="$project/app/build/outputs/apk/release/app-release.apk"
  create_apk "$old_apk" "202601010101.01"
  create_apk "$new_apk" "202602020202.02"

  run_discover "$project"
  assert_rc_zero "multiple standard APKs return rc=0" "$DISCOVER_RC"
  assert_eq "newest standard APK path is printed" "$new_apk" "$DISCOVER_OUTPUT"
  assert_contains "newest standard APK is logged" "$new_apk" "$LOG_INFO_MESSAGES"
fi

echo ""
echo "Test 5: same-mtime standard APKs choose a deterministic path"
if require_discover_android_apk "same-mtime standard APK tie can be selected"; then
  project="$TMPDIR/standard-same-mtime"
  first_apk="$project/app/build/outputs/apk/alpha/app-alpha.apk"
  second_apk="$project/app/build/outputs/apk/zeta/app-zeta.apk"
  create_apk "$second_apk" "202602020202.02"
  create_apk "$first_apk" "202602020202.02"

  run_discover "$project"
  assert_rc_zero "same-mtime standard APKs return rc=0" "$DISCOVER_RC"
  assert_eq "lexicographically first same-mtime standard APK is printed" "$first_apk" "$DISCOVER_OUTPUT"
  assert_contains "same-mtime standard APK selection is logged" "$first_apk" "$LOG_INFO_MESSAGES"
fi

echo ""
echo "Test 6: standard Gradle APK takes precedence over newer fallback APK"
if require_discover_android_apk "standard APK precedence can be enforced"; then
  project="$TMPDIR/standard-precedence"
  standard_apk="$project/app/build/outputs/apk/debug/app-debug.apk"
  fallback_apk="$project/artifacts/newer-side-loaded.apk"
  create_apk "$standard_apk" "202601010101.01"
  create_apk "$fallback_apk" "202603030303.03"

  run_discover "$project"
  assert_rc_zero "standard precedence returns rc=0" "$DISCOVER_RC"
  assert_eq "standard APK wins over newer fallback APK" "$standard_apk" "$DISCOVER_OUTPUT"
  assert_contains "standard precedence logs selected standard APK" "$standard_apk" "$LOG_INFO_MESSAGES"
fi

echo ""
echo "Test 7: fallback recursive search returns the newest APK when no standard APK exists"
if require_discover_android_apk "fallback newest APK can be selected"; then
  project="$TMPDIR/fallback-newest"
  old_apk="$project/build/old.apk"
  new_apk="$project/dist/nested/new.apk"
  create_apk "$old_apk" "202601010101.01"
  create_apk "$new_apk" "202604040404.04"

  run_discover "$project"
  assert_rc_zero "fallback APK discovery returns rc=0" "$DISCOVER_RC"
  assert_eq "newest fallback APK path is printed" "$new_apk" "$DISCOVER_OUTPUT"
  assert_contains "fallback discovery logs selected APK" "$new_apk" "$LOG_INFO_MESSAGES"
fi

echo ""
echo "Test 8: empty standard Gradle output still falls back to recursive project search"
if require_discover_android_apk "fallback can run after empty standard output"; then
  project="$TMPDIR/empty-standard-with-fallback"
  fallback_apk="$project/artifacts/app-from-build-cache.apk"
  mkdir -p "$project/app/build/outputs/apk/debug"
  create_apk "$fallback_apk" "202605050505.05"

  run_discover "$project"
  assert_rc_zero "empty standard output with fallback APK returns rc=0" "$DISCOVER_RC"
  assert_eq "fallback APK is printed when standard output is empty" "$fallback_apk" "$DISCOVER_OUTPUT"
  assert_contains "empty standard output fallback logs selected APK" "$fallback_apk" "$LOG_INFO_MESSAGES"
fi

echo ""
echo "Test 9: APK path control characters are sanitized only in the info log"
if require_discover_android_apk "control-character APK path can be discovered"; then
  project="$TMPDIR/control-character-apk"
  apk_name=$'release\n[ERROR] forged\e[31m.apk'
  expected="$project/app/build/outputs/apk/debug/$apk_name"
  expected_log="Discovered Android APK: ${expected//$'\n'/?}"
  expected_log="${expected_log//$'\e'/?}"
  create_apk "$expected" "202606060606.06"

  run_discover "$project"
  info_line_count="$(wc -l < "$LOG_INFO_FILE" | tr -d '[:space:]')"
  assert_rc_zero "control-character APK returns rc=0" "$DISCOVER_RC"
  assert_eq "control-character APK stdout preserves raw path" "$expected" "$DISCOVER_OUTPUT"
  assert_eq "control-character APK writes one info log line" "1" "$info_line_count"
  assert_eq "control-character APK log uses sanitized path" "$expected_log" "$LOG_INFO_MESSAGES"
  assert_not_contains "control-character APK log does not forge an error line" $'\n[ERROR]' "$LOG_INFO_MESSAGES"
fi

echo ""
echo "Test 10: discovery still succeeds when log_info is not defined"
if require_discover_android_apk "APK can be discovered without log_info"; then
  project="$TMPDIR/no-log-info"
  expected="$project/app/build/outputs/apk/debug/app-debug.apk"
  create_apk "$expected" "202607070707.07"

  run_discover_without_log_info "$project"
  assert_rc_zero "missing log_info still returns rc=0" "$DISCOVER_RC"
  assert_eq "missing log_info still prints APK path" "$expected" "$DISCOVER_OUTPUT"
  assert_eq "missing log_info writes no stderr" "" "$DISCOVER_ERR"
  assert_eq "missing log_info emits no info log" "" "$LOG_INFO_MESSAGES"
fi

echo ""
echo "Test 11: no APK returns non-zero quietly"
if require_discover_android_apk "no APK miss can be reported"; then
  project="$TMPDIR/no-apks"
  mkdir -p "$project/app/build/outputs/apk/debug"

  run_discover "$project"
  assert_rc_nonzero "no APK returns non-zero" "$DISCOVER_RC"
  assert_eq "no APK prints no stdout" "" "$DISCOVER_OUTPUT"
  assert_eq "no APK prints no stderr" "" "$DISCOVER_ERR"
  assert_eq "no APK emits no info log" "" "$LOG_INFO_MESSAGES"
  assert_eq "no APK emits no warning log" "" "$LOG_WARN_MESSAGES"
  assert_eq "no APK emits no error log" "" "$LOG_ERROR_MESSAGES"
fi

echo ""
echo "Test 12: missing project path returns non-zero quietly"
if require_discover_android_apk "missing project miss can be reported"; then
  missing_project="$TMPDIR/does-not-exist"

  run_discover "$missing_project"
  assert_rc_nonzero "missing project returns non-zero" "$DISCOVER_RC"
  assert_eq "missing project prints no stdout" "" "$DISCOVER_OUTPUT"
  assert_eq "missing project prints no stderr" "" "$DISCOVER_ERR"
  assert_eq "missing project emits no info log" "" "$LOG_INFO_MESSAGES"
  assert_eq "missing project emits no warning log" "" "$LOG_WARN_MESSAGES"
  assert_eq "missing project emits no error log" "" "$LOG_ERROR_MESSAGES"
fi

echo ""
echo "Test 13: empty project path returns non-zero quietly"
if require_discover_android_apk "empty project path miss can be reported"; then
  run_discover ""
  assert_rc_nonzero "empty project path returns non-zero" "$DISCOVER_RC"
  assert_eq "empty project path prints no stdout" "" "$DISCOVER_OUTPUT"
  assert_eq "empty project path prints no stderr" "" "$DISCOVER_ERR"
  assert_eq "empty project path emits no info log" "" "$LOG_INFO_MESSAGES"
  assert_eq "empty project path emits no warning log" "" "$LOG_WARN_MESSAGES"
  assert_eq "empty project path emits no error log" "" "$LOG_ERROR_MESSAGES"
fi

echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
