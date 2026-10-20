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

# repolens-r10-p3-1: IO failures in a private finding snapshot are fatal.
# shellcheck disable=SC2034 # Registry reads LOG_BASE from the fixture.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO/lib/ledger.sh"
set -euo pipefail
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
LOG_BASE="$FIXTURE/run"
fail_duplicate_read=false duplicate_read_rc=2
# Intercept only the duplicate-presence predicate, mark its execution, optionally
# emit real jq output, then return the injected failure; forward all other calls.
jq() {
  if [[ "$fail_duplicate_read" == true && " $* " == *'any(.[]; .status == "duplicate")'* ]]; then
    : > "$FIXTURE/duplicate-read-reached"
    [[ "$partial" != true ]] || command jq "$@"
    return "$duplicate_read_rc"
  fi
  command jq "$@"
}
mkdir -p "$FIXTURE/findings" "$LOG_BASE/final"
printf -- '---\ntitle: Saved authorization finding\nseverity: high\ndomain: security\nlens: injection\nstatus: duplicate\nduplicate_of: missing.md\n---\nEvidence\n' > "$FIXTURE/findings/001.md"
build_finding_registry fixture "$FIXTURE/findings"
cp "$LOG_BASE/final/findings.jsonl" "$FIXTURE/before.jsonl"
cp "$LOG_BASE/final/findings.csv" "$FIXTURE/before.csv"
jq -se 'length == 1' "$FIXTURE/before.jsonl" >/dev/null
PASS=0 FAIL=0
# Count assertions without interrupting the remaining independent fault cases.
check() {
  local desc="$1"; shift
  if "$@"; then PASS=$((PASS + 1))
  else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$desc"; fi
}
# Real EACCES after a successful copy, plus deterministic EIO at each reader.
# No product command, source file or other checkout is modified.
fail_reader=none partial=false
# Copy normally, then revoke access only to the completed private snapshot.
cat() {
  command cat "$@" || return $?
  if [[ "$fail_reader" == permission && "${!#}" == "$FIXTURE/findings/001.md" ]]; then
    local destination reader_pid="$BASHPID"
    destination="$(readlink "/proc/$reader_pid/fd/1")" || return 1
    chmod 000 "$destination"
  fi
}
# Inject reader errors, retaining real EACCES when mode bits prevent reading.
awk() {
  if [[ "${!#}" == *.source.* ]]; then
    if [[ "$fail_reader" == permission && -r "${!#}" ]]; then
      printf 'snapshot remains readable after chmod; injecting reader failure\n' >&2
      return 2
    fi
    if [[ "$fail_reader" == duplicate_receipt && "${FUNCNAME[1]:-}" == _ledger_local_duplicate_receipt ]]; then
      : > "$FIXTURE/receipt-reader-reached"
      [[ "$partial" != true ]] || command awk "$@"
      return 2
    fi
    if [[ "$fail_reader" == frontmatter && "${1:-}" != -v ]] \
        || [[ "${1:-}" == -v && "${2:-}" == "key=$fail_reader" ]] \
        || [[ "$fail_reader" == generic_title && "${2:-}" == key=title \
              && "${FUNCNAME[2]:-}" == build_findings_jsonl_from_local ]]; then
      [[ "$partial" != true ]] || command awk "$@"
      printf 'injected snapshot read error\n' >&2
      return 2
    fi
  fi
  command awk "$@"
}
for fail_reader in permission frontmatter title severity domain lens type status duplicate_of complexity generic_source_id; do
  for partial in false true; do
    rc=0
    build_finding_registry fixture "$FIXTURE/findings" > "$FIXTURE/rebuild.log" 2>&1 || rc=$?
    check "$fail_reader (partial=$partial) fails rebuilding" test "$rc" -ne 0
    check "$fail_reader preserves JSONL" cmp -s "$FIXTURE/before.jsonl" "$LOG_BASE/final/findings.jsonl"
    check "$fail_reader preserves CSV" cmp -s "$FIXTURE/before.csv" "$LOG_BASE/final/findings.csv"
    # Restore saved outputs after an expected red-phase failure, so each case
    # independently starts from the last complete publication.
    cp "$FIXTURE/before.jsonl" "$LOG_BASE/final/findings.jsonl"
    cp "$FIXTURE/before.csv" "$LOG_BASE/final/findings.csv"
  done
done
fail_reader=none
build_finding_registry fixture "$FIXTURE/findings"
check 'repaired snapshot rebuild succeeds unchanged' cmp -s "$FIXTURE/before.jsonl" "$LOG_BASE/final/findings.jsonl"

# Generic projections reread the JSON-quoted title after the ordinary scalar
# reads. Fail only that direct reread (the first passes through the trim helper).
printf -- '---\ntitle: "Generic authorization finding"\nseverity: high\ndomain: generic\nlens: investigator\ngeneric_source_id: %064d\n---\nEvidence\n' 0 > "$FIXTURE/findings/002.md"
build_finding_registry fixture "$FIXTURE/findings"
check 'Generic fixture is indexed with its decoded title' jq -se \
  'length == 2 and any(.[]; .domain == "generic" and .title == "Generic authorization finding")' \
  "$LOG_BASE/final/findings.jsonl"
cp "$LOG_BASE/final/findings.jsonl" "$FIXTURE/before.jsonl"
cp "$LOG_BASE/final/findings.csv" "$FIXTURE/before.csv"
fail_reader=generic_title
for partial in false true; do
  rc=0
  build_finding_registry fixture "$FIXTURE/findings" > "$FIXTURE/rebuild.log" 2>&1 || rc=$?
  check "Generic title reread (partial=$partial) fails rebuilding" test "$rc" -ne 0
  check 'Generic title reread preserves JSONL' cmp -s "$FIXTURE/before.jsonl" "$LOG_BASE/final/findings.jsonl"
  check 'Generic title reread preserves CSV' cmp -s "$FIXTURE/before.csv" "$LOG_BASE/final/findings.csv"
  cp "$FIXTURE/before.jsonl" "$LOG_BASE/final/findings.jsonl"
  cp "$FIXTURE/before.csv" "$LOG_BASE/final/findings.csv"
done
fail_reader=none
build_finding_registry fixture "$FIXTURE/findings"
check 'repaired Generic reread succeeds unchanged' cmp -s "$FIXTURE/before.jsonl" "$LOG_BASE/final/findings.jsonl"
# A receipt reader failure is fatal even after emitting a valid duplicate mark.
# Use real owned content; the injected failure is confined to its awk reader.
printf -- '---\ntitle: Saved authorization finding\nseverity: high\ndomain: security\nlens: injection\nstatus: reviewed\nduplicate_of: missing.md\n---\nEvidence\n<!-- repolens-dedupe:begin -->\n<!-- repolens-dedupe:duplicate -->\n<!-- repolens-dedupe:end -->\n' > "$FIXTURE/findings/001.md"
build_finding_registry fixture "$FIXTURE/findings"
cp "$LOG_BASE/final/findings.jsonl" "$FIXTURE/before.jsonl"
cp "$LOG_BASE/final/findings.csv" "$FIXTURE/before.csv"
fail_reader=duplicate_receipt
for partial in false true; do
  rm -f "$FIXTURE/receipt-reader-reached"
  rc=0
  build_finding_registry fixture "$FIXTURE/findings" > "$FIXTURE/rebuild.log" 2>&1 || rc=$?
  check 'receipt fault was reached' test -f "$FIXTURE/receipt-reader-reached"
  check "receipt reader (partial=$partial) fails rebuilding" test "$rc" -ne 0
  check 'receipt error preserves JSONL' cmp -s "$FIXTURE/before.jsonl" "$LOG_BASE/final/findings.jsonl"
  check 'receipt error preserves CSV' cmp -s "$FIXTURE/before.csv" "$LOG_BASE/final/findings.csv"
done
fail_reader=none
build_finding_registry fixture "$FIXTURE/findings"
check 'repaired receipt reader succeeds unchanged' cmp -s "$FIXTURE/before.jsonl" "$LOG_BASE/final/findings.jsonl"
# Empty and malformed-only trees still produce successful empty registries.
rm "$FIXTURE/findings/001.md" "$FIXTURE/findings/002.md"
printf 'ordinary notes without frontmatter\n' > "$FIXTURE/findings/notes.md"
build_finding_registry fixture "$FIXTURE/findings"
check 'readable malformed input stays skippable' test ! -s "$LOG_BASE/final/findings.jsonl"
# A failed duplicate-presence read must not promote valid duplicates to new.
# shellcheck source=/dev/null
source "$REPO/lib/local-dedupe.sh"
for lens in injection validation; do
  mkdir -p "$FIXTURE/findings/security/$lens"
  printf -- '---\ntitle: SQL injection in login query\nseverity: high\ndomain: security\nlens: %s\n---\nIndependent evidence.\n' "$lens" > "$FIXTURE/findings/security/$lens/001.md"
done
dedupe_local_markdown "$FIXTURE/findings"
build_finding_registry fixture "$FIXTURE/findings"
check 'control has one actionable finding and one linked duplicate' jq -se \
  'length == 2 and ([.[] | select(.status == "new")] | length) == 1 and ([.[] | select(.status == "duplicate")] | length) == 1 and any(.[]; (.also_reported_by // [] | length) == 1)' "$LOG_BASE/final/findings.jsonl"
cp "$LOG_BASE/final/findings.jsonl" "$FIXTURE/before.jsonl"
cp "$LOG_BASE/final/findings.csv" "$FIXTURE/before.csv"
fail_duplicate_read=true duplicate_read_rc=2

for duplicate_read_rc in 1 2 74; do
  for partial in false true; do
    rm -f "$FIXTURE/duplicate-read-reached"
    rc=0
    build_finding_registry fixture "$FIXTURE/findings" > "$FIXTURE/rebuild.log" 2>&1 || rc=$?
    check 'duplicate-presence reader fault was reached' test -f "$FIXTURE/duplicate-read-reached"
    check "duplicate read rc=$duplicate_read_rc partial=$partial fails rebuild" test "$rc" -ne 0
    check 'duplicate read preserves JSONL and provenance' cmp -s "$FIXTURE/before.jsonl" "$LOG_BASE/final/findings.jsonl"
    check 'duplicate read preserves CSV' cmp -s "$FIXTURE/before.csv" "$LOG_BASE/final/findings.csv"
    cp "$FIXTURE/before.jsonl" "$LOG_BASE/final/findings.jsonl"
    cp "$FIXTURE/before.csv" "$LOG_BASE/final/findings.csv"
  done
done
fail_duplicate_read=false
build_finding_registry fixture "$FIXTURE/findings"
check 'repaired duplicate read reproduces complete registry' cmp -s "$FIXTURE/before.jsonl" "$LOG_BASE/final/findings.jsonl"
rm "$FIXTURE/findings/security/validation/001.md"
build_finding_registry fixture "$FIXTURE/findings"
check 'readable inventory without duplicates remains publishable' jq -se 'length == 1 and .[0].status == "new"' "$LOG_BASE/final/findings.jsonl"
printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
test "$FAIL" -eq 0
