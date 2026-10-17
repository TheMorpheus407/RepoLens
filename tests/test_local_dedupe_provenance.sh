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

# repolens-r9-p3-2: delivered canonical YAML must preserve every contributor.
# Real ingestion/grouping/surgery; no model or forge calls, stdlib-only checks.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/local-dedupe.sh
source "$ROOT/lib/local-dedupe.sh"
TMPROOT="$(mktemp -d)"
trap 'rm -rf -- "$TMPROOT"' EXIT
for variant in flat backslash-root missing-domain missing-lens special-path newline-path; do
  output="$TMPROOT/$variant"
  [[ "$variant" != backslash-root ]] || output="$output/with\\backslash"
  mkdir -p "$output"
  contributor='b.md'
  [[ "$variant" != special-path ]] || contributor=$'b back\\slash: [x]\t#?.md'
  [[ "$variant" != newline-path ]] || contributor=$'b\n\nx.md'
  lens='' domain=''
  case "$variant" in
    backslash-root|special-path|newline-path) lens=auth; domain=security ;;
    missing-domain) lens=auth ;;
    missing-lens) domain=security ;;
  esac
  for name in a.md "$contributor"; do
    severity=high
    [[ "$name" == a.md ]] || severity=low
    {
      printf -- '---\ntitle: Missing authorization permits unauthorized account deletion\nseverity: %s\n' "$severity"
      [[ -z "$lens" ]] || printf 'lens: %s\n' "$lens"
      [[ -z "$domain" ]] || printf 'domain: %s\n' "$domain"
      printf -- '---\nEvidence: src/account.sh:10\n'
    } > "$output/$name"
  done
  jq -n --arg root "$output" --arg lens "$lens" --arg domain "$domain" --arg path "$contributor" \
    '{root:$root,expected:{lens:$lens,domain:$domain,markdown_path:$path}}' > "$TMPROOT/$variant-expected.json"
  dedupe_local_markdown "$output///"
  python3 - "$output" "$TMPROOT/$variant-first.json" <<'HASH'
import hashlib,json,pathlib,sys
root=pathlib.Path(sys.argv[1])
pathlib.Path(sys.argv[2]).write_text(json.dumps({str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in root.glob('*.md')}))
HASH
  dedupe_local_markdown "$output///"
done
python3 - "$TMPROOT" <<'VERIFY'
import hashlib,json,pathlib,re,sys
root=pathlib.Path(sys.argv[1]);passed=failed=0
for case in sorted(root.glob('*-expected.json')):
    variant=case.name.removesuffix('-expected.json');fixture=json.loads(case.read_text())
    output=pathlib.Path(fixture['root']);doc=(output/'a.md').read_text()
    block=doc.split('also_reported_by:\n',1)[-1].split('\n---',1)[0]
    actual={};parse_ok=True
    # Decode the generated scalar subset independently. JSON strings are valid
    # quoted YAML scalars; plain paths/IDs remain readable for ordinary values.
    for line in block.splitlines():
        m=re.fullmatch(r'  (?:- |  )(lens|domain|markdown_path): ?(.*)',line)
        if not m:parse_ok=False;continue
        key,value=m.groups()
        try:actual[key]=json.loads(value) if value.startswith('"') else value
        except ValueError:parse_ok=False
    checks={
        'lossless optional fields and relative path':parse_ok and actual==fixture['expected'],
        'contributor path resolves to original file':bool(actual.get('markdown_path')) and not pathlib.Path(actual['markdown_path']).is_absolute() and (output/actual['markdown_path']).is_file(),
        'canonical remains a non-duplicate':not re.search(r'^status: duplicate$',doc,re.M),
    }
    hashes={str(p.relative_to(output)):hashlib.sha256(p.read_bytes()).hexdigest() for p in output.glob('*.md')}
    checks['second pass is byte-identical']=hashes==json.loads((root/f'{variant}-first.json').read_text())
    for name,ok in checks.items():
        if ok:passed+=1;print(f'PASS: {variant}: {name}')
        else:failed+=1;print(f'FAIL: {variant}: {name}; got {actual!r}')
print(f'Results: {passed} passed, {failed} failed')
sys.exit(bool(failed))
VERIFY
