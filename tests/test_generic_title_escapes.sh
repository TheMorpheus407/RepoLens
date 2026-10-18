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


# Quoted title syntax is presentation, not literal delivered content.
# YAML 1.2.2 sections 5.7 and 7.3.1: https://yaml.org/spec/1.2.2/
# shellcheck disable=SC2034 # Production callbacks consume these globals.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO/lib/core.sh"
# shellcheck source=/dev/null
source "$REPO/lib/rounds.sh"
# shellcheck source=/dev/null
source "$REPO/lib/ledger.sh"
# shellcheck source=/dev/null
source "$REPO/lib/summary.sh"
FIXTURE="$(mktemp -d)" || exit 1
trap 'rm -rf -- "$FIXTURE"' EXIT
# Independent expected strings exercise syntax without requiring a YAML package.
python3 - "$FIXTURE" <<'PYCASES'
from pathlib import Path
import sys
root = Path(sys.argv[1])
cases = [
    (r'"Failure in \"login\" endpoint"', 'Failure in "login" endpoint'),
    (r'"Windows C:\\repo\\src"', r'Windows C:\repo\src'),
    (r'"\u263A \x22login\x22 \U0001F680"', '☺ "login" 🚀'),
    (r'"before\tquoted\nline"', 'before\tquoted\nline'),
    ("'Failure in \\\"login\\\" endpoint'", r'Failure in \"login\" endpoint'),
    (r'Failure in \"login\" endpoint', r'Failure in \"login\" endpoint'),
    (r'"Literal \\n \\\\"', r'Literal \n \\'),
    (r'"Failure in \"login\"" # explanatory comment', 'Failure in "login"'),
    (r'"https:\/\/fixture.invalid\/path"', 'https://fixture.invalid/path'),
]
for number, (raw, expected) in enumerate(cases):
    folder = root / str(number)
    folder.mkdir()
    (folder / 'raw-title').write_text(raw)
    (folder / 'expected').write_text(expected)
PYCASES
failures=0
check() {
  if ! "$@"; then printf 'FAIL: %s\n' "$*" >&2; failures=$((failures+1)); fi
}
for case_dir in "$FIXTURE"/*; do
  LOG_BASE="$case_dir/run" OUTPUT_DIR="$case_dir/output" RUN_ID=title-probe MODE=bugreport ROUNDS=1
  LOCAL_MODE=true OUTPUT_DIR_SET=true SUMMARY_FILE="$LOG_BASE/summary.json" MAX_ISSUES=''
  raw="$LOG_BASE/rounds/round-1/lens-outputs/probe.md"
  mkdir -p "${raw%/*}" "$OUTPUT_DIR"
  init_summary "$SUMMARY_FILE" "$RUN_ID" "$FIXTURE" bugreport mock '' '' local "$OUTPUT_DIR"
  printf '%s\n' '{"lens_ids":["generic/probe"]}' > "$LOG_BASE/rounds/round-1/metadata.json"
  printf -- '---\ndomain: generic\nlens_id: probe\nseverity: high\ntitle: %s\n---\n## hypothesis\nLogin fails\n## evidence\nsrc/login.py:1\n' "$(cat "$case_dir/raw-title")" > "$raw"
  raw_hash="$(sha256sum < "$raw")"
  check export_generic_local_findings "$OUTPUT_DIR"
  check build_findings_jsonl_from_local "$OUTPUT_DIR" "$case_dir/registry.jsonl"
  check jq -se --rawfile expected "$case_dir/expected" 'length == 1 and .[0].title == $expected' "$case_dir/registry.jsonl"
  # Decode the delivered header independently to pin the Markdown projection too.
  check python3 - "$case_dir/registry.jsonl" "$case_dir/expected" <<'PYCHECK'
import json, sys
from pathlib import Path
row = json.loads(Path(sys.argv[1]).read_text())
projection = Path(row['markdown_path']).read_text()
raw_title = projection.splitlines()[1].removeprefix('title: ')
assert json.loads(raw_title) == Path(sys.argv[2]).read_text(), raw_title
PYCHECK
  check test "$(sha256sum < "$raw")" = "$raw_hash"
done
# Invalid or failed decoding cannot retire the previous delivery/ownership.
receipt="$LOG_BASE/final/generic-delivery.json"
receipt_hash="$(sha256sum < "$receipt")"
projection="$(jq -r .markdown_path "$case_dir/registry.jsonl")"
projection_hash="$(sha256sum < "$projection")"
for invalid in '"bad\q"' '"bad\0"' '"bad\uD800"'; do
  printf -- '---\ndomain: generic\nlens_id: probe\nseverity: high\ntitle: %s\n---\n## hypothesis\nLogin fails\n' "$invalid" > "$raw"
  rc=0; export_generic_local_findings "$OUTPUT_DIR" || rc=$?
  check test "$rc" -ne 0
  check test "$(sha256sum < "$receipt")" = "$receipt_hash"
  check test "$(sha256sum < "$projection")" = "$projection_hash"
done
# Inject partial output plus an operational error only in the scalar decoder.
# shellcheck disable=SC2329 # Called indirectly by the sourced scalar helper.
python3() {
  if [[ "${1:-}" == -c && "${2:-}" == *'frontmatter scalar decode failed:'* ]]; then
    touch "$FIXTURE/decoder-fault-reached"
    printf 'partial'
    return 74
  fi
  command python3 "$@"
}
printf -- '---\ndomain: generic\nlens_id: probe\nseverity: high\ntitle: %s\n---\n## hypothesis\nLogin fails\n' "$(cat "$FIXTURE/0/raw-title")" > "$raw"
rc=0; export_generic_local_findings "$OUTPUT_DIR" || rc=$?
check test -f "$FIXTURE/decoder-fault-reached"
check test "$rc" -ne 0
check test "$(sha256sum < "$receipt")" = "$receipt_hash"
check test "$(sha256sum < "$projection")" = "$projection_hash"
unset -f python3
check export_generic_local_findings "$OUTPUT_DIR"
check build_findings_jsonl_from_local "$OUTPUT_DIR" "$case_dir/registry.jsonl"
check jq -se 'length == 1 and .[0].title == "Failure in \"login\" endpoint"' "$case_dir/registry.jsonl"
printf 'Generic title escape assertions: %s failures\n' "$failures"
(( failures == 0 ))
