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

# repolens-r12-p4-1/p6-1: projected metadata must share one root mapping.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/core.sh"
source "$ROOT/lib/rounds.sh"
source "$ROOT/lib/summary.sh"
source "$ROOT/lib/ledger.sh"
source "$ROOT/lib/artifacts.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
PASS=0 FAIL=0
# Accumulate assertion failures; return the final suite status at the end.
check() { if "$@"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$*" >&2; fi; }
MODE=bugreport LOCAL_MODE=true ROUNDS=1 RUN_ID=probe REPOLENS_MIN_SEVERITY=high
for scenario in plain indent2 indent4 comment-indent2 spaced-owned no-final-newline; do
  indent=0 key='title:'
  case "$scenario" in indent2|comment-indent2) indent=2;; indent4) indent=4;; spaced-owned) indent=2; key='title :';; esac
  prefix="$(printf '%*s' "$indent" '')"
  case_dir="$TMP/$scenario"
  LOG_BASE="$case_dir/run" OUTPUT_DIR="$case_dir/output" SUMMARY_FILE="$LOG_BASE/summary.json"
  source_dir="$LOG_BASE/rounds/round-1/lens-outputs"
  mkdir -p "$source_dir" "$OUTPUT_DIR"
  printf '%s\n' '{"lens_ids":["generic/probe"]}' > "$LOG_BASE/rounds/round-1/metadata.json"
  printf '## hypothesis\nImportant high finding\n## evidence\nsrc/a.sh:1\ntitle: literal body text\n' > "$case_dir/body"
  if [[ "$scenario" == no-final-newline ]]; then
    printf '## hypothesis\nImportant high finding\n## evidence\nsrc/a.sh:1\ntitle: literal body text' > "$case_dir/body"
  fi
  cp "$case_dir/body" "$case_dir/expected-body"
  if [[ "$scenario" == no-final-newline ]]; then
    printf '\n' >> "$case_dir/expected-body"
  fi
  {
    printf -- '---\n'
    [[ "$scenario" != comment-indent2 ]] || printf '# Preserve this root-level comment: unchanged\n'
    printf '%sprovenance:\n%s  title: Earlier finding\n%s  severity: low\n%s  generic_source_id: nested-marker\n' "$prefix" "$prefix" "$prefix" "$prefix"
    printf '%s%s Important high finding\n%sdomain: generic\n%slens_id: probe\n%sseverity: high\n%stype: security-vulnerability\n%scomplexity: 3\n%sconfidence: high\n' "$prefix" "$key" "$prefix" "$prefix" "$prefix" "$prefix" "$prefix" "$prefix"
    printf -- '---\n'
    cat "$case_dir/body"
  } > "$source_dir/probe.md"
  source_hash="$(cksum < "$source_dir/probe.md")"
  check init_summary "$SUMMARY_FILE" probe "$TMP" bugreport mock '' '' local "$OUTPUT_DIR"
  check build_findings_jsonl_from_local "$source_dir" "$case_dir/raw.jsonl"
  check jq -se 'length==1 and .[0].severity=="high" and .[0].type=="security-vulnerability" and .[0].complexity==3' "$case_dir/raw.jsonl"
  check export_generic_local_findings "$OUTPUT_DIR"
  check build_finding_registry "$RUN_ID" "$OUTPUT_DIR" false
  registry="$LOG_BASE/final/findings.jsonl"
  check test -s "$registry"
  check jq -se 'length==1 and .[0].title=="Important high finding" and .[0].severity=="high" and .[0].type=="security-vulnerability" and .[0].complexity==3 and .[0].domain=="generic" and .[0].lens=="probe"' "$registry"
  check test -s "$LOG_BASE/final/findings.csv"
  check generate_todo_md "$registry" "$LOG_BASE/final/TODO.md"
  check generate_summary_md "$registry" "$LOG_BASE/final/SUMMARY.md"
  check grep -Fq 'Important high finding' "$LOG_BASE/final/TODO.md"
  check grep -Fq 'Important high finding' "$LOG_BASE/final/SUMMARY.md"
  check test "$source_hash" = "$(cksum < "$source_dir/probe.md")"
  projection='' rc=0
  projection="$(find "$OUTPUT_DIR" -type f -name '*.md' -print)" || rc=$?
  check test "$rc" -eq 0
  check test -f "$projection"
  if [[ -f "$projection" ]]; then
    projection_hash="$(cksum < "$projection")"
    # Compare actual bytes: line-oriented extraction would hide a missing LF.
    python3 - "$projection" "$case_dir/projected-body" <<'PYBODY'
from pathlib import Path
import sys
Path(sys.argv[2]).write_bytes(Path(sys.argv[1]).read_bytes().split(b"\n---\n", 1)[1])
PYBODY
    check cmp "$case_dir/expected-body" "$case_dir/projected-body"
    check test "$(grep -Ec '^[[:space:]]*title[[:space:]]*:' "$projection")" -eq 3
    # One canonical title, one nested title, and one literal body line remain.
    check grep -Fxq '  title: Earlier finding' "$projection"
    check grep -Fxq '  severity: low' "$projection"
    if [[ "$scenario" == comment-indent2 ]]; then
      check grep -Fxq '# Preserve this root-level comment: unchanged' "$projection"
    fi
    check export_generic_local_findings "$OUTPUT_DIR"
    check test "$projection_hash" = "$(cksum < "$projection")"
    check build_finding_registry "$RUN_ID" "$OUTPUT_DIR" false
  fi
done
printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
