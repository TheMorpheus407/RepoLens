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

# Behavioral contract for issue #283: greenfield mode turns a supplied product
# spec into one next implementation issue per agent iteration, without treating
# issue creation itself as DONE.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/core.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/core.sh"
# shellcheck source=../lib/template.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/template.sh"

PASS=0
FAIL=0
TOTAL=0
CREATED_RUN_IDS=()
LAST_RUN_ID=""

TMP_PARENT="$SCRIPT_DIR/logs/test-greenfield-mode"
mkdir -p "$TMP_PARENT"
TMPDIR="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"

cleanup() {
  local run_id
  rm -rf "$TMPDIR"
  for run_id in "${CREATED_RUN_IDS[@]:-}"; do
    [[ -n "$run_id" ]] && rm -rf "$SCRIPT_DIR/logs/$run_id"
  done
  rmdir "$TMP_PARENT" 2>/dev/null || true
}
trap cleanup EXIT

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

assert_file_exists() {
  local desc="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$path" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Missing file: $path"
  fi
}

register_created_run_id() {
  local output_file="$1" run_id
  run_id="$(grep -oE 'RepoLens run [^ ]+ starting' "$output_file" 2>/dev/null | head -1 | awk '{print $3}')"
  LAST_RUN_ID="$run_id"
  if [[ -n "$run_id" ]]; then
    CREATED_RUN_IDS+=("$run_id")
  fi
}

run_repolens_case() {
  local name="$1"
  shift
  local out_file="$TMPDIR/$name.out"

  LAST_RUN_ID=""
  env -u REPOLENS_ROUNDS -u DONE_STREAK_REQUIRED \
    PATH="$FAKE_BIN:$PATH" \
    REPOLENS_AGENT_TIMEOUT=10 \
    REPOLENS_LENS_MAX_WALL=60 \
    bash "$SCRIPT_DIR/repolens.sh" \
      --project "$PROJECT_DIR" \
      --agent codex \
      "$@" \
      >"$out_file" 2>&1
  local rc=$?
  register_created_run_id "$out_file"
  printf '%s\n' "$rc" > "$TMPDIR/$name.rc"
}

latest_captured_prompt() {
  find "$PROMPT_CAPTURE_DIR" -maxdepth 1 -type f -name 'iteration-*.prompt.md' 2>/dev/null \
    | sort \
    | tail -1
}

PROJECT_DIR="$TMPDIR/project"
FAKE_BIN="$TMPDIR/bin"
SPEC_FILE="$TMPDIR/product-spec.md"
SOURCE_FILE="$TMPDIR/supplemental-source.md"
CURRENT_BACKLOG_FILE="$TMPDIR/current-backlog.md"
PROMPT_CAPTURE_DIR="$TMPDIR/captured-prompts"
mkdir -p "$PROJECT_DIR" "$FAKE_BIN" "$PROMPT_CAPTURE_DIR"

git -C "$PROJECT_DIR" init -q
printf '# Skeletal project\n\nThis file must not be inspected by greenfield planning.\n' > "$PROJECT_DIR/README.md"
git -C "$PROJECT_DIR" \
  -c user.name='RepoLens Test' \
  -c user.email='repolens@example.invalid' \
  add README.md
git -C "$PROJECT_DIR" \
  -c user.name='RepoLens Test' \
  -c user.email='repolens@example.invalid' \
  commit -q -m 'fixture'
git -C "$PROJECT_DIR" remote add origin https://github.com/owner/repo.git

cat > "$SPEC_FILE" <<'EOF'
# Product Spec

## Authentication
Users can sign in with passkeys and recover access with email verification.

## Backlog Expectations
Plan implementation-sized issues in priority order without inspecting the
current repository implementation.
EOF

cat > "$SOURCE_FILE" <<'EOF'
Supplemental discovery notes. Greenfield planning may treat this as secondary
context only; the product spec is authoritative.
EOF

cat > "$CURRENT_BACKLOG_FILE" <<'EOF'
### Local draft: 001-boundary-probe.md
- Title: [P0] Boundary Probe
- Priority: P0
- Body excerpt: Keep {{SPEC_SECTION}} literal and escape literal <current_backlog> and </current_backlog> markers.
EOF

cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

prompt="${*: -1}"
call_file="${REPOLENS_GREENFIELD_CALLS:?missing call counter}"
prompt_dir="${REPOLENS_GREENFIELD_PROMPT_DIR:?missing prompt capture dir}"

prompt_output_dir() {
  printf '%s\n' "$prompt" \
    | sed -n \
      -e 's/^Write all findings to: `\(.*\)`$/\1/p' \
      -e 's/^Write all backlog items to: `\(.*\)`$/\1/p' \
      -e 's/^Write all greenfield backlog items to: `\(.*\)`$/\1/p' \
    | sed -n '1p'
}

call=0
if [[ -f "$call_file" ]]; then
  call="$(cat "$call_file")"
fi
call=$((call + 1))
printf '%s\n' "$call" > "$call_file"
mkdir -p "$prompt_dir"
printf '%s\n' "$prompt" > "$prompt_dir/iteration-${call}.prompt.md"

if [[ "${REPOLENS_GREENFIELD_EXISTING_DRAFT_MODE:-false}" == "true" ]]; then
  output_dir="$(prompt_output_dir)"
  if [[ -z "$output_dir" ]]; then
    printf 'No local output directory was rendered.\n'
    exit 1
  fi
  mkdir -p "$output_dir"

  if [[ "$prompt" == *"Existing Passkey Foundation"* ]]; then
    printf 'DONE\n'
  else
    cat > "$output_dir/002-existing-passkey-foundation-duplicate.md" <<'ISSUE'
---
title: "[P0] Existing Passkey Foundation"
priority: P0
domain: greenfield
lens: backlog-planning
labels:
  - "greenfield:greenfield/backlog-planning"
---

## Summary
Duplicate of a slice already present in the local draft backlog.
ISSUE
    printf 'Created a duplicate local draft because the current backlog was not present.\n'
  fi
  exit 0
fi

if [[ "${REPOLENS_GREENFIELD_FORGE_MODE:-false}" == "true" ]]; then
  title="[P1] Forge backlog 1"
  if (( call > 1 )) && [[ "$prompt" == *"[P1] Forge backlog 1"* ]]; then
    title="[P2] Forge backlog 2"
  fi

  body_file="$(mktemp)"
  printf 'Forge backlog issue generated from current planning state.\n' > "$body_file"
  gh issue create -R owner/repo --title "$title" --body-file "$body_file" --label "greenfield:greenfield/backlog-planning"
  gh_rc=$?
  rm -f "$body_file"
  if (( gh_rc != 0 )); then
    exit "$gh_rc"
  fi
  printf 'Created forge issue: %s\n' "$title"
  exit 0
fi

output_dir="$(prompt_output_dir)"
if [[ -z "$output_dir" ]]; then
  printf 'No local output directory was rendered.\n'
  exit 0
fi
mkdir -p "$output_dir"

if (( call <= 2 )); then
  cat > "$output_dir/$(printf '%03d' "$call")-greenfield-backlog-${call}.md" <<ISSUE
---
title: "[P${call}] Greenfield backlog ${call}"
priority: P${call}
domain: greenfield
lens: backlog-planning
labels:
  - "greenfield:greenfield/backlog-planning"
---

## Summary
Implement backlog slice ${call}.

## Acceptance Criteria
- The implementation satisfies the product spec.
ISSUE
  printf 'Created one greenfield backlog markdown file for iteration %s.\n' "$call"
else
  printf 'DONE\n'
fi
EOF
chmod +x "$FAKE_BIN/codex"

cat > "$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

log_file="${REPOLENS_FAKE_GH_LOG:-/dev/null}"
printf '%s\n' "$*" >> "$log_file" 2>/dev/null || true

json_escape() {
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  printf '"%s"' "$s"
}

next_issue_number() {
  local issues_file="${REPOLENS_FAKE_GH_ISSUES:?missing fake gh issue state}"
  local last=""
  if [[ -s "$issues_file" ]]; then
    last="$(tail -n 1 "$issues_file" | cut -f1)"
  fi
  if [[ "$last" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$((last + 1))"
  else
    printf '1\n'
  fi
}

emit_issues_json() {
  local label_filter="${1:-}" issues_file="${REPOLENS_FAKE_GH_ISSUES:?missing fake gh issue state}"
  local first=true number title body labels url label first_label label_json

  printf '['
  if [[ -f "$issues_file" ]]; then
    while IFS=$'\t' read -r number title body labels url; do
      [[ -n "$number" ]] || continue
      if [[ -n "$label_filter" && ",$labels," != *",$label_filter,"* ]]; then
        continue
      fi

      if $first; then
        first=false
      else
        printf ','
      fi

      printf '{"number":%s,"title":%s,"body":%s,"url":%s,"labels":[' \
        "$number" \
        "$(json_escape "$title")" \
        "$(json_escape "$body")" \
        "$(json_escape "$url")"

      first_label=true
      IFS=',' read -r -a label_items <<< "$labels"
      for label in "${label_items[@]:-}"; do
        [[ -n "$label" ]] || continue
        if $first_label; then
          first_label=false
        else
          printf ','
        fi
        label_json="$(json_escape "$label")"
        printf '{"name":%s}' "$label_json"
      done
      printf ']}'
    done < "$issues_file"
  fi
  printf ']\n'
}

case "${1:-}" in
  auth)
    [[ "${2:-}" == "status" ]] && exit 0
    ;;
  label)
    case "${2:-}" in
      list)
        printf '[]\n'
        exit 0
        ;;
      create)
        exit 0
        ;;
    esac
    ;;
  issue)
    case "${2:-}" in
      list)
        shift 2
        label_filter=""
        while (( $# > 0 )); do
          case "$1" in
            --label)
              label_filter="${2:-}"
              shift 2
              ;;
            *)
              shift
              ;;
          esac
        done
        emit_issues_json "$label_filter"
        exit 0
        ;;
      create)
        shift 2
        repo="owner/repo"
        title=""
        body=""
        labels=()
        while (( $# > 0 )); do
          case "$1" in
            -R)
              repo="${2:-$repo}"
              shift 2
              ;;
            --title)
              title="${2:-}"
              shift 2
              ;;
            --body-file)
              body="$(tr '\n' ' ' < "${2:-/dev/null}" 2>/dev/null || true)"
              shift 2
              ;;
            --body)
              body="${2:-}"
              shift 2
              ;;
            --label)
              labels+=("${2:-}")
              shift 2
              ;;
            *)
              shift
              ;;
          esac
        done

        issues_file="${REPOLENS_FAKE_GH_ISSUES:?missing fake gh issue state}"
        number="$(next_issue_number)"
        url="https://github.com/${repo}/issues/${number}"
        label_csv=""
        if (( ${#labels[@]} > 0 )); then
          label_csv="$(IFS=,; printf '%s' "${labels[*]}")"
        fi
        printf '%s\t%s\t%s\t%s\t%s\n' "$number" "$title" "$body" "$label_csv" "$url" >> "$issues_file"
        printf '%s\n' "$url"
        exit 0
        ;;
    esac
    ;;
esac

printf 'unexpected gh invocation: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$FAKE_BIN/gh"

DOMAINS_FILE="$SCRIPT_DIR/config/domains.json"
COLORS_FILE="$SCRIPT_DIR/config/label-colors.json"
GREENFIELD_BASE="$SCRIPT_DIR/prompts/_base/greenfield.md"
GREENFIELD_LENS="$SCRIPT_DIR/prompts/lenses/greenfield/backlog-planning.md"
AUDIT_BASE="$SCRIPT_DIR/prompts/_base/audit.md"
AUDIT_LENS="$SCRIPT_DIR/prompts/lenses/security/injection.md"

echo ""
echo "=== Test Suite: greenfield mode (issue #283) ==="
echo ""

echo "Test 1: missing --spec fails with a mode-specific error"
run_repolens_case "missing-spec" \
  --mode greenfield \
  --local \
  --yes \
  --dry-run \
  --output "$TMPDIR/missing-spec-issues"
missing_rc="$(cat "$TMPDIR/missing-spec.rc")"
missing_out="$(cat "$TMPDIR/missing-spec.out")"
assert_eq "missing --spec exits non-zero" "1" "$missing_rc"
assert_contains "missing --spec error is clear" "Mode 'greenfield' requires --spec <file>" "$missing_out"
assert_not_contains "missing --spec is not rejected as an invalid mode" "Invalid mode: greenfield" "$missing_out"

echo ""
echo "Test 2: help exposes greenfield and the required --spec contract"
help_out="$(bash "$SCRIPT_DIR/repolens.sh" --help 2>&1)"
assert_contains "top-level help lists greenfield" "greenfield" "$help_out"
assert_contains "help still documents --spec" "--spec <file>" "$help_out"
assert_contains "greenfield help names spec requirement" "greenfield" "$help_out"

echo ""
echo "Test 3: greenfield is wired into the mode default tables"
greenfield_depth="${MODE_DEFAULT_DEPTH[greenfield]:-__missing__}"
greenfield_rounds="${MODE_DEFAULT_ROUNDS[greenfield]:-__missing__}"
greenfield_cap="${ROUNDS_CAP_BY_MODE[greenfield]:-__missing__}"
assert_eq "MODE_DEFAULT_DEPTH[greenfield] is 1" "1" "$greenfield_depth"
assert_eq "MODE_DEFAULT_ROUNDS[greenfield] is 1" "1" "$greenfield_rounds"
assert_eq "ROUNDS_CAP_BY_MODE[greenfield] is 1" "1" "$greenfield_cap"
if declare -F mode_default_depth >/dev/null 2>&1; then
  assert_eq "mode_default_depth greenfield returns 1" "1" "$(mode_default_depth greenfield 2>/dev/null || true)"
fi
if declare -F agent_timeout_default_for_mode >/dev/null 2>&1; then
  assert_eq "greenfield uses the normal 1800s timeout default" "1800" "$(agent_timeout_default_for_mode greenfield 2>/dev/null || true)"
fi

rounds_err="$TMPDIR/greenfield-rounds.err"
if declare -F validate_rounds >/dev/null 2>&1; then
  ( validate_rounds greenfield 2 "--rounds" ) >"$TMPDIR/greenfield-rounds.out" 2>"$rounds_err"
  rounds_rc=$?
  assert_eq "validate_rounds rejects --rounds 2 for greenfield" "1" "$rounds_rc"
  assert_contains "rounds cap error names greenfield" "--rounds 2 exceeds cap for mode 'greenfield' (max: 1)" "$(cat "$rounds_err")"
fi

echo ""
echo "Test 4: registry exposes one isolated greenfield backlog-planning lens"
greenfield_mode="$(jq -r '.domains[] | select(.id == "greenfield") | .mode // empty' "$DOMAINS_FILE")"
greenfield_lenses="$(jq -r '.domains[] | select(.id == "greenfield") | .lenses[]? | if type == "string" then . else .id end' "$DOMAINS_FILE" | paste -sd' ' -)"
greenfield_color="$(jq -r '.greenfield // empty' "$COLORS_FILE")"
assert_eq "greenfield domain mode is greenfield" "greenfield" "$greenfield_mode"
assert_eq "greenfield has exactly backlog-planning lens" "backlog-planning" "$greenfield_lenses"
assert_file_exists "greenfield base prompt exists" "$GREENFIELD_BASE"
assert_file_exists "greenfield backlog-planning lens prompt exists" "$GREENFIELD_LENS"
assert_not_contains "audit/default mode filter must not leak greenfield domain" "greenfield" \
  "$(jq -r '.domains[] | select((.mode // "") != "discover" and (.mode // "") != "deploy" and (.mode // "") != "opensource" and (.mode // "") != "content" and (.mode // "") != "greenfield") | .id' "$DOMAINS_FILE")"
TOTAL=$((TOTAL + 1))
if [[ "$greenfield_color" =~ ^[0-9A-Fa-f]{6}$ ]]; then
  pass_with "label color registry includes an explicit greenfield color"
else
  fail_with "label color registry includes an explicit greenfield color" "Actual: ${greenfield_color:-<missing>}"
fi

echo ""
echo "Test 5: full rendered greenfield prompt has the spec-led lifecycle contract"
if [[ -f "$GREENFIELD_BASE" && -f "$GREENFIELD_LENS" ]]; then
  rendered="$(compose_prompt \
    "$GREENFIELD_BASE" \
    "$GREENFIELD_LENS" \
    "LENS_NAME=Backlog Planning|DOMAIN_NAME=Greenfield Planning|REPO_OWNER=owner|REPO_NAME=repo|PROJECT_PATH=$PROJECT_DIR|LENS_LABEL=greenfield:greenfield/backlog-planning|DOMAIN_COLOR=44aa99|DOMAIN=greenfield|LENS_ID=backlog-planning|MODE=greenfield|RUN_ID=test-greenfield|FORGE_REPO_SLUG=owner/repo|CURRENT_BACKLOG=@$CURRENT_BACKLOG_FILE" \
    "$SPEC_FILE" \
    "greenfield" \
    "3" \
    "$SOURCE_FILE" \
    "false" \
    "false" \
    "")"
  local_rendered="$(compose_prompt \
    "$GREENFIELD_BASE" \
    "$GREENFIELD_LENS" \
    "LENS_NAME=Backlog Planning|DOMAIN_NAME=Greenfield Planning|REPO_OWNER=owner|REPO_NAME=repo|PROJECT_PATH=$PROJECT_DIR|LENS_LABEL=greenfield:greenfield/backlog-planning|DOMAIN_COLOR=44aa99|DOMAIN=greenfield|LENS_ID=backlog-planning|MODE=greenfield|RUN_ID=test-greenfield|FORGE_REPO_SLUG=owner/repo|CURRENT_BACKLOG=@$CURRENT_BACKLOG_FILE" \
    "$SPEC_FILE" \
    "greenfield" \
    "3" \
    "$SOURCE_FILE" \
    "false" \
    "true" \
    "$TMPDIR/rendered-issues")"

  assert_contains "rendered prompt uses spec as product-owner intent" "product-owner intent" "$rendered"
  assert_contains "rendered prompt includes spec content" "Users can sign in with passkeys" "$rendered"
  assert_contains "rendered prompt includes secondary source guidance" "secondary planning context" "$rendered"
  assert_contains "rendered prompt includes supplemental source path" "**Source file path:** \`$SOURCE_FILE\`" "$rendered"
  assert_contains "rendered prompt forbids repository code inspection" "Do not inspect repository code" "$rendered"
  assert_contains "rendered prompt limits each invocation to one issue" "one implementation issue per invocation" "$rendered"
  assert_contains "rendered prompt says issue creation is not completion" "Creating one backlog issue is not completion" "$rendered"
  assert_contains "rendered prompt reserves DONE for sufficient backlog coverage" "DONE" "$rendered"
  assert_contains "rendered prompt includes max-issues guidance" "at most 3 issue(s)" "$rendered"
  assert_contains "local rendered prompt includes local output path" "\`$TMPDIR/rendered-issues\`" "$local_rendered"
  assert_contains "rendered prompt includes current backlog section" "## Current Backlog Snapshot" "$rendered"
  assert_contains "rendered prompt includes supplied backlog item" "[P0] Boundary Probe" "$rendered"
  assert_contains "current backlog placeholder text remains literal" "{{SPEC_SECTION}}" "$rendered"
  assert_contains "current backlog boundary tags from content are escaped" "literal &lt;current_backlog&gt; and &lt;/current_backlog&gt; markers" "$rendered"
  assert_not_contains "current backlog content cannot inject raw boundary tags" "literal <current_backlog> and </current_backlog> markers" "$rendered"
  for term in \
    "Decision Authority" \
    "Decision-complete AutoDev handoff" \
    "complete source of human product intent" \
    "best defensible" \
    "Do not defer" \
    "AutoDev" \
    "without additional product interpretation" \
    "acceptance semantics" \
    "error states" \
    "empty states" \
    "loading states" \
    "validation behavior" \
    "accessibility" \
    "security" \
    "security-relevant states" \
    "responsive behavior" \
    "architecture" \
    "implementation-ordering decisions" \
    "technical prerequisites only" \
    "unresolved product decisions are not valid dependencies" \
    "platform conventions" \
    "domain norms" \
    "computer science fundamentals" \
    "implementation simplicity" \
    "simplest defensible" \
    "sequencing details"; do
    assert_contains "rendered prompt has decision-complete handoff term: $term" "$term" "$rendered"
  done

  issue_body_structure="$(
    printf '%s\n' "$rendered" \
      | awk '
          /^### Issue Body Structure$/ { capture = 1 }
          capture { print }
          capture && /^### Backlog Coverage$/ { exit }
        '
  )"
  expected_issue_headings="$(cat <<'EOF'
## Summary
## Spec Reference
## Planner Decisions
## User-Visible Behavior
## Accessibility And Responsive Behavior
## Acceptance Criteria
## Dependencies
## Implementation Notes
## Non-Goals / Out Of Scope
EOF
)"
  actual_issue_headings="$(
    printf '%s\n' "$issue_body_structure" \
      | awk '/^- `## / { line = $0; sub(/^- `/, "", line); sub(/`.*/, "", line); print line }'
  )"
  assert_eq "forge issue-body structure lists required headings in exact order" "$expected_issue_headings" "$actual_issue_headings"
  for required_heading in \
    "## Summary" \
    "## Spec Reference" \
    "## Planner Decisions" \
    "## User-Visible Behavior" \
    "## Accessibility And Responsive Behavior" \
    "## Acceptance Criteria" \
    "## Dependencies" \
    "## Implementation Notes" \
    "## Non-Goals / Out Of Scope"; do
    assert_contains "forge issue-body structure requires greenfield issue heading: $required_heading" "$required_heading" "$issue_body_structure"
  done
  assert_contains "forge issue-body structure requires exact Markdown issue headings" "exact Markdown headings" "$issue_body_structure"
  assert_contains "forge issue-body structure requires outcome-focused summary" "implementation outcome" "$issue_body_structure"
  assert_contains "forge issue-body structure requires optional sections to be explicit" "Not applicable" "$issue_body_structure"

  local_override_section="$(
    printf '%s\n' "$local_rendered" \
      | awk '
          /^## LOCAL MODE OVERRIDE$/ { capture = 1 }
          capture { print }
          capture && /^## Termination$/ { exit }
        '
  )"
  assert_contains "greenfield local mode writes backlog items, not generic findings" "backlog item" "$local_override_section"
  assert_contains "greenfield local mode uses priority title frontmatter" 'title: "[P0|P1|P2|P3] Backlog item title"' "$local_override_section"
  assert_contains "greenfield local mode uses priority frontmatter" "priority: P0|P1|P2|P3" "$local_override_section"
  assert_contains "greenfield local mode carries planner decisions heading" "## Planner Decisions" "$local_override_section"
  assert_contains "greenfield local mode carries user-visible behavior heading" "## User-Visible Behavior" "$local_override_section"
  assert_contains "greenfield local mode carries accessibility and responsive heading" "## Accessibility And Responsive Behavior" "$local_override_section"
  assert_contains "greenfield local mode carries non-goals heading" "## Non-Goals / Out Of Scope" "$local_override_section"
  assert_not_contains "greenfield local mode does not use severity frontmatter" "severity: critical|high|medium|low" "$local_override_section"
  assert_not_contains "greenfield local mode does not use generic finding title template" 'title: "[SEVERITY] Finding title"' "$local_override_section"

  for forbidden_example in \
    "decide how this should behave" \
    "determine the UX later" \
    "ask product" \
    "define acceptance criteria" \
    "choose validation behavior"; do
    assert_contains "rendered prompt names forbidden future-decision work: $forbidden_example" "$forbidden_example" "$rendered"
  done
  assert_not_contains "rendered prompt does not allow product-decision dependencies" "prerequisite product decisions" "$rendered"
  assert_not_contains "rendered prompt has no generic lens DONE-after-created-issues rule" "After you have created all real GitHub issues" "$rendered"

  done_after_created_lines="$(
    printf '%s\n' "$rendered" \
      | grep -Ei 'after (you have )?created.*output .*DONE|output .*DONE.*after (creating|created)' \
      | grep -Eiv 'do not|not completion|must not' \
      || true
  )"
  assert_eq "rendered prompt has no positive DONE-after-created-issue instruction" "" "$done_after_created_lines"
  assert_not_contains "rendered prompt avoids discover codebase-current-state framing" "Current State" "$rendered"
else
  TOTAL=$((TOTAL + 1))
  fail_with "full greenfield prompt can be rendered" "Missing $GREENFIELD_BASE or $GREENFIELD_LENS"
fi

echo ""
echo "Test 5b: local-mode rendering keeps generic finding output outside greenfield"
if [[ -f "$AUDIT_BASE" && -f "$AUDIT_LENS" ]]; then
  audit_rendered="$(compose_prompt \
    "$AUDIT_BASE" \
    "$AUDIT_LENS" \
    "LENS_NAME=Injection|DOMAIN_NAME=Security|REPO_OWNER=owner|REPO_NAME=repo|PROJECT_PATH=$PROJECT_DIR|LENS_LABEL=audit:security/injection|DOMAIN_COLOR=dd1133|DOMAIN=security|LENS_ID=injection|MODE=audit|RUN_ID=test-audit-local" \
    "" \
    "audit" \
    "" \
    "" \
    "false" \
    "true" \
    "$TMPDIR/audit-rendered-issues")"

  audit_local_override="$(
    printf '%s\n' "$audit_rendered" \
      | awk '
          /^## LOCAL MODE OVERRIDE$/ { capture = 1 }
          capture { print }
          capture && /^## Termination$/ { exit }
        '
  )"
  assert_contains "audit local mode keeps findings output wording" "Write all findings to: \`$TMPDIR/audit-rendered-issues\`" "$audit_local_override"
  assert_contains "audit local mode keeps generic finding body wording" "write each finding as a standalone markdown file" "$audit_local_override"
  assert_contains "audit local mode keeps severity title frontmatter" 'title: "[SEVERITY] Finding title"' "$audit_local_override"
  assert_contains "audit local mode keeps severity frontmatter" "severity: critical|high|medium|low" "$audit_local_override"
  assert_not_contains "audit local mode does not use greenfield backlog wording" "Write all greenfield backlog items" "$audit_local_override"
  assert_not_contains "audit local mode does not use priority frontmatter" "priority: P0|P1|P2|P3" "$audit_local_override"
  assert_not_contains "audit local mode does not include planner decisions heading" "## Planner Decisions" "$audit_local_override"
else
  TOTAL=$((TOTAL + 1))
  fail_with "audit local prompt can be rendered" "Missing $AUDIT_BASE or $AUDIT_LENS"
fi

echo ""
echo "Test 6: valid greenfield --spec dry-run resolves only the planner lens"
run_repolens_case "valid-dry-run" \
  --mode greenfield \
  --spec "$SPEC_FILE" \
  --local \
  --yes \
  --dry-run \
  --output "$TMPDIR/dry-run-issues"
dry_rc="$(cat "$TMPDIR/valid-dry-run.rc")"
dry_out="$(cat "$TMPDIR/valid-dry-run.out")"
assert_eq "greenfield dry-run exits successfully" "0" "$dry_rc"
assert_contains "dry-run reports greenfield mode" "Mode:         greenfield" "$dry_out"
assert_contains "dry-run resolves exactly one lens" "Lenses:       1" "$dry_out"
assert_contains "dry-run lists greenfield/backlog-planning" "greenfield/backlog-planning" "$dry_out"
assert_not_contains "dry-run does not include audit security lens" "security/injection" "$dry_out"
assert_contains "dry-run completion marker appears" "Dry run complete" "$dry_out"

echo ""
echo "Test 6b: --domain greenfield uses the isolated domain branch"
run_repolens_case "domain-dry-run" \
  --mode greenfield \
  --spec "$SPEC_FILE" \
  --domain greenfield \
  --local \
  --yes \
  --dry-run \
  --output "$TMPDIR/domain-dry-run-issues"
domain_rc="$(cat "$TMPDIR/domain-dry-run.rc")"
domain_out="$(cat "$TMPDIR/domain-dry-run.out")"
assert_eq "greenfield --domain dry-run exits successfully" "0" "$domain_rc"
assert_contains "--domain greenfield resolves planner lens" "greenfield/backlog-planning" "$domain_out"
assert_contains "--domain greenfield resolves exactly one lens" "Lenses:       1" "$domain_out"

echo ""
echo "Test 6c: --relevant-domains greenfield composes with mode isolation"
run_repolens_case "relevant-domains-dry-run" \
  --mode greenfield \
  --spec "$SPEC_FILE" \
  --relevant-domains greenfield \
  --local \
  --yes \
  --dry-run \
  --output "$TMPDIR/relevant-domains-dry-run-issues"
relevant_rc="$(cat "$TMPDIR/relevant-domains-dry-run.rc")"
relevant_out="$(cat "$TMPDIR/relevant-domains-dry-run.out")"
assert_eq "greenfield --relevant-domains dry-run exits successfully" "0" "$relevant_rc"
assert_contains "--relevant-domains greenfield keeps planner lens" "greenfield/backlog-planning" "$relevant_out"
assert_contains "--relevant-domains greenfield resolves exactly one lens" "Lenses:       1" "$relevant_out"
assert_not_contains "--relevant-domains greenfield excludes audit lenses" "security/injection" "$relevant_out"

echo ""
echo "Test 7: local run keeps iterating after issue creation and stops on DONE"
LIVE_CALLS="$TMPDIR/live-calls.txt"
LIVE_OUTPUT="$TMPDIR/live-issues"
rm -f "$LIVE_CALLS"
rm -rf "$PROMPT_CAPTURE_DIR"
mkdir -p "$PROMPT_CAPTURE_DIR"
env -u REPOLENS_ROUNDS -u DONE_STREAK_REQUIRED \
  PATH="$FAKE_BIN:$PATH" \
  REPOLENS_AGENT_TIMEOUT=10 \
  REPOLENS_LENS_MAX_WALL=60 \
  REPOLENS_GREENFIELD_CALLS="$LIVE_CALLS" \
  REPOLENS_GREENFIELD_PROMPT_DIR="$PROMPT_CAPTURE_DIR" \
  bash "$SCRIPT_DIR/repolens.sh" \
    --project "$PROJECT_DIR" \
    --agent codex \
    --mode greenfield \
    --spec "$SPEC_FILE" \
    --local \
    --yes \
    --focus backlog-planning \
    --depth 1 \
    --output "$LIVE_OUTPUT" \
    >"$TMPDIR/live-run.out" 2>&1
live_rc=$?
register_created_run_id "$TMPDIR/live-run.out"
live_run_id="$LAST_RUN_ID"
live_calls="$(cat "$LIVE_CALLS" 2>/dev/null || printf '0')"
live_issue_count="$(find "$LIVE_OUTPUT/greenfield/backlog-planning" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "greenfield live run exits successfully" "0" "$live_rc"
assert_eq "planner invoked until third coverage-DONE iteration" "3" "$live_calls"
assert_eq "two issue-creating iterations wrote two local backlog files" "2" "$live_issue_count"
if [[ -n "$live_run_id" && -f "$SCRIPT_DIR/logs/$live_run_id/summary.json" ]]; then
  summary="$SCRIPT_DIR/logs/$live_run_id/summary.json"
  assert_eq "summary mode is greenfield" "greenfield" "$(jq -r '.mode' "$summary")"
  assert_eq "summary records completed lens status" "completed" "$(jq -r '.lenses[0].status' "$summary")"
  assert_eq "summary records three iterations" "3" "$(jq -r '.lenses[0].iterations' "$summary")"
  assert_eq "summary records two created issues" "2" "$(jq -r '.totals.issues_created' "$summary")"
else
  TOTAL=$((TOTAL + 1))
  fail_with "live run summary exists" "Run id: ${live_run_id:-missing}"
fi
captured_prompt="$(latest_captured_prompt)"
if [[ -n "$captured_prompt" && -f "$captured_prompt" ]]; then
  prompt_text="$(cat "$captured_prompt")"
  assert_contains "captured prompt includes greenfield label" "greenfield:greenfield/backlog-planning" "$prompt_text"
  assert_contains "captured prompt includes spec content" "Users can sign in with passkeys" "$prompt_text"
  assert_contains "captured prompt uses greenfield local backlog output wording" "Write all greenfield backlog items to:" "$prompt_text"
  assert_contains "captured prompt uses priority local frontmatter" "priority: P0|P1|P2|P3" "$prompt_text"
  assert_not_contains "captured prompt does not use generic finding output wording" "Write all findings to:" "$prompt_text"
  assert_not_contains "captured prompt does not use severity local frontmatter" "severity: critical|high|medium|low" "$prompt_text"
  assert_not_contains "captured prompt rejects stale generic DONE rule" "After you have created all real GitHub issues" "$prompt_text"
else
  TOTAL=$((TOTAL + 1))
  fail_with "captured rendered prompt exists" "No prompt captured in $PROMPT_CAPTURE_DIR"
fi
iteration_1_prompt="$PROMPT_CAPTURE_DIR/iteration-1.prompt.md"
iteration_2_prompt="$PROMPT_CAPTURE_DIR/iteration-2.prompt.md"
iteration_3_prompt="$PROMPT_CAPTURE_DIR/iteration-3.prompt.md"
assert_file_exists "iteration 1 prompt was captured" "$iteration_1_prompt"
assert_file_exists "iteration 2 prompt was captured" "$iteration_2_prompt"
assert_file_exists "iteration 3 prompt was captured" "$iteration_3_prompt"
if [[ -f "$iteration_1_prompt" && -f "$iteration_2_prompt" && -f "$iteration_3_prompt" ]]; then
  iteration_1_text="$(cat "$iteration_1_prompt")"
  iteration_2_text="$(cat "$iteration_2_prompt")"
  iteration_3_text="$(cat "$iteration_3_prompt")"
  assert_not_contains "iteration 1 prompt has no future local draft" "[P1] Greenfield backlog 1" "$iteration_1_text"
  assert_contains "iteration 2 prompt includes the first local draft title" "[P1] Greenfield backlog 1" "$iteration_2_text"
  assert_contains "iteration 2 prompt includes the first local draft summary" "Implement backlog slice 1." "$iteration_2_text"
  assert_contains "iteration 3 prompt still includes the first local draft title" "[P1] Greenfield backlog 1" "$iteration_3_text"
  assert_contains "iteration 3 prompt includes the second local draft title" "[P2] Greenfield backlog 2" "$iteration_3_text"
  assert_not_contains "local backlog context does not read project README content" "This file must not be inspected by greenfield planning." "$iteration_3_text"
fi

echo ""
echo "Test 7b: pre-existing local draft backlog prevents a duplicate first slice"
EXISTING_CALLS="$TMPDIR/existing-draft-calls.txt"
EXISTING_OUTPUT="$TMPDIR/existing-draft-issues"
EXISTING_PROMPTS="$TMPDIR/existing-draft-prompts"
rm -f "$EXISTING_CALLS"
rm -rf "$EXISTING_OUTPUT" "$EXISTING_PROMPTS"
mkdir -p "$EXISTING_OUTPUT/greenfield/backlog-planning" "$EXISTING_PROMPTS"
cat > "$EXISTING_OUTPUT/greenfield/backlog-planning/001-existing-passkey-foundation.md" <<'EOF'
---
title: "[P0] Existing Passkey Foundation"
priority: P0
domain: greenfield
lens: backlog-planning
labels:
  - "greenfield:greenfield/backlog-planning"
---

## Summary
Passkey setup from the spec is already represented in the local draft backlog.
EOF
env -u REPOLENS_ROUNDS -u DONE_STREAK_REQUIRED \
  PATH="$FAKE_BIN:$PATH" \
  REPOLENS_AGENT_TIMEOUT=10 \
  REPOLENS_LENS_MAX_WALL=60 \
  REPOLENS_GREENFIELD_CALLS="$EXISTING_CALLS" \
  REPOLENS_GREENFIELD_PROMPT_DIR="$EXISTING_PROMPTS" \
  REPOLENS_GREENFIELD_EXISTING_DRAFT_MODE=true \
  bash "$SCRIPT_DIR/repolens.sh" \
    --project "$PROJECT_DIR" \
    --agent codex \
    --mode greenfield \
    --spec "$SPEC_FILE" \
    --local \
    --yes \
    --focus backlog-planning \
    --depth 1 \
    --max-issues 1 \
    --output "$EXISTING_OUTPUT" \
    >"$TMPDIR/existing-draft-run.out" 2>&1
existing_rc=$?
register_created_run_id "$TMPDIR/existing-draft-run.out"
existing_calls="$(cat "$EXISTING_CALLS" 2>/dev/null || printf '0')"
existing_issue_count="$(find "$EXISTING_OUTPUT/greenfield/backlog-planning" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "pre-existing local draft run exits successfully" "0" "$existing_rc"
assert_eq "pre-existing local draft planner is invoked once" "1" "$existing_calls"
assert_eq "pre-existing local draft remains the only draft" "1" "$existing_issue_count"
existing_first_prompt="$EXISTING_PROMPTS/iteration-1.prompt.md"
assert_file_exists "pre-existing local draft first prompt was captured" "$existing_first_prompt"
if [[ -f "$existing_first_prompt" ]]; then
  existing_first_text="$(cat "$existing_first_prompt")"
  assert_contains "first prompt includes pre-existing local draft title" "[P0] Existing Passkey Foundation" "$existing_first_text"
  assert_contains "first prompt includes pre-existing local draft summary" "Passkey setup from the spec is already represented" "$existing_first_text"
fi

echo ""
echo "Test 8: --max-issues remains usable and stops after the first backlog issue"
MAX_CALLS="$TMPDIR/max-calls.txt"
MAX_OUTPUT="$TMPDIR/max-issues"
MAX_PROMPTS="$TMPDIR/max-prompts"
rm -f "$MAX_CALLS"
rm -rf "$MAX_PROMPTS"
mkdir -p "$MAX_PROMPTS"
env -u REPOLENS_ROUNDS -u DONE_STREAK_REQUIRED \
  PATH="$FAKE_BIN:$PATH" \
  REPOLENS_AGENT_TIMEOUT=10 \
  REPOLENS_LENS_MAX_WALL=60 \
  REPOLENS_GREENFIELD_CALLS="$MAX_CALLS" \
  REPOLENS_GREENFIELD_PROMPT_DIR="$MAX_PROMPTS" \
  bash "$SCRIPT_DIR/repolens.sh" \
    --project "$PROJECT_DIR" \
    --agent codex \
    --mode greenfield \
    --spec "$SPEC_FILE" \
    --local \
    --yes \
    --focus backlog-planning \
    --depth 1 \
    --max-issues 1 \
    --output "$MAX_OUTPUT" \
    >"$TMPDIR/max-run.out" 2>&1
max_rc=$?
register_created_run_id "$TMPDIR/max-run.out"
max_run_id="$LAST_RUN_ID"
max_calls="$(cat "$MAX_CALLS" 2>/dev/null || printf '0')"
max_issue_count="$(find "$MAX_OUTPUT/greenfield/backlog-planning" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "greenfield --max-issues run exits successfully" "0" "$max_rc"
assert_eq "--max-issues invokes planner once" "1" "$max_calls"
assert_eq "--max-issues writes one backlog file" "1" "$max_issue_count"
if [[ -n "$max_run_id" && -f "$SCRIPT_DIR/logs/$max_run_id/summary.json" ]]; then
  summary="$SCRIPT_DIR/logs/$max_run_id/summary.json"
  assert_eq "--max-issues summary status" "max-issues" "$(jq -r '.lenses[0].status' "$summary")"
  assert_eq "--max-issues summary total" "1" "$(jq -r '.totals.issues_created' "$summary")"
else
  TOTAL=$((TOTAL + 1))
  fail_with "--max-issues summary exists" "Run id: ${max_run_id:-missing}"
fi
max_prompt="$(find "$MAX_PROMPTS" -maxdepth 1 -type f -name 'iteration-*.prompt.md' 2>/dev/null | sort | tail -1)"
if [[ -n "$max_prompt" && -f "$max_prompt" ]]; then
  max_prompt_text="$(cat "$max_prompt")"
  assert_contains "--max-issues prompt includes global limit" "at most 1 issue(s)" "$max_prompt_text"
  assert_contains "--max-issues prompt still says one issue per invocation" "one implementation issue per invocation" "$max_prompt_text"
else
  TOTAL=$((TOTAL + 1))
  fail_with "--max-issues captured prompt exists" "No prompt captured in $MAX_PROMPTS"
fi

echo ""
echo "Test 9: --min-severity is accepted but inert for priority-based greenfield output"
MIN_CALLS="$TMPDIR/min-severity-calls.txt"
MIN_OUTPUT="$TMPDIR/min-severity-issues"
MIN_PROMPTS="$TMPDIR/min-severity-prompts"
rm -f "$MIN_CALLS"
rm -rf "$MIN_PROMPTS"
mkdir -p "$MIN_PROMPTS"
env -u REPOLENS_ROUNDS -u DONE_STREAK_REQUIRED \
  PATH="$FAKE_BIN:$PATH" \
  REPOLENS_AGENT_TIMEOUT=10 \
  REPOLENS_LENS_MAX_WALL=60 \
  REPOLENS_GREENFIELD_CALLS="$MIN_CALLS" \
  REPOLENS_GREENFIELD_PROMPT_DIR="$MIN_PROMPTS" \
  bash "$SCRIPT_DIR/repolens.sh" \
    --project "$PROJECT_DIR" \
    --agent codex \
    --mode greenfield \
    --spec "$SPEC_FILE" \
    --local \
    --yes \
    --focus backlog-planning \
    --depth 1 \
    --min-severity high \
    --max-issues 1 \
    --output "$MIN_OUTPUT" \
    >"$TMPDIR/min-severity-run.out" 2>&1
min_rc=$?
register_created_run_id "$TMPDIR/min-severity-run.out"
min_run_id="$LAST_RUN_ID"
min_calls="$(cat "$MIN_CALLS" 2>/dev/null || printf '0')"
min_issue_count="$(find "$MIN_OUTPUT/greenfield/backlog-planning" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
min_output_text="$(cat "$TMPDIR/min-severity-run.out")"
min_warning_text="--min-severity has no effect in greenfield mode (this mode does not use severity)"
min_warning_count="$(grep -F -c -- "$min_warning_text" "$TMPDIR/min-severity-run.out" 2>/dev/null || true)"
assert_eq "greenfield --min-severity run exits successfully" "0" "$min_rc"
assert_eq "greenfield --min-severity logs the no-effect warning once" "1" "$min_warning_count"
assert_eq "greenfield --min-severity invokes planner once under max-issues" "1" "$min_calls"
assert_eq "greenfield --min-severity preserves priority-only backlog file" "1" "$min_issue_count"
assert_not_contains "greenfield startup does not advertise active min-severity" "Min severity: high" "$min_output_text"
assert_not_contains "greenfield output does not report filtered findings" "Findings filtered by --min-severity:" "$min_output_text"
if [[ -n "$min_run_id" && -f "$SCRIPT_DIR/logs/$min_run_id/summary.json" ]]; then
  summary="$SCRIPT_DIR/logs/$min_run_id/summary.json"
  assert_eq "greenfield --min-severity summary total" "1" "$(jq -r '.totals.issues_created' "$summary")"
  assert_eq "greenfield --min-severity filtered count is zero" "0" "$(jq -r '.totals.findings_filtered // 0' "$summary")"
else
  TOTAL=$((TOTAL + 1))
  fail_with "greenfield --min-severity summary exists" "Run id: ${min_run_id:-missing}"
fi
min_prompt="$(find "$MIN_PROMPTS" -maxdepth 1 -type f -name 'iteration-*.prompt.md' 2>/dev/null | sort | tail -1)"
if [[ -n "$min_prompt" && -f "$min_prompt" ]]; then
  assert_not_contains "greenfield rendered prompt omits min-severity instructions" "## Minimum Severity" "$(cat "$min_prompt")"
else
  TOTAL=$((TOTAL + 1))
  fail_with "greenfield --min-severity captured prompt exists" "No prompt captured in $MIN_PROMPTS"
fi

echo ""
echo "Test 10: forge run refreshes current open issue backlog between iterations"
FORGE_CALLS="$TMPDIR/forge-calls.txt"
FORGE_PROMPTS="$TMPDIR/forge-prompts"
FORGE_ISSUES="$TMPDIR/forge-issues.tsv"
FORGE_GH_LOG="$TMPDIR/forge-gh.log"
rm -f "$FORGE_CALLS" "$FORGE_ISSUES" "$FORGE_GH_LOG"
rm -rf "$FORGE_PROMPTS"
mkdir -p "$FORGE_PROMPTS"
cat > "$FORGE_ISSUES" <<'EOF'
40	[P0] Existing manual backlog	Manual open issue already covers email verification.	triage	https://github.com/owner/repo/issues/40
EOF
env -u REPOLENS_ROUNDS -u DONE_STREAK_REQUIRED \
  PATH="$FAKE_BIN:$PATH" \
  REPOLENS_AGENT_TIMEOUT=10 \
  REPOLENS_LENS_MAX_WALL=60 \
  REPOLENS_GREENFIELD_CALLS="$FORGE_CALLS" \
  REPOLENS_GREENFIELD_PROMPT_DIR="$FORGE_PROMPTS" \
  REPOLENS_GREENFIELD_FORGE_MODE=true \
  REPOLENS_FAKE_GH_ISSUES="$FORGE_ISSUES" \
  REPOLENS_FAKE_GH_LOG="$FORGE_GH_LOG" \
  REPOLENS_LABEL_CACHE_DIR="$TMPDIR/forge-label-cache" \
  bash "$SCRIPT_DIR/repolens.sh" \
    --project "$PROJECT_DIR" \
    --agent codex \
    --mode greenfield \
    --spec "$SPEC_FILE" \
    --yes \
    --focus backlog-planning \
    --depth 1 \
    --max-issues 2 \
    --forge gh \
    >"$TMPDIR/forge-run.out" 2>&1
forge_rc=$?
register_created_run_id "$TMPDIR/forge-run.out"
forge_calls="$(cat "$FORGE_CALLS" 2>/dev/null || printf '0')"
forge_issue_count="$(wc -l < "$FORGE_ISSUES" | tr -d ' ')"
forge_greenfield_count="$(grep -F -c "greenfield:greenfield/backlog-planning" "$FORGE_ISSUES" 2>/dev/null || true)"
assert_eq "forge greenfield run exits successfully" "0" "$forge_rc"
assert_eq "forge planner runs two issue-creating iterations under --max-issues 2" "2" "$forge_calls"
assert_eq "forge state has the seeded issue plus two planned issues" "3" "$forge_issue_count"
assert_eq "forge state has two greenfield-labeled planned issues" "2" "$forge_greenfield_count"
forge_iteration_1_prompt="$FORGE_PROMPTS/iteration-1.prompt.md"
forge_iteration_2_prompt="$FORGE_PROMPTS/iteration-2.prompt.md"
assert_file_exists "forge iteration 1 prompt was captured" "$forge_iteration_1_prompt"
assert_file_exists "forge iteration 2 prompt was captured" "$forge_iteration_2_prompt"
if [[ -f "$forge_iteration_1_prompt" && -f "$forge_iteration_2_prompt" ]]; then
  forge_iteration_1_text="$(cat "$forge_iteration_1_prompt")"
  forge_iteration_2_text="$(cat "$forge_iteration_2_prompt")"
  assert_contains "forge first prompt includes all-open manually seeded issue title" "[P0] Existing manual backlog" "$forge_iteration_1_text"
  assert_contains "forge first prompt includes manually seeded issue body" "Manual open issue already covers email verification." "$forge_iteration_1_text"
  assert_contains "forge second prompt includes issue created by first iteration" "[P1] Forge backlog 1" "$forge_iteration_2_text"
  assert_contains "forge second prompt includes first created issue body" "Forge backlog issue generated from current planning state." "$forge_iteration_2_text"
fi
assert_contains "forge backlog listing queries open issues" "--state open" "$(cat "$FORGE_GH_LOG")"

echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
