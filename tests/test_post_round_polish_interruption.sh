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

# repolens-r2-p1-1: stop polish emission and verifier after parent signals.
# shellcheck disable=SC2034,SC2329 # Extracted production blocks consume globals.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)" || exit 1
trap 'rm -rf "$TEST_DIR"' EXIT
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/parallel.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/polish.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/verify.sh"
sed -n '/^# --- Polish ranking (post-rounds/,/^# --- Synthesizer (post-rounds/p' \
  "$SCRIPT_DIR/repolens.sh" | sed '$d' > "$TEST_DIR/phases.sh"
parallel_preflight() { _REPOLENS_SCOPE_READY=1; _REPOLENS_SCOPE_FAILED=0; }
# Inject signals after the caller predicate but before helper entry.
log_info() {
  case "$row/$*" in
    emission-entry/'Polish issue emission: filing ranked lens shortlists'|verifier-entry/'Verifier: re-reading cited code locations for evidence accuracy') interrupt_parent ;;
  esac
}
log_warn() { :; }
die() { printf 'Unexpected fatal error: %s\n' "$*" >&2; exit 1; }
interrupt_parent() { kill -s "$SIGNAL" "$FINALIZER_PID"; }
run_polish_ranking() {
  printf 'rank\n' >> "$LOG_BASE/ranking-calls"
  if [[ "$row" == ranking-* ]]; then interrupt_parent; fi
  [[ "$row" != ranking-fail && "$row" != normal-ranking-fail ]]
}
# Keep real rendering while controlling its completion boundary.
eval "$(declare -f _polish_render_issue_body | sed '1s/_polish_render_issue_body/render_issue_body_real/')"
_polish_render_issue_body() {
  printf 'render\n' >> "$LOG_BASE/renders"
  case "$row" in render-*|local-render) interrupt_parent ;; esac
  [[ "$row" != render-fail && "$row" != normal-render-fail ]] || return 1
  render_issue_body_real "$@"
}
forge_issue_create() {
  printf 'post\n' >> "$LOG_BASE/posts"
  case "$row" in post-*) interrupt_parent ;; esac
  [[ "$row" != post-fail && "$row" != normal-post-fail ]] || return 1
  printf 'https://github.com/o/r/issues/1\n'
}
compose_prompt() {
  case "$row" in verifier-compose*) interrupt_parent ;; esac
  printf 'mock verifier prompt'
}
run_agent() { printf 'verify\n' >> "$LOG_BASE/agents"; printf '[]\n'; }
passed=0 failed=0
check_eq() {
  if [[ "$2" == "$3" ]]; then passed=$((passed + 1));
  else failed=$((failed + 1)); printf 'FAIL %s: expected [%s], got [%s]\n' "$1" "$2" "$3"; fi
}
FINALIZER_PID="$BASHPID"
for SIGNAL in INT TERM; do
  for row in before-ranking ranking-ok ranking-fail before-verifier emission-entry render-ok render-fail local-render post-ok post-fail verifier-entry verifier-compose verifier-compose-callback clean disabled-verifier normal-ranking-fail normal-render-fail normal-post-fail; do
    LOG_BASE="$TEST_DIR/$SIGNAL-$row"
    SUMMARY_FILE="$LOG_BASE/summary.json"
    mkdir -p "$LOG_BASE/polish" "$LOG_BASE/rounds/round-1/lens-outputs"
    printf 'finding\n' > "$LOG_BASE/rounds/round-1/lens-outputs/finding.md"
    printf '[{"domain":"polish","lens_id":"microcopy","title":"Retry","body":"Clearer retry","voice_fit":"strong","polish_rank_x1000":1000},{"domain":"polish","lens_id":"feedback","title":"Feedback","body":"Clearer feedback","voice_fit":"strong","polish_rank_x1000":900}]\n' > "$LOG_BASE/polish/ranked-suggestions.json"
    RUN_ID=probe RUN_ROUNDS_RC=0 REPOLENS_FINAL_STATE=finished MODE=polish
    LOCAL_MODE=false FORGE_REPO_SLUG=o/r NO_VERIFIER=false GLOBAL_ISSUES_CREATED=0
    AGENT=mock PROJECT_PATH="$TEST_DIR" ROUNDS=1
    init_parallel "$LOG_BASE/.semaphore" 1 || exit 1
    _VERIFIER_AGENT_CALLBACK=""
    expected_posts=0 expected_agents=0 expected_rank=1 expected_receipts=0 expected_fatal=0
    expected_state=interrupted expected_signal=130
    [[ "$SIGNAL" != TERM ]] || expected_signal=143
    case "$row" in
      before-ranking) interrupt_parent; expected_rank=0 ;;
      before-verifier) MODE=audit; interrupt_parent; expected_rank=0 ;;
      local-render) LOCAL_MODE=true ;;
      post-ok) expected_posts=1; expected_receipts=1 ;;
      post-fail) expected_posts=1 ;;
      verifier-*) MODE=audit; expected_rank=0
        [[ "$row" != verifier-compose-callback ]] || _VERIFIER_AGENT_CALLBACK=run_agent ;;
      clean) expected_posts=2; expected_receipts=2; expected_agents=1; expected_state=finished ;;
      disabled-verifier) NO_VERIFIER=true; expected_posts=2; expected_receipts=2; expected_state=finished ;;
      normal-*) expected_fatal=1; expected_state=finished
        [[ "$row" != normal-post-fail ]] || expected_posts=1 ;;
    esac
    # Ordinary errors stay fatal; interrupted errors must reach finalization.
    if (( expected_fatal )); then
      phase_rc=0
      # shellcheck source=/dev/null
      ( source "$TEST_DIR/phases.sh" ) > "$LOG_BASE/fatal-output" 2>&1 || phase_rc=$?
      check_eq "$SIGNAL/$row fatal exit" 1 "$phase_rc"
      check_eq "$SIGNAL/$row fatal message" 1 "$(grep -c 'Unexpected fatal error: Polish' "$LOG_BASE/fatal-output" || true)"
    else
      # shellcheck source=/dev/null
      source "$TEST_DIR/phases.sh"
    fi
    check_eq "$SIGNAL/$row state" "$expected_state" "$REPOLENS_FINAL_STATE"
    if [[ "$expected_state" == interrupted ]]; then
      check_eq "$SIGNAL/$row signal exit" "$expected_signal" "$REPOLENS_INTERRUPT_EXIT_CODE"
    fi
    receipts=$(find "$LOG_BASE/polish" -name '*.url' -type f | wc -l)
    check_eq "$SIGNAL/$row receipts" "$expected_receipts" "$receipts"
    check_eq "$SIGNAL/$row issue count" "$expected_receipts" "$GLOBAL_ISSUES_CREATED"
    check_eq "$SIGNAL/$row temporary groups" 0 "$(find "$LOG_BASE/polish" -name 'issue-groups*.tmp.*' | wc -l)"
    for kind in ranking-calls posts agents; do
      calls=0
      if [[ -f "$LOG_BASE/$kind" ]]; then calls="$(wc -l < "$LOG_BASE/$kind")"; fi
      case "$kind" in
        ranking-calls) expected="$expected_rank" ;;
        posts) expected="$expected_posts" ;;
        agents) expected="$expected_agents" ;;
      esac
      check_eq "$SIGNAL/$row/$kind" "$expected" "$calls"
    done
  done
done
trap - INT TERM
printf 'Results: %s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
