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


# repolens-r8-p2-1 / p2-2: production sequential traps and fresh resume counters.
# shellcheck disable=SC2034,SC2329 # Globals/callbacks consumed by sourced code.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
# shellcheck source=lib/core.sh
source "$REPO/lib/core.sh"
# shellcheck source=lib/summary.sh
source "$REPO/lib/summary.sh"
# shellcheck source=lib/polish.sh
source "$REPO/lib/polish.sh"
eval "$(sed -n '/^_handle_hangup() {/,/^trap _handle_termination TERM/p' "$REPO/repolens.sh")"
trap - HUP INT TERM
print_resume_hint() { :; }
eval "$(declare -f increment_summary_issues_created | sed '1s/increment_summary_issues_created/original_increment_summary_issues_created/')"
PASS=0 FAIL=0
check() {
  if "$@"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$*"; fi
}
forge_issue_create() {
  printf '%s\n' "$2" >> "$LOG_BASE/posts"
  local n
  n="$(wc -l < "$LOG_BASE/posts")"
  printf 'https://github.com/fixture/repo/issues/%s\n' "$n"
  if [[ "$boundary" == post && "$n" -eq 1 ]]; then kill -s "$signal" "$parent_pid"; fi
  return 0
}
for boundary in post summary summary-write; do
  for signal in HUP INT TERM; do
    RUN_ID=probe LOG_BASE="$FIXTURE/$boundary-$signal" SUMMARY_FILE="$FIXTURE/$boundary-$signal/summary.json"
    MODE=polish MAX_ISSUES=1 GLOBAL_ISSUES_CREATED=0 LOCAL_MODE=false PARALLEL=false
    FORGE_REPO_SLUG=fixture/repo REPOLENS_FINAL_STATE=finished
    mkdir -p "$LOG_BASE/polish"
    : > "$LOG_BASE/posts"
    init_summary "$SUMMARY_FILE" "$RUN_ID" "$FIXTURE" polish mock '' 1 github ''
    jq -n '["spacing-consistency","typographic-rhythm"] | map({domain:"fluency",lens_id:.,title:("[POLISH] "+.),body:"Concrete suggestion",voice_fit:"strong",polish_rank_x1000:1500})' \
      > "$LOG_BASE/polish/ranked-suggestions.json"
    rc=0
    (
      parent_pid=$BASHPID
      trap '_handle_hangup' HUP
      trap '_handle_interrupt' INT
      trap '_handle_termination' TERM
      # Terminate the summary writer before its atomic promotion, as a
      # foreground process-group signal can do while preserving the receipt.
      jq() {
        if [[ "$boundary" == summary-write && "$*" == *'.totals.issues_created = ((.totals.issues_created // 0) + $c)'* ]]; then
          python3 -c 'import os, signal, sys; os.kill(os.getppid(), getattr(signal, "SIG" + sys.argv[1])); os.kill(os.getpid(), signal.SIGTERM)' "$signal"
          return $?
        fi
        command jq "$@"
      }
      increment_summary_issues_created() {
        local count_rc=0
        original_increment_summary_issues_created "$@" || count_rc=$?
        if [[ "$boundary" == summary ]]; then kill -s "$signal" "$parent_pid"; fi
        return "$count_rc"
      }
      run_polish_issue_emission probe 3
    ) || rc=$?
    expected=143
    case "$signal" in HUP) expected=129 ;; INT) expected=130 ;; esac
    check test "$rc" -eq "$expected"
    check test "$(wc -l < "$LOG_BASE/posts")" -eq 1
    check test "$(find "$LOG_BASE/polish/filed" -name '*.url' | wc -l)" -eq 1
    initial_count=1
    [[ "$boundary" != summary-write ]] || initial_count=0
    check test "$(jq .totals.issues_created "$SUMMARY_FILE")" -eq "$initial_count"
    GLOBAL_ISSUES_CREATED=0 REPOLENS_FINAL_STATE=finished
    rc=0
    run_polish_issue_emission probe 3 || rc=$?
    check test "$rc" -eq 0
    check test "$(wc -l < "$LOG_BASE/posts")" -eq 1
    check test "$(find "$LOG_BASE/polish/filed" -name '*.url' | wc -l)" -eq 1
    check test "$(jq .totals.issues_created "$SUMMARY_FILE")" -eq 1
    check test "$(classify_summary_health "$SUMMARY_FILE")" = ok
    # An additional resume must keep the same run-wide cap too.
    GLOBAL_ISSUES_CREATED=0
    run_polish_issue_emission probe 3 || rc=$?
    check test "$(wc -l < "$LOG_BASE/posts")" -eq 1
    check test "$(jq .totals.issues_created "$SUMMARY_FILE")" -eq 1
  done
done
# Ranking can change across resumes: recover every receipt even when its lens
# disappeared, and count new shortlists on top of the recovered total.
for resume_case in empty remaining higher-count; do
  LOG_BASE="$FIXTURE/$resume_case" SUMMARY_FILE="$FIXTURE/$resume_case/summary.json"
  MAX_ISSUES='' GLOBAL_ISSUES_CREATED=0 REPOLENS_FINAL_STATE=finished
  mkdir -p "$LOG_BASE/polish/filed"
  : > "$LOG_BASE/posts"
  init_summary "$SUMMARY_FILE" probe "$FIXTURE" polish mock '' '' github ''
  printf 'https://github.com/fixture/repo/issues/10\n' > "$LOG_BASE/polish/filed/old-a.url"
  printf 'https://github.com/fixture/repo/issues/11\n' > "$LOG_BASE/polish/filed/old-b.url"
  printf '[]\n' > "$LOG_BASE/polish/ranked-suggestions.json"
  expected_count=2 expected_posts=0
  if [[ "$resume_case" == remaining ]]; then
    MAX_ISSUES=3 expected_count=3 expected_posts=1
    jq -n '[{domain:"fluency",lens_id:"new-lens",title:"New suggestion",body:"Concrete suggestion",voice_fit:"strong",polish_rank_x1000:1500}]' \
      > "$LOG_BASE/polish/ranked-suggestions.json"
  elif [[ "$resume_case" == higher-count ]]; then
    increment_summary_issues_created "$SUMMARY_FILE" 5
    expected_count=5
  fi
  for attempt in 1 2; do
    GLOBAL_ISSUES_CREATED=0
    rc=0
    run_polish_issue_emission probe 3 || rc=$?
    check test "$rc" -eq 0
    check test "$(jq .totals.issues_created "$SUMMARY_FILE")" -eq "$expected_count"
    check test "$(wc -l < "$LOG_BASE/posts")" -eq "$expected_posts"
    check test "$(classify_summary_health "$SUMMARY_FILE")" = ok
  done
done
# repolens-r9-p4-1: a successful remote POST followed by ENOSPC at the
# URL receipt must remain reserved across every resume, even with a new batch.
LOG_BASE="$FIXTURE/receipt-enospc" SUMMARY_FILE="$FIXTURE/receipt-enospc/summary.json"
RUN_ID=probe MODE=polish LOCAL_MODE=false MAX_ISSUES=1 GLOBAL_ISSUES_CREATED=0 REPOLENS_FINAL_STATE=finished
mkdir -p "$LOG_BASE/polish"
: > "$LOG_BASE/posts"
init_summary "$SUMMARY_FILE" probe "$FIXTURE" polish mock '' 1 github ''
printf '[{"domain":"fluency","lens_id":"spacing-consistency","title":"Spacing","body":"Concrete suggestion","voice_fit":"strong","polish_rank_x1000":1500}]\n' > "$LOG_BASE/polish/ranked-suggestions.json"
forge_issue_create() {
  builtin printf 'created\n' >> "$LOG_BASE/posts"
  builtin printf 'https://github.com/fixture/repo/issues/%s\n' "$(wc -l < "$LOG_BASE/posts")"
}
printf() {
  if [[ "${FUNCNAME[1]:-}" == run_polish_issue_emission && "${2:-}" == https://github.com/fixture/repo/issues/* ]]; then
    builtin printf '%s\n' "$2" > /dev/full
    return $?
  fi
  # shellcheck disable=SC2059 # Transparent wrapper must forward the caller's format and arguments.
  builtin printf "$@"
}
rc=0
run_polish_issue_emission probe 3 || rc=$?
unset -f printf
check test "$rc" -ne 0
check test "$(wc -l < "$LOG_BASE/posts")" -eq 1
check test "$(find "$LOG_BASE/polish/filed" -name '*.url' -size +0c | wc -l)" -eq 0
for retry_case in same changed empty; do
  if [[ "$retry_case" == changed ]]; then
    printf '[{"domain":"fluency","lens_id":"new-lens","title":"Changed ranking","body":"Other suggestion","voice_fit":"strong","polish_rank_x1000":1500}]\n' > "$LOG_BASE/polish/ranked-suggestions.json"
  elif [[ "$retry_case" == empty ]]; then
    printf '[]\n' > "$LOG_BASE/polish/ranked-suggestions.json"
  fi
  GLOBAL_ISSUES_CREATED=0
  rc=0
  run_polish_issue_emission probe 3 || rc=$?
  check test "$rc" -ne 0
  check test "$(wc -l < "$LOG_BASE/posts")" -eq 1
  check test "$(jq .totals.issues_created "$SUMMARY_FILE")" -eq 0
  printf 'receipt failure resume %s: rc=%s posts=%s\n' "$retry_case" "$rc" "$(wc -l < "$LOG_BASE/posts")"
done
# Simulate independent reconciliation of the one known fixture POST. A saved
# URL must restore accounting without repeating publication, even on an empty batch.
printf 'https://github.com/fixture/repo/issues/1\n' > "$LOG_BASE/polish/filed/fluency-spacing-consistency.url"
GLOBAL_ISSUES_CREATED=0
rc=0
run_polish_issue_emission probe 3 || rc=$?
check test "$rc" -eq 0
check test "$(wc -l < "$LOG_BASE/posts")" -eq 1
check test "$(jq .totals.issues_created "$SUMMARY_FILE")" -eq 1
# An existing reservation must also block a fresh run before the POST.
LOG_BASE="$FIXTURE/preexisting-attempt" SUMMARY_FILE="$FIXTURE/preexisting-attempt/summary.json"
GLOBAL_ISSUES_CREATED=0
mkdir -p "$LOG_BASE/polish/filed"
: > "$LOG_BASE/posts"
: > "$LOG_BASE/polish/filed/fluency-spacing-consistency.attempted"
printf '[{"domain":"fluency","lens_id":"spacing-consistency","title":"Spacing","body":"Concrete suggestion","voice_fit":"strong","polish_rank_x1000":1500}]\n' > "$LOG_BASE/polish/ranked-suggestions.json"
init_summary "$SUMMARY_FILE" probe "$FIXTURE" polish mock '' 1 github ''
rc=0
run_polish_issue_emission probe 3 || rc=$?
check test "$rc" -ne 0
check test "$(wc -l < "$LOG_BASE/posts")" -eq 0
# A reservation appearing after preflight must not be overwritten at POST.
LOG_BASE="$FIXTURE/late-attempt" SUMMARY_FILE="$FIXTURE/late-attempt/summary.json"
GLOBAL_ISSUES_CREATED=0
mkdir -p "$LOG_BASE/polish/filed"
: > "$LOG_BASE/posts"
printf '[{"domain":"fluency","lens_id":"spacing-consistency","title":"Spacing","body":"Concrete suggestion","voice_fit":"strong","polish_rank_x1000":1500}]\n' > "$LOG_BASE/polish/ranked-suggestions.json"
init_summary "$SUMMARY_FILE" probe "$FIXTURE" polish mock '' 1 github ''
eval "$(declare -f _polish_render_issue_body | sed '1s/_polish_render_issue_body/original_polish_render_issue_body/')"
_polish_render_issue_body() {
  original_polish_render_issue_body "$@" || return $?
  printf 'existing attempt\n' > "$LOG_BASE/polish/filed/fluency-spacing-consistency.attempted"
}
rc=0
run_polish_issue_emission probe 3 || rc=$?
check test "$rc" -ne 0
check test "$(wc -l < "$LOG_BASE/posts")" -eq 0
check test "$(cat "$LOG_BASE/polish/filed/fluency-spacing-consistency.attempted")" = 'existing attempt'
unset -f _polish_render_issue_body
eval "$(declare -f original_polish_render_issue_body | sed '1s/original_polish_render_issue_body/_polish_render_issue_body/')"
unset -f original_polish_render_issue_body
# A failed write may leave nonempty bytes; a failed rename must not publish
# a receipt either. Both outcomes stay reserved until independent reconciliation.
for receipt_failure in partial-write short-write promote; do
  LOG_BASE="$FIXTURE/$receipt_failure" SUMMARY_FILE="$FIXTURE/$receipt_failure/summary.json"
  MAX_ISSUES='' GLOBAL_ISSUES_CREATED=0 REPOLENS_FINAL_STATE=finished
  mkdir -p "$LOG_BASE/polish"
  : > "$LOG_BASE/posts"
  init_summary "$SUMMARY_FILE" probe "$FIXTURE" polish mock '' '' github ''
  printf '[{"domain":"fluency","lens_id":"spacing-consistency","title":"Spacing","body":"Concrete suggestion","voice_fit":"strong","polish_rank_x1000":1500}]\n' > "$LOG_BASE/polish/ranked-suggestions.json"
  printf() {
    if [[ "$receipt_failure" == *-write && "${FUNCNAME[1]:-}" == run_polish_issue_emission && "${2:-}" == https://github.com/fixture/repo/issues/* ]]; then
      builtin printf 'https://github.com/fixture/repo/issues/'
      [[ "$receipt_failure" == short-write ]]
      return $?
    fi
    # shellcheck disable=SC2059 # Transparent wrapper forwards caller format and arguments.
    builtin printf "$@"
  }
  mv() {
    if [[ "$receipt_failure" == promote && "${*: -1}" == *.url ]]; then return 1; fi
    command mv "$@"
  }
  rc=0
  run_polish_issue_emission probe 3 || rc=$?
  unset -f printf mv
  check test "$rc" -ne 0
  check test "$(wc -l < "$LOG_BASE/posts")" -eq 1
  check test ! -s "$LOG_BASE/polish/filed/fluency-spacing-consistency.url"
  check test -e "$LOG_BASE/polish/filed/fluency-spacing-consistency.attempted"
  check test "$(find "$LOG_BASE/polish/filed" -name '*.tmp.*' | wc -l)" -eq 0
  for retry_case in same changed empty; do
    case "$retry_case" in
      changed) printf '[{"domain":"fluency","lens_id":"new-lens","title":"Other","body":"Suggestion","voice_fit":"strong","polish_rank_x1000":1500}]\n' > "$LOG_BASE/polish/ranked-suggestions.json" ;;
      empty) printf '[]\n' > "$LOG_BASE/polish/ranked-suggestions.json" ;;
    esac
    GLOBAL_ISSUES_CREATED=0
    rc=0
    run_polish_issue_emission probe 3 || rc=$?
    check test "$rc" -ne 0
    check test "$(wc -l < "$LOG_BASE/posts")" -eq 1
    check test "$GLOBAL_ISSUES_CREATED" -eq 0
    check test "$(jq .totals.issues_created "$SUMMARY_FILE")" -eq 0
  done
  printf 'receipt failure %s: probes complete\n' "$receipt_failure"
done
# Deliver real signals to the sequential CLI handler after reservation and
# before POST. DEBUG observes the file in the parent without a production hook.
for signal in HUP INT TERM; do
  LOG_BASE="$FIXTURE/reserved-$signal" SUMMARY_FILE="$FIXTURE/reserved-$signal/summary.json"
  MAX_ISSUES=1 GLOBAL_ISSUES_CREATED=0 REPOLENS_FINAL_STATE=finished
  mkdir -p "$LOG_BASE/polish"
  : > "$LOG_BASE/posts"
  init_summary "$SUMMARY_FILE" probe "$FIXTURE" polish mock '' 1 github ''
  printf '[{"domain":"fluency","lens_id":"spacing-consistency","title":"Spacing","body":"Concrete suggestion","voice_fit":"strong","polish_rank_x1000":1500}]\n' > "$LOG_BASE/polish/ranked-suggestions.json"
  rc=0
  (
    parent_pid=$BASHPID
    trap '_handle_hangup' HUP
    trap '_handle_interrupt' INT
    trap '_handle_termination' TERM
    set -T
    trap 'if [[ "$BASHPID" == "$parent_pid" && -n "${attempted:-}" && -e "$attempted" && "${REPOLENS_FINAL_STATE:-}" != interrupted ]]; then kill -s "$signal" "$parent_pid"; fi' DEBUG
    run_polish_issue_emission probe 3
  ) || rc=$?
  expected=143
  case "$signal" in HUP) expected=129 ;; INT) expected=130 ;; esac
  check test "$rc" -eq "$expected"
  check test "$(wc -l < "$LOG_BASE/posts")" -eq 0
  check test ! -e "$LOG_BASE/polish/filed/fluency-spacing-consistency.attempted"
  check test ! -e "$LOG_BASE/polish/filed/fluency-spacing-consistency.url"
  check test "$(jq .totals.issues_created "$SUMMARY_FILE")" -eq 0
  GLOBAL_ISSUES_CREATED=0 REPOLENS_FINAL_STATE=finished
  rc=0
  run_polish_issue_emission probe 3 || rc=$?
  check test "$rc" -eq 0
  check test "$(wc -l < "$LOG_BASE/posts")" -eq 1
  check test "$(jq .totals.issues_created "$SUMMARY_FILE")" -eq 1
  printf 'cancelled fresh reservation %s: released and resumed\n' "$signal"
done
printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
