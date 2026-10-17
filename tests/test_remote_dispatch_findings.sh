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

# Follow the actual bugreport output instruction with a deterministic agent.
# shellcheck disable=SC2034,SC2329,SC2154 # Extracted callback consumes globals and supplies locals.
set -euo pipefail
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO/lib/template.sh"
# shellcheck source=/dev/null
source "$REPO/lib/rounds.sh"
# shellcheck source=/dev/null
source "$REPO/lib/summary.sh"
# shellcheck source=/dev/null
source "$REPO/lib/verify.sh"
# shellcheck source=/dev/null
source "$REPO/lib/synthesize.sh"
for fn in run_lens is_lens_completed mark_lens_completed template_var_escape; do
  eval "$(sed -n "/^$fn() {/,/^}/p" "$REPO/repolens.sh")"
done
FIXTURE="$(mktemp -d)"
JOB="$FIXTURE"
trap 'rm -rf -- "$FIXTURE"' EXIT
LOG_BASE="$FIXTURE/tool logs|pipe\backslash\"quote"$'\t'"/probe" RUN_ID=probe MODE=bugreport ROUNDS=2
PROJECT_PATH="$FIXTURE/project" LOCAL_MODE=false OUTPUT_DIR_SET=false PARALLEL=false AGENT=mock
OUTPUT_DIR='' CURRENT_ROUND_OUTPUT_DIR='' CURRENT_ROUND_INDEX=2 CURRENT_ROUND_TOTAL=2
SUMMARY_FILE="$LOG_BASE/summary.json" completed_lenses_file="$LOG_BASE/.completed"
LENSES_DIR="$REPO/prompts/lenses" BASE_WRAPPER_FILE="$REPO/prompts/_base/bugreport.md"
BASE_PROMPTS_DIR="$REPO/prompts/_base" DOMAINS_FILE="$REPO/config/domains.json" COLORS_FILE="$REPO/config/label-colors.json"
AGENT_TIMEOUT_SECS=5 AGENT_KILL_GRACE_SECS=1 MIN_SEVERITY=low
REPO_OWNER=acme REPO_NAME=repo FORGE_REPO_SLUG=acme/repo
CHANGE_STATEMENT='' SPEC_FILE='' MAX_ISSUES='' SOURCE_FILE='' HOSTED=false LOGS_PATH='' HOSTED_NETWORK=''
BUG_REPORT_FILE='' TRIAGE_CONTEXT_PACK_FILE='' LENS_MAX_WALL_SECS=60
MAX_ITERATIONS_PER_LENS=2 GLOBAL_ISSUES_CREATED=0
REPOLENS_NO_PROGRESS_MIN_BYTES=1 REPOLENS_NO_PROGRESS_LIMIT=2 DONE_STREAK_REQUIRED=1
retire_legacy_lens_heartbeat() { :; }
resolve_effective_agent() { printf mock; }
resolve_agent_timeout() { printf 5; }
resolve_lens_heartbeat_interval() { printf 0; }
forge_prompt_issue_create() { :; }
forge_prompt_label_create() { :; }
forge_prompt_issue_list() { :; }
forge_issue_list_count() { printf 0; }
count_issues_in_output() { printf 0; }
classify_agent_iteration() { printf unknown; }
check_done() { return 0; }
compress_lens_iterations() { :; }
log_info() { :; }
log_warn() { :; }
log_error() { :; }
# Read exactly the inventory advertised by each downstream prompt, from the
# agent's project cwd. No hidden LOG_BASE knowledge or canned finding paths.
read_downstream_findings() {
  local phase="$1" prompt="$2" project="$3"
  printf '%s\n' "$prompt" > "$JOB/$phase-prompt.md"
  (
    cd "$project" || exit 1
    python3 - "$phase" "$JOB/$phase-prompt.md" <<'PYTHON'
import hashlib
import json
from pathlib import Path
import re
import sys

phase, prompt_file = sys.argv[1:]
prompt = Path(prompt_file).read_text()
pattern = re.search(r"^- Walk `([^`]+)`", prompt, re.M).group(1)
root = Path(pattern.split("/round-*/lens-outputs/")[0])
files = sorted(root.glob("round-*/lens-outputs/**/*.md"))
assert len(files) == 2, f"{phase}: advertised inventory {pattern} found {len(files)}, expected 2"
# Decode the real schema examples, not paths independently serialized by this
# mock. JSON examples must preserve the same root as the inventory instruction.
schema = re.search(r"```json\n(.*?)\n```", prompt, re.S).group(1)
if phase == "verifier":
    example = json.loads(schema.replace("<integer>", "2"))
    expected = str(root / "round-N/lens-outputs/<lens>.md")
    assert example["source_finding_path"] == expected, repr(example["source_finding_path"])
else:
    example = json.loads(schema)[0]
    expected = str(root / "round-1/lens-outputs/<lens>.md")
    assert example["source_finding_paths"][0] == expected, repr(example["source_finding_paths"])
    action_path = str(root / "round-3/lens-outputs/<lens>.md")
    assert example["cross_link_actions"][0]["body"].endswith(action_path)
roles = set()
entries = []
for path in files:
    text = path.read_text()
    role = re.search(r"^title: (\w+) investigation$", text, re.M).group(1)
    assert f"{role} evidence" in text
    roles.add(role)
    if phase == "verifier":
        relative = path.relative_to(path.parents[1]).as_posix()
        identity = "\0".join(["injection", "security", "2", "src/a.sh:1", relative])
        entries.append(dict(finding_id=hashlib.sha1(identity.encode()).hexdigest()[:16],
                            status="VERIFIED", notes=f"Read {role} evidence",
                            source_finding_path=str(path)))
    else:
        entries.append(dict(cluster_id=role, title=f"[high] {role} investigation",
                            severity="high", domain="security", lens="injection",
                            root_cause_category="missing-validation", body=text,
                            source_finding_paths=[str(path)], dedup_against_existing=[],
                            proposed_labels=[], cross_link_actions=[], granularity="independent",
                            verification_status="verified"))
assert roles == {"deeper", "broader"}
if phase == "synthesizer":
    verification_path = re.search(r"^- If `([^`]+/final/verification.json)` exists", prompt, re.M).group(1)
    verification = json.loads(Path(verification_path).read_text())
    assert {item["source_finding_path"] for item in verification} == {str(path) for path in files}
    assert all(item["status"] == "VERIFIED" for item in verification)
print(json.dumps(entries))
PYTHON
  )
}
run_agent() {
  case "$2" in
    *'RepoLens Verifier'*) read_downstream_findings verifier "$2" "$3"; return $? ;;
    *'RepoLens Synthesizer'*) read_downstream_findings synthesizer "$2" "$3"; return $? ;;
  esac
  local instruction target
  printf '%s\n' "$2" > "$JOB/remote-prompt-$lens_role.md"
  instruction="$(printf '%s\n' "$2" | awk '/Write your findings to a single Markdown file at:/ {getline; getline; getline; print; exit}')"
  test -n "$instruction"
  printf '%s: %s\n' "$lens_role" "$instruction" >> "$JOB/remote-output-instructions.txt"
  target="${instruction//<run-id>/$RUN_ID}"
  target="${target//<lens_id>/$lens_id}"
  [[ "$target" == /* ]] || target="$PROJECT_PATH/$target"
  mkdir -p "$(dirname "$target")"
  cat > "$target" <<EOF
---
title: $lens_role investigation
lens_id: injection
domain: security
severity: high
root_cause_category: missing-validation
suspect_files:
  - src/a.sh:1
---
## Hypothesis
$lens_role evidence
EOF
  printf 'DONE\n'
}
mkdir -p "$LOG_BASE" "$PROJECT_PATH"
touch "$completed_lenses_file"
: > "$JOB/remote-output-instructions.txt"
init_summary "$SUMMARY_FILE" probe "$PROJECT_PATH" bugreport mock '' '' forge ''
first="$(_rounds_meta_tuple_serialize security/injection deeper 'src/a.sh:1' '' '')"
second="$(_rounds_meta_tuple_serialize security/injection broader 'src/b.sh:1' '' '')"
if run_lens "$first"; then :; else exit 1; fi
if run_lens "$second"; then :; else exit 1; fi
_rounds_all_lenses_completed "$completed_lenses_file" "$first" "$second"
test "$(wc -l < "$completed_lenses_file")" -eq 2
count="$(find "$LOG_BASE/rounds" -type f -name '*.md' | wc -l)"
printf 'Findings files: %s (expected 2)\n' "$count"
test "$count" -eq 2
for role in deeper broader; do
  target="$(sed -n "s/^$role: //p" "$JOB/remote-output-instructions.txt")"
  grep -Fxq "$role evidence" "$target"
done
build_round_digest "$LOG_BASE/rounds/round-2"
grep -Fq 'deeper' "$LOG_BASE/rounds/round-2/digest.md"
grep -Fq 'broader' "$LOG_BASE/rounds/round-2/digest.md"
before="$(cat "$JOB/remote-output-instructions.txt")"
run_lens "$first"
run_lens "$second"
test "$(cat "$JOB/remote-output-instructions.txt")" = "$before"
verifier_rc=0
run_verifier "$RUN_ID" || verifier_rc=$?
synthesizer_rc=0
run_synthesizer "$RUN_ID" || synthesizer_rc=$?
if (( verifier_rc != 0 )); then cat "$LOG_BASE/final/verifier-output.txt"; fi
if (( synthesizer_rc != 0 )); then cat "$LOG_BASE/final/synthesizer-output.txt"; fi
printf 'Downstream dispatch results: verifier=%s synthesizer=%s (expected 0/0)\n' "$verifier_rc" "$synthesizer_rc"
# Failed dispatches must never reach PASS, even when invoked in a guarded context.
test "$verifier_rc" -eq 0
test "$synthesizer_rc" -eq 0
jq -e 'length == 2 and ([.[].source_finding_path] | unique | length == 2)' "$LOG_BASE/final/verification.json" >/dev/null
jq -e 'length == 2 and ([.[].source_finding_paths[]] | unique | length == 2)' "$LOG_BASE/final/manifest.json" >/dev/null
printf 'PASS: separate findings survive retries, digest, verification and synthesis.\n'
