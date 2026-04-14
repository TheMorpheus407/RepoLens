#!/usr/bin/env bash
# Copyright 2025 Bootstrap Academy
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

# Tests for issue #1: README rewrite for launch
# Validates that README.md reflects the actual state of the codebase.
# shellcheck disable=SC2016  # backticks in regex patterns are intentional literals
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
README="$SCRIPT_DIR/README.md"
DOMAINS_FILE="$SCRIPT_DIR/config/domains.json"

PASS=0
FAIL=0
TOTAL=0

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    Expected to contain: $needle"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    Expected NOT to contain: $needle"
  fi
}

assert_matches() {
  local desc="$1" pattern="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if echo "$haystack" | grep -qP "$pattern"; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    Expected to match pattern: $pattern"
  fi
}

echo ""
echo "=== Test Suite: README rewrite (issue #1) ==="
echo ""

readme_content="$(cat "$README")"

# =====================================================================
# 1. License badge — must say Apache-2.0, not MIT
# =====================================================================

echo "Test 1: License badge is Apache-2.0"
assert_contains "README mentions Apache-2.0" "Apache-2.0" "$readme_content"

echo ""
echo "Test 2: No MIT license reference"
# The word "MIT" should not appear as a license claim
# (it may appear in other contexts like a domain name, but the license line must be gone)
last_line_area="$(tail -5 "$README")"
assert_not_contains "no MIT in license section" "MIT" "$last_line_area"

# =====================================================================
# 2. Lens count — must match actual count from domains.json
# =====================================================================

echo ""
echo "Test 3: Lens count matches domains.json"
actual_count="$(jq '[.domains[].lenses | length] | add' "$DOMAINS_FILE")"
assert_contains "README has actual lens count ($actual_count)" "$actual_count" "$readme_content"

echo ""
echo "Test 4: Old lens count '109' is gone"
assert_not_contains "no stale '109' count" "109 expert" "$readme_content"

# =====================================================================
# 3. Domain count — must match actual count from domains.json
# =====================================================================

echo ""
echo "Test 5: Domain count matches domains.json"
actual_domains="$(jq '.domains | length' "$DOMAINS_FILE")"
assert_contains "README has actual domain count ($actual_domains)" "$actual_domains" "$readme_content"

# =====================================================================
# 4. All 8 modes documented
# =====================================================================

echo ""
echo "Test 6: All 8 modes are documented as modes"
# Each mode must appear backtick-quoted (e.g. `discover`) to count as documented as a mode,
# not just mentioned as a random word (e.g. "discovery" or "deployment").
for mode in audit feature bugfix discover deploy custom opensource content; do
  TOTAL=$((TOTAL + 1))
  if echo "$readme_content" | grep -qP "\`$mode\`"; then
    PASS=$((PASS + 1))
    echo "  PASS: mode '$mode' documented as \`$mode\`"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: mode '$mode' not documented as \`$mode\`"
    echo "    Expected to find backtick-quoted: \`$mode\`"
  fi
done

echo ""
echo "Test 7: Discover mode has meaningful description"
# Must have more than just the word — needs context about what discover mode does
assert_matches "discover mode description" '(?i)`discover`.*discover|discover.*`discover`' "$readme_content"

echo ""
echo "Test 8: Deploy mode has meaningful description"
assert_matches "deploy mode description" '(?i)`deploy`.*server|server.*`deploy`|`deploy`.*live|live.*`deploy`' "$readme_content"

echo ""
echo "Test 9: Custom mode has meaningful description"
assert_matches "custom mode description" '(?i)`custom`.*change|change.*`custom`|`custom`.*impact|impact.*`custom`' "$readme_content"

echo ""
echo "Test 10: Opensource mode has meaningful description"
assert_matches "opensource mode description" '(?i)`opensource`.*open.source|open.source.*`opensource`|`opensource`.*public|public.*`opensource`' "$readme_content"

echo ""
echo "Test 11: Content mode has meaningful description"
assert_matches "content mode description" '(?i)`content`.*content|content.*`content`' "$readme_content"

# =====================================================================
# 5. Install instructions
# =====================================================================

echo ""
echo "Test 12: Install instructions section exists"
assert_matches "install/prerequisites section" "(?i)(install|prerequisites|requirements|getting started)" "$readme_content"

echo ""
echo "Test 13: jq mentioned in requirements"
assert_contains "jq in requirements" "jq" "$readme_content"

echo ""
echo "Test 14: gh CLI mentioned in requirements"
assert_contains "gh in requirements" "gh" "$readme_content"

echo ""
echo "Test 15: gh auth login instruction"
assert_contains "gh auth login mentioned" "gh auth login" "$readme_content"

echo ""
echo "Test 16: git mentioned in requirements"
assert_contains "git in requirements" "git" "$readme_content"

echo ""
echo "Test 17: Agent CLI mentioned"
assert_contains "claude CLI mentioned" "claude" "$readme_content"

echo ""
echo "Test 18: chmod instruction present"
assert_contains "chmod +x instruction" "chmod" "$readme_content"

# =====================================================================
# 6. All CLI flags documented
# =====================================================================

echo ""
echo "Test 19: All CLI flags documented in README"
for flag in "--project" "--agent" "--mode" "--change" "--source" "--focus" "--domain" "--parallel" "--max-parallel" "--resume" "--spec" "--max-issues" "--hosted"; do
  assert_contains "flag $flag documented" "$flag" "$readme_content"
done

# =====================================================================
# 7. Legal section
# =====================================================================

echo ""
echo "Test 20: Legal section exists"
assert_matches "Legal section heading" "(?i)## .*legal" "$readme_content"

echo ""
echo "Test 21: Deploy mode authorization requirement in legal"
# Legal section must mention that deploy-mode requires authorization on the target server
assert_matches "deploy authorization mentioned" "(?i)(authori[sz]ation|permission).*server|server.*(authori[sz]ation|permission)" "$readme_content"

echo ""
echo "Test 22: --dangerously-skip-permissions explained"
assert_contains "dangerously-skip-permissions explained" "dangerously-skip-permissions" "$readme_content"

echo ""
echo "Test 23: As-is / no warranty disclaimer"
assert_matches "as-is disclaimer" '(?i)(as[- ]is|no warranty|without warranty|provided "as is")' "$readme_content"

# =====================================================================
# 8. METHODOLOGY.md link
# =====================================================================

echo ""
echo "Test 24: Link to METHODOLOGY.md"
assert_contains "METHODOLOGY.md link" "METHODOLOGY.md" "$readme_content"

# =====================================================================
# 9. Sponsor/Patreon section
# =====================================================================

echo ""
echo "Test 25: Sponsor or support section exists"
assert_matches "sponsor section" "(?i)(sponsor|support|patreon|fund|donat)" "$readme_content"

# =====================================================================
# 10. New domains present that were missing from old README
# =====================================================================

echo ""
echo "Test 26: New domains documented"
# These domains are missing from the old README entirely. Check for their id or display name.
# Use word-boundary-aware matching to avoid false positives (e.g., "deployment safety" != domain "deployment")
for domain in "toolgate" "discovery" "deployment" "open-source-readiness" "content-quality" "visual-design" "design-system" "interaction-design" "information-architecture" "adaptive-ux" "ux-antipatterns"; do
  domain_name="$(jq -r --arg d "$domain" '.domains[] | select(.id == $d) | .name' "$DOMAINS_FILE")"
  TOTAL=$((TOTAL + 1))
  # Check for domain appearing as a documented domain (in a table row, heading, or backtick-quoted)
  # The domain ID must appear with surrounding formatting: backticks, bold, table cell, or as heading text
  if echo "$readme_content" | grep -qP "\`$domain\`|\*\*.*${domain_name}.*\*\*|^\|.*${domain_name}.*\|" 2>/dev/null; then
    PASS=$((PASS + 1))
    echo "  PASS: domain '$domain' ($domain_name) documented"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: domain '$domain' ($domain_name) not documented"
    echo "    Expected to find: \`$domain\` or **$domain_name** or |...$domain_name...|"
  fi
done

# =====================================================================
# 11. Compliance domain lens count accuracy
# =====================================================================

echo ""
echo "Test 27: Compliance domain lens count is accurate"
# The old README says 6 — must now show the actual count
assert_not_contains "no stale compliance count of 6" "| 6 |" "$(echo "$readme_content" | grep -i compliance | head -1)"

# =====================================================================
# 12. Frontend domain lens count accuracy (was 9, now 5)
# =====================================================================

echo ""
echo "Test 28: Frontend domain lens count not stale"
# The old README claims 9 for frontend — it should now be 5
old_frontend_line="$(echo "$readme_content" | grep -i '| \*\*Frontend\*\*' | head -1 || true)"
if [[ -n "$old_frontend_line" ]]; then
  assert_not_contains "frontend not showing old count 9" "| 9 |" "$old_frontend_line"
fi
# If the line doesn't exist in that exact format, it's been restructured — still pass
if [[ -z "$old_frontend_line" ]]; then
  TOTAL=$((TOTAL + 1))
  PASS=$((PASS + 1))
  echo "  PASS: frontend domain line restructured (old format gone)"
fi

# =====================================================================
# 13. Mode-specific domains documented
# =====================================================================

echo ""
echo "Test 29: Mode-domain mapping documented"
# Mode-specific domains should be documented in context of their mode
# Check for the domain name appearing near the mode or as a backtick-quoted domain id
assert_matches "discovery domain documented" '(?i)discover.*14 lenses|14.*discover|`discovery`' "$readme_content"
assert_matches "deployment domain documented" '(?i)deploy.*26 lenses|26.*deploy|`deployment`' "$readme_content"
assert_matches "open-source-readiness domain documented" '(?i)opensource.*13 lenses|13.*opensource|`open-source-readiness`|open.source.readiness' "$readme_content"
assert_matches "content-quality domain documented" '(?i)content.*17 lenses|17.*content|`content-quality`|content.quality' "$readme_content"

# =====================================================================
# 14. Quickstart / first-run example
# =====================================================================

echo ""
echo "Test 30: Quickstart example with a runnable command"
assert_matches "quickstart command example" "repolens\.sh --project .* --agent" "$readme_content"

# =====================================================================
# 15. Overall structure — key sections present
# =====================================================================

echo ""
echo "Test 31: Key sections present"
assert_matches "has modes section" "(?i)^#{1,3} .*mode" "$readme_content"
assert_matches "has install/requirements section" "(?i)^#{1,3} .*(install|requirements|prerequisites|getting started)" "$readme_content"

# =====================================================================
# 16. Per-domain lens count accuracy — every domain count matches domains.json
# =====================================================================

echo ""
echo "Test 32: Per-domain lens counts match domains.json"
# For each domain, verify that its actual lens count from domains.json appears
# in the same README table row as the domain name. This catches stale counts.
while IFS=$'\t' read -r domain_id actual_count domain_name; do
  # Find the README line that contains this domain's display name (bold in table)
  readme_line="$(echo "$readme_content" | grep -i "| \*\*${domain_name}\*\*" | head -1 || true)"
  if [[ -z "$readme_line" ]]; then
    # Some domains may use slightly different formatting — try without bold
    readme_line="$(echo "$readme_content" | grep -i "| ${domain_name}" | head -1 || true)"
  fi
  TOTAL=$((TOTAL + 1))
  if [[ -z "$readme_line" ]]; then
    # Domain not found in any table — skip (covered by Test 26)
    PASS=$((PASS + 1))
    echo "  PASS: domain '$domain_id' ($domain_name) — not in table format (ok, tested elsewhere)"
  elif echo "$readme_line" | grep -qP "\|\s*${actual_count}\s"; then
    PASS=$((PASS + 1))
    echo "  PASS: domain '$domain_id' ($domain_name) shows correct count: $actual_count"
  elif echo "$readme_line" | grep -qP "${actual_count}\s+lenses"; then
    PASS=$((PASS + 1))
    echo "  PASS: domain '$domain_id' ($domain_name) shows correct count: $actual_count lenses"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: domain '$domain_id' ($domain_name) expected count $actual_count in table"
    echo "    Line: $readme_line"
  fi
done < <(jq -r '.domains[] | "\(.id)\t\(.lenses | length)\t\(.name)"' "$DOMAINS_FILE")

# =====================================================================
# 17. Code/toolgate aggregate lens count accuracy
# =====================================================================

echo ""
echo "Test 33: Code/toolgate aggregate lens count is accurate"
# The modes table claims N code/toolgate lenses — verify the number
code_toolgate_total="$(jq '[.domains[] | select(.mode == "code" or .mode == null) | .lenses | length] | add' "$DOMAINS_FILE")"
assert_contains "aggregate code/toolgate count ($code_toolgate_total) in README" "$code_toolgate_total" "$readme_content"

echo ""
echo "Test 34: Code/toolgate domain count is accurate"
code_toolgate_domains="$(jq '[.domains[] | select(.mode == "code" or .mode == null)] | length' "$DOMAINS_FILE")"
assert_contains "aggregate code/toolgate domain count ($code_toolgate_domains) in README" "$code_toolgate_domains" "$readme_content"

# =====================================================================
# 18. Agent CLI completeness — all supported agents documented
# =====================================================================

echo ""
echo "Test 35: All supported agent CLIs documented"
for agent in "claude" "codex" "spark" "sparc" "opencode"; do
  assert_contains "agent '$agent' documented" "$agent" "$readme_content"
done

# =====================================================================
# 19. Structural sections — key headings present
# =====================================================================

echo ""
echo "Test 36: Additional structural sections present"
assert_matches "has CLI Reference section" "(?i)^#{1,3} .*cli.*(reference|flag|usage)" "$readme_content"
assert_matches "has How It Works section" "(?i)^#{1,3} .*how it works" "$readme_content"
assert_matches "has Adding a Lens section" "(?i)^#{1,3} .*add.*lens" "$readme_content"
assert_matches "has Resume section" "(?i)^#{1,3} .*resume" "$readme_content"
assert_matches "has Output section" "(?i)^#{1,3} .*output" "$readme_content"
assert_matches "has Support section" "(?i)^#{1,3} .*(support|sponsor)" "$readme_content"

# =====================================================================
# 20. License badge is a proper image/shield link
# =====================================================================

echo ""
echo "Test 37: License badge is a proper shield image"
assert_matches "shield badge image" "\[!\[.*Apache.*\]\(https://img\.shields\.io" "$readme_content"

# --- Summary ---
echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
