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

# Tests for issues #73, #74, #75, #76, and #77: llm-security lens integration.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LENS_DIR="$SCRIPT_DIR/prompts/lenses/llm-security"
OUTPUT_LENS_FILE="$LENS_DIR/output-sanitization.md"
PROMPT_INJECTION_LENS_FILE="$LENS_DIR/prompt-injection.md"
AGENT_ISOLATION_LENS_FILE="$LENS_DIR/agent-isolation.md"
COST_CONTROL_LENS_FILE="$LENS_DIR/cost-control.md"
CREDENTIAL_EXPOSURE_LENS_FILE="$LENS_DIR/credential-exposure.md"
DOMAINS_FILE="$SCRIPT_DIR/config/domains.json"
COLORS_FILE="$SCRIPT_DIR/config/label-colors.json"

PASS=0
FAIL=0
TOTAL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    Expected: $expected"
    echo "    Actual:   $actual"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    Missing: $needle"
  fi
}

assert_file_exists() {
  local desc="$1" filepath="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$filepath" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    File not found: $filepath"
  fi
}

echo ""
echo "=== Test Suite: llm-security lenses (issues #73, #74, #75, #76, and #77) ==="
echo ""

assert_file_exists "output-sanitization lens prompt exists" "$OUTPUT_LENS_FILE"
assert_file_exists "prompt-injection lens prompt exists" "$PROMPT_INJECTION_LENS_FILE"
assert_file_exists "agent-isolation lens prompt exists" "$AGENT_ISOLATION_LENS_FILE"
assert_file_exists "cost-control lens prompt exists" "$COST_CONTROL_LENS_FILE"
assert_file_exists "credential-exposure lens prompt exists" "$CREDENTIAL_EXPOSURE_LENS_FILE"

lens_content=""
if [[ -f "$OUTPUT_LENS_FILE" ]]; then
  lens_content="$(cat "$OUTPUT_LENS_FILE")"
fi

prompt_injection_content=""
if [[ -f "$PROMPT_INJECTION_LENS_FILE" ]]; then
  prompt_injection_content="$(cat "$PROMPT_INJECTION_LENS_FILE")"
fi

agent_isolation_content=""
if [[ -f "$AGENT_ISOLATION_LENS_FILE" ]]; then
  agent_isolation_content="$(cat "$AGENT_ISOLATION_LENS_FILE")"
fi

cost_control_content=""
if [[ -f "$COST_CONTROL_LENS_FILE" ]]; then
  cost_control_content="$(cat "$COST_CONTROL_LENS_FILE")"
fi

credential_exposure_content=""
if [[ -f "$CREDENTIAL_EXPOSURE_LENS_FILE" ]]; then
  credential_exposure_content="$(cat "$CREDENTIAL_EXPOSURE_LENS_FILE")"
fi

echo ""
echo "Test 1: output-sanitization frontmatter is complete"
assert_contains "id frontmatter" "id: output-sanitization" "$lens_content"
assert_contains "domain frontmatter" "domain: llm-security" "$lens_content"
assert_contains "name frontmatter" "name: LLM Output Sanitization & Rendering Safety" "$lens_content"
assert_contains "role frontmatter" "role: LLM Output Security Specialist" "$lens_content"

echo ""
echo "Test 2: output-sanitization body has required sections"
assert_contains "expert focus section" "## Your Expert Focus" "$lens_content"
assert_contains "hunt section" "### What You Hunt For" "$lens_content"
assert_contains "investigate section" "### How You Investigate" "$lens_content"

echo ""
echo "Test 3: output-sanitization covers LLM output rendering and injection risks"
for term in \
  "LLM output" \
  "Stored XSS" \
  "dangerouslySetInnerHTML" \
  "v-html" \
  "DOMPurify" \
  "bleach" \
  "sanitize-html" \
  "GitHub Issues" \
  "Jira" \
  "Slack" \
  "javascript:" \
  "data:" \
  "Pydantic" \
  "Zod" \
  "JSON Schema" \
  "Content-Security-Policy"; do
  assert_contains "prompt mentions $term" "$term" "$lens_content"
done

echo ""
echo "Test 4: prompt-injection frontmatter is complete"
assert_contains "id frontmatter" "id: prompt-injection" "$prompt_injection_content"
assert_contains "domain frontmatter" "domain: llm-security" "$prompt_injection_content"
assert_contains "name frontmatter" "name: LLM Prompt Injection Surfaces" "$prompt_injection_content"
assert_contains "role frontmatter" "role: LLM Prompt Injection Specialist" "$prompt_injection_content"

echo ""
echo "Test 5: prompt-injection body has required sections"
assert_contains "expert focus section" "## Your Expert Focus" "$prompt_injection_content"
assert_contains "hunt section" "### What You Hunt For" "$prompt_injection_content"
assert_contains "investigate section" "### How You Investigate" "$prompt_injection_content"

echo ""
echo "Test 6: prompt-injection covers LLM prompt injection risks"
for term in \
  "LLM prompt injection" \
  "Direct Prompt Injection" \
  "System Prompt Weakness" \
  "Indirect Injection via RAG" \
  "Tool-Use and Function-Calling Abuse" \
  "Chat History and Multi-Turn Injection" \
  "role confusion" \
  "Multi-Step Agent Chain Injection" \
  "Missing Output Validation" \
  "Prompt Template Management"; do
  assert_contains "prompt mentions $term" "$term" "$prompt_injection_content"
done

echo ""
echo "Test 7: agent-isolation frontmatter is complete"
assert_contains "id frontmatter" "id: agent-isolation" "$agent_isolation_content"
assert_contains "domain frontmatter" "domain: llm-security" "$agent_isolation_content"
assert_contains "name frontmatter" "name: Agent Isolation & Sandbox Escape" "$agent_isolation_content"
assert_contains "role frontmatter" "role: Agent Sandbox Security Specialist" "$agent_isolation_content"

echo ""
echo "Test 8: agent-isolation body has required sections"
assert_contains "expert focus section" "## Your Expert Focus" "$agent_isolation_content"
assert_contains "hunt section" "### What You Hunt For" "$agent_isolation_content"
assert_contains "investigate section" "### How You Investigate" "$agent_isolation_content"

echo ""
echo "Test 9: agent-isolation covers agent sandbox escape risks"
for term in \
  "LLM agent isolation" \
  "Docker socket" \
  "privileged" \
  "--pid=host" \
  "--network=host" \
  "cap_drop" \
  "Filesystem Escape" \
  ".git/hooks/" \
  "--pids-limit" \
  "169.254.169.254" \
  "Subprocess Fallback Without Sandboxing" \
  "seccomp" \
  "AppArmor" \
  "SIGKILL"; do
  assert_contains "prompt mentions $term" "$term" "$agent_isolation_content"
done

echo ""
echo "Test 10: cost-control frontmatter is complete"
assert_contains "id frontmatter" "id: cost-control" "$cost_control_content"
assert_contains "domain frontmatter" "domain: llm-security" "$cost_control_content"
assert_contains "name frontmatter" "name: LLM Cost Control & Token Budget Enforcement" "$cost_control_content"
assert_contains "role frontmatter" "role: LLM Cost Control Specialist" "$cost_control_content"

echo ""
echo "Test 11: cost-control body has required sections"
assert_contains "expert focus section" "## Your Expert Focus" "$cost_control_content"
assert_contains "hunt section" "### What You Hunt For" "$cost_control_content"
assert_contains "investigate section" "### How You Investigate" "$cost_control_content"

echo ""
echo "Test 12: cost-control covers LLM cost control risks"
for term in \
  "token budget" \
  "max_tokens" \
  "rate limiting" \
  "retry" \
  "timeout" \
  "circuit breaker" \
  "token usage" \
  "spend anomaly" \
  "kill switch" \
  "free-tier" \
  "model-level access control" \
  "background jobs" \
  "maximum iteration"; do
  assert_contains "prompt mentions $term" "$term" "$cost_control_content"
done

echo ""
echo "Test 13: credential-exposure frontmatter is complete"
assert_contains "id frontmatter" "id: credential-exposure" "$credential_exposure_content"
assert_contains "domain frontmatter" "domain: llm-security" "$credential_exposure_content"
assert_contains "name frontmatter" "name: LLM Agent Credential Exposure" "$credential_exposure_content"
assert_contains "role frontmatter" "role: LLM Credential Isolation Specialist" "$credential_exposure_content"

echo ""
echo "Test 14: credential-exposure body has required sections"
assert_contains "expert focus section" "## Your Expert Focus" "$credential_exposure_content"
assert_contains "hunt section" "### What You Hunt For" "$credential_exposure_content"
assert_contains "investigate section" "### How You Investigate" "$credential_exposure_content"

echo ""
echo "Test 15: credential-exposure covers LLM credential exposure risks"
for term in \
  "LLM API Keys" \
  "ANTHROPIC_API_KEY" \
  "OPENAI_API_KEY" \
  "AZURE_OPENAI_KEY" \
  "GOOGLE_API_KEY" \
  "Agent processes inheriting the full parent environment" \
  "DATABASE_URL" \
  "OAuth client secrets" \
  "AWS access keys" \
  "Shared and Unscoped Credentials" \
  "spend caps" \
  "rotation" \
  "Credentials Leaking Through LLM Conversation Logs" \
  "tool output" \
  "redaction" \
  "Tool and Function Calling" \
  "connection_string" \
  "proxy/gateway" \
  "prompt injection"; do
  assert_contains "prompt mentions $term" "$term" "$credential_exposure_content"
done

echo ""
echo "Test 16: llm-security domain is registered once"
domain_count="$(jq '[.domains[] | select(.id == "llm-security")] | length' "$DOMAINS_FILE")"
assert_eq "one llm-security domain" "1" "$domain_count"

echo ""
echo "Test 17: llm-security domain is mode-less default audit coverage"
domain_mode="$(jq -r '.domains[] | select(.id == "llm-security") | .mode // "null"' "$DOMAINS_FILE")"
assert_eq "no mode field" "null" "$domain_mode"

echo ""
echo "Test 18: llm-security domain contains all lenses"
domain_lenses="$(jq -r '.domains[] | select(.id == "llm-security") | .lenses | join(",")' "$DOMAINS_FILE")"
assert_eq "registered lens list" "output-sanitization,prompt-injection,agent-isolation,cost-control,credential-exposure" "$domain_lenses"

echo ""
echo "Test 19: llm-security label color is configured"
label_color="$(jq -r '."llm-security" // empty' "$COLORS_FILE")"
assert_eq "llm-security label color" "b91c1c" "$label_color"

echo ""
echo "Test 20: Audit-like mode resolution includes all llm-security lenses"
audit_lenses="$(jq -r --arg mode "audit" \
  '.domains | sort_by(.order)[] | (if $mode == "discover" then select(.mode == "discover") elif $mode == "deploy" then select(.mode == "deploy") elif $mode == "opensource" then select(.mode == "opensource") elif $mode == "content" then select(.mode == "content") else select(.mode != "discover" and .mode != "deploy" and .mode != "opensource" and .mode != "content") end) | .id as $d | .lenses[] | $d + "/" + .' "$DOMAINS_FILE")"
for expected_lens in \
  "llm-security/output-sanitization" \
  "llm-security/prompt-injection" \
  "llm-security/agent-isolation" \
  "llm-security/cost-control" \
  "llm-security/credential-exposure"; do
  if grep -qxF "$expected_lens" <<< "$audit_lenses"; then
    PASS=$((PASS + 1))
    TOTAL=$((TOTAL + 1))
    echo "  PASS: audit mode includes $expected_lens"
  else
    FAIL=$((FAIL + 1))
    TOTAL=$((TOTAL + 1))
    echo "  FAIL: audit mode should include $expected_lens"
  fi
done

echo ""
echo "Test 21: Exclusive modes do not include llm-security lenses"
for mode in discover deploy opensource content; do
  mode_lenses="$(jq -r --arg mode "$mode" \
    '.domains | sort_by(.order)[] | (if $mode == "discover" then select(.mode == "discover") elif $mode == "deploy" then select(.mode == "deploy") elif $mode == "opensource" then select(.mode == "opensource") elif $mode == "content" then select(.mode == "content") else select(.mode != "discover" and .mode != "deploy" and .mode != "opensource" and .mode != "content") end) | .id as $d | .lenses[] | $d + "/" + .' "$DOMAINS_FILE")"
  for excluded_lens in \
    "llm-security/output-sanitization" \
    "llm-security/prompt-injection" \
    "llm-security/agent-isolation" \
    "llm-security/cost-control" \
    "llm-security/credential-exposure"; do
    if grep -qxF "$excluded_lens" <<< "$mode_lenses"; then
      FAIL=$((FAIL + 1))
      TOTAL=$((TOTAL + 1))
      echo "  FAIL: $mode mode should not include $excluded_lens"
    else
      PASS=$((PASS + 1))
      TOTAL=$((TOTAL + 1))
      echo "  PASS: $mode mode excludes $excluded_lens"
    fi
  done
done

echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
