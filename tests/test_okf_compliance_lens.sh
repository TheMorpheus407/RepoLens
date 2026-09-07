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

# Behavioral contract for issue #387: content-quality/okf-compliance.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LENS_FILE="$SCRIPT_DIR/prompts/lenses/content-quality/okf-compliance.md"
DOMAINS_FILE="$SCRIPT_DIR/config/domains.json"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/template.sh"

PASS=0
FAIL=0
TOTAL=0
CREATED_RUN_IDS=()

OKF_TEST_TMP="$(mktemp -d)"
PROJECT_DIR="$OKF_TEST_TMP/project"
FAKE_BIN="$OKF_TEST_TMP/bin"
mkdir -p "$PROJECT_DIR" "$FAKE_BIN"

# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
cleanup() {
  local run_id
  rm -rf "$OKF_TEST_TMP"
  for run_id in "${CREATED_RUN_IDS[@]:-}"; do
    if [[ "$run_id" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$ ]]; then
      rm -rf "$SCRIPT_DIR/logs/$run_id"
    fi
  done
}
trap cleanup EXIT

printf '# OKF lens routing fixture\n' > "$PROJECT_DIR/README.md"
git -C "$PROJECT_DIR" init -q
git -C "$PROJECT_DIR" config user.name "RepoLens Test"
git -C "$PROJECT_DIR" config user.email "repolens@example.invalid"
git -C "$PROJECT_DIR" config commit.gpgsign false
git -C "$PROJECT_DIR" add README.md
git -C "$PROJECT_DIR" commit -q -m "fixture"
git -C "$PROJECT_DIR" remote add origin https://github.com/owner/repo.git

printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/codex"
chmod +x "$FAKE_BIN/codex"

record_pass() {
  TOTAL=$((TOTAL + 1))
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

record_fail() {
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (expected '$expected', got '$actual')"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (missing '$needle')"
  fi
}

assert_matches() {
  local desc="$1" pattern="$2" haystack="$3"
  if grep -Eiq -- "$pattern" <<< "$haystack"; then
    record_pass "$desc"
  else
    record_fail "$desc (missing pattern '$pattern')"
  fi
}

echo ""
echo "=== Test Suite: OKF compliance lens (issue #387) ==="
echo ""

if [[ -f "$LENS_FILE" ]]; then
  record_pass "OKF compliance lens prompt exists"
  lens_content="$(cat "$LENS_FILE")"
else
  record_fail "OKF compliance lens prompt exists"
  lens_content=""
fi

echo ""
echo "Test 1: frontmatter exposes the expected lens identity"
if [[ -f "$LENS_FILE" ]]; then
  assert_eq "frontmatter id" "okf-compliance" "$(read_frontmatter "$LENS_FILE" id)"
  assert_eq "frontmatter domain" "content-quality" "$(read_frontmatter "$LENS_FILE" domain)"
  assert_eq "frontmatter name" "OKF (Open Knowledge Format) Compliance" "$(read_frontmatter "$LENS_FILE" name)"
  assert_eq "frontmatter role" "Open Knowledge Format Auditor" "$(read_frontmatter "$LENS_FILE" role)"
else
  record_fail "frontmatter id (prompt missing)"
  record_fail "frontmatter domain (prompt missing)"
  record_fail "frontmatter name (prompt missing)"
  record_fail "frontmatter role (prompt missing)"
fi

echo ""
echo "Test 2: applicability is established before reporting"
for section in \
  "## Your Expert Focus" \
  "### Applicability Gate" \
  "### What You Hunt For" \
  "### OKF v0.2 Conformance vs Readiness" \
  "### False-Positive Guards" \
  "### How You Investigate"; do
  assert_contains "prompt contains $section" "$section" "$lens_content"
done
assert_matches "identifies a coherent bundle and its root" \
  'coherent (candidate )?(OKF )?(bundle|corpus).*(root|boundary)|(root|boundary).*coherent (candidate )?(OKF )?(bundle|corpus)' \
  "$lens_content"
assert_matches "ordinary Markdown alone is not reported" \
  '(do not|never).*(report|convert|flag).*(every|ordinary|arbitrary).*Markdown' \
  "$lens_content"
assert_matches "readiness findings require demonstrated impact or benefit" \
  '(readiness|conversion).*(finding|opportunit).*(concrete|demonstrated|evidence).*(impact|benefit|consumer|maintenance)' \
  "$lens_content"

echo ""
echo "Test 3: strict OKF v0.2 conformance has the narrow canonical floor"
assert_contains "links the canonical v0.2 specification" \
  "https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/main/okf/SPEC.md" \
  "$lens_content"
assert_matches "ordinary concepts require UTF-8 Markdown" \
  'ordinary concept.*require UTF-8 Markdown|ordinary concept.*not UTF-8 Markdown' \
  "$lens_content"
assert_matches "ordinary concepts require parseable opening YAML frontmatter" \
  'ordinary concept.*parseable.*(opening|start).*YAML frontmatter' \
  "$lens_content"
assert_matches "ordinary concepts require non-empty type" \
  '(non-empty|required).*`type`|`type`.*(non-empty|required)' \
  "$lens_content"
assert_contains "type is the only always-required key" \
  '`type` is the only always-required frontmatter key' \
  "$lens_content"
assert_matches "identity is the bundle-relative path without .md" \
  '(ID|identity).*bundle-relative path without the `?\.md`? suffix' \
  "$lens_content"

echo ""
echo "Test 4: reserved files use their own structure"
assert_matches "index.md and log.md are reserved exceptions" \
  '`index\.md`.*`log\.md`.*reserved-file exceptions' \
  "$lens_content"
assert_matches "root index permits only the optional v0.2 declaration" \
  'bundle-root `index\.md`.*single optional declaration `okf_version: "0\.2"`' \
  "$lens_content"
assert_matches "all other indexes omit frontmatter" \
  '`index\.md`.*contains no frontmatter, except.*bundle-root' \
  "$lens_content"
assert_matches "index body uses heading-grouped sections" \
  '`index\.md`.*body uses one or more heading-grouped sections.*concepts or subdirectories' \
  "$lens_content"
assert_matches "index entry descriptions are not strict" \
  'entry descriptions are recommended, not strict' \
  "$lens_content"
assert_matches "log entries use ISO dates" \
  '`log\.md`.*ISO.*YYYY-MM-DD' \
  "$lens_content"
assert_matches "log entries are newest first" \
  '`log\.md`.*(newest-first|reverse chronological)' \
  "$lens_content"
assert_matches "log is a flat date-grouped list" \
  '`log\.md`.*flat, date-grouped list' \
  "$lens_content"

echo ""
echo "Test 5: optional families stay outside strict conformance"
for family in sources generated verified status stale_after links "Attested Computation"; do
assert_matches "names optional/readiness family: $family" \
    "(optional|readiness|quality).*${family}|${family}.*(optional|readiness|quality)" \
    "$lens_content"
done
assert_matches "malformed optional data is never strict non-conformance" \
  '(malformed|invalid|incomplete).*optional.*(must never|not|do not).*strict non-conformance' \
  "$lens_content"
assert_matches "optional-data findings require consumer impact" \
  '(malformed|invalid|incomplete).*optional.*(readiness|content-quality).*finding.*consumer impact' \
  "$lens_content"

echo ""
echo "Test 6: present optional metadata follows accurate v0.2 shapes"
assert_contains "recommended discovery fields are not strict requirements" \
  '`title`, `description`, `resource`, and `tags` are recommended discovery metadata, not strict requirements' \
  "$lens_content"
assert_matches "source entries require resource and may use an attribution id" \
  '`sources` entry requires `resource`.*`id` is an optional.*(join|attribution)' \
  "$lens_content"
assert_matches "generated.by is required only when generated is present" \
  '`generated` family is optional.*`generated\.by` is required whenever `generated` is present' \
  "$lens_content"
assert_matches "generated.at is an ISO 8601 date-time when present" \
  '`generated\.at`, when present, is an ISO 8601 date-time' \
  "$lens_content"
assert_matches "verified accepts one event or a list" \
  '`verified`.*one event mapping or a list of events' \
  "$lens_content"
assert_matches "verification events contain by and at" \
  'Every event contains `by`.*and `at`.*ISO 8601' \
  "$lens_content"
assert_contains "does not invent a verification method field" \
  'OKF v0.2 defines no `method` field' \
  "$lens_content"
assert_matches "defines all canonical actor forms" \
  '<producer>/<version>.*`human:<id>`.*`process:<id>`' \
  "$lens_content"
assert_matches "human-authored or confirmed content uses the human actor form" \
  'must use the `human:` form for hand-authored or human-confirmed content' \
  "$lens_content"
assert_matches "derives all three trust tiers from verified" \
  'no `verified` key means unverified.*non-`human:` actors means machine-confirmed.*`human:<id>` verifier means human-reviewed' \
  "$lens_content"
assert_matches "missing trust metadata does not invalidate a concept" \
  'Missing trust metadata never makes an otherwise conformant concept invalid' \
  "$lens_content"
assert_matches "status uses the canonical lifecycle values" \
  '`status` uses `draft`, `stable`, or `deprecated`' \
  "$lens_content"
assert_matches "absent status means stable" \
  '`status`.*when absent it means `stable`' \
  "$lens_content"
assert_matches "stale_after uses an ISO date" \
  '`stale_after` is an ISO `YYYY-MM-DD` date' \
  "$lens_content"
assert_contains "staleness starts on the configured date" \
  'stale when `today >= stale_after`' \
  "$lens_content"
assert_matches "Attested Computation identifies its runtime contract" \
  '`Attested Computation`.*`runtime` is required.*soft contract' \
  "$lens_content"
assert_matches "Attested Computation covers parameters, executor, and attester" \
  'Parameter entries.*`name`.*`type`.*`required`.*executor.*`resource`.*`receipt`.*attester `resource`' \
  "$lens_content"

echo ""
echo "Test 7: false-positive boundaries match OKF v0.2"
assert_matches "does not require issue-example extension fields" \
  '(do not|never).*require.*`id`.*`domain`.*`topic`.*`owner`.*`last-reviewed`.*`relations`' \
  "$lens_content"
assert_matches "supports ordinary relative Markdown links" \
  'ordinary relative Markdown links.*supported and valid' \
  "$lens_content"
assert_matches "metadata path fields accept ordinary relative paths" \
  '`resource`.*`sources\[\]\.resource`.*`computation`.*`executor\.resource`.*`attester\.resource`.*ordinary relative paths' \
  "$lens_content"
assert_matches "source resources may be non-path scope descriptors" \
  '`sources\[\]\.resource` may instead be a non-path.*scope descriptor' \
  "$lens_content"
assert_matches "does not flag valid relative metadata paths or scope descriptors" \
  'Do not flag either valid relative metadata paths or valid scope descriptors merely for their form' \
  "$lens_content"
assert_matches "accepts unknown type values and extra fields" \
  'Accept an unknown or open-ended `type` and extra, unknown, or additional frontmatter fields' \
  "$lens_content"
assert_matches "distinguishes v0.1 migration from strict conformance" \
  'v0\.1.*(timestamp|Citations).*(migration|not strict conformance)' \
  "$lens_content"
assert_matches "scopes findings to configured human effort limit" \
  'configured human implementation-hour limit.*(schema|template|directory|concept set|index|workflow)' \
  "$lens_content"

echo ""
echo "Test 8: the lens covers reusable-knowledge outcomes"
assert_matches "covers modular reusable knowledge units" \
  '(modular|split).*(reusable|knowledge units?|concepts?)' \
  "$lens_content"
assert_matches "covers cross-links and progressive disclosure" \
  '(cross-links?|Markdown links?).*`index\.md`.*progressive disclosure|`index\.md`.*progressive disclosure.*(cross-links?|Markdown links?)' \
  "$lens_content"
assert_matches "covers machine-readable enrichment and cataloging" \
  'machine-readable metadata.*(catalog|ingestion|enrichment)' \
  "$lens_content"

echo ""
echo "Test 9: registry and mode resolution expose the lens exactly once"
domain_count="$(jq '[.domains[] | select(.id == "content-quality")] | length' "$DOMAINS_FILE")"
registration_count="$(jq '[.domains[] | select(.id == "content-quality") | .lenses[] | select((if type == "string" then . else .id end) == "okf-compliance")] | length' "$DOMAINS_FILE")"
content_mode="$(jq -r '.domains[] | select(.id == "content-quality") | .mode' "$DOMAINS_FILE")"
assert_eq "content-quality domain exists once" "1" "$domain_count"
assert_eq "OKF lens is registered exactly once" "1" "$registration_count"
assert_eq "content-quality remains content-only" "content" "$content_mode"

content_output="$OKF_TEST_TMP/content.out"
env PATH="$FAKE_BIN:$PATH" bash "$SCRIPT_DIR/repolens.sh" \
  --project "$PROJECT_DIR" \
  --agent codex \
  --mode content \
  --focus okf-compliance \
  --local \
  --yes \
  --dry-run \
  > "$content_output" 2>&1
content_rc=$?
content_run_id="$(grep -oE 'RepoLens run [^ ]+ starting' "$content_output" | head -1 | awk '{print $3}')"
[[ -n "$content_run_id" ]] && CREATED_RUN_IDS+=("$content_run_id")
content_cli_output="$(cat "$content_output")"
assert_eq "production content-mode dry-run succeeds" "0" "$content_rc"
assert_contains "production content-mode resolution includes OKF lens" \
  "content-quality/okf-compliance" \
  "$content_cli_output"

audit_output="$OKF_TEST_TMP/audit.out"
env PATH="$FAKE_BIN:$PATH" bash "$SCRIPT_DIR/repolens.sh" \
  --project "$PROJECT_DIR" \
  --agent codex \
  --mode audit \
  --focus okf-compliance \
  --local \
  --yes \
  --dry-run \
  > "$audit_output" 2>&1
audit_rc=$?
audit_run_id="$(grep -oE 'RepoLens run [^ ]+ starting' "$audit_output" | head -1 | awk '{print $3}')"
[[ -n "$audit_run_id" ]] && CREATED_RUN_IDS+=("$audit_run_id")
audit_cli_output="$(cat "$audit_output")"
if [[ "$audit_rc" -ne 0 ]]; then
  record_pass "production audit-mode resolution rejects OKF lens"
else
  record_fail "production audit-mode resolution rejects OKF lens"
fi
assert_contains "audit-mode rejection identifies the unavailable lens" \
  "Lens 'okf-compliance' not found in domains.json (mode: audit)" \
  "$audit_cli_output"

echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"

if [[ "$FAIL" -ne 0 ]]; then
  exit 1
fi
exit 0
