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

# Digest staging failures must preserve the published report and permit retry.
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
write_format=''
# Define the override before builtin printf calls for older ShellCheck versions.
# Restore the limit at the next output operation, so only the here-string's
# temporary-file write fails; subsequent rendering could otherwise hide it.
printf() {
  if (( fault_armed )); then
    ulimit -S -f "$saved_file_limit"
    fault_armed=0
  fi
  if [[ "$fault" == render-output && "${1:-}" == "$write_format" ]]; then
    builtin printf 'reached\n' > "$fixture/fault-reached"
    local injected_write_rc=0
    ulimit -S -f 0
    # Return the actual EFBIG status, then allow later writes to succeed.
    # shellcheck disable=SC2059 # Forward the production format and arguments.
    builtin printf "$@" || injected_write_rc=$?
    ulimit -S -f "$saved_file_limit"
    builtin printf '%s\n' "$injected_write_rc" > "$fixture/write-status"
    return "$injected_write_rc"
  fi
  if [[ "$fault" == cap-marker && "${1:-}" == 'Digest truncated at 500 lines.\n' ]]; then
    builtin printf 'reached\n' > "$fixture/fault-reached"
    builtin printf 'partial marker'
    return 1
  fi
  # shellcheck disable=SC2059 # Forward the caller's format and arguments.
  builtin printf "$@"
  # Exercise the defensive hard-cap branch with actual oversized render output,
  # without hundreds of findings or a false line-count result.
  if [[ "$fault" == cap* && "${1:-}" == '## Coverage\n' ]]; then
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
mktemp() {
  if [[ "$fault" == cap-create && "${1:-}" == *.cap.XXXXXX ]]; then
    builtin printf 'reached\n' > "$fixture/fault-reached"
    return 1
  fi
  command mktemp "$@"
}
head() {
  if [[ "$fault" == cap-head && "${1:-}" == -n && "${2:-}" == 499 ]]; then
    builtin printf 'reached\n' > "$fixture/fault-reached"
    builtin printf 'partial capped output\n'
    return 1
  fi
  command head "$@"
}
cat() {
  if [[ "$fault" == cap-copy && "${1:-}" == *.cap.* ]]; then
    builtin printf 'reached\n' > "$fixture/fault-reached"
    builtin printf 'partial copied output\n'
    return 1
  fi
  command cat "$@"
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

# A failed output operation can be hidden by later successful writes/counters.
# Cover the header, a finding body, and both final coverage operations with
# real transient file-size failures rather than a fabricated printf status.
write_case=0
for write_format in '# Round Digest\n\n' ' hypothesis="%s"\n' '## Coverage\n' 'Touched %s/%s audit domains: %s\n'; do
  write_case=$((write_case + 1))
  fault=render-output
  rm -f "$fixture/fault-reached" "$fixture/write-status"
  rc=0
  build_round_digest "$round" 2>&1 | cat > "$fixture/write-$write_case.log" || rc=$?
  [[ -f "$fixture/fault-reached" ]] || fail 'render-output fault was not reached'
  [[ "$(cat "$fixture/write-status")" -ne 0 ]] || fail 'printf did not report a real write failure'
  grep 'File too large' "$fixture/write-$write_case.log" || fail 'missing real EFBIG diagnostic'
  builtin printf 'render-output %s: printf=%s digest=%s\n' "$write_case" "$(cat "$fixture/write-status")" "$rc"
  if (( rc == 0 )); then
    builtin printf 'FAIL: output failure %s must fail the digest build\n' "$write_case" >&2
    failures=$((failures + 1))
  fi
  if ! cmp -s "$fixture/before" "$round/digest.md"; then
    builtin printf 'FAIL: output failure %s replaced the complete digest\n' "$write_case" >&2
    failures=$((failures + 1))
  fi
  staged_files="$(find "$round" -name 'digest.md.tmp.*' -print)" || fail 'output staging inspection failed'
  [[ -z "$staged_files" ]] || fail 'output failure retained staging'
  fault=none
  build_round_digest "$round" || fail 'output failure retry failed'
  cmp "$fixture/before" "$round/digest.md" || fail 'output retry changed the complete digest'
done
test "$failures" -eq 0 || fail 'render-output preservation assertions failed'
builtin printf 'PASS: real render-output failures preserve digest, clean staging and retry.\n'

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

# All cap preparation failures must preserve an already published digest,
# including producers that write partial bytes before returning failure.
for fault in cap-create cap-head cap-marker cap-copy; do
  cp "$fixture/before" "$round/digest.md"
  rm -f "$fixture/fault-reached"
  rc=0
  build_round_digest "$round" > "$fixture/$fault.log" 2>&1 || rc=$?
  [[ -f "$fixture/fault-reached" ]] || fail "$fault was not reached"
  (( rc != 0 )) || fail "$fault reported success"
  cmp "$fixture/before" "$round/digest.md" || fail "$fault replaced the saved digest"
  staged_files="$(find "$round" -name 'digest.md.tmp.*' -print)" || fail 'cap staging inspection failed'
  [[ -z "$staged_files" ]] || fail "$fault retained staging"
  fault=capped-output
  build_round_digest "$round" || fail 'cap failure retry failed'
  [[ "$(wc -l < "$round/digest.md")" -eq 500 ]] || fail 'cap retry violates line limit'
  grep -qx 'Digest truncated at 500 lines.' "$round/digest.md" || fail 'cap retry lacks marker'
  grep -q 'Retained security evidence' "$round/digest.md" || fail 'cap retry lost evidence'
done
builtin printf 'PASS: cap preparation failures preserve digest, clean staging and retry.\n'

# Capping must follow the same permission policy as an uncapped publication,
# including a restrictive umask, both for first publication and replacement.
for digest_umask in 022 027 077; do
  (
    umask "$digest_umask"
    rm -f "$round/digest.md"
    fault=none
    build_round_digest "$round" || fail 'permission baseline failed'
    normal_mode="$(python3 -c 'import os, stat, sys; print(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))' "$round/digest.md")"
    for publication in replacement first; do
      [[ "$publication" != first ]] || rm -f "$round/digest.md"
      fault=capped-output
      build_round_digest "$round" || fail 'capped permission build failed'
      capped_mode="$(python3 -c 'import os, stat, sys; print(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))' "$round/digest.md")"
      [[ "$capped_mode" == "$normal_mode" ]] || fail "capping changed mode under umask $digest_umask ($publication): $normal_mode -> $capped_mode"
    done
  )
done
builtin printf 'PASS: capped and normal digest permissions match under umasks 022, 027 and 077.\n'
