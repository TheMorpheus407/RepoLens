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

# Row names match the transition table in docs/finding-registry-schema.md.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
python3 -B - "$REPO" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

REPO = Path(sys.argv[1])
sys.path.insert(0, str(REPO / 'lib'))
from local_dedupe_status import preserve_status

ARCHIVE = 'repolens_dedupe_original_status'
ORIGINAL = 'status\t: "duplicate-pending" # original'
MARK = 'status: duplicate\nduplicate_of: canonical.md'


class Transitions(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.file = self.root / 'finding.md'

    def fixture(self, metadata='', status=ORIGINAL):
        text = '\n'.join(['---', 'title: Unsafe access to shared state',
                          'severity: high', 'domain: security', 'lens: probe-a',
                          metadata, status, '---', 'body', ''])
        self.file.write_text(text)
        return self.file.read_bytes()

    def mark(self, mode='duplicate', succeeds=True):
        addition = MARK if mode == 'duplicate' else ''
        result = subprocess.run(
            ['bash', '-c', 'set -euo pipefail; source "$1/lib/local-dedupe.sh"; '
             '_local_dedupe_mark_file "$2" "$3" "" "$4"',
             'mark', str(REPO), str(self.file), addition, mode],
            capture_output=True, text=True)
        if succeeds:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('preserving', result.stderr)
        self.assertEqual(list(self.root.rglob('*.rldedupe.*')), [])

    def archived(self):
        lines = self.file.read_text().splitlines()
        values = [json.loads(s.split(':', 1)[1]) for s in lines
                  if s.startswith(ARCHIVE + ':')]
        self.assertEqual(values, [ORIGINAL])
        self.assertEqual(lines.count('status: duplicate'), 1)

    def reject(self, mode, direct=False):
        before = self.file.read_bytes()
        if direct:
            with self.assertRaises(ValueError):
                preserve_status(self.file.read_text(), mode)
        else:
            self.mark(mode, succeeds=False)
        self.assertEqual(self.file.read_bytes(), before)

    def test_T01_first_mark(self):
        self.fixture()
        self.mark()
        self.archived()

    def test_T02_repeated_mark_and_retarget(self):
        self.fixture()
        self.mark()
        before = self.file.read_bytes()
        self.mark()
        self.assertEqual(self.file.read_bytes(), before)
        self.file.write_text(self.file.read_text().replace('canonical.md', 'old.md'))
        self.mark()
        self.assertEqual(self.file.read_bytes(), before)
        self.archived()

    def test_T03_custom_canonical_then_mark(self):
        before = self.fixture()
        self.mark('canonical')
        self.assertEqual(self.file.read_bytes(), before)
        self.mark()
        self.archived()

    def test_T04_promote_then_mark_again(self):
        before = self.fixture()
        self.mark()
        self.mark('canonical')
        self.assertEqual(self.file.read_bytes(), before)
        self.mark()
        self.archived()

    def test_T05_depart_then_repeat(self):
        before = self.fixture()
        self.mark()
        self.mark('restore-only')
        self.assertEqual(self.file.read_bytes(), before)
        self.mark('restore-only')
        self.assertEqual(self.file.read_bytes(), before)

    def test_T06_absent_status(self):
        before = self.fixture(status='')
        self.mark()
        self.assertNotIn(ARCHIVE, self.file.read_text())
        self.mark('canonical')
        self.assertEqual(self.file.read_bytes(), before)

    def test_T07_managed_scalar(self):
        for value in ['duplicate', '"duplicate"', "'duplicate'"]:
            self.fixture(status='status \t: ' + value + ' # managed')
            self.mark()
            self.assertNotIn(ARCHIVE, self.file.read_text())
            self.mark('canonical')
            self.assertNotIn('status', self.file.read_text())

    def test_T08_legacy_collision(self):
        self.fixture(status=ORIGINAL + '\n' + MARK)
        self.mark()
        self.archived()
        self.mark('canonical')
        self.assertIn(ORIGINAL, self.file.read_text())

    def test_T09_user_edit_after_mark(self):
        self.fixture()
        self.mark()
        self.file.write_text(self.file.read_text().replace('status: duplicate', 'status: reviewed'))
        for mode in ['duplicate', 'canonical', 'restore-only']:
            self.reject(mode)

    def test_T10_bad_archives(self):
        for value in ['{foreign: data}', '42', '"status: duplicate"', '"status: |"',
                      '"status: >- # block"',
                      '"status: &state pending"', '"status: pending\\nnext"']:
            self.fixture(status=ARCHIVE + ': ' + value + '\n' + MARK)
            for mode in ['duplicate', 'canonical', 'restore-only']:
                self.reject(mode)

    def test_T11_duplicate_archive(self):
        self.fixture()
        self.mark()
        text = self.file.read_text()
        line = next(s for s in text.splitlines() if s.startswith(ARCHIVE + ':'))
        self.file.write_text(text.replace(line, line + '\n' + line))
        for mode in ['duplicate', 'canonical', 'restore-only']:
            self.reject(mode)

    def test_T12_missing_status_or_archive(self):
        self.fixture()
        self.mark()
        self.file.write_text(self.file.read_text().replace('status: duplicate\n', ''))
        for mode in ['duplicate', 'canonical', 'restore-only']:
            self.reject(mode)
        before = self.fixture(status='status: duplicate\nduplicate_of: old.md')
        self.mark('restore-only')
        self.assertEqual(self.file.read_bytes(), before)

    def test_T13_unsupported_status(self):
        for value in ['duplicate\n  pending', '"duplicate\npending: confirmation"',
                      '&state pending', '!!str pending', '*state', '[pending]', '|\n  pending']:
            self.fixture(status='status: ' + value)
            for mode in ['duplicate', 'canonical']:
                self.reject(mode)

    def test_T14_unrelated_multiline_before_mark(self):
        for prefix, closing in [('"', '"'), ("'", "'"), ('&notes "', '"'),
                                ('!!str "', '"'), ('!!str &notes "', '"'),
                                ('["', '"]'), ('{notes: "', '"}')]:
            for key in ['status: pending', 'status: duplicate', 'duplicate_of: old.md',
                        ARCHIVE + ': foreign', 'also_reported_by:']:
                self.fixture('description: ' + prefix + 'Reviewer notes\n' + key
                             + '\nclosing: text' + closing, status='')
                for mode in ['duplicate', 'canonical', 'restore-only']:
                    self.reject(mode, direct=True)
        self.fixture('description: "Reviewer notes\nstatus: pending\nclosing: text"', status='')
        for mode in ['duplicate', 'canonical', 'restore-only']:
            self.reject(mode)

    def test_T15_unsupported_after_mark(self):
        for mode in ['duplicate', 'canonical', 'restore-only']:
            self.fixture()
            self.mark()
            self.file.write_text(self.file.read_text().replace(
                'severity: high', 'description: "notes\nduplicate_of: old.md\nend: text"\nseverity: high'))
            self.reject(mode)

    def test_T16_nested_and_block_controls(self):
        for metadata in ['provenance:\n  status: [pending, reviewed]',
                         'description: |\n  status: "unfinished\n  [brackets',
                         'description: >-\n  status: [draft]',
                         'description: &notes |2-\n  status: "unfinished',
                         'provenance:\n  - description: |\n      status: "unfinished\n    note: [pending]',
                         'provenance:\n  - |\n    status: "unfinished',
                         'description: "Single \\"quoted\\" value"',
                         "description: 'Single ''quoted'' value'",
                         'description: plain apostrophe isn\'t a quoted scalar',
                         'provenance: {status: [pending, "reviewed"]}']:
            before = self.fixture(metadata)
            self.mark()
            self.archived()
            self.mark('restore-only')
            self.assertEqual(self.file.read_bytes(), before)

    def test_T17_nested_sequence_and_quoted_key_boundaries(self):
        for metadata in ['provenance:\n  - description: "notes\nstatus: pending\nend: text"',
                         'provenance:\n  - "notes\nstatus: pending\nend: text"',
                         '"description": "notes\nstatus: pending\nend: text"',
                         '"long key\nstatus: pending\nend": text',
                         '? "long key\nstatus: pending\nend"\n: text',
                         '? [long,\nstatus: pending]\n: text',
                         'provenance:\n  - description: |\n      block text\n    note: "notes\nstatus: pending\nend: text"',
                         'provenance:\n  - - description: >\n        block text\n      note: "notes\nstatus: pending\nend: text"',
                         'description: [pending,\nstatus: reviewed]',
                         'description: {notes: pending,\nstatus: reviewed}']:
            self.fixture(metadata, status='')
            for mode in ['duplicate', 'canonical', 'restore-only']:
                self.reject(mode, direct=True)
        self.fixture('provenance:\n  - description: |\n      text\n    note: "notes\nstatus: pending\nend: text"', status='')
        self.reject('duplicate')

    def test_T19_root_sequence_preservation(self):
        for sibling in ['', '\n  description: text']:
            for indent in ['', '  ']:
                preamble = '\n# user metadata\n' + indent + '- provenance:\n' + indent + '  status: reviewed'
                preamble += sibling.replace('\n', '\n' + indent) + '\n'
                for remainder in ['', self.fixture().decode().split('---\n')[1]]:
                    self.file.write_text('---\n' + preamble + remainder + '---\nbody\n')
                    for mode in ['duplicate', 'canonical', 'restore-only']:
                        self.reject(mode)

    def test_T18_registry_before_after_and_departure(self):
        self.fixture('description: "Reviewer notes\nstatus: pending\nclosing: text"', status='')
        other = self.root / 'canonical.md'
        other.write_text('---\ntitle: Unsafe access to shared state\nseverity: critical\n'
                         'domain: security\nlens: probe-b\n---\nbody\n')
        before = self.file.read_bytes()
        script = ('set -euo pipefail; source "$1/lib/local-dedupe.sh"; '
                  'source "$1/lib/ledger.sh"; '
                  'build_findings_jsonl_from_local "$2" "$3"; '
                  'dedupe_local_markdown "$2"; '
                  'build_findings_jsonl_from_local "$2" "$4"')
        env = dict(os.environ, LOG_BASE=str(self.root / 'logs'))
        for phase in ['first', 'repeat', 'depart']:
            if phase == 'depart':
                other.write_text(other.read_text().replace(
                    'Unsafe access to shared state', 'Credentials exposed in request logs'))
            result = subprocess.run(['bash', '-c', script, 'group', str(REPO),
                                     str(self.root), str(self.root / 'before.jsonl'),
                                     str(self.root / 'after.jsonl')], env=env,
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.file.read_bytes(), before)
            for name in ['before.jsonl', 'after.jsonl']:
                records = [json.loads(s) for s in (self.root / name).read_text().splitlines()]
                self.assertEqual(len(records), 2)
                self.assertTrue(all(r['status'] == 'new' for r in records), records)


unittest.main(argv=[sys.argv[0]], verbosity=2)
PY
