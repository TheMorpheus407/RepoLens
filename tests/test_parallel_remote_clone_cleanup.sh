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

# Real scoped CLI workers with default heartbeat; only git clone and the agent
# executable are mocked. A completed worker must not delete their shared clone.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/parallel.sh"
source "$SCRIPT_DIR/tests/process_scope_test_support.sh"
require_process_scopes
TEST_DIR="$(mktemp -d)"
RUN_PID="" RUN_ID=""
PASS=0 FAIL=0
# shellcheck disable=SC2329 # Invoked by the EXIT trap.
cleanup() {
  if [[ -n "$RUN_PID" ]]; then
    kill -TERM "$RUN_PID" 2>/dev/null || true
    wait "$RUN_PID" 2>/dev/null || true
  fi
  if [[ -f "$TEST_DIR/clone-path" ]]; then
    local clone
    read -r clone < "$TEST_DIR/clone-path"
    chmod -R u+w "$clone" 2>/dev/null || true
    rm -rf -- "$clone"
  fi
  [[ -z "$RUN_ID" ]] || rm -rf -- "$SCRIPT_DIR/logs/$RUN_ID"
  rm -rf -- "$TEST_DIR"
}
trap cleanup EXIT
check() {
  local description="$1"; shift
  if "$@"; then PASS=$((PASS + 1)); echo "PASS: $description";
  else FAIL=$((FAIL + 1)); echo "FAIL: $description"; fi
}
wait_for_file() {
  local file="$1" deadline=$((SECONDS + 15))
  while [[ ! -f "$file" ]] && (( SECONDS < deadline )); do sleep 0.02; done
  [[ -f "$file" ]]
}

mkdir -p "$TEST_DIR/project" "$TEST_DIR/bin"
git init -q "$TEST_DIR/project" || exit 1
printf 'shared source fixture\n' > "$TEST_DIR/project/README.md"
git -C "$TEST_DIR/project" add README.md || exit 1
git -C "$TEST_DIR/project" -c user.name=Test -c user.email=test@example.invalid commit -qm fixture || exit 1
export REPOLENS_TEST_WORKER_DIR="$TEST_DIR" REPOLENS_TEST_WORKER_GIT
REPOLENS_TEST_WORKER_GIT="$(command -v git)"
cat > "$TEST_DIR/bin/git" <<'GIT'
#!/usr/bin/env bash
set -uo pipefail
if [[ "$1" == clone ]]; then
  target="${!#}"
  "$REPOLENS_TEST_WORKER_GIT" clone -q "$REPOLENS_TEST_WORKER_DIR/project" "$target" || exit 1
  printf '%s\n' "$target" > "$REPOLENS_TEST_WORKER_DIR/clone-path"
  exit 0
fi
exec "$REPOLENS_TEST_WORKER_GIT" "$@"
GIT
cat > "$TEST_DIR/bin/codex" <<'AGENT'
#!/usr/bin/env bash
set -uo pipefail
if mkdir "$REPOLENS_TEST_WORKER_DIR/first-agent" 2>/dev/null; then role=fast; else role=slow; fi
[[ ! -f "$PWD/README.md" ]] || touch "$REPOLENS_TEST_WORKER_DIR/$role.source-start"
touch "$REPOLENS_TEST_WORKER_DIR/$role.started"
deadline=$((SECONDS + 20))
while [[ ! -f "$REPOLENS_TEST_WORKER_DIR/$role.release" ]] && (( SECONDS < deadline )); do sleep 0.02; done
[[ -f "$REPOLENS_TEST_WORKER_DIR/$role.release" ]] || exit 90
[[ ! -f "$PWD/README.md" ]] || touch "$REPOLENS_TEST_WORKER_DIR/$role.source-finish"
printf 'Analysis complete. No findings.\nDONE\n'
AGENT
chmod +x "$TEST_DIR/bin/git" "$TEST_DIR/bin/codex"
for provider in gh glab tea fj; do
  printf '#!/usr/bin/env bash\ntouch "$REPOLENS_TEST_WORKER_DIR/forbidden-forge"\nexit 99\n' > "$TEST_DIR/bin/$provider"
  chmod +x "$TEST_DIR/bin/$provider"
done

# Unset both knobs so this catches the production default (15s), including the
# synchronous first heartbeat and the handler restored after normal completion.
env -u REPOLENS_HEARTBEAT_INTERVAL -u REPOLENS_LENS_HEARTBEAT_INTERVAL \
  PATH="$TEST_DIR/bin:$PATH" REPOLENS_AGENT_TIMEOUT=25 \
  timeout --kill-after=2 35 bash "$SCRIPT_DIR/repolens.sh" \
    --project https://example.invalid/test.git --agent codex --domain i18n \
    --mode audit --local --yes --parallel --max-parallel 2 --depth 1 \
    > "$TEST_DIR/cli.log" 2>&1 &
RUN_PID=$!
check "first mocked lens started" wait_for_file "$TEST_DIR/fast.started"
check "second mocked lens started concurrently" wait_for_file "$TEST_DIR/slow.started"
RUN_ID="$(sed -n 's/.*RepoLens run \([^ ]*\) starting.*/\1/p' "$TEST_DIR/cli.log" | head -1)"
if [[ -z "$RUN_ID" ]]; then cat "$TEST_DIR/cli.log"; exit 1; fi
run_dir="$SCRIPT_DIR/logs/$RUN_ID"
check "both workers initially see the cloned source" test -f "$TEST_DIR/fast.source-start" -a -f "$TEST_DIR/slow.source-start"
heartbeat_count="$(find "$run_dir/.heartbeat" -maxdepth 1 -name '*.json' -type f | wc -l | tr -d ' ')"
check "default per-lens heartbeat is active in both workers" test "$heartbeat_count" = 2

touch "$TEST_DIR/fast.release"
# Collection removes the first token only after its worker and heartbeat writer
# have exited. Release the second agent after that boundary, never on a sleep.
deadline=$((SECONDS + 15))
while (( SECONDS < deadline )); do
  tokens="$(find "$run_dir/.semaphore" -maxdepth 1 -name '*.token' -type f | wc -l | tr -d ' ')"
  [[ "$tokens" != 1 ]] || break
  sleep 0.02
done
check "first worker finishes and is collected while second remains active" test "$tokens" = 1
touch "$TEST_DIR/slow.release"
wait "$RUN_PID"; rc=$?
RUN_PID=""
check "remote CLI completes successfully" test "$rc" = 0
check "second lens retains source after first worker exits" test -f "$TEST_DIR/slow.source-finish"
read -r clone < "$TEST_DIR/clone-path"
check "parent removes the shared clone when the run finishes" test ! -d "$clone"
check "parent collects every semaphore token" test "$(find "$run_dir/.semaphore" -name '*.token' | wc -l | tr -d ' ')" = 0
check "worker heartbeat cleanup removes completed heartbeat files" test "$(find "$run_dir/.heartbeat" -name '*.json' | wc -l | tr -d ' ')" = 0
check "local test never invokes a forge client" test ! -e "$TEST_DIR/forbidden-forge"
(( FAIL == 0 )) || cat "$TEST_DIR/cli.log"
printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
