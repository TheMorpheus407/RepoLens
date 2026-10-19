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


# Regression for repolens-r15-p5-2: CSV targets are exact paths, never containers.
set -euo pipefail
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# Source only ledger: the public registry and CSV entry points stay standalone.
# shellcheck source=lib/ledger.sh
source "$REPO/lib/ledger.sh"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
failures=0
check() {
  local description="$1"
  shift
  if "$@"; then printf 'PASS: %s\n' "$description";
  else printf 'FAIL: %s\n' "$description"; failures=$((failures + 1)); fi
}
for kind in directory directory-link; do
  for content in empty finding; do
    LOG_BASE="$fixture/$kind-$content"
    mkdir -p "$LOG_BASE/final" "$LOG_BASE/obstruction"
    printf 'keep obstruction bytes\n' > "$LOG_BASE/obstruction/sentinel"
    if [[ "$kind" == directory ]]; then
      mv "$LOG_BASE/obstruction" "$LOG_BASE/final/findings.csv"
      obstruction="$LOG_BASE/final/findings.csv"
    else
      ln -s "$LOG_BASE/obstruction" "$LOG_BASE/final/findings.csv"
      obstruction="$LOG_BASE/obstruction"
    fi
    if [[ "$content" == empty ]]; then
      printf '[]\n' > "$LOG_BASE/final/manifest.json"
      expected=0
    else
      printf '%s\n' '[{"cluster_id":"one","title":"Current finding","severity":"high","domain":"security","lens":"injection"}]' > "$LOG_BASE/final/manifest.json"
      expected=1
    fi
    rc=0
    build_finding_registry probe '' > "$LOG_BASE/attempt.log" 2>&1 || rc=$?
    check "$kind/$content: registry rejects obstructed CSV" test "$rc" -ne 0
    check "$kind/$content: CSV failure reaches real caller" grep -Fq 'csv projection failed' "$LOG_BASE/attempt.log"
    check "$kind/$content: obstruction content preserved" grep -Fxq 'keep obstruction bytes' "$obstruction/sentinel"
    check "$kind/$content: no candidate nested in obstruction" test "$(find "$obstruction" -type f | wc -l | tr -d ' ')" -eq 1
    check "$kind/$content: failed stage removed" test "$(find "$LOG_BASE/final" -maxdepth 1 -name 'findings.csv.tmp.*' | wc -l | tr -d ' ')" -eq 0
    # Remove only this failed attempt's misplaced fixture candidate after assertions.
    rm -f -- "$obstruction/findings.csv.tmp.$$"
    if [[ "$kind" == directory ]]; then
      rm -- "$obstruction/sentinel"
      rmdir -- "$obstruction"
    else
      check "$kind/$content: symlink preserved" test -L "$LOG_BASE/final/findings.csv"
      rm -- "$LOG_BASE/final/findings.csv"
    fi
    build_finding_registry probe ''
    check "$kind/$content: retry publishes regular CSV" test -f "$LOG_BASE/final/findings.csv"
    check "$kind/$content: retry publishes exact row count" python3 -B - "$LOG_BASE/final/findings.csv" "$expected" <<'PYCHECK'
import csv
import sys
from pathlib import Path
with Path(sys.argv[1]).open(newline='') as stream:
    rows = list(csv.DictReader(stream))
assert len(rows) == int(sys.argv[2]), rows
if rows:
    assert rows[0]['title'] == 'Current finding', rows
PYCHECK
  done
done
printf 'Results: %s failed\n' "$failures"
[[ "$failures" -eq 0 ]]
