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

# A stale duplicate mark must not hide the last actionable local finding.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
for lib in ledger synthesize local-dedupe branch-scope human_review artifacts; do
  # shellcheck source=/dev/null
  source "$REPO/lib/$lib.sh"
done
failed=0 checks=0
check() {
  checks=$((checks + 1))
  if ! "$@" >/dev/null 2>&1; then
    printf 'FAIL: %s: %s\n' "$scenario" "$*"
    failed=$((failed + 1))
  fi
}
write_finding() {
  local path="$1" lens="$2" status="$3" target="${4:-}" citation="${5:-src/live.sh:12}"
  cat > "$path" <<EOF
---
title: Unsafe access to shared state
severity: high
domain: security
lens: $lens
${status:+status: $status}
${target:+duplicate_of: $target}
---
Shared state access at $citation needs synchronization.
EOF
}
# Append a complete owned receipt; malformed variants exercise ownership guards.
receipt() {
  local path="$1" style="$2" target="${3:-security/probe/002.md}"
  if [[ "$style" == outside ]]; then
    printf '\n<!-- repolens-dedupe:duplicate -->\n' >> "$path"
    return
  fi
  {
    printf '\n<!-- repolens-dedupe:begin -->\n'
    case "$style" in
      typed|incomplete) printf '<!-- repolens-dedupe:duplicate -->\n' ;;
      legacy) printf '> Duplicate of `%s` — see the canonical finding for the full details.\n' "$target" ;;
      canonical) printf '> Canonical finding — other contributors follow.\n' ;;
      malformed) printf '<!-- repolens-dedupe:duplicate --> extra\n' ;;
    esac
    if [[ "$style" != incomplete ]]; then printf '<!-- repolens-dedupe:end -->\n'; fi
  } >> "$path"
}
for scenario in missing missing-link invalid filtered self chain cycle outside failed-dedupe valid \
    receipt-typed receipt-legacy receipt-bare receipt-canonical receipt-incomplete receipt-outside \
    receipt-typed-trailing receipt-legacy-trailing receipt-malformed-trailing receipt-canonical-trailing \
    receipt-malformed receipt-missing-link receipt-chain receipt-cycle receipt-missing receipt-unrelated receipt-self; do
  LOG_BASE="$FIXTURE/$scenario/logs/probe"
  OUTPUT_DIR="$FIXTURE/$scenario/output"
  mkdir -p "$OUTPUT_DIR/security/probe"
  a="$OUTPUT_DIR/security/probe/001.md"
  b="$OUTPUT_DIR/security/probe/002.md"
  c="$OUTPUT_DIR/security/probe/003.md"
  write_finding "$a" probe-a duplicate security/probe/002.md
  expected_new=1 expected_duplicates=0 expected_records=1
  case "$scenario" in
    missing-link) write_finding "$a" probe-a duplicate ;;
    invalid) printf 'No frontmatter\n' > "$b" ;;
    self) write_finding "$a" probe-a duplicate security/probe/001.md ;;
    chain)
      write_finding "$b" probe-b duplicate security/probe/003.md
      write_finding "$c" probe-c new
      expected_new=2 expected_duplicates=1 expected_records=3 ;;
    cycle)
      write_finding "$b" probe-b duplicate security/probe/001.md
      expected_new=2 expected_records=2 ;;
    outside)
      write_finding "$FIXTURE/$scenario/outside.md" outside new
      write_finding "$a" probe-a duplicate ../outside.md ;;
    valid)
      write_finding "$b" probe-b new
      expected_duplicates=1 expected_records=2 ;;
    filtered)
      # Match production order: dedupe sees both files; branch scope then
      # preserves the rejected canonical outside the *.md consumer tree.
      write_finding "$a" probe-a ""
      write_finding "$b" probe-b "" "" src/rejected.sh:12
      # The higher severity makes the out-of-scope file canonical.
      sed -i 's/severity: high/severity: critical/' "$b"
      dedupe_local_markdown "$OUTPUT_DIR" >/dev/null 2>&1
      check grep -qE '^status: duplicate$' "$a"
      printf '["src/live.sh"]\n' > "$FIXTURE/$scenario/scope.json"
      MODE=branch-review BRANCH_SCOPE_FILE="$FIXTURE/$scenario/scope.json" \
        branch_scope_filter_directory "$OUTPUT_DIR"
      check test -f "$b.out-of-scope" ;;
    failed-dedupe)
      rc=0
      TMPDIR="$FIXTURE/$scenario/missing-parent" dedupe_local_markdown "$OUTPUT_DIR" \
        >/dev/null 2>&1 || rc=$?
      check test "$rc" -eq 1 ;;
  esac
  if [[ "$scenario" == receipt-* ]]; then
    style="${scenario#receipt-}"
    write_finding "$a" probe-a reviewed security/probe/002.md
    write_finding "$b" probe-b new
    expected_records=2 expected_new=2 expected_duplicates=0
    case "$style" in
      typed|legacy|typed-trailing|legacy-trailing)
        receipt "$a" "${style%-trailing}"
        if [[ "$style" == *-trailing ]]; then
          printf '\n## Follow-up\nKeep this user evidence.\n' >> "$a"
        fi
        expected_new=1 expected_duplicates=1 ;;
      malformed-trailing|canonical-trailing)
        receipt "$a" "${style%-trailing}"
        # A later closing sentinel cannot turn a non-duplicate receipt into one.
        printf '\n<!-- repolens-dedupe:duplicate -->\n<!-- repolens-dedupe:end -->\n' >> "$a" ;;
      chain)
        receipt "$a" typed
        write_finding "$b" probe-b duplicate security/probe/003.md
        write_finding "$c" probe-c new
        expected_records=3 expected_new=2 expected_duplicates=1 ;;
      cycle)
        receipt "$a" typed
        write_finding "$b" probe-b duplicate security/probe/001.md ;;
      missing-link)
        write_finding "$a" probe-a reviewed
        receipt "$a" typed ;;
      missing)
        receipt "$a" typed
        rm "$b"
        expected_records=1 expected_new=1 ;;
      unrelated)
        receipt "$a" typed
        sed -i 's/title:.*/title: Cross-site scripting through template rendering/' "$b" ;;
      self)
        write_finding "$a" probe-a reviewed security/probe/001.md
        receipt "$a" typed ;;
      bare) : ;;
      *) receipt "$a" "$style" ;;
    esac
  fi
  if [[ "$scenario" == missing ]]; then
    # Successful singleton dedupe leaves the stale raw mark untouched.
    dedupe_local_markdown "$OUTPUT_DIR" >/dev/null 2>&1
    check grep -qE '^status: duplicate$' "$a"
  fi
  before="$(sha256sum "$a")"
  build_finding_registry probe "$OUTPUT_DIR"
  findings="$LOG_BASE/final/findings.jsonl"
  check jq -se --argjson n "$expected_records" --argjson actions "$expected_new" --argjson duplicates "$expected_duplicates" \
    'length == $n and (map(select(.status == "new")) | length) == $actions
      and (map(select(.status == "duplicate")) | length) == $duplicates
      and all(has("__local_duplicate_of") | not)' "$findings"
  if (( expected_duplicates )); then
    check jq -se 'map(select(has("also_reported_by"))) | length == 1 and (.[0].also_reported_by | length) == 1' "$findings"
  else
    check jq -se 'all(has("also_reported_by") | not)' "$findings"
  fi
  render_human_review_digest probe
  generate_todo_md "$findings" "$LOG_BASE/final/TODO.md"
  check test "$(grep -cE '^### ' "$LOG_BASE/final/HUMAN_REVIEW.md" || true)" -eq "$expected_new"
  check grep -qE 'Unsafe access to shared state' "$LOG_BASE/final/TODO.md"
  check test "$before" = "$(sha256sum "$a")"
  registry_before="$(sha256sum "$findings")"
  build_finding_registry probe "$OUTPUT_DIR"
  check test "$before" = "$(sha256sum "$a")"
  check test "$registry_before" = "$(sha256sum "$findings")"
  # CSV is a projection of these exact normalized statuses.
  check test "$(tail -n +2 "$LOG_BASE/final/findings.csv" | grep -cE ',"new",' || true)" -eq "$expected_new"
done
printf 'Local duplicate recovery: %s checks, %s failures.\n' "$checks" "$failed"
(( failed == 0 ))
