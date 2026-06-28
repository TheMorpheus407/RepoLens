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

# Tests for issue #359 — Print startup wall-clock estimate + loud >24h warning
# with tuning levers.
#
# The estimator helper estimate_run_wall_seconds (issue #357, lib/summary.sh) is
# a prerequisite that already exists. This issue WIRES it into the two startup
# output blocks (confirm_run + the dry-run preview) so users see how long a run
# will take, and prints a loud warning with concrete tuning levers when the
# estimate is very large.
#
# Acceptance criteria (from the issue) exercised here:
#   AC1: The dry-run preview AND the startup confirmation show an estimated
#        wall-clock line (e.g. "Estimated wall-clock: ~Nh at --max-parallel M").
#   AC2: When the estimate exceeds the threshold, a clearly marked warning with
#        the tuning levers (raise --max-parallel, faster/cheaper --agent, lower
#        --depth, scope with --domain/--focus, --max-issues) is printed.
#   AC3: The threshold is overridable via REPOLENS_EST_WARN_HOURS (default 24h)
#        and is documented in the repolens.sh usage env help and the README.
#   AC4: The estimate is omitted gracefully (no crash) if the helper returns
#        nothing / a non-numeric threshold is supplied.
#
# These are BEHAVIORAL tests driven through `repolens.sh --dry-run` (which exits
# before any agent runs) plus source/doc assertions for the paths that cannot be
# exercised non-interactively (confirm_run dies on piped stdin without a TTY).
# NO real models are invoked — a fake `codex` on PATH is the only "agent", and
# every run uses --dry-run so it never executes.
#
# Deterministic threshold control: the warning branch is forced/suppressed with
# REPOLENS_EST_PER_ITER_SECS (inflates the per-iteration seconds the estimator
# multiplies by) paired with REPOLENS_EST_WARN_HOURS, so the fire/no-fire
# decision does not depend on the exact lens count of bugreport mode.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$SCRIPT_DIR/repolens.sh"
README="$SCRIPT_DIR/README.md"

TMP_PARENT="$SCRIPT_DIR/logs/test-wall-estimate"
mkdir -p "$TMP_PARENT"
TMPDIR="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"
CREATED_RUN_IDS=()
BUG_FILE="$TMPDIR/bug-report.md"
printf 'Wall-clock estimate fixture bug report — placeholder text.\n' > "$BUG_FILE"

# shellcheck disable=SC2329  # cleanup is invoked indirectly via 'trap cleanup EXIT' below.
cleanup() {
  local run_id
  rm -rf "$TMPDIR"
  for run_id in "${CREATED_RUN_IDS[@]:-}"; do
    [[ -n "$run_id" ]] && rm -rf "$SCRIPT_DIR/logs/$run_id"
  done
  rmdir "$TMP_PARENT" 2>/dev/null || true
}
trap cleanup EXIT

PASS=0
FAIL=0
TOTAL=0
FAKE_BIN="$TMPDIR/bin"
LAST_OUTPUT_FILE=""
LAST_RC=0

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

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected: $expected | Actual: $actual"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected output to contain: $needle"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Did not expect output to contain: $needle"
  fi
}

# Pass if EITHER needle is present (e.g. the issue allows --domain OR --focus).
assert_contains_either() {
  local desc="$1" a="$2" b="$3" haystack="$4"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$a"* || "$haystack" == *"$b"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected output to contain '$a' or '$b'"
  fi
}

# Extended-regex match against a file's contents.
assert_file_matches() {
  local desc="$1" file="$2" pattern="$3"
  TOTAL=$((TOTAL + 1))
  if grep -Eq "$pattern" "$file" 2>/dev/null; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected $file to match: $pattern"
  fi
}

# Extended-regex match against a captured output string (not a file).
assert_str_matches() {
  local desc="$1" pattern="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if printf '%s\n' "$haystack" | grep -Eq "$pattern"; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected output to match: $pattern"
  fi
}

make_fake_codex() {
  mkdir -p "$FAKE_BIN"
  cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
printf 'DONE\n'
EOF
  chmod +x "$FAKE_BIN/codex"
}

make_project() {
  local project="$1"
  mkdir -p "$project"
  git -C "$project" init -q
  # Enough source bytes so the cost block (and thus the TOTAL_LENSES>0 path the
  # wall-clock line shares) is reached in dry-run.
  local i
  for i in $(seq 1 20); do
    printf 'line %d of seed source — keep the repo above the 1k-token threshold\n' "$i" \
      >> "$project/src.txt"
  done
  printf '# wall-clock estimate fixture\n' > "$project/README.md"
}

last_output() {
  cat "$LAST_OUTPUT_FILE"
}

register_created_run_id() {
  local run_id
  run_id="$(grep -oE 'RepoLens run [^ ]+ starting' "$LAST_OUTPUT_FILE" 2>/dev/null | head -1 | awk '{print $3}')"
  if [[ -n "$run_id" ]]; then
    CREATED_RUN_IDS+=("$run_id")
  fi
}

# run_dryrun NAME [ENV=VAL ...] -- [repolens-args ...]
#
# ENV=VAL tokens before `--` are injected into repolens' environment for this
# run only. Tokens after `--` are forwarded to repolens.sh. Output (stdout AND
# stderr — the warning goes to stderr via log_warn) is captured merged so the
# assertions see both streams. The new REPOLENS_EST_* vars are stripped from the
# calling shell first so a vanilla run starts from a clean slate.
run_dryrun() {
  local name="$1"
  shift

  local -a env_extras=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    env_extras+=("$1")
    shift
  done
  [[ "${1:-}" == "--" ]] && shift

  local project="$TMPDIR/proj-$name"
  make_project "$project"

  LAST_OUTPUT_FILE="$TMPDIR/out-$name.txt"

  env -u REPOLENS_ROUNDS -u REPOLENS_MAX_ROUNDS -u DONE_STREAK_REQUIRED \
      -u REPOLENS_EST_WARN_HOURS -u REPOLENS_EST_PER_ITER_SECS \
    PATH="$FAKE_BIN:$PATH" \
    "${env_extras[@]}" \
    bash "$REPO" \
      --project "$project" \
      --agent codex \
      --mode bugreport \
      --bug-report "$BUG_FILE" \
      --local \
      --output "$TMPDIR/issues-$name" \
      --dry-run --yes \
      "$@" </dev/null >"$LAST_OUTPUT_FILE" 2>&1
  LAST_RC=$?
  register_created_run_id
}

echo ""
echo "=== Test Suite: startup wall-clock estimate (issue #359) ==="
echo ""

make_fake_codex

# ---------------------------------------------------------------------------
# AC1 — the dry-run preview shows the wall-clock line (vanilla run, no knobs).
# ---------------------------------------------------------------------------
echo "Test 1: dry-run preview prints an estimated wall-clock line"
run_dryrun "ac1-line" --
assert_eq "vanilla dry-run exits 0" "0" "$LAST_RC"
out1="$(last_output)"
assert_contains "dry-run prints the wall-clock estimate label" \
                "Estimated wall-clock" "$out1"
assert_contains "wall-clock line names the --max-parallel lever (per issue example)" \
                "--max-parallel" "$out1"

# ---------------------------------------------------------------------------
# AC2 / AC3 — warning FIRES on the default 24h threshold when the estimate is
# huge. REPOLENS_EST_PER_ITER_SECS=100000 makes any >0-lens run exceed 24h
# (>=100000s > 86400s) regardless of the bugreport lens count, with NO
# REPOLENS_EST_WARN_HOURS set (so this also proves the default 24h is active).
# ---------------------------------------------------------------------------
echo ""
echo "Test 2: estimate over the default 24h threshold prints the levers warning"
run_dryrun "ac2-fires" REPOLENS_EST_PER_ITER_SECS=100000 --
assert_eq "huge-estimate dry-run still exits 0" "0" "$LAST_RC"
out2="$(last_output)"
assert_contains "warning path still prints the wall-clock line" \
                "Estimated wall-clock" "$out2"
assert_contains "warning lists the --max-parallel lever" "--max-parallel" "$out2"
assert_contains "warning lists the --agent lever"        "--agent"        "$out2"
assert_contains "warning lists the --depth lever"        "--depth"        "$out2"
assert_contains "warning lists the --max-issues lever"   "--max-issues"   "$out2"
assert_contains_either "warning lists a scoping lever (--domain / --focus)" \
                "--domain" "--focus" "$out2"

# ---------------------------------------------------------------------------
# AC2 (negative) / AC3 — same huge estimate, but a very high override threshold
# SUPPRESSES the warning. Identical REPOLENS_EST_PER_ITER_SECS as Test 2; only
# REPOLENS_EST_WARN_HOURS differs, so a behavior flip proves the override is
# honored. The levers (--agent/--depth/--max-issues) appear ONLY in the warning,
# so their absence is a reliable "did not fire" signal. The estimate line itself
# must still be present (AC1 holds whether or not the warning fires).
# ---------------------------------------------------------------------------
echo ""
echo "Test 3: a high REPOLENS_EST_WARN_HOURS override suppresses the warning"
run_dryrun "ac3-suppressed" \
  REPOLENS_EST_PER_ITER_SECS=100000 REPOLENS_EST_WARN_HOURS=100000 --
assert_eq "suppressed-warning dry-run exits 0" "0" "$LAST_RC"
out3="$(last_output)"
assert_contains "estimate line is still present when the warning is suppressed" \
                "Estimated wall-clock" "$out3"
assert_not_contains "no warning: --agent lever absent below threshold"     "--agent"      "$out3"
assert_not_contains "no warning: --depth lever absent below threshold"     "--depth"      "$out3"
assert_not_contains "no warning: --max-issues lever absent below threshold" "--max-issues" "$out3"

# ---------------------------------------------------------------------------
# AC4 — robustness: a non-numeric threshold must NOT crash the run under
# `set -uo pipefail`; the estimate line is still printed and the run exits 0.
# ---------------------------------------------------------------------------
echo ""
echo "Test 4: a non-numeric REPOLENS_EST_WARN_HOURS does not crash the run"
run_dryrun "ac4-garbage-threshold" REPOLENS_EST_WARN_HOURS=abc --
assert_eq "garbage threshold still exits 0 (no set -u crash)" "0" "$LAST_RC"
assert_contains "garbage threshold still prints the wall-clock line" \
                "Estimated wall-clock" "$(last_output)"

# ---------------------------------------------------------------------------
# AC1 (confirmation path) — confirm_run cannot be exercised non-interactively
# (it dies on piped stdin without a TTY), so assert structurally that it wires
# up the wall-clock estimate. confirm_run has no "wall" reference today; whether
# the implementer inlines the echo or calls a helper, the word "wall" must now
# appear in the function body.
# ---------------------------------------------------------------------------
echo ""
echo "Test 5: confirm_run wires up the wall-clock estimate"
confirm_body="$(awk '/^confirm_run\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$REPO")"
TOTAL=$((TOTAL + 1))
if printf '%s' "$confirm_body" | grep -qi 'wall'; then
  pass_with "confirm_run body references the wall-clock estimate"
else
  fail_with "confirm_run body references the wall-clock estimate" \
            "no /wall/i reference found inside confirm_run()"
fi

# ---------------------------------------------------------------------------
# AC4 (graceful omission) — the wall-clock emission must be guarded so a
# non-numeric / empty estimator result omits the line instead of printing
# garbage. Assert a numeric/emptiness guard appears just before the emission.
# ---------------------------------------------------------------------------
echo ""
echo "Test 6: the wall-clock emission is guarded against a non-numeric estimate"
TOTAL=$((TOTAL + 1))
emit_line="$(grep -n 'Estimated wall-clock' "$REPO" | head -1 | cut -d: -f1)"
if [[ -z "$emit_line" ]]; then
  fail_with "wall-clock emission is numeric-guarded" \
            "no 'Estimated wall-clock' emission found in $REPO"
else
  win_start=$(( emit_line > 30 ? emit_line - 30 : 1 ))
  guard_window="$(awk -v s="$win_start" -v e="$emit_line" 'NR>=s && NR<=e' "$REPO")"
  # Accept any defensive shape: a numeric regex test (=~ ... [0-9] ...), an
  # emptiness test (-z/-n), or a `declare -F` availability check on the helper.
  if printf '%s\n' "$guard_window" | grep -qE '\[0-9\]|\[\[ -[zn] |declare -F'; then
    pass_with "wall-clock emission is guarded (numeric/emptiness/availability)"
  else
    fail_with "wall-clock emission is numeric-guarded" \
              "no numeric/emptiness/availability guard within 30 lines before the emission"
  fi
fi

# ---------------------------------------------------------------------------
# AC3 — the threshold env var is documented in BOTH the README env section and
# the repolens.sh usage env help, and the README states the 24h default.
# ---------------------------------------------------------------------------
echo ""
echo "Test 7: REPOLENS_EST_WARN_HOURS is documented (README + usage)"
assert_file_matches "README documents REPOLENS_EST_WARN_HOURS" \
                    "$README" 'REPOLENS_EST_WARN_HOURS'
assert_file_matches "README documents the 24h default for REPOLENS_EST_WARN_HOURS" \
                    "$README" 'REPOLENS_EST_WARN_HOURS.*24|24.*REPOLENS_EST_WARN_HOURS'
assert_file_matches "repolens.sh usage documents REPOLENS_EST_WARN_HOURS" \
                    "$REPO" 'REPOLENS_EST_WARN_HOURS'

# ---------------------------------------------------------------------------
# Coverage gap (AC2 / AC3) — REPOLENS_EST_WARN_HOURS=0 is the documented "disable
# the warning" sentinel and a DISTINCT code branch (the `(( warn_hours > 0 ))`
# guard) from Test 3's high-threshold suppression. Same huge estimate as Test 2,
# but warn_hours=0 must suppress the levers warning entirely while the estimate
# line itself stays. Test 3 raises the threshold above the estimate; this proves
# the separate 0-disables path, which the high-threshold case never exercises.
# ---------------------------------------------------------------------------
echo ""
echo "Test 8: REPOLENS_EST_WARN_HOURS=0 disables the warning (documented sentinel)"
run_dryrun "ac3-disabled-zero" \
  REPOLENS_EST_PER_ITER_SECS=100000 REPOLENS_EST_WARN_HOURS=0 --
assert_eq "disabled-warning dry-run exits 0" "0" "$LAST_RC"
out8="$(last_output)"
assert_contains "estimate line is still present when the warning is disabled (=0)" \
                "Estimated wall-clock" "$out8"
assert_not_contains "=0 disables: --agent lever absent"      "--agent"      "$out8"
assert_not_contains "=0 disables: --depth lever absent"      "--depth"      "$out8"
assert_not_contains "=0 disables: --max-issues lever absent" "--max-issues" "$out8"

# ---------------------------------------------------------------------------
# Coverage gap (AC3) — a CUSTOM numeric threshold must be honored in BOTH
# directions and its value must reach the warning message. Test 2 only asserts
# the levers are present under the default; it never checks that the threshold
# number is interpolated into the "exceeds Nh" line. With warn_hours=1 and a huge
# estimate the warning fires AND the message must say "exceeds 1h" (proving the
# override value — not the 24h default — drives both the decision and the text).
# ---------------------------------------------------------------------------
echo ""
echo "Test 9: a custom REPOLENS_EST_WARN_HOURS value drives and labels the warning"
run_dryrun "ac3-custom-threshold" \
  REPOLENS_EST_PER_ITER_SECS=100000 REPOLENS_EST_WARN_HOURS=1 --
assert_eq "custom-threshold dry-run exits 0" "0" "$LAST_RC"
out9="$(last_output)"
assert_str_matches "warning message reports the custom threshold ('exceeds 1h')" \
                   "exceeds 1h" "$out9"
assert_contains "custom-threshold warning still lists a lever (--max-parallel)" \
                "--max-parallel" "$out9"

# ---------------------------------------------------------------------------
# Coverage gap (AC4) — Test 4 proves a non-numeric threshold does not CRASH, but
# not that it falls back to the documented 24h default and still makes the right
# fire decision. With the same huge estimate, a garbage threshold must behave
# exactly like the default 24h: the warning FIRES and the message says
# "exceeds 24h". This pins the `warn_hours=24` fallback semantics, not just
# "no crash".
# ---------------------------------------------------------------------------
echo ""
echo "Test 10: a garbage threshold falls back to 24h and still fires the warning"
run_dryrun "ac4-garbage-fires" \
  REPOLENS_EST_PER_ITER_SECS=100000 REPOLENS_EST_WARN_HOURS=abc --
assert_eq "garbage-fallback dry-run exits 0" "0" "$LAST_RC"
out10="$(last_output)"
assert_str_matches "garbage threshold falls back to the 24h default ('exceeds 24h')" \
                   "exceeds 24h" "$out10"
assert_contains "garbage-fallback warning still lists a lever (--max-issues)" \
                "--max-issues" "$out10"

# ---------------------------------------------------------------------------
# Coverage gap (AC1) — Test 1 only asserts the "Estimated wall-clock" label is
# present, not that a REAL formatted duration follows it. This pins the
# status_format_duration integration: the line must be
# `Estimated wall-clock: ~<duration> at --max-parallel <N>` with a duration that
# starts with a digit (e.g. "~2h 19m") and a numeric --max-parallel value, so an
# empty/garbage estimate (which the guard would omit) cannot pass.
# ---------------------------------------------------------------------------
echo ""
echo "Test 11: the wall-clock line carries a real formatted duration, not just a label"
run_dryrun "ac1-formatted" --
assert_eq "formatted-line dry-run exits 0" "0" "$LAST_RC"
out11="$(last_output)"
assert_str_matches "wall-clock line shows a formatted duration and numeric max-parallel" \
                   "Estimated wall-clock: ~[0-9].* at --max-parallel [0-9]+" "$out11"

# ---------------------------------------------------------------------------
# Coverage gap (AC2 / AC4) — a zero-padded threshold must be read base-10, not
# octal. Bare `(( 08 > 0 ))` aborts with "value too great for base" (08/09 are
# invalid octal) and silently SUPPRESSES the warning, while "024" would be read
# as octal 20 and mislabel the message. With the same huge estimate as Test 2,
# REPOLENS_EST_WARN_HOURS=08 must behave as 8h: the warning FIRES and the message
# says "exceeds 8h" (NOT "exceeds 08h", and not suppressed). Pins the 10#$ base-10
# normalization that mirrors the sibling estimator in lib/summary.sh.
# ---------------------------------------------------------------------------
echo ""
echo "Test 12: a zero-padded REPOLENS_EST_WARN_HOURS is read base-10, not octal"
run_dryrun "ac2-leading-zero" \
  REPOLENS_EST_PER_ITER_SECS=100000 REPOLENS_EST_WARN_HOURS=08 --
assert_eq "leading-zero threshold dry-run exits 0 (no octal abort)" "0" "$LAST_RC"
out12="$(last_output)"
assert_str_matches "08 is normalized to 8h ('exceeds 8h', not octal-aborted/suppressed)" \
                   "exceeds 8h" "$out12"
assert_not_contains "08 is not echoed verbatim in the threshold label" \
                    "exceeds 08h" "$out12"
assert_contains "leading-zero warning still lists a lever (--max-parallel)" \
                "--max-parallel" "$out12"

# ===========================================================================
# Coverage-test stage additions (issue #359).
#
# The CLI-driven tests above can only reach print_wall_estimate through paths the
# real estimator/formatter expose: estimate_run_wall_seconds always emits one
# integer, so the estimate line is always present, and status_format_duration is
# always sourced. Three shipped behaviors are therefore unreachable from the CLI
# and were only covered STRUCTURALLY before (Test 6 greps that *a* guard exists;
# it never proves the guard actually omits the line):
#
#   - AC4 graceful omission: an unavailable helper, or an empty / non-numeric
#     estimator result, must omit the line WITHOUT crashing under set -u.
#   - AC1 formatter fallback: when status_format_duration is unavailable, the line
#     must fall back to a raw "<secs>s" duration.
#   - AC2 "exceeds" semantics: the threshold test is a STRICT `>` — an estimate
#     exactly AT the threshold must NOT fire; one second over MUST fire.
#
# These extract the REAL shipped print_wall_estimate body from repolens.sh (the
# same awk technique Test 5 uses on confirm_run) and run it in an isolated
# `set -uo pipefail` shell with controlled stubs for its dependencies
# (estimate_run_wall_seconds / status_format_duration / log_warn). It is the
# shipped function, not a re-implementation.
# ===========================================================================

# The exact function body as shipped: signature line through the lone closing
# brace at column 0 (the only such line in the function).
PWE_DEF="$(awk '/^print_wall_estimate\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$REPO")"

# pwe_run EST_MODE FMT_MODE WARN_HOURS
#   EST_MODE  : num:<N> (estimator echoes N) | empty | nonnum | absent (undefined)
#   FMT_MODE  : fmt (define a realistic status_format_duration) | nofmt
#   WARN_HOURS: value for REPOLENS_EST_WARN_HOURS, or the literal "unset"
# Builds a driver that defines the requested stubs, sources the extracted
# print_wall_estimate, and calls it. Captures merged stdout+stderr into PWE_OUT
# (log_warn goes to stderr) and the exit code into PWE_RC.
pwe_run() {
  local est_mode="$1" fmt_mode="$2" warn="$3"
  local driver="$TMPDIR/pwe-driver.sh"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -uo pipefail'
    echo 'TOTAL_LENSES=100'
    echo 'DONE_STREAK_REQUIRED=3'
    echo 'ROUNDS=1'
    echo 'MAX_PARALLEL=8'
    printf '%s\n' 'log_warn() { printf "[WARN] %s\n" "$*" >&2; }'
    case "$est_mode" in
      num:*)  echo "estimate_run_wall_seconds() { echo ${est_mode#num:}; }" ;;
      empty)  echo 'estimate_run_wall_seconds() { return 0; }' ;;
      nonnum) echo 'estimate_run_wall_seconds() { echo "n/a"; }' ;;
      absent) : ;;  # intentionally undefined -> exercises the `declare -F` guard
    esac
    if [[ "$fmt_mode" == "fmt" ]]; then
      cat <<'FMT'
status_format_duration() {
  local s="$1"
  if (( s >= 3600 )); then
    printf '%dh %02dm\n' "$(( s / 3600 ))" "$(( (s % 3600) / 60 ))"
  else
    printf '%ds\n' "$s"
  fi
}
FMT
    fi
    printf '%s\n' "$PWE_DEF"
    echo 'print_wall_estimate'
  } > "$driver"

  if [[ "$warn" == "unset" ]]; then
    env -u REPOLENS_EST_WARN_HOURS bash "$driver" >"$TMPDIR/pwe-out.txt" 2>&1
  else
    REPOLENS_EST_WARN_HOURS="$warn" bash "$driver" >"$TMPDIR/pwe-out.txt" 2>&1
  fi
  PWE_RC=$?
  PWE_OUT="$(cat "$TMPDIR/pwe-out.txt")"
}

# Guard: a broken awk extraction must fail loudly, not let the behavioral tests
# below pass vacuously against an empty function body.
echo ""
echo "Test 13: the real print_wall_estimate body is extractable from repolens.sh"
TOTAL=$((TOTAL + 1))
if [[ -n "$PWE_DEF" && "$PWE_DEF" == *"Estimated wall-clock"* ]]; then
  pass_with "extracted print_wall_estimate() body from repolens.sh"
else
  fail_with "extracted print_wall_estimate() body from repolens.sh" \
            "awk extraction returned empty or unexpected content"
fi

echo ""
echo "Test 14: an EMPTY estimator result omits the line, no crash (AC4, behavioral)"
pwe_run empty fmt unset
assert_eq "empty estimate: exit 0 (no set -u crash)" "0" "$PWE_RC"
assert_not_contains "empty estimate omits the wall-clock line" \
                    "Estimated wall-clock" "$PWE_OUT"

echo ""
echo "Test 15: a NON-NUMERIC estimator result omits the line (AC4, behavioral)"
pwe_run nonnum fmt unset
assert_eq "non-numeric estimate: exit 0" "0" "$PWE_RC"
assert_not_contains "non-numeric estimate omits the wall-clock line" \
                    "Estimated wall-clock" "$PWE_OUT"

echo ""
echo "Test 16: an UNAVAILABLE estimator helper omits the line (AC4, declare -F guard)"
pwe_run absent fmt unset
assert_eq "absent helper: exit 0" "0" "$PWE_RC"
assert_not_contains "absent estimator helper omits the wall-clock line" \
                    "Estimated wall-clock" "$PWE_OUT"

echo ""
echo "Test 17: status_format_duration absent -> raw '<secs>s' fallback (AC1)"
# 3661s formats to "1h 01m" with the formatter present; without it the line must
# show the raw-seconds fallback. High threshold so no warning noise.
pwe_run num:3661 nofmt 100000
assert_eq "formatter-absent: exit 0" "0" "$PWE_RC"
assert_contains "formatter-absent line shows the raw-seconds fallback" \
                "Estimated wall-clock: ~3661s at --max-parallel 8" "$PWE_OUT"

echo ""
echo "Test 18: an estimate exactly AT the threshold does NOT fire (strict >, AC2)"
# warn=1h=3600s, estimate=3600s exactly. The line must still print; the levers
# warning must not (3600 > 3600 is false).
pwe_run num:3600 fmt 1
assert_eq "at-threshold: exit 0" "0" "$PWE_RC"
assert_contains "at-threshold still prints the estimate line" \
                "Estimated wall-clock" "$PWE_OUT"
assert_not_contains "estimate == threshold does not fire the warning" \
                    "exceeds 1h" "$PWE_OUT"
assert_not_contains "at-threshold prints no levers (--max-issues)" \
                    "--max-issues" "$PWE_OUT"

echo ""
echo "Test 19: an estimate one second OVER the threshold fires the warning (strict >, AC2)"
pwe_run num:3601 fmt 1
assert_eq "just-over: exit 0" "0" "$PWE_RC"
assert_contains "estimate one second over threshold fires the warning" \
                "exceeds 1h" "$PWE_OUT"
assert_contains "just-over warning lists a lever (--max-issues)" \
                "--max-issues" "$PWE_OUT"

echo ""
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
