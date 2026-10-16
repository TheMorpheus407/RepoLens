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

# A sequential audit must reject missing report prerequisites before run state
# or agent dispatch. Use a restricted PATH and dry runs; no real models/forges.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
failed=0 checks=0
check() {
  checks=$((checks + 1))
  if ! "$@"; then
    printf 'FAIL: %s: %s\n' "$scenario" "$*"
    failed=$((failed + 1))
  fi
}
mkdir -p "$FIXTURE/bin" "$FIXTURE/app/logs" "$FIXTURE/project"
# Symlink the runtime into a fixture so any pre-fix run state stays isolated.
for path in repolens.sh lib config prompts; do
  ln -s "$REPO/$path" "$FIXTURE/app/$path"
done
for cmd in bash git jq timeout dirname basename cat sed tr date od mkdir flock \
  head rm wc sort find cut awk realpath readlink stat uname mktemp env touch \
  cmp sha256sum nproc grep mv; do
  cmd_path="$(command -v "$cmd")" || continue
  ln -s "$cmd_path" "$FIXTURE/bin/$cmd"
done
cat > "$FIXTURE/bin/codex" <<'AGENT'
#!/usr/bin/env bash
printf 'unexpected dispatch\n' > "${AGENT_MARKER:?}"
exit 99
AGENT
chmod +x "$FIXTURE/bin/codex"
export AGENT_MARKER="$FIXTURE/agent"
git -C "$FIXTURE/project" init -q
git -C "$FIXTURE/project" -c user.name=Test -c user.email=test@example.com \
  commit --allow-empty -qm initial

for scenario in sequential forced-sequential python-present help; do
  previous_failures="$failed"
  rm -rf -- "$FIXTURE/app/logs"
  mkdir "$FIXTURE/app/logs"
  options=(--project "$FIXTURE/project" --agent codex --mode audit --local \
    --focus injection --dry-run --yes)
  case "$scenario" in
    forced-sequential) options+=(--parallel --max-issues 1) ;;
    python-present) ln -s "$(command -v python3)" "$FIXTURE/bin/python3" ;;
    help) rm "$FIXTURE/bin/python3"; options=(--help) ;;
  esac
  rc=0
  PATH="$FIXTURE/bin" bash "$FIXTURE/app/repolens.sh" "${options[@]}" \
    > "$FIXTURE/$scenario.log" 2>&1 || rc=$?
  if [[ "$scenario" == sequential || "$scenario" == forced-sequential ]]; then
    check test "$rc" -ne 0
    check grep -q 'Missing required command: python3' "$FIXTURE/$scenario.log"
    check test -z "$(find "$FIXTURE/app/logs" -mindepth 1 -print -quit)"
  else
    check test "$rc" -eq 0
    if [[ "$scenario" == python-present ]]; then
      check grep -q 'Parallel: false' "$FIXTURE/$scenario.log"
    else
      check grep -q 'Usage: repolens.sh' "$FIXTURE/$scenario.log"
    fi
  fi
  check test ! -e "$AGENT_MARKER"
  if (( failed > previous_failures )); then cat "$FIXTURE/$scenario.log"; fi
done
printf 'Python preflight: %s checks, %s failures.\n' "$checks" "$failed"
(( failed == 0 ))
