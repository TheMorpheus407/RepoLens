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

# Tests for issue #159: lib/synthesize.sh — validate_manifest and run_synthesizer.
# shellcheck disable=SC2329

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNTHESIZE_LIB="$SCRIPT_DIR/lib/synthesize.sh"
TEMPLATE_LIB="$SCRIPT_DIR/lib/template.sh"
CORE_LIB="$SCRIPT_DIR/lib/core.sh"
STREAK_LIB="$SCRIPT_DIR/lib/streak.sh"
SUMMARY_LIB="$SCRIPT_DIR/lib/summary.sh"

PASS=0
FAIL=0
TOTAL=0

TMP_PARENT="$SCRIPT_DIR/logs/test-synthesize"
mkdir -p "$TMP_PARENT"
TMPDIR="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"

cleanup() {
  rm -rf "$TMPDIR"
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

assert_success() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -eq 0 ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected exit 0, got $actual"
  fi
}

assert_failure() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -ne 0 ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected non-zero exit"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Did not find '$needle' in: $haystack"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Unexpectedly found '$needle' in: $haystack"
  fi
}

assert_file_exists() {
  local desc="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$path" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected file $path"
  fi
}

assert_file_missing() {
  local desc="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [[ ! -e "$path" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Did not expect file $path"
  fi
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

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

# Helper that emits a single valid manifest entry; callers may append more.
write_clean_manifest() {
  local path="$1"
  cat > "$path" <<'JSON'
[
  {
    "cluster_id": "missing-validation::lib-upload-handler",
    "title": "[high] Validate upload filenames before writing files",
    "severity": "high",
    "domain": "code",
    "lens": "input-validation",
    "root_cause_category": "missing-validation",
    "source_finding_paths": [
      "logs/run-1/rounds/round-1/lens-outputs/code/input-validation.md"
    ],
    "dedup_against_existing": [],
    "proposed_labels": ["bug", "input-validation"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "## Summary\nUploads are not sanitized.\n\n## Expected\nNames sanitized.\n\n## Actual\nRaw write.\n\n## Root Cause\nNo validator.\n\n## Reproduction\nUpload ../etc/passwd.\n\n## Recommended Fix\nAdd validator.\n\n## Impact\nPath traversal."
  }
]
JSON
}

if [[ ! -f "$SYNTHESIZE_LIB" ]]; then
  echo "  FAIL: lib/synthesize.sh missing at $SYNTHESIZE_LIB"
  exit 1
fi

# shellcheck disable=SC1090
source "$TEMPLATE_LIB"
# shellcheck disable=SC1090
source "$STREAK_LIB"
# shellcheck disable=SC1090
source "$SUMMARY_LIB"
# shellcheck disable=SC1090
source "$CORE_LIB"
# shellcheck disable=SC1090
source "$SYNTHESIZE_LIB"

echo "=== validate_manifest schema and shape ==="

# Case: clean manifest passes
clean_path="$TMPDIR/clean.json"
write_clean_manifest "$clean_path"
validate_manifest "$clean_path" 2>"$TMPDIR/clean.err"
status=$?
assert_success "clean manifest returns 0" "$status"

# Case: uppercase/bracketed severity is normalized in-place
uppercase_sev="$TMPDIR/uppercase-severity.json"
cat > "$uppercase_sev" <<'JSON'
[
  {
    "cluster_id": "x::y",
    "title": "[HIGH] Fix upload validation",
    "severity": "HIGH",
    "domain": "code",
    "lens": "input-validation",
    "root_cause_category": "missing-validation",
    "source_finding_paths": ["logs/run-1/rounds/round-1/lens-outputs/code/input-validation.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["bug"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "body"
  },
  {
    "cluster_id": "x::z",
    "title": "[MEDIUM] Fix upload validation elsewhere",
    "severity": "[MEDIUM]",
    "domain": "code",
    "lens": "input-validation",
    "root_cause_category": "missing-validation",
    "source_finding_paths": ["logs/run-1/rounds/round-1/lens-outputs/code/input-validation-2.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["bug"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "body"
  }
]
JSON
validate_manifest "$uppercase_sev" 2>"$TMPDIR/uppercase-severity.err"
status=$?
assert_success "uppercase and bracketed severity returns 0" "$status"
assert_eq "uppercase severity is stored canonical" "high" "$(jq -r '.[0].severity' "$uppercase_sev")"
assert_eq "bracketed severity is stored canonical" "medium" "$(jq -r '.[1].severity' "$uppercase_sev")"

# Case: missing required body field
missing_body="$TMPDIR/missing-body.json"
cat > "$missing_body" <<'JSON'
[
  {
    "cluster_id": "x::y",
    "title": "[low] Tweak readme typo",
    "severity": "low",
    "domain": "docs",
    "lens": "readme-quality",
    "root_cause_category": "docs-drift",
    "source_finding_paths": ["logs/run-1/rounds/round-1/lens-outputs/docs/readme-quality.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["docs"],
    "cross_link_actions": [],
    "granularity": "independent"
  }
]
JSON
validate_manifest "$missing_body" 2>"$TMPDIR/missing-body.err"
status=$?
assert_failure "missing body returns non-zero" "$status"
assert_contains "missing body error mentions body" "body" "$(cat "$TMPDIR/missing-body.err")"

# Case: missing source_finding_paths
missing_sources="$TMPDIR/missing-sources.json"
cat > "$missing_sources" <<'JSON'
[
  {
    "cluster_id": "a::b",
    "title": "[medium] Adjust foo helper",
    "severity": "medium",
    "domain": "code",
    "lens": "duplicates",
    "root_cause_category": "duplication",
    "source_finding_paths": [],
    "dedup_against_existing": [],
    "proposed_labels": ["bug"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "Some body content here"
  }
]
JSON
validate_manifest "$missing_sources" 2>"$TMPDIR/missing-sources.err"
status=$?
assert_failure "empty source_finding_paths returns non-zero" "$status"
assert_contains "error mentions source_finding_paths" "source_finding_paths" "$(cat "$TMPDIR/missing-sources.err")"

# Case: invalid severity
invalid_sev="$TMPDIR/invalid-sev.json"
cat > "$invalid_sev" <<'JSON'
[
  {
    "cluster_id": "x::y",
    "title": "[urgent] Fix something",
    "severity": "urgent",
    "domain": "code",
    "lens": "input-validation",
    "root_cause_category": "missing-validation",
    "source_finding_paths": ["logs/run-1/rounds/round-1/lens-outputs/code/input-validation.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["bug"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "body"
  }
]
JSON
validate_manifest "$invalid_sev" 2>"$TMPDIR/invalid-sev.err"
status=$?
assert_failure "invalid severity returns non-zero" "$status"
assert_contains "error mentions invalid severity" "severity" "$(cat "$TMPDIR/invalid-sev.err")"

# Case: invalid granularity
invalid_gran="$TMPDIR/invalid-gran.json"
cat > "$invalid_gran" <<'JSON'
[
  {
    "cluster_id": "x::y",
    "title": "[low] Fix something",
    "severity": "low",
    "domain": "code",
    "lens": "input-validation",
    "root_cause_category": "missing-validation",
    "source_finding_paths": ["logs/run-1/rounds/round-1/lens-outputs/code/input-validation.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["bug"],
    "cross_link_actions": [],
    "granularity": "umbrella",
    "body": "body"
  }
]
JSON
validate_manifest "$invalid_gran" 2>/dev/null
status=$?
assert_failure "invalid granularity returns non-zero" "$status"

# Case: top-level object instead of array
top_obj="$TMPDIR/top-obj.json"
echo '{"items": []}' > "$top_obj"
validate_manifest "$top_obj" 2>"$TMPDIR/top-obj.err"
status=$?
assert_failure "top-level object returns non-zero" "$status"
assert_contains "error mentions array" "array" "$(cat "$TMPDIR/top-obj.err")"

# Case: invalid JSON
bad_json="$TMPDIR/bad.json"
echo 'not json {' > "$bad_json"
validate_manifest "$bad_json" 2>"$TMPDIR/bad.err"
status=$?
assert_failure "invalid JSON returns non-zero" "$status"
assert_contains "error mentions JSON" "JSON" "$(cat "$TMPDIR/bad.err")"

# Case: empty array is allowed
empty="$TMPDIR/empty.json"
echo '[]' > "$empty"
validate_manifest "$empty" 2>/dev/null
status=$?
assert_success "empty array returns 0" "$status"

# Case: missing manifest path
validate_manifest "$TMPDIR/does-not-exist.json" 2>/dev/null
status=$?
assert_failure "missing manifest returns non-zero" "$status"

# Case: extra fields are allowed (forward compat)
extra="$TMPDIR/extra.json"
cat > "$extra" <<'JSON'
[
  {
    "cluster_id": "x::y",
    "title": "[low] Fix typo in README",
    "severity": "low",
    "domain": "docs",
    "lens": "readme-quality",
    "root_cause_category": "docs-drift",
    "source_finding_paths": ["logs/run-1/rounds/round-1/lens-outputs/docs/readme-quality.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["docs"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "body content",
    "future_field": "ok",
    "another_extra": { "nested": true }
  }
]
JSON
validate_manifest "$extra" 2>/dev/null
status=$?
assert_success "extra fields are accepted" "$status"

echo ""
echo "=== validate_manifest title similarity ==="

# Case: two near-duplicate titles flagged
dup="$TMPDIR/dup.json"
cat > "$dup" <<'JSON'
[
  {
    "cluster_id": "a::1",
    "title": "[high] Validate upload filenames before writing files to disk",
    "severity": "high",
    "domain": "code",
    "lens": "input-validation",
    "root_cause_category": "missing-validation",
    "source_finding_paths": ["logs/run-1/rounds/round-1/lens-outputs/code/input-validation.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["bug"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "body"
  },
  {
    "cluster_id": "a::2",
    "title": "[high] Validate upload filenames before writing files to disk",
    "severity": "high",
    "domain": "code",
    "lens": "input-validation",
    "root_cause_category": "missing-validation",
    "source_finding_paths": ["logs/run-1/rounds/round-2/lens-outputs/code/input-validation.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["bug"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "body two"
  }
]
JSON
validate_manifest "$dup" 2>"$TMPDIR/dup.err"
status=$?
assert_failure "near-duplicate titles return non-zero" "$status"
dup_err="$(cat "$TMPDIR/dup.err")"
assert_contains "duplicate error mentions first title" "Validate upload filenames before writing files to disk" "$dup_err"
# both titles printed (we look for the duplicate-line marker)
TOTAL=$((TOTAL + 1))
dup_count=$(grep -c "Validate upload filenames before writing files to disk" "$TMPDIR/dup.err" || true)
if [[ "$dup_count" -ge 2 ]]; then
  pass_with "stderr lists both offending titles"
else
  fail_with "stderr lists both offending titles" "Expected >= 2 occurrences, got $dup_count"
fi

# Case: short duplicate titles do not blow up arithmetic
short_dup="$TMPDIR/short-dup.json"
cat > "$short_dup" <<'JSON'
[
  {
    "cluster_id": "a::1",
    "title": "[low] Fix typo",
    "severity": "low",
    "domain": "docs",
    "lens": "readme-quality",
    "root_cause_category": "docs-drift",
    "source_finding_paths": ["logs/run-1/rounds/round-1/lens-outputs/docs/readme-quality.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["docs"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "body"
  },
  {
    "cluster_id": "a::2",
    "title": "[low] Fix typo",
    "severity": "low",
    "domain": "docs",
    "lens": "readme-quality",
    "root_cause_category": "docs-drift",
    "source_finding_paths": ["logs/run-1/rounds/round-2/lens-outputs/docs/readme-quality.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["docs"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "body two"
  }
]
JSON
validate_manifest "$short_dup" 2>"$TMPDIR/short-dup.err"
status=$?
assert_failure "short duplicate titles flagged without arithmetic errors" "$status"

# Case: distinct titles do not trip similarity
distinct="$TMPDIR/distinct.json"
cat > "$distinct" <<'JSON'
[
  {
    "cluster_id": "a::1",
    "title": "[high] Validate upload filenames before writing files",
    "severity": "high",
    "domain": "code",
    "lens": "input-validation",
    "root_cause_category": "missing-validation",
    "source_finding_paths": ["logs/run-1/rounds/round-1/lens-outputs/code/input-validation.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["bug"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "body"
  },
  {
    "cluster_id": "b::1",
    "title": "[medium] Reduce memory pressure in worker pool",
    "severity": "medium",
    "domain": "code",
    "lens": "memory",
    "root_cause_category": "resource-pressure",
    "source_finding_paths": ["logs/run-1/rounds/round-2/lens-outputs/code/memory.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["performance"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "body two"
  }
]
JSON
validate_manifest "$distinct" 2>/dev/null
status=$?
assert_success "distinct titles pass" "$status"

echo ""
echo "=== run_synthesizer dispatcher (stubbed) ==="

# Stub run_agent and compose_prompt to keep the dispatcher hermetic.
# We stash the originals under different names so we can restore them.
PROJECT_PATH="$TMPDIR/project"
mkdir -p "$PROJECT_PATH"
export AGENT="claude"
export PROJECT_PATH

setup_run() {
  local run="$1"
  RUN_LOG="$TMPDIR/$run-logs/$run"
  mkdir -p "$RUN_LOG/rounds/round-1/lens-outputs/code"
  mkdir -p "$RUN_LOG/rounds/round-2/lens-outputs/docs"
  echo "finding 1" > "$RUN_LOG/rounds/round-1/lens-outputs/code/input-validation.md"
  echo "finding 2" > "$RUN_LOG/rounds/round-2/lens-outputs/docs/readme-quality.md"
  export LOG_BASE="$RUN_LOG"
}

setup_empty_run() {
  local run="$1"
  RUN_LOG="$TMPDIR/$run-logs/$run"
  mkdir -p "$RUN_LOG/rounds/round-1/lens-outputs/code"
  export LOG_BASE="$RUN_LOG"
}

setup_missing_rounds_run() {
  local run="$1"
  RUN_LOG="$TMPDIR/$run-logs/$run"
  mkdir -p "$RUN_LOG"
  export LOG_BASE="$RUN_LOG"
}

COMPOSE_LOG="$TMPDIR/compose.log"
AGENT_LOG="$TMPDIR/agent.log"
stub_compose_prompt() {
  compose_prompt() {
    echo "$3" >> "$COMPOSE_LOG"
    printf 'STUBBED PROMPT'
  }
}

# Success path: agent emits a clean manifest array on stdout
: > "$COMPOSE_LOG"
: > "$AGENT_LOG"
stub_compose_prompt
run_agent() {
  echo "call" >> "$AGENT_LOG"
  cat <<'OUT'
Here is the manifest you asked for:
[
  {
    "cluster_id": "x::y",
    "title": "[high] Validate upload filenames before writing files",
    "severity": "high",
    "domain": "code",
    "lens": "input-validation",
    "root_cause_category": "missing-validation",
    "source_finding_paths": ["logs/run-success/rounds/round-1/lens-outputs/code/input-validation.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["bug"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "Summary body"
  }
]
DONE
OUT
}

setup_run "run-success"
run_synthesizer "run-success" 2>"$TMPDIR/run-success.err"
status=$?
assert_success "run_synthesizer succeeds with valid agent output" "$status"
assert_file_exists "manifest.json promoted on success" "$RUN_LOG/final/manifest.json"
agent_calls=$(wc -l < "$AGENT_LOG" | tr -d ' ')
compose_calls=$(wc -l < "$COMPOSE_LOG" | tr -d ' ')
assert_eq "run_agent called exactly once" "1" "$agent_calls"
assert_eq "compose_prompt called exactly once" "1" "$compose_calls"
assert_contains "TOTAL_FINDINGS counts nested lens outputs" "TOTAL_FINDINGS=2" "$(cat "$COMPOSE_LOG")"

# Zero-finding runs are deterministic and do not invoke the agent.
: > "$COMPOSE_LOG"
: > "$AGENT_LOG"
stub_compose_prompt
run_agent() {
  echo "call" >> "$AGENT_LOG"
  echo "agent should not run for empty synthesis" >&2
  return 99
}
setup_empty_run "run-empty"
mkdir -p "$RUN_LOG/final"
echo '[{"stale":true}]' > "$RUN_LOG/final/manifest.json"
echo '[]' > "$RUN_LOG/final/cross-link-actions.preserved.json"
run_synthesizer "run-empty" 2>"$TMPDIR/run-empty.err"
status=$?
assert_success "run_synthesizer short-circuits empty findings" "$status"
assert_file_exists "empty manifest.json promoted" "$RUN_LOG/final/manifest.json"
assert_eq "empty manifest is canonical array" "[]" "$(jq -c '.' "$RUN_LOG/final/manifest.json")"
assert_file_missing "empty run removes stale preserved cross-link actions" "$RUN_LOG/final/cross-link-actions.preserved.json"
agent_calls=$(wc -l < "$AGENT_LOG" | tr -d ' ')
compose_calls=$(wc -l < "$COMPOSE_LOG" | tr -d ' ')
assert_eq "run_agent not called for empty findings" "0" "$agent_calls"
assert_eq "compose_prompt not called for empty findings" "0" "$compose_calls"
assert_file_missing "empty run does not create synthesizer transcript" "$RUN_LOG/final/synthesizer-output.txt"

: > "$COMPOSE_LOG"
: > "$AGENT_LOG"
setup_missing_rounds_run "run-no-rounds"
run_synthesizer "run-no-rounds" 2>"$TMPDIR/run-no-rounds.err"
status=$?
assert_success "run_synthesizer short-circuits missing rounds directory" "$status"
assert_eq "missing rounds manifest is canonical array" "[]" "$(jq -c '.' "$RUN_LOG/final/manifest.json")"
agent_calls=$(wc -l < "$AGENT_LOG" | tr -d ' ')
compose_calls=$(wc -l < "$COMPOSE_LOG" | tr -d ' ')
assert_eq "run_agent not called when rounds directory is missing" "0" "$agent_calls"
assert_eq "compose_prompt not called when rounds directory is missing" "0" "$compose_calls"

# Pre-validation min-severity filtering removes below-threshold entries before
# validate_manifest and turns invalid severities into warning-and-drop skips.
: > "$COMPOSE_LOG"
: > "$AGENT_LOG"
stub_compose_prompt
run_agent() {
  echo "call" >> "$AGENT_LOG"
  cat <<'OUT'
[
  {
    "cluster_id": "low::filtered",
    "title": "[low] Tidy local docs wording",
    "severity": "low",
    "domain": "docs",
    "lens": "readme-quality",
    "root_cause_category": "docs-drift",
    "source_finding_paths": ["logs/run-min-filter/rounds/round-1/lens-outputs/docs/readme-quality.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["docs"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "body"
  },
  {
    "cluster_id": "high::kept",
    "title": "[high] Validate upload filenames before writing files",
    "severity": "high",
    "domain": "code",
    "lens": "input-validation",
    "root_cause_category": "missing-validation",
    "source_finding_paths": ["logs/run-min-filter/rounds/round-1/lens-outputs/code/input-validation.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["bug"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "body"
  }
]
DONE
OUT
}

setup_run "run-min-filter"
export REPOLENS_MIN_SEVERITY=high
run_synthesizer "run-min-filter" 2>"$TMPDIR/run-min-filter.err"
status=$?
unset REPOLENS_MIN_SEVERITY
assert_success "run_synthesizer succeeds after min-severity filtering" "$status"
assert_eq "pre-validation min-severity filter keeps only high entry" "high::kept" "$(jq -r '.[].cluster_id' "$RUN_LOG/final/manifest.json")"

: > "$COMPOSE_LOG"
: > "$AGENT_LOG"
stub_compose_prompt
run_agent() {
  echo "call" >> "$AGENT_LOG"
  cat <<'OUT'
[
  {
    "cluster_id": "urgent::invalid",
    "title": "[urgent] Invalid severity must not be filtered away",
    "severity": "urgent",
    "domain": "code",
    "lens": "input-validation",
    "root_cause_category": "missing-validation",
    "source_finding_paths": ["logs/run-min-invalid/rounds/round-1/lens-outputs/code/input-validation.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["bug"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "body"
  }
]
DONE
OUT
}

setup_run "run-min-invalid"
export REPOLENS_MIN_SEVERITY=high
run_synthesizer "run-min-invalid" 2>"$TMPDIR/run-min-invalid.err"
status=$?
unset REPOLENS_MIN_SEVERITY
assert_success "invalid severity is skipped during min-severity filtering" "$status"
assert_eq "invalid min-severity run promotes empty manifest" "[]" "$(jq -c '.' "$RUN_LOG/final/manifest.json")"
assert_contains "invalid min-severity run warns about skipped finding" \
  "has invalid severity: \"urgent\"" \
  "$(cat "$TMPDIR/run-min-invalid.err")"

# Failure path: agent emits invalid manifest (duplicate titles)
: > "$COMPOSE_LOG"
: > "$AGENT_LOG"
stub_compose_prompt
run_agent() {
  echo "call" >> "$AGENT_LOG"
  cat <<'OUT'
[
  {
    "cluster_id": "x::1",
    "title": "[high] Validate upload filenames before writing files to disk",
    "severity": "high",
    "domain": "code",
    "lens": "input-validation",
    "root_cause_category": "missing-validation",
    "source_finding_paths": ["a.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["bug"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "body one"
  },
  {
    "cluster_id": "x::2",
    "title": "[high] Validate upload filenames before writing files to disk",
    "severity": "high",
    "domain": "code",
    "lens": "input-validation",
    "root_cause_category": "missing-validation",
    "source_finding_paths": ["b.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["bug"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "body two"
  }
]
DONE
OUT
}

setup_run "run-fail"
run_synthesizer "run-fail" 2>"$TMPDIR/run-fail.err"
status=$?
assert_failure "run_synthesizer fails on invalid manifest" "$status"
assert_eq "invalid manifest returns validation rc" "5" "$status"
assert_file_missing "manifest.json absent on failure" "$RUN_LOG/final/manifest.json"
assert_file_missing "candidate manifest cleaned up on failure" "$RUN_LOG/final/manifest.json.tmp.$$"

# Failure path: agent emits no JSON array
: > "$COMPOSE_LOG"
: > "$AGENT_LOG"
stub_compose_prompt
run_agent() {
  echo "call" >> "$AGENT_LOG"
  echo "I have nothing to report"
  echo "DONE"
}
setup_run "run-no-json"
run_synthesizer "run-no-json" 2>"$TMPDIR/run-no-json.err"
status=$?
assert_failure "run_synthesizer fails when no JSON array is emitted" "$status"
assert_eq "missing JSON array returns extraction rc" "4" "$status"
assert_file_exists "no-JSON synthesizer writes transcript" "$RUN_LOG/final/synthesizer-output.txt"
assert_contains "no-JSON transcript preserves agent output" "I have nothing to report" "$(cat "$RUN_LOG/final/synthesizer-output.txt" 2>/dev/null)"
assert_file_missing "no manifest.json when JSON array missing" "$RUN_LOG/final/manifest.json"

# Stale manifest is removed on failure
: > "$COMPOSE_LOG"
: > "$AGENT_LOG"
stub_compose_prompt
run_agent() {
  echo "call" >> "$AGENT_LOG"
  echo "no array here"
}
setup_run "run-stale"
mkdir -p "$RUN_LOG/final"
echo '[]' > "$RUN_LOG/final/manifest.json"
run_synthesizer "run-stale" 2>/dev/null
status=$?
assert_failure "run_synthesizer fails when no JSON array is emitted (stale)" "$status"
# The dispatcher must clear any stale manifest.json upfront so that NO
# consumable manifest survives any failure path (extraction, agent, or
# validation). Verify both that the stale manifest is gone and that no
# candidate temp files were left behind.
assert_file_missing "stale manifest.json removed on failure" "$RUN_LOG/final/manifest.json"
TOTAL=$((TOTAL + 1))
candidate_count=$(find "$RUN_LOG/final" -maxdepth 1 -name 'manifest.json.tmp.*' | wc -l | tr -d ' ')
if [[ "$candidate_count" -eq 0 ]]; then
  pass_with "no candidate temp files left behind"
else
  fail_with "no candidate temp files left behind" "Found $candidate_count"
fi

# Failure path: direct non-rate-limit agent invocation failures are distinct
# from generic synthesis failures and remain visible to the orchestrator.
: > "$COMPOSE_LOG"
: > "$AGENT_LOG"
stub_compose_prompt
run_agent() {
  echo "call" >> "$AGENT_LOG"
  echo "agent subprocess exited before producing a manifest"
  return 42
}
setup_run "run-agent-fail"
mkdir -p "$RUN_LOG/final"
echo '[]' > "$RUN_LOG/final/manifest.json"
echo '[]' > "$RUN_LOG/final/cross-link-actions.preserved.json"
run_synthesizer "run-agent-fail" 2>"$TMPDIR/run-agent-fail.err"
status=$?
assert_failure "run_synthesizer fails when agent invocation fails" "$status"
assert_eq "agent invocation failure returns distinct rc" "6" "$status"
assert_file_exists "agent invocation failure writes transcript" "$RUN_LOG/final/synthesizer-output.txt"
assert_contains "agent invocation transcript preserves agent output" "agent subprocess exited" "$(cat "$RUN_LOG/final/synthesizer-output.txt" 2>/dev/null)"
assert_file_missing "agent invocation failure removes stale manifest" "$RUN_LOG/final/manifest.json"
assert_file_missing "agent invocation failure removes stale preserved cross-link actions" "$RUN_LOG/final/cross-link-actions.preserved.json"

orchestrator_synth_case="$(awk '/case "\$synth_rc" in/{flag=1} flag{print} flag && /esac/{exit}' "$SCRIPT_DIR/repolens.sh")"
orchestrator_warning="$(
  # shellcheck disable=SC2034
  synth_rc=6
  log_warn() {
    printf '%s\n' "$*"
  }
  eval "$orchestrator_synth_case"
)"
assert_contains "orchestrator maps agent invocation rc to specific warning" \
  "Synthesizer: agent invocation failed; see final/synthesizer-output.txt" \
  "$orchestrator_warning"
assert_not_contains "orchestrator agent invocation rc avoids generic manifest warning" \
  "Synthesizer: failed to produce a valid manifest" \
  "$orchestrator_warning"

# Failure path: direct agent rate-limit failures are distinguished from
# generic manifest failures and leave operator-visible abort state.
: > "$COMPOSE_LOG"
: > "$AGENT_LOG"
stub_compose_prompt
run_agent() {
  echo "call" >> "$AGENT_LOG"
  printf "ERROR: You've hit your usage limit. Try again at May 14th, 2026 11:00 PM.\n"
  return 42
}
setup_run "run-rate-limit"
SUMMARY_FILE="$RUN_LOG/summary.json"
mkdir -p "$RUN_LOG/final"
printf '{"stopped_reason":null,"lenses":[]}\n' > "$SUMMARY_FILE"
echo '[]' > "$RUN_LOG/final/manifest.json"
echo '[]' > "$RUN_LOG/final/cross-link-actions.preserved.json"
export SUMMARY_FILE
run_synthesizer "run-rate-limit" 2>"$TMPDIR/run-rate-limit.err"
status=$?
assert_eq "rate-limited synthesizer returns distinct rc" "3" "$status"
assert_file_exists "rate-limited synthesizer writes transcript" "$RUN_LOG/final/synthesizer-output.txt"
assert_contains "rate-limited synthesizer transcript preserves agent output" "usage limit" "$(cat "$RUN_LOG/final/synthesizer-output.txt" 2>/dev/null)"
assert_file_exists "rate-limited synthesizer creates abort sentinel" "$RUN_LOG/.rate-limit-abort"
assert_eq "rate-limited synthesizer records phase stop reason" "rate-limited-synthesizer" "$(jq -r '.stopped_reason' "$SUMMARY_FILE")"
assert_file_missing "rate-limited synthesizer removes stale manifest" "$RUN_LOG/final/manifest.json"
assert_file_missing "rate-limited synthesizer removes stale preserved cross-link actions" "$RUN_LOG/final/cross-link-actions.preserved.json"
unset SUMMARY_FILE

# Failure path: structured Claude rate-limit envelopes with rc=0 must take the
# same phase abort path instead of promoting the valid-looking manifest result.
: > "$COMPOSE_LOG"
: > "$AGENT_LOG"
stub_compose_prompt
run_agent() {
  echo "call" >> "$AGENT_LOG"
  local envelope_path="${6:-${REPOLENS_AGENT_ENVELOPE_FILE:-}}"
  if [[ -n "$envelope_path" ]]; then
    mkdir -p "$(dirname "$envelope_path")"
    cat > "$envelope_path" <<'JSON'
{"result":"[{\"cluster_id\":\"structured-rate-limit::1\",\"title\":\"[high] This manifest must not be promoted\",\"severity\":\"high\",\"domain\":\"code\",\"lens\":\"input-validation\",\"root_cause_category\":\"missing-validation\",\"source_finding_paths\":[\"logs/run-1/rounds/round-1/lens-outputs/code/input-validation.md\"],\"dedup_against_existing\":[],\"proposed_labels\":[\"bug\"],\"cross_link_actions\":[],\"granularity\":\"independent\",\"body\":\"body\"}]\nDONE\n","is_error":true,"api_error_status":429,"error":{"type":"rate_limit_error","message":"rate limited"}}
JSON
  fi
  cat <<'JSON'
[
  {
    "cluster_id": "structured-rate-limit::1",
    "title": "[high] This manifest must not be promoted",
    "severity": "high",
    "domain": "code",
    "lens": "input-validation",
    "root_cause_category": "missing-validation",
    "source_finding_paths": ["logs/run-1/rounds/round-1/lens-outputs/code/input-validation.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["bug"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "body"
  }
]
DONE
JSON
  return 0
}
setup_run "run-structured-rate-limit"
SUMMARY_FILE="$RUN_LOG/summary.json"
mkdir -p "$RUN_LOG/final"
printf '{"stopped_reason":null,"lenses":[]}\n' > "$SUMMARY_FILE"
echo '[]' > "$RUN_LOG/final/manifest.json"
echo '[]' > "$RUN_LOG/final/cross-link-actions.preserved.json"
export SUMMARY_FILE
run_synthesizer "run-structured-rate-limit" 2>"$TMPDIR/run-structured-rate-limit.err"
status=$?
assert_eq "structured rc=0 rate-limited synthesizer returns distinct rc" "3" "$status"
assert_file_exists "structured rate-limited synthesizer writes transcript" "$RUN_LOG/final/synthesizer-output.txt"
assert_file_exists "structured rate-limited synthesizer creates abort sentinel" "$RUN_LOG/.rate-limit-abort"
assert_eq "structured rate-limited synthesizer records phase stop reason" "rate-limited-synthesizer" "$(jq -r '.stopped_reason' "$SUMMARY_FILE")"
assert_file_missing "structured rate-limited synthesizer removes stale manifest" "$RUN_LOG/final/manifest.json"
assert_file_missing "structured rate-limited synthesizer removes stale preserved cross-link actions" "$RUN_LOG/final/cross-link-actions.preserved.json"
unset SUMMARY_FILE

finish
