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


# shellcheck disable=SC2034 # Production functions consume fixture globals.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Reuse setup and the production finalization callback, without running scenarios.
# shellcheck source=/dev/null
source <(awk '/^LOG_BASE=/ {exit} /^REPO=/ {next} {print}' "$REPO/tests/test_generic_explicit_output.sh")
for scenario in ${1:-severity invalid trust overlap large strings private-discovery rounds-dangling rounds-loop rounds-file rounds-before-find rounds-during-find}; do
  LOG_BASE="$FIXTURE/$scenario/run" OUTPUT_DIR="$FIXTURE/$scenario/output"
  OUTPUT_DIR_SET=true RUN_ID=probe MODE=bugreport LOCAL_MODE=true HUMAN_REVIEW=true
  PROJECT_PATH="$FIXTURE/project" REPOLENS_FINAL_STATE=finished
  SUMMARY_FILE="$LOG_BASE/summary.json"
  rawdir="$LOG_BASE/rounds/round-1/lens-outputs"
  mkdir -p "$rawdir" "$OUTPUT_DIR" "$LOG_BASE/final" "$PROJECT_PATH"
  init_summary "$SUMMARY_FILE" probe "$PROJECT_PATH" bugreport mock '' '' local "$OUTPUT_DIR"
  printf '%s\n' '{"lens_ids":["generic/probe|deeper|check||"]}' > "$LOG_BASE/rounds/round-1/metadata.json"
  raw="$rawdir/probe.md"
  printf -- '---\ndomain: generic\nlens_id: probe\nseverity: high\n---\n## hypothesis\nAccepted finding\n## evidence\nEvidence retained.\n' > "$raw"
  case "$scenario" in
    rounds-*)
      # repolens-r16-p9-1: initialize a valid symlink layout before its outage.
      rounds_store="$FIXTURE/$scenario/rounds-store"
      mv "$LOG_BASE/rounds" "$rounds_store"
      ln -s "$rounds_store" "$LOG_BASE/rounds"
      RUN_ROUNDS_RC=0
      optional_local_finalization
      projection="$(jq -r .markdown_path "$LOG_BASE/final/findings.jsonl")"
      kept_paths=("$projection" "$LOG_BASE/final/"{generic-delivery.json,findings.jsonl,findings.csv,TODO.md,SUMMARY.md,NEEDS_REVIEW.md,DUPLICATES.md,HUMAN_REVIEW.md})
      before="$(sha256sum "${kept_paths[@]}")"
      case "$scenario" in
        rounds-dangling) mv "$rounds_store" "$rounds_store.offline" ;;
        rounds-loop) rm "$LOG_BASE/rounds"; ln -s rounds "$LOG_BASE/rounds" ;;
        rounds-file) rm "$LOG_BASE/rounds"; printf 'obstruction\n' > "$LOG_BASE/rounds" ;;
      esac
      # Lose a previously observed target just before find traverses it. GNU
      # find -H succeeds with no matches on the now-dangling command-line link.
      # shellcheck disable=SC2329 # The production inventory invokes this callback.
      find() {
        # Ordinary inventory runs after presence was observed but before the
        # rounds listing. Removing the link must still fail, not skip that list.
        if [[ "$scenario" == rounds-before-find && "${1:-}" == -H && "${2:-}" == "$OUTPUT_DIR" ]]; then
          command rm "$LOG_BASE/rounds" || return 1
        fi
        if [[ "$scenario" == rounds-during-find && "${1:-}" == -H && "${2:-}" == "$LOG_BASE/rounds" ]]; then
          command mv "$rounds_store" "$rounds_store.offline" || return 1
        fi
        command find "$@"
      }
      # The real CLI finalizer attempts delivery even after an earlier failure.
      RUN_ROUNDS_RC=1 REPOLENS_FINAL_STATE=failed
      optional_local_finalization > "$LOG_BASE/outage.stdout" 2> "$LOG_BASE/outage.stderr"
      test "$(sha256sum "${kept_paths[@]}")" = "$before"
      grep -Fq 'Generic delivery incomplete' "$LOG_BASE/outage.stderr"
      test "$GLOBAL_ISSUES_CREATED" -eq 1
      unset -f find
      if [[ -d "$rounds_store.offline" ]]; then mv "$rounds_store.offline" "$rounds_store"; fi
      rm -f "$LOG_BASE/rounds"
      ln -s "$rounds_store" "$LOG_BASE/rounds"
      RUN_ROUNDS_RC=0 REPOLENS_FINAL_STATE=finished
      optional_local_finalization
      test "$(sha256sum "${kept_paths[@]}")" = "$before"
      jq -se 'length == 1 and .[0].title == "Accepted finding"' "$LOG_BASE/final/findings.jsonl" >/dev/null
      # A readable inventory that really became empty still retires delivery.
      rm "$raw"
      optional_local_finalization
      test "$GLOBAL_ISSUES_CREATED" -eq 0
      test ! -e "$projection"
      jq -se 'length == 0' "$LOG_BASE/final/findings.jsonl" >/dev/null
      ;;
    severity|invalid|trust)
      sed -e 's/Accepted finding/Rejected finding/' -e 's/severity: high/severity: low/' "$raw" > "$rawdir/rejected.md"
      if [[ "$scenario" == severity ]]; then
        REPOLENS_MIN_SEVERITY=high
      elif [[ "$scenario" == invalid ]]; then
        sed -i 's/severity: low/severity: nonsensical/' "$rawdir/rejected.md"
        sed '/severity:/d' "$rawdir/rejected.md" > "$rawdir/missing.md"
      else
        sed -i 's/lens_id: probe/lens_id: never-dispatched/' "$rawdir/rejected.md"
        # The same identity is trusted in round 1, but not in round 2.
        mkdir -p "$LOG_BASE/rounds/round-2/lens-outputs"
        cp "$raw" "$LOG_BASE/rounds/round-2/lens-outputs/probe.md"
        printf '%s\n' '{"lens_ids":[]}' > "$LOG_BASE/rounds/round-2/metadata.json"
      fi
      optional_local_finalization
      jq -sc '{rows:length,titles:map(.title),severities:map(.severity)}' "$LOG_BASE/final/findings.jsonl"
      jq -se 'length == 1 and .[0].title == "Accepted finding" and .[0].severity == "high"' "$LOG_BASE/final/findings.jsonl" >/dev/null
      if grep -q 'Rejected finding' "$LOG_BASE/final/TODO.md"; then exit 1; fi
      unset REPOLENS_MIN_SEVERITY
      ;;
    overlap)
      OUTPUT_DIR="$rawdir"
      before="$(sha256sum "$raw")"
      for attempt in 1 2 3; do
        optional_local_finalization
        jq -sc '{rows:length,titles:map(.title)}' "$LOG_BASE/final/findings.jsonl"
        jq -se 'length == 1 and .[0].title == "Accepted finding"' "$LOG_BASE/final/findings.jsonl" >/dev/null
        test "$(find "$OUTPUT_DIR/generic" -name '*.md' | wc -l)" -eq 1
        test "$(sha256sum "$raw")" = "$before"
      done
      ;;
    private-discovery)
      OUTPUT_DIR="$rawdir"
      optional_local_finalization
      rm "$raw"
      # Generated-only trees must not trigger verifier/synthesizer agent work.
      run_agent() { echo 'Unexpected private discovery callback' >&2; return 1; }
      _VERIFIER_AGENT_CALLBACK=run_agent
      run_verifier "$RUN_ID"
      jq -e 'length == 0' "$LOG_BASE/final/verification.json" >/dev/null
      run_synthesizer "$RUN_ID"
      jq -e 'length == 0' "$LOG_BASE/final/manifest.json" >/dev/null
      ;;
    strings)
      expected='Café: $HOME `cmd` "quotes" 再試行'
      sed -i "2i title: '$expected'" "$raw"
      optional_local_finalization
      jq -se --arg expected "$expected" 'length == 1 and .[0].title == $expected' "$LOG_BASE/final/findings.jsonl" >/dev/null
      grep -Fq '再試行' "$LOG_BASE/final/TODO.md"
      ;;
    large)
      python3 - "$raw" <<'PYBODY'
from pathlib import Path
import sys
with Path(sys.argv[1]).open('a') as stream:
    stream.write('Full evidence line.\n' * 10000 + 'END OF LARGE EVIDENCE\n')
PYBODY
      optional_local_finalization
      jq -se 'length == 1' "$LOG_BASE/final/findings.jsonl" >/dev/null
      delivered="$(jq -r .markdown_path "$LOG_BASE/final/findings.jsonl")"
      grep -Fq 'END OF LARGE EVIDENCE' "$delivered"
      python3 - "$raw" "$delivered" <<'PYCOMPARE'
from pathlib import Path
import sys
body = lambda path: Path(path).read_text().split('\n---\n', 1)[1]
assert body(sys.argv[1]) == body(sys.argv[2])
PYCOMPARE
      ;;
  esac
  printf 'Generic delivery edge passed: %s\n' "$scenario"
done
