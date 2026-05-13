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
assert_not_contains "suspect_files list does not leak into category output" "config/runtime.yml" "$digest_content"

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
assert_not_contains "non-audit domain name is not listed as touched audit coverage" "discovery" "$digest_content"
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
assert_contains "warning identifies missing required keys" "severity, domain, and lens are required" "$warnings"

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
echo "Test 8: oversized digest output is truncated to the hard line cap"
LOG_WARN_MESSAGES=()
truncation_repo="$TMPDIR/truncation-repo"
mkdir -p "$truncation_repo/lib"
cp "$ROUNDS_LIB" "$truncation_repo/lib/rounds.sh"
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
assert_contains "oversized digest includes truncation marker" "Digest truncated at 500 lines." "$digest_content"

finish
