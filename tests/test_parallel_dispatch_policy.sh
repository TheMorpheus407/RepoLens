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

# Resolve actual execution mode before requiring a parallel-only capability.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPROOT="$(mktemp -d)"
RUN_IDS=()
# shellcheck disable=SC2329 # Invoked by the EXIT trap.
cleanup() {
  local run_id
  for run_id in "${RUN_IDS[@]:-}"; do [[ -z "$run_id" ]] || rm -rf "$SCRIPT_DIR/logs/$run_id"; done
  rm -rf "$TMPROOT"
}
trap cleanup EXIT
PASS=0 FAIL=0
check() {
  local description="$1"; shift
  if "$@"; then echo "PASS: $description"; PASS=$((PASS + 1));
  else echo "FAIL: $description"; FAIL=$((FAIL + 1)); fi
}
REAL_PYTHON="$(command -v python3)"
export REAL_PYTHON
export PROBE_MARKER="$TMPROOT/probe" AGENT_MARKER="$TMPROOT/agent"
mkdir -p "$TMPROOT/bin" "$TMPROOT/project"
cat > "$TMPROOT/bin/python3" <<'PYTHON'
#!/usr/bin/env bash
if [[ "${1:-}" == */process_scope.py ]]; then
  printf 'unavailable\n' >> "$PROBE_MARKER"
  echo 'simulated unavailable cgroup backend' >&2
  exit 1
fi
exec "$REAL_PYTHON" "$@"
PYTHON
cat > "$TMPROOT/bin/codex" <<'AGENT'
#!/usr/bin/env bash
touch "$AGENT_MARKER"
exit 99
AGENT
cat > "$TMPROOT/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
# Hosted dry-run setup is fully stubbed; no containers or networks are changed.
exit 0
DOCKER
chmod +x "$TMPROOT/bin/"*
printf 'services: {}\n' > "$TMPROOT/project/compose.yml"
git -C "$TMPROOT/project" init -q
git -C "$TMPROOT/project" -c user.name=Test -c user.email=test@example.com add compose.yml
git -C "$TMPROOT/project" -c user.name=Test -c user.email=test@example.com commit -qm initial
for policy in default max-issues hosted cursor-base cursor-override fallback refuse; do
  options=()
  backend_fallback=error
  case "$policy" in
    max-issues) options=(--parallel --max-issues 1) ;;
    hosted) options=(--parallel --hosted) ;;
    cursor-base) options=(--parallel --agent cursor-ide) ;;
    cursor-override) options=(--parallel --agent-override security=cursor-ide) ;;
    fallback) options=(--parallel); backend_fallback=sequential ;;
    refuse) options=(--parallel) ;;
  esac
  rm -f "$PROBE_MARKER"
  PATH="$TMPROOT/bin:$PATH" REPOLENS_PARALLEL_FALLBACK="$backend_fallback" \
    REPOLENS_PROCESS_SCOPE_RESOLVED=stale-inherited-value \
    bash "$SCRIPT_DIR/repolens.sh" --project "$TMPROOT/project" --agent codex \
      --local --focus injection --dry-run --yes "${options[@]}" > "$TMPROOT/$policy.out" 2>&1
  rc=$?
  run_id="$(sed -n 's/.*RepoLens run \([^ ]*\) starting.*/\1/p' "$TMPROOT/$policy.out" | head -1)"
  [[ -z "$run_id" ]] || RUN_IDS+=("$run_id")
  if [[ "$policy" == refuse ]]; then
    check "requested parallel execution still fails closed" test "$rc" -ne 0
    check "refused parallel execution creates no run state" test -z "$run_id"
  else
    check "$policy reaches dry-run on an unsupported host" test "$rc" = 0
    check "$policy reports actual sequential execution" grep -q 'Parallel: false' "$TMPROOT/$policy.out"
    if [[ "$policy" == fallback ]]; then
      check "explicit fallback is visible in dry-run" grep -q 'Process scope: sequential-fallback' "$TMPROOT/$policy.out"
    else
      check "$policy never probes parallel capability" test ! -e "$PROBE_MARKER"
      check "$policy clears inherited backend metadata" bash -c '! grep -q "Process scope:" "$1"' bash "$TMPROOT/$policy.out"
    fi
  fi
  if (( rc != 0 )) && [[ "$policy" != refuse ]]; then cat "$TMPROOT/$policy.out"; fi
done
check "policy dry-runs never execute an agent" test ! -e "$AGENT_MARKER"
echo "Results: $PASS passed, $FAIL failed"
exit "$FAIL"
