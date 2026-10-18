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

# Regression: repolens-r14-p2-1. Failed identities must never collapse records.
# shellcheck disable=SC2317,SC2329
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/lib/ledger.sh"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
FAIL=0
check() {
  if "$@"; then printf 'PASS: %s\n' "$*"; else printf 'FAIL: %s\n' "$*"; FAIL=$((FAIL + 1)); fi
}
LOG_BASE="$fixture/logs"
OUTPUT_DIR="$fixture/local"
mkdir -p "$OUTPUT_DIR" "$LOG_BASE/final"
for n in 1 2; do
  printf -- '---\ntitle: independent finding %s\nseverity: high\ndomain: security\nlens: injection\n---\nEvidence.\n' "$n" > "$OUTPUT_DIR/$n.md"
done
build_finding_registry probe "$OUTPUT_DIR" || exit 1
cp "$LOG_BASE/final/findings.jsonl" "$fixture/registry.before"
cp "$LOG_BASE/final/findings.csv" "$fixture/csv.before"
printf '[{"title":"one","domain":"security","lens":"injection"}]\n' > "$fixture/manifest.json"
printf 'prior manifest records\n' > "$fixture/manifest.records"
cp "$fixture/manifest.records" "$fixture/manifest.before"
# Keep every ingestion dependency available, but omit both SHA utilities.
mkdir "$fixture/bin"
for tool in awk cat dirname find jq mkdir mktemp mv python3 realpath rm sort tr cmp; do
  ln -s "$(type -P "$tool")" "$fixture/bin/$tool"
done
normal_path="$PATH"
for fault in failed failed_valid malformed missing; do
  case "$fault" in
    failed) sha256sum() { cat >/dev/null; return 71; } ;;
    # Digest syntax alone must not hide a failed producer behind awk's success.
    failed_valid) sha256sum() { cat >/dev/null; printf '%064d\n' 0; return 71; } ;;
    malformed) sha256sum() { cat >/dev/null; printf 'invalid digest\n'; } ;;
    missing) unset -f sha256sum; PATH="$fixture/bin" ;;
  esac
  id=''
  rc=0
  # The library must detect pipeline failures even for callers without pipefail.
  id="$(set +o pipefail; finding_id security injection one)" || rc=$?
  check test "$rc" -ne 0
  check test -z "$id"
  rc=0
  build_finding_registry probe "$OUTPUT_DIR" || rc=$?
  check test "$rc" -ne 0
  check cmp "$fixture/registry.before" "$LOG_BASE/final/findings.jsonl"
  check cmp "$fixture/csv.before" "$LOG_BASE/final/findings.csv"
  rc=0
  build_findings_jsonl_from_manifest "$fixture/manifest.json" "$fixture/manifest.records" || rc=$?
  check test "$rc" -ne 0
  check cmp "$fixture/manifest.before" "$fixture/manifest.records"
  PATH="$normal_path"
  unset -f sha256sum 2>/dev/null || true
done
# A repaired retry publishes the complete registry again.
check build_finding_registry probe "$OUTPUT_DIR"
check cmp "$fixture/registry.before" "$LOG_BASE/final/findings.jsonl"
check cmp "$fixture/csv.before" "$LOG_BASE/final/findings.csv"
printf 'Results: %s failed\n' "$FAIL"
(( FAIL == 0 ))
