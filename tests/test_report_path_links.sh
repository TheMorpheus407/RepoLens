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

# repolens-r9-p2-3: report links must resolve to the actual finding files.
# Exercise real manifest ingestion and all public Markdown report writers.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for lib in ledger artifacts human_review; do
  # shellcheck source=/dev/null
  source "$ROOT/lib/$lib.sh"
done
TMPROOT="$(mktemp -d)"
trap 'rm -rf -- "$TMPROOT"' EXIT
for variant in plain spaces special autolink html newlines crlf markup; do
  case "$variant" in
    plain) project="$TMPROOT/project" ;;
    autolink) project="$TMPROOT/project <a@b.com> <https://example.com>" ;;
    html) project="$TMPROOT/project <em>evidence</em>" ;;
    newlines) project="$TMPROOT/"$'project\n\nevidence' ;;
    crlf) project="$TMPROOT/"$'project\r\n\r\nevidence' ;;
    markup) project="$TMPROOT/"'project &copy; `code` *emphasis* _under_ !' ;;
    spaces) project="$TMPROOT/project with spaces" ;;
    special) project="$TMPROOT/project [ä] with \\ spaces #?%" ;;
  esac
  LOG_BASE="$TMPROOT/run-$variant"
  export PROJECT_PATH="$project"
  mkdir -p "$LOG_BASE/final" "$project"
  path="$project/finding (a)[b].md"
  [[ "$variant" != plain ]] || path="$project/finding.md"
  contributor="$project/contributor.md"
  printf 'Original evidence\n' > "$path"
  printf 'Contributor evidence\n' > "$contributor"
  jq -n --arg path "$path" '[{cluster_id:"approved",title:"Approved finding",domain:"security",lens:"injection",severity:"high",source_finding_paths:[$path],verification_status:"verified"}]' > "$LOG_BASE/final/manifest.json"
  build_finding_registry report-links ''
  # Public writer fixture adds convergence and external review metadata to the
  # real ingested record; both paths refer to existing local evidence files.
  jq -c --arg contributor "$contributor" '. + {validation:{suggested_validation:"needs external scanner"},also_reported_by:[{domain:"security",lens:"auth",markdown_path:$contributor}]}' "$LOG_BASE/final/findings.jsonl" > "$LOG_BASE/final/report-fixture.jsonl"
  registry="$LOG_BASE/final/report-fixture.jsonl"
  generate_todo_md "$registry" "$LOG_BASE/final/TODO.md"
  generate_summary_md "$registry" "$LOG_BASE/final/SUMMARY.md"
  generate_needs_review_md "$registry" "$LOG_BASE/final/NEEDS_REVIEW.md"
  generate_duplicates_md "$registry" "$LOG_BASE/final/DUPLICATES.md"
  render_human_review_digest report-links
  printf '%s\n' "$path" > "$LOG_BASE/expected-path.txt"
  printf '%s\n' "$contributor" > "$LOG_BASE/expected-contributor.txt"
done
# Standalone local ingestion must bind a relative root to its calling cwd.
# Reports live elsewhere, so their links cannot depend on that cwd afterward.
for variant in local-relative local-relative-special; do (
  project="$TMPROOT/$variant"
  export PROJECT_PATH="$project"
  local_root=findings
  [[ "$variant" != local-relative-special ]] || local_root='findings [ä] #?%'
  LOG_BASE="$TMPROOT/run-$variant"
  mkdir -p "$project/$local_root" "$LOG_BASE/final"
  cd "$project"
  path="$project/$local_root/finding (a)[b].md"
  contributor="$project/contributor.md"
  printf -- '---\ntitle: Approved local finding\nseverity: high\ndomain: security\nlens: injection\n---\nEvidence\n' > "$path"
  printf 'Contributor evidence\n' > "$contributor"
  build_finding_registry report-links "$local_root" false
  jq -c --arg contributor "$contributor" '. + {validation:{suggested_validation:"needs external scanner"},also_reported_by:[{domain:"security",lens:"auth",markdown_path:$contributor}]}' "$LOG_BASE/final/findings.jsonl" > "$LOG_BASE/final/report-fixture.jsonl"
  registry="$LOG_BASE/final/report-fixture.jsonl"
  generate_todo_md "$registry" "$LOG_BASE/final/TODO.md"
  generate_summary_md "$registry" "$LOG_BASE/final/SUMMARY.md"
  generate_needs_review_md "$registry" "$LOG_BASE/final/NEEDS_REVIEW.md"
  generate_duplicates_md "$registry" "$LOG_BASE/final/DUPLICATES.md"
  render_human_review_digest report-links
  printf '%s\n' "$path" > "$LOG_BASE/expected-path.txt"
  printf '%s\n' "$contributor" > "$LOG_BASE/expected-contributor.txt"
); done
python3 - "$TMPROOT" <<'PYTEST'
import os,pathlib,re,sys,urllib.parse
# The normal suite needs only stdlib. The optional replay also checks the full
# CommonMark token tree (REPOLENS_TEST_COMMONMARK=1 requires markdown-it-py).
parser = None
if os.environ.get('REPOLENS_TEST_COMMONMARK') == '1':
    from markdown_it import MarkdownIt
    parser = MarkdownIt('commonmark')
root=pathlib.Path(sys.argv[1]);passed=failed=0
for variant in ('plain','spaces','special','autolink','html','newlines','crlf','markup','local-relative','local-relative-special'):
    run=root/f'run-{variant}'
    path=(run/'expected-path.txt').read_bytes().decode().removesuffix('\n')
    contributor=(run/'expected-contributor.txt').read_bytes().decode().removesuffix('\n')
    for name in ('TODO','SUMMARY','NEEDS_REVIEW','DUPLICATES','HUMAN_REVIEW'):
        doc=(run/'final'/f'{name}.md').read_text()
        # Require a single-line plain-text label: no raw Markdown/HTML syntax
        # or entities that can change the displayed filename or create links.
        links=re.findall(r'\[((?:\\[^\r\n]|[^\]\\\r\n])*)\]\(([^)\s]+)\)',doc)
        expected=[path,contributor] if name=='DUPLICATES' else [path]
        hrefs=[href for _,href in links]
        wanted=[urllib.parse.quote(p,safe='/~') for p in expected]
        ok=sorted(hrefs)==sorted(wanted)
        labels=[]
        for label,_ in links:
            ok=ok and not re.search(r'(?<!\\)[<>&`*_!]',label)
            labels.append(re.sub(r'\\([!-/:-@\[-`{-~])',r'\1',label))
        normalized=[p.replace('\r',' ').replace('\n',' ') for p in expected]
        ok=ok and sorted(labels)==sorted(normalized)
        if parser:
            rendered=[]
            for token in parser.parse(doc):
                if token.type != 'inline':
                    continue
                depth=0
                text=''
                for child in token.children:
                    if child.type=='link_open':
                        ok=ok and depth==0
                        depth+=1
                        href=child.attrGet('href')
                        text=''
                    elif child.type=='link_close':
                        depth-=1
                        rendered.append((href,text))
                    elif depth:
                        ok=ok and child.type=='text'
                        text+=child.content
            ok=ok and sorted(rendered)==sorted(zip(wanted,normalized))
        ok=ok and all((run/'final'/urllib.parse.unquote(href)).is_file() for href in hrefs)
        if variant=='plain':
            ok=ok and f'[{path}]({path})' in doc
        if ok:passed+=1;print(f'PASS: {variant}/{name} links resolve to exact original files')
        else:failed+=1;print(f'FAIL: {variant}/{name}: hrefs={hrefs!r}, expected={wanted!r}')
print(f'Results: {passed} passed, {failed} failed')
sys.exit(bool(failed))
PYTEST
