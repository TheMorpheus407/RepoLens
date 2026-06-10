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

# Issue #251 — non-destructive guards:
#   * --dry-run names the run it WOULD remove but deletes nothing.
#   * a run whose .repolens.flock is held by a live process is skipped, because
#     age/state alone cannot tell that a long-running run is active right now.

set -uo pipefail

# shellcheck disable=SC1091
# shellcheck source=tests/clean_test_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/clean_test_lib.sh"
trap clean_cleanup EXIT

echo "=== clean: --dry-run and live-run flock guard (issue #251) ==="

# ---------------------------------------------------------------------------
# --dry-run: report-only. The candidate must be NAMED in output but survive.
# ---------------------------------------------------------------------------
clean_setup_farm
make_run "20260101T020202Z-drytest0" "finished" "" 60 >/dev/null

clean_run --older-than 30d --keep-last 0 --dry-run --force
rc=$?
assert_eq "dry-run exits 0" "0" "$rc"
assert_contains "dry-run names the candidate run id" "20260101T020202Z-drytest0" "$CLEAN_OUT"
assert_dir_present "dry-run deletes nothing" "20260101T020202Z-drytest0"

# ---------------------------------------------------------------------------
# Non-interactive stdin: without --force, clean must auto-skip the prompt when
# stdin is not a TTY. The AutoDev/CI path relies on this not hanging.
# ---------------------------------------------------------------------------
clean_cleanup
clean_setup_farm
make_run "20260101T020303Z-nottyrun" "finished" "" 60 >/dev/null

clean_run_timed 5 --older-than 30d --keep-last 0
rc=$?
assert_eq "non-TTY clean without --force exits 0" "0" "$rc"
assert_dir_absent "non-TTY clean without --force removes eligible run" "20260101T020303Z-nottyrun"

# ---------------------------------------------------------------------------
# Live-run guard: hold a non-blocking flock on the run's .repolens.flock and
# confirm clean skips it even though it is old and finished.
# ---------------------------------------------------------------------------
if command -v flock >/dev/null 2>&1; then
  clean_cleanup
  clean_setup_farm
  locked_dir="$(make_run "20260101T030303Z-lockedru" "finished" "" 60)"
  lock_file="$locked_dir/.repolens.flock"

  # Hold the lock for the duration of the clean invocation in a background
  # subshell, mirroring how acquire_run_lock holds it during a live run.
  exec {hold_fd}>"$lock_file"
  flock -n "$hold_fd"
  (
    exec {bg_fd}>"$lock_file"
    flock -n "$bg_fd" || true   # already held by parent; keep file busy
    sleep 5
  ) &
  bg_pid=$!

  clean_run --older-than 30d --keep-last 0 --force
  rc=$?

  exec {hold_fd}>&-
  kill "$bg_pid" 2>/dev/null || true
  wait "$bg_pid" 2>/dev/null || true

  assert_eq "clean exits 0 while a run is locked" "0" "$rc"
  assert_dir_present "locked (live) run is skipped" "20260101T030303Z-lockedru"

  clean_cleanup
  clean_setup_farm
  symlink_dir="$(make_run "20260101T030404Z-locklink" "finished" "" 60)"
  symlink_target="$CLEAN_TEST_FARM/lock-target.txt"
  printf 'do not truncate\n' > "$symlink_target"
  ln -s "$symlink_target" "$symlink_dir/.repolens.flock"
  touch -d "@$(epoch_days_ago 60)" "$symlink_dir"

  clean_run --older-than 30d --keep-last 0 --force
  rc=$?
  symlink_target_content="$(cat "$symlink_target" 2>/dev/null || true)"

  assert_eq "clean exits 0 with a symlink lock path" "0" "$rc"
  assert_eq "symlink lock target is not truncated" "do not truncate" "$symlink_target_content"
  assert_dir_absent "symlink lock path is not treated as a live lock" "20260101T030404Z-locklink"
else
  echo "  SKIP: flock not available — live-run guard test skipped"
fi

clean_finish
