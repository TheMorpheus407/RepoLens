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

# Tests for ANSI escape code handling in DONE streak detection
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/streak.sh"

PASS=0
FAIL=0
TOTAL=0
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

assert_done() {
  local desc="$1" file="$2" expected="$3"
  TOTAL=$((TOTAL + 1))
  if check_done "$file"; then
    actual="yes"
  else
    actual="no"
  fi
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (expected=$expected actual=$actual)"
  fi
}

assert_strip() {
  local desc="$1" input="$2" expected="$3"
  TOTAL=$((TOTAL + 1))
  local actual
  actual="$(printf '%s' "$input" | strip_ansi)"
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (expected='$expected' actual='$actual')"
  fi
}

echo "=== ANSI Escape Code Handling in Streak Detection ==="

# Plain DONE (baseline)
f="$TMPDIR/plain.txt"
printf "DONE\n" > "$f"
assert_done "Plain DONE" "$f" "yes"

# DONE wrapped in ANSI color reset
f="$TMPDIR/ansi-reset.txt"
printf '\e[0mDONE\e[0m\n' > "$f"
assert_done "DONE wrapped in ANSI reset codes" "$f" "yes"

# DONE with ANSI color prefix (bold green)
f="$TMPDIR/ansi-color.txt"
printf '\e[1;32mDONE\e[0m\n' > "$f"
assert_done "DONE with bold green ANSI" "$f" "yes"

# Colored output with DONE at end
f="$TMPDIR/ansi-last.txt"
printf '\e[0mSome analysis output here.\nFound 3 issues.\n\e[1;33mDONE\e[0m\n' > "$f"
assert_done "DONE as last word with ANSI colors" "$f" "yes"

# DONE at start, colored content follows
f="$TMPDIR/ansi-first.txt"
printf '\e[0mDONE\e[0m\n\e[1;34mAll issues reported above.\e[0m\n' > "$f"
assert_done "DONE as first word with ANSI colors" "$f" "yes"

# Opencode-style output: color reset prefix, content, no DONE
f="$TMPDIR/ansi-no-done.txt"
printf '\e[0mI found several issues. Created them via gh issue create call.\e[0m\n' > "$f"
assert_done "ANSI output without DONE" "$f" "no"

# DONE only in middle (should NOT match)
f="$TMPDIR/middle-done.txt"
printf 'Analysis DONE here but more text follows\n' > "$f"
assert_done "DONE only in middle (should not match)" "$f" "no"

# Multiple ANSI sequences wrapping DONE
f="$TMPDIR/multi-ansi.txt"
printf '\e[0m\e[1m\e[36mDONE\e[0m\e[0m\n' > "$f"
assert_done "DONE with multiple nested ANSI sequences" "$f" "yes"

# Empty file
f="$TMPDIR/empty.txt"
printf '' > "$f"
assert_done "Empty file" "$f" "no"

# Real opencode output pattern (from bug report: first word [0m, last word call.)
f="$TMPDIR/opencode-broken.txt"
printf '\e[0mI analyzed the codebase and created issues via gh issue create call.\e[0m\n' > "$f"
assert_done "Opencode pattern without DONE (was false positive before fix)" "$f" "no"

# Real opencode output pattern with DONE at end
f="$TMPDIR/opencode-done.txt"
printf '\e[0mI have completed my analysis. All issues reported.\n\nDONE\e[0m\n' > "$f"
assert_done "Opencode pattern with DONE at end" "$f" "yes"

# Screen mode sequence: \e(B (character set selection, used by some terminals)
f="$TMPDIR/screen-mode.txt"
printf '\e(BDONE\n' > "$f"
assert_done "DONE wrapped in screen mode sequence \\e(B" "$f" "yes"

# Screen mode at end of colored output with DONE
f="$TMPDIR/screen-mode-last.txt"
printf 'Analysis complete.\n\e(BDONE\n' > "$f"
assert_done "DONE as last word after screen mode sequence" "$f" "yes"

# OSC hyperlink wrapping DONE
f="$TMPDIR/hyperlink-done.txt"
printf '\e]8;;https://example.com\e\\DONE\e]8;;\e\\\n' > "$f"
assert_done "DONE wrapped in OSC hyperlink sequence" "$f" "yes"

# OSC hyperlink without DONE (negative case)
f="$TMPDIR/hyperlink-no-done.txt"
printf '\e]8;;https://example.com\e\\click here\e]8;;\e\\\n' > "$f"
assert_done "Hyperlink without DONE" "$f" "no"

# Mixed: CSI color + screen mode + DONE
f="$TMPDIR/mixed-ansi.txt"
printf '\e[1;32m\e(BDONE\e[0m\n' > "$f"
assert_done "DONE with mixed CSI color and screen mode" "$f" "yes"

echo ""
echo "=== Direct strip_ansi Output Verification ==="

assert_strip "CSI color code stripped cleanly" $'\e[31mhello\e[0m' "hello"
assert_strip "Screen mode \\e(B stripped cleanly" $'\e(Bhello' "hello"
assert_strip "OSC hyperlink stripped to link text" $'\e]8;;https://example.com\e\\link text\e]8;;\e\\' "link text"
assert_strip "Multiple CSI codes stripped" $'\e[1m\e[32mDONE\e[0m' "DONE"
assert_strip "Plain text unchanged" "no ansi here" "no ansi here"
assert_strip "Empty input unchanged" "" ""

echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
exit "$FAIL"
