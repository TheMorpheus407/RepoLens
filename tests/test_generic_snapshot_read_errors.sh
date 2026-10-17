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


# shellcheck disable=SC2034,SC2329 # Globals/callbacks are used by production.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Reuse fixture setup and the real CLI finalization callback.
# shellcheck source=/dev/null
source <(awk '/^LOG_BASE=/ {exit} /^REPO=/ {next} {print}' "$REPO/tests/test_generic_explicit_output.sh")
trap 'chmod -R u+rwX "$FIXTURE"; rm -rf -- "$FIXTURE"' EXIT
printf -- '---\n---\nBody\n' > "$FIXTURE/empty-block.md"
_round_digest_frontmatter_block "$FIXTURE/empty-block.md" >/dev/null
for fault in unreadable empty-error partial-error; do
  (
    LOG_BASE="$FIXTURE/$fault/run" OUTPUT_DIR="$FIXTURE/$fault/output"
    SUMMARY_FILE="$LOG_BASE/summary.json" PROJECT_PATH="$FIXTURE/project"
    OUTPUT_DIR_SET=true RUN_ID=probe ROUNDS=1 MODE=bugreport LOCAL_MODE=true
    HUMAN_REVIEW=true REPOLENS_FINAL_STATE=finished
    raw="$LOG_BASE/rounds/round-1/lens-outputs/probe.md"
    mkdir -p "$(dirname "$raw")" "$OUTPUT_DIR" "$PROJECT_PATH"
    init_summary "$SUMMARY_FILE" probe "$PROJECT_PATH" bugreport mock '' '' local "$OUTPUT_DIR"
    printf '%s\n' '{"lens_ids":["generic/probe"]}' > "$LOG_BASE/rounds/round-1/metadata.json"
    printf -- '---\ndomain: generic\nlens_id: probe\nseverity: high\ntitle: Saved finding\n---\n## hypothesis\nSaved finding\n## evidence\nOriginal evidence.\n' > "$raw"
    optional_local_finalization
    delivered="$(jq -r .markdown_path "$LOG_BASE/final/findings.jsonl")"
    before="$(sha256sum "$raw" "$delivered" "$LOG_BASE/final/"*.json* "$LOG_BASE/final/"*.csv "$LOG_BASE/final/"*.md)"
    # Revoke permissions only after the raw source was copied successfully.
    cat() {
      command cat "$@" || return $?
      if [[ "$fault" == unreadable && "${!#}" == "$raw" ]]; then
        local reader_pid="$BASHPID"
        chmod 000 "$(readlink "/proc/$reader_pid/fd/1")"
      fi
    }
    awk() {
      if [[ "${!#}" == "$LOG_BASE/final/.generic-plan."*/source ]]; then
        case "$fault" in
          empty-error) return 74 ;;
          partial-error) command awk "$@"; return 74 ;;
          unreadable)
            # Root bypasses mode bits; emulate the same failed reader there.
            [[ "$(id -u)" != 0 ]] || return 2
            ;;
        esac
      fi
      command awk "$@"
    }
    rc=0
    export_generic_local_findings "$OUTPUT_DIR" || rc=$?
    printf 'snapshot=%s export_rc=%s\n' "$fault" "$rc"
    test "$rc" -ne 0
    optional_local_finalization
    test "$(sha256sum "$raw" "$delivered" "$LOG_BASE/final/"*.json* "$LOG_BASE/final/"*.csv "$LOG_BASE/final/"*.md)" = "$before"
    unset -f cat awk
    optional_local_finalization
    jq -se 'length == 1 and .[0].title == "Saved finding"' "$LOG_BASE/final/findings.jsonl" >/dev/null
    # Readable malformed ordinary drafts remain skippable.
    printf 'Not a finding\n' > "$(dirname "$raw")/malformed.md"
    optional_local_finalization
    jq -se 'length == 1' "$LOG_BASE/final/findings.jsonl" >/dev/null
    printf 'Snapshot read error preserves delivery and reports, retry succeeds: %s\n' "$fault"
  )
done
