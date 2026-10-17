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
set -euo pipefail
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
compose_prompt() { cat "$1"; }
run_agent() { return 99; }
verify_fixture() {
  python3 - "$2" "$raw" "$relative" <<'PYVERIFY'
import hashlib, json, re, sys, textwrap
from pathlib import Path
prompt, raw, relative = sys.argv[1:]
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
blocks = re.findall(r"^---\n(.*?)^---\n(.*?)(?=^---\n|\Z)", Path(raw).read_text(), re.S | re.M)
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
                     source_finding_path=raw))
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
  LOG_BASE="$FIXTURE/$layout" PROJECT_PATH="$FIXTURE" AGENT=mock MODE=bugreport ROUNDS=1
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
  printf 'PASS: distinct stable per-segment IDs, retained first ID: %s\n' "$layout"
done
