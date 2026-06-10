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

# Issue #251 — opt-in startup auto-retention (maybe_auto_clean).
#
# REPOLENS_AUTO_CLEAN gates a background prune of old run dirs at startup.
# Default OFF. When ON it backgrounds clean_command --force, parameterised by
# REPOLENS_RETENTION_DAYS (default 30) and REPOLENS_KEEP_LAST (default 50).
#
# We source lib/clean.sh directly and point SCRIPT_DIR at the isolated farm,
# so maybe_auto_clean's clean_command reads $SCRIPT_DIR/logs. The prune is
# backgrounded; we `wait` for it before asserting (it is a child of this shell).

set -uo pipefail

# shellcheck disable=SC1091
# shellcheck source=tests/clean_test_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/clean_test_lib.sh"
trap clean_cleanup EXIT

# shellcheck source=/dev/null
source "$CLEAN_TEST_ROOT/lib/clean.sh"

AUTO_CLEAN_INFO_LINES=()
# shellcheck disable=SC2329 # Invoked indirectly by maybe_auto_clean in sourced lib/clean.sh.
log_info() {
  AUTO_CLEAN_INFO_LINES+=("$*")
}

echo "=== clean: opt-in startup auto-retention (issue #251) ==="

# ---------------------------------------------------------------------------
# Default OFF: with REPOLENS_AUTO_CLEAN unset or != "true", maybe_auto_clean is
# a no-op — it returns 0 and prunes nothing, even an ancient finished run.
# ---------------------------------------------------------------------------
clean_setup_farm
SCRIPT_DIR="$CLEAN_TEST_FARM"
make_run "20260101T000301Z-offdefolt" "finished" "" 365 >/dev/null

unset REPOLENS_AUTO_CLEAN
maybe_auto_clean
rc=$?
wait 2>/dev/null || true
assert_eq "maybe_auto_clean returns 0 when unset" "0" "$rc"
assert_dir_present "no prune when REPOLENS_AUTO_CLEAN unset" "20260101T000301Z-offdefolt"

REPOLENS_AUTO_CLEAN="false" maybe_auto_clean
wait 2>/dev/null || true
assert_dir_present "no prune when REPOLENS_AUTO_CLEAN=false" "20260101T000301Z-offdefolt"

# ---------------------------------------------------------------------------
# ON: REPOLENS_AUTO_CLEAN=true prunes runs older than REPOLENS_RETENTION_DAYS,
# protects the REPOLENS_KEEP_LAST newest, and keeps recent runs.
# ---------------------------------------------------------------------------
clean_cleanup
clean_setup_farm
SCRIPT_DIR="$CLEAN_TEST_FARM"
make_run "20260101T000401Z-oldprune0" "finished" "" 60 >/dev/null
make_run "20260601T000402Z-recentkep" "finished" "" 1 >/dev/null
make_run "20260101T000403Z-autointr" "interrupted" "" 60 >/dev/null

AUTO_CLEAN_INFO_LINES=()
REPOLENS_AUTO_CLEAN="true" REPOLENS_RETENTION_DAYS="7" REPOLENS_KEEP_LAST="0" maybe_auto_clean
wait 2>/dev/null || true
auto_clean_info_text="${AUTO_CLEAN_INFO_LINES[*]}"
assert_contains "auto-clean logs resolved retention at INFO" "Startup auto-clean enabled: pruning logs older than 7d (keep-last 0)" "$auto_clean_info_text"
assert_dir_absent "auto-clean prunes old finished run" "20260101T000401Z-oldprune0"
assert_dir_present "auto-clean keeps recent run (age guard)" "20260601T000402Z-recentkep"
assert_dir_present "auto-clean keeps interrupted resume candidate" "20260101T000403Z-autointr"

# ---------------------------------------------------------------------------
# REPOLENS_KEEP_LAST is honoured: the N newest survive even past the cutoff.
# ---------------------------------------------------------------------------
clean_cleanup
clean_setup_farm
SCRIPT_DIR="$CLEAN_TEST_FARM"
make_run "20260101T000501Z-kl0000001" "finished" "" 50 >/dev/null
make_run "20260201T000502Z-kl0000002" "finished" "" 40 >/dev/null

REPOLENS_AUTO_CLEAN="true" REPOLENS_RETENTION_DAYS="7" REPOLENS_KEEP_LAST="1" maybe_auto_clean
wait 2>/dev/null || true
assert_dir_present "auto-clean protects newest via REPOLENS_KEEP_LAST" "20260201T000502Z-kl0000002"
assert_dir_absent "auto-clean prunes beyond REPOLENS_KEEP_LAST" "20260101T000501Z-kl0000001"

# ---------------------------------------------------------------------------
# Non-numeric retention/keep-last fall back to the defaults (30 / 50) instead
# of crashing. With a bogus retention, the 60-day run still falls past the
# 30-day default and is pruned (keep-last forced to 0 here).
# ---------------------------------------------------------------------------
clean_cleanup
clean_setup_farm
# shellcheck disable=SC2034 # Read by maybe_auto_clean in sourced lib/clean.sh.
SCRIPT_DIR="$CLEAN_TEST_FARM"
make_run "20260101T000601Z-fallback0" "finished" "" 60 >/dev/null

REPOLENS_AUTO_CLEAN="true" REPOLENS_RETENTION_DAYS="not-a-number" REPOLENS_KEEP_LAST="0" maybe_auto_clean
wait 2>/dev/null || true
assert_dir_absent "non-numeric retention falls back to 30d default" "20260101T000601Z-fallback0"

# A bogus keep-last value falls back to 50, protecting this single old run.
clean_cleanup
clean_setup_farm
# shellcheck disable=SC2034 # Read by maybe_auto_clean in sourced lib/clean.sh.
SCRIPT_DIR="$CLEAN_TEST_FARM"
make_run "20260101T000602Z-keepfall" "finished" "" 60 >/dev/null

REPOLENS_AUTO_CLEAN="true" REPOLENS_RETENTION_DAYS="7" REPOLENS_KEEP_LAST="not-a-number" maybe_auto_clean
wait 2>/dev/null || true
assert_dir_present "non-numeric keep-last falls back to 50 default" "20260101T000602Z-keepfall"

# ---------------------------------------------------------------------------
# CLI startup hook: the direct helper tests above prove maybe_auto_clean's
# behavior, but this pins the actual repolens.sh startup call site. A dry-run
# run still performs normal startup and then exits before any agent execution.
# ---------------------------------------------------------------------------
clean_cleanup
clean_setup_farm
make_run "20260101T000701Z-startold" "finished" "" 60 >/dev/null
make_run "20260601T000702Z-startnew" "finished" "" 1 >/dev/null

fake_bin="$CLEAN_TEST_FARM/bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/codex" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$fake_bin/codex"

startup_project="$CLEAN_TEST_FARM/project"
startup_output="$CLEAN_TEST_FARM/startup.out"
mkdir -p "$startup_project"
git -C "$startup_project" init -q
printf '# auto-clean startup hook\n' > "$startup_project/README.md"

PATH="$fake_bin:$PATH" \
REPOLENS_AUTO_CLEAN="true" \
REPOLENS_RETENTION_DAYS="7" \
REPOLENS_KEEP_LAST="0" \
  timeout 20 bash "$CLEAN_TEST_FARM/repolens.sh" \
    --project "$startup_project" \
    --agent codex \
    --focus naming \
    --local \
    --output "$CLEAN_TEST_FARM/issues" \
    --dry-run \
    --yes >"$startup_output" 2>&1
rc=$?
startup_output_content="$(cat "$startup_output" 2>/dev/null || true)"
assert_eq "CLI dry-run with auto-clean exits 0" "0" "$rc"
assert_contains "CLI startup auto-clean emits INFO output" "[INFO]" "$startup_output_content"
assert_contains "CLI startup auto-clean logs resolved retention" "Startup auto-clean enabled: pruning logs older than 7d (keep-last 0)" "$startup_output_content"

for _ in $(seq 1 50); do
  [[ ! -d "$CLEAN_TEST_LOGS/20260101T000701Z-startold" ]] && break
  sleep 0.1
done

assert_dir_absent "CLI startup auto-clean prunes old finished run" "20260101T000701Z-startold"
assert_dir_present "CLI startup auto-clean keeps recent run" "20260601T000702Z-startnew"

startup_run_id="$(grep -oE 'RepoLens run [^ ]+ starting' "$startup_output" 2>/dev/null | head -1 | awk '{print $3}')"
TOTAL=$((TOTAL + 1))
if [[ -n "$startup_run_id" && -d "$CLEAN_TEST_LOGS/$startup_run_id" ]]; then
  record_pass "CLI startup auto-clean keeps the current dry-run log dir"
else
  record_fail "CLI startup auto-clean keeps the current dry-run log dir" "run_id='${startup_run_id:-<missing>}'"
fi

clean_finish
