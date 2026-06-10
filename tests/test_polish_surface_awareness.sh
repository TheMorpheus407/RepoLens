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

# Tests for issue #303: polish-mode surface-aware lens gating.
#
# The behavioral contract is the public dry-run fanout:
# - CLI/backend polish targets skip visual fluency lenses.
# - Effort-signal and hedonic polish lenses still run for CLI/backend targets.
# - UI polish targets run the full polish lens set.
# - Explicit visual-fluency overrides on CLI/backend targets fail before a run.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOLENS_SH="$SCRIPT_DIR/repolens.sh"

PASS=0
FAIL=0
TOTAL=0

TMP_PARENT="$SCRIPT_DIR/test-work-polish-surface-awareness"
mkdir -p "$TMP_PARENT"
TMPDIR="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"
CREATED_RUN_IDS=()

cleanup() {
  local run_id
  rm -rf "$TMPDIR"
  for run_id in "${CREATED_RUN_IDS[@]:-}"; do
    [[ -n "$run_id" ]] && rm -rf "$SCRIPT_DIR/logs/$run_id"
  done
  rmdir "$TMP_PARENT" 2>/dev/null || true
}
trap cleanup EXIT

pass_with() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

fail_with() {
  local desc="$1" detail="${2:-}"
  FAIL=$((FAIL + 1))
  echo "  FAIL: $desc"
  [[ -n "$detail" ]] && printf '    %s\n' "$detail"
}

assert_success() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -eq 0 ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected exit 0, got $actual"
  fi
}

assert_failure() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -ne 0 ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected non-zero exit, got 0"
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected: '$expected' | Actual: '${actual:-<empty>}'"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected to find '$needle'"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Did not expect to find '$needle'"
  fi
}

assert_matches() {
  local desc="$1" pattern="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if grep -qiE -- "$pattern" <<< "$haystack"; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected to match regex '$pattern'"
  fi
}

register_run_id_from() {
  local out_file="$1" run_id
  run_id="$(grep -oE 'RepoLens run [^ ]+ starting' "$out_file" 2>/dev/null | head -1 | awk '{print $3}')"
  [[ -n "$run_id" ]] && CREATED_RUN_IDS+=("$run_id")
}

extract_lens_entries() {
  local out_file="$1"
  awk '
    /^Lenses that would run:/ { in_list = 1; next }
    in_list && /^[[:space:]]*$/ { in_list = 0; next }
    in_list { gsub(/^[[:space:]]+/, "", $0); print }
  ' "$out_file"
}

count_lens_entries() {
  local out_file="$1"
  extract_lens_entries "$out_file" | sed '/^$/d' | wc -l | tr -d ' '
}

run_polish_dry() {
  local project="$1" out_file="$2"
  shift 2
  bash "$REPOLENS_SH" \
    --project "$project" \
    --agent claude \
    --mode polish \
    --local \
    --dry-run \
    --yes \
    --output "$TMPDIR/issues" \
    "$@" \
    >"$out_file" 2>&1
  local rc=$?
  register_run_id_from "$out_file"
  return "$rc"
}

make_cli_project() {
  local project="$1"
  mkdir -p "$project/bin"
  printf '# CLI polish fixture\n' > "$project/README.md"
  cat > "$project/bin/repolens-demo" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --help|-h)
    echo "Usage: repolens-demo [--help] <path>"
    ;;
  *)
    echo "Inspecting ${1:-.}"
    ;;
esac
SH
  chmod +x "$project/bin/repolens-demo"
}

make_docs_only_project() {
  local project="$1"
  make_cli_project "$project"
  mkdir -p "$project/docs"
  cat > "$project/docs/index.html" <<'HTML'
<!doctype html>
<title>CLI polish fixture docs</title>
HTML
}

make_root_static_project() {
  local project="$1"
  mkdir -p "$project"
  cat > "$project/index.html" <<'HTML'
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <title>Root static polish fixture</title>
    <link rel="stylesheet" href="./style.css">
  </head>
  <body>
    <main class="shell">
      <h1>Root static polish fixture</h1>
    </main>
  </body>
</html>
HTML
  cat > "$project/style.css" <<'CSS'
.shell {
  max-width: 42rem;
  margin: 3rem auto;
  font-family: system-ui, sans-serif;
}
CSS
}

make_package_only_ui_project() {
  local project="$1"
  mkdir -p "$project"
  cat > "$project/package.json" <<'JSON'
{
  "name": "polish-package-ui-fixture",
  "private": true,
  "dependencies": {
    "next": "^15.0.0",
    "react": "^19.0.0"
  }
}
JSON
}

make_ui_project() {
  local project="$1"
  mkdir -p "$project/src"
  cat > "$project/package.json" <<'JSON'
{
  "name": "polish-ui-fixture",
  "private": true,
  "dependencies": {
    "@vitejs/plugin-react": "^5.0.0",
    "vite": "^7.0.0",
    "react": "^19.0.0",
    "react-dom": "^19.0.0"
  }
}
JSON
  cat > "$project/src/App.tsx" <<'TSX'
export function App() {
  return <main><h1>Polish UI fixture</h1></main>;
}
TSX
}

make_mixed_ui_project() {
  local project="$1"
  make_cli_project "$project"
  mkdir -p "$project/src"
  cat > "$project/src/StatusPanel.svelte" <<'SVELTE'
<script>
  export let status = "ready";
</script>

<main>
  <h1>Mixed polish fixture: {status}</h1>
</main>
SVELTE
}

make_flutter_project() {
  local project="$1"
  mkdir -p "$project"
  cat > "$project/pubspec.yaml" <<'YAML'
name: polish_flutter_fixture
publish_to: none
dependencies:
  flutter:
    sdk: flutter
YAML
}

make_android_layout_project() {
  local project="$1"
  mkdir -p "$project/app/src/main/res/layout"
  cat > "$project/app/src/main/res/layout/activity_main.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<LinearLayout xmlns:android="http://schemas.android.com/apk/res/android"
  android:layout_width="match_parent"
  android:layout_height="match_parent"
  android:orientation="vertical">
</LinearLayout>
XML
}

assert_cli_backend_lenses() {
  local desc_prefix="$1" out_file="$2" lenses
  lenses="$(extract_lens_entries "$out_file")"

  assert_eq "$desc_prefix queues ten polish lenses" "10" "$(count_lens_entries "$out_file")"
  assert_not_contains "$desc_prefix skips fluency polish lenses" "fluency/" "$lenses"

  assert_contains "$desc_prefix keeps effort-signal/empty-states" "effort-signal/empty-states" "$lenses"
  assert_contains "$desc_prefix keeps effort-signal/loading-transparency" "effort-signal/loading-transparency" "$lenses"
  assert_contains "$desc_prefix keeps effort-signal/forgotten-corners" "effort-signal/forgotten-corners" "$lenses"
  assert_contains "$desc_prefix keeps hedonic/voice-and-microcopy" "hedonic/voice-and-microcopy" "$lenses"
  assert_contains "$desc_prefix keeps hedonic/fitting-easter-eggs" "hedonic/fitting-easter-eggs" "$lenses"
}

assert_only_fluency_lenses() {
  local desc_prefix="$1" out_file="$2" lenses
  lenses="$(extract_lens_entries "$out_file")"

  assert_eq "$desc_prefix queues six fluency lenses" "6" "$(count_lens_entries "$out_file")"
  assert_contains "$desc_prefix keeps fluency/contrast-figure-ground" "fluency/contrast-figure-ground" "$lenses"
  assert_contains "$desc_prefix keeps fluency/alignment-symmetry" "fluency/alignment-symmetry" "$lenses"
  assert_contains "$desc_prefix keeps fluency/typographic-rhythm" "fluency/typographic-rhythm" "$lenses"
  assert_not_contains "$desc_prefix excludes effort-signal lenses" "effort-signal/" "$lenses"
  assert_not_contains "$desc_prefix excludes hedonic lenses" "hedonic/" "$lenses"
}

assert_all_polish_lenses() {
  local desc_prefix="$1" out_file="$2" lenses
  lenses="$(extract_lens_entries "$out_file")"

  assert_eq "$desc_prefix queues sixteen polish lenses" "16" "$(count_lens_entries "$out_file")"
  assert_contains "$desc_prefix keeps fluency/contrast-figure-ground" "fluency/contrast-figure-ground" "$lenses"
  assert_contains "$desc_prefix keeps fluency/typographic-rhythm" "fluency/typographic-rhythm" "$lenses"
  assert_contains "$desc_prefix keeps effort-signal/empty-states" "effort-signal/empty-states" "$lenses"
  assert_contains "$desc_prefix keeps hedonic/voice-and-microcopy" "hedonic/voice-and-microcopy" "$lenses"
}

echo ""
echo "=== Test Suite: polish surface-awareness gating (issue #303) ==="
echo ""

FAKE_BIN="$TMPDIR/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/claude" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FAKE_BIN/claude"
export PATH="$FAKE_BIN:$PATH"

CLI_PROJECT="$TMPDIR/project-cli"
DOCS_PROJECT="$TMPDIR/project-docs-only"
ROOT_STATIC_PROJECT="$TMPDIR/project-root-static"
PACKAGE_UI_PROJECT="$TMPDIR/project-package-ui"
UI_PROJECT="$TMPDIR/project-ui"
MIXED_UI_PROJECT="$TMPDIR/project-mixed-ui"
FLUTTER_PROJECT="$TMPDIR/project-flutter"
ANDROID_LAYOUT_PROJECT="$TMPDIR/project-android-layout"
make_cli_project "$CLI_PROJECT"
make_docs_only_project "$DOCS_PROJECT"
make_root_static_project "$ROOT_STATIC_PROJECT"
make_package_only_ui_project "$PACKAGE_UI_PROJECT"
make_ui_project "$UI_PROJECT"
make_mixed_ui_project "$MIXED_UI_PROJECT"
make_flutter_project "$FLUTTER_PROJECT"
make_android_layout_project "$ANDROID_LAYOUT_PROJECT"

echo "Test 1: CLI/backend polish target skips visual-fluency lenses"
CLI_OUT="$TMPDIR/cli-dry-run.log"
run_polish_dry "$CLI_PROJECT" "$CLI_OUT"
cli_rc=$?
cli_output="$(cat "$CLI_OUT")"
assert_success "CLI/backend polish dry-run exits 0" "$cli_rc"
assert_cli_backend_lenses "CLI/backend polish target" "$CLI_OUT"
assert_contains "CLI/backend surface is logged" "Polish surface: cli-backend" "$cli_output"
assert_contains "CLI/backend dry-run completes" "Dry run complete" "$cli_output"

echo ""
echo "Test 2: UI polish target runs all polish lenses"
UI_OUT="$TMPDIR/ui-dry-run.log"
run_polish_dry "$UI_PROJECT" "$UI_OUT"
ui_rc=$?
ui_output="$(cat "$UI_OUT")"
assert_success "UI polish dry-run exits 0" "$ui_rc"
assert_all_polish_lenses "UI polish target" "$UI_OUT"
assert_contains "UI surface is logged" "Polish surface: visual-ui" "$ui_output"
assert_contains "UI dry-run completes" "Dry run complete" "$ui_output"

echo ""
echo "Test 3: package-only UI target runs all polish lenses"
PACKAGE_UI_OUT="$TMPDIR/package-ui-dry-run.log"
run_polish_dry "$PACKAGE_UI_PROJECT" "$PACKAGE_UI_OUT"
package_ui_rc=$?
package_ui_output="$(cat "$PACKAGE_UI_OUT")"
assert_success "package-only UI polish dry-run exits 0" "$package_ui_rc"
assert_all_polish_lenses "package-only UI polish target" "$PACKAGE_UI_OUT"
assert_contains "package-only UI surface is logged" "Polish surface: visual-ui" "$package_ui_output"

echo ""
echo "Test 4: mixed CLI plus UI source target runs all polish lenses"
MIXED_UI_OUT="$TMPDIR/mixed-ui-dry-run.log"
run_polish_dry "$MIXED_UI_PROJECT" "$MIXED_UI_OUT"
mixed_ui_rc=$?
mixed_ui_output="$(cat "$MIXED_UI_OUT")"
assert_success "mixed UI polish dry-run exits 0" "$mixed_ui_rc"
assert_all_polish_lenses "mixed UI polish target" "$MIXED_UI_OUT"
assert_contains "mixed UI surface is logged" "Polish surface: visual-ui" "$mixed_ui_output"

echo ""
echo "Test 5: root static HTML/CSS target runs all polish lenses"
ROOT_STATIC_OUT="$TMPDIR/root-static-dry-run.log"
run_polish_dry "$ROOT_STATIC_PROJECT" "$ROOT_STATIC_OUT"
root_static_rc=$?
root_static_output="$(cat "$ROOT_STATIC_OUT")"
assert_success "root static polish dry-run exits 0" "$root_static_rc"
assert_all_polish_lenses "root static polish target" "$ROOT_STATIC_OUT"
assert_contains "root static surface is logged" "Polish surface: visual-ui" "$root_static_output"
assert_contains "root static dry-run completes" "Dry run complete" "$root_static_output"

echo ""
echo "Test 6: mobile UI markers run all polish lenses"
FLUTTER_OUT="$TMPDIR/flutter-dry-run.log"
run_polish_dry "$FLUTTER_PROJECT" "$FLUTTER_OUT"
flutter_rc=$?
flutter_output="$(cat "$FLUTTER_OUT")"
assert_success "Flutter polish dry-run exits 0" "$flutter_rc"
assert_all_polish_lenses "Flutter polish target" "$FLUTTER_OUT"
assert_contains "Flutter surface is logged" "Polish surface: visual-ui" "$flutter_output"

ANDROID_LAYOUT_OUT="$TMPDIR/android-layout-dry-run.log"
run_polish_dry "$ANDROID_LAYOUT_PROJECT" "$ANDROID_LAYOUT_OUT"
android_layout_rc=$?
android_layout_output="$(cat "$ANDROID_LAYOUT_OUT")"
assert_success "Android layout polish dry-run exits 0" "$android_layout_rc"
assert_all_polish_lenses "Android layout polish target" "$ANDROID_LAYOUT_OUT"
assert_contains "Android layout surface is logged" "Polish surface: visual-ui" "$android_layout_output"

echo ""
echo "Test 7: docs-only HTML does not make a CLI/backend target visual"
DOCS_OUT="$TMPDIR/docs-dry-run.log"
run_polish_dry "$DOCS_PROJECT" "$DOCS_OUT"
docs_rc=$?
docs_output="$(cat "$DOCS_OUT")"
assert_success "docs-only polish dry-run exits 0" "$docs_rc"
assert_cli_backend_lenses "docs-only CLI/backend polish target" "$DOCS_OUT"
assert_contains "docs-only surface is logged" "Polish surface: cli-backend" "$docs_output"

echo ""
echo "Test 8: visual-fluency overrides are rejected on CLI/backend polish targets"
DOMAIN_OUT="$TMPDIR/domain-fluency.log"
run_polish_dry "$CLI_PROJECT" "$DOMAIN_OUT" --domain fluency
domain_rc=$?
domain_output="$(cat "$DOMAIN_OUT")"
assert_failure "CLI/backend rejects --domain fluency" "$domain_rc"
assert_not_contains "rejected --domain does not reach dry-run completion" "Dry run complete" "$domain_output"
assert_not_contains "rejected --domain does not queue fluency lenses" "fluency/" "$(extract_lens_entries "$DOMAIN_OUT")"
assert_matches "rejected --domain explains the polish domain is unavailable" "Domain 'fluency' not found|not applicable|not available|wrong[- ]surface|current polish surface" "$domain_output"

FOCUS_OUT="$TMPDIR/focus-typographic-rhythm.log"
run_polish_dry "$CLI_PROJECT" "$FOCUS_OUT" --focus typographic-rhythm
focus_rc=$?
focus_output="$(cat "$FOCUS_OUT")"
assert_failure "CLI/backend rejects --focus typographic-rhythm" "$focus_rc"
assert_not_contains "rejected --focus does not reach dry-run completion" "Dry run complete" "$focus_output"
assert_not_contains "rejected --focus does not queue typographic rhythm" "fluency/typographic-rhythm" "$(extract_lens_entries "$FOCUS_OUT")"
assert_matches "rejected --focus explains the polish lens is unavailable" "Lens 'typographic-rhythm' not found|not applicable|not available|wrong[- ]surface|current polish surface" "$focus_output"

echo ""
echo "Test 9: relevant-domain filtering respects the polish surface gate"
RD_CLI_OUT="$TMPDIR/relevant-domains-cli-fluency.log"
run_polish_dry "$CLI_PROJECT" "$RD_CLI_OUT" --relevant-domains fluency
rd_cli_rc=$?
rd_cli_output="$(cat "$RD_CLI_OUT")"
assert_failure "CLI/backend rejects --relevant-domains fluency" "$rd_cli_rc"
assert_not_contains "rejected --relevant-domains does not reach dry-run completion" "Dry run complete" "$rd_cli_output"
assert_not_contains "rejected --relevant-domains does not queue fluency lenses" "fluency/" "$(extract_lens_entries "$RD_CLI_OUT")"
assert_matches "rejected --relevant-domains explains fluency is unavailable" "--relevant-domains: domain id 'fluency'.*current polish surface|not available|wrong[- ]surface" "$rd_cli_output"

RD_UI_OUT="$TMPDIR/relevant-domains-ui-fluency.log"
run_polish_dry "$UI_PROJECT" "$RD_UI_OUT" --relevant-domains fluency
rd_ui_rc=$?
assert_success "UI accepts --relevant-domains fluency" "$rd_ui_rc"
assert_only_fluency_lenses "UI --relevant-domains fluency" "$RD_UI_OUT"

echo ""
echo "Test 10: visual UI targets still allow explicit fluency domain and focus"
UI_DOMAIN_OUT="$TMPDIR/ui-domain-fluency.log"
run_polish_dry "$UI_PROJECT" "$UI_DOMAIN_OUT" --domain fluency
ui_domain_rc=$?
assert_success "UI accepts --domain fluency" "$ui_domain_rc"
assert_only_fluency_lenses "UI --domain fluency" "$UI_DOMAIN_OUT"

UI_FOCUS_OUT="$TMPDIR/ui-focus-typographic-rhythm.log"
run_polish_dry "$UI_PROJECT" "$UI_FOCUS_OUT" --focus typographic-rhythm
ui_focus_rc=$?
ui_focus_lenses="$(extract_lens_entries "$UI_FOCUS_OUT")"
assert_success "UI accepts --focus typographic-rhythm" "$ui_focus_rc"
assert_eq "UI --focus queues one lens" "1" "$(count_lens_entries "$UI_FOCUS_OUT")"
assert_eq "UI --focus selects fluency/typographic-rhythm" "fluency/typographic-rhythm" "$ui_focus_lenses"

echo ""
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
