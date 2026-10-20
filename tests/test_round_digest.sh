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

# Tests for issue #145: build_round_digest summarizes prior-round lens outputs
# into a compact, deterministic digest for later rounds.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROUNDS_LIB="$SCRIPT_DIR/lib/rounds.sh"

PASS=0
FAIL=0
TOTAL=0

TMP_PARENT="$SCRIPT_DIR/logs/test-round-digest"
mkdir -p "$TMP_PARENT"
TMPDIR="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"

cleanup() {
  rm -rf "$TMPDIR"
  rmdir "$TMP_PARENT" 2>/dev/null || true
}
trap cleanup EXIT

pass_with() {
  local desc="$1"
  PASS=$((PASS + 1))
  echo "  PASS: $desc"
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

assert_not_eq() {
  local desc="$1" left="$2" right="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$left" != "$right" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Did not expect equal values: $left"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected to find: $needle"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Did not expect to find: $needle"
  fi
}

assert_file_exists() {
  local desc="$1" file="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$file" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected file at $file"
  fi
}

assert_le() {
  local desc="$1" actual="$2" limit="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" =~ ^[0-9]+$ && "$actual" -le "$limit" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected $actual <= $limit"
  fi
}

assert_nonempty() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -n "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected a non-empty value"
  fi
}

join_by() {
  local sep="$1"
  shift
  local IFS="$sep"
  printf '%s' "$*"
}

read_if_exists() {
  local file="$1"
  if [[ -f "$file" ]]; then
    tr '\n' '\n' < "$file"
  else
    printf ''
  fi
}

make_round_dir() {
  local name="$1"
  local round_dir="$TMPDIR/$name/round-1"
  mkdir -p "$round_dir/lens-outputs"
  printf '%s\n' "$round_dir"
}

write_finding() {
  local file="$1" severity="$2" domain="$3" lens="$4" category="$5" suspect_file="$6"

  cat > "$file" <<EOF
---
title: "[$severity] Mock finding for $lens"
severity: $severity
domain: $domain
lens: $lens
root_cause_category: $category
suspect_files:
  - "$suspect_file"
labels:
  - "audit:$domain"
---

## Summary
Mock summary for $lens.

## Impact
Mock impact.

## Evidence
Mock evidence.

## Recommended Fix
Mock fix.

## References
Mock reference.
EOF
}

write_required_only_finding() {
  local file="$1" severity="$2" domain="$3" lens="$4"

  cat > "$file" <<EOF
---
severity: $severity
domain: $domain
lens: $lens
---

## Summary
Mock summary for $lens with only required frontmatter.

## Impact
Mock impact.
EOF
}

write_finding_with_category_list() {
  local file="$1" severity="$2" domain="$3" lens="$4" suspect_file="$5"

  cat > "$file" <<EOF
---
title: "[$severity] Mock finding for $lens"
severity: $severity
domain: $domain
lens: $lens
root_cause_category:
  - "Ops Drift"
  - Input_Validation
suspect_files:
  - "$suspect_file"
labels:
  - "audit:$domain"
---

## Summary
Mock summary for $lens.

## Impact
Mock impact.
EOF
}

write_lens_id_finding() {
  local file="$1" severity="$2" domain="$3" lens="$4" confidence="$5" first_suspect="$6" second_suspect="$7" hypothesis="$8"

  cat > "$file" <<EOF
---
title: "[$severity] Mock lens_id finding for $lens"
severity: $severity
confidence: $confidence
domain: $domain
lens_id: $lens
round: 1
root_cause_category: Input Validation
suspect_files:
  - "$first_suspect"
  - "$second_suspect"
---

## suspect_files
- $first_suspect
- $second_suspect

## hypothesis
$hypothesis

## evidence
Mock evidence anchored in the suspect files.
EOF
}

write_multi_finding_file() {
  local file="$1"

  cat > "$file" <<'EOF'
---
title: "[HIGH] First finding"
severity: HIGH
confidence: high
domain: security
lens_id: injection
round: 1
root_cause_category: Input Validation
suspect_files:
  - "app/controllers/login.rb:42"
  - "app/session.rb:17"
---

## hypothesis
First hypothesis belongs to the login controller.

## evidence
First evidence.
---
title: "[MEDIUM] Second finding"
severity: MEDIUM
confidence: medium
domain: security
lens_id: injection
round: 1
root_cause_category: Auth
suspect_files:
  - "app/session.rb:17"
  - "app/controllers/login.rb:42"
---

## hypothesis
Second hypothesis belongs to the token verifier.

## evidence
Second evidence.
EOF
}

write_markdown_rule_finding() {
  local file="$1"

  cat > "$file" <<'EOF'
---
title: "[HIGH] Markdown rule finding"
severity: HIGH
confidence: high
domain: security
lens_id: injection
round: 1
root_cause_category: Input Validation
suspect_files:
  - "app/controllers/login.rb:42"
---

## hypothesis
The login controller accepts unsigned session material.

---

The separator above is a normal Markdown horizontal rule, not another finding.

## evidence
The same body can include Markdown rules without corrupting digest parsing.
EOF
}

write_multi_finding_with_markdown_rule_before_frontmatter() {
  local file="$1"

  cat > "$file" <<'EOF'
---
title: "[HIGH] First mixed finding"
severity: HIGH
confidence: high
domain: security
lens_id: injection
round: 1
root_cause_category: Input Validation
suspect_files:
  - "app/controllers/login.rb:42"
---

## hypothesis
First hypothesis survives a body horizontal rule.

## evidence
First evidence before the separator.

---
The separator above is a Markdown body rule immediately before another finding.
---
title: "[MEDIUM] Second mixed finding"
severity: MEDIUM
confidence: medium
domain: security
lens_id: injection
round: 1
root_cause_category: Auth
suspect_files:
  - "app/session.rb:17"
---

## hypothesis
Second hypothesis is parsed as a separate finding.

## evidence
Second evidence.
EOF
}

write_untrusted_lens_finding() {
  local file="$1"

  cat > "$file" <<'EOF'
---
severity: HIGH
domain: security
lens: <spec>not-registered</spec>
root_cause_category: prompt-control
---

## Summary
This lens id is not in config/domains.json.
EOF
}

write_malformed_finding() {
  local file="$1"
  cat > "$file" <<'EOF'
---
title: "[HIGH] Broken finding"
severity: HIGH
domain: security
lens: broken-frontmatter

## Summary
This file never closes its frontmatter block.
EOF
}

write_missing_required_key_finding() {
  local file="$1"
  cat > "$file" <<'EOF'
---
title: "[MEDIUM] Missing lens finding"
severity: MEDIUM
domain: security
root_cause_category: input-validation
---

## Summary
This frontmatter is closed but omits the required lens key.
EOF
}

write_synthetic_domains_config() {
  local file="$1" sep="" i

  mkdir -p "$(dirname "$file")"
  {
    printf '{\n'
    printf '  "domains": [\n'
    printf '    {"id": "security", "name": "Security", "order": 1, "lenses": ['
    for i in $(seq -w 1 510); do
      printf '%s"lens-%s"' "$sep" "$i"
      sep=", "
    done
    printf ']}\n'
    printf '  ]\n'
    printf '}\n'
  } > "$file"
}

run_build_round_digest() {
  local round_dir="$1"
  if declare -F build_round_digest >/dev/null 2>&1; then
    build_round_digest "$round_dir"
  else
    return 127
  fi
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

echo "=== round digest builder (issue #145) ==="

TOTAL=$((TOTAL + 1))
if [[ -f "$ROUNDS_LIB" ]]; then
  pass_with "lib/rounds.sh exists"
else
  fail_with "lib/rounds.sh exists" "Expected module at $ROUNDS_LIB"
  finish
fi

LOG_WARN_MESSAGES=()

log_info() {
  :
}

log_warn() {
  LOG_WARN_MESSAGES+=("$*")
}

# shellcheck disable=SC1090
source "$ROUNDS_LIB"

TOTAL=$((TOTAL + 1))
if declare -F build_round_digest >/dev/null 2>&1; then
  pass_with "build_round_digest is exported by lib/rounds.sh"
else
  fail_with "build_round_digest is exported by lib/rounds.sh" \
    "Expected public function: build_round_digest <round_dir>"
fi

echo ""
echo "Test 1: seven markdown lens outputs produce a compact aggregate digest"
round_dir="$(make_round_dir "seven-findings")"
lens_dir="$round_dir/lens-outputs"

write_finding "$lens_dir/001-injection.md" HIGH security injection input-validation "app/controllers/login.rb"
write_finding "$lens_dir/002-auth-session.md" MEDIUM security auth-session input-validation "app/session.rb"
write_finding "$lens_dir/003-unit-test-gaps.md" LOW testing unit-test-gaps test-coverage "tests/api_test.rb"
write_finding "$lens_dir/004-error-path-tests.md" MEDIUM testing error-path-tests test-coverage "tests/error_test.rb"
write_finding "$lens_dir/005-ci-pipeline.md" LOW devops ci-pipeline build-configuration ".github/workflows/ci.yml"
write_finding "$lens_dir/006-env-config.md" MEDIUM devops env-config build-configuration ".env.example"
write_finding "$lens_dir/007-logging.md" LOW observability logging input-validation "lib/logging.sh"
cat > "$lens_dir/not-a-finding.txt" <<'EOF'
---
severity: HIGH
domain: security
lens: ignored-non-md
root_cause_category: ignored
---
EOF

run_build_round_digest "$round_dir"
rc=$?
assert_eq "build_round_digest exits successfully for valid lens outputs" "0" "$rc"

digest="$round_dir/digest.md"
assert_file_exists "digest.md is written into the round directory" "$digest"
digest_content="$(read_if_exists "$digest")"

for lens in injection auth-session unit-test-gaps error-path-tests ci-pipeline env-config logging; do
  assert_contains "digest lists lens id $lens" "$lens" "$digest_content"
  assert_contains "digest records one finding for $lens" "$lens: 1" "$digest_content"
done

assert_contains "digest includes top themes section" "## Top Themes" "$digest_content"
assert_contains "digest includes input-validation theme" "input-validation" "$digest_content"
assert_contains "digest includes test-coverage theme" "test-coverage" "$digest_content"
assert_contains "digest includes build-configuration theme" "build-configuration" "$digest_content"
assert_contains "digest includes coverage section" "## Coverage" "$digest_content"
assert_contains "coverage denominator uses audit-visible domains" "4/27" "$digest_content"
for domain in security testing devops observability; do
  assert_contains "coverage lists touched domain $domain" "$domain" "$digest_content"
done
assert_not_contains "non-markdown files are ignored" "ignored-non-md" "$digest_content"

if [[ -f "$digest" ]]; then
  digest_lines="$(wc -l < "$digest")"
else
  digest_lines=9999
fi
assert_le "digest stays within the 500-line hard cap" "$digest_lines" 500

echo ""
echo "Test 1b: nested LOCAL_MODE lens output directories are included in digest"
LOG_WARN_MESSAGES=()
round_dir="$(make_round_dir "nested-lens-outputs")"
mkdir -p "$round_dir/lens-outputs/security/injection" \
         "$round_dir/lens-outputs/testing/unit-test-gaps"

write_finding "$round_dir/lens-outputs/security/injection/001-injection.md" HIGH security injection input-validation "app/controllers/login.rb"
write_finding "$round_dir/lens-outputs/testing/unit-test-gaps/001-unit-test-gaps.md" LOW testing unit-test-gaps test-coverage "tests/api_test.rb"

run_build_round_digest "$round_dir"
rc=$?
assert_eq "nested LOCAL_MODE outputs exit successfully" "0" "$rc"

digest="$round_dir/digest.md"
assert_file_exists "nested output round writes digest.md" "$digest"
digest_content="$(read_if_exists "$digest")"

assert_contains "digest includes nested security lens output" "injection: 1 finding" "$digest_content"
assert_contains "digest includes nested testing lens output" "unit-test-gaps: 1 finding" "$digest_content"
assert_contains "nested digest records input-validation theme" "input-validation" "$digest_content"
assert_contains "nested digest records test-coverage theme" "test-coverage" "$digest_content"
warnings="$(join_by " " "${LOG_WARN_MESSAGES[@]:-}")"
assert_eq "nested registered outputs emit no warnings" "" "$warnings"

echo ""
echo "Test 2: duplicate lenses and category lists aggregate into stable counts"
LOG_WARN_MESSAGES=()
round_dir="$(make_round_dir "aggregate-counts")"
lens_dir="$round_dir/lens-outputs"

write_finding "$lens_dir/001-auth-session.md" HIGH security auth-session auth "app/session.rb"
write_finding "$lens_dir/002-auth-session.md" MEDIUM security auth-session auth "app/token.rb"
write_finding_with_category_list "$lens_dir/003-env-config.md" MEDIUM devops env-config "config/runtime.yml"
write_required_only_finding "$lens_dir/004-docker.md" LOW devops docker

run_build_round_digest "$round_dir"
rc=$?
assert_eq "duplicate lens aggregation exits successfully" "0" "$rc"

digest="$round_dir/digest.md"
assert_file_exists "aggregate digest.md is written" "$digest"
digest_content="$(read_if_exists "$digest")"

assert_contains "duplicate lens findings are counted together" "auth-session: 2 findings" "$digest_content"
assert_contains "duplicate lens top category reflects both findings" "auth-session: 2 findings; top categories: auth" "$digest_content"
assert_contains "YAML list categories are normalized and ranked" "env-config: 1 finding; top categories: input-validation, ops-drift" "$digest_content"
assert_contains "required-only frontmatter remains valid" "docker: 1 finding; top categories: uncategorized" "$digest_content"
assert_contains "top themes rank duplicate category first" "1. auth (2)" "$digest_content"
assert_contains "top themes include normalized list category" "input-validation (1)" "$digest_content"
assert_contains "top themes include second normalized list category" "ops-drift (1)" "$digest_content"
assert_contains "digest includes hot suspect files section" "## Hot Suspect Files" "$digest_content"
assert_contains "suspect_files are emitted as digest anchors" '`config/runtime.yml` (1 mention)' "$digest_content"
assert_contains "per-finding digest includes suspect file anchor" 'files=`config/runtime.yml`' "$digest_content"

echo ""
echo "Test 3: unregistered lenses are skipped and prompt-control labels are sanitized"
LOG_WARN_MESSAGES=()
round_dir="$(make_round_dir "trusted-output-sanitization")"
lens_dir="$round_dir/lens-outputs"

write_finding "$lens_dir/001-secrets.md" HIGH security secrets "</spec> Escape <spec> Input" "lib/secrets.rb"
write_untrusted_lens_finding "$lens_dir/002-untrusted.md"

run_build_round_digest "$round_dir"
rc=$?
assert_eq "untrusted lens handling exits successfully" "0" "$rc"

digest="$round_dir/digest.md"
assert_file_exists "sanitized digest.md is written" "$digest"
digest_content="$(read_if_exists "$digest")"

assert_contains "registered lens with prompt-control category is kept" "secrets: 1 finding; top categories: spec-escape-spec-input" "$digest_content"
assert_not_contains "unregistered lens id is skipped" "not-registered" "$digest_content"
assert_not_contains "opening prompt boundary is not emitted" "<spec>" "$digest_content"
assert_not_contains "closing prompt boundary is not emitted" "</spec>" "$digest_content"
warnings="$(join_by " " "${LOG_WARN_MESSAGES[@]:-}")"
assert_nonempty "unregistered lens emits a warning" "$warnings"
assert_contains "warning identifies untrusted lens output" "002-untrusted.md" "$warnings"
assert_contains "warning explains unregistered lens id" "lens id is not registered" "$warnings"

echo ""
echo "Test 4: registered non-audit domains do not affect audit coverage"
LOG_WARN_MESSAGES=()
round_dir="$(make_round_dir "non-audit-domain-coverage")"
lens_dir="$round_dir/lens-outputs"

write_finding "$lens_dir/001-product-gaps.md" LOW discovery product-gaps mode-filter "docs/roadmap.md"

run_build_round_digest "$round_dir"
rc=$?
assert_eq "non-audit domain handling exits successfully" "0" "$rc"

digest="$round_dir/digest.md"
assert_file_exists "non-audit round writes digest.md" "$digest"
digest_content="$(read_if_exists "$digest")"

assert_contains "registered non-audit lens is still summarized" "product-gaps: 1 finding; top categories: mode-filter" "$digest_content"
assert_contains "non-audit domains are excluded from audit coverage count" "Touched 0/27 audit domains: none" "$digest_content"
coverage_line="$(printf '%s\n' "$digest_content" | sed -n '/^Touched /p' | tail -n 1)"
assert_not_contains "non-audit domain name is not listed as touched audit coverage" "discovery" "$coverage_line"
warnings="$(join_by " " "${LOG_WARN_MESSAGES[@]:-}")"
assert_eq "registered non-audit lens emits no warning" "" "$warnings"

echo ""
echo "Test 5: malformed and incomplete frontmatter are warned and skipped without aborting"
LOG_WARN_MESSAGES=()
round_dir="$(make_round_dir "malformed-frontmatter")"
lens_dir="$round_dir/lens-outputs"

write_finding "$lens_dir/001-good.md" HIGH security injection input-validation "app/controllers/login.rb"
write_finding "$lens_dir/002-good.md" MEDIUM security auth-session input-validation "app/session.rb"
write_finding "$lens_dir/003-good.md" LOW testing unit-test-gaps test-coverage "tests/api_test.rb"
write_finding "$lens_dir/004-good.md" MEDIUM testing error-path-tests test-coverage "tests/error_test.rb"
write_finding "$lens_dir/005-good.md" LOW devops ci-pipeline build-configuration ".github/workflows/ci.yml"
write_finding "$lens_dir/006-good.md" LOW observability logging input-validation "lib/logging.sh"
write_finding "$lens_dir/007-invalid-severity.md" INFO observability structured-logging input-validation "lib/structured_logging.sh"
write_malformed_finding "$lens_dir/008-bad-frontmatter.md"
write_missing_required_key_finding "$lens_dir/009-missing-lens.md"

run_build_round_digest "$round_dir"
rc=$?
assert_eq "malformed frontmatter does not abort digest generation" "0" "$rc"

digest="$round_dir/digest.md"
assert_file_exists "digest.md is still written when one file is malformed" "$digest"
digest_content="$(read_if_exists "$digest")"

for lens in injection auth-session unit-test-gaps error-path-tests ci-pipeline logging; do
  assert_contains "digest keeps valid lens id $lens" "$lens" "$digest_content"
done
assert_not_contains "malformed lens is skipped from digest" "broken-frontmatter" "$digest_content"
assert_not_contains "invalid INFO severity is skipped from digest" "structured-logging" "$digest_content"
assert_not_contains "frontmatter missing required lens key is skipped" "Missing lens finding" "$digest_content"
warnings="$(join_by " " "${LOG_WARN_MESSAGES[@]:-}")"
assert_nonempty "malformed frontmatter emits a warning" "$warnings"
assert_contains "warning identifies malformed file" "008-bad-frontmatter.md" "$warnings"
assert_contains "warning identifies invalid severity file" "007-invalid-severity.md" "$warnings"
assert_contains "warning identifies missing required keys" "severity, domain, and lens_id or lens are required" "$warnings"

echo ""
echo "Test 6: empty lens-outputs directory still writes a no-findings digest"
LOG_WARN_MESSAGES=()
round_dir="$(make_round_dir "empty-lens-outputs")"

run_build_round_digest "$round_dir"
rc=$?
assert_eq "empty lens-outputs exits successfully" "0" "$rc"

digest="$round_dir/digest.md"
assert_file_exists "empty round writes digest.md" "$digest"
digest_content="$(read_if_exists "$digest")"
digest_lower="$(printf '%s' "$digest_content" | tr '[:upper:]' '[:lower:]')"
assert_contains "empty digest states no findings" "no findings this round" "$digest_lower"
assert_contains "empty digest reports zero audit-domain coverage" "0/27" "$digest_content"

echo ""
echo "Test 7: missing lens-outputs directory is treated as a no-findings round"
LOG_WARN_MESSAGES=()
round_dir="$TMPDIR/missing-lens-outputs/round-1"
mkdir -p "$round_dir"

run_build_round_digest "$round_dir"
rc=$?
assert_eq "missing lens-outputs exits successfully" "0" "$rc"

digest="$round_dir/digest.md"
assert_file_exists "missing lens-outputs round writes digest.md" "$digest"
digest_content="$(read_if_exists "$digest")"
digest_lower="$(printf '%s' "$digest_content" | tr '[:upper:]' '[:lower:]')"
assert_contains "missing lens-outputs digest states no findings" "no findings this round" "$digest_lower"
assert_contains "missing lens-outputs reports zero audit-domain coverage" "0/27" "$digest_content"

echo ""
echo "Test 8: lens_id findings emit stable ids, hypotheses, and file anchors"
LOG_WARN_MESSAGES=()
round_dir="$(make_round_dir "finding-bodies")"
lens_dir="$round_dir/lens-outputs"

write_lens_id_finding "$lens_dir/001-injection.md" HIGH security injection high \
  "app/controllers/login.rb:42" "app/session.rb:17" \
  "Login validation accepts unsigned session material across the controller boundary."
write_finding "$lens_dir/002-auth-session.md" MEDIUM security auth-session auth "app/token.rb:9"

run_build_round_digest "$round_dir"
rc=$?
assert_eq "lens_id finding digest exits successfully" "0" "$rc"

digest="$round_dir/digest.md"
assert_file_exists "lens_id digest.md is written" "$digest"
digest_content="$(read_if_exists "$digest")"
assert_contains "per-finding section is emitted" "## Findings" "$digest_content"
assert_contains "finding entry has stable id prefix" '`f:' "$digest_content"
assert_contains "finding entry includes severity and confidence" "high/high" "$digest_content"
assert_contains "finding entry includes lens_id lens path" '`security/injection`' "$digest_content"
assert_contains "finding entry includes first suspect anchor" '`app/controllers/login.rb:42`' "$digest_content"
assert_contains "finding entry includes second suspect anchor" '`app/session.rb:17`' "$digest_content"
assert_contains "finding entry includes hypothesis excerpt" "Login validation accepts unsigned session material" "$digest_content"

first_id="$(printf '%s\n' "$digest_content" | sed -nE 's/^- `f:([0-9a-f]{16})`.*/\1/p' | head -n 1)"
assert_nonempty "finding id can be extracted" "$first_id"

round_dir="$(make_round_dir "finding-id-stability")"
lens_dir="$round_dir/lens-outputs"
write_lens_id_finding "$lens_dir/001-injection.md" HIGH security injection high \
  "app/session.rb:17" "app/controllers/login.rb:42" \
  "Login validation accepts unsigned session material across the controller boundary."

run_build_round_digest "$round_dir"
rc=$?
assert_eq "reordered suspect files digest exits successfully" "0" "$rc"
digest_content="$(read_if_exists "$round_dir/digest.md")"
second_id="$(printf '%s\n' "$digest_content" | sed -nE 's/^- `f:([0-9a-f]{16})`.*/\1/p' | head -n 1)"
assert_eq "finding id is stable across suspect file order" "$first_id" "$second_id"

echo ""
echo "Test 9: multiple findings in one markdown file each contribute digest records"
LOG_WARN_MESSAGES=()
round_dir="$(make_round_dir "multi-finding-file")"
lens_dir="$round_dir/lens-outputs"
write_multi_finding_file "$lens_dir/001-combined.md"

run_build_round_digest "$round_dir"
rc=$?
assert_eq "multi-finding digest exits successfully" "0" "$rc"

digest="$round_dir/digest.md"
assert_file_exists "multi-finding digest.md is written" "$digest"
digest_content="$(read_if_exists "$digest")"
assert_contains "first finding hypothesis is emitted" "First hypothesis belongs to the login controller" "$digest_content"
assert_contains "second finding hypothesis is emitted" "Second hypothesis belongs to the token verifier" "$digest_content"
assert_contains "shared first finding anchor is emitted" '`app/controllers/login.rb:42`' "$digest_content"
assert_contains "shared second finding anchor is emitted" '`app/session.rb:17`' "$digest_content"
assert_contains "shared first hot suspect is counted twice" '`app/controllers/login.rb:42` (2 mentions)' "$digest_content"
assert_contains "shared second hot suspect is counted twice" '`app/session.rb:17` (2 mentions)' "$digest_content"

first_id="$(printf '%s\n' "$digest_content" | sed -nE 's/^- `f:([0-9a-f]{16})`.*/\1/p' | sed -n '1p')"
second_id="$(printf '%s\n' "$digest_content" | sed -nE 's/^- `f:([0-9a-f]{16})`.*/\1/p' | sed -n '2p')"
assert_nonempty "first multi-finding id can be extracted" "$first_id"
assert_nonempty "second multi-finding id can be extracted" "$second_id"
assert_not_eq "multi-finding records have distinct ids" "$first_id" "$second_id"

echo ""
echo "Test 10: markdown horizontal rules in finding bodies are preserved"
LOG_WARN_MESSAGES=()
round_dir="$(make_round_dir "markdown-rule-body")"
lens_dir="$round_dir/lens-outputs"
write_markdown_rule_finding "$lens_dir/001-markdown-rule.md"

run_build_round_digest "$round_dir"
rc=$?
assert_eq "markdown-rule finding digest exits successfully" "0" "$rc"

digest="$round_dir/digest.md"
assert_file_exists "markdown-rule digest.md is written" "$digest"
digest_content="$(read_if_exists "$digest")"
assert_contains "markdown-rule finding hypothesis is emitted" "The login controller accepts unsigned session material" "$digest_content"
assert_contains "markdown-rule finding file anchor is emitted" '`app/controllers/login.rb:42`' "$digest_content"
warnings="$(printf '%s\n' "${LOG_WARN_MESSAGES[@]:-}")"
assert_not_contains "markdown horizontal rule does not warn as malformed" "001-markdown-rule.md" "$warnings"

echo ""
echo "Test 11: markdown rule before later frontmatter still splits findings"
LOG_WARN_MESSAGES=()
round_dir="$(make_round_dir "markdown-rule-before-frontmatter")"
lens_dir="$round_dir/lens-outputs"
write_multi_finding_with_markdown_rule_before_frontmatter "$lens_dir/001-mixed.md"

run_build_round_digest "$round_dir"
rc=$?
assert_eq "mixed delimiter digest exits successfully" "0" "$rc"

digest="$round_dir/digest.md"
assert_file_exists "mixed delimiter digest.md is written" "$digest"
digest_content="$(read_if_exists "$digest")"
assert_contains "first mixed hypothesis is emitted" "First hypothesis survives a body horizontal rule" "$digest_content"
assert_contains "second mixed hypothesis is emitted" "Second hypothesis is parsed as a separate finding" "$digest_content"
assert_contains "first mixed anchor is emitted" '`app/controllers/login.rb:42`' "$digest_content"
assert_contains "second mixed anchor is emitted" '`app/session.rb:17`' "$digest_content"
first_id="$(printf '%s\n' "$digest_content" | sed -nE 's/^- `f:([0-9a-f]{16})`.*/\1/p' | sed -n '1p')"
second_id="$(printf '%s\n' "$digest_content" | sed -nE 's/^- `f:([0-9a-f]{16})`.*/\1/p' | sed -n '2p')"
assert_nonempty "first mixed id can be extracted" "$first_id"
assert_nonempty "second mixed id can be extracted" "$second_id"
assert_not_eq "mixed records have distinct ids" "$first_id" "$second_id"
warnings="$(printf '%s\n' "${LOG_WARN_MESSAGES[@]:-}")"
assert_not_contains "mixed delimiter file does not warn as malformed" "001-mixed.md" "$warnings"

echo ""
echo "Test: static trust binds both domain and lens; generated collisions require dispatch"
LOG_WARN_MESSAGES=()
round_dir="$(make_round_dir "domain-bound-trust")"
lens_dir="$round_dir/lens-outputs"
for trust_domain in security generic custom testing; do
  write_lens_id_finding "$lens_dir/$trust_domain.md" HIGH "$trust_domain" injection 0.9 \
    src/probe.rb:1 src/probe.rb:2 "DOMAIN_TRUST_$trust_domain"
done
build_round_digest "$round_dir" generic/deeper-check
assert_eq "unrelated generated dispatch builds successfully" 0 "$?"
digest_content="$(read_if_exists "$round_dir/digest.md")"
assert_contains "registered security/injection remains trusted without dispatch" DOMAIN_TRUST_security "$digest_content"
for trust_domain in generic custom testing; do
  assert_not_contains "static name cannot authorize $trust_domain/injection" "DOMAIN_TRUST_$trust_domain" "$digest_content"
done
build_round_digest "$round_dir" generic/injection custom/injection
assert_eq "explicitly dispatched colliding generated names build successfully" 0 "$?"
digest_content="$(read_if_exists "$round_dir/digest.md")"
for trust_domain in generic custom; do
  assert_contains "explicit dispatch authorizes $trust_domain/injection" "DOMAIN_TRUST_$trust_domain" "$digest_content"
done
assert_not_contains "generated dispatch cannot authorize testing/injection" DOMAIN_TRUST_testing "$digest_content"
# Registry entries use domain/lens pairs for both supported lens representations.
trust_registry="$TMPDIR/trust-registry.json"
printf '%s\n' '{"domains":[{"id":"security","lenses":["injection",{"id":"authorization"}]}]}' > "$trust_registry"
assert_eq "registry extraction returns exact pairs for strings and objects" \
  $'security/injection\nsecurity/authorization' "$(_round_digest_registered_lenses "$trust_registry")"

echo "Test 12: oversized digest output is semantically capped before the hard line cap"
LOG_WARN_MESSAGES=()
truncation_repo="$TMPDIR/truncation-repo"
mkdir -p "$truncation_repo/lib"
cp "$ROUNDS_LIB" "$truncation_repo/lib/rounds.sh"
cp "$SCRIPT_DIR/lib/artifacts.sh" "$truncation_repo/lib/artifacts.sh"
write_synthetic_domains_config "$truncation_repo/config/domains.json"

# shellcheck disable=SC1090
source "$truncation_repo/lib/rounds.sh"

round_dir="$truncation_repo/logs/round-1"
mkdir -p "$round_dir/lens-outputs"
lens_dir="$round_dir/lens-outputs"

for i in $(seq -w 1 510); do
  write_finding "$lens_dir/$i-lens.md" LOW security "lens-$i" "category-$i" "lib/file-$i.sh"
done

run_build_round_digest "$round_dir"
rc=$?
assert_eq "oversized digest exits successfully" "0" "$rc"

digest="$round_dir/digest.md"
assert_file_exists "oversized round writes digest.md" "$digest"
if [[ -f "$digest" ]]; then
  digest_lines="$(wc -l < "$digest")"
else
  digest_lines=9999
fi
assert_le "oversized digest is truncated within the 500-line hard cap" "$digest_lines" 500
digest_content="$(read_if_exists "$digest")"
assert_contains "oversized digest includes finding section despite many lens summaries" "## Findings" "$digest_content"
assert_contains "oversized digest summarizes omitted lens summaries" "more lenses omitted from digest summary" "$digest_content"
assert_not_contains "oversized digest avoids hard truncation marker" "Digest truncated at 500 lines." "$digest_content"

finish
