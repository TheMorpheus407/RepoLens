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

# repolens-r18-p11-1: incomplete input must terminate validation with failure.
# shellcheck disable=SC2034,SC2329
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/lib/ledger.sh"
if [[ "${1:-}" == probe ]]; then
  input="$2" fault="$3" reads=0
  # Model a persistent source IO error for both a direct Bash reader and a
  # checked jq reader. The schema query and production caller stay real.
  read() {
    local fd_path
    fd_path="$(readlink "/proc/$BASHPID/fd/0")"
    if [[ "${FUNCNAME[1]:-}" == validate_findings_jsonl && "$fd_path" == "$input" ]]; then
      if [[ "$fault" == before ]] || (( reads >= 1 )); then
        printf 'injected persistent input read failure\n' >&2
        return 1
      fi
      reads=$((reads + 1))
    fi
    builtin read -r "$@"
  }
  jq() {
    if [[ "${FUNCNAME[1]:-}" == validate_findings_jsonl && "${!#}" == "$input" ]]; then
      if [[ "$fault" != before ]]; then
        local args=("$@")
        args[${#args[@]}-1]=/dev/stdin
        command head -n 1 -- "$input" | command jq "${args[@]}"
      fi
      printf 'injected incomplete validator input\n' >&2
      return 74
    fi
    command jq "$@"
  }
  validate_findings_jsonl "$input"
  exit $?
fi
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
row='{"id":"valid-id","title":"Finding","severity":"high","type":"maintainability","domain":"security","lens":"injection","status":"new","primary_location":"","confidence":null,"duplicate_group":null,"markdown_path":null,"validation":{}}'
printf '%s\n%s\n' "$row" "$row" > "$FIXTURE/findings.jsonl"
validate_findings_jsonl "$FIXTURE/findings.jsonl"
for fault in before after; do
  rc=0
  timeout 2 bash "${BASH_SOURCE[0]}" probe "$FIXTURE/findings.jsonl" "$fault" > "$FIXTURE/$fault.log" 2>&1 || rc=$?
  printf 'fault=%s validator_exit=%s\n' "$fault" "$rc"
  if (( rc == 0 || rc == 124 || rc == 137 )); then
    head -n 2 "$FIXTURE/$fault.log"
    printf 'FAIL: an incomplete source read must fail promptly, before timeout\n' >&2
    exit 1
  fi
done
# Keep empty files, whitespace and the final line without LF valid.
: > "$FIXTURE/empty.jsonl"
validate_findings_jsonl "$FIXTURE/empty.jsonl"
printf ' \n%s' "$row" > "$FIXTURE/no-newline.jsonl"
validate_findings_jsonl "$FIXTURE/no-newline.jsonl"
printf '%s\nnot JSON\n%s\n' "$row" "$row" > "$FIXTURE/invalid.jsonl"
rc=0
validate_findings_jsonl "$FIXTURE/invalid.jsonl" > "$FIXTURE/invalid.log" 2>&1 || rc=$?
test "$rc" -ne 0
grep -q 'line 2:' "$FIXTURE/invalid.log"
# The same read failure must not promote a partially validated registry.
LOG_BASE="$FIXTURE/run"
mkdir -p "$LOG_BASE/final"
printf '[{"cluster_id":"old","title":"Saved finding","severity":"high","domain":"security","lens":"injection"}]\n' > "$LOG_BASE/final/manifest.json"
jq() {
  if [[ "${FUNCNAME[1]:-}" == validate_findings_jsonl && "${validator_fault:-}" != '' ]]; then
    : > "$FIXTURE/validator-read-reached"
    if [[ "$validator_fault" == after ]]; then
      local args=("$@")
      args[${#args[@]}-1]=/dev/stdin
      command head -n 1 -- "${!#}" | command jq "${args[@]}"
    fi
    return 74
  fi
  command jq "$@"
}
build_finding_registry fixture
jsonl_hash="$(sha256sum < "$LOG_BASE/final/findings.jsonl")"
csv_hash="$(sha256sum < "$LOG_BASE/final/findings.csv")"
printf '[{"cluster_id":"new","title":"Replacement finding","severity":"high","domain":"security","lens":"injection"}]\n' > "$LOG_BASE/final/manifest.json"

for validator_fault in before after; do
  rm -f "$FIXTURE/validator-read-reached"
  rc=0
  build_finding_registry fixture > "$FIXTURE/registry-$validator_fault.log" 2>&1 || rc=$?
  test "$rc" -ne 0
  test -f "$FIXTURE/validator-read-reached"
  test "$(sha256sum < "$LOG_BASE/final/findings.jsonl")" = "$jsonl_hash"
  test "$(sha256sum < "$LOG_BASE/final/findings.csv")" = "$csv_hash"
  test "$(find "$LOG_BASE/final" -name '*.tmp.*' | wc -l)" -eq 0
  grep -q 'cannot read findings.jsonl' "$FIXTURE/registry-$validator_fault.log"
done
validator_fault=''
build_finding_registry fixture
command jq -se 'length == 1 and .[0].title == "Replacement finding"' "$LOG_BASE/final/findings.jsonl" > /dev/null
printf 'Results: incomplete validation fails promptly; registry preserved and retry succeeds\n'
