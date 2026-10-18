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

# Regression: repolens-r15-p2-1; real partial receipt writes must not certify work.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$REPO" <<'PYTEST'
from pathlib import Path
import resource
import signal
import subprocess
import sys
import tempfile
repo = Path(sys.argv[1])
pending = 'security/injection|deeper|src/auth.sh:1||README.md'
executed = pending + ',docs/'
script = r"""
set -euo pipefail
source "$1/lib/rounds.sh"
eval "$(sed -n '/^mark_lens_completed() {/,/^}/p' "${REPOLENS_TEST_CALLBACK_SOURCE:-$1/repolens.sh}")"
completed_lenses_file="$2"
mark_lens_completed "$3"
"""
lookup = r"""
set -euo pipefail
source "$1/lib/rounds.sh"
_rounds_all_lenses_completed "$2" "$3"
"""
def limited():
    resource.setrlimit(resource.RLIMIT_FSIZE, (len(pending), len(pending)))
    signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
def run(code, receipt, entry, **kwargs):
    return subprocess.run(['bash', '-c', code, '_', str(repo), str(receipt), entry], **kwargs)
with tempfile.TemporaryDirectory() as root:
    receipt = Path(root) / 'completed'
    receipt.touch()
    assert run(script, receipt, executed, preexec_fn=limited).returncode != 0
    assert receipt.read_bytes() == b'', 'failed append did not roll back'
    assert run(lookup, receipt, pending).returncode == 1, 'partial bytes falsely certify pending work'
    assert run(lookup, receipt, executed).returncode == 1
    # Also repair a fragment left by an interrupted older writer.
    receipt.write_text(pending)
    assert run(lookup, receipt, pending).returncode == 1, 'unterminated receipt accepted'
    assert run(script, receipt, executed).returncode == 0
    assert receipt.read_text() == executed + '\n'
    assert run(lookup, receipt, executed).returncode == 0
    assert run(lookup, receipt, pending).returncode == 1
    # A real failed append preserves prior complete receipts byte for byte.
    prior = b'security/xss-csrf\n'
    receipt.write_bytes(prior)
    assert run(script, receipt, executed, preexec_fn=limited).returncode != 0
    assert receipt.read_bytes() == prior, 'rollback damaged previous receipts'
    # Existing valid lines also survive repair.
    receipt.write_text('security/xss-csrf\n' + pending)
    assert run(script, receipt, executed).returncode == 0
    assert receipt.read_text() == 'security/xss-csrf\n' + executed + '\n'
print('PASS: short-write rollback, prior receipts, and interrupted-tail repair')
PYTEST
