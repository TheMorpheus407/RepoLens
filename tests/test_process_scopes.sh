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

# Backend contract: no mocks count as Linux containment coverage.
# shellcheck disable=SC2329,SC2317
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/parallel.sh"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
PASS=0 FAIL=0
check() {
  local description="$1"; shift
  if "$@"; then echo "PASS: $description"; PASS=$((PASS + 1));
  else echo "FAIL: $description"; FAIL=$((FAIL + 1)); fi
}
if [[ "${1:-}" != --topology ]]; then
# Unsupported-host semantics are exercised even where cgroup access is absent.
(
  uname() { echo Darwin; }
  marker_callback() { touch "$TMPROOT/forbidden"; }
  parallel_preflight >/dev/null 2>&1 && exit 1
  spawn_lens forbidden marker_callback >/dev/null 2>&1 && exit 1
  [[ ! -e "$TMPROOT/forbidden" ]] || exit 1
  REPOLENS_PARALLEL_FALLBACK=sequential
  parallel_preflight >/dev/null 2>&1 || exit 1
  [[ "$PARALLEL" == false && "$MAX_PARALLEL" == 1 && "$REPOLENS_PROCESS_SCOPE_RESOLVED" == sequential-fallback ]] || exit 1
  REPOLENS_PROCESS_SCOPE=linux-cgroup-v2
  parallel_preflight >/dev/null 2>&1 && exit 1
  exit 0
); check "macOS refuses callbacks; only explicit auto fallback selects sequential" test "$?" = 0
(
  python3() { echo 'read-only cgroup hierarchy' >&2; return 1; }
  parallel_preflight >/dev/null 2>&1 && exit 1
  [[ "$_REPOLENS_SCOPE_READY" == 0 ]]
); check "read-only/missing cgroup capability fails closed" test "$?" = 0
source "$SCRIPT_DIR/tests/process_scope_test_support.sh"
require_process_scopes
# Save the real RPC function; delaying readiness forces both scheduling orders.
eval "$(declare -f _scope_call | sed '1s/_scope_call/_scope_call_real/')"
_scope_call() {
  if [[ "$2" == enroll ]]; then
    [[ ! -e "$TMPROOT/gate-callback" ]] || return 1
    [[ "$schedule" != child-first ]] || sleep 0.2
    _scope_call_real "$@" || return 1
    [[ ! -e "$TMPROOT/gate-callback" ]] || return 1
    touch "$TMPROOT/enrollment-verified"
  else
    _scope_call_real "$@"
  fi
}
printf() {
  if [[ "${schedule:-}" == parent-first && "${1:-}" == '%s %s\n' ]]; then sleep 0.2; fi
  # shellcheck disable=SC2059 # Preserve the wrapped builtin format.
  builtin printf "$@"
}
gated_callback() {
  [[ -f "$TMPROOT/enrollment-verified" ]] || return 1
  [[ "$(cat "/proc/$BASHPID/cgroup")" == *'/repolens-'* ]] || return 1
  touch "$TMPROOT/gate-callback"
}
for schedule in parent-first child-first; do
  rm -f "$TMPROOT/gate-callback" "$TMPROOT/enrollment-verified"
  init_parallel "$TMPROOT/$schedule" 2 || exit 1
  spawn_lens gated gated_callback || exit 1
  check "$schedule ready/GO preserves verified enrollment before callback" wait_all
  check "$schedule callback actually executed" test -f "$TMPROOT/gate-callback"
done
unset -f printf _scope_call
eval "$(declare -f _scope_call_real | sed '1s/_scope_call_real/_scope_call/')"
# Callback inheritance includes already-open descriptors, including 8/9/10.
exec 8>"$TMPROOT/inherited-8" 9>"$TMPROOT/inherited-9" 10>"$TMPROOT/inherited-10"
inherited_callback() { printf child >&8; printf child >&9; printf child >&10; }
init_parallel "$TMPROOT/inherited-fds" 2 || exit 1
spawn_lens inherited inherited_callback || exit 1
python3 - "${_REPOLENS_SCOPE_SERVERS[0]}" <<'SIGNALS'
import os,signal,sys
fd=os.pidfd_open(int(sys.argv[1]))
for sig in (signal.SIGINT,signal.SIGTERM,signal.SIGHUP):
    signal.pidfd_send_signal(fd,sig)
os.close(fd)
SIGNALS
check "scope supervisor survives orchestrator foreground-group signals" _scope_call 0 state
check "callback can write caller-owned descriptors 8, 9, and 10" wait_all
printf parent >&8
exec 8>&- 9>&- 10>&-
check "caller and callback preserve descriptor 8" test "$(cat "$TMPROOT/inherited-8")" = childparent
check "callback preserves descriptor 9" test "$(cat "$TMPROOT/inherited-9")" = child
check "callback preserves descriptor 10" test "$(cat "$TMPROOT/inherited-10")" = child
# A failed probe acknowledgment has its own bound, even without an outer watchdog.
cat > "$TMPROOT/no-probe-ready" <<'STALL'
#!/usr/bin/env bash
read -r -t 120 ignored
STALL
chmod +x "$TMPROOT/no-probe-ready"
python3 - "$_REPOLENS_SCOPE_HELPER" "$TMPROOT/no-probe-ready" <<'PROBE'
import importlib.util,sys,time
spec=importlib.util.spec_from_file_location('process_scope',sys.argv[1])
module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
module.sys.executable=sys.argv[2]
started=time.monotonic()
try:
    module.probe()
except RuntimeError:
    assert time.monotonic()-started < 7
else:
    raise AssertionError('missing acknowledgment unexpectedly succeeded')
PROBE
check "probe acknowledgment timeout is bounded and fails closed" test "$?" = 0

# A failed enrollment cannot pass GO, and later spawns stop.
(
  init_parallel "$TMPROOT/bad-handshake" 2 || exit 1
  _scope_call() { [[ "$2" != enroll ]] || return 1; _scope_call_real "$@"; }
  forbidden() { touch "$TMPROOT/forbidden"; }
  spawn_lens forbidden forbidden >/dev/null 2>&1 && exit 1
  spawn_lens again forbidden >/dev/null 2>&1 && exit 1
  [[ ! -e "$TMPROOT/forbidden" ]]
); check "failed enrollment starts no callback and stops new spawns" test "$?" = 0
# A gated child that exits before GO cannot enroll or signal a foreign PID.
(
  init_parallel "$TMPROOT/pre-go-exit" 2 || exit 1
  printf() {
    if [[ "${1:-}" == '%s %s\n' ]]; then
      # We are still before ENROLL, so no callback may have executed.
      exit 125
    fi
    # shellcheck disable=SC2059
    builtin printf "$@"
  }
  forbidden() { touch "$TMPROOT/forbidden"; }
  spawn_lens before-go forbidden >/dev/null 2>&1 && exit 1
  [[ ! -e "$TMPROOT/forbidden" ]]
); check "pre-enrollment child exit cannot release a callback" test "$?" = 0
# Abrupt parent loss must clean through retained scope and caller pidfd authority.
cat > "$TMPROOT/parent-exit.sh" <<'PARENT'
set -uo pipefail
source "$1/lib/logging.sh"
source "$1/lib/parallel.sh"
cb() { trap '' TERM; sleep 120 & echo "$!" > "$2/abrupt-descendant"; wait; }
init_parallel "$2/abrupt-sem" 2 || exit 1
spawn_lens abrupt cb "$1" "$2" || exit 1
deadline=$((SECONDS + 3))
while [[ ! -s "$2/abrupt-descendant" ]] && (( SECONDS < deadline )); do sleep 0.02; done
[[ -s "$2/abrupt-descendant" ]] || exit 1
# Record diagnostics before deliberately bypassing wait_all/cleanup.
printf '%s\n' "${_REPOLENS_SCOPE_RUNTIMES[0]}" > "$2/abrupt-runtime"
exit 0
PARENT
output="$(timeout --kill-after=2 12 bash -c 'captured="$(bash "$1/parent-exit.sh" "$2" "$1")"; printf "%s\n" "$captured"' bash "$TMPROOT" "$SCRIPT_DIR" 2>&1)"; rc=$?
check "abrupt parent exit drains inherited writers inside watchdog" test "$rc" = 0
if [[ -s "$TMPROOT/abrupt-runtime" ]]; then
  read -r runtime < "$TMPROOT/abrupt-runtime"
  owned_path="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["path"])' "$runtime/manifest.json")"
  deadline=$((SECONDS + 5))
  while [[ -d "$owned_path" ]] && (( SECONDS < deadline )); do sleep 0.02; done
  check "parent-death supervisor removes kernel-confirmed empty scope" test ! -d "$owned_path"
  rm -rf "$runtime"
else
  check "parent-death scenario actually launched callback" test 1 = 0
fi

# Corrupt each identity dimension with an unrelated live process present.
# Restore known-good test metadata solely to finish test-owned cleanup.
for field in path identity nonce; do
  init_parallel "$TMPROOT/foreign-$field" 2 || exit 1
  stubborn() { trap '' TERM; while true; do sleep 1; done; }
  spawn_lens owned stubborn || exit 1
  runtime="${_REPOLENS_SCOPE_RUNTIMES[0]}"
  cp "$runtime/manifest.json" "$runtime/original.json"
  sleep 60 & foreign=$!
  python3 - "$runtime/manifest.json" "$field" <<'CORRUPT'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); key=sys.argv[2]
d[key] = {'path':'/sys/fs/cgroup', 'identity':[0,0], 'nonce':'foreign'}[key]
json.dump(d,open(p,'w'))
CORRUPT
  wait_all >"$TMPROOT/failure-$field" 2>&1; rc=$?
  check "corrupt $field produces terminal cleanup failure" test "$rc" = 1
  check "corrupt $field preserves diagnostics" test -f "$runtime/terminal-error.json"
  check "corrupt $field leaves foreign process alive" kill -0 "$foreign"
  cp "$runtime/original.json" "$runtime/manifest.json"
  _scope_terminate 0 0 || exit 1
  wait "${_REPOLENS_CHILD_PIDS[0]}" 2>/dev/null || true
  _scope_destroy 0 || exit 1
  _REPOLENS_CHILD_PIDS=()
  _REPOLENS_SCOPE_FAILED=0
  kill "$foreign"; wait "$foreign" 2>/dev/null || true
done
# Preserve per-agent GNU timeout exit classification in both dispatch modes.
source "$SCRIPT_DIR/lib/core.sh"
mkdir -p "$TMPROOT/timeout-bin" "$TMPROOT/timeout-project"
cat > "$TMPROOT/timeout-bin/codex" <<'AGENT'
#!/usr/bin/env bash
if [[ "$TERM_PROFILE" == ignore ]]; then trap '' TERM; else trap 'exit 0' TERM; fi
sleep 120 &
wait
AGENT
chmod +x "$TMPROOT/timeout-bin/codex"
run_and_record() {
  local result_path="$1"
  run_agent codex 'timeout parity' "$TMPROOT/timeout-project" 1 1 >"$result_path.output" 2>&1
  printf '%s\n' "$?" > "$result_path"
}
original_path="$PATH"
export PATH="$TMPROOT/timeout-bin:$PATH"
for TERM_PROFILE in clean ignore; do
  export TERM_PROFILE
  expected=124
  [[ "$TERM_PROFILE" != ignore ]] || expected=137
  run_and_record "$TMPROOT/sequential-$TERM_PROFILE"
  init_parallel "$TMPROOT/parity-$TERM_PROFILE" 2 || exit 1
  spawn_lens parity run_and_record "$TMPROOT/parallel-$TERM_PROFILE" || exit 1
  check "$TERM_PROFILE per-agent timeout drains the parallel scope" wait_all
  check "$TERM_PROFILE sequential timeout retains status $expected" test "$(cat "$TMPROOT/sequential-$TERM_PROFILE")" = "$expected"
  check "$TERM_PROFILE parallel timeout retains status $expected" test "$(cat "$TMPROOT/parallel-$TERM_PROFILE")" = "$expected"
done
export PATH="$original_path"

fi
# Real run_agent topology, including GNU timeout's nested group and setsid.
if [[ "${1:-}" != --topology ]]; then
  output="$(timeout --kill-after=2 25 bash "$0" --topology 2>&1)"; rc=$?
  check "production topology closes inherited output inside watchdog" test "$rc" = 0
  if (( rc != 0 )); then printf '%s\n' "$output"; fi
else
  source "$SCRIPT_DIR/lib/core.sh"
  mkdir -p "$TMPROOT/bin" "$TMPROOT/project"
  cat > "$TMPROOT/bin/codex" <<'CODEX'
#!/usr/bin/env bash
trap '' TERM
printf '%s\n' "$BASHPID" > "$IDENTITY_DIR/agent"
printf '%s\n' "$PPID" > "$IDENTITY_DIR/timeout"
bash -c 'trap "" TERM; echo "$BASHPID" > "$IDENTITY_DIR/helper"; sleep 120 & wait' &
setsid bash -c 'trap "" TERM; echo "$BASHPID" > "$IDENTITY_DIR/session"; sleep 120 & wait' &
wait
CODEX
  chmod +x "$TMPROOT/bin/codex"
  export PATH="$TMPROOT/bin:$PATH" IDENTITY_DIR="$TMPROOT"
  production() {
    printf '%s\n' "$BASHPID" > "$TMPROOT/wrapper"
    run_agent codex 'scope test' "$TMPROOT/project" 120 1
  }
  init_parallel "$TMPROOT/production" 2 || exit 1
  REPOLENS_CHILD_MAX_WAIT=2
  spawn_lens production production || exit 1
  deadline=$((SECONDS + 3))
  while [[ ! -s "$TMPROOT/session" ]] && (( SECONDS < deadline )); do sleep 0.02; done
  for member in wrapper timeout agent helper session; do
    read -r pid < "$TMPROOT/$member" || exit 1
    kill -0 "$pid" || exit 1
    # Unique pid+start-time identity; observations never authorize signals.
    awk '{print $1, $22}' "/proc/$pid/stat" > "$TMPROOT/$member.identity"
  done
  wrapper_group="$(ps -o pgid= -p "$(cat "$TMPROOT/wrapper")" | tr -d ' ')"
  timeout_group="$(ps -o pgid= -p "$(cat "$TMPROOT/timeout")" | tr -d ' ')"
  [[ "$wrapper_group" != "$timeout_group" ]] || exit 1
  wait_all; rc=$?
  [[ "$rc" == 1 ]] || exit 1
  for member in wrapper timeout agent helper session; do
    read -r pid started < "$TMPROOT/$member.identity"
    if [[ -e "/proc/$pid/stat" ]]; then
      read -r state now_started < <(awk '{print $3, $22}' "/proc/$pid/stat")
      [[ "$now_started" != "$started" || "$state" == Z || "$state" == X ]] || exit 1
    fi
  done
fi
echo "Results: $PASS passed, $FAIL failed"
exit "$FAIL"
