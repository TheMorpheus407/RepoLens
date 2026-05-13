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

# Unit and fast integration coverage for per-mode and per-agent timeout resolution.
#
# Contract for issue #110 and issue #184:
#   1. resolve_agent_timeout <mode> [agent] exposes the effective per-invocation
#      timeout without invoking a real agent.
#   2. Precedence is:
#        REPOLENS_AGENT_TIMEOUT_<AGENT>
#        > REPOLENS_AGENT_TIMEOUT
#        > REPOLENS_AGENT_TIMEOUT_<MODE>
#        > hardcoded default.
#   3. Built-in defaults are 1800s unless explicitly overridden.
#   4. The resolved value is what the orchestrator passes to timeout(1)
#      and reports in timeout logs.
#
# Contract for issue #113:
#   5. Agent timeout wrappers pass --kill-after=<grace>s to timeout(1).
#   6. REPOLENS_AGENT_KILL_GRACE defaults to 30s and is configurable.
#
# Contract for issue #183:
#   7. REPOLENS_LENS_MAX_WALL defaults to 3600s and is configurable.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$SCRIPT_DIR/lib/core.sh"
REPO="$SCRIPT_DIR/repolens.sh"
README="$SCRIPT_DIR/README.md"

PASS=0
FAIL=0
TOTAL=0
TMPDIR="$(mktemp -d)"
RUN_ID=""
trap 'rm -rf "$TMPDIR"; [[ -n "${RUN_ID:-}" ]] && rm -rf "$SCRIPT_DIR/logs/$RUN_ID" || true' EXIT

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (expected='$expected' actual='$actual')"
  fi
}

assert_match() {
  local desc="$1" file="$2" pattern="$3"
  TOTAL=$((TOTAL + 1))
  if grep -qE "$pattern" "$file" 2>/dev/null; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (pattern not found: $pattern)"
  fi
}

assert_count_at_least() {
  local desc="$1" file="$2" pattern="$3" min="$4"
  TOTAL=$((TOTAL + 1))
  local n
  n="$(grep -cE "$pattern" "$file" 2>/dev/null || echo 0)"
  if (( n >= min )); then
    PASS=$((PASS + 1))
    echo "  PASS: $desc (found $n)"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (found $n, expected >= $min)"
  fi
}

assert_function_exists() {
  local desc="$1" fn="$2"
  TOTAL=$((TOTAL + 1))
  if declare -F "$fn" >/dev/null 2>&1; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
    return 0
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (missing function: $fn)"
    return 1
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (needle='$needle' not found)"
  fi
}

clear_timeout_env() {
  unset REPOLENS_AGENT_TIMEOUT
  unset REPOLENS_AGENT_TIMEOUT_CLAUDE
  unset REPOLENS_AGENT_TIMEOUT_CODEX
  unset REPOLENS_AGENT_TIMEOUT_OPENCODE
  unset REPOLENS_AGENT_TIMEOUT_SPARK
  unset REPOLENS_AGENT_TIMEOUT_SPARC
  unset REPOLENS_AGENT_TIMEOUT_AUDIT
  unset REPOLENS_AGENT_TIMEOUT_FEATURE
  unset REPOLENS_AGENT_TIMEOUT_BUGFIX
  unset REPOLENS_AGENT_TIMEOUT_BUGREPORT
  unset REPOLENS_AGENT_TIMEOUT_DISCOVER
  unset REPOLENS_AGENT_TIMEOUT_DEPLOY
  unset REPOLENS_AGENT_TIMEOUT_CUSTOM
  unset REPOLENS_AGENT_TIMEOUT_OPENSOURCE
  unset REPOLENS_AGENT_TIMEOUT_CONTENT
  unset REPOLENS_AGENT_KILL_GRACE
  unset REPOLENS_LENS_MAX_WALL
}

resolve_timeout() {
  local mode="$1"
  local agent="${2:-}"
  if declare -F resolve_agent_timeout >/dev/null 2>&1; then
    if [[ -n "$agent" ]]; then
      resolve_agent_timeout "$mode" "$agent"
    else
      resolve_agent_timeout "$mode"
    fi
  else
    printf '%s\n' "__missing_resolve_agent_timeout__"
  fi
}

resolve_kill_grace() {
  if declare -F resolve_agent_kill_grace >/dev/null 2>&1; then
    resolve_agent_kill_grace
  else
    printf '%s\n' "__missing_resolve_agent_kill_grace__"
  fi
}

resolve_wall() {
  if declare -F resolve_lens_max_wall >/dev/null 2>&1; then
    resolve_lens_max_wall
  else
    printf '%s\n' "__missing_resolve_lens_max_wall__"
  fi
}

echo "=== REPOLENS_AGENT_TIMEOUT per-mode defaults ==="

if [[ -f "$CORE" ]]; then
  # shellcheck disable=SC1090,SC1091
  source "$CORE"
else
  echo "  FAIL: Missing $CORE"
  FAIL=$((FAIL + 1))
  TOTAL=$((TOTAL + 1))
fi

if assert_function_exists "lib/core.sh exposes resolve_agent_timeout" "resolve_agent_timeout"; then
  for mode in audit feature bugfix bugreport discover deploy custom opensource content; do
    clear_timeout_env
    assert_eq "Default timeout for $mode is 1800s" "1800" "$(resolve_timeout "$mode")"
  done
else
  echo "  SKIP: resolver default matrix waits for resolve_agent_timeout"
fi

echo ""
echo "=== REPOLENS_AGENT_TIMEOUT precedence ==="

if declare -F resolve_agent_timeout >/dev/null 2>&1; then
  clear_timeout_env
  export REPOLENS_AGENT_TIMEOUT_DEPLOY=42
  assert_eq "Deploy mode-specific override is honored" "42" "$(resolve_timeout deploy)"
  assert_eq "Deploy override does not affect audit" "1800" "$(resolve_timeout audit)"

  clear_timeout_env
  export REPOLENS_AGENT_TIMEOUT_AUDIT=31
  assert_eq "Audit mode-specific override is honored" "31" "$(resolve_timeout audit)"
  assert_eq "Audit override does not affect deploy default" "1800" "$(resolve_timeout deploy)"

  for mode_case in \
    "audit:REPOLENS_AGENT_TIMEOUT_AUDIT:31" \
    "feature:REPOLENS_AGENT_TIMEOUT_FEATURE:32" \
    "bugfix:REPOLENS_AGENT_TIMEOUT_BUGFIX:33" \
    "bugreport:REPOLENS_AGENT_TIMEOUT_BUGREPORT:34" \
    "discover:REPOLENS_AGENT_TIMEOUT_DISCOVER:35" \
    "deploy:REPOLENS_AGENT_TIMEOUT_DEPLOY:36" \
    "custom:REPOLENS_AGENT_TIMEOUT_CUSTOM:37" \
    "opensource:REPOLENS_AGENT_TIMEOUT_OPENSOURCE:38" \
    "content:REPOLENS_AGENT_TIMEOUT_CONTENT:39"; do
    IFS=: read -r mode env_var timeout_value <<<"$mode_case"
    clear_timeout_env
    export "$env_var=$timeout_value"
    assert_eq "$env_var override is honored for $mode" "$timeout_value" "$(resolve_timeout "$mode")"
  done

  clear_timeout_env
  export REPOLENS_AGENT_TIMEOUT=99
  export REPOLENS_AGENT_TIMEOUT_DEPLOY=42
  export REPOLENS_AGENT_TIMEOUT_AUDIT=31
  for mode in audit feature bugfix bugreport discover deploy custom opensource content; do
    assert_eq "Global override wins for $mode" "99" "$(resolve_timeout "$mode")"
  done

  clear_timeout_env
  export REPOLENS_AGENT_TIMEOUT=""
  export REPOLENS_AGENT_TIMEOUT_DEPLOY=77
  assert_eq "Empty global override falls back to mode-specific deploy override" "77" "$(resolve_timeout deploy)"

  clear_timeout_env
  export REPOLENS_AGENT_TIMEOUT_DEPLOY=""
  assert_eq "Empty deploy mode override falls back to deploy default" "1800" "$(resolve_timeout deploy)"
else
  echo "  SKIP: resolver precedence matrix waits for resolve_agent_timeout"
fi

echo ""
echo "=== REPOLENS_AGENT_TIMEOUT per-agent overrides ==="

if declare -F resolve_agent_timeout >/dev/null 2>&1; then
  for agent_case in \
    "claude:REPOLENS_AGENT_TIMEOUT_CLAUDE:11" \
    "codex:REPOLENS_AGENT_TIMEOUT_CODEX:12" \
    "spark:REPOLENS_AGENT_TIMEOUT_SPARK:13" \
    "sparc:REPOLENS_AGENT_TIMEOUT_SPARC:14" \
    "opencode:REPOLENS_AGENT_TIMEOUT_OPENCODE:15" \
    "opencode/qwen3-coder:REPOLENS_AGENT_TIMEOUT_OPENCODE:16"; do
    IFS=: read -r agent env_var timeout_value <<<"$agent_case"
    clear_timeout_env
    export "$env_var=$timeout_value"
    assert_eq "$env_var override is honored for agent $agent" "$timeout_value" "$(resolve_timeout audit "$agent")"
  done

  clear_timeout_env
  export REPOLENS_AGENT_TIMEOUT_SPARK=21
  assert_eq "SPARK override applies to sparc alias" "21" "$(resolve_timeout audit sparc)"

  clear_timeout_env
  export REPOLENS_AGENT_TIMEOUT_SPARC=22
  assert_eq "SPARC override applies to spark alias" "22" "$(resolve_timeout audit spark)"

  clear_timeout_env
  export REPOLENS_AGENT_TIMEOUT_CODEX=12
  export REPOLENS_AGENT_TIMEOUT=99
  export REPOLENS_AGENT_TIMEOUT_AUDIT=31
  assert_eq "Agent-specific override wins over global and mode-specific timeout" "12" "$(resolve_timeout audit codex)"

  clear_timeout_env
  export REPOLENS_AGENT_TIMEOUT_CODEX=""
  export REPOLENS_AGENT_TIMEOUT=99
  assert_eq "Empty agent-specific override falls back to global timeout" "99" "$(resolve_timeout audit codex)"

  clear_timeout_env
  export REPOLENS_AGENT_TIMEOUT_CODEX=""
  export REPOLENS_AGENT_TIMEOUT_AUDIT=31
  assert_eq "Empty agent-specific override falls back to mode-specific timeout" "31" "$(resolve_timeout audit codex)"
else
  echo "  SKIP: per-agent resolver matrix waits for resolve_agent_timeout"
fi

echo ""
echo "=== REPOLENS_AGENT_KILL_GRACE default and override ==="

if assert_function_exists "lib/core.sh exposes resolve_agent_kill_grace" "resolve_agent_kill_grace"; then
  clear_timeout_env
  assert_eq "Default kill grace is 30s" "30" "$(resolve_kill_grace)"

  clear_timeout_env
  export REPOLENS_AGENT_KILL_GRACE=2
  assert_eq "Kill grace override is honored" "2" "$(resolve_kill_grace)"
else
  echo "  SKIP: kill grace resolver waits for resolve_agent_kill_grace"
fi

echo ""
echo "=== REPOLENS_LENS_MAX_WALL default and override ==="

if assert_function_exists "lib/core.sh exposes resolve_lens_max_wall" "resolve_lens_max_wall"; then
  clear_timeout_env
  assert_eq "Default lens wall-clock budget is 3600s" "3600" "$(resolve_wall)"

  clear_timeout_env
  export REPOLENS_LENS_MAX_WALL=42
  assert_eq "Lens wall-clock budget override is honored" "42" "$(resolve_wall)"
else
  echo "  SKIP: lens wall resolver waits for resolve_lens_max_wall"
fi

echo ""
echo "=== Timeout watchdog regressions ==="

assert_count_at_least \
  "lib/core.sh wraps each agent branch with timeout(1) kill-after grace (>=5 call sites)" \
  "$CORE" \
  '^[[:space:]]*timeout[[:space:]]+--kill-after="\$\{kill_grace_secs\}s"[[:space:]]+"\$\{timeout_secs\}s"' \
  5

assert_match \
  "lib/core.sh subshell redirects stdin to /dev/null" \
  "$CORE" \
  'exec[[:space:]]*<[[:space:]]*/dev/null'

assert_match \
  "repolens.sh preflight requires the timeout command" \
  "$REPO" \
  '^require_cmd timeout$'

assert_match \
  "repolens.sh logs timeout failures distinctly" \
  "$REPO" \
  'agent timed out'

assert_match \
  "repolens.sh logs hard-killed timeouts distinctly" \
  "$REPO" \
  'hard-killed after'

echo ""
echo "=== README timeout documentation ==="

assert_match \
  "README documents the global timeout override" \
  "$README" \
  'REPOLENS_AGENT_TIMEOUT'

assert_match \
  "README documents the timeout kill grace override" \
  "$README" \
  'REPOLENS_AGENT_KILL_GRACE'

assert_match \
  "README documents the timeout kill grace default" \
  "$README" \
  'REPOLENS_AGENT_KILL_GRACE.*30|30.*REPOLENS_AGENT_KILL_GRACE'

assert_match \
  "repolens.sh usage documents the timeout kill grace override" \
  "$REPO" \
  'REPOLENS_AGENT_KILL_GRACE'

assert_match \
  "README documents the lens wall-clock budget" \
  "$README" \
  'REPOLENS_LENS_MAX_WALL'

assert_match \
  "README documents the lens wall-clock budget default" \
  "$README" \
  'REPOLENS_LENS_MAX_WALL.*3600|3600.*REPOLENS_LENS_MAX_WALL'

assert_match \
  "repolens.sh usage documents the lens wall-clock budget" \
  "$REPO" \
  'REPOLENS_LENS_MAX_WALL'

for mode_var in \
  REPOLENS_AGENT_TIMEOUT_AUDIT \
  REPOLENS_AGENT_TIMEOUT_FEATURE \
  REPOLENS_AGENT_TIMEOUT_BUGFIX \
  REPOLENS_AGENT_TIMEOUT_BUGREPORT \
  REPOLENS_AGENT_TIMEOUT_DISCOVER \
  REPOLENS_AGENT_TIMEOUT_DEPLOY \
  REPOLENS_AGENT_TIMEOUT_CUSTOM \
  REPOLENS_AGENT_TIMEOUT_OPENSOURCE \
  REPOLENS_AGENT_TIMEOUT_CONTENT; do
  assert_match "README documents $mode_var" "$README" "$mode_var"
done

assert_match \
  "README documents deploy's 1800s default" \
  "$README" \
  'REPOLENS_AGENT_TIMEOUT_DEPLOY.*1800|1800.*REPOLENS_AGENT_TIMEOUT_DEPLOY'

assert_match \
  "README documents audit's 1800s default" \
  "$README" \
  'REPOLENS_AGENT_TIMEOUT_AUDIT.*1800|1800.*REPOLENS_AGENT_TIMEOUT_AUDIT'

assert_match \
  "README documents agent-specific timeout precedence over global override" \
  "$README" \
  'agent-specific|Agent-specific'

for agent_var in \
  REPOLENS_AGENT_TIMEOUT_CLAUDE \
  REPOLENS_AGENT_TIMEOUT_CODEX \
  REPOLENS_AGENT_TIMEOUT_OPENCODE \
  REPOLENS_AGENT_TIMEOUT_SPARK \
  REPOLENS_AGENT_TIMEOUT_SPARC; do
  assert_match "README documents $agent_var" "$README" "$agent_var"
  assert_match "repolens.sh usage documents $agent_var" "$REPO" "$agent_var"
done

assert_match \
  "README documents concrete 30 min x 20 worst-case math" \
  "$README" \
  '30[[:space:]]*min.*20.*10[[:space:]]*hours|1800.*20.*36000'

assert_match \
  "repolens.sh usage documents concrete 30 min x 20 worst-case math" \
  "$REPO" \
  '30[[:space:]]*min.*20.*10[[:space:]]*hours|1800.*20.*36000'

echo ""
echo "=== Resolved timeout reaches agent invocation and timeout log ==="

if ! command -v git >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "  SKIP: git and jq are required for the orchestrator integration check"
else
  PROJECT="$TMPDIR/project"
  mkdir -p "$PROJECT"
  (
    cd "$PROJECT" || exit 1
    git init -q 2>/dev/null
    git config user.email test@example.com
    git config user.name Test
    echo "# test" > README.md
    git add README.md
    git commit -q -m init 2>/dev/null
  ) || true

  FAKE_BIN="$TMPDIR/bin"
  mkdir -p "$FAKE_BIN"
  TIMEOUT_MARKER="$TMPDIR/timeout-args"
  : > "$TIMEOUT_MARKER"

  cat > "$FAKE_BIN/timeout" <<'SH'
#!/usr/bin/env bash
marker="${FAKE_TIMEOUT_MARKER:?marker path required}"
calls="$(wc -l < "$marker" 2>/dev/null | tr -d ' ')"
printf '%s %s\n' "$1" "$2" >> "$marker"
shift 2
if (( calls == 0 )); then
  exit 124
fi
"$@"
SH
  chmod +x "$FAKE_BIN/timeout"

  cat > "$FAKE_BIN/codex" <<'SH'
#!/usr/bin/env bash
echo "Analysis complete. No findings."
echo "DONE"
exit 0
SH
  chmod +x "$FAKE_BIN/codex"

  clear_timeout_env
  : > "$TIMEOUT_MARKER"
  PATH="$FAKE_BIN:$PATH" \
    FAKE_TIMEOUT_MARKER="$TIMEOUT_MARKER" \
    REPOLENS_AGENT_TIMEOUT_CODEX=7 \
    run_agent codex "Prompt text" "$PROJECT" >/dev/null 2>&1
  run_agent_timeout_args="$(head -1 "$TIMEOUT_MARKER" 2>/dev/null || true)"
  assert_eq "run_agent without explicit timeout honors agent-specific Codex override" "--kill-after=30s 7s" "$run_agent_timeout_args"

  : > "$TIMEOUT_MARKER"
  OUT_FILE="$TMPDIR/run.log"
  clear_timeout_env
  PATH="$FAKE_BIN:$PATH" \
    FAKE_TIMEOUT_MARKER="$TIMEOUT_MARKER" \
    REPOLENS_AGENT_TIMEOUT_CODEX=2 \
    REPOLENS_AGENT_KILL_GRACE=2 \
    bash "$REPO" \
      --project "$PROJECT" \
      --agent codex \
      --mode deploy \
      --focus service-health \
      --local \
      --yes \
      >"$OUT_FILE" 2>&1
  exit_code=$?

  run_id="$(grep -oE 'RepoLens run [^ ]+ starting' "$OUT_FILE" | head -1 | awk '{print $3}')"
  RUN_ID="${run_id:-}"

  first_timeout_args="$(head -1 "$TIMEOUT_MARKER" 2>/dev/null || true)"
  log_contents="$(cat "$OUT_FILE")"

  assert_eq "Kill grace is passed to timeout(1)" "--kill-after=2s 2s" "$first_timeout_args"
  assert_contains "Startup log includes configured kill grace" "Agent timeout kill grace: 2s" "$log_contents"
  assert_contains "Startup log includes lens wall budget" "Lens wall-clock budget: 3600s" "$log_contents"
  assert_contains "Timeout log uses Codex agent-specific timeout" "agent timed out after 2s" "$log_contents"

  TOTAL=$((TOTAL + 1))
  if [[ "$exit_code" -eq 0 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: Orchestrator recovered after the synthetic timeout"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: Orchestrator exited with $exit_code"
    echo "---- run.log ----"
    cat "$OUT_FILE"
    echo "-----------------"
  fi
fi

echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
exit "$FAIL"
