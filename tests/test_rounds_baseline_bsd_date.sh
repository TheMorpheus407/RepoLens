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

# Regression: repolens-r6-p3-3. Run the real baseline suite with BSD date's
# option contract. This is an emulated contract test, not a native macOS run.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
FIXTURE="$(mktemp -d)" || exit 1
trap 'rm -rf -- "$FIXTURE"' EXIT
BASELINE_TEST_REAL_DATE="$(command -v date)" || exit 1
BASELINE_TEST_DATE_LOG="$FIXTURE/date.log"
export BASELINE_TEST_REAL_DATE BASELINE_TEST_DATE_LOG
mkdir "$FIXTURE/bin" || exit 1
cat > "$FIXTURE/bin/date" <<'SHIM' || exit 1
#!/usr/bin/env bash
set -uo pipefail
if [[ "${1:-}" == -d ]]; then
  printf 'GNU option rejected\n' >> "$BASELINE_TEST_DATE_LOG"
  printf 'date: illegal option -- d\n' >&2
  exit 1
elif [[ "${1:-}" == -j ]]; then
  [[ "$#" -eq 5 && "$2" == -f && "$3" == '%Y-%m-%d %H:%M:%S' && "$5" == +%s ]] || exit 2
  printf 'BSD parsing used\n' >> "$BASELINE_TEST_DATE_LOG"
  # Delegate natively on BSD, translate only the accepted BSD parse on GNU.
  "$BASELINE_TEST_REAL_DATE" "$@" 2>/dev/null && exit 0
  exec "$BASELINE_TEST_REAL_DATE" -d "$4" "$5"
fi
exec "$BASELINE_TEST_REAL_DATE" "$@"
SHIM
chmod +x "$FIXTURE/bin/date" || exit 1
rc=0
PATH="$FIXTURE/bin:$PATH" bash "$REPO/tests/test_rounds_default_no_regression.sh" > "$FIXTURE/output" 2>&1 || rc=$?
if (( rc != 0 )); then
  cat "$FIXTURE/output"
  printf 'FAIL: actual default-rounds suite rejected BSD date (exit %s)\n' "$rc"
  exit 1
fi
grep -qx 'BSD parsing used' "$BASELINE_TEST_DATE_LOG" || { echo 'FAIL: BSD parsing was not exercised'; exit 1; }
grep -q 'Results:.*0 failed' "$FIXTURE/output" || { cat "$FIXTURE/output"; exit 1; }
cat "$FIXTURE/output"
echo 'Results: actual baseline suite passes with BSD date options'
