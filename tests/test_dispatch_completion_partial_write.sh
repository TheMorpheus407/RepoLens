#!/usr/bin/env bash
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
eval "$(sed -n '/^mark_lens_completed() {/,/^}/p' "$1/repolens.sh")"
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
    assert run(lookup, receipt, pending).returncode == 1, 'partial bytes falsely certify pending work'
    assert run(lookup, receipt, executed).returncode == 1
    # Also repair a fragment left by an interrupted older writer.
    receipt.write_text(pending)
    assert run(lookup, receipt, pending).returncode == 1, 'unterminated receipt accepted'
    assert run(script, receipt, executed).returncode == 0
    assert receipt.read_text() == executed + '\n'
    assert run(lookup, receipt, executed).returncode == 0
    assert run(lookup, receipt, pending).returncode == 1
    # Existing valid lines survive the failed append and the repair.
    receipt.write_text('security/xss-csrf\n' + pending)
    assert run(script, receipt, executed).returncode == 0
    assert receipt.read_text() == 'security/xss-csrf\n' + executed + '\n'
print('Results: 10 passed, 0 failed')
PYTEST
