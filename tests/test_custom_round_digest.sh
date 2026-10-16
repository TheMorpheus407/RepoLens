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

# repolens-r9-p2-1: generated Custom findings must reach the round digest.
# shellcheck disable=SC2034 # The real round/meta helpers consume fixture globals.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO/lib/rounds.sh"
set -euo pipefail
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
LOG_BASE="$FIXTURE/run" CURRENT_ROUND_INDEX=2 MODE=bugreport
mkdir -p "$LOG_BASE/rounds/round-1"
cat > "$FIXTURE/meta.txt" <<'META'
CUSTOM: payment-retry-race role=deeper
```text
Investigate the retry path at src/retry.sh:1.
```
META
_rounds_meta_parse_output "$FIXTURE/meta.txt" "$LOG_BASE/rounds/round-1/dispatch.md" "$FIXTURE/hypotheses.md"
entry="$(_rounds_meta_dispatch_custom_entries "$LOG_BASE/rounds/round-1/dispatch.md" "$LOG_BASE/rounds/round-1/custom-lenses")"
canonical="${entry%%|*}" lens="${entry%%|*}"
lens="${lens#*/}"
[[ "$canonical" == custom/r2-* && "$entry" == *'|deeper|'* ]]
round="$LOG_BASE/rounds/round-2"
mkdir -p "$round/lens-outputs/$canonical"
write_finding() {
  local path="$1" domain="$2" finding_lens="$3" label="$4"
  printf -- '---\ntitle: %s\nseverity: high\ndomain: %s\nlens: %s\nconfidence: high\nroot_cause_category: race\nsuspect_files:\n  - src/retry.sh:1\n---\n## hypothesis\n%s charges twice at the retry site.\n## evidence\nsrc/retry.sh:1\n' \
    "$label" "$domain" "$finding_lens" "$label" > "$path"
}
write_finding "$round/lens-outputs/$canonical/001.md" custom "$lens" AcceptedCustom
write_finding "$round/lens-outputs/undispatched.md" custom r2-never-dispatched UndispatchedCustom
write_finding "$round/lens-outputs/spoofed.md" generic "$lens" DomainSpoof
PASS=0 FAIL=0
check_contains() {
  local description="$1" text="$2" expected="$3"
  if [[ "$text" == *"$expected"* ]]; then PASS=$((PASS + 1))
  else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$description"; fi
}
check_absent() {
  local description="$1" text="$2" unwanted="$3"
  if [[ "$text" != *"$unwanted"* ]]; then PASS=$((PASS + 1))
  else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$description"; fi
}
build_round_digest "$round" "$entry" 2> "$FIXTURE/warnings"
digest="$(cat "$round/digest.md")"
check_contains 'actual generated Custom dispatch is summarized' "$digest" "$lens: 1 finding"
check_contains 'Custom hypothesis is retained' "$digest" AcceptedCustom
check_contains 'Custom source anchor is retained' "$digest" '`src/retry.sh:1`'
check_absent 'undispatched Custom finding rejected' "$digest" UndispatchedCustom
check_absent 'different domain cannot borrow Custom dispatch' "$digest" DomainSpoof
build_round_digest "$round" 2> "$FIXTURE/no-dispatch-warnings"
check_contains 'no dynamic dispatch means no trust' "$(cat "$round/digest.md")" 'No findings this round.'
# Static registered lenses and generated Generic dispatches retain their paths.
write_finding "$round/lens-outputs/registered.md" security injection RegisteredControl
write_finding "$round/lens-outputs/generic.md" generic deeper-fallback GenericControl
build_round_digest "$round" "$entry" 'generic/deeper-fallback|deeper|||' 2> "$FIXTURE/mixed-warnings"
digest="$(cat "$round/digest.md")"
check_contains 'mixed digest keeps Custom' "$digest" AcceptedCustom
check_contains 'mixed digest keeps registered lens' "$digest" RegisteredControl
check_contains 'mixed digest keeps dispatched Generic' "$digest" GenericControl
check_absent 'mixed digest still rejects undispatched Custom' "$digest" UndispatchedCustom
check_absent 'mixed digest still rejects domain spoof' "$digest" DomainSpoof
printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
test "$FAIL" -eq 0
