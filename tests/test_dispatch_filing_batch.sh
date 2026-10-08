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

# Tests for issue #165: lib/filing.sh — dispatch_filing_batch.
#
# Required cases (from acceptance criteria):
#   1. Idempotent skip — manifest with 5 clusters, 3 pre-`.url` markers; the
#      stub callback runs for exactly the missing 2 and the aggregate output
#      is `Filed: 2, Verification-failed: 0, Skipped-existing: 3`.
#   2. Stale-lock retry — pre-populate one `.lock` with mtime older than
#      STALE_LOCK_TIMEOUT and assert the dispatcher retakes the lock and
#      re-dispatches.
#   3. Missing-manifest gating — no manifest.json -> non-zero exit and no
#      writes inside `final/filed/`.

# Shims are invoked by the sourced dispatcher; each lifecycle fixture isolates
# its own PARALLEL setting in a subshell.
# shellcheck disable=SC2329,SC2030,SC2031
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILING_LIB="$SCRIPT_DIR/lib/filing.sh"
PARALLEL_LIB="$SCRIPT_DIR/lib/parallel.sh"
LOGGING_LIB="$SCRIPT_DIR/lib/logging.sh"
TEMPLATE_LIB="$SCRIPT_DIR/lib/template.sh"
CORE_LIB="$SCRIPT_DIR/lib/core.sh"

PASS=0
FAIL=0
TOTAL=0

# Keep the runtime scratch path short: parallel.sh places its Unix socket
# under TMPDIR, and a deep checkout path can exceed the AF_UNIX path limit.
TMPDIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

pass_with() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

fail_with() {
  local desc="$1" detail="${2:-}"
  FAIL=$((FAIL + 1))
  echo "  FAIL: $desc"
  if [[ -n "$detail" ]]; then
    printf '    %s\n' "$detail"
  fi
}

assert_success() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -eq 0 ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected exit 0, got $actual"
  fi
}

assert_failure() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -ne 0 ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected non-zero exit"
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected '$expected', got '$actual'"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Did not find '$needle' in: $haystack"
  fi
}

assert_file_exists() {
  local desc="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -e "$path" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected file $path"
  fi
}

assert_file_missing() {
  local desc="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [[ ! -e "$path" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Did not expect file $path"
  fi
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

if [[ ! -f "$FILING_LIB" ]]; then
  echo "  FAIL: lib/filing.sh missing at $FILING_LIB"
  exit 1
fi

# shellcheck disable=SC1090
source "$LOGGING_LIB"
# shellcheck disable=SC1090
source "$PARALLEL_LIB"
# shellcheck disable=SC1090
source "$TEMPLATE_LIB"
# shellcheck disable=SC1090
source "$CORE_LIB"
# shellcheck disable=SC1090
source "$FILING_LIB"

# Builds a manifest with N clusters using cluster ids cluster-1 .. cluster-N.
write_manifest_n() {
  local path="$1" n="$2"
  local i
  echo '[' > "$path"
  for (( i = 1; i <= n; i++ )); do
    cat >> "$path" <<JSON
  {
    "cluster_id": "cluster-$i",
    "title": "[medium] Issue $i title differs entirely",
    "severity": "medium",
    "domain": "code",
    "lens": "input-validation",
    "root_cause_category": "missing-validation",
    "source_finding_paths": ["logs/run-1/rounds/round-1/lens-outputs/code/input-validation-$i.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["bug"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "Body of issue $i alpha bravo charlie delta echo foxtrot $(printf '%s ' golf hotel india juliet kilo)$i"
  }
JSON
    if (( i < n )); then
      echo "  ," >> "$path"
    fi
  done
  echo ']' >> "$path"
}

# Stub filing-agent callback used by the dispatcher under test. Records its
# invocations into $CALLBACK_LOG (one cluster_id per line) and `touch`es the
# corresponding .url marker so the cluster ends in a terminal success state.
test_stub_filing_callback() {
  local run_id="$1" cluster_id="$2"
  local log_base
  log_base="$(_filing_log_base "$run_id")"
  printf '%s\n' "$cluster_id" >> "$CALLBACK_LOG"
  printf 'https://example.invalid/issues/%s\n' "$cluster_id" \
    > "$log_base/final/filed/$cluster_id.url"
  rm -f "$log_base/final/filed/$cluster_id.lock"
}

echo "=== Case 1: idempotent skip — 5 clusters, 3 pre-filed ==="

RUN_LOG="$TMPDIR/idempotent"
mkdir -p "$RUN_LOG/final/filed"
export LOG_BASE="$RUN_LOG"

write_manifest_n "$RUN_LOG/final/manifest.json" 5

# Pre-populate three .url markers
echo "https://example.invalid/issues/cluster-1" > "$RUN_LOG/final/filed/cluster-1.url"
echo "https://example.invalid/issues/cluster-2" > "$RUN_LOG/final/filed/cluster-2.url"
echo "https://example.invalid/issues/cluster-3" > "$RUN_LOG/final/filed/cluster-3.url"

CALLBACK_LOG="$TMPDIR/idempotent-callback.log"
: > "$CALLBACK_LOG"

export _FILING_AGENT_CALLBACK="test_stub_filing_callback"
output="$(dispatch_filing_batch "idempotent" 2>"$TMPDIR/idempotent.err")"
status=$?

assert_success "dispatcher exits 0 on idempotent run" "$status"
assert_eq "aggregate counts match" \
  "Filed: 2, Verification-failed: 0, Skipped-existing: 3" "$output"

callback_count=$(wc -l < "$CALLBACK_LOG" | tr -d ' ')
assert_eq "callback ran exactly twice" "2" "$callback_count"

assert_file_exists ".url present for cluster-4" "$RUN_LOG/final/filed/cluster-4.url"
assert_file_exists ".url present for cluster-5" "$RUN_LOG/final/filed/cluster-5.url"
assert_file_missing ".lock cleaned up for cluster-4" "$RUN_LOG/final/filed/cluster-4.lock"
assert_file_missing ".lock cleaned up for cluster-5" "$RUN_LOG/final/filed/cluster-5.lock"

# Verify the callback was invoked only for the missing two
TOTAL=$((TOTAL + 1))
if grep -q '^cluster-1$' "$CALLBACK_LOG" || grep -q '^cluster-2$' "$CALLBACK_LOG" || grep -q '^cluster-3$' "$CALLBACK_LOG"; then
  fail_with "callback NOT invoked for already-filed clusters" \
    "log: $(tr '\n' ',' < "$CALLBACK_LOG")"
else
  pass_with "callback NOT invoked for already-filed clusters"
fi

TOTAL=$((TOTAL + 1))
if grep -q '^cluster-4$' "$CALLBACK_LOG" && grep -q '^cluster-5$' "$CALLBACK_LOG"; then
  pass_with "callback invoked for missing clusters"
else
  fail_with "callback invoked for missing clusters" \
    "log: $(tr '\n' ',' < "$CALLBACK_LOG")"
fi

unset LOG_BASE

echo ""
echo "=== Case 2: stale-lock retry ==="

RUN_LOG="$TMPDIR/stale-lock"
mkdir -p "$RUN_LOG/final/filed"
export LOG_BASE="$RUN_LOG"

# Single-cluster manifest
write_manifest_n "$RUN_LOG/final/manifest.json" 1

# Pre-populate a stale .lock for cluster-1: low STALE_LOCK_TIMEOUT lets us
# create the lock with the current time and have it appear stale via the
# 1-second timeout. We additionally backdate to 1 hour ago to be robust on
# fast hosts.
touch -d "1 hour ago" "$RUN_LOG/final/filed/cluster-1.lock" 2>/dev/null \
  || touch -t 202001010000 "$RUN_LOG/final/filed/cluster-1.lock"

CALLBACK_LOG="$TMPDIR/stale-callback.log"
: > "$CALLBACK_LOG"
export _FILING_AGENT_CALLBACK="test_stub_filing_callback"
export STALE_LOCK_TIMEOUT=1

output="$(dispatch_filing_batch "stale-lock" 2>"$TMPDIR/stale.err")"
status=$?

assert_success "dispatcher exits 0 with stale lock retake" "$status"
assert_eq "stale-lock aggregate counts" \
  "Filed: 1, Verification-failed: 0, Skipped-existing: 0" "$output"

callback_count=$(wc -l < "$CALLBACK_LOG" | tr -d ' ')
assert_eq "callback ran for the stale-locked cluster" "1" "$callback_count"
assert_file_exists ".url written for stale-locked cluster" "$RUN_LOG/final/filed/cluster-1.url"

unset STALE_LOCK_TIMEOUT
unset LOG_BASE

echo ""
echo "=== Case 2b: fresh lock blocks dispatch ==="

RUN_LOG="$TMPDIR/fresh-lock"
mkdir -p "$RUN_LOG/final/filed"
export LOG_BASE="$RUN_LOG"

write_manifest_n "$RUN_LOG/final/manifest.json" 1

# Recently-touched lock is owned by another (still-running) worker.
: > "$RUN_LOG/final/filed/cluster-1.lock"

CALLBACK_LOG="$TMPDIR/fresh-callback.log"
: > "$CALLBACK_LOG"
export _FILING_AGENT_CALLBACK="test_stub_filing_callback"
# Default STALE_LOCK_TIMEOUT (3600) is well above the brand-new lock age.

output="$(dispatch_filing_batch "fresh-lock" 2>"$TMPDIR/fresh.err")"
status=$?

assert_success "dispatcher exits 0 when fresh lock blocks" "$status"
assert_eq "fresh-lock aggregate counts" \
  "Filed: 0, Verification-failed: 0, Skipped-existing: 0" "$output"

callback_count=$(wc -l < "$CALLBACK_LOG" | tr -d ' ')
assert_eq "callback skipped for fresh-locked cluster" "0" "$callback_count"
assert_file_missing ".url not written for fresh-locked cluster" \
  "$RUN_LOG/final/filed/cluster-1.url"

unset LOG_BASE

echo ""
echo "=== Case 3: missing manifest -> non-zero, no writes to filed/ ==="

RUN_LOG="$TMPDIR/missing-manifest"
mkdir -p "$RUN_LOG/final"
export LOG_BASE="$RUN_LOG"
# Intentionally do NOT create manifest.json.

CALLBACK_LOG="$TMPDIR/missing-callback.log"
: > "$CALLBACK_LOG"
export _FILING_AGENT_CALLBACK="test_stub_filing_callback"

output="$(dispatch_filing_batch "missing-manifest" 2>"$TMPDIR/missing.err")"
status=$?

assert_failure "dispatcher exits non-zero for missing manifest" "$status"

callback_count=$(wc -l < "$CALLBACK_LOG" | tr -d ' ')
assert_eq "no callback invocations on missing manifest" "0" "$callback_count"

# Either the filed/ directory was not created, or it was created and is empty.
TOTAL=$((TOTAL + 1))
if [[ ! -d "$RUN_LOG/final/filed" ]]; then
  pass_with "filed/ directory not created on missing manifest"
else
  contents=$(find "$RUN_LOG/final/filed" -mindepth 1 | wc -l | tr -d ' ')
  if [[ "$contents" -eq 0 ]]; then
    pass_with "filed/ directory empty on missing manifest"
  else
    fail_with "filed/ directory empty on missing manifest" \
      "Found $contents entries"
  fi
fi

err_text="$(cat "$TMPDIR/missing.err")"
assert_contains "stderr mentions missing manifest" "manifest" "$err_text"

unset LOG_BASE

echo ""
echo "=== Case 4: empty manifest ([]) -> 0,0,0 success ==="

RUN_LOG="$TMPDIR/empty-manifest"
mkdir -p "$RUN_LOG/final"
export LOG_BASE="$RUN_LOG"
echo '[]' > "$RUN_LOG/final/manifest.json"

CALLBACK_LOG="$TMPDIR/empty-callback.log"
: > "$CALLBACK_LOG"
export _FILING_AGENT_CALLBACK="test_stub_filing_callback"

output="$(dispatch_filing_batch "empty-manifest" 2>"$TMPDIR/empty.err")"
status=$?

assert_success "dispatcher returns 0 on empty manifest" "$status"
assert_eq "empty manifest aggregate counts" \
  "Filed: 0, Verification-failed: 0, Skipped-existing: 0" "$output"

callback_count=$(wc -l < "$CALLBACK_LOG" | tr -d ' ')
assert_eq "no callback invocations on empty manifest" "0" "$callback_count"

unset LOG_BASE

echo ""
echo "=== Case 5: pre-existing .failed treated as terminal ==="

RUN_LOG="$TMPDIR/pre-failed"
mkdir -p "$RUN_LOG/final/filed"
export LOG_BASE="$RUN_LOG"

write_manifest_n "$RUN_LOG/final/manifest.json" 1
echo "VERIFICATION_FAILED: dummy" > "$RUN_LOG/final/filed/cluster-1.failed"

CALLBACK_LOG="$TMPDIR/pre-failed-callback.log"
: > "$CALLBACK_LOG"
export _FILING_AGENT_CALLBACK="test_stub_filing_callback"

output="$(dispatch_filing_batch "pre-failed" 2>"$TMPDIR/pre-failed.err")"
status=$?

assert_success "dispatcher exits 0 when only cluster is .failed" "$status"
assert_eq "pre-existing .failed counted as Verification-failed" \
  "Filed: 0, Verification-failed: 1, Skipped-existing: 0" "$output"

callback_count=$(wc -l < "$CALLBACK_LOG" | tr -d ' ')
assert_eq "no callback invocation for pre-existing .failed" "0" "$callback_count"

echo "=== Lifecycle integration: sequential defaults and explicit fallback ==="
for policy in default fallback; do
  RUN_LOG="$TMPDIR/sequential-$policy"
  mkdir -p "$RUN_LOG/final/filed"
  export LOG_BASE="$RUN_LOG"
  write_manifest_n "$RUN_LOG/final/manifest.json" 1
  CALLBACK_LOG="$TMPDIR/sequential-$policy.log"
  : > "$CALLBACK_LOG"
  (
    uname() { echo Darwin; }
    _REPOLENS_SCOPE_READY=0
    unset PARALLEL
    if [[ "$policy" == fallback ]]; then
      export PARALLEL=true
      export REPOLENS_PARALLEL_FALLBACK=sequential
      parallel_preflight || exit 1
    fi
    dispatch_filing_batch "sequential-$policy"
  ) > "$TMPDIR/sequential-$policy.out" 2>&1
  status=$?
  assert_success "$policy filing succeeds with no platform backend" "$status"
  assert_eq "$policy callback executes exactly once" 1 "$(wc -l < "$CALLBACK_LOG" | tr -d ' ')"
done

echo "=== Lifecycle integration: parallel infrastructure failures ==="
for failure in init spawn wait terminal-after-url recorded-rejection; do
  RUN_LOG="$TMPDIR/infrastructure-$failure"
  mkdir -p "$RUN_LOG/final/filed"
  export LOG_BASE="$RUN_LOG"
  write_manifest_n "$RUN_LOG/final/manifest.json" 1
  CALLBACK_LOG="$TMPDIR/infrastructure-$failure.log"
  : > "$CALLBACK_LOG"
  (
    export PARALLEL=true
    _REPOLENS_SCOPE_FAILED=0
    _cleanup_children() { :; }
    init_parallel() { [[ "$failure" != init ]]; }
    spawn_lens() {
      [[ "$failure" != spawn ]] || return 1
      local callback="$2" run_id="$3" cluster="$4"
      if [[ "$failure" == recorded-rejection ]]; then
        printf 'governed rejection\n' > "$LOG_BASE/final/filed/$cluster.failed"
      else
        "$callback" "$run_id" "$cluster" || true
      fi
      return 0
    }
    wait_all() {
      [[ "$failure" != terminal-after-url ]] || _REPOLENS_SCOPE_FAILED=1
      return 1
    }
    dispatch_filing_batch "infrastructure-$failure"
  ) > "$TMPDIR/infrastructure-$failure.out" 2>&1
  status=$?
  if [[ "$failure" == recorded-rejection ]]; then
    assert_success "governed rejection stays a recorded per-cluster result" "$status"
    assert_contains "governed rejection counted in aggregate" "Verification-failed: 1" "$(cat "$TMPDIR/infrastructure-$failure.out")"
  else
    assert_failure "$failure propagates through captured dispatcher status" "$status"
    if [[ "$failure" == init || "$failure" == spawn ]]; then
      assert_eq "$failure starts no callback" 0 "$(wc -l < "$CALLBACK_LOG" | tr -d ' ')"
      assert_file_missing "$failure releases never-dispatched reservation" "$RUN_LOG/final/filed/cluster-1.lock"
    elif [[ "$failure" == terminal-after-url ]]; then
      assert_file_exists "terminal cleanup failure remains fatal after a URL was recorded" "$RUN_LOG/final/filed/cluster-1.url"
    fi
  fi
done

echo "=== Lifecycle integration: real parallel mixed governed outcomes ==="
if python3 "$_REPOLENS_SCOPE_HELPER" probe 2>/dev/null; then
  RUN_LOG="$TMPDIR/real-parallel"
  mkdir -p "$RUN_LOG/final/filed"
  export LOG_BASE="$RUN_LOG"
  write_manifest_n "$RUN_LOG/final/manifest.json" 2
  CALLBACK_LOG="$TMPDIR/real-parallel.log"
  : > "$CALLBACK_LOG"
  (
    export PARALLEL=true
    real_parallel_callback() {
      local run_id="$1" cluster="$2"
      if [[ "$cluster" == cluster-1 ]]; then
        printf 'VERIFICATION_FAILED: governed fixture rejection\n' > "$LOG_BASE/final/filed/$cluster.failed"
        return 1
      fi
      test_stub_filing_callback "$run_id" "$cluster"
    }
    _FILING_AGENT_CALLBACK=real_parallel_callback
    dispatch_filing_batch real-parallel
  ) > "$TMPDIR/real-parallel.out" 2>&1
  status=$?
  assert_success "real parallel callback rejection remains a governed result" "$status"
  assert_contains "real parallel batch records both terminal outcomes" "Filed: 1, Verification-failed: 1" "$(cat "$TMPDIR/real-parallel.out")"
else
  echo "  SKIP: real parallel filing requires delegated cgroup v2"
fi

unset LOG_BASE
unset _FILING_AGENT_CALLBACK

finish
