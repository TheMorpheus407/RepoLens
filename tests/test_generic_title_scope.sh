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


# Title decoding must stay at the explicit Generic delivery boundary.
# shellcheck disable=SC2034 # Production callbacks consume these globals.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO/lib/core.sh"
# shellcheck source=/dev/null
source "$REPO/lib/rounds.sh"
# shellcheck source=/dev/null
source "$REPO/lib/ledger.sh"
# shellcheck source=/dev/null
source "$REPO/lib/summary.sh"
set -euo pipefail
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
failures=0
check() {
  if ! "$@"; then printf 'FAIL: %s\n' "$*" >&2; failures=$((failures+1)); fi
}
LOG_BASE="$FIXTURE/run" OUTPUT_DIR="$FIXTURE/output" RUN_ID=scope-probe MODE=bugreport ROUNDS=1
LOCAL_MODE=true OUTPUT_DIR_SET=true SUMMARY_FILE="$LOG_BASE/summary.json" MAX_ISSUES=''
round_dir="$LOG_BASE/rounds/round-1"
raw="$round_dir/lens-outputs/probe.md"
mkdir -p "${raw%/*}" "$OUTPUT_DIR"
init_summary "$SUMMARY_FILE" "$RUN_ID" "$FIXTURE" bugreport mock '' '' local "$OUTPUT_DIR"
printf '%s\n' '{"lens_ids":["generic/probe"]}' > "$round_dir/metadata.json"
write_finding() {
  printf -- '---\ndomain: %s\nlens_id: %s\nseverity: %s\ntitle: %s\n---\n## hypothesis\nLogin fails\n## evidence\nsrc/login.py:1\n' "$@" > "$raw"
}
# A title-only change cannot newly admit escaped attribution/severity values
# that the ordinary registry reader would interpret differently.
for metadata in domain severity lens_id; do
  domain=generic severity=high lens=probe
  case "$metadata" in
    domain) domain='"\u0067eneric"' ;;
    severity) severity='"hi\u0067h"' ;;
    lens_id) lens='"pr\u006fbe"' ;;
  esac
  write_finding "$domain" "$lens" "$severity" 'Escaped metadata'
  check export_generic_local_findings "$OUTPUT_DIR"
  check build_findings_jsonl_from_local "$OUTPUT_DIR" "$FIXTURE/registry.jsonl"
  check jq -se 'length == 0' "$FIXTURE/registry.jsonl"
done
# Dequoting the same literal title must preserve the existing digest and ID
# across static, Custom and Generic inputs. Generic delivery alone decodes it.
for identity in security/injection custom/probe generic/probe; do
  domain="${identity%/*}" lens="${identity#*/}"
  write_finding "$domain" "$lens" high 'Failure in \"login\" endpoint'
  check build_round_digest "$round_dir" "$identity"
  cp "$round_dir/digest.md" "$FIXTURE/plain-digest.md"
  write_finding "$domain" "$lens" high '"Failure in \"login\" endpoint"'
  check build_round_digest "$round_dir" "$identity"
  check cmp -s "$round_dir/digest.md" "$FIXTURE/plain-digest.md"
done
# Malformed escapes in excluded evidence cannot abort an otherwise valid digest.
write_finding generic undispatched high '"bad\q"'
check build_round_digest "$round_dir" generic/probe
check grep -Fq 'No findings this round.' "$round_dir/digest.md"
REPOLENS_MIN_SEVERITY=high
write_finding generic probe low '"bad\q"'
check build_round_digest "$round_dir" generic/probe
check grep -Fq 'No findings this round.' "$round_dir/digest.md"
# An unrelated malformed domain must not block a valid Generic delivery.
write_finding generic probe high 'Independent Generic finding'
ordinary="$round_dir/lens-outputs/security/injection/ordinary.md"
mkdir -p "${ordinary%/*}"
printf -- '---\ndomain: "security\\q"\nlens_id: injection\nseverity: high\ntitle: Ordinary draft\n---\nDraft evidence\n' > "$ordinary"
ordinary_hash="$(sha256sum < "$ordinary")"
check export_generic_local_findings "$OUTPUT_DIR"
check build_findings_jsonl_from_local "$OUTPUT_DIR" "$FIXTURE/registry.jsonl"
check jq -se 'length == 1 and .[0].title == "Independent Generic finding"' "$FIXTURE/registry.jsonl"
check test "$(sha256sum < "$ordinary")" = "$ordinary_hash"
printf 'Generic title scope assertions: %s failures\n' "$failures"
(( failures == 0 ))
