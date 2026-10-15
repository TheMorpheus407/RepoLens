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

# Saved non-regular nodes must be collisions, never reused or opened for reading.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
payload=$'CUSTOM: Retry\nDraft prompt:\nInspect retries.'
materialize() {
  timeout 2 bash -c '
    set -euo pipefail
    source "$1/lib/rounds.sh"
    CURRENT_ROUND_INDEX=2
    _rounds_meta_write_custom_lens "$2" "$3" 1
  ' _ "$REPO" "$1" "$payload"
}
passed=0 failed=0
check() {
  if "$@"; then passed=$((passed + 1));
  else failed=$((failed + 1)); printf 'FAIL: %s\n' "$*"; fi
}
for kind in symlink dangling directory fifo; do
  dest="$FIXTURE/$kind"
  mkdir -p "$dest/custom"
  first="$(materialize "$dest")"
  saved="$dest/$first.md"
  mv "$saved" "$dest/target.md"
  case "$kind" in
    symlink) ln -s ../target.md "$saved" ;;
    dangling) ln -s ../missing.md "$saved" ;;
    directory) mkdir "$saved" ;;
    fifo) mkfifo "$saved" ;;
  esac
  rc=0
  entry="$(materialize "$dest")" || rc=$?
  check test "$rc" -eq 0
  check test "$entry" = custom/r2-retry-2
  # Changing a symlink target must not change the selected canonical prompt.
  printf 'Changed target content.\n' > "$dest/target.md"
  check test -f "$dest/$entry.md"
  check test ! -L "$dest/$entry.md"
  if [[ -f "$dest/$entry.md" ]]; then
    check grep -q 'Inspect retries.' "$dest/$entry.md"
  fi
  again="$(materialize "$dest")" || again=failed
  check test "$again" = "$entry"
done
printf '%s checks passed; %s failed.\n' "$passed" "$failed"
test "$failed" -eq 0
