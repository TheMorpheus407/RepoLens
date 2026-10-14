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

# Exercise the real integration-fixture allocation in an isolated logs tree.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)" || exit 1
trap 'rm -rf "$TEST_DIR"' EXIT
passed=0 failed=0
check() {
  if "$@"; then passed=$((passed + 1)); else failed=$((failed + 1)); printf 'FAIL: %s\n' "$*"; fi
}
for kind in FAKE LEGACY; do
  snippet="$TEST_DIR/$kind.sh"
  # Run the allocation statements from the actual test, before it writes metadata.
  if [[ "$kind" == FAKE ]]; then
    sed -n '/^FAKE_\(RUN_ID\|LOG_BASE\)=/,/^jq -n /p' "$SCRIPT_DIR/tests/test_rounds_resume.sh" | sed '$d' > "$snippet"
  else
    sed -n '/^LEGACY_\(RUN_ID\|LOG_BASE\)=/,/^: > /p' "$SCRIPT_DIR/tests/test_rounds_resume.sh" | sed '$d' > "$snippet"
  fi
  check test -s "$snippet"
  (
    SCRIPT_DIR="$TEST_DIR/$kind"
    mkdir -p "$SCRIPT_DIR/logs/20260101T000000Z-resumetest" "$SCRIPT_DIR/logs/20260101T000000Z-resumelegacy"
    printf 'keep\n' > "$SCRIPT_DIR/logs/20260101T000000Z-resumetest/owned-by-another-run"
    printf 'keep\n' > "$SCRIPT_DIR/logs/20260101T000000Z-resumelegacy/owned-by-another-run"
    CREATED_RUN_IDS=()
    # shellcheck source=/dev/null
    source "$snippet"
    for run_id in "${CREATED_RUN_IDS[@]}"; do rm -rf "$SCRIPT_DIR/logs/$run_id"; done
    test -f "$SCRIPT_DIR/logs/20260101T000000Z-resumetest/owned-by-another-run" &&
      test -f "$SCRIPT_DIR/logs/20260101T000000Z-resumelegacy/owned-by-another-run"
  )
  check test "$?" -eq 0
  (
    SCRIPT_DIR="$TEST_DIR/failure-$kind"
    mkdir -p "$SCRIPT_DIR/logs"
    CREATED_RUN_IDS=()
    # If allocation fails, the test must stop before registering any directory.
    # shellcheck disable=SC2329 # Called by the extracted allocation code.
    mktemp() { return 42; }
    # shellcheck source=/dev/null
    source "$snippet"
    exit 0
  )
  check test "$?" -ne 0
done
printf 'Results: %s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
