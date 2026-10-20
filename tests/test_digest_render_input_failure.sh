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

# A failed here-string temporary-file write must not publish missing findings.
# shellcheck disable=SC2317,SC2329
set -euo pipefail
export LC_ALL=C
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/lib/core.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/rounds.sh"
saved_file_limit="$(ulimit -S -f)"
fault=none
fault_armed=0
# Define the override before builtin printf calls for older ShellCheck versions.
# Restore the limit at the next output operation, so only the here-string's
# temporary-file write fails; subsequent rendering could otherwise hide it.
printf() {
  if (( fault_armed )); then
    ulimit -S -f "$saved_file_limit"
    fault_armed=0
  fi
  # shellcheck disable=SC2059 # Forward the caller's format and arguments.
  builtin printf "$@"
  # Exercise the defensive hard-cap branch with actual oversized render output,
  # without hundreds of findings or a false line-count result.
  if [[ "$fault" == capped-output && "${1:-}" == '## Coverage\n' ]]; then
    local extra_line
    for ((extra_line = 0; extra_line < 510; extra_line++)); do
      builtin printf 'extra coverage context %s\n' "$extra_line"
    done
  fi
  if [[ "$fault" == render-input && "${1:-}" == '## Findings\n' ]]; then
    builtin printf 'reached\n' > "$fixture/fault-reached"
    ulimit -S -f 0
    fault_armed=1
  fi
}
fail() {
  builtin printf 'FAIL: %s\n' "$*" >&2
  exit 1
}
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
round="$fixture/round-1"
mkdir -p "$round/lens-outputs"
# Unbounded suspect metadata makes Bash spill the sorted here-string to disk.
long_path="$(builtin printf '%65536s' '')"
long_path="src/${long_path// /x}.sh"
builtin printf -- '---\ntitle: retained finding\nseverity: high\ndomain: security\nlens: injection\nsuspect_files: %s\n---\n## hypothesis\nRetained security evidence\n' "$long_path" > "$round/lens-outputs/finding.md"
# Conditional calls keep errexit disabled inside the library, as in production.
build_round_digest "$round" || fail 'baseline digest build failed'
cp "$round/digest.md" "$fixture/before"

trap '' XFSZ
fault=render-input
rc=0
# Collect diagnostics through a pipe: the temporary file-size limit also
# prevents this shell from writing directly to a regular stderr log.
build_round_digest "$round" 2>&1 | cat > "$fixture/stderr" || rc=$?
ulimit -S -f "$saved_file_limit"
fault_armed=0
builtin printf 'render-input: rc=%s\n' "$rc"
cat "$fixture/stderr"
test -f "$fixture/fault-reached" || fail 'render-input fault was not reached'
grep -q 'here-document' "$fixture/stderr" || fail 'missing here-string failure diagnostic'
failures=0
if [[ "$rc" -eq 0 ]]; then
  builtin printf 'FAIL: here-string failure must fail the digest build\n' >&2
  failures=$((failures + 1))
fi
if ! cmp "$fixture/before" "$round/digest.md"; then
  builtin printf 'FAIL: here-string failure must preserve the complete digest\n' >&2
  failures=$((failures + 1))
fi
staged_files="$(find "$round" -name 'digest.md.tmp.*' -print)" || fail 'staging inspection failed'
test -z "$staged_files" || fail 'temporary digest was not removed'
fault=none
build_round_digest "$round" || fail 'digest retry failed'
cmp "$fixture/before" "$round/digest.md" || fail 'retry changed the saved digest'
test "$failures" -eq 0 || fail 'render-input preservation assertions failed'
builtin printf 'PASS: render-input failure preserves digest, cleans staging and permits retry.\n'

# Publication needs only a small finding; the large-path fixture above is
# reserved for forcing Bash's here-string spill and keeps these cases quick.
builtin printf -- '---\ntitle: retained finding\nseverity: high\ndomain: security\nlens: injection\nsuspect_files: src/probe.sh:1\n---\n## hypothesis\nRetained security evidence\n' > "$round/lens-outputs/finding.md"
build_round_digest "$round" || fail 'publication baseline failed'
cp "$round/digest.md" "$fixture/before"

# Directory destinations must not turn a staged file into a nested artifact.
for output_size in normal capped; do
  fault=none
  [[ "$output_size" != capped ]] || fault=capped-output
  for destination in directory symlink-directory; do
    rm -f "$round/digest.md"
    target="$fixture/$output_size-$destination-target"
    mkdir "$target"
    builtin printf 'untouched target marker\n' > "$target/marker"
    if [[ "$destination" == directory ]]; then
      mkdir "$round/digest.md"
    else
      ln -s "$target" "$round/digest.md"
    fi
    rc=0
    build_round_digest "$round" > "$fixture/publish-$output_size-$destination.log" 2>&1 || rc=$?
    if (( rc == 0 )); then
      builtin printf 'FAIL: %s destination reports false success\n' "$destination" >&2
      failures=$((failures + 1))
    fi
    staged_files="$(find "$round" "$target" -name 'digest.md.tmp.*' -print)" || fail 'publication staging inspection failed'
    if [[ -n "$staged_files" ]]; then
      builtin printf 'FAIL: %s destination retains or nests staging\n' "$destination" >&2
      failures=$((failures + 1))
    fi
    [[ -d "$round/digest.md" ]] || fail 'failed publication replaced its obstruction'
    [[ "$destination" != symlink-directory || -L "$round/digest.md" ]] || fail 'failed publication replaced its symlink'
    [[ "$(cat "$target/marker")" == 'untouched target marker' ]] || fail 'publication changed the target marker'
    rm -rf -- "$round/digest.md"
    build_round_digest "$round" || fail 'repaired destination retry failed'
    [[ -f "$round/digest.md" && ! -L "$round/digest.md" ]] || fail 'retry did not publish the exact regular digest'
    if [[ "$output_size" == normal ]]; then
      cmp "$fixture/before" "$round/digest.md" || fail 'destination retry changed digest content'
    else
      [[ "$(wc -l < "$round/digest.md")" -eq 500 ]] || fail 'capped retry violates the line limit'
      grep -q '^Digest truncated at 500 lines.$' "$round/digest.md" || fail 'capped retry lacks the truncation marker'
      grep -q 'Retained security evidence' "$round/digest.md" || fail 'capped retry lost finding evidence'
    fi
  done
done
test "$failures" -eq 0 || fail 'exact-path publication assertions failed'
builtin printf 'PASS: exact publication rejects directory destinations, cleans staging and retries.\n'
