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
for scenario in ${1:-severity invalid trust overlap large strings private-discovery}; do
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
      if rg -q 'Rejected finding' "$LOG_BASE/final/TODO.md"; then exit 1; fi
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
