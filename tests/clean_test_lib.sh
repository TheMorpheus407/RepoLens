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

# Shared helpers for issue #251 `repolens clean` integration tests.
#
# The `clean` subcommand DELETES run directories. Running it against the real
# repo `logs/` would destroy live runs and AutoDev state, so every test runs
# repolens.sh inside an isolated "symlink farm": a fresh temp dir that symlinks
# repolens.sh / lib / config / prompts back to the real tree but owns its own
# `logs/` directory. repolens.sh derives SCRIPT_DIR (and therefore the logs
# base) from its own location, so the farm gives us a fully isolated logs tree
# while exercising the real CLI.

CLEAN_TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
TOTAL=0

CLEAN_TEST_FARM=""
CLEAN_TEST_LOGS=""
CLEAN_OUT=""
CLEAN_ERR=""

clean_cleanup() {
  [[ -n "$CLEAN_TEST_FARM" && -d "$CLEAN_TEST_FARM" ]] && rm -rf "$CLEAN_TEST_FARM"
}

record_pass() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

record_fail() {
  FAIL=$((FAIL + 1))
  if [[ -n "${2:-}" ]]; then
    echo "  FAIL: $1 ($2)"
  else
    echo "  FAIL: $1"
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    record_pass "$desc"
  else
    record_fail "$desc" "expected='$expected' actual='${actual:-<empty>}'"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    record_pass "$desc"
  else
    record_fail "$desc" "needle='$needle' not found"
  fi
}

# assert_dir_present / assert_dir_absent operate on the isolated logs tree.
assert_dir_present() {
  local desc="$1" name="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -d "$CLEAN_TEST_LOGS/$name" ]]; then
    record_pass "$desc"
  else
    record_fail "$desc" "expected logs/$name to remain"
  fi
}

assert_dir_absent() {
  local desc="$1" name="$2"
  TOTAL=$((TOTAL + 1))
  if [[ ! -e "$CLEAN_TEST_LOGS/$name" ]]; then
    record_pass "$desc"
  else
    record_fail "$desc" "expected logs/$name to be removed"
  fi
}

# clean_setup_farm builds the isolated symlink farm and an empty logs dir.
clean_setup_farm() {
  CLEAN_TEST_FARM="$(mktemp -d)"
  local item
  for item in repolens.sh lib config prompts; do
    ln -s "$CLEAN_TEST_ROOT/$item" "$CLEAN_TEST_FARM/$item"
  done
  CLEAN_TEST_LOGS="$CLEAN_TEST_FARM/logs"
  mkdir -p "$CLEAN_TEST_LOGS"
}

# clean_run <args...> invokes the real `repolens.sh clean` against the isolated
# logs tree. stdout/stderr are captured into CLEAN_OUT/CLEAN_ERR; returns the
# command's exit code. stdin is /dev/null so a missing-TTY confirm auto-skips.
clean_run() {
  local out err rc
  out="$(mktemp)"
  err="$(mktemp)"
  bash "$CLEAN_TEST_FARM/repolens.sh" clean "$@" </dev/null >"$out" 2>"$err"
  rc=$?
  # shellcheck disable=SC2034 # Asserted on by sourcing clean tests.
  CLEAN_OUT="$(cat "$out")"
  # shellcheck disable=SC2034 # Asserted on by sourcing clean tests.
  CLEAN_ERR="$(cat "$err")"
  rm -f "$out" "$err"
  return "$rc"
}

# clean_run_timed <secs> <args...> — like clean_run but wraps the invocation in
# `timeout <secs>`. Used by the missing-trailing-value regression: if the arg
# parser ever hangs again, timeout kills it and rc becomes 124, which the test's
# `assert_eq "1"` then flags. stdin is /dev/null (matches clean_run).
clean_run_timed() {
  local secs="$1"; shift
  local out err rc
  out="$(mktemp)"
  err="$(mktemp)"
  timeout "$secs" bash "$CLEAN_TEST_FARM/repolens.sh" clean "$@" </dev/null >"$out" 2>"$err"
  rc=$?
  # shellcheck disable=SC2034 # Asserted on by sourcing clean tests.
  CLEAN_OUT="$(cat "$out")"
  # shellcheck disable=SC2034 # Asserted on by sourcing clean tests.
  CLEAN_ERR="$(cat "$err")"
  rm -f "$out" "$err"
  return "$rc"
}

# epoch_days_ago <n> — UTC epoch seconds for n days before now (no Date.now in
# tests-of-tests concerns; this is a plain shell test, `date` is fine here).
epoch_days_ago() {
  local now days
  now="$(date -u +%s)"
  days="$1"
  printf '%s' "$(( now - days * 86400 ))"
}

# make_run <name> <state> [stopped_reason] [age_days]
#
# Creates an isolated run dir that the clean selector should recognise as a
# genuine RepoLens run: a run-id-shaped name plus summary.json and status.json.
#   state          -> status.json .state (running|finished|finished-empty|failed|interrupted)
#   stopped_reason -> summary.json .stopped_reason (pass "" or omit for null)
#   age_days       -> dir mtime AND completed_at/updated_at are set this many
#                     days in the past (default 60), so age comparisons agree
#                     regardless of whether clean keys off dir mtime or the
#                     JSON timestamp.
make_run() {
  local name="$1" state="$2" stopped="${3:-}" age_days="${4:-60}"
  local dir="$CLEAN_TEST_LOGS/$name"
  local epoch iso
  epoch="$(epoch_days_ago "$age_days")"
  iso="$(date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$dir"

  local sr_json='null'
  [[ -n "$stopped" ]] && sr_json="\"$stopped\""

  cat > "$dir/status.json" <<EOF
{"run_id":"$name","state":"$state","updated_at":"$iso","started_at":"$iso"}
EOF
  cat > "$dir/summary.json" <<EOF
{"run_id":"$name","stopped_reason":$sr_json,"started_at":"$iso","completed_at":"$iso"}
EOF
  # Dir mtime must be stamped LAST: writing entries bumps it back to "now".
  touch -d "@$epoch" "$dir"
  printf '%s' "$dir"
}

# make_run_aged_seconds <name> <secs_ago>
#
# Like make_run but ages the dir mtime <secs_ago> seconds into the past instead
# of whole days, so sub-day --older-than units (Nh / Nm / bare seconds) can be
# exercised end-to-end. clean keys retention off dir mtime, so only that needs
# the precise stamp; summary/status carry just enough to pass the run selector.
make_run_aged_seconds() {
  local name="$1" secs="$2"
  local dir="$CLEAN_TEST_LOGS/$name"
  local epoch
  epoch="$(( $(date -u +%s) - secs ))"
  mkdir -p "$dir"
  printf '{"run_id":"%s","state":"finished"}\n' "$name" > "$dir/status.json"
  printf '{"run_id":"%s","stopped_reason":null}\n' "$name" > "$dir/summary.json"
  # Dir mtime must be stamped LAST: writing entries bumps it back to "now".
  touch -d "@$epoch" "$dir"
  printf '%s' "$dir"
}

clean_finish() {
  echo ""
  echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
  exit "$FAIL"
}
