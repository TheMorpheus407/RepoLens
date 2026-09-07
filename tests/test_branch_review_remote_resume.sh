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

# Exercise actual CLI cloning and resume with local Git transport, never a model.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
RUN_IDS=()
PASS=0 FAIL=0
# shellcheck disable=SC2329 # Invoked by EXIT.
cleanup() {
  local run_id
  for run_id in "${RUN_IDS[@]:-}"; do
    [[ -z "$run_id" ]] || rm -rf -- "$SCRIPT_DIR/logs/$run_id"
  done
  rm -rf -- "$TEST_DIR"
}
trap cleanup EXIT
check() {
  local description="$1"; shift
  if "$@"; then PASS=$((PASS + 1)); echo "PASS: $description";
  else FAIL=$((FAIL + 1)); echo "FAIL: $description"; fi
}
contains() { [[ "$1" == *"$2"* ]]; }
export REPOLENS_RESUME_TEST_DIR="$TEST_DIR" REPOLENS_RESUME_REAL_GIT
REPOLENS_RESUME_REAL_GIT="$(command -v git)"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$TEST_DIR/gitconfig"
export GIT_AUTHOR_NAME=Review GIT_COMMITTER_NAME=Review
export GIT_AUTHOR_EMAIL=review@example.invalid GIT_COMMITTER_EMAIL=review@example.invalid
git config --file "$GIT_CONFIG_GLOBAL" "url.file://$TEST_DIR/source.insteadOf" https://resume.example.invalid/project.git
git init -q --initial-branch=main "$TEST_DIR/source" || exit 1
printf 'base\n' > "$TEST_DIR/source/app.txt"
git -C "$TEST_DIR/source" add app.txt && git -C "$TEST_DIR/source" commit -qm base || exit 1
git -C "$TEST_DIR/source" switch -qc feature || exit 1
printf 'reviewed feature\n' > "$TEST_DIR/source/app.txt"
git -C "$TEST_DIR/source" commit -qam feature || exit 1
saved_head="$(git -C "$TEST_DIR/source" rev-parse HEAD)"
git -C "$TEST_DIR/source" switch -q main || exit 1
mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/git" <<'GIT'
#!/usr/bin/env bash
set -uo pipefail
if [[ "${1:-}" == clone ]]; then
  touch "$REPOLENS_RESUME_TEST_DIR/$REPOLENS_RESUME_CASE.cloned"
fi
"$REPOLENS_RESUME_REAL_GIT" "$@" || exit "$?"
if [[ "${1:-}" == -C && "${3:-}" == checkout ]]; then
  "$REPOLENS_RESUME_REAL_GIT" -C "$2" rev-parse HEAD > "$REPOLENS_RESUME_TEST_DIR/$REPOLENS_RESUME_CASE.checked-out"
fi
GIT
for executable in codex gh glab tea fj; do
  cat > "$TEST_DIR/bin/$executable" <<'FORBIDDEN'
#!/usr/bin/env bash
touch "$REPOLENS_RESUME_TEST_DIR/forbidden-executable"
exit 99
FORBIDDEN
  chmod +x "$TEST_DIR/bin/$executable"
done
chmod +x "$TEST_DIR/bin/git"
export PATH="$TEST_DIR/bin:$PATH"
run_preview() {
  export REPOLENS_RESUME_CASE="$1"; shift
  bash "$SCRIPT_DIR/repolens.sh" --project https://resume.example.invalid/project.git \
    --agent codex --mode branch-review --local --focus injection --dry-run --yes \
    --output "$TEST_DIR/reports" "$@" > "$TEST_DIR/$REPOLENS_RESUME_CASE.log" 2>&1
  preview_rc=$?
  preview_output="$(cat "$TEST_DIR/$REPOLENS_RESUME_CASE.log")"
  local run_id
  run_id="$(sed -n 's/.*RepoLens run \([^ ]*\) starting.*/\1/p' "$TEST_DIR/$REPOLENS_RESUME_CASE.log")"
  [[ -z "$run_id" ]] || RUN_IDS+=("$run_id")
}
run_preview fresh --branch-base main --branch-head feature --task-hours 6
check "fresh URL review succeeds" test "$preview_rc" = 0
check "fresh clone checks out the selected feature commit" test "$(cat "$TEST_DIR/fresh.checked-out")" = "$saved_head"
run_id="${RUN_IDS[0]:-}"
[[ -n "$run_id" ]] || { printf '%s\n' "$preview_output"; exit 1; }
run_dir="$SCRIPT_DIR/logs/$run_id"
cp "$run_dir/branch-manifest.md" "$TEST_DIR/manifest.original"
cp "$run_dir/branch-diff.txt" "$TEST_DIR/diff.original"
for resume_case in omitted matching; do
  resume_args=()
  [[ "$resume_case" != matching ]] || resume_args=(--branch-base main --branch-head feature)
  run_preview "$resume_case" --resume "$run_id" "${resume_args[@]+"${resume_args[@]}"}"
  check "$resume_case refs resume succeeds" test "$preview_rc" = 0
  check "$resume_case refs resume checks out the saved commit" test "$(cat "$TEST_DIR/$resume_case.checked-out" 2>/dev/null)" = "$saved_head"
  check "$resume_case refs preserve task hours" contains "$preview_output" 'Task scope: up to 6 human implementation hour(s)'
done

# The ref still exists but now points elsewhere. A resume must use the frozen SHA.
"$REPOLENS_RESUME_REAL_GIT" -C "$TEST_DIR/source" switch -q feature || exit 1
printf 'newer feature\n' > "$TEST_DIR/source/app.txt"
"$REPOLENS_RESUME_REAL_GIT" -C "$TEST_DIR/source" commit -qam advance || exit 1
"$REPOLENS_RESUME_REAL_GIT" -C "$TEST_DIR/source" switch -q main || exit 1
for resume_case in advanced-omitted advanced-matching; do
  resume_args=()
  [[ "$resume_case" != advanced-matching ]] || resume_args=(--branch-base main --branch-head feature)
  run_preview "$resume_case" --resume "$run_id" "${resume_args[@]+"${resume_args[@]}"}"
  check "$resume_case resumes successfully" test "$preview_rc" = 0
  check "$resume_case checks out the original commit" test "$(cat "$TEST_DIR/$resume_case.checked-out" 2>/dev/null)" = "$saved_head"
  check "$resume_case keeps original ref provenance" contains "$preview_output" "Branch head:  feature ($saved_head)"
done
check "resumes leave the saved manifest unchanged" cmp -s "$run_dir/branch-manifest.md" "$TEST_DIR/manifest.original"
check "resumes leave the saved patch unchanged" cmp -s "$run_dir/branch-diff.txt" "$TEST_DIR/diff.original"
check "resumes retain the persisted task-hour cap" test "$(cat "$run_dir/task-hours")" = 6
for flag in --branch-base --branch-head; do
  run_preview "conflict-${flag#--}" --resume "$run_id" "$flag" HEAD
  check "conflicting $flag is rejected" test "$preview_rc" = 1
  check "conflicting $flag retains the mismatch diagnostic" contains "$preview_output" 'does not match persisted value'
done

for corruption in missing-head invalid-head nul-head duplicate-head symlink missing-file; do
  cp "$TEST_DIR/manifest.original" "$run_dir/branch-manifest.md"
  case "$corruption" in
    missing-head) sed '/^- head commit: /d' "$TEST_DIR/manifest.original" > "$run_dir/branch-manifest.md" ;;
    invalid-head) sed 's/^- head commit: .*/- head commit: feature/' "$TEST_DIR/manifest.original" > "$run_dir/branch-manifest.md" ;;
    nul-head)
      sed '/^- head commit: /d' "$TEST_DIR/manifest.original" > "$run_dir/branch-manifest.md"
      printf -- '- head commit: %s\0\n' "$saved_head" >> "$run_dir/branch-manifest.md"
      ;;
    duplicate-head) printf -- '- head commit: %s\n' "$saved_head" >> "$run_dir/branch-manifest.md" ;;
    symlink) rm "$run_dir/branch-manifest.md"; ln -s "$TEST_DIR/manifest.original" "$run_dir/branch-manifest.md" ;;
    missing-file) rm "$run_dir/branch-manifest.md" ;;
  esac
  run_preview "$corruption" --resume "$run_id"
  check "$corruption manifest is rejected" test "$preview_rc" = 1
  check "$corruption manifest fails before any clone" test ! -e "$TEST_DIR/$corruption.cloned"
  check "$corruption diagnostic identifies the saved manifest" contains "$preview_output" 'branch-manifest.md'
  rm -f "$run_dir/branch-manifest.md"
done
cp "$TEST_DIR/manifest.original" "$run_dir/branch-manifest.md"

# A syntactically valid but unavailable saved commit must never select a new head.
sed 's/^- head commit: .*/- head commit: ffffffffffffffffffffffffffffffffffffffff/' \
  "$TEST_DIR/manifest.original" > "$run_dir/branch-manifest.md"
run_preview unavailable-head --resume "$run_id"
check "unavailable frozen commit is rejected" test "$preview_rc" = 1
check "unavailable frozen commit is named in the failure" contains "$preview_output" \
  'Unable to resolve --branch-head ffffffffffffffffffffffffffffffffffffffff'
check "unavailable frozen commit never falls back to another checkout" test ! -e "$TEST_DIR/unavailable-head.checked-out"
cp "$TEST_DIR/manifest.original" "$run_dir/branch-manifest.md"

# Empty-delta manifests intentionally contain no SHA; preserve no-op resumes.
run_preview empty --branch-base main
empty_run="${RUN_IDS[${#RUN_IDS[@]}-1]}"
check "empty-delta URL review succeeds" test "$preview_rc" = 0
check "empty-delta manifest remains empty" test ! -s "$SCRIPT_DIR/logs/$empty_run/branch-manifest.md"
run_preview empty-resume --resume "$empty_run"
check "empty-delta URL resume succeeds" test "$preview_rc" = 0
check "dry-runs never execute an agent or forge" test ! -e "$TEST_DIR/forbidden-executable"
printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
