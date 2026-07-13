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
#
# Behavioural contract for `--agent copilot`: native support for the GitHub
# Copilot CLI, invoked through `gh copilot` (the `gh` CLI itself auto-downloads
# the Copilot CLI on first run, so users only need `gh` installed and
# authenticated). Modeled on tests/test_antigravity_agent.sh, which locked the
# same five choke points (validate_agent, require_agent_cmd,
# resolve_agent_timeout, run_agent dispatch, --help sync) for the antigravity
# agent.
#
# Dispatch shape under test (PLAIN-TEXT wrapper path, like codex/opencode/
# antigravity — NOT the claude JSON-envelope path):
#
#     gh copilot -p "$prompt" --allow-all-tools --no-ask-user --no-color -s
#
#   * `gh copilot`          -> runs the GitHub Copilot CLI; `gh` auto-downloads
#                              it on first use, so only `gh` itself is required.
#   * `-p`                  -> headless (non-interactive) invocation.
#   * `--allow-all-tools`   -> auto-approve all tool calls; required for
#                              non-interactive mode so an unattended lens never
#                              blocks on a permission prompt (stdin is closed).
#   * `--no-ask-user`       -> disables the ask_user tool for the same reason.
#   * `--no-color` / `-s`   -> keep stdout to the plain-text agent response so
#                              the DONE-streak detector reads it unchanged.
#   * `copilot/<model>`     -> adds `--model <model>` to pin a specific model.
#
# NO REAL MODEL IS EVER INVOKED (CLAUDE.md::Tests). `gh` and `timeout` are PATH
# shims that record their argv and emit canned output; the unit sections source
# lib/core.sh and call its functions directly; the integration sections drive
# repolens.sh under --dry-run / --local (no real agent executes).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$SCRIPT_DIR/lib/core.sh"
REPOLENS_SH="$SCRIPT_DIR/repolens.sh"

PASS=0
FAIL=0
TOTAL=0

TMPDIR="$(mktemp -d)"
CREATED_RUN_IDS=()
cleanup() {
  local run_id
  rm -rf "$TMPDIR"
  for run_id in "${CREATED_RUN_IDS[@]:-}"; do
    [[ -n "$run_id" ]] && rm -rf "$SCRIPT_DIR/logs/$run_id"
  done
}
trap cleanup EXIT

pass_with() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail_with() {
  local desc="$1" detail="${2:-}"
  FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
  [[ -n "$detail" ]] && printf '    %s\n' "$detail"
}
assert_eq() {
  local desc="$1" expected="$2" actual="$3"; TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then pass_with "$desc"
  else fail_with "$desc" "expected='$expected' actual='$actual'"; fi
}
assert_success() {
  local desc="$1" actual="$2"; TOTAL=$((TOTAL + 1))
  if [[ "$actual" -eq 0 ]]; then pass_with "$desc"
  else fail_with "$desc" "expected exit 0, got $actual"; fi
}
assert_failure() {
  local desc="$1" actual="$2"; TOTAL=$((TOTAL + 1))
  if [[ "$actual" -ne 0 ]]; then pass_with "$desc"
  else fail_with "$desc" "expected non-zero exit, got 0"; fi
}
assert_contains() {
  local desc="$1" needle="$2" haystack="$3"; TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then pass_with "$desc"
  else fail_with "$desc" "expected to find '$needle' in: '$haystack'"; fi
}
assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"; TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then pass_with "$desc"
  else fail_with "$desc" "did NOT expect '$needle' in: '$haystack'"; fi
}

# --------------------------------------------------------------------------
# Hermetic shims. FAKE_BIN holds recording stand-ins for `gh` (copilot is
# invoked as `gh copilot ...`) and `timeout` (so we can observe the wrapper
# args without a real subprocess clock).
# --------------------------------------------------------------------------
FAKE_BIN="$TMPDIR/bin"
mkdir -p "$FAKE_BIN"

# gh shim: only the `copilot` subcommand is relevant here. It records its exact
# trailing argv into GH_COPILOT_ARGS_MARKER, prints canned stdout (default
# DONE), and exits with a caller-chosen code. Any other `gh` invocation (e.g.
# forge auth/label calls elsewhere in the codebase) is a harmless no-op so this
# shim never interferes outside the copilot dispatch path.
cat > "$FAKE_BIN/gh" <<'SHIM'
#!/usr/bin/env bash
if [[ "${1:-}" == "copilot" ]]; then
  shift
  if [[ -n "${GH_COPILOT_ARGS_MARKER:-}" ]]; then
    printf '%s\n' "$*" >> "$GH_COPILOT_ARGS_MARKER"
  fi
  printf '%s\n' "${GH_COPILOT_STDOUT_TEXT:-DONE}"
  exit "${GH_COPILOT_EXIT_CODE:-0}"
fi
echo DONE
exit 0
SHIM
chmod +x "$FAKE_BIN/gh"

# timeout shim: records the two leading timeout(1) args plus the wrapped
# command ("$*") so we can prove the copilot arm is wrapped in
# `timeout --kill-after=<grace>s <secs>s` AND that the wrapped binary is `gh`,
# then shifts those two args and execs the real (shimmed) command so exit codes
# and stdout propagate untouched.
cat > "$FAKE_BIN/timeout" <<'SHIM'
#!/usr/bin/env bash
if [[ -n "${FAKE_TIMEOUT_MARKER:-}" ]]; then
  printf '%s\n' "$*" >> "$FAKE_TIMEOUT_MARKER"
fi
shift 2
exec "$@"
SHIM
chmod +x "$FAKE_BIN/timeout"

# claude/codex/opencode/agy shims: only needed so repolens.sh preflight
# require_cmd stays deterministic in the --dry-run integration section (it
# never runs them).
for _agent_bin in claude codex opencode agy; do
  printf '#!/usr/bin/env bash\necho DONE\n' > "$FAKE_BIN/$_agent_bin"
  chmod +x "$FAKE_BIN/$_agent_bin"
done
unset _agent_bin

GH_COPILOT_ARGS_MARKER="$TMPDIR/gh-copilot-args"
TIMEOUT_MARKER="$TMPDIR/timeout-args"

# --------------------------------------------------------------------------
# Source lib/core.sh so the unit sections can call the agent functions directly
# (validate_agent / require_agent_cmd / resolve_agent_timeout / run_agent).
# These functions call `die` (which exits) on the error path, so every failing
# call is captured inside a command substitution — its subshell absorbs the exit.
# --------------------------------------------------------------------------
if [[ -f "$CORE" ]]; then
  # shellcheck disable=SC1090,SC1091
  source "$CORE"
else
  echo "  FAIL: missing $CORE"; exit 1
fi

echo ""
echo "=== Section 1: validate_agent accepts copilot ==="

out="$(validate_agent copilot 2>&1)"; rc=$?
assert_success "validate_agent copilot is accepted" "$rc"

out="$(validate_agent copilot/gpt-5.4 2>&1)"; rc=$?
assert_success "validate_agent copilot/<model> is accepted" "$rc"

out="$(validate_agent copilot/ 2>&1)"; rc=$?
assert_failure "validate_agent copilot/ (empty model) is rejected" "$rc"
assert_contains "empty-model rejection names the missing model" "missing model after" "$out"

# The reject message for a truly-invalid agent must advertise copilot as a
# valid option, so operators discover the new value from the error itself.
out="$(validate_agent not-a-real-agent 2>&1)"; rc=$?
assert_failure "a bogus agent is still rejected" "$rc"
assert_contains "reject message advertises copilot as a valid agent" "copilot" "$out"

echo ""
echo "=== Section 2: require_agent_cmd maps copilot -> the gh binary ==="

# With gh present on PATH, the preflight passes.
out="$(PATH="$FAKE_BIN:$PATH" require_agent_cmd copilot 2>&1)"; rc=$?
assert_success "require_agent_cmd copilot succeeds when the gh binary exists" "$rc"

out="$(PATH="$FAKE_BIN:$PATH" require_agent_cmd copilot/gpt-5.4 2>&1)"; rc=$?
assert_success "require_agent_cmd copilot/<model> succeeds when the gh binary exists" "$rc"

# With gh absent, it must fail fast through the shared require_cmd path
# (naming the missing binary) — so a missing install is caught at startup, not
# 200 lenses deep. The message must name `gh`, the real binary, not `copilot`
# (the flag), proving the correct decoupling (mirrors antigravity -> agy).
NO_GH_BIN="$TMPDIR/nogh"
mkdir -p "$NO_GH_BIN"
out="$(PATH="$NO_GH_BIN" require_agent_cmd copilot 2>&1)"; rc=$?
assert_failure "require_agent_cmd copilot fails when the gh binary is missing" "$rc"
assert_contains "missing binary is reported as gh via require_cmd (not 'copilot')" \
  "Missing required command: gh" "$out"

echo ""
echo "=== Section 3: resolve_agent_timeout honours REPOLENS_AGENT_TIMEOUT_COPILOT ==="

# Per-agent override is honoured for copilot (precedence tier 1).
out="$(REPOLENS_AGENT_TIMEOUT_COPILOT=17 resolve_agent_timeout audit copilot)"
assert_eq "REPOLENS_AGENT_TIMEOUT_COPILOT is honoured for the copilot agent" "17" "$out"

# Agent-specific override beats the global REPOLENS_AGENT_TIMEOUT — matching
# the documented precedence for every other agent.
out="$(REPOLENS_AGENT_TIMEOUT_COPILOT=17 REPOLENS_AGENT_TIMEOUT=99 resolve_agent_timeout audit copilot)"
assert_eq "copilot-specific timeout wins over the global override" "17" "$out"

# An empty copilot override falls back to the global timeout.
out="$(REPOLENS_AGENT_TIMEOUT_COPILOT='' REPOLENS_AGENT_TIMEOUT=88 resolve_agent_timeout audit copilot)"
assert_eq "empty copilot timeout falls back to the global override" "88" "$out"

# Precedence tier 3: with no agent-specific var and no global
# REPOLENS_AGENT_TIMEOUT, the per-mode var applies.
out="$(unset REPOLENS_AGENT_TIMEOUT REPOLENS_AGENT_TIMEOUT_COPILOT
       REPOLENS_AGENT_TIMEOUT_AUDIT=44 resolve_agent_timeout audit copilot)"
assert_eq "copilot falls back to the per-mode timeout when no agent/global var is set" "44" "$out"

# Precedence tier 4 (baseline): with NO timeout env at all, copilot resolves to
# the hardcoded 1800 default.
out="$(unset REPOLENS_AGENT_TIMEOUT REPOLENS_AGENT_TIMEOUT_COPILOT REPOLENS_AGENT_TIMEOUT_AUDIT
       resolve_agent_timeout audit copilot)"
assert_eq "copilot uses the hardcoded 1800 default when no timeout env is set" "1800" "$out"

echo ""
echo "=== Section 4: run_agent copilot dispatches the gh copilot plain-text wrapper ==="

AGENT_PROJECT="$TMPDIR/agent-proj"
mkdir -p "$AGENT_PROJECT"

# 4a. Dispatch shape: copilot is invoked as
# `gh copilot -p <prompt> --allow-all-tools --no-ask-user --no-color -s`,
# wrapped in `timeout --kill-after=<grace>s <secs>s`. run_agent's 4th/5th
# positional args are timeout_secs=5 and kill_grace_secs=1, so the wrapper must
# read `--kill-after=1s 5s gh`.
: > "$GH_COPILOT_ARGS_MARKER"; : > "$TIMEOUT_MARKER"
out="$(PATH="$FAKE_BIN:$PATH" \
       FAKE_TIMEOUT_MARKER="$TIMEOUT_MARKER" \
       GH_COPILOT_ARGS_MARKER="$GH_COPILOT_ARGS_MARKER" \
       GH_COPILOT_STDOUT_TEXT="hello from copilot" \
       run_agent copilot "SAFE_PROMPT_MARKER" "$AGENT_PROJECT" 5 1 2>&1)"
rc=$?
timeout_args="$(cat "$TIMEOUT_MARKER")"
gh_args="$(cat "$GH_COPILOT_ARGS_MARKER")"

assert_success "run_agent copilot exits 0 on a successful run" "$rc"
assert_contains "the gh binary is wrapped in timeout --kill-after=1s 5s" \
  "--kill-after=1s 5s gh" "$timeout_args"
assert_contains "gh copilot gets the headless -p prompt flag with the prompt" \
  "-p SAFE_PROMPT_MARKER" "$gh_args"
assert_contains "gh copilot gets --allow-all-tools for non-interactive auto-approve" \
  "--allow-all-tools" "$gh_args"
assert_contains "gh copilot gets --no-ask-user so it never blocks on the ask_user tool" \
  "--no-ask-user" "$gh_args"
assert_contains "gh copilot gets -s/--no-color for clean plain-text stdout" \
  "-s" "$gh_args"

# 4a continued. Plain-text passthrough: gh copilot's stdout reaches the caller
# verbatim so the DONE-streak detector reads it (the codex/opencode/antigravity
# text path, not the claude JSON path). Checked here, before the next call
# below overwrites $out.
assert_contains "gh copilot stdout is passed through to the caller as plain text" \
  "hello from copilot" "$out"

# 4b. copilot/<model> adds --model <model> to the gh copilot invocation.
: > "$GH_COPILOT_ARGS_MARKER"; : > "$TIMEOUT_MARKER"
out="$(PATH="$FAKE_BIN:$PATH" \
       FAKE_TIMEOUT_MARKER="$TIMEOUT_MARKER" \
       GH_COPILOT_ARGS_MARKER="$GH_COPILOT_ARGS_MARKER" \
       run_agent copilot/gpt-5.4 "p" "$AGENT_PROJECT" 5 1 2>&1)"
gh_args="$(cat "$GH_COPILOT_ARGS_MARKER")"
assert_contains "copilot/<model> passes --model <model> to gh copilot" \
  "--model gpt-5.4" "$gh_args"

# 4c. NOT the JSON-envelope path: a Copilot answer that happens to look like
# JSON must survive intact — never reduced to a `.result` field the way the
# claude arm extracts.
: > "$GH_COPILOT_ARGS_MARKER"; : > "$TIMEOUT_MARKER"
out="$(PATH="$FAKE_BIN:$PATH" \
       FAKE_TIMEOUT_MARKER="$TIMEOUT_MARKER" \
       GH_COPILOT_ARGS_MARKER="$GH_COPILOT_ARGS_MARKER" \
       GH_COPILOT_STDOUT_TEXT='{"result":"WRONG_EXTRACTED","response":"real answer"}' \
       run_agent copilot "p" "$AGENT_PROJECT" 5 1 2>&1)"
assert_contains "JSON-shaped gh copilot output is not collapsed to .result" \
  '"response":"real answer"' "$out"

# 4d. Failure-path (MANDATORY): when gh copilot exits non-zero, run_agent must
# propagate the REAL exit code, not swallow it to 0. 42 is deliberately
# distinct from die's generic 1, so a rc of 42 proves genuine propagation of
# the child's status through the timeout wrapper.
: > "$GH_COPILOT_ARGS_MARKER"; : > "$TIMEOUT_MARKER"
out="$(PATH="$FAKE_BIN:$PATH" \
       FAKE_TIMEOUT_MARKER="$TIMEOUT_MARKER" \
       GH_COPILOT_ARGS_MARKER="$GH_COPILOT_ARGS_MARKER" \
       GH_COPILOT_EXIT_CODE=42 \
       run_agent copilot "p" "$AGENT_PROJECT" 5 1 2>&1)"
rc=$?
assert_eq "run_agent copilot propagates a failing gh copilot exit code" "42" "$rc"

echo ""
echo "=== Section 5: --dry-run --agent copilot is accepted and priced without an opencode fallback ==="

# End-to-end through repolens.sh: parse -> validate_agent -> require_agent_cmd
# -> dry-run cost preview must all accept copilot, and the cost estimate must
# price the run with its own copilot-default model rather than silently
# falling back to the opencode-default label (config/agent-pricing.json
# agent_default_model entry: "copilot": "copilot-default").
GIT_PROJECT="$TMPDIR/dry-proj"
mkdir -p "$GIT_PROJECT"
git -C "$GIT_PROJECT" init -q
printf '# copilot dry-run test\nprint("x")\n' > "$GIT_PROJECT/a.py"
git -C "$GIT_PROJECT" -c user.email=t@t -c user.name=t add -A >/dev/null 2>&1 || true
git -C "$GIT_PROJECT" -c user.email=t@t -c user.name=t commit -q -m init >/dev/null 2>&1 || true

DRY_OUT="$TMPDIR/dry-out.txt"
PATH="$FAKE_BIN:$PATH" \
  bash "$REPOLENS_SH" \
    --project "$GIT_PROJECT" \
    --agent copilot \
    --mode audit \
    --domain security \
    --dry-run \
    --yes \
    --local \
    --output "$TMPDIR/issues-copilot" \
    >"$DRY_OUT" 2>&1
rc=$?
dry_output="$(cat "$DRY_OUT")"
run_id="$(grep -oE 'RepoLens run [^ ]+ starting' "$DRY_OUT" 2>/dev/null | head -1 | awk '{print $3}')"
[[ -n "$run_id" ]] && CREATED_RUN_IDS+=("$run_id")

# The cost breakdown emits a `  model:      <label>  —  ...` line for the
# resolved agent model; isolate it for the pricing assertions.
model_line="$(grep -iE '^[[:space:]]*model:' "$DRY_OUT" | head -1)"

assert_success "--dry-run --agent copilot exits 0" "$rc"
assert_contains "copilot dry-run reaches completion" "Dry run complete" "$dry_output"
assert_contains "cost estimate resolves the GitHub Copilot CLI model label" \
  "github copilot" "${model_line,,}"
assert_not_contains "copilot is not mispriced as the opencode-default fallback" \
  "opencode" "${model_line,,}"

echo ""
echo "=== Section 6: a real scan actually dispatches a lens to the gh copilot binary ==="

# Sections 4-5 prove the run_agent unit call and the --dry-run preflight.
# NEITHER exercises a real scan reaching run_agent copilot: --dry-run stops
# before any agent runs. This section drives a full single-lens scan
# (--depth 1) under recording shims and NO fake `timeout` (the real timeout
# wraps the copilot arm), proving the whole parse -> route -> run_agent
# copilot -> DONE-streak path works and that gh copilot's plain-text DONE
# actually drives the streak to completion.
E2E_BIN="$TMPDIR/e2e-bin"
mkdir -p "$E2E_BIN"

# gh shim: records the FULL argv (not just the basename) so the assertions can
# distinguish an actual `gh copilot ...` dispatch from any unrelated `gh` call
# elsewhere in the codebase (e.g. forge auth/label lookups), which would never
# have "copilot" as its first argument.
cat > "$E2E_BIN/gh" <<'SHIM'
#!/usr/bin/env bash
[[ -n "${REPOLENS_OVERRIDE_INVOKE_LOG:-}" ]] && printf 'gh %s\n' "$*" >> "$REPOLENS_OVERRIDE_INVOKE_LOG"
if [[ "${1:-}" == "copilot" ]]; then
  echo "DONE"
  exit 0
fi
echo DONE
exit 0
SHIM
chmod +x "$E2E_BIN/gh"

# Other agent binaries: only needed so an unexpected routing choice is
# observable (and never silently no-ops via a missing-binary die).
for _e2e_bin in claude codex opencode agy; do
  cat > "$E2E_BIN/$_e2e_bin" <<'SHIM'
#!/usr/bin/env bash
[[ -n "${REPOLENS_OVERRIDE_INVOKE_LOG:-}" ]] && printf '%s\n' "$(basename "$0")" >> "$REPOLENS_OVERRIDE_INVOKE_LOG"
echo "DONE"
SHIM
  chmod +x "$E2E_BIN/$_e2e_bin"
done
unset _e2e_bin

e2e_make_project() {
  local project="$1"
  mkdir -p "$project"
  git -C "$project" init -q
  printf '# copilot e2e dispatch test\n' > "$project/README.md"
  git -C "$project" -c user.email=t@t -c user.name=t add -A >/dev/null 2>&1 || true
  git -C "$project" -c user.email=t@t -c user.name=t commit -q -m init >/dev/null 2>&1 || true
}
e2e_register_run_id() {
  local out_file="$1" run_id
  run_id="$(grep -oE 'RepoLens run [^ ]+ starting' "$out_file" 2>/dev/null | head -1 | awk '{print $3}')"
  [[ -n "$run_id" ]] && CREATED_RUN_IDS+=("$run_id")
}

# 6a. `--agent copilot` end-to-end: the security lens must be run through
# `gh copilot ...` (and no other agent binary), and the scan must complete
# cleanly — proving the real parse->validate->route->run_agent copilot->streak
# path, not just the white-box run_agent call from Section 4.
E2E_PROJ_A="$TMPDIR/e2e-proj-a"
e2e_make_project "$E2E_PROJ_A"
E2E_LOG_A="$TMPDIR/e2e-invoke-a.log"; : > "$E2E_LOG_A"
E2E_OUT_A="$TMPDIR/e2e-out-a.txt"
PATH="$E2E_BIN:$PATH" \
  REPOLENS_OVERRIDE_INVOKE_LOG="$E2E_LOG_A" \
  REPOLENS_AGENT_TIMEOUT=5 \
  REPOLENS_AGENT_KILL_GRACE=1 \
  bash "$REPOLENS_SH" \
    --project "$E2E_PROJ_A" \
    --agent copilot \
    --mode audit \
    --depth 1 \
    --local \
    --yes \
    --focus authorization \
    --output "$TMPDIR/e2e-issues-a" \
    >"$E2E_OUT_A" 2>&1
rc=$?
e2e_register_run_id "$E2E_OUT_A"
e2e_invoked_a="$(cat "$E2E_LOG_A")"
assert_success "--agent copilot end-to-end scan exits 0" "$rc"
assert_contains "the lens is actually run through gh copilot" "gh copilot" "$e2e_invoked_a"
assert_not_contains "no other agent binary runs the lens under --agent copilot" \
  "codex" "$e2e_invoked_a"

# 6b. `--agent-override <domain>=copilot` routes that domain's lens to
# gh copilot even though the global agent is codex.
E2E_PROJ_B="$TMPDIR/e2e-proj-b"
e2e_make_project "$E2E_PROJ_B"
E2E_LOG_B="$TMPDIR/e2e-invoke-b.log"; : > "$E2E_LOG_B"
E2E_OUT_B="$TMPDIR/e2e-out-b.txt"
PATH="$E2E_BIN:$PATH" \
  REPOLENS_OVERRIDE_INVOKE_LOG="$E2E_LOG_B" \
  REPOLENS_AGENT_TIMEOUT=5 \
  REPOLENS_AGENT_KILL_GRACE=1 \
  bash "$REPOLENS_SH" \
    --project "$E2E_PROJ_B" \
    --agent codex \
    --mode audit \
    --depth 1 \
    --local \
    --yes \
    --agent-override security=copilot \
    --focus authorization \
    --output "$TMPDIR/e2e-issues-b" \
    >"$E2E_OUT_B" 2>&1
rc=$?
e2e_register_run_id "$E2E_OUT_B"
e2e_invoked_b="$(cat "$E2E_LOG_B")"
e2e_out_b="$(cat "$E2E_OUT_B")"
assert_success "--agent-override security=copilot scan exits 0" "$rc"
assert_contains "the overridden security lens is routed through gh copilot" \
  "gh copilot" "$e2e_invoked_b"
assert_not_contains "the global codex does NOT run the overridden security lens" \
  "codex" "$e2e_invoked_b"
assert_contains "the routing note records the copilot override for audit" \
  "Routed to agent 'copilot'" "$e2e_out_b"

echo ""
echo "=== Section 7: --help advertises copilot and its timeout env var (in sync with code) ==="

# --help must stay in sync with validate_agent's accept-list — otherwise the
# in-CLI reference contradicts real behaviour.
help_out="$(bash "$REPOLENS_SH" --help 2>&1)"

(validate_agent copilot) >/dev/null 2>&1; rc=$?
assert_success "validate_agent still accepts copilot (help/code sync anchor)" "$rc"

# The `--agent <agent>` usage line (not the separate --agent-override line)
# must advertise copilot as a valid value, matching validate_agent's
# accept-list.
agent_usage_line="$(printf '%s\n' "$help_out" | grep -E '^[[:space:]]*--agent ' | head -1)"
assert_contains "--help --agent usage line lists copilot as a valid agent" \
  "copilot" "$agent_usage_line"

# The Environment: block must document the per-agent timeout override so
# operators discover REPOLENS_AGENT_TIMEOUT_COPILOT from --help itself,
# matching the resolve_agent_timeout copilot arm exercised in Section 3.
assert_contains "--help documents the REPOLENS_AGENT_TIMEOUT_COPILOT env var" \
  "REPOLENS_AGENT_TIMEOUT_COPILOT" "$help_out"

echo ""
echo "=== Results: $PASS passed, $FAIL failed, $TOTAL total ==="
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
