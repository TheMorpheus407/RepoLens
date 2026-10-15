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

# Behavioral contract for the severity single-source-of-truth helpers and the
# filename/frontmatter mismatch detector (issue #331).
#
# Decision encoded by the issue: frontmatter `severity:` is the SINGLE SOURCE
# OF TRUTH. The title `[SEVERITY]` prefix and the filename slug are display-only
# and must NEVER override the frontmatter value. When the title prefix disagrees
# with frontmatter, the run must surface a non-fatal warning without dropping or
# mutating the finding — frontmatter always wins.
#
# This file is written BEFORE the implementation (TDD red phase). The two pure
# helpers (severity_from_title, detect_severity_mismatch) and the warn wired
# into count_dry_run_issues do not exist yet, so the helper tables and the
# "mismatch is logged" integration assertion fail until the implementer adds
# them. The two preservation guards (agreeing case emits no warning; the
# filename slug is never used as a severity source) pass before AND after the
# change — they pin behavior the issue requires to be kept, not introduced.
#
# Mirrors tests/test_severity_normalize.sh / tests/test_finding_type_normalize.sh
# for the pure-helper tables and tests/test_min_severity_observability.sh for
# the count_dry_run_issues integration setup. No real model is ever invoked.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_LIB="$SCRIPT_DIR/lib/core.sh"
LOGGING_LIB="$SCRIPT_DIR/lib/logging.sh"
SUMMARY_LIB="$SCRIPT_DIR/lib/summary.sh"
TEMPLATE_LIB="$SCRIPT_DIR/lib/template.sh"
STREAK_LIB="$SCRIPT_DIR/lib/streak.sh"

PASS=0
FAIL=0
TOTAL=0

pass_with() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

fail_with() {
  local desc="$1" detail="${2:-}"
  FAIL=$((FAIL + 1))
  echo "  FAIL: $desc"
  [[ -n "$detail" ]] && printf '    %s\n' "$detail"
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

# assert_out_rc: pins BOTH the stdout value and the exit code of
# detect_severity_mismatch in a single assertion. The detector's contract is
# two-channel — stdout carries the authoritative (frontmatter) severity, the
# exit code signals whether the title prefix disagreed — so both must be checked.
assert_out_rc() {
  local desc="$1" exp_out="$2" exp_rc="$3" act_out="$4" act_rc="$5"
  TOTAL=$((TOTAL + 1))
  if [[ "$exp_out" == "$act_out" && "$exp_rc" == "$act_rc" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected out='$exp_out' rc=$exp_rc, got out='$act_out' rc=$act_rc"
  fi
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

for lib in "$CORE_LIB" "$LOGGING_LIB" "$SUMMARY_LIB" "$TEMPLATE_LIB" "$STREAK_LIB"; do
  if [[ ! -f "$lib" ]]; then
    fail_with "required lib exists" "Missing $lib"
    finish
  fi
done

# shellcheck disable=SC1090
source "$TEMPLATE_LIB"
# shellcheck disable=SC1090
source "$LOGGING_LIB"
# shellcheck disable=SC1090
source "$SUMMARY_LIB"
# shellcheck disable=SC1090
source "$CORE_LIB"
# shellcheck disable=SC1090
source "$STREAK_LIB"

# ---------------------------------------------------------------------------
echo "=== severity_from_title: extract a normalized severity from a [SEVERITY] prefix ==="
# ---------------------------------------------------------------------------
# Reuses the canonical title-prefix regex (^\[([A-Za-z]+)\]...) from
# _synthesize_normalize_title and feeds the captured word through
# severity_normalize. Display-only / advisory: never a data source.

assert_eq "uppercase prefix yields canonical severity" "high" "$(severity_from_title "[HIGH] SQL injection")"
assert_eq "lowercase prefix folds to canonical" "low" "$(severity_from_title "[low] minor typo")"
assert_eq "mixed-case prefix folds to canonical" "medium" "$(severity_from_title "[Medium] flaky retry")"
assert_eq "prefix with no trailing text still resolves" "critical" "$(severity_from_title "[CRITICAL]")"
assert_eq "no bracket prefix yields empty" "" "$(severity_from_title "No prefix here")"
assert_eq "non-severity bracket word yields empty" "" "$(severity_from_title "[BOGUS] something")"
# The title-prefix regex is STRICT: unlike severity_normalize, it does not strip
# spaces inside the brackets. "[ HIGH ]" is a display string, not a [SEVERITY]
# prefix, so it carries no advisory severity.
assert_eq "spaces inside brackets are not a prefix" "" "$(severity_from_title "[ HIGH ] spaced")"
assert_eq "empty title yields empty" "" "$(severity_from_title "")"
assert_eq "no argument is safe and empty under set -u" "" "$(severity_from_title)"
# The prefix MUST be leading: a bracketed severity anywhere but the very start of
# the title (e.g. a trailing tag, or after whitespace) carries no advisory
# severity. These guard the regex anchor (^\[) against regressing into a
# "contains [SEVERITY] anywhere" match, which would resurrect the title as a
# back-door data source.
assert_eq "trailing bracket severity is not a prefix" "" "$(severity_from_title "SQL injection [HIGH]")"
assert_eq "leading whitespace before the bracket is not a prefix" "" "$(severity_from_title "  [HIGH] x")"
# Branch-review titles carry one canonical mode marker before their severity.
# That marker is not itself a severity and must not hide the following prefix.
assert_eq "branch-review marker exposes its following severity" "low" \
  "$(severity_from_title "[REGRESSION][LOW] x")"

# ---------------------------------------------------------------------------
echo ""
echo "=== detect_severity_mismatch: frontmatter wins; title prefix is advisory ==="
# ---------------------------------------------------------------------------
# Contract: ALWAYS prints the canonical frontmatter severity on stdout (so the
# caller consumes it as the data value regardless of outcome). Returns 0 when
# the title carries no severity prefix OR it agrees with frontmatter; returns
# non-zero (mismatch) when the title prefix is present and disagrees.

out="$(detect_severity_mismatch "high" "[LOW] foo")"; rc=$?
assert_out_rc "disagreeing title flags mismatch, returns frontmatter value" "high" "1" "$out" "$rc"

out="$(detect_severity_mismatch "high" "[REGRESSION][LOW] x")"; rc=$?
assert_out_rc "branch-review disagreement flags mismatch, returns frontmatter value" \
  "high" "1" "$out" "$rc"

out="$(detect_severity_mismatch "high" "[REGRESSION][HIGH] x")"; rc=$?
assert_out_rc "branch-review agreement is silent and returns frontmatter value" \
  "high" "0" "$out" "$rc"

out="$(detect_severity_mismatch "high" "[HIGH] foo")"; rc=$?
assert_out_rc "agreeing title is no mismatch, returns frontmatter value" "high" "0" "$out" "$rc"

out="$(detect_severity_mismatch "high" "no prefix at all")"; rc=$?
assert_out_rc "title without a prefix is no mismatch" "high" "0" "$out" "$rc"

out="$(detect_severity_mismatch "HIGH" "[high] foo")"; rc=$?
assert_out_rc "both sides normalize before comparison (case/raw)" "high" "0" "$out" "$rc"

out="$(detect_severity_mismatch "high" "[BOGUS] foo")"; rc=$?
assert_out_rc "non-severity bracket word carries no severity, no mismatch" "high" "0" "$out" "$rc"

out="$(detect_severity_mismatch "low" "[CRITICAL] foo")"; rc=$?
assert_out_rc "frontmatter wins even when the title claims a higher severity" "low" "1" "$out" "$rc"

out="$(detect_severity_mismatch "" "plain title")"; rc=$?
assert_out_rc "empty frontmatter + no title prefix is no mismatch, empty value" "" "0" "$out" "$rc"

out="$(detect_severity_mismatch "" "[LOW] foo")"; rc=$?
assert_out_rc "empty frontmatter + titled severity surfaces the gap" "" "1" "$out" "$rc"

out="$(detect_severity_mismatch)"; rc=$?
assert_out_rc "no arguments are safe, empty value, no mismatch" "" "0" "$out" "$rc"

# An unrecognized (non-empty) frontmatter value normalizes to empty just like a
# missing one, so a titled severity still surfaces the gap. Invalid frontmatter
# is never special-cased into a spurious "agreement" — severity_normalize is the
# sole gate on both sides.
out="$(detect_severity_mismatch "bogus" "[high] foo")"; rc=$?
assert_out_rc "invalid frontmatter normalizes to empty and surfaces the titled gap" "" "1" "$out" "$rc"

# ---------------------------------------------------------------------------
echo ""
echo "=== count_dry_run_issues: mismatch is warned, finding is kept, slug is never a source ==="
# ---------------------------------------------------------------------------
# Integration: the --local finding processor must surface a non-fatal warning
# when the title prefix disagrees with frontmatter, WITHOUT dropping the finding
# or altering the count. The warn may be routed to the run log (log_warn /
# _streak_log_min_severity_warn) or to stderr (warn) depending on the wiring
# choice, so each scenario searches the union of the run log and captured
# stderr for a case-insensitive "mismatch" token (the issue's own word:
# "filename/frontmatter mismatch detector").

TMP_PARENT="$SCRIPT_DIR/tests/logs/test-severity-single-source"
mkdir -p "$TMP_PARENT"
TMPDIR_T="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"

cleanup() {
  rm -rf "$TMPDIR_T"
  rmdir "$TMP_PARENT" 2>/dev/null || true
  rmdir "$SCRIPT_DIR/tests/logs" 2>/dev/null || true
}
trap cleanup EXIT

# Stand up a run-scoped logging + summary context. Sets the globals
# SCEN_OUTPUT (finding dir), SCEN_LOG_FILE, and SCEN_STDERR for the caller.
# Must be called directly (NOT in a command substitution) so the globals land
# in the current shell rather than a discarded subshell.
setup_scenario() {
  local name="$1"
  local log_dir="$TMPDIR_T/$name"
  local project="$log_dir/project"
  local summary="$log_dir/summary.json"
  SCEN_OUTPUT="$log_dir/output"
  mkdir -p "$project" "$SCEN_OUTPUT"

  export PROJECT_PATH="$project"
  export LOG_BASE="$log_dir"
  export SUMMARY_FILE="$summary"
  export AGENT=codex
  export MODE=bugreport
  export REPOLENS_MODE=bugreport

  init_logging "$name" "$log_dir" >/dev/null 2>&1
  init_summary "$summary" "$name" "$project" "bugreport" "$AGENT" "" "" "local" "$SCEN_OUTPUT" >/dev/null 2>&1

  SCEN_LOG_FILE="$log_dir/$name.log"
  SCEN_STDERR="$log_dir/count.err"
}

# Concatenate the run log and the captured stderr so an assertion is agnostic to
# which sink the implementer routes the warn through.
# Consumers must drain this stream: an early grep -q exit can SIGPIPE cat while
# it writes the second file, making a successful match fail under pipefail.
scenario_observed() {
  cat "$SCEN_LOG_FILE" "$SCEN_STDERR" 2>/dev/null
}

# --- Scenario A: title [LOW] disagrees with frontmatter `high` ----------------
# min-severity is `low` so the high finding is always kept regardless of
# filtering. The mismatch must be surfaced AND the finding must remain counted.
setup_scenario mismatch-warns
cat > "$SCEN_OUTPUT/001-titled-low-but-high.md" <<'MD'
---
title: "[REGRESSION][LOW] Frontmatter is authoritative"
severity: high
domain: security
lens: injection
---

## Summary
The branch-review title prefix says LOW but the frontmatter says high.
MD
export REPOLENS_MIN_SEVERITY=low
count="$(count_dry_run_issues "$SCEN_OUTPUT" 2>"$SCEN_STDERR")"
unset REPOLENS_MIN_SEVERITY

assert_eq "mismatched finding is kept (frontmatter high meets min low)" "1" "$count"
if scenario_observed | grep -i 'mismatch' >/dev/null; then
  pass_with "title/frontmatter disagreement surfaces a non-fatal 'mismatch' warning"
else
  fail_with "title/frontmatter disagreement surfaces a non-fatal 'mismatch' warning" \
    "No 'mismatch' warning found in run log or stderr"
fi
TOTAL=$((TOTAL + 1))

# --- Scenario B: title [HIGH] agrees with frontmatter `high` ------------------
# A finding whose title prefix matches frontmatter must NOT trigger the warning.
setup_scenario agreeing-silent
cat > "$SCEN_OUTPUT/001-titled-high-and-high.md" <<'MD'
---
title: "[HIGH] Title agrees with frontmatter"
severity: high
domain: security
lens: injection
---

## Summary
The title prefix and the frontmatter agree.
MD
export REPOLENS_MIN_SEVERITY=low
count="$(count_dry_run_issues "$SCEN_OUTPUT" 2>"$SCEN_STDERR")"
unset REPOLENS_MIN_SEVERITY

assert_eq "agreeing finding is kept" "1" "$count"
if scenario_observed | grep -i 'mismatch' >/dev/null; then
  fail_with "agreeing title/frontmatter emits no mismatch warning" \
    "Unexpected 'mismatch' warning for an agreeing finding"
else
  pass_with "agreeing title/frontmatter emits no mismatch warning"
fi
TOTAL=$((TOTAL + 1))

# --- Scenario C: the filename slug is NEVER a severity source (AC #3) ---------
# Filename slug claims "critical" but frontmatter says `low`. With min-severity
# `high` the finding MUST be dropped — proving severity is read from frontmatter
# only. If any code path parsed the slug, "critical" would keep the finding and
# the count would be 1. (Title agrees with frontmatter, so no warning here.)
setup_scenario slug-not-a-source
cat > "$SCEN_OUTPUT/001-critical-blocker-rce.md" <<'MD'
---
title: "[LOW] Slug says critical, frontmatter says low"
severity: low
domain: security
lens: injection
---

## Summary
The filename slug implies critical but the frontmatter severity is low.
MD
export REPOLENS_MIN_SEVERITY=high
count="$(count_dry_run_issues "$SCEN_OUTPUT" 2>"$SCEN_STDERR")"
unset REPOLENS_MIN_SEVERITY

assert_eq "filename slug 'critical' is ignored; frontmatter low is dropped below high" "0" "$count"

# --- Scenario D: a mismatched finding DROPPED by min-severity still warns ------
# The warn is wired BEFORE the min-severity drop/continue branch, so a finding
# that is legitimately filtered out on its (authoritative) frontmatter severity
# must STILL surface its title/frontmatter inconsistency — the drop must not
# swallow the warning. Title [CRITICAL] over frontmatter `low`, min-severity
# `high`: frontmatter low < high, so the finding is dropped (count 0). If the
# warn were placed after the drop's `continue`, this mismatch would go silent.
setup_scenario mismatch-warns-when-dropped
cat > "$SCEN_OUTPUT/001-titled-critical-but-low.md" <<'MD'
---
title: "[CRITICAL] Auth bypass on admin endpoint"
severity: low
domain: security
lens: injection
---

## Summary
The title prefix screams CRITICAL but the frontmatter severity is low.
MD
export REPOLENS_MIN_SEVERITY=high
count="$(count_dry_run_issues "$SCEN_OUTPUT" 2>"$SCEN_STDERR")"
unset REPOLENS_MIN_SEVERITY

assert_eq "mismatched finding below min-severity is dropped on its frontmatter value" "0" "$count"
if scenario_observed | grep -i 'mismatch' >/dev/null; then
  pass_with "a dropped finding still surfaces its title/frontmatter mismatch warning"
else
  fail_with "a dropped finding still surfaces its title/frontmatter mismatch warning" \
    "No 'mismatch' warning found in run log or stderr for a finding dropped by min-severity"
fi
TOTAL=$((TOTAL + 1))

# --- Scenario E: the mismatch warning is INFORMATIVE --------------------------
# A warning that only says "mismatch" is not actionable. The surfaced line must
# name BOTH the authoritative frontmatter severity and the disagreeing
# title-derived severity, so an operator can see what won and what was ignored.
# The fixture is built so each value can ONLY originate from the message body,
# never from the echoed title text: the display text "Auth bypass" contains
# neither severity word, and the echoed prefix "[LOW]" is UPPERCASE — so a
# lowercase "low" in the warn line can only be the normalized title severity the
# message reports, and "high" can only be the frontmatter value.
setup_scenario informative-warn
cat > "$SCEN_OUTPUT/001-informative.md" <<'MD'
---
title: "[LOW] Auth bypass"
severity: high
domain: security
lens: injection
---

## Summary
Frontmatter says high; the title prefix says LOW.
MD
export REPOLENS_MIN_SEVERITY=low
count="$(count_dry_run_issues "$SCEN_OUTPUT" 2>"$SCEN_STDERR")"
unset REPOLENS_MIN_SEVERITY

assert_eq "informative-warn finding is kept (frontmatter high meets min low)" "1" "$count"
mismatch_line="$(scenario_observed | grep -i 'mismatch' | sed -n '1p')"
if [[ "$mismatch_line" == *high* ]]; then
  pass_with "mismatch warning names the authoritative frontmatter severity (high)"
else
  fail_with "mismatch warning names the authoritative frontmatter severity (high)" \
    "mismatch line did not contain 'high': $mismatch_line"
fi
TOTAL=$((TOTAL + 1))
if [[ "$mismatch_line" == *low* ]]; then
  pass_with "mismatch warning names the disagreeing title severity (lowercase 'low', from the message body not the echoed [LOW] prefix)"
else
  fail_with "mismatch warning names the disagreeing title severity (low)" \
    "mismatch line did not contain lowercase 'low': $mismatch_line"
fi
TOTAL=$((TOTAL + 1))

finish
