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

# repolens-r13-p1-1: recovered dispatch errors must not keep runs incomplete.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$(mktemp -d)"
RUN_DIRS=()
trap 'rm -rf -- "$FIXTURE"; if (( ${#RUN_DIRS[@]} )); then rm -rf -- "${RUN_DIRS[@]}"; fi' EXIT
mkdir -p "$FIXTURE/bin" "$REPO/logs"
REAL_CAT="$(command -v cat)"
export REAL_CAT
cat > "$FIXTURE/bin/cat" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
for arg in "$@"; do
  if [[ "${FAIL_DISPATCH:-0}" == 1 && "$arg" == */round-1/dispatch.md ]]; then
    count="$("$REAL_CAT" "$READ_COUNTER")"
    count=$((count + 1))
    printf '%s\n' "$count" > "$READ_COUNTER"
    if (( count == FAIL_READ )); then
      printf 'injected dispatch read error\n' >&2
      exit 42
    fi
  fi
done
exec "$REAL_CAT" "$@"
SHIM
cat > "$FIXTURE/bin/codex" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
printf '[]\nLENS: injection\nHYPOTHESES_TO_VERIFY:\n- Follow up.\nDONE\n'
SHIM
chmod +x "$FIXTURE/bin/cat" "$FIXTURE/bin/codex"
export PATH="$FIXTURE/bin:$PATH"
export REPOLENS_LENS_HEARTBEAT_INTERVAL=0 REPOLENS_STATUS_INTERVAL=1
export REPOLENS_AGENT_TIMEOUT=5 REPOLENS_AGENT_KILL_GRACE=1
# shellcheck source=/dev/null
source "$REPO/lib/clean.sh"
for FAIL_READ in 1 3; do
  export FAIL_READ READ_COUNTER="$FIXTURE/reads-$FAIL_READ"
  printf '0\n' > "$READ_COUNTER"
  RUN_LOG="$(mktemp -d "$REPO/logs/test-dispatch-resume.XXXXXX")"
  RUN_DIRS+=("$RUN_LOG")
  RUN_ID="${RUN_LOG##*/}"
  args=(--project "$REPO" --agent codex --yes --mode bugreport --bug-report 'Fixture: inspect the injection path.' --local --output "$RUN_LOG/output" --resume "$RUN_ID" --rounds 2 --depth 1 --focus injection)
  first_rc=0
  FAIL_DISPATCH=1 bash "$REPO/repolens.sh" "${args[@]}" > "$FIXTURE/first-$FAIL_READ.log" 2>&1 || first_rc=$?
  if [[ "$FAIL_READ" == 3 ]]; then reason=generic-dispatch-failed; else reason=lens-dispatch-read-failed; fi
  test "$first_rc" -ne 0
  jq -e --arg reason "$reason" '.stopped_reason == $reason' "$RUN_LOG/summary.json" >/dev/null
  resume_rc=0
  FAIL_DISPATCH=0 bash "$REPO/repolens.sh" "${args[@]}" > "$FIXTURE/resume-$FAIL_READ.log" 2>&1 || resume_rc=$?
  printf '%s: first_exit=%s resume_exit=%s stop=%s\n' "$reason" "$first_rc" "$resume_rc" "$(jq -r '.stopped_reason // ""' "$RUN_LOG/summary.json")"
  test "$resume_rc" -eq 0
  jq -e '(.stopped_reason // "") == ""' "$RUN_LOG/summary.json" >/dev/null
  jq -e '.[-1] | .exit_code == 0 and ((.why_stopped // "") == "")' "$RUN_LOG/attempts.json" >/dev/null
  jq -e --arg reason "$reason" '.[0] | .exit_code != 0 and .why_stopped == $reason' "$RUN_LOG/attempts.json" >/dev/null
  jq -e '.state == "finished-empty"' "$RUN_LOG/status.json" >/dev/null
  if _clean_is_incomplete "$RUN_LOG"; then printf 'FAIL: completed resume is still incomplete\n' >&2; exit 1; fi
  test -f "$RUN_LOG/rounds/round-2/.completed"
done
printf 'PASS: both repaired dispatch failures clear current diagnostics and preserve historical attempts.\n'
