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


# Exercise the prompt's actual ID recipe through the real verifier dispatcher.
# shellcheck disable=SC2034,SC2329 # Globals and callback are consumed by verify.sh.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO/lib/verify.sh"
# shellcheck source=/dev/null
source "$REPO/lib/template.sh"
set -euo pipefail
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
run_agent() { return 99; }
verify_fixture() {
  python3 - "$2" "$LOG_BASE" "$1" "$PROJECT_PATH" <<'PYVERIFY'
import hashlib, json, re, sys, textwrap
from pathlib import Path
prompt, log_base, run_id, project_path = sys.argv[1:]
assert f"run `{run_id}`" in prompt
assert f"located at `{project_path}`" in prompt
assert "{{RUN_ID}}" not in prompt and "{{PROJECT_PATH}}" not in prompt
recipes = [textwrap.dedent(code) for code in re.findall(r"```python\n(.*?)```", prompt, re.S)
           if "def verifier_finding_id(" in code]
if recipes:
    namespace = {}
    exec(recipes[0], namespace)
    recipe = namespace["verifier_finding_id"]
else:
    # Follow the original documented recipe on the baseline, so its duplicate
    # IDs fail the real validator rather than failing due to a missing API.
    assert "source_relative_path" in prompt and "lens_id\\0domain\\0round" in prompt
    def recipe(lens_id, domain, round_number, suspect_files, source_relative_path, segment_index):
        parts = [lens_id, domain, str(round_number), "\n".join(sorted(suspect_files))]
        if "/" in source_relative_path:
            parts.append(source_relative_path)
        return hashlib.sha1("\0".join(parts).encode()).hexdigest()[:16]
sources = list(Path(log_base).glob("rounds/round-*/lens-outputs/**/*.md"))
assert len(sources) == 1
raw = sources[0]
relative = raw.relative_to(Path(log_base) / "rounds/round-1/lens-outputs").as_posix()
blocks = re.findall(r"^---\n(.*?)^---\n(.*?)(?=^---\n|\Z)", raw.read_text(), re.S | re.M)
assert len(blocks) == 2
rows = []
for index, (frontmatter, body) in enumerate(blocks, 1):
    field = lambda name: re.search(rf"^{name}: (.+)$", frontmatter, re.M)[1]
    suspects = re.findall(r"^  - (.+)$", frontmatter, re.M)
    args = (field("lens_id"), field("domain"), int(field("round")))
    finding_id = recipe(*args, suspects, relative, index)
    assert finding_id == recipe(*args, list(reversed(suspects)), relative, index)
    if index == 1:
        legacy = [*map(str, args), "\n".join(sorted(suspects))]
        if "/" in relative:
            legacy.append(relative)
        assert finding_id == hashlib.sha1("\0".join(legacy).encode()).hexdigest()[:16]
    rows.append(dict(finding_id=finding_id, status="VERIFIED" if index == 1 else "WRONG",
                     notes=body.strip(), lens_id=args[0], domain=args[1], round=args[2],
                     source_finding_path=str(raw)))
print(json.dumps(rows))
PYVERIFY
}
_VERIFIER_AGENT_CALLBACK=verify_fixture
case "${1:-all}" in
  all) layouts=(flat nested) ;;
  flat|nested) layouts=("$1") ;;
  *) exit 2 ;;
esac
for layout in "${layouts[@]}"; do
  PROJECT_PATH="$FIXTURE/$layout/checkout-one" AGENT=mock MODE=bugreport ROUNDS=1
  LOG_BASE="$PROJECT_PATH/logs/probe"
  relative=probe.md
  [[ "$layout" != nested ]] || relative=0123456789abcdef0123456789abcdef/probe.md
  raw="$LOG_BASE/rounds/round-1/lens-outputs/$relative"
  mkdir -p "$(dirname "$raw")"
  for hypothesis in 'Missing authorization permits reads' 'Missing null guard crashes lookup'; do
    printf -- '---\nlens_id: probe\ndomain: generic\nround: 1\nseverity: high\nconfidence: high\nroot_cause_category: logic\nsuspect_files:\n  - src/a.sh:1\n  - src/b.sh:2\n---\n## hypothesis\n%s\n## evidence\nsrc/a.sh:1 and src/b.sh:2\n' "$hypothesis" >> "$raw"
  done
  rc=0
  run_verifier probe || rc=$?
  printf 'layout=%s verifier_rc=%s\n' "$layout" "$rc"
  test "$rc" -eq 0
  validate_verification_manifest "$LOG_BASE/final/verification.json"
  jq -e 'length == 2 and (map(.finding_id) | unique | length) == 2 and map(.status) == ["VERIFIED","WRONG"]' "$LOG_BASE/final/verification.json" >/dev/null
  before="$(sha256sum < "$LOG_BASE/final/verification.json")"
  run_verifier another-run-id
  test "$(sha256sum < "$LOG_BASE/final/verification.json")" = "$before"
  original_manifest="$LOG_BASE/final/verification.json"
  # Recreate the source in another checkout and run directory. Compare IDs
  # separately: source_finding_path must change to point at the new inventory.
  PROJECT_PATH="$FIXTURE/$layout/checkout-two"
  LOG_BASE="$PROJECT_PATH/logs/relocated-run"
  relocated_raw="$LOG_BASE/rounds/round-1/lens-outputs/$relative"
  mkdir -p "$(dirname "$relocated_raw")"
  cp "$raw" "$relocated_raw"
  run_verifier relocated-run
  python3 - "$original_manifest" "$LOG_BASE/final/verification.json" "$relocated_raw" <<'PYRELOCATE'
import json, sys
from pathlib import Path
before, after = (json.loads(Path(path).read_text()) for path in sys.argv[1:3])
assert {row["source_finding_path"] for row in before}.isdisjoint(
    row["source_finding_path"] for row in after)
assert all(row["source_finding_path"] == sys.argv[3] and Path(row["source_finding_path"]).is_file()
           for row in after)
assert [{k: v for k, v in row.items() if k != "source_finding_path"} for row in before] == [
    {k: v for k, v in row.items() if k != "source_finding_path"} for row in after]
PYRELOCATE
  printf 'PASS: distinct stable per-segment IDs, retained first ID, relocated checkout/run: %s\n' "$layout"
done
