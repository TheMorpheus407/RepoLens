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

# Deterministic RepoLens test-agent harness.
#
# Environment contract:
# - REPOLENS_MOCK_AGENT_LOG is optional; when set, each invocation appends one
#   role line to that file.
# - REPOLENS_MOCK_AGENT_FINDINGS defaults to 1 and may be set to 2.
# - The prompt is read from REPOLENS_MOCK_PROMPT_FILE, stdin, or the last CLI
#   argument. This matches `codex exec --yolo "$prompt"` in lib/core.sh while
#   remaining reusable for direct test invocations.
# - Lens prompts in local mode must contain the rendered "Write all findings
#   to:" output directory. The mock writes deterministic markdown findings
#   there and captures the rendered prompt under the enclosing round directory.

set -uo pipefail

read_prompt() {
  local prompt_file="${REPOLENS_MOCK_PROMPT_FILE:-}" last_arg=""

  if [[ -n "$prompt_file" && -f "$prompt_file" ]]; then
    cat "$prompt_file"
    return
  fi

  if [[ ! -t 0 ]]; then
    local stdin_prompt
    stdin_prompt="$(cat || true)"
    if [[ -n "$stdin_prompt" ]]; then
      printf '%s\n' "$stdin_prompt"
      return
    fi
  fi

  if (( $# > 0 )); then
    last_arg="${!#}"
  fi
  printf '%s\n' "$last_arg"
}

trim() {
  local value="$*"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

slugify() {
  printf '%s\n' "$*" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E -e 's/[^a-z0-9]+/-/g' -e 's/-+/-/g' -e 's/^-+//' -e 's/-+$//'
}

log_role() {
  local role="$1"
  if [[ -n "${REPOLENS_MOCK_AGENT_LOG:-}" ]]; then
    printf '%s\n' "$role" >> "$REPOLENS_MOCK_AGENT_LOG"
  fi
}

extract_first_match() {
  local regex="$1" prompt="$2"
  if [[ "$prompt" =~ $regex ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

emit_meta_dispatch() {
  log_role "meta"
  cat <<'OUT'
## Round dispatch plan

- LENS: injection - `README.md:1`; keep the integration test on one stable lens.
HYPOTHESES_TO_VERIFY:
- Re-check the deterministic mock finding with prior-round context.
OUT
}

emit_manifest() {
  local prompt="$1" run_id
  log_role "synthesizer"
  run_id="$(extract_first_match 'run `([^`]+)`' "$prompt")"
  [[ -n "$run_id" ]] || run_id="mock-run"
  jq -n --arg run_id "$run_id" '
    [
      {
        cluster_id: "mock-round-handoff",
        title: "[low] Keep deterministic mock finding wired",
        severity: "low",
        domain: "security",
        lens: "injection",
        root_cause_category: "test-handoff",
        source_finding_paths: [
          ("logs/" + $run_id + "/rounds/round-1/lens-outputs/security/injection/001-mock-finding-injection-r1.md")
        ],
        dedup_against_existing: [],
        proposed_labels: ["bug", "audit:security/injection"],
        cross_link_actions: [],
        granularity: "independent",
        verification_status: "unknown",
        body: "## Summary\nDeterministic mock finding for the multi-round handoff integration test.\n\n## Expected\nPrior round digests are handed to later round prompts.\n\n## Actual\nThe mock manifest records that the handoff path ran.\n\n## Root Cause\nTest harness output.\n\n## Reproduction\nRun tests/test_rounds_multi_round_handoff.sh.\n\n## Recommended Fix\nKeep the multi-round handoff wired.\n\n## Impact\nRegression coverage for --rounds 3."
      }
    ]
  '
}

emit_lens_findings() {
  local prompt="$1" output_dir round_dir capture_dir domain lens round findings_count i title slug file

  log_role "lens"
  output_dir="$(printf '%s\n' "$prompt" | sed -n 's/^Write all findings to: `\(.*\)`$/\1/p' | sed -n '1p')"
  if [[ -z "$output_dir" ]]; then
    printf 'DONE\nNo local output directory was rendered.\nDONE\n'
    return 0
  fi

  mkdir -p "$output_dir"
  lens="$(basename "$output_dir")"
  domain="$(basename "$(dirname "$output_dir")")"
  round_dir="${output_dir%/lens-outputs/*}"
  round="$(extract_first_match 'round \*\*([0-9]+) of [0-9]+\*\*' "$prompt")"
  [[ -n "$round" ]] || round="1"

  capture_dir="$round_dir/captured-prompts"
  mkdir -p "$capture_dir"
  printf '%s\n' "$prompt" > "$capture_dir/${domain}__${lens}.prompt.md"

  findings_count="${REPOLENS_MOCK_AGENT_FINDINGS:-1}"
  if [[ "$findings_count" != "2" ]]; then
    findings_count=1
  fi

  for (( i = 1; i <= findings_count; i++ )); do
    title="mock-finding-${lens}-r${round}-${i}"
    slug="$(slugify "$title")"
    file="$output_dir/$(printf '%03d' "$i")-${slug}.md"
    cat > "$file" <<EOF
---
title: "[LOW] ${title}"
severity: low
domain: ${domain}
lens: ${lens}
labels:
  - "audit:${domain}/${lens}"
root_cause_category: test-handoff
---

## Summary
${title}

## Impact
Deterministic integration-test evidence for round ${round}.

## Evidence
README.md:1 is the stable fixture anchor.

## Recommended Fix
Keep the multi-round handoff contract wired.

## References
Issue #180.
EOF
  done

  printf 'DONE\n'
  printf 'Created %s mock finding(s) for %s/%s round %s.\n' "$findings_count" "$domain" "$lens" "$round"
  printf 'DONE\n'
}

main() {
  local prompt
  prompt="$(read_prompt "$@")"

  if [[ "$prompt" == *"RepoLens Synthesizer"* ]]; then
    emit_manifest "$prompt"
  elif [[ "$prompt" == *"META-ORCHESTRATOR"* ]]; then
    emit_meta_dispatch
  else
    emit_lens_findings "$prompt"
  fi
}

main "$@"
