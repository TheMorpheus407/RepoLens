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
set -uo pipefail
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
log_info() { :; }
log_warn() { :; }
die() { printf 'Unexpected fatal error: %s\n' "$*" >&2; exit 1; }
interrupt_parent() { kill -s "$SIGNAL" "$FINALIZER_PID"; }
run_polish_ranking() {
  printf 'rank\n' >> "$LOG_BASE/ranking-calls"
  if [[ "$row" == ranking-* ]]; then interrupt_parent; fi
  [[ "$row" != ranking-fail && "$row" != normal-ranking-fail ]]
}
forge_issue_create() { printf 'post\n' >> "$LOG_BASE/posts"; printf 'https://github.com/o/r/issues/1\n'; }
_polish_increment_issue_counts() { return 0; }
compose_prompt() { printf 'mock verifier prompt'; }
run_agent() { printf 'verify\n' >> "$LOG_BASE/agents"; printf '[]\n'; }
passed=0 failed=0
check_eq() {
  if [[ "$2" == "$3" ]]; then passed=$((passed + 1));
  else failed=$((failed + 1)); printf 'FAIL %s: expected [%s], got [%s]\n' "$1" "$2" "$3"; fi
}
FINALIZER_PID="$BASHPID"
for SIGNAL in INT TERM; do
  for row in before-ranking ranking-ok ranking-fail before-verifier clean disabled-verifier; do
    LOG_BASE="$TEST_DIR/$SIGNAL-$row"
    SUMMARY_FILE="$LOG_BASE/summary.json"
    mkdir -p "$LOG_BASE/polish" "$LOG_BASE/rounds/round-1/lens-outputs"
    printf 'finding\n' > "$LOG_BASE/rounds/round-1/lens-outputs/finding.md"
    printf '[{"domain":"polish","lens_id":"microcopy","title":"Retry","body":"Clearer retry","voice_fit":"strong","polish_rank_x1000":1000}]\n' > "$LOG_BASE/polish/ranked-suggestions.json"
    RUN_ID=probe RUN_ROUNDS_RC=0 REPOLENS_FINAL_STATE=finished MODE=polish
    LOCAL_MODE=false FORGE_REPO_SLUG=o/r NO_VERIFIER=false
    AGENT=mock PROJECT_PATH="$TEST_DIR" ROUNDS=1
    init_parallel "$LOG_BASE/.semaphore" 1 || exit 1
    expected_posts=0 expected_agents=0 expected_rank=1
    case "$row" in
      before-ranking) interrupt_parent; expected_rank=0 ;;
      before-verifier) MODE=audit; interrupt_parent; expected_rank=0 ;;
      clean) expected_posts=1; expected_agents=1 ;;
      disabled-verifier) NO_VERIFIER=true; expected_posts=1 ;;
    esac
    # A fatal ranking error on an interrupted run is also a regression.
    # shellcheck source=/dev/null
    source "$TEST_DIR/phases.sh"
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
