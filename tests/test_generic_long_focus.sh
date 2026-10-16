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


# repolens-r8-p2-3. Real parser, round driver and run_lens; local agent stub only.
# shellcheck disable=SC2034,SC2329 # Extracted driver functions consume globals/callbacks.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
# shellcheck source=/dev/null
source "$REPO/lib/template.sh"
# shellcheck source=lib/rounds.sh
source "$REPO/lib/rounds.sh"
# shellcheck source=/dev/null
source "$REPO/lib/summary.sh"
# shellcheck source=lib/verify.sh
source "$REPO/lib/verify.sh"
# shellcheck source=lib/synthesize.sh
source "$REPO/lib/synthesize.sh"
for function_name in run_lens is_lens_completed mark_lens_completed template_var_escape \
    sanitize_heartbeat_component lens_heartbeat_key lens_heartbeat_path lens_heartbeat_iteration_path \
    write_lens_heartbeat write_lens_heartbeat_iteration; do
  eval "$(sed -n "/^${function_name}() {/,/^}/p" "$REPO/repolens.sh")"
done

set -euo pipefail
LOCAL_MODE=true MODE=bugreport AGENT=mock PARALLEL=false
RUN_ID=probe RESUME_RUN_ID=probe
LENSES_DIR="$REPO/prompts/lenses" BASE_WRAPPER_FILE="$REPO/prompts/_base/bugreport.md"
BASE_PROMPTS_DIR="$REPO/prompts/_base"
DOMAINS_FILE="$REPO/config/domains.json" COLORS_FILE="$REPO/config/label-colors.json"
AGENT_TIMEOUT_SECS=5 AGENT_KILL_GRACE_SECS=1
MIN_SEVERITY=low REPO_OWNER=acme REPO_NAME=repo FORGE_REPO_SLUG=acme/repo
CHANGE_STATEMENT='' SPEC_FILE='' MAX_ISSUES='' SOURCE_FILE='' HOSTED=false LOGS_PATH='' HOSTED_NETWORK=''
BUG_REPORT_FILE='' TRIAGE_CONTEXT_PACK_FILE=''
LENS_MAX_WALL_SECS=60 MAX_ITERATIONS_PER_LENS=2 GLOBAL_ISSUES_CREATED=0
REPOLENS_NO_PROGRESS_MIN_BYTES=1 REPOLENS_NO_PROGRESS_LIMIT=2 DONE_STREAK_REQUIRED=1
retire_legacy_lens_heartbeat() { :; }
resolve_effective_agent() { printf mock; }
resolve_agent_timeout() { printf 5; }
resolve_lens_heartbeat_interval() { printf 0; }
forge_prompt_issue_create() { :; }
forge_prompt_label_create() { :; }
forge_prompt_issue_list() { :; }
count_dry_run_issues() { printf 0; }
count_issues_in_output() { printf 0; }
classify_agent_iteration() { printf unknown; }
check_done() { return 0; }
compress_lens_iterations() { :; }
log_info() { :; }
log_warn() { printf '%s\n' "$*" >&2; }
log_error() { printf '%s\n' "$*" >&2; }
# shellcheck disable=SC2154 # Read the extracted callback's dynamically scoped locals.
run_agent() {
  if declare -F check_component_limits >/dev/null; then
    # Exercise real capture/envelope and heartbeat paths, including atomic
    # write suffixes, under the same limits as the execution directories.
    local beat iteration_path
    beat="$(lens_heartbeat_path "$domain" "$heartbeat_lens_id")" || return 1
    iteration_path="$(lens_heartbeat_iteration_path "$domain" "$heartbeat_lens_id")" || return 1
    check_component_limits "$output_file" "$6" "$output_envelope_file" \
      "$beat.tmp.$BASHPID" "$iteration_path.tmp.$BASHPID" || return 1
    write_lens_heartbeat_iteration "$iteration_path" 1 || return 1
    write_lens_heartbeat "$beat" "$RUN_ID" "$domain" "$lens_id" "$BASHPID" 1 fixture || return 1
    printf '{"status":"completed"}\n' > "$6" || return 1
  fi
  printf 'called\n' >> "$LOG_BASE/agent-calls"
  if [[ "${domain:-}" == generic ]]; then
    # Follow investigator.md's actual <lens_id>.md output contract.
    local findings_dir findings_file
    findings_dir="$(round_lens_outputs_dir "$RUN_ID" "${CURRENT_ROUND_INDEX:-1}")"
    findings_file="$(printf '%s\n' "$2" | awk '/^Write your findings to a single Markdown file at:$/ { output=1; next } output && /^```$/ { getline; print; exit }')"
    # The agent must receive the generated identity and exact destination;
    # it cannot infer a hash from the investigation's full focus text.
    [[ "$findings_file" == "$findings_dir/"* && "${findings_file##*/}" == "$lens_id.md" ]] || return 1
    [[ "$2" == *$'\n'"lens_id: $lens_id"$'\n'* ]] || return 1
    [[ "$2" == *"$lens_focus"* && "$2" == *"$prior_finding_anchor"* && "$2" == *"$exclusion_hints"* ]] || return 1
    mkdir -p "$(dirname -- "$findings_file")" || return 1
    printf '%s\n' "$findings_file" >> "$LOG_BASE/finding-paths"
    printf -- '---\nlens_id: %s\ndomain: generic\nround: %s\nseverity: low\ntype: test-gap\nconfidence: high\nrole: %s\nfocus: %s\nroot_cause_category: test-gap\nsuspect_files:\n  - probe.sh:1\n---\n## suspect_files\n- probe.sh:1\n## hypothesis\nMock finding. %s\n## evidence\nMock evidence.\n## next_steps_for_synthesizer\nVerify fixture.\n' \
      "$lens_id" "${CURRENT_ROUND_INDEX:-1}" "$lens_role" "$(jq -Rn --arg text "$lens_focus" '$text')" \
      "Dispatch evidence: $(jq -cn --arg focus "${lens_focus:0:32}" --arg anchor "$prior_finding_anchor" --arg exclude "$exclusion_hints" '[$focus,$anchor,$exclude]')" \
      > "$findings_file" || return 1
  fi
  printf 'DONE\n'
}
# Follow the verifier's rendered discovery and hash contract without a model.
# The identity probe supplies recursive discovery independently, so a flat-glob
# omission cannot mask a duplicate-ID failure in the manifest validator.
verify_generic_findings() {
  python3 - "$LOG_BASE" "$2" "$verifier_probe" <<'PYVERIFY'
import hashlib
import json
import re
import sys
from pathlib import Path

base, prompt, probe = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
entries = []
for root in sorted((base / 'rounds').glob('round-*/lens-outputs')):
    recursive = probe == 'identity' or 'Also traverse recursively' in prompt
    for path in sorted(root.rglob('*.md') if recursive else root.glob('*.md')):
        text = path.read_text()
        if 'Exclude generated local delivery projections' in prompt and re.search(r'^generic_source_id:', text, re.M):
            continue
        field = lambda name: re.search(rf'^{name}: (.+)$', text, re.M)[1]
        citations = re.search(r'^suspect_files:\n((?:  - .+\n)+)', text, re.M)[1]
        suspects = sorted(line[4:] for line in citations.splitlines())
        parts = [field('lens_id'), field('domain'), field('round'), '\n'.join(suspects)]
        relative = path.relative_to(root).as_posix()
        if '/' in relative and 'source_relative_path' in prompt:
            parts.append(relative)
        finding_id = hashlib.sha1('\0'.join(parts).encode()).hexdigest()[:16]
        # Deliberately different verdicts for identical citations: filtering
        # must keep each verdict associated with its own dispatch source.
        status = 'WRONG' if not entries else 'VERIFIED'
        entries.append(dict(finding_id=finding_id, status=status, notes='Fixture vote',
                            lens_id=field('lens_id'), domain=field('domain'),
                            round=int(field('round')), source_finding_path=str(path)))
print(json.dumps(entries))
PYVERIFY
}
_VERIFIER_AGENT_CALLBACK=verify_generic_findings
getconf() {
  # Model separate log/output mounts without requiring privileged mounts.
  if [[ "$1" == NAME_MAX ]]; then
    case "$2" in
      "$FIXTURE/external-output"*) printf '%s\n' "$output_name_max" ;;
      "$FIXTURE/heartbeat-mount"*) printf '%s\n' "$heartbeat_name_max" ;;
      "$LOG_BASE"*) printf '%s\n' "$log_name_max" ;;
      *) command getconf "$@" ;;
    esac
  else
    command getconf "$@"
  fi
}
# Enforce the simulated mount's component limit before creating directories.
# A getconf stub alone leaves the host's 255-byte limit in effect and can hide
# oversized runtime artifacts even when the generated findings basename fits.
check_component_limits() {
  local path relative component limit
  local LC_ALL=C
  for path in "$@"; do
    case "$path" in
      "$FIXTURE/external-output/"*) relative="${path#"$FIXTURE/external-output/"}"; limit="$output_name_max" ;;
      "$FIXTURE/heartbeat-mount/"*) relative="${path#"$FIXTURE/heartbeat-mount/"}"; limit="$heartbeat_name_max" ;;
      "$LOG_BASE/"*) relative="${path#"$LOG_BASE/"}"; limit="$log_name_max" ;;
      *) continue ;;
    esac
    while [[ -n "$relative" ]]; do
      component="${relative%%/*}"
      if (( ${#component} > limit )); then
        printf 'Simulated NAME_MAX=%s rejects %s-byte component: %s\n' "$limit" "${#component}" "$component" >&2
        return 1
      fi
      if [[ "$relative" != */* ]]; then break; fi
      relative="${relative#*/}"
    done
  done
}
mkdir() {
  local path
  for path in "$@"; do
    [[ "$path" == -* ]] && continue
    check_component_limits "$path" || return 1
  done
  command mkdir "$@"
}
mv() { check_component_limits "$@" && command mv "$@"; }
cp() { check_component_limits "$@" && command cp "$@"; }
mktemp() { check_component_limits "$@" && command mktemp "$@"; }
for scenario in supported-minimum plain-limit heartbeat-limit output-limit log-limit short boundary over253 over254 over255 long; do
  LOG_BASE="$FIXTURE/$scenario" OUTPUT_DIR="$FIXTURE/$scenario/output" PROJECT_PATH="$FIXTURE/project"
  OUTPUT_DIR_SET=false
  output_name_max=255 log_name_max=255 heartbeat_name_max=255
  if [[ "$scenario" == supported-minimum || "$scenario" == plain-limit ]]; then
    output_name_max=128 log_name_max=128
  elif [[ "$scenario" == output-limit ]]; then
    OUTPUT_DIR="$FIXTURE/external-output" OUTPUT_DIR_SET=true output_name_max=128
  elif [[ "$scenario" == log-limit ]]; then
    OUTPUT_DIR="$FIXTURE/external-output" OUTPUT_DIR_SET=true log_name_max=128
  fi
  SUMMARY_FILE="$LOG_BASE/summary.json" completed_lenses_file="$LOG_BASE/.completed"
  HEARTBEAT_DIR="$LOG_BASE/.heartbeats"
  if [[ "$scenario" == heartbeat-limit ]]; then
    HEARTBEAT_DIR="$FIXTURE/heartbeat-mount" heartbeat_name_max=128
  elif [[ "$scenario" == supported-minimum || "$scenario" == plain-limit ]]; then
    heartbeat_name_max=128
  elif [[ "$scenario" == log-limit ]]; then
    heartbeat_name_max=128
  fi
  mkdir -p "$LOG_BASE" "$PROJECT_PATH" "$OUTPUT_DIR" "$HEARTBEAT_DIR"
  : > "$completed_lenses_file"
  : > "$LOG_BASE/agent-calls"
  focus='Check query construction'
  if [[ "$scenario" == boundary ]]; then
    focus="$(printf '%0245d' 0 | tr 0 a)"
  elif [[ "$scenario" == over* ]]; then
    printf -v focus '%*s' "$((${scenario#over} - 7))" ''
    focus="${focus// /a}"
  elif [[ "$scenario" == long || "$scenario" == *-limit || "$scenario" == supported-minimum ]]; then
    focus='Trace the complete request lifecycle from the public HTTP route through authentication and authorization middleware into the database transaction and asynchronous worker callback, checking error propagation, cancellation, retry behavior, resource cleanup, and concurrent updates to the same account.'
  fi
  printf 'GENERIC: role=deeper focus="%s"\n' "$focus" > "$LOG_BASE/dispatch.md"
  parsed="$(_rounds_meta_dispatch_generic_entries "$LOG_BASE/dispatch.md" "$OUTPUT_DIR")"
  mapfile -t ENTRIES <<< "$parsed"
  test "${#ENTRIES[@]}" -eq 1
  canonical="${ENTRIES[0]%%|*}"
  if [[ "$scenario" == plain-limit ]]; then ENTRIES=("$canonical"); fi
  name_max="$log_name_max"
  if (( output_name_max < name_max )); then name_max="$output_name_max"; fi
  if (( heartbeat_name_max < name_max )); then name_max="$heartbeat_name_max"; fi
  test "$((${#canonical} - 8 + 3))" -le "$name_max"
  if [[ "$scenario" == boundary ]]; then test "$canonical" = "generic/deeper-$focus"; fi
  init_summary "$SUMMARY_FILE" probe "$PROJECT_PATH" bugreport mock '' '' local "$OUTPUT_DIR"
  for attempt in first resume; do
    test "$(_rounds_meta_dispatch_generic_entries "$LOG_BASE/dispatch.md" "$OUTPUT_DIR")" = "$parsed"
    rc=0
    run_rounds 1 ENTRIES || rc=$?
    printf '%s/%s: generated_basename_bytes=%s run_rounds_rc=%s model_calls=%s completion_receipts=%s stopped_reason=%s\n' \
      "$scenario" "$attempt" "$((${#canonical} - 8))" "$rc" "$(wc -l < "$LOG_BASE/agent-calls")" \
      "$(wc -l < "$completed_lenses_file")" "$(jq -r .stopped_reason "$SUMMARY_FILE")"
    test "$rc" -eq 0
    test "$(wc -l < "$LOG_BASE/agent-calls")" -eq 1
    test "$(wc -l < "$completed_lenses_file")" -eq 1
    test -e "$LOG_BASE/rounds/round-1/.completed"
    test -f "$(cat "$LOG_BASE/finding-paths")"
    grep -Fq 'Mock finding.' "$LOG_BASE/rounds/round-1/digest.md"
    # Inspect every created directory and file too, including redirected writes.
    mapfile -t runtime_paths < <(find "$LOG_BASE" "$OUTPUT_DIR" "$HEARTBEAT_DIR" -mindepth 1 -print)
    check_component_limits "${runtime_paths[@]}"
    test "$(find "$HEARTBEAT_DIR" -name '*.json' | wc -l)" -eq 1
    test "$(find "$LOG_BASE/output" -name '*.envelope.json' | wc -l)" -eq 1
    dispatch_hash="$(sha256_text "${ENTRIES[0]}")"
    if (( heartbeat_name_max == 128 )); then
      test -f "$HEARTBEAT_DIR/generic__$dispatch_hash.json"
    else
      test -f "$HEARTBEAT_DIR/$(lens_heartbeat_key generic "dispatch-$dispatch_hash").json"
    fi
  done
done
# Unsupported mounts must fail before invocation, including saved tuples that
# bypass parsing. Completed receipts still skip without altering old artifacts.
last_supported_base="$LOG_BASE"
last_supported_entries=("${ENTRIES[@]}")
for unsupported_limit in 36 37 127; do
  for destination in log output heartbeat; do
    LOG_BASE="$FIXTURE/reject-$unsupported_limit-$destination" OUTPUT_DIR="$FIXTURE/external-output"
    output_name_max=255 log_name_max=255 heartbeat_name_max=255
    if [[ "$destination" == log ]]; then log_name_max="$unsupported_limit";
    elif [[ "$destination" == output ]]; then output_name_max="$unsupported_limit";
    else heartbeat_name_max="$unsupported_limit"; fi
    SUMMARY_FILE="$LOG_BASE/summary.json" completed_lenses_file="$LOG_BASE/.completed"
    HEARTBEAT_DIR="$LOG_BASE/.heartbeats"
    if [[ "$destination" == heartbeat ]]; then HEARTBEAT_DIR="$FIXTURE/heartbeat-mount"; fi
    mkdir -p "$LOG_BASE" "$OUTPUT_DIR"
    : > "$completed_lenses_file"
    : > "$LOG_BASE/agent-calls"
    printf 'GENERIC: role=deeper focus="query"\n' > "$LOG_BASE/dispatch.md"
    rc=0
    _rounds_meta_dispatch_generic_entries "$LOG_BASE/dispatch.md" > "$LOG_BASE/parsed" 2> "$LOG_BASE/error" || rc=$?
    printf 'unsupported-%s/%s: parser_rc=%s (expected nonzero)\n' "$unsupported_limit" "$destination" "$rc"
    test "$rc" -ne 0
    grep -Fq "$unsupported_limit" "$LOG_BASE/error"
    grep -Fq '128' "$LOG_BASE/error"
    if [[ "$destination" == log ]]; then grep -Fq "$LOG_BASE" "$LOG_BASE/error";
    elif [[ "$destination" == output ]]; then grep -Fq "$OUTPUT_DIR" "$LOG_BASE/error";
    else grep -Fq "$HEARTBEAT_DIR" "$LOG_BASE/error"; fi
    init_summary "$SUMMARY_FILE" probe "$PROJECT_PATH" bugreport mock '' '' local "$OUTPUT_DIR"
    for entry in generic/saved 'generic/saved|deeper|query||'; do
      ENTRIES=("$entry")
      rc=0
      run_rounds 1 ENTRIES || rc=$?
      test "$rc" -ne 0
      test ! -s "$LOG_BASE/agent-calls"
      test ! -s "$completed_lenses_file"
      test ! -e "$LOG_BASE/rounds/round-1/.completed"
    done
    printf '%s\n' "$entry" > "$completed_lenses_file"
    receipt_before="$(cat "$completed_lenses_file")"
    run_lens "$entry"
    test "$(cat "$completed_lenses_file")" = "$receipt_before"
    test ! -s "$LOG_BASE/agent-calls"
  done
done
unset -f getconf mkdir mv cp mktemp check_component_limits
LOG_BASE="$last_supported_base" OUTPUT_DIR="$last_supported_base/output"
SUMMARY_FILE="$LOG_BASE/summary.json" completed_lenses_file="$LOG_BASE/.completed"
HEARTBEAT_DIR="$LOG_BASE/.heartbeats"
ENTRIES=("${last_supported_entries[@]}")

# A Generic result is trusted only when its identity was dispatched for this
# round. A matching slug in a different domain must not inherit that trust.
findings_dir="$LOG_BASE/rounds/round-1/lens-outputs"
valid_finding="$(cat "$LOG_BASE/finding-paths")"
sed -e 's/^lens_id:.*/lens_id: never-dispatched/' -e 's/Mock finding\./Untrusted finding./' \
  "$valid_finding" > "$findings_dir/untrusted.md"
sed -e 's/^domain: generic/domain: security/' -e 's/Mock finding\./Spoofed finding./' \
  "$valid_finding" > "$findings_dir/spoofed.md"
build_round_digest "$LOG_BASE/rounds/round-1" "${ENTRIES[@]}"
grep -Fq 'Mock finding.' "$LOG_BASE/rounds/round-1/digest.md"
if grep -Eq '(Untrusted|Spoofed) finding\.' "$LOG_BASE/rounds/round-1/digest.md"; then exit 1; fi
build_round_digest "$LOG_BASE/rounds/round-1"
if grep -Fq 'Mock finding.' "$LOG_BASE/rounds/round-1/digest.md"; then exit 1; fi

# Reach the same failure through the public bugreport waves path: real triage
# seed -> wave selector -> dispatch parser -> round driver -> lens callback.
LOG_BASE="$FIXTURE/waves" OUTPUT_DIR="$FIXTURE/waves/output" PROJECT_PATH="$FIXTURE/project"
SUMMARY_FILE="$LOG_BASE/summary.json" completed_lenses_file="$LOG_BASE/.completed"
CURRENT_ROUND_OUTPUT_DIR='' STRATEGY=waves
mkdir -p "$LOG_BASE/triage"
printf '%s\n' "$focus" > "$LOG_BASE/triage/investigation-seeds.txt"
: > "$completed_lenses_file"
: > "$LOG_BASE/agent-calls"
init_summary "$SUMMARY_FILE" probe "$PROJECT_PATH" bugreport mock '' '' local "$OUTPUT_DIR"
LENSES=(security/injection)
for attempt in first resume; do
  rc=0
  run_rounds 2 LENSES || rc=$?
  printf 'waves/%s: run_rounds_rc=%s model_calls=%s round1_complete=%s\n' "$attempt" "$rc" \
    "$(wc -l < "$LOG_BASE/agent-calls")" \
    "$(if [[ -e "$LOG_BASE/rounds/round-1/.completed" ]]; then echo yes; else echo no; fi)"
  test "$rc" -eq 0
  test -s "$LOG_BASE/agent-calls"
  test -e "$LOG_BASE/rounds/round-1/.completed"
  grep -Fq 'Mock finding.' "$LOG_BASE/rounds/round-1/digest.md"
  if [[ "$attempt" == first ]]; then wave_calls="$(wc -l < "$LOG_BASE/agent-calls")";
  else test "$(wc -l < "$LOG_BASE/agent-calls")" -eq "$wave_calls"; fi
done

# Same long prefix, different tails: retain focus text and stable distinct IDs.
LOG_BASE="$FIXTURE/identities"
mkdir -p "$LOG_BASE"
prefix="$(printf '%0400d' 0 | tr 0 a)"
ids=()
for tail in b c; do
  focus="$prefix$tail | café 再試行"
  printf 'GENERIC: role=deeper focus="%s" anchor="probe.sh:1" exclude="α | β"\n' "$focus" > "$LOG_BASE/dispatch.md"
  tuple="$(_rounds_meta_dispatch_generic_entries "$LOG_BASE/dispatch.md")"
  identity='' role='' restored_focus='' anchor='' exclude=''
  _rounds_meta_tuple_parse "$tuple" identity role restored_focus anchor exclude
  test "$restored_focus" = "$focus"
  test "$role" = deeper
  test "$anchor" = probe.sh:1
  test "$exclude" = 'α | β'
  test "${#identity}" -le 260
  test "$(_rounds_meta_dispatch_generic_entries "$LOG_BASE/dispatch.md")" = "$tuple"
  ids+=("$identity")
done
test "${ids[0]}" != "${ids[1]}"
rc=0
( sha256_text() { return 1; }; _rounds_meta_dispatch_generic_entries "$LOG_BASE/dispatch.md" ) || rc=$?
test "$rc" -ne 0
# Distinct tuples can have the same canonical slug: varying anchors or
# exclusions, and punctuation normalized out of focus, must preserve both
# findings. Consume the rendered output path exactly as an agent would.
for collision in anchor exclude normalized long; do
  LOG_BASE="$FIXTURE/collision-$collision" OUTPUT_DIR="$LOG_BASE/output"
  SUMMARY_FILE="$LOG_BASE/summary.json" completed_lenses_file="$LOG_BASE/.completed"
  CURRENT_ROUND_OUTPUT_DIR='' STRATEGY=fanout
  CURRENT_ROUND_INDEX=1 CURRENT_ROUND_TOTAL=1
  mkdir -p "$LOG_BASE"
  : > "$completed_lenses_file"
  : > "$LOG_BASE/agent-calls"
  focus='src/query.go:10' other_focus="$focus"
  anchor='prior-a' other_anchor="$anchor" exclude='checked-b' other_exclude="$exclude"
  case "$collision" in
    anchor) other_anchor='prior-c' ;;
    exclude) other_exclude='checked-d' ;;
    normalized) other_focus='src-query-go-10' ;;
    long) focus="$prefix" other_focus="$prefix" other_anchor='prior-c' ;;
  esac
  printf 'GENERIC: role=deeper focus="%s" anchor="%s" exclude="%s"\n' \
    "$focus" "$anchor" "$exclude" "$other_focus" "$other_anchor" "$other_exclude" \
    "$focus" "$anchor" "$exclude" > "$LOG_BASE/dispatch.md"
  parsed="$(_rounds_meta_dispatch_generic_entries "$LOG_BASE/dispatch.md")"
  mapfile -t ENTRIES <<< "$parsed"
  test "${#ENTRIES[@]}" -eq 2
  test "${ENTRIES[0]%%|*}" = "${ENTRIES[1]%%|*}"
  init_summary "$SUMMARY_FILE" probe "$PROJECT_PATH" bugreport mock '' '' local "$OUTPUT_DIR"
  if [[ "$collision" == exclude ]]; then
    # Actual concurrent callbacks exercise the same destinations as parallel
    # dispatch; the round driver then consumes their saved receipts.
    (trap - EXIT; run_lens "${ENTRIES[0]}" || exit 1) &
    first_pid=$!
    (trap - EXIT; run_lens "${ENTRIES[1]}" || exit 1) &
    second_pid=$!
    wait "$first_pid"
    wait "$second_pid"
  else
    # Resume after the first investigation completed, with the remaining
    # tuple first. Reordering must preserve output paths and exact receipts.
    run_lens "${ENTRIES[0]}" || exit 1
  fi
  ENTRIES=("${ENTRIES[1]}" "${ENTRIES[0]}")
  run_rounds 1 ENTRIES
  test "$(wc -l < "$LOG_BASE/agent-calls")" -eq 2
  test "$(wc -l < "$completed_lenses_file")" -eq 2
  printf 'collision-%s: calls=%s receipts=%s distinct_paths=%s finding_files=%s\n' "$collision" \
    "$(wc -l < "$LOG_BASE/agent-calls")" "$(wc -l < "$completed_lenses_file")" \
    "$(sort -u "$LOG_BASE/finding-paths" | wc -l)" \
    "$(find "$LOG_BASE/rounds/round-1/lens-outputs" -name '*.md' | wc -l)"
  test "$(sort -u "$LOG_BASE/finding-paths" | wc -l)" -eq 2
  test "$(find "$LOG_BASE/rounds/round-1/lens-outputs" -name '*.md' | wc -l)" -eq 2
  digest="$LOG_BASE/rounds/round-1/digest.md"
  for evidence in "$(jq -cn --arg f "${focus:0:32}" --arg a "$anchor" --arg e "$exclude" '[$f,$a,$e]')" \
      "$(jq -cn --arg f "${other_focus:0:32}" --arg a "$other_anchor" --arg e "$other_exclude" '[$f,$a,$e]')"; do
    grep -Fq "Dispatch evidence: $evidence" "$digest"
  done
  # Give both findings identical citation sets to exercise stable sorting too.
  while IFS= read -r finding_path; do
    sed -i '/^  - probe.sh:1$/a\  - probe.sh:2' "$finding_path"
  done < "$LOG_BASE/finding-paths"
  # Verify the real findings from both dispatches, not synthetic unique IDs.
  verifier_failures=0
  for verifier_probe in identity discovery; do
    verifier_rc=0
    run_verifier "$RUN_ID" || verifier_rc=$?
    verification="$LOG_BASE/final/verification.json"
    verified_count=0
    if [[ -f "$verification" ]]; then verified_count="$(jq length "$verification")"; fi
    printf 'verifier-%s/%s: rc=%s entries=%s (expected rc=0 entries=2)\n' \
      "$collision" "$verifier_probe" "$verifier_rc" "$verified_count"
    if (( verifier_rc != 0 || verified_count != 2 )); then
      verifier_failures=$((verifier_failures + 1))
    fi
  done
  test "$verifier_failures" -eq 0
  test "$(jq '[.[].finding_id] | unique | length' "$verification")" -eq 2
  verification_before="$(jq -c 'sort_by(.source_finding_path)' "$verification")"
  for vote in WRONG VERIFIED; do
    source_path="$(jq -r --arg vote "$vote" '.[] | select(.status == $vote) | .source_finding_path' "$verification")"
    test -f "$source_path"
    source_relative_path="${source_path#"$LOG_BASE/rounds/round-1/lens-outputs/"}"
    source_lens_id="${source_path##*/}"
    expected_id="$(printf '%s\0%s\0%s\0%s\0%s' "${source_lens_id%.md}" generic 1 $'probe.sh:1\nprobe.sh:2' "$source_relative_path" | sha1sum | cut -c1-16)"
    test "$(jq -r --arg vote "$vote" '.[] | select(.status == $vote) | .finding_id' "$verification")" = "$expected_id"
    jq -n --arg path "$source_path" '[{cluster_id:"fixture",source_finding_paths:[$path]}]' > "$LOG_BASE/cluster.json"
    gate_rc=0
    validate_manifest_against_verification "$LOG_BASE/cluster.json" "$verification" || gate_rc=$?
    if [[ "$vote" == WRONG ]]; then test "$gate_rc" -ne 0; else test "$gate_rc" -eq 0; fi
  done
  receipts_before="$(sha256_text "$(cat "$completed_lenses_file")")"
  paths_before="$(cat "$LOG_BASE/finding-paths")"
  run_rounds 1 ENTRIES
  test "$(wc -l < "$LOG_BASE/agent-calls")" -eq 2
  test "$(sha256_text "$(cat "$completed_lenses_file")")" = "$receipts_before"
  test "$(cat "$LOG_BASE/finding-paths")" = "$paths_before"
  # Citation order must not change IDs when revisiting the same sources.
  while IFS= read -r finding_path; do
    python3 - "$finding_path" <<'PYREORDER'
import sys
from pathlib import Path
p = Path(sys.argv[1])
p.write_text(p.read_text().replace('  - probe.sh:1\n  - probe.sh:2', '  - probe.sh:2\n  - probe.sh:1'))
PYREORDER
  done < "$LOG_BASE/finding-paths"
  run_verifier "$RUN_ID"
  test "$(jq -c 'sort_by(.source_finding_path)' "$verification")" = "$verification_before"
  if [[ "$collision" == anchor ]]; then
    original_log_base="$LOG_BASE"
    ids_before="$(jq -c '[.[].finding_id] | sort' "$verification")"
    mv -- "$LOG_BASE" "$LOG_BASE-relocated"
    LOG_BASE="$LOG_BASE-relocated"
    run_verifier "$RUN_ID"
    test "$(jq -c '[.[].finding_id] | sort' "$LOG_BASE/final/verification.json")" = "$ids_before"
    while IFS= read -r source_path; do test -f "$source_path"; done < <(jq -r '.[].source_finding_path' "$LOG_BASE/final/verification.json")
    mv -- "$LOG_BASE" "$original_log_base"
    LOG_BASE="$original_log_base"
  fi
  printf 'collision-%s: distinct verifier IDs stable on resume; WRONG source rejected independently\n' "$collision"
  printf 'collision-%s: two findings retained in files and digest; resume adds no calls\n' "$collision"
done
# Plain calls keep the historical location, and completed legacy tuples skip
# before touching the new directory. Failures must not certify lost work.
LOG_BASE="$FIXTURE/plain" OUTPUT_DIR="$LOG_BASE/output"
SUMMARY_FILE="$LOG_BASE/summary.json" completed_lenses_file="$LOG_BASE/.completed"
CURRENT_ROUND_INDEX=1 CURRENT_ROUND_TOTAL=1 CURRENT_ROUND_OUTPUT_DIR=''
mkdir -p "$LOG_BASE"
: > "$completed_lenses_file"
: > "$LOG_BASE/agent-calls"
init_summary "$SUMMARY_FILE" probe "$PROJECT_PATH" bugreport mock '' '' local "$OUTPUT_DIR"
run_lens generic/plain-probe || exit 1
test "$(cat "$LOG_BASE/finding-paths")" = "$LOG_BASE/rounds/round-1/lens-outputs/plain-probe.md"
run_lens generic/plain-probe || exit 1
test "$(wc -l < "$LOG_BASE/agent-calls")" -eq 1
run_verifier "$RUN_ID"
# Historical flat-output IDs keep the original four-field recipe.
expected_id="$(printf 'plain-probe\0generic\0001\0probe.sh:1' | sha1sum | cut -c1-16)"
test "$(jq -r '.[0].finding_id' "$LOG_BASE/final/verification.json")" = "$expected_id"

LOG_BASE="$FIXTURE/legacy" OUTPUT_DIR="$LOG_BASE/output"
completed_lenses_file="$LOG_BASE/.completed"
legacy_dir="$LOG_BASE/rounds/round-1/lens-outputs"
mkdir -p "$legacy_dir"
legacy_entry="${parsed%%|*}"
legacy_file="$legacy_dir/${legacy_entry#*/}.md"
printf 'legacy finding\n' > "$legacy_file"
printf '%s\n' "$parsed" > "$completed_lenses_file"
: > "$LOG_BASE/agent-calls"
run_lens "$parsed" || exit 1
test ! -s "$LOG_BASE/agent-calls"
test "$(cat "$legacy_file")" = 'legacy finding'
test "$(find "$legacy_dir" -mindepth 1 -type d | wc -l)" -eq 0

for failure in hash directory; do
  LOG_BASE="$FIXTURE/failure-$failure" OUTPUT_DIR="$LOG_BASE/output"
  SUMMARY_FILE="$LOG_BASE/summary.json" completed_lenses_file="$LOG_BASE/.completed"
  mkdir -p "$LOG_BASE/rounds/round-1/lens-outputs"
  : > "$completed_lenses_file"
  : > "$LOG_BASE/agent-calls"
  printf 'GENERIC: role=deeper focus="probe.sh:1"\n' > "$LOG_BASE/dispatch.md"
  parsed="$(_rounds_meta_dispatch_generic_entries "$LOG_BASE/dispatch.md")"
  ENTRIES=("$parsed")
  dispatch_digest="$(sha256_text "$parsed")"
  blocked="$LOG_BASE/rounds/round-1/lens-outputs/${dispatch_digest:0:32}"
  if [[ "$failure" == directory ]]; then
    printf 'preserve me\n' > "$blocked"
  else
    saved_hash="$(declare -f sha256_text)"
    sha256_text() { return 1; }
  fi
  init_summary "$SUMMARY_FILE" probe "$PROJECT_PATH" bugreport mock '' '' local "$OUTPUT_DIR"
  rc=0
  run_rounds 1 ENTRIES || rc=$?
  test "$rc" -ne 0
  test ! -s "$LOG_BASE/agent-calls"
  test ! -s "$completed_lenses_file"
  test ! -e "$LOG_BASE/rounds/round-1/.completed"
  if [[ "$failure" == directory ]]; then
    test "$(cat "$blocked")" = 'preserve me'
    rm -- "$blocked"
  else
    eval "$saved_hash"
  fi
  run_rounds 1 ENTRIES || exit 1
  test "$(wc -l < "$LOG_BASE/agent-calls")" -eq 1
  test -s "$completed_lenses_file"
  printf 'failure-%s: no agent call or receipt before recovery; retry succeeds\n' "$failure"
done
printf 'Results: 12 filename/resume scenarios, 9 unsupported destinations, 4 collisions, plain paths and failure recovery passed, 0 failed\n'
