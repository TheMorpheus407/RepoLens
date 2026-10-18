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

# Receipt repair must preserve snapshots, unbounded identities, and accounting.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$REPO" "${1:-all}" <<'PYTEST'
from pathlib import Path
import os
import subprocess
import sys
import tempfile
import time
repo = Path(os.environ.get("REPOLENS_TEST_REPO", sys.argv[1]))
case = sys.argv[2]
base = r"""
set -euo pipefail
source "$1/lib/rounds.sh"
source "$1/lib/attempts.sh"
eval "$(sed -n '/^mark_lens_completed() {/,/^}/p' "$1/repolens.sh")"
completed_lenses_file="$2"
"""
def run(code, receipt, *args, **kwargs):
    return subprocess.run(['bash', '-c', base + code, '_', str(repo), str(receipt), *args], **kwargs)
def wait_file(path):
    deadline = time.monotonic() + 5
    while not path.exists():
        assert time.monotonic() < deadline, f'timed out: {path}'
        time.sleep(.005)
with tempfile.TemporaryDirectory() as root:
    root = Path(root)
    receipt = root / '.completed'
    if case in ('all', 'large'):
        result = run(r'''printf -v padding '%262144s' ''
entry="security/injection|deeper|$padding|anchor|exclude"
mark_lens_completed "$entry"
_rounds_all_lenses_completed "$completed_lenses_file" "$entry"
''', receipt)
        assert result.returncode == 0, 'oversized identity was not persisted'
        assert len(receipt.read_bytes()) > 262144
    if case in ('all', 'empty'):
        for contents in (b'', b'interrupted'):
            receipt.write_bytes(contents)
            assert run('_rounds_all_lenses_completed "$completed_lenses_file"', receipt).returncode == 0, 'empty selection must complete'
            assert run('_rounds_all_lenses_completed "$completed_lenses_file" security/injection', receipt).returncode == 1
    if case in ('all', 'accounting'):
        for receipt in (root / '.completed', root / '.rounds/round-1.lenses.completed'):
            receipt.parent.mkdir(exist_ok=True)
            receipt.write_bytes(b'security/xss-csrf\ninterrupted')
            result = run(r'''log_warn() { printf '%s\n' "$*" >&2; }
attempts_begin "$3"
mark_lens_completed security/injection
attempts_finalize "$3" finished '' 0
jq -e 'last | .lenses_completed_this_attempt == 1 and .lenses_completed_total == 2' "$3/attempts.json"
''', receipt, str(root))
            assert result.returncode == 0, 'repair undercounted resumed completion'
            receipt.unlink()
    if case in ('all', 'status'):
        receipt = root / '.completed'
        receipt.write_bytes(b'security/xss-csrf\nsecurity/injection')
        (root / '.status-lenses').write_bytes(b'security/xss-csrf\nsecurity/injection\n')
        result = run(r'''source "$1/lib/status.sh"
write_status_snapshot running probe "$3" "$3/.heartbeat" "$completed_lenses_file" "$3/summary.json" /tmp/project owner/repo audit mock false 1 "$3/.status-lenses"
jq -e '.completed == ["security/xss-csrf"] and .queued == ["security/injection"] and .counts.completed == 1' "$3/status.json"
''', receipt, str(root))
        assert result.returncode == 0, 'status certified an unterminated receipt'
    if case in ('all', 'race'):
        receipt = root / '.completed'
        receipt.write_bytes(b'security/injection|deeper|old-prefix')
        # Split cat at a known byte boundary; the replacement's suffix would
        # otherwise turn the old prefix into a falsely certified hybrid tuple.
        shim = root / 'split-cat.py'
        shim.write_text("""from pathlib import Path
import sys, time
p = Path(sys.argv[1])
with p.open('rb', buffering=0) as f:
    sys.stdout.buffer.write(f.read(34))
    sys.stdout.buffer.flush()
    (p.parent / 'reading').touch()
    deadline = time.monotonic() + 5
    while not (p.parent / 'continue').exists():
        assert time.monotonic() < deadline
        time.sleep(.005)
    sys.stdout.buffer.write(f.read())
""")
        replacement = b'security/injection|broader|new-focus-and-suffix\n'
        phantom = receipt.read_bytes()[:34] + replacement[34:-1]
        code = r'''split_cat_script="$3"
cat() { python3 "$split_cat_script" "$1"; }
_rounds_all_lenses_completed "$completed_lenses_file" "$4"
'''
        reader = subprocess.Popen(['bash', '-c', base + code, '_', str(repo), str(receipt), str(shim), os.fsdecode(phantom)])
        wait_file(root / 'reading')
        # The real writer must wait for the shared snapshot lock. Probe the
        # inode non-blockingly so the test requires no scheduling guess.
        import fcntl
        with receipt.open('a+b', buffering=0) as probe:
            try:
                fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
                locked = False
            except BlockingIOError:
                locked = True
        writer = subprocess.Popen(['bash', '-c', base + 'mark_lens_completed "$3"', '_', str(repo), str(receipt), os.fsdecode(replacement[:-1])])
        if not locked:
            assert writer.wait(timeout=5) == 0
        (root / 'continue').touch()
        rc = reader.wait(timeout=5)
        assert writer.wait(timeout=5) == 0
        assert rc == 1, 'cross-version snapshot falsely certified hybrid dispatch'
        assert locked, 'reader failed to hold a shared inode lock'
print(f'PASS: completion receipt {case}')
PYTEST
