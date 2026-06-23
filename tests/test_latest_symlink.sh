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

# Behavioral coverage for issue #313 — maintain logs/LATEST symlink to the
# authoritative run (atomic, portable).
#
# At finalize, alongside the canonical logs/latest-result.json pointer (issue
# #308), RepoLens must (re)point logs/LATEST at the just-finished run dir using:
#   - a RELATIVE target (the run-id, not an absolute path) so the logs tree is
#     relocatable,
#   - an ATOMIC swap (build a temp link, rename it over LATEST) leaving no
#     leftover logs/.LATEST.tmp,
#   - a CLOBBER GUARD that refuses to destroy a real (non-symlink) file/dir that
#     happens to sit at logs/LATEST (warn instead), and
#   - the file's governing NON-FATAL contract: every failure path logs a warning
#     and returns 0 so a symlink failure never changes the run's exit code.
#
# The contract (from the issue + research) is a new helper in
# lib/result_pointer.sh:
#     update_latest_symlink <logs_dir> <run_id>
# pointing <logs_dir>/LATEST -> <run_id> (relative). It is wired into the
# existing finalize hook by being called from write_latest_result_pointer's
# happy path, so no repolens.sh change is needed.
#
# Two harnesses:
#   Part A — unit tests of update_latest_symlink against hand-built logs dirs.
#            Fast, deterministic, covers AC #1-#4 plus the dangling-link repoint.
#   Part B — end-to-end finalize wiring: one mock-agent run inside an isolated
#            symlink-farm logs tree proves the new helper is actually invoked at
#            finalize (a unit-only suite would pass even if the implementer
#            forgot to call it).
#
# CLAUDE.md hard rule: NO real models. Part A calls the lib function directly;
# Part B drives tests/mock-agent.sh through a fake `codex` on PATH. NOTE: the
# issue text says "--dry-run", but --dry-run exits before the finalize hook, so
# it would never create logs/LATEST. The mock-agent harness is the correct
# no-real-model way to reach finalize (same approach as the sibling #308 test).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
TOTAL=0
KEEP_ARTIFACTS=0
TMP_ROOT=""

# shellcheck disable=SC2329  # cleanup is invoked indirectly via 'trap cleanup EXIT' below.
cleanup() {
  if (( KEEP_ARTIFACTS == 0 )); then
    [[ -n "$TMP_ROOT" && -d "$TMP_ROOT" ]] && rm -rf "$TMP_ROOT"
  else
    printf 'Preserved test artifacts: %s\n' "$TMP_ROOT"
  fi
}
trap cleanup EXIT

pass_with() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

fail_with() {
  local desc="$1" detail="${2:-}"
  FAIL=$((FAIL + 1))
  KEEP_ARTIFACTS=1
  echo "  FAIL: $desc"
  [[ -n "$detail" ]] && printf '    %s\n' "$detail"
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected: $expected | Actual: $actual"
  fi
}

# assert_true <desc> <cmd...> — passes iff the command succeeds (rc 0).
assert_true() {
  local desc="$1"; shift
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then
    pass_with "$desc"
  else
    fail_with "$desc" "command failed: $*"
  fi
}

# assert_false <desc> <cmd...> — passes iff the command fails (rc != 0).
assert_false() {
  local desc="$1"; shift
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then
    fail_with "$desc" "command unexpectedly succeeded: $*"
  else
    pass_with "$desc"
  fi
}

assert_file_exists() {
  local desc="$1" file="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$file" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected file at $file"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "needle '$needle' not found"
  fi
}

finish() {
  echo ""
  echo "Results: $PASS/$TOTAL passed, $FAIL failed"
  [[ "$FAIL" -gt 0 ]] && exit 1
  exit 0
}

parse_run_id() {
  sed -n 's/.*RepoLens run \([^ ]*\) starting.*/\1/p' "$1" | head -1
}

# Canonicalize a path (resolve symlinks). Used to compare a symlink's resolved
# target against the real run dir without being fooled by /tmp symlinking.
canon() {
  readlink -f "$1" 2>/dev/null || printf '%s' "$1"
}

TMP_ROOT="$(mktemp -d)"

LOG_LIB="$SCRIPT_DIR/lib/logging.sh"
RP_LIB="$SCRIPT_DIR/lib/result_pointer.sh"

# run_symlink <logs_dir> <run_id> — call update_latest_symlink in an isolated
# shell with the documented signature; stderr (where log_warn writes) -> UNIT_ERR.
UNIT_ERR=""
run_symlink() {
  local logs_dir="$1" run_id="$2"
  UNIT_ERR="$(mktemp "$TMP_ROOT/unit-err.XXXXXX")"
  bash -c '
    set -uo pipefail
    source "$1"   # logging.sh        (log_warn)
    source "$2"   # result_pointer.sh (function under test)
    update_latest_symlink "$3" "$4"
  ' _ "$LOG_LIB" "$RP_LIB" "$logs_dir" "$run_id" \
    2>"$UNIT_ERR"
  return $?
}

# run_symlink_path <path_prefix> <logs_dir> <run_id> — same as run_symlink but
# prepends <path_prefix> to PATH so the function-under-test resolves a SHADOWED
# `mv`/`ln`. Used to drive the BSD/macOS `ln -sfn` fallback by simulating a
# platform whose `mv` has no GNU `-T`.
run_symlink_path() {
  local path_prefix="$1" logs_dir="$2" run_id="$3"
  UNIT_ERR="$(mktemp "$TMP_ROOT/unit-err.XXXXXX")"
  PATH="$path_prefix:$PATH" bash -c '
    set -uo pipefail
    source "$1"
    source "$2"
    update_latest_symlink "$3" "$4"
  ' _ "$LOG_LIB" "$RP_LIB" "$logs_dir" "$run_id" \
    2>"$UNIT_ERR"
  return $?
}

# Fake `mv` simulating a platform without GNU `mv -T` (BSD/macOS): fail whenever
# the first argument is `-T`, otherwise defer to the REAL mv. The function under
# test only ever calls `mv -T`, so this deterministically forces the `ln -sfn`
# fallback branch while leaving every other command (ln, rm) real.
REAL_MV="$(command -v mv)"
FAKE_MV_BIN="$TMP_ROOT/fake-mv-bin"
mkdir -p "$FAKE_MV_BIN"
cat > "$FAKE_MV_BIN/mv" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "-T" ]]; then exit 1; fi
exec "$REAL_MV" "\$@"
EOF
chmod +x "$FAKE_MV_BIN/mv"

# ---------------------------------------------------------------------------
# Part A — unit: update_latest_symlink behavior (issue #313 AC #1-#4)
# ---------------------------------------------------------------------------
echo "=== update_latest_symlink unit behavior (issue #313) ==="

if [[ ! -f "$RP_LIB" ]]; then
  fail_with "lib/result_pointer.sh exists" "Missing $RP_LIB"
fi

RUN_A="20260601T000000Z-aaaa0001"
RUN_B="20260601T010000Z-bbbb0002"

# --- A1: AC #1 — relative symlink resolving to the finished run dir -----------
LOGS_A="$TMP_ROOT/logs-a"
mkdir -p "$LOGS_A/$RUN_A"
printf '{"run_id":"%s"}\n' "$RUN_A" > "$LOGS_A/$RUN_A/summary.json"

run_symlink "$LOGS_A" "$RUN_A"
assert_eq "A1: update_latest_symlink returns 0 on success" "0" "$?"
assert_true  "A1: logs/LATEST is a symlink" test -L "$LOGS_A/LATEST"
assert_eq "A1: readlink target is the RELATIVE run-id" \
  "$RUN_A" "$(readlink "$LOGS_A/LATEST" 2>/dev/null || true)"
# A relative target must NOT begin with '/'.
assert_false "A1: target is relative (does not start with /)" \
  bash -c '[[ "$(readlink "$0")" == /* ]]' "$LOGS_A/LATEST"
# Following the link must land inside the real run dir.
assert_eq "A1: LATEST resolves to the run dir" \
  "$(canon "$LOGS_A/$RUN_A")" "$(canon "$LOGS_A/LATEST")"
assert_file_exists "A1: LATEST/summary.json reachable through the link" \
  "$LOGS_A/LATEST/summary.json"

# --- A2: AC #2 — a second run repoints with no leftover .LATEST.tmp -----------
mkdir -p "$LOGS_A/$RUN_B"
printf '{"run_id":"%s"}\n' "$RUN_B" > "$LOGS_A/$RUN_B/summary.json"

run_symlink "$LOGS_A" "$RUN_B"
assert_eq "A2: repoint returns 0" "0" "$?"
assert_eq "A2: readlink now points at the newer run-id" \
  "$RUN_B" "$(readlink "$LOGS_A/LATEST" 2>/dev/null || true)"
assert_eq "A2: LATEST resolves to the newer run dir" \
  "$(canon "$LOGS_A/$RUN_B")" "$(canon "$LOGS_A/LATEST")"
assert_false "A2: no leftover .LATEST.tmp after repoint" \
  test -e "$LOGS_A/.LATEST.tmp"

# --- A3: AC #3 — pre-existing REAL FILE at logs/LATEST is preserved + warned --
LOGS_F="$TMP_ROOT/logs-realfile"
mkdir -p "$LOGS_F/$RUN_A"
printf 'precious-not-a-symlink\n' > "$LOGS_F/LATEST"

run_symlink "$LOGS_F" "$RUN_A"
assert_eq "A3: real-file clobber guard returns 0 (non-fatal)" "0" "$?"
assert_true  "A3: pre-existing regular file still present" test -f "$LOGS_F/LATEST"
assert_false "A3: pre-existing file was NOT turned into a symlink" \
  test -L "$LOGS_F/LATEST"
assert_eq "A3: file content is unchanged" \
  "precious-not-a-symlink" "$(cat "$LOGS_F/LATEST" 2>/dev/null || true)"
assert_contains "A3: a warning is logged when LATEST is a real file" \
  "[WARN]" "$(cat "$UNIT_ERR" 2>/dev/null || true)"

# --- A4: AC #3 — pre-existing REAL DIR at logs/LATEST is preserved + warned ---
# A genuine directory (not a symlink-to-dir) must not be clobbered, and no
# nested logs/LATEST/<run-id> stray may be created inside it.
LOGS_D="$TMP_ROOT/logs-realdir"
mkdir -p "$LOGS_D/$RUN_A" "$LOGS_D/LATEST"
printf 'marker\n' > "$LOGS_D/LATEST/keep.txt"

run_symlink "$LOGS_D" "$RUN_A"
assert_eq "A4: real-dir clobber guard returns 0 (non-fatal)" "0" "$?"
assert_true  "A4: pre-existing real directory still present" test -d "$LOGS_D/LATEST"
assert_false "A4: real directory was NOT replaced by a symlink" \
  test -L "$LOGS_D/LATEST"
assert_file_exists "A4: directory content untouched" "$LOGS_D/LATEST/keep.txt"
assert_false "A4: no nested LATEST/<run-id> stray created" \
  test -e "$LOGS_D/LATEST/$RUN_A"
assert_contains "A4: a warning is logged when LATEST is a real dir" \
  "[WARN]" "$(cat "$UNIT_ERR" 2>/dev/null || true)"

# --- A5: AC #4 — symlink failure does not change the exit code ----------------
# logs_dir is a regular FILE, so ln -s into "<file>/.LATEST.tmp" can never
# succeed (non-directory parent). The helper must swallow it: rc 0 + a warning.
BAD_LOGS="$TMP_ROOT/not-a-dir"
: > "$BAD_LOGS"

run_symlink "$BAD_LOGS" "$RUN_A"
assert_eq "A5: symlink creation failure returns 0 (non-fatal)" "0" "$?"
assert_contains "A5: a warning is logged on symlink failure" \
  "[WARN]" "$(cat "$UNIT_ERR" 2>/dev/null || true)"

# --- A6: dangling pre-existing symlink is repointed (guard allows it) ---------
# `-e` follows symlinks, so a dangling LATEST is NOT caught by the real-file
# guard and must be repointed to the live run.
LOGS_DANG="$TMP_ROOT/logs-dangling"
mkdir -p "$LOGS_DANG/$RUN_A"
ln -s "nonexistent-run-id" "$LOGS_DANG/LATEST"

run_symlink "$LOGS_DANG" "$RUN_A"
assert_eq "A6: dangling-link repoint returns 0" "0" "$?"
assert_true "A6: LATEST is still a symlink" test -L "$LOGS_DANG/LATEST"
assert_eq "A6: dangling link repointed to the live run-id" \
  "$RUN_A" "$(readlink "$LOGS_DANG/LATEST" 2>/dev/null || true)"
assert_false "A6: no leftover .LATEST.tmp after dangling repoint" \
  test -e "$LOGS_DANG/.LATEST.tmp"

# --- A7: a stale pre-existing .LATEST.tmp is cleared before the swap ----------
# A crashed prior finalize can leave logs/.LATEST.tmp behind. `ln -s` refuses to
# create a link whose name already exists, so the helper `rm -f`s the temp name
# first; without that pre-clean the repoint would silently no-op (ln -s fails ->
# warn -> return 0, but LATEST never updates). Pre-seed a stale temp link and
# assert LATEST is still (re)pointed and no temp survives.
LOGS_STALE="$TMP_ROOT/logs-staletmp"
mkdir -p "$LOGS_STALE/$RUN_A"
printf '{"run_id":"%s"}\n' "$RUN_A" > "$LOGS_STALE/$RUN_A/summary.json"
ln -s "garbage-stale-target" "$LOGS_STALE/.LATEST.tmp"

run_symlink "$LOGS_STALE" "$RUN_A"
assert_eq "A7: repoint over a stale .LATEST.tmp returns 0" "0" "$?"
assert_true "A7: LATEST is a symlink despite the stale temp" \
  test -L "$LOGS_STALE/LATEST"
assert_eq "A7: stale temp did not block the repoint" \
  "$RUN_A" "$(readlink "$LOGS_STALE/LATEST" 2>/dev/null || true)"
assert_eq "A7: LATEST resolves to the run dir" \
  "$(canon "$LOGS_STALE/$RUN_A")" "$(canon "$LOGS_STALE/LATEST")"
assert_false "A7: stale .LATEST.tmp was cleared (none left)" \
  test -e "$LOGS_STALE/.LATEST.tmp"

# --- A8: the relative target survives relocating the logs tree ----------------
# The whole point of a RELATIVE target is that moving/copying the logs tree keeps
# LATEST valid. A1 only asserts the target STRING is relative; this asserts the
# relocation actually works end to end — an absolute target would dangle here.
LOGS_MOVE="$TMP_ROOT/logs-move"
mkdir -p "$LOGS_MOVE/$RUN_A"
printf '{"run_id":"%s"}\n' "$RUN_A" > "$LOGS_MOVE/$RUN_A/summary.json"
run_symlink "$LOGS_MOVE" "$RUN_A"
assert_eq "A8: pre-move symlink creation returns 0" "0" "$?"

LOGS_MOVED="$TMP_ROOT/logs-move-relocated"
mv "$LOGS_MOVE" "$LOGS_MOVED"
assert_true "A8: LATEST is still a symlink after relocation" \
  test -L "$LOGS_MOVED/LATEST"
assert_file_exists "A8: LATEST/summary.json still reachable after relocation" \
  "$LOGS_MOVED/LATEST/summary.json"
assert_eq "A8: relocated LATEST resolves to the moved run dir" \
  "$(canon "$LOGS_MOVED/$RUN_A")" "$(canon "$LOGS_MOVED/LATEST")"

# --- A9: BSD/macOS portability — `ln -sfn` fallback when `mv -T` is absent -----
# "portable" is in the issue title: on platforms without GNU `mv -T` the helper
# must still produce a correct relative LATEST symlink via the `ln -sfn` fallback
# and clean up its temp link. We force that branch with a shadowed `mv` that
# fails on `-T` (mirroring BSD/macOS). A happy-path GNU box never exercises this
# code otherwise.
LOGS_FB="$TMP_ROOT/logs-fallback"
mkdir -p "$LOGS_FB/$RUN_A"
printf '{"run_id":"%s"}\n' "$RUN_A" > "$LOGS_FB/$RUN_A/summary.json"

run_symlink_path "$FAKE_MV_BIN" "$LOGS_FB" "$RUN_A"
assert_eq "A9: fallback creation returns 0" "0" "$?"
assert_true "A9: LATEST is a symlink via the ln -sfn fallback" \
  test -L "$LOGS_FB/LATEST"
assert_eq "A9: fallback target is the RELATIVE run-id" \
  "$RUN_A" "$(readlink "$LOGS_FB/LATEST" 2>/dev/null || true)"
assert_eq "A9: fallback LATEST resolves to the run dir" \
  "$(canon "$LOGS_FB/$RUN_A")" "$(canon "$LOGS_FB/LATEST")"
assert_false "A9: fallback cleaned up its .LATEST.tmp" \
  test -e "$LOGS_FB/.LATEST.tmp"

# --- A10: fallback REPOINT over an existing symlink-to-dir (the `-n` matters) --
# After A9, LATEST is a symlink to RUN_A (a real directory). The `ln -sfn`
# fallback's `-n` must treat that symlink-to-dir as a plain name and replace it,
# NOT dereference it and create LATEST/<run-id> nested inside RUN_A. Without `-n`
# the repoint would silently nest. This is the fallback analogue of A2.
mkdir -p "$LOGS_FB/$RUN_B"
printf '{"run_id":"%s"}\n' "$RUN_B" > "$LOGS_FB/$RUN_B/summary.json"

run_symlink_path "$FAKE_MV_BIN" "$LOGS_FB" "$RUN_B"
assert_eq "A10: fallback repoint returns 0" "0" "$?"
assert_eq "A10: fallback repoint updates readlink to the newer run-id" \
  "$RUN_B" "$(readlink "$LOGS_FB/LATEST" 2>/dev/null || true)"
assert_eq "A10: fallback repoint resolves to the newer run dir" \
  "$(canon "$LOGS_FB/$RUN_B")" "$(canon "$LOGS_FB/LATEST")"
assert_false "A10: fallback repoint created no nested LATEST/<run-id> stray" \
  test -e "$LOGS_FB/$RUN_A/$RUN_B"
assert_false "A10: no leftover .LATEST.tmp after fallback repoint" \
  test -e "$LOGS_FB/.LATEST.tmp"

# ---------------------------------------------------------------------------
# Part B — e2e: the finalize hook actually maintains logs/LATEST
# ---------------------------------------------------------------------------
echo ""
echo "=== logs/LATEST maintained at finalize (mock-agent) ==="

# Symlink farm: isolate $SCRIPT_DIR/logs so the run dir + LATEST land in the
# farm, never the real logs tree. repolens derives its logs base from its own
# location, so symlinking the entry point + libs gives a fully isolated run.
FARM="$TMP_ROOT/farm"
mkdir -p "$FARM/logs"
for item in repolens.sh lib config prompts; do
  ln -s "$SCRIPT_DIR/$item" "$FARM/$item"
done

# Throwaway git repo to audit.
PROJECT_DIR="$TMP_ROOT/project"
mkdir -p "$PROJECT_DIR"
git -C "$PROJECT_DIR" init -q
printf '# RepoLens issue 313 fixture\n' > "$PROJECT_DIR/README.md"
git -C "$PROJECT_DIR" add README.md
git -C "$PROJECT_DIR" -c user.name='RepoLens Test' -c user.email='repolens@example.invalid' \
  commit -q -m 'fixture'

# Fake `codex` that defers to the deterministic mock agent.
FAKE_BIN="$TMP_ROOT/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
exec bash "$REPOLENS_TEST_SCRIPT_DIR/tests/mock-agent.sh" "$@"
EOF
chmod +x "$FAKE_BIN/codex"

run_output="$TMP_ROOT/run-output.txt"
PATH="$FAKE_BIN:$PATH" \
  REPOLENS_AGENT_TIMEOUT=10 \
  REPOLENS_AGENT_KILL_GRACE=1 \
  REPOLENS_TEST_SCRIPT_DIR="$SCRIPT_DIR" \
  bash "$FARM/repolens.sh" \
    --project "$PROJECT_DIR" \
    --agent codex \
    --local \
    --focus injection \
    --depth 1 \
    --yes \
    >"$run_output" 2>&1
run_rc=$?

assert_eq "B: completed audit run exits successfully" "0" "$run_rc"

RUN_ID="$(parse_run_id "$run_output")"
assert_eq "B: run id is discoverable from output" "set" \
  "$([[ -n "$RUN_ID" ]] && printf 'set' || printf 'missing')"

LATEST="$FARM/logs/LATEST"

# AC #1 at the e2e level: finalize produced a relative symlink to the run dir.
assert_true "B: logs/LATEST is a symlink after a completed run" test -L "$LATEST"
assert_eq "B: readlink logs/LATEST is the RELATIVE run-id (not absolute)" \
  "$RUN_ID" "$(readlink "$LATEST" 2>/dev/null || true)"
assert_eq "B: LATEST resolves into the finished run dir" \
  "$(canon "$FARM/logs/$RUN_ID")" "$(canon "$LATEST")"
assert_file_exists "B: logs/LATEST/summary.json reachable through the link" \
  "$LATEST/summary.json"
# No transient temp link left behind after finalize.
assert_false "B: no leftover .LATEST.tmp after finalize" \
  test -e "$FARM/logs/.LATEST.tmp"

finish
