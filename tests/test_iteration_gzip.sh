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

# Issue #251 — per-lens iteration-file gzip. After a lens finishes, the forensic
# iteration-N-T.txt captures are compressed, keeping the K most-recent (highest
# iteration number) uncompressed. lens-outputs/*.md (the artifacts synth/verify
# and --resume actually read) and the .envelope.json sidecars must be untouched.
#
# Contract (TDD — defined here for the implementer):
#   lib/clean.sh defines: compress_lens_iterations <lens_log_dir> [keep=3]
#   - gzips iteration-*.txt in <lens_log_dir>, keeping the `keep` highest
#     iteration numbers uncompressed; older ones become iteration-*.txt.gz
#   - touches nothing else; no-op (non-fatal) when gzip is unavailable.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
TOTAL=0

assert_true() {
  local desc="$1" cond="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$cond" == "1" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc — expected='$expected' actual='$actual'"
  fi
}

echo "=== iteration-file gzip hook (issue #251) ==="

if ! command -v gzip >/dev/null 2>&1; then
  echo "  SKIP: gzip not available"
  echo ""
  echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
  exit 0
fi

# logging.sh provides log_* helpers the hook may call; init it into a temp dir
# so any logging is harmless and self-contained.
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/logging.sh"
init_logging "gziptest" "$workdir/log" >/dev/null 2>&1
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/clean.sh" 2>/dev/null || true

lens_dir="$workdir/security/injection"
mkdir -p "$lens_dir/lens-outputs"

# 10 iterations, timestamps and creation order both increasing with N so that
# "most recent" is unambiguous by iteration number, by filename, and by mtime.
for n in $(seq 1 10); do
  ts="20260101T0000$(printf '%02d' "$n")Z"
  f="$lens_dir/iteration-${n}-${ts}.txt"
  printf 'forensic capture for iteration %s\n' "$n" > "$f"
  # Peer envelope sidecar that v1 must NOT compress.
  printf '{"iter":%s}\n' "$n" > "$f.envelope.json"
done
# Artifact that synth/verify/--resume read — must survive untouched.
printf '# finding\nreal output\n' > "$lens_dir/lens-outputs/injection.md"
md_before="$(cat "$lens_dir/lens-outputs/injection.md")"

# --- Exercise the hook: keep the 3 most-recent uncompressed. ---
compress_lens_iterations "$lens_dir" 3

# Iterations 8,9,10 (highest N) stay plain; 1..7 are gzipped.
for n in 8 9 10; do
  ts="20260101T0000$(printf '%02d' "$n")Z"
  plain="$lens_dir/iteration-${n}-${ts}.txt"
  c=0; [[ -f "$plain" && ! -e "$plain.gz" ]] && c=1
  assert_true "iteration $n (recent) kept uncompressed" "$c"
done

gz_count=0
for n in 1 2 3 4 5 6 7; do
  ts="20260101T0000$(printf '%02d' "$n")Z"
  base="$lens_dir/iteration-${n}-${ts}.txt"
  if [[ -f "$base.gz" && ! -f "$base" ]]; then
    gz_count=$((gz_count + 1))
  fi
done
assert_eq "older 7 iterations gzipped (plain .txt removed)" "7" "$gz_count"

# Round-trip: a gzipped iteration decompresses to its original bytes.
roundtrip="$(zcat "$lens_dir/iteration-1-20260101T000001Z.txt.gz" 2>/dev/null)"
assert_eq "gzipped iteration round-trips losslessly" "forensic capture for iteration 1" "$roundtrip"

# lens-outputs artifact untouched.
md_after="$(cat "$lens_dir/lens-outputs/injection.md" 2>/dev/null)"
assert_eq "lens-outputs/*.md untouched" "$md_before" "$md_after"

# Envelope sidecars not compressed in v1 (smallest blast radius).
env_plain=0
[[ -f "$lens_dir/iteration-1-20260101T000001Z.txt.envelope.json" ]] && env_plain=1
assert_true "envelope sidecar left uncompressed (v1 scope)" "$env_plain"

# --- No-op when there are no more than `keep` iterations. ---
# A short lens (fewer iteration files than the keep window) must leave every
# capture uncompressed — nothing to forensically archive yet.
small_dir="$workdir/security/short-lens"
mkdir -p "$small_dir"
for n in 1 2 3; do
  printf 'cap %s\n' "$n" > "$small_dir/iteration-${n}-20260202T0000${n}Z.txt"
done
compress_lens_iterations "$small_dir" 3
noop_plain=0
for n in 1 2 3; do
  [[ -f "$small_dir/iteration-${n}-20260202T0000${n}Z.txt" \
     && ! -e "$small_dir/iteration-${n}-20260202T0000${n}Z.txt.gz" ]] && noop_plain=$((noop_plain + 1))
done
assert_eq "no-op: <=keep iterations all stay uncompressed" "3" "$noop_plain"

# --- Non-iteration files are ignored; only iteration-*.txt is a candidate. ---
# A file that does not match the iteration-<N>-... shape must never be gzipped,
# even when the real iteration files around it are.
mixed_dir="$workdir/security/mixed-lens"
mkdir -p "$mixed_dir"
for n in 1 2 3 4 5; do
  printf 'cap %s\n' "$n" > "$mixed_dir/iteration-${n}-20260303T0000${n}Z.txt"
done
printf 'not an iteration\n' > "$mixed_dir/notes.txt"
printf 'malformed\n' > "$mixed_dir/iteration-foo-bar.txt"   # non-numeric N -> skipped
compress_lens_iterations "$mixed_dir" 2
foreign_safe=0
[[ -f "$mixed_dir/notes.txt" && ! -e "$mixed_dir/notes.txt.gz" ]] && foreign_safe=1
assert_true "non-iteration file left untouched" "$foreign_safe"
malformed_safe=0
[[ -f "$mixed_dir/iteration-foo-bar.txt" && ! -e "$mixed_dir/iteration-foo-bar.txt.gz" ]] && malformed_safe=1
assert_true "iteration file with non-numeric N skipped" "$malformed_safe"

# --- No-op when gzip is unavailable. ---
# The run loop must not fail or delete plain forensic captures merely because
# gzip is not on PATH.
nogzip_dir="$workdir/security/no-gzip-lens"
mkdir -p "$nogzip_dir"
for n in 1 2 3 4; do
  printf 'cap %s\n' "$n" > "$nogzip_dir/iteration-${n}-20260404T0000${n}Z.txt"
done
# shellcheck disable=SC2329 # Invoked indirectly by compress_lens_iterations through command -v.
command() {
  if [[ "${1:-}" == "-v" && "${2:-}" == "gzip" ]]; then
    return 1
  fi
  builtin command "$@"
}
compress_lens_iterations "$nogzip_dir" 2
unset -f command

nogzip_plain=0
nogzip_gz=0
for n in 1 2 3 4; do
  [[ -f "$nogzip_dir/iteration-${n}-20260404T0000${n}Z.txt" ]] && nogzip_plain=$((nogzip_plain + 1))
  [[ -e "$nogzip_dir/iteration-${n}-20260404T0000${n}Z.txt.gz" ]] && nogzip_gz=$((nogzip_gz + 1))
done
assert_eq "gzip unavailable leaves all iteration files plain" "4" "$nogzip_plain"
assert_eq "gzip unavailable creates no .gz files" "0" "$nogzip_gz"

# --- CLI hook: a real focused run invokes compression after lens completion. ---
# The direct helper checks above would still pass if repolens.sh stopped calling
# compress_lens_iterations. This pins the run_lens call site using a fake codex
# binary and a symlink farm with its own isolated logs/ directory.
if command -v timeout >/dev/null 2>&1 && command -v git >/dev/null 2>&1; then
  hook_root="$workdir/cli-hook"
  hook_farm="$hook_root/farm"
  hook_bin="$hook_root/bin"
  hook_project="$hook_root/project"
  hook_output="$hook_root/run.out"
  hook_count="$hook_root/codex-count"
  mkdir -p "$hook_farm" "$hook_bin" "$hook_project"
  for item in repolens.sh lib config prompts; do
    ln -s "$SCRIPT_DIR/$item" "$hook_farm/$item"
  done
  mkdir -p "$hook_farm/logs"
  : > "$hook_count"

  cat > "$hook_bin/codex" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
printf 'call\n' >> "${REPOLENS_CLI_HOOK_COUNT:?}"
printf 'fake gzip-hook integration iteration\n'
printf 'DONE\n'
EOF
  chmod +x "$hook_bin/codex"

  git -C "$hook_project" init -q
  printf '# gzip hook project\n' > "$hook_project/README.md"

  PATH="$hook_bin:$PATH" \
  REPOLENS_CLI_HOOK_COUNT="$hook_count" \
  REPOLENS_ITERATION_KEEP=2 \
    timeout 60 bash "$hook_farm/repolens.sh" \
      --project "$hook_project" \
      --agent codex \
      --focus naming \
      --local \
      --output "$hook_root/issues" \
      --yes \
      --depth 5 \
      >"$hook_output" 2>&1
  hook_rc=$?

  assert_eq "CLI gzip hook run exits 0" "0" "$hook_rc"
  assert_eq "CLI gzip hook produced five iterations" "5" "$(wc -l < "$hook_count" | tr -d ' ')"

  hook_run_id="$(grep -oE 'RepoLens run [^ ]+ starting' "$hook_output" 2>/dev/null | head -1 | awk '{print $3}')"
  hook_lens_dir="$hook_farm/logs/$hook_run_id/code-quality/naming"
  plain_count="$(find "$hook_lens_dir" -maxdepth 1 -type f -name 'iteration-*.txt' 2>/dev/null | wc -l | tr -d ' ')"
  gz_count="$(find "$hook_lens_dir" -maxdepth 1 -type f -name 'iteration-*.txt.gz' 2>/dev/null | wc -l | tr -d ' ')"

  assert_eq "CLI gzip hook keeps REPOLENS_ITERATION_KEEP plain captures" "2" "$plain_count"
  assert_eq "CLI gzip hook gzips older captures after lens completion" "3" "$gz_count"
else
  echo "  SKIP: timeout or git not available — CLI gzip hook integration skipped"
fi

echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
if (( FAIL > 0 )); then
  exit 1
fi
